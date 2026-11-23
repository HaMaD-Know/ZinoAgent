import Foundation

public enum ProviderType: String, CaseIterable, Identifiable, Codable, Sendable {
    case openRouter = "openrouter"
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case openAICompatible = "openai_compatible"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter (Free & Paid Models)"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .openAICompatible: return "OpenAI-Compatible (Ollama / LM Studio / Custom)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible: return "http://localhost:11434/v1"
        }
    }

    public var requiresAPIKey: Bool {
        self != .openAICompatible
    }
}

public struct ProviderConfiguration: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var providerType: ProviderType
    public var baseURL: String
    public var keychainAccount: String
    public var defaultModelID: String?
    public var cachedModels: [AIModelDescriptor]
    public var isDefault: Bool
    public var supportsVision: Bool
    public var supportsImageGeneration: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        providerType: ProviderType,
        baseURL: String? = nil,
        keychainAccount: String? = nil,
        defaultModelID: String? = nil,
        cachedModels: [AIModelDescriptor] = [],
        isDefault: Bool = false,
        supportsVision: Bool = true,
        supportsImageGeneration: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.baseURL = (baseURL ?? providerType.defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.keychainAccount = keychainAccount ?? "provider.\(id)"
        self.defaultModelID = defaultModelID
        self.cachedModels = cachedModels
        self.isDefault = isDefault
        self.supportsVision = supportsVision
        self.supportsImageGeneration = supportsImageGeneration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ChatImagePayload: Sendable {
    public let mimeType: String
    public let base64Data: String

    public init(mimeType: String, base64Data: String) {
        self.mimeType = mimeType
        self.base64Data = base64Data
    }
}

public struct ProviderChatMessage: Sendable {
    public let role: ChatRole
    public let content: String
    public let images: [ChatImagePayload]
    public let toolCallID: String?
    public let toolName: String?

    public init(
        role: ChatRole,
        content: String,
        images: [ChatImagePayload] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func toFoundationObject() -> Any {
        switch self {
        case let .string(v): return v
        case let .int(v): return v
        case let .double(v): return v
        case let .bool(v): return v
        case let .array(arr): return arr.map { $0.toFoundationObject() }
        case let .object(dict): return dict.mapValues { $0.toFoundationObject() }
        case .null: return NSNull()
        }
    }
}

public struct ProviderToolSchema: Sendable {
    public let name: String
    public let description: String
    public let parametersSchema: [String: JSONValue]

    public init(name: String, description: String, parametersSchema: [String: JSONValue]) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
    }

    public var parametersFoundationDictionary: [String: Any] {
        parametersSchema.mapValues { $0.toFoundationObject() }
    }
}

public struct OnlineChatRequest: Sendable {
    public let modelID: String
    public let messages: [ProviderChatMessage]
    public let config: GenerationConfig
    public let tools: [ProviderToolSchema]

    public init(
        modelID: String,
        messages: [ProviderChatMessage],
        config: GenerationConfig,
        tools: [ProviderToolSchema] = []
    ) {
        self.modelID = modelID
        self.messages = messages
        self.config = config
        self.tools = tools
    }
}

public struct OnlineImageRequest: Sendable {
    public let modelID: String
    public let prompt: String
    public let negativePrompt: String?
    public let width: Int
    public let height: Int
    public let quality: String?

    public init(
        modelID: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int = 1024,
        height: Int = 1024,
        quality: String? = nil
    ) {
        self.modelID = modelID
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.quality = quality
    }
}

public struct GeneratedImagePayload: Sendable {
    public let imageData: Data
    public let mimeType: String
    public let revisedPrompt: String?
}

public protocol OnlineAIProviderAdapter: Sendable {
    var providerType: ProviderType { get }
    var supportsModelDiscovery: Bool { get }
    var supportsStreaming: Bool { get }
    var supportsVision: Bool { get }
    var supportsImageGeneration: Bool { get }

    func testConnection(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor]
    func fetchModels(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor]
    func streamChat(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) -> AsyncThrowingStream<StreamChunk, Error>
    func generateImage(request: OnlineImageRequest, config: ProviderConfiguration, apiKey: String?) async throws -> [GeneratedImagePayload]
}
