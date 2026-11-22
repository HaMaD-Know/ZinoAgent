import Foundation

public struct SummaryVerificationResult: Sendable, Equatable {
    public let passed: Bool
    public let retentionScore: Double
    public let missingCriticalItems: [String]
    public let notes: String
}

/// Generates structured summaries preserving decisions, preferences, file references, project state, and instructions,
/// and verifies every summary against original messages so critical facts are never silently lost.
public enum SummaryGeneratorAndVerifier {
    public typealias ModelSummarizer = @Sendable (_ prompt: String) async throws -> String

    /// Generates and (if enabled) verifies a summary for a batch of messages.
    public static func summarizeAndVerify(
        batch: [ChatMessage],
        verify: Bool,
        modelSummarizer: ModelSummarizer? = nil
    ) async -> (summary: String, verification: SummaryVerificationResult) {
        let extractive = buildStructuredExtractiveSummary(messages: batch)

        var candidate = extractive
        if let modelSummarizer {
            let prompt = buildSummarizationPrompt(messages: batch)
            if let aiSummary = try? await modelSummarizer(prompt), !aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate = aiSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard verify else {
            return (candidate, SummaryVerificationResult(passed: true, retentionScore: 1.0, missingCriticalItems: [], notes: "Verification disabled by user."))
        }

        let initialCheck = verifySummary(candidate, against: batch)
        if initialCheck.passed {
            return (candidate, initialCheck)
        }

        // Corrective preservation pass: append missing critical references/decisions so nothing is silently discarded.
        var repaired = candidate
        let missingBlock = initialCheck.missingCriticalItems.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        if !missingBlock.isEmpty {
            repaired += "\n\n[Verified Preserved Details]\n\(missingBlock)"
        }
        let recheck = verifySummary(repaired, against: batch)
        let notes = recheck.passed
            ? "Verified after preserving \(initialCheck.missingCriticalItems.count) critical detail(s)."
            : "Retained verbatim key facts; retention \(Int(recheck.retentionScore * 100))%."
        return (repaired, SummaryVerificationResult(
            passed: recheck.passed,
            retentionScore: recheck.retentionScore,
            missingCriticalItems: recheck.missingCriticalItems,
            notes: notes
        ))
    }

    public static func verifySummary(_ summary: String, against originals: [ChatMessage]) -> SummaryVerificationResult {
        let lowerSummary = summary.lowercased()
        let criticalItems = extractCriticalFacts(from: originals)

        guard !criticalItems.isEmpty else {
            let nonEmpty = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return SummaryVerificationResult(
                passed: nonEmpty,
                retentionScore: nonEmpty ? 1.0 : 0.0,
                missingCriticalItems: [],
                notes: nonEmpty ? "Verified (no specialized artifacts to cross-check)." : "Summary was empty."
            )
        }

        var missing: [String] = []
        for item in criticalItems {
            if !lowerSummary.contains(item.lowercased()) {
                missing.append(item)
            }
        }

        let retained = criticalItems.count - missing.count
        let score = Double(retained) / Double(criticalItems.count)
        let passed = score >= 0.80 && missing.count <= 2
        let notes = passed
            ? "Verified \(retained)/\(criticalItems.count) critical facts retained (\(Int(score * 100))%)."
            : "Missing \(missing.count) critical fact(s) from original messages."

        return SummaryVerificationResult(
            passed: passed,
            retentionScore: score,
            missingCriticalItems: missing,
            notes: notes
        )
    }

    /// Extracts filenames, paths, explicit preferences/instructions, technical decisions, and key numeric constraints.
    public static func extractCriticalFacts(from messages: [ChatMessage]) -> [String] {
        var facts: [String] = []
        var seen = Set<String>()

        func addFact(_ raw: String) {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 3 else { return }
            let key = clean.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                facts.append(clean)
            }
        }

        let fileRegex = try? NSRegularExpression(pattern: "\\b[A-Za-z0-9_\\-]+\\.(swift|py|js|ts|json|md|txt|pdf|docx|csv|xml|glb|gltf|usdz|obj|stl|gguf|zip|png|jpg|yml|yaml)\\b", options: .caseInsensitive)

        for msg in messages {
            for att in msg.attachments {
                addFact(att.filename)
            }

            if let fileRegex {
                let range = NSRange(msg.content.startIndex..<msg.content.endIndex, in: msg.content)
                for match in fileRegex.matches(in: msg.content, range: range) {
                    if let r = Range(match.range, in: msg.content) {
                        addFact(String(msg.content[r]))
                    }
                }
            }

            // Capture explicit constraints, decisions, and user preferences.
            let lines = msg.content.components(separatedBy: .newlines)
            for line in lines {
                let lower = line.lowercased()
                if lower.contains("always ") || lower.contains("never ") || lower.contains("must ")
                    || lower.contains("prefer ") || lower.contains("decision:") || lower.contains("decided ")
                    || lower.contains("requirement:") {
                    addFact(String(line.prefix(140)))
                }
            }
        }

        return Array(facts.prefix(20))
    }

    public static func buildStructuredExtractiveSummary(messages: [ChatMessage]) -> String {
        var userGoals: [String] = []
        var decisions: [String] = []
        var files: [String] = []
        var answers: [String] = []

        let critical = extractCriticalFacts(from: messages)
        for c in critical {
            if c.contains(".") && !c.contains(" ") {
                files.append(c)
            } else {
                decisions.append(c)
            }
        }

        for msg in messages {
            let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let firstSentence = trimmed.components(separatedBy: CharacterSet(charactersIn: "\n")).first.map { String($0.prefix(180)) } ?? ""
            if msg.role == .user && !firstSentence.isEmpty {
                userGoals.append(firstSentence)
            } else if msg.role == .assistant && !firstSentence.isEmpty {
                answers.append(firstSentence)
            }
            for att in msg.attachments where !files.contains(att.filename) {
                files.append(att.filename)
            }
        }

        var sections: [String] = ["[Conversation Context Summary — \(messages.count) messages]"]
        if !userGoals.isEmpty {
            sections.append("Topics & Requests:\n" + userGoals.prefix(5).map { "- \($0)" }.joined(separator: "\n"))
        }
        if !decisions.isEmpty {
            sections.append("Decisions & Preferences:\n" + decisions.prefix(6).map { "- \($0)" }.joined(separator: "\n"))
        }
        if !files.isEmpty {
            sections.append("Referenced Files: " + files.prefix(12).joined(separator: ", "))
        }
        if !answers.isEmpty {
            sections.append("Key Assistant Conclusions:\n" + answers.prefix(4).map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func buildSummarizationPrompt(messages: [ChatMessage]) -> String {
        let transcript = messages.map { msg in
            let files = msg.attachments.isEmpty ? "" : " [Files: \(msg.attachments.map(\.filename).joined(separator: ", "))]"
            return "\(msg.role.rawValue.uppercased())\(files): \(msg.content.prefix(1500))"
        }.joined(separator: "\n\n")

        return """
        Summarize the following conversation segment accurately and concisely.
        You MUST preserve:
        - Explicit user instructions and preferences
        - Technical decisions and project state
        - Exact file names, paths, and identifiers
        - Key answers and conclusions

        Transcript:
        \(transcript)
        """
    }
}
