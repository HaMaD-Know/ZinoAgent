import Foundation

/// Typed application error with user-facing descriptions, recovery guidance, and automatic secret scrubbing.
public struct ZinoError: LocalizedError, Sendable, Equatable {
    public enum Code: String, Sendable, Codable {
        case invalidArgument
        case permissionDenied
        case bookmarkStale
        case pathOutOfScope
        case fileNotFound
        case fileAlreadyExists
        case unsupportedFormat
        case ioFailure
        case databaseFailure
        case keychainFailure
        case networkFailure
        case authenticationFailure
        case providerNotConfigured
        case modelNotLoaded
        case modelLoadFailed
        case incompatibleModel
        case insufficientMemory
        case contextFull
        case inferenceFailed
        case cancelled
        case consentRequired
        case toolRejected
        case unknown
    }

    public let code: Code
    public let message: String
    public let recoverySuggestionText: String?

    public init(_ code: Code, _ message: String, recovery: String? = nil) {
        self.code = code
        self.message = SecretRedactor.redact(message)
        self.recoverySuggestionText = recovery.map { SecretRedactor.redact($0) }
    }

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recoverySuggestionText }
}

/// Scrubs bearer tokens, common API key prefixes, and user-registered secrets from logs and error strings.
public enum SecretRedactor {
    private static let lock = NSLock()
    private static var registeredSecrets: Set<String> = []

    public static func register(secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return }
        lock.lock()
        registeredSecrets.insert(trimmed)
        lock.unlock()
    }

    public static func unregister(secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        registeredSecrets.remove(trimmed)
        lock.unlock()
    }

    public static func redact(_ input: String) -> String {
        var output = input
        lock.lock()
        let secrets = registeredSecrets
        lock.unlock()

        for secret in secrets where !secret.isEmpty {
            output = output.replacingOccurrences(of: secret, with: "[REDACTED]")
        }

        let patterns = [
            "(?i)(Bearer\\s+)[A-Za-z0-9._\\-]{10,}",
            "sk-[A-Za-z0-9_\\-]{16,}",
            "sk-ant-[A-Za-z0-9_\\-]{16,}",
            "AIza[0-9A-Za-z_\\-]{20,}",
            "(?i)(x-api-key[\"':=\\s]+)[A-Za-z0-9._\\-]{10,}"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "[REDACTED]")
            }
        }
        return output
    }
}
