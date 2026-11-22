import SwiftUI

public struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewModel: HomeViewModel

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: HomeViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZinoTheme.Spacing.lg) {
                    welcomeHeader
                    quickActionsSection

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320), spacing: ZinoTheme.Spacing.md)],
                        spacing: ZinoTheme.Spacing.md
                    ) {
                        aiStatusCard
                        storageOverviewCard
                    }

                    recentActivitySection
                }
                .padding(ZinoTheme.Spacing.lg)
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                viewModel.refresh()
            }
        }
    }

    // MARK: - Welcome Header

    private var welcomeHeader: some View {
        HStack(alignment: .center, spacing: ZinoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("ZinoAgent")
                        .font(.largeTitle.weight(.bold))
                    StatusBadge("2.0", tint: Color.accentColor)
                }
                Text("Offline-first AI file manager & personal workspace")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    StatusBadge(
                        coordinator.settings.defaultAIMode.displayName,
                        icon: coordinator.settings.defaultAIMode.iconName,
                        tint: coordinator.settings.defaultAIMode == .offline ? ZinoTheme.statusPositive : ZinoTheme.statusInfo
                    )
                    StatusBadge(
                        coordinator.activeModelDisplayName,
                        icon: "sparkles",
                        tint: .secondary
                    )
                    StatusBadge(
                        "Thermal: \(coordinator.resourceMonitor.snapshot.thermalLevel.displayName)",
                        icon: "thermometer.medium",
                        tint: coordinator.resourceMonitor.snapshot.thermalLevel.isElevated ? ZinoTheme.statusWarning : ZinoTheme.statusPositive
                    )
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .zinoCard()
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: ZinoTheme.Spacing.sm) {
            Text("Quick Actions")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 155), spacing: ZinoTheme.Spacing.sm)],
                spacing: ZinoTheme.Spacing.sm
            ) {
                quickActionButton(title: "Open Files", subtitle: "\(viewModel.mountedFolderCount) mounted", icon: "folder.fill", tint: .blue) {
                    coordinator.selectedSection = .files
                }
                quickActionButton(title: "New AI Chat", subtitle: coordinator.settings.defaultAIMode.shortName, icon: "plus.bubble.fill", tint: .indigo) {
                    coordinator.openNewChat()
                }
                quickActionButton(title: "Open 3D Model", subtitle: "GLB, USDZ, OBJ, STL", icon: "cube.fill", tint: .teal) {
                    coordinator.selectedSection = .threeDStudio
                }
                quickActionButton(title: "Generate Image", subtitle: "Online & Core ML", icon: "photo.on.rectangle.angled", tint: .purple) {
                    coordinator.selectedSection = .imageStudio
                }
                quickActionButton(title: "Download Model", subtitle: "\(coordinator.modelRegistry.models.count) local GGUF", icon: "arrow.down.circle.fill", tint: .green) {
                    coordinator.openModelCatalog()
                }
                quickActionButton(title: "Connect Provider", subtitle: "\(coordinator.providerRegistry.providers.count) configured", icon: "key.fill", tint: .orange) {
                    coordinator.openProviderSetup()
                }
            }
        }
    }

    private func quickActionButton(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(ZinoTheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: ZinoTheme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ZinoTheme.Radius.md).stroke(ZinoTheme.border, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    // MARK: - AI Status Card

    private var aiStatusCard: some View {
        let res = coordinator.resourceMonitor.snapshot
        let ctx = coordinator.smartContextEngine.latestSnapshot
        return VStack(alignment: .leading, spacing: ZinoTheme.Spacing.sm) {
            HStack {
                Label("AI Engine & Hardware", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                StatusBadge(
                    coordinator.settings.defaultAIMode.shortName,
                    tint: coordinator.settings.defaultAIMode == .offline ? ZinoTheme.statusPositive : ZinoTheme.statusInfo
                )
            }

            Divider()

            statusRow("Active Model", value: coordinator.activeModelDisplayName)
            statusRow("Local Engine State", value: localStateLabel)
            statusRow("SmartContext Usage", value: "\(Formatters.tokens(ctx.currentTokenCount)) / \(Formatters.tokens(ctx.effectiveCapacity)) tokens")
            statusRow("App RAM Footprint", value: Formatters.bytes(res.appFootprintBytes))
            if res.availableHeadroomBytes > 0 {
                statusRow("Available RAM Headroom", value: Formatters.memory(res.availableHeadroomBytes))
            }
            statusRow("Device RAM", value: Formatters.memory(res.physicalMemoryBytes))
        }
        .zinoCard()
    }

    private var localStateLabel: String {
        switch coordinator.offlineEngine.loadState {
        case .unloaded: return "Unloaded (Ready)"
        case let .loading(name, progress): return "Loading \(name) (\(Int(progress * 100))%)"
        case let .loaded(info): return "Loaded (\(info.gpuOffloadEnabled ? "Metal GPU" : "CPU"))"
        case let .failed(msg): return "Error: \(msg.prefix(32))"
        }
    }

    // MARK: - Storage Overview Card

    private var storageOverviewCard: some View {
        let s = coordinator.storageBreakdown
        return VStack(alignment: .leading, spacing: ZinoTheme.Spacing.sm) {
            HStack {
                Label("Storage Overview", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Text(Formatters.bytes(s.totalManagedBytes))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            statusRow("Downloaded Local Models (\(coordinator.modelRegistry.models.count))", value: Formatters.bytes(s.localModelsBytes))
            statusRow("Core ML Image Models", value: Formatters.bytes(s.diffusionModelsBytes))
            statusRow("Generated Images & 3D Projects", value: Formatters.bytes(s.generatedImagesBytes + s.threeDProjectsBytes))
            statusRow("Database", value: Formatters.bytes(s.databaseBytes))
            statusRow("Cache Usage", value: Formatters.bytes(s.cacheBytes))
            if s.deviceAvailableBytes > 0 {
                statusRow("Free Device Storage", value: Formatters.bytes(s.deviceAvailableBytes))
            }
        }
        .zinoCard()
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: ZinoTheme.Spacing.md) {
            Text("Recent Activity")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: ZinoTheme.Spacing.md)],
                spacing: ZinoTheme.Spacing.md
            ) {
                recentCard(title: "Recent Conversations", icon: "bubble.left.and.bubble.right", isEmpty: viewModel.recentConversations.isEmpty, emptyText: "No conversations yet. Start a new AI chat to begin.") {
                    ForEach(viewModel.recentConversations) { conv in
                        Button {
                            coordinator.selectedSection = .aiChat
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conv.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(conv.mode.shortName) • \(Formatters.relativeDate(conv.updatedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                recentCard(title: "Recently Opened Files", icon: "doc.text", isEmpty: viewModel.recentFiles.isEmpty, emptyText: "Select a folder in Files and open documents to see recent files here.") {
                    ForEach(viewModel.recentFiles) { item in
                        Button {
                            coordinator.selectedSection = .files
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(item.subtitle) • \(Formatters.relativeDate(item.openedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                recentCard(title: "Recent 3D Projects", icon: "cube", isEmpty: viewModel.recentThreeDProjects.isEmpty, emptyText: "Import a GLB, GLTF, USDZ, OBJ, or STL model in 3D Studio.") {
                    ForEach(viewModel.recentThreeDProjects) { proj in
                        Button {
                            coordinator.selectedSection = .threeDStudio
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proj.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(proj.format.displayName) • \(proj.meshCount) meshes • \(Formatters.bytes(proj.fileSizeBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                recentCard(title: "Recent Image Generations", icon: "photo", isEmpty: viewModel.recentImages.isEmpty, emptyText: "Generate images in Image Studio using an online provider or Core ML.") {
                    ForEach(viewModel.recentImages) { img in
                        Button {
                            coordinator.selectedSection = .imageStudio
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(img.prompt).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(img.modelName) • \(img.width)×\(img.height) • \(Formatters.relativeDate(img.createdAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recentCard<Content: View>(
        title: String,
        icon: String,
        isEmpty: Bool,
        emptyText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ZinoTheme.Spacing.xs) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Divider()
            if isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                content()
            }
        }
        .zinoCard()
    }
}
