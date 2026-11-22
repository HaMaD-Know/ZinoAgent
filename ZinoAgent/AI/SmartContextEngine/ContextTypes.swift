import Foundation

public struct SmartContextConfiguration: Codable, Sendable, Equatable {
    public var adaptiveBatchingEnabled: Bool
    public var smartHistoryRetrievalEnabled: Bool
    public var preserveOriginalMessages: Bool
    public var summaryVerificationEnabled: Bool
    public var baselineContextTarget: Int
    public var initialMessageBatchTarget: Int
    public var maxRetrievedMessages: Int
    public var summaryTriggerRatio: Double

    public init(
        adaptiveBatchingEnabled: Bool = true,
        smartHistoryRetrievalEnabled: Bool = true,
        preserveOriginalMessages: Bool = true,
        summaryVerificationEnabled: Bool = true,
        baselineContextTarget: Int = 4096,
        initialMessageBatchTarget: Int = 5,
        maxRetrievedMessages: Int = 8,
        summaryTriggerRatio: Double = 0.78
    ) {
        self.adaptiveBatchingEnabled = adaptiveBatchingEnabled
        self.smartHistoryRetrievalEnabled = smartHistoryRetrievalEnabled
        self.preserveOriginalMessages = preserveOriginalMessages
        self.summaryVerificationEnabled = summaryVerificationEnabled
        self.baselineContextTarget = max(1024, baselineContextTarget)
        self.initialMessageBatchTarget = max(2, initialMessageBatchTarget)
        self.maxRetrievedMessages = max(0, maxRetrievedMessages)
        self.summaryTriggerRatio = min(0.95, max(0.4, summaryTriggerRatio))
    }
}

public enum TokenizerSource: String, Sendable, Equatable {
    case modelNative = "Model Tokenizer (Exact)"
    case familyCalibrated = "Family-Calibrated Estimator"
}

public struct ContextSummaryRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let conversationID: String
    public let summaryText: String
    public let coveredMessageIDs: [String]
    public let coveredMessageCount: Int
    public let tokenCount: Int
    public let verificationPassed: Bool
    public let verificationNotes: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        summaryText: String,
        coveredMessageIDs: [String],
        tokenCount: Int,
        verificationPassed: Bool,
        verificationNotes: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.summaryText = summaryText
        self.coveredMessageIDs = coveredMessageIDs
        self.coveredMessageCount = coveredMessageIDs.count
        self.tokenCount = tokenCount
        self.verificationPassed = verificationPassed
        self.verificationNotes = verificationNotes
        self.createdAt = createdAt
    }
}

public struct ContextSnapshot: Sendable, Equatable {
    public let currentTokenCount: Int
    public let targetContextBudget: Int
    public let modelContextWindow: Int
    public let totalMessageCount: Int
    public let includedMessageCount: Int
    public let retrievedHistoryCount: Int
    public let pinnedMessageCount: Int
    public let summaryTokenCount: Int
    public let summaryCount: Int
    public let tokenizerSource: TokenizerSource
    public let adaptiveBatchSize: Int

    public var availableContextTokens: Int {
        max(0, effectiveCapacity - currentTokenCount)
    }

    public var effectiveCapacity: Int {
        min(targetContextBudget, modelContextWindow)
    }

    public var utilizationRatio: Double {
        guard effectiveCapacity > 0 else { return 0 }
        return min(1.0, Double(currentTokenCount) / Double(effectiveCapacity))
    }
}

public struct AssembledContext: Sendable {
    public let promptMessages: [ProviderChatMessage]
    public let snapshot: ContextSnapshot
    public let retrievedMessageIDs: [String]
    public let appliedSummaries: [ContextSummaryRecord]
}
