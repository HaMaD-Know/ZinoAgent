import Foundation
import Combine

/// Manages the persistent local GGUF model registry, file imports, GGUF verification,
/// compatibility re-evaluation, and safe deletion.
@MainActor
public final class ModelRegistryService: ObservableObject {
    @Published public private(set) var models: [LocalModelRecord] = []

    private let database: AppDatabase
    private let storagePaths: AppStoragePaths
    private let resourceMonitor: SystemResourceMonitor

    public init(database: AppDatabase, storagePaths: AppStoragePaths, resourceMonitor: SystemResourceMonitor) {
        self.database = database
        self.storagePaths = storagePaths
        self.resourceMonitor = resourceMonitor
        reload()
    }

    public func reload() {
        do {
            let rows = try database.sqlite.query("SELECT * FROM local_models ORDER BY created_at DESC;")
            var loaded: [LocalModelRecord] = []
            for row in rows {
                guard let id = row.string("id"),
                      let name = row.string("name"),
                      let filename = row.string("filename"),
                      let relativePath = row.string("relative_path"),
                      let size = row.int64("file_size_bytes"),
                      let arch = row.string("architecture"),
                      let quant = row.string("quantization"),
                      let params = row.string("parameter_count_label"),
                      let ctx = row.int("context_length"),
                      let trainedCtx = row.int("trained_context_length"),
                      let layers = row.int("layer_count"),
                      let embd = row.int("embedding_dim"),
                      let statusRaw = row.string("compatibility_status"),
                      let status = ModelCompatibilityStatus(rawValue: statusRaw),
                      let notes = row.string("compatibility_notes"),
                      let estRAM = row.int64("estimated_ram_bytes"),
                      let created = row.date("created_at") else { continue }

                let record = LocalModelRecord(
                    id: id,
                    name: name,
                    filename: filename,
                    relativePath: relativePath,
                    fileSizeBytes: size,
                    architecture: arch,
                    quantization: quant,
                    parameterCountLabel: params,
                    contextLength: ctx,
                    trainedContextLength: trainedCtx,
                    layerCount: layers,
                    embeddingDim: embd,
                    hasChatTemplate: row.bool("has_chat_template"),
                    isSplit: row.bool("is_split"),
                    compatibilityStatus: status,
                    compatibilityNotes: notes,
                    estimatedRAMBytes: estRAM,
                    sourceURL: row.string("source_url"),
                    sha256Prefix: row.string("sha256_prefix"),
                    createdAt: created
                )
                // Only keep entries whose files still exist on disk.
                if FileManager.default.fileExists(atPath: resolveFileURL(for: record).path) {
                    loaded.append(record)
                }
            }
            self.models = loaded
        } catch {
            AppLogger.shared.error("ModelRegistry", "Failed to load local models: \(error.localizedDescription)")
        }
    }

    public func resolveFileURL(for model: LocalModelRecord) -> URL {
        storagePaths.localModelsDirectory.appendingPathComponent(model.relativePath)
    }

