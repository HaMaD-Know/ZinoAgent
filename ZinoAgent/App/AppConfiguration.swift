import Foundation

/// Static build and product configuration for ZinoAgent 2.0.
public enum AppConfiguration {
    public static let appName = "ZinoAgent"
    public static let version = "2.0.0"
    public static let buildNumber = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    public static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.zinoagent.app"

    public static let maintenanceBackgroundTaskID = "com.zinoagent.app.maintenance"
    public static let modelCleanupBackgroundTaskID = "com.zinoagent.app.model-cleanup"

    /// Target hardware profile used for conservative memory guidance when live headroom is unavailable (e.g. simulator).
    public static let targetDeviceDescription = "iPad Pro M2 (8 GB RAM, Apple Silicon, Metal)"
    public static let safeMemoryHeadroomReserveBytes: Int64 = 1_100_000_000 // ~1.1 GB reserve for iPadOS + UI

    public static let openSourceLicenses: [(name: String, license: String, url: String)] = [
        ("llama.cpp", "MIT License", "https://github.com/ggml-org/llama.cpp"),
        ("Apple ml-stable-diffusion", "MIT License", "https://github.com/apple/ml-stable-diffusion"),
        ("ZIPFoundation", "MIT License", "https://github.com/weichsel/ZIPFoundation"),
        ("SQLite", "Public Domain", "https://www.sqlite.org")
    ]
}
