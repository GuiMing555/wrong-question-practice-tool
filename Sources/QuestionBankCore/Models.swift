import CryptoKit
import Foundation

public enum StudySubject: String, CaseIterable, Codable, Hashable, Sendable {
    case medicalComprehensive = "medical_comprehensive"
    case politics
    case english

    public var displayName: String {
        switch self {
        case .medicalComprehensive: return "医学综合"
        case .politics: return "政治"
        case .english: return "英语"
        }
    }

    public var workbookFilename: String { "\(displayName)题本.xlsx" }
    public var questionDocumentFilename: String { "\(displayName)题本_纯题.docx" }
    public var answerDocumentFilename: String { "\(displayName)题本_答案与解析.docx" }
}

public enum XingceCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case politicsAndCommonSense = "politics_and_common_sense"
    case verbalUnderstanding = "verbal_understanding"
    case quantitativeRelations = "quantitative_relations"
    case judgmentReasoning = "judgment_reasoning"
    case dataAnalysis = "data_analysis"

    public var displayName: String {
        switch self {
        case .politicsAndCommonSense: return "政治理论与常识判断"
        case .verbalUnderstanding: return "言语理解与表达"
        case .quantitativeRelations: return "数量关系"
        case .judgmentReasoning: return "判断推理"
        case .dataAnalysis: return "资料分析"
        }
    }

    public var sourceCategoryName: String {
        self == .politicsAndCommonSense ? "政治理论与常识判断（公基）" : displayName
    }

    public var bundledQuestionCount: Int {
        switch self {
        case .politicsAndCommonSense: return 1_002
        case .verbalUnderstanding: return 1_005
        case .quantitativeRelations: return 880
        case .judgmentReasoning: return 706
        case .dataAnalysis: return 3
        }
    }
}

public enum PracticeMode: String, Codable, Sendable {
    case normal
    case wrongBook = "wrong_book"
}

public enum QuestionType: String, Codable, Sendable {
    case singleChoice = "single_choice"
    case multipleChoice = "multiple_choice"
    case essay
}

public struct OptionDraft: Equatable, Sendable {
    public var id: String?
    public var originalLabel: String?
    public var text: String
    public var isCorrect: Bool

    public init(id: String? = nil, originalLabel: String? = nil, text: String, isCorrect: Bool) {
        self.id = id
        self.originalLabel = originalLabel
        self.text = text
        self.isCorrect = isCorrect
    }
}

public struct QuestionDraft: Equatable, Sendable {
    public var id: String?
    public var stableExternalID: String
    public var stem: String
    public var type: QuestionType
    public var options: [OptionDraft]
    public var explanation: String
    public var knowledgePoints: [String]
    public var source: String?
    public var sourceImagePath: String?
    public var sourceImageHash: String?
    public var capturedAt: Date?
    public var curriculumSection: String?
    public var curriculumChapter: String?
    public var contentAnalysisJSON: String?

    public init(
        id: String? = nil,
        stableExternalID: String,
        stem: String,
        type: QuestionType,
        options: [OptionDraft],
        explanation: String = "",
        knowledgePoints: [String] = [],
        source: String? = nil,
        sourceImagePath: String? = nil,
        sourceImageHash: String? = nil,
        capturedAt: Date? = nil,
        curriculumSection: String? = nil,
        curriculumChapter: String? = nil,
        contentAnalysisJSON: String? = nil
    ) {
        self.id = id
        self.stableExternalID = stableExternalID
        self.stem = stem
        self.type = type
        self.options = options
        self.explanation = explanation
        self.knowledgePoints = knowledgePoints
        self.source = source
        self.sourceImagePath = sourceImagePath
        self.sourceImageHash = sourceImageHash
        self.capturedAt = capturedAt
        self.curriculumSection = curriculumSection
        self.curriculumChapter = curriculumChapter
        self.contentAnalysisJSON = contentAnalysisJSON
    }
}

public struct CapturedQuestionOption: Equatable, Sendable {
    public var originalLabel: String
    public var text: String

    public init(originalLabel: String, text: String) {
        self.originalLabel = originalLabel
        self.text = text
    }
}

public struct CapturedQuestionDraft: Equatable, Sendable {
    public var stableExternalID: String
    public var stem: String
    public var options: [CapturedQuestionOption]
    public var correctLabels: Set<String>
    public var type: QuestionType?
    public var explanation: String
    public var knowledgePoints: [String]
    public var sourceImagePath: String
    public var sourceImageHash: String
    public var capturedAt: Date
    public var source: String
    public var curriculumSection: String?
    public var curriculumChapter: String?
    public var contentAnalysisJSON: String?

