import Foundation
import QuestionBankCore

struct CapturedQuestionRecord {
    let subject: StudySubject
    let sourcePath: String
    let sourceHash: String
    let capturedAt: Date
    let question: String
    let options: [String]
    let correctAnswer: String
    let questionType: String?
    let explanation: String
    let knowledgePoints: [String]
    let needsReview: Bool
    let curriculumSection: String?
    let curriculumChapter: String?
    let contentAnalysisJSON: String?
    let contentInputHash: String?
    let contentCompletedAt: Date?
    let repeatOccurrences: [CapturedQuestionOccurrence]
}

struct CapturedQuestionOccurrence {
    let sourcePath: String
    let sourceHash: String
    let capturedAt: Date
}

struct QuestionBankSyncReport {
    var insertedCount = 0
    var updatedCount = 0
    var unchangedCount = 0
    var skippedReviewCount = 0
    var repeatedWrongCount = 0
    var apiResponseCount = 0
    var synchronizedBySubject: [StudySubject: Int] = [:]
    var failures: [String] = []

    var synchronizedCount: Int { insertedCount + updatedCount + unchangedCount }
    var changedCount: Int { insertedCount + updatedCount }
    var hasFailures: Bool { !failures.isEmpty }

    var summary: String {
        let subjectSummary = StudySubject.allCases.map {
            "\($0.displayName) \(synchronizedBySubject[$0, default: 0]) 题"
        }.joined(separator: "，")
        var value = "练习题本：已同步 \(synchronizedCount) 个截图记录（\(subjectSummary)）"
        if skippedReviewCount > 0 {
            value += "，\(skippedReviewCount) 张待校对图片未进入题本"
        }
        if repeatedWrongCount > 0 {
            value += "，重复遇题错误次数 +\(repeatedWrongCount)"
        }
        if apiResponseCount > 0 {
            value += "，题目分析回复入库 \(apiResponseCount) 条"
        }
        if !failures.isEmpty {
            value += "，\(failures.count) 项同步失败（不影响 JSON 和 Word 文档）"
        }
        return value + "。"
    }

    var diagnostic: String {
        guard !failures.isEmpty else { return summary }
        return summary + "\n" + failures.prefix(20).map { "- \($0)" }.joined(separator: "\n")
    }
}

final class QuestionBankSync {
    private let databaseURLProvider: (StudySubject) throws -> URL

    init(databaseURLProvider: @escaping (StudySubject) throws -> URL = {
        try QuestionBankPaths.defaultDatabaseURL(for: $0)
    }) {
        self.databaseURLProvider = databaseURLProvider
    }

