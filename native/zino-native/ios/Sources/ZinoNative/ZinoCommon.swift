import Foundation
import CryptoKit
import Capacitor

/// Error type shared by all ZinoAgent plugins. `code` is a stable machine-readable string
/// that the TypeScript layer maps to user-facing messages and recovery actions.
struct ZinoError: Error, LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    var errorDescription: String? { message }
}

extension CAPPluginCall {
    /// Reject with a ZinoError code when available, otherwise a generic NATIVE_ERROR.
    func zinoReject(_ error: Error) {
        if let z = error as? ZinoError {
            reject(z.message, z.code, z)
        } else if (error as NSError).domain == NSCocoaErrorDomain {
            reject(error.localizedDescription, "FILE_SYSTEM_ERROR", error)
        } else {
            reject(error.localizedDescription, "NATIVE_ERROR", error)
        }
    }
}

/// App-private storage. Everything ZinoAgent owns (models, assets, database, temp files)
/// lives under Application Support/ZinoAgent, which is not visible in the Files app.
enum ZinoPaths {
    static let rootName = "ZinoAgent"

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(rootName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Models and generated media are large and re-downloadable/re-creatable on demand.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
        }
        return url
    }

    static var tmp: URL {
        let url = root.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolve an app-relative path ("models/chat/x.gguf") to an absolute URL, refusing any
    /// path that would escape the app storage root (absolute paths, "..", symlink tricks).
    static func resolve(_ relative: String) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return root }
        if trimmed.hasPrefix("/") || trimmed.contains("\0") {
            throw ZinoError("INVALID_PATH", "Path must be relative to app storage.")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == ".." || $0 == "." }) {
            throw ZinoError("INVALID_PATH", "Path must not contain '.' or '..' components.")
        }
        // "." / ".." and absolute paths are rejected above; ZinoAgent never creates symlinks
        // inside its own storage, so a standardized prefix check is sufficient here.
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path.hasPrefix(rootPath + "/") else {
            throw ZinoError("PATH_OUTSIDE_STORAGE", "Path resolves outside app storage.")
        }
        return url
    }

    static func relative(_ url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath + "/") {
            return String(p.dropFirst(rootPath.count + 1))
        }
        return p
    }

    static func ensureParent(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func availableCapacity() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }
}

enum ZinoHash {
    /// Streaming SHA-256 so multi-gigabyte model files never need to fit in memory.
    static func sha256(of url: URL, chunkSize: Int = 8 * 1024 * 1024, shouldCancel: (() -> Bool)? = nil) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZinoError("FILE_NOT_FOUND", "Cannot open file for hashing.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if shouldCancel?() == true { throw ZinoError("CANCELLED", "Hashing cancelled.") }
            let data = try autoreleasepool { () throws -> Data in
                return try handle.read(upToCount: chunkSize) ?? Data()
            }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ZinoFS {
    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    static func iso(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return ISO8601DateFormatter().string(from: date)
    }
}

/// Incremental UTF-8 decoder: holds back incomplete multi-byte sequences between chunks.
struct UTF8Accumulator {
    private var pending = Data()

    mutating func append(_ data: Data) -> String {
        pending.append(data)
        if let s = String(data: pending, encoding: .utf8) {
            pending.removeAll(keepingCapacity: true)
            return s
        }
        // Try holding back up to 3 trailing bytes (an incomplete code point).
        for cut in 1...3 where pending.count > cut {
            let head = pending.prefix(pending.count - cut)
            if let s = String(data: head, encoding: .utf8) {
                pending = Data(pending.suffix(cut))
                return s
            }
        }
        if pending.count > 16 {
            // Not valid UTF-8 at all: decode lossily so the stream never stalls.
            let s = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return s
        }
        return ""
    }

    mutating func flush() -> String {
        defer { pending.removeAll() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }
}
