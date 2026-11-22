import SwiftUI
import UniformTypeIdentifiers

public struct ModelManagerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewModel: ModelManagerViewModel

    @State private var showGGUFImporter = false
    @State private var showCoreMLImporter = false
    @State private var showCustomURLSheet = false

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: ModelManagerViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                activeEngineBanner
                Divider()

                Picker("Section", selection: $viewModel.selectedTab) {
                    ForEach(ModelManagerViewModel.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, ZinoTheme.Spacing.md)
                .padding(.vertical, 10)

                if let msg = viewModel.statusMessage {
                    bannerBar(msg, isError: false) { viewModel.statusMessage = nil }
                }
                if let err = viewModel.errorMessage {
                    bannerBar(err, isError: true) { viewModel.errorMessage = nil }
                }

                switch viewModel.selectedTab {
                case .installed:
                    installedModelsList
                case .catalog:
                    catalogList
                case .coreML:
                    coreMLModelsList
                }
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle("Models")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showCustomURLSheet = true
                    } label: {
                        Label("URL Download", systemImage: "link.badge.plus")
                    }
                    Button {
                        if viewModel.selectedTab == .coreML {
                            showCoreMLImporter = true
                        } else {
                            showGGUFImporter = true
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showGGUFImporter) {
                DocumentPickerView(contentTypes: [.item], allowsMultipleSelection: false) { urls in
                    if let first = urls.first { viewModel.importGGUF(from: first) }
                }
            }
            .sheet(isPresented: $showCoreMLImporter) {
                DocumentPickerView(contentTypes: [.folder], allowsMultipleSelection: false) { urls in
                    if let first = urls.first { viewModel.importCoreMLFolder(from: first) }
                }
            }
            .sheet(isPresented: $showCustomURLSheet) {
                NavigationStack {
                    Form {
                        Section("Direct GGUF Download URL") {
                            TextField("Display name (optional)", text: $viewModel.customDownloadName)
                            TextField("https://huggingface.co/.../model.gguf", text: $viewModel.customDownloadURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Section {
                            Text("HTTPS is required for remote downloads. The downloaded file's GGUF header and architecture compatibility are verified automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Download from URL")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCustomURLSheet = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Download") {
                                viewModel.startCustomDownload()
                                showCustomURLSheet = false
                            }
                            .disabled(viewModel.customDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $viewModel.memoryWarningPrompt) { prompt in
                NavigationStack {
                    List {
                        Section("Memory Requirement Warning") {
                            Text(prompt.report.notes)
                                .font(.subheadline)
                            LabeledContent("Estimated Required RAM", value: Formatters.bytes(prompt.report.estimatedRAMBytes))
                            LabeledContent("Available App Headroom", value: Formatters.bytes(prompt.report.availableHeadroomBytes))
                            LabeledContent("Selected Context Window", value: "\(coordinator.settings.localContextLength) tokens")
                        }
                        Section("Your Choice") {
                            Text("ZinoAgent will never silently downgrade your chosen model. You can proceed with loading '\(prompt.model.name)' or pick a smaller local alternative below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Load '\(prompt.model.name)' Anyway") {
                                viewModel.performLoad(prompt.model)
                            }
                            .foregroundStyle(ZinoTheme.statusWarning)
                        }
                        if !prompt.alternatives.isEmpty {
                            Section("Smaller Compatible Alternatives") {
                                ForEach(prompt.alternatives) { alt in
                                    Button {
                                        viewModel.performLoad(alt)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(alt.name).font(.subheadline.weight(.medium))
                                                Text("\(alt.quantization) • Est. \(Formatters.bytes(alt.estimatedRAMBytes))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text("Load").font(.caption.weight(.semibold))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Memory Check")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { viewModel.memoryWarningPrompt = nil }
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete Local Model?",
                isPresented: Binding(
                    get: { viewModel.pendingDeleteModel != nil },
                    set: { if !$0 { viewModel.pendingDeleteModel = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    if let m = viewModel.pendingDeleteModel {
                        viewModel.deleteModel(m)
                    }
                    viewModel.pendingDeleteModel = nil
                }
                Button("Cancel", role: .cancel) { viewModel.pendingDeleteModel = nil }
            } message: {
                Text("This permanently removes '\(viewModel.pendingDeleteModel?.name ?? "")' from ZinoAgent's app-managed model directory.")
            }
            .onAppear {
                viewModel.consumeHandoff()
                coordinator.modelRegistry.reload()
                coordinator.imageGenerationService.coreMLEngine.scanInstalledModels()
            }
        }
    }

    // MARK: - Active Engine Banner

    private var activeEngineBanner: some View {
        let res = coordinator.resourceMonitor.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch coordinator.offlineEngine.loadState {
                case .unloaded:
                    Label("Local Engine Idle (llama.cpp Metal)", systemImage: "cpu")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                case let .loading(name, progress):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading \(name) (\(Int(progress * 100))%)")
                            .font(.subheadline.weight(.semibold))
                        ProgressView(value: progress)
                    }
                case let .loaded(info):
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            StatusBadge("Loaded", icon: "checkmark.circle.fill", tint: ZinoTheme.statusPositive)
                            Text(info.modelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        Text("\(info.architecture.uppercased()) • ctx \(info.contextLength) • \(info.gpuOffloadEnabled ? "Metal GPU" : "CPU") • loaded in \(info.loadDurationMs)ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        viewModel.runBenchmark()
                    } label: {
                        if viewModel.isBenchmarking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Benchmark")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isBenchmarking)

                    Button("Unload", role: .destructive) {
                        viewModel.unloadActiveModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                case let .failed(err):
                    Label("Load failed: \(err)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ZinoTheme.statusCritical)
                    Spacer()
                }
            }

            HStack(spacing: 14) {
                Text("App RAM: \(Formatters.bytes(res.appFootprintBytes))")
                if res.availableHeadroomBytes > 0 {
                    Text("Headroom: \(Formatters.memory(res.availableHeadroomBytes))")
                }
                Text("Thermal: \(res.thermalLevel.displayName)")
                if let bench = viewModel.benchmarkResult {
                    Text("Prompt: \(Formatters.speed(bench.promptTokensPerSecond)) • Gen: \(Formatters.speed(bench.generationTokensPerSecond))")
                        .foregroundStyle(ZinoTheme.statusPositive)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ZinoTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(ZinoTheme.surfaceSecondary.opacity(0.6))
    }

    // MARK: - Installed Models

    private var installedModelsList: some View {
        List {
            if !coordinator.downloadManager.activeDownloads.isEmpty {
                Section("Active Downloads") {
                    ForEach(Array(coordinator.downloadManager.activeDownloads.values).sorted(by: { $0.name < $1.name })) { dl in
                        downloadRow(dl)
                    }
                }
            }

            if coordinator.modelRegistry.models.isEmpty {
                ContentUnavailableView {
                    Label("No Local GGUF Models", systemImage: "cpu")
                } description: {
                    Text("Import a GGUF file from Apple Files or download one from the Catalog tab to run AI completely offline.")
                } actions: {
                    HStack {
                        Button("Import GGUF") { showGGUFImporter = true }
                            .buttonStyle(.borderedProminent)
                        Button("Browse Catalog") { viewModel.selectedTab = .catalog }
                            .buttonStyle(.bordered)
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Installed GGUF Models (\(coordinator.modelRegistry.models.count))") {
                    ForEach(coordinator.modelRegistry.models) { model in
                        installedModelRow(model)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func installedModelRow(_ model: LocalModelRecord) -> some View {
        let isLoaded = coordinator.offlineEngine.loadedModel?.id == model.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline)
                    Text("\(model.architecture.uppercased()) • \(model.quantization) • \(model.parameterCountLabel) • \(Formatters.bytes(model.fileSizeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(
                    model.compatibilityStatus.displayName,
                    tint: badgeTint(for: model.compatibilityStatus)
                )
            }

            HStack(spacing: 12) {
                Label("Trained Ctx: \(Formatters.tokens(model.trainedContextLength))", systemImage: "text.alignleft")
                Label("Est. RAM: \(Formatters.bytes(model.estimatedRAMBytes))", systemImage: "memorychip")
                if model.hasChatTemplate {
                    Label("Chat Template", systemImage: "checkmark.bubble")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(model.compatibilityNotes)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                if isLoaded {
                    Button("Unload", role: .destructive) {
                        viewModel.unloadActiveModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Load into Memory") {
                        viewModel.requestLoad(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.compatibilityStatus.canAttemptLoad)
                }
                Spacer()
                Button(role: .destructive) {
                    viewModel.pendingDeleteModel = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Download Catalog

    private var catalogList: some View {
        List {
            if !coordinator.downloadManager.activeDownloads.isEmpty {
                Section("Downloads in Progress") {
                    ForEach(Array(coordinator.downloadManager.activeDownloads.values).sorted(by: { $0.name < $1.name })) { dl in
                        downloadRow(dl)
                    }
                }
            }

            Section("Recommended for 8 GB iPad Pro M2") {
                ForEach(ModelCatalog.curatedModels.filter(\.recommendedFor8GBiPad)) { entry in
                    catalogRow(entry)
                }
            }

            Section("High-Capacity Models (Tight on 8 GB RAM)") {
                ForEach(ModelCatalog.curatedModels.filter { !$0.recommendedFor8GBiPad }) { entry in
                    catalogRow(entry)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func catalogRow(_ entry: CatalogModelEntry) -> some View {
        let alreadyInstalled = coordinator.modelRegistry.models.contains { $0.filename == entry.filename }
        let activeDL = coordinator.downloadManager.activeDownloads[entry.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text("\(entry.family) • \(entry.parameterCountLabel) • \(entry.quantization) • \(Formatters.bytes(entry.approximateSizeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(entry.recommendedFor8GBiPad ? "8 GB Ready" : "High RAM", tint: entry.recommendedFor8GBiPad ? ZinoTheme.statusPositive : ZinoTheme.statusWarning)
            }

            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Speed: \(entry.speedRating)")
                Text("Quality: \(entry.intelligenceRating)")
                Text("Est. RAM: \(Formatters.bytes(entry.estimatedRAMBytes))")
                Text("Ctx: \(Formatters.tokens(entry.contextWindow))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            HStack {
                if alreadyInstalled {
                    StatusBadge("Downloaded", icon: "checkmark.circle.fill", tint: ZinoTheme.statusPositive)
                } else if let dl = activeDL {
                    Text("\(Int(dl.progress * 100))% • \(dl.state.rawValue.capitalized)")
                        .font(.caption.weight(.medium))
                } else {
                    Button {
                        viewModel.startCatalogDownload(entry)
                    } label: {
                        Label("Download GGUF", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func downloadRow(_ dl: ActiveModelDownload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dl.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(dl.progress * 100))%").font(.caption.monospacedDigit())
            }
            ProgressView(value: dl.progress)
            HStack {
                Text("\(Formatters.bytes(dl.bytesDownloaded)) / \(dl.totalBytes > 0 ? Formatters.bytes(dl.totalBytes) : "…")")
                if dl.bytesPerSecond > 0 {
                    Text("• \(Formatters.bytes(Int64(dl.bytesPerSecond)))/s")
                }
                Spacer()
                if dl.state == .downloading {
                    Button("Pause") { coordinator.downloadManager.pauseDownload(id: dl.id) }
                        .buttonStyle(.bordered).controlSize(.mini)
                } else if dl.state == .paused || dl.state == .failed {
                    Button("Resume") { coordinator.downloadManager.resumeDownload(id: dl.id) }
                        .buttonStyle(.borderedProminent).controlSize(.mini)
                }
                Button("Cancel", role: .destructive) { coordinator.downloadManager.cancelDownload(id: dl.id) }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let err = dl.errorMessage {
                Text(err).font(.caption2).foregroundStyle(ZinoTheme.statusCritical)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Core ML Image Models

    private var coreMLModelsList: some View {
        let engine = coordinator.imageGenerationService.coreMLEngine
        return List {
            Section {
                Text("Offline image generation uses Apple's Core ML Stable Diffusion runtime. Import a compiled Core ML resource folder containing TextEncoder.mlmodelc, Unet.mlmodelc (or UnetChunk1/2), VAEDecoder.mlmodelc, vocab.json, and merges.txt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.installedModels.isEmpty {
                ContentUnavailableView {
                    Label("No Core ML Image Models", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Optional: Import a compiled Core ML Stable Diffusion folder to generate images locally without internet access.")
                } actions: {
                    Button("Import Compiled Model Folder") { showCoreMLImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Installed Core ML Models") {
                    ForEach(engine.installedModels) { info in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(info.name).font(.headline)
                                Spacer()
                                StatusBadge(info.isValid ? (info.isSDXL ? "SDXL Ready" : "SD Ready") : "Incomplete", tint: info.isValid ? ZinoTheme.statusPositive : ZinoTheme.statusCritical)
                            }
                            Text("Native: \(info.nativeSize)×\(info.nativeSize) • Disk: \(Formatters.bytes(info.diskSizeBytes)) • Est. RAM: \(Formatters.bytes(info.estimatedRAMBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !info.missingComponents.isEmpty {
                                Text("Missing: \(info.missingComponents.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(ZinoTheme.statusCritical)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func badgeTint(for status: ModelCompatibilityStatus) -> Color {
        switch status {
        case .compatible: return ZinoTheme.statusPositive
        case .warningHighMemory: return ZinoTheme.statusWarning
        case .incompatibleArchitecture, .splitShardIncomplete, .corruptOrInvalid: return ZinoTheme.statusCritical
        }
    }

    private func bannerBar(_ text: String, isError: Bool, dismissAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? ZinoTheme.statusCritical : ZinoTheme.statusPositive)
            Text(text).font(.caption).lineLimit(3)
            Spacer()
            Button(action: dismissAction) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((isError ? ZinoTheme.statusCritical : ZinoTheme.statusPositive).opacity(0.10))
    }
}
