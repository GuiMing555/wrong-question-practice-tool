import Foundation
import QuestionBankCore

enum PracticeScope: Hashable, Sendable {
    case education(StudySubject)
    case xingce(XingceCategory)

    var displayName: String {
        switch self {
        case .education(let subject): return subject.displayName
        case .xingce(let category): return category.displayName
        }
    }

    var supportsDynamicPlan: Bool {
        if case .education = self { return true }
        return false
    }
}

enum PracticeMode: String, Codable, Sendable {
    case normal
    case wrongBook
    case dynamicPlan

    var title: String {
        switch self {
        case .normal: return "普通模式"
        case .wrongBook: return "错题模式"
        case .dynamicPlan: return "动态计划"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "rectangle.stack.badge.play"
        case .wrongBook: return "exclamationmark.arrow.triangle.2.circlepath"
        case .dynamicPlan: return "calendar.badge.clock"
        }
    }
}

struct PracticeSettings: Equatable, Sendable {
    var normalReviewIntervalDays: Int = 7
    var wrongRequiredConsecutiveCorrect: Int = 3
    /// `nil` means that every currently eligible question is included.
    var questionsPerSession: Int? = nil
    var dynamicPlanEnabled = false
    var dynamicPlanTargetDate: Date?
}

enum PracticeInteractionPreferences {
    static let swipeThresholdKey = "practicePageSwipeThreshold"
    static let defaultSwipeThreshold = 110.0
}

struct DashboardSummary: Equatable, Sendable {
    var totalQuestions: Int
    var unseenQuestions: Int
    var dueQuestions: Int
    var wrongBookQuestions: Int
    var wrongBookSessionQuestions: Int
    var answeredToday: Int
    var dynamicPlan: DailyPlanSummary

    static let empty = DashboardSummary(
        totalQuestions: 0,
        unseenQuestions: 0,
        dueQuestions: 0,
        wrongBookQuestions: 0,
        wrongBookSessionQuestions: 0,
        answeredToday: 0,
        dynamicPlan: .disabled
    )
}

struct DailyPlanSummary: Equatable, Sendable {
    var isSupported: Bool
    var isEnabled: Bool
    var targetDate: Date?
    var daysRemaining: Int
    var isOverdue: Bool
    var unseenRemaining: Int
    var currentWrongQuestions: Int
    var todayFirstPassTarget: Int
    var todayFirstPassCompleted: Int
    var todayReviewTarget: Int
    var todayReviewsCompleted: Int
    var todayCorrectionQuestionTarget: Int
    var todayCorrectionQuestionsCompleted: Int
    var todayCorrectionAttemptsRemaining: Int
    var combinedFirstPassTarget: Int
    var combinedFirstPassCompleted: Int
    var combinedReviewTarget: Int
    var combinedReviewsCompleted: Int
    var combinedCorrectionTarget: Int
    var combinedCorrectionsCompleted: Int
    var estimatedWrongProbability: Double
    var estimatedFutureWrongQuestions: Int
    var reservedCorrectionDays: Int
    var effectiveFirstPassDays: Int
    var isScheduleOverloaded: Bool

    static let disabled = DailyPlanSummary(
        isSupported: false,
        isEnabled: false,
        targetDate: nil,
        daysRemaining: 0,
        isOverdue: false,
        unseenRemaining: 0,
        currentWrongQuestions: 0,
        todayFirstPassTarget: 0,
        todayFirstPassCompleted: 0,
        todayReviewTarget: 0,
        todayReviewsCompleted: 0,
        todayCorrectionQuestionTarget: 0,
        todayCorrectionQuestionsCompleted: 0,
        todayCorrectionAttemptsRemaining: 0,
        combinedFirstPassTarget: 0,
        combinedFirstPassCompleted: 0,
        combinedReviewTarget: 0,
        combinedReviewsCompleted: 0,
        combinedCorrectionTarget: 0,
        combinedCorrectionsCompleted: 0,
        estimatedWrongProbability: 0,
        estimatedFutureWrongQuestions: 0,
        reservedCorrectionDays: 0,
        effectiveFirstPassDays: 0,
        isScheduleOverloaded: false
    )

