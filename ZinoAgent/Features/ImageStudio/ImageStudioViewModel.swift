import Foundation
import SwiftUI
import Combine

@MainActor
public final class ImageStudioViewModel: ObservableObject {
    @Published public var mode: ImageGenerationMode = .online
    @Published public var prompt: String = ""
    @Published public var negativePrompt: String = ""
    @Published public var selectedProviderID: String?
    @Published public var selectedModelID: String = "gpt-image-1"
    @Published public var selectedSizeIndex: Int = 0
    @Published public var selectedQuality: String = "medium"

    // Offline Core ML controls
    @Published public var steps: Int = 25
    @Published public var guidanceScale: Double = 7.5
    @Published public var useRandomSeed: Bool = true
    @Published public var customSeedText: String = "42"

    @Published public var isGenerating: Bool = false
    @Published public var selectedRecord: ImageGenerationRecord?
    @Published public var shareURL: URL?
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?

    private let coordinator: AppCoordinator
    private var activeTask: Task<Void, Never>?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        syncDefaultProvider()
        selectedRecord = coordinator.imageGenerationService.history.first
    }

    public var imageCapableProviders: [ProviderConfiguration] {
        coordinator.providerRegistry.providers.filter { $0.providerType != .anthropic }
    }

    public var selectedProvider: ProviderConfiguration? {
        if let id = selectedProviderID, let match = imageCapableProviders.first(where: { $0.id == id }) {
            return match
        }
        return imageCapableProviders.first
    }

    public var availableOnlineModels: [String] {
        guard let provider = selectedProvider else { return [] }
        let discovered = provider.cachedModels.filter(\.supportsImageGeneration).map(\.id)
        if !discovered.isEmpty { return discovered }
        switch provider.providerType {
        case .openAI: return ["gpt-image-1", "dall-e-3"]
        case .gemini: return ["imagen-3.0-generate-002", "gemini-2.0-flash-exp-image-generation"]
        case .openAICompatible: return [provider.defaultModelID ?? "flux"]
        case .anthropic: return []
        }
    }

    public var currentCapabilities: ImageProviderCapabilities {
        if mode == .offlineCoreML {
            let native = coordinator.imageGenerationService.coreMLEngine.loadedModel?.nativeSize ?? 512
            return ImageProviderCapabilities.forOfflineCoreML(nativeSize: native)
        }
        guard let provider = selectedProvider else {
            return ImageProviderCapabilities.forProvider(type: .openAI, modelID: selectedModelID)
        }
        return ImageProviderCapabilities.forProvider(type: provider.providerType, modelID: selectedModelID)
    }

    public func syncDefaultProvider() {
        if selectedProviderID == nil, let first = imageCapableProviders.first {
            selectedProviderID = first.id
            selectedModelID = availableOnlineModels.first ?? "gpt-image-1"
            selectedQuality = currentCapabilities.qualityOptions.first ?? ""
        }
    }

    public func generate() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a prompt describing the image you want to generate."
            return
        }

        errorMessage = nil
        statusMessage = nil
        isGenerating = true

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isGenerating = false }

            do {
                let record: ImageGenerationRecord
                if self.mode == .online {
                    guard let provider = self.selectedProvider else {
                        throw ZinoError(.providerNotConfigured, "Configure an OpenAI, Gemini, or OpenAI-compatible provider in Settings to generate images online.")
                    }
                    let sizes = self.currentCapabilities.supportedSizes
                    let chosen = sizes.indices.contains(self.selectedSizeIndex)
                        ? sizes[self.selectedSizeIndex]
                        : ImageSizeOption(label: "1024×1024", width: 1024, height: 1024)
                    let qual = self.currentCapabilities.supportsQualitySelector ? self.selectedQuality : nil

                    record = try await self.coordinator.imageGenerationService.generateOnline(
                        provider: provider,
                        modelID: self.selectedModelID,
                        prompt: trimmed,
                        width: chosen.width,
                        height: chosen.height,
                        quality: qual
                    )
                } else {
                    let seed: UInt32
                    if self.useRandomSeed {
                        seed = UInt32.random(in: 1..<UInt32.max)
                    } else {
                        seed = UInt32(self.customSeedText) ?? 42
                    }
                    record = try await self.coordinator.imageGenerationService.generateOfflineCoreML(
                        prompt: trimmed,
                        negativePrompt: self.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        steps: self.steps,
                        guidanceScale: Float(self.guidanceScale),
                        seed: seed
                    )
                }

                self.selectedRecord = record
                self.coordinator.refreshStorage()
                self.statusMessage = "Generated \(record.width)×\(record.height) image in \(String(format: "%.1fs", Double(record.durationMs) / 1000.0))."
            } catch let zErr as ZinoError where zErr.code == .cancelled {
                self.statusMessage = "Image generation cancelled."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func cancelGeneration() {
        activeTask?.cancel()
        coordinator.imageGenerationService.coreMLEngine.cancelGeneration()
        isGenerating = false
    }

    public func loadCoreMLModel(_ model: CoreMLDiffusionModelInfo) {
        Task {
            do {
                try await coordinator.imageGenerationService.coreMLEngine.load(
                    model: model,
                    availableHeadroomBytes: coordinator.resourceMonitor.snapshot.availableHeadroomBytes
                )
                statusMessage = "Loaded Core ML model '\(model.name)'."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func unloadCoreMLModel() {
        Task {
            await coordinator.imageGenerationService.coreMLEngine.unload()
            statusMessage = "Unloaded Core ML image model."
        }
    }

    public func importCoreMLModel(from url: URL) {
        do {
            let info = try coordinator.imageGenerationService.coreMLEngine.importModelFolder(from: url)
            coordinator.refreshStorage()
            statusMessage = "Imported Core ML model '\(info.name)'."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveSelectedToPhotos() {
        guard let record = selectedRecord else { return }
        Task {
            do {
                try await coordinator.imageGenerationService.saveToPhotoLibrary(record)
                statusMessage = "Saved image to Photo Library."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func exportSelected() {
        guard let record = selectedRecord else { return }
        shareURL = coordinator.imageGenerationService.imageURL(for: record)
    }

    public func deleteRecord(_ record: ImageGenerationRecord) {
        do {
            try coordinator.imageGenerationService.deleteRecord(record)
            if selectedRecord?.id == record.id {
                selectedRecord = coordinator.imageGenerationService.history.first
            }
            coordinator.refreshStorage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func sendPromptToAIChatForHelp() {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = base.isEmpty
            ? "Help me craft a detailed, cinematic image generation prompt."
            : "Refine and expand this image generation prompt with lighting, composition, and lens details:\n\n\"\(base)\""
        coordinator.openNewChat(draft: draft)
    }
}
