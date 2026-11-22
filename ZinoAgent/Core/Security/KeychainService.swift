import Foundation
import Security

public protocol KeychainStoring: Sendable {
    func setSecret(_ secret: String, forAccount account: String) throws
    func getSecret(forAccount account: String) -> String?
    func deleteSecret(forAccount account: String) throws
    func hasSecret(forAccount account: String) -> Bool
    func maskedHint(forAccount account: String) -> String?
}

/// Production iOS Keychain storage for provider API keys.
/// Secrets are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and registered with `SecretRedactor`.
public final class KeychainService: KeychainStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.zinoagent.credentials") {
        self.service = service
    }

    public func setSecret(_ secret: String, forAccount account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ZinoError(.invalidArgument, "Credential cannot be empty.")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ZinoError(.invalidArgument, "Credential could not be encoded as UTF-8.")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ZinoError(.keychainFailure, "Could not save credential to Keychain (OSStatus \(addStatus)).")
            }
        } else if status != errSecSuccess {
            throw ZinoError(.keychainFailure, "Could not update credential in Keychain (OSStatus \(status)).")
        }

        SecretRedactor.register(secret: trimmed)
    }

    public func getSecret(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        SecretRedactor.register(secret: secret)
        return secret
    }

    public func deleteSecret(forAccount account: String) throws {
        if let existing = getSecret(forAccount: account) {
            SecretRedactor.unregister(secret: existing)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZinoError(.keychainFailure, "Could not delete credential from Keychain (OSStatus \(status)).")
        }
    }

    public func hasSecret(forAccount account: String) -> Bool {
        getSecret(forAccount: account) != nil
    }

    public func maskedHint(forAccount account: String) -> String? {
        guard let secret = getSecret(forAccount: account) else { return nil }
        return Self.mask(secret)
    }

    public static func mask(_ secret: String) -> String {
        guard secret.count > 8 else { return "••••" }
        return "••••" + secret.suffix(4)
    }
}

/// In-memory Keychain double used strictly by automated tests.
public final class InMemoryKeychainService: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func setSecret(_ secret: String, forAccount account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZinoError(.invalidArgument, "Credential cannot be empty.") }
        lock.lock()
        storage[account] = trimmed
        lock.unlock()
        SecretRedactor.register(secret: trimmed)
    }

    public func getSecret(forAccount account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func deleteSecret(forAccount account: String) throws {
        lock.lock()
        let old = storage.removeValue(forKey: account)
        lock.unlock()
        if let old { SecretRedactor.unregister(secret: old) }
    }

    public func hasSecret(forAccount account: String) -> Bool {
        getSecret(forAccount: account) != nil
    }

    public func maskedHint(forAccount account: String) -> String? {
        getSecret(forAccount: account).map { KeychainService.mask($0) }
    }
}
