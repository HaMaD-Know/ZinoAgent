import Foundation
import SwiftUI
import Combine

public struct LargeThreeDWarning: Identifiable {
    public let id = UUID()
    public let url: URL
    public let fileSizeBytes: Int64
    public let thresholdMB: Int
}

@MainActor
public final class ThreeDStudioViewModel: ObservableObject {
    public enum InspectorTab: String, CaseIterable, Identifiable {
        case hierarchy = "Hierarchy"
        case materials = "Materials"
        case info = "Info"

        public var id: String { rawValue }
    }

    @Published public private(set) var loadedModel: LoadedThreeDModel?
    @Published public private(set) var activeProject: ThreeDProjectRecord?
    @Published public var isLoading: Bool = false
    @Published public var inspectorTab: InspectorTab = .hierarchy
    @Published public var showInspector: Bool = true
    @Published public var selectedNodeID: String?
    @Published public var hiddenNodeIDs: Set<String> = []

    @Published public var lightingPreset: ThreeDLightingPreset
    @Published public var environmentPreset: ThreeDEnvironmentPreset
    @Published public var lightIntensity: Double = 1.0
    @Published public var isWireframe: Bool = false
    @Published public var showGrid: Bool
    @Published public var resetCameraToken: UUID = UUID()

    @Published public var largeFileWarning: LargeThreeDWarning?
    @Published public var errorMessage: String?

    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.lightingPreset = ThreeDLightingPreset(rawValue: coordinator.settings.threeDLightingPreset) ?? .studio
        self.environmentPreset = ThreeDEnvironmentPreset(rawValue: coordinator.settings.threeDEnvironmentPreset) ?? .darkStudio
        self.showGrid = coordinator.settings.threeDShowGrid
    }

    public func consumePendingHandoff() {
        if let url = coordinator.pendingThreeDFileURL {
            coordinator.pendingThreeDFileURL = nil
            requestImport(from: url)
        }
    }

    public func requestImport(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if accessed { url.stopAccessingSecurityScopedResource() }

        let thresholdBytes = Int64(coordinator.settings.threeDLargeFileWarningMB) * 1_048_576
        if sizeBytes > thresholdBytes {
            largeFileWarning = LargeThreeDWarning(
                url: url,
                fileSizeBytes: sizeBytes,
                thresholdMB: coordinator.settings.threeDLargeFileWarningMB
            )
            return
        }
        performImport(from: url)
    }

    public func performImport(from url: URL) {
        largeFileWarning = nil
        isLoading = true
        errorMessage = nil
        selectedNodeID = nil
        hiddenNodeIDs.removeAll()

        Task {
            defer { isLoading = false }
            do {
                let (model, project) = try await coordinator.threeDService.importAndLoad(from: url)
                self.loadedModel = model
                self.activeProject = project
                self.resetCameraToken = UUID()
                self.coordinator.refreshStorage()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func openProject(_ project: ThreeDProjectRecord) {
        isLoading = true
        errorMessage = nil
        selectedNodeID = nil
        hiddenNodeIDs.removeAll()

        Task {
            defer { isLoading = false }
            do {
                let model = try await coordinator.threeDService.openProject(project)
                self.loadedModel = model
                self.activeProject = project
                self.resetCameraToken = UUID()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func deleteProject(_ project: ThreeDProjectRecord) {
        do {
            try coordinator.threeDService.deleteProject(project)
            if activeProject?.id == project.id {
                activeProject = nil
                loadedModel = nil
                selectedNodeID = nil
            }
            coordinator.refreshStorage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleNodeVisibility(nodeID: String) {
        guard let node = loadedModel?.nodeMap[nodeID] else { return }
        node.isHidden.toggle()
        if node.isHidden {
            hiddenNodeIDs.insert(nodeID)
        } else {
            hiddenNodeIDs.remove(nodeID)
        }
    }

    public func resetCamera() {
        resetCameraToken = UUID()
    }

    public func selectedNodeInfo() -> ThreeDNodeInfo? {
        guard let targetID = selectedNodeID, let roots = loadedModel?.metadata.rootNodes else { return nil }
        return findNode(id: targetID, in: roots)
    }

    public func explainModelWithAI() {
        guard let meta = loadedModel?.metadata else { return }
        let draft = "Please analyze this 3D model's structure, geometry, and materials, and suggest any workflow improvements:\n\n\(meta.summaryForAI())"
        coordinator.openNewChat(draft: draft)
    }

    private func findNode(id: String, in nodes: [ThreeDNodeInfo]) -> ThreeDNodeInfo? {
        for n in nodes {
            if n.id == id { return n }
            if let hit = findNode(id: id, in: n.children) { return hit }
        }
        return nil
    }
}
