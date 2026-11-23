import Foundation
import UIKit

public struct PendingToolProposal: Identifiable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public let toolCallID: String
    public let toolName: FileToolName
    public let folderID: String
    public let folderName: String
    public let argumentsJSON: String
    public let previewSummary: String
    public let risk: FileToolRisk
    public let isSuggestionOnly: Bool
}

public enum ToolEvaluationOutcome: Sendable {
    case executed(output: String, ephemeralImage: ChatImagePayload?)
    case requiresConfirmation(PendingToolProposal)
    case denied(reason: String)
}

/// Permission-aware AI tool validator and executor for both Offline (llama.cpp) and Online AI.
/// Covers user-selected folders, Local HTTP Server, Custom Browser (with ephemeral RAM-only screenshots),
/// Workspace Terminal, GitHub Plugin, and Cloudflare Plugin.
public final class FileToolExecutor: @unchecked Sendable {
    private let fileService: FileManagerService
    private let permissionService: PermissionService
    private let storagePaths: AppStoragePaths

    @MainActor public weak var browserService: ZinoBrowserService?
    @MainActor public weak var terminalService: ZinoTerminalService?
    @MainActor public weak var githubPlugin: GitHubPluginService?
    @MainActor public weak var cloudflarePlugin: CloudflarePluginService?

    public init(
        fileService: FileManagerService,
        permissionService: PermissionService,
        storagePaths: AppStoragePaths
    ) {
        self.fileService = fileService
        self.permissionService = permissionService
        self.storagePaths = storagePaths
    }

    /// Builds a live manifest of the user's provided/mounted folders, top-level files, running local server,
    /// and browser state so both Offline and Online AI immediately know the user's folder contents.
    @MainActor
    public func buildLiveWorkspaceContextSummary() -> String {
        let folders = (try? fileService.bookmarks.loadFolders()) ?? []
        guard !folders.isEmpty else {
            return "Mounted Folders: None selected yet."
        }

        let primary = folders[0]
        var lines: [String] = [
            "### User's Mounted Folders & Active Workspace",
            "Active Primary Folder: '\(primary.displayName)' (Permission: \(primary.permissionLevel.displayName))",
            "All Mounted Folders: " + folders.map { "'\($0.displayName)'" }.joined(separator: ", ")
        ]

        if let items = try? fileService.listDirectory(in: primary, directoryURL: nil) {
            let listing = items.prefix(35).map { item in
                item.isDirectory ? "\(item.name)/" : "\(item.name) (\(Formatters.bytes(item.sizeBytes)))"
            }.joined(separator: ", ")
            lines.append("Files in '\(primary.displayName)': \(listing.isEmpty ? "(empty folder)" : listing)")
        }

        if let browser = browserService {
            if browser.localServer.isRunning {
                lines.append("Local HTTP Server: RUNNING at \(browser.localServer.baseURLString) (serving '\(browser.localServer.activeFolder?.displayName ?? primary.displayName)')")
            } else {
                lines.append("Local HTTP Server: Stopped (use `open_in_browser` or `start_local_server` to start automatically)")
            }
            if browser.currentURLString != "about:blank" {
                lines.append("Custom Browser Current Page: \(browser.pageTitle) (\(browser.currentURLString))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Synchronous evaluation entry point for pure-filesystem unit tests and quick checks.
    public func evaluate(
        toolCall: ToolCallRequest,
        conversationID: String,
        globalPermissionLevel: AIPermissionLevel
    ) -> ToolEvaluationOutcome {
        guard let tool = FileToolName(rawValue: toolCall.name) else {
            let reason = "Unknown tool '\(toolCall.name)'."
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: toolCall.name,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: globalPermissionLevel,
                status: "denied",
                resultSummary: reason
            )
            return .denied(reason: reason)
        }

        let args = parseJSONArguments(toolCall.argumentsJSON)
        let folders = (try? fileService.bookmarks.loadFolders()) ?? []
        guard let targetFolder = resolveTargetFolder(requestedName: args["folder_name"] as? String, folders: folders) else {
            let msg = "No folders are mounted. Select a folder in the Files tab first."
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: globalPermissionLevel,
                status: "denied",
                resultSummary: msg
            )
            return .denied(reason: msg)
        }

        let effectiveLevel = stricterPermission(globalPermissionLevel, targetFolder.permissionLevel)

        if tool.risk == .readOnly {
            return executeSyncFilesystemTool(
                tool: tool,
                args: args,
                folder: targetFolder,
                conversationID: conversationID,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel
            )
        }

        switch effectiveLevel {
        case .readOnly:
            let msg = "Operation '\(tool.displayTitle)' blocked: AI permission is set to Read-only."
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel,
                status: "denied",
                resultSummary: msg
            )
            return .denied(reason: msg)

        case .suggest, .confirm:
            let proposal = PendingToolProposal(
                id: UUID().uuidString,
                conversationID: conversationID,
                toolCallID: toolCall.id,
                toolName: tool,
                folderID: targetFolder.id,
                folderName: targetFolder.displayName,
                argumentsJSON: toolCall.argumentsJSON,
                previewSummary: describeProposal(tool: tool, args: args, folderName: targetFolder.displayName),
                risk: tool.risk,
                isSuggestionOnly: effectiveLevel == .suggest
            )
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel,
                status: effectiveLevel == .suggest ? "suggested" : "awaiting_confirmation",
                resultSummary: proposal.previewSummary
            )
            return .requiresConfirmation(proposal)

        case .authorized:
            if tool.risk == .nonDestructiveWrite {
                return executeSyncFilesystemTool(
                    tool: tool,
                    args: args,
                    folder: targetFolder,
                    conversationID: conversationID,
                    argumentsJSON: toolCall.argumentsJSON,
                    permissionLevel: effectiveLevel
                )
            } else {
                let proposal = PendingToolProposal(
                    id: UUID().uuidString,
                    conversationID: conversationID,
                    toolCallID: toolCall.id,
                    toolName: tool,
                    folderID: targetFolder.id,
                    folderName: targetFolder.displayName,
                    argumentsJSON: toolCall.argumentsJSON,
                    previewSummary: describeProposal(tool: tool, args: args, folderName: targetFolder.displayName),
                    risk: tool.risk,
                    isSuggestionOnly: false
                )
                return .requiresConfirmation(proposal)
            }
        }
    }

