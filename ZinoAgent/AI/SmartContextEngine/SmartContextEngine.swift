import Foundation
import Combine

/// Dedicated context optimization subsystem (`SmartContextEngine`).
/// Tracks real token usage, runs adaptive batching, retrieves relevant past turns, generates & verifies
/// structured summaries, and strictly preserves original conversation history in SQLite.
@MainActor
public final class SmartContextEngine: ObservableObject {
    @Published public var configuration: SmartContextConfiguration
    @Published public private(set) var latestSnapshot: ContextSnapshot
    @Published public private(set) var activeSummaries: [ContextSummaryRecord] = []

    private let database: AppDatabase
    private let conversationRepository: ConversationRepository

    public init(
        database: AppDatabase,
        conversationRepository: ConversationRepository,
        configuration: SmartContextConfiguration = SmartContextConfiguration()
    ) {
        self.database = database
        self.conversationRepository = conversationRepository
        self.configuration = configuration
        self.latestSnapshot = ContextSnapshot(
            currentTokenCount: 0,
            targetContextBudget: configuration.baselineContextTarget,
            modelContextWindow: configuration.baselineContextTarget,
            totalMessageCount: 0,
            includedMessageCount: 0,
            retrievedHistoryCount: 0,
            pinnedMessageCount: 0,
            summaryTokenCount: 0,
            summaryCount: 0,
            tokenizerSource: .familyCalibrated,
            adaptiveBatchSize: configuration.initialMessageBatchTarget
        )
    }

    public func syncConfiguration(from settings: SettingsManager) {
        configuration = SmartContextConfiguration(
            adaptiveBatchingEnabled: settings.adaptiveBatchingEnabled,
            smartHistoryRetrievalEnabled: settings.smartHistoryRetrievalEnabled,
            preserveOriginalMessages: settings.preserveOriginalMessages,
            summaryVerificationEnabled: settings.summaryVerificationEnabled,
            baselineContextTarget: settings.baselineContextTarget,
            initialMessageBatchTarget: settings.initialMessageBatchTarget,
            maxRetrievedMessages: settings.maxRetrievedMessages
        )
    }

