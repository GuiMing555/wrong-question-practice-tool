import Foundation

/// UI-facing boundary around the shared question-bank database.
/// Implementations must persist each submission before returning feedback.
protocol PracticeRepository: Sendable {
    func dashboard() async throws -> DashboardSummary
    func loadSettings() async throws -> PracticeSettings
    func saveSettings(_ settings: PracticeSettings) async throws
    func buildCurrentWrongKnowledgeDocument() async throws -> URL
    func startSession(mode: PracticeMode) async throws -> PracticeSessionState
    func finishSession(id: String) throws
    func submit(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        typedAnswer: String?,
        submissionToken: String,
        markAsUnsure: Bool
    ) async throws -> AnswerFeedback
}
