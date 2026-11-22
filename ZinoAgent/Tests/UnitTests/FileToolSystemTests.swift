import XCTest
@testable import ZinoAgent

final class FileToolSystemTests: XCTestCase {
    private var tempRoot: URL!
    private var db: AppDatabase!
    private var bookmarks: SecurityScopedBookmarkManager!
    private var fileService: FileManagerService!
    private var permissionService: PermissionService!
    private var executor: FileToolExecutor!
    private var mountedFolder: MountedFolder!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ZinoToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        db = try AppDatabase.inMemory()
        bookmarks = SecurityScopedBookmarkManager(database: db)
        fileService = FileManagerService(database: db, bookmarks: bookmarks)
        permissionService = PermissionService(database: db)
        let storagePaths = AppStoragePaths(
            baseURL: tempRoot.appendingPathComponent("AppData", isDirectory: true),
            cacheBaseURL: tempRoot.appendingPathComponent("Caches", isDirectory: true)
        )
        executor = FileToolExecutor(fileService: fileService, permissionService: permissionService, storagePaths: storagePaths)

        let workspaceDir = tempRoot.appendingPathComponent("UserWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try "Hello from ZinoAgent 2.0".write(to: workspaceDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        mountedFolder = try bookmarks.addFolder(url: workspaceDir, permissionLevel: .authorized)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testBlocksPathTraversalOutsideSelectedFolder() {
        let call = ToolCallRequest(name: "read_supported_document", argumentsJSON: "{\"relative_path\": \"../../etc/passwd\"}")
        let outcome = executor.evaluate(toolCall: call, conversationID: "c1", globalPermissionLevel: .authorized)
        if case let .denied(reason) = outcome {
            XCTAssertTrue(reason.lowercased().contains("traversal") || reason.lowercased().contains("outside"))
        } else {
            XCTFail("Expected path traversal attempt to be denied.")
        }
    }

    func testReadOnlyPermissionBlocksWriteTools() {
        let call = ToolCallRequest(name: "create_folder", argumentsJSON: "{\"name\": \"SecretDir\"}")
        let outcome = executor.evaluate(toolCall: call, conversationID: "c1", globalPermissionLevel: .readOnly)
        if case .denied = outcome {
            // Expected
        } else {
            XCTFail("Write tool must be denied under Read-only permission.")
        }
    }

    func testConfirmPermissionRequiresUserApprovalBeforeExecuting() throws {
        let call = ToolCallRequest(name: "create_folder", argumentsJSON: "{\"name\": \"ApprovedDocs\"}")
        let outcome = executor.evaluate(toolCall: call, conversationID: "c1", globalPermissionLevel: .confirm)
        guard case let .requiresConfirmation(proposal) = outcome else {
            XCTFail("Expected confirmation proposal under Confirm permission.")
            return
        }

        let execOutcome = executor.executeApprovedProposal(proposal)
        guard case let .executed(output) = execOutcome else {
            XCTFail("Expected approved proposal to execute cleanly.")
            return
        }
        XCTAssertTrue(output.contains("ApprovedDocs"))

        let logs = try permissionService.fetchToolActivityLog(limit: 10)
        XCTAssertFalse(logs.isEmpty)
    }

    func testGenerateFileRefusesSilentOverwrite() {
        let call = ToolCallRequest(name: "generate_file", argumentsJSON: "{\"filename\": \"readme.txt\", \"content\": \"Overwritten!\"}")
        let outcome = executor.evaluate(toolCall: call, conversationID: "c1", globalPermissionLevel: .authorized)
        if case let .denied(reason) = outcome {
            XCTAssertTrue(reason.lowercased().contains("already exists"))
        } else {
            XCTFail("generate_file must never silently overwrite an existing user file.")
        }
    }
}