    /// Async evaluation supporting Browser, Local HTTP Server, Ephemeral RAM Screenshots, Terminal, GitHub, and Cloudflare tools.
    @MainActor
    public func evaluateAsync(
        toolCall: ToolCallRequest,
        conversationID: String,
        globalPermissionLevel: AIPermissionLevel
    ) async -> ToolEvaluationOutcome {
        guard let tool = FileToolName(rawValue: toolCall.name) else {
            return evaluate(toolCall: toolCall, conversationID: conversationID, globalPermissionLevel: globalPermissionLevel)
        }

        switch tool {
        case .startLocalServer, .openInBrowser, .captureBrowserScreenshot,
             .runBrowserJavaScript, .runTerminalCommand, .githubPlugin, .cloudflarePlugin:
            let args = parseJSONArguments(toolCall.argumentsJSON)
            let folders = (try? fileService.bookmarks.loadFolders()) ?? []
            guard let targetFolder = resolveTargetFolder(requestedName: args["folder_name"] as? String, folders: folders) else {
                return .denied(reason: "No mounted folder available.")
            }
            let effectiveLevel = stricterPermission(globalPermissionLevel, targetFolder.permissionLevel)
            if tool.risk != .readOnly {
                if effectiveLevel == .readOnly {
                    return .denied(reason: "Blocked under Read-only permission.")
                }
                if effectiveLevel == .suggest || effectiveLevel == .confirm {
                    let proposal = PendingToolProposal(
                        id: UUID().uuidString,
                        conversationID: conversationID,
                        toolCallID: toolCall.id,
                        toolName: tool,
                        folderID: targetFolder.id,
                        folderName: targetFolder.displayName,
                        argumentsJSON: toolCall.argumentsJSON,
                        previewSummary: describeProposal(tool: tool, args: args, folderName: targetFolder.displayName),
                        risk: tool.risk,
                        isSuggestionOnly: effectiveLevel == .suggest
                    )
                    return .requiresConfirmation(proposal)
                }
            }
            return await executeAsyncWorkspaceTool(
                tool: tool,
                args: args,
                folder: targetFolder,
                conversationID: conversationID,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel
            )
        default:
            return evaluate(toolCall: toolCall, conversationID: conversationID, globalPermissionLevel: globalPermissionLevel)
        }
    }

