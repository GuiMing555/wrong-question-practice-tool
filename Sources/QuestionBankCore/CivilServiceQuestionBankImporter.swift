import Foundation

public struct CivilServiceQuestionBankImportReport: Equatable, Sendable {
    public let category: XingceCategory
    public let total: Int
    public let inserted: Int
    public let updated: Int
    public let unchanged: Int
}

public enum CivilServiceQuestionBankImportError: LocalizedError, Equatable {
    case packageMissing
    case invalidRecord(line: Int, reason: String)
    case countMismatch(category: String, expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .packageMissing:
            return "应用内未找到行测题库数据包，请重新安装完整版本。"
        case .invalidRecord(let line, let reason):
            return "行测题库第 \(line) 行无法导入：\(reason)"
        case .countMismatch(let category, let expected, let actual):
            return "\(category)题量校验失败：应为 \(expected) 题，实际读取 \(actual) 题。"
        }
    }
}

public enum CivilServiceQuestionBankImporter {
    public static let sourceIdentifier = "manual-entry:xingce-v1"

    public static func isBundledPackageAvailable(bundle: Bundle = .main) -> Bool {
        (try? bundledPackageURL(bundle: bundle)) != nil
    }

    public static func bundledPackageURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.resourceURL?
            .appendingPathComponent("CivilServiceQuestionBank", isDirectory: true)
            .appendingPathComponent("questions.jsonl", isDirectory: false),
              FileManager.default.fileExists(atPath: url.path)
        else { throw CivilServiceQuestionBankImportError.packageMissing }
        return url
    }

    @discardableResult
    public static func installIfNeeded(
        category: XingceCategory,
        packageURL: URL? = nil,
        databaseURL: URL? = nil
    ) throws -> CivilServiceQuestionBankImportReport {
        let targetURL = try databaseURL ?? QuestionBankPaths.civilServiceDatabaseURL(for: category)
        let store = try QuestionBankStore(
            databaseURL: targetURL,
            sourceApplication: "civil-service-import:\(category.rawValue)"
        )
        let existing = try store.questionCount(source: sourceIdentifier)
        if existing == category.bundledQuestionCount {
            return CivilServiceQuestionBankImportReport(
                category: category,
                total: existing,
                inserted: 0,
                updated: 0,
                unchanged: existing
            )
        }

        let sourceURL = try packageURL ?? bundledPackageURL()
        let records = try records(in: sourceURL, category: category)
        guard records.count == category.bundledQuestionCount else {
            throw CivilServiceQuestionBankImportError.countMismatch(
                category: category.displayName,
                expected: category.bundledQuestionCount,
                actual: records.count
            )
        }
        let results = try store.upsertQuestions(records.map(\.draft))
        return CivilServiceQuestionBankImportReport(
            category: category,
            total: results.count,
            inserted: results.filter { $0.status == .inserted }.count,
            updated: results.filter { $0.status == .updated }.count,
            unchanged: results.filter { $0.status == .unchanged }.count
        )
    }

    private static func records(in url: URL, category: XingceCategory) throws -> [BundledQuestion] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var output: [BundledQuestion] = []
        for (offset, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                let record = try decoder.decode(BundledQuestion.self, from: Data(line.utf8))
                if record.category == category.sourceCategoryName {
                    output.append(record)
                }
            } catch {
                throw CivilServiceQuestionBankImportError.invalidRecord(
                    line: offset + 1,
                    reason: error.localizedDescription
                )
            }
        }
        return output
    }
}

private struct BundledOption: Decodable {
    let label: String
    let text: String
}

private struct BundledQuestion: Decodable {
    let stableID: String
    let category: String
    let subcategory: String
    let stem: String
    let options: [BundledOption]
    let correctLabels: [String]
    let explanation: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case stableID = "stable_id"
        case category, subcategory, stem, options
        case correctLabels = "correct_labels"
        case explanation, source
    }

    var draft: QuestionDraft {
        let correct = Set(correctLabels)
        return QuestionDraft(
            stableExternalID: stableID,
            stem: stem,
            type: correct.count > 1 ? .multipleChoice : .singleChoice,
            options: options.map {
                OptionDraft(originalLabel: $0.label, text: $0.text, isCorrect: correct.contains($0.label))
            },
            explanation: explanation,
            source: source,
            curriculumSection: category,
            curriculumChapter: subcategory
        )
    }
}
