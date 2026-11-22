import Foundation
import Combine

@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public private(set) var recentFiles: [RecentActivityItem] = []
    @Published public private(set) var recentConversations: [ChatConversation] = []
    @Published public private(set) var recentThreeDProjects: [ThreeDProjectRecord] = []
    @Published public private(set) var recentImages: [ImageGenerationRecord] = []
    @Published public private(set) var mountedFolderCount: Int = 0

    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        refresh()
    }

    public func refresh() {
        coordinator.resourceMonitor.refresh()
        coordinator.refreshStorage()
        coordinator.threeDService.reloadProjects()
        coordinator.imageGenerationService.reloadHistory()

        recentFiles = (try? coordinator.database.fetchRecentActivity(kind: "file", limit: 6)) ?? []
        recentConversations = Array(((try? coordinator.conversationRepository.fetchConversations()) ?? []).prefix(5))
        recentThreeDProjects = Array(coordinator.threeDService.projects.prefix(4))
        recentImages = Array(coordinator.imageGenerationService.history.prefix(4))
        mountedFolderCount = ((try? coordinator.bookmarkManager.loadFolders()) ?? []).count
    }
}
