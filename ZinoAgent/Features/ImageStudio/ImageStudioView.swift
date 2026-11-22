import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct ImageStudioView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewModel: ImageStudioViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showCoreMLImporter = false

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: ImageStudioViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    HStack(spacing: 0) {
                        controlsPane
                            .frame(width: 360)
                        Divider()
                        previewAndHistoryPane
                    }
                } else {
                    ScrollView {
                        VStack(spacing: ZinoTheme.Spacing.md) {
                            previewCanvas
                            controlsContent
                            historyStrip
                        }
                        .padding(ZinoTheme.Spacing.md)
                    }
                }
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle("Image Studio")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.sendPromptToAIChatForHelp()
                    } label: {
                        Label("Prompt Helper", systemImage: "sparkles")
                    }
                    if viewModel.selectedRecord != nil {
                        Button {
                            viewModel.saveSelectedToPhotos()
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            viewModel.exportSelected()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCoreMLImporter) {
                DocumentPickerView(contentTypes: [.folder], allowsMultipleSelection: false) { urls in
                    if let first = urls.first { viewModel.importCoreMLModel(from: first) }
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.shareURL != nil },
                set: { if !$0 { viewModel.shareURL = nil } }
            )) {
                if let url = viewModel.shareURL {
                    ShareSheetView(activityItems: [url])
                }
            }
            .onAppear {
                viewModel.syncDefaultProvider()
                coordinator.imageGenerationService.coreMLEngine.scanInstalledModels()
            }
        }
    }

    private var controlsPane: some View {
        ScrollView {
            controlsContent
                .padding(ZinoTheme.Spacing.md)
        }
        .background(ZinoTheme.surfaceSecondary.opacity(0.35))
    }

    private var controlsContent: some View {
        let caps = viewModel.currentCapabilities
        return VStack(alignment: .leading, spacing: ZinoTheme.Spacing.md) {
            Picker("Engine", selection: $viewModel.mode) {
                ForEach(ImageGenerationMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(ZinoTheme.statusCritical)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ZinoTheme.statusCritical.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(ZinoTheme.statusPositive)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ZinoTheme.statusPositive.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if viewModel.mode == .online {
                onlineProviderControls
            } else {
                offlineCoreMLControls
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").font(.subheadline.weight(.semibold))
                TextEditor(text: $viewModel.prompt)
                    .frame(minHeight: 95)
                    .padding(8)
                    .background(ZinoTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(ZinoTheme.border, lineWidth: 0.75))
            }

            if caps.supportsNegativePrompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Negative Prompt").font(.subheadline.weight(.semibold))
                    TextField("Elements to avoid...", text: $viewModel.negativePrompt)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if !caps.supportedSizes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dimensions").font(.subheadline.weight(.semibold))
                    Picker("Size", selection: $viewModel.selectedSizeIndex) {
                        ForEach(Array(caps.supportedSizes.enumerated()), id: \.offset) { idx, item in
                            Text(item.label).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            if caps.supportsQualitySelector && !caps.qualityOptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quality").font(.subheadline.weight(.semibold))
                    Picker("Quality", selection: $viewModel.selectedQuality) {
                        ForEach(caps.qualityOptions, id: \.self) { q in
                            Text(q.capitalized).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if caps.supportsStepsAndGuidance {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Inference Steps: \(viewModel.steps)", value: $viewModel.steps, in: 5...60, step: 5)
                    HStack {
                        Text("Guidance Scale: \(String(format: "%.1f", viewModel.guidanceScale))")
                            .font(.subheadline)
                        Slider(value: $viewModel.guidanceScale, in: 1.0...15.0, step: 0.5)
                    }
                }
            }

            if caps.supportsSeed {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Random Seed", isOn: $viewModel.useRandomSeed)
                    if !viewModel.useRandomSeed {
                        TextField("Seed", text: $viewModel.customSeedText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if viewModel.isGenerating {
                VStack(spacing: 8) {
                    if viewModel.mode == .offlineCoreML && coordinator.imageGenerationService.coreMLEngine.progressTotalSteps > 0 {
                        let step = coordinator.imageGenerationService.coreMLEngine.progressStep
                        let total = coordinator.imageGenerationService.coreMLEngine.progressTotalSteps
                        ProgressView(value: Double(step), total: Double(total))
                        Text("Core ML Step \(step) / \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Generating image...")
                    }
                    Button("Cancel Generation", role: .destructive) {
                        viewModel.cancelGeneration()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    viewModel.generate()
                } label: {
                    Label("Generate Image", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var onlineProviderControls: some View {
        if viewModel.imageCapableProviders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No Online Image Provider Configured")
                    .font(.subheadline.weight(.semibold))
                Text("Add OpenAI, Google Gemini, or an OpenAI-compatible server in Settings > AI Providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Configure Provider") {
                    coordinator.openProviderSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .zinoCard()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Provider", selection: Binding(
                    get: { viewModel.selectedProvider?.id ?? "" },
                    set: { newID in
                        viewModel.selectedProviderID = newID
                        viewModel.selectedModelID = viewModel.availableOnlineModels.first ?? ""
                        viewModel.selectedSizeIndex = 0
                        viewModel.selectedQuality = viewModel.currentCapabilities.qualityOptions.first ?? ""
                    }
                )) {
                    ForEach(viewModel.imageCapableProviders) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Model", selection: $viewModel.selectedModelID) {
                    ForEach(viewModel.availableOnlineModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var offlineCoreMLControls: some View {
        let engine = coordinator.imageGenerationService.coreMLEngine
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Core ML Local Model").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Import Folder") { showCoreMLImporter = true }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

            if let loaded = engine.loadedModel {
                HStack {
                    StatusBadge("Loaded: \(loaded.name)", icon: "checkmark.circle.fill", tint: ZinoTheme.statusPositive)
                    Spacer()
                    Button("Unload", role: .destructive) { viewModel.unloadCoreMLModel() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            } else if engine.installedModels.isEmpty {
                Text("No compiled Core ML Stable Diffusion models imported. Offline image generation is optional and independent from offline text chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.installedModels) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name).font(.caption.weight(.semibold))
                            Text("\(m.nativeSize)×\(m.nativeSize) • Est. \(Formatters.bytes(m.estimatedRAMBytes))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(engine.isLoading ? "Loading…" : "Load") {
                            viewModel.loadCoreMLModel(m)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(engine.isLoading || !m.isValid)
                    }
                }
            }
        }
        .zinoCard()
    }

    private var previewAndHistoryPane: some View {
        VStack(spacing: 0) {
            previewCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            historyStrip
                .frame(height: 150)
                .padding(.horizontal, ZinoTheme.Spacing.md)
                .padding(.vertical, 10)
        }
    }

    private var previewCanvas: some View {
        Group {
            if let rec = viewModel.selectedRecord,
               let uiImg = UIImage(contentsOfFile: coordinator.imageGenerationService.imageURL(for: rec).path) {
                VStack(spacing: 10) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .padding()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.prompt)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            Text("\(rec.providerName) • \(rec.modelName) • \(rec.width)×\(rec.height)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.deleteRecord(rec)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, ZinoTheme.Spacing.md)
                    .padding(.bottom, 10)
                }
            } else {
                ContentUnavailableView(
                    "Image Canvas",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Enter a prompt and generate an image using a configured online provider or a local Core ML Stable Diffusion model.")
                )
            }
        }
    }

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Generation History (\(coordinator.imageGenerationService.history.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if coordinator.imageGenerationService.history.isEmpty {
                Text("Generated images will appear here and persist locally.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(coordinator.imageGenerationService.history) { item in
                            let selected = viewModel.selectedRecord?.id == item.id
                            Button {
                                viewModel.selectedRecord = item
                            } label: {
                                if let img = UIImage(contentsOfFile: coordinator.imageGenerationService.imageURL(for: item).path) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(selected ? Color.accentColor : ZinoTheme.border, lineWidth: selected ? 2.5 : 0.75)
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
