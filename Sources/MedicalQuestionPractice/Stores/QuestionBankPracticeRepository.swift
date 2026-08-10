import Foundation
import QuestionBankCore

final class QuestionBankPracticeRepository: PracticeRepository, @unchecked Sendable {
    private let store: QuestionBankStore
    private let exportsWorkbook: Bool
    private let educationSubject: StudySubject?
    private let educationPlanCoordinator: EducationDynamicPlanCoordinator?
    private let educationStores: [StudySubject: QuestionBankStore]

    init(subject: StudySubject = .medicalComprehensive, databaseURL: URL? = nil) throws {
        exportsWorkbook = true
        educationSubject = subject
        if let databaseURL {
            store = try QuestionBankStore(
                databaseURL: databaseURL,
                sourceApplication: "question-practice-macos:\(subject.rawValue)"
            )
        } else {
            store = try QuestionBankStore(
                databaseURL: QuestionBankPaths.defaultDatabaseURL(for: subject),
                sourceApplication: "question-practice-macos:\(subject.rawValue)"
            )
        }
        var stores: [StudySubject: QuestionBankStore] = [subject: store]
        if databaseURL == nil {
            for otherSubject in StudySubject.allCases where otherSubject != subject {
                stores[otherSubject] = try QuestionBankStore(
                    databaseURL: QuestionBankPaths.defaultDatabaseURL(for: otherSubject),
                    sourceApplication: "question-practice-macos:plan:\(otherSubject.rawValue)"
                )
            }
        }
        educationStores = stores
        educationPlanCoordinator = databaseURL == nil
            ? EducationDynamicPlanCoordinator(stores: stores)
            : nil
        // 启动时补刷一次，覆盖上次在数据库提交后、工作簿写入前意外退出的情况。
        _ = try? store.exportWorkbook()
    }

    init(xingceCategory: XingceCategory, databaseURL: URL? = nil) throws {
        exportsWorkbook = false
        educationSubject = nil
        educationPlanCoordinator = nil
        educationStores = [:]
        _ = try CivilServiceQuestionBankImporter.installIfNeeded(
            category: xingceCategory,
            databaseURL: databaseURL
        )
        let targetURL: URL
        if let databaseURL {
            targetURL = databaseURL
        } else {
            targetURL = try QuestionBankPaths.civilServiceDatabaseURL(for: xingceCategory)
        }
        store = try QuestionBankStore(
            databaseURL: targetURL,
            sourceApplication: "question-practice-macos:civil-service:\(xingceCategory.rawValue)"
        )
    }

    func dashboard() async throws -> DashboardSummary {
        let value = try store.dashboard()
        let planSummary: DailyPlanSummary
        if let educationSubject, let educationPlanCoordinator {
            let combined = try educationPlanCoordinator.snapshot()
            let allocation = combined.allocations[educationSubject]
            planSummary = DailyPlanSummary(
                isSupported: true,
                isEnabled: combined.isEnabled,
                targetDate: combined.targetDate,
                daysRemaining: combined.daysRemaining,
                isOverdue: combined.isOverdue,
                unseenRemaining: combined.unseenQuestionsRemaining,
                currentWrongQuestions: combined.currentWrongQuestions,
                todayFirstPassTarget: allocation?.firstPassTargetToday ?? 0,
                todayFirstPassCompleted: allocation?.firstPassCompletedToday ?? 0,
                todayReviewTarget: (allocation?.reviewQuestionsRemainingToday ?? 0)
                    + (allocation?.reviewsCompletedToday ?? 0),
                todayReviewsCompleted: allocation?.reviewsCompletedToday ?? 0,
                todayCorrectionQuestionTarget: (allocation?.correctionQuestionsRemainingToday ?? 0)
                    + (allocation?.correctionsCompletedToday ?? 0),
                todayCorrectionQuestionsCompleted: allocation?.correctionsCompletedToday ?? 0,
                todayCorrectionAttemptsRemaining: allocation?.correctionAttemptCount ?? 0,
                combinedFirstPassTarget: combined.firstPassTargetToday,
                combinedFirstPassCompleted: combined.firstPassCompletedToday,
                combinedReviewTarget: combined.reviewTargetToday,
                combinedReviewsCompleted: combined.reviewsCompletedToday,
                combinedCorrectionTarget: combined.correctionsTargetToday,
                combinedCorrectionsCompleted: combined.correctionsCompletedToday,
                estimatedWrongProbability: combined.estimatedWrongProbability,
                estimatedFutureWrongQuestions: combined.estimatedFutureWrongQuestions,
                reservedCorrectionDays: combined.reservedCorrectionDays,
                effectiveFirstPassDays: combined.effectiveFirstPassDays,
                isScheduleOverloaded: combined.isScheduleOverloaded
            )
        } else {
            planSummary = .disabled
        }
        return DashboardSummary(
            totalQuestions: value.totalQuestions,
            unseenQuestions: value.unseenCount,
            dueQuestions: value.dueNormalCount,
            wrongBookQuestions: value.wrongBookCount,
            wrongBookSessionQuestions: value.wrongBookSessionQuestionCount,
            answeredToday: value.answeredTodayCount,
            dynamicPlan: planSummary
        )
    }