    public init(
        stableExternalID: String,
        stem: String,
        options: [CapturedQuestionOption],
        correctLabels: Set<String>,
        type: QuestionType? = nil,
        explanation: String = "",
        knowledgePoints: [String] = [],
        sourceImagePath: String,
        sourceImageHash: String,
        capturedAt: Date,
        source: String = "capture",
        curriculumSection: String? = nil,
        curriculumChapter: String? = nil,
        contentAnalysisJSON: String? = nil
    ) {
        self.stableExternalID = stableExternalID
        self.stem = stem
        self.options = options
        self.correctLabels = Set(correctLabels.map(Self.normalizeLabel))
        self.type = type
        self.explanation = explanation
        self.knowledgePoints = knowledgePoints
        self.sourceImagePath = sourceImagePath
        self.sourceImageHash = sourceImageHash
        self.capturedAt = capturedAt
        self.source = source
        self.curriculumSection = curriculumSection
        self.curriculumChapter = curriculumChapter
        self.contentAnalysisJSON = contentAnalysisJSON
    }

    public static func labels(from answer: String) -> Set<String> {
        let upper = answer.uppercased()
        let letters = upper.unicodeScalars.compactMap { scalar -> String? in
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            return String(Character(scalar))
        }
        return Set(letters)
    }

    private static func normalizeLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".、:：()（）[]【】"))
            .uppercased()
    }
}

public enum CapturedQuestionIdentity {
    public static func stableExternalID(for question: String) -> String {
        let scalars = question.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        let normalized = String(String.UnicodeScalarView(scalars))
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "capture:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum QuestionImportStatus: String, Codable, Sendable {
    case inserted
    case updated
    case unchanged
}

public struct QuestionImportResult: Equatable, Sendable {
    public let questionID: String
    public let status: QuestionImportStatus
    public let addedToWrongBook: Bool

    public init(questionID: String, status: QuestionImportStatus, addedToWrongBook: Bool) {
        self.questionID = questionID
        self.status = status
        self.addedToWrongBook = addedToWrongBook
    }
}

public struct StoredQuestionAnalysis: Equatable, Sendable {
    public let questionID: String
    public let inputHash: String
    public let result: QuestionContentResult
    public let receivedAt: Date

    public init(questionID: String, inputHash: String, result: QuestionContentResult, receivedAt: Date) {
        self.questionID = questionID
        self.inputHash = inputHash
        self.result = result
        self.receivedAt = receivedAt
    }
}

public struct SettingsSnapshot: Equatable, Sendable {
    public var normalReviewIntervalDays: Int
    public var wrongRequiredConsecutiveCorrect: Int
    public var questionsPerSession: Int?
    public var dynamicPlanEnabled: Bool
    public var dynamicPlanTargetDate: Date?

    public init(
        normalReviewIntervalDays: Int = 7,
        wrongRequiredConsecutiveCorrect: Int = 3,
        questionsPerSession: Int? = nil,
        dynamicPlanEnabled: Bool = false,
        dynamicPlanTargetDate: Date? = nil
    ) {
        self.normalReviewIntervalDays = normalReviewIntervalDays
        self.wrongRequiredConsecutiveCorrect = wrongRequiredConsecutiveCorrect
        self.questionsPerSession = questionsPerSession
        self.dynamicPlanEnabled = dynamicPlanEnabled
        self.dynamicPlanTargetDate = dynamicPlanTargetDate
    }
}

public struct PracticeOption: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let originalLabel: String?
}

public struct PracticeQuestion: Codable, Equatable, Sendable {
    public let itemID: String
    public let questionID: String
    public let stem: String
    public let type: QuestionType
    public let options: [PracticeOption]
    public let explanation: String
    public let wrongProgress: Int
    public let wrongRequired: Int
    public let isInWrongBook: Bool?

    public var allowsMultipleSelection: Bool { type == .multipleChoice }
    public var requiresTypedAnswer: Bool { type == .essay }
}

public struct PracticeSessionSummary: Codable, Equatable, Sendable {
    public let id: String
    public let mode: PracticeMode
    public let currentIndex: Int
    public let totalCount: Int
    public let answeredCount: Int
    public let isComplete: Bool
    public let planDateKey: String?

    public var isDynamicPlan: Bool { planDateKey != nil }
}

