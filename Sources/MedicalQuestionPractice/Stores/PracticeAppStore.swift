import AppKit
import Foundation
import QuestionBankCore

@MainActor
final class PracticeAppStore: ObservableObject {
    @Published private(set) var dashboard: DashboardSummary = .empty
    @Published private(set) var session: PracticeSessionState?
    @Published private(set) var feedback: AnswerFeedback?
    @Published private(set) var answeredQuestion: PracticeQuestion?
    @Published private(set) var reviewedAnswer: AnsweredQuestionReview?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isBuildingKnowledgeDocument = false
    @Published private(set) var currentScope: PracticeScope
    @Published var presentedError: PresentedError?

    private var repository: any PracticeRepository
    private var pendingSubmissionTokens: [String: String] = [:]
    private var answerHistory: [AnsweredQuestionReview] = []
    private var reviewedAnswerIndex: Int?

    init(initialSubject: StudySubject = .medicalComprehensive) {
        currentScope = .education(initialSubject)
        repository = PracticeRepositoryFactory.make(scope: .education(initialSubject))
    }

    func selectSubject(_ subject: StudySubject) async {
        await selectScope(.education(subject))
    }

    func selectXingceCategory(_ category: XingceCategory) async {
        await selectScope(.xingce(category))
    }

    private func selectScope(_ scope: PracticeScope) async {
        guard session == nil else { return }
        if currentScope != scope {
            currentScope = scope
            repository = await Task.detached(priority: .userInitiated) {
                PracticeRepositoryFactory.make(scope: scope)
            }.value
            dashboard = .empty
            feedback = nil
            answeredQuestion = nil
            reviewedAnswer = nil
            answerHistory.removeAll()
            pendingSubmissionTokens.removeAll()
        }
        await refreshDashboard()
    }

    func refreshDashboard() async {
        isLoading = true
        defer { isLoading = false }
        do {
            dashboard = try await repository.dashboard()
        } catch {
            present(error)
        }
    }

    func start(_ mode: PracticeMode) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            feedback = nil
            answeredQuestion = nil
            reviewedAnswer = nil
            reviewedAnswerIndex = nil
            answerHistory.removeAll()
            session = try await repository.startSession(mode: mode)
            dashboard = try await repository.dashboard()
        } catch {
            present(error)
        }
    }

    func submit(selectedOptionIDs: Set<String>, typedAnswer: String? = nil, markAsUnsure: Bool) async {
        guard let session, let question = session.currentQuestion,
              feedback == nil, !isSubmitting else { return }

        let submittedSessionID = session.id
        isSubmitting = true
        answeredQuestion = question
        let token = pendingSubmissionTokens[question.id] ?? UUID().uuidString
        pendingSubmissionTokens[question.id] = token
        defer { isSubmitting = false }
        do {
            let result = try await repository.submit(
                sessionID: session.id,
                itemID: question.id,
                selectedOptionIDs: selectedOptionIDs,
                typedAnswer: typedAnswer,
                submissionToken: token,
                markAsUnsure: markAsUnsure
            )
            pendingSubmissionTokens.removeValue(forKey: question.id)
            dashboard = try await repository.dashboard()
            guard self.session?.id == submittedSessionID else { return }
            // The repository has committed the answer before this UI state changes.
            answerHistory.append(
                AnsweredQuestionReview(
                    position: session.currentIndex,
                    question: question,
                    feedback: result
                )
            )
            feedback = result
            self.session = result.session
        } catch {
            guard self.session?.id == submittedSessionID else { return }
            present(error)
        }
    }

    func advanceAfterFeedback() {
        guard let feedback else { return }
        reviewedAnswer = nil
        reviewedAnswerIndex = nil
        self.feedback = nil
        answeredQuestion = nil
        session = feedback.session
    }

    @discardableResult
    func showPreviousQuestion() -> Bool {
        guard !answerHistory.isEmpty else { return false }

        let targetIndex: Int
        if let reviewedAnswerIndex {
            targetIndex = reviewedAnswerIndex - 1
        } else if feedback != nil {
            targetIndex = answerHistory.count - 2
        } else {
            targetIndex = answerHistory.count - 1
        }
        guard answerHistory.indices.contains(targetIndex) else { return false }

        reviewedAnswerIndex = targetIndex
        reviewedAnswer = answerHistory[targetIndex]
        return true
    }

    @discardableResult
    func showNextQuestion() -> Bool {
        guard let reviewedAnswerIndex else {
            if feedback != nil {
                advanceAfterFeedback()
                return true
            }
            return false
        }

        let nextIndex = reviewedAnswerIndex + 1
        if feedback != nil, nextIndex == answerHistory.count - 1 {
            self.reviewedAnswerIndex = nil
            reviewedAnswer = nil
        } else if answerHistory.indices.contains(nextIndex) {
            self.reviewedAnswerIndex = nextIndex
            reviewedAnswer = answerHistory[nextIndex]
        } else {
            self.reviewedAnswerIndex = nil
            reviewedAnswer = nil
        }
        return true
    }

    var canShowPreviousQuestion: Bool {
        if let reviewedAnswerIndex { return reviewedAnswerIndex > 0 }
        if feedback != nil { return answerHistory.count >= 2 }
        return !answerHistory.isEmpty
    }

    var canShowNextQuestion: Bool {
        reviewedAnswerIndex != nil || feedback != nil
    }

    var displayedQuestionNumber: Int {
        if let reviewedAnswer { return reviewedAnswer.position + 1 }
        if feedback != nil, let latest = answerHistory.last { return latest.position + 1 }
        return min((session?.currentIndex ?? 0) + 1, session?.totalCount ?? 1)
    }

    func leavePractice() {
        let sessionID = session?.id
        feedback = nil
        answeredQuestion = nil
        reviewedAnswer = nil
        reviewedAnswerIndex = nil
        answerHistory.removeAll()
        session = nil
        pendingSubmissionTokens.removeAll()
        if let sessionID {
            do {
                try repository.finishSession(id: sessionID)
            } catch {
                present(error)
            }
        }
        Task { await refreshDashboard() }
    }

    func loadSettings() async throws -> PracticeSettings {
        try await repository.loadSettings()
    }

    func saveSettings(_ settings: PracticeSettings) async throws {
        try await repository.saveSettings(settings)
        await refreshDashboard()
    }

    func buildCurrentWrongKnowledgeDocument() async {
        guard !isBuildingKnowledgeDocument else { return }
        isBuildingKnowledgeDocument = true
        defer { isBuildingKnowledgeDocument = false }
        do {
            let output = try await repository.buildCurrentWrongKnowledgeDocument()
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        presentedError = PresentedError(message: error.localizedDescription)
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
}
