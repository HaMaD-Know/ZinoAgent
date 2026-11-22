import Foundation

public enum FileToolRisk: String, Sendable, Codable {
    case readOnly
    case nonDestructiveWrite
    case modifiesOrMovesExisting
}

public enum FileToolName: String, CaseIterable, Sendable, Codable {
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

    public var risk: FileToolRisk {
        switch self {
        case .listFiles, .searchFiles, .getFileMetadata, .readSupportedDocument, .summarizeDocument:
            return .readOnly
        case .createFolder, .copyFile, .exportFile, .generateFile:
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
        case .generateFile: return "Generate File"
        }
    }
}

public enum FileToolDefinitions {
    public static func schemas(for permissionLevel: AIPermissionLevel) -> [ProviderToolSchema] {
        var tools: [ProviderToolSchema] = [
            ProviderToolSchema(
                name: FileToolName.listFiles.rawValue,
                description: "List files and folders inside a user-permitted folder (optional relative subfolder path).",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name (optional if only one folder is mounted).")]),
                        "relative_path": .object(["type": .string("string"), "description": .string("Relative subfolder path inside the mounted folder.")])
                    ])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.searchFiles.rawValue,
                description: "Search for files by filename substring inside user-permitted folders.",
                parametersSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Search text to match filenames.")]),
                        "folder_name": .object(["type": .string("string"), "description": .string("Optional mounted folder name to scope search.")])
                    ]),
                    "required": .array([.string("query")])
                ]
            ),
            ProviderToolSchema(
                name: FileToolName.getFileMetadata.rawValue,
                description: "Inspect metadata (size, kind, dates, MIME type) of a file inside a user-permitted folder.",
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
                description: "Extract readable text from a supported document (PDF, DOCX, TXT, MD, CSV, JSON, XML, code, ZIP listing).",
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
            )
        ]

        if permissionLevel != .readOnly {
            tools.append(contentsOf: [
                ProviderToolSchema(
                    name: FileToolName.createFolder.rawValue,
                    description: "Create a new folder inside a user-permitted folder.",
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
                    description: "Rename a file or subfolder inside a user-permitted folder (never overwrites existing items).",
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
                    description: "Copy a file to another directory inside the user-permitted folder.",
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
                    description: "Move a file to another directory inside the user-permitted folder.",
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
                    description: "Create a new text/code/markdown file inside a user-permitted folder without overwriting existing files.",
                    parametersSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "filename": .object(["type": .string("string"), "description": .string("Filename to create (e.g. notes.md).")]),
                            "content": .object(["type": .string("string"), "description": .string("UTF-8 text contents for the new file.")]),
                            "directory_relative_path": .object(["type": .string("string"), "description": .string("Optional relative directory.")]),
                            "folder_name": .object(["type": .string("string"), "description": .string("Mounted folder name.")])
                        ]),
                        "required": .array([.string("filename"), .string("content")])
                    ]
                )
            ])
        }

        return tools
    }
}
