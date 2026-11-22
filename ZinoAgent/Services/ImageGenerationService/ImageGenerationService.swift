import Foundation
import UIKit
import Photos
import Combine

/// Unified online + optional offline image generation service with persistent local gallery history.
@MainActor
public final class ImageGenerationService: ObservableObject {
    @Published public private(set) var history: [ImageGenerationRecord] = []

    public let coreMLEngine: CoreMLDiffusionEngine
    private let onlineEngine: OnlineAIEngine
    private let database: AppDatabase
    private let storagePaths: AppStoragePaths

    public init(
        database: AppDatabase,
        storagePaths: AppStoragePaths,
        onlineEngine: OnlineAIEngine
    ) {
        self.database = database
        self.storagePaths = storagePaths
        self.onlineEngine = onlineEngine
        self.coreMLEngine = CoreMLDiffusionEngine(storagePaths: storagePaths)
        reloadHistory()
    }

    public func reloadHistory() {
        do {
            let rows = try database.sqlite.query("SELECT * FROM image_generations ORDER BY created_at DESC LIMIT 200;")
            self.history = rows.compactMap { row in
                guard let id = row.string("id"),
                      let prompt = row.string("prompt"),
                      let modeRaw = row.string("mode"),
                      let mode = ImageGenerationMode(rawValue: modeRaw),
                      let providerName = row.string("provider_name"),
                      let modelName = row.string("model_name"),
                      let width = row.int("width"),
                      let height = row.int("height"),
                      let relPath = row.string("relative_image_path"),
                      let durationMs = row.int("duration_ms"),
                      let createdAt = row.date("created_at") else { return nil }
                return ImageGenerationRecord(
                    id: id,
                    prompt: prompt,
                    negativePrompt: row.string("negative_prompt"),
                    mode: mode,
                    providerName: providerName,
                    modelName: modelName,
                    width: width,
                    height: height,
                    quality: row.string("quality"),
                    seed: row.int("seed"),
                    relativeImagePath: relPath,
                    durationMs: durationMs,
                    createdAt: createdAt
                )
            }
        } catch {
            AppLogger.shared.error("ImageStudio", "Failed to load image history: \(error.localizedDescription)")
        }
    }

    public func imageURL(for record: ImageGenerationRecord) -> URL {
        storagePaths.generatedImagesDirectory.appendingPathComponent(record.relativeImagePath)
    }

    public func generateOnline(
        provider: ProviderConfiguration,
        modelID: String,
        prompt: String,
        width: Int,
        height: Int,
        quality: String?
    ) async throws -> ImageGenerationRecord {
        let started = Date()
        let request = OnlineImageRequest(
            modelID: modelID,
            prompt: prompt,
            negativePrompt: nil,
            width: width,
            height: height,
            quality: quality
        )
        let payloads = try await onlineEngine.generateImage(provider: provider, request: request)
        guard let first = payloads.first else {
            throw ZinoError(.networkFailure, "No image returned by provider.")
        }

        let actualSize = imageDimensions(from: first.imageData) ?? (width, height)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        return try saveGeneratedImage(
            data: first.imageData,
            prompt: prompt,
            negativePrompt: nil,
            mode: .online,
            providerName: provider.name,
            modelName: modelID,
            width: actualSize.0,
            height: actualSize.1,
            quality: quality,
            seed: nil,
            durationMs: elapsedMs
        )
    }

    public func generateOfflineCoreML(
        prompt: String,
        negativePrompt: String,
        steps: Int,
        guidanceScale: Float,
        seed: UInt32
    ) async throws -> ImageGenerationRecord {
        guard let loaded = coreMLEngine.loadedModel else {
            throw ZinoError(.modelNotLoaded, "Load a compiled Core ML Stable Diffusion model first.")
        }
        let started = Date()
        let result = try await coreMLEngine.generate(
            prompt: prompt,
            negativePrompt: negativePrompt,
            steps: steps,
            guidanceScale: guidanceScale,
            seed: seed
        )
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        return try saveGeneratedImage(
            data: result.pngData,
            prompt: prompt,
            negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
            mode: .offlineCoreML,
            providerName: "Core ML (Local)",
            modelName: loaded.name,
            width: result.width,
            height: result.height,
            quality: "\(steps) steps",
            seed: Int(seed),
            durationMs: elapsedMs
        )
    }

    public func deleteRecord(_ record: ImageGenerationRecord) throws {
        let url = imageURL(for: record)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try database.sqlite.execute("DELETE FROM image_generations WHERE id = ?;", bindings: [.text(record.id)])
        try database.sqlite.execute("DELETE FROM recent_activity WHERE reference_id = ? AND kind = 'image';", bindings: [.text(record.id)])
        reloadHistory()
    }

    public func saveToPhotoLibrary(_ record: ImageGenerationRecord) async throws {
        let url = imageURL(for: record)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw ZinoError(.fileNotFound, "Image file is missing.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ZinoError(.permissionDenied, "Photo Library permission was denied. Enable it in iPadOS Settings to save images.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    private func saveGeneratedImage(
        data: Data,
        prompt: String,
        negativePrompt: String?,
        mode: ImageGenerationMode,
        providerName: String,
        modelName: String,
        width: Int,
        height: Int,
        quality: String?,
        seed: Int?,
        durationMs: Int
    ) throws -> ImageGenerationRecord {
        try FileManager.default.createDirectory(at: storagePaths.generatedImagesDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let filename = "img-\(id).png"
        let url = storagePaths.generatedImagesDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)

        let record = ImageGenerationRecord(
            id: id,
            prompt: prompt,
            negativePrompt: negativePrompt,
            mode: mode,
            providerName: providerName,
            modelName: modelName,
            width: width,
            height: height,
            quality: quality,
            seed: seed,
            relativeImagePath: filename,
            durationMs: durationMs,
            createdAt: Date()
        )

        try database.sqlite.execute(
            """
            INSERT INTO image_generations (
                id, prompt, negative_prompt, mode, provider_name, model_name,
                width, height, quality, seed, relative_image_path, duration_ms, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id),
                .text(record.prompt),
                record.negativePrompt.map { .text($0) } ?? .null,
                .text(record.mode.rawValue),
                .text(record.providerName),
                .text(record.modelName),
                .integer(Int64(record.width)),
                .integer(Int64(record.height)),
                record.quality.map { .text($0) } ?? .null,
                record.seed.map { .integer(Int64($0)) } ?? .null,
                .text(record.relativeImagePath),
                .integer(Int64(record.durationMs)),
                .real(record.createdAt.timeIntervalSince1970)
            ]
        )

        try? database.recordRecentActivity(
            kind: "image",
            title: String(prompt.prefix(48)),
            subtitle: "\(modelName) • \(width)×\(height)",
            referenceID: record.id
        )
        reloadHistory()
        return record
    }

    private func imageDimensions(from data: Data) -> (Int, Int)? {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        return (cg.width, cg.height)
    }
}