    /// Assembles the optimized prompt context for the current request while preserving all original messages.
    public func assembleContext(
        conversationID: String,
        systemPrompt: String,
        allMessages: [ChatMessage],
        currentUserQuery: String,
        modelContextWindow: Int,
        tokenizer: ContextTokenCounting,
        imagePayloadsByMessageID: [String: [ChatImagePayload]] = [:],
        modelSummarizer: SummaryGeneratorAndVerifier.ModelSummarizer? = nil
    ) async throws -> AssembledContext {
        let effectiveBudget = max(1024, min(configuration.baselineContextTarget, modelContextWindow))
        let reserveForCompletion = min(1024, effectiveBudget / 4)
        let promptBudget = max(512, effectiveBudget - reserveForCompletion)

        // 1. Measure real/calibrated tokens for every message.
        var tokenCounts: [String: Int] = [:]
        for msg in allMessages {
            tokenCounts[msg.id] = await tokenizer.countMessageTokens(msg)
        }
        let systemTokens = await tokenizer.countTokens(systemPrompt) + 8

        // 2. Load persisted verified summaries for this conversation.
        var summaries = (try? fetchSummaries(conversationID: conversationID)) ?? []
        let summarizedIDs = Set(summaries.flatMap(\.coveredMessageIDs))
        let unsummarizedMessages = allMessages.filter { !summarizedIDs.contains($0.id) }

        let totalUnsummarizedTokens = unsummarizedMessages.reduce(0) { $0 + (tokenCounts[$1.id] ?? 64) }
        let existingSummaryTokens = summaries.reduce(0) { $0 + $1.tokenCount }

        // 3. Adaptive batching & verified summarization when approaching budget threshold.
        let triggerLimit = Int(Double(promptBudget) * configuration.summaryTriggerRatio)
        let adaptiveBatchSize = AdaptiveBatchPlanner.recommendedBatchSize(
            messages: unsummarizedMessages,
            tokenCounts: tokenCounts,
            config: configuration,
            modelContextWindow: modelContextWindow,
            retrievedTokens: 0
        )

        if systemTokens + existingSummaryTokens + totalUnsummarizedTokens > triggerLimit && unsummarizedMessages.count > max(4, adaptiveBatchSize) {
            // Keep the newest messages verbatim; summarize older unsummarized messages in adaptive batches.
            let keepRecentCount = max(4, min(adaptiveBatchSize, unsummarizedMessages.count / 2))
            let candidates = Array(unsummarizedMessages.dropLast(keepRecentCount))
            let batches = AdaptiveBatchPlanner.planBatches(
                candidates: candidates,
                tokenCounts: tokenCounts,
                targetBatchSize: adaptiveBatchSize,
                maxBatchTokens: max(600, promptBudget / 3)
            )
            if let firstBatch = batches.first, !firstBatch.messages.isEmpty {
                let (summaryText, verification) = await SummaryGeneratorAndVerifier.summarizeAndVerify(
                    batch: firstBatch.messages,
                    verify: configuration.summaryVerificationEnabled,
                    modelSummarizer: modelSummarizer
                )
                let summaryTokens = await tokenizer.countTokens(summaryText)
                let record = ContextSummaryRecord(
                    conversationID: conversationID,
                    summaryText: summaryText,
                    coveredMessageIDs: firstBatch.messages.map(\.id),
                    tokenCount: summaryTokens,
                    verificationPassed: verification.passed,
                    verificationNotes: verification.notes
                )
                try saveSummary(record)
                if configuration.preserveOriginalMessages {
                    try conversationRepository.markMessagesArchivedToSummary(ids: record.coveredMessageIDs)
                }
                summaries.append(record)
            }
        }

        // Recompute recent vs historical split after any compaction.
        let updatedSummarizedIDs = Set(summaries.flatMap(\.coveredMessageIDs))
        let recentMessages = allMessages.filter { !updatedSummarizedIDs.contains($0.id) }
        let historicalPool = allMessages.filter { updatedSummarizedIDs.contains($0.id) || $0.isPinned }
            .filter { hist in !recentMessages.contains(where: { $0.id == hist.id }) }

        // 4. Smart history retrieval for older relevant or user-pinned messages.
        let summaryBlockTokens = summaries.reduce(0) { $0 + $1.tokenCount }
        var retrievedScores: [RetrievedMessageScore] = []
        if configuration.smartHistoryRetrievalEnabled && !historicalPool.isEmpty {
            let retrievalTokenBudget = max(256, promptBudget / 4)
            retrievedScores = SmartHistoryRetriever.retrieveRelevant(
                query: currentUserQuery,
                historicalMessages: historicalPool,
                maxMessages: configuration.maxRetrievedMessages,
                maxTokens: retrievalTokenBudget,
                tokenCounts: tokenCounts
            )
        } else {
            // Even if retrieval is disabled, honor explicitly pinned messages.
            let pinned = historicalPool.filter(\.isPinned)
            retrievedScores = pinned.map { RetrievedMessageScore(message: $0, score: 10.0, reason: "user-pinned") }
        }

        // 5. Assemble final prompt messages cleanly within token budget.
        var promptMessages: [ProviderChatMessage] = []
        var usedTokens = 0

        var combinedSystem = systemPrompt
        if !summaries.isEmpty {
            let summaryText = summaries.map(\.summaryText).joined(separator: "\n\n")
            combinedSystem += "\n\n### Verified Prior Conversation Context\n\(summaryText)"
        }
        promptMessages.append(ProviderChatMessage(role: .system, content: combinedSystem))
        usedTokens += systemTokens + summaryBlockTokens

        if !retrievedScores.isEmpty {
            let retrievedBlock = retrievedScores.map { item in
                "[\(item.message.role.rawValue.uppercased()) • \(item.reason)]: \(item.message.content)"
            }.joined(separator: "\n---\n")
            promptMessages.append(ProviderChatMessage(
                role: .system,
                content: "### Retrieved Relevant History\n\(retrievedBlock)"
            ))
            usedTokens += retrievedScores.reduce(0) { $0 + (tokenCounts[$1.message.id] ?? 64) }
        }

        // Include as many recent messages as fit in the remaining prompt budget (always keep latest message).
        var includedRecent: [ChatMessage] = []
        var remainingBudget = max(256, promptBudget - usedTokens)
        for msg in recentMessages.reversed() {
            let t = tokenCounts[msg.id] ?? 64
            if includedRecent.isEmpty || t <= remainingBudget {
                includedRecent.append(msg)
                remainingBudget -= t
                usedTokens += t
            } else {
                break
            }
        }
        includedRecent.reverse()

        for msg in includedRecent {
            var content = msg.content
            for att in msg.attachments where att.kind != .image {
                if let preview = att.extractedPreview, !preview.isEmpty {
                    content += "\n\n[Attached file: \(att.filename)]\n\(preview)"
                }
            }
            promptMessages.append(ProviderChatMessage(
                role: msg.role,
                content: content,
                images: imagePayloadsByMessageID[msg.id] ?? [],
                toolCallID: msg.toolCallID,
                toolName: msg.toolName
            ))
        }

        let snapshot = ContextSnapshot(
            currentTokenCount: usedTokens,
            targetContextBudget: configuration.baselineContextTarget,
            modelContextWindow: modelContextWindow,
            totalMessageCount: allMessages.count,
            includedMessageCount: includedRecent.count,
            retrievedHistoryCount: retrievedScores.count,
            pinnedMessageCount: allMessages.filter(\.isPinned).count,
            summaryTokenCount: summaryBlockTokens,
            summaryCount: summaries.count,
            tokenizerSource: tokenizer.source,
            adaptiveBatchSize: adaptiveBatchSize
        )

        self.activeSummaries = summaries
        self.latestSnapshot = snapshot

        return AssembledContext(
            promptMessages: promptMessages,
            snapshot: snapshot,
            retrievedMessageIDs: retrievedScores.map(\.message.id),
            appliedSummaries: summaries
        )
    }

