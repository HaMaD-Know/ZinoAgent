import Foundation
import Combine

/// Persisted application settings across General, AI, Local Models, SmartContextEngine, Files, Privacy, and 3D Studio.
@MainActor
public final class SettingsManager: ObservableObject {
    private let database: AppDatabase

    // General
    @Published public var appearance: AppAppearance = .system { didSet { persist("appearance", appearance.rawValue) } }
    @Published public var defaultSection: NavigationSection = .home { didSet { persist("defaultSection", defaultSection.rawValue) } }
    @Published public var preferredLanguageCode: String = Locale.current.language.languageCode?.identifier ?? "en" {
        didSet { persist("preferredLanguageCode", preferredLanguageCode) }
    }

    // AI
    @Published public var defaultAIMode: AIMode = .offline { didSet { persist("defaultAIMode", defaultAIMode.rawValue) } }
    @Published public var temperature: Double = 0.7 { didSet { persist("temperature", String(temperature)) } }
    @Published public var topP: Double = 0.95 { didSet { persist("topP", String(topP)) } }
    @Published public var maxGenerationTokens: Int = 2048 { didSet { persist("maxGenerationTokens", String(maxGenerationTokens)) } }
    @Published public var defaultSystemPrompt: String = GenerationConfig().systemPrompt {
        didSet { persist("defaultSystemPrompt", defaultSystemPrompt) }
    }

    // Local Models
    @Published public var localContextLength: Int = 4096 { didSet { persist("localContextLength", String(localContextLength)) } }
    @Published public var useMetalGPUOffload: Bool = true { didSet { persist("useMetalGPUOffload", String(useMetalGPUOffload)) } }
    @Published public var autoUnloadOnMemoryWarning: Bool = true { didSet { persist("autoUnloadOnMemoryWarning", String(autoUnloadOnMemoryWarning)) } }
    @Published public var thermalNotificationsEnabled: Bool = true { didSet { persist("thermalNotificationsEnabled", String(thermalNotificationsEnabled)) } }

    // SmartContextEngine defaults (per specification)
    @Published public var adaptiveBatchingEnabled: Bool = true { didSet { persist("adaptiveBatchingEnabled", String(adaptiveBatchingEnabled)) } }
    @Published public var smartHistoryRetrievalEnabled: Bool = true { didSet { persist("smartHistoryRetrievalEnabled", String(smartHistoryRetrievalEnabled)) } }
    @Published public var preserveOriginalMessages: Bool = true { didSet { persist("preserveOriginalMessages", String(preserveOriginalMessages)) } }
    @Published public var summaryVerificationEnabled: Bool = true { didSet { persist("summaryVerificationEnabled", String(summaryVerificationEnabled)) } }
    @Published public var baselineContextTarget: Int = 4096 { didSet { persist("baselineContextTarget", String(baselineContextTarget)) } }
    @Published public var initialMessageBatchTarget: Int = 5 { didSet { persist("initialMessageBatchTarget", String(initialMessageBatchTarget)) } }
    @Published public var maxRetrievedMessages: Int = 8 { didSet { persist("maxRetrievedMessages", String(maxRetrievedMessages)) } }

    // Files
    @Published public var defaultFileViewMode: String = "grid" { didSet { persist("defaultFileViewMode", defaultFileViewMode) } }
    @Published public var defaultFileSort: String = "name" { didSet { persist("defaultFileSort", defaultFileSort) } }
    @Published public var aiFilePermissionLevel: AIPermissionLevel = .confirm { didSet { persist("aiFilePermissionLevel", aiFilePermissionLevel.rawValue) } }

    // 3D Studio
    @Published public var threeDLightingPreset: String = "studio" { didSet { persist("threeDLightingPreset", threeDLightingPreset) } }
    @Published public var threeDEnvironmentPreset: String = "darkStudio" { didSet { persist("threeDEnvironmentPreset", threeDEnvironmentPreset) } }
    @Published public var threeDShowGrid: Bool = true { didSet { persist("threeDShowGrid", String(threeDShowGrid)) } }
    @Published public var threeDLargeFileWarningMB: Int = 100 { didSet { persist("threeDLargeFileWarningMB", String(threeDLargeFileWarningMB)) } }

