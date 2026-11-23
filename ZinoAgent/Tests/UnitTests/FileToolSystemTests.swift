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
        guard case let .executed(output, _) = execOutcome else {
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

    func testExtractsOfflineStructuredToolCallsForSnakeGameAndBrowser() {
        let modelOutput = """
        I will create snake.html in your folder and open it in the browser with the local server:
        <tool_call>{"name": "generate_file", "arguments": {"filename": "snake.html", "content": "<!DOCTYPE html><html><body><canvas id='game'></canvas></body></html>"}}</tool_call>
        <tool_call>{"name": "open_in_browser", "arguments": {"relative_path": "snake.html"}}</tool_call>
        """
        let calls = FileToolDefinitions.extractStructuredToolCalls(from: modelOutput)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "generate_file")
        XCTAssertEqual(calls[1].name, "open_in_browser")
    }

    @MainActor
    func testLocalHTTPServerServesGeneratedSnakeGameFromMountedFolder() async throws {
        // 1. AI generates snake.html in the user's mounted folder
        let genCall = ToolCallRequest(
            name: "generate_file",
            argumentsJSON: "{\"filename\": \"snake.html\", \"content\": \"<!DOCTYPE html><html><head><title>Zino Snake</title></head><body><h1>Snake Game Ready</h1></body></html>\"}"
        )
        let genOutcome = executor.evaluate(toolCall: genCall, conversationID: "c-snake", globalPermissionLevel: .authorized)
        guard case let .executed(msg, _) = genOutcome else {
            XCTFail("Expected snake.html creation to succeed.")
            return
        }
        XCTAssertTrue(msg.contains("snake.html"))

        // 2. Start LocalHTTPServer serving the mounted folder
        let server = LocalHTTPServer(bookmarks: bookmarks)
        let baseURL = try server.start(serving: mountedFolder, preferredPort: 8085)
        defer { server.stop() }

        // Give NWListener a brief moment to enter ready state on loopback
        try await Task.sleep(nanoseconds: 150_000_000)

        let url = URL(string: "\(baseURL)/snake.html")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResp = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResp.statusCode, 200)
        let html = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("Snake Game Ready"))
    }

    @MainActor
    func testWorkspaceTerminalAndSkillRegistry() async throws {
        let server = LocalHTTPServer(bookmarks: bookmarks)
        let browser = ZinoBrowserService(localServer: server, bookmarks: bookmarks)
        let keychain = InMemoryKeychainService()
        let gh = GitHubPluginService(database: db, keychain: keychain)
        let cf = CloudflarePluginService(database: db, keychain: keychain)
        let skills = SkillRegistryService(database: db)
        let monitor = SystemResourceMonitor()
        let terminal = ZinoTerminalService(
            fileService: fileService,
            browserService: browser,
            githubPlugin: gh,
            cloudflarePlugin: cf,
            skillRegistry: skills,
            resourceMonitor: monitor
        )

        // Built-in skills seeded including web-game-builder
        XCTAssertGreaterThanOrEqual(skills.skills.count, 5)
        let promptBlock = skills.activeSkillsPromptBlock(for: "make a snake game and open in browser")
        XCTAssertTrue(promptBlock.contains("web-game-builder"))

        // Terminal JavaScript runtime & file listing
        let jsOut = await terminal.execute("js 6 * 7")
        XCTAssertEqual(jsOut.trimmingCharacters(in: .whitespacesAndNewlines), "42")

        let lsOut = await terminal.execute("ls")
        XCTAssertTrue(lsOut.contains("readme.txt"))
    }
}