    func loadSettings() async throws -> PracticeSettings {
        let value = try store.settings()
        let planConfiguration = try educationPlanCoordinator?.configuration()
        return PracticeSettings(
            normalReviewIntervalDays: value.normalReviewIntervalDays,
            wrongRequiredConsecutiveCorrect: value.wrongRequiredConsecutiveCorrect,
            questionsPerSession: value.questionsPerSession,
            dynamicPlanEnabled: planConfiguration?.dynamicPlanEnabled ?? false,
            dynamicPlanTargetDate: planConfiguration?.dynamicPlanTargetDate
        )
    }

    func saveSettings(_ settings: PracticeSettings) async throws {
        try store.updateSettings(
            SettingsSnapshot(
                normalReviewIntervalDays: settings.normalReviewIntervalDays,
                wrongRequiredConsecutiveCorrect: settings.wrongRequiredConsecutiveCorrect,
                questionsPerSession: settings.questionsPerSession,
                dynamicPlanEnabled: settings.dynamicPlanEnabled,
                dynamicPlanTargetDate: settings.dynamicPlanTargetDate
            )
        )
        try educationPlanCoordinator?.synchronizeConfiguration(
            enabled: settings.dynamicPlanEnabled,
            targetDate: settings.dynamicPlanTargetDate
        )
    }

    func buildCurrentWrongKnowledgeDocument() async throws -> URL {
        guard !educationStores.isEmpty else {
            throw PracticeRepositoryError.unavailable("当前错题知识点整合仅支持升学考试题库")
        }
        let stores = educationStores
        return try await Task.detached(priority: .userInitiated) {
            let configuration = SharedContentServiceConfigurationStore.load().normalized()
            var candidates: [(StudySubject, QuestionBankStore, QuestionAnalysisCandidate)] = []
            for subject in StudySubject.allCases {
                guard let subjectStore = stores[subject] else { continue }
                for candidate in try subjectStore.questionsMissingAPIResponse(
                    subject: subject,
                    wrongBookOnly: true
                ) {
                    candidates.append((subject, subjectStore, candidate))
                }
            }

            if !candidates.isEmpty {
                guard configuration.enabled else {
                    throw PracticeRepositoryError.unavailable(
                        "当前错题中有 \(candidates.count) 题缺少知识点回复。请先在设置中启用两个程序共用的题目分析 API。"
                    )
                }
                try configuration.validate()
                guard let endpoint = URL(string: configuration.endpoint) else {
                    throw SharedContentServiceConfigurationError.invalidEndpoint
                }
                let service = QuestionContentService(
                    endpoint: endpoint,
                    accessKey: configuration.accessKey,
                    model: configuration.model
                )
                var failures: [String] = []
                for (_, subjectStore, candidate) in candidates {
                    var failureReasons: [String] = []
                    var result: QuestionContentResult?
                    for _ in 1...3 {
                        do {
                            result = try service.analyze(candidate.input)
                            break
                        } catch {
                            failureReasons.append(error.localizedDescription)
                        }
                    }
                    if let result {
                        _ = try subjectStore.recordAPIResponse(
                            questionID: candidate.questionID,
                            inputHash: QuestionContentService.inputHash(candidate.input),
                            endpoint: configuration.endpoint,
                            model: configuration.model,
                            result: result
                        )
                    } else {
                        let reasons = failureReasons.enumerated().map {
                            "第 \($0.offset + 1) 次：\($0.element)"
                        }.joined(separator: "；")
                        failures.append("\(candidate.input.stableID)：\(reasons)")
                    }
                }
                if !failures.isEmpty {
                    throw PracticeRepositoryError.unavailable(
                        "有 \(failures.count) 题连续重试 3 次仍失败：\n" + failures.prefix(8).joined(separator: "\n")
                    )
                }
            }

            var records: [QuestionKnowledgeRecord] = []
            for subject in StudySubject.allCases {
                guard let subjectStore = stores[subject] else { continue }
                records += try subjectStore.knowledgeRecords(
                    subject: subject,
                    wrongBookOnly: true
                )
            }
            let output = URL(
                fileURLWithPath: configuration.knowledgeDocumentFolderPath,
                isDirectory: true
            ).appendingPathComponent("当前错题知识点.docx")
            try KnowledgeDocumentWriter.write(
                records: records,
                kind: .currentWrong(updatedAt: Date()),
                to: output
            )
            return output
        }.value
    }

