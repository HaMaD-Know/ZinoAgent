import SwiftUI

/// Primary 7 application sections for iPad sidebar and iPhone compact navigation.
/// Browser, Terminal, Skills, and Plugins live exclusively in the right-side workspace dock inside AI Chat.
public enum NavigationSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case home
    case files
    case aiChat
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
        case .aiChat: return "Assistant, Browser, Terminal, Skills & Plugins"
        case .threeDStudio: return "Interactive 3D inspection"
        case .imageStudio: return "Image generation studio"
        case .models: return "Local GGUF & Core ML models"
        case .settings: return "Preferences, providers & privacy"
        }
    }
}

/// Tabs hosted exclusively inside the right-side Workspace Dock of AI Chat.
public enum AIChatRightDockTab: String, CaseIterable, Identifiable, Sendable {
    case browser = "Browser"
    case terminal = "Terminal"
    case skills = "Skills"
    case plugins = "Plugins"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .browser: return "globe"
        case .terminal: return "terminal"
        case .skills: return "sparkles"
        case .plugins: return "puzzlepiece.extension"
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
