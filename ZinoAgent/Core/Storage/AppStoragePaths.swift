import Foundation

public struct StorageBreakdown: Sendable, Equatable {
    public let localModelsBytes: Int64
    public let diffusionModelsBytes: Int64
    public let generatedImagesBytes: Int64
    public let threeDProjectsBytes: Int64
    public let databaseBytes: Int64
    public let cacheBytes: Int64
    public let deviceAvailableBytes: Int64
    public let deviceTotalBytes: Int64

    public var totalManagedBytes: Int64 {
        localModelsBytes + diffusionModelsBytes + generatedImagesBytes + threeDProjectsBytes + databaseBytes + cacheBytes
    }
}

/// Manages all app-owned storage directories. Large model weights and media live on disk outside SQLite.
public final class AppStoragePaths: Sendable {
    public let rootDirectory: URL
    public let databaseDirectory: URL
    public let localModelsDirectory: URL
    public let diffusionModelsDirectory: URL
    public let generatedImagesDirectory: URL
    public let threeDProjectsDirectory: URL
    public let exportsDirectory: URL
    public let cacheDirectory: URL
    public let tempDirectory: URL

    public init(baseURL: URL? = nil, cacheBaseURL: URL? = nil) {
        let fm = FileManager.default
        let appSupport = baseURL ?? (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZinoAgent", isDirectory: true))
        let caches = cacheBaseURL ?? (fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZinoAgent", isDirectory: true))

        self.rootDirectory = appSupport
        self.databaseDirectory = appSupport.appendingPathComponent("Database", isDirectory: true)
        self.localModelsDirectory = appSupport.appendingPathComponent("Models/GGUF", isDirectory: true)
        self.diffusionModelsDirectory = appSupport.appendingPathComponent("Models/CoreMLDiffusion", isDirectory: true)
        self.generatedImagesDirectory = appSupport.appendingPathComponent("GeneratedImages", isDirectory: true)
        self.threeDProjectsDirectory = appSupport.appendingPathComponent("ThreeDProjects", isDirectory: true)
        self.exportsDirectory = appSupport.appendingPathComponent("Exports", isDirectory: true)
        self.cacheDirectory = caches
        self.tempDirectory = caches.appendingPathComponent("Temp", isDirectory: true)

        ensureDirectoriesExist()
    }

    public func ensureDirectoriesExist() {
        let fm = FileManager.default
        let dirs = [
            rootDirectory, databaseDirectory, localModelsDirectory, diffusionModelsDirectory,
            generatedImagesDirectory, threeDProjectsDirectory, exportsDirectory, cacheDirectory, tempDirectory
        ]
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Exclude large downloaded models from iCloud backup per Apple guidelines.
        var modelDir = localModelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? modelDir.setResourceValues(values)
        var diffDir = diffusionModelsDirectory
        try? diffDir.setResourceValues(values)
    }

    public var databaseFileURL: URL {
        databaseDirectory.appendingPathComponent("zinoagent.sqlite3")
    }

    public func computeStorageBreakdown() -> StorageBreakdown {
        let volume = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return StorageBreakdown(
            localModelsBytes: Self.directorySize(at: localModelsDirectory),
            diffusionModelsBytes: Self.directorySize(at: diffusionModelsDirectory),
            generatedImagesBytes: Self.directorySize(at: generatedImagesDirectory),
            threeDProjectsBytes: Self.directorySize(at: threeDProjectsDirectory),
            databaseBytes: Self.directorySize(at: databaseDirectory),
            cacheBytes: Self.directorySize(at: cacheDirectory),
            deviceAvailableBytes: volume?.volumeAvailableCapacityForImportantUsage ?? 0,
            deviceTotalBytes: Int64(volume?.volumeTotalCapacity ?? 0)
        )
    }

    /// Safely clears only caches and temporary files; never touches user models, projects, or database.
    @discardableResult
    public func clearSafeCaches() throws -> Int64 {
        let before = Self.directorySize(at: cacheDirectory)
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
        ensureDirectoriesExist()
        let after = Self.directorySize(at: cacheDirectory)
        return max(0, before - after)
    }

    public static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
