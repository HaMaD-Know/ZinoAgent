import XCTest
@testable import ZinoAgent

final class SmartContextEngineTests: XCTestCase {
    @MainActor
    func testOriginalMessagesPreservedAfterCompactionAndVerification() async throws {
        let db = try AppDatabase.inMemory()
        let convRepo = ConversationRepository(database: db)
        let engine = SmartContextEngine(
            database: db,
            conversationRepository: convRepo,
            configuration: SmartContextConfiguration(
                adaptiveBatchingEnabled: true,
                smartHistoryRetrievalEnabled: true,
                preserveOriginalMessages: true,
                summaryVerificationEnabled: true,
                baselineContextTarget: 1024,
                initialMessageBatchTarget: 5,
                maxRetrievedMessages: 5
            )
        )

        let conv = ChatConversation(title: "Context Preservation Test", mode: .offline)
        try convRepo.createConversation(conv)

        var messages: [ChatMessage] = []
        for i in 1...10 {
            let role: ChatRole = i.isMultiple(of: 2) ? .assistant : .user
            let content = role == .user
                ? "Turn \(i): Please always keep ArchitecturePlan.md and ZinoEngine.swift synced. Decision: use SQLite WAL mode for turn \(i). " + String(repeating: "Detailed context prose for token testing. ", count: 14)
                : "Response \(i): Confirmed working on ZinoEngine.swift and ArchitecturePlan.md with SQLite WAL mode. " + String(repeating: "Implementation details verified cleanly. ", count: 14)
            let msg = ChatMessage(
                conversationID: conv.id,
                role: role,
                content: content,
                createdAt: Date(timeIntervalSince1970: Double(1000 + i * 10))
            )
            try convRepo.saveMessage(msg)
            messages.append(msg)
        }

        let tokenizer = SmartContextTokenizer(family: .qwen)
        let assembled = try await engine.assembleContext(
            conversationID: conv.id,
            systemPrompt: "You are ZinoAgent.",
            allMessages: messages,
            currentUserQuery: "What did we decide about ZinoEngine.swift?",
            modelContextWindow: 4096,
            tokenizer: tokenizer
        )

        // 1. Original messages MUST remain intact in SQLite.
        let persisted = try convRepo.fetchMessages(conversationID: conv.id)
        XCTAssertEqual(persisted.count, 10, "Original messages must never be deleted by summarization.")

        // 2. Context summary should have been generated and verified.
        let summaries = try engine.fetchSummaries(conversationID: conv.id)
        XCTAssertFalse(summaries.isEmpty, "Expected SmartContextEngine to compact older messages.")
        XCTAssertTrue(summaries.allSatisfy { $0.verificationPassed }, "Summary verification should pass and retain critical facts.")
        XCTAssertTrue(summaries.first?.summaryText.contains("ZinoEngine.swift") == true)
        XCTAssertGreaterThan(assembled.snapshot.currentTokenCount, 0)
        XCTAssertEqual(assembled.snapshot.totalMessageCount, 10)
    }

    func testAdaptiveBatchPlannerNeverSplitsToolCallFromToolResult() {
        let convID = "conv-tool-split"
        let msgs: [ChatMessage] = [
            ChatMessage(conversationID: convID, role: .user, content: "List files"),
            ChatMessage(conversationID: convID, role: .assistant, content: "Calling list_files"),
            ChatMessage(conversationID: convID, role: .tool, content: "a.txt\nb.txt", toolCallID: "tc1", toolName: "list_files"),
            ChatMessage(conversationID: convID, role: .user, content: "Thanks"),
            ChatMessage(conversationID: convID, role: .assistant, content: "You're welcome")
        ]
        let counts = Dictionary(uniqueKeysWithValues: msgs.map { ($0.id, 100) })
        let batches = AdaptiveBatchPlanner.planBatches(
            candidates: msgs,
            tokenCounts: counts,
            targetBatchSize: 2,
            maxBatchTokens: 250
        )

        // The assistant message (index 1) and tool result (index 2) must stay in the exact same batch.
        for batch in batches {
            let hasAssistantCall = batch.messages.contains(where: { $0.id == msgs[1].id })
            let hasToolResult = batch.messages.contains(where: { $0.id == msgs[2].id })
            XCTAssertEqual(hasAssistantCall, hasToolResult, "Tool call and tool result must never be split across batches.")
        }
    }

    func testSmartHistoryRetrieverAlwaysIncludesPinnedMessages() {
        let convID = "conv-pin"
        let pinned = ChatMessage(
            conversationID: convID,
            role: .user,
            content: "Critical preference: export reports as Markdown.",
            isPinned: true,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let unrelated = ChatMessage(
            conversationID: convID,
            role: .user,
            content: "Tell me a short story about mountains.",
            isPinned: false,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let counts = [pinned.id: 20, unrelated.id: 20]
        let retrieved = SmartHistoryRetriever.retrieveRelevant(
            query: "Check 3D mesh textures",
            historicalMessages: [pinned, unrelated],
            maxMessages: 2,
            maxTokens: 500,
            tokenCounts: counts
        )
        XCTAssertTrue(retrieved.contains(where: { $0.message.id == pinned.id }))
    }

    func testSummaryVerifierDetectsAndPreservesMissingFacts() async {
        let convID = "conv-verify"
        let msgs = [
            ChatMessage(conversationID: convID, role: .user, content: "Always keep SecurityAudit.pdf encrypted. Decision: target iPadOS 17."),
            ChatMessage(conversationID: convID, role: .assistant, content: "Understood, SecurityAudit.pdf will stay local.")
        ]

        // Simulate a lossy model summary that forgot the filename and decision.
        let (repaired, verification) = await SummaryGeneratorAndVerifier.summarizeAndVerify(
            batch: msgs,
            verify: true,
            modelSummarizer: { _ in "The user talked about a file." }
        )

        XCTAssertTrue(repaired.contains("SecurityAudit.pdf"), "Verifier must preserve omitted critical filenames.")
        XCTAssertTrue(verification.passed)
    }
}
