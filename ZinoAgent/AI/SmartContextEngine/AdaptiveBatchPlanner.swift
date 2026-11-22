import Foundation

public struct MessageBatch: Sendable, Equatable {
    public let messages: [ChatMessage]
    public let totalTokens: Int
}

/// Dynamically computes message batches for summarization/compaction based on message lengths,
/// available context budget, model context window, complexity, and retrieved history.
/// Guarantees tool calls and their corresponding tool results are never split across batch boundaries.
public enum AdaptiveBatchPlanner {
    public static func recommendedBatchSize(
        messages: [ChatMessage],
        tokenCounts: [String: Int],
        config: SmartContextConfiguration,
        modelContextWindow: Int,
        retrievedTokens: Int
    ) -> Int {
        guard config.adaptiveBatchingEnabled else {
            return config.initialMessageBatchTarget
        }
        guard !messages.isEmpty else { return config.initialMessageBatchTarget }

        let avgTokens = Double(messages.reduce(0) { $0 + (tokenCounts[$1.id] ?? 64) }) / Double(messages.count)
        let codeHeavyCount = messages.filter { $0.content.contains("```") || $0.attachments.count > 0 }.count
        let complexityRatio = Double(codeHeavyCount) / Double(messages.count)

        let effectiveBudget = max(1024, min(config.baselineContextTarget, modelContextWindow) - retrievedTokens)
        var size = Double(config.initialMessageBatchTarget)

        // Scale up slightly for very short conversational turns, scale down for dense/long messages.
        if avgTokens > 450 {
            size *= 0.65
        } else if avgTokens > 220 {
            size *= 0.85
        } else if avgTokens < 70 {
            size *= 1.4
        }

        // Code/attachment-heavy batches are kept tighter so technical decisions aren't over-compressed.
        if complexityRatio > 0.35 {
            size *= 0.8
        }

        // Larger model context windows can safely hold larger summarization batches.
        if effectiveBudget >= 16_000 {
            size *= 1.35
        } else if effectiveBudget <= 2_500 {
            size *= 0.75
        }

        return max(2, min(14, Int(round(size))))
    }

    /// Partitions older candidate messages into coherent batches without splitting tool-call / tool-result groups.
    public static func planBatches(
        candidates: [ChatMessage],
        tokenCounts: [String: Int],
        targetBatchSize: Int,
        maxBatchTokens: Int
    ) -> [MessageBatch] {
        guard !candidates.isEmpty else { return [] }

        // First group atomic units (e.g., assistant tool call + immediately following tool result(s)).
        var units: [[ChatMessage]] = []
        var idx = 0
        while idx < candidates.count {
            var unit = [candidates[idx]]
            if candidates[idx].role == .assistant {
                var next = idx + 1
                while next < candidates.count && candidates[next].role == .tool {
                    unit.append(candidates[next])
                    next += 1
                }
                idx = next
            } else {
                idx += 1
            }
            units.append(unit)
        }

        var batches: [MessageBatch] = []
        var current: [ChatMessage] = []
        var currentTokens = 0

        for unit in units {
            let unitTokens = unit.reduce(0) { $0 + (tokenCounts[$1.id] ?? 64) }
            let wouldExceedCount = !current.isEmpty && (current.count + unit.count) > targetBatchSize
            let wouldExceedTokens = !current.isEmpty && (currentTokens + unitTokens) > maxBatchTokens

            if wouldExceedCount || wouldExceedTokens {
                batches.append(MessageBatch(messages: current, totalTokens: currentTokens))
                current = []
                currentTokens = 0
            }
            current.append(contentsOf: unit)
            currentTokens += unitTokens
        }

        if !current.isEmpty {
            batches.append(MessageBatch(messages: current, totalTokens: currentTokens))
        }
        return batches
    }
}
