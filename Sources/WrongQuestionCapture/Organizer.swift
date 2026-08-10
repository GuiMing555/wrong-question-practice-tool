import AppKit
import CryptoKit
import Foundation
import ImageIO
import QuestionBankCore
import Vision

struct OrganizerProgressUpdate: Sendable {
    let phase: String
    let completed: Int
    let total: Int
    let detail: String
}

enum OrganizerRunMode: Equatable {
    case normal
    case repairPendingExplanationsOnce
}

struct OrganizerContentFailure: Sendable {
    let questionID: String
    let question: String
    let attemptCount: Int
    let reasons: [String]

    var copyText: String {
        let reasonText = reasons.enumerated().map { "第 \($0.offset + 1) 次：\($0.element)" }.joined(separator: "\n")
        return "题目编号：\(questionID)\n题干：\(question)\n连续失败：\(attemptCount) 次\n\(reasonText)"
    }
}

struct OrganizerReport {
    let scannedImageCount: Int
    let newCount: Int
    let updatedCount: Int
    let totalCount: Int
    let uniqueCount: Int
    let duplicateCount: Int
    let repeatedQuestionCount: Int
    let ignoredConsecutiveCount: Int
    let reviewCount: Int
    let automaticallyClassifiedCount: Int
    let unclassifiedCount: Int
    let classificationRetryCount: Int
    let contentSubmittedCount: Int
    let contentReusedCount: Int
    let contentRetriedCount: Int
    let contentCompletedCount: Int
    let repairedExplanationCount: Int
    let contentFailedCount: Int
    let contentFailures: [OrganizerContentFailure]
    let knowledgeCardCount: Int
    let questionBankSync: QuestionBankSyncReport
    let workbookCount: Int
    let workbook: URL?
    let questionBook: URL?
    let answerBook: URL?
    let knowledgeBook: URL?
    let screenshotArchive: URL?
    let archivedImageCount: Int

    var summary: String {
        "本轮读取 \(scannedImageCount) 份采集内容：新增 \(newCount) 份，更新 \(updatedCount) 份；历史记录共 \(totalCount) 份；" +
        "查重后 \(uniqueCount) 题，合并 \(duplicateCount) 个重复记录，" +
        "\(repeatedQuestionCount) 组题目非连续重复出现，" +
        "忽略 \(ignoredConsecutiveCount) 个连续误操作；" +
        "\(reviewCount) 题需人工校对。\n" +
        "科目自动分类：本轮确定 \(automaticallyClassifiedCount) 题，接口重试 \(classificationRetryCount) 次，" +
        "仍有 \(unclassifiedCount) 题待分类。\n" +
        "题目分析 API：复用题库已有回复 \(contentReusedCount) 题，本轮请求 \(contentSubmittedCount) 次，完成 \(contentCompletedCount) 题，" +
        "自动重试 \(contentRetriedCount) 次，" +
        "最终失败 \(contentFailedCount) 题；" +
        "当前可背知识卡 \(knowledgeCardCount) 条。\n" +
        (repairedExplanationCount > 0
            ? "一次性解析补全：已按题干与答案重新生成并写回 \(repairedExplanationCount) 题。\n"
            : "") +
        (workbookCount == 0
            ? "三个科目的题本工作簿均刷新失败。\n"
            : "已刷新 \(workbookCount)/\(StudySubject.allCases.count) 个独立题本工作簿，错题本状态和累计答错次数来自实时作答记录。\n") +
        "已生成当日新增知识点 Word，并按科目与章节去重。\n" +
        (questionBook == nil ? "纯题和答案解析 Word 未开启。\n" : "已按题本表格生成纯题和答案解析 Word。\n") +
        questionBankSync.summary + "\n" +
        (screenshotArchive.map { "已将 \(archivedImageCount) 份本轮原始采集内容校验后封存到：\($0.path)\n" }
            ?? "本轮没有需要封存的原始采集内容。\n") +
        "文件夹：\((workbook ?? questionBook)?.deletingLastPathComponent().path ?? "未生成")"
    }

    var copyableFailureText: String {
        contentFailures.map(\.copyText).joined(separator: "\n\n--------------------\n\n")
    }
}

private struct OrganizerState: Codable {
    var schemaVersion = 11
    var lastRunAt: Date?
    var items: [WrongQuestionItem] = []
}

private struct ContentSubmissionRecord: Codable {
    var requestID: String
    var inputHash: String
    var submittedAt: Date
    var status: String
    var completedAt: Date?
    var failure: String?
    var attemptCount: Int?
    var failureHistory: [String]?
}

private struct WrongQuestionItem: Codable {
    var subject: StudySubject?
    var id: String
    var sourcePath: String
    var sourceHash: String
    var capturedAt: Date
    var recognizedAt: Date
    var rawText: String
    var question: String
    var options: [String]
    var correctAnswer: String
    var userAnswer: String
    var explanation: String
    var knowledgePoints: [String]
    var needsReview: Bool
    var curriculumSection: String?
    var curriculumChapter: String?
    var contentSubmission: ContentSubmissionRecord?
    var contentResult: QuestionContentResult?
}

private struct ParsedQuestion {
    var question: String
    var options: [String]
    var correctAnswer: String
    var userAnswer: String
    var explanation: String
    var needsReview: Bool
}

private struct ContentProcessingReport {
    var submittedCount = 0
    var retriedCount = 0
    var completedCount = 0
    var failedCount = 0
    var classifiedSubjectCount = 0
    var repairedExplanationCount = 0
    var failures: [OrganizerContentFailure] = []
}

private struct ExistingContentReuseReport {
    var reusedCount = 0
}

private struct SubjectClassificationReport {
    var classifiedCount = 0
    var retriedCount = 0
    var unclassifiedCount = 0
}

private struct ContentCandidate {
    let itemIndex: Int
    let input: QuestionContentInput
    let missingAnswer: Bool
    let missingExplanation: Bool
    let isExplanationRepair: Bool
}

private struct DeduplicationResult {
    var items: [WrongQuestionItem]
    var episodeItems: [WrongQuestionItem]
    var consecutiveDuplicateItems: [WrongQuestionItem]
    var occurrenceCountsByID: [String: Int]
    var duplicateCount: Int
    var ignoredConsecutiveCount: Int

    var repeatedQuestionCount: Int {
        occurrenceCountsByID.values.filter { $0 >= 2 }.count
    }
}

