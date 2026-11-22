import Foundation

public enum TokenizerModelFamily: String, Sendable {
    case llama
    case qwen
    case gemma
    case openAI
    case anthropic
    case gemini
    case generic

    public static func detect(modelID: String?, architecture: String?) -> TokenizerModelFamily {
        let hint = ((architecture ?? "") + " " + (modelID ?? "")).lowercased()
        if hint.contains("qwen") { return .qwen }
        if hint.contains("gemma") { return .gemma }
        if hint.contains("llama") || hint.contains("mistral") || hint.contains("phi") { return .llama }
        if hint.contains("gpt") || hint.contains("o1") || hint.contains("o3") || hint.contains("o4") { return .openAI }
        if hint.contains("claude") { return .anthropic }
        if hint.contains("gemini") { return .gemini }
        return .generic
    }

    /// Average UTF-8 characters per token calibrated per tokenizer family (BPE vs SentencePiece).
    public var proseCharsPerToken: Double {
        switch self {
        case .openAI: return 4.0
        case .anthropic: return 3.8
        case .gemini: return 3.9
        case .qwen: return 3.7
        case .gemma: return 3.8
        case .llama: return 3.9
        case .generic: return 3.8
        }
    }

    public var codeCharsPerToken: Double {
        switch self {
        case .openAI: return 3.1
        case .anthropic: return 2.9
        case .qwen: return 3.0
        default: return 2.8
        }
    }
}

public protocol ContextTokenCounting: Sendable {
    var source: TokenizerSource { get }
    func countTokens(_ text: String) async -> Int
    func countMessageTokens(_ message: ChatMessage) async -> Int
}

/// Model-aware tokenizer: delegates to exact `llama_tokenize` when a local model is loaded,
/// otherwise applies family-calibrated BPE/SentencePiece tokenization heuristics with per-message framing overhead.
public final class SmartContextTokenizer: ContextTokenCounting, @unchecked Sendable {
    public let source: TokenizerSource
    private let family: TokenizerModelFamily
    private let exactCounter: (@Sendable (String) async -> Int?)?

    public init(
        family: TokenizerModelFamily = .generic,
        exactCounter: (@Sendable (String) async -> Int?)? = nil
    ) {
        self.family = family
        self.exactCounter = exactCounter
        self.source = exactCounter != nil ? .modelNative : .familyCalibrated
    }

    public func countTokens(_ text: String) async -> Int {
        guard !text.isEmpty else { return 0 }
        if let exactCounter, let exact = await exactCounter(text) {
            return exact
        }
        return Self.estimateTokens(text, family: family)
    }

    public func countMessageTokens(_ message: ChatMessage) async -> Int {
        var combined = message.content
        for att in message.attachments {
            if let preview = att.extractedPreview, !preview.isEmpty {
                combined += "\n[Attachment \(att.filename)]\n\(preview)"
            }
        }
        let bodyTokens = await countTokens(combined)
        // Role framing + template control tokens overhead (~6 tokens per message).
        return bodyTokens + 6
    }

    public static func estimateTokens(_ text: String, family: TokenizerModelFamily) -> Int {
        guard !text.isEmpty else { return 0 }
        let scalars = text.unicodeScalars
        var cjkCount = 0
        var symbolCount = 0
        var total = 0

        for scalar in scalars {
            total += 1
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                cjkCount += 1
            } else if !CharacterSet.alphanumerics.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                symbolCount += 1
            }
        }

        let symbolRatio = Double(symbolCount) / Double(max(1, total))
        let isCodeHeavy = symbolRatio > 0.14 || text.contains("```")
        let rate = isCodeHeavy ? family.codeCharsPerToken : family.proseCharsPerToken

        let nonCJK = max(0, total - cjkCount)
        let nonCJKTokens = Double(nonCJK) / rate
        // CJK ideographs typically tokenize near ~0.7-1.1 chars/token.
        let cjkTokens = Double(cjkCount) * 1.15
        return max(1, Int(ceil(nonCJKTokens + cjkTokens)))
    }
}
