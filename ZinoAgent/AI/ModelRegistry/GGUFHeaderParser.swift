import Foundation

public struct GGUFMetadata: Sendable, Equatable {
    public let version: UInt32
    public let tensorCount: UInt64
    public let kvCount: UInt64
    public let architecture: String
    public let name: String?
    public let sizeLabel: String?
    public let fileType: Int?
    public let quantizationLabel: String
    public let trainedContextLength: Int
    public let blockCount: Int
    public let embeddingLength: Int
    public let headCount: Int
    public let headCountKV: Int
    public let hasChatTemplate: Bool
    public let isSplit: Bool
    public let splitCount: Int
    public let fileSizeBytes: Int64
}

public struct GGUFCompatibilityReport: Sendable, Equatable {
    public let status: ModelCompatibilityStatus
    public let notes: String
    public let estimatedRAMBytes: Int64
    public let availableHeadroomBytes: Int64
}

/// Pure-Swift binary GGUF v2/v3 header parser & llama.cpp compatibility verifier.
/// Inspects only the header metadata (never allocates tensor weights) so invalid, truncated,
/// or incompatible architectures are caught before attempting inference.
public enum GGUFHeaderParser {
    private static let ggufMagic: UInt32 = 0x46554747 // "GGUF" little-endian

    /// Architectures supported by llama.cpp (tag b12020).
    public static let supportedArchitectures: Set<String> = [
        "llama", "llama4", "mistral", "mistral3", "qwen2", "qwen2moe", "qwen2vl", "qwen3", "qwen3moe",
        "gemma", "gemma2", "gemma3", "phi2", "phi3", "deepseek", "deepseek2", "command-r", "cohere2",
        "internlm2", "starcoder", "starcoder2", "falcon", "mpt", "gpt2", "gptneox", "bloom",
        "stablelm", "smollm", "olmo", "olmo2", "granite", "baichuan", "chatglm", "orion",
        "arctic", "dbrx", "jamba", "mamba", "nemotron", "exaone", "minicpm", "minicpm3", "chameleon",
        "glm4", "bailingmoe", "lfm2", "seed_oss"
    ]

    public static func parse(fileURL: URL) throws -> GGUFMetadata {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        guard fileSize >= 24 else {
            throw ZinoError(.incompatibleModel, "File is too small (\(fileSize) bytes) to be a valid GGUF model.")
        }
        // Read up to 4 MB of header metadata (covers even huge tokenizers and chat templates safely).
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let readLength = min(Int(fileSize), 4 * 1024 * 1024)
        let data = try handle.read(upToCount: readLength) ?? Data()
        return try parse(data: data, totalFileSize: fileSize, filename: fileURL.lastPathComponent)
    }

    public static func parse(data: Data, totalFileSize: Int64? = nil, filename: String = "") throws -> GGUFMetadata {
        var reader = BinaryCursor(data: data)
        let magic = try reader.readUInt32()
        guard magic == ggufMagic else {
            throw ZinoError(.incompatibleModel, "Invalid GGUF header magic. This file is not a valid GGUF model.")
        }

        let version = try reader.readUInt32()
        guard version == 2 || version == 3 else {
            throw ZinoError(.incompatibleModel, "Unsupported GGUF format version \(version). llama.cpp requires GGUF v2 or v3.")
        }

        let tensorCount = try reader.readUInt64()
        let kvCount = try reader.readUInt64()
        guard kvCount < 50_000 else {
            throw ZinoError(.incompatibleModel, "GGUF header metadata count (\(kvCount)) appears corrupt.")
        }

        var strings: [String: String] = [:]
        var ints: [String: Int] = [:]

        for _ in 0..<kvCount {
            guard reader.hasRemaining(8) else { break }
            let key: String
            do {
                key = try reader.readGGUFString()
                let valueType = try reader.readUInt32()
                try readKVValue(type: valueType, key: key, reader: &reader, strings: &strings, ints: &ints)
            } catch {
                // Header may exceed our 4 MB sample window due to a huge vocab array; keep already-read metadata.
                break
            }
        }

        let arch = strings["general.architecture"]?.lowercased() ?? ""
        let fileType = ints["general.file_type"]
        let quant = quantizationName(fileType: fileType, filename: filename)
        let trainedCtx = ints["\(arch).context_length"] ?? 4096
        let blocks = ints["\(arch).block_count"] ?? 0
        let embd = ints["\(arch).embedding_length"] ?? 0
        let heads = ints["\(arch).attention.head_count"] ?? 0
        let headsKV = ints["\(arch).attention.head_count_kv"] ?? heads
        let splitCount = ints["split.count"] ?? 0

        return GGUFMetadata(
            version: version,
            tensorCount: tensorCount,
            kvCount: kvCount,
            architecture: arch,
            name: strings["general.name"] ?? strings["general.basename"],
            sizeLabel: strings["general.size_label"],
            fileType: fileType,
            quantizationLabel: quant,
            trainedContextLength: max(512, trainedCtx),
            blockCount: blocks,
            embeddingLength: embd,
            headCount: heads,
            headCountKV: headsKV,
            hasChatTemplate: strings["tokenizer.chat_template"] != nil,
            isSplit: splitCount > 1,
            splitCount: splitCount,
            fileSizeBytes: totalFileSize ?? Int64(data.count)
        )
    }