    public func executeApprovedProposal(_ proposal: PendingToolProposal) -> ToolEvaluationOutcome {
        guard let folder = (try? fileService.bookmarks.loadFolders())?.first(where: { $0.id == proposal.folderID }) else {
            return .denied(reason: "Mounted folder '\(proposal.folderName)' is no longer available.")
        }
        let args = parseJSONArguments(proposal.argumentsJSON)
        return executeSyncFilesystemTool(
            tool: proposal.toolName,
            args: args,
            folder: folder,
            conversationID: proposal.conversationID,
            argumentsJSON: proposal.argumentsJSON,
            permissionLevel: .confirm
        )
    }

    @MainActor
    public func executeApprovedProposalAsync(_ proposal: PendingToolProposal) async -> ToolEvaluationOutcome {
        guard let folder = (try? fileService.bookmarks.loadFolders())?.first(where: { $0.id == proposal.folderID }) else {
            return .denied(reason: "Mounted folder '\(proposal.folderName)' is no longer available.")
        }
        let args = parseJSONArguments(proposal.argumentsJSON)
        switch proposal.toolName {
        case .startLocalServer, .openInBrowser, .captureBrowserScreenshot,
             .runBrowserJavaScript, .runTerminalCommand, .githubPlugin, .cloudflarePlugin:
            return await executeAsyncWorkspaceTool(
                tool: proposal.toolName,
                args: args,
                folder: folder,
                conversationID: proposal.conversationID,
                argumentsJSON: proposal.argumentsJSON,
                permissionLevel: .confirm
            )
        default:
            return executeSyncFilesystemTool(
                tool: proposal.toolName,
                args: args,
                folder: folder,
                conversationID: proposal.conversationID,
                argumentsJSON: proposal.argumentsJSON,
                permissionLevel: .confirm
            )
        }
    }

    public func rejectProposal(_ proposal: PendingToolProposal) {
        permissionService.logToolActivity(
            conversationID: proposal.conversationID,
            toolName: proposal.toolName.rawValue,
            argumentsJSON: proposal.argumentsJSON,
            permissionLevel: .confirm,
            status: "rejected_by_user",
            resultSummary: "User declined: \(proposal.previewSummary)"
        )
    }

    // MARK: - Async Browser / Server / Terminal / Plugin Execution

