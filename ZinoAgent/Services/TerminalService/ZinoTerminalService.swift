import Foundation
import JavaScriptCore
import CryptoKit
import Combine

public struct TerminalTranscriptLine: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case command
        case output
        case error
        case system
    }

    public let id = UUID()
    public let timestamp: Date
    public let kind: Kind
    public let text: String
}

/// iPadOS Workspace Terminal & JavaScriptCore Runtime operating directly inside the user's mounted folders.
/// Accessible interactively in the Terminal tab and programmatically by both Offline and Online AI.
@MainActor
public final class ZinoTerminalService: ObservableObject {
    @Published public private(set) var transcript: [TerminalTranscriptLine] = []
    @Published public private(set) var commandHistory: [String] = []
    @Published public private(set) var activeFolder: MountedFolder?
    @Published public private(set) var currentRelativeDirectory: String = ""

    private let fileService: FileManagerService
    private let browserService: ZinoBrowserService
    private let githubPlugin: GitHubPluginService
    private let cloudflarePlugin: CloudflarePluginService
    private let skillRegistry: SkillRegistryService
    private let resourceMonitor: SystemResourceMonitor
    private let http: HTTPClient

    public init(
        fileService: FileManagerService,
        browserService: ZinoBrowserService,
        githubPlugin: GitHubPluginService,
        cloudflarePlugin: CloudflarePluginService,
        skillRegistry: SkillRegistryService,
        resourceMonitor: SystemResourceMonitor,
        http: HTTPClient = HTTPClient()
    ) {
        self.fileService = fileService
        self.browserService = browserService
        self.githubPlugin = githubPlugin
        self.cloudflarePlugin = cloudflarePlugin
        self.skillRegistry = skillRegistry
        self.resourceMonitor = resourceMonitor
        self.http = http

        syncActiveFolder()
        append(.system, "ZinoAgent 2.0 Workspace Terminal • Type 'help' for commands (ls, cd, cat, write, serve, open, js/node, gh, cf, curl).")
    }

    public var promptDisplay: String {
        let folderName = activeFolder?.displayName ?? "Workspace"
        let rel = currentRelativeDirectory.isEmpty ? "~" : "~/\(currentRelativeDirectory)"
        return "\(folderName):\(rel) $"
    }

    public func syncActiveFolder() {
        let folders = (try? fileService.bookmarks.loadFolders()) ?? []
        if let active = activeFolder, let refreshed = folders.first(where: { $0.id == active.id }) {
            activeFolder = refreshed
        } else {
            activeFolder = folders.first
            currentRelativeDirectory = ""
        }
    }

    public func switchMountedFolder(_ folder: MountedFolder) {
        activeFolder = folder
        currentRelativeDirectory = ""
        append(.system, "Switched active folder to '\(folder.displayName)'.")
    }

    public func clearTranscript() {
        transcript.removeAll()
    }

    /// Executes a command line and returns its textual output (for both interactive Terminal UI and AI tool calls).
    @discardableResult
    public func execute(_ rawCommandLine: String) async -> String {
        let trimmed = rawCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        syncActiveFolder()
        commandHistory.append(trimmed)
        append(.command, "\(promptDisplay) \(trimmed)")

        let tokens = Self.tokenizeCommand(trimmed)
        guard let cmd = tokens.first?.lowercased() else { return "" }
        let args = Array(tokens.dropFirst())

        if cmd == "clear" {
            clearTranscript()
            return "Cleared terminal."
        }

        do {
            let output = try await dispatchCommand(cmd: cmd, args: args, rawLine: trimmed)
            if !output.isEmpty {
                append(.output, output)
            }
            return output
        } catch {
            let errText = "error: \(error.localizedDescription)"
            append(.error, errText)
            return errText
        }
    }