    func startSession(mode: PracticeMode) async throws -> PracticeSessionState {
        do {
            try store.finishActiveSessions()
            let value: PracticeSessionSnapshot
            if mode == .dynamicPlan {
                guard let educationSubject, let educationPlanCoordinator else {
                    throw PracticeRepositoryError.unavailable("动态计划仅适用于升学考试三科")
                }
                value = try educationPlanCoordinator.startSession(subject: educationSubject)
            } else {
                value = try store.startSession(mode: mapMode(mode), resumeExisting: false)
            }
            return mapSession(value)
        } catch QuestionBankError.wrongModeLocked(let unseenCount, let wrongCount) {
            throw PracticeRepositoryError.wrongModeLocked(
                unseenCount: unseenCount,
                wrongCount: wrongCount
            )
        } catch QuestionBankError.noEligibleQuestions {
            throw PracticeRepositoryError.noEligibleQuestions(mode)
        } catch QuestionBankError.dynamicPlanNotConfigured {
            throw PracticeRepositoryError.dynamicPlanNotConfigured
        } catch QuestionBankError.dynamicPlanRequiresThreeCorrect {
            throw PracticeRepositoryError.dynamicPlanRequiresThreeCorrect
        } catch QuestionBankError.noDynamicPlanTasksToday {
            throw PracticeRepositoryError.noDynamicPlanTasksToday
        }
    }

    func finishSession(id: String) throws {
        try store.finishSession(id: id)
    }

    func submit(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        typedAnswer: String?,
        submissionToken: String,
        markAsUnsure: Bool
    ) async throws -> AnswerFeedback {
        let current = try store.session(id: sessionID).currentItem
        guard current?.itemID == itemID else { throw QuestionBankError.itemIsNotCurrent }
        var essayEvaluation: EssayGradingResult?
        if current?.requiresTypedAnswer == true, !markAsUnsure {
            let configuration = SharedContentServiceConfigurationStore.load()
            guard configuration.enabled,
                  let endpoint = URL(string: configuration.endpoint),
                  !configuration.accessKey.isEmpty,
                  let answer = typedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty,
                  let question = current
            else {
                throw PracticeRepositoryError.unavailable("论述题必须启用题目分析 API，并输入作答内容后才能评分。")
            }
            essayEvaluation = try await Task.detached(priority: .userInitiated) {
                try EssayGradingService(
                    endpoint: endpoint,
                    accessKey: configuration.accessKey,
                    model: configuration.model
                ).grade(
                    EssayGradingInput(
                        question: question.stem,
                        referenceExplanation: question.explanation,
                        answer: answer
                    )
                )
            }.value
        }
        let value = try store.submit(
            SubmitAnswerRequest(
                sessionID: sessionID,
                itemID: itemID,
                selectedOptionIDs: selectedOptionIDs,
                typedAnswer: typedAnswer,
                essayEvaluation: essayEvaluation,
                submissionToken: submissionToken,
                markAsUnsure: markAsUnsure
            )
        )
        // 作答记录已经提交后再刷新工作簿；工作簿失败不回滚本次作答。
        if exportsWorkbook {
            do {
                _ = try store.exportWorkbook()
            } catch {
                FileHandle.standardError.write(Data(("题本工作簿刷新失败：\(error.localizedDescription)\n").utf8))
            }
        }
        let session = mapSession(value.session)
        let progress = value.isInWrongBook
            ? WrongBookProgress(
                consecutiveCorrect: value.wrongProgressAfter,
                requiredCorrect: try store.settings().wrongRequiredConsecutiveCorrect
            )
            : nil
        return AnswerFeedback(
            isCorrect: value.isCorrect,
            selectedOptionIDs: value.selectedOptionIDs,
            correctOptionIDs: value.correctOptionIDs,
            typedAnswer: value.typedAnswer,
            essayEvaluation: value.essayEvaluation,
            explanation: value.explanation,
            markedAsUnsure: value.markedAsUnsure,
            isInWrongBook: value.isInWrongBook,
            wrongBookProgress: progress,
            removedFromWrongBook: value.removedFromWrongBook,
            session: session
        )
    }

