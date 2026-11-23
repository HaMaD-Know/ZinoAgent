import Foundation

public enum FileToolRisk: String, Sendable, Codable {
    case readOnly
    case nonDestructiveWrite
    case modifiesOrMovesExisting
}

public enum FileToolName: String, CaseIterable, Sendable, Codable {
    // Folder & File tools
    case listFiles = "list_files"
    case searchFiles = "search_files"
    case getFileMetadata = "get_file_metadata"
    case readSupportedDocument = "read_supported_document"
    case summarizeDocument = "summarize_document"
    case createFolder = "create_folder"
    case renameFile = "rename_file"
    case copyFile = "copy_file"
    case moveFile = "move_file"
    case exportFile = "export_file"
    case generateFile = "generate_file"

    // Custom Browser & Local Server tools
    case startLocalServer = "start_local_server"
    case openInBrowser = "open_in_browser"
    case captureBrowserScreenshot = "capture_browser_screenshot"
    case runBrowserJavaScript = "run_browser_javascript"

    // Terminal & Plugins tools
    case runTerminalCommand = "run_terminal_command"
    case githubPlugin = "github_plugin"
    case cloudflarePlugin = "cloudflare_plugin"

    public var risk: FileToolRisk {
        switch self {
        case .listFiles, .searchFiles, .getFileMetadata, .readSupportedDocument, .summarizeDocument,
             .startLocalServer, .openInBrowser, .captureBrowserScreenshot:
            return .readOnly
        case .createFolder, .copyFile, .exportFile, .generateFile,
             .runBrowserJavaScript, .runTerminalCommand, .githubPlugin, .cloudflarePlugin:
            return .nonDestructiveWrite
        case .renameFile, .moveFile:
            return .modifiesOrMovesExisting
        }
    }

    public var displayTitle: String {
        switch self {
        case .listFiles: return "List Files"
        case .searchFiles: return "Search Files"
        case .getFileMetadata: return "Get File Metadata"
        case .readSupportedDocument: return "Read Document"
        case .summarizeDocument: return "Summarize Document"
        case .createFolder: return "Create Folder"
        case .renameFile: return "Rename File"
        case .copyFile: return "Copy File"
        case .moveFile: return "Move File"
        case .exportFile: return "Export File"
        case .generateFile: return "Generate / Write File"
        case .startLocalServer: return "Start Local HTTP Server"
        case .openInBrowser: return "Open in Custom Browser"
        case .captureBrowserScreenshot: return "Inspect Browser & Ephemeral Screenshot"
        case .runBrowserJavaScript: return "Run Browser JavaScript"
        case .runTerminalCommand: return "Run Terminal Command"
        case .githubPlugin: return "GitHub Plugin"
        case .cloudflarePlugin: return "Cloudflare Plugin"
        }
    }
}

