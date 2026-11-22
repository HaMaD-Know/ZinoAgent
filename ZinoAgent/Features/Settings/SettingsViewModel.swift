import Foundation
import SwiftUI
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var mountedFolders: [MountedFolder] = []
    @Published public private(set) var toolActivityLog: [ToolActivityEntry] = []
    @Published public var exportDataURL: URL?
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?

    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        refresh()
    }

    public func refresh() {
        mountedFolders = (try? coordinator.bookmarkManager.loadFolders()) ?? []
        toolActivityLog = (try? coordinator.permissionService.fetchToolActivityLog(limit: 80)) ?? []
        coordinator.refreshStorage()
    }

    public func clearSafeCaches() {
        do {
            let freed = try coordinator.storagePaths.clearSafeCaches()
            coordinator.refreshStorage()
            statusMessage = "Cleared caches (\(Formatters.bytes(freed)) freed). Models and project files were untouched."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func exportAllData() {
        do {
            exportDataURL = try coordinator.exportService.exportAllWorkspaceData(
                settings: coordinator.settings.exportDictionary()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteAllConversations() {
        do {
            try coordinator.database.clearAllConversations()
            statusMessage = "Deleted all local conversations."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearToolLog() {
        do {
            try coordinator.permissionService.clearToolActivityLog()
            refresh()
            statusMessage = "Cleared AI tool activity log."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeFolder(_ folder: MountedFolder) {
        do {
            try coordinator.bookmarkManager.removeFolder(id: folder.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updateFolderPermission(_ folder: MountedFolder, level: AIPermissionLevel) {
        do {
            try coordinator.bookmarkManager.updatePermissionLevel(folderID: folder.id, level: level)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteProvider(_ provider: ProviderConfiguration) {
        do {
            try coordinator.providerRegistry.deleteProvider(id: provider.id)
            statusMessage = "Removed provider '\(provider.name)' and deleted its Keychain credential."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setDefaultProvider(_ provider: ProviderConfiguration) {
        do {
            try coordinator.providerRegistry.setDefaultProvider(id: provider.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
