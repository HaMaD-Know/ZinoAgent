import Foundation
import Combine
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(StableDiffusion)
import StableDiffusion
#endif

/// Optional offline image generation engine using Apple's Core ML `StableDiffusion` package.
/// Validates compiled `.mlmodelc` packages, monitors memory, reports step progress, and supports cancellation.
@MainActor
public final class CoreMLDiffusionEngine: ObservableObject {
    @Published public private(set) var installedModels: [CoreMLDiffusionModelInfo] = []
    @Published public private(set) var loadedModel: CoreMLDiffusionModelInfo?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isGenerating: Bool = false
    @Published public private(set) var progressStep: Int = 0
    @Published public private(set) var progressTotalSteps: Int = 0

    private let storagePaths: AppStoragePaths
    private let worker = CoreMLDiffusionWorker()

    public init(storagePaths: AppStoragePaths) {
        self.storagePaths = storagePaths
        scanInstalledModels()
    }

    public static var isRuntimeCompiledIn: Bool {
        #if canImport(StableDiffusion)
        return true
        #else
        return false
        #endif
    }

    public func scanInstalledModels() {
        let root = storagePaths.diffusionModelsDirectory
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            installedModels = []
            return
        }

        installedModels = folders.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return Self.inspectModelDirectory(url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies a user-selected compiled Core ML Stable Diffusion folder into app-managed storage and validates it.
    @discardableResult
    public func importModelFolder(from externalURL: URL) throws -> CoreMLDiffusionModelInfo {
        let accessed = externalURL.startAccessingSecurityScopedResource()
        defer { if accessed { externalURL.stopAccessingSecurityScopedResource() } }

        let inspected = Self.inspectModelDirectory(externalURL)
        guard inspected.isValid else {
            throw ZinoError(
                .incompatibleModel,
                "Folder '\(externalURL.lastPathComponent)' is not a valid compiled Core ML Stable Diffusion package. Missing: \(inspected.missingComponents.joined(separator: ", "))."
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(at: storagePaths.diffusionModelsDirectory, withIntermediateDirectories: true)
        var dest = storagePaths.diffusionModelsDirectory.appendingPathComponent(externalURL.lastPathComponent, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            dest = storagePaths.diffusionModelsDirectory.appendingPathComponent("\(externalURL.lastPathComponent)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        }
        try fm.copyItem(at: externalURL, to: dest)
        scanInstalledModels()
        return Self.inspectModelDirectory(dest)
    }

    public func deleteModel(_ info: CoreMLDiffusionModelInfo) throws {
        if loadedModel?.id == info.id {
            Task { await unload() }
        }
        try FileManager.default.removeItem(at: info.folderURL)
        scanInstalledModels()
    }

    public func load(model: CoreMLDiffusionModelInfo, availableHeadroomBytes: UInt64) async throws {
        guard model.isValid else {
            throw ZinoError(.incompatibleModel, "Missing required Core ML files: \(model.missingComponents.joined(separator: ", ")).")
        }
        if availableHeadroomBytes > 0 && Int64(availableHeadroomBytes) < model.estimatedRAMBytes / 2 {
            throw ZinoError(
                .insufficientMemory,
                "Available memory headroom (\(Formatters.memory(availableHeadroomBytes))) is too low to safely load \(model.name) (needs ~\(Formatters.bytes(model.estimatedRAMBytes))). Unload any active local LLM first."
            )
        }

        await unload()
        isLoading = true
        defer { isLoading = false }

        try await worker.load(resourceDir: Self.locateResourceDir(model.folderURL), isXL: model.isSDXL)
        loadedModel = model
        AppLogger.shared.info("ImageStudio", "Loaded Core ML Diffusion model '\(model.name)'")
    }

    public func unload() async {
        worker.cancel()
        await worker.unload()
        loadedModel = nil
        isGenerating = false
    }

    public func cancelGeneration() {
        worker.cancel()
    }

    public func generate(
        prompt: String,
        negativePrompt: String,
        steps: Int,
        guidanceScale: Float,
        seed: UInt32
    ) async throws -> (pngData: Data, width: Int, height: Int) {
        guard loadedModel != nil else {
            throw ZinoError(.modelNotLoaded, "Load a compiled Core ML Stable Diffusion model before generating offline.")
        }
        isGenerating = true
        progressStep = 0
        progressTotalSteps = steps
        defer { isGenerating = false }

        return try await worker.generate(
            prompt: prompt,
            negativePrompt: negativePrompt,
            steps: steps,
            guidanceScale: guidanceScale,
            seed: seed
        ) { [weak self] step, total in
            Task { @MainActor in
                self?.progressStep = step
                self?.progressTotalSteps = total
            }
        }
    }

    // MARK: - Model Directory Validation

    public nonisolated static func locateResourceDir(_ url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("vocab.json").path) { return url }
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let candidate as URL in enumerator where candidate.lastPathComponent == "vocab.json" {
                return candidate.deletingLastPathComponent()
            }
        }
        return url
    }

    public nonisolated static func inspectModelDirectory(_ folderURL: URL) -> CoreMLDiffusionModelInfo {
        let dir = locateResourceDir(folderURL)
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }

        let hasUnet = exists("Unet.mlmodelc") || (exists("UnetChunk1.mlmodelc") && exists("UnetChunk2.mlmodelc"))
        var missing: [String] = []
        if !exists("TextEncoder.mlmodelc") { missing.append("TextEncoder.mlmodelc") }
        if !hasUnet { missing.append("Unet.mlmodelc (or UnetChunk1/2)") }
        if !exists("VAEDecoder.mlmodelc") { missing.append("VAEDecoder.mlmodelc") }
        if !exists("vocab.json") { missing.append("vocab.json") }
        if !exists("merges.txt") { missing.append("merges.txt") }

        let isXL = exists("TextEncoder2.mlmodelc")
        let sizeBytes = AppStoragePaths.directorySize(at: folderURL)
        let estimatedRAM: Int64 = isXL ? 4_600_000_000 : 2_600_000_000

        return CoreMLDiffusionModelInfo(
            id: folderURL.lastPathComponent,
            name: folderURL.lastPathComponent,
            folderURL: folderURL,
            isValid: missing.isEmpty,
            missingComponents: missing,
            isSDXL: isXL,
            supportsImageToImage: exists("VAEEncoder.mlmodelc"),
            nativeSize: isXL ? 1024 : 512,
            diskSizeBytes: sizeBytes,
            estimatedRAMBytes: estimatedRAM
        )
    }
}

private final class CoreMLDiffusionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zinoagent.diffusion.worker", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    #if canImport(StableDiffusion)
    private var pipeline: StableDiffusionPipelineProtocol?
    private var isXL = false
    #endif

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func resetCancel() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func load(resourceDir: URL, isXL: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                #if canImport(StableDiffusion)
                do {
                    self.pipeline?.unloadResources()
                    self.pipeline = nil

                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine
                    let pipe: StableDiffusionPipelineProtocol
                    if isXL {
                        pipe = try StableDiffusionXLPipeline(resourcesAt: resourceDir, configuration: config, reduceMemory: true)
                    } else {
                        pipe = try StableDiffusionPipeline(resourcesAt: resourceDir, controlNet: [], configuration: config, disableSafety: false, reduceMemory: true)
                    }
                    try pipe.loadResources()
                    self.pipeline = pipe
                    self.isXL = isXL
                    cont.resume()
                } catch {
                    cont.resume(throwing: ZinoError(.modelLoadFailed, "Core ML Stable Diffusion failed to load: \(error.localizedDescription)"))
                }
                #else
                cont.resume(throwing: ZinoError(.unsupportedFormat, "Apple ml-stable-diffusion package is not linked in this build."))
                #endif
            }
        }
    }

    func unload() async {
        await withCheckedContinuation { cont in
            queue.async {
                #if canImport(StableDiffusion)
                self.pipeline?.unloadResources()
                self.pipeline = nil
                #endif
                cont.resume()
            }
        }
    }

    func generate(
        prompt: String,
        negativePrompt: String,
        steps: Int,
        guidanceScale: Float,
        seed: UInt32,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> (pngData: Data, width: Int, height: Int) {
        resetCancel()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                #if canImport(StableDiffusion)
                guard let pipeline = self.pipeline else {
                    cont.resume(throwing: ZinoError(.modelNotLoaded, "No Core ML diffusion model is loaded."))
                    return
                }
                do {
                    var cfg = PipelineConfiguration(prompt: prompt)
                    cfg.negativePrompt = negativePrompt
                    cfg.stepCount = max(1, min(80, steps))
                    cfg.guidanceScale = guidanceScale
                    cfg.imageCount = 1
                    cfg.seed = seed
                    cfg.schedulerType = .dpmSolverMultistepScheduler
                    cfg.disableSafety = false
                    if self.isXL {
                        cfg.encoderScaleFactor = 0.13025
                        cfg.decoderScaleFactor = 0.13025
                    }

                    let images = try pipeline.generateImages(configuration: cfg) { progress in
                        onProgress(progress.step, progress.stepCount)
                        return !self.isCancelled()
                    }
                    if self.isCancelled() {
                        throw ZinoError(.cancelled, "Image generation cancelled.")
                    }
                    guard let firstOpt = images.first, let cgImage = firstOpt else {
                        throw ZinoError(.inferenceFailed, "Image generation produced no output (or was filtered by the model's safety checker).")
                    }
                    let mutableData = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
                        throw ZinoError(.ioFailure, "Could not encode generated PNG.")
                    }
                    CGImageDestinationAddImage(dest, cgImage, nil)
                    guard CGImageDestinationFinalize(dest) else {
                        throw ZinoError(.ioFailure, "Could not finalize generated PNG.")
                    }
                    cont.resume(returning: (mutableData as Data, cgImage.width, cgImage.height))
                } catch {
                    cont.resume(throwing: error)
                }
                #else
                cont.resume(throwing: ZinoError(.unsupportedFormat, "Apple ml-stable-diffusion package is not linked in this build."))
                #endif
            }
        }
    }
}