final class WrongQuestionOrganizer {
    private let fileManager = FileManager.default
    private let stateEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let stateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func captureRoot(settings: AppSettings = .load()) throws -> URL {
        let root = settings.captureFolderURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func outputFolder(settings: AppSettings = .load()) throws -> URL {
        let folder = settings.outputFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func run(
        settings: AppSettings = .load(),
        mode: OrganizerRunMode = .normal,
        progress: ((OrganizerProgressUpdate) -> Void)? = nil
    ) throws -> OrganizerReport {
        try settings.ensureFoldersExist()
        let root = try Self.captureRoot(settings: settings)
        let output = try Self.outputFolder(settings: settings)
        let stateURL = output.appendingPathComponent(".wrong-question-state.json")
        var state = try loadState(from: stateURL)
        var updatedCount = 0
        if state.schemaVersion < 8 {
            for index in state.items.indices {
                let parsed = parse(rawText: state.items[index].rawText, recognitionMode: settings.recognitionMode)
                state.items[index].question = parsed.question
                state.items[index].options = parsed.options
                state.items[index].correctAnswer = parsed.correctAnswer
                state.items[index].userAnswer = parsed.userAnswer
                state.items[index].explanation = parsed.explanation
                state.items[index].knowledgePoints = []
                state.items[index].needsReview = parsed.needsReview
                state.items[index].recognizedAt = Date()
                updatedCount += 1
            }
            state.schemaVersion = 8
        }
        if state.schemaVersion < 9 {
            // 旧版基于分词频次生成的知识点不再使用，统一等待题目分析接口返回结构化结果。
            for index in state.items.indices {
                state.items[index].knowledgePoints = []
                state.items[index].contentSubmission = nil
                state.items[index].contentResult = nil
            }
            state.schemaVersion = 9
        }
        if state.schemaVersion < 10 {
            // 迁移前的历史截图全部来自医学综合题本；迁移后的新截图自动判断科目。
            for index in state.items.indices where state.items[index].subject == nil {
                state.items[index].subject = .medicalComprehensive
            }
            state.schemaVersion = 10
        }
        if state.schemaVersion < 11 {
            for index in state.items.indices {
                if let result = state.items[index].contentResult {
                    state.items[index].curriculumSection = result.curriculumSection
                    state.items[index].curriculumChapter = result.curriculumChapter
                }
            }
            state.schemaVersion = 11
        }
        if settings.recognitionMode == .fentiQuestionBank {
            for index in state.items.indices where state.items[index].subject == .medicalComprehensive {
                let normalizedQuestion = normalizedFentiMedicalText(state.items[index].question)
                let normalizedOptions = state.items[index].options.map(normalizedFentiMedicalText)
                let normalizedExplanation = normalizedFentiMedicalText(state.items[index].explanation)
                guard normalizedQuestion != state.items[index].question ||
                        normalizedOptions != state.items[index].options ||
                        normalizedExplanation != state.items[index].explanation
                else { continue }
                state.items[index].question = normalizedQuestion
                state.items[index].options = normalizedOptions
                state.items[index].explanation = normalizedExplanation
                state.items[index].recognizedAt = Date()
                updatedCount += 1
            }
        }
        let images = try discoverImages(under: root, excluding: output)
        progress?(OrganizerProgressUpdate(phase: "本机 OCR", completed: 0, total: images.count, detail: "正在检查截图…"))
        var itemsByPath = Dictionary(uniqueKeysWithValues: state.items.map { ($0.sourcePath, $0) })
        var recognizedItemIDs: Set<String> = []
        var nextNumber = (state.items.compactMap { Int($0.id.dropFirst(2)) }.max() ?? 0) + 1
        var newCount = 0

        for (index, imageURL) in images.enumerated() {
            let path = imageURL.path
            let hash = try sha256(of: imageURL)
            if let existing = itemsByPath[path], existing.sourceHash == hash {
                progress?(OrganizerProgressUpdate(
                    phase: "本机 OCR", completed: index + 1, total: images.count,
                    detail: "已检查 \(index + 1) / \(images.count) 份采集内容"
                ))
                continue
            }

            let rawText = try recognizeText(in: imageURL, recognitionMode: settings.recognitionMode)
            let parsed = parse(rawText: rawText, recognitionMode: settings.recognitionMode)
            let old = itemsByPath[path]
            let explicitSubject = old?.subject ?? studySubject(for: imageURL)
            let item = WrongQuestionItem(
                subject: explicitSubject,
                id: old?.id ?? String(format: "WQ%04d", nextNumber),
                sourcePath: path,
                sourceHash: hash,
                capturedAt: captureDate(for: imageURL),
                recognizedAt: Date(),
                rawText: rawText,
                question: parsed.question,
                options: parsed.options,
                correctAnswer: parsed.correctAnswer,
                userAnswer: parsed.userAnswer,
                explanation: parsed.explanation,
                knowledgePoints: [],
                needsReview: parsed.needsReview || explicitSubject == nil,
                curriculumSection: nil,
                curriculumChapter: nil,
                contentSubmission: nil,
                contentResult: nil
            )
            itemsByPath[path] = item
            recognizedItemIDs.insert(item.id)
            if old == nil {
                newCount += 1
                nextNumber += 1
            } else {
                updatedCount += 1
            }

            let completed = index + 1
            if completed % 10 == 0 || completed == images.count {
                print("OCR 进度：\(completed)/\(images.count)")
                fflush(stdout)
            }
            progress?(OrganizerProgressUpdate(
                phase: "本机 OCR", completed: completed, total: images.count,
                detail: "已识别 \(completed) / \(images.count) 份采集内容"
            ))
        }

        state.items = itemsByPath.values.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return $0.id < $1.id
        }
        state.lastRunAt = Date()

        let subjectClassification = try classifySubjects(
            state: &state,
            settings: settings,
            stateURL: stateURL
        )

        var deduplicated = deduplicatedItems(state.items)
        let repairKeys: Set<String> = mode == .repairPendingExplanationsOnce
            ? Set(state.items.filter { recognizedItemIDs.contains($0.id) }.map(duplicateKey))
            : []
        let forcedExplanationItemIDs: Set<String> = Set(
            deduplicated.items.compactMap { repairKeys.contains(duplicateKey(for: $0)) ? $0.id : nil }
        )
        let reusedContent = try reuseStoredContentResults(
            state: &state,
            primaryItemIDs: Set(deduplicated.items.map(\.id)),
            excludingItemIDs: forcedExplanationItemIDs,
            stateURL: stateURL
        )
        let contentReport = try processContentService(
            state: &state,
            primaryItemIDs: Set(deduplicated.items.map(\.id)),
            forcedExplanationItemIDs: forcedExplanationItemIDs,
            repairOnly: mode == .repairPendingExplanationsOnce,
            settings: settings,
            stateURL: stateURL,
            progress: progress
        )
        deduplicated = deduplicatedItems(state.items)
        let legacyKnowledgeBook = output.appendingPathComponent("医学综合错题本_薄弱知识点.docx")
        if fileManager.fileExists(atPath: legacyKnowledgeBook.path) {
            try fileManager.removeItem(at: legacyKnowledgeBook)
        }
        try syncProblemImages(
            reviewItems: state.items.filter(\.needsReview),
            consecutiveDuplicateItems: deduplicated.consecutiveDuplicateItems,
            under: root
        )
        try stateEncoder.encode(state).write(to: stateURL, options: .atomic)

        // 题本内容仍按题干只同步一份。非连续重复截图作为独立遇错事件写入计数，
        // 连续截图视为误操作，不增加错误次数。
        let syncRecords = deduplicated.items.compactMap { item -> CapturedQuestionRecord? in
            guard let subject = item.subject else { return nil }
            let key = duplicateKey(for: item)
            let repeats = deduplicated.episodeItems.filter {
                $0.id != item.id && duplicateKey(for: $0) == key
            }.map {
                CapturedQuestionOccurrence(
                    sourcePath: $0.sourcePath,
                    sourceHash: $0.sourceHash,
                    capturedAt: $0.capturedAt
                )
            }
            return CapturedQuestionRecord(
                subject: subject,
                sourcePath: item.sourcePath,
                sourceHash: item.sourceHash,
                capturedAt: item.capturedAt,
                question: item.question,
                options: item.options,
                correctAnswer: item.correctAnswer,
                questionType: item.contentResult?.questionType ?? (isEssayItem(item) ? "论述题" : nil),
                explanation: item.explanation,
                knowledgePoints: item.knowledgePoints,
                needsReview: item.needsReview,
                curriculumSection: item.curriculumSection ?? item.contentResult?.curriculumSection,
                curriculumChapter: item.curriculumChapter ?? item.contentResult?.curriculumChapter,
                contentAnalysisJSON: encodedContentResult(item.contentResult),
                contentInputHash: item.contentSubmission?.inputHash,
                contentCompletedAt: item.contentSubmission?.completedAt,
                repeatOccurrences: repeats
            )
        }
        let sharedContentConfiguration = SharedContentServiceConfiguration(
            enabled: settings.contentServiceEnabled,
            endpoint: settings.contentServiceEndpoint,
            model: settings.contentServiceModel,
            accessKey: settings.contentServiceAccessKey,
            knowledgeDocumentFolderPath: settings.outputFolderPath
        )
        let questionBankSync = QuestionBankSync().synchronize(
            syncRecords,
            contentServiceConfiguration: sharedContentConfiguration
        )
        if questionBankSync.hasFailures {
            FileHandle.standardError.write(Data((questionBankSync.diagnostic + "\n").utf8))
        }

        var workbook: URL?
        var workbookCount = 0
        var workbookRowsBySubject: [StudySubject: [QuestionWorkbookRow]] = [:]
        for subject in StudySubject.allCases {
            let workbookURL = output.appendingPathComponent(subject.workbookFilename)
            do {
                let store = try QuestionBankStore(
                    databaseURL: QuestionBankPaths.defaultDatabaseURL(for: subject),
                    sourceApplication: "capture-workbook:\(subject.rawValue)"
                )
                try store.configureWorkbookOutput(workbookURL)
                let generated = try store.exportWorkbook(to: workbookURL)
                workbookCount += 1
                workbookRowsBySubject[subject] = try store.workbookRows()
                if subject == .medicalComprehensive { workbook = generated }
            } catch {
                FileHandle.standardError.write(
                    Data(("\(subject.displayName)题本工作簿刷新失败：\(error.localizedDescription)\n").utf8)
                )
            }
        }

        let completedItems = deduplicated.items.filter { $0.contentResult != nil }
        let today = Date()
        let startOfToday = Calendar.current.startOfDay(for: today)
        let startOfTomorrow = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday) ?? today
        var dailyKnowledgeRecords: [QuestionKnowledgeRecord] = []
        for subject in StudySubject.allCases {
            let store = try QuestionBankStore(
                databaseURL: QuestionBankPaths.defaultDatabaseURL(for: subject),
                sourceApplication: "capture-daily-knowledge:\(subject.rawValue)"
            )
            dailyKnowledgeRecords += try store.knowledgeRecords(
                subject: subject,
                wrongBookOnly: false,
                receivedFrom: startOfToday,
                receivedBefore: startOfTomorrow
            )
        }
        let knowledgeBookURL = output.appendingPathComponent("\(shortDate(today))新增知识点.docx")
        try KnowledgeDocumentWriter.write(
            records: dailyKnowledgeRecords,
            kind: .dailyNew(date: today),
            to: knowledgeBookURL
        )
        var questionBook: URL?
        var answerBook: URL?
        let knowledgeBook: URL? = knowledgeBookURL
        if settings.generateWordDocuments {
            for subject in StudySubject.allCases {
                let questionBookURL = output.appendingPathComponent(subject.questionDocumentFilename)
                let answerBookURL = output.appendingPathComponent(subject.answerDocumentFilename)
                let rows = workbookRowsBySubject[subject, default: []]
                try createQuestionBook(rows: rows, subject: subject, at: questionBookURL)
                try createAnswerBook(rows: rows, subject: subject, at: answerBookURL)
                if subject == .medicalComprehensive {
                    questionBook = questionBookURL
                    answerBook = answerBookURL
                }
            }
        }

        let knowledgeCardCount = completedItems.reduce(0) { $0 + ($1.contentResult?.knowledgeCards.count ?? 0) }
        progress?(OrganizerProgressUpdate(
            phase: "封存原始采集内容",
            completed: 0,
            total: images.isEmpty ? 0 : 1,
            detail: images.isEmpty ? "没有待封存的原始采集内容" : "正在创建并校验本轮采集内容压缩包…"
        ))
        let screenshotArchive = try ScreenshotBatchArchiver().archive(
            imageURLs: images,
            captureRoot: root
        )
        if screenshotArchive != nil {
            progress?(OrganizerProgressUpdate(
                phase: "封存原始采集内容",
                completed: 1,
                total: 1,
                detail: "已封存 \(screenshotArchive?.archivedImageCount ?? 0) 份原始采集内容"
            ))
        }

        return OrganizerReport(
            scannedImageCount: images.count,
            newCount: newCount,
            updatedCount: updatedCount,
            totalCount: state.items.count,
            uniqueCount: deduplicated.items.count,
            duplicateCount: deduplicated.duplicateCount,
            repeatedQuestionCount: deduplicated.repeatedQuestionCount,
            ignoredConsecutiveCount: deduplicated.ignoredConsecutiveCount,
            reviewCount: state.items.filter(\.needsReview).count,
            automaticallyClassifiedCount: subjectClassification.classifiedCount + contentReport.classifiedSubjectCount,
            unclassifiedCount: state.items.filter {
                $0.subject == nil ||
                    (settings.contentServiceEnabled && $0.contentSubmission?.status == "failed" && $0.contentResult == nil)
            }.count,
            classificationRetryCount: contentReport.retriedCount,
            contentSubmittedCount: contentReport.submittedCount,
            contentReusedCount: reusedContent.reusedCount,
            contentRetriedCount: contentReport.retriedCount,
            contentCompletedCount: contentReport.completedCount,
            repairedExplanationCount: contentReport.repairedExplanationCount,
            contentFailedCount: contentReport.failedCount,
            contentFailures: contentReport.failures,
            knowledgeCardCount: knowledgeCardCount,
            questionBankSync: questionBankSync,
            workbookCount: workbookCount,
            workbook: workbook,
            questionBook: questionBook,
            answerBook: answerBook,
            knowledgeBook: knowledgeBook,
            screenshotArchive: screenshotArchive?.archiveURL,
            archivedImageCount: screenshotArchive?.archivedImageCount ?? 0
        )
    }

