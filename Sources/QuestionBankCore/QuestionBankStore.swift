import Foundation

private struct SessionPayload: Codable {
    let stem: String
    let type: QuestionType
    let explanation: String
    let options: [PracticeOption]
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

public final class QuestionBankStore: @unchecked Sendable {
    public let databaseURL: URL
    public let sourceApplication: String

    private let queue = DispatchQueue(label: "com.guiming.medicalquestionbank.database")
    private let db: SQLiteDatabase

    public init(databaseURL: URL, sourceApplication: String = "question-bank") throws {
        self.databaseURL = databaseURL
        self.sourceApplication = sourceApplication
        db = try SQLiteDatabase(url: databaseURL)
        try QuestionBankSchema.migrate(db)
    }

    public convenience init(sourceApplication: String = "question-bank") throws {
        try self.init(databaseURL: QuestionBankPaths.defaultDatabaseURL(), sourceApplication: sourceApplication)
    }

    public func migrate() throws {
        try queue.sync { try QuestionBankSchema.migrate(db) }
    }

    public func settings() throws -> SettingsSnapshot {
        try queue.sync { try readSettings() }
    }

    public func updateSettings(_ settings: SettingsSnapshot) throws {
        guard settings.normalReviewIntervalDays >= 0 else {
            throw QuestionBankError.invalidSettings("复习间隔不能小于 0 天")
        }
        guard settings.wrongRequiredConsecutiveCorrect > 0 else {
            throw QuestionBankError.invalidSettings("错题移出次数必须大于 0")
        }
        if let count = settings.questionsPerSession, count <= 0 {
            throw QuestionBankError.invalidSettings("每轮题数必须大于 0，不限制时请使用 nil")
        }
        if settings.dynamicPlanEnabled, settings.dynamicPlanTargetDate == nil {
            throw QuestionBankError.invalidSettings("启用动态计划时必须选择目标结束日期")
        }
        if settings.dynamicPlanEnabled, settings.wrongRequiredConsecutiveCorrect != 3 {
            throw QuestionBankError.dynamicPlanRequiresThreeCorrect
        }
        try queue.sync {
            try db.transaction {
                try db.execute(
                    """
                    UPDATE settings SET normal_review_interval_days = ?,
                        wrong_required_consecutive_correct = ?, questions_per_session = ?,
                        dynamic_plan_enabled = ?, dynamic_plan_target_date = ?, updated_at = ? WHERE id = 1
                    """,
                    [
                        .integer(Int64(settings.normalReviewIntervalDays)),
                        .integer(Int64(settings.wrongRequiredConsecutiveCorrect)),
                        settings.questionsPerSession.map { .integer(Int64($0)) } ?? .null,
                        .integer(settings.dynamicPlanEnabled ? 1 : 0),
                        settings.dynamicPlanTargetDate.map { .real($0.timeIntervalSince1970) } ?? .null,
                        .real(Date().timeIntervalSince1970)
                    ]
                )
                try appendChange(entityType: "settings", entityID: "1", action: "updated")
            }
        }
        notifyChange()
    }

    public func configureWorkbookOutput(_ url: URL) throws {
        let normalized = url.standardizedFileURL.path
        try queue.sync {
            try db.execute(
                "UPDATE settings SET workbook_output_path = ?, updated_at = ? WHERE id = 1",
                [.text(normalized), .real(Date().timeIntervalSince1970)]
            )
        }
    }

    public func workbookRows() throws -> [QuestionWorkbookRow] {
        try queue.sync { try workbookRowsInsideQueue() }
    }

    public func storedAnalysis(externalID: String) throws -> StoredQuestionAnalysis? {
        try queue.sync {
            guard let row = try db.rows(
                """
                SELECT q.id AS question_id, r.input_hash, r.response_json, r.received_at
                FROM questions q
                JOIN question_api_responses r ON r.question_id = q.id
                WHERE q.external_id = ? AND q.active = 1
                ORDER BY r.received_at DESC, r.id DESC LIMIT 1
                """,
                [.text(externalID)]
            ).first,
            let questionID = row["question_id"]?.string,
            let inputHash = row["input_hash"]?.string,
            let json = row["response_json"]?.string,
            let data = json.data(using: .utf8),
            let result = try? JSONDecoder().decode(QuestionContentResult.self, from: data),
            !result.knowledgeCards.isEmpty,
            let receivedAt = row["received_at"]?.double
            else { return nil }
            return StoredQuestionAnalysis(
                questionID: questionID,
                inputHash: inputHash,
                result: result,
                receivedAt: Date(timeIntervalSince1970: receivedAt)
            )
        }
    }

