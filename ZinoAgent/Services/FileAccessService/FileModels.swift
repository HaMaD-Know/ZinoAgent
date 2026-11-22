import Foundation
import UniformTypeIdentifiers

public enum FileCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case documents
    case images
    case threeD
    case code
    case archives
    case folders
    case favorites

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .documents: return "Documents"
        case .images: return "Images"
        case .threeD: return "3D Models"
        case .code: return "Code"
        case .archives: return "Archives"
        case .folders: return "Folders"
        case .favorites: return "Favorites"
        }
    }

    public var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .documents: return "doc.text"
        case .images: return "photo"
        case .threeD: return "cube"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "doc.zipper"
        case .folders: return "folder"
        case .favorites: return "star"
        }
    }

    public static func classify(fileExtension ext: String, isDirectory: Bool) -> FileCategory {
        if isDirectory { return .folders }
        let lower = ext.lowercased()
        if ["pdf", "txt", "md", "markdown", "docx", "csv", "tsv", "rtf"].contains(lower) {
            return .documents
        }
        if ["png", "jpg", "jpeg", "webp", "heic", "heif", "gif", "bmp", "tiff", "svg"].contains(lower) {
            return .images
        }
        if ["glb", "gltf", "obj", "usdz", "usd", "stl"].contains(lower) {
            return .threeD
        }
        if ["swift", "py", "js", "jsx", "ts", "tsx", "html", "htm", "css", "scss", "lua", "json", "xml", "yaml", "yml", "c", "cpp", "h", "rs", "go", "sh", "sql"].contains(lower) {
            return .code
        }
        if ["zip", "tar", "gz", "7z"].contains(lower) {
            return .archives
        }
        return .all
    }
}

public enum FileSortOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case dateModified
    case size
    case kind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

public enum FileViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case grid
    case list

    public var id: String { rawValue }
}

public struct MountedFolder: Identifiable, Sendable, Equatable {
    public let id: String
    public var displayName: String
    public var bookmarkData: Data
    public var lastResolvedPath: String
    public var permissionLevel: AIPermissionLevel
    public var isAccessible: Bool
    public let createdAt: Date
    public var lastAccessedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        bookmarkData: Data,
        lastResolvedPath: String,
        permissionLevel: AIPermissionLevel = .confirm,
        isAccessible: Bool = true,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastResolvedPath = lastResolvedPath
        self.permissionLevel = permissionLevel
        self.isAccessible = isAccessible
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

public struct FileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let fileExtension: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let category: FileCategory
    public let contentTypeIdentifier: String
    public var isFavorite: Bool

    public var iconName: String {
        if isDirectory { return "folder.fill" }
        switch category {
        case .documents:
            return fileExtension == "pdf" ? "doc.richtext.fill" : "doc.text.fill"
        case .images: return "photo.fill"
        case .threeD: return "cube.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "doc.zipper"
        default: return "doc.fill"
        }
    }

    public var isThreeDModel: Bool {
        ["glb", "gltf", "obj", "usdz", "stl"].contains(fileExtension.lowercased())
    }

    public var isImage: Bool {
        category == .images
    }

    public var isTextReadable: Bool {
        DocumentTextExtractor.isTextReadable(url: url)
    }

    public var mimeType: String {
        if let utType = UTType(filenameExtension: fileExtension), let mime = utType.preferredMIMEType {
            return mime
        }
        return isDirectory ? "inode/directory" : "application/octet-stream"
    }
}

public struct FileUndoRecord: Identifiable, Sendable {
    public let seq: Int64
    public let operation: String
    public let sourcePath: String
    public let destinationPath: String?
    public let trashPath: String?
    public let createdAt: Date

    public var id: Int64 { seq }
}