    private func dispatchCommand(cmd: String, args: [String], rawLine: String) async throws -> String {
        switch cmd {
        case "help":
            return """
            Available Workspace Commands:
              Folder & Files:
                pwd                          Show current mounted folder & path
                folders                      List mounted folders; 'folder <name>' switches active folder
                ls [-la] [dir]               List directory contents
                cd <dir>                     Change directory inside mounted folder
                cat <file>                   Print file contents
                head [-n N] <file>           Print first N lines of a file
                mkdir <name>                 Create a folder
                touch <file>                 Create an empty file
                write <file> <content...>    Write UTF-8 text into a file
                cp <src> <dst_dir>           Copy file into destination directory
                mv <src> <dst_dir_or_name>   Move or rename file
                rm <file>                    Move item to recoverable folder trash (.zino_trash)
                find <query>                 Search files recursively
                grep <pattern> [file]        Search text inside a file or current directory
                tree                         Display directory hierarchy
                sha256 <file>                Compute SHA-256 prefix of a file

              Local Server & Browser:
                serve [port]                 Start Local HTTP Server on active folder (default port 8080)
                server stop | status         Stop or inspect the Local HTTP Server
                open <file.html | url>       Serve local HTML file (or URL) and open in Custom Browser
                inspect                      Capture ephemeral RAM-only browser DOM/Canvas/Console snapshot

              Runtimes & Plugins:
                js <expression>              Evaluate JavaScript with JavaScriptCore
                node <script.js>             Execute a .js file from the mounted folder
                curl <url>                   Perform an HTTP/HTTPS GET request
                gh <whoami|repos|files|cat|push|issues>   GitHub Plugin CLI
                cf <whoami|zones|dns|workers|deploy|pages|d1>  Cloudflare Plugin CLI
                skills                       List active AI skills
                sysinfo                      Show iPad RAM headroom, thermal state & storage
                clear                        Clear terminal output
            """

        case "pwd":
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let dir = try currentDirectoryURL(root: root)
            return "Folder: \(folder.displayName)\nPath: /\(currentRelativeDirectory)\nResolved: \(dir.path)"

        case "folders":
            let folders = try fileService.bookmarks.loadFolders()
            return folders.map { f in
                let marker = (f.id == activeFolder?.id) ? "* " : "  "
                return "\(marker)\(f.displayName) [\(f.permissionLevel.displayName)]"
            }.joined(separator: "\n")

        case "folder":
            let target = args.joined(separator: " ")
            let folders = try fileService.bookmarks.loadFolders()
            guard let found = folders.first(where: { $0.displayName.caseInsensitiveCompare(target) == .orderedSame }) else {
                throw ZinoError(.fileNotFound, "No mounted folder named '\(target)'.")
            }
            switchMountedFolder(found)
            return "Active folder is now '\(found.displayName)'."

        case "cd":
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let arg = args.first ?? ""
            if arg.isEmpty || arg == "~" || arg == "/" {
                currentRelativeDirectory = ""
                return "/"
            }
            let currentDir = try currentDirectoryURL(root: root)
            let candidate = currentDir.appendingPathComponent(arg).standardizedFileURL
            let safe = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: candidate, root: root)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: safe.path, isDirectory: &isDir), isDir.boolValue else {
                throw ZinoError(.fileNotFound, "Directory '\(arg)' does not exist.")
            }
            let rootStd = root.resolvingSymlinksInPath().standardizedFileURL.path
            let rel = safe.path.replacingOccurrences(of: rootStd, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            currentRelativeDirectory = rel
            return "/\(rel)"

        case "ls":
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let showHidden = args.contains("-la") || args.contains("-a")
            let pathArg = args.first(where: { !$0.hasPrefix("-") })
            let dir = try resolvePath(pathArg ?? "", root: root)
            let items = try fileService.listDirectory(in: folder, directoryURL: dir, includeHidden: showHidden)
            if items.isEmpty { return "(empty directory)" }
            return items.map { item in
                let kind = item.isDirectory ? "DIR " : "FILE"
                let size = item.isDirectory ? "-" : Formatters.bytes(item.sizeBytes)
                return "\(kind)  \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(item.name)"
            }.joined(separator: "\n")

        case "tree":
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let dir = try currentDirectoryURL(root: root)
            return buildTree(at: dir, depth: 0, maxDepth: 3)

        case "cat", "head":
            guard let fileArg = args.last else { throw ZinoError(.invalidArgument, "Usage: \(cmd) <file>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let target = try resolvePath(fileArg, root: root)
            let doc = try fileService.readDocument(in: folder, at: target, maxCharacters: 40_000)
            if cmd == "head" {
                let lines = doc.text.components(separatedBy: "\n").prefix(20)
                return lines.joined(separator: "\n")
            }
            return doc.text

        case "mkdir":
            guard let name = args.first else { throw ZinoError(.invalidArgument, "Usage: mkdir <folder_name>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let dir = try currentDirectoryURL(root: root)
            let created = try fileService.createFolder(in: folder, parentDirectory: dir, name: name)
            return "Created folder '\(created.lastPathComponent)'."

        case "touch":
            guard let name = args.first else { throw ZinoError(.invalidArgument, "Usage: touch <filename>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let dir = try currentDirectoryURL(root: root)
            let created = try fileService.writeNewFile(in: folder, directory: dir, filename: name, content: "", allowOverwrite: true)
            return "Touched '\(created.lastPathComponent)'."

        case "write":
            guard args.count >= 2 else { throw ZinoError(.invalidArgument, "Usage: write <filename> <content>") }
            let filename = args[0]
            let content = args.dropFirst().joined(separator: " ")
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let dir = try currentDirectoryURL(root: root)
            let created = try fileService.writeNewFile(in: folder, directory: dir, filename: filename, content: content, allowOverwrite: true)
            return "Wrote \(content.utf8.count) bytes to '\(created.lastPathComponent)'."

        case "cp":
            guard args.count >= 2 else { throw ZinoError(.invalidArgument, "Usage: cp <source> <dest_directory>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let src = try resolvePath(args[0], root: root)
            let dstDir = try resolvePath(args[1], root: root)
            let out = try fileService.copyItem(in: folder, from: src, toDirectory: dstDir)
            return "Copied to '\(out.lastPathComponent)'."

        case "mv":
            guard args.count >= 2 else { throw ZinoError(.invalidArgument, "Usage: mv <source> <new_name_or_dir>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let src = try resolvePath(args[0], root: root)
            let dstCandidate = try resolvePath(args[1], root: root)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dstCandidate.path, isDirectory: &isDir), isDir.boolValue {
                let moved = try fileService.moveItem(in: folder, from: src, toDirectory: dstCandidate)
                return "Moved to '\(moved.path)'."
            } else {
                let renamed = try fileService.renameItem(in: folder, at: src, newName: args[1])
                return "Renamed to '\(renamed.lastPathComponent)'."
            }

        case "rm":
            guard let targetArg = args.first else { throw ZinoError(.invalidArgument, "Usage: rm <file>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let target = try resolvePath(targetArg, root: root)
            try fileService.deleteItem(in: folder, at: target, allowRestore: true)
            return "Moved '\(target.lastPathComponent)' to recoverable trash (.zino_trash)."

        case "find":
            let query = args.joined(separator: " ")
            let folder = try requireActiveFolder()
            let matches = try fileService.searchFiles(in: folder, query: query, maxResults: 80)
            if matches.isEmpty { return "No matching files." }
            return matches.map { "\($0.name) (\(Formatters.bytes($0.sizeBytes)))" }.joined(separator: "\n")

        case "grep":
            guard let pattern = args.first else { throw ZinoError(.invalidArgument, "Usage: grep <pattern> [file]") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            if args.count >= 2 {
                let fileURL = try resolvePath(args[1], root: root)
                let doc = try fileService.readDocument(in: folder, at: fileURL, maxCharacters: 60_000)
                let hits = doc.text.components(separatedBy: "\n").enumerated().filter { $0.element.localizedCaseInsensitiveContains(pattern) }
                return hits.isEmpty ? "No matches." : hits.prefix(50).map { "L\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            } else {
                let dir = try currentDirectoryURL(root: root)
                let items = try fileService.listDirectory(in: folder, directoryURL: dir)
                var out: [String] = []
                for item in items where !item.isDirectory && item.isTextReadable {
                    if let doc = try? fileService.readDocument(in: folder, at: item.url, maxCharacters: 25_000) {
                        for (idx, line) in doc.text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(pattern) {
                            out.append("\(item.name):\(idx + 1): \(line)")
                            if out.count >= 50 { break }
                        }
                    }
                }
                return out.isEmpty ? "No matches in current directory." : out.joined(separator: "\n")
            }

        case "sha256":
            guard let fileArg = args.first else { throw ZinoError(.invalidArgument, "Usage: sha256 <file>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let url = try resolvePath(fileArg, root: root)
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return "\(digest)  \(url.lastPathComponent)"

        case "serve":
            let folder = try requireActiveFolder()
            let port = args.first.flatMap(UInt16.init) ?? 8080
            let url = try browserService.localServer.start(serving: folder, preferredPort: port)
            return "Local HTTP Server running at \(url) (serving '\(folder.displayName)')."

        case "server":
            let sub = args.first?.lowercased() ?? "status"
            if sub == "stop" {
                browserService.localServer.stop()
                return "Stopped Local HTTP Server."
            } else if sub == "start" {
                let folder = try requireActiveFolder()
                let port = args.dropFirst().first.flatMap(UInt16.init) ?? 8080
                let url = try browserService.localServer.start(serving: folder, preferredPort: port)
                return "Started Local HTTP Server at \(url) (serving '\(folder.displayName)')."
            } else {
                let s = browserService.localServer
                return s.isRunning
                    ? "Running at \(s.baseURLString) • Serving '\(s.activeFolder?.displayName ?? "")' • \(s.requestLogs.count) requests served."
                    : "Local HTTP Server is stopped."
            }

        case "open":
            guard let target = args.first else { throw ZinoError(.invalidArgument, "Usage: open <file.html | https://...>") }
            if target.hasPrefix("http://") || target.hasPrefix("https://") {
                browserService.loadURLString(target)
                return "Opened \(target) in Custom Browser."
            } else {
                let folder = try requireActiveFolder()
                let rel = currentRelativeDirectory.isEmpty ? target : "\(currentRelativeDirectory)/\(target)"
                let url = try browserService.serveAndOpenFile(relativePath: rel, in: folder)
                return "Serving '\(folder.displayName)' and opened \(url) in Custom Browser."
            }

        case "inspect", "screenshot":
            let snap = await browserService.captureEphemeralVisionSnapshot()
            let imgSize = snap.inMemoryPNGData.map { Formatters.bytes(Int64($0.count)) } ?? "None"
            return """
            [Ephemeral RAM-Only Browser Snapshot — Not Saved to Device]
            \(snap.domSummary)
            In-Memory Screenshot Buffer: \(imgSize)
            Console Logs (\(snap.consoleLogs.count)):
            \(snap.consoleLogs.joined(separator: "\n"))
            """

        case "js":
            let expr = rawLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return try evaluateJavaScriptInWorkspace(code: expr)

        case "node":
            guard let scriptArg = args.first else { throw ZinoError(.invalidArgument, "Usage: node <script.js>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let scriptURL = try resolvePath(scriptArg, root: root)
            let code = try String(contentsOf: scriptURL, encoding: .utf8)
            return try evaluateJavaScriptInWorkspace(code: code)

        case "curl":
            guard let urlStr = args.last, let url = URL(string: urlStr) else {
                throw ZinoError(.invalidArgument, "Usage: curl <url>")
            }
            let resp = try await http.data(for: URLRequest(url: url))
            let body = String(data: resp.data, encoding: .utf8) ?? "(\(resp.data.count) binary bytes)"
            return "HTTP \(resp.statusCode)\n\(body.prefix(4000))"

        case "gh":
            return try await runGitHubCLI(args: args)

        case "cf":
            return try await runCloudflareCLI(args: args)

        case "skills":
            return skillRegistry.skills.map { s in
                "[\(s.isEnabled ? "ON " : "OFF")] \(s.name) (\(s.slug)) — \(s.description)"
            }.joined(separator: "\n")

        case "sysinfo", "memory":
            resourceMonitor.refresh()
            let r = resourceMonitor.snapshot
            return """
            Device: \(r.deviceModelIdentifier) (\(r.systemVersion))
            Physical RAM: \(Formatters.memory(r.physicalMemoryBytes))
            App Footprint: \(Formatters.bytes(r.appFootprintBytes))
            Available Headroom: \(Formatters.memory(r.availableHeadroomBytes))
            Thermal State: \(r.thermalLevel.displayName)
            """

        default:
            throw ZinoError(.invalidArgument, "Unknown command '\(cmd)'. Type 'help' to see available commands.")
        }
    }

    // MARK: - Embedded JavaScriptCore Runtime

    private func evaluateJavaScriptInWorkspace(code: String) throws -> String {
        guard let ctx = JSContext() else {
            throw ZinoError(.inferenceFailed, "Could not initialize JavaScriptCore context.")
        }
        var logs: [String] = []
        var jsError: String?

        ctx.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "JavaScript exception"
        }

        let logBlock: @convention(block) (String) -> Void = { msg in
            logs.append(msg)
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__zinoPrint" as NSString)
        _ = ctx.evaluateScript("""
            var console = {
                log: function() { __zinoPrint(Array.prototype.slice.call(arguments).join(' ')); },
                warn: function() { __zinoPrint('[WARN] ' + Array.prototype.slice.call(arguments).join(' ')); },
                error: function() { __zinoPrint('[ERROR] ' + Array.prototype.slice.call(arguments).join(' ')); }
            };
        """)

        let result = ctx.evaluateScript(code)
        if let jsError {
            throw ZinoError(.inferenceFailed, "JS Error: \(jsError)")
        }
        var outputParts = logs
        if let res = result, !res.isUndefined {
            outputParts.append(res.toString() ?? "")
        }
        return outputParts.joined(separator: "\n")
    }

    // MARK: - Plugin CLI Runners

    private func runGitHubCLI(args: [String]) async throws -> String {
        let sub = args.first?.lowercased() ?? "whoami"
        switch sub {
        case "whoami":
            let user = try await githubPlugin.verifyAndFetchUser()
            return "GitHub authenticated as @\(user)"
        case "repos":
            let repos = try await githubPlugin.listRepositories()
            return repos.map { "\($0.fullName) (\($0.isPrivate ? "private" : "public")) — \($0.htmlURL)" }.joined(separator: "\n")
        case "files":
            let repo = args.count > 1 ? args[1] : githubPlugin.defaultRepository
            let path = args.count > 2 ? args[2] : ""
            let files = try await githubPlugin.listFiles(repoFullName: repo, path: path)
            return files.map { "[\($0.type.uppercased())] \($0.path) (\($0.size) B)" }.joined(separator: "\n")
        case "cat":
            guard args.count >= 3 else { throw ZinoError(.invalidArgument, "Usage: gh cat <owner/repo> <remote_path>") }
            return try await githubPlugin.readFileContent(repoFullName: args[1], path: args[2])
        case "push":
            guard args.count >= 3 else { throw ZinoError(.invalidArgument, "Usage: gh push <owner/repo> <local_file> [remote_path] [commit_msg]") }
            let repo = args[1]
            let localFile = args[2]
            let remotePath = args.count > 3 ? args[3] : localFile
            let msg = args.count > 4 ? args.dropFirst(4).joined(separator: " ") : "Update \(remotePath) from ZinoAgent 2.0"
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let fileURL = try resolvePath(localFile, root: root)
            let data = try Data(contentsOf: fileURL)
            return try await githubPlugin.pushFile(repoFullName: repo, remotePath: remotePath, contentData: data, commitMessage: msg)
        case "issues":
            let repo = args.count > 1 ? args[1] : githubPlugin.defaultRepository
            let issues = try await githubPlugin.listIssues(repoFullName: repo)
            return issues.isEmpty ? "No open issues." : issues.map { "#\($0.number) \($0.title) [\($0.state)]" }.joined(separator: "\n")
        default:
            return "Usage: gh <whoami | repos | files [owner/repo] [path] | cat <owner/repo> <path> | push <owner/repo> <local_file> [remote_path] [msg] | issues [owner/repo]>"
        }
    }

    private func runCloudflareCLI(args: [String]) async throws -> String {
        let sub = args.first?.lowercased() ?? "whoami"
        switch sub {
        case "whoami", "verify":
            let info = try await cloudflarePlugin.verifyAndDiscoverAccounts()
            return "Cloudflare Account: \(info)"
        case "zones":
            let zones = try await cloudflarePlugin.listZones()
            return zones.isEmpty ? "No zones found." : zones.map { "\($0.name) [ID: \($0.id)] (\($0.status))" }.joined(separator: "\n")
        case "dns":
            guard args.count >= 2 else { throw ZinoError(.invalidArgument, "Usage: cf dns <zone_id>") }
            let records = try await cloudflarePlugin.listDNSRecords(zoneID: args[1])
            return records.map { "\($0.type) \($0.name) -> \($0.content) (proxied: \($0.proxied))" }.joined(separator: "\n")
        case "workers":
            let workers = try await cloudflarePlugin.listWorkers()
            return workers.isEmpty ? "No Workers scripts found." : workers.map { "\($0.id) (updated \($0.modifiedOn))" }.joined(separator: "\n")
        case "deploy":
            guard args.count >= 3 else { throw ZinoError(.invalidArgument, "Usage: cf deploy <worker_name> <local_file.js>") }
            let folder = try requireActiveFolder()
            let root = try fileService.bookmarks.resolveURL(for: folder)
            let jsURL = try resolvePath(args[2], root: root)
            let code = try String(contentsOf: jsURL, encoding: .utf8)
            return try await cloudflarePlugin.deployWorkerScript(scriptName: args[1], javascriptContent: code)
        case "pages":
            let pages = try await cloudflarePlugin.listPagesProjects()
            return pages.isEmpty ? "No Pages projects found." : pages.joined(separator: "\n")
        case "d1":
            let dbs = try await cloudflarePlugin.listD1Databases()
            return dbs.isEmpty ? "No D1 databases found." : dbs.joined(separator: "\n")
        default:
            return "Usage: cf <whoami | zones | dns <zone_id> | workers | deploy <worker_name> <local_file.js> | pages | d1>"
        }
    }

    // MARK: - Helpers

    private func requireActiveFolder() throws -> MountedFolder {
        syncActiveFolder()
        guard let folder = activeFolder else {
            throw ZinoError(.permissionDenied, "No folder is mounted. Select a folder in the Files tab first.")
        }
        return folder
    }

    private func currentDirectoryURL(root: URL) throws -> URL {
        let candidate = currentRelativeDirectory.isEmpty ? root : root.appendingPathComponent(currentRelativeDirectory)
        return try SecurityScopedBookmarkManager.ensureInsideScope(candidate: candidate, root: root)
    }

    private func resolvePath(_ arg: String, root: URL) throws -> URL {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try currentDirectoryURL(root: root)
        }
        let base = try currentDirectoryURL(root: root)
        let candidate = trimmed.hasPrefix("/")
            ? root.appendingPathComponent(String(trimmed.dropFirst()))
            : base.appendingPathComponent(trimmed)
        return try SecurityScopedBookmarkManager.ensureInsideScope(candidate: candidate, root: root)
    }

    private func buildTree(at url: URL, depth: Int, maxDepth: Int) -> String {
        guard depth <= maxDepth else { return "" }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var lines: [String] = []
        let indent = String(repeating: "  ", count: depth)
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            lines.append("\(indent)├─ \(item.lastPathComponent)\(isDir ? "/" : "")")
            if isDir && depth < maxDepth {
                let sub = buildTree(at: item, depth: depth + 1, maxDepth: maxDepth)
                if !sub.isEmpty { lines.append(sub) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func append(_ kind: TerminalTranscriptLine.Kind, _ text: String) {
        transcript.append(TerminalTranscriptLine(timestamp: Date(), kind: kind, text: text))
        if transcript.count > 400 {
            transcript.removeFirst(transcript.count - 400)
        }
    }

    public static func tokenizeCommand(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false

        for ch in line {
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if ch.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
