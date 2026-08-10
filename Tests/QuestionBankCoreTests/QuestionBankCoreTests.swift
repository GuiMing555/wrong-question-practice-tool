import CryptoKit
import Foundation
import XCTest
@testable import QuestionBankCore

final class QuestionBankCoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var databaseURL: URL!
    private var store: QuestionBankStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuestionBankCoreTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = temporaryDirectory.appendingPathComponent("question-bank.sqlite3")
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "tests")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSingleInstanceLockRejectsDuplicateAndReleasesOnDeinit() throws {
        let identifier = "single-instance-test-\(UUID().uuidString)"
        var firstLock: SingleInstanceLock? = try XCTUnwrap(
            SingleInstanceLock.acquire(identifier: identifier)
        )
        XCTAssertNotNil(firstLock)
        XCTAssertNil(try SingleInstanceLock.acquire(identifier: identifier))

        firstLock = nil
        XCTAssertNotNil(try SingleInstanceLock.acquire(identifier: identifier))
    }

    func testScreenshotBatchArchiveIsVerifiedBeforeOriginalsAreRemoved() throws {
        let captureRoot = temporaryDirectory.appendingPathComponent("截图", isDirectory: true)
        let first = captureRoot.appendingPathComponent("2026-08-10/第一题.png")
        let second = captureRoot.appendingPathComponent("2026-08-10/第二题.jpg")
        let third = captureRoot.appendingPathComponent("2026-08-10/第三题.snapshot.txt")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first-image".utf8).write(to: first)
        try Data("second-image".utf8).write(to: second)
        let snapshot = try PageSnapshotSidecar.write("完整页面题干、选项和解析", nextTo: first)
        XCTAssertEqual(PageSnapshotSidecar.read(nextTo: first), "完整页面题干、选项和解析")
        try PageSnapshotSidecar.writeStandalone("第三题完整页面数据", to: third)
        XCTAssertEqual(PageSnapshotSidecar.readStandalone(from: third), "第三题完整页面数据")

        let report = try XCTUnwrap(
            ScreenshotBatchArchiver().archive(
                imageURLs: [first, second, third],
                captureRoot: captureRoot,
                archivedAt: Date(timeIntervalSince1970: 1_786_320_000)
            )
        )
        XCTAssertEqual(report.archivedImageCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", report.archiveURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testStoredAnalysisCanBeReusedWithoutAnotherNetworkSubmission() throws {
        let externalID = CapturedQuestionIdentity.stableExternalID(for: "历史人物的作用是什么？")
        let imported = try store.upsertQuestion(
            QuestionDraft(
                stableExternalID: externalID,
                stem: "历史人物的作用是什么？",
                type: .singleChoice,
                options: [
                    OptionDraft(originalLabel: "A", text: "决定历史方向", isCorrect: false),
                    OptionDraft(originalLabel: "B", text: "受规律制约并推动历史", isCorrect: true)
                ],
                explanation: "历史人物受社会发展客观规律制约。"
            )
        )
        let result = QuestionContentResult(
            subject: .politics,
            curriculumSection: PoliticalCurriculumTaxonomy.sections[0].name,
            curriculumChapter: PoliticalCurriculumTaxonomy.sections[0].chapters[0],
            questionType: "单选题",
            knowledgeCards: [StudyKnowledgeCard(title: "历史人物", memoryText: "历史人物受客观规律制约。")]
        )
        XCTAssertTrue(
            try store.recordAPIResponse(
                questionID: imported.questionID,
                inputHash: "legacy-existing-response",
                endpoint: "existing",
                model: "",
                result: result
            )
        )

        let stored = try XCTUnwrap(store.storedAnalysis(externalID: externalID))
        XCTAssertEqual(stored.questionID, imported.questionID)
        XCTAssertEqual(stored.result, result)
    }

    func testPoliticalEssayUsesTypedAnswerAndPersistsAPIGrade() throws {
        let reference = """
        （1）历史人物的出现有历史必然性。（4分）
        （2）历史人物的作用受社会发展客观规律制约。（4分）
        （3）社会发展趋势提供舞台，具体人物表现具有偶然性。（2分）
        """
        _ = try store.upsertQuestion(
            QuestionDraft(
                stableExternalID: "politics-essay-1",
                stem: "说明历史人物出现的必然性和偶然性。",
                type: .essay,
                options: [],
                explanation: reference,
                curriculumSection: PoliticalCurriculumTaxonomy.sections[0].name,
                curriculumChapter: PoliticalCurriculumTaxonomy.sections[0].chapters[0]
            )
        )
        let session = try store.startSession(mode: .normal, seed: 81)
        let item = try XCTUnwrap(session.currentItem)
        XCTAssertTrue(item.requiresTypedAnswer)
        XCTAssertTrue(item.options.isEmpty)

        let evaluation = EssayGradingResult(
            score: 8,
            maximumScore: 10,
            passed: true,
            gradingBasisFound: true,
            criteria: [
                EssayCriterionGrade(title: "历史必然性", passed: true, awardedScore: 4, maximumScore: 4, comment: "准确说明了社会任务对人物的需要。"),
                EssayCriterionGrade(title: "客观规律制约", passed: true, awardedScore: 3, maximumScore: 4, comment: "说明了规律制约，但论证略简。"),
                EssayCriterionGrade(title: "必然与偶然统一", passed: false, awardedScore: 1, maximumScore: 2, comment: "提到偶然性，但关系表述不完整。")
            ],
            summary: "主要原理正确，部分关系需要补充。"
        )
        let submitted = try store.submit(
            SubmitAnswerRequest(
                sessionID: session.id,
                itemID: item.itemID,
                selectedOptionIDs: [],
                typedAnswer: "历史人物由时代任务产生，也受客观规律制约，具体人物具有偶然性。",
                essayEvaluation: evaluation
            )
        )
        XCTAssertTrue(submitted.isCorrect)
        XCTAssertEqual(submitted.essayEvaluation?.score, 8)
        XCTAssertEqual(submitted.essayEvaluation?.maximumScore, 10)
        XCTAssertFalse(submitted.isInWrongBook)
    }

    func testEssayGradingUsesOriginalFourFourTwoWeightsAndHighThinkingMode() throws {
        let input = EssayGradingInput(
            question: "说明历史人物出现的必然性和偶然性。",
            referenceExplanation: "（1）历史必然性。（4分）（2）客观规律制约。（4分）（3）必然与偶然统一。（2分）",
            answer: "时代需要历史人物，但个人表现具有偶然性。"
        )
        let body = try EssayGradingService.requestBody(input: input, model: "deepseek-v4-flash")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((object["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(object["reasoning_effort"] as? String, "high")

        let response = """
        {"score":8,"maximum_score":10,"passed":true,"grading_basis_found":true,"criteria":[
          {"title":"历史必然性","passed":true,"awarded_score":4,"maximum_score":4,"comment":"已准确说明。"},
          {"title":"客观规律制约","passed":true,"awarded_score":3,"maximum_score":4,"comment":"原理正确但不够完整。"},
          {"title":"必然与偶然统一","passed":false,"awarded_score":1,"maximum_score":2,"comment":"只提到偶然性。"}
        ],"summary":"总分8分，主要原理正确。"}
        """
        let decoded = try EssayGradingService.decodeAndValidate(
            Data(response.utf8),
            expectedMaximumScores: [4, 4, 2]
        )
        XCTAssertEqual(decoded.score, 8)
        XCTAssertEqual(decoded.maximumScore, 10)
        XCTAssertEqual(decoded.criteria.map(\.maximumScore), [4, 4, 2])
    }

    func testEssayGradingReadsEachQuestionsOwnWeightsInsteadOfFixedFourFourTwo() throws {
        let reference = """
        （1）准确说明第一个原理。（3分）
        （2）完整分析第二个原理。（7分）
        本题总分10分。
        """
        XCTAssertEqual(EssayGradingService.explicitScoreWeights(in: reference), [3, 7])
        XCTAssertEqual(EssayGradingService.explicitScoreWeights(in: "一、定义。（二分）\n二、意义。（八分）"), [2, 8])

        let wrongWeights = """
        {"score":8,"maximum_score":10,"passed":true,"grading_basis_found":true,"criteria":[
          {"title":"第一个原理","passed":true,"awarded_score":4,"maximum_score":4,"comment":"已说明。"},
          {"title":"第二个原理","passed":true,"awarded_score":4,"maximum_score":6,"comment":"已说明。"}
        ],"summary":"总分8分。"}
        """
        XCTAssertThrowsError(
            try EssayGradingService.decodeAndValidate(
                Data(wrongWeights.utf8),
                expectedMaximumScores: [3, 7]
            )
        )
    }

    func testEssayGradingRejectsResponseWithoutOriginalScoreBasis() throws {
        let response = """
        {"score":0,"maximum_score":0,"passed":false,"grading_basis_found":false,"criteria":[],"summary":"原解析没有明确分值。"}
        """
        XCTAssertThrowsError(try EssayGradingService.decodeAndValidate(Data(response.utf8))) { error in
            XCTAssertEqual(error as? EssayGradingServiceError, .missingGradingBasis)
        }
    }

    func testPoliticalEssayClassificationAcceptsNoChoiceQuestionAndLocalHint() throws {
        let question = """
        说明历史人物的出现为什么既有历史必然性又有偶然性，并分析其作用受到什么制约。
        """
        XCTAssertEqual(QuestionSubjectClassifier.classifyLocally(question: question), .politics)

        let response = """
        {"subject":"政治","curriculum_section":"第一部分、马克思主义哲学原理","curriculum_chapter":"历史观的基本问题和社会发展的基本规律","question_type":"论述题","knowledge_cards":[{"title":"历史人物的必然性与偶然性","memory_text":"社会历史发展具有客观规律，历史任务为人物活动提供舞台，具体人物及其表现又受偶然因素影响。","pitfalls":[]}],"resolved_answer":null,"resolved_explanation":null}
        """
        let decoded = try QuestionContentService.decodeAndValidate(Data(response.utf8))
        XCTAssertEqual(decoded.subject, .politics)
        XCTAssertEqual(decoded.questionType, "论述题")
    }

    func testDynamicPlanDailyTargetAndMixedScheduler() {
        XCTAssertEqual(DynamicStudyPlanScheduler.dailyTarget(workload: 0, daysRemaining: 10), 0)
        XCTAssertEqual(DynamicStudyPlanScheduler.dailyTarget(workload: 11, daysRemaining: 5), 3)
        XCTAssertEqual(DynamicStudyPlanScheduler.dailyTarget(workload: 4, daysRemaining: 0), 4)

        let arranged = DynamicStudyPlanScheduler.arrange(
            newQuestionIDs: ["new-1", "new-2", "new-3"],
            wrongQuestionRemaining: ["wrong-1": 3, "wrong-2": 2],
            wrongOccurrenceLimit: 4,
            seed: 20260809
        )
        XCTAssertEqual(arranged.count, 7)
        XCTAssertEqual(arranged.filter { $0.hasPrefix("new-") }.count, 3)
        XCTAssertEqual(arranged.filter { $0.hasPrefix("wrong-") }.count, 4)
        XCTAssertTrue(
            zip(arranged, arranged.dropFirst()).allSatisfy { pair in
                pair.0 != pair.1
            }
        )
    }

    func testDynamicPlanDistributesFirstPassAcrossInclusiveRemainingDays() throws {
        for number in 1...10 { try insertQuestion(number: number) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        let target = try XCTUnwrap(calendar.date(byAdding: .day, value: 4, to: now))
        try store.updateSettings(
            SettingsSnapshot(
                wrongRequiredConsecutiveCorrect: 3,
                dynamicPlanEnabled: true,
                dynamicPlanTargetDate: target
            )
        )

        var plan = try store.dynamicStudyPlan(now: now, calendar: calendar)
        XCTAssertEqual(plan.daysRemaining, 5)
        XCTAssertEqual(plan.todayFirstPassTarget, 2)
        XCTAssertEqual(plan.firstPassRemainingToday, 2)
        XCTAssertEqual(plan.todayWrongTarget, 0)

        let session = try store.startDynamicPlanSession(now: now, calendar: calendar, seed: 8)
        XCTAssertTrue(session.summary.isDynamicPlan)
        XCTAssertEqual(session.totalCount, 2)
        _ = try answer(session, correct: true, at: now.addingTimeInterval(60))

        plan = try store.dynamicStudyPlan(now: now.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(plan.todayFirstPassTarget, 2)
        XCTAssertEqual(plan.todayFirstPassCompleted, 1)
        XCTAssertEqual(plan.firstPassRemainingToday, 1)
    }

    func testDynamicPlanSchedulesThreeCorrectAnswersAndRemovesWrongQuestion() throws {
        try insertQuestion(number: 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        try store.updateSettings(
            SettingsSnapshot(
                wrongRequiredConsecutiveCorrect: 3,
                dynamicPlanEnabled: true,
                dynamicPlanTargetDate: now
            )
        )

        let firstPass = try store.startDynamicPlanSession(now: now, calendar: calendar, seed: 11)
        _ = try answer(firstPass, correct: false, at: now.addingTimeInterval(60))
        var plan = try store.dynamicStudyPlan(now: now.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(plan.unseenRemaining, 0)
        XCTAssertEqual(plan.wrongMasteryRemaining, 3)
        XCTAssertEqual(plan.wrongRemainingToday, 3)

        var correction = try store.startDynamicPlanSession(
            now: now.addingTimeInterval(180),
            calendar: calendar,
            seed: 12
        )
        XCTAssertEqual(correction.totalCount, 3)
        while !correction.isComplete {
            correction = try answer(
                correction,
                correct: true,
                at: now.addingTimeInterval(Double(240 + correction.currentIndex * 60))
            ).session
        }

        plan = try store.dynamicStudyPlan(now: now.addingTimeInterval(600), calendar: calendar)
        XCTAssertEqual(try store.wrongBookCount(), 0)
        XCTAssertEqual(plan.wrongMasteryRemaining, 0)
        XCTAssertTrue(plan.isFullyMastered)
        XCTAssertEqual(plan.totalRemainingToday, 0)
    }

    func testDynamicPlanRequiresThreeCorrectSetting() throws {
        XCTAssertThrowsError(
            try store.updateSettings(
                SettingsSnapshot(
                    wrongRequiredConsecutiveCorrect: 2,
                    dynamicPlanEnabled: true,
                    dynamicPlanTargetDate: Date()
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuestionBankError, .dynamicPlanRequiresThreeCorrect)
        }
    }

    func testEducationPlanPrioritizesMedicalAndPoliticsThenCapsEnglishFillAtThirty() throws {
        let stores = try makeEducationStores()
        try insertQuestions(count: 100, prefix: "m", into: stores[.medicalComprehensive]!)
        try insertQuestions(count: 80, prefix: "p", into: stores[.politics]!)
        try insertQuestions(count: 100, prefix: "e", into: stores[.english]!)
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        let coordinator = EducationDynamicPlanCoordinator(stores: stores)
        try coordinator.synchronizeConfiguration(
            enabled: true,
            targetDate: now.addingTimeInterval(30 * 86_400)
        )

        let plan = try coordinator.snapshot(now: now, calendar: utcCalendar())
        XCTAssertEqual(plan.firstPassTargetToday, 200)
        XCTAssertEqual(plan.allocations[.medicalComprehensive]?.firstPassTargetToday, 100)
        XCTAssertEqual(plan.allocations[.politics]?.firstPassTargetToday, 80)
        XCTAssertEqual(plan.allocations[.english]?.firstPassTargetToday, 20)
        XCTAssertLessThanOrEqual(
            (plan.allocations[.english]?.firstPassTargetToday ?? 0)
                + (plan.allocations[.english]?.reviewQuestionIDs.count ?? 0)
                + (plan.allocations[.english]?.correctionQuestionIDs.count ?? 0),
            30
        )
    }

    func testEducationPlanLeavesEnglishOutWhenPrimarySubjectsCanFillDailyPlan() throws {
        let stores = try makeEducationStores()
        try insertQuestions(count: 240, prefix: "m", into: stores[.medicalComprehensive]!)
        try insertQuestions(count: 160, prefix: "p", into: stores[.politics]!)
        try insertQuestions(count: 100, prefix: "e", into: stores[.english]!)
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        let coordinator = EducationDynamicPlanCoordinator(stores: stores)
        try coordinator.synchronizeConfiguration(
            enabled: true,
            targetDate: now.addingTimeInterval(30 * 86_400)
        )

        let plan = try coordinator.snapshot(now: now, calendar: utcCalendar())
        XCTAssertEqual(plan.firstPassTargetToday, 200)
        XCTAssertEqual(plan.allocations[.medicalComprehensive]?.firstPassTargetToday, 120)
        XCTAssertEqual(plan.allocations[.politics]?.firstPassTargetToday, 80)
        XCTAssertEqual(plan.allocations[.english]?.sessionAttemptCount, 0)
        XCTAssertEqual(plan.estimatedFutureWrongQuestions, 100)
        XCTAssertEqual(plan.reservedCorrectionDays, 1)
    }

    func testEducationPlanEnglishDailyCapIncludesCorrectionsAlreadyCompletedToday() throws {
        let stores = try makeEducationStores()
        let english = try XCTUnwrap(stores[.english])
        try insertQuestions(count: 101, prefix: "english-cap", into: english)
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        var first = try english.startSession(
            mode: .normal,
            limit: 1,
            now: now.addingTimeInterval(-86_400),
            seed: 17
        )
        let wrongQuestionID = try XCTUnwrap(first.currentItem?.questionID)
        first = try answer(
            first,
            in: english,
            correct: false,
            at: now.addingTimeInterval(-86_400)
        ).session
        XCTAssertTrue(first.isComplete)

        let coordinator = EducationDynamicPlanCoordinator(stores: stores)
        try coordinator.synchronizeConfiguration(enabled: true, targetDate: now.addingTimeInterval(30 * 86_400))
        var correction = try english.startEducationDynamicPlanSession(
            firstPassLimit: 0,
            reviewQuestionIDs: [],
            correctionQuestionIDs: [wrongQuestionID],
            now: now,
            calendar: utcCalendar(),
            seed: 18
        )
        while !correction.isComplete {
            correction = try answer(correction, in: english, correct: true, at: now).session
        }

        let plan = try coordinator.snapshot(now: now, calendar: utcCalendar())
        let englishPlan = try XCTUnwrap(plan.allocations[.english])
        XCTAssertEqual(englishPlan.correctionsCompletedToday, 1)
        XCTAssertEqual(
            englishPlan.firstPassTargetToday
                + englishPlan.reviewQuestionIDs.count
                + englishPlan.correctionQuestionIDs.count
                + englishPlan.correctionsCompletedToday,
            30
        )
    }

    func testEducationPlanReviewsFromDaySevenAndForcesCoverageBeforeDayFourteen() throws {
        let stores = try makeEducationStores()
        let medical = try XCTUnwrap(stores[.medicalComprehensive])
        try insertQuestions(count: 14, prefix: "review", into: medical)
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        var session = try medical.startSession(
            mode: .normal,
            limit: 14,
            now: now.addingTimeInterval(-7 * 86_400),
            seed: 7
        )
        while !session.isComplete {
            session = try answer(
                session,
                in: medical,
                correct: true,
                at: now.addingTimeInterval(-7 * 86_400)
            ).session
        }
        let coordinator = EducationDynamicPlanCoordinator(stores: stores)
        try coordinator.synchronizeConfiguration(enabled: true, targetDate: now.addingTimeInterval(30 * 86_400))

        var plan = try coordinator.snapshot(now: now, calendar: utcCalendar())
        XCTAssertEqual(plan.reviewTargetToday, 2)
        XCTAssertEqual(plan.allocations[.medicalComprehensive]?.reviewQuestionIDs.count, 2)

        plan = try coordinator.snapshot(
            now: now.addingTimeInterval(6 * 86_400),
            calendar: utcCalendar()
        )
        XCTAssertEqual(plan.reviewTargetToday, 14)
    }

    func testEducationPlanCarriesUnfinishedWrongCorrectionsAndCapsAtOneHundred() throws {
        let stores = try makeEducationStores()
        let medical = try XCTUnwrap(stores[.medicalComprehensive])
        try insertQuestions(count: 105, prefix: "wrong", into: medical)
        let now = Date(timeIntervalSince1970: 1_893_499_200)
        var session = try medical.startSession(
            mode: .normal,
            limit: 105,
            now: now.addingTimeInterval(-86_400),
            seed: 11
        )
        while !session.isComplete {
            session = try answer(
                session,
                in: medical,
                correct: false,
                at: now.addingTimeInterval(-86_400)
            ).session
        }
        let coordinator = EducationDynamicPlanCoordinator(stores: stores)
        try coordinator.synchronizeConfiguration(enabled: true, targetDate: now.addingTimeInterval(10 * 86_400))

        var plan = try coordinator.snapshot(now: now, calendar: utcCalendar())
        XCTAssertEqual(plan.correctionsTargetToday, 100)
        XCTAssertEqual(plan.allocations[.medicalComprehensive]?.correctionQuestionIDs.count, 100)
        XCTAssertEqual(plan.allocations[.medicalComprehensive]?.correctionAttemptCount, 300)

        plan = try coordinator.snapshot(now: now.addingTimeInterval(86_400), calendar: utcCalendar())
        XCTAssertEqual(plan.correctionsTargetToday, 100)
        XCTAssertEqual(plan.allocations[.medicalComprehensive]?.correctionQuestionIDs.count, 100)
    }

    func testCapturedRepeatIncrementsWrongCounterOnceWithoutActivatingWrongBook() throws {
        let inserted = try store.importCapturedQuestion(capturedQuestion(hash: "repeat-primary"))
        XCTAssertTrue(try store.recordCapturedQuestionRepeat(
            questionID: inserted.questionID,
            sourceImagePath: "/tmp/repeat-second.png",
            sourceImageHash: "repeat-second",
            capturedAt: Date(timeIntervalSince1970: 1_800_086_400)
        ))
        XCTAssertFalse(try store.recordCapturedQuestionRepeat(
            questionID: inserted.questionID,
            sourceImagePath: "/tmp/repeat-second.png",
            sourceImageHash: "repeat-second",
            capturedAt: Date(timeIntervalSince1970: 1_800_086_400)
        ))
        let row = try XCTUnwrap(store.workbookRows().first)
        XCTAssertEqual(row.wrongAttempts, 1)
        XCTAssertEqual(row.totalAttempts, 0)
        XCTAssertFalse(row.isInWrongBook)
    }

    func testNormalModeUsesUnseenThenDueAndDashboardDoesNotDoubleCountUnseen() throws {
        try insertQuestion(number: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var dashboard = try store.dashboard(now: now)
        XCTAssertEqual(dashboard.unseenCount, 1)
        XCTAssertEqual(dashboard.dueNormalCount, 0)

        let session = try store.startSession(mode: .normal, now: now, seed: 1)
        _ = try answer(session, correct: true, at: now)
        dashboard = try store.dashboard(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(dashboard.unseenCount, 0)
        XCTAssertEqual(dashboard.dueNormalCount, 0)
        XCTAssertThrowsError(try store.startSession(mode: .normal, now: now.addingTimeInterval(86_400))) { error in
            XCTAssertEqual(error as? QuestionBankError, .noEligibleQuestions(.normal))
        }

        dashboard = try store.dashboard(now: now.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(dashboard.dueNormalCount, 1)
        XCTAssertNoThrow(try store.startSession(mode: .normal, now: now.addingTimeInterval(8 * 86_400), seed: 2))
    }

    func testSessionAndShuffledOptionsResumeAfterStoreRestart() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        let session = try store.startSession(mode: .normal, seed: 99)
        let first = try XCTUnwrap(session.currentItem)
        let firstOrder = first.options.map(\.id)

        store = nil
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "restarted-tests")
        let resumed = try XCTUnwrap(store.currentSession(mode: .normal))
        XCTAssertEqual(resumed.id, session.id)
        XCTAssertEqual(resumed.currentItem?.itemID, first.itemID)
        XCTAssertEqual(resumed.currentItem?.options.map(\.id), firstOrder)

        _ = try answer(resumed, correct: true)
        store = nil
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "restarted-again")
        let progressed = try XCTUnwrap(store.currentSession(mode: .normal))
        XCTAssertEqual(progressed.currentIndex, 1)
        XCTAssertNotEqual(progressed.currentItem?.itemID, first.itemID)
    }

    func testWrongBookSchedulerCreatesThreePseudoChaoticOccurrencesWithDynamicSpacing() {
        let sizes = [1, 2, 3, 4, 5, 8, 16, 32, 64, 116]
        for uniqueCount in sizes {
            let questionIDs = (0..<uniqueCount).map { "question-\($0)" }
            for seed in 0..<8 {
                let arranged = WrongBookSessionScheduler.arrange(
                    questionIDs: questionIDs,
                    seed: UInt64(seed)
                )
                XCTAssertEqual(
                    arranged.count,
                    WrongBookSessionPolicy.expandedQuestionCount(uniqueQuestionCount: uniqueCount)
                )

                let positions = Dictionary(grouping: arranged.indices, by: { arranged[$0] })
                XCTAssertEqual(positions.count, uniqueCount)
                XCTAssertTrue(positions.values.allSatisfy {
                    $0.count == WrongBookSessionPolicy.repetitionsPerQuestion
                })

                if uniqueCount > 1 {
                    let minimumDistance = WrongBookSessionPolicy.targetMinimumPositionDistance(
                        uniqueQuestionCount: uniqueCount
                    )
                    let gaps = positions.values.flatMap { values in
                        zip(values, values.dropFirst()).map { current, next in next - current }
                    }
                    XCTAssertTrue(gaps.allSatisfy { $0 >= minimumDistance })
                    XCTAssertFalse(
                        zip(arranged, arranged.dropFirst()).contains { current, next in current == next }
                    )
                    if uniqueCount >= 3 {
                        XCTAssertGreaterThan(Set(gaps).count, 1)
                        let first = Array(arranged[0..<uniqueCount])
                        let second = Array(arranged[uniqueCount..<(uniqueCount * 2)])
                        let third = Array(arranged[(uniqueCount * 2)..<(uniqueCount * 3)])
                        XCTAssertFalse(first == second && second == third)
                    }
                }
            }
        }

        let ids = (0..<12).map { "stable-\($0)" }
        XCTAssertEqual(
            WrongBookSessionScheduler.arrange(questionIDs: ids, seed: 91),
            WrongBookSessionScheduler.arrange(questionIDs: ids, seed: 91)
        )
        XCTAssertNotEqual(
            WrongBookSessionScheduler.arrange(questionIDs: ids, seed: 91),
            WrongBookSessionScheduler.arrange(questionIDs: ids, seed: 92)
        )
    }

    func testWrongBookSessionExpandsSelectedQuestionsToThreeOccurrences() throws {
        for number in 1...6 { try insertQuestion(number: number) }
        var normal = try store.startSession(mode: .normal, seed: 61)
        while !normal.isComplete {
            normal = try answer(normal, correct: false).session
        }

        let dashboard = try store.dashboard()
        XCTAssertEqual(dashboard.wrongBookCount, 6)
        XCTAssertEqual(dashboard.wrongBookSessionQuestionCount, 18)

        let wrong = try store.startSession(mode: .wrongBook, limit: 4, seed: 62)
        XCTAssertEqual(wrong.totalCount, 12)
    }

    func testCivilServiceImporterLoadsAllFiveIndependentCategoryDatabases() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryRoot
            .appendingPathComponent(".build/civil-service-bank/questions.jsonl", isDirectory: false)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw XCTSkip("先运行 script/build_civil_service_bank.py 生成本地验收数据包")
        }
        let packageText = try String(contentsOf: packageURL, encoding: .utf8)
        XCTAssertFalse(packageText.contains("!["), "公务员题库不应再包含 Markdown 图片引用")
        XCTAssertFalse(packageText.contains("civil-asset://"), "公务员题库不应再包含本地图片资源引用")

        var importedTotal = 0
        for category in XingceCategory.allCases {
            let categoryDatabase = temporaryDirectory
                .appendingPathComponent("civil-service", isDirectory: true)
                .appendingPathComponent(category.rawValue, isDirectory: true)
                .appendingPathComponent("question-bank.sqlite3", isDirectory: false)
            let report = try CivilServiceQuestionBankImporter.installIfNeeded(
                category: category,
                packageURL: packageURL,
                databaseURL: categoryDatabase
            )
            XCTAssertEqual(report.total, category.bundledQuestionCount)
            XCTAssertEqual(report.inserted, category.bundledQuestionCount)

            let categoryStore = try QuestionBankStore(databaseURL: categoryDatabase, sourceApplication: "civil-test")
            let dashboard = try categoryStore.dashboard()
            XCTAssertEqual(dashboard.totalQuestions, category.bundledQuestionCount)
            XCTAssertEqual(dashboard.unseenCount, category.bundledQuestionCount)
            XCTAssertEqual(try categoryStore.questionCount(source: CivilServiceQuestionBankImporter.sourceIdentifier), category.bundledQuestionCount)
            let session = try categoryStore.startSession(mode: .normal, limit: 3, seed: 2026)
            XCTAssertEqual(session.totalCount, 3)
            XCTAssertFalse(try XCTUnwrap(session.currentItem).options.isEmpty)
            importedTotal += dashboard.totalQuestions
        }
        XCTAssertEqual(importedTotal, 3_596)
    }

    func testInactiveWrongQuestionsAreExcludedFromCountsAndSessions() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        var normal = try store.startSession(mode: .normal, seed: 71)
        while !normal.isComplete {
            normal = try answer(normal, correct: false).session
        }
        XCTAssertEqual(try store.wrongBookCount(), 2)

        store = nil
        do {
            let rawDatabase = try SQLiteDatabase(url: databaseURL)
            try rawDatabase.execute(
                "UPDATE questions SET active = 0 WHERE external_id = ?",
                [.text("question-1")]
            )
        }
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "inactive-filter-test")

        let dashboard = try store.dashboard()
        XCTAssertEqual(try store.wrongBookCount(), 1)
        XCTAssertEqual(dashboard.wrongBookCount, 1)
        XCTAssertEqual(dashboard.wrongBookSessionQuestionCount, 3)
        XCTAssertEqual(try store.startSession(mode: .wrongBook, seed: 72).totalCount, 3)
    }

    func testWrongModeUnavailableWhenEmptyAndThresholdRemovesQuestion() throws {
        try insertQuestion(number: 1)
        XCTAssertThrowsError(try store.startSession(mode: .wrongBook)) { error in
            XCTAssertEqual(error as? QuestionBankError, .noEligibleQuestions(.wrongBook))
        }

        let normal = try store.startSession(mode: .normal, seed: 3)
        let wrong = try answer(normal, correct: false)
        XCTAssertTrue(wrong.isInWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 1)

        try store.updateSettings(SettingsSnapshot(normalReviewIntervalDays: 7, wrongRequiredConsecutiveCorrect: 2))
        let correction1 = try store.startSession(mode: .wrongBook, seed: 4)
        let firstCorrect = try answer(correction1, correct: true)
        XCTAssertEqual(firstCorrect.wrongProgressAfter, 1)
        XCTAssertTrue(firstCorrect.isInWrongBook)

        let correction2 = try store.startSession(mode: .wrongBook, seed: 5)
        let secondCorrect = try answer(correction2, correct: true)
        XCTAssertEqual(secondCorrect.wrongProgressAfter, 2)
        XCTAssertTrue(secondCorrect.removedFromWrongBook)
        XCTAssertFalse(secondCorrect.isInWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)
    }

    func testWrongAnswerResetsConsecutiveCorrectProgress() throws {
        try insertQuestion(number: 1)
        try store.updateSettings(SettingsSnapshot(normalReviewIntervalDays: 7, wrongRequiredConsecutiveCorrect: 2))
        let normal = try store.startSession(mode: .normal, seed: 1)
        _ = try answer(normal, correct: false)

        let first = try store.startSession(mode: .wrongBook, seed: 2)
        XCTAssertEqual(try answer(first, correct: true).wrongProgressAfter, 1)

        let second = try store.startSession(mode: .wrongBook, seed: 3)
        let reset = try answer(second, correct: false)
        XCTAssertEqual(reset.wrongProgressBefore, 1)
        XCTAssertEqual(reset.wrongProgressAfter, 0)

        let third = try store.startSession(mode: .wrongBook, seed: 4)
        XCTAssertEqual(try answer(third, correct: true).wrongProgressAfter, 1)
        XCTAssertEqual(try store.wrongBookCount(), 1)
    }

    func testSubmissionTokenIsIdempotent() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        let session = try store.startSession(mode: .normal, seed: 8)
        let item = try XCTUnwrap(session.currentItem)
        let selected = try optionIDs(in: item, correct: false)
        let token = "fixed-submission-token"
        let request = SubmitAnswerRequest(
            sessionID: session.id,
            itemID: item.itemID,
            selectedOptionIDs: selected,
            submissionToken: token
        )
        let first = try store.submit(request)
        let retry = try store.submit(request)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.session.currentIndex, 1)
        XCTAssertEqual(try store.dashboard().answeredTodayCount, 1)
    }

    func testQuestionBookImportStaysOutOfWrongBookUntilActuallyAnsweredWrong() throws {
        try store.updateSettings(SettingsSnapshot(normalReviewIntervalDays: 7, wrongRequiredConsecutiveCorrect: 1))
        let first = capturedQuestion(hash: "image-hash-1")
        let inserted = try store.importCapturedQuestion(first)
        XCTAssertEqual(inserted.status, .inserted)
        XCTAssertFalse(inserted.addedToWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)

        let duplicate = try store.importCapturedQuestion(first)
        XCTAssertEqual(duplicate.status, .unchanged)
        XCTAssertFalse(duplicate.addedToWrongBook)

        let normal = try store.startSession(mode: .normal, seed: 8)
        _ = try answer(normal, correct: false)
        XCTAssertEqual(try store.wrongBookCount(), 1)

        let correction = try store.startSession(mode: .wrongBook, seed: 9)
        XCTAssertTrue(try answer(correction, correct: true).removedFromWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)

        let newEvent = try store.importCapturedQuestion(capturedQuestion(hash: "image-hash-2"))
        XCTAssertEqual(newEvent.status, .updated)
        XCTAssertFalse(newEvent.addedToWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)
    }

    func testThreeSubjectQuestionBooksKeepQuestionsAndWrongBooksIndependent() throws {
        let medicalStore = try QuestionBankStore(
            databaseURL: temporaryDirectory.appendingPathComponent("medical.sqlite3"),
            sourceApplication: "medical-test"
        )
        let politicsStore = try QuestionBankStore(
            databaseURL: temporaryDirectory.appendingPathComponent("politics.sqlite3"),
            sourceApplication: "politics-test"
        )
        let englishStore = try QuestionBankStore(
            databaseURL: temporaryDirectory.appendingPathComponent("english.sqlite3"),
            sourceApplication: "english-test"
        )

        for target in [medicalStore, politicsStore, englishStore] {
            _ = try target.upsertQuestion(
                QuestionDraft(
                    stableExternalID: "same-external-id",
                    stem: "三个科目可拥有相同标识的独立题目",
                    type: .singleChoice,
                    options: [
                        OptionDraft(originalLabel: "A", text: "错误", isCorrect: false),
                        OptionDraft(originalLabel: "B", text: "正确", isCorrect: true)
                    ],
                    explanation: "独立题本测试"
                )
            )
        }

        let medicalSession = try medicalStore.startSession(mode: .normal, seed: 201)
        let medicalItem = try XCTUnwrap(medicalSession.currentItem)
        let wrongOption = try XCTUnwrap(medicalItem.options.first { $0.originalLabel == "A" })
        _ = try medicalStore.submit(
            SubmitAnswerRequest(
                sessionID: medicalSession.id,
                itemID: medicalItem.itemID,
                selectedOptionIDs: [wrongOption.id]
            )
        )

        XCTAssertEqual(try medicalStore.dashboard().totalQuestions, 1)
        XCTAssertEqual(try politicsStore.dashboard().totalQuestions, 1)
        XCTAssertEqual(try englishStore.dashboard().totalQuestions, 1)
        XCTAssertEqual(try medicalStore.wrongBookCount(), 1)
        XCTAssertEqual(try politicsStore.wrongBookCount(), 0)
        XCTAssertEqual(try englishStore.wrongBookCount(), 0)
        XCTAssertEqual(StudySubject.medicalComprehensive.workbookFilename, "医学综合题本.xlsx")
        XCTAssertEqual(StudySubject.politics.workbookFilename, "政治题本.xlsx")
        XCTAssertEqual(StudySubject.english.workbookFilename, "英语题本.xlsx")

        let politicsWorkbook = temporaryDirectory.appendingPathComponent(StudySubject.politics.workbookFilename)
        _ = try politicsStore.exportWorkbook(to: politicsWorkbook)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", politicsWorkbook.path, "xl/worksheets/sheet2.xml"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let categoryXML = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(categoryXML.contains("第一部分、马克思主义哲学原理"))
        XCTAssertTrue(categoryXML.contains("第三部分、新时代中国特色社会主义思想概论"))
        XCTAssertTrue(categoryXML.contains("全面从严治党"))
        XCTAssertFalse(categoryXML.contains("第二部分、生理学"))
    }

    func testMigration3ClearsLegacyUnansweredCaptureWrongState() throws {
        let imported = try store.importCapturedQuestion(capturedQuestion(hash: "legacy-capture-hash"))
        store = nil

        var rawDatabase: SQLiteDatabase? = try SQLiteDatabase(url: databaseURL)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970
        try rawDatabase?.execute(
            """
            INSERT INTO question_state(question_id, is_wrong_book, added_to_wrong_at, updated_at)
            VALUES (?, 1, ?, ?)
            """,
            [.text(imported.questionID), .real(timestamp), .real(timestamp)]
        )
        try rawDatabase?.execute(
            """
            INSERT INTO change_log(source_app, entity_type, entity_id, action, created_at)
            VALUES ('capture', 'wrong_book', ?, 'capture_added', ?)
            """,
            [.text(imported.questionID), .real(timestamp)]
        )
        try rawDatabase?.execute("DELETE FROM schema_migrations WHERE version = 3")
        rawDatabase = nil

        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "migration-test")
        XCTAssertEqual(try store.wrongBookCount(), 0)

        store = nil
        rawDatabase = try SQLiteDatabase(url: databaseURL)
        XCTAssertEqual(
            try rawDatabase?.scalarInt("SELECT COUNT(*) FROM schema_migrations WHERE version = 3"),
            1
        )
        XCTAssertEqual(
            try rawDatabase?.scalarInt(
                "SELECT COUNT(*) FROM change_log WHERE action = 'cleared_auto_capture_wrong'"
            ),
            1
        )
        rawDatabase = nil
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "tests")
    }

    func testSameCaptureHashRefreshesCorrectedExplanationWithoutReaddingWrongBook() throws {
        let original = capturedQuestion(hash: "same-image-hash")
        XCTAssertEqual(try store.importCapturedQuestion(original).status, .inserted)

        let corrected = CapturedQuestionDraft(
            stableExternalID: original.stableExternalID,
            stem: original.stem,
            options: original.options,
            correctLabels: original.correctLabels,
            explanation: "修正后的截图解析",
            knowledgePoints: original.knowledgePoints,
            sourceImagePath: original.sourceImagePath,
            sourceImageHash: original.sourceImageHash,
            capturedAt: original.capturedAt
        )
        let refreshed = try store.importCapturedQuestion(corrected)
        XCTAssertEqual(refreshed.status, .updated)
        XCTAssertFalse(refreshed.addedToWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)

        let session = try store.startSession(mode: .normal, seed: 11)
        XCTAssertEqual(session.currentItem?.explanation, "修正后的截图解析")
    }

    func testSameCaptureHashRepairsStaleCaptureEventQuestionID() throws {
        let captured = capturedQuestion(hash: "stale-capture-event-hash")
        let original = try store.importCapturedQuestion(captured)
        store = nil

        var rawDatabase: SQLiteDatabase? = try SQLiteDatabase(url: databaseURL)
        try rawDatabase?.execute("PRAGMA foreign_keys = OFF")
        try rawDatabase?.execute(
            "UPDATE capture_events SET question_id = ? WHERE source_image_hash = ?",
            [.text("stale-question-id"), .text(captured.sourceImageHash)]
        )
        rawDatabase = nil

        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "stale-event-test")
        let refreshed = try store.importCapturedQuestion(captured)
        XCTAssertEqual(refreshed.questionID, original.questionID)
    }

    func testExplanationBoundaryStopsPageControlsAndOCRVariantsOnly() {
        XCTAssertTrue(ExplanationBoundary.isExactMarker("试题答疑"))
        XCTAssertTrue(ExplanationBoundary.shouldStop(
            at: "放题笔讥",
            previousContentLine: "正常解析。",
            isLastLine: true
        ))
        XCTAssertTrue(ExplanationBoundary.shouldStop(
            at: "口5",
            previousContentLine: "正常解析。",
            isLastLine: true
        ))
        XCTAssertTrue(ExplanationBoundary.shouldStop(
            at: "半旺处堅",
            previousContentLine: "正常解析。",
            isLastLine: true
        ))
        XCTAssertFalse(ExplanationBoundary.shouldStop(
            at: "血压升高",
            previousContentLine: "前一句。",
            isLastLine: true
        ))
    }

    func testQuestionTextCleanupRemovesRepeatedCaseSummary() {
        let duplicated = "女，46岁。进油腻食物后出现阵发性右上腹绞痛，向右肩背部放射1周，症状加重伴发热2小时就诊。1年前 曾诊断为胆石症，未治疗。i 女，46岁。进油腻食物后出现阵发性右上腹绞痛，向右肩背部放射1周，症状加重伴发热2小时就诊。1年前曾诊断为胆石症，未治疗。对该患者诊断最有意义的辅助检查是（）"
        let expected = "女，46岁。进油腻食物后出现阵发性右上腹绞痛，向右肩背部放射1周，症状加重伴发热2小时就诊。1年前曾诊断为胆石症，未治疗。对该患者诊断最有意义的辅助检查是（）"

        XCTAssertEqual(
            QuestionTextCleanup.removingRepeatedIntroductoryBlock(from: duplicated),
            expected
        )
    }

    func testQuestionTextCleanupRemovesRepeatedSingleLongCaseSentence() {
        let caseText = "男，26岁。右大腿和右小腿被烫伤，局部肿胀发红，伴有水疱，创面红润，疼痛明显"
        let duplicated = "\(caseText)。\(caseText)。该患者属于（）"

        XCTAssertEqual(
            QuestionTextCleanup.removingRepeatedIntroductoryBlock(from: duplicated),
            "\(caseText)。该患者属于（）"
        )
    }

    func testQuestionTextCleanupRemovesRecoveredOptionPrefixes() {
        XCTAssertEqual(
            QuestionTextCleanup.removingRecoveredOptionPrefix(from: "<D3级", expectedLabel: "D"),
            "3级"
        )
        XCTAssertEqual(
            QuestionTextCleanup.removingRecoveredOptionPrefix(from: "1B 前纵韧带", expectedLabel: "B"),
            "前纵韧带"
        )
        XCTAssertEqual(
            QuestionTextCleanup.removingRecoveredOptionPrefix(from: "乙B促甲状腺激素", expectedLabel: "B"),
            "促甲状腺激素"
        )
        XCTAssertEqual(
            QuestionTextCleanup.removingRecoveredOptionPrefix(from: "］ B 右侧腹股沟疝修补术", expectedLabel: "B"),
            "右侧腹股沟疝修补术"
        )
        XCTAssertEqual(
            QuestionTextCleanup.removingRecoveredOptionPrefix(from: "B超检查", expectedLabel: "B"),
            "B超检查"
        )
    }

    func testQuestionTextCleanupRemovesQuestionBankHeaderArtifacts() {
        XCTAssertEqual(
            QuestionTextCleanup.removingQuestionBankHeaderArtifacts(
                from: "Na+118mmol/L，心电图示T波低平。男，42岁。查血Na+118mmol/L，心电图示T波低平。患者水、钠代谢紊乱的类型是（）"
            ),
            "男，42岁。查血Na+118mmol/L，心电图示T波低平。患者水、钠代谢紊乱的类型是（）"
        )
        XCTAssertEqual(
            QuestionTextCleanup.removingQuestionBankHeaderArtifacts(
                from: "自多些胆处，不泊1。女，46岁。进油腻食物后右上腹痛。最可能出现的体征是（）"
            ),
            "女，46岁。进油腻食物后右上腹痛。最可能出现的体征是（）"
        )
    }

    func testWrongModeRequiresFiveWrongQuestionsWhileNormalQuestionsRemain() throws {
        for number in 1...6 { try insertQuestion(number: number) }

        for index in 1...4 {
            let normal = try store.startSession(mode: .normal, limit: 1, seed: UInt64(index))
            _ = try answer(normal, correct: false)
        }
        XCTAssertEqual(try store.dashboard().wrongBookCount, 4)
        XCTAssertThrowsError(try store.startSession(mode: .wrongBook, seed: 20)) { error in
            XCTAssertEqual(
                error as? QuestionBankError,
                .wrongModeLocked(unseenCount: 2, wrongCount: 4)
            )
        }

        let fifth = try store.startSession(mode: .normal, limit: 1, seed: 21)
        _ = try answer(fifth, correct: false)
        XCTAssertEqual(try store.dashboard().wrongBookCount, 5)
        XCTAssertNoThrow(try store.startSession(mode: .wrongBook, seed: 22))
    }

    func testWrongModeAllowsFewerThanFiveAfterAllNormalQuestionsAnswered() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        var normal = try store.startSession(mode: .normal, seed: 30)
        let first = try answer(normal, correct: false)
        normal = first.session
        _ = try answer(normal, correct: true)

        let dashboard = try store.dashboard()
        XCTAssertEqual(dashboard.unseenCount, 0)
        XCTAssertEqual(dashboard.wrongBookCount, 1)
        XCTAssertNoThrow(try store.startSession(mode: .wrongBook, seed: 31))
    }

    func testUnknownAnswerEntersWrongBookAndReturnsCorrectAnswer() throws {
        try insertQuestion(number: 1)
        let session = try store.startSession(mode: .normal, seed: 7)
        let item = try XCTUnwrap(session.currentItem)
        let correctOption = try XCTUnwrap(item.options.first { $0.originalLabel == "B" })
        let result = try store.submit(
            SubmitAnswerRequest(
                sessionID: session.id,
                itemID: item.itemID,
                selectedOptionIDs: [],
                markAsUnsure: true
            )
        )
        XCTAssertFalse(result.isCorrect)
        XCTAssertTrue(result.markedAsUnsure)
        XCTAssertTrue(result.isInWrongBook)
        XCTAssertEqual(result.wrongProgressAfter, 0)
        XCTAssertEqual(result.correctOptionIDs, [correctOption.id])
        XCTAssertEqual(result.explanation, "解析 1")
    }

    func testFinishingSessionLeavesUnansweredQuestionsEligible() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        let session = try store.startSession(mode: .normal, seed: 40)

        try store.finishSession(id: session.id)

        XCTAssertNil(try store.currentSession())
        XCTAssertTrue(try store.session(id: session.id).isComplete)
        XCTAssertEqual(try store.dashboard().unseenCount, 2)

        let next = try store.startSession(mode: .normal, seed: 41, resumeExisting: false)
        XCTAssertNotEqual(next.id, session.id)
        XCTAssertEqual(next.currentIndex, 0)
    }

    func testFinishingActiveSessionsClearsOrphanedRound() throws {
        try insertQuestion(number: 1)
        let session = try store.startSession(mode: .normal, seed: 42)

        try store.finishActiveSessions()

        XCTAssertNil(try store.currentSession())
        XCTAssertTrue(try store.session(id: session.id).isComplete)
    }

    func testTwoApplicationsCanRaceToMigrateTheSameNewDatabase() throws {
        store = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        var errors: [Error] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            do {
                let opened = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "app-\(index)")
                _ = try opened.settings()
            } catch {
                lock.lock()
                errors.append(error)
                lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "Concurrent migration errors: \(errors)")
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "tests")
    }

    func testMedicalCurriculumTaxonomyMatchesFixedFourPartOutline() {
        XCTAssertEqual(MedicalCurriculumTaxonomy.sections.count, 4)
        XCTAssertEqual(MedicalCurriculumTaxonomy.sections.map(\.chapters.count), [12, 12, 5, 10])
        XCTAssertTrue(MedicalCurriculumTaxonomy.contains(section: "第二部分、生理学", chapter: "血液循环"))
        XCTAssertFalse(MedicalCurriculumTaxonomy.contains(section: "第二部分、生理学", chapter: "外科休克"))
    }

    func testLocalSubjectClassifierUsesEnglishStemAndFixedEnglishSections() {
        XCTAssertEqual(
            QuestionSubjectClassifier.classifyLocally(
                question: "Choose the word that best completes the following sentence.",
                options: ["A. have", "B. has", "C. had", "D. having"]
            ),
            .english
        )
        XCTAssertEqual(
            QuestionSubjectClassifier.classifyLocally(
                question: "第三章 完形填空：根据短文内容选择最佳答案。",
                options: ["A. where", "B. when", "C. what", "D. which"]
            ),
            .english
        )
        XCTAssertEqual(
            EnglishCurriculumTaxonomy.sections,
            ["语音", "语法与词汇", "完形填空", "阅读理解", "对话", "写作"]
        )
    }

    func testLocalSubjectClassifierFocusesPoliticalAndMedicalChineseEvidence() {
        XCTAssertEqual(
            QuestionSubjectClassifier.classifyLocally(
                question: "马克思主义哲学认为，实践与认识的关系是（）。",
                options: ["A. 实践决定认识", "B. 认识决定实践", "C. 二者无关", "D. 实践否定认识"]
            ),
            .politics
        )
        XCTAssertEqual(
            QuestionSubjectClassifier.classifyLocally(
                question: "女性，46岁，进油腻食物后右上腹绞痛，既往有胆石症病史，最有意义的辅助检查是（）。",
                options: ["A. 腹部超声", "B. 心电图", "C. 脑电图", "D. 肺功能"]
            ),
            .medicalComprehensive
        )
        XCTAssertNil(
            QuestionSubjectClassifier.classifyLocally(
                question: "下列说法中正确的是（）。",
                options: ["A. 甲", "B. 乙", "C. 丙", "D. 丁"]
            )
        )
    }

    func testCombinedContentRequestUsesStrictThreeSubjectTaxonomies() throws {
        XCTAssertEqual(PoliticalCurriculumTaxonomy.sections.map(\.chapters.count), [6, 9, 18])
        let input = QuestionContentInput(
            stableID: "politics-1",
            question: "中国特色社会主义进入新时代的主要矛盾是（）。",
            options: ["A. 选项一", "B. 选项二"],
            knownAnswer: nil,
            existingExplanation: nil,
            requiresSolution: true,
            subjectHint: "政治"
        )
        let data = try QuestionContentService.makeRequestBody(input: input, model: "deepseek-v4-flash")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertTrue(system.contains("第三部分、新时代中国特色社会主义思想概论"))
        XCTAssertTrue(system.contains("语法与词汇"))

        let politics = """
        {"subject":"政治","curriculum_section":"第三部分、新时代中国特色社会主义思想概论","curriculum_chapter":"全面依法治国","question_type":"单选题","knowledge_cards":[{"title":"全面依法治国","memory_text":"全面依法治国是国家治理的一场深刻革命。","pitfalls":[]}],"resolved_answer":"A","resolved_explanation":"测试解析"}
        """
        let decodedPolitics = try QuestionContentService.decodeAndValidate(Data(politics.utf8))
        XCTAssertEqual(decodedPolitics.subject, .politics)
        XCTAssertEqual(decodedPolitics.curriculumChapter, "全面依法治国")

        let politicsWithoutPartPrefix = politics.replacingOccurrences(
            of: "第三部分、新时代中国特色社会主义思想概论",
            with: "新时代中国特色社会主义思想概论"
        )
        let normalizedPolitics = try QuestionContentService.decodeAndValidate(Data(politicsWithoutPartPrefix.utf8))
        XCTAssertEqual(normalizedPolitics.curriculumSection, "第三部分、新时代中国特色社会主义思想概论")

        let english = """
        {"subject":"英语","curriculum_section":"英语","curriculum_chapter":"阅读理解","question_type":"单选题","knowledge_cards":[{"title":"主旨题","memory_text":"Main-idea questions require identifying the central claim.","pitfalls":[]}],"resolved_answer":null,"resolved_explanation":null}
        """
        XCTAssertEqual(try QuestionContentService.decodeAndValidate(Data(english.utf8)).subject, .english)

        let invalid = politics.replacingOccurrences(of: "全面依法治国", with: "接口自创章节")
        XCTAssertThrowsError(try QuestionContentService.decodeAndValidate(Data(invalid.utf8))) { error in
            XCTAssertEqual(
                error as? QuestionContentServiceError,
                .invalidCategory(
                    subject: "政治",
                    section: "第三部分、新时代中国特色社会主义思想概论",
                    chapter: "接口自创章节"
                )
            )
        }
    }

    func testDeepSeekFlashRequestContainsTaxonomyAndStructuredOutputSettings() throws {
        let input = QuestionContentInput(
            stableID: "test-1",
            question: "维持细胞外液渗透压的主要离子是（）。",
            options: ["A. Na+", "B. K+", "C. Ca2+", "D. Mg2+"],
            knownAnswer: "A",
            existingExplanation: "钠离子是细胞外液主要阳离子。",
            requiresSolution: false
        )
        let data = try QuestionContentService.makeRequestBody(input: input, model: "deepseek-v4-flash")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual((object["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(object["reasoning_effort"] as? String, "high")
        XCTAssertNil(object["temperature"])
        XCTAssertEqual(object["max_tokens"] as? Int, 8_000)
        XCTAssertEqual((object["response_format"] as? [String: String])?["type"], "json_object")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let system = try XCTUnwrap(messages.first?["content"])
        for section in MedicalCurriculumTaxonomy.sections {
            XCTAssertTrue(system.contains(section.name))
        }

        let repairInput = QuestionContentInput(
            stableID: "repair-1",
            question: "测试题",
            options: ["A. 正确", "B. 错误"],
            knownAnswer: "A",
            existingExplanation: nil,
            requiresSolution: true,
            forceCompleteExplanation: true
        )
        let repairBody = try QuestionContentService.makeRequestBody(
            input: repairInput,
            model: "deepseek-v4-flash"
        )
        let repairObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: repairBody) as? [String: Any]
        )
        let repairMessages = try XCTUnwrap(repairObject["messages"] as? [[String: String]])
        XCTAssertTrue(repairMessages[0]["content"]?.contains("一次性解析修复") == true)
        XCTAssertTrue(repairMessages[1]["content"]?.contains("\"force_complete_explanation\":true") == true)
    }

    func testNormalContentInputHashRemainsCompatibleWhenRepairFlagIsFalse() throws {
        struct LegacyHashPayload: Codable {
            let question: String
            let options: [String]
            let knownAnswer: String?
            let existingExplanation: String?
            let requiresSolution: Bool
            let subjectHint: String?
        }
        let input = QuestionContentInput(
            stableID: "legacy-hash",
            question: "原有题目",
            options: ["A. 一", "B. 二"],
            knownAnswer: "A",
            existingExplanation: "原有解析",
            requiresSolution: false,
            subjectHint: "政治"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var legacyData = try encoder.encode(
            LegacyHashPayload(
                question: input.question,
                options: input.options,
                knownAnswer: input.knownAnswer,
                existingExplanation: input.existingExplanation,
                requiresSolution: input.requiresSolution,
                subjectHint: input.subjectHint
            )
        )
        legacyData.append(Data("|taxonomy:\(MedicalCurriculumTaxonomy.version)|knowledge-contract:4".utf8))
        let legacyHash = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(QuestionContentService.inputHash(input), legacyHash)

        var repairInput = input
        repairInput.forceCompleteExplanation = true
        XCTAssertNotEqual(QuestionContentService.inputHash(repairInput), legacyHash)
    }

    func testContentServiceDecodesChatResponseAndRejectsUnknownCategory() throws {
        let content = """
        {"medical_category":{"section":"第二部分、生理学","chapter":"血液循环"},"question_type":"单选题","knowledge_cards":[{"title":"心输出量","memory_text":"心输出量等于心率与每搏输出量的乘积。","pitfalls":["心指数需按体表面积校正。"]}],"resolved_answer":null,"resolved_explanation":null}
        """
        let wrapped: [String: Any] = ["choices": [["message": ["content": content]]]]
        let decoded = try QuestionContentService.decodeAndValidate(
            JSONSerialization.data(withJSONObject: wrapped)
        )
        XCTAssertEqual(decoded.medicalCategory.chapter, "血液循环")
        XCTAssertEqual(decoded.knowledgeCards.first?.title, "心输出量")

        let invalid = content.replacingOccurrences(of: "血液循环", with: "不存在的章节")
        XCTAssertThrowsError(try QuestionContentService.decodeAndValidate(Data(invalid.utf8))) { error in
            XCTAssertEqual(
                error as? QuestionContentServiceError,
                .invalidCategory(
                    subject: "医学综合",
                    section: "第二部分、生理学",
                    chapter: "不存在的章节"
                )
            )
        }
    }

    func testContentServiceRunsCompleteRequestResponsePipeline() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ContentServiceURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-key")
            let result = """
            {"medical_category":{"section":"第四部分、外科学（外科总论）","chapter":"外科感染"},"question_type":"单选题","knowledge_cards":[{"title":"外科感染","memory_text":"外科感染常需同时处理感染灶并合理使用抗菌药物。","pitfalls":[]}],"resolved_answer":"A","resolved_explanation":"基础测试解析。"}
            """
            let response = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": result]]]
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        defer { ContentServiceURLProtocol.handler = nil }

        let service = QuestionContentService(
            endpoint: URL(string: "https://local.test/chat/completions")!,
            accessKey: "test-access-key",
            model: "deepseek-v4-flash",
            timeout: 5,
            session: session
        )
        let result = try service.analyze(
            QuestionContentInput(
                stableID: "pipeline-test",
                question: "外科感染测试题",
                options: ["A. 正确", "B. 错误"],
                knownAnswer: nil,
                existingExplanation: nil,
                requiresSolution: true
            )
        )
        XCTAssertEqual(result.medicalCategory.chapter, "外科感染")
        XCTAssertEqual(result.resolvedAnswer, "A")
        XCTAssertEqual(result.resolvedExplanation, "基础测试解析。")
    }

    func testWorkbookRowsAndFileRefreshWrongAttemptCount() throws {
        _ = try store.upsertQuestion(
            QuestionDraft(
                stableExternalID: "workbook-question",
                stem: "工作簿测试题",
                type: .singleChoice,
                options: [
                    OptionDraft(originalLabel: "A", text: "错误", isCorrect: false),
                    OptionDraft(originalLabel: "B", text: "正确", isCorrect: true)
                ],
                explanation: "工作簿解析",
                knowledgePoints: ["工作簿知识点"],
                curriculumSection: "第二部分、生理学",
                curriculumChapter: "血液循环",
                contentAnalysisJSON: "{\"ok\":true}"
            )
        )
        let session = try store.startSession(mode: .normal, seed: 101)
        _ = try answer(session, correct: false)
        let output = temporaryDirectory.appendingPathComponent(QuestionBankPaths.workbookFilename)
        try store.configureWorkbookOutput(output)
        XCTAssertEqual(try store.exportWorkbook(), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let row = try XCTUnwrap(store.workbookRows().first { $0.externalID == "workbook-question" })
        XCTAssertEqual(row.wrongAttempts, 1)
        XCTAssertEqual(row.totalAttempts, 1)
        XCTAssertTrue(row.isInWrongBook)
        XCTAssertEqual(row.curriculumChapter, "血液循环")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", output.path, "xl/worksheets/sheet1.xml"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("累计答错次数"))
        XCTAssertTrue(xml.contains("工作簿测试题"))

        let workbookProcess = Process()
        let workbookPipe = Pipe()
        workbookProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        workbookProcess.arguments = ["-p", output.path, "xl/workbook.xml"]
        workbookProcess.standardOutput = workbookPipe
        try workbookProcess.run()
        workbookProcess.waitUntilExit()
        XCTAssertEqual(workbookProcess.terminationStatus, 0)
        let workbookXML = String(
            data: workbookPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(workbookXML.contains("name=\"题本\""))
        XCTAssertFalse(workbookXML.contains("name=\"题库\""))
    }

    func testAPIResponsesAreVersionedAndCurrentWrongKnowledgeTracksLiveWrongBook() throws {
        try insertQuestion(number: 1)
        let candidate = try XCTUnwrap(
            store.questionsMissingAPIResponse(
                subject: .medicalComprehensive,
                wrongBookOnly: false
            ).first
        )
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let first = QuestionContentResult(
            subject: .medicalComprehensive,
            curriculumSection: "第二部分、生理学",
            curriculumChapter: "血液循环",
            questionType: "单选题",
            knowledgeCards: [
                StudyKnowledgeCard(
                    title: "心输出量",
                    memoryText: "心输出量等于心率与每搏输出量的乘积。",
                    pitfalls: ["心指数需按体表面积校正。"]
                )
            ]
        )
        XCTAssertTrue(try store.recordAPIResponse(
            questionID: candidate.questionID,
            inputHash: "hash-v1",
            endpoint: "https://example.invalid/api",
            model: "test-model",
            result: first,
            receivedAt: earlier
        ))
        XCTAssertFalse(try store.recordAPIResponse(
            questionID: candidate.questionID,
            inputHash: "hash-v1",
            endpoint: "https://example.invalid/api",
            model: "test-model",
            result: first,
            receivedAt: earlier
        ))
        XCTAssertEqual(try store.questionsMissingAPIResponse(
            subject: .medicalComprehensive,
            wrongBookOnly: false
        ).count, 1)

        let later = earlier.addingTimeInterval(86_400)
        let updated = QuestionContentResult(
            subject: .medicalComprehensive,
            curriculumSection: "第二部分、生理学",
            curriculumChapter: "血液循环",
            questionType: "单选题",
            knowledgeCards: [
                StudyKnowledgeCard(
                    title: "心输出量的计算",
                    memoryText: "心输出量等于心率与每搏输出量的乘积，安静成人约为每分钟 5 升。",
                    pitfalls: ["心指数是心输出量除以体表面积。"]
                )
            ]
        )
        XCTAssertTrue(try store.recordAPIResponse(
            questionID: candidate.questionID,
            inputHash: QuestionContentService.inputHash(candidate.input),
            endpoint: "https://example.invalid/api",
            model: "test-model",
            result: updated,
            receivedAt: later
        ))
        XCTAssertTrue(try store.questionsMissingAPIResponse(
            subject: .medicalComprehensive,
            wrongBookOnly: false
        ).isEmpty)
        let latest = try XCTUnwrap(store.knowledgeRecords(
            subject: .medicalComprehensive,
            wrongBookOnly: false
        ).first)
        XCTAssertEqual(latest.knowledgeCards.first?.title, "心输出量的计算")
        XCTAssertEqual(try store.knowledgeRecords(
            subject: .medicalComprehensive,
            wrongBookOnly: false,
            receivedFrom: later,
            receivedBefore: later.addingTimeInterval(60)
        ).count, 1)

        var normal = try store.startSession(mode: .normal, seed: 700)
        normal = try answer(normal, correct: false).session
        XCTAssertTrue(normal.isComplete)
        var repeatWrong = try store.startSession(mode: .wrongBook, seed: 701)
        while !repeatWrong.isComplete {
            repeatWrong = try answer(repeatWrong, correct: false).session
        }
        let wrongRecord = try XCTUnwrap(store.knowledgeRecords(
            subject: .medicalComprehensive,
            wrongBookOnly: true
        ).first)
        XCTAssertEqual(wrongRecord.wrongAttempts, 4)
        let html = KnowledgeDocumentWriter.documentHTML(
            records: [wrongRecord, wrongRecord],
            kind: .currentWrong(updatedAt: later)
        )
        XCTAssertTrue(html.contains("high-frequency"))
        XCTAssertEqual(html.components(separatedBy: "<h5>心输出量的计算</h5>").count - 1, 1)
        XCTAssertTrue(html.contains("size: A4 portrait"))
        XCTAssertTrue(html.contains("font-size:10pt; line-height:1.15"))

        let output = ProcessInfo.processInfo.environment["KNOWLEDGE_DOC_QA_OUTPUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? temporaryDirectory.appendingPathComponent("当前错题知识点.docx")
        try KnowledgeDocumentWriter.write(
            records: [wrongRecord],
            kind: .currentWrong(updatedAt: later),
            to: output
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", output.path, "word/document.xml"]
        let documentXMLPipe = Pipe()
        unzip.standardOutput = documentXMLPipe
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let documentXML = String(
            data: documentXMLPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(documentXML.contains("<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"))
        XCTAssertTrue(documentXML.contains("w:top=\"850\" w:right=\"907\" w:bottom=\"850\" w:left=\"907\""))

        var correction = try store.startSession(mode: .wrongBook, seed: 702)
        while !correction.isComplete {
            correction = try answer(correction, correct: true).session
        }
        XCTAssertEqual(try store.wrongBookCount(), 0)
        XCTAssertTrue(try store.knowledgeRecords(
            subject: .medicalComprehensive,
            wrongBookOnly: true
        ).isEmpty)
    }

    private func insertQuestion(number: Int) throws {
        _ = try store.upsertQuestion(
            QuestionDraft(
                stableExternalID: "question-\(number)",
                stem: "测试题 \(number)",
                type: .singleChoice,
                options: [
                    OptionDraft(originalLabel: "A", text: "错误选项 \(number)", isCorrect: false),
                    OptionDraft(originalLabel: "B", text: "正确选项 \(number)", isCorrect: true),
                    OptionDraft(originalLabel: "C", text: "干扰选项 \(number)", isCorrect: false)
                ],
                explanation: "解析 \(number)",
                knowledgePoints: ["知识点 \(number)"]
            )
        )
    }

    private func makeEducationStores() throws -> [StudySubject: QuestionBankStore] {
        try Dictionary(uniqueKeysWithValues: StudySubject.allCases.map { subject in
            (
                subject,
                try QuestionBankStore(
                    databaseURL: temporaryDirectory.appendingPathComponent("\(subject.rawValue).sqlite3"),
                    sourceApplication: "education-plan-tests"
                )
            )
        })
    }

    private func insertQuestions(count: Int, prefix: String, into target: QuestionBankStore) throws {
        for number in 1...count {
            _ = try target.upsertQuestion(
                QuestionDraft(
                    stableExternalID: "\(prefix)-\(number)",
                    stem: "\(prefix) 测试题 \(number)",
                    type: .singleChoice,
                    options: [
                        OptionDraft(originalLabel: "A", text: "错误", isCorrect: false),
                        OptionDraft(originalLabel: "B", text: "正确", isCorrect: true)
                    ],
                    explanation: "解析"
                )
            )
        }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func capturedQuestion(hash: String) -> CapturedQuestionDraft {
        CapturedQuestionDraft(
            stableExternalID: "captured-question",
            stem: "截图题干",
            options: [
                CapturedQuestionOption(originalLabel: "A", text: "错误"),
                CapturedQuestionOption(originalLabel: "B", text: "正确")
            ],
            correctLabels: ["B"],
            explanation: "截图解析",
            knowledgePoints: ["截图知识点"],
            sourceImagePath: "/tmp/\(hash).png",
            sourceImageHash: hash,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func answer(
        _ session: PracticeSessionSnapshot,
        correct: Bool,
        markUnsure: Bool = false,
        at date: Date = Date()
    ) throws -> SubmissionResult {
        let item = try XCTUnwrap(session.currentItem)
        return try store.submit(
            SubmitAnswerRequest(
                sessionID: session.id,
                itemID: item.itemID,
                selectedOptionIDs: try optionIDs(in: item, correct: correct),
                markAsUnsure: markUnsure,
                submittedAt: date
            )
        )
    }

    private func answer(
        _ session: PracticeSessionSnapshot,
        in target: QuestionBankStore,
        correct: Bool,
        at date: Date
    ) throws -> SubmissionResult {
        let item = try XCTUnwrap(session.currentItem)
        return try target.submit(
            SubmitAnswerRequest(
                sessionID: session.id,
                itemID: item.itemID,
                selectedOptionIDs: try optionIDs(in: item, correct: correct),
                submittedAt: date
            )
        )
    }

    private func optionIDs(in item: PracticeQuestion, correct: Bool) throws -> Set<String> {
        let wantedLabel = correct ? "B" : "A"
        let option = try XCTUnwrap(item.options.first { $0.originalLabel == wantedLabel })
        return [option.id]
    }
}

private final class ContentServiceURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw NSError(domain: "ContentServiceURLProtocol", code: 1)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
