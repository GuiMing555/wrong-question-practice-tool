import Foundation

enum QuestionBankSchema {
    static let currentVersion = 8

    static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """)
        for version in 1...currentVersion {
            try db.transaction {
                // Recheck after BEGIN IMMEDIATE. The capture and practice apps may
                // launch together and race while opening a brand-new shared file.
                guard try db.scalarInt(
                    "SELECT COUNT(*) FROM schema_migrations WHERE version = ?",
                    [.integer(Int64(version))]
                ) == 0 else { return }
                switch version {
                case 1: try migration1(db)
                case 2: try migration2(db)
                case 3: try migration3(db)
                case 4: try migration4(db)
                case 5: try migration5(db)
                case 6: try migration6(db)
                case 7: try migration7(db)
                case 8: try migration8(db)
                default: break
                }
                try db.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                    [.integer(Int64(version)), .real(Date().timeIntervalSince1970)]
                )
            }
        }
    }

    private static func migration1(_ db: SQLiteDatabase) throws {
        let statements = [
            """
            CREATE TABLE settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                normal_review_interval_days INTEGER NOT NULL DEFAULT 7 CHECK (normal_review_interval_days >= 0),
                wrong_required_consecutive_correct INTEGER NOT NULL DEFAULT 3 CHECK (wrong_required_consecutive_correct > 0),
                questions_per_session INTEGER,
                updated_at REAL NOT NULL
            )
            """,
            """
            INSERT INTO settings(id, normal_review_interval_days, wrong_required_consecutive_correct, questions_per_session, updated_at)
            VALUES (1, 7, 3, NULL, 0)
            """,
            """
            CREATE TABLE questions (
                id TEXT PRIMARY KEY,
                external_id TEXT NOT NULL UNIQUE,
                stem TEXT NOT NULL,
                question_type TEXT NOT NULL CHECK (question_type IN ('single_choice', 'multiple_choice')),
                explanation TEXT NOT NULL DEFAULT '',
                source TEXT,
                source_image_path TEXT,
                source_image_hash TEXT,
                captured_at REAL,
                active INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE options (
                id TEXT PRIMARY KEY,
                question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                original_label TEXT,
                text TEXT NOT NULL,
                is_correct INTEGER NOT NULL CHECK (is_correct IN (0, 1)),
                sort_order INTEGER NOT NULL,
                active INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX options_question_active ON options(question_id, active, sort_order)",
            """
            CREATE TABLE question_state (
                question_id TEXT PRIMARY KEY REFERENCES questions(id) ON DELETE CASCADE,
                last_answered_at REAL,
                total_attempts INTEGER NOT NULL DEFAULT 0,
                correct_attempts INTEGER NOT NULL DEFAULT 0,
                wrong_attempts INTEGER NOT NULL DEFAULT 0,
                is_wrong_book INTEGER NOT NULL DEFAULT 0,
                consecutive_correct INTEGER NOT NULL DEFAULT 0,
                added_to_wrong_at REAL,
                removed_from_wrong_at REAL,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX question_state_wrong ON question_state(is_wrong_book, updated_at)",
            """
            CREATE TABLE practice_sessions (
                id TEXT PRIMARY KEY,
                mode TEXT NOT NULL CHECK (mode IN ('normal', 'wrong_book')),
                status TEXT NOT NULL CHECK (status IN ('active', 'completed')),
                current_index INTEGER NOT NULL DEFAULT 0,
                total_items INTEGER NOT NULL,
                random_seed INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            )
            """,
            "CREATE INDEX practice_sessions_active ON practice_sessions(status, updated_at DESC)",
            """
            CREATE TABLE session_items (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES practice_sessions(id) ON DELETE CASCADE,
                question_id TEXT NOT NULL REFERENCES questions(id),
                position INTEGER NOT NULL,
                question_snapshot_json TEXT NOT NULL,
                option_order_json TEXT NOT NULL,
                correct_option_ids_json TEXT NOT NULL,
                answered_at REAL,
                attempt_id TEXT UNIQUE,
                UNIQUE(session_id, position),
                UNIQUE(session_id, question_id)
            )
            """,
            "CREATE INDEX session_items_session_position ON session_items(session_id, position)",
            """
            CREATE TABLE attempts (
                id TEXT PRIMARY KEY,
                submission_token TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL REFERENCES practice_sessions(id),
                session_item_id TEXT NOT NULL REFERENCES session_items(id),
                question_id TEXT NOT NULL REFERENCES questions(id),
                mode TEXT NOT NULL,
                submitted_at REAL NOT NULL,
                selected_option_ids_json TEXT NOT NULL,
                displayed_option_order_json TEXT NOT NULL,
                correct_option_ids_json TEXT NOT NULL,
                is_correct INTEGER NOT NULL,
                marked_unsure INTEGER NOT NULL,
                was_in_wrong_book INTEGER NOT NULL,
                is_in_wrong_book INTEGER NOT NULL,
                wrong_progress_before INTEGER NOT NULL,
                wrong_progress_after INTEGER NOT NULL,
                removed_from_wrong_book INTEGER NOT NULL,
                explanation_snapshot TEXT NOT NULL,
                result_json TEXT
            )
            """,
            "CREATE INDEX attempts_question_time ON attempts(question_id, submitted_at DESC)",
            "CREATE INDEX attempts_session ON attempts(session_id, submitted_at)",
            """
            CREATE TRIGGER attempts_are_append_only_update
            BEFORE UPDATE ON attempts BEGIN
                SELECT RAISE(ABORT, 'attempts are append-only');
            END
            """,
            """
            CREATE TRIGGER attempts_are_append_only_delete
            BEFORE DELETE ON attempts BEGIN
                SELECT RAISE(ABORT, 'attempts are append-only');
            END
            """,
            """
            CREATE TABLE change_log (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                source_app TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                action TEXT NOT NULL,
                payload_json TEXT,
                created_at REAL NOT NULL
            )
            """,
            "CREATE INDEX change_log_created ON change_log(sequence, created_at)"
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration2(_ db: SQLiteDatabase) throws {
        let statements = [
            """
            CREATE TABLE knowledge_points (
                id TEXT PRIMARY KEY,
                normalized_name TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE question_knowledge_points (
                question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                knowledge_point_id TEXT NOT NULL REFERENCES knowledge_points(id) ON DELETE CASCADE,
                PRIMARY KEY(question_id, knowledge_point_id)
            )
            """,
            """
            CREATE TABLE capture_events (
                id TEXT PRIMARY KEY,
                source_image_hash TEXT NOT NULL UNIQUE,
                question_id TEXT NOT NULL REFERENCES questions(id),
                source_image_path TEXT NOT NULL,
                captured_at REAL NOT NULL,
                imported_at REAL NOT NULL
            )
            """,
            "CREATE INDEX capture_events_question ON capture_events(question_id, captured_at DESC)"
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration3(_ db: SQLiteDatabase) throws {
        let condition = """
            is_wrong_book = 1
            AND total_attempts = 0
            AND EXISTS (
                SELECT 1 FROM change_log c
                WHERE c.entity_type = 'wrong_book'
                  AND c.entity_id = question_state.question_id
                  AND c.action = 'capture_added'
            )
            AND NOT EXISTS (
                SELECT 1 FROM change_log c
                WHERE c.entity_type = 'wrong_book'
                  AND c.entity_id = question_state.question_id
                  AND c.action = 'manually_added'
            )
            AND NOT EXISTS (
                SELECT 1 FROM attempts a WHERE a.question_id = question_state.question_id
            )
            """
        let affected = try db.scalarInt("SELECT COUNT(*) FROM question_state WHERE \(condition)")
        guard affected > 0 else { return }

        let timestamp = Date().timeIntervalSince1970
        try db.execute(
            """
            UPDATE question_state
            SET is_wrong_book = 0,
                consecutive_correct = 0,
                added_to_wrong_at = NULL,
                removed_from_wrong_at = NULL,
                updated_at = ?
            WHERE \(condition)
            """,
            [.real(timestamp)]
        )
        try db.execute(
            """
            INSERT INTO change_log(source_app, entity_type, entity_id, action, payload_json, created_at)
            VALUES ('schema_migration', 'wrong_book_cleanup', 'migration-3',
                    'cleared_auto_capture_wrong', ?, ?)
            """,
            [.text("{\"cleared\":\(affected)}"), .real(timestamp)]
        )
    }

    private static func migration4(_ db: SQLiteDatabase) throws {
        let statements = [
            "ALTER TABLE questions ADD COLUMN curriculum_section TEXT",
            "ALTER TABLE questions ADD COLUMN curriculum_chapter TEXT",
            "ALTER TABLE questions ADD COLUMN content_analysis_json TEXT",
            "ALTER TABLE settings ADD COLUMN workbook_output_path TEXT"
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration5(_ db: SQLiteDatabase) throws {
        let statements = [
            "ALTER TABLE session_items RENAME TO session_items_legacy",
            """
            CREATE TABLE session_items (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES practice_sessions(id) ON DELETE CASCADE,
                question_id TEXT NOT NULL REFERENCES questions(id),
                position INTEGER NOT NULL,
                question_snapshot_json TEXT NOT NULL,
                option_order_json TEXT NOT NULL,
                correct_option_ids_json TEXT NOT NULL,
                answered_at REAL,
                attempt_id TEXT UNIQUE,
                UNIQUE(session_id, position)
            )
            """,
            """
            INSERT INTO session_items(
                id, session_id, question_id, position, question_snapshot_json,
                option_order_json, correct_option_ids_json, answered_at, attempt_id
            )
            SELECT id, session_id, question_id, position, question_snapshot_json,
                   option_order_json, correct_option_ids_json, answered_at, attempt_id
            FROM session_items_legacy
            """,
            """
            CREATE TABLE attempts_v5 (
                id TEXT PRIMARY KEY,
                submission_token TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL REFERENCES practice_sessions(id),
                session_item_id TEXT NOT NULL REFERENCES session_items(id),
                question_id TEXT NOT NULL REFERENCES questions(id),
                mode TEXT NOT NULL,
                submitted_at REAL NOT NULL,
                selected_option_ids_json TEXT NOT NULL,
                displayed_option_order_json TEXT NOT NULL,
                correct_option_ids_json TEXT NOT NULL,
                is_correct INTEGER NOT NULL,
                marked_unsure INTEGER NOT NULL,
                was_in_wrong_book INTEGER NOT NULL,
                is_in_wrong_book INTEGER NOT NULL,
                wrong_progress_before INTEGER NOT NULL,
                wrong_progress_after INTEGER NOT NULL,
                removed_from_wrong_book INTEGER NOT NULL,
                explanation_snapshot TEXT NOT NULL,
                result_json TEXT
            )
            """,
            """
            INSERT INTO attempts_v5(
                id, submission_token, session_id, session_item_id, question_id, mode,
                submitted_at, selected_option_ids_json, displayed_option_order_json,
                correct_option_ids_json, is_correct, marked_unsure, was_in_wrong_book,
                is_in_wrong_book, wrong_progress_before, wrong_progress_after,
                removed_from_wrong_book, explanation_snapshot, result_json
            )
            SELECT id, submission_token, session_id, session_item_id, question_id, mode,
                   submitted_at, selected_option_ids_json, displayed_option_order_json,
                   correct_option_ids_json, is_correct, marked_unsure, was_in_wrong_book,
                   is_in_wrong_book, wrong_progress_before, wrong_progress_after,
                   removed_from_wrong_book, explanation_snapshot, result_json
            FROM attempts
            """,
            "DROP TABLE attempts",
            "ALTER TABLE attempts_v5 RENAME TO attempts",
            "DROP TABLE session_items_legacy",
            "CREATE INDEX session_items_session_position ON session_items(session_id, position)",
            "CREATE INDEX attempts_question_time ON attempts(question_id, submitted_at DESC)",
            "CREATE INDEX attempts_session ON attempts(session_id, submitted_at)",
            """
            CREATE TRIGGER attempts_are_append_only_update
            BEFORE UPDATE ON attempts BEGIN
                SELECT RAISE(ABORT, 'attempts are append-only');
            END
            """,
            """
            CREATE TRIGGER attempts_are_append_only_delete
            BEFORE DELETE ON attempts BEGIN
                SELECT RAISE(ABORT, 'attempts are append-only');
            END
            """
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration6(_ db: SQLiteDatabase) throws {
        let statements = [
            "ALTER TABLE settings ADD COLUMN dynamic_plan_enabled INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE settings ADD COLUMN dynamic_plan_target_date REAL",
            "ALTER TABLE practice_sessions ADD COLUMN plan_date_key TEXT"
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration7(_ db: SQLiteDatabase) throws {
        let statements = [
            """
            CREATE TABLE question_api_responses (
                id TEXT PRIMARY KEY,
                question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                input_hash TEXT NOT NULL,
                endpoint TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                response_json TEXT NOT NULL,
                received_at REAL NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(question_id, input_hash)
            )
            """,
            "CREATE INDEX question_api_responses_question_time ON question_api_responses(question_id, received_at DESC)",
            "CREATE INDEX question_api_responses_received ON question_api_responses(received_at)",
            """
            INSERT OR IGNORE INTO question_api_responses(
                id, question_id, input_hash, endpoint, model, response_json, received_at, created_at
            )
            SELECT 'legacy-' || q.id, q.id, 'legacy:' || q.id, 'legacy-import', '',
                   q.content_analysis_json, COALESCE(q.captured_at, q.updated_at), q.updated_at
            FROM questions q
            WHERE q.content_analysis_json IS NOT NULL AND TRIM(q.content_analysis_json) != ''
            """
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration8(_ db: SQLiteDatabase) throws {
        let statements = [
            "ALTER TABLE questions ADD COLUMN response_type TEXT NOT NULL DEFAULT 'choice' CHECK (response_type IN ('choice', 'essay'))",
            "ALTER TABLE attempts ADD COLUMN typed_answer TEXT",
            "ALTER TABLE attempts ADD COLUMN essay_evaluation_json TEXT"
        ]
        for statement in statements { try db.execute(statement) }
    }
}