    // Privacy
    @Published public var requireConsentBeforeOnlineFileUpload: Bool = true {
        didSet { persist("requireConsentBeforeOnlineFileUpload", String(requireConsentBeforeOnlineFileUpload)) }
    }

    private var isLoading = false

    public init(database: AppDatabase) {
        self.database = database
        load()
    }

    public var generationConfig: GenerationConfig {
        GenerationConfig(
            temperature: temperature,
            topP: topP,
            topK: 40,
            repeatPenalty: 1.1,
            maxTokens: maxGenerationTokens,
            systemPrompt: defaultSystemPrompt
        )
    }

    public func load() {
        isLoading = true
        defer { isLoading = false }
        guard let all = try? database.allSettings() else { return }

        if let v = all["appearance"], let parsed = AppAppearance(rawValue: v) { appearance = parsed }
        if let v = all["defaultSection"], let parsed = NavigationSection(rawValue: v) { defaultSection = parsed }
        if let v = all["preferredLanguageCode"] { preferredLanguageCode = v }

        if let v = all["defaultAIMode"], let parsed = AIMode(rawValue: v) { defaultAIMode = parsed }
        if let v = all["temperature"], let parsed = Double(v) { temperature = parsed }
        if let v = all["topP"], let parsed = Double(v) { topP = parsed }
        if let v = all["maxGenerationTokens"], let parsed = Int(v) { maxGenerationTokens = parsed }
        if let v = all["defaultSystemPrompt"] { defaultSystemPrompt = v }

        if let v = all["localContextLength"], let parsed = Int(v) { localContextLength = parsed }
        if let v = all["useMetalGPUOffload"] { useMetalGPUOffload = (v == "true") }
        if let v = all["autoUnloadOnMemoryWarning"] { autoUnloadOnMemoryWarning = (v == "true") }
        if let v = all["thermalNotificationsEnabled"] { thermalNotificationsEnabled = (v == "true") }

        if let v = all["adaptiveBatchingEnabled"] { adaptiveBatchingEnabled = (v == "true") }
        if let v = all["smartHistoryRetrievalEnabled"] { smartHistoryRetrievalEnabled = (v == "true") }
        if let v = all["preserveOriginalMessages"] { preserveOriginalMessages = (v == "true") }
        if let v = all["summaryVerificationEnabled"] { summaryVerificationEnabled = (v == "true") }
        if let v = all["baselineContextTarget"], let parsed = Int(v) { baselineContextTarget = parsed }
        if let v = all["initialMessageBatchTarget"], let parsed = Int(v) { initialMessageBatchTarget = parsed }
        if let v = all["maxRetrievedMessages"], let parsed = Int(v) { maxRetrievedMessages = parsed }

        if let v = all["defaultFileViewMode"] { defaultFileViewMode = v }
        if let v = all["defaultFileSort"] { defaultFileSort = v }
        if let v = all["aiFilePermissionLevel"], let parsed = AIPermissionLevel(rawValue: v) { aiFilePermissionLevel = parsed }

        if let v = all["threeDLightingPreset"] { threeDLightingPreset = v }
        if let v = all["threeDEnvironmentPreset"] { threeDEnvironmentPreset = v }
        if let v = all["threeDShowGrid"] { threeDShowGrid = (v == "true") }
        if let v = all["threeDLargeFileWarningMB"], let parsed = Int(v) { threeDLargeFileWarningMB = parsed }

        if let v = all["requireConsentBeforeOnlineFileUpload"] { requireConsentBeforeOnlineFileUpload = (v == "true") }
    }

    public func exportDictionary() -> [String: String] {
        (try? database.allSettings()) ?? [:]
    }

    private func persist(_ key: String, _ value: String) {
        guard !isLoading else { return }
        do {
            try database.setSetting(key: key, value: value)
        } catch {
            AppLogger.shared.error("Settings", "Failed to persist setting '\(key)': \(error.localizedDescription)")
        }
    }
}