    private func loadState(from url: URL) throws -> OrganizerState {
        guard fileManager.fileExists(atPath: url.path) else { return OrganizerState() }
        let decoded = try stateDecoder.decode(OrganizerState.self, from: Data(contentsOf: url))
        return decoded
    }

    private func reuseStoredContentResults(
        state: inout OrganizerState,
        primaryItemIDs: Set<String>,
        excludingItemIDs: Set<String> = [],
        stateURL: URL
    ) throws -> ExistingContentReuseReport {
        var report = ExistingContentReuseReport()
        var stores: [StudySubject: QuestionBankStore] = [:]
        for index in state.items.indices {
            let item = state.items[index]
            guard primaryItemIDs.contains(item.id),
                  !excludingItemIDs.contains(item.id),
                  let subject = item.subject,
                  let candidate = contentCandidate(for: item, at: index)
            else { continue }
            if item.contentSubmission?.status == "completed", item.contentResult != nil { continue }

            if let existingResult = item.contentResult, !existingResult.knowledgeCards.isEmpty {
                state.items[index].contentSubmission = ContentSubmissionRecord(
                    requestID: "reused:state:\(item.id)",
                    inputHash: QuestionContentService.inputHash(candidate.input),
                    submittedAt: item.recognizedAt,
                    status: "completed",
                    completedAt: item.recognizedAt,
                    failure: nil,
                    attemptCount: 0,
                    failureHistory: []
                )
                report.reusedCount += 1
                continue
            }
            let store: QuestionBankStore
            if let existing = stores[subject] {
                store = existing
            } else {
                store = try QuestionBankStore(
                    databaseURL: QuestionBankPaths.defaultDatabaseURL(for: subject),
                    sourceApplication: "capture-analysis-reuse:\(subject.rawValue)"
                )
                stores[subject] = store
            }
            let externalID = CapturedQuestionIdentity.stableExternalID(for: item.question)
            guard let stored = try store.storedAnalysis(externalID: externalID),
                  stored.result.subject == subject
            else { continue }

            if candidate.missingExplanation,
               let explanation = stored.result.resolvedExplanation,
               !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.items[index].explanation = explanation
            }
            if candidate.missingAnswer,
               !isEssayItem(state.items[index]),
               let answer = normalizedResolvedAnswer(
                   stored.result.resolvedAnswer,
                   options: state.items[index].options
               ) {
                state.items[index].correctAnswer = answer
            }
            state.items[index].contentResult = stored.result
            state.items[index].subject = stored.result.subject
            state.items[index].curriculumSection = stored.result.curriculumSection
            state.items[index].curriculumChapter = stored.result.curriculumChapter
            state.items[index].knowledgePoints = stored.result.knowledgeCards.map(\.title)
            let currentCandidate = contentCandidate(for: state.items[index], at: index) ?? candidate
            state.items[index].contentSubmission = ContentSubmissionRecord(
                requestID: "reused:\(stored.questionID)",
                inputHash: QuestionContentService.inputHash(currentCandidate.input),
                submittedAt: stored.receivedAt,
                status: "completed",
                completedAt: stored.receivedAt,
                failure: nil,
                attemptCount: 0,
                failureHistory: []
            )
            report.reusedCount += 1
        }
        if report.reusedCount > 0 {
            try stateEncoder.encode(state).write(to: stateURL, options: .atomic)
        }
        return report
    }

    private func classifySubjects(
        state: inout OrganizerState,
        settings: AppSettings,
        stateURL: URL
    ) throws -> SubjectClassificationReport {
        var report = SubjectClassificationReport()

        for index in state.items.indices where state.items[index].subject == nil {
            let question = state.items[index].question
            let options = state.items[index].options
            let detected = QuestionSubjectClassifier.classifyLocally(
                question: question,
                options: options
            )

            if let detected {
                state.items[index].subject = detected
                let reparsed = parse(
                    rawText: state.items[index].rawText,
                    recognitionMode: settings.recognitionMode
                )
                state.items[index].needsReview = reparsed.needsReview
                report.classifiedCount += 1
            } else {
                state.items[index].needsReview = true
            }
        }
        report.unclassifiedCount = state.items.filter { $0.subject == nil }.count
        try stateEncoder.encode(state).write(to: stateURL, options: .atomic)
        return report
    }

    private func processContentService(
        state: inout OrganizerState,
        primaryItemIDs: Set<String>,
        forcedExplanationItemIDs: Set<String> = [],
        repairOnly: Bool = false,
        settings: AppSettings,
        stateURL: URL,
        progress: ((OrganizerProgressUpdate) -> Void)?
    ) throws -> ContentProcessingReport {
        var report = ContentProcessingReport()
        guard settings.contentServiceEnabled,
              let endpoint = URL(string: settings.contentServiceEndpoint)
        else { return report }

        let service = QuestionContentService(
            endpoint: endpoint,
            accessKey: settings.contentServiceAccessKey,
            model: settings.contentServiceModel
        )
        let maximumAttempts = 3
        for index in state.items.indices {
            let item = state.items[index]
            if repairOnly, !forcedExplanationItemIDs.contains(item.id) { continue }
            guard let candidate = contentCandidate(
                for: item,
                at: index,
                forceCompleteExplanation: forcedExplanationItemIDs.contains(item.id)
            ) else { continue }
            let currentHash = QuestionContentService.inputHash(candidate.input)
            guard primaryItemIDs.contains(item.id),
                  let submission = item.contentSubmission,
                  submission.inputHash == currentHash,
                  submission.status == "failed",
                  (submission.attemptCount ?? 0) >= maximumAttempts
            else { continue }
            let reasons = submission.failureHistory ?? submission.failure.map { [$0] } ?? ["未记录具体原因"]
            report.failures.append(
                OrganizerContentFailure(
                    questionID: item.id,
                    question: item.question,
                    attemptCount: submission.attemptCount ?? maximumAttempts,
                    reasons: reasons
                )
            )
        }
        report.failedCount = report.failures.count
        let candidates = state.items.indices.compactMap { index -> ContentCandidate? in
            let item = state.items[index]
            if repairOnly, !forcedExplanationItemIDs.contains(item.id) { return nil }
            guard primaryItemIDs.contains(item.id),
                  !item.question.hasPrefix("[OCR"),
                  (item.options.count >= 2 || isEssayItem(item)),
                  let candidate = contentCandidate(
                    for: item,
                    at: index,
                    forceCompleteExplanation: forcedExplanationItemIDs.contains(item.id)
                  )
            else { return nil }
            let currentHash = QuestionContentService.inputHash(candidate.input)
            guard let submission = item.contentSubmission else { return candidate }
            if submission.inputHash != currentHash { return candidate }
            if submission.status == "completed", item.contentResult != nil { return nil }
            return submission.status == "failed" && (submission.attemptCount ?? 1) < maximumAttempts
                ? candidate
                : nil
        }
        let progressPhase = forcedExplanationItemIDs.isEmpty ? "题目分析 API" : "一次性解析补全 API"
        progress?(OrganizerProgressUpdate(
            phase: progressPhase, completed: 0, total: candidates.count,
            detail: candidates.isEmpty ? "没有需要提交的新题" : "准备分析 \(candidates.count) 道题…"
        ))

        let concurrentRequestCount = 8
        var pendingCandidates = candidates
        var nextCandidatePosition = 0
        var completedPosition = 0
        while nextCandidatePosition < pendingCandidates.count {
            let end = min(nextCandidatePosition + concurrentRequestCount, pendingCandidates.count)
            let wave = Array(pendingCandidates[nextCandidatePosition..<end])
            for candidate in wave {
                let previousSubmission = state.items[candidate.itemIndex].contentSubmission
                let inputHash = QuestionContentService.inputHash(candidate.input)
                let isSameInput = previousSubmission?.inputHash == inputHash
                let previousAttempts = isSameInput ? (previousSubmission?.attemptCount ?? 1) : 0
                let previousFailures = isSameInput
                    ? (previousSubmission?.failureHistory ?? previousSubmission?.failure.map { [$0] } ?? [])
                    : []
                if previousAttempts > 0 {
                    report.retriedCount += 1
                }
                state.items[candidate.itemIndex].contentSubmission = ContentSubmissionRecord(
                    requestID: UUID().uuidString,
                    inputHash: inputHash,
                    submittedAt: Date(),
                    status: "submitted",
                    completedAt: nil,
                    failure: nil,
                    attemptCount: previousAttempts + 1,
                    failureHistory: previousFailures
                )
            }
            // 每一并发批次在发出请求前落盘，确保重启后不会超过限定重试次数。
            try stateEncoder.encode(state).write(to: stateURL, options: .atomic)
            report.submittedCount += wave.count

            let resultLock = NSLock()
            var results: [Int: Result<QuestionContentResult, Error>] = [:]
            DispatchQueue.concurrentPerform(iterations: wave.count) { offset in
                let candidate = wave[offset]
                let result: Result<QuestionContentResult, Error>
                do {
                    result = .success(try service.analyze(candidate.input))
                } catch {
                    result = .failure(error)
                }
                resultLock.lock()
                results[candidate.itemIndex] = result
                resultLock.unlock()
            }

            var retryCandidates: [ContentCandidate] = []
            for candidate in wave {
                let index = candidate.itemIndex
                do {
                    guard let outcome = results[index] else {
                        throw QuestionContentServiceError.emptyResponse
                    }
                    let result = try outcome.get()
                    if candidate.missingExplanation {
                        guard let explanation = result.resolvedExplanation, !explanation.isEmpty else {
                            throw QuestionContentServiceError.invalidResponse
                        }
                        state.items[index].explanation = explanation
                    }
                    if candidate.missingAnswer {
                        guard let answer = normalizedResolvedAnswer(
                            result.resolvedAnswer,
                            options: state.items[index].options
                        ) else { throw QuestionContentServiceError.invalidResponse }
                        state.items[index].correctAnswer = answer
                    }

                    state.items[index].contentResult = result
                    report.classifiedSubjectCount += 1
                    state.items[index].subject = result.subject
                    state.items[index].curriculumSection = result.curriculumSection
                    state.items[index].curriculumChapter = result.curriculumChapter
                    state.items[index].knowledgePoints = result.knowledgeCards.map(\.title)
                    state.items[index].contentSubmission?.status = "completed"
                    state.items[index].contentSubmission?.completedAt = Date()
                    state.items[index].contentSubmission?.failure = nil
                    if candidate.isExplanationRepair {
                        report.repairedExplanationCount += 1
                    }
                    if let canonical = contentCandidate(for: state.items[index], at: index) {
                        state.items[index].contentSubmission?.inputHash = QuestionContentService.inputHash(canonical.input)
                    }

                    let minimumOptions = result.questionType == "判断题" ? 2 : 4
                    let isEssay = result.questionType == "论述题"
                    let structuralIssue = state.items[index].question.hasPrefix("[OCR") ||
                        (!isEssay && state.items[index].options.count < minimumOptions) ||
                        state.items[index].options.contains(where: isSuspiciousFentiOption)
                    if !structuralIssue,
                       (isEssay || state.items[index].correctAnswer != "待校对"),
                       !state.items[index].explanation.hasPrefix("待人工补充") {
                        state.items[index].needsReview = false
                    }
                    report.completedCount += 1
                } catch {
                    state.items[index].contentSubmission?.status = "failed"
                    state.items[index].contentSubmission?.completedAt = Date()
                    state.items[index].contentSubmission?.failure = error.localizedDescription
                    var failureHistory = state.items[index].contentSubmission?.failureHistory ?? []
                    failureHistory.append(error.localizedDescription)
                    state.items[index].contentSubmission?.failureHistory = failureHistory
                    let attemptCount = state.items[index].contentSubmission?.attemptCount ?? maximumAttempts
                    if attemptCount < maximumAttempts {
                        retryCandidates.append(candidate)
                        print("题目分析自动重试：\(state.items[index].id)（第 \(attemptCount + 1)/\(maximumAttempts) 次）")
                        fflush(stdout)
                        progress?(OrganizerProgressUpdate(
                            phase: progressPhase, completed: completedPosition, total: candidates.count,
                            detail: "\(state.items[index].id) 第 \(attemptCount) 次失败，正在进行第 \(attemptCount + 1) 次尝试…"
                        ))
                        continue
                    }
                    state.items[index].needsReview = true
                    report.failedCount += 1
                    let failures = state.items[index].contentSubmission?.failureHistory ?? [error.localizedDescription]
                    report.failures.append(
                        OrganizerContentFailure(
                            questionID: state.items[index].id,
                            question: state.items[index].question,
                            attemptCount: attemptCount,
                            reasons: failures
                        )
                    )
                }
                completedPosition += 1
                print("题目分析进度：\(completedPosition)/\(candidates.count)")
                fflush(stdout)
                progress?(OrganizerProgressUpdate(
                    phase: progressPhase, completed: completedPosition, total: candidates.count,
                    detail: "已完成 \(completedPosition) / \(candidates.count) 道题"
                ))
            }
            try stateEncoder.encode(state).write(to: stateURL, options: .atomic)
            pendingCandidates.append(contentsOf: retryCandidates)
            nextCandidatePosition = end
        }
        return report
    }

    private func contentCandidate(
        for item: WrongQuestionItem,
        at index: Int,
        forceCompleteExplanation: Bool = false
    ) -> ContentCandidate? {
        let isEssay = isEssayItem(item)
        guard !item.question.hasPrefix("[OCR"), item.options.count >= 2 || isEssay else { return nil }
        let missingAnswer = !isEssay && item.correctAnswer == "待校对"
        let missingExplanation = forceCompleteExplanation || item.explanation.hasPrefix("待人工补充")
        return ContentCandidate(
            itemIndex: index,
            input: QuestionContentInput(
                stableID: item.id,
                question: item.question,
                options: item.options,
                knownAnswer: missingAnswer ? nil : item.correctAnswer,
                existingExplanation: missingExplanation ? nil : item.explanation,
                requiresSolution: missingAnswer || missingExplanation,
                subjectHint: item.subject?.displayName,
                forceCompleteExplanation: forceCompleteExplanation
            ),
            missingAnswer: missingAnswer,
            missingExplanation: missingExplanation,
            isExplanationRepair: forceCompleteExplanation
        )
    }

    private func isEssayItem(_ item: WrongQuestionItem) -> Bool {
        item.contentResult?.questionType == "论述题" ||
            item.rawText.range(
                of: #"[\[［【(（]\s*(论述题|问答题|简答题)\s*[\]］】)）]"#,
                options: .regularExpression
            ) != nil
    }

    private func encodedContentResult(_ result: QuestionContentResult?) -> String? {
        guard let result else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func normalizedResolvedAnswer(_ answer: String?, options: [String]) -> String? {
        guard let answer else { return nil }
        let labels = answer.uppercased().unicodeScalars.compactMap { scalar -> String? in
            guard (65...70).contains(Int(scalar.value)) else { return nil }
            return String(Character(scalar))
        }
        let unique = Array(Set(labels)).sorted()
        guard !unique.isEmpty else { return nil }
        let available = Set(options.compactMap { optionComponents(in: $0)?.label })
        guard Set(unique).isSubset(of: available) else { return nil }
        return unique.joined()
    }

    private func discoverImages(under root: URL, excluding output: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let imageExtensions = Set(["png", "jpg", "jpeg", "heic"])
        let rootPath = root.standardizedFileURL.path
        let outputPath = output.standardizedFileURL.path
        let outputIsNested = outputPath != rootPath && outputPath.hasPrefix(rootPath + "/")
        return enumerator.compactMap { entry in
            guard let url = entry as? URL,
                  (!outputIsNested || !url.path.hasPrefix(outputPath + "/")),
                  !url.pathComponents.contains(where: { $0.hasPrefix("待人工校对图片") }),
                  !url.pathComponents.contains(ScreenshotBatchArchiver.archiveFolderName),
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            else { return nil }
            let isImage = imageExtensions.contains(url.pathExtension.lowercased())
            let isSnapshot = PageSnapshotSidecar.isStandaloneSnapshotURL(url)
            guard isImage || isSnapshot else { return nil }
            if isSnapshot {
                let basePath = String(url.path.dropLast(PageSnapshotSidecar.standaloneSuffix.count))
                if fileManager.fileExists(atPath: basePath) {
                    // 图片旁边的文字副本由图片作为主记录处理，不重复导入。
                    return nil
                }
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func recognizeText(in url: URL, recognitionMode: RecognitionMode) throws -> String {
        if let pageSnapshot = PageSnapshotSidecar.readStandalone(from: url), pageSnapshot.count >= 20 {
            return pageSnapshot
        }
        if let pageSnapshot = PageSnapshotSidecar.read(nextTo: url), pageSnapshot.count >= 20 {
            return pageSnapshot
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw NSError(domain: "WrongQuestionOrganizer", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图片：\(url.lastPathComponent)"])
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropRect: CGRect
        switch recognitionMode {
        case .fentiQuestionBank:
            // 焚题库正文位于窗口左侧。保留接近页面顶端的题干，同时裁掉右侧答题卡。
            cropRect = CGRect(
                x: width * 0.055,
                y: height * 0.035,
                width: width * 0.690,
                height: height * 0.930
            ).integral
        case .general:
            cropRect = CGRect(
                x: width * 0.015,
                y: height * 0.015,
                width: width * 0.970,
                height: height * 0.970
            ).integral
        }
        guard let cropped = image.cropping(to: cropRect) else {
            throw NSError(domain: "WrongQuestionOrganizer", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "无法裁切图片：\(url.lastPathComponent)"])
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        if recognitionMode == .fentiQuestionBank {
            request.customWords = [
                "参考答案", "我的答案", "参考解析", "单选题", "多选题", "判断题",
                "HIV", "Horner综合征", "Duroziez双重杂音", "肾小盏", "麻痹性斜视",
                "Na+", "K+", "促甲状腺激素", "肺动脉瓣狭窄", "前纵韧带", "中度烧伤", "重度烧伤", "特重烧伤",
                "浅II度烧伤", "深II度烧伤", "III度烧伤"
            ]
        }
        try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])

        let observations = (request.results ?? []).sorted {
            let verticalDifference = abs($0.boundingBox.midY - $1.boundingBox.midY)
            if verticalDifference > 0.012 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func parse(rawText: String, recognitionMode: RecognitionMode) -> ParsedQuestion {
        var lines = rawText.components(separatedBy: .newlines)
            .map(cleanLine)
            .filter {
                !$0.isEmpty && (!isInterfaceNoise($0, recognitionMode: recognitionMode) || ExplanationBoundary.isExactMarker($0))
            }
        if recognitionMode == .fentiQuestionBank,
           let reordered = reorderedFentiPageSnapshotLines(lines), !reordered.isEmpty {
            lines = reordered
        }

        let questionMarkerPattern = #"\d*\s*[\[［【(（]\s*(单选题|多选题|判断题|论述题|问答题|简答题)\s*[\]］】)）Jj]?"#
        let hasQuestionMarker = lines.contains {
            $0.range(of: questionMarkerPattern, options: .regularExpression) != nil
        }
        let questionIndex = lines.firstIndex {
            $0.range(of: questionMarkerPattern, options: .regularExpression) != nil
        } ?? lines.firstIndex { line in
            line.contains("单选题") || line.contains("多选题") || line.contains("判断题") ||
                line.contains("论述题") || line.contains("问答题") || line.contains("简答题")
        } ?? 0
        if questionIndex > 0 { lines = Array(lines[questionIndex...]) }

        let answerIndex = lines.firstIndex { $0.contains("参考答案") } ?? lines.count
        let explanationIndex = lines.firstIndex { $0.contains("参考解析") }
        let beforeAnswer = Array(lines.prefix(answerIndex)).flatMap(splitEmbeddedFirstOption)
        let questionStop = beforeAnswer.indices.dropFirst().first { isQuestionAreaStop(beforeAnswer[$0]) }
            ?? beforeAnswer.endIndex
        let questionArea = Array(beforeAnswer[..<questionStop])

        let explicitOptions = questionArea.enumerated().compactMap { index, line -> (Int, String, String)? in
            guard let option = optionComponents(in: line) else { return nil }
            return (index, option.label, option.text)
        }

        var questionLines = questionArea
        var options: [String] = []
        if let first = explicitOptions.first,
           let firstLabelIndex = optionLabelIndex(first.1) {
            // 浅灰色的 A/B/C/D 有时不会被 Vision 识别，但正文仍然存在。
            // 根据相邻已识别选项的顺序恢复标签，不补写任何选项正文。
            let optionStart = max(1, first.0 - firstLabelIndex)
            questionLines = Array(questionArea.prefix(optionStart))
            var recovered: [Int: String] = [:]
            var expected = 0

            for index in optionStart..<questionArea.count {
                let line = questionArea[index]
                if let option = optionComponents(in: line),
                   let labelIndex = optionLabelIndex(option.label), labelIndex < 4 {
                    recovered[labelIndex] = cleanedOptionText(
                        option.text,
                        expectedLabel: option.label,
                        recognitionMode: recognitionMode
                    )
                    expected = max(expected, labelIndex + 1)
                } else if expected < 4 {
                    let label = String(UnicodeScalar(65 + expected)!)
                    guard let text = unlabeledOptionCandidate(from: line, expectedLabel: label) else { continue }
                    recovered[expected] = cleanedOptionText(
                        text,
                        expectedLabel: label,
                        recognitionMode: recognitionMode
                    )
                    expected += 1
                }
            }

            options = (0..<4).compactMap { index in
                guard let text = recovered[index] else { return nil }
                let label = String(UnicodeScalar(65 + index)!)
                return "\(label). \(text)"
            }
        }

        var question = questionLines.joined(separator: " ")
        question = question.replacingOccurrences(
            of: #"^\s*\d*\s*[\[［【(（]\s*(单选题|多选题|判断题|论述题|问答题|简答题)\s*[\]］】)）1lI|｜Jj]?\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        question = question.replacingOccurrences(
            of: #"\s+[0oOiIl丨|｜Xx◎○〇×]\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        question = QuestionTextCleanup.removingRepeatedIntroductoryBlock(from: question)
        if recognitionMode == .fentiQuestionBank {
            question = QuestionTextCleanup.removingQuestionBankHeaderArtifacts(from: question)
            question = normalizedFentiMedicalText(question)
        }

        if question.isEmpty {
            question = "[OCR 未能可靠识别题干，请对照原截图]"
        }

        let isEssayQuestion = lines.contains {
            $0.range(
                of: #"[\[［【(（]\s*(论述题|问答题|简答题)\s*[\]］】)）]"#,
                options: .regularExpression
            ) != nil
        }
        let correctAnswer = isEssayQuestion ? "主观评分" : extractAnswer(label: "参考答案", lines: lines)
        let userAnswer = extractAnswer(label: "我的答案", lines: lines)
        var explanation = ""
        if let start = explanationIndex {
            let first = lines[start].replacingOccurrences(
                of: #"^.*?参考解析\s*[:：]?\s*"#,
                with: "",
                options: .regularExpression
            )
            var explanationLines = first.isEmpty ? [] : [first]
            if start + 1 < lines.count {
                for index in (start + 1)..<lines.count {
                    let line = lines[index]
                    if ExplanationBoundary.shouldStop(
                        at: line,
                        previousContentLine: explanationLines.last,
                        isLastLine: index == lines.index(before: lines.endIndex)
                    ) { break }
                    explanationLines.append(line)
                }
            }
            explanation = explanationLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if recognitionMode == .fentiQuestionBank {
            explanation = normalizedFentiMedicalText(explanation)
        }
        if isEssayQuestion {
            let referenceAnswer = extractEssayReferenceAnswer(
                lines: lines,
                answerIndex: answerIndex,
                explanationIndex: explanationIndex
            )
            if explanation.isEmpty {
                explanation = referenceAnswer
            } else if !referenceAnswer.isEmpty, !explanation.contains(referenceAnswer) {
                explanation = "参考答案：\(referenceAnswer)\n参考解析：\(explanation)"
            }
        }
        if explanation.isEmpty { explanation = "待人工补充：截图中未可靠识别到参考解析。" }

        let isBinaryQuestion = questionArea.first?.contains("判断题") == true
        let minimumOptions = isEssayQuestion ? 0 : (isBinaryQuestion ? 2 : 4)
        let suspiciousFentiStem = recognitionMode == .fentiQuestionBank &&
            isSuspiciousFentiStem(question, hasQuestionMarker: hasQuestionMarker)
        let suspiciousFentiOptions = recognitionMode == .fentiQuestionBank &&
            options.contains(where: isSuspiciousFentiOption)
        let needsReview = question.hasPrefix("[OCR") || options.count < minimumOptions ||
            (!isEssayQuestion && correctAnswer == "待校对") || explanation.hasPrefix("待人工补充") ||
            suspiciousFentiStem || suspiciousFentiOptions

        return ParsedQuestion(
            question: question,
            options: options,
            correctAnswer: correctAnswer,
            userAnswer: userAnswer,
            explanation: explanation,
            needsReview: needsReview
        )
    }

    func diagnosticParsedSnapshot(_ rawText: String) -> String {
        let parsed = parse(rawText: rawText, recognitionMode: .fentiQuestionBank)
        let object: [String: Any] = [
            "question": parsed.question,
            "options": parsed.options,
            "correctAnswer": parsed.correctAnswer,
            "explanation": parsed.explanation,
            "needsReview": parsed.needsReview
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func pageSnapshotIsUsable(_ rawText: String) -> Bool {
        let parsed = parse(rawText: rawText, recognitionMode: .fentiQuestionBank)
        return !parsed.needsReview &&
            !parsed.question.hasPrefix("[OCR") &&
            !parsed.explanation.hasPrefix("待人工补充")
    }

    /// 焚题库的“全选复制”顺序与视觉顺序不同：统计和解析在题型标记之前，
    /// 当前题干和选项在题型标记之后。重排为旧解析器使用的标准顺序。
    private func reorderedFentiPageSnapshotLines(_ lines: [String]) -> [String]? {
        let markerPattern = #"^\s*[\[［【(（]\s*(单选题|多选题|判断题|论述题|问答题|简答题)\s*[\]］】)）]\s*$"#
        guard let markerIndex = lines.lastIndex(where: {
            $0.range(of: markerPattern, options: .regularExpression) != nil
        }) else { return nil }

        let stopPrefixes = [
            "手动评判", "收藏本题", "纠错", "收起解析", "展开解析",
            "试题答疑", "做题笔记", "答对", "答错", "返回", "计算器", "设置"
        ]
        var questionBlock: [String] = []
        if markerIndex + 1 < lines.count {
            for line in lines[(markerIndex + 1)...] {
                if stopPrefixes.contains(where: line.hasPrefix) { break }
                questionBlock.append(line)
            }
        }
        guard !questionBlock.isEmpty else { return nil }

        let resultIndex = lines[..<markerIndex].lastIndex {
            $0 == "回答错误" || $0 == "回答正确"
        }
        var explanationStart: Int?
        if let resultIndex {
            explanationStart = lines[(resultIndex + 1)..<markerIndex].lastIndex {
                $0.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) != nil
            }.map { $0 + 1 }
            if explanationStart == nil { explanationStart = resultIndex + 1 }
        }
        let explanationLines: [String]
        if let start = explanationStart, start < markerIndex {
            explanationLines = lines[start..<markerIndex].filter { line in
                line != "共" && !line.contains("人答过") && !line.contains("平均正确率") &&
                    line.range(of: #"^\d+(?:\.\d+)?%?$"#, options: .regularExpression) == nil
            }
        } else {
            explanationLines = []
        }

        var rebuilt = [lines[markerIndex]] + questionBlock
        if let answerLine = extractedCopiedReferenceAnswer(from: lines, before: markerIndex) {
            rebuilt.append("参考答案：\(answerLine)")
        } else {
            rebuilt.append("参考答案：")
        }
        rebuilt.append("参考解析：")
        rebuilt.append(contentsOf: explanationLines)
        return rebuilt
    }

    private func extractedCopiedReferenceAnswer(from lines: [String], before end: Int) -> String? {
        guard let label = lines[..<end].lastIndex(where: { $0.contains("参考答案") }) else { return nil }
        let inline = lines[label].replacingOccurrences(
            of: #"^.*?参考答案\s*[:：]?\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if inline.range(of: #"^[A-F]+$"#, options: .regularExpression) != nil { return inline }
        let upperBound = min(end, label + 5)
        guard label + 1 < upperBound else { return nil }
        return lines[(label + 1)..<upperBound].first {
            $0.range(of: #"^[A-F]+$"#, options: .regularExpression) != nil
        }
    }

    private func extractEssayReferenceAnswer(
        lines: [String],
        answerIndex: Int,
        explanationIndex: Int?
    ) -> String {
        guard answerIndex < lines.count else { return "" }
        let end = explanationIndex ?? lines.count
        guard answerIndex < end else { return "" }
        var answerLines: [String] = []
        let first = lines[answerIndex].replacingOccurrences(
            of: #"^.*?参考答案\s*[:：]?\s*"#,
            with: "",
            options: .regularExpression
        )
        if !first.isEmpty { answerLines.append(first) }
        if answerIndex + 1 < end {
            for index in (answerIndex + 1)..<end {
                let line = lines[index]
                if isQuestionAreaStop(line) { break }
                answerLines.append(line)
            }
        }
        return answerLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?<=[\u4E00-\u9FFF，。；：！？、（）“”])\s+(?=[\u4E00-\u9FFF，。；：！？、（）“”])"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isInterfaceNoise(_ line: String, recognitionMode: RecognitionMode) -> Bool {
        let exactNoise: Set<String> = [
            "上一题", "下一题", "查看答案", "试题答疑", "做题笔记", "展开全部解析",
            "收起解析", "答题卡", "收藏", "纠错", "返回", "交卷", "正确", "错误", "确定"
        ]
        if exactNoise.contains(line) { return true }
        if line.range(of: #"^\d+$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^[iIl丨|｜-]$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^[iIl丨|｜]?(答|单|多|共)$"#, options: .regularExpression) != nil { return true }
        if line.contains("ICP备") || line.contains("扫码") { return true }
        guard recognitionMode == .fentiQuestionBank else { return false }
        let fentiExactNoise: Set<String> = [
            "首页", "题库", "首页 题库", "焚题库", "焚题库官网", "APP工具", "APP下载",
            "合作加盟", "医学综合", "切换", "章节练习", "模拟试卷"
        ]
        if fentiExactNoise.contains(line) { return true }
        let lowercase = line.lowercased()
        return lowercase.contains("tiku.hkwx8.com") || lowercase.contains("/burn_exam/") ||
            lowercase.contains("http://") || lowercase.contains("https://")
    }

    private func normalizeOption(_ line: String) -> String {
        let normalized = line.replacingOccurrences(of: "Ａ", with: "A")
            .replacingOccurrences(of: "Ｂ", with: "B")
            .replacingOccurrences(of: "Ｃ", with: "C")
            .replacingOccurrences(of: "Ｄ", with: "D")
            .replacingOccurrences(of: "Ｅ", with: "E")
            .replacingOccurrences(of: "Ｆ", with: "F")
            .replacingOccurrences(of: "ａ", with: "a")
            .replacingOccurrences(of: "ｂ", with: "b")
            .replacingOccurrences(of: "ｃ", with: "c")
            .replacingOccurrences(of: "ｄ", with: "d")
            .replacingOccurrences(of: "ｅ", with: "e")
            .replacingOccurrences(of: "ｆ", with: "f")
            .replacingOccurrences(of: #"^[<＜>＞•◎○〇●×✓☑☐□■▢口◉◯⑴-⒇①-⑳xX0Oo~|｜\s]*([A-Fa-f])\s*[、．:]?\s*"#, with: "$1. ", options: .regularExpression)
        guard let first = normalized.first else { return normalized }
        return first.uppercased() + normalized.dropFirst()
    }

    private func optionComponents(in line: String) -> (label: String, text: String)? {
        let normalized = line
            .replacingOccurrences(of: "Ａ", with: "A")
            .replacingOccurrences(of: "Ｂ", with: "B")
            .replacingOccurrences(of: "Ｃ", with: "C")
            .replacingOccurrences(of: "Ｄ", with: "D")
            .replacingOccurrences(of: "Ｅ", with: "E")
            .replacingOccurrences(of: "Ｆ", with: "F")
            .replacingOccurrences(of: "ａ", with: "a")
            .replacingOccurrences(of: "ｂ", with: "b")
            .replacingOccurrences(of: "ｃ", with: "c")
            .replacingOccurrences(of: "ｄ", with: "d")
            .replacingOccurrences(of: "ｅ", with: "e")
            .replacingOccurrences(of: "ｆ", with: "f")
        let pattern = #"^[<＜>＞•◎○〇●×✓☑☐□■▢口◉◯⑴-⒇①-⑳xX0Oo~|｜\s]*([A-Fa-f])\s*[\.、．:]?\s*(\S.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let labelRange = Range(match.range(at: 1), in: normalized),
              let textRange = Range(match.range(at: 2), in: normalized)
        else { return nil }
        let label = String(normalized[labelRange]).uppercased()
        let text = String(normalized[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (label, text)
    }

    private func optionLabelIndex(_ label: String) -> Int? {
        guard let scalar = label.uppercased().unicodeScalars.first else { return nil }
        let value = Int(scalar.value) - 65
        return (0..<6).contains(value) ? value : nil
    }

    private func cleanedOptionText(
        _ value: String,
        expectedLabel: String,
        recognitionMode: RecognitionMode
    ) -> String {
        guard recognitionMode == .fentiQuestionBank else { return value }
        var result = QuestionTextCleanup.removingRecoveredOptionPrefix(
            from: value,
            expectedLabel: expectedLabel
        )
            .replacingOccurrences(of: "減", with: "减")
            .replacingOccurrences(of: "黃", with: "黄")
            .replacingOccurrences(of: "淺", with: "浅")
        result = result.replacingOccurrences(
            of: #"(?<=[浅深])(?:\|I|｜I|lI|1I|I\||I｜)(?=\s*度)"#,
            with: "II",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^O(?=ml$)"#,
            with: "0",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(of: #"(?<=II)\s+(?=度)"#, with: "", options: .regularExpression)
        return normalizedFentiMedicalText(result)
    }

    private func normalizedFentiMedicalText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "Nat-K+", with: "Na+-K+")
            .replacingOccurrences(of: "Nat-K", with: "Na+-K")
            .replacingOccurrences(of: "Na*", with: "Na+")
            .replacingOccurrences(of: "K*", with: "K+")
            .replacingOccurrences(
                of: #"(?<=[浅深])(?:\|I|｜I|lI|1I|I\||I｜)(?=\s*度)"#,
                with: "II",
                options: .regularExpression
            )
    }

    private func unlabeledOptionCandidate(from line: String, expectedLabel: String) -> String? {
        let stripped = line.replacingOccurrences(
            of: #"^[•◎○〇●×✓☑☐□■▢口◉◯⑴-⒇①-⑳xX0Oo~|｜\s]+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let recovered = QuestionTextCleanup.removingRecoveredOptionPrefix(
            from: stripped,
            expectedLabel: expectedLabel
        )
        guard !recovered.isEmpty,
              recovered.range(of: #"^\d+$"#, options: .regularExpression) == nil,
              recovered.range(of: #"^[iIl丨|｜]?(答|单|多|共)$"#, options: .regularExpression) == nil,
              !isQuestionAreaStop(recovered)
        else { return nil }
        let meaningfulCount = recovered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        return meaningfulCount >= 2 ? recovered : nil
    }

    private func isSuspiciousFentiStem(_ question: String, hasQuestionMarker: Bool) -> Bool {
        if !hasQuestionMarker { return true }
        let lowercase = question.lowercased()
        if lowercase.contains("tiku.hkwx8.com") || lowercase.contains("/burn_exam/") ||
            lowercase.contains("http://") || lowercase.contains("https://") {
            return true
        }
        let meaningfulCount = question.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        guard meaningfulCount < 12 else { return false }
        let compact = question.replacingOccurrences(of: " ", with: "")
        let questionEndings = ["（）", "()", "？", "?", "有", "是", "为", "包括", "不包括"]
        return !questionEndings.contains(where: compact.contains)
    }

    private func isSuspiciousFentiOption(_ option: String) -> Bool {
        if option.contains("*") || option.contains("Nat") || option.contains("mmdl") { return true }
        return option.range(
            of: #"^[A-F]\.\s*[\]］】]|[匕乚]\s*[A-Fa-f]"#,
            options: .regularExpression
        ) != nil
    }

    private func isQuestionAreaStop(_ line: String) -> Bool {
        let stops = ["确定", "回答错误", "回答正确", "参考答案", "我的答案", "收藏本题", "查看解析", "收起解析"]
        if stops.contains(where: line.contains) { return true }
        return line == "错误" || line == "正确"
    }

    private func splitEmbeddedFirstOption(_ line: String) -> [String] {
        let pattern = #"\s+[•◎○●×✓①-⑳\s]*[AＡ]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line),
              line[..<range.lowerBound].contains("）") || line[..<range.lowerBound].contains(")")
        else { return [line] }
        let stem = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let optionText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return [stem, "A " + optionText]
    }

    private func extractAnswer(label: String, lines: [String]) -> String {
        for (index, line) in lines.enumerated() where line.contains(label) {
            let suffix = line.components(separatedBy: label).dropFirst().joined(separator: label)
            if let answer = firstAnswerLetter(in: suffix) { return answer }
            if index + 1 < lines.count, let answer = firstAnswerLetter(in: lines[index + 1]) {
                return answer
            }
        }
        return "待校对"
    }

    private func firstAnswerLetter(in value: String) -> String? {
        guard let range = value.range(of: #"(?<![A-Za-z])[A-FＡ-Ｆ](?:\s*[,、，]?\s*[A-FＡ-Ｆ])*"#,
                                      options: .regularExpression) else { return nil }
        return String(value[range])
            .uppercased()
            .replacingOccurrences(of: "Ａ", with: "A")
            .replacingOccurrences(of: "Ｂ", with: "B")
            .replacingOccurrences(of: "Ｃ", with: "C")
            .replacingOccurrences(of: "Ｄ", with: "D")
            .replacingOccurrences(of: "Ｅ", with: "E")
            .replacingOccurrences(of: "Ｆ", with: "F")
            .replacingOccurrences(of: #"[^A-F]"#, with: "", options: .regularExpression)
    }

    private func captureDate(for url: URL) -> Date {
        let pattern = #"(\d{8})_(\d{6})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: url.lastPathComponent,
                                        range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)),
           let dayRange = Range(match.range(at: 1), in: url.lastPathComponent),
           let timeRange = Range(match.range(at: 2), in: url.lastPathComponent) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMddHHmmss"
            if let date = formatter.date(from: String(url.lastPathComponent[dayRange]) + String(url.lastPathComponent[timeRange])) {
                return date
            }
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private func deduplicatedItems(_ items: [WrongQuestionItem]) -> DeduplicationResult {
        var primaryIDByKey: [String: String] = [:]
        var unique: [WrongQuestionItem] = []
        var episodeItems: [WrongQuestionItem] = []
        var consecutiveDuplicateItems: [WrongQuestionItem] = []
        var occurrenceCountsByID: [String: Int] = [:]
        var previousKey: String?
        var ignoredConsecutiveCount = 0
        for item in items {
            let key = duplicateKey(for: item)
            if let primaryID = primaryIDByKey[key] {
                if previousKey == key {
                    ignoredConsecutiveCount += 1
                    consecutiveDuplicateItems.append(item)
                } else {
                    occurrenceCountsByID[primaryID, default: 1] += 1
                    episodeItems.append(item)
                }
            } else {
                primaryIDByKey[key] = item.id
                occurrenceCountsByID[item.id] = 1
                unique.append(item)
                episodeItems.append(item)
            }
            previousKey = key
        }
        return DeduplicationResult(
            items: unique,
            episodeItems: episodeItems,
            consecutiveDuplicateItems: consecutiveDuplicateItems,
            occurrenceCountsByID: occurrenceCountsByID,
            duplicateCount: items.count - unique.count,
            ignoredConsecutiveCount: ignoredConsecutiveCount
        )
    }

    private func duplicateKey(for item: WrongQuestionItem) -> String {
        // 误操作以题干为准：浅色选项标签或 OCR 文字差异不应导致同题漏判。
        // 题干无法识别时不合并，避免把多个不同的 OCR 失败截图误判成同一道题。
        let subjectPrefix = (item.subject?.rawValue ?? "unclassified") + ":"
        if item.question.hasPrefix("[OCR") { return subjectPrefix + "unreadable:\(item.sourceHash)" }
        let scalars = item.question.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        let key = String(String.UnicodeScalarView(scalars))
        return subjectPrefix + (key.isEmpty ? "unreadable:\(item.sourceHash)" : key)
    }

    private func studySubject(for imageURL: URL) -> StudySubject? {
        let name = imageURL.lastPathComponent
        return StudySubject.allCases.first { name.contains("_\($0.displayName)_") }
    }

    private func reviewIssueLabels(for item: WrongQuestionItem) -> [String] {
        var labels: [String] = []
        let isEssay = isEssayItem(item)
        if item.subject == nil { labels.append("科目待分类") }
        if item.contentSubmission?.status == "failed", item.contentResult == nil {
            labels.append("接口分类失败")
        }
        if item.question.hasPrefix("[OCR") { labels.append("无题干") }
        let minimumOptions = isEssay ? 0 : (item.rawText.contains("判断题") ? 2 : 4)
        if item.options.count < minimumOptions { labels.append("选项不全") }
        if !isEssay, item.correctAnswer == "待校对" { labels.append("无答案") }
        if item.explanation.hasPrefix("待人工补充") { labels.append("无解析") }
        if labels.isEmpty && item.needsReview { labels.append("OCR待校对") }
        return labels
    }

    private func syncProblemImages(
        reviewItems: [WrongQuestionItem],
        consecutiveDuplicateItems: [WrongQuestionItem],
        under root: URL
    ) throws {
        let folder = root.appendingPathComponent("待人工校对图片", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var labelsByPath: [String: [String]] = [:]
        var itemByPath: [String: WrongQuestionItem] = [:]
        for item in consecutiveDuplicateItems {
            labelsByPath[item.sourcePath, default: []].append("重复截图")
            itemByPath[item.sourcePath] = item
        }
        for item in reviewItems {
            labelsByPath[item.sourcePath, default: []].append(contentsOf: reviewIssueLabels(for: item))
            itemByPath[item.sourcePath] = item
        }

        var desiredNames: Set<String> = []
        for path in labelsByPath.keys.sorted() {
            guard let item = itemByPath[path] else { continue }
            var labels: [String] = []
            for label in labelsByPath[path] ?? [] where !labels.contains(label) {
                labels.append(label)
            }
            let source = URL(fileURLWithPath: path)
            let filename = "\(labels.joined(separator: "_"))_\(item.id)_\(source.lastPathComponent)"
            desiredNames.insert(filename)
            let destination = folder.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destination.path) { continue }
            // 已完成批次的原图可能已进入校验过的压缩包；不要因此阻断后续整理。
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: destination)
        }

        let managedPattern = try NSRegularExpression(pattern: #"^.*WQ\d{4}_"#)
        for existing in try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let name = existing.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard managedPattern.firstMatch(in: name, range: range) != nil,
                  !desiredNames.contains(name)
            else { continue }
            try fileManager.removeItem(at: existing)
        }
    }

    private func createQuestionBook(
        rows: [QuestionWorkbookRow],
        subject: StudySubject,
        at output: URL
    ) throws {
        var body = coverHTML(
            title: "\(subject.displayName)题本",
            subtitle: "纯题版",
            itemCount: rows.count,
            note: "本册由题本工作簿生成，不含答案与解析，适合打印后独立练习。"
        )
        for (index, item) in rows.enumerated() {
            body += "<section class='question'>"
            body += "<h2>第 \(index + 1) 题 <span class='date'>\(html(item.curriculumChapter))</span></h2>"
            if item.wrongAttempts >= 2 {
                body += "<p class='repeat-badge'>累计答错 \(item.wrongAttempts) 次</p>"
            }
            body += "<p class='stem'>\(html(item.stem))</p>"
            if item.questionType == "论述题" {
                body += "<p class='answer-space'>作答：</p>"
                body += "<p class='answer-space'>____________________________________________________________</p>"
                body += "<p class='answer-space'>____________________________________________________________</p>"
                body += "<p class='answer-space'>____________________________________________________________</p>"
            } else if item.options.isEmpty {
                body += "<p class='review'>选项待补充。</p>"
            } else {
                body += "<ol class='options'>" + item.options.enumerated().map {
                    "<li>\(html(optionLabel($0.offset))). \(html($0.element))</li>"
                }.joined() + "</ol>"
            }
            if item.questionType != "论述题" {
                body += "<p class='answer-space'>作答：________________________</p>"
            }
            body += "</section>"
        }
        try convertHTMLToDocx(
            documentHTML(title: "\(subject.displayName)题本_纯题", body: body),
            output: output
        )
    }

    private func createAnswerBook(
        rows: [QuestionWorkbookRow],
        subject: StudySubject,
        at output: URL
    ) throws {
        var body = coverHTML(
            title: "\(subject.displayName)题本",
            subtitle: "答案与解析",
            itemCount: rows.count,
            note: "本册由题本工作簿生成，与纯题版题号一一对应。"
        )
        for (index, item) in rows.enumerated() {
            body += "<section class='question'>"
            body += "<h2>第 \(index + 1) 题 <span class='date'>\(html(item.curriculumChapter))</span></h2>"
            if item.wrongAttempts >= 2 {
                body += "<p class='repeat-badge'>累计答错 \(item.wrongAttempts) 次</p>"
            }
            body += "<p class='stem'>\(html(item.stem))</p>"
            if item.questionType == "论述题" {
                body += "<div class='answer'><b>评分方式：</b>按原解析标注的考点和分值评分</div>"
            } else {
                body += "<div class='answer'><b>参考答案：</b>\(html(item.correctAnswer.isEmpty ? "待补充" : item.correctAnswer))</div>"
            }
            body += "<h3>参考解析</h3><p>\(html(item.explanation.isEmpty ? "待补充" : item.explanation))</p>"
            body += "</section>"
        }
        try convertHTMLToDocx(
            documentHTML(title: "\(subject.displayName)题本_答案与解析", body: body),
            output: output
        )
    }

    private func createStudyKnowledgeBook(items: [WrongQuestionItem], at output: URL) throws {
        struct Card {
            let section: String
            let chapter: String
            let value: StudyKnowledgeCard
        }
        var seen: Set<String> = []
        var cards: [Card] = []
        for item in items {
            guard let result = item.contentResult else { continue }
            for card in result.knowledgeCards {
                let key = normalizedKnowledgeKey(card.title + "|" + card.memoryText)
                guard seen.insert(key).inserted else { continue }
                cards.append(Card(section: result.medicalCategory.section, chapter: result.medicalCategory.chapter, value: card))
            }
        }

        var body = "<section class='study-opening'><div class='kicker'>成人高考专升本 · 医学综合</div><h1>医学综合知识点背诵汇总</h1></section>"
        for section in MedicalCurriculumTaxonomy.sections {
            let sectionCards = cards.filter { $0.section == section.name }
            guard !sectionCards.isEmpty else { continue }
            body += "<section class='study-section'><h2>\(html(section.name))</h2>"
            for chapter in section.chapters {
                let chapterCards = sectionCards.filter { $0.chapter == chapter }
                guard !chapterCards.isEmpty else { continue }
                body += "<h3 class='study-chapter'>\(html(chapter))</h3>"
                for card in chapterCards {
                    body += "<article class='memory-card'><h4>\(html(card.value.title))</h4>"
                    body += "<p class='memory-text'>\(html(card.value.memoryText))</p>"
                    if !card.value.pitfalls.isEmpty {
                        body += "<div class='pitfalls'><b>易错辨析</b><ul>" + card.value.pitfalls.map { "<li>\(html($0))</li>" }.joined() + "</ul></div>"
                    }
                    body += "</article>"
                }
            }
            body += "</section>"
        }
        try convertHTMLToDocx(documentHTML(title: "医学综合知识点背诵汇总", body: body), output: output)
    }

    private func optionLabel(_ index: Int) -> String {
        guard (0..<26).contains(index), let scalar = UnicodeScalar(65 + index) else { return "?" }
        return String(Character(scalar))
    }

    private func normalizedKnowledgeKey(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func coverHTML(title: String, subtitle: String, itemCount: Int, itemUnit: String = "题", note: String) -> String {
        """
        <section class='cover'>
          <div class='kicker'>成人高考专升本 · 医学综合</div>
          <h1>\(html(title))</h1>
          <div class='subtitle'>\(html(subtitle))</div>
          <div class='rule'></div>
          <p>当前收录：<b>\(itemCount)</b> \(html(itemUnit))</p>
          <p>生成时间：\(html(fullDate(Date())))</p>
          <div class='cover-note'>\(html(note))</div>
        </section>
        <div class='page-break'></div>
        """
    }

    private func documentHTML(title: String, body: String) -> String {
        """
        <!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><title>\(html(title))</title>
        <style>
          @page { size: Letter portrait; margin: 1in; }
          body { font-family: 'Arial Unicode MS', 'PingFang SC', 'Songti SC', sans-serif; font-size: 11pt; line-height: 1.25; color: #222; margin: 0; }
          .cover { min-height: 8.2in; padding-top: 1.25in; }
          .kicker { color: #2E74B5; font-size: 11pt; letter-spacing: 1px; margin-bottom: 18pt; }
          h1 { color: #2E74B5; font-size: 24pt; margin: 0 0 10pt; }
          .subtitle { color: #1F4D78; font-size: 16pt; margin-bottom: 18pt; }
          .rule { height: 3px; background: #2E74B5; width: 1.6in; margin: 18pt 0 24pt; }
          .cover-note { margin-top: 30pt; padding: 12pt; background: #E8EEF5; border-left: 4px solid #2E74B5; }
          .page-break { page-break-after: always; }
          .question { page-break-inside: avoid; border-bottom: 1px solid #D9E1E8; padding: 0 0 10pt; margin: 0 0 12pt; }
          h2 { color: #2E74B5; font-size: 16pt; margin: 18pt 0 10pt; }
          h3 { color: #1F4D78; font-size: 12pt; margin: 10pt 0 5pt; }
          p { margin: 0 0 6pt; }
          .date { float: right; color: #777; font-size: 9pt; font-weight: normal; }
          .stem { font-weight: 600; }
          .options { list-style: none; margin: 4pt 0 8pt 0; padding: 0; }
          .options li { margin: 2pt 0; }
          .answer-space { color: #666; margin-top: 8pt; }
          .answer { background: #E8EEF5; padding: 7pt 9pt; margin: 6pt 0; }
          .repeat { color: #C00000; }
          .repeat-badge { color: #C00000; font-weight: 700; margin: -4pt 0 7pt; }
          .review { color: #C00000; font-weight: 600; }
          .source { color: #777; font-size: 8pt; margin-top: 7pt; }
          .study-opening { padding: 8pt 0 18pt; border-bottom: 3px solid #2E74B5; margin-bottom: 18pt; }
          .study-opening h1 { font-size: 22pt; }
          .study-section { margin-bottom: 20pt; }
          .study-chapter { margin: 14pt 0 7pt; padding-bottom: 3pt; border-bottom: 1px solid #B4C7DC; }
          .memory-card { page-break-inside: avoid; margin: 0 0 10pt; padding: 8pt 10pt; background: #F5F8FB; border-left: 3px solid #2E74B5; }
          .memory-card h4 { color: #1F4D78; font-size: 11.5pt; margin: 0 0 4pt; }
          .memory-text { margin: 0; }
          .pitfalls { color: #8B1A1A; margin-top: 5pt; }
          .pitfalls ul { margin: 3pt 0 0 18pt; padding: 0; }
          .pitfalls li { margin: 2pt 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    private func convertHTMLToDocx(_ source: String, output: URL) throws {
        let temporaryHTML = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).html")
        let temporaryDocx = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).docx")
        let correctedDocx = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-cjk.docx")
        defer {
            try? fileManager.removeItem(at: temporaryHTML)
            try? fileManager.removeItem(at: temporaryDocx)
            try? fileManager.removeItem(at: correctedDocx)
        }
        try Data(source.utf8).write(to: temporaryHTML, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", "-format", "html", "-output", temporaryDocx.path, temporaryHTML.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fileManager.fileExists(atPath: temporaryDocx.path) else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "WrongQuestionOrganizer", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "生成 Word 文档失败：\(message)"])
        }
        try addEastAsianFontMetadata(to: temporaryDocx, output: correctedDocx)
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        try fileManager.moveItem(at: correctedDocx, to: output)
    }

    private func addEastAsianFontMetadata(to source: URL, output: URL) throws {
        let working = source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-docx", isDirectory: true)
        try fileManager.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: working) }

        try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-q", source.path, "-d", working.path]
        )
        let documentXML = working.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: documentXML, encoding: .utf8)
        xml = xml.replacingOccurrences(
            of: "<w:rFonts ",
            with: "<w:rFonts w:eastAsia=\"Noto Sans CJK SC\" "
        )
        // textutil 会给每个字符运行写入 0 间距；LibreOffice 对 CJK 的兼容实现会把它误判为零字宽。
        xml = xml.replacingOccurrences(of: "<w:spacing w:val=\"0\"/>", with: "")
        try Data(xml.utf8).write(to: documentXML, options: .atomic)
        try installEmbeddedCJKFont(into: working)
        try runProcess(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-r", output.path, "."],
            currentDirectory: working
        )
    }

    private func installEmbeddedCJKFont(into working: URL) throws {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("DocxFonts", isDirectory: true),
              fileManager.fileExists(atPath: resources.appendingPathComponent("font1.odttf").path)
        else {
            throw NSError(domain: "WrongQuestionOrganizer", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "应用缺少 Word 中文字体资源，请重新安装完整应用。"])
        }

        let fontsFolder = working.appendingPathComponent("word/fonts", isDirectory: true)
        let relationshipsFolder = working.appendingPathComponent("word/_rels", isDirectory: true)
        try fileManager.createDirectory(at: fontsFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relationshipsFolder, withIntermediateDirectories: true)
        try fileManager.copyItem(at: resources.appendingPathComponent("font1.odttf"),
                                 to: fontsFolder.appendingPathComponent("font1.odttf"))
        try fileManager.copyItem(at: resources.appendingPathComponent("font2.odttf"),
                                 to: fontsFolder.appendingPathComponent("font2.odttf"))
        try fileManager.copyItem(at: resources.appendingPathComponent("fontTable.xml"),
                                 to: working.appendingPathComponent("word/fontTable.xml"))
        try fileManager.copyItem(at: resources.appendingPathComponent("fontTable.xml.rels"),
                                 to: relationshipsFolder.appendingPathComponent("fontTable.xml.rels"))

        let contentTypesURL = working.appendingPathComponent("[Content_Types].xml")
        var contentTypes = try String(contentsOf: contentTypesURL, encoding: .utf8)
        let declarations = """
        <Default Extension="odttf" ContentType="application/vnd.openxmlformats-officedocument.obfuscatedFont"/>
        <Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/>
        """
        contentTypes = contentTypes.replacingOccurrences(of: "</Types>", with: declarations + "</Types>")
        try Data(contentTypes.utf8).write(to: contentTypesURL, options: .atomic)

        let documentRelationshipsURL = relationshipsFolder.appendingPathComponent("document.xml.rels")
        var relationships = try String(contentsOf: documentRelationshipsURL, encoding: .utf8)
        let fontRelationship = "<Relationship Id=\"rIdDocxFontTable\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable\" Target=\"fontTable.xml\"/>"
        relationships = relationships.replacingOccurrences(
            of: "</Relationships>",
            with: fontRelationship + "</Relationships>"
        )
        try Data(relationships.utf8).write(to: documentRelationshipsURL, options: .atomic)
    }

    private func runProcess(executable: String, arguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "WrongQuestionOrganizer", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "修正 Word 中文字体失败：\(message)"])
        }
    }

    private func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func relativeSourcePath(_ path: String) -> String {
        let marker = "/错题截图/"
        if let range = path.range(of: marker) { return String(path[range.upperBound...]) }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
