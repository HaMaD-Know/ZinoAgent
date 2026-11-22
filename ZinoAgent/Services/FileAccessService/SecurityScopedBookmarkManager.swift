import Foundation

/// Manages security-scoped bookmarks for user-selected folders from Apple's Files app.
/// Respects iOS sandbox boundaries and supports multiple mounted locations and stale-bookmark recovery.
public final class SecurityScopedBookmarkManager: @unchecked Sendable {
    private let database: AppDatabase
    private let lock = NSLock()
    private var activeAccessURLs: [String: URL] = [:]

    public init(database: AppDatabase) {
        self.database = database
    }

    deinit {
        stopAllAccess()
    }

    /// Registers a folder explicitly selected by the user through the Files document picker.
    public func addFolder(url: URL, permissionLevel: AIPermissionLevel = .confirm) throws -> MountedFolder {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Fallback for non-security-scoped local test directories (e.g. simulator/unit tests).
            bookmarkData = Data(url.path.utf8)
        }

        let standardized = url.standardizedFileURL.path
        let existing = try loadFolders().first { $0.lastResolvedPath == standardized }
        let now = Date()
        let folder = MountedFolder(
            id: existing?.id ?? UUID().uuidString,
            displayName: url.lastPathComponent.isEmpty ? "Selected Folder" : url.lastPathComponent,
            bookmarkData: bookmarkData,
            lastResolvedPath: standardized,
            permissionLevel: existing?.permissionLevel ?? permissionLevel,
            isAccessible: true,
            createdAt: existing?.createdAt ?? now,
            lastAccessedAt: now
        )

        try saveFolder(folder)
        return folder
    }

    /// Reconnects an existing folder whose bookmark became stale or lost iOS sandbox permission.
    public func reconnectFolder(id: String, newURL: URL) throws -> MountedFolder {
        let accessed = newURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { newURL.stopAccessingSecurityScopedResource() }
        }

        guard var folder = try loadFolders().first(where: { $0.id == id }) else {
            return try addFolder(url: newURL)
        }

        let bookmarkData = (try? newURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? Data(newURL.path.utf8)
        folder.displayName = newURL.lastPathComponent.isEmpty ? folder.displayName : newURL.lastPathComponent
        folder.bookmarkData = bookmarkData
        folder.lastResolvedPath = newURL.standardizedFileURL.path
        folder.isAccessible = true
        folder.lastAccessedAt = Date()
        try saveFolder(folder)
        return folder
    }

    public func updatePermissionLevel(folderID: String, level: AIPermissionLevel) throws {
        try database.sqlite.execute(
            "UPDATE folder_bookmarks SET permission_level = ? WHERE id = ?;",
            bindings: [.text(level.rawValue), .text(folderID)]
        )
    }

    public func removeFolder(id: String) throws {
        lock.lock()
        if let url = activeAccessURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        lock.unlock()
        try database.sqlite.execute("DELETE FROM folder_bookmarks WHERE id = ?;", bindings: [.text(id)])
    }

    public func loadFolders() throws -> [MountedFolder] {
        let rows = try database.sqlite.query("SELECT * FROM folder_bookmarks ORDER BY last_accessed_at DESC;")
        return rows.compactMap { row in
            guard let id = row.string("id"),
                  let name = row.string("display_name"),
                  let data = row.data("bookmark_data"),
                  let path = row.string("last_resolved_path"),
                  let created = row.date("created_at"),
                  let accessed = row.date("last_accessed_at") else { return nil }
            let perm = row.string("permission_level").flatMap(AIPermissionLevel.init(rawValue:)) ?? .confirm
            return MountedFolder(
                id: id,
                displayName: name,
                bookmarkData: data,
                lastResolvedPath: path,
                permissionLevel: perm,
                isAccessible: row.bool("is_accessible"),
                createdAt: created,
                lastAccessedAt: accessed
            )
        }
    }

    /// Resolves a mounted folder bookmark into a live URL and checks accessibility.
    public func resolveURL(for folder: MountedFolder) throws -> URL {
        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            if isStale {
                let accessed = resolved.startAccessingSecurityScopedResource()
                defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
                if let refreshed = try? resolved.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    var updated = folder
                    updated.bookmarkData = refreshed
                    updated.lastResolvedPath = resolved.standardizedFileURL.path
                    updated.lastAccessedAt = Date()
                    updated.isAccessible = true
                    try? saveFolder(updated)
                }
            }
            return resolved
        }

        // Fallback check for direct paths (e.g. unit tests / app container directories).
        let fallbackURL = URL(fileURLWithPath: folder.lastResolvedPath, isDirectory: true)
        if FileManager.default.isReadableFile(atPath: fallbackURL.path) {
            return fallbackURL
        }

        try? markAccessibility(folderID: folder.id, accessible: false)
        throw ZinoError(
            .bookmarkStale,
            "Access to '\(folder.displayName)' has expired or the folder was moved.",
            recovery: "Tap Reconnect Folder to re-select it in Apple Files."
        )
    }

    /// Executes work while holding security-scoped access to the folder containing `targetURL`.
    public func withScopedAccess<T>(for folder: MountedFolder, _ work: (URL) throws -> T) throws -> T {
        let rootURL = try resolveURL(for: folder)
        let started = rootURL.startAccessingSecurityScopedResource()
        defer {
            if started { rootURL.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            try? markAccessibility(folderID: folder.id, accessible: false)
            throw ZinoError(
                .bookmarkStale,
                "Folder '\(folder.displayName)' is no longer reachable.",
                recovery: "Reconnect the folder from Files."
            )
        }
        try? markAccessibility(folderID: folder.id, accessible: true)
        return try work(rootURL)
    }

    /// Validates that `candidate` is strictly inside `root` (resolving symlinks and `..` traversal).
    public static func ensureInsideScope(candidate: URL, root: URL) throws -> URL {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        let candPath = resolvedCandidate.path

        if candPath == resolvedRoot.path || candPath.hasPrefix(rootPath) {
            return resolvedCandidate
        }
        throw ZinoError(
            .pathOutOfScope,
            "Access denied: '\(candidate.lastPathComponent)' is outside the user-selected folder scope."
        )
    }

    public func stopAllAccess() {
        lock.lock()
        let urls = activeAccessURLs.values
        activeAccessURLs.removeAll()
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func saveFolder(_ folder: MountedFolder) throws {
        try database.sqlite.execute(
            """
            INSERT INTO folder_bookmarks (
                id, display_name, bookmark_data, last_resolved_path, permission_level,
                is_accessible, created_at, last_accessed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                bookmark_data = excluded.bookmark_data,
                last_resolved_path = excluded.last_resolved_path,
                permission_level = excluded.permission_level,
                is_accessible = excluded.is_accessible,
                last_accessed_at = excluded.last_accessed_at;
            """,
            bindings: [
                .text(folder.id),
                .text(folder.displayName),
                .blob(folder.bookmarkData),
                .text(folder.lastResolvedPath),
                .text(folder.permissionLevel.rawValue),
                .integer(folder.isAccessible ? 1 : 0),
                .real(folder.createdAt.timeIntervalSince1970),
                .real(folder.lastAccessedAt.timeIntervalSince1970)
            ]
        )
    }

    private func markAccessibility(folderID: String, accessible: Bool) throws {
        try database.sqlite.execute(
            "UPDATE folder_bookmarks SET is_accessible = ?, last_accessed_at = ? WHERE id = ?;",
            bindings: [.integer(accessible ? 1 : 0), .real(Date().timeIntervalSince1970), .text(folderID)]
        )
    }
}
