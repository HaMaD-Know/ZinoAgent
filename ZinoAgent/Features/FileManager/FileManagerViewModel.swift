import Foundation
import SwiftUI
import Combine

@MainActor
public final class FileManagerViewModel: ObservableObject {
    @Published public private(set) var mountedFolders: [MountedFolder] = []
    @Published public var selectedFolder: MountedFolder?
    @Published public var currentDirectoryURL: URL?
    @Published public private(set) var breadcrumbURLs: [URL] = []
    @Published public private(set) var items: [FileItem] = []

    @Published public var viewMode: FileViewMode = .grid
    @Published public var sortOption: FileSortOption = .name
    @Published public var sortAscending: Bool = true
    @Published public var selectedCategory: FileCategory = .all
    @Published public var searchQuery: String = ""

    @Published public var isMultiSelecting: Bool = false
    @Published public var selectedItemIDs: Set<String> = []
    @Published public var clipboardItems: (operation: ClipboardOp, items: [FileItem], sourceFolder: MountedFolder)?

    @Published public var previewItem: FileItem?
    @Published public var infoItem: FileItem?
    @Published public var shareURLs: [URL]?

    @Published public var statusMessage: String?
    @Published public var errorMessage: String?
    @Published public var needsReconnectFolder: MountedFolder?
    @Published public var undoCount: Int = 0

