import SwiftUI

/// Adaptive root navigation shell:
/// - iPad / Regular width: Collapsible `NavigationSplitView` sidebar + spacious workspace detail pane.
/// - iPhone / Compact width / iPad narrow Split View: Adaptive compact `TabView` preserving state across switches.
public struct RootNavigationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadSidebarLayout
            } else {
                compactTabLayout
            }
        }
        .overlay(alignment: .top) {
            if let banner = coordinator.systemBannerMessage {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(ZinoTheme.statusInfo)
                    Text(banner)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        coordinator.systemBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZinoTheme.border, lineWidth: 0.75))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.systemBannerMessage)
    }

    private var iPadSidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding<NavigationSection?>(
                get: { coordinator.selectedSection },
                set: { if let v = $0 { coordinator.selectedSection = v } }
            )) {
                Section {
                    ForEach(NavigationSection.allCases) { section in
                        Label(section.title, systemImage: section.iconName)
                            .tag(section)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .foregroundStyle(Color.accentColor)
                        Text("ZinoAgent 2.0")
                            .font(.headline)
                            .textCase(nil)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Live Status") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            StatusBadge(
                                coordinator.settings.defaultAIMode.shortName,
                                icon: coordinator.settings.defaultAIMode.iconName,
                                tint: coordinator.settings.defaultAIMode == .offline ? ZinoTheme.statusPositive : ZinoTheme.statusInfo
                            )
                            Spacer()
                            if coordinator.resourceMonitor.snapshot.thermalLevel.isElevated {
                                StatusBadge(
                                    coordinator.resourceMonitor.snapshot.thermalLevel.displayName,
                                    icon: "thermometer.high",
                                    tint: ZinoTheme.statusWarning
                                )
                            }
                        }
                        Text(coordinator.activeModelDisplayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        let headroom = coordinator.resourceMonitor.snapshot.availableHeadroomBytes
                        if headroom > 0 {
                            Text("RAM Headroom: \(Formatters.memory(headroom))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Workspace")
            .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 290)
        } detail: {
            sectionView(for: coordinator.selectedSection)
        }
    }

    private var compactTabLayout: some View {
        TabView(selection: $coordinator.selectedSection) {
            HomeView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.home.title, systemImage: NavigationSection.home.iconName) }
                .tag(NavigationSection.home)

            FileManagerView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.files.title, systemImage: NavigationSection.files.iconName) }
                .tag(NavigationSection.files)

            AIChatView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.aiChat.title, systemImage: NavigationSection.aiChat.iconName) }
                .tag(NavigationSection.aiChat)

            ThreeDStudioView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.threeDStudio.title, systemImage: NavigationSection.threeDStudio.iconName) }
                .tag(NavigationSection.threeDStudio)

            ImageStudioView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.imageStudio.title, systemImage: NavigationSection.imageStudio.iconName) }
                .tag(NavigationSection.imageStudio)

            ModelManagerView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.models.title, systemImage: NavigationSection.models.iconName) }
                .tag(NavigationSection.models)

            SettingsView(coordinator: coordinator)
                .tabItem { Label(NavigationSection.settings.title, systemImage: NavigationSection.settings.iconName) }
                .tag(NavigationSection.settings)
        }
    }

    @ViewBuilder
    private func sectionView(for section: NavigationSection) -> some View {
        switch section {
        case .home:
            HomeView(coordinator: coordinator)
        case .files:
            FileManagerView(coordinator: coordinator)
        case .aiChat:
            AIChatView(coordinator: coordinator)
        case .threeDStudio:
            ThreeDStudioView(coordinator: coordinator)
        case .imageStudio:
            ImageStudioView(coordinator: coordinator)
        case .models:
            ModelManagerView(coordinator: coordinator)
        case .settings:
            SettingsView(coordinator: coordinator)
        }
    }
}
