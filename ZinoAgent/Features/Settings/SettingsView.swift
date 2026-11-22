import SwiftUI

public struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: SettingsManager
    @StateObject private var viewModel: SettingsViewModel

    @State private var showAddProviderSheet = false
    @State private var editingProvider: ProviderConfiguration?
    @State private var showContextDashboard = false
    @State private var showDeleteConversationsConfirm = false
    @State private var showToolLogSheet = false

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
        _viewModel = StateObject(wrappedValue: SettingsViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let msg = viewModel.statusMessage {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(ZinoTheme.statusPositive)
                            Text(msg).font(.caption)
                            Spacer()
                            Button { viewModel.statusMessage = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                        }
                    }
                }
                if let err = viewModel.errorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ZinoTheme.statusCritical)
                            Text(err).font(.caption)
                            Spacer()
                            Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                        }
                    }
                }

                generalSection
                aiSection
                localModelsSection
                smartContextSection
                filesSection
                privacySection
                threeDStudioSection
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddProviderSheet) {
                ProviderEditorSheet(existing: nil, registry: coordinator.providerRegistry) {
                    viewModel.refresh()
                }
            }
            .sheet(item: $editingProvider) { provider in
                ProviderEditorSheet(existing: provider, registry: coordinator.providerRegistry) {
                    viewModel.refresh()
                }
            }
            .sheet(isPresented: $showContextDashboard) {
                SmartContextDashboardView(
                    contextEngine: coordinator.smartContextEngine,
                    settings: settings,
                    conversationID: nil,
                    onCompactNow: {},
                    onClearSummaries: {}
                )
            }
            .sheet(isPresented: $showToolLogSheet) {
                NavigationStack {
                    List {
                        if viewModel.toolActivityLog.isEmpty {
                            Text("No AI file tool operations have been recorded yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.toolActivityLog) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.toolName).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        StatusBadge(entry.status, tint: entry.status == "executed" ? ZinoTheme.statusPositive : ZinoTheme.statusWarning)
                                    }
                                    Text(entry.resultSummary).font(.caption).foregroundStyle(.secondary)
                                    Text("\(entry.permissionLevel.displayName) • \(Formatters.timestamp(entry.createdAt))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .navigationTitle("AI File Tool Activity")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if !viewModel.toolActivityLog.isEmpty {
                                Button("Clear", role: .destructive) { viewModel.clearToolLog() }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showToolLogSheet = false }
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.exportDataURL != nil },
                set: { if !$0 { viewModel.exportDataURL = nil } }
            )) {
                if let url = viewModel.exportDataURL {
                    ShareSheetView(activityItems: [url])
                }
            }
            .confirmationDialog(
                "Delete All Conversations?",
                isPresented: $showDeleteConversationsConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All Conversations", role: .destructive) {
                    viewModel.deleteAllConversations()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all local chats and context summaries. Your mounted files, downloaded models, and 3D projects are unaffected.")
            }
            .onAppear {
                viewModel.refresh()
                if coordinator.requestOpenProviderSetup {
                    coordinator.requestOpenProviderSetup = false
                    showAddProviderSheet = true
                }
            }
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("General") {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("Default Startup Screen", selection: $settings.defaultSection) {
                ForEach(NavigationSection.allCases) { sec in
                    Text(sec.title).tag(sec)
                }
            }
            LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: settings.preferredLanguageCode) ?? "English")
        }
    }

    private var aiSection: some View {
        Section("AI & Online Providers") {
            Picker("Default AI Mode", selection: $settings.defaultAIMode) {
                ForEach(AIMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }

            HStack {
                Text("Temperature: \(String(format: "%.2f", settings.temperature))")
                Slider(value: $settings.temperature, in: 0.0...1.5, step: 0.05)
            }
            HStack {
                Text("Top-P: \(String(format: "%.2f", settings.topP))")
                Slider(value: $settings.topP, in: 0.1...1.0, step: 0.05)
            }
            Stepper("Max Response Tokens: \(settings.maxGenerationTokens)", value: $settings.maxGenerationTokens, in: 256...16384, step: 256)

            ForEach(coordinator.providerRegistry.providers) { provider in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(provider.name).font(.subheadline.weight(.semibold))
                            if provider.isDefault {
                                StatusBadge("Default", tint: ZinoTheme.statusPositive)
                            }
                        }
                        Text("\(provider.providerType.displayName) • \(provider.defaultModelID ?? "No model selected")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let masked = coordinator.providerRegistry.maskedCredential(for: provider) {
                            Text("Keychain: \(masked)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Edit") { editingProvider = provider }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { viewModel.deleteProvider(provider) }
                    if !provider.isDefault {
                        Button("Set Default") { viewModel.setDefaultProvider(provider) }
                            .tint(.blue)
                    }
                }
            }

            Button {
                showAddProviderSheet = true
            } label: {
                Label("Add Online AI Provider", systemImage: "plus.circle")
            }
        }
    }

    private var localModelsSection: some View {
        Section("Local Models (llama.cpp Metal)") {
            LabeledContent("Storage Used", value: Formatters.bytes(coordinator.storageBreakdown.localModelsBytes))
            LabeledContent("Installed GGUF Models", value: "\(coordinator.modelRegistry.models.count)")
            Picker("Local Context Window", selection: $settings.localContextLength) {
                Text("2K (2,048)").tag(2048)
                Text("4K (4,096)").tag(4096)
                Text("8K (8,192)").tag(8192)
                Text("16K (16,384)").tag(16384)
                Text("32K (32,768)").tag(32768)
            }
            Toggle("Metal GPU Layer Offload", isOn: $settings.useMetalGPUOffload)
            Toggle("Auto-Unload Idle Model on Memory Warning", isOn: $settings.autoUnloadOnMemoryWarning)
            Toggle("Thermal Awareness Alerts", isOn: $settings.thermalNotificationsEnabled)
            if coordinator.offlineEngine.loadState.isLoaded {
                Button("Unload Active Local Model Now", role: .destructive) {
                    Task { await coordinator.offlineEngine.unload() }
                }
            }
        }
    }

    private var smartContextSection: some View {
        Section("SmartContextEngine") {
            Toggle("Adaptive Batch Sizing", isOn: $settings.adaptiveBatchingEnabled)
            Toggle("Smart History Retrieval", isOn: $settings.smartHistoryRetrievalEnabled)
            Toggle("Preserve Original Messages", isOn: $settings.preserveOriginalMessages)
            Toggle("Summary Verification", isOn: $settings.summaryVerificationEnabled)
            Stepper("Baseline Context Target: \(Formatters.tokens(settings.baselineContextTarget))", value: $settings.baselineContextTarget, in: 2048...32768, step: 1024)
            Stepper("Initial Batch Size: \(settings.initialMessageBatchTarget) msgs", value: $settings.initialMessageBatchTarget, in: 2...12)
            Stepper("Max Retrieved Messages: \(settings.maxRetrievedMessages)", value: $settings.maxRetrievedMessages, in: 0...20)
            Button {
                showContextDashboard = true
            } label: {
                Label("Open SmartContext Dashboard", systemImage: "brain.head.profile")
            }
        }
        .onChange(of: settings.adaptiveBatchingEnabled) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
        .onChange(of: settings.smartHistoryRetrievalEnabled) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
        .onChange(of: settings.preserveOriginalMessages) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
        .onChange(of: settings.summaryVerificationEnabled) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
        .onChange(of: settings.baselineContextTarget) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
        .onChange(of: settings.initialMessageBatchTarget) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
        .onChange(of: settings.maxRetrievedMessages) { _, _ in coordinator.smartContextEngine.syncConfiguration(from: settings) }
    }

    private var filesSection: some View {
        Section("Files & AI Tool Permissions") {
            Picker("Global AI File Permission", selection: $settings.aiFilePermissionLevel) {
                ForEach(AIPermissionLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Text(settings.aiFilePermissionLevel.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Default File View", selection: $settings.defaultFileViewMode) {
                Text("Grid").tag("grid")
                Text("List").tag("list")
            }
            Picker("Default Sort", selection: $settings.defaultFileSort) {
                ForEach(FileSortOption.allCases) { opt in
                    Text(opt.displayName).tag(opt.rawValue)
                }
            }

            if !viewModel.mountedFolders.isEmpty {
                ForEach(viewModel.mountedFolders) { folder in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(folder.displayName).font(.subheadline.weight(.medium))
                            Spacer()
                            StatusBadge(folder.isAccessible ? "Connected" : "Needs Reconnect", tint: folder.isAccessible ? ZinoTheme.statusPositive : ZinoTheme.statusWarning)
                        }
                        Picker("Folder AI Scope", selection: Binding(
                            get: { folder.permissionLevel },
                            set: { viewModel.updateFolderPermission(folder, level: $0) }
                        )) {
                            ForEach(AIPermissionLevel.allCases) { lvl in
                                Text(lvl.displayName).tag(lvl)
                            }
                        }
                        .font(.caption)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { viewModel.removeFolder(folder) }
                    }
                }
            }

            Button {
                viewModel.refresh()
                showToolLogSheet = true
            } label: {
                Label("View AI Tool Activity Log (\(viewModel.toolActivityLog.count))", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy & Data Control") {
            Toggle("Require Consent Before Sending Files Online", isOn: $settings.requireConsentBeforeOnlineFileUpload)
            Text("ZinoAgent is offline-first with zero telemetry and zero automatic cloud sync. Files are accessed strictly inside folders you explicitly select via Apple Files.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Cache Usage", value: Formatters.bytes(coordinator.storageBreakdown.cacheBytes))
            Button("Clear Safe Caches") {
                viewModel.clearSafeCaches()
            }
            Button("Export All Conversations & Settings (No API Keys)") {
                viewModel.exportAllData()
            }
            Button("Delete All Conversations", role: .destructive) {
                showDeleteConversationsConfirm = true
            }
        }
    }

    private var threeDStudioSection: some View {
        Section("3D Studio") {
            Picker("Default Lighting", selection: $settings.threeDLightingPreset) {
                ForEach(ThreeDLightingPreset.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }
            Picker("Default Environment", selection: $settings.threeDEnvironmentPreset) {
                ForEach(ThreeDEnvironmentPreset.allCases) { e in
                    Text(e.displayName).tag(e.rawValue)
                }
            }
            Toggle("Show Reference Grid by Default", isOn: $settings.threeDShowGrid)
            Stepper("Large-File Warning: \(settings.threeDLargeFileWarningMB) MB", value: $settings.threeDLargeFileWarningMB, in: 25...500, step: 25)
            Text("Original 3D assets, polygon counts, materials, and textures are always preserved at full quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        let res = coordinator.resourceMonitor.snapshot
        return Section("About ZinoAgent 2.0") {
            LabeledContent("Version", value: "\(AppConfiguration.version) (Build \(AppConfiguration.buildNumber))")
            LabeledContent("Device Model", value: res.deviceModelIdentifier)
            LabeledContent("OS", value: res.systemVersion)
            LabeledContent("Physical RAM", value: Formatters.memory(res.physicalMemoryBytes))
            LabeledContent("llama.cpp Linked", value: LlamaCppEngine.isRuntimeCompiledIn ? "Yes (Metal)" : "Requires XCFramework Build")
            LabeledContent("Core ML Diffusion Linked", value: CoreMLDiffusionEngine.isRuntimeCompiledIn ? "Yes" : "Unavailable")

            ForEach(AppConfiguration.openSourceLicenses, id: \.name) { lic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(lic.name).font(.subheadline.weight(.medium))
                    Text("\(lic.license) • \(lic.url)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
