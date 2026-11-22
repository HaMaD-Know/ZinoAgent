import XCTest
@testable import ZinoAgent

final class AppDatabaseTests: XCTestCase {
    func testMigrationsApplyCleanly() throws {
        let db = try AppDatabase.inMemory()
        let version = try db.currentSchemaVersion()
        XCTAssertGreaterThanOrEqual(version, 2)
    }

    func testConversationAndAttachmentPersistenceAndCascadeDelete() throws {
        let db = try AppDatabase.inMemory()
        let repo = ConversationRepository(database: db)

        let conv = ChatConversation(title: "Project Alpha", mode: .offline, modelID: "qwen2.5-3b")
        try repo.createConversation(conv)

        let att = ChatAttachment(
            kind: .file,
            filename: "notes.md",
            filePath: "/tmp/notes.md",
            mimeType: "text/markdown",
            fileSizeBytes: 512,
            extractedPreview: "# Notes"
        )
        let msg = ChatMessage(
            conversationID: conv.id,
            role: .user,
            content: "Summarize notes.md",
            attachments: [att]
        )
        try repo.saveMessage(msg)

        let fetched = try repo.fetchMessages(conversationID: conv.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].attachments.count, 1)
        XCTAssertEqual(fetched[0].attachments[0].filename, "notes.md")

        try repo.deleteConversation(id: conv.id)
        let afterDelete = try repo.fetchMessages(conversationID: conv.id)
        XCTAssertTrue(afterDelete.isEmpty, "Deleting conversation must cascade-delete messages.")
    }

    @MainActor
    func testProviderRegistryStoresKeyOnlyInKeychainAndNotDatabase() throws {
        let db = try AppDatabase.inMemory()
        let keychain = InMemoryKeychainService()
        let registry = ProviderRegistry(database: db, keychain: keychain)

        let secret = "sk-test-super-secret-key-9876543210"
        let provider = ProviderConfiguration(name: "OpenAI Test", providerType: .openAI)
        try registry.saveProvider(provider, apiKey: secret)

        XCTAssertTrue(registry.hasCredential(for: provider))
        XCTAssertEqual(registry.maskedCredential(for: provider), "••••3210")

        // Ensure raw secret does not appear anywhere in SQLite ai_providers table.
        let rows = try db.sqlite.query("SELECT * FROM ai_providers;")
        XCTAssertEqual(rows.count, 1)
        for row in rows {
            XCTAssertNotEqual(row.string("keychain_account"), secret)
            XCTAssertNotEqual(row.string("name"), secret)
        }

        // Deleting provider must also purge credential from Keychain.
        try registry.deleteProvider(id: provider.id)
        XCTAssertFalse(keychain.hasSecret(forAccount: provider.keychainAccount))
    }

    @MainActor
    func testSettingsManagerPersistsAcrossReinitialization() throws {
        let db = try AppDatabase.inMemory()
        let first = SettingsManager(database: db)
        first.appearance = .dark
        first.baselineContextTarget = 8192
        first.aiFilePermissionLevel = .readOnly

        let second = SettingsManager(database: db)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertEqual(second.baselineContextTarget, 8192)
        XCTAssertEqual(second.aiFilePermissionLevel, .readOnly)
    }
}
