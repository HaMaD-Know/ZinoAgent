import Foundation
import SwiftUI
import Combine

public struct HighMemoryLoadPrompt: Identifiable {
    public let id = UUID()
    public let model: LocalModelRecord
    public let report: GGUFCompatibilityReport
    public let alternatives: [LocalModelRecord]
}

@MainActor
public final class ModelManagerViewModel: ObservableObject {
    public enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case catalog = "Download Catalog"
        case coreML = "Core ML Image"

        public var id: String { rawValue }
    }

    @Published public var selectedTab: Tab = .installed
    @Published public var customDownloadURL: String = ""
    @Published public var customDownloadName: String = ""
    @Published public var memoryWarningPrompt: HighMemoryLoadPrompt?
    @Published public var pendingDeleteModel: LocalModelRecord?
    @Published public var benchmarkResult: LocalBenchmarkResult?
    @Published public var isBenchmarking: Bool = false
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?

    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        if coordinator.requestOpenModelCatalog {
            selectedTab = .catalog
            coordinator.requestOpenModelCatalog = false
        }
    }

    public func consumeHandoff() {
        if coordinator.requestOpenModelCatalog {
            selectedTab = .catalog
            coordinator.requestOpenModelCatalog = false
        }
    }

    public func importGGUF(from url: URL) {
        do {
            let record = try coordinator.modelRegistry.importModel(
                from: url,
                targetContextLength: coordinator.settings.localContextLength
            )
            coordinator.refreshStorage()
            statusMessage = "Imported '\(record.name)' (\(record.architecture.uppercased()), \(record.quantization))."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func importCoreMLFolder(from url: URL) {
        do {
            let info = try coordinator.imageGenerationService.coreMLEngine.importModelFolder(from: url)
            coordinator.refreshStorage()
            statusMessage = "Imported Core ML model '\(info.name)' (\(info.isSDXL ? "SDXL" : "SD 1.5/2.1"))."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func startCatalogDownload(_ entry: CatalogModelEntry) {
        do {
            try coordinator.downloadManager.startDownload(
                id: entry.id,
                name: entry.name,
                url: entry.downloadURL,
                filename: entry.filename
            )
            statusMessage = "Downloading '\(entry.name)'..."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func startCustomDownload() {
        let trimmed = customDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = "Enter a valid HTTPS URL to a .gguf model file."
            return
        }
        let filename = url.lastPathComponent.isEmpty ? "custom-model.gguf" : url.lastPathComponent
        let name = customDownloadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : customDownloadName
        do {
            try coordinator.downloadManager.startDownload(name: name, url: url, filename: filename)
            customDownloadURL = ""
            customDownloadName = ""
            statusMessage = "Started download for '\(name)'."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Evaluates compatibility and RAM fit before loading. Never silently downgrades the user's choice.
    public func requestLoad(_ model: LocalModelRecord) {
        let report = coordinator.modelRegistry.checkMemoryFit(
            for: model,
            contextLength: coordinator.settings.localContextLength
        )

        switch report.status {
        case .compatible:
            performLoad(model)
        case .warningHighMemory:
            let alts = coordinator.modelRegistry.smallerAlternatives(to: model)
            memoryWarningPrompt = HighMemoryLoadPrompt(model: model, report: report, alternatives: alts)
        case .incompatibleArchitecture, .splitShardIncomplete, .corruptOrInvalid:
            errorMessage = report.notes
        }
    }

    public func performLoad(_ model: LocalModelRecord) {
        memoryWarningPrompt = nil
        benchmarkResult = nil
        Task {
            do {
                let url = coordinator.modelRegistry.resolveFileURL(for: model)
                try await coordinator.offlineEngine.loadModel(
                    model,
                    fileURL: url,
                    contextLength: coordinator.settings.localContextLength,
                    useMetalGPU: coordinator.settings.useMetalGPUOffload
                )
                coordinator.resourceMonitor.refresh()
                statusMessage = "Loaded '\(model.name)' and ready for offline chat."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func unloadActiveModel() {
        Task {
            await coordinator.offlineEngine.unload()
            benchmarkResult = nil
            coordinator.resourceMonitor.refresh()
            statusMessage = "Unloaded local model."
        }
    }

    public func runBenchmark() {
        isBenchmarking = true
        Task {
            defer { isBenchmarking = false }
            do {
                benchmarkResult = try await coordinator.offlineEngine.runBenchmark()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func deleteModel(_ model: LocalModelRecord) {
        Task {
            if coordinator.offlineEngine.loadedModel?.id == model.id {
                await coordinator.offlineEngine.unload()
            }
            do {
                try coordinator.modelRegistry.deleteModel(model)
                coordinator.refreshStorage()
                statusMessage = "Deleted '\(model.name)'."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