    @MainActor
    private func executeAsyncWorkspaceTool(
        tool: FileToolName,
        args: [String: Any],
        folder: MountedFolder,
        conversationID: String,
        argumentsJSON: String,
        permissionLevel: AIPermissionLevel
    ) async -> ToolEvaluationOutcome {
        do {
            var output = ""
            var ephemeralImagePayload: ChatImagePayload?

            switch tool {
            case .startLocalServer:
                guard let browser = browserService else {
                    throw ZinoError(.networkFailure, "Browser service is unavailable.")
                }
                let port = (args["port"] as? Int).map { UInt16(clamping: $0) } ?? 8080
                let baseURL = try browser.localServer.start(serving: folder, preferredPort: port)
                output = "Started Local HTTP Server at \(baseURL) serving folder '\(folder.displayName)'."

            case .openInBrowser:
                guard let browser = browserService else {
                    throw ZinoError(.networkFailure, "Browser service is unavailable.")
                }
                let rel = (args["relative_path"] as? String) ?? ""
                let openedURL: String
                if rel.hasPrefix("http://") || rel.hasPrefix("https://") {
                    browser.loadURLString(rel)
                    openedURL = rel
                } else {
                    openedURL = try browser.serveAndOpenFile(relativePath: rel, in: folder)
                }
                // Wait briefly for WKWebView to render and capture an ephemeral RAM-only snapshot automatically!
                try? await Task.sleep(nanoseconds: 550_000_000)
                let snap = await browser.captureEphemeralVisionSnapshot()
                if let png = snap.inMemoryPNGData {
                    ephemeralImagePayload = ChatImagePayload(mimeType: "image/png", base64Data: png.base64EncodedString())
                }
                output = """
                Opened \(openedURL) in ZinoAgent Custom Browser (serving '\(folder.displayName)').
                [Ephemeral RAM-Only Page Inspection — Not Saved to Device]
                \(snap.domSummary)
                Console Logs: \(snap.consoleLogs.isEmpty ? "No errors" : snap.consoleLogs.joined(separator: " | "))
                """

            case .captureBrowserScreenshot:
                guard let browser = browserService else {
                    throw ZinoError(.networkFailure, "Browser service is unavailable.")
                }
                let snap = await browser.captureEphemeralVisionSnapshot()
                if let png = snap.inMemoryPNGData {
                    ephemeralImagePayload = ChatImagePayload(mimeType: "image/png", base64Data: png.base64EncodedString())
                }
                output = """
                [Ephemeral RAM-Only Browser Screenshot & DOM Inspection — Not Saved to Device]
                \(snap.domSummary)
                Console Logs:
                \(snap.consoleLogs.isEmpty ? "(No console errors)" : snap.consoleLogs.joined(separator: "\n"))
                """

            case .runBrowserJavaScript:
                guard let browser = browserService else {
                    throw ZinoError(.networkFailure, "Browser service is unavailable.")
                }
                let script = (args["script"] as? String) ?? ""
                let res = try await browser.evaluateJavaScript(script)
                output = "Browser JS Result:\n\(res)"

            case .runTerminalCommand:
                guard let term = terminalService else {
                    throw ZinoError(.ioFailure, "Terminal service is unavailable.")
                }
                let cmd = (args["command"] as? String) ?? ""
                output = await term.execute(cmd)

            case .githubPlugin:
                guard let gh = githubPlugin else {
                    throw ZinoError(.providerNotConfigured, "GitHub plugin service is unavailable.")
                }
                let action = ((args["action"] as? String) ?? "whoami").lowercased()
                let repo = (args["repo"] as? String) ?? gh.defaultRepository
                switch action {
                case "whoami":
                    let user = try await gh.verifyAndFetchUser()
                    output = "GitHub authenticated as @\(user)."
                case "list_repos":
                    let repos = try await gh.listRepositories()
                    output = repos.map { "\($0.fullName) (\($0.isPrivate ? "private" : "public"))" }.joined(separator: "\n")
                case "list_files":
                    let path = (args["path"] as? String) ?? ""
                    let files = try await gh.listFiles(repoFullName: repo, path: path)
                    output = files.map { "[\($0.type)] \($0.path) (\($0.size) B)" }.joined(separator: "\n")
                case "read_file":
                    let path = (args["path"] as? String) ?? ""
                    output = try await gh.readFileContent(repoFullName: repo, path: path)
                case "push_local_file":
                    let localRel = (args["local_path"] as? String) ?? ""
                    let remotePath = (args["path"] as? String)?.isEmpty == false ? (args["path"] as! String) : localRel
                    let commitMsg = (args["message"] as? String) ?? "Update \(remotePath) from ZinoAgent 2.0"
                    let rootURL = try fileService.bookmarks.resolveURL(for: folder)
                    let fileURL = try resolveRelative(localRel, in: rootURL)
                    let data = try Data(contentsOf: fileURL)
                    output = try await gh.pushFile(repoFullName: repo, remotePath: remotePath, contentData: data, commitMessage: commitMsg)
                case "list_issues":
                    let issues = try await gh.listIssues(repoFullName: repo)
                    output = issues.isEmpty ? "No open issues." : issues.map { "#\($0.number) \($0.title)" }.joined(separator: "\n")
                case "create_issue":
                    let title = (args["message"] as? String) ?? "New Issue"
                    let body = (args["body"] as? String) ?? ""
                    output = try await gh.createIssue(repoFullName: repo, title: title, body: body)
                default:
                    throw ZinoError(.invalidArgument, "Unknown github_plugin action '\(action)'.")
                }

            case .cloudflarePlugin:
                guard let cf = cloudflarePlugin else {
                    throw ZinoError(.providerNotConfigured, "Cloudflare plugin service is unavailable.")
                }
                let action = ((args["action"] as? String) ?? "verify").lowercased()
                switch action {
                case "verify", "whoami":
                    output = try await cf.verifyAndDiscoverAccounts()
                case "list_zones":
                    let zones = try await cf.listZones()
                    output = zones.isEmpty ? "No zones found." : zones.map { "\($0.name) [zone_id: \($0.id)] (\($0.status))" }.joined(separator: "\n")
                case "list_dns":
                    let zoneID = (args["zone_id"] as? String) ?? ""
                    let recs = try await cf.listDNSRecords(zoneID: zoneID)
                    output = recs.map { "\($0.type) \($0.name) -> \($0.content)" }.joined(separator: "\n")
                case "create_dns":
                    let zoneID = (args["zone_id"] as? String) ?? ""
                    let type = (args["dns_type"] as? String) ?? "A"
                    let name = (args["dns_name"] as? String) ?? ""
                    let content = (args["dns_content"] as? String) ?? ""
                    output = try await cf.createDNSRecord(zoneID: zoneID, type: type, name: name, content: content)
                case "list_workers":
                    let workers = try await cf.listWorkers()
                    output = workers.isEmpty ? "No Workers found." : workers.map(\.id).joined(separator: "\n")
                case "deploy_worker":
                    let workerName = (args["worker_name"] as? String) ?? ""
                    let localRel = (args["local_path"] as? String) ?? ""
                    let rootURL = try fileService.bookmarks.resolveURL(for: folder)
                    let fileURL = try resolveRelative(localRel, in: rootURL)
                    let jsCode = try String(contentsOf: fileURL, encoding: .utf8)
                    output = try await cf.deployWorkerScript(scriptName: workerName, javascriptContent: jsCode)
                case "list_pages":
                    let pages = try await cf.listPagesProjects()
                    output = pages.isEmpty ? "No Pages projects." : pages.joined(separator: "\n")
                case "list_d1":
                    let dbs = try await cf.listD1Databases()
                    output = dbs.isEmpty ? "No D1 databases." : dbs.joined(separator: "\n")
                default:
                    throw ZinoError(.invalidArgument, "Unknown cloudflare_plugin action '\(action)'.")
                }

            default:
                return executeSyncFilesystemTool(
                    tool: tool,
                    args: args,
                    folder: folder,
                    conversationID: conversationID,
                    argumentsJSON: argumentsJSON,
                    permissionLevel: permissionLevel
                )
            }

            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: argumentsJSON,
                permissionLevel: permissionLevel,
                status: "executed",
                resultSummary: String(output.prefix(240))
            )
            return .executed(output: output, ephemeralImage: ephemeralImagePayload)
        } catch {
            let reason = error.localizedDescription
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: argumentsJSON,
                permissionLevel: permissionLevel,
                status: "error",
                resultSummary: reason
            )
            return .denied(reason: reason)
        }
    }

    // MARK: - Synchronous Scoped Filesystem Tools

    private func executeSyncFilesystemTool(
        tool: FileToolName,
        args: [String: Any],
        folder: MountedFolder,
        conversationID: String,
        argumentsJSON: String,
        permissionLevel: AIPermissionLevel
    ) -> ToolEvaluationOutcome {
        do {
            let rootURL = try fileService.bookmarks.resolveURL(for: folder)
            let output: String

            switch tool {
            case .listFiles:
                let rel = (args["relative_path"] as? String) ?? ""
                let dir = try resolveRelative(rel, in: rootURL)
                let items = try fileService.listDirectory(in: folder, directoryURL: dir)
                if items.isEmpty {
                    output = "Folder '\(folder.displayName)/\(rel)' is empty."
                } else {
                    output = items.map { item in
                        let tag = item.isDirectory ? "[DIR]" : "[\(item.fileExtension.uppercased())]"
                        return "\(tag) \(item.name) — \(Formatters.bytes(item.sizeBytes))"
                    }.joined(separator: "\n")
                }

            case .searchFiles:
                let query = (args["query"] as? String) ?? ""
                let items = try fileService.searchFiles(in: folder, query: query, maxResults: 60)
                if items.isEmpty {
                    output = "No files matching '\(query)' found in '\(folder.displayName)'."
                } else {
                    output = items.map { item in
                        let rel = item.url.path.replacingOccurrences(of: rootURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        return "\(rel) (\(Formatters.bytes(item.sizeBytes)))"
                    }.joined(separator: "\n")
                }

            case .getFileMetadata:
                guard let rel = args["relative_path"] as? String else {
                    throw ZinoError(.invalidArgument, "relative_path is required.")
                }
                let url = try resolveRelative(rel, in: rootURL)
                let item = try fileService.itemMetadata(in: folder, at: url)
                output = """
                Name: \(item.name)
                Category: \(item.category.displayName)
                Directory: \(item.isDirectory)
                Size: \(Formatters.bytes(item.sizeBytes)) (\(item.sizeBytes) bytes)
                MIME: \(item.mimeType)
                Modified: \(item.modifiedAt.map(Formatters.timestamp) ?? "Unknown")
                """

            case .readSupportedDocument, .summarizeDocument:
                guard let rel = args["relative_path"] as? String else {
                    throw ZinoError(.invalidArgument, "relative_path is required.")
                }
                let url = try resolveRelative(rel, in: rootURL)
                let limit = (tool == .summarizeDocument) ? 18_000 : 32_000
                let extracted = try fileService.readDocument(in: folder, at: url, maxCharacters: limit)
                let pageNote = extracted.pageCount.map { " (\($0) pages)" } ?? ""
                let truncNote = extracted.truncated ? "\n[Note: truncated to \(limit) characters]" : ""
                output = "Document: \(extracted.title) [\(extracted.format)\(pageNote)]\n\n\(extracted.text)\(truncNote)"

            case .createFolder:
                guard let name = args["name"] as? String else {
                    throw ZinoError(.invalidArgument, "name is required.")
                }
                let parentRel = (args["parent_relative_path"] as? String) ?? ""
                let parentURL = try resolveRelative(parentRel, in: rootURL)
                let created = try fileService.createFolder(in: folder, parentDirectory: parentURL, name: name)
                output = "Created folder '\(created.lastPathComponent)' inside '\(folder.displayName)'."

            case .renameFile:
                guard let rel = args["relative_path"] as? String,
                      let newName = args["new_name"] as? String else {
                    throw ZinoError(.invalidArgument, "relative_path and new_name are required.")
                }
                let src = try resolveRelative(rel, in: rootURL)
                let renamed = try fileService.renameItem(in: folder, at: src, newName: newName)
                output = "Renamed '\(src.lastPathComponent)' to '\(renamed.lastPathComponent)'."

            case .copyFile:
                guard let srcRel = args["source_relative_path"] as? String,
                      let destDirRel = args["destination_directory"] as? String else {
                    throw ZinoError(.invalidArgument, "source_relative_path and destination_directory are required.")
                }
                let src = try resolveRelative(srcRel, in: rootURL)
                let destDir = try resolveRelative(destDirRel, in: rootURL)
                let newName = args["new_name"] as? String
                let copied = try fileService.copyItem(in: folder, from: src, toDirectory: destDir, newName: newName)
                output = "Copied '\(src.lastPathComponent)' to '\(copied.lastPathComponent)'."

            case .moveFile:
                guard let srcRel = args["source_relative_path"] as? String,
                      let destDirRel = args["destination_directory"] as? String else {
                    throw ZinoError(.invalidArgument, "source_relative_path and destination_directory are required.")
                }
                let src = try resolveRelative(srcRel, in: rootURL)
                let destDir = try resolveRelative(destDirRel, in: rootURL)
                let moved = try fileService.moveItem(in: folder, from: src, toDirectory: destDir)
                output = "Moved '\(src.lastPathComponent)' to '\(moved.path)'."

            case .exportFile:
                guard let rel = args["relative_path"] as? String else {
                    throw ZinoError(.invalidArgument, "relative_path is required.")
                }
                let src = try resolveRelative(rel, in: rootURL)
                let exportedURL: URL = try fileService.bookmarks.withScopedAccess(for: folder) { scopedRoot in
                    let safeSrc = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: src, root: scopedRoot)
                    let exportTarget = storagePaths.exportsDirectory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(safeSrc.lastPathComponent)")
                    try FileManager.default.copyItem(at: safeSrc, to: exportTarget)
                    return exportTarget
                }
                output = "Exported '\(src.lastPathComponent)' to app Exports (\(exportedURL.lastPathComponent))."

            case .generateFile:
                guard let filename = args["filename"] as? String,
                      let content = args["content"] as? String else {
                    throw ZinoError(.invalidArgument, "filename and content are required.")
                }
                let dirRel = (args["directory_relative_path"] as? String) ?? ""
                let allowOverwrite = (args["overwrite"] as? Bool) ?? false
                let dirURL = try resolveRelative(dirRel, in: rootURL)
                let created = try fileService.writeNewFile(
                    in: folder,
                    directory: dirURL,
                    filename: filename,
                    content: content,
                    allowOverwrite: allowOverwrite
                )
                output = "Saved file '\(created.lastPathComponent)' (\(content.utf8.count) bytes) in '\(folder.displayName)'."

            default:
                throw ZinoError(.invalidArgument, "Tool '\(tool.rawValue)' requires async workspace execution.")
            }

            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: argumentsJSON,
                permissionLevel: permissionLevel,
                status: "executed",
                resultSummary: String(output.prefix(240))
            )
            return .executed(output: output, ephemeralImage: nil)
        } catch {
            let reason = error.localizedDescription
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: argumentsJSON,
                permissionLevel: permissionLevel,
                status: "error",
                resultSummary: reason
            )
            return .denied(reason: reason)
        }
    }

    private func resolveTargetFolder(requestedName: String?, folders: [MountedFolder]) -> MountedFolder? {
        guard !folders.isEmpty else { return nil }
        if let requested = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            if let exact = folders.first(where: { $0.displayName.caseInsensitiveCompare(requested) == .orderedSame }) {
                return exact
            }
        }
        return folders[0]
    }

    private func resolveRelative(_ relativePath: String, in rootURL: URL) throws -> URL {
        let cleaned = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleaned.contains("..") {
            throw ZinoError(.pathOutOfScope, "Path traversal ('..') is not permitted.")
        }
        let candidate = cleaned.isEmpty ? rootURL : rootURL.appendingPathComponent(cleaned)
        return try SecurityScopedBookmarkManager.ensureInsideScope(candidate: candidate, root: rootURL)
    }

    private func stricterPermission(_ a: AIPermissionLevel, _ b: AIPermissionLevel) -> AIPermissionLevel {
        let order: [AIPermissionLevel] = [.readOnly, .suggest, .confirm, .authorized]
        let idxA = order.firstIndex(of: a) ?? 0
        let idxB = order.firstIndex(of: b) ?? 0
        return order[min(idxA, idxB)]
    }

    private func describeProposal(tool: FileToolName, args: [String: Any], folderName: String) -> String {
        switch tool {
        case .createFolder:
            return "Create folder '\(args["name"] as? String ?? "?")' in \(folderName)"
        case .renameFile:
            return "Rename '\(args["relative_path"] as? String ?? "?")' to '\(args["new_name"] as? String ?? "?")' in \(folderName)"
        case .copyFile:
            return "Copy '\(args["source_relative_path"] as? String ?? "?")' into '\(args["destination_directory"] as? String ?? "/")' (\(folderName))"
        case .moveFile:
            return "Move '\(args["source_relative_path"] as? String ?? "?")' into '\(args["destination_directory"] as? String ?? "/")' (\(folderName))"
        case .exportFile:
            return "Export '\(args["relative_path"] as? String ?? "?")' from \(folderName)"
        case .generateFile:
            return "Write file '\(args["filename"] as? String ?? "?")' in \(folderName)"
        case .runTerminalCommand:
            return "Run terminal command '\(args["command"] as? String ?? "?")' in \(folderName)"
        case .runBrowserJavaScript:
            return "Run JavaScript in Custom Browser"
        case .githubPlugin:
            return "GitHub Plugin: \(args["action"] as? String ?? "action")"
        case .cloudflarePlugin:
            return "Cloudflare Plugin: \(args["action"] as? String ?? "action")"
        default:
            return "\(tool.displayTitle) in \(folderName)"
        }
    }

    private func parseJSONArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