public struct PracticeSessionSnapshot: Codable, Equatable, Sendable {
    public let summary: PracticeSessionSummary
    public let currentItem: PracticeQuestion?

    public var id: String { summary.id }
    public var mode: PracticeMode { summary.mode }
    public var currentIndex: Int { summary.currentIndex }
    public var totalCount: Int { summary.totalCount }
    public var answeredCount: Int { summary.answeredCount }
    public var isComplete: Bool { summary.isComplete }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public let totalQuestions: Int
    public let unseenCount: Int
    public let dueNormalCount: Int
    public let wrongBookCount: Int
    public let answeredTodayCount: Int
    public let activeSession: PracticeSessionSummary?
    public let dynamicPlan: DynamicStudyPlanSnapshot

    public var wrongBookSessionQuestionCount: Int {
        WrongBookSessionPolicy.expandedQuestionCount(uniqueQuestionCount: wrongBookCount)
    }
}

public struct DynamicStudyPlanSnapshot: Equatable, Sendable {
    public let isEnabled: Bool
    public let targetDate: Date?
    public let daysRemaining: Int
    public let isOverdue: Bool
    public let unseenRemaining: Int
    public let wrongMasteryRemaining: Int
    public let todayFirstPassTarget: Int
    public let todayFirstPassCompleted: Int
    public let todayWrongTarget: Int
    public let todayWrongCompleted: Int

    public var firstPassRemainingToday: Int {
        max(0, todayFirstPassTarget - todayFirstPassCompleted)
    }

    public var wrongRemainingToday: Int {
        max(0, todayWrongTarget - todayWrongCompleted)
    }

    public var totalRemainingToday: Int {
        firstPassRemainingToday + wrongRemainingToday
    }

    public var totalTargetToday: Int {
        todayFirstPassTarget + todayWrongTarget
    }

    public var totalCompletedToday: Int {
        min(todayFirstPassCompleted, todayFirstPassTarget)
            + min(todayWrongCompleted, todayWrongTarget)
    }

    public var isFullyMastered: Bool {
        unseenRemaining == 0 && wrongMasteryRemaining == 0
    }
}

public struct ChangeLogEntry: Equatable, Sendable {
    public let sequence: Int64
    public let sourceApplication: String
    public let entityType: String
    public let entityID: String
    public let action: String
    public let payloadJSON: String?
    public let createdAt: Date
}

public struct SubmitAnswerRequest: Equatable, Sendable {
    public let sessionID: String
    public let itemID: String
    public let selectedOptionIDs: Set<String>
    public let typedAnswer: String?
    public let essayEvaluation: EssayGradingResult?
    public let submissionToken: String
    public let markAsUnsure: Bool
    public let submittedAt: Date

    public init(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        typedAnswer: String? = nil,
        essayEvaluation: EssayGradingResult? = nil,
        submissionToken: String = UUID().uuidString,
        markAsUnsure: Bool = false,
        submittedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.selectedOptionIDs = selectedOptionIDs
        self.typedAnswer = typedAnswer
        self.essayEvaluation = essayEvaluation
        self.submissionToken = submissionToken
        self.markAsUnsure = markAsUnsure
        self.submittedAt = submittedAt
    }
}

public struct SubmissionResult: Codable, Equatable, Sendable {
    public let attemptID: String
    public let isCorrect: Bool
    public let correctOptionIDs: Set<String>
    public let selectedOptionIDs: Set<String>
    public let typedAnswer: String?
    public let essayEvaluation: EssayGradingResult?
    public let explanation: String
    public let markedAsUnsure: Bool
    public let isInWrongBook: Bool
    public let wrongProgressBefore: Int
    public let wrongProgressAfter: Int
    public let removedFromWrongBook: Bool
    public let session: PracticeSessionSnapshot
}

