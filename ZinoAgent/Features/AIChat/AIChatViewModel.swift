import Foundation
import SwiftUI
import UIKit
import Combine

public struct OnlineConsentPrompt: Identifiable {
    public let id = UUID()
    public let providerName: String
    public let providerID: String
    public let filenames: [String]
    public let filePaths: [String]
    public let onApprove: () -> Void
}

@MainActor
public final class AIChatViewModel: ObservableObject {
    @Published public private(set) var conversations: [ChatConversation] = []
    @Published public var activeConversation: ChatConversation?
    @Published public private(set) var messages: [ChatMessage] = []

    @Published public var inputText: String = ""
    @Published public var draftAttachments: [ChatAttachment] = []
    @Published public var isGenerating: Bool = false
    @Published public var streamingText: String = ""
    @Published public var streamingThinking: String = ""
    @Published public var lastSpeedLabel: String?

    @Published public var pendingToolProposals: [PendingToolProposal] = []
    @Published public var pendingOnlineConsent: OnlineConsentPrompt?
    @Published public var exportURL: URL?
    @Published public var errorMessage: String?

    private let coordinator: AppCoordinator
    private var generationTask: Task<Void, Never>?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        loadConversations()
        consumePendingHandoff()
    }

    public func consumePendingHandoff() {
        if coordinator.requestNewChatID != nil {
            coordinator.requestNewChatID = nil
            createNewConversation()
        }
        if let draft = coordinator.pendingChatDraft {
            inputText = draft
            coordinator.pendingChatDraft = nil
        }
        if !coordinator.pendingChatAttachments.isEmpty {
            draftAttachments.append(contentsOf: coordinator.pendingChatAttachments)
            coordinator.pendingChatAttachments = []
        }
    }

    public func loadConversations() {
        do {
            conversations = try coordinator.conversationRepository.fetchConversations()
            if let active = activeConversation,
               let updated = conversations.first(where: { $0.id == active.id }) {
                activeConversation = updated
                loadMessages(for: updated)
            } else if let first = conversations.first {
                selectConversation(first)
            } else {
                createNewConversation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createNewConversation() {
        let mode = coordinator.settings.defaultAIMode
        let providerID = mode == .online ? coordinator.providerRegistry.defaultProvider?.id : nil
        let modelID: String?
        if mode == .offline {
            modelID = coordinator.offlineEngine.loadedModel?.id ?? coordinator.modelRegistry.models.first?.id
        } else {
            modelID = coordinator.providerRegistry.defaultProvider?.defaultModelID
        }

        let conv = ChatConversation(
            title: "New Chat",
            mode: mode,
            providerID: providerID,
            modelID: modelID,
            systemPrompt: coordinator.settings.defaultSystemPrompt
        )
        do {
            try coordinator.conversationRepository.createConversation(conv)
            conversations.insert(conv, at: 0)
            selectConversation(conv)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectConversation(_ conversation: ChatConversation) {
        activeConversation = conversation
        pendingToolProposals.removeAll()
        loadMessages(for: conversation)
    }

    public func renameConversation(_ conversation: ChatConversation, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = conversation
        updated.title = trimmed
        do {
            try coordinator.conversationRepository.updateConversation(updated)
            if activeConversation?.id == updated.id { activeConversation = updated }
            loadConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteConversation(_ conversation: ChatConversation) {
        do {
            try coordinator.conversationRepository.deleteConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            if activeConversation?.id == conversation.id {
                activeConversation = conversations.first
                if let next = activeConversation {
                    loadMessages(for: next)
                } else {
                    messages = []
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Switches between Offline and Online mode WITHOUT deleting conversation history.
    public func switchMode(to newMode: AIMode) {
        guard var conv = activeConversation else { return }
        conv.mode = newMode
        if newMode == .offline {
            conv.providerID = nil
            conv.modelID = coordinator.offlineEngine.loadedModel?.id ?? coordinator.modelRegistry.models.first?.id
        } else {
            let provider = coordinator.providerRegistry.defaultProvider
            conv.providerID = provider?.id
            conv.modelID = provider?.defaultModelID ?? provider?.cachedModels.first?.id
        }
        activeConversation = conv
        try? coordinator.conversationRepository.updateConversation(conv)
        refreshContextSnapshot()
    }

    public func selectOnlineProvider(_ provider: ProviderConfiguration, modelID: String?) {
        guard var conv = activeConversation else { return }
        conv.mode = .online
        conv.providerID = provider.id
        conv.modelID = modelID ?? provider.defaultModelID ?? provider.cachedModels.first?.id
        activeConversation = conv
        try? coordinator.conversationRepository.updateConversation(conv)
        refreshContextSnapshot()
    }

    public func selectLocalModel(_ model: LocalModelRecord) {
        guard var conv = activeConversation else { return }
        conv.mode = .offline
        conv.providerID = nil
        conv.modelID = model.id
        activeConversation = conv
        try? coordinator.conversationRepository.updateConversation(conv)
        refreshContextSnapshot()
    }

    // MARK: - Attachments

    public func attachFiles(from urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let isImage = ["png", "jpg", "jpeg", "webp", "heic", "gif"].contains(ext)
            let is3D = ["glb", "gltf", "usdz", "obj", "stl"].contains(ext)

            // Stage a local copy in temp directory so attachments remain readable during async streaming.
            let stagedURL = coordinator.storagePaths.tempDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try? FileManager.default.copyItem(at: url, to: stagedURL)

            var preview: String?
            if !isImage && !is3D && DocumentTextExtractor.isTextReadable(url: stagedURL) {
                preview = try? DocumentTextExtractor.extract(from: stagedURL, maxCharacters: 20_000).text
            }

            let kind: ChatAttachment.Kind = isImage ? .image : (is3D ? .threeDModel : .file)
            let mime = isImage ? "image/\(ext == "jpg" ? "jpeg" : ext)" : "text/plain"
            draftAttachments.append(ChatAttachment(
                kind: kind,
                filename: url.lastPathComponent,
                filePath: stagedURL.path,
                mimeType: mime,
                fileSizeBytes: size,
                extractedPreview: preview
            ))
        }
    }

    public func attachImageData(_ data: Data, filename: String = "photo.jpg") {
        let dest = coordinator.storagePaths.tempDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        do {
            try data.write(to: dest, options: .atomic)
            draftAttachments.append(ChatAttachment(
                kind: .image,
                filename: filename,
                filePath: dest.path,
                mimeType: "image/jpeg",
                fileSizeBytes: Int64(data.count),
                extractedPreview: nil
            ))
        } catch {
            errorMessage = "Could not attach image: \(error.localizedDescription)"
        }
    }

    public func removeDraftAttachment(_ attachment: ChatAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - Sending, Editing, Regenerating, Pinning

    public func sendCurrentInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty else { return }
        if activeConversation == nil { createNewConversation() }
        guard let conv = activeConversation else { return }

        // Privacy gate: require explicit user consent before transmitting attached file contents to an online provider.
        if conv.mode == .online,
           !draftAttachments.isEmpty,
           coordinator.settings.requireConsentBeforeOnlineFileUpload,
           let provider = resolvedOnlineProvider(for: conv) {
            let paths = draftAttachments.map(\.filePath)
            if !coordinator.permissionService.hasSessionConsentForOnlineUpload(providerID: provider.id, filePaths: paths) {
                pendingOnlineConsent = OnlineConsentPrompt(
                    providerName: provider.name,
                    providerID: provider.id,
                    filenames: draftAttachments.map(\.filename),
                    filePaths: paths,
                    onApprove: { [weak self] in
                        guard let self else { return }
                        self.coordinator.permissionService.grantSessionConsentForOnlineUpload(providerID: provider.id, filePaths: paths)
                        self.pendingOnlineConsent = nil
                        self.commitAndStreamUserMessage(text: text, attachments: self.draftAttachments)
                    }
                )
                return
            }
        }

        commitAndStreamUserMessage(text: text, attachments: draftAttachments)
    }

    public func stopGeneration() {
        generationTask?.cancel()
        coordinator.offlineEngine.cancelGeneration()
        coordinator.onlineEngine.cancelStreaming()
        isGenerating = false
    }

    public func regenerateLastResponse() {
        guard let conv = activeConversation, !isGenerating else { return }
        if let last = messages.last, last.role == .assistant {
            try? coordinator.conversationRepository.deleteMessage(id: last.id)
            messages.removeLast()
        }
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }
        runAssistantTurn(for: conv, latestQuery: lastUser.content)
    }

    public func editMessage(_ message: ChatMessage, newContent: String) {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = message
        updated.content = trimmed
        try? coordinator.conversationRepository.saveMessage(updated)
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = updated
        }
        refreshContextSnapshot()
    }

    public func togglePin(_ message: ChatMessage) {
        let next = !message.isPinned
        try? coordinator.conversationRepository.setMessagePinned(id: message.id, pinned: next)
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].isPinned = next
        }
        refreshContextSnapshot()
    }

    public func approveToolProposal(_ proposal: PendingToolProposal) {
        pendingToolProposals.removeAll { $0.id == proposal.id }
        let outcome = coordinator.fileToolExecutor.executeApprovedProposal(proposal)
        handleToolResult(toolCallID: proposal.toolCallID, toolName: proposal.toolName.rawValue, outcome: outcome)
    }

    public func rejectToolProposal(_ proposal: PendingToolProposal) {
        pendingToolProposals.removeAll { $0.id == proposal.id }
        coordinator.fileToolExecutor.rejectProposal(proposal)
        appendToolMessage(
            toolCallID: proposal.toolCallID,
            toolName: proposal.toolName.rawValue,
            content: "User declined operation: \(proposal.previewSummary)"
        )
    }

    // MARK: - SmartContext Controls & Export

    public func compactContextNow() {
        guard let conv = activeConversation else { return }
        Task {
            do {
                let tokenizer = activeTokenizer(for: conv)
                _ = try await coordinator.smartContextEngine.compactNow(
                    conversationID: conv.id,
                    allMessages: messages,
                    modelContextWindow: activeModelContextWindow(for: conv),
                    tokenizer: tokenizer
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func clearSummaries() {
        guard let conv = activeConversation else { return }
        try? coordinator.smartContextEngine.clearSummaries(conversationID: conv.id)
        refreshContextSnapshot()
    }

    public func exportActiveConversation(asJSON: Bool) {
        guard let conv = activeConversation else { return }
        do {
            exportURL = asJSON
                ? try coordinator.exportService.exportConversationJSON(conversation: conv)
                : try coordinator.exportService.exportConversationMarkdown(conversation: conv)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Core Turn Execution

    private func commitAndStreamUserMessage(text: String, attachments: [ChatAttachment]) {
        guard var conv = activeConversation else { return }
        let userMessage = ChatMessage(
            conversationID: conv.id,
            role: .user,
            content: text.isEmpty ? "Please analyze the attached file(s)." : text,
            attachments: attachments
        )
        do {
            try coordinator.conversationRepository.saveMessage(userMessage)
            messages.append(userMessage)
            inputText = ""
            draftAttachments = []

            if conv.title == "New Chat" && !userMessage.content.isEmpty {
                conv.title = String(userMessage.content.prefix(42))
                try? coordinator.conversationRepository.updateConversation(conv)
                activeConversation = conv
                if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
                    conversations[idx] = conv
                }
            }
            try? coordinator.database.recordRecentActivity(
                kind: "conversation",
                title: conv.title,
                subtitle: "\(conv.mode.shortName) • \(messages.count) messages",
                referenceID: conv.id
            )
            runAssistantTurn(for: conv, latestQuery: userMessage.content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runAssistantTurn(for conversation: ChatConversation, latestQuery: String) {
        stopGeneration()
        isGenerating = true
        streamingText = ""
        streamingThinking = ""
        errorMessage = nil

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
            }

            do {
                self.coordinator.smartContextEngine.syncConfiguration(from: self.coordinator.settings)
                let tokenizer = self.activeTokenizer(for: conversation)
                let ctxWindow = self.activeModelContextWindow(for: conversation)
                let imageMap = self.buildImagePayloadsByMessageID()

                let assembled = try await self.coordinator.smartContextEngine.assembleContext(
                    conversationID: conversation.id,
                    systemPrompt: conversation.systemPrompt ?? self.coordinator.settings.defaultSystemPrompt,
                    allMessages: self.messages,
                    currentUserQuery: latestQuery,
                    modelContextWindow: ctxWindow,
                    tokenizer: tokenizer,
                    imagePayloadsByMessageID: imageMap
                )

                var collectedText = ""
                var collectedThinking = ""
                var toolCalls: [ToolCallRequest] = []
                var finalUsage: TokenUsage?
                let providerLabel: String
                let modelLabel: String

                if conversation.mode == .offline {
                    guard let loaded = self.coordinator.offlineEngine.loadedModel else {
                        throw ZinoError(
                            .modelNotLoaded,
                            "No local GGUF model is loaded. Open the Models tab to load a downloaded/imported model, or switch to Online mode."
                        )
                    }
                    providerLabel = "Offline (llama.cpp Metal)"
                    modelLabel = loaded.name
                    let promptMsgs = assembled.promptMessages.map {
                        ChatTemplateFormatter.PromptMessage(role: $0.role.rawValue, content: $0.content)
                    }
                    let stream = self.coordinator.offlineEngine.streamChat(
                        messages: promptMsgs,
                        config: self.coordinator.settings.generationConfig
                    )
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        switch chunk {
                        case let .text(delta):
                            collectedText += delta
                            self.streamingText = collectedText
                        case let .thinking(delta):
                            collectedThinking += delta
                            self.streamingThinking = collectedThinking
                        case let .toolCall(tc):
                            toolCalls.append(tc)
                        case let .usage(u):
                            finalUsage = u
                            if let tps = u.tokensPerSecond { self.lastSpeedLabel = Formatters.speed(tps) }
                        case .done:
                            break
                        }
                    }
                } else {
                    guard let provider = self.resolvedOnlineProvider(for: conversation) else {
                        throw ZinoError(
                            .providerNotConfigured,
                            "No online AI provider is configured. Add one in Settings > AI Providers, or switch to Offline mode."
                        )
                    }
                    let modelID = conversation.modelID ?? provider.defaultModelID ?? provider.cachedModels.first?.id
                    guard let modelID, !modelID.isEmpty else {
                        throw ZinoError(.providerNotConfigured, "Select a model for '\(provider.name)' first.")
                    }
                    providerLabel = provider.name
                    modelLabel = modelID

                    let folders = (try? self.coordinator.bookmarkManager.loadFolders()) ?? []
                    let tools = folders.isEmpty ? [] : FileToolDefinitions.schemas(for: self.coordinator.settings.aiFilePermissionLevel)

                    let request = OnlineChatRequest(
                        modelID: modelID,
                        messages: assembled.promptMessages,
                        config: self.coordinator.settings.generationConfig,
                        tools: tools
                    )
                    let stream = self.coordinator.onlineEngine.streamChat(provider: provider, request: request)
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        switch chunk {
                        case let .text(delta):
                            collectedText += delta
                            self.streamingText = collectedText
                        case let .thinking(delta):
                            collectedThinking += delta
                            self.streamingThinking = collectedThinking
                        case let .toolCall(tc):
                            toolCalls.append(tc)
                        case let .usage(u):
                            finalUsage = u
                        case .done:
                            break
                        }
                    }
                }

                if !collectedText.isEmpty || !collectedThinking.isEmpty {
                    let assistantMsg = ChatMessage(
                        conversationID: conversation.id,
                        role: .assistant,
                        content: collectedText.isEmpty ? "(Tool action requested)" : collectedText,
                        thinkingContent: collectedThinking.isEmpty ? nil : collectedThinking,
                        providerLabel: providerLabel,
                        modelLabel: modelLabel,
                        tokenCount: finalUsage?.completionTokens
                    )
                    try self.coordinator.conversationRepository.saveMessage(assistantMsg)
                    self.messages.append(assistantMsg)
                }

                self.streamingText = ""
                self.streamingThinking = ""

                // Evaluate any AI file tool calls through the permission-aware FileToolExecutor.
                var autoExecutedAny = false
                for tc in toolCalls {
                    let outcome = self.coordinator.fileToolExecutor.evaluate(
                        toolCall: tc,
                        conversationID: conversation.id,
                        globalPermissionLevel: self.coordinator.settings.aiFilePermissionLevel
                    )
                    switch outcome {
                    case let .executed(output):
                        self.appendToolMessage(toolCallID: tc.id, toolName: tc.name, content: output)
                        autoExecutedAny = true
                    case let .requiresConfirmation(proposal):
                        self.pendingToolProposals.append(proposal)
                    case let .denied(reason):
                        self.appendToolMessage(toolCallID: tc.id, toolName: tc.name, content: "Denied: \(reason)")
                    }
                }

                self.refreshContextSnapshot()
                if autoExecutedAny && !Task.isCancelled {
                    self.runAssistantTurn(for: conversation, latestQuery: "Summarize the tool results for the user.")
                }
            } catch let zErr as ZinoError where zErr.code == .cancelled {
                self.commitPartialStreamIfNeeded(conversation: conversation)
            } catch is CancellationError {
                self.commitPartialStreamIfNeeded(conversation: conversation)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleToolResult(toolCallID: String, toolName: String, outcome: ToolEvaluationOutcome) {
        switch outcome {
        case let .executed(output):
            appendToolMessage(toolCallID: toolCallID, toolName: toolName, content: output)
            if let conv = activeConversation {
                runAssistantTurn(for: conv, latestQuery: "The user approved \(toolName). Continue responding.")
            }
        case let .denied(reason):
            appendToolMessage(toolCallID: toolCallID, toolName: toolName, content: "Failed: \(reason)")
        case let .requiresConfirmation(p):
            pendingToolProposals.append(p)
        }
    }

    private func appendToolMessage(toolCallID: String, toolName: String, content: String) {
        guard let conv = activeConversation else { return }
        let msg = ChatMessage(
            conversationID: conv.id,
            role: .tool,
            content: content,
            providerLabel: "File Tool",
            modelLabel: toolName,
            toolCallID: toolCallID,
            toolName: toolName
        )
        try? coordinator.conversationRepository.saveMessage(msg)
        messages.append(msg)
    }

    private func commitPartialStreamIfNeeded(conversation: ChatConversation) {
        guard !streamingText.isEmpty else { return }
        let partial = ChatMessage(
            conversationID: conversation.id,
            role: .assistant,
            content: streamingText + "\n\n*[Generation stopped]*",
            thinkingContent: streamingThinking.isEmpty ? nil : streamingThinking,
            providerLabel: conversation.mode == .offline ? "Offline" : "Online"
        )
        try? coordinator.conversationRepository.saveMessage(partial)
        messages.append(partial)
        streamingText = ""
        streamingThinking = ""
    }

    private func loadMessages(for conversation: ChatConversation) {
        messages = (try? coordinator.conversationRepository.fetchMessages(conversationID: conversation.id)) ?? []
        refreshContextSnapshot()
    }

    private func refreshContextSnapshot() {
        guard let conv = activeConversation else { return }
        let msgs = messages
        let tokenizer = activeTokenizer(for: conv)
        let ctxWindow = activeModelContextWindow(for: conv)
        Task {
            _ = try? await coordinator.smartContextEngine.refreshSnapshot(
                conversationID: conv.id,
                allMessages: msgs,
                modelContextWindow: ctxWindow,
                tokenizer: tokenizer
            )
        }
    }

    private func resolvedOnlineProvider(for conversation: ChatConversation) -> ProviderConfiguration? {
        if let pid = conversation.providerID,
           let match = coordinator.providerRegistry.providers.first(where: { $0.id == pid }) {
            return match
        }
        return coordinator.providerRegistry.defaultProvider
    }

    private func activeTokenizer(for conversation: ChatConversation) -> ContextTokenCounting {
        if conversation.mode == .offline, let loaded = coordinator.offlineEngine.loadedModel {
            let engine = coordinator.offlineEngine
            return SmartContextTokenizer(
                family: TokenizerModelFamily.detect(modelID: loaded.name, architecture: loaded.architecture),
                exactCounter: { text in
                    await engine.exactTokenCount(for: text)
                }
            )
        }
        return SmartContextTokenizer(family: TokenizerModelFamily.detect(modelID: conversation.modelID, architecture: nil))
    }

    private func activeModelContextWindow(for conversation: ChatConversation) -> Int {
        if conversation.mode == .offline {
            if case let .loaded(info) = coordinator.offlineEngine.loadState {
                return info.contextLength
            }
            return coordinator.settings.localContextLength
        }
        if let provider = resolvedOnlineProvider(for: conversation),
           let modelID = conversation.modelID,
           let descriptor = provider.cachedModels.first(where: { $0.id == modelID }) {
            return descriptor.contextWindow
        }
        return 128_000
    }

    private func buildImagePayloadsByMessageID() -> [String: [ChatImagePayload]] {
        var result: [String: [ChatImagePayload]] = [:]
        for msg in messages {
            var payloads: [ChatImagePayload] = []
            for att in msg.attachments where att.kind == .image {
                let url = URL(fileURLWithPath: att.filePath)
                if let data = try? Data(contentsOf: url) {
                    payloads.append(ChatImagePayload(mimeType: att.mimeType, base64Data: data.base64EncodedString()))
                }
            }
            if !payloads.isEmpty {
                result[msg.id] = payloads
            }
        }
        return result
    }
}
