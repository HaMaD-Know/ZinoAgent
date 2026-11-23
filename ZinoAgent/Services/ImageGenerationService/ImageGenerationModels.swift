import Foundation

public enum ImageGenerationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case online
    case offlineCoreML

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .online: return "Online Provider"
        case .offlineCoreML: return "Offline (Core ML)"
        }
    }
}

public enum ImageAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case square = "1:1"
    case landscape4x3 = "4:3"
    case widescreen16x9 = "16:9"
    case portrait3x4 = "3:4"
    case tall9x16 = "9:16"

    public var id: String { rawValue }

    public func dimensions(baseSize: Int = 1024) -> (width: Int, height: Int) {
        switch self {
        case .square: return (baseSize, baseSize)
        case .landscape4x3: return (baseSize, Int(Double(baseSize) * 0.75))
        case .widescreen16x9: return (1792, 1024)
        case .portrait3x4: return (Int(Double(baseSize) * 0.75), baseSize)
        case .tall9x16: return (1024, 1792)
        }
    }
}

public struct ImageSizeOption: Sendable, Equatable {
    public let label: String
    public let width: Int
    public let height: Int

    public init(label: String, width: Int, height: Int) {
        self.label = label
        self.width = width
        self.height = height
    }
}

public struct ImageProviderCapabilities: Sendable, Equatable {
    public let supportsNegativePrompt: Bool
    public let supportsQualitySelector: Bool
    public let supportsStepsAndGuidance: Bool
    public let supportsSeed: Bool
    public let supportedSizes: [ImageSizeOption]
    public let qualityOptions: [String]

    public static func forProvider(type: ProviderType, modelID: String) -> ImageProviderCapabilities {
        let lower = modelID.lowercased()
        switch type {
        case .openAI, .openAICompatible, .openRouter:
            if lower.contains("dall-e-3") {
                return ImageProviderCapabilities(
                    supportsNegativePrompt: false,
                    supportsQualitySelector: true,
                    supportsStepsAndGuidance: false,
                    supportsSeed: false,
                    supportedSizes: [
                        ImageSizeOption(label: "1024 × 1024", width: 1024, height: 1024),
                        ImageSizeOption(label: "1792 × 1024", width: 1792, height: 1024),
                        ImageSizeOption(label: "1024 × 1792", width: 1024, height: 1792)
                    ],
                    qualityOptions: ["standard", "hd"]
                )
            }
            return ImageProviderCapabilities(
                supportsNegativePrompt: false,
                supportsQualitySelector: true,
                supportsStepsAndGuidance: false,
                supportsSeed: false,
                supportedSizes: [
                    ImageSizeOption(label: "1024 × 1024", width: 1024, height: 1024),
                    ImageSizeOption(label: "1536 × 1024", width: 1536, height: 1024),
                    ImageSizeOption(label: "1024 × 1536", width: 1024, height: 1536)
                ],
                qualityOptions: ["low", "medium", "high"]
            )
        case .gemini:
            return ImageProviderCapabilities(
                supportsNegativePrompt: false,
                supportsQualitySelector: false,
                supportsStepsAndGuidance: false,
                supportsSeed: false,
                supportedSizes: [
                    ImageSizeOption(label: "1024 × 1024 (1:1)", width: 1024, height: 1024),
                    ImageSizeOption(label: "1408 × 768 (16:9)", width: 1408, height: 768),
                    ImageSizeOption(label: "768 × 1408 (9:16)", width: 768, height: 1408),
                    ImageSizeOption(label: "1152 × 896 (4:3)", width: 1152, height: 896)
                ],
                qualityOptions: []
            )
        case .anthropic:
            return ImageProviderCapabilities(
                supportsNegativePrompt: false,
                supportsQualitySelector: false,
                supportsStepsAndGuidance: false,
                supportsSeed: false,
                supportedSizes: [],
                qualityOptions: []
            )
        }
    }

    public static func forOfflineCoreML(nativeSize: Int) -> ImageProviderCapabilities {
        ImageProviderCapabilities(
            supportsNegativePrompt: true,
            supportsQualitySelector: false,
            supportsStepsAndGuidance: true,
            supportsSeed: true,
            supportedSizes: [
                ImageSizeOption(label: "\(nativeSize) × \(nativeSize) (Model Native)", width: nativeSize, height: nativeSize)
            ],
            qualityOptions: []
        )
    }
}

public struct CoreMLDiffusionModelInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let folderURL: URL
    public let isValid: Bool
    public let missingComponents: [String]
    public let isSDXL: Bool
    public let supportsImageToImage: Bool
    public let nativeSize: Int
    public let diskSizeBytes: Int64
    public let estimatedRAMBytes: Int64
}

public struct ImageGenerationRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let negativePrompt: String?
    public let mode: ImageGenerationMode
    public let providerName: String
    public let modelName: String
    public let width: Int
    public let height: Int
    public let quality: String?
    public let seed: Int?
    public let relativeImagePath: String
    public let durationMs: Int
    public let createdAt: Date
}
