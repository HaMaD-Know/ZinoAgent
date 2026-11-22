import XCTest
@testable import ZinoAgent

final class WorkspaceIntegrationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZinoIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testScopedFileLifecycleWithCreateRenameDuplicateDeleteAndUndoRestore() throws {
        let db = try AppDatabase.inMemory()
        let bookmarks = SecurityScopedBookmarkManager(database: db)
        let service = FileManagerService(database: db, bookmarks: bookmarks)

        let folderDir = tempRoot.appendingPathComponent("MountedDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        let folder = try bookmarks.addFolder(url: folderDir)

        // Create subfolder & file
        let sub = try service.createFolder(in: folder, parentDirectory: folderDir, name: "Reports")
        let noteURL = try service.writeNewFile(in: folder, directory: sub, filename: "summary.md", content: "# Q4 Summary\nAll metrics verified.")

        // Read document text
        let extracted = try service.readDocument(in: folder, at: noteURL)
        XCTAssertTrue(extracted.text.contains("All metrics verified."))

        // Rename & duplicate
        let renamed = try service.renameItem(in: folder, at: noteURL, newName: "q4_summary.md")
        XCTAssertEqual(renamed.lastPathComponent, "q4_summary.md")
        let dup = try service.duplicateItem(in: folder, at: renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dup.path))

        // Search
        let found = try service.searchFiles(in: folder, query: "q4_summary")
        XCTAssertEqual(found.count, 2)

        // Soft delete + Undo restore
        try service.deleteItem(in: folder, at: renamed, allowRestore: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        let undoMessage = try service.undoLastOperation(in: folder)
        XCTAssertTrue(undoMessage.contains("Restored"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testConversationExportScrubsRegisteredSecrets() throws {
        let db = try AppDatabase.inMemory()
        let repo = ConversationRepository(database: db)
        let storagePaths = AppStoragePaths(
            baseURL: tempRoot.appendingPathComponent("App", isDirectory: true),
            cacheBaseURL: tempRoot.appendingPathComponent("Cache", isDirectory: true)
        )
        let exporter = ExportService(storagePaths: storagePaths, conversationRepository: repo)

        let secret = "sk-live-secret-token-998877665544"
        SecretRedactor.register(secret: secret)

        let conv = ChatConversation(title: "Security Check", mode: .online)
        try repo.createConversation(conv)
        try repo.saveMessage(ChatMessage(conversationID: conv.id, role: .user, content: "Accidentally pasted \(secret)"))

        let mdURL = try exporter.exportConversationMarkdown(conversation: conv)
        let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertFalse(mdContent.contains(secret))
        XCTAssertTrue(mdContent.contains("[REDACTED]"))
    }
}
