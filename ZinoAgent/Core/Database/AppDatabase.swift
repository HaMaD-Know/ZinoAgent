import Foundation

public struct DatabaseMigration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String
}

/// Central persistence layer with versioned SQLite migrations covering conversations, SmartContextEngine,
/// local model metadata, provider configurations (without secrets), folder bookmarks, favorites, recents,
/// image generation history, 3D projects, tool audit logs, undo journal, and settings.
public final class AppDatabase: Sendable {
    public let sqlite: SQLiteDatabase

    public init(path: String) throws {
        self.sqlite = try SQLiteDatabase(path: path)
        try runMigrations()
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(path: ":memory:")
    }

    public func currentSchemaVersion() throws -> Int {
        let rows = try sqlite.query("SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations;")
        return rows.first?.int("v") ?? 0
    }

    private func runMigrations() throws {
        try sqlite.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at REAL NOT NULL
            );
        """)

        let applied = Set(try sqlite.query("SELECT version FROM schema_migrations;").compactMap { $0.int("version") })

        for migration in Self.migrations where !applied.contains(migration.version) {
            try sqlite.executeScript(migration.sql)
            try sqlite.execute(
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?);",
                bindings: [.integer(Int64(migration.version)), .text(migration.name), .real(Date().timeIntervalSince1970)]
            )
            AppLogger.shared.info("Database", "Applied migration v\(migration.version): \(migration.name)")
        }
    }

    private static let migrations: [DatabaseMigration] = [
        DatabaseMigration(
            version: 1,
            name: "initial_core_schema",
            sql: """
            CREATE TABLE IF NOT EXISTS app_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS ai_providers (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                provider_type TEXT NOT NULL,
                base_url TEXT NOT NULL,
                keychain_account TEXT NOT NULL,
                default_model_id TEXT,
                cached_models_json TEXT,
                is_default INTEGER NOT NULL DEFAULT 0,
                supports_vision INTEGER NOT NULL DEFAULT 0,
                supports_image_generation INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS local_models (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                architecture TEXT NOT NULL,
                quantization TEXT NOT NULL,
                parameter_count_label TEXT NOT NULL,
                context_length INTEGER NOT NULL,
                trained_context_length INTEGER NOT NULL,
                layer_count INTEGER NOT NULL,
                embedding_dim INTEGER NOT NULL,
                has_chat_template INTEGER NOT NULL DEFAULT 0,
                is_split INTEGER NOT NULL DEFAULT 0,
                compatibility_status TEXT NOT NULL,
                compatibility_notes TEXT NOT NULL,
                estimated_ram_bytes INTEGER NOT NULL,
                source_url TEXT,
                sha256_prefix TEXT,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                mode TEXT NOT NULL,
                provider_id TEXT,
                model_id TEXT,
                system_prompt TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                thinking_content TEXT,
                provider_label TEXT,
                model_label TEXT,
                token_count INTEGER,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_archived_to_summary INTEGER NOT NULL DEFAULT 0,
                tool_call_id TEXT,
                tool_name TEXT,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS message_attachments (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                filename TEXT NOT NULL,
                file_path TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                extracted_preview TEXT
            );

            CREATE TABLE IF NOT EXISTS context_summaries (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                summary_text TEXT NOT NULL,
                covered_message_ids_json TEXT NOT NULL,
                covered_message_count INTEGER NOT NULL,
                token_count INTEGER NOT NULL,
                verification_passed INTEGER NOT NULL,
                verification_notes TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS folder_bookmarks (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                bookmark_data BLOB NOT NULL,
                last_resolved_path TEXT NOT NULL,
                permission_level TEXT NOT NULL DEFAULT 'confirm',
                is_accessible INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                last_accessed_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS favorite_files (
                path TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                folder_id TEXT,
                added_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS recent_activity (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT NOT NULL,
                reference_id TEXT NOT NULL,
                opened_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS image_generations (
                id TEXT PRIMARY KEY,
                prompt TEXT NOT NULL,
                negative_prompt TEXT,
                mode TEXT NOT NULL,
                provider_name TEXT NOT NULL,
                model_name TEXT NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                quality TEXT,
                seed INTEGER,
                relative_image_path TEXT NOT NULL,
                duration_ms INTEGER NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS threed_projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                format TEXT NOT NULL,
                relative_file_path TEXT NOT NULL,
                original_path TEXT,
                file_size_bytes INTEGER NOT NULL,
                object_count INTEGER NOT NULL,
                mesh_count INTEGER NOT NULL,
                material_count INTEGER NOT NULL,
                vertex_count INTEGER NOT NULL,
                last_opened_at REAL NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS tool_activity_log (
                id TEXT PRIMARY KEY,
                conversation_id TEXT,
                tool_name TEXT NOT NULL,
                arguments_json TEXT NOT NULL,
                permission_level TEXT NOT NULL,
                status TEXT NOT NULL,
                result_summary TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS file_undo_journal (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                operation TEXT NOT NULL,
                source_path TEXT NOT NULL,
                destination_path TEXT,
                trash_path TEXT,
                created_at REAL NOT NULL
            );
            """
        ),
        DatabaseMigration(
            version: 2,
            name: "performance_indexes",
            sql: """
            CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON messages(conversation_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_context_summaries_conversation ON context_summaries(conversation_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_recent_activity_kind_opened ON recent_activity(kind, opened_at DESC);
            CREATE INDEX IF NOT EXISTS idx_image_generations_created ON image_generations(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_threed_projects_opened ON threed_projects(last_opened_at DESC);
            CREATE INDEX IF NOT EXISTS idx_tool_activity_created ON tool_activity_log(created_at DESC);
            """
        )
    ]

    // MARK: - Settings KV

    public func setSetting(key: String, value: String) throws {
        try sqlite.execute(
            """
            INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
            """,
            bindings: [.text(key), .text(value), .real(Date().timeIntervalSince1970)]
        )
    }

    public func getSetting(key: String) throws -> String? {
        let rows = try sqlite.query("SELECT value FROM app_settings WHERE key = ? LIMIT 1;", bindings: [.text(key)])
        return rows.first?.string("value")
    }

    public func allSettings() throws -> [String: String] {
        let rows = try sqlite.query("SELECT key, value FROM app_settings;")
        var result: [String: String] = [:]
        for row in rows {
            if let k = row.string("key"), let v = row.string("value") {
                result[k] = v
            }
        }
        return result
    }

    // MARK: - Recent Activity

    public func recordRecentActivity(kind: String, title: String, subtitle: String, referenceID: String) throws {
        let id = "\(kind)::\(referenceID)"
        try sqlite.execute(
            """
            INSERT INTO recent_activity (id, kind, title, subtitle, reference_id, opened_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                subtitle = excluded.subtitle,
                opened_at = excluded.opened_at;
            """,
            bindings: [
                .text(id), .text(kind), .text(title), .text(subtitle), .text(referenceID),
                .real(Date().timeIntervalSince1970)
            ]
        )
    }

    public func fetchRecentActivity(kind: String? = nil, limit: Int = 10) throws -> [RecentActivityItem] {
        let rows: [SQLiteRow]
        if let kind {
            rows = try sqlite.query(
                "SELECT * FROM recent_activity WHERE kind = ? ORDER BY opened_at DESC LIMIT ?;",
                bindings: [.text(kind), .integer(Int64(limit))]
            )
        } else {
            rows = try sqlite.query(
                "SELECT * FROM recent_activity ORDER BY opened_at DESC LIMIT ?;",
                bindings: [.integer(Int64(limit))]
            )
        }
        return rows.compactMap { row in
            guard let id = row.string("id"),
                  let kind = row.string("kind"),
                  let title = row.string("title"),
                  let subtitle = row.string("subtitle"),
                  let ref = row.string("reference_id"),
                  let openedAt = row.date("opened_at") else { return nil }
            return RecentActivityItem(id: id, kind: kind, title: title, subtitle: subtitle, referenceID: ref, openedAt: openedAt)
        }
    }

    public func clearAllConversations() throws {
        try sqlite.execute("DELETE FROM conversations;")
        try sqlite.execute("DELETE FROM recent_activity WHERE kind = 'conversation';")
    }
}

public struct RecentActivityItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let title: String
    public let subtitle: String
    public let referenceID: String
    public let openedAt: Date
}