    public enum ClipboardOp {
        case copy, move
    }

    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.viewMode = FileViewMode(rawValue: coordinator.settings.defaultFileViewMode) ?? .grid
        self.sortOption = FileSortOption(rawValue: coordinator.settings.defaultFileSort) ?? .name
        reloadFolders()
    }

    public func reloadFolders() {
        do {
            mountedFolders = try coordinator.bookmarkManager.loadFolders()
            if let current = selectedFolder,
               let refreshed = mountedFolders.first(where: { $0.id == current.id }) {
                selectedFolder = refreshed
            } else {
                selectedFolder = mountedFolders.first
                currentDirectoryURL = nil
            }
            refreshUndoCount()
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addFolder(from url: URL) {
        do {
            let folder = try coordinator.bookmarkManager.addFolder(
                url: url,
                permissionLevel: coordinator.settings.aiFilePermissionLevel
            )
            reloadFolders()
            selectFolder(folder)
            statusMessage = "Connected folder '\(folder.displayName)'."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func reconnectFolder(_ folder: MountedFolder, with newURL: URL) {
        do {
            let updated = try coordinator.bookmarkManager.reconnectFolder(id: folder.id, newURL: newURL)
            needsReconnectFolder = nil
            reloadFolders()
            selectFolder(updated)
            statusMessage = "Reconnected '\(updated.displayName)'."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeFolder(_ folder: MountedFolder) {
        do {
            try coordinator.bookmarkManager.removeFolder(id: folder.id)
            if selectedFolder?.id == folder.id {
                selectedFolder = nil
                currentDirectoryURL = nil
                items = []
                breadcrumbURLs = []
            }
            reloadFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectFolder(_ folder: MountedFolder) {
        selectedFolder = folder
        currentDirectoryURL = nil
        selectedItemIDs.removeAll()
        searchQuery = ""
        selectedCategory = .all
        loadCurrentDirectory()
    }

    public func navigateTo(directoryURL: URL) {
        currentDirectoryURL = directoryURL
        selectedItemIDs.removeAll()
        loadCurrentDirectory()
    }

    public func navigateUp() {
        guard breadcrumbURLs.count > 1 else { return }
        let parent = breadcrumbURLs[breadcrumbURLs.count - 2]
        navigateTo(directoryURL: parent)
    }

    public func loadCurrentDirectory() {
        guard let folder = selectedFolder else {
            items = []
            breadcrumbURLs = []
            return
        }
        do {
            let rootURL = try coordinator.bookmarkManager.resolveURL(for: folder)
            let targetDir = currentDirectoryURL ?? rootURL
            currentDirectoryURL = targetDir
            breadcrumbURLs = computeBreadcrumbs(root: rootURL, current: targetDir)

            let rawItems: [FileItem]
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawItems = try coordinator.fileService.searchFiles(
                    in: folder,
                    query: searchQuery,
                    category: selectedCategory
                )
            } else {
                let listed = try coordinator.fileService.listDirectory(in: folder, directoryURL: targetDir)
                rawItems = listed.filter { matchesCategory($0, category: selectedCategory) }
            }

            items = sortItems(rawItems)
            refreshUndoCount()
        } catch let err as ZinoError where err.code == .bookmarkStale {
            needsReconnectFolder = folder
            errorMessage = err.message
            items = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var visibleItems: [FileItem] {
        sortItems(items.filter { matchesCategory($0, category: selectedCategory) })
    }

    public func openItem(_ item: FileItem) {
        guard let folder = selectedFolder else { return }
        if item.isDirectory {
            navigateTo(directoryURL: item.url)
        } else {
            coordinator.fileService.recordRecentFile(item: item, folderName: folder.displayName)
            previewItem = item
        }
    }

    public func createNewFolder(named name: String) {
        guard let folder = selectedFolder, let dir = currentDirectoryURL else { return }
        do {
            _ = try coordinator.fileService.createFolder(in: folder, parentDirectory: dir, name: name)
            statusMessage = "Created folder '\(name)'."
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func renameItem(_ item: FileItem, to newName: String) {
        guard let folder = selectedFolder else { return }
        do {
            _ = try coordinator.fileService.renameItem(in: folder, at: item.url, newName: newName)
            statusMessage = "Renamed '\(item.name)' to '\(newName)'."
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func duplicateItem(_ item: FileItem) {
        guard let folder = selectedFolder else { return }
        do {
            let copy = try coordinator.fileService.duplicateItem(in: folder, at: item.url)
            statusMessage = "Duplicated to '\(copy.lastPathComponent)'."
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteItems(_ targets: [FileItem]) {
        guard let folder = selectedFolder else { return }
        var deleted = 0
        for item in targets {
            do {
                try coordinator.fileService.deleteItem(in: folder, at: item.url, allowRestore: true)
                deleted += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        selectedItemIDs.removeAll()
        isMultiSelecting = false
        if deleted > 0 {
            statusMessage = "Moved \(deleted) item(s) to recoverable trash. Tap Undo to restore."
        }
        loadCurrentDirectory()
    }

    public func stageClipboard(operation: ClipboardOp, targets: [FileItem]) {
        guard let folder = selectedFolder, !targets.isEmpty else { return }
        clipboardItems = (operation, targets, folder)
        statusMessage = "\(operation == .copy ? "Copied" : "Ready to move") \(targets.count) item(s). Navigate to destination and tap Paste."
        selectedItemIDs.removeAll()
        isMultiSelecting = false
    }

    public func pasteClipboardHere() {
        guard let clip = clipboardItems,
              let destFolder = selectedFolder,
              let destDir = currentDirectoryURL else { return }
        var count = 0
        for item in clip.items {
            do {
                if clip.operation == .copy {
                    _ = try coordinator.fileService.copyItem(in: destFolder, from: item.url, toDirectory: destDir)
                } else {
                    _ = try coordinator.fileService.moveItem(in: destFolder, from: item.url, toDirectory: destDir)
                }
                count += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if clip.operation == .move {
            clipboardItems = nil
        }
        if count > 0 {
            statusMessage = "\(clip.operation == .copy ? "Copied" : "Moved") \(count) item(s)."
        }
        loadCurrentDirectory()
    }

    public func importExternalFiles(_ urls: [URL]) {
        guard let folder = selectedFolder, let dir = currentDirectoryURL else { return }
        var imported = 0
        for url in urls {
            do {
                _ = try coordinator.fileService.importExternalFile(from: url, into: folder, directory: dir)
                imported += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if imported > 0 {
            statusMessage = "Imported \(imported) file(s)."
            loadCurrentDirectory()
        }
    }

    public func extractZip(_ item: FileItem) {
        guard let folder = selectedFolder else { return }
        do {
            let dest = try coordinator.fileService.extractZipArchive(in: folder, archiveURL: item.url)
            statusMessage = "Extracted archive into '\(dest.lastPathComponent)'."
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func undoLastOperation() {
        guard let folder = selectedFolder else { return }
        do {
            let msg = try coordinator.fileService.undoLastOperation(in: folder)
            statusMessage = msg
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleFavorite(_ item: FileItem) {
        guard let folder = selectedFolder else { return }
        do {
            _ = try coordinator.fileService.toggleFavorite(item: item, folderID: folder.id)
            loadCurrentDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func askAIAbout(_ item: FileItem) {
        guard let folder = selectedFolder else { return }
        var previewText: String?
        if item.isTextReadable {
            previewText = try? coordinator.fileService.readDocument(in: folder, at: item.url, maxCharacters: 20_000).text
        }
        let kind: ChatAttachment.Kind = item.isImage ? .image : (item.isThreeDModel ? .threeDModel : .file)
        let attachment = ChatAttachment(
            kind: kind,
            filename: item.name,
            filePath: item.url.path,
            mimeType: item.mimeType,
            fileSizeBytes: item.sizeBytes,
            extractedPreview: previewText
        )
        coordinator.openNewChat(
            draft: "Please analyze and explain '\(item.name)'.",
            attachments: [attachment]
        )
    }

    public func openInThreeDStudio(_ item: FileItem) {
        coordinator.openInThreeDStudio(fileURL: item.url)
    }

    public func prepareShare(items targets: [FileItem]) {
        guard let folder = selectedFolder else { return }
        // Stage copies into temp exports directory so UIActivityViewController has clean readable access.
        var staged: [URL] = []
        do {
            try coordinator.bookmarkManager.withScopedAccess(for: folder) { root in
                for item in targets where !item.isDirectory {
                    let safe = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: item.url, root: root)
                    let tempURL = coordinator.storagePaths.tempDirectory.appendingPathComponent(item.name)
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: safe, to: tempURL)
                    staged.append(tempURL)
                }
            }
            if !staged.isEmpty {
                shareURLs = staged
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var selectedItems: [FileItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    private func refreshUndoCount() {
        undoCount = ((try? coordinator.fileService.fetchUndoHistory(limit: 20)) ?? []).count
    }

    private func matchesCategory(_ item: FileItem, category: FileCategory) -> Bool {
        switch category {
        case .all: return true
        case .favorites: return item.isFavorite
        default: return item.category == category
        }
    }

    private func sortItems(_ list: [FileItem]) -> [FileItem] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let ordered: Bool
            switch sortOption {
            case .name:
                ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .dateModified:
                ordered = (a.modifiedAt ?? .distantPast) < (b.modifiedAt ?? .distantPast)
            case .size:
                ordered = a.sizeBytes < b.sizeBytes
            case .kind:
                ordered = a.fileExtension.localizedStandardCompare(b.fileExtension) == .orderedAscending
            }
            return sortAscending ? ordered : !ordered
        }
    }

    private func computeBreadcrumbs(root: URL, current: URL) -> [URL] {
        let stdRoot = root.standardizedFileURL
        var chain: [URL] = []
        var cursor = current.standardizedFileURL
        while cursor.path.count >= stdRoot.path.count {
            chain.append(cursor)
            if cursor.path == stdRoot.path { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return chain.reversed()
    }
}
