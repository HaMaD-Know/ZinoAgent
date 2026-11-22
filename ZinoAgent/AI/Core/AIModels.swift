import Foundation

public enum AIMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case offline
    case online

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .offline: return "Offline (Local)"
        case .online: return "Online (Cloud)"
        }
    }

    public var shortName: String {
        switch self {
        case .offline: return "Offline"
        case .online: return "Online"
        }
    }

    public var iconName: String {
        switch self {
        case .offline: return "cpu"
        case .online: return "cloud"
        }
    }
}

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatAttachment: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case file
        case image
        case threeDModel
    }

    public let id: String
    public let kind: Kind
    public let filename: String
    public let filePath: String
    public let mimeType: String
    public let fileSizeBytes: Int64
    public let extractedPreview: String?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        filename: String,
        filePath: String,
        mimeType: String,
        fileSizeBytes: Int64,
        extractedPreview: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.filePath = filePath
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
        self.extractedPreview = extractedPreview
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public var role: ChatRole
    public var content: String
    public var thinkingContent: String?
    public var providerLabel: String?
    public var modelLabel: String?
    public var tokenCount: Int?
    public var isPinned: Bool
    public var isArchivedToSummary: Bool
    public var toolCallID: String?
    public var toolName: String?
    public var attachments: [ChatAttachment]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        role: ChatRole,
        content: String,
        thinkingContent: String? = nil,
        providerLabel: String? = nil,
        modelLabel: String? = nil,
        tokenCount: Int? = nil,
        isPinned: Bool = false,
        isArchivedToSummary: Bool = false,
        toolCallID: String? = nil,
        toolName: String? = nil,
        attachments: [ChatAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.thinkingContent = thinkingContent
        self.providerLabel = providerLabel
        self.modelLabel = modelLabel
        self.tokenCount = tokenCount
        self.isPinned = isPinned
        self.isArchivedToSummary = isArchivedToSummary
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

public struct ChatConversation: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var mode: AIMode
    public var providerID: String?
    public var modelID: String?
    public var systemPrompt: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String = "New Conversation",
        mode: AIMode = .offline,
        providerID: String? = nil,
        modelID: String? = nil,
        systemPrompt: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.providerID = providerID
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let tokensPerSecond: Double?

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int? = nil, tokensPerSecond: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens ?? (promptTokens + completionTokens)
        self.tokensPerSecond = tokensPerSecond
    }
}

public struct ToolCallRequest: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public enum StreamChunk: Sendable {
    case text(String)
    case thinking(String)
    case toolCall(ToolCallRequest)
    case usage(TokenUsage)
    case done(stopReason: String)
}

public struct GenerationConfig: Codable, Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var maxTokens: Int
    public var systemPrompt: String

    public init(
        temperature: Double = 0.7,
        topP: Double = 0.95,
        topK: Int = 40,
        repeatPenalty: Double = 1.1,
        maxTokens: Int = 2048,
        systemPrompt: String = "You are ZinoAgent, a helpful, privacy-focused AI assistant running in a local-first iPad workspace. Be concise, accurate, and transparent about file permissions."
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }
}

public struct AIModelDescriptor: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let contextWindow: Int
    public let supportsVision: Bool
    public let supportsTools: Bool
    public let supportsImageGeneration: Bool

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int = 128_000,
        supportsVision: Bool = false,
        supportsTools: Bool = true,
        supportsImageGeneration: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsImageGeneration = supportsImageGeneration
    }
}

public enum AIPermissionLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case readOnly = "read_only"
    case suggest = "suggest"
    case confirm = "confirm"
    case authorized = "authorized"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readOnly: return "Read-only"
        case .suggest: return "Suggest"
        case .confirm: return "Confirm"
        case .authorized: return "Authorized (Non-destructive)"
        }
    }

    public var description: String {
        switch self {
        case .readOnly:
            return "AI can inspect and read permitted files, but cannot propose or execute write operations."
        case .suggest:
            return "AI can read files and propose operations as suggestions for you to review."
        case .confirm:
            return "AI prepares file operations and asks for your explicit approval before executing."
        case .authorized:
            return "AI may execute non-destructive operations (such as creating folders or copying) inside permitted folders, while destructive actions still require confirmation."
        }
    }
}
