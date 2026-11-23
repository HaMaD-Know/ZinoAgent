import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

public struct AIChatView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewModel: AIChatViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showConversationDrawer = false
    @State private var showContextDashboard = false
    @State private var showFileAttachPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var renamingConversation: ChatConversation?
    @State private var renameTitle = ""
    @State private var editingMessage: ChatMessage?
    @State private var editedMessageText = ""

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: AIChatViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if horizontalSizeClass == .regular {
                    conversationSidebar
                        .frame(width: 240)
                    Divider()
                }
                chatMainColumn
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle(viewModel.activeConversation?.title ?? "AI Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(isPresented: $showConversationDrawer) {
                NavigationStack {
                    conversationSidebar
                        .navigationTitle("Conversations")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showConversationDrawer = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showContextDashboard) {
                SmartContextDashboardView(
                    contextEngine: coordinator.smartContextEngine,
                    settings: coordinator.settings,
                    conversationID: viewModel.activeConversation?.id,
                    onCompactNow: { viewModel.compactContextNow() },
                    onClearSummaries: { viewModel.clearSummaries() }
                )
            }
            .sheet(isPresented: $showFileAttachPicker) {
                DocumentPickerView(contentTypes: [.item], allowsMultipleSelection: true) { urls in
                    viewModel.attachFiles(from: urls)
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.exportURL != nil },
                set: { if !$0 { viewModel.exportURL = nil } }
            )) {
                if let url = viewModel.exportURL {
                    ShareSheetView(activityItems: [url])
                }
            }
            .sheet(item: $viewModel.pendingOnlineConsent) { consent in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Confirm External Data Transmission", systemImage: "lock.shield")
                            .font(.title3.weight(.semibold))
                        Text("You are in **Online mode** using **\(consent.providerName)**. Sending this message will transmit the following attached file content to \(consent.providerName)'s API:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(consent.filenames, id: \.self) { file in
                                Label(file, systemImage: "doc.fill")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ZinoTheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("No files are ever uploaded without your confirmation. Switch to Offline mode at any time to process files strictly on-device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        HStack {
                            Button("Cancel", role: .cancel) {
                                viewModel.pendingOnlineConsent = nil
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button("Allow & Send") {
                                consent.onApprove()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(20)
                    .navigationTitle("Privacy Check")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
            .alert("Rename Conversation", isPresented: Binding(
                get: { renamingConversation != nil },
                set: { if !$0 { renamingConversation = nil } }
            )) {
                TextField("Title", text: $renameTitle)
                Button("Save") {
                    if let conv = renamingConversation {
                        viewModel.renameConversation(conv, to: renameTitle)
                    }
                    renamingConversation = nil
                }
                Button("Cancel", role: .cancel) { renamingConversation = nil }
            }
            .alert("Edit Message", isPresented: Binding(
                get: { editingMessage != nil },
                set: { if !$0 { editingMessage = nil } }
            )) {
                TextField("Message", text: $editedMessageText, axis: .vertical)
                Button("Save") {
                    if let msg = editingMessage {
                        viewModel.editMessage(msg, newContent: editedMessageText)
                    }
                    editingMessage = nil
                }
                Button("Cancel", role: .cancel) { editingMessage = nil }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        viewModel.attachImageData(data)
                    }
                    selectedPhotoItem = nil
                }
            }
            .onAppear {
                viewModel.consumePendingHandoff()
            }
        }
    }

    // MARK: - Conversation Sidebar

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.createNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(viewModel.conversations) { conv in
                let isSelected = viewModel.activeConversation?.id == conv.id
                Button {
                    viewModel.selectConversation(conv)
                    showConversationDrawer = false
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conv.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Image(systemName: conv.mode.iconName)
                            Text(Formatters.relativeDate(conv.updatedAt))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                .contextMenu {
                    Button {
                        renamingConversation = conv
                        renameTitle = conv.title
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) {
                        viewModel.deleteConversation(conv)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .listStyle(.plain)
        }
        .background(ZinoTheme.surfaceSecondary.opacity(0.45))
    }

    // MARK: - Main Chat Column

    private var chatMainColumn: some View {
        VStack(spacing: 0) {
            modeAndModelControlBar
            Divider()

            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZinoTheme.statusCritical)
                    Text(error).font(.caption).lineLimit(3)
                    Spacer()
                    Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark").font(.caption2) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ZinoTheme.statusCritical.opacity(0.10))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if viewModel.messages.isEmpty && !viewModel.isGenerating {
                            emptyChatState
                        } else {
                            ForEach(viewModel.messages) { msg in
                                messageRow(msg)
                                    .id(msg.id)
                            }
                            if viewModel.isGenerating {
                                streamingBubble
                                    .id("streaming-active")
                            }
                            ForEach(viewModel.pendingToolProposals) { proposal in
                                toolProposalCard(proposal)
                            }
                        }
                    }
                    .padding(ZinoTheme.Spacing.md)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    proxy.scrollTo("streaming-active", anchor: .bottom)
                }
            }

            Divider()
            composerArea
        }
    }

    private var modeAndModelControlBar: some View {
        let mode = viewModel.activeConversation?.mode ?? coordinator.settings.defaultAIMode
        let snap = coordinator.smartContextEngine.latestSnapshot
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("Mode", selection: Binding(
                    get: { mode },
                    set: { viewModel.switchMode(to: $0) }
                )) {
                    Text("Offline").tag(AIMode.offline)
                    Text("Online").tag(AIMode.online)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                modelSelectorMenu(mode: mode)

                Button {
                    showContextDashboard = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "brain.head.profile")
                        Text("Context \(Formatters.tokens(snap.currentTokenCount))/\(Formatters.tokens(snap.effectiveCapacity))")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ZinoTheme.surfaceSecondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                StatusBadge(
                    "Tools: \(coordinator.settings.aiFilePermissionLevel.displayName)",
                    icon: "lock.shield",
                    tint: .secondary
                )

                if coordinator.localHTTPServer.isRunning {
                    Button {
                        coordinator.selectedSection = .browser
                    } label: {
                        StatusBadge(
                            "Live Browser (\(coordinator.localHTTPServer.baseURLString))",
                            icon: "globe",
                            tint: ZinoTheme.statusPositive
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let speed = viewModel.lastSpeedLabel {
                    StatusBadge(speed, icon: "bolt.fill", tint: ZinoTheme.statusPositive)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func modelSelectorMenu(mode: AIMode) -> some View {
        if mode == .offline {
            Menu {
                if coordinator.modelRegistry.models.isEmpty {
                    Button("Go to Models to Download / Import") {
                        coordinator.selectedSection = .models
                    }
                } else {
                    ForEach(coordinator.modelRegistry.models) { model in
                        Button {
                            viewModel.selectLocalModel(model)
                            if coordinator.offlineEngine.loadedModel?.id != model.id {
                                Task {
                                    let url = coordinator.modelRegistry.resolveFileURL(for: model)
                                    try? await coordinator.offlineEngine.loadModel(
                                        model,
                                        fileURL: url,
                                        contextLength: coordinator.settings.localContextLength,
                                        useMetalGPU: coordinator.settings.useMetalGPUOffload
                                    )
                                }
                            }
                        } label: {
                            let isLoaded = coordinator.offlineEngine.loadedModel?.id == model.id
                            Label("\(model.name) (\(model.quantization))\(isLoaded ? " • Loaded" : "")", systemImage: isLoaded ? "checkmark.circle.fill" : "cpu")
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                    Text(coordinator.offlineEngine.loadedModel?.name ?? "Select Local Model")
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ZinoTheme.surfaceSecondary)
                .clipShape(Capsule())
            }
        } else {
            Menu {
                if coordinator.providerRegistry.providers.isEmpty {
                    Button("Configure Provider in Settings") {
                        coordinator.openProviderSetup()
                    }
                } else {
                    ForEach(coordinator.providerRegistry.providers) { provider in
                        Menu(provider.name) {
                            let models = provider.cachedModels.filter { !$0.supportsImageGeneration }
                            if models.isEmpty {
                                Button(provider.defaultModelID ?? "Use Default") {
                                    viewModel.selectOnlineProvider(provider, modelID: provider.defaultModelID)
                                }
                            } else {
                                ForEach(models.prefix(30)) { m in
                                    Button(m.displayName) {
                                        viewModel.selectOnlineProvider(provider, modelID: m.id)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cloud")
                    Text(viewModel.activeConversation?.modelID ?? coordinator.providerRegistry.defaultProvider?.defaultModelID ?? "Select Online Model")
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ZinoTheme.surfaceSecondary)
                .clipShape(Capsule())
            }
        }
    }

    private var emptyChatState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("ZinoAgent AI Workspace")
                .font(.title3.weight(.semibold))
            Text("Chat locally with GGUF models on Apple Silicon or switch to your configured online providers without losing conversation history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func messageRow(_ msg: ChatMessage) -> some View {
        let isUser = msg.role == .user
        let isTool = msg.role == .tool

        return HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(isUser ? "You" : (isTool ? "Tool: \(msg.toolName ?? "File")" : (msg.modelLabel ?? "Assistant")))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isUser ? Color.accentColor : .secondary)
                    if let provider = msg.providerLabel, !isUser {
                        Text("• \(provider)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if msg.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(ZinoTheme.statusWarning)
                    }
                    Spacer()
                    Text(Formatters.relativeDate(msg.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let thinking = msg.thinkingContent, !thinking.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.medium))
                }

                if !msg.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(msg.attachments) { att in
                                Label(att.filename, systemImage: att.kind == .image ? "photo" : "doc")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ZinoTheme.surfaceTertiary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                MarkdownMessageView(content: msg.content)
                    .font(.body)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = msg.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                    }
                    Button {
                        viewModel.togglePin(msg)
                    } label: {
                        Label(msg.isPinned ? "Unpin" : "Pin to Context", systemImage: msg.isPinned ? "pin.slash" : "pin").font(.caption2)
                    }
                    if isUser {
                        Button {
                            editingMessage = msg
                            editedMessageText = msg.content
                        } label: {
                            Label("Edit", systemImage: "pencil").font(.caption2)
                        }
                    }
                    if !isUser && !isTool && msg.id == viewModel.messages.last?.id {
                        Button {
                            viewModel.regenerateLastResponse()
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise").font(.caption2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(12)
            .background(isUser ? Color.accentColor.opacity(0.10) : (isTool ? ZinoTheme.statusInfo.opacity(0.08) : ZinoTheme.surfaceSecondary))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ZinoTheme.border, lineWidth: 0.75))
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Generating...").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !viewModel.streamingThinking.isEmpty {
                Text(viewModel.streamingThinking)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.streamingText.isEmpty {
                MarkdownMessageView(content: viewModel.streamingText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZinoTheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func toolProposalCard(_ proposal: PendingToolProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(proposal.isSuggestionOnly ? "Suggested File Action" : "Approval Required", systemImage: "folder.badge.questionmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ZinoTheme.statusWarning)
                Spacer()
                StatusBadge(proposal.toolName.displayTitle, tint: ZinoTheme.statusWarning)
            }
            Text(proposal.previewSummary)
                .font(.subheadline)
            Text("Folder scope: \(proposal.folderName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Decline", role: .destructive) {
                    viewModel.rejectToolProposal(proposal)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Approve & Execute") {
                    viewModel.approveToolProposal(proposal)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(ZinoTheme.statusWarning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZinoTheme.statusWarning.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(spacing: 8) {
            if !viewModel.draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.draftAttachments) { att in
                            HStack(spacing: 6) {
                                Image(systemName: att.kind == .image ? "photo" : "doc.text")
                                Text(att.filename).font(.caption).lineLimit(1)
                                Button {
                                    viewModel.removeDraftAttachment(att)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ZinoTheme.surfaceSecondary)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button { showFileAttachPicker = true } label: {
                        Label("Attach File from Files", systemImage: "doc.badge.plus")
                    }
                    Button {
                        viewModel.attachCurrentBrowserEphemeralScreenshot()
                    } label: {
                        Label("Attach Live Browser Snapshot (RAM Only)", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }

                TextField("Ask ZinoAgent anything about your files, code, or 3D models...", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ZinoTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if viewModel.isGenerating {
                    Button {
                        viewModel.stopGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ZinoTheme.statusCritical)
                    }
                } else {
                    Button {
                        viewModel.sendCurrentInput()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.draftAttachments.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if horizontalSizeClass != .regular {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showConversationDrawer = true
                } label: {
                    Label("Chats", systemImage: "sidebar.left")
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                viewModel.createNewConversation()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }

            Menu {
                Button {
                    showContextDashboard = true
                } label: { Label("SmartContext Dashboard", systemImage: "brain.head.profile") }
                if let conv = viewModel.activeConversation {
                    Button {
                        renamingConversation = conv
                        renameTitle = conv.title
                    } label: { Label("Rename Chat", systemImage: "pencil") }
                    Button {
                        viewModel.exportActiveConversation(asJSON: false)
                    } label: { Label("Export Markdown", systemImage: "doc.plaintext") }
                    Button {
                        viewModel.exportActiveConversation(asJSON: true)
                    } label: { Label("Export JSON", systemImage: "curlybraces") }
                    Divider()
                    Button(role: .destructive) {
                        viewModel.deleteConversation(conv)
                    } label: { Label("Delete Chat", systemImage: "trash") }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}
