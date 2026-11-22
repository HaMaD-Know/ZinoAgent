import Foundation
import os

public struct DiagnosticLogEntry: Identifiable, Sendable, Codable {
    public enum Level: String, Sendable, Codable {
        case debug, info, warning, error
    }

    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), category: String, level: Level, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = SecretRedactor.redact(message)
    }
}

/// Centralized structured logger with secret redaction and bounded in-memory ring buffer for diagnostics.
public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private let subsystem = "com.zinoagent.app"
    private let lock = NSLock()
    private var entries: [DiagnosticLogEntry] = []
    private let maxEntries = 400

    private init() {}

    public func log(_ level: DiagnosticLogEntry.Level, category: String, _ message: String) {
        let scrubbed = SecretRedactor.redact(message)
        let osLog = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: osLog.debug("\(scrubbed, privacy: .public)")
        case .info: osLog.info("\(scrubbed, privacy: .public)")
        case .warning: osLog.warning("\(scrubbed, privacy: .public)")
        case .error: osLog.error("\(scrubbed, privacy: .public)")
        }

        let entry = DiagnosticLogEntry(category: category, level: level, message: scrubbed)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
    }

    public func info(_ category: String, _ message: String) { log(.info, category: category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category: category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category: category, message) }
    public func debug(_ category: String, _ message: String) { log(.debug, category: category, message) }

    public func recentEntries(limit: Int = 100) -> [DiagnosticLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(limit).reversed())
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