public enum QuestionBankError: Error, Equatable, LocalizedError {
    case invalidQuestion(String)
    case invalidSettings(String)
    case noEligibleQuestions(PracticeMode)
    case wrongModeLocked(unseenCount: Int, wrongCount: Int)
    case dynamicPlanNotConfigured
    case dynamicPlanRequiresThreeCorrect
    case noDynamicPlanTasksToday
    case sessionNotFound
    case sessionCompleted
    case sessionItemNotFound
    case itemAlreadyAnswered
    case itemIsNotCurrent
    case invalidSelection
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .invalidQuestion(let message), .invalidSettings(let message), .database(let message): return message
        case .noEligibleQuestions(.wrongBook): return "错题本为空"
        case .noEligibleQuestions(.normal): return "当前没有待练习的题目"
        case .wrongModeLocked(let unseenCount, let wrongCount):
            return "还有 \(unseenCount) 道普通题未完成，当前错题 \(wrongCount) 道；累计至少 5 道错题后可开启错题模式"
        case .dynamicPlanNotConfigured: return "请先在设置中启用动态计划并选择目标结束日期"
        case .dynamicPlanRequiresThreeCorrect: return "动态计划要求错题连续答对 3 次后移出，请先保存对应设置"
        case .noDynamicPlanTasksToday: return "今天的动态计划已经完成"
        case .sessionNotFound: return "练习记录不存在"
        case .sessionCompleted: return "本轮练习已完成"
        case .sessionItemNotFound: return "本轮中不存在该题"
        case .itemAlreadyAnswered: return "该题已提交"
        case .itemIsNotCurrent: return "只能提交当前题"
        case .invalidSelection: return "所选选项不属于当前题"
        }
    }
}

public enum QuestionBankPaths {
    public static let databaseChangedNotification = Notification.Name("com.guiming.medicalquestionbank.databaseChanged")
    public static let workbookFilename = StudySubject.medicalComprehensive.workbookFilename

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        try defaultDatabaseURL(for: .medicalComprehensive, fileManager: fileManager)
    }

    public static func defaultDatabaseURL(
        for subject: StudySubject,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory: URL
        switch subject {
        case .medicalComprehensive:
            // 保留旧位置，现有医学题本和作答记录无需搬迁。
            directory = base.appendingPathComponent("医学综合练习", isDirectory: true)
        case .politics, .english:
            directory = base
                .appendingPathComponent("考试题本练习", isDirectory: true)
                .appendingPathComponent(subject.displayName, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent("question-bank.sqlite3", isDirectory: false)
    }

    public static func defaultWorkbookURL(fileManager: FileManager = .default) throws -> URL {
        try defaultWorkbookURL(for: .medicalComprehensive, fileManager: fileManager)
    }

    public static func defaultWorkbookURL(
        for subject: StudySubject,
        fileManager: FileManager = .default
    ) throws -> URL {
        try defaultDatabaseURL(for: subject, fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(subject.workbookFilename, isDirectory: false)
    }

    public static func civilServiceDatabaseURL(
        for category: XingceCategory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("考试题本练习", isDirectory: true)
            .appendingPathComponent("公务员考试", isDirectory: true)
            .appendingPathComponent("行测", isDirectory: true)
            .appendingPathComponent(category.displayName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("question-bank.sqlite3", isDirectory: false)
    }
}

public struct QuestionWorkbookRow: Equatable, Sendable {
    public let questionID: String
    public let externalID: String
    public let curriculumSection: String
    public let curriculumChapter: String
    public let questionType: String
    public let stem: String
    public let options: [String]
    public let correctAnswer: String
    public let explanation: String
    public let knowledgePoints: [String]
    public let memoryTexts: [String]
    public let pitfalls: [String]
    public let isInWrongBook: Bool
    public let wrongAttempts: Int
    public let totalAttempts: Int
    public let consecutiveCorrect: Int
    public let lastAnsweredAt: Date?
    public let sourceImagePath: String
    public let updatedAt: Date

    public init(
        questionID: String,
        externalID: String,
        curriculumSection: String,
        curriculumChapter: String,
        questionType: String,
        stem: String,
        options: [String],
        correctAnswer: String,
        explanation: String,
        knowledgePoints: [String],
        memoryTexts: [String],
        pitfalls: [String],
        isInWrongBook: Bool,
        wrongAttempts: Int,
        totalAttempts: Int,
        consecutiveCorrect: Int,
        lastAnsweredAt: Date?,
        sourceImagePath: String,
        updatedAt: Date
    ) {
        self.questionID = questionID
        self.externalID = externalID
        self.curriculumSection = curriculumSection
        self.curriculumChapter = curriculumChapter
        self.questionType = questionType
        self.stem = stem
        self.options = options
        self.correctAnswer = correctAnswer
        self.explanation = explanation
        self.knowledgePoints = knowledgePoints
        self.memoryTexts = memoryTexts
        self.pitfalls = pitfalls
        self.isInWrongBook = isInWrongBook
        self.wrongAttempts = wrongAttempts
        self.totalAttempts = totalAttempts
        self.consecutiveCorrect = consecutiveCorrect
        self.lastAnsweredAt = lastAnsweredAt
        self.sourceImagePath = sourceImagePath
        self.updatedAt = updatedAt
    }
}
