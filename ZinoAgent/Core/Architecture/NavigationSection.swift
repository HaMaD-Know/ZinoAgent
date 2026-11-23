import SwiftUI

/// Primary application sections for iPad sidebar and iPhone compact navigation.
public enum NavigationSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case home
    case files
    case aiChat
    case browser
    case terminal
    case skillsAndPlugins
    case threeDStudio
    case imageStudio
    case models
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .files: return "Files"
        case .aiChat: return "AI Chat"
        case .browser: return "Browser"
        case .terminal: return "Terminal"
        case .skillsAndPlugins: return "Skills & Plugins"
        case .threeDStudio: return "3D Studio"
        case .imageStudio: return "Image Studio"
        case .models: return "Models"
        case .settings: return "Settings"
        }
    }

    public var iconName: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .files: return "folder"
        case .aiChat: return "bubble.left.and.text.bubble.right"
        case .browser: return "globe"
        case .terminal: return "terminal"
        case .skillsAndPlugins: return "puzzlepiece.extension"
        case .threeDStudio: return "cube"
        case .imageStudio: return "photo.on.rectangle.angled"
        case .models: return "cpu"
        case .settings: return "gearshape"
        }
    }

    public var subtitle: String {
        switch self {
        case .home: return "Workspace overview"
        case .files: return "Selected folders & operations"
        case .aiChat: return "Offline & online assistant"
        case .browser: return "Live server & ephemeral AI vision"
        case .terminal: return "Workspace shell, JS runtime & CLI"
        case .skillsAndPlugins: return "AI skills, GitHub & Cloudflare"
        case .threeDStudio: return "Interactive 3D inspection"
        case .imageStudio: return "Image generation studio"
        case .models: return "Local GGUF & Core ML models"
        case .settings: return "Preferences, providers & privacy"
        }
    }
}

public enum AppAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
