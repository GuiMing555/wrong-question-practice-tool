import Foundation

public struct EducationPlanCorrectionCandidate: Equatable, Sendable {
    public let questionID: String
    public let remainingCorrect: Int
    public let addedToWrongBookAt: Date
}

public struct EducationPlanReviewCandidate: Equatable, Sendable {
    public let questionID: String
    public let lastReviewedAt: Date
    public let completedToday: Bool
}

public struct EducationPlanSubjectMetrics: Equatable, Sendable {
    public let totalQuestions: Int
    public let unseenQuestions: Int
    public let firstPassCompletedToday: Int
    public let reviewCandidates: [EducationPlanReviewCandidate]
    public let reviewsCompletedToday: [EducationPlanReviewCandidate]
    public let correctionCandidates: [EducationPlanCorrectionCandidate]
    public let correctionsCompletedToday: Int
    public let currentWrongQuestions: Int
    public let firstPassAttemptCount: Int
    public let firstPassWrongCount: Int
}

public struct EducationPlanSubjectAllocation: Equatable, Sendable {
    public let subject: StudySubject
    public let totalQuestions: Int
    public let unseenQuestions: Int
    public let firstPassTargetToday: Int
    public let firstPassCompletedToday: Int
    public let reviewQuestionIDs: [String]
    public let reviewsCompletedToday: Int
    public let correctionQuestionIDs: [String]
    public let correctionAttemptCount: Int
    public let correctionsCompletedToday: Int

    public var firstPassRemainingToday: Int {
        max(0, firstPassTargetToday - firstPassCompletedToday)
    }

    public var correctionQuestionsRemainingToday: Int {
        correctionQuestionIDs.count
    }

    public var reviewQuestionsRemainingToday: Int {
        reviewQuestionIDs.count
    }

    public var sessionAttemptCount: Int {
        firstPassRemainingToday + reviewQuestionsRemainingToday + correctionAttemptCount
    }
}

public struct EducationDynamicPlanSnapshot: Equatable, Sendable {
    public let isEnabled: Bool
    public let targetDate: Date?
    public let daysRemaining: Int
    public let isOverdue: Bool
    public let firstPassTargetToday: Int
    public let firstPassCompletedToday: Int
    public let reviewTargetToday: Int
    public let reviewsCompletedToday: Int
    public let correctionsTargetToday: Int
    public let correctionsCompletedToday: Int
    public let unseenQuestionsRemaining: Int
    public let currentWrongQuestions: Int
    public let estimatedWrongProbability: Double
    public let estimatedFutureWrongQuestions: Int
    public let reservedCorrectionDays: Int
    public let effectiveFirstPassDays: Int
    public let isScheduleOverloaded: Bool
    public let allocations: [StudySubject: EducationPlanSubjectAllocation]

    public var firstPassRemainingToday: Int {
        max(0, firstPassTargetToday - firstPassCompletedToday)
    }

    public var correctionsRemainingToday: Int {
        max(0, correctionsTargetToday - correctionsCompletedToday)
    }

    public var reviewsRemainingToday: Int {
        max(0, reviewTargetToday - reviewsCompletedToday)
    }
}

public final class EducationDynamicPlanCoordinator: @unchecked Sendable {
    public static let minimumFirstPassQuestionsPerDay = 200
    public static let maximumCorrectionQuestionsPerDay = 100
    public static let maximumEnglishQuestionsPerDay = 30

    private let stores: [StudySubject: QuestionBankStore]

    public init(stores: [StudySubject: QuestionBankStore]) {
        self.stores = stores
    }

    public func configuration() throws -> SettingsSnapshot {
        guard let canonical = stores[.medicalComprehensive] else {
            throw QuestionBankError.database("缺少医学综合题本，无法读取三科动态计划")
        }
        return try canonical.settings()
    }