public enum FileToolDefinitions {
    public static func schemas(for permissionLevel: AIPermissionLevel) -> [ProviderToolSchema] {
        var tools: [ProviderToolSchema] = [
            ProviderToolSchema(
                name: FileToolName.listFiles.rawValue,
                description: "List files and folders inside the user's selected/mounted folder (optional relative subfolder path).",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name (optional; defaults to the primary user-selected folder).")]),
                        "relative_path": .object(["type": .string("string"), "description": .string("Relative subfolder path inside the mounted folder.")])
                    ])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.searchFiles.rawValue,
                description: "Search for files by filename substring inside the user's mounted folder.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Search text to match filenames.")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Optional mounted folder name.")])
                    ]),
                    "required": .array([.string("query")])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.getFileMetadata.rawValue,
                description: "Inspect metadata (size, kind, dates, MIME type) of a file inside the user's mounted folder.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "relative_path": .object(["type": .string("string"), "description": .string("Path relative to the mounted folder.")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                    ]),
                    "required": .array([.string("relative_path")])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.readSupportedDocument.rawValue,
                description: "Read text from a supported document (PDF, DOCX, TXT, MD, CSV, JSON, XML, HTML, JS, Swift, Python, ZIP listing) in the user's folder.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "relative_path": .object(["type": .string("string"), "description": .string("Path relative to the mounted folder.")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                    ]),
                    "required": .array([.string("relative_path")])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.summarizeDocument.rawValue,
                description: "Read and extract key sections from a supported document for summarization.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "relative_path": .object(["type": .string("string"), "description": .string("Path relative to the mounted folder.")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                    ]),
                    "required": .array([.string("relative_path")])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.startLocalServer.rawValue,
                description: "Start ZinoAgent's built-in Local HTTP Server (http://127.0.0.1:8080) serving the user's mounted folder.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "port": .object(["type": .string("integer"), "description": .string("Optional port (default 8080).")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Optional mounted folder name.")])
                    ])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.openInBrowser.rawValue,
                description: "Open a local HTML file from the user's mounted folder (automatically starting the Local HTTP Server) or an HTTPS URL in ZinoAgent's built-in Custom Browser.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "relative_path": .object(["type": .string("string"), "description": .string("Relative path to local HTML file (e.g. 'snake.html') or full URL.")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Optional mounted folder name.")])
                    ]),
                    "required": .array([.string("relative_path")])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.captureBrowserScreenshot.rawValue,
                description: "Inspect the currently loaded page in ZinoAgent's Custom Browser and capture an ephemeral RAM-only screenshot (never saved to device storage) along with DOM/Canvas/Console logs.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ]
            )
        ]

        if permissionLevel != .readOnly {
            tools.append(contentsOf: [
                ProviderToolSchema(
                    name: FileToolName.createFolder.rawValue,
                    description: "Create a new folder inside the user's mounted folder.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string"), "description": .string("New folder name.")]),
                            "parent_relative_path": .object(["type": .string("string"), "description": .string("Optional relative parent path.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("name")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.renameFile.rawValue,
                    description: "Rename a file or subfolder inside the user's mounted folder.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "relative_path": .object(["type": .string("string"), "description": .string("Current relative path of the file.")]),
                            "new_name": .object(["type": .string("string"), "description": .string("New filename without path separators.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("relative_path"), .string("new_name")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.copyFile.rawValue,
                    description: "Copy a file to another directory inside the user's mounted folder.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "source_relative_path": .object(["type": .string("string"), "description": .string("Source relative path.")]),
                            "destination_directory": .object(["type": .string("string"), "description": .string("Destination folder relative path.")]),
                            "new_name": .object(["type": .string("string"), "description": .string("Optional new filename at destination.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("source_relative_path"), .string("destination_directory")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.moveFile.rawValue,
                    description: "Move a file to another directory inside the user's mounted folder.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "source_relative_path": .object(["type": .string("string"), "description": .string("Source relative path.")]),
                            "destination_directory": .object(["type": .string("string"), "description": .string("Destination folder relative path.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("source_relative_path"), .string("destination_directory")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.exportFile.rawValue,
                    description: "Stage a copy of a permitted file into ZinoAgent's Exports folder for sharing.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "relative_path": .object(["type": .string("string"), "description": .string("Relative path of file to export.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("relative_path")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.generateFile.rawValue,
                    description: "Create or update a text/HTML/code/markdown file inside the user's mounted folder (e.g. snake.html, script.js, notes.md).",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "filename": .object(["type": .string("string"), "description": .string("Filename to create (e.g. snake.html).")]),
                            "content": .object(["type": .string("string"), "description": .string("Full UTF-8 text/HTML/code contents for the file.")]),
                            "directory_relative_path": .object(["type": .string("string"), "description": .string("Optional relative directory.")]),
                            "overwrite": .object(["type": .string("boolean"), "description": .string("Set true only when updating a file you just created.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("filename"), .string("content")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.runBrowserJavaScript.rawValue,
                    description: "Execute JavaScript inside the live page loaded in ZinoAgent's Custom Browser and return the result.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "script": .object(["type": .string("string"), "description": .string("JavaScript expression or snippet to evaluate in the page.")])
                        ]),
                        "required": .array([.string("script")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.runTerminalCommand.rawValue,
                    description: "Run a workspace terminal command inside the user's mounted folder (ls, cd, cat, write, serve, open, inspect, js, node, gh, cf, curl).",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object(["type": .string("string"), "description": .string("Command line to execute.")])
                        ]),
                        "required": .array([.string("command")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.githubPlugin.rawValue,
                    description: "Interact with GitHub repositories via the built-in GitHub plugin (whoami, list_repos, list_files, read_file, push_local_file, list_issues, create_issue).",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "action": .object(["type": .string("string"), "description": .string("One of: whoami, list_repos, list_files, read_file, push_local_file, list_issues, create_issue.")]),
                            "repo": .object(["type": .string("string"), "description": .string("Repository in 'owner/repo' format.")]),
                            "path": .object(["type": .string("string"), "description": .string("Remote path in repository.")]),
                            "local_path": .object(["type": .string("string"), "description": .string("Local relative path in mounted folder (for push_local_file).")]),
                            "message": .object(["type": .string("string"), "description": .string("Commit message or issue title.")]),
                            "body": .object(["type": .string("string"), "description": .string("Issue body text.")])
                        ]),
                        "required": .array([.string("action")])
                    ]
                ),
                ProviderToolSchema(
                    name: FileToolName.cloudflarePlugin.rawValue,
                    description: "Interact with Cloudflare via the built-in Cloudflare plugin (verify, list_zones, list_dns, create_dns, list_workers, deploy_worker, list_pages, list_d1).",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "action": .object(["type": .string("string"), "description": .string("One of: verify, list_zones, list_dns, create_dns, list_workers, deploy_worker, list_pages, list_d1.")]),
                            "zone_id": .object(["type": .string("string"), "description": .string("Cloudflare Zone ID (for DNS operations).")]),
                            "worker_name": .object(["type": .string("string"), "description": .string("Cloudflare Worker script name.")]),
                            "local_path": .object(["type": .string("string"), "description": .string("Local JS file in mounted folder (for deploy_worker).")]),
                            "dns_type": .object(["type": .string("string"), "description": .string("DNS record type (A, CNAME, TXT).")]),
                            "dns_name": .object(["type": .string("string"), "description": .string("DNS record name.")]),
                            "dns_content": .object(["type": .string("string"), "description": .string("DNS record content.")])
                        ]),
                        "required": .array([.string("action")])
                    ]
                )
            ])
        }

        return tools
    }

    /// Generates the tool-calling instruction block for Offline GGUF models (`llama.cpp`) and non-native tool models
    /// so both Offline and Online AI can invoke all file, browser, server, terminal, GitHub, and Cloudflare tools.
    public static func offlineToolPromptBlock(for permissionLevel: AIPermissionLevel) -> String {
        let writeAvailable = (permissionLevel != .readOnly)
        var lines: [String] = [
            "### ZinoAgent Tool Calling Protocol",
            "You have direct access to the user's selected folder, built-in Local HTTP Server, Custom Browser (with ephemeral RAM-only screenshots), Workspace Terminal, and GitHub/Cloudflare plugins.",
            "To call a tool, output a JSON object inside `<tool_call>` tags exactly like this:",
            "<tool_call>{\"name\": \"tool_name\", \"arguments\": {\"key\": \"value\"}}</tool_call>",
            "",
            "Available Tools:",
            "- `list_files`: `{\"relative_path\": \"\", \"folder_name\": \"\"}`",
            "- `search_files`: `{\"query\": \"text\"}`",
            "- `read_supported_document`: `{\"relative_path\": \"file.txt\"}`",
            "- `start_local_server`: `{\"port\": 8080}` — starts HTTP server on the user's folder",
            "- `open_in_browser`: `{\"relative_path\": \"snake.html\"}` — starts HTTP server and opens the file/URL in the Custom Browser",
            "- `capture_browser_screenshot`: `{}` — inspects live browser DOM/Canvas/Console and captures an ephemeral RAM-only screenshot (never saved to device)"
        ]
        if writeAvailable {
            lines.append(contentsOf: [
                "- `generate_file`: `{\"filename\": \"snake.html\", \"content\": \"<!DOCTYPE html>...\", \"overwrite\": false}` — writes a file into the user's folder",
                "- `create_folder`: `{\"name\": \"FolderName\"}`",
                "- `rename_file`: `{\"relative_path\": \"old.txt\", \"new_name\": \"new.txt\"}`",
                "- `copy_file`: `{\"source_relative_path\": \"a.txt\", \"destination_directory\": \"sub\"}`",
                "- `move_file`: `{\"source_relative_path\": \"a.txt\", \"destination_directory\": \"sub\"}`",
                "- `run_browser_javascript`: `{\"script\": \"document.title\"}`",
                "- `run_terminal_command`: `{\"command\": \"ls -la\"}`",
                "- `github_plugin`: `{\"action\": \"whoami|list_repos|list_files|read_file|push_local_file|list_issues|create_issue\", \"repo\": \"owner/repo\", \"path\": \"\", \"local_path\": \"\"}`",
                "- `cloudflare_plugin`: `{\"action\": \"verify|list_zones|list_dns|create_dns|list_workers|deploy_worker|list_pages|list_d1\", \"zone_id\": \"\", \"worker_name\": \"\", \"local_path\": \"\"}`"
            ])
        }
        return lines.joined(separator: "\n")
    }

    /// Extracts `<tool_call>{...}</tool_call>` or fenced ` ```tool_call {...} ``` ` blocks from assistant text output
    /// so offline local GGUF models and OpenAI-compatible models can execute tools seamlessly.
    public static func extractStructuredToolCalls(from text: String) -> [ToolCallRequest] {
        var results: [ToolCallRequest] = []
        let patterns = [
            "<tool_call>\\s*(\\{[\\s\\S]*?\\})\\s*</tool_call>",
            "```tool_call\\s*(\\{[\\s\\S]*?\\})\\s*```"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let jsonRange = Range(match.range(at: 1), in: text) else { continue }
                let jsonStr = String(text[jsonRange])
                guard let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = obj["name"] as? String else { continue }
                let argsObj = obj["arguments"] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data("{}".utf8)
                let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                results.append(ToolCallRequest(name: name, argumentsJSON: argsJSON))
            }
        }
        return results
    }
}
