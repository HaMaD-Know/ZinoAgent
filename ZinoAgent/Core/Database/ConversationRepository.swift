import Foundation

/// Persists conversations, messages, and message attachments in SQLite while preserving original history.
public final class ConversationRepository: Sendable {
    private let db: AppDatabase

    public init(database: AppDatabase) {
        self.db = database
    }

    public func createConversation(_ conversation: ChatConversation) throws {
        try db.sqlite.execute(
            """
            INSERT INTO conversations (id, title, mode, provider_id, model_id, system_prompt, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(conversation.id),
                .text(conversation.title),
                .text(conversation.mode.rawValue),
                conversation.providerID.map { .text($0) } ?? .null,
                conversation.modelID.map { .text($0) } ?? .null,
                conversation.systemPrompt.map { .text($0) } ?? .null,
                .real(conversation.createdAt.timeIntervalSince1970),
                .real(conversation.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func updateConversation(_ conversation: ChatConversation) throws {
        try db.sqlite.execute(
            """
            UPDATE conversations
            SET title = ?, mode = ?, provider_id = ?, model_id = ?, system_prompt = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(conversation.title),
                .text(conversation.mode.rawValue),
                conversation.providerID.map { .text($0) } ?? .null,
                conversation.modelID.map { .text($0) } ?? .null,
                conversation.systemPrompt.map { .text($0) } ?? .null,
                .real(Date().timeIntervalSince1970),
                .text(conversation.id)
            ]
        )
    }

    public func deleteConversation(id: String) throws {
        try db.sqlite.execute("DELETE FROM conversations WHERE id = ?;", bindings: [.text(id)])
        try db.sqlite.execute("DELETE FROM recent_activity WHERE reference_id = ? AND kind = 'conversation';", bindings: [.text(id)])
    }

    public func fetchConversations() throws -> [ChatConversation] {
        let rows = try db.sqlite.query("SELECT * FROM conversations ORDER BY updated_at DESC;")
        return rows.compactMap(Self.mapConversation)
    }

    public func fetchConversation(id: String) throws -> ChatConversation? {
        let rows = try db.sqlite.query("SELECT * FROM conversations WHERE id = ? LIMIT 1;", bindings: [.text(id)])
        return rows.first.flatMap(Self.mapConversation)
    }

    public func saveMessage(_ message: ChatMessage) throws {
        try db.sqlite.transaction {
            try db.sqlite.executeInTransaction(
                """
                INSERT INTO messages (
                    id, conversation_id, role, content, thinking_content, provider_label, model_label,
                    token_count, is_pinned, is_archived_to_summary, tool_call_id, tool_name, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    thinking_content = excluded.thinking_content,
                    provider_label = excluded.provider_label,
                    model_label = excluded.model_label,
                    token_count = excluded.token_count,
                    is_pinned = excluded.is_pinned,
                    is_archived_to_summary = excluded.is_archived_to_summary;
                """,
                bindings: [
                    .text(message.id),
                    .text(message.conversationID),
                    .text(message.role.rawValue),
                    .text(message.content),
                    message.thinkingContent.map { .text($0) } ?? .null,
                    message.providerLabel.map { .text($0) } ?? .null,
                    message.modelLabel.map { .text($0) } ?? .null,
                    message.tokenCount.map { .integer(Int64($0)) } ?? .null,
                    .integer(message.isPinned ? 1 : 0),
                    .integer(message.isArchivedToSummary ? 1 : 0),
                    message.toolCallID.map { .text($0) } ?? .null,
                    message.toolName.map { .text($0) } ?? .null,
                    .real(message.createdAt.timeIntervalSince1970)
                ]
            )

            try db.sqlite.executeInTransaction(
                "DELETE FROM message_attachments WHERE message_id = ?;",
                bindings: [.text(message.id)]
            )

            for att in message.attachments {
                try db.sqlite.executeInTransaction(
                    """
                    INSERT INTO message_attachments (
                        id, message_id, kind, filename, file_path, mime_type, file_size_bytes, extracted_preview
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .text(att.id),
                        .text(message.id),
                        .text(att.kind.rawValue),
                        .text(att.filename),
                        .text(att.filePath),
                        .text(att.mimeType),
                        .integer(att.fileSizeBytes),
                        att.extractedPreview.map { .text($0) } ?? .null
                    ]
                )
            }

            try db.sqlite.executeInTransaction(
                "UPDATE conversations SET updated_at = ? WHERE id = ?;",
                bindings: [.real(Date().timeIntervalSince1970), .text(message.conversationID)]
            )
        }
    }

    public func deleteMessage(id: String) throws {
        try db.sqlite.execute("DELETE FROM messages WHERE id = ?;", bindings: [.text(id)])
    }

    public func setMessagePinned(id: String, pinned: Bool) throws {
        try db.sqlite.execute(
            "UPDATE messages SET is_pinned = ? WHERE id = ?;",
            bindings: [.integer(pinned ? 1 : 0), .text(id)]
        )
    }

    public func markMessagesArchivedToSummary(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.sqlite.transaction {
            for id in ids {
                try db.sqlite.executeInTransaction(
                    "UPDATE messages SET is_archived_to_summary = 1 WHERE id = ?;",
                    bindings: [.text(id)]
                )
            }
        }
    }

    public func fetchMessages(conversationID: String) throws -> [ChatMessage] {
        let rows = try db.sqlite.query(
            "SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at ASC;",
            bindings: [.text(conversationID)]
        )
        let attRows = try db.sqlite.query(
            """
            SELECT a.* FROM message_attachments a
            INNER JOIN messages m ON m.id = a.message_id
            WHERE m.conversation_id = ?;
            """,
            bindings: [.text(conversationID)]
        )
        var attachmentsByMessage: [String: [ChatAttachment]] = [:]
        for row in attRows {
            guard let id = row.string("id"),
                  let messageID = row.string("message_id"),
                  let kindRaw = row.string("kind"),
                  let kind = ChatAttachment.Kind(rawValue: kindRaw),
                  let filename = row.string("filename"),
                  let filePath = row.string("file_path"),
                  let mimeType = row.string("mime_type"),
                  let size = row.int64("file_size_bytes") else { continue }
            let attachment = ChatAttachment(
                id: id,
                kind: kind,
                filename: filename,
                filePath: filePath,
                mimeType: mimeType,
                fileSizeBytes: size,
                extractedPreview: row.string("extracted_preview")
            )
            attachmentsByMessage[messageID, default: []].append(attachment)
        }

        return rows.compactMap { row -> ChatMessage? in
            guard let id = row.string("id"),
                  let convID = row.string("conversation_id"),
                  let roleRaw = row.string("role"),
                  let role = ChatRole(rawValue: roleRaw),
                  let content = row.string("content"),
                  let createdAt = row.date("created_at") else { return nil }
            return ChatMessage(
                id: id,
                conversationID: convID,
                role: role,
                content: content,
                thinkingContent: row.string("thinking_content"),
                providerLabel: row.string("provider_label"),
                modelLabel: row.string("model_label"),
                tokenCount: row.int("token_count"),
                isPinned: row.bool("is_pinned"),
                isArchivedToSummary: row.bool("is_archived_to_summary"),
                toolCallID: row.string("tool_call_id"),
                toolName: row.string("tool_name"),
                attachments: attachmentsByMessage[id] ?? [],
                createdAt: createdAt
            )
        }
    }

    private static func mapConversation(_ row: SQLiteRow) -> ChatConversation? {
        guard let id = row.string("id"),
              let title = row.string("title"),
              let modeRaw = row.string("mode"),
              let mode = AIMode(rawValue: modeRaw),
              let createdAt = row.date("created_at"),
              let updatedAt = row.date("updated_at") else { return nil }
        return ChatConversation(
            id: id,
            title: title,
            mode: mode,
            providerID: row.string("provider_id"),
            modelID: row.string("model_id"),
            systemPrompt: row.string("system_prompt"),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
