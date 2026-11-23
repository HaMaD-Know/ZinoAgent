import Foundation

/// Manages security-scoped bookmarks for user-selected folders from Apple's Files app.
/// Keeps security-scoped access active in memory while folders are mounted so AI tools,
/// the Local HTTP Dev Server, Browser, and Terminal can all read and write inside the user's selected folder.
public final class SecurityScopedBookmarkManager: @unchecked Sendable {
    private let database: AppDatabase
    private let defaultWorkspaceURL: URL?
    private let lock = NSLock()
    private var activeAccessURLs: [String: URL] = [:]
    private var activeScopeStarted: Set<String> = []

    public init(database: AppDatabase, defaultWorkspaceURL: URL? = nil) {
        self.database = database
        self.defaultWorkspaceURL = defaultWorkspaceURL
        if let ws = defaultWorkspaceURL {
            try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            ensureDefaultWorkspaceMounted(at: ws)
        }
        activateAllMountedFolders()
    }

    deinit {
        stopAllAccess()
    }

    private func ensureDefaultWorkspaceMounted(at url: URL) {
        let existing = (try? loadFoldersRaw()) ?? []
        if existing.isEmpty {
            _ = try? addFolder(url: url, permissionLevel: .authorized)
        }
    }

    public func activateAllMountedFolders() {
        guard let folders = try? loadFoldersRaw() else { return }
        for folder in folders {
            _ = try? resolveURL(for: folder)
        }
    }

    /// Registers a folder explicitly selected by the user through the Files document picker.
    public func addFolder(url: URL, permissionLevel: AIPermissionLevel = .authorized) throws -> MountedFolder {
        let started = url.startAccessingSecurityScopedResource()

        // IMPORTANT: On iOS/iPadOS, `.minimalBookmark` strips security scope!
        // Always use `options: []` so the security scope persists across resolutions.
        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            bookmarkData = Data(url.path.utf8)
        }

        let standardized = url.standardizedFileURL.path
        let existing = try loadFoldersRaw().first { $0.lastResolvedPath == standardized }
        let now = Date()
        let folderID = existing?.id ?? UUID().uuidString
        let folder = MountedFolder(
            id: folderID,
            displayName: url.lastPathComponent.isEmpty ? "Selected Folder" : url.lastPathComponent,
            bookmarkData: bookmarkData,
            lastResolvedPath: standardized,
            permissionLevel: permissionLevel,
            isAccessible: true,
            createdAt: existing?.createdAt ?? now,
            lastAccessedAt: now
        )

        lock.lock()
        activeAccessURLs[folderID] = url
        if started {
            activeScopeStarted.insert(folderID)
        }
        lock.unlock()