    public func questionsMissingAPIResponse(
        subject: StudySubject,
        wrongBookOnly: Bool
    ) throws -> [QuestionAnalysisCandidate] {
        try queue.sync {
            var sql = """
            SELECT q.id, q.external_id, q.stem, q.explanation, q.response_type,
                   (
                       SELECT r.input_hash FROM question_api_responses r
                       WHERE r.question_id = q.id
                       ORDER BY r.received_at DESC, r.id DESC LIMIT 1
                   ) AS latest_input_hash,
                   (
                       SELECT r.response_json FROM question_api_responses r
                       WHERE r.question_id = q.id
                       ORDER BY r.received_at DESC, r.id DESC LIMIT 1
                   ) AS latest_response_json
            FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
            WHERE q.active = 1
            """
            if wrongBookOnly { sql += " AND COALESCE(s.is_wrong_book, 0) = 1" }
            sql += " ORDER BY q.created_at, q.id"
            return try db.rows(sql).compactMap { row in
                guard let questionID = row["id"]?.string,
                      let externalID = row["external_id"]?.string,
                      let stem = row["stem"]?.string
                else { return nil }
                let optionRows = try db.rows(
                    "SELECT original_label, text, is_correct FROM options WHERE question_id = ? AND active = 1 ORDER BY sort_order",
                    [.text(questionID)]
                )
                let options = optionRows.enumerated().map { index, option in
                    let label = option["original_label"]?.string ?? Self.optionLabel(index)
                    return "\(label). \(option["text"]?.string ?? "")"
                }
                let answer = optionRows.enumerated().compactMap { index, option -> String? in
                    guard option["is_correct"]?.int == 1 else { return nil }
                    return option["original_label"]?.string ?? Self.optionLabel(index)
                }.joined()
                let explanation = row["explanation"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isEssay = row["response_type"]?.string == "essay"
                let input = QuestionContentInput(
                    stableID: externalID,
                    question: stem,
                    options: options,
                    knownAnswer: answer.isEmpty ? nil : answer,
                    existingExplanation: explanation.isEmpty ? nil : explanation,
                    requiresSolution: isEssay ? explanation.isEmpty : (answer.isEmpty || explanation.isEmpty),
                    subjectHint: subject.displayName
                )
                if row["latest_input_hash"]?.string == QuestionContentService.inputHash(input),
                   let json = row["latest_response_json"]?.string,
                   let data = json.data(using: .utf8),
                   let result = try? JSONDecoder().decode(QuestionContentResult.self, from: data),
                   !result.knowledgeCards.isEmpty {
                    return nil
                }
                return QuestionAnalysisCandidate(
                    questionID: questionID,
                    input: input
                )
            }
        }
    }

    @discardableResult
    public func recordAPIResponse(
        questionID: String,
        inputHash: String,
        endpoint: String,
        model: String,
        result: QuestionContentResult,
        receivedAt: Date = Date()
    ) throws -> Bool {
        let responseData = try JSONEncoder().encode(result)
        guard let responseJSON = String(data: responseData, encoding: .utf8) else {
            throw QuestionBankError.database("无法编码题目分析 API 回复")
        }
        let changed = try queue.sync {
            try db.transaction {
                guard try db.scalarInt(
                    "SELECT COUNT(*) FROM questions WHERE id = ? AND active = 1",
                    [.text(questionID)]
                ) == 1 else { throw QuestionBankError.invalidQuestion("API 回复对应的题目不存在") }
                let timestamp = receivedAt.timeIntervalSince1970
                let before = try db.scalarInt(
                    "SELECT COUNT(*) FROM question_api_responses WHERE question_id = ? AND input_hash = ?",
                    [.text(questionID), .text(inputHash)]
                )
                if before == 0 {
                    try db.execute(
                        """
                        INSERT INTO question_api_responses(
                            id, question_id, input_hash, endpoint, model, response_json, received_at, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(UUID().uuidString), .text(questionID), .text(inputHash),
                            .text(endpoint), .text(model), .text(responseJSON),
                            .real(timestamp), .real(Date().timeIntervalSince1970)
                        ]
                    )
                }
                try db.execute(
                    """
                    UPDATE questions SET curriculum_section = ?, curriculum_chapter = ?,
                        content_analysis_json = ?, updated_at = ? WHERE id = ?
                    """,
                    [
                        .text(result.curriculumSection), .text(result.curriculumChapter),
                        .text(responseJSON), .real(Date().timeIntervalSince1970), .text(questionID)
                    ]
                )
                try db.execute("DELETE FROM question_knowledge_points WHERE question_id = ?", [.text(questionID)])
                for card in result.knowledgeCards {
                    let normalized = normalizeText(card.title)
                    guard !normalized.isEmpty else { continue }
                    let pointID = stableID(prefix: "kp", source: normalized)
                    try db.execute(
                        "INSERT OR IGNORE INTO knowledge_points(id, normalized_name, display_name, created_at) VALUES (?, ?, ?, ?)",
                        [.text(pointID), .text(normalized), .text(card.title), .real(Date().timeIntervalSince1970)]
                    )
                    try db.execute(
                        "INSERT OR IGNORE INTO question_knowledge_points(question_id, knowledge_point_id) VALUES (?, ?)",
                        [.text(questionID), .text(pointID)]
                    )
                }
                try appendChange(
                    entityType: "question_api_response",
                    entityID: questionID,
                    action: before == 0 ? "inserted" : "unchanged",
                    payload: "{\"inputHash\":\"\(inputHash)\"}"
                )
                return before == 0
            }
        }
        if changed { notifyChange() }
        return changed
    }

    public func knowledgeRecords(
        subject: StudySubject,
        wrongBookOnly: Bool,
        receivedFrom start: Date? = nil,
        receivedBefore end: Date? = nil
    ) throws -> [QuestionKnowledgeRecord] {
        try queue.sync {
            var sql = """
            SELECT q.id, r.response_json, r.received_at,
                   COALESCE(s.wrong_attempts, 0) AS wrong_attempts
            FROM questions q
            JOIN question_api_responses r ON r.question_id = q.id
            LEFT JOIN question_state s ON s.question_id = q.id
            WHERE q.active = 1
            """
            var bindings: [SQLiteValue] = []
            if wrongBookOnly { sql += " AND COALESCE(s.is_wrong_book, 0) = 1" }
            if let start {
                sql += " AND r.received_at >= ?"
                bindings.append(.real(start.timeIntervalSince1970))
            }
            if let end {
                sql += " AND r.received_at < ?"
                bindings.append(.real(end.timeIntervalSince1970))
            }
            sql += " ORDER BY q.id, r.received_at DESC, r.id DESC"
            var seen: Set<String> = []
            let decoder = JSONDecoder()
            return try db.rows(sql, bindings).compactMap { row in
                guard let questionID = row["id"]?.string,
                      seen.insert(questionID).inserted,
                      let json = row["response_json"]?.string,
                      let data = json.data(using: .utf8),
                      let result = try? decoder.decode(QuestionContentResult.self, from: data),
                      let received = row["received_at"]?.double
                else { return nil }
                return QuestionKnowledgeRecord(
                    questionID: questionID,
                    subject: result.subject,
                    curriculumSection: result.curriculumSection,
                    curriculumChapter: result.curriculumChapter,
                    knowledgeCards: result.knowledgeCards,
                    wrongAttempts: row["wrong_attempts"]?.int ?? 0,
                    responseReceivedAt: Date(timeIntervalSince1970: received)
                )
            }
        }
    }

    @discardableResult
    public func exportWorkbook(to explicitURL: URL? = nil) throws -> URL {
        let payload: ([QuestionWorkbookRow], String?) = try queue.sync {
            let path = try db.rows("SELECT workbook_output_path FROM settings WHERE id = 1")
                .first?["workbook_output_path"]?.string
            return (try workbookRowsInsideQueue(), path)
        }
        let destination: URL
        if let explicitURL {
            destination = explicitURL
        } else if let path = payload.1 {
            destination = URL(fileURLWithPath: path)
        } else {
            destination = try QuestionBankPaths.defaultWorkbookURL()
        }
        try QuestionWorkbookWriter.write(rows: payload.0, to: destination)
        return destination
    }

    @discardableResult
    public func upsertQuestion(_ draft: QuestionDraft) throws -> QuestionImportResult {
        try validate(draft)
        let result = try queue.sync {
            try db.transaction { try upsertQuestionInsideTransaction(draft) }
        }
        if result.status != .unchanged { notifyChange() }
        return result
    }

    public func upsertQuestions(_ drafts: [QuestionDraft]) throws -> [QuestionImportResult] {
        try drafts.forEach(validate)
        guard !drafts.isEmpty else { return [] }
        let results = try queue.sync {
            try db.transaction {
                try drafts.map(upsertQuestionInsideTransaction)
            }
        }
        if results.contains(where: { $0.status != .unchanged }) { notifyChange() }
        return results
    }

    @discardableResult
    public func importCapturedQuestion(_ captured: CapturedQuestionDraft) throws -> QuestionImportResult {
        let normalizedCorrect = Set(captured.correctLabels.map(normalizeLabel))
        let options = captured.options.map { option in
            OptionDraft(
                originalLabel: normalizeLabel(option.originalLabel),
                text: option.text,
                isCorrect: normalizedCorrect.contains(normalizeLabel(option.originalLabel))
            )
        }
        let type: QuestionType = captured.type
            ?? (normalizedCorrect.count > 1 ? .multipleChoice : .singleChoice)
        let draft = QuestionDraft(
            stableExternalID: captured.stableExternalID,
            stem: captured.stem,
            type: type,
            options: options,
            explanation: captured.explanation,
            knowledgePoints: captured.knowledgePoints,
            source: captured.source,
            sourceImagePath: captured.sourceImagePath,
            sourceImageHash: captured.sourceImageHash,
            capturedAt: captured.capturedAt,
            curriculumSection: captured.curriculumSection,
            curriculumChapter: captured.curriculumChapter,
            contentAnalysisJSON: captured.contentAnalysisJSON
        )
        try validate(draft)
        guard !captured.sourceImageHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("截图导入必须包含 sourceImageHash")
        }

        let result = try queue.sync {
            try db.transaction {
                if let existing = try db.rows(
                    "SELECT question_id FROM capture_events WHERE source_image_hash = ? LIMIT 1",
                    [.text(captured.sourceImageHash)]
                ).first, let questionID = existing["question_id"]?.string {
                    let refreshed = try upsertQuestionInsideTransaction(draft)
                    if questionID != refreshed.questionID {
                        try db.execute(
                            "UPDATE capture_events SET question_id = ? WHERE source_image_hash = ?",
                            [.text(refreshed.questionID), .text(captured.sourceImageHash)]
                        )
                    }
                    return QuestionImportResult(
                        questionID: refreshed.questionID,
                        status: refreshed.status,
                        addedToWrongBook: false
                    )
                }

                var imported = try upsertQuestionInsideTransaction(draft)
                let now = Date().timeIntervalSince1970
                try db.execute(
                    """
                    INSERT INTO capture_events(id, source_image_hash, question_id, source_image_path, captured_at, imported_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(UUID().uuidString), .text(captured.sourceImageHash), .text(imported.questionID),
                        .text(captured.sourceImagePath), .real(captured.capturedAt.timeIntervalSince1970), .real(now)
                    ]
                )
                if imported.status == .unchanged {
                    imported = QuestionImportResult(
                        questionID: imported.questionID,
                        status: .updated,
                        addedToWrongBook: false
                    )
                }
                return imported
            }
        }
        if result.status != .unchanged { notifyChange() }
        return result
    }

    /// Records a later, non-consecutive capture of a question already in the question book.
    /// The counter is idempotent per image hash and deliberately does not activate the wrong book.
    @discardableResult
    public func recordCapturedQuestionRepeat(
        questionID: String,
        sourceImagePath: String,
        sourceImageHash: String,
        capturedAt: Date
    ) throws -> Bool {
        guard !sourceImageHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("重复截图必须包含 sourceImageHash")
        }
        let changed = try queue.sync {
            try db.transaction {
                guard try db.scalarInt(
                    "SELECT COUNT(*) FROM questions WHERE id = ? AND active = 1",
                    [.text(questionID)]
                ) == 1 else {
                    throw QuestionBankError.invalidQuestion("重复截图对应的题目不存在")
                }
                guard try db.scalarInt(
                    "SELECT COUNT(*) FROM capture_events WHERE source_image_hash = ?",
                    [.text(sourceImageHash)]
                ) == 0 else { return false }

                let now = Date().timeIntervalSince1970
                try db.execute(
                    """
                    INSERT INTO capture_events(id, source_image_hash, question_id, source_image_path, captured_at, imported_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(UUID().uuidString), .text(sourceImageHash), .text(questionID),
                        .text(sourceImagePath), .real(capturedAt.timeIntervalSince1970), .real(now)
                    ]
                )
                try db.execute(
                    """
                    INSERT INTO question_state(question_id, wrong_attempts, updated_at)
                    VALUES (?, 1, ?)
                    ON CONFLICT(question_id) DO UPDATE SET
                        wrong_attempts = question_state.wrong_attempts + 1,
                        updated_at = excluded.updated_at
                    """,
                    [.text(questionID), .real(now)]
                )
                try appendChange(
                    entityType: "question",
                    entityID: questionID,
                    action: "captured_repeat",
                    payload: "{\"sourceImageHash\":\"\(sourceImageHash)\"}"
                )
                return true
            }
        }
        if changed { notifyChange() }
        return changed
    }

    public func markQuestionAsUnsure(questionID: String, at date: Date = Date()) throws {
        try queue.sync {
            try db.transaction {
                guard try db.scalarInt("SELECT COUNT(*) FROM questions WHERE id = ? AND active = 1", [.text(questionID)]) == 1 else {
                    throw QuestionBankError.invalidQuestion("题目不存在")
                }
                try ensureWrongBook(questionID: questionID, at: date, resetProgress: true)
                try appendChange(entityType: "wrong_book", entityID: questionID, action: "manually_added")
            }
        }
        notifyChange()
    }

    public func wrongBookCount() throws -> Int {
        try queue.sync {
            try db.scalarInt(
                """
                SELECT COUNT(*) FROM question_state s JOIN questions q ON q.id = s.question_id
                WHERE q.active = 1 AND s.is_wrong_book = 1
                """
            )
        }
    }

    public func questionCount(source: String) throws -> Int {
        try queue.sync {
            try db.scalarInt(
                "SELECT COUNT(*) FROM questions WHERE active = 1 AND source = ?",
                [.text(source)]
            )
        }
    }

    public func dashboard(now: Date = Date(), calendar: Calendar = .current) throws -> DashboardSnapshot {
        try queue.sync {
            let settings = try readSettings()
            let cutoff = now.addingTimeInterval(-Double(settings.normalReviewIntervalDays) * 86_400).timeIntervalSince1970
            let startOfDay = calendar.startOfDay(for: now).timeIntervalSince1970
            let total = try db.scalarInt("SELECT COUNT(*) FROM questions WHERE active = 1")
            let unseen = try db.scalarInt(
                """
                SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                """
            )
            let due = try db.scalarInt(
                """
                SELECT COUNT(*) FROM questions q JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND s.total_attempts > 0 AND s.last_answered_at <= ?
                """,
                [.real(cutoff)]
            )
            let wrong = try db.scalarInt(
                """
                SELECT COUNT(*) FROM question_state s JOIN questions q ON q.id = s.question_id
                WHERE q.active = 1 AND s.is_wrong_book = 1
                """
            )
            let answeredToday = try db.scalarInt("SELECT COUNT(*) FROM attempts WHERE submitted_at >= ?", [.real(startOfDay)])
            let active = try activeSessionSummary()
            let dynamicPlan = try dynamicStudyPlanInsideQueue(now: now, calendar: calendar)
            return DashboardSnapshot(
                totalQuestions: total,
                unseenCount: unseen,
                dueNormalCount: due,
                wrongBookCount: wrong,
                answeredTodayCount: answeredToday,
                activeSession: active,
                dynamicPlan: dynamicPlan
            )
        }
    }

    public func dynamicStudyPlan(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DynamicStudyPlanSnapshot {
        try queue.sync { try dynamicStudyPlanInsideQueue(now: now, calendar: calendar) }
    }

    public func educationPlanMetrics(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> EducationPlanSubjectMetrics {
        try queue.sync {
            let startOfToday = calendar.startOfDay(for: now)
            let startTimestamp = startOfToday.timeIntervalSince1970
            let total = try db.scalarInt("SELECT COUNT(*) FROM questions WHERE active = 1")
            let unseen = try db.scalarInt(
                """
                SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                """
            )
            let firstPassCompletedToday = try db.scalarInt(
                """
                SELECT COUNT(*) FROM questions q
                JOIN (
                    SELECT question_id, MIN(submitted_at) AS first_answered_at
                    FROM attempts GROUP BY question_id
                ) first_attempt ON first_attempt.question_id = q.id
                WHERE q.active = 1 AND first_attempt.first_answered_at >= ?
                """,
                [.real(startTimestamp)]
            )
            let firstPassStats = try db.rows(
                """
                SELECT COUNT(*) AS attempt_count,
                    COALESCE(SUM(CASE WHEN a.is_correct = 0 OR a.marked_unsure = 1 THEN 1 ELSE 0 END), 0) AS wrong_count
                FROM attempts a JOIN questions q ON q.id = a.question_id
                WHERE q.active = 1 AND NOT EXISTS (
                    SELECT 1 FROM attempts earlier
                    WHERE earlier.question_id = a.question_id
                      AND (earlier.submitted_at < a.submitted_at
                        OR (earlier.submitted_at = a.submitted_at AND earlier.id < a.id))
                )
                """
            ).first
            let reviewCutoff = calendar.date(byAdding: .day, value: -7, to: now)
                ?? now.addingTimeInterval(-7 * 86_400)
            let reviewRows = try db.rows(
                """
                SELECT q.id, s.last_answered_at
                FROM questions q JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND s.total_attempts > 0
                  AND s.is_wrong_book = 0 AND s.last_answered_at <= ?
                ORDER BY s.last_answered_at, q.id
                """,
                [.real(reviewCutoff.timeIntervalSince1970)]
            )
            let reviewCandidates = reviewRows.compactMap { row -> EducationPlanReviewCandidate? in
                guard let questionID = row["id"]?.string,
                      let lastReviewedAt = row["last_answered_at"]?.double
                else { return nil }
                return EducationPlanReviewCandidate(
                    questionID: questionID,
                    lastReviewedAt: Date(timeIntervalSince1970: lastReviewedAt),
                    completedToday: false
                )
            }
            let completedReviewRows = try db.rows(
                """
                WITH reviews_today AS (
                    SELECT a.question_id, MIN(a.submitted_at) AS reviewed_at
                    FROM attempts a JOIN questions q ON q.id = a.question_id
                    WHERE q.active = 1 AND a.submitted_at >= ? AND a.was_in_wrong_book = 0
                      AND EXISTS (
                          SELECT 1 FROM attempts previous
                          WHERE previous.question_id = a.question_id
                            AND previous.submitted_at < a.submitted_at
                      )
                    GROUP BY a.question_id
                )
                SELECT reviews_today.question_id,
                    (SELECT MAX(previous.submitted_at) FROM attempts previous
                     WHERE previous.question_id = reviews_today.question_id
                       AND previous.submitted_at < reviews_today.reviewed_at) AS last_reviewed_at
                FROM reviews_today
                WHERE last_reviewed_at <= ?
                """,
                [.real(startTimestamp), .real(reviewCutoff.timeIntervalSince1970)]
            )
            let reviewsCompletedToday = completedReviewRows.compactMap {
                row -> EducationPlanReviewCandidate? in
                guard let questionID = row["question_id"]?.string,
                      let lastReviewedAt = row["last_reviewed_at"]?.double
                else { return nil }
                return EducationPlanReviewCandidate(
                    questionID: questionID,
                    lastReviewedAt: Date(timeIntervalSince1970: lastReviewedAt),
                    completedToday: true
                )
            }
            let correctionRows = try db.rows(
                """
                SELECT q.id, s.consecutive_correct, s.added_to_wrong_at
                FROM questions q JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND s.is_wrong_book = 1
                  AND s.added_to_wrong_at IS NOT NULL AND s.added_to_wrong_at < ?
                ORDER BY s.added_to_wrong_at DESC, q.id
                """,
                [.real(startTimestamp)]
            )
            let correctionCandidates = correctionRows.compactMap { row -> EducationPlanCorrectionCandidate? in
                guard let questionID = row["id"]?.string,
                      let addedAt = row["added_to_wrong_at"]?.double
                else { return nil }
                return EducationPlanCorrectionCandidate(
                    questionID: questionID,
                    remainingCorrect: max(0, 3 - (row["consecutive_correct"]?.int ?? 0)),
                    addedToWrongBookAt: Date(timeIntervalSince1970: addedAt)
                )
            }
            let correctionsCompletedToday = try db.scalarInt(
                """
                SELECT COUNT(DISTINCT a.question_id)
                FROM attempts a JOIN questions q ON q.id = a.question_id
                WHERE q.active = 1 AND a.submitted_at >= ? AND a.removed_from_wrong_book = 1
                """,
                [.real(startTimestamp)]
            )
            let currentWrong = try db.scalarInt(
                """
                SELECT COUNT(*) FROM question_state s JOIN questions q ON q.id = s.question_id
                WHERE q.active = 1 AND s.is_wrong_book = 1
                """
            )
            return EducationPlanSubjectMetrics(
                totalQuestions: total,
                unseenQuestions: unseen,
                firstPassCompletedToday: firstPassCompletedToday,
                reviewCandidates: reviewCandidates,
                reviewsCompletedToday: reviewsCompletedToday,
                correctionCandidates: correctionCandidates,
                correctionsCompletedToday: correctionsCompletedToday,
                currentWrongQuestions: currentWrong,
                firstPassAttemptCount: firstPassStats?["attempt_count"]?.int ?? 0,
                firstPassWrongCount: firstPassStats?["wrong_count"]?.int ?? 0
            )
        }
    }

    public func startSession(
        mode: PracticeMode,
        limit: Int? = nil,
        now: Date = Date(),
        seed: UInt64? = nil,
        resumeExisting: Bool = true
    ) throws -> PracticeSessionSnapshot {
        let result = try queue.sync {
            try db.transaction {
                if resumeExisting, let row = try db.rows(
                    "SELECT id FROM practice_sessions WHERE mode = ? AND status = 'active' ORDER BY updated_at DESC LIMIT 1",
                    [.text(mode.rawValue)]
                ).first, let id = row["id"]?.string {
                    return try sessionSnapshot(id: id)
                }

                if mode == .wrongBook {
                    let unseen = try db.scalarInt(
                        """
                        SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                        """
                    )
                    let wrong = try db.scalarInt(
                        """
                        SELECT COUNT(*) FROM question_state s JOIN questions q ON q.id = s.question_id
                        WHERE q.active = 1 AND s.is_wrong_book = 1
                        """
                    )
                    if wrong == 0 {
                        throw QuestionBankError.noEligibleQuestions(.wrongBook)
                    }
                    if unseen > 0, wrong < 5 {
                        throw QuestionBankError.wrongModeLocked(unseenCount: unseen, wrongCount: wrong)
                    }
                }

                let settings = try readSettings()
                let requestedLimit = limit ?? settings.questionsPerSession
                if let requestedLimit, requestedLimit <= 0 {
                    throw QuestionBankError.invalidSettings("每轮题数必须大于 0")
                }
                let candidateRows: [SQLiteRow]
                switch mode {
                case .normal:
                    let cutoff = now.addingTimeInterval(-Double(settings.normalReviewIntervalDays) * 86_400).timeIntervalSince1970
                    candidateRows = try db.rows(
                        """
                        SELECT q.id FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND (s.last_answered_at IS NULL OR s.last_answered_at <= ?)
                        ORDER BY q.id
                        """,
                        [.real(cutoff)]
                    )
                case .wrongBook:
                    candidateRows = try db.rows(
                        """
                        SELECT q.id FROM questions q JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND s.is_wrong_book = 1 ORDER BY q.id
                        """
                    )
                }
                var questionIDs = candidateRows.compactMap { $0["id"]?.string }
                guard !questionIDs.isEmpty else { throw QuestionBankError.noEligibleQuestions(mode) }

                let actualSeed = seed ?? UInt64.random(in: UInt64.min...UInt64.max)
                var generator = SeededRandomNumberGenerator(seed: actualSeed)
                questionIDs.shuffle(using: &generator)
                if let requestedLimit { questionIDs = Array(questionIDs.prefix(requestedLimit)) }
                if mode == .wrongBook {
                    questionIDs = WrongBookSessionScheduler.arrange(
                        questionIDs: questionIDs,
                        seed: actualSeed ^ 0xD1B54A32D192ED03
                    )
                }

                return try createSessionInsideTransaction(
                    mode: mode,
                    questionIDs: questionIDs,
                    planDateKey: nil,
                    now: now,
                    seed: actualSeed,
                    generator: &generator
                )
            }
        }
        notifyChange()
        return result
    }

    public func startDynamicPlanSession(
        now: Date = Date(),
        calendar: Calendar = .current,
        seed: UInt64? = nil
    ) throws -> PracticeSessionSnapshot {
        let result = try queue.sync {
            try db.transaction {
                let settings = try readSettings()
                guard settings.dynamicPlanEnabled, settings.dynamicPlanTargetDate != nil else {
                    throw QuestionBankError.dynamicPlanNotConfigured
                }
                guard settings.wrongRequiredConsecutiveCorrect == 3 else {
                    throw QuestionBankError.dynamicPlanRequiresThreeCorrect
                }
                let plan = try dynamicStudyPlanInsideQueue(now: now, calendar: calendar)
                guard plan.totalRemainingToday > 0 else {
                    throw QuestionBankError.noDynamicPlanTasksToday
                }

                let unseenRows = try db.rows(
                    """
                    SELECT q.id FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                    WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                    ORDER BY q.id
                    """
                )
                let wrongRows = try db.rows(
                    """
                    SELECT q.id, s.consecutive_correct
                    FROM questions q JOIN question_state s ON s.question_id = q.id
                    WHERE q.active = 1 AND s.is_wrong_book = 1
                    ORDER BY q.id
                    """
                )
                let actualSeed = seed ?? UInt64.random(in: UInt64.min...UInt64.max)
                var generator = SeededRandomNumberGenerator(seed: actualSeed)
                var newQuestionIDs = unseenRows.compactMap { $0["id"]?.string }
                newQuestionIDs.shuffle(using: &generator)
                newQuestionIDs = Array(newQuestionIDs.prefix(plan.firstPassRemainingToday))

                let wrongPairs: [(String, Int)] = wrongRows.compactMap { row -> (String, Int)? in
                    guard let id = row["id"]?.string else { return nil }
                    let progress = row["consecutive_correct"]?.int ?? 0
                    return (id, max(0, settings.wrongRequiredConsecutiveCorrect - progress))
                }
                let wrongRemaining = Dictionary(uniqueKeysWithValues: wrongPairs)
                let questionIDs = DynamicStudyPlanScheduler.arrange(
                    newQuestionIDs: newQuestionIDs,
                    wrongQuestionRemaining: wrongRemaining,
                    wrongOccurrenceLimit: plan.wrongRemainingToday,
                    seed: actualSeed ^ 0xA24BAED4963EE407
                )
                guard !questionIDs.isEmpty else {
                    throw QuestionBankError.noDynamicPlanTasksToday
                }
                return try createSessionInsideTransaction(
                    mode: .normal,
                    questionIDs: questionIDs,
                    planDateKey: Self.planDateKey(for: now, calendar: calendar),
                    now: now,
                    seed: actualSeed,
                    generator: &generator
                )
            }
        }
        notifyChange()
        return result
    }

    public func startEducationDynamicPlanSession(
        firstPassLimit: Int,
        reviewQuestionIDs: [String],
        correctionQuestionIDs: [String],
        now: Date = Date(),
        calendar: Calendar = .current,
        seed: UInt64? = nil
    ) throws -> PracticeSessionSnapshot {
        let result = try queue.sync {
            try db.transaction {
                let settings = try readSettings()
                guard settings.dynamicPlanEnabled, settings.dynamicPlanTargetDate != nil else {
                    throw QuestionBankError.dynamicPlanNotConfigured
                }
                guard settings.wrongRequiredConsecutiveCorrect == 3 else {
                    throw QuestionBankError.dynamicPlanRequiresThreeCorrect
                }
                let unseenRows = try db.rows(
                    """
                    SELECT q.id FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                    WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                    ORDER BY q.id
                    """
                )
                let actualSeed = seed ?? UInt64.random(in: UInt64.min...UInt64.max)
                var generator = SeededRandomNumberGenerator(seed: actualSeed)
                var newQuestionIDs = unseenRows.compactMap { $0["id"]?.string }
                newQuestionIDs.shuffle(using: &generator)
                newQuestionIDs = Array(newQuestionIDs.prefix(max(0, firstPassLimit)))

                var normalQuestionIDs = newQuestionIDs
                if !reviewQuestionIDs.isEmpty {
                    let uniqueReviewIDs = Array(Set(reviewQuestionIDs)).sorted()
                    let placeholders = Array(repeating: "?", count: uniqueReviewIDs.count)
                        .joined(separator: ",")
                    let rows = try db.rows(
                        """
                        SELECT q.id FROM questions q JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND s.is_wrong_book = 0
                          AND q.id IN (\(placeholders))
                        """,
                        uniqueReviewIDs.map(SQLiteValue.text)
                    )
                    normalQuestionIDs.append(contentsOf: rows.compactMap { $0["id"]?.string })
                }
                normalQuestionIDs.shuffle(using: &generator)

                let uniqueCorrectionIDs = Array(Set(correctionQuestionIDs)).sorted()
                var wrongRemaining: [String: Int] = [:]
                if !uniqueCorrectionIDs.isEmpty {
                    let placeholders = Array(repeating: "?", count: uniqueCorrectionIDs.count)
                        .joined(separator: ",")
                    let rows = try db.rows(
                        """
                        SELECT q.id, s.consecutive_correct
                        FROM questions q JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND s.is_wrong_book = 1
                          AND q.id IN (\(placeholders))
                        """,
                        uniqueCorrectionIDs.map(SQLiteValue.text)
                    )
                    for row in rows {
                        guard let questionID = row["id"]?.string else { continue }
                        wrongRemaining[questionID] = max(
                            0,
                            3 - (row["consecutive_correct"]?.int ?? 0)
                        )
                    }
                }
                let correctionAttempts = wrongRemaining.values.reduce(0, +)
                let questionIDs = DynamicStudyPlanScheduler.arrange(
                    newQuestionIDs: normalQuestionIDs,
                    wrongQuestionRemaining: wrongRemaining,
                    wrongOccurrenceLimit: correctionAttempts,
                    seed: actualSeed ^ 0xA24BAED4963EE407
                )
                guard !questionIDs.isEmpty else {
                    throw QuestionBankError.noDynamicPlanTasksToday
                }
                return try createSessionInsideTransaction(
                    mode: .normal,
                    questionIDs: questionIDs,
                    planDateKey: Self.planDateKey(for: now, calendar: calendar),
                    now: now,
                    seed: actualSeed,
                    generator: &generator
                )
            }
        }
        notifyChange()
        return result
    }

    public func currentSession(mode: PracticeMode? = nil) throws -> PracticeSessionSnapshot? {
        try queue.sync {
            var sql = "SELECT id FROM practice_sessions WHERE status = 'active'"
            var bindings: [SQLiteValue] = []
            if let mode {
                sql += " AND mode = ?"
                bindings.append(.text(mode.rawValue))
            }
            sql += " ORDER BY updated_at DESC LIMIT 1"
            guard let id = try db.rows(sql, bindings).first?["id"]?.string else { return nil }
            return try sessionSnapshot(id: id)
        }
    }

    public func session(id: String) throws -> PracticeSessionSnapshot {
        try queue.sync { try sessionSnapshot(id: id) }
    }

    public func finishSession(id: String, at date: Date = Date()) throws {
        let changed = try queue.sync {
            try db.transaction {
                guard let row = try db.rows(
                    "SELECT status, current_index, total_items FROM practice_sessions WHERE id = ?",
                    [.text(id)]
                ).first else { throw QuestionBankError.sessionNotFound }
                guard row["status"]?.string == "active" else { return false }

                let timestamp = date.timeIntervalSince1970
                try db.execute(
                    "UPDATE practice_sessions SET status = 'completed', updated_at = ?, completed_at = ? WHERE id = ?",
                    [.real(timestamp), .real(timestamp), .text(id)]
                )
                let answered = row["current_index"]?.int ?? 0
                let total = row["total_items"]?.int ?? 0
                try appendChange(
                    entityType: "practice_session",
                    entityID: id,
                    action: "finished",
                    payload: "{\"answered\":\(answered),\"total\":\(total),\"reason\":\"left_practice\"}"
                )
                return true
            }
        }
        if changed { notifyChange() }
    }

    public func finishActiveSessions(at date: Date = Date()) throws {
        let changed = try queue.sync {
            try db.transaction {
                let rows = try db.rows(
                    "SELECT id, current_index, total_items FROM practice_sessions WHERE status = 'active'"
                )
                guard !rows.isEmpty else { return false }

                let timestamp = date.timeIntervalSince1970
                for row in rows {
                    guard let id = row["id"]?.string else { continue }
                    try db.execute(
                        "UPDATE practice_sessions SET status = 'completed', updated_at = ?, completed_at = ? WHERE id = ?",
                        [.real(timestamp), .real(timestamp), .text(id)]
                    )
                    let answered = row["current_index"]?.int ?? 0
                    let total = row["total_items"]?.int ?? 0
                    try appendChange(
                        entityType: "practice_session",
                        entityID: id,
                        action: "finished",
                        payload: "{\"answered\":\(answered),\"total\":\(total),\"reason\":\"new_session\"}"
                    )
                }
                return true
            }
        }
        if changed { notifyChange() }
    }

    public func submit(_ request: SubmitAnswerRequest) throws -> SubmissionResult {
        let outcome: (result: SubmissionResult, changed: Bool) = try queue.sync {
            try db.transaction {
                if let existing = try db.rows(
                    "SELECT session_id, session_item_id, result_json FROM attempts WHERE submission_token = ? LIMIT 1",
                    [.text(request.submissionToken)]
                ).first {
                    guard existing["session_id"]?.string == request.sessionID,
                          existing["session_item_id"]?.string == request.itemID else {
                        throw QuestionBankError.invalidSelection
                    }
                    guard let json = existing["result_json"]?.string else {
                        throw QuestionBankError.database("幂等记录缺少结果快照")
                    }
                    return (try decode(SubmissionResult.self, from: json), false)
                }

                guard let sessionRow = try db.rows(
                    "SELECT mode, status, current_index, total_items FROM practice_sessions WHERE id = ?",
                    [.text(request.sessionID)]
                ).first else { throw QuestionBankError.sessionNotFound }
                guard sessionRow["status"]?.string == "active" else { throw QuestionBankError.sessionCompleted }
                guard let itemRow = try db.rows(
                    """
                    SELECT id, question_id, position, question_snapshot_json, option_order_json,
                        correct_option_ids_json, answered_at
                    FROM session_items WHERE id = ? AND session_id = ?
                    """,
                    [.text(request.itemID), .text(request.sessionID)]
                ).first else { throw QuestionBankError.sessionItemNotFound }
                guard itemRow["answered_at"] == .null || itemRow["answered_at"] == nil else {
                    throw QuestionBankError.itemAlreadyAnswered
                }
                guard itemRow["position"]?.int == sessionRow["current_index"]?.int else {
                    throw QuestionBankError.itemIsNotCurrent
                }

                let payload = try decode(SessionPayload.self, from: itemRow["question_snapshot_json"]?.string ?? "")
                let allowedIDs = Set(payload.options.map(\.id))
                let correctIDs = Set(try decodeStringArray(itemRow["correct_option_ids_json"]?.string))
                let typedAnswer = request.typedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
                let isCorrect: Bool
                if payload.type == .essay {
                    guard request.selectedOptionIDs.isEmpty,
                          request.markAsUnsure || (typedAnswer?.isEmpty == false && request.essayEvaluation != nil)
                    else { throw QuestionBankError.invalidSelection }
                    isCorrect = !request.markAsUnsure && request.essayEvaluation?.passed == true
                } else {
                    let hasValidSelection = request.selectedOptionIDs.isSubset(of: allowedIDs)
                        && (!request.selectedOptionIDs.isEmpty || request.markAsUnsure)
                    guard hasValidSelection, typedAnswer == nil, request.essayEvaluation == nil else {
                        throw QuestionBankError.invalidSelection
                    }
                    isCorrect = request.selectedOptionIDs == correctIDs
                }
                let effectiveWrong = !isCorrect || request.markAsUnsure
                let questionID = itemRow["question_id"]?.string ?? ""
                let state = try stateRow(questionID: questionID)
                let wasWrong = state?["is_wrong_book"]?.int == 1
                let progressBefore = state?["consecutive_correct"]?.int ?? 0
                let required = try readSettings().wrongRequiredConsecutiveCorrect
                var isWrong = wasWrong
                var progressAfter = progressBefore
                var removed = false
                if effectiveWrong {
                    isWrong = true
                    progressAfter = 0
                } else if wasWrong {
                    progressAfter += 1
                    if progressAfter >= required {
                        isWrong = false
                        removed = true
                    }
                } else {
                    progressAfter = 0
                }

                let submittedAt = request.submittedAt.timeIntervalSince1970
                try db.execute(
                    """
                    INSERT INTO question_state(question_id, last_answered_at, total_attempts, correct_attempts,
                        wrong_attempts, is_wrong_book, consecutive_correct, added_to_wrong_at, removed_from_wrong_at, updated_at)
                    VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(question_id) DO UPDATE SET
                        last_answered_at = excluded.last_answered_at,
                        total_attempts = question_state.total_attempts + 1,
                        correct_attempts = question_state.correct_attempts + excluded.correct_attempts,
                        wrong_attempts = question_state.wrong_attempts + excluded.wrong_attempts,
                        is_wrong_book = excluded.is_wrong_book,
                        consecutive_correct = excluded.consecutive_correct,
                        added_to_wrong_at = CASE
                            WHEN excluded.is_wrong_book = 1 AND question_state.is_wrong_book = 0 THEN excluded.added_to_wrong_at
                            ELSE question_state.added_to_wrong_at END,
                        removed_from_wrong_at = CASE
                            WHEN excluded.is_wrong_book = 0 AND question_state.is_wrong_book = 1 THEN excluded.removed_from_wrong_at
                            ELSE question_state.removed_from_wrong_at END,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(questionID), .real(submittedAt), .integer(isCorrect ? 1 : 0),
                        .integer(effectiveWrong ? 1 : 0), .integer(isWrong ? 1 : 0),
                        .integer(Int64(progressAfter)), isWrong ? .real(submittedAt) : .null,
                        removed ? .real(submittedAt) : .null,
                        .real(submittedAt)
                    ]
                )

                let attemptID = UUID().uuidString
                let mode = PracticeMode(rawValue: sessionRow["mode"]?.string ?? "") ?? .normal
                let nextIndex = (sessionRow["current_index"]?.int ?? 0) + 1
                let total = sessionRow["total_items"]?.int ?? 0
                let complete = nextIndex >= total
                try db.execute(
                    """
                    UPDATE practice_sessions SET current_index = ?, status = ?, updated_at = ?, completed_at = ? WHERE id = ?
                    """,
                    [
                        .integer(Int64(nextIndex)), .text(complete ? "completed" : "active"), .real(submittedAt),
                        complete ? .real(submittedAt) : .null, .text(request.sessionID)
                    ]
                )
                let session = try sessionSnapshot(id: request.sessionID)
                let answer = SubmissionResult(
                    attemptID: attemptID,
                    isCorrect: isCorrect,
                    correctOptionIDs: correctIDs,
                    selectedOptionIDs: request.selectedOptionIDs,
                    typedAnswer: typedAnswer,
                    essayEvaluation: request.essayEvaluation,
                    explanation: payload.explanation,
                    markedAsUnsure: request.markAsUnsure,
                    isInWrongBook: isWrong,
                    wrongProgressBefore: progressBefore,
                    wrongProgressAfter: progressAfter,
                    removedFromWrongBook: removed,
                    session: session
                )
                try db.execute(
                    """
                    INSERT INTO attempts(id, submission_token, session_id, session_item_id, question_id, mode,
                        submitted_at, selected_option_ids_json, displayed_option_order_json, correct_option_ids_json,
                        is_correct, marked_unsure, was_in_wrong_book, is_in_wrong_book, wrong_progress_before,
                        wrong_progress_after, removed_from_wrong_book, explanation_snapshot, result_json,
                        typed_answer, essay_evaluation_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(attemptID), .text(request.submissionToken), .text(request.sessionID), .text(request.itemID),
                        .text(questionID), .text(mode.rawValue), .real(submittedAt),
                        .text(try request.selectedOptionIDs.sorted().encodedJSONString()),
                        .text(itemRow["option_order_json"]?.string ?? "[]"),
                        .text(try correctIDs.sorted().encodedJSONString()), .integer(isCorrect ? 1 : 0),
                        .integer(request.markAsUnsure ? 1 : 0), .integer(wasWrong ? 1 : 0),
                        .integer(isWrong ? 1 : 0), .integer(Int64(progressBefore)), .integer(Int64(progressAfter)),
                        .integer(removed ? 1 : 0), .text(payload.explanation), .text(try encode(answer)),
                        typedAnswer.map(SQLiteValue.text) ?? .null,
                        request.essayEvaluation.map { .text(try encode($0)) } ?? .null
                    ]
                )
                try db.execute(
                    "UPDATE session_items SET answered_at = ?, attempt_id = ? WHERE id = ?",
                    [.real(submittedAt), .text(attemptID), .text(request.itemID)]
                )
                try appendChange(entityType: "attempt", entityID: attemptID, action: "submitted", payload: "{\"questionID\":\"\(questionID)\"}")
                try appendChange(entityType: "wrong_book", entityID: questionID, action: isWrong ? "active" : "inactive")
                return (answer, true)
            }
        }
        if outcome.changed { notifyChange() }
        return outcome.result
    }

    public func changes(after sequence: Int64 = 0, limit: Int = 500) throws -> [ChangeLogEntry] {
        try queue.sync {
            try db.rows(
                """
                SELECT sequence, source_app, entity_type, entity_id, action, payload_json, created_at
                FROM change_log WHERE sequence > ? ORDER BY sequence LIMIT ?
                """,
                [.integer(sequence), .integer(Int64(max(1, limit)))]
            ).compactMap { row in
                guard let sequence = row["sequence"]?.int,
                      let source = row["source_app"]?.string,
                      let type = row["entity_type"]?.string,
                      let id = row["entity_id"]?.string,
                      let action = row["action"]?.string,
                      let created = row["created_at"]?.double else { return nil }
                return ChangeLogEntry(
                    sequence: Int64(sequence), sourceApplication: source, entityType: type,
                    entityID: id, action: action, payloadJSON: row["payload_json"]?.string,
                    createdAt: Date(timeIntervalSince1970: created)
                )
            }
        }
    }

    private func validate(_ draft: QuestionDraft) throws {
        guard !draft.stableExternalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("stableExternalID 不能为空")
        }
        guard !draft.stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("题干不能为空")
        }
        if draft.type == .essay {
            guard draft.options.isEmpty else { throw QuestionBankError.invalidQuestion("论述题不能包含选择项") }
            guard !draft.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuestionBankError.invalidQuestion("论述题必须包含参考答案或解析")
            }
            return
        }
        guard draft.options.count >= 2 else { throw QuestionBankError.invalidQuestion("客观题至少需要 2 个选项") }
        guard draft.options.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw QuestionBankError.invalidQuestion("选项内容不能为空")
        }
        let correctCount = draft.options.filter(\.isCorrect).count
        guard correctCount > 0 else { throw QuestionBankError.invalidQuestion("至少需要一个正确选项") }
        if draft.type == .singleChoice, correctCount != 1 {
            throw QuestionBankError.invalidQuestion("单选题必须且只能有一个正确选项")
        }
    }

    private func readSettings() throws -> SettingsSnapshot {
        guard let row = try db.rows("SELECT * FROM settings WHERE id = 1").first else {
            throw QuestionBankError.database("设置记录不存在")
        }
        return SettingsSnapshot(
            normalReviewIntervalDays: row["normal_review_interval_days"]?.int ?? 7,
            wrongRequiredConsecutiveCorrect: row["wrong_required_consecutive_correct"]?.int ?? 3,
            questionsPerSession: row["questions_per_session"]?.int,
            dynamicPlanEnabled: row["dynamic_plan_enabled"]?.int == 1,
            dynamicPlanTargetDate: row["dynamic_plan_target_date"]?.double.map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }

    private func upsertQuestionInsideTransaction(_ draft: QuestionDraft) throws -> QuestionImportResult {
        let now = Date().timeIntervalSince1970
        let existing = try db.rows("SELECT * FROM questions WHERE external_id = ? LIMIT 1", [.text(draft.stableExternalID)]).first
        let questionID = existing?["id"]?.string ?? draft.id ?? UUID().uuidString
        let oldOptions = try db.rows(
            "SELECT id, original_label, text, is_correct, sort_order FROM options WHERE question_id = ? AND active = 1 ORDER BY sort_order",
            [.text(questionID)]
        )
        let storedQuestionType = draft.type == .essay ? QuestionType.singleChoice.rawValue : draft.type.rawValue
        let responseType = draft.type == .essay ? "essay" : "choice"
        let sameQuestion = existing?["stem"]?.string == draft.stem &&
            existing?["question_type"]?.string == storedQuestionType &&
            existing?["response_type"]?.string == responseType &&
            existing?["explanation"]?.string == draft.explanation &&
            existing?["source"]?.string == draft.source &&
            existing?["source_image_path"]?.string == draft.sourceImagePath &&
            existing?["source_image_hash"]?.string == draft.sourceImageHash &&
            existing?["curriculum_section"]?.string == draft.curriculumSection &&
            existing?["curriculum_chapter"]?.string == draft.curriculumChapter &&
            existing?["content_analysis_json"]?.string == draft.contentAnalysisJSON &&
            oldOptions.count == draft.options.count && zip(oldOptions, draft.options.enumerated()).allSatisfy { row, pair in
                let (index, option) = pair
                return row["original_label"]?.string == option.originalLabel && row["text"]?.string == option.text &&
                    row["is_correct"]?.int == (option.isCorrect ? 1 : 0) && row["sort_order"]?.int == index
            }
        let status: QuestionImportStatus = existing == nil ? .inserted : (sameQuestion ? .unchanged : .updated)

        try db.execute(
            """
            INSERT INTO questions(id, external_id, stem, question_type, response_type, explanation, source, source_image_path,
                source_image_hash, captured_at, curriculum_section, curriculum_chapter, content_analysis_json,
                active, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(external_id) DO UPDATE SET stem = excluded.stem, question_type = excluded.question_type,
                response_type = excluded.response_type,
                explanation = excluded.explanation, source = excluded.source, source_image_path = excluded.source_image_path,
                source_image_hash = excluded.source_image_hash, captured_at = excluded.captured_at, active = 1,
                curriculum_section = excluded.curriculum_section, curriculum_chapter = excluded.curriculum_chapter,
                content_analysis_json = excluded.content_analysis_json,
                updated_at = excluded.updated_at
            """,
            [
                .text(questionID), .text(draft.stableExternalID), .text(draft.stem), .text(storedQuestionType),
                .text(responseType), .text(draft.explanation), draft.source.map(SQLiteValue.text) ?? .null,
                draft.sourceImagePath.map(SQLiteValue.text) ?? .null,
                draft.sourceImageHash.map(SQLiteValue.text) ?? .null,
                draft.capturedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                draft.curriculumSection.map(SQLiteValue.text) ?? .null,
                draft.curriculumChapter.map(SQLiteValue.text) ?? .null,
                draft.contentAnalysisJSON.map(SQLiteValue.text) ?? .null,
                .real(now), .real(now)
            ]
        )
        try db.execute("UPDATE options SET active = 0, updated_at = ? WHERE question_id = ?", [.real(now), .text(questionID)])
        for (index, option) in draft.options.enumerated() {
            let optionID = option.id ?? stableID(prefix: "opt", source: "\(draft.stableExternalID)|\(option.originalLabel ?? "")|\(normalizeText(option.text))")
            try db.execute(
                """
                INSERT INTO options(id, question_id, original_label, text, is_correct, sort_order, active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET original_label = excluded.original_label, text = excluded.text,
                    is_correct = excluded.is_correct, sort_order = excluded.sort_order, active = 1, updated_at = excluded.updated_at
                """,
                [
                    .text(optionID), .text(questionID), option.originalLabel.map(SQLiteValue.text) ?? .null,
                    .text(option.text), .integer(option.isCorrect ? 1 : 0), .integer(Int64(index)), .real(now), .real(now)
                ]
            )
        }

        try db.execute("DELETE FROM question_knowledge_points WHERE question_id = ?", [.text(questionID)])
        for point in draft.knowledgePoints where !normalizeText(point).isEmpty {
            let normalized = normalizeText(point)
            let pointID = stableID(prefix: "kp", source: normalized)
            try db.execute(
                "INSERT OR IGNORE INTO knowledge_points(id, normalized_name, display_name, created_at) VALUES (?, ?, ?, ?)",
                [.text(pointID), .text(normalized), .text(point), .real(now)]
            )
            try db.execute(
                "INSERT OR IGNORE INTO question_knowledge_points(question_id, knowledge_point_id) VALUES (?, ?)",
                [.text(questionID), .text(pointID)]
            )
        }
        try appendChange(entityType: "question", entityID: questionID, action: status.rawValue)
        return QuestionImportResult(questionID: questionID, status: status, addedToWrongBook: false)
    }

    private func workbookRowsInsideQueue() throws -> [QuestionWorkbookRow] {
        let questionRows = try db.rows(
            """
            SELECT q.id, q.external_id, q.curriculum_section, q.curriculum_chapter, q.question_type, q.response_type,
                q.stem, q.explanation, q.content_analysis_json, q.source_image_path, q.updated_at,
                COALESCE(s.is_wrong_book, 0) AS is_wrong_book,
                COALESCE(s.wrong_attempts, 0) AS wrong_attempts,
                COALESCE(s.total_attempts, 0) AS total_attempts,
                COALESCE(s.consecutive_correct, 0) AS consecutive_correct,
                s.last_answered_at
            FROM questions q
            LEFT JOIN question_state s ON s.question_id = q.id
            WHERE q.active = 1
            ORDER BY COALESCE(q.captured_at, q.created_at), q.external_id
            """
        )
        return try questionRows.map { row in
            let questionID = row["id"]?.string ?? ""
            let optionRows = try db.rows(
                "SELECT original_label, text, is_correct FROM options WHERE question_id = ? AND active = 1 ORDER BY sort_order",
                [.text(questionID)]
            )
            let options = optionRows.map { $0["text"]?.string ?? "" }
            let answer = optionRows.enumerated().compactMap { index, option -> String? in
                guard option["is_correct"]?.int == 1 else { return nil }
                return option["original_label"]?.string ?? Self.optionLabel(index)
            }.joined()
            let points = try db.rows(
                """
                SELECT k.display_name FROM knowledge_points k
                JOIN question_knowledge_points qk ON qk.knowledge_point_id = k.id
                WHERE qk.question_id = ? ORDER BY k.display_name
                """,
                [.text(questionID)]
            ).compactMap { $0["display_name"]?.string }
            let contentResult = row["content_analysis_json"]?.string
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(QuestionContentResult.self, from: $0) }
            let rawType = row["question_type"]?.string ?? "single_choice"
            let displayType: String
            if row["response_type"]?.string == "essay" {
                displayType = "论述题"
            } else {
                displayType = rawType == QuestionType.multipleChoice.rawValue ? "多选题" : "单选题"
            }
            let updatedTimestamp = row["updated_at"]?.double ?? 0
            return QuestionWorkbookRow(
                questionID: questionID,
                externalID: row["external_id"]?.string ?? "",
                curriculumSection: row["curriculum_section"]?.string ?? "待分类",
                curriculumChapter: row["curriculum_chapter"]?.string ?? "待分类",
                questionType: displayType,
                stem: row["stem"]?.string ?? "",
                options: options,
                correctAnswer: displayType == "论述题" ? "按解析评分" : answer,
                explanation: row["explanation"]?.string ?? "",
                knowledgePoints: contentResult?.knowledgeCards.map(\.title) ?? points,
                memoryTexts: contentResult?.knowledgeCards.map(\.memoryText) ?? [],
                pitfalls: contentResult?.knowledgeCards.flatMap(\.pitfalls) ?? [],
                isInWrongBook: row["is_wrong_book"]?.int == 1,
                wrongAttempts: row["wrong_attempts"]?.int ?? 0,
                totalAttempts: row["total_attempts"]?.int ?? 0,
                consecutiveCorrect: row["consecutive_correct"]?.int ?? 0,
                lastAnsweredAt: row["last_answered_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                sourceImagePath: row["source_image_path"]?.string ?? "",
                updatedAt: Date(timeIntervalSince1970: updatedTimestamp)
            )
        }
    }

    private static func optionLabel(_ index: Int) -> String {
        guard (0..<26).contains(index), let scalar = UnicodeScalar(65 + index) else { return "?" }
        return String(Character(scalar))
    }

    private func dynamicStudyPlanInsideQueue(
        now: Date,
        calendar: Calendar
    ) throws -> DynamicStudyPlanSnapshot {
        let settings = try readSettings()
        let today = calendar.startOfDay(for: now)
        let startOfDay = today.timeIntervalSince1970
        let unseen = try db.scalarInt(
            """
            SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
            WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
            """
        )
        let firstPassCompletedToday = try db.scalarInt(
            """
            SELECT COUNT(*) FROM questions q
            JOIN (
                SELECT question_id, MIN(submitted_at) AS first_answered_at
                FROM attempts GROUP BY question_id
            ) first_attempt ON first_attempt.question_id = q.id
            WHERE q.active = 1 AND first_attempt.first_answered_at >= ?
            """,
            [.real(startOfDay)]
        )
        let required = settings.wrongRequiredConsecutiveCorrect
        let wrongMasteryRemaining = try db.scalarInt(
            """
            SELECT COALESCE(SUM(
                CASE WHEN ? > s.consecutive_correct THEN ? - s.consecutive_correct ELSE 0 END
            ), 0)
            FROM question_state s JOIN questions q ON q.id = s.question_id
            WHERE q.active = 1 AND s.is_wrong_book = 1
            """,
            [.integer(Int64(required)), .integer(Int64(required))]
        )
        let wrongCompletedToday = try db.scalarInt(
            """
            SELECT COUNT(*) FROM attempts a JOIN questions q ON q.id = a.question_id
            WHERE q.active = 1 AND a.submitted_at >= ?
              AND a.is_correct = 1 AND a.marked_unsure = 0
              AND a.was_in_wrong_book = 1
              AND a.wrong_progress_after > a.wrong_progress_before
            """,
            [.real(startOfDay)]
        )

        guard settings.dynamicPlanEnabled, let configuredTarget = settings.dynamicPlanTargetDate else {
            return DynamicStudyPlanSnapshot(
                isEnabled: false,
                targetDate: settings.dynamicPlanTargetDate,
                daysRemaining: 0,
                isOverdue: false,
                unseenRemaining: unseen,
                wrongMasteryRemaining: wrongMasteryRemaining,
                todayFirstPassTarget: 0,
                todayFirstPassCompleted: firstPassCompletedToday,
                todayWrongTarget: 0,
                todayWrongCompleted: wrongCompletedToday
            )
        }

        let targetDate = calendar.startOfDay(for: configuredTarget)
        let dayDifference = calendar.dateComponents([.day], from: today, to: targetDate).day ?? 0
        let daysRemaining = max(1, dayDifference + 1)
        let firstPassWorkload = unseen + firstPassCompletedToday
        let wrongWorkload = wrongMasteryRemaining + wrongCompletedToday
        return DynamicStudyPlanSnapshot(
            isEnabled: true,
            targetDate: targetDate,
            daysRemaining: daysRemaining,
            isOverdue: targetDate < today,
            unseenRemaining: unseen,
            wrongMasteryRemaining: wrongMasteryRemaining,
            todayFirstPassTarget: DynamicStudyPlanScheduler.dailyTarget(
                workload: firstPassWorkload,
                daysRemaining: daysRemaining
            ),
            todayFirstPassCompleted: firstPassCompletedToday,
            todayWrongTarget: DynamicStudyPlanScheduler.dailyTarget(
                workload: wrongWorkload,
                daysRemaining: daysRemaining
            ),
            todayWrongCompleted: wrongCompletedToday
        )
    }

    private func createSessionInsideTransaction(
        mode: PracticeMode,
        questionIDs: [String],
        planDateKey: String?,
        now: Date,
        seed: UInt64,
        generator: inout SeededRandomNumberGenerator
    ) throws -> PracticeSessionSnapshot {
        let sessionID = UUID().uuidString
        let timestamp = now.timeIntervalSince1970
        try db.execute(
            """
            INSERT INTO practice_sessions(
                id, mode, status, current_index, total_items, random_seed,
                created_at, updated_at, plan_date_key
            )
            VALUES (?, ?, 'active', 0, ?, ?, ?, ?, ?)
            """,
            [
                .text(sessionID), .text(mode.rawValue), .integer(Int64(questionIDs.count)),
                .integer(Int64(bitPattern: seed)), .real(timestamp), .real(timestamp),
                planDateKey.map(SQLiteValue.text) ?? .null
            ]
        )

        for (position, questionID) in questionIDs.enumerated() {
            guard let question = try db.rows(
                "SELECT stem, question_type, response_type, explanation FROM questions WHERE id = ?",
                [.text(questionID)]
            ).first else { continue }
            let optionRows = try db.rows(
                """
                SELECT id, text, original_label, is_correct FROM options
                WHERE question_id = ? AND active = 1 ORDER BY sort_order, id
                """,
                [.text(questionID)]
            )
            var options = optionRows.compactMap { row -> PracticeOption? in
                guard let id = row["id"]?.string, let text = row["text"]?.string else { return nil }
                return PracticeOption(id: id, text: text, originalLabel: row["original_label"]?.string)
            }
            options.shuffle(using: &generator)
            let correctIDs = optionRows.compactMap { row in
                row["is_correct"]?.int == 1 ? row["id"]?.string : nil
            }
            let type: QuestionType = question["response_type"]?.string == "essay"
                ? .essay
                : (QuestionType(rawValue: question["question_type"]?.string ?? "") ?? .singleChoice)
            let payload = SessionPayload(
                stem: question["stem"]?.string ?? "",
                type: type,
                explanation: question["explanation"]?.string ?? "",
                options: options
            )
            try db.execute(
                """
                INSERT INTO session_items(id, session_id, question_id, position, question_snapshot_json,
                    option_order_json, correct_option_ids_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(UUID().uuidString), .text(sessionID), .text(questionID), .integer(Int64(position)),
                    .text(try encode(payload)), .text(try options.map(\.id).encodedJSONString()),
                    .text(try correctIDs.encodedJSONString())
                ]
            )
        }
        let payload = planDateKey.map {
            "{\"mode\":\"dynamic_plan\",\"date\":\"\($0)\"}"
        } ?? "{\"mode\":\"\(mode.rawValue)\"}"
        try appendChange(
            entityType: "practice_session",
            entityID: sessionID,
            action: "started",
            payload: payload
        )
        return try sessionSnapshot(id: sessionID)
    }

    private static func planDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func sessionSnapshot(id: String) throws -> PracticeSessionSnapshot {
        guard let row = try db.rows(
            "SELECT id, mode, status, current_index, total_items, plan_date_key FROM practice_sessions WHERE id = ?",
            [.text(id)]
        ).first else { throw QuestionBankError.sessionNotFound }
        let mode = PracticeMode(rawValue: row["mode"]?.string ?? "") ?? .normal
        let currentIndex = row["current_index"]?.int ?? 0
        let total = row["total_items"]?.int ?? 0
        let complete = row["status"]?.string == "completed"
        let summary = PracticeSessionSummary(
            id: id, mode: mode, currentIndex: currentIndex, totalCount: total,
            answeredCount: currentIndex, isComplete: complete,
            planDateKey: row["plan_date_key"]?.string
        )
        guard !complete, let item = try db.rows(
            """
            SELECT id, question_id, question_snapshot_json FROM session_items
            WHERE session_id = ? AND position = ? LIMIT 1
            """,
            [.text(id), .integer(Int64(currentIndex))]
        ).first else {
            return PracticeSessionSnapshot(summary: summary, currentItem: nil)
        }
        let payload = try decode(SessionPayload.self, from: item["question_snapshot_json"]?.string ?? "")
        let questionID = item["question_id"]?.string ?? ""
        let state = try stateRow(questionID: questionID)
        let required = try readSettings().wrongRequiredConsecutiveCorrect
        let question = PracticeQuestion(
            itemID: item["id"]?.string ?? "", questionID: questionID, stem: payload.stem,
            type: payload.type, options: payload.options, explanation: payload.explanation,
            wrongProgress: state?["consecutive_correct"]?.int ?? 0,
            wrongRequired: required,
            isInWrongBook: state?["is_wrong_book"]?.int == 1
        )
        return PracticeSessionSnapshot(summary: summary, currentItem: question)
    }

    private func activeSessionSummary() throws -> PracticeSessionSummary? {
        guard let row = try db.rows(
            """
            SELECT id, mode, current_index, total_items, plan_date_key FROM practice_sessions
            WHERE status = 'active' ORDER BY updated_at DESC LIMIT 1
            """
        ).first, let id = row["id"]?.string else { return nil }
        return PracticeSessionSummary(
            id: id,
            mode: PracticeMode(rawValue: row["mode"]?.string ?? "") ?? .normal,
            currentIndex: row["current_index"]?.int ?? 0,
            totalCount: row["total_items"]?.int ?? 0,
            answeredCount: row["current_index"]?.int ?? 0,
            isComplete: false,
            planDateKey: row["plan_date_key"]?.string
        )
    }

    private func stateRow(questionID: String) throws -> SQLiteRow? {
        try db.rows("SELECT * FROM question_state WHERE question_id = ?", [.text(questionID)]).first
    }

    private func ensureWrongBook(questionID: String, at date: Date, resetProgress: Bool) throws {
        let timestamp = date.timeIntervalSince1970
        try db.execute(
            """
            INSERT INTO question_state(question_id, is_wrong_book, consecutive_correct, added_to_wrong_at, updated_at)
            VALUES (?, 1, 0, ?, ?)
            ON CONFLICT(question_id) DO UPDATE SET is_wrong_book = 1,
                consecutive_correct = CASE WHEN ? = 1 THEN 0 ELSE question_state.consecutive_correct END,
                added_to_wrong_at = CASE WHEN question_state.is_wrong_book = 0 THEN excluded.added_to_wrong_at ELSE question_state.added_to_wrong_at END,
                updated_at = excluded.updated_at
            """,
            [.text(questionID), .real(timestamp), .real(timestamp), .integer(resetProgress ? 1 : 0)]
        )
    }

    private func appendChange(entityType: String, entityID: String, action: String, payload: String? = nil) throws {
        try db.execute(
            "INSERT INTO change_log(source_app, entity_type, entity_id, action, payload_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(sourceApplication), .text(entityType), .text(entityID), .text(action),
                payload.map(SQLiteValue.text) ?? .null, .real(Date().timeIntervalSince1970)
            ]
        )
    }

    private func notifyChange() {
        let userInfo: [AnyHashable: Any] = ["databasePath": databaseURL.path, "sourceApplication": sourceApplication]
        NotificationCenter.default.post(name: QuestionBankPaths.databaseChangedNotification, object: self, userInfo: userInfo)
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            QuestionBankPaths.databaseChangedNotification,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        #endif
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw QuestionBankError.database("Unable to encode JSON")
        }
        return json
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw QuestionBankError.database("Invalid JSON") }
        return try JSONDecoder().decode(type, from: data)
    }

    private func normalizeLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".、:：()（）[]【】"))
            .uppercased()
    }

    private func normalizeText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private func stableID(prefix: String, source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)_\(String(hash, radix: 16))"
    }
}