    var firstPassRemainingToday: Int {
        max(0, todayFirstPassTarget - todayFirstPassCompleted)
    }

    var correctionQuestionsRemainingToday: Int {
        max(0, todayCorrectionQuestionTarget - todayCorrectionQuestionsCompleted)
    }

    var reviewQuestionsRemainingToday: Int {
        max(0, todayReviewTarget - todayReviewsCompleted)
    }

    var totalRemainingToday: Int {
        firstPassRemainingToday + reviewQuestionsRemainingToday + todayCorrectionAttemptsRemaining
    }

    var totalTargetToday: Int {
        todayFirstPassTarget + todayReviewTarget + todayCorrectionAttemptsRemaining
    }

    var isFullyMastered: Bool {
        unseenRemaining == 0 && currentWrongQuestions == 0 && reviewQuestionsRemainingToday == 0
    }
}

struct PracticeOption: Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    /// Label in the imported source, used only to update letter references in explanations.
    var originalLabel: String?
}

struct WrongBookProgress: Equatable, Sendable {
    var consecutiveCorrect: Int
    var requiredCorrect: Int

    var remaining: Int { max(0, requiredCorrect - consecutiveCorrect) }
}

struct PracticeQuestion: Identifiable, Equatable, Sendable {
    /// Identifies this question occurrence inside the persisted session.
    var id: String
    var questionID: String
    var stem: String
    var options: [PracticeOption]
    var allowsMultipleSelection: Bool
    var requiresTypedAnswer: Bool
    var wrongBookProgress: WrongBookProgress?
}

struct PracticeSessionState: Identifiable, Equatable, Sendable {
    var id: String
    var mode: PracticeMode
    var currentIndex: Int
    var totalCount: Int
    var currentQuestion: PracticeQuestion?
    var isComplete: Bool

    var answeredCount: Int { min(currentIndex, totalCount) }
}

struct AnswerFeedback: Equatable, Sendable {
    var isCorrect: Bool
    var selectedOptionIDs: Set<String>
    var correctOptionIDs: Set<String>
    var typedAnswer: String?
    var essayEvaluation: EssayGradingResult?
    var explanation: String?
    var markedAsUnsure: Bool
    var isInWrongBook: Bool
    var wrongBookProgress: WrongBookProgress?
    var removedFromWrongBook: Bool
    var session: PracticeSessionState
}

struct AnsweredQuestionReview: Equatable, Sendable {
    var position: Int
    var question: PracticeQuestion
    var feedback: AnswerFeedback
}

enum PracticeRepositoryError: LocalizedError {
    case noEligibleQuestions(PracticeMode)
    case wrongModeLocked(unseenCount: Int, wrongCount: Int)
    case dynamicPlanNotConfigured
    case dynamicPlanRequiresThreeCorrect
    case noDynamicPlanTasksToday
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noEligibleQuestions(.normal):
            return "当前没有未做过或已到复习时间的题目。"
        case .noEligibleQuestions(.wrongBook):
            return "错题本为空，暂时不能开始错题模式。"
        case .noEligibleQuestions(.dynamicPlan):
            return "今天的动态计划已经完成。"
        case .wrongModeLocked(let unseenCount, let wrongCount):
            return "还有 \(unseenCount) 道普通题未完成，当前错题 \(wrongCount) 道。错题达到 5 道后可提前开启，或先刷完所有未做题。"
        case .dynamicPlanNotConfigured:
            return "请先在设置中启用动态计划并选择目标学习结束日期。"
        case .dynamicPlanRequiresThreeCorrect:
            return "动态计划要求错题连续答对 3 次后移出，请重新保存设置。"
        case .noDynamicPlanTasksToday:
            return "今天的动态计划已经完成。"
        case .unavailable(let message):
            return message
        }
    }
}
