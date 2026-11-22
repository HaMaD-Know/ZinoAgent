import Foundation

public enum ModelCompatibilityStatus: String, Codable, Sendable {
    case compatible
    case warningHighMemory
    case incompatibleArchitecture
    case splitShardIncomplete
    case corruptOrInvalid

    public var displayName: String {
        switch self {
        case .compatible: return "Compatible"
        case .warningHighMemory: return "High Memory Warning"
        case .incompatibleArchitecture: return "Unsupported Architecture"
        case .splitShardIncomplete: return "Incomplete Split GGUF"
        case .corruptOrInvalid: return "Invalid / Corrupt GGUF"
        }
    }

    public var canAttemptLoad: Bool {
        self == .compatible || self == .warningHighMemory
    }
}

public struct LocalModelRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public let filename: String
    public let relativePath: String
    public let fileSizeBytes: Int64
    public let architecture: String
    public let quantization: String
    public let parameterCountLabel: String
    public let contextLength: Int
    public let trainedContextLength: Int
    public let layerCount: Int
    public let embeddingDim: Int
    public let hasChatTemplate: Bool
    public let isSplit: Bool
    public var compatibilityStatus: ModelCompatibilityStatus
    public var compatibilityNotes: String
    public let estimatedRAMBytes: Int64
    public let sourceURL: String?
    public let sha256Prefix: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        filename: String,
        relativePath: String,
        fileSizeBytes: Int64,
        architecture: String,
        quantization: String,
        parameterCountLabel: String,
        contextLength: Int,
        trainedContextLength: Int,
        layerCount: Int,
        embeddingDim: Int,
        hasChatTemplate: Bool,
        isSplit: Bool,
        compatibilityStatus: ModelCompatibilityStatus,
        compatibilityNotes: String,
        estimatedRAMBytes: Int64,
        sourceURL: String? = nil,
        sha256Prefix: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
        self.architecture = architecture
        self.quantization = quantization
        self.parameterCountLabel = parameterCountLabel
        self.contextLength = contextLength
        self.trainedContextLength = trainedContextLength
        self.layerCount = layerCount
        self.embeddingDim = embeddingDim
        self.hasChatTemplate = hasChatTemplate
        self.isSplit = isSplit
        self.compatibilityStatus = compatibilityStatus
        self.compatibilityNotes = compatibilityNotes
        self.estimatedRAMBytes = estimatedRAMBytes
        self.sourceURL = sourceURL
        self.sha256Prefix = sha256Prefix
        self.createdAt = createdAt
    }
}

public struct CatalogModelEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let family: String
    public let quantization: String
    public let parameterCountLabel: String
    public let approximateSizeBytes: Int64
    public let estimatedRAMBytes: Int64
    public let contextWindow: Int
    public let downloadURL: URL
    public let filename: String
    public let summary: String
    public let recommendedFor8GBiPad: Bool
    public let speedRating: String
    public let intelligenceRating: String
}
