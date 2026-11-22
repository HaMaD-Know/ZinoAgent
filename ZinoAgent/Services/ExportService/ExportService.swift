import Foundation
import UIKit

/// Exports conversations, settings, and media safely — always scrubbing credentials before writing.
public final class ExportService: Sendable {
    private let storagePaths: AppStoragePaths
    private let conversationRepository: ConversationRepository

    public init(storagePaths: AppStoragePaths, conversationRepository: ConversationRepository) {
        self.storagePaths = storagePaths
        self.conversationRepository = conversationRepository
    }

    public func exportConversationMarkdown(conversation: ChatConversation) throws -> URL {
        let messages = try conversationRepository.fetchMessages(conversationID: conversation.id)
        var lines: [String] = [
            "# \(conversation.title)",
            "",
            "- **Exported:** \(Formatters.timestamp(Date()))",
            "- **Mode:** \(conversation.mode.displayName)",
            "- **Model:** \(conversation.modelID ?? "Unselected")",
            "",
            "---",
            ""
        ]

        for msg in messages {
            let roleTitle = msg.role.rawValue.capitalized
            let badge = [msg.providerLabel, msg.modelLabel].compactMap { $0 }.joined(separator: " • ")
            lines.append("### \(roleTitle)\(badge.isEmpty ? "" : " (\(badge))")")
            lines.append("*\(Formatters.timestamp(msg.createdAt))*")
            lines.append("")
            lines.append(SecretRedactor.redact(msg.content))
            if !msg.attachments.isEmpty {
                lines.append("")
                lines.append("**Attachments:** " + msg.attachments.map(\.filename).joined(separator: ", "))
            }
            lines.append("")
        }

        let safeName = sanitizedFilename(conversation.title) + "-\(Int(Date().timeIntervalSince1970)).md"
        let outURL = storagePaths.exportsDirectory.appendingPathComponent(safeName)
        try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    public func exportConversationJSON(conversation: ChatConversation) throws -> URL {
        let messages = try conversationRepository.fetchMessages(conversationID: conversation.id).map { msg -> ChatMessage in
            var clean = msg
            clean.content = SecretRedactor.redact(msg.content)
            clean.thinkingContent = msg.thinkingContent.map { SecretRedactor.redact($0) }
            return clean
        }

        struct ExportEnvelope: Codable {
            let exportedAt: Date
            let appVersion: String
            let conversation: ChatConversation
            let messages: [ChatMessage]
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            ExportEnvelope(
                exportedAt: Date(),
                appVersion: AppConfiguration.version,
                conversation: conversation,
                messages: messages
            )
        )
        let safeName = sanitizedFilename(conversation.title) + "-\(Int(Date().timeIntervalSince1970)).json"
        let outURL = storagePaths.exportsDirectory.appendingPathComponent(safeName)
        try data.write(to: outURL, options: .atomic)
        return outURL
    }

    public func exportAllWorkspaceData(settings: [String: String]) throws -> URL {
        let conversations = try conversationRepository.fetchConversations()
        var messageMap: [String: [ChatMessage]] = [:]
        for conv in conversations {
            let msgs = try conversationRepository.fetchMessages(conversationID: conv.id).map { msg -> ChatMessage in
                var clean = msg
                clean.content = SecretRedactor.redact(msg.content)
                clean.thinkingContent = msg.thinkingContent.map { SecretRedactor.redact($0) }
                return clean
            }
            messageMap[conv.id] = msgs
        }

        struct WorkspaceBackup: Codable {
            let exportedAt: Date
            let appVersion: String
            let notice: String
            let settings: [String: String]
            let conversations: [ChatConversation]
            let messagesByConversationID: [String: [ChatMessage]]
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = WorkspaceBackup(
            exportedAt: Date(),
            appVersion: AppConfiguration.version,
            notice: "API keys and credentials are intentionally excluded from exports for your security.",
            settings: settings,
            conversations: conversations,
            messagesByConversationID: messageMap
        )
        let data = try encoder.encode(payload)
        let outURL = storagePaths.exportsDirectory.appendingPathComponent("ZinoAgent-Export-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: outURL, options: .atomic)
        return outURL
    }

    private func sanitizedFilename(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = input.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return str.isEmpty ? "Conversation" : String(str.prefix(48))
    }
}