    func synchronize(
        _ records: [CapturedQuestionRecord],
        contentServiceConfiguration: SharedContentServiceConfiguration? = nil
    ) -> QuestionBankSyncReport {
        var report = QuestionBankSyncReport()
        report.skippedReviewCount = records.filter(\.needsReview).count
        let eligible = records.filter { !$0.needsReview }
        guard !eligible.isEmpty else { return report }

        for subject in StudySubject.allCases {
            let subjectRecords = eligible.filter { $0.subject == subject }
            guard !subjectRecords.isEmpty else { continue }
            do {
                let databaseURL = try databaseURLProvider(subject)
                let store = try QuestionBankStore(
                    databaseURL: databaseURL,
                    sourceApplication: "capture:\(subject.rawValue)"
                )
                try store.migrate()
                for record in subjectRecords {
                    do {
                        let draft = try makeDraft(from: record)
                        // 截图同步只导入题目；错题状态只由实际答错或用户明确标记产生。
                        let result = try store.importCapturedQuestion(draft)
                        switch result.status {
                        case .inserted: report.insertedCount += 1
                        case .updated: report.updatedCount += 1
                        case .unchanged: report.unchangedCount += 1
                        }
                        if let json = record.contentAnalysisJSON,
                           let data = json.data(using: .utf8),
                           let contentResult = try? JSONDecoder().decode(QuestionContentResult.self, from: data) {
                            let inputHash = record.contentInputHash ?? "capture:\(record.sourceHash)"
                            let inserted = try store.recordAPIResponse(
                                questionID: result.questionID,
                                inputHash: inputHash,
                                endpoint: contentServiceConfiguration?.endpoint ?? "capture-import",
                                model: contentServiceConfiguration?.model ?? "",
                                result: contentResult,
                                receivedAt: record.contentCompletedAt ?? record.capturedAt
                            )
                            if inserted { report.apiResponseCount += 1 }
                        }
                        for occurrence in record.repeatOccurrences {
                            if try store.recordCapturedQuestionRepeat(
                                questionID: result.questionID,
                                sourceImagePath: occurrence.sourcePath,
                                sourceImageHash: occurrence.sourceHash,
                                capturedAt: occurrence.capturedAt
                            ) {
                                report.repeatedWrongCount += 1
                            }
                        }
                        report.synchronizedBySubject[subject, default: 0] += 1
                    } catch {
                        report.failures.append(
                            "\(subject.displayName) / \(URL(fileURLWithPath: record.sourcePath).lastPathComponent)：\(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                report.failures.append("无法打开\(subject.displayName)题本：\(error.localizedDescription)")
            }
        }

        return report
    }

    private func makeDraft(from record: CapturedQuestionRecord) throws -> CapturedQuestionDraft {
        if record.questionType == "论述题" || (record.subject == .politics && record.options.isEmpty) {
            return CapturedQuestionDraft(
                stableExternalID: CapturedQuestionIdentity.stableExternalID(for: record.question),
                stem: record.question,
                options: [],
                correctLabels: [],
                type: .essay,
                explanation: record.explanation,
                knowledgePoints: record.knowledgePoints,
                sourceImagePath: record.sourcePath,
                sourceImageHash: record.sourceHash,
                capturedAt: record.capturedAt,
                source: "capture",
                curriculumSection: record.curriculumSection,
                curriculumChapter: record.curriculumChapter,
                contentAnalysisJSON: record.contentAnalysisJSON
            )
        }
        let parsedOptions = record.options.enumerated().map { index, raw in
            let fallback = String(UnicodeScalar(65 + index)!)
            let parsed = splitOption(raw, fallbackLabel: fallback)
            return CapturedQuestionOption(originalLabel: parsed.label, text: parsed.text)
        }
        let correctLabels = CapturedQuestionDraft.labels(from: record.correctAnswer)
        let availableLabels = Set(parsedOptions.map { $0.originalLabel.uppercased() })
        guard !correctLabels.isEmpty, correctLabels.isSubset(of: availableLabels) else {
            throw NSError(
                domain: "QuestionBankSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "参考答案无法与选项对应"]
            )
        }

        return CapturedQuestionDraft(
            stableExternalID: CapturedQuestionIdentity.stableExternalID(for: record.question),
            stem: record.question,
            options: parsedOptions,
            correctLabels: correctLabels,
            explanation: record.explanation,
            knowledgePoints: record.knowledgePoints,
            sourceImagePath: record.sourcePath,
            sourceImageHash: record.sourceHash,
            capturedAt: record.capturedAt,
            source: "capture",
            curriculumSection: record.curriculumSection,
            curriculumChapter: record.curriculumChapter,
            contentAnalysisJSON: record.contentAnalysisJSON
        )
    }

    private func splitOption(_ raw: String, fallbackLabel: String) -> (label: String, text: String) {
        let pattern = #"^\s*([A-Fa-f])\s*[\.．、:：]?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let labelRange = Range(match.range(at: 1), in: raw),
              let textRange = Range(match.range(at: 2), in: raw)
        else {
            return (fallbackLabel, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (
            String(raw[labelRange]).uppercased(),
            String(raw[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

}