    /// Copies a user-selected GGUF model from Apple Files into app-managed storage and verifies its GGUF header.
    @discardableResult
    public func importModel(from externalURL: URL, targetContextLength: Int = 4096) throws -> LocalModelRecord {
        let accessed = externalURL.startAccessingSecurityScopedResource()
        defer { if accessed { externalURL.stopAccessingSecurityScopedResource() } }

        guard externalURL.pathExtension.lowercased() == "gguf" else {
            throw ZinoError(.unsupportedFormat, "Only .gguf model files can be imported into the local LLM engine.")
        }

        // Validate GGUF header BEFORE copying gigabytes of weights.
        let metadata = try GGUFHeaderParser.parse(fileURL: externalURL)

        let fm = FileManager.default
        try fm.createDirectory(at: storagePaths.localModelsDirectory, withIntermediateDirectories: true)
        let filename = externalURL.lastPathComponent
        var destURL = storagePaths.localModelsDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: destURL.path) {
            let base = externalURL.deletingPathExtension().lastPathComponent
            destURL = storagePaths.localModelsDirectory.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).gguf")
        }
        try fm.copyItem(at: externalURL, to: destURL)
        let shaPrefix = ModelDownloadManager.computeSHA256Prefix(for: destURL)

        return try registerModelFile(
            at: destURL,
            displayName: metadata.name ?? destURL.deletingPathExtension().lastPathComponent,
            sourceURL: nil,
            sha256Prefix: shaPrefix,
            targetContextLength: targetContextLength
        )
    }

    /// Inspects and persists a GGUF model already placed in `localModelsDirectory`.
    @discardableResult
    public func registerModelFile(
        at fileURL: URL,
        displayName: String? = nil,
        sourceURL: String? = nil,
        sha256Prefix: String? = nil,
        targetContextLength: Int = 4096
    ) throws -> LocalModelRecord {
        let metadata: GGUFMetadata
        let report: GGUFCompatibilityReport

        let headroom = Int64(resourceMonitor.snapshot.availableHeadroomBytes)
        do {
            metadata = try GGUFHeaderParser.parse(fileURL: fileURL)
            report = GGUFHeaderParser.evaluateCompatibility(
                metadata: metadata,
                targetContextLength: targetContextLength,
                availableHeadroomBytes: headroom,
                fileURL: fileURL
            )
        } catch {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            metadata = GGUFMetadata(
                version: 0,
                tensorCount: 0,
                kvCount: 0,
                architecture: "unknown",
                name: displayName,
                sizeLabel: nil,
                fileType: nil,
                quantizationLabel: "Unknown",
                trainedContextLength: 0,
                blockCount: 0,
                embeddingLength: 0,
                headCount: 0,
                headCountKV: 0,
                hasChatTemplate: false,
                isSplit: false,
                splitCount: 0,
                fileSizeBytes: size
            )
            report = GGUFCompatibilityReport(
                status: .corruptOrInvalid,
                notes: error.localizedDescription,
                estimatedRAMBytes: size,
                availableHeadroomBytes: headroom
            )
        }

        let name = displayName ?? metadata.name ?? fileURL.deletingPathExtension().lastPathComponent
        let record = LocalModelRecord(
            name: name,
            filename: fileURL.lastPathComponent,
            relativePath: fileURL.lastPathComponent,
            fileSizeBytes: metadata.fileSizeBytes,
            architecture: metadata.architecture.isEmpty ? "unknown" : metadata.architecture,
            quantization: metadata.quantizationLabel,
            parameterCountLabel: metadata.sizeLabel ?? inferParameterLabel(sizeBytes: metadata.fileSizeBytes, quantization: metadata.quantizationLabel),
            contextLength: min(targetContextLength, max(512, metadata.trainedContextLength)),
            trainedContextLength: metadata.trainedContextLength,
            layerCount: metadata.blockCount,
            embeddingDim: metadata.embeddingLength,
            hasChatTemplate: metadata.hasChatTemplate,
            isSplit: metadata.isSplit,
            compatibilityStatus: report.status,
            compatibilityNotes: report.notes,
            estimatedRAMBytes: report.estimatedRAMBytes,
            sourceURL: sourceURL,
            sha256Prefix: sha256Prefix,
            createdAt: Date()
        )

        try persist(record)
        reload()
        return record
    }

    public func deleteModel(_ model: LocalModelRecord) throws {
        let url = resolveFileURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try database.sqlite.execute("DELETE FROM local_models WHERE id = ?;", bindings: [.text(model.id)])
        reload()
    }

    /// Evaluates whether a model fits safely in current device memory headroom without silently downgrading.
    public func checkMemoryFit(for model: LocalModelRecord, contextLength: Int) -> GGUFCompatibilityReport {
        let url = resolveFileURL(for: model)
        let headroom = Int64(resourceMonitor.snapshot.availableHeadroomBytes)
        if let meta = try? GGUFHeaderParser.parse(fileURL: url) {
            return GGUFHeaderParser.evaluateCompatibility(
                metadata: meta,
                targetContextLength: contextLength,
                availableHeadroomBytes: headroom,
                fileURL: url
            )
        }
        return GGUFCompatibilityReport(
            status: model.compatibilityStatus,
            notes: model.compatibilityNotes,
            estimatedRAMBytes: model.estimatedRAMBytes,
            availableHeadroomBytes: headroom
        )
    }

    /// Offers smaller compatible alternatives if the user's chosen model triggers a memory warning.
    public func smallerAlternatives(to model: LocalModelRecord) -> [LocalModelRecord] {
        models.filter { $0.id != model.id && $0.estimatedRAMBytes < model.estimatedRAMBytes && $0.compatibilityStatus == .compatible }
    }

    private func persist(_ m: LocalModelRecord) throws {
        try database.sqlite.execute(
            """
            INSERT INTO local_models (
                id, name, filename, relative_path, file_size_bytes, architecture, quantization,
                parameter_count_label, context_length, trained_context_length, layer_count,
                embedding_dim, has_chat_template, is_split, compatibility_status, compatibility_notes,
                estimated_ram_bytes, source_url, sha256_prefix, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                compatibility_status = excluded.compatibility_status,
                compatibility_notes = excluded.compatibility_notes,
                estimated_ram_bytes = excluded.estimated_ram_bytes;
            """,
            bindings: [
                .text(m.id), .text(m.name), .text(m.filename), .text(m.relativePath),
                .integer(m.fileSizeBytes), .text(m.architecture), .text(m.quantization),
                .text(m.parameterCountLabel), .integer(Int64(m.contextLength)),
                .integer(Int64(m.trainedContextLength)), .integer(Int64(m.layerCount)),
                .integer(Int64(m.embeddingDim)), .integer(m.hasChatTemplate ? 1 : 0),
                .integer(m.isSplit ? 1 : 0), .text(m.compatibilityStatus.rawValue),
                .text(m.compatibilityNotes), .integer(m.estimatedRAMBytes),
                m.sourceURL.map { .text($0) } ?? .null,
                m.sha256Prefix.map { .text($0) } ?? .null,
                .real(m.createdAt.timeIntervalSince1970)
            ]
        )
    }

    private func inferParameterLabel(sizeBytes: Int64, quantization: String) -> String {
        let bitsPerParam: Double
        if quantization.hasPrefix("Q2") || quantization.hasPrefix("IQ2") { bitsPerParam = 2.7 }
        else if quantization.hasPrefix("Q3") || quantization.hasPrefix("IQ3") { bitsPerParam = 3.5 }
        else if quantization.hasPrefix("Q4") || quantization.hasPrefix("IQ4") { bitsPerParam = 4.8 }
        else if quantization.hasPrefix("Q5") { bitsPerParam = 5.7 }
        else if quantization.hasPrefix("Q6") { bitsPerParam = 6.6 }
        else if quantization.hasPrefix("Q8") { bitsPerParam = 8.5 }
        else if quantization == "F16" || quantization == "BF16" { bitsPerParam = 16.0 }
        else { bitsPerParam = 4.8 }

        let paramsBillions = (Double(sizeBytes) * 8.0 / bitsPerParam) / 1_000_000_000.0
        if paramsBillions >= 1.0 {
            return String(format: "~%.1fB", paramsBillions)
        }
        return String(format: "~%.0fM", max(100, paramsBillions * 1000))
    }
}
