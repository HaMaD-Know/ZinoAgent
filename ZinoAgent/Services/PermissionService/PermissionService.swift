import Foundation

public struct ToolActivityEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let conversationID: String?
    public let toolName: String
    public let argumentsJSON: String
    public let permissionLevel: AIPermissionLevel
    public let status: String
    public let resultSummary: String
    public let createdAt: Date
}

/// Manages AI file permissions, online file-transmission consent records, and tool audit logs.
public final class PermissionService: @unchecked Sendable {
    private let database: AppDatabase
    private let lock = NSLock()
    private var approvedOnlineUploadKeys: Set<String> = []

    public init(database: AppDatabase) {
        self.database = database
    }

    public func hasSessionConsentForOnlineUpload(providerID: String, filePaths: [String]) -> Bool {
        let key = consentKey(providerID: providerID, filePaths: filePaths)
        lock.lock()
        defer { lock.unlock() }
        return approvedOnlineUploadKeys.contains(key)
    }

    public func grantSessionConsentForOnlineUpload(providerID: String, filePaths: [String]) {
        let key = consentKey(providerID: providerID, filePaths: filePaths)
        lock.lock()
        approvedOnlineUploadKeys.insert(key)
        lock.unlock()
    }

    public func revokeAllSessionConsents() {
        lock.lock()
        approvedOnlineUploadKeys.removeAll()
        lock.unlock()
    }

    public func logToolActivity(
        conversationID: String?,
        toolName: String,
        argumentsJSON: String,
        permissionLevel: AIPermissionLevel,
        status: String,
        resultSummary: String
    ) {
        let entryID = UUID().uuidString
        try? database.sqlite.execute(
            """
            INSERT INTO tool_activity_log (
                id, conversation_id, tool_name, arguments_json, permission_level, status, result_summary, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(entryID),
                conversationID.map { .text($0) } ?? .null,
                .text(toolName),
                .text(SecretRedactor.redact(argumentsJSON)),
                .text(permissionLevel.rawValue),
                .text(status),
                .text(SecretRedactor.redact(resultSummary)),
                .real(Date().timeIntervalSince1970)
            ]
        )
    }

    public func fetchToolActivityLog(limit: Int = 100) throws -> [ToolActivityEntry] {
        let rows = try database.sqlite.query(
            "SELECT * FROM tool_activity_log ORDER BY created_at DESC LIMIT ?;",
            bindings: [.integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let id = row.string("id"),
                  let toolName = row.string("tool_name"),
                  let args = row.string("arguments_json"),
                  let permRaw = row.string("permission_level"),
                  let perm = AIPermissionLevel(rawValue: permRaw),
                  let status = row.string("status"),
                  let summary = row.string("result_summary"),
                  let created = row.date("created_at") else { return nil }
            return ToolActivityEntry(
                id: id,
                conversationID: row.string("conversation_id"),
                toolName: toolName,
                argumentsJSON: args,
                permissionLevel: perm,
                status: status,
                resultSummary: summary,
                createdAt: created
            )
        }
    }

    public func clearToolActivityLog() throws {
        try database.sqlite.execute("DELETE FROM tool_activity_log;")
    }

    private func consentKey(providerID: String, filePaths: [String]) -> String {
        "\(providerID)::" + filePaths.sorted().joined(separator: "|")
    }
}