    private func mapMode(_ mode: PracticeMode) -> QuestionBankCore.PracticeMode {
        switch mode {
        case .normal: return .normal
        case .wrongBook: return .wrongBook
        case .dynamicPlan: return .normal
        }
    }

    private func mapMode(_ mode: QuestionBankCore.PracticeMode) -> PracticeMode {
        switch mode {
        case .normal: return .normal
        case .wrongBook: return .wrongBook
        }
    }

    private func mapSession(_ value: PracticeSessionSnapshot) -> PracticeSessionState {
        let mode: PracticeMode = value.summary.isDynamicPlan ? .dynamicPlan : mapMode(value.mode)
        return PracticeSessionState(
            id: value.id,
            mode: mode,
            currentIndex: value.currentIndex,
            totalCount: value.totalCount,
            currentQuestion: value.currentItem.map { mapQuestion($0, mode: mode) },
            isComplete: value.isComplete
        )
    }

    private func mapQuestion(
        _ value: QuestionBankCore.PracticeQuestion,
        mode: PracticeMode
    ) -> PracticeQuestion {
        PracticeQuestion(
            id: value.itemID,
            questionID: value.questionID,
            stem: value.stem,
            options: value.options.map {
                PracticeOption(id: $0.id, text: $0.text, originalLabel: $0.originalLabel)
            },
            allowsMultipleSelection: value.allowsMultipleSelection,
            requiresTypedAnswer: value.requiresTypedAnswer,
            wrongBookProgress: (mode == .wrongBook || mode == .dynamicPlan)
                && value.isInWrongBook == true
                ? WrongBookProgress(
                    consecutiveCorrect: value.wrongProgress,
                    requiredCorrect: value.wrongRequired
                )
                : nil
        )
    }
}

enum PracticeRepositoryFactory {
    static func make(scope: PracticeScope) -> any PracticeRepository {
        do {
            switch scope {
            case .education(let subject):
                return try QuestionBankPracticeRepository(subject: subject)
            case .xingce(let category):
                return try QuestionBankPracticeRepository(xingceCategory: category)
            }
        } catch {
            return UnavailablePracticeRepository(
                message: "无法打开\(scope.displayName)题本：\(error.localizedDescription)"
            )
        }
    }
}

private struct UnavailablePracticeRepository: PracticeRepository {
    let message: String

    func dashboard() async throws -> DashboardSummary { throw unavailable }
    func loadSettings() async throws -> PracticeSettings { throw unavailable }
    func saveSettings(_ settings: PracticeSettings) async throws { throw unavailable }
    func buildCurrentWrongKnowledgeDocument() async throws -> URL { throw unavailable }
    func startSession(mode: PracticeMode) async throws -> PracticeSessionState { throw unavailable }
    func finishSession(id: String) throws { throw unavailable }
    func submit(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        typedAnswer: String?,
        submissionToken: String,
        markAsUnsure: Bool
    ) async throws -> AnswerFeedback { throw unavailable }

    private var unavailable: PracticeRepositoryError { .unavailable(message) }
}
