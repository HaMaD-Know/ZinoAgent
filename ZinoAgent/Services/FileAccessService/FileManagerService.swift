import Foundation
import UniformTypeIdentifiers
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Complete scoped file management service.
/// Every file operation validates user-selected folder permissions, never silently overwrites files,
/// and journals reversible operations (including soft-delete to `.zino_trash` within the mounted folder).
public final class FileManagerService: @unchecked Sendable {
    public let bookmarks: SecurityScopedBookmarkManager
    private let database: AppDatabase
    private let fm = FileManager.default
    private let trashFolderName = ".zino_trash"

    public init(database: AppDatabase, bookmarks: SecurityScopedBookmarkManager) {
        self.database = database
        self.bookmarks = bookmarks
    }

    // MARK: - Browsing & Search

    public func listDirectory(in folder: MountedFolder, directoryURL: URL? = nil, includeHidden: Bool = false) throws -> [FileItem] {
        let favorites = try fetchFavoritePaths()
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let targetDir = try SecurityScopedBookmarkManager.ensureInsideScope(
                candidate: directoryURL ?? rootURL,
                root: rootURL
            )
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .fileSizeKey, .creationDateKey,
                .contentModificationDateKey, .contentTypeKey, .isHiddenKey
            ]
            let contents = try fm.contentsOfDirectory(
                at: targetDir,
                includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            return contents.compactMap { url in
                if !includeHidden && url.lastPathComponent == trashFolderName { return nil }
                return buildFileItem(url: url, favorites: favorites)
            }
        }
    }

    public func searchFiles(
        in folder: MountedFolder,
        query: String,
        category: FileCategory = .all,
        maxResults: Int = 250
    ) throws -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let favorites = try fetchFavoritePaths()
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            var matches: [FileItem] = []
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            for case let url as URL in enumerator {
                if url.lastPathComponent == trashFolderName {
                    enumerator.skipDescendants()
                    continue
                }
                guard let item = buildFileItem(url: url, favorites: favorites) else { continue }
                let matchesQuery = trimmed.isEmpty || item.name.lowercased().contains(trimmed)
                let matchesCategory: Bool
                switch category {
                case .all: matchesCategory = true
                case .favorites: matchesCategory = item.isFavorite
                default: matchesCategory = item.category == category
                }
                if matchesQuery && matchesCategory {
                    matches.append(item)
                    if matches.count >= maxResults { break }
                }
            }
            return matches
        }
    }

    public func itemMetadata(in folder: MountedFolder, at url: URL) throws -> FileItem {
        let favorites = try fetchFavoritePaths()
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: url, root: rootURL)
            guard fm.fileExists(atPath: safeURL.path),
                  let item = buildFileItem(url: safeURL, favorites: favorites) else {
                throw ZinoError(.fileNotFound, "File '\(url.lastPathComponent)' does not exist.")
            }
            return item
        }
    }

    // MARK: - Scoped File Operations (Never Silent Overwrite)

    @discardableResult
    public func createFolder(in folder: MountedFolder, parentDirectory: URL, name: String) throws -> URL {
        let cleanName = try sanitizeFilename(name)
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeParent = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: parentDirectory, root: rootURL)
            let target = try SecurityScopedBookmarkManager.ensureInsideScope(
                candidate: safeParent.appendingPathComponent(cleanName, isDirectory: true),
                root: rootURL
            )
            guard !fm.fileExists(atPath: target.path) else {
                throw ZinoError(.fileAlreadyExists, "A folder or file named '\(cleanName)' already exists.")
            }
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try recordUndo(operation: "create_folder", sourcePath: target.path, destinationPath: nil, trashPath: nil)
            return target
        }
    }

    @discardableResult
    public func renameItem(in folder: MountedFolder, at sourceURL: URL, newName: String) throws -> URL {
        let cleanName = try sanitizeFilename(newName)
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeSource = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: sourceURL, root: rootURL)
            guard safeSource.path != rootURL.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw ZinoError(.permissionDenied, "Cannot rename the root mounted folder from inside ZinoAgent.")
            }
            guard fm.fileExists(atPath: safeSource.path) else {
                throw ZinoError(.fileNotFound, "'\(sourceURL.lastPathComponent)' no longer exists.")
            }
            let dest = try SecurityScopedBookmarkManager.ensureInsideScope(
                candidate: safeSource.deletingLastPathComponent().appendingPathComponent(cleanName),
                root: rootURL
            )
            guard !fm.fileExists(atPath: dest.path) else {
                throw ZinoError(.fileAlreadyExists, "An item named '\(cleanName)' already exists in this folder.")
            }
            try fm.moveItem(at: safeSource, to: dest)
            try recordUndo(operation: "rename", sourcePath: safeSource.path, destinationPath: dest.path, trashPath: nil)
            return dest
        }
    }

    @discardableResult
    public func copyItem(in folder: MountedFolder, from sourceURL: URL, toDirectory destinationDir: URL, newName: String? = nil) throws -> URL {
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeSource = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: sourceURL, root: rootURL)
            let safeDestDir = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: destinationDir, root: rootURL)
            guard fm.fileExists(atPath: safeSource.path) else {
                throw ZinoError(.fileNotFound, "Source '\(sourceURL.lastPathComponent)' does not exist.")
            }
            let targetName = try newName.map { try sanitizeFilename($0) } ?? safeSource.lastPathComponent
            let target = try SecurityScopedBookmarkManager.ensureInsideScope(
                candidate: safeDestDir.appendingPathComponent(targetName),
                root: rootURL
            )
            guard !fm.fileExists(atPath: target.path) else {
                throw ZinoError(.fileAlreadyExists, "'\(targetName)' already exists at the destination.")
            }
            try fm.copyItem(at: safeSource, to: target)
            try recordUndo(operation: "copy", sourcePath: safeSource.path, destinationPath: target.path, trashPath: nil)
            return target
        }
    }

    @discardableResult
    public func duplicateItem(in folder: MountedFolder, at sourceURL: URL) throws -> URL {
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeSource = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: sourceURL, root: rootURL)
            guard fm.fileExists(atPath: safeSource.path) else {
                throw ZinoError(.fileNotFound, "'\(sourceURL.lastPathComponent)' does not exist.")
            }
            let parent = safeSource.deletingLastPathComponent()
            let ext = safeSource.pathExtension
            let base = safeSource.deletingPathExtension().lastPathComponent
            var candidate = uniqueDuplicateURL(in: parent, base: base, ext: ext)
            candidate = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: candidate, root: rootURL)
            try fm.copyItem(at: safeSource, to: candidate)
            try recordUndo(operation: "copy", sourcePath: safeSource.path, destinationPath: candidate.path, trashPath: nil)
            return candidate
        }
    }

    @discardableResult
    public func moveItem(in folder: MountedFolder, from sourceURL: URL, toDirectory destinationDir: URL) throws -> URL {
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeSource = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: sourceURL, root: rootURL)
            let safeDestDir = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: destinationDir, root: rootURL)
            guard fm.fileExists(atPath: safeSource.path) else {
                throw ZinoError(.fileNotFound, "'\(sourceURL.lastPathComponent)' does not exist.")
            }
            let dest = try SecurityScopedBookmarkManager.ensureInsideScope(
                candidate: safeDestDir.appendingPathComponent(safeSource.lastPathComponent),
                root: rootURL
            )
            guard !fm.fileExists(atPath: dest.path) else {
                throw ZinoError(.fileAlreadyExists, "'\(safeSource.lastPathComponent)' already exists at the destination.")
            }
            try fm.moveItem(at: safeSource, to: dest)
            try recordUndo(operation: "move", sourcePath: safeSource.path, destinationPath: dest.path, trashPath: nil)
            return dest
        }
    }

    /// Deletes an item. When `allowRestore` is true, moves the item into `.zino_trash` inside the
    /// mounted folder so the user can restore it via Undo/Restore.
    public func deleteItem(in folder: MountedFolder, at targetURL: URL, allowRestore: Bool = true) throws {
        try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeTarget = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: targetURL, root: rootURL)
            guard safeTarget.path != rootURL.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw ZinoError(.permissionDenied, "Cannot delete the root mounted folder.")
            }
            guard fm.fileExists(atPath: safeTarget.path) else {
                throw ZinoError(.fileNotFound, "'\(targetURL.lastPathComponent)' does not exist.")
            }

            if allowRestore {
                let trashDir = rootURL.appendingPathComponent(trashFolderName, isDirectory: true)
                if !fm.fileExists(atPath: trashDir.path) {
                    try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
                }
                let stampedName = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))-\(safeTarget.lastPathComponent)"
                let trashedURL = trashDir.appendingPathComponent(stampedName)
                try fm.moveItem(at: safeTarget, to: trashedURL)
                try recordUndo(operation: "delete", sourcePath: safeTarget.path, destinationPath: nil, trashPath: trashedURL.path)
            } else {
                try fm.removeItem(at: safeTarget)
            }
        }
    }

    /// Reverses the most recent reversible file operation recorded in `file_undo_journal`.
    public func undoLastOperation(in folder: MountedFolder) throws -> String {
        let rows = try database.sqlite.query("SELECT * FROM file_undo_journal ORDER BY seq DESC LIMIT 1;")
        guard let row = rows.first,
              let seq = row.int64("seq"),
              let op = row.string("operation"),
              let sourcePath = row.string("source_path") else {
            throw ZinoError(.invalidArgument, "No recent reversible file operation to undo.")
        }
        let destPath = row.string("destination_path")
        let trashPath = row.string("trash_path")

        let message: String = try bookmarks.withScopedAccess(for: folder) { rootURL in
            switch op {
            case "delete":
                guard let trashPath else { throw ZinoError(.ioFailure, "Trash reference missing.") }
                let trashedURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: URL(fileURLWithPath: trashPath), root: rootURL)
                let originalURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: URL(fileURLWithPath: sourcePath), root: rootURL)
                guard fm.fileExists(atPath: trashedURL.path) else {
                    throw ZinoError(.fileNotFound, "Deleted item is no longer in trash.")
                }
                guard !fm.fileExists(atPath: originalURL.path) else {
                    throw ZinoError(.fileAlreadyExists, "An item already exists at '\(originalURL.lastPathComponent)'.")
                }
                try fm.moveItem(at: trashedURL, to: originalURL)
                return "Restored '\(originalURL.lastPathComponent)'"

            case "rename", "move":
                guard let destPath else { throw ZinoError(.ioFailure, "Destination path missing.") }
                let currentURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: URL(fileURLWithPath: destPath), root: rootURL)
                let originalURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: URL(fileURLWithPath: sourcePath), root: rootURL)
                guard fm.fileExists(atPath: currentURL.path) else {
                    throw ZinoError(.fileNotFound, "Moved/renamed item no longer exists.")
                }
                guard !fm.fileExists(atPath: originalURL.path) else {
                    throw ZinoError(.fileAlreadyExists, "Cannot restore: '\(originalURL.lastPathComponent)' already exists.")
                }
                try fm.moveItem(at: currentURL, to: originalURL)
                return "Reverted \(op) of '\(originalURL.lastPathComponent)'"

            case "copy":
                guard let destPath else { throw ZinoError(.ioFailure, "Copy destination missing.") }
                let copyURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: URL(fileURLWithPath: destPath), root: rootURL)
                if fm.fileExists(atPath: copyURL.path) {
                    try fm.removeItem(at: copyURL)
                }
                return "Removed copied item '\(copyURL.lastPathComponent)'"

            case "create_folder":
                let createdURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: URL(fileURLWithPath: sourcePath), root: rootURL)
                let contents = (try? fm.contentsOfDirectory(atPath: createdURL.path)) ?? []
                guard contents.isEmpty else {
                    throw ZinoError(.permissionDenied, "Cannot undo folder creation because '\(createdURL.lastPathComponent)' is not empty.")
                }
                try fm.removeItem(at: createdURL)
                return "Removed empty folder '\(createdURL.lastPathComponent)'"

            default:
                throw ZinoError(.unsupportedFormat, "Operation '\(op)' is not reversible.")
            }
        }

        try database.sqlite.execute("DELETE FROM file_undo_journal WHERE seq = ?;", bindings: [.integer(seq)])
        return message
    }

    public func fetchUndoHistory(limit: Int = 20) throws -> [FileUndoRecord] {
        let rows = try database.sqlite.query("SELECT * FROM file_undo_journal ORDER BY seq DESC LIMIT ?;", bindings: [.integer(Int64(limit))])
        return rows.compactMap { row in
            guard let seq = row.int64("seq"),
                  let op = row.string("operation"),
                  let src = row.string("source_path"),
                  let created = row.date("created_at") else { return nil }
            return FileUndoRecord(
                seq: seq,
                operation: op,
                sourcePath: src,
                destinationPath: row.string("destination_path"),
                trashPath: row.string("trash_path"),
                createdAt: created
            )
        }
    }

    /// Writes a newly generated text file into the mounted folder without ever silently overwriting existing files.
    @discardableResult
    public func writeNewFile(in folder: MountedFolder, directory: URL, filename: String, content: String, allowOverwrite: Bool = false) throws -> URL {
        let cleanName = try sanitizeFilename(filename)
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeDir = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: directory, root: rootURL)
            let target = try SecurityScopedBookmarkManager.ensureInsideScope(
                candidate: safeDir.appendingPathComponent(cleanName),
                root: rootURL
            )
            if fm.fileExists(atPath: target.path) && !allowOverwrite {
                throw ZinoError(.fileAlreadyExists, "'\(cleanName)' already exists. Choose a different filename to avoid overwriting.")
            }
            guard let data = content.data(using: .utf8) else {
                throw ZinoError(.ioFailure, "Could not encode file content as UTF-8.")
            }
            try data.write(to: target, options: .atomic)
            return target
        }
    }

    /// Imports an external file picked by the user into a mounted folder directory.
    @discardableResult
    public func importExternalFile(from externalURL: URL, into folder: MountedFolder, directory: URL) throws -> URL {
        let extAccess = externalURL.startAccessingSecurityScopedResource()
        defer { if extAccess { externalURL.stopAccessingSecurityScopedResource() } }

        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeDir = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: directory, root: rootURL)
            var dest = safeDir.appendingPathComponent(externalURL.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                dest = uniqueDuplicateURL(
                    in: safeDir,
                    base: externalURL.deletingPathExtension().lastPathComponent,
                    ext: externalURL.pathExtension
                )
            }
            dest = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: dest, root: rootURL)
            try fm.copyItem(at: externalURL, to: dest)
            return dest
        }
    }

    /// Extracts a ZIP archive into a new subfolder inside the mounted folder (protecting against zip-slip!).
    @discardableResult
    public func extractZipArchive(in folder: MountedFolder, archiveURL: URL) throws -> URL {
        #if canImport(ZIPFoundation)
        return try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeArchive = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: archiveURL, root: rootURL)
            let folderName = safeArchive.deletingPathExtension().lastPathComponent + "_extracted"
            let destDir = uniqueDuplicateURL(in: safeArchive.deletingLastPathComponent(), base: folderName, ext: "")
            let safeDest = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: destDir, root: rootURL)
            try fm.createDirectory(at: safeDest, withIntermediateDirectories: true)

            let archive = try Archive(url: safeArchive, accessMode: .read)
            for entry in archive {
                let target = safeDest.appendingPathComponent(entry.path)
                // Guard against zip-slip path traversal
                _ = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: target, root: safeDest)
                if entry.type == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try archive.extract(entry, to: target)
                }
            }
            return safeDest
        }
        #else
        throw ZinoError(.unsupportedFormat, "ZIP extraction is unavailable in this build.")
        #endif
    }

    // MARK: - Reading Documents

    public func readDocument(in folder: MountedFolder, at url: URL, maxCharacters: Int = 60_000) throws -> ExtractedDocument {
        try bookmarks.withScopedAccess(for: folder) { rootURL in
            let safeURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: url, root: rootURL)
            guard fm.fileExists(atPath: safeURL.path) else {
                throw ZinoError(.fileNotFound, "'\(url.lastPathComponent)' does not exist.")
            }
            return try DocumentTextExtractor.extract(from: safeURL, maxCharacters: maxCharacters)
        }
    }

    // MARK: - Favorites & Recents

    public func toggleFavorite(item: FileItem, folderID: String) throws -> Bool {
        let favorites = try fetchFavoritePaths()
        if favorites.contains(item.url.path) {
            try database.sqlite.execute("DELETE FROM favorite_files WHERE path = ?;", bindings: [.text(item.url.path)])
            return false
        } else {
            try database.sqlite.execute(
                """
                INSERT INTO favorite_files (path, display_name, folder_id, added_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET display_name = excluded.display_name, added_at = excluded.added_at;
                """,
                bindings: [.text(item.url.path), .text(item.name), .text(folderID), .real(Date().timeIntervalSince1970)]
            )
            return true
        }
    }

    public func fetchFavoritePaths() throws -> Set<String> {
        let rows = try database.sqlite.query("SELECT path FROM favorite_files;")
        return Set(rows.compactMap { $0.string("path") })
    }

    public func recordRecentFile(item: FileItem, folderName: String) {
        try? database.recordRecentActivity(
            kind: "file",
            title: item.name,
            subtitle: "\(folderName) • \(Formatters.bytes(item.sizeBytes))",
            referenceID: item.url.path
        )
    }

    // MARK: - Helpers

    private func buildFileItem(url: URL, favorites: Set<String>) -> FileItem? {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey
        ])
        let isDir = values?.isDirectory ?? false
        let ext = url.pathExtension.lowercased()
        return FileItem(
            id: url.standardizedFileURL.path,
            url: url,
            name: url.lastPathComponent,
            fileExtension: ext,
            isDirectory: isDir,
            sizeBytes: Int64(values?.fileSize ?? 0),
            createdAt: values?.creationDate,
            modifiedAt: values?.contentModificationDate,
            category: FileCategory.classify(fileExtension: ext, isDirectory: isDir),
            contentTypeIdentifier: values?.contentType?.identifier ?? "public.data",
            isFavorite: favorites.contains(url.path)
        )
    }

    private func sanitizeFilename(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ZinoError(.invalidArgument, "Name cannot be empty.")
        }
        guard !trimmed.contains("/") && !trimmed.contains(":") && trimmed != "." && trimmed != ".." else {
            throw ZinoError(.invalidArgument, "Name contains invalid path characters.")
        }
        return trimmed
    }

    private func uniqueDuplicateURL(in dir: URL, base: String, ext: String) -> URL {
        for index in 1...999 {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let filename = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let candidate = dir.appendingPathComponent(filename)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return dir.appendingPathComponent(ext.isEmpty ? "\(base)_\(stamp)" : "\(base)_\(stamp).\(ext)")
    }

    private func recordUndo(operation: String, sourcePath: String, destinationPath: String?, trashPath: String?) throws {
        try database.sqlite.execute(
            """
            INSERT INTO file_undo_journal (operation, source_path, destination_path, trash_path, created_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(operation),
                .text(sourcePath),
                destinationPath.map { .text($0) } ?? .null,
                trashPath.map { .text($0) } ?? .null,
                .real(Date().timeIntervalSince1970)
            ]
        )
    }
}