        try saveFolder(folder)
        return folder
    }

    /// Reconnects an existing folder whose bookmark became stale or lost iOS sandbox permission.
    public func reconnectFolder(id: String, newURL: URL) throws -> MountedFolder {
        let started = newURL.startAccessingSecurityScopedResource()

        guard var folder = try loadFoldersRaw().first(where: { $0.id == id }) else {
            return try addFolder(url: newURL)
        }

        let bookmarkData = (try? newURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? Data(newURL.path.utf8)
        folder.displayName = newURL.lastPathComponent.isEmpty ? folder.displayName : newURL.lastPathComponent
        folder.bookmarkData = bookmarkData
        folder.lastResolvedPath = newURL.standardizedFileURL.path
        folder.isAccessible = true
        folder.lastAccessedAt = Date()

        lock.lock()
        if let oldURL = activeAccessURLs[id], activeScopeStarted.contains(id) {
            oldURL.stopAccessingSecurityScopedResource()
        }
        activeAccessURLs[id] = newURL
        if started {
            activeScopeStarted.insert(id)
        }
        lock.unlock()

        try saveFolder(folder)
        return folder
    }

    public func updatePermissionLevel(folderID: String, level: AIPermissionLevel) throws {
        try database.sqlite.execute(
            "UPDATE folder_bookmarks SET permission_level = ? WHERE id = ?;",
            bindings: [.text(level.rawValue), .text(folderID)]
        )
    }

    public func touchFolder(id: String) {
        try? database.sqlite.execute(
            "UPDATE folder_bookmarks SET last_accessed_at = ? WHERE id = ?;",
            bindings: [.real(Date().timeIntervalSince1970), .text(id)]
        )
    }

    public func removeFolder(id: String) throws {
        lock.lock()
        if let url = activeAccessURLs.removeValue(forKey: id), activeScopeStarted.contains(id) {
            url.stopAccessingSecurityScopedResource()
        }
        activeScopeStarted.remove(id)
        lock.unlock()
        try database.sqlite.execute("DELETE FROM folder_bookmarks WHERE id = ?;", bindings: [.text(id)])
    }

    public func loadFolders() throws -> [MountedFolder] {
        let folders = try loadFoldersRaw()
        // Prioritize user-selected external folders ahead of the built-in fallback Workspace folder when sorting.
        return folders.sorted { a, b in
            let aIsDefault = (a.lastResolvedPath == defaultWorkspaceURL?.standardizedFileURL.path)
            let bIsDefault = (b.lastResolvedPath == defaultWorkspaceURL?.standardizedFileURL.path)
            if aIsDefault != bIsDefault {
                return !aIsDefault
            }
            return a.lastAccessedAt > b.lastAccessedAt
        }
    }

    private func loadFoldersRaw() throws -> [MountedFolder] {
        let rows = try database.sqlite.query("SELECT * FROM folder_bookmarks ORDER BY last_accessed_at DESC;")
        return rows.compactMap { row in
            guard let id = row.string("id"),
                  let name = row.string("display_name"),
                  let data = row.data("bookmark_data"),
                  let path = row.string("last_resolved_path"),
                  let created = row.date("created_at"),
                  let accessed = row.date("last_accessed_at") else { return nil }
            let perm = row.string("permission_level").flatMap(AIPermissionLevel.init(rawValue:)) ?? .authorized
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

    /// Resolves a mounted folder bookmark into a live URL and keeps its security scope active.
    public func resolveURL(for folder: MountedFolder) throws -> URL {
        lock.lock()
        if let active = activeAccessURLs[folder.id], FileManager.default.fileExists(atPath: active.path) {
            lock.unlock()
            return active
        }
        lock.unlock()

        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            let started = resolved.startAccessingSecurityScopedResource()
            lock.lock()
            activeAccessURLs[folder.id] = resolved
            if started { activeScopeStarted.insert(folder.id) }
            lock.unlock()

            if isStale {
                if let refreshed = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    var updated = folder
                    updated.bookmarkData = refreshed
                    updated.lastResolvedPath = resolved.standardizedFileURL.path
                    updated.lastAccessedAt = Date()
                    updated.isAccessible = true
                    try? saveFolder(updated)
                }
            }
            if FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }

        let fallbackURL = URL(fileURLWithPath: folder.lastResolvedPath, isDirectory: true)
        let startedFallback = fallbackURL.startAccessingSecurityScopedResource()
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            lock.lock()
            activeAccessURLs[folder.id] = fallbackURL
            if startedFallback { activeScopeStarted.insert(folder.id) }
            lock.unlock()
            return fallbackURL
        }
        if startedFallback { fallbackURL.stopAccessingSecurityScopedResource() }

        try? markAccessibility(folderID: folder.id, accessible: false)
        throw ZinoError(
            .bookmarkStale,
            "Access to '\(folder.displayName)' has expired or the folder was moved.",
            recovery: "Tap Reconnect Folder in Files to re-authorize access."
        )
    }

    /// Executes work while holding security-scoped access to the folder.
    /// Does not prematurely revoke security scope on exit so concurrent Browser/Server/AI calls continue working.
    public func withScopedAccess<T>(for folder: MountedFolder, _ work: (URL) throws -> T) throws -> T {
        let rootURL = try resolveURL(for: folder)
        var extraStarted = false
        lock.lock()
        let alreadyActive = activeScopeStarted.contains(folder.id)
        lock.unlock()
        if !alreadyActive {
            extraStarted = rootURL.startAccessingSecurityScopedResource()
            if extraStarted {
                lock.lock()
                activeScopeStarted.insert(folder.id)
                lock.unlock()
            }
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
            "Access denied: '\(candidate.lastPathComponent)' is outside the selected folder scope."
        )
    }

    public func stopAllAccess() {
        lock.lock()
        let active = activeAccessURLs
        let startedIDs = activeScopeStarted
        activeAccessURLs.removeAll()
        activeScopeStarted.removeAll()
        lock.unlock()
        for (id, url) in active where startedIDs.contains(id) {
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
