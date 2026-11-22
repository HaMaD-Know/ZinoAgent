import Foundation
import NaturalLanguage

public struct RetrievedMessageScore: Sendable {
    public let message: ChatMessage
    public let score: Double
    public let reason: String
}

/// Retrieves relevant older conversation messages using on-device NaturalLanguage embeddings (when available),
/// TF-IDF / lexical keyword matching (file names, code identifiers, topics), recency decay, and user pins.
public enum SmartHistoryRetriever {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "have", "what", "when", "where",
        "your", "about", "into", "could", "would", "should", "there", "their", "they", "them",
        "please", "make", "just", "like", "some", "more", "very", "also", "been", "will", "can"
    ]

    public static func retrieveRelevant(
        query: String,
        historicalMessages: [ChatMessage],
        maxMessages: Int,
        maxTokens: Int,
        tokenCounts: [String: Int]
    ) -> [RetrievedMessageScore] {
        guard !historicalMessages.isEmpty, maxMessages > 0, maxTokens > 0 else { return [] }

        let pinned = historicalMessages.filter(\.isPinned)
        let unpinned = historicalMessages.filter { !$0.isPinned }

        let queryTerms = extractTerms(query)
        let docFreq = buildDocumentFrequencies(messages: unpinned)
        let docCount = Double(max(1, unpinned.count))
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)

        let newestTime = historicalMessages.map(\.createdAt.timeIntervalSince1970).max() ?? Date().timeIntervalSince1970
        let oldestTime = historicalMessages.map(\.createdAt.timeIntervalSince1970).min() ?? newestTime
        let timeSpan = max(1.0, newestTime - oldestTime)

        var scored: [RetrievedMessageScore] = []

        for msg in unpinned {
            let text = msg.content + " " + msg.attachments.map(\.filename).joined(separator: " ")
            let msgTerms = extractTerms(text)

            // 1. TF-IDF lexical relevance (great for file paths, code identifiers, exact decisions).
            var lexicalScore = 0.0
            if !queryTerms.isEmpty && !msgTerms.isEmpty {
                let termSet = Set(msgTerms)
                for q in queryTerms where termSet.contains(q) {
                    let df = Double(docFreq[q] ?? 1)
                    let idf = log((docCount + 1.0) / (df + 0.5)) + 1.0
                    // Boost filename or symbol matches containing dots/underscores/slashes.
                    let boost = (q.contains(".") || q.contains("_") || q.contains("/")) ? 1.6 : 1.0
                    lexicalScore += idf * boost
                }
                lexicalScore /= Double(queryTerms.count)
            }

            // 2. On-device semantic sentence similarity via Apple NaturalLanguage when available.
            var semanticScore = 0.0
            if let embedding, !query.isEmpty, !msg.content.isEmpty {
                let snippet = String(msg.content.prefix(400))
                let dist = embedding.distance(between: String(query.prefix(400)), and: snippet, distanceType: .cosine)
                if dist.isFinite && dist >= 0 && dist <= 2.0 {
                    semanticScore = max(0.0, 1.0 - (dist / 2.0))
                }
            }

            // 3. Mild recency bias (0.0 .. 0.25).
            let recency = ((msg.createdAt.timeIntervalSince1970 - oldestTime) / timeSpan) * 0.25

            // 4. Boost messages with attachments or explicit decisions/preferences.
            let attachmentBonus = msg.attachments.isEmpty ? 0.0 : 0.15

            let combined = (lexicalScore * 0.55) + (semanticScore * 0.35) + recency + attachmentBonus
            if combined > 0.18 {
                let reason = lexicalScore >= semanticScore ? "keyword & file match" : "semantic relevance"
                scored.append(RetrievedMessageScore(message: msg, score: combined, reason: reason))
            }
        }

        scored.sort { $0.score > $1.score }

        // Assemble final set: pinned messages ALWAYS come first, then top relevant matches within token budget.
        var selected: [RetrievedMessageScore] = []
        var usedTokens = 0

        for p in pinned {
            let t = tokenCounts[p.id] ?? 64
            if usedTokens + t <= maxTokens {
                selected.append(RetrievedMessageScore(message: p, score: 10.0, reason: "user-pinned"))
                usedTokens += t
            }
        }

        for candidate in scored {
            if selected.count >= maxMessages + pinned.count { break }
            let t = tokenCounts[candidate.message.id] ?? 64
            if usedTokens + t <= maxTokens {
                selected.append(candidate)
                usedTokens += t
            }
        }

        // Preserve chronological order for coherent LLM reading.
        return selected.sorted { $0.message.createdAt < $1.message.createdAt }
    }

    public static func extractTerms(_ text: String) -> [String] {
        let lower = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/"))
        let pieces = lower.components(separatedBy: allowed.inverted)
        return pieces.filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func buildDocumentFrequencies(messages: [ChatMessage]) -> [String: Int] {
        var freq: [String: Int] = [:]
        for msg in messages {
            let uniqueTerms = Set(extractTerms(msg.content))
            for term in uniqueTerms {
                freq[term, default: 0] += 1
            }
        }
        return freq
    }
}