    public static func evaluateCompatibility(
        metadata: GGUFMetadata,
        targetContextLength: Int,
        availableHeadroomBytes: Int64,
        fileURL: URL? = nil
    ) -> GGUFCompatibilityReport {
        if metadata.architecture.isEmpty {
            return GGUFCompatibilityReport(
                status: .corruptOrInvalid,
                notes: "Missing general.architecture metadata. This GGUF file may be incomplete or non-standard.",
                estimatedRAMBytes: metadata.fileSizeBytes,
                availableHeadroomBytes: availableHeadroomBytes
            )
        }

        if !supportedArchitectures.contains(metadata.architecture) {
            return GGUFCompatibilityReport(
                status: .incompatibleArchitecture,
                notes: "Architecture '\(metadata.architecture)' is not recognized as compatible with this llama.cpp build.",
                estimatedRAMBytes: metadata.fileSizeBytes,
                availableHeadroomBytes: availableHeadroomBytes
            )
        }

        if metadata.isSplit, let url = fileURL {
            let parent = url.deletingLastPathComponent()
            let siblingCount = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
                .filter { $0.hasSuffix(".gguf") && $0.contains("-of-") }
                .count
            if siblingCount < metadata.splitCount {
                return GGUFCompatibilityReport(
                    status: .splitShardIncomplete,
                    notes: "This is a split GGUF (\(metadata.splitCount) shards required). Import all shards into the same folder before loading.",
                    estimatedRAMBytes: metadata.fileSizeBytes * Int64(max(1, metadata.splitCount)),
                    availableHeadroomBytes: availableHeadroomBytes
                )
            }
        }

        // Estimate memory footprint: weights + KV cache (FP16 K & V) + Metal compute buffers (~350 MB).
        let effectiveCtx = min(max(512, targetContextLength), metadata.trainedContextLength)
        let headDim = metadata.headCount > 0 ? (metadata.embeddingLength / max(1, metadata.headCount)) : 128
        let kvBytesPerToken = Int64(max(1, metadata.blockCount)) * Int64(max(1, metadata.headCountKV)) * Int64(max(64, headDim)) * 2 * 2
        let kvCacheBytes = kvBytesPerToken * Int64(effectiveCtx)
        let metalOverhead: Int64 = 380 * 1024 * 1024
        let estimatedRAM = Int64(Double(metadata.fileSizeBytes) * 1.12) + kvCacheBytes + metalOverhead

        // Use real headroom if available, otherwise fall back to conservative 8 GB iPad Pro M2 app budget (~5.2 GB).
        let effectiveBudget = availableHeadroomBytes > 0 ? availableHeadroomBytes : Int64(5.2 * 1_073_741_824.0)
        let safeThreshold = Int64(Double(effectiveBudget) * 0.85)

        if estimatedRAM > safeThreshold {
            let msg = "Estimated memory required is \(Formatters.bytes(estimatedRAM)) (weights + \(effectiveCtx)-token KV cache + Metal buffers), which approaches or exceeds available app memory headroom (\(Formatters.bytes(effectiveBudget))). You may still attempt to load it, lower context length, or choose a smaller quantization."
            return GGUFCompatibilityReport(
                status: .warningHighMemory,
                notes: msg,
                estimatedRAMBytes: estimatedRAM,
                availableHeadroomBytes: effectiveBudget
            )
        }

        return GGUFCompatibilityReport(
            status: .compatible,
            notes: "Verified \(metadata.architecture.uppercased()) (\(metadata.quantizationLabel)) • Est. RAM \(Formatters.bytes(estimatedRAM)) within available headroom (\(Formatters.bytes(effectiveBudget))).",
            estimatedRAMBytes: estimatedRAM,
            availableHeadroomBytes: effectiveBudget
        )
    }

