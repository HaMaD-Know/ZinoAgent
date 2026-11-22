import Foundation

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
    case executed(output: String)
    case requiresConfirmation(PendingToolProposal)
    case denied(reason: String)
}

/// Permission-aware AI file tool validator and executor.
/// Validates folder scope, file existence, types, destination safety (never silent overwrite),
/// and user authorization level before touching the filesystem.
public final class FileToolExecutor: @unchecked Sendable {
    private let fileService: FileManagerService
    private let permissionService: PermissionService
    private let storagePaths: AppStoragePaths

    public init(
        fileService: FileManagerService,
        permissionService: PermissionService,
        storagePaths: AppStoragePaths
    ) {
        self.fileService = fileService
        self.permissionService = permissionService
        self.storagePaths = storagePaths
    }

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
        let folders: [MountedFolder]
        do {
            folders = try fileService.bookmarks.loadFolders()
        } catch {
            return .denied(reason: "Could not read mounted folders: \(error.localizedDescription)")
        }

        guard !folders.isEmpty else {
            let msg = "No folders have been selected from Apple Files yet. Open the Files tab and add a folder first."
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

        let requestedFolderName = args["folder_name"] as? String
        let targetFolder: MountedFolder
        if let requested = requestedFolderName, !requested.isEmpty {
            guard let found = folders.first(where: { $0.displayName.caseInsensitiveCompare(requested) == .orderedSame }) else {
                let names = folders.map(\.displayName).joined(separator: ", ")
                return .denied(reason: "Folder '\(requested)' is not mounted. Available permitted folders: \(names).")
            }
            targetFolder = found
        } else {
            targetFolder = folders[0]
        }

        // Effective permission is the stricter of global setting and folder-specific setting.
        let effectiveLevel = stricterPermission(globalPermissionLevel, targetFolder.permissionLevel)

        // Read-only tools execute directly within the permitted folder scope.
        if tool.risk == .readOnly {
            return executeValidated(
                tool: tool,
                args: args,
                folder: targetFolder,
                conversationID: conversationID,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel
            )
        }

        // Write/modify tools must respect permission levels!
        switch effectiveLevel {
        case .readOnly:
            let msg = "Operation '\(tool.displayTitle)' blocked: AI file permission is set to Read-only."
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel,
                status: "denied",
                resultSummary: msg
            )
            return .denied(reason: msg)

        case .suggest:
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
                isSuggestionOnly: true
            )
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel,
                status: "suggested",
                resultSummary: proposal.previewSummary
            )
            return .requiresConfirmation(proposal)

        case .confirm:
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
            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: toolCall.argumentsJSON,
                permissionLevel: effectiveLevel,
                status: "awaiting_confirmation",
                resultSummary: proposal.previewSummary
            )
            return .requiresConfirmation(proposal)

        case .authorized:
            if tool.risk == .nonDestructiveWrite {
                return executeValidated(
                    tool: tool,
                    args: args,
                    folder: targetFolder,
                    conversationID: conversationID,
                    argumentsJSON: toolCall.argumentsJSON,
                    permissionLevel: effectiveLevel
                )
            } else {
                // Modifying/moving existing files still requires explicit confirmation for safety.
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

    public func executeApprovedProposal(_ proposal: PendingToolProposal) -> ToolEvaluationOutcome {
        guard let folder = (try? fileService.bookmarks.loadFolders())?.first(where: { $0.id == proposal.folderID }) else {
            return .denied(reason: "Mounted folder '\(proposal.folderName)' is no longer available.")
        }
        let args = parseJSONArguments(proposal.argumentsJSON)
        return executeValidated(
            tool: proposal.toolName,
            args: args,
            folder: folder,
            conversationID: proposal.conversationID,
            argumentsJSON: proposal.argumentsJSON,
            permissionLevel: .confirm
        )
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

    private func executeValidated(
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
                let dirURL = try resolveRelative(dirRel, in: rootURL)
                let created = try fileService.writeNewFile(in: folder, directory: dirURL, filename: filename, content: content, allowOverwrite: false)
                output = "Created file '\(created.lastPathComponent)' (\(content.utf8.count) bytes) in '\(folder.displayName)'."
            }

            permissionService.logToolActivity(
                conversationID: conversationID,
                toolName: tool.rawValue,
                argumentsJSON: argumentsJSON,
                permissionLevel: permissionLevel,
                status: "executed",
                resultSummary: String(output.prefix(240))
            )
            return .executed(output: output)
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
            return "Create new file '\(args["filename"] as? String ?? "?")' in \(folderName)"
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