    /// Manually compacts older unsummarized messages into a verified summary without deleting original rows.
    @discardableResult
    public func compactNow(
        conversationID: String,
        allMessages: [ChatMessage],
        modelContextWindow: Int,
        tokenizer: ContextTokenCounting,
        modelSummarizer: SummaryGeneratorAndVerifier.ModelSummarizer? = nil
    ) async throws -> ContextSummaryRecord? {
        let existing = (try? fetchSummaries(conversationID: conversationID)) ?? []
        let covered = Set(existing.flatMap(\.coveredMessageIDs))
        let unsummarized = allMessages.filter { !covered.contains($0.id) }
        guard unsummarized.count >= 3 else { return nil }

        let keepTail = min(2, unsummarized.count - 1)
        let toSummarize = Array(unsummarized.dropLast(keepTail))
        let (summaryText, verification) = await SummaryGeneratorAndVerifier.summarizeAndVerify(
            batch: toSummarize,
            verify: configuration.summaryVerificationEnabled,
            modelSummarizer: modelSummarizer
        )
        let tokens = await tokenizer.countTokens(summaryText)
        let record = ContextSummaryRecord(
            conversationID: conversationID,
            summaryText: summaryText,
            coveredMessageIDs: toSummarize.map(\.id),
            tokenCount: tokens,
            verificationPassed: verification.passed,
            verificationNotes: verification.notes
        )
        try saveSummary(record)
        try conversationRepository.markMessagesArchivedToSummary(ids: record.coveredMessageIDs)
        _ = try await refreshSnapshot(conversationID: conversationID, allMessages: allMessages, modelContextWindow: modelContextWindow, tokenizer: tokenizer)
        return record
    }

    public func refreshSnapshot(
        conversationID: String,
        allMessages: [ChatMessage],
        modelContextWindow: Int,
        tokenizer: ContextTokenCounting
    ) async throws -> ContextSnapshot {
        let assembled = try await assembleContext(
            conversationID: conversationID,
            systemPrompt: "",
            allMessages: allMessages,
            currentUserQuery: allMessages.last?.content ?? "",
            modelContextWindow: modelContextWindow,
            tokenizer: tokenizer
        )
        return assembled.snapshot
    }

    public func fetchSummaries(conversationID: String) throws -> [ContextSummaryRecord] {
        let rows = try database.sqlite.query(
            "SELECT * FROM context_summaries WHERE conversation_id = ? ORDER BY created_at ASC;",
            bindings: [.text(conversationID)]
        )
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let id = row.string("id"),
                  let convID = row.string("conversation_id"),
                  let text = row.string("summary_text"),
                  let idsJSON = row.string("covered_message_ids_json"),
                  let idsData = idsJSON.data(using: .utf8),
                  let ids = try? decoder.decode([String].self, from: idsData),
                  let tokenCount = row.int("token_count"),
                  let notes = row.string("verification_notes"),
                  let created = row.date("created_at") else { return nil }
            return ContextSummaryRecord(
                id: id,
                conversationID: convID,
                summaryText: text,
                coveredMessageIDs: ids,
                tokenCount: tokenCount,
                verificationPassed: row.bool("verification_passed"),
                verificationNotes: notes,
                createdAt: created
            )
        }
    }

    public func clearSummaries(conversationID: String) throws {
        try database.sqlite.execute("DELETE FROM context_summaries WHERE conversation_id = ?;", bindings: [.text(conversationID)])
        try database.sqlite.execute("UPDATE messages SET is_archived_to_summary = 0 WHERE conversation_id = ?;", bindings: [.text(conversationID)])
        activeSummaries = []
    }

    private func saveSummary(_ record: ContextSummaryRecord) throws {
        let idsData = (try? JSONEncoder().encode(record.coveredMessageIDs)) ?? Data("[]".utf8)
        let idsJSON = String(data: idsData, encoding: .utf8) ?? "[]"
        try database.sqlite.execute(
            """
            INSERT INTO context_summaries (
                id, conversation_id, summary_text, covered_message_ids_json, covered_message_count,
                token_count, verification_passed, verification_notes, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id),
                .text(record.conversationID),
                .text(record.summaryText),
                .text(idsJSON),
                .integer(Int64(record.coveredMessageCount)),
                .integer(Int64(record.tokenCount)),
                .integer(record.verificationPassed ? 1 : 0),
                .text(record.verificationNotes),
                .real(record.createdAt.timeIntervalSince1970)
            ]
        )
    }
}