    private static func quantizationName(fileType: Int?, filename: String) -> String {
        let map: [Int: String] = [
            0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1",
            10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M",
            16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS",
            22: "IQ3_XXS", 23: "IQ1_S", 24: "IQ4_NL", 25: "IQ3_S", 26: "IQ3_M",
            27: "IQ2_S", 28: "IQ2_M", 29: "IQ4_XS", 30: "IQ1_M", 31: "BF16"
        ]
        if let ft = fileType, let label = map[ft] {
            return label
        }
        let upper = filename.uppercased()
        for candidate in ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q6_K", "Q8_0", "Q3_K_M", "Q2_K", "IQ4_XS", "F16"] {
            if upper.contains(candidate) { return candidate }
        }
        return "GGUF"
    }

    private static func readKVValue(
        type: UInt32,
        key: String,
        reader: inout BinaryCursor,
        strings: inout [String: String],
        ints: inout [String: Int]
    ) throws {
        switch type {
        case 0: ints[key] = Int(try reader.readUInt8())
        case 1: ints[key] = Int(try reader.readInt8())
        case 2: ints[key] = Int(try reader.readUInt16())
        case 3: ints[key] = Int(try reader.readInt16())
        case 4: ints[key] = Int(try reader.readUInt32())
        case 5: ints[key] = Int(try reader.readInt32())
        case 6: _ = try reader.readUInt32() // float32
        case 7: ints[key] = Int(try reader.readUInt8()) // bool
        case 8:
            let str = try reader.readGGUFString()
            if str.count <= 24_000 { strings[key] = str }
        case 9: // array
            let elemType = try reader.readUInt32()
            let count = try reader.readUInt64()
            try skipArray(elemType: elemType, count: count, reader: &reader)
        case 10: ints[key] = Int(truncatingIfNeeded: try reader.readUInt64())
        case 11: ints[key] = Int(truncatingIfNeeded: try reader.readInt64())
        case 12: _ = try reader.readUInt64() // float64
        default:
            throw ZinoError(.incompatibleModel, "Unknown GGUF metadata value type \(type).")
        }
    }

    private static func skipArray(elemType: UInt32, count: UInt64, reader: inout BinaryCursor) throws {
        switch elemType {
        case 0, 1, 7: try reader.skip(Int(count))
        case 2, 3: try reader.skip(Int(count) * 2)
        case 4, 5, 6: try reader.skip(Int(count) * 4)
        case 10, 11, 12: try reader.skip(Int(count) * 8)
        case 8:
            for _ in 0..<count {
                let len = try reader.readUInt64()
                try reader.skip(Int(len))
            }
        default:
            throw ZinoError(.incompatibleModel, "Unsupported nested GGUF array element type \(elemType).")
        }
    }
}

private struct BinaryCursor {
    let data: Data
    var offset: Int = 0

    func hasRemaining(_ count: Int) -> Bool {
        offset + count <= data.count
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw ZinoError(.incompatibleModel, "Unexpected end of GGUF header.")
        }
        offset += count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard hasRemaining(1) else { throw ZinoError(.incompatibleModel, "Truncated GGUF header.") }
        let v = data[offset]
        offset += 1
        return v
    }

    mutating func readInt8() throws -> Int8 { Int8(bitPattern: try readUInt8()) }

    mutating func readUInt16() throws -> UInt16 {
        guard hasRemaining(2) else { throw ZinoError(.incompatibleModel, "Truncated GGUF header.") }
        let v = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        return v
    }

    mutating func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }

    mutating func readUInt32() throws -> UInt32 {
        guard hasRemaining(4) else { throw ZinoError(.incompatibleModel, "Truncated GGUF header.") }
        let v = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return v
    }

    mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    mutating func readUInt64() throws -> UInt64 {
        let lo = UInt64(try readUInt32())
        let hi = UInt64(try readUInt32())
        return lo | (hi << 32)
    }

    mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }

    mutating func readGGUFString() throws -> String {
        let len = Int(try readUInt64())
        guard len >= 0, len <= 2_000_000, hasRemaining(len) else {
            throw ZinoError(.incompatibleModel, "Invalid GGUF string length (\(len)).")
        }
        let slice = data[offset..<(offset + len)]
        offset += len
        return String(decoding: slice, as: UTF8.self)
    }
}