    public func synchronizeConfiguration(enabled: Bool, targetDate: Date?) throws {
        for subject in StudySubject.allCases {
            guard let store = stores[subject] else { continue }
            var settings = try store.settings()
            settings.dynamicPlanEnabled = enabled
            settings.dynamicPlanTargetDate = targetDate
            if enabled { settings.wrongRequiredConsecutiveCorrect = 3 }
            try store.updateSettings(settings)
        }
    }

    public func snapshot(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> EducationDynamicPlanSnapshot {
        let configuration = try configuration()
        var metrics: [StudySubject: EducationPlanSubjectMetrics] = [:]
        for subject in StudySubject.allCases {
            guard let store = stores[subject] else { continue }
            metrics[subject] = try store.educationPlanMetrics(now: now, calendar: calendar)
        }
        let today = calendar.startOfDay(for: now)
        guard configuration.dynamicPlanEnabled,
              let configuredTarget = configuration.dynamicPlanTargetDate
        else {
            return EducationDynamicPlanSnapshot(
                isEnabled: false,
                targetDate: configuration.dynamicPlanTargetDate,
                daysRemaining: 0,
                isOverdue: false,
                firstPassTargetToday: 0,
                firstPassCompletedToday: metrics.values.reduce(0) { $0 + $1.firstPassCompletedToday },
                reviewTargetToday: 0,
                reviewsCompletedToday: metrics.values.reduce(0) { $0 + $1.reviewsCompletedToday.count },
                correctionsTargetToday: 0,
                correctionsCompletedToday: metrics.values.reduce(0) { $0 + $1.correctionsCompletedToday },
                unseenQuestionsRemaining: metrics.values.reduce(0) { $0 + $1.unseenQuestions },
                currentWrongQuestions: metrics.values.reduce(0) { $0 + $1.currentWrongQuestions },
                estimatedWrongProbability: estimatedWrongProbability(metrics: metrics),
                estimatedFutureWrongQuestions: 0,
                reservedCorrectionDays: 0,
                effectiveFirstPassDays: 0,
                isScheduleOverloaded: false,
                allocations: disabledAllocations(metrics: metrics)
            )
        }
        guard configuration.wrongRequiredConsecutiveCorrect == 3 else {
            throw QuestionBankError.dynamicPlanRequiresThreeCorrect
        }

        let targetDate = calendar.startOfDay(for: configuredTarget)
        let difference = calendar.dateComponents([.day], from: today, to: targetDate).day ?? 0
        let daysRemaining = max(1, difference + 1)
        let primaryMetrics = metrics.filter { $0.key != .english }
        let primaryFirstPassCompleted = primaryMetrics.values.reduce(0) { $0 + $1.firstPassCompletedToday }
        let primaryUnseen = primaryMetrics.values.reduce(0) { $0 + $1.unseenQuestions }
        let firstPassWorkload = primaryUnseen + primaryFirstPassCompleted
        let wrongProbability = estimatedWrongProbability(metrics: primaryMetrics)
        let estimatedFutureWrongQuestions = Int(ceil(Double(primaryUnseen) * wrongProbability))
        let currentWrongQuestions = primaryMetrics.values.reduce(0) { $0 + $1.currentWrongQuestions }
        let estimatedCorrectionWorkload = currentWrongQuestions + estimatedFutureWrongQuestions
        let reservedCorrectionDays = estimatedCorrectionWorkload > 0
            ? max(1, (estimatedCorrectionWorkload + Self.maximumCorrectionQuestionsPerDay - 1)
                / Self.maximumCorrectionQuestionsPerDay)
            : 0
        let effectiveFirstPassDays = max(1, daysRemaining - reservedCorrectionDays)
        let deadlineTarget = DynamicStudyPlanScheduler.dailyTarget(
            workload: firstPassWorkload,
            daysRemaining: effectiveFirstPassDays
        )
        let primaryFirstPassTarget = min(
            firstPassWorkload,
            max(Self.minimumFirstPassQuestionsPerDay, deadlineTarget)
        )
        var firstPassAllocations = proportionalAllocation(
            total: primaryFirstPassTarget,
            weights: primaryMetrics.mapValues { $0.totalQuestions },
            capacities: primaryMetrics.mapValues { $0.unseenQuestions + $0.firstPassCompletedToday }
        )

        let allPrimaryReviews: [(subject: StudySubject, candidate: EducationPlanReviewCandidate)] = primaryMetrics.flatMap { subject, value in
            (value.reviewCandidates + value.reviewsCompletedToday).map {
                (subject: subject, candidate: $0)
            }
        }
        let primaryReviewTarget = reviewTargetToday(
            candidates: allPrimaryReviews.map { $0.candidate },
            now: now,
            calendar: calendar
        )
        let primaryReviewsCompleted = allPrimaryReviews.reduce(0) {
            $0 + ($1.candidate.completedToday ? 1 : 0)
        }
        let primaryReviewsRemaining = max(0, primaryReviewTarget - primaryReviewsCompleted)
        var selectedReviews = Array(allPrimaryReviews.filter { !$0.candidate.completedToday }.sorted { left, right in
            if left.candidate.lastReviewedAt != right.candidate.lastReviewedAt {
                return left.candidate.lastReviewedAt < right.candidate.lastReviewedAt
            }
            if left.subject.rawValue != right.subject.rawValue {
                return left.subject.rawValue < right.subject.rawValue
            }
            return left.candidate.questionID < right.candidate.questionID
        }.prefix(primaryReviewsRemaining))

        let englishMetrics = metrics[.english]
        let englishReviewsCompleted = englishMetrics?.reviewsCompletedToday.count ?? 0
        let englishFirstCompleted = englishMetrics?.firstPassCompletedToday ?? 0
        let englishCorrectionsCompleted = englishMetrics?.correctionsCompletedToday ?? 0
        let englishNormalGap = max(
            0,
            Self.minimumFirstPassQuestionsPerDay - primaryFirstPassTarget - primaryReviewTarget
        )
        let englishNormalCompleted = englishFirstCompleted + englishReviewsCompleted
        let englishNormalCapacity = min(
            max(0, Self.maximumEnglishQuestionsPerDay - englishCorrectionsCompleted),
            max(englishNormalCompleted, englishNormalGap)
        )
        let englishReviewCandidates = (englishMetrics?.reviewCandidates ?? []).sorted {
            if $0.lastReviewedAt != $1.lastReviewedAt { return $0.lastReviewedAt < $1.lastReviewedAt }
            return $0.questionID < $1.questionID
        }
        let englishReviewTarget = min(
            englishReviewCandidates.count + englishReviewsCompleted,
            max(englishReviewsCompleted, englishNormalCapacity - englishFirstCompleted)
        )
        let englishReviewsRemaining = max(0, englishReviewTarget - englishReviewsCompleted)
        selectedReviews.append(contentsOf: englishReviewCandidates.prefix(englishReviewsRemaining).map {
            (subject: StudySubject.english, candidate: $0)
        })
        let englishFirstCapacity = max(englishFirstCompleted, englishNormalCapacity - englishReviewTarget)
        let englishFirstTarget = min(
            (englishMetrics?.unseenQuestions ?? 0) + englishFirstCompleted,
            max(englishFirstCompleted, englishFirstCapacity)
        )
        firstPassAllocations[.english] = englishFirstTarget
        let firstPassTarget = primaryFirstPassTarget + englishFirstTarget
        let firstPassCompleted = primaryFirstPassCompleted + englishFirstCompleted
        let reviewTarget = primaryReviewTarget + englishReviewTarget
        let reviewsCompleted = primaryReviewsCompleted + englishReviewsCompleted

        let correctionsCompleted = metrics.values.reduce(0) { $0 + $1.correctionsCompletedToday }
        let allCandidates: [(subject: StudySubject, candidate: EducationPlanCorrectionCandidate)] = metrics.flatMap { subject, value in
            value.correctionCandidates.map { (subject: subject, candidate: $0) }
        }
        let sortedCorrections = allCandidates.sorted { left, right in
            if left.candidate.addedToWrongBookAt != right.candidate.addedToWrongBookAt {
                return left.candidate.addedToWrongBookAt < right.candidate.addedToWrongBookAt
            }
            if left.subject.rawValue != right.subject.rawValue {
                return left.subject.rawValue < right.subject.rawValue
            }
            return left.candidate.questionID < right.candidate.questionID
        }
        let correctionCapacity = max(0, Self.maximumCorrectionQuestionsPerDay - correctionsCompleted)
        var selectedCorrections = Array(sortedCorrections.filter { $0.subject != .english }.prefix(correctionCapacity))
        let remainingCorrectionCapacity = max(0, correctionCapacity - selectedCorrections.count)
        let englishUsedToday = englishFirstTarget + englishReviewTarget + englishCorrectionsCompleted
        let englishCorrectionCapacity = max(0, Self.maximumEnglishQuestionsPerDay - englishUsedToday)
        selectedCorrections.append(contentsOf: sortedCorrections.filter { $0.subject == .english }.prefix(
            min(remainingCorrectionCapacity, englishCorrectionCapacity)
        ))
        let correctionTarget = correctionsCompleted + selectedCorrections.count

        var allocations: [StudySubject: EducationPlanSubjectAllocation] = [:]
        for subject in StudySubject.allCases {
            let value = metrics[subject] ?? EducationPlanSubjectMetrics(
                totalQuestions: 0,
                unseenQuestions: 0,
                firstPassCompletedToday: 0,
                reviewCandidates: [],
                reviewsCompletedToday: [],
                correctionCandidates: [],
                correctionsCompletedToday: 0,
                currentWrongQuestions: 0,
                firstPassAttemptCount: 0,
                firstPassWrongCount: 0
            )
            let selectedReviewIDs = selectedReviews.filter { $0.subject == subject }
            let selected = selectedCorrections.filter { $0.subject == subject }
            allocations[subject] = EducationPlanSubjectAllocation(
                subject: subject,
                totalQuestions: value.totalQuestions,
                unseenQuestions: value.unseenQuestions,
                firstPassTargetToday: firstPassAllocations[subject] ?? 0,
                firstPassCompletedToday: value.firstPassCompletedToday,
                reviewQuestionIDs: selectedReviewIDs.map { $0.candidate.questionID },
                reviewsCompletedToday: value.reviewsCompletedToday.count,
                correctionQuestionIDs: selected.map { $0.candidate.questionID },
                correctionAttemptCount: selected.reduce(0) {
                    $0 + $1.candidate.remainingCorrect
                },
                correctionsCompletedToday: value.correctionsCompletedToday
            )
        }
        return EducationDynamicPlanSnapshot(
            isEnabled: true,
            targetDate: targetDate,
            daysRemaining: daysRemaining,
            isOverdue: targetDate < today,
            firstPassTargetToday: firstPassTarget,
            firstPassCompletedToday: firstPassCompleted,
            reviewTargetToday: reviewTarget,
            reviewsCompletedToday: reviewsCompleted,
            correctionsTargetToday: correctionTarget,
            correctionsCompletedToday: correctionsCompleted,
            unseenQuestionsRemaining: primaryUnseen,
            currentWrongQuestions: currentWrongQuestions,
            estimatedWrongProbability: wrongProbability,
            estimatedFutureWrongQuestions: estimatedFutureWrongQuestions,
            reservedCorrectionDays: reservedCorrectionDays,
            effectiveFirstPassDays: effectiveFirstPassDays,
            isScheduleOverloaded: estimatedCorrectionWorkload
                > daysRemaining * Self.maximumCorrectionQuestionsPerDay
                || (primaryUnseen > 0 && daysRemaining <= reservedCorrectionDays),
            allocations: allocations
        )
    }

    public func startSession(
        subject: StudySubject,
        now: Date = Date(),
        calendar: Calendar = .current,
        seed: UInt64? = nil
    ) throws -> PracticeSessionSnapshot {
        guard let store = stores[subject] else {
            throw QuestionBankError.database("缺少\(subject.displayName)题本")
        }
        let plan = try snapshot(now: now, calendar: calendar)
        guard plan.isEnabled else { throw QuestionBankError.dynamicPlanNotConfigured }
        guard let allocation = plan.allocations[subject], allocation.sessionAttemptCount > 0 else {
            throw QuestionBankError.noDynamicPlanTasksToday
        }
        return try store.startEducationDynamicPlanSession(
            firstPassLimit: allocation.firstPassRemainingToday,
            reviewQuestionIDs: allocation.reviewQuestionIDs,
            correctionQuestionIDs: allocation.correctionQuestionIDs,
            now: now,
            calendar: calendar,
            seed: seed
        )
    }

    private func disabledAllocations(
        metrics: [StudySubject: EducationPlanSubjectMetrics]
    ) -> [StudySubject: EducationPlanSubjectAllocation] {
        Dictionary(uniqueKeysWithValues: StudySubject.allCases.map { subject in
            let value = metrics[subject]
            return (
                subject,
                EducationPlanSubjectAllocation(
                    subject: subject,
                    totalQuestions: value?.totalQuestions ?? 0,
                    unseenQuestions: value?.unseenQuestions ?? 0,
                    firstPassTargetToday: 0,
                    firstPassCompletedToday: value?.firstPassCompletedToday ?? 0,
                    reviewQuestionIDs: [],
                    reviewsCompletedToday: value?.reviewsCompletedToday.count ?? 0,
                    correctionQuestionIDs: [],
                    correctionAttemptCount: 0,
                    correctionsCompletedToday: value?.correctionsCompletedToday ?? 0
                )
            )
        })
    }

    private func estimatedWrongProbability(
        metrics: [StudySubject: EducationPlanSubjectMetrics]
    ) -> Double {
        let attempts = metrics.values.reduce(0) { $0 + $1.firstPassAttemptCount }
        let wrong = metrics.values.reduce(0) { $0 + $1.firstPassWrongCount }
        let priorSampleCount = 20.0
        let priorWrongCount = 5.0
        return (Double(wrong) + priorWrongCount) / (Double(attempts) + priorSampleCount)
    }

    private func reviewTargetToday(
        candidates: [EducationPlanReviewCandidate],
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        let deadlines = candidates.map { candidate -> Int in
            let lastDay = calendar.startOfDay(for: candidate.lastReviewedAt)
            let deadline = calendar.date(byAdding: .day, value: 14, to: lastDay) ?? today
            return max(1, calendar.dateComponents([.day], from: today, to: deadline).day ?? 1)
        }.sorted()
        var target = 0
        for (index, daysUntilDeadline) in deadlines.enumerated() {
            let cumulative = index + 1
            target = max(target, (cumulative + daysUntilDeadline - 1) / daysUntilDeadline)
        }
        return min(candidates.count, target)
    }

    private func proportionalAllocation(
        total: Int,
        weights: [StudySubject: Int],
        capacities: [StudySubject: Int]
    ) -> [StudySubject: Int] {
        var result = Dictionary(uniqueKeysWithValues: StudySubject.allCases.map { ($0, 0) })
        guard total > 0 else { return result }
        var remaining = total
        while remaining > 0 {
            let eligible = StudySubject.allCases.filter {
                result[$0, default: 0] < capacities[$0, default: 0]
            }
            guard !eligible.isEmpty else { break }
            let selected = eligible.min { left, right in
                let leftWeight = max(1, weights[left, default: 0])
                let rightWeight = max(1, weights[right, default: 0])
                let leftScaled = result[left, default: 0] * rightWeight
                let rightScaled = result[right, default: 0] * leftWeight
                if leftScaled != rightScaled { return leftScaled < rightScaled }
                return left.rawValue < right.rawValue
            } ?? eligible[0]
            result[selected, default: 0] += 1
            remaining -= 1
        }
        return result
    }
}
