import SwiftUI

/// Right-side AI Workspace Dock visible exclusively inside AI Chat.
/// Hosts Browser (with Local HTTP Server & RAM-only screenshots), Terminal, Skills, and Plugins (GitHub & Cloudflare).
public struct AIChatWorkspaceDock: View {
    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace Tool", selection: $coordinator.activeChatRightDockTab) {
                ForEach(AIChatRightDockTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.iconName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ZinoTheme.surfaceSecondary.opacity(0.6))

            Divider()

            Group {
                switch coordinator.activeChatRightDockTab {
                case .browser:
                    BrowserStudioView(coordinator: coordinator)
                case .terminal:
                    TerminalView(coordinator: coordinator)
                case .skills:
                    SkillsPluginsView(coordinator: coordinator, displayMode: .skillsOnly)
                case .plugins:
                    SkillsPluginsView(coordinator: coordinator, displayMode: .pluginsOnly)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ZinoTheme.surfacePrimary)
    }
}
