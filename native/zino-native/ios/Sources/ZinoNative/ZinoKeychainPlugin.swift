import Foundation
import Capacitor
import Security

/// Keychain storage for API keys. Secrets are written from JS once and are never returned
/// to JavaScript afterwards: ZinoHttpPlugin reads them natively and injects them into requests.
enum ZinoKeychain {
    static let service = "com.zinoagent.credentials"

    static func set(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw ZinoError("INVALID_ARGUMENT", "Secret is not valid UTF-8") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attrs.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ZinoError("KEYCHAIN_ERROR", "Keychain write failed (\(addStatus))") }
        } else if status != errSecSuccess {
            throw ZinoError("KEYCHAIN_ERROR", "Keychain update failed (\(status))")
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZinoError("KEYCHAIN_ERROR", "Keychain delete failed (\(status))")
        }
    }

    static func masked(_ secret: String) -> String {
        guard secret.count > 8 else { return "••••" }
        return "••••" + secret.suffix(4)
    }
}

@objc(ZinoKeychainPlugin)
public class ZinoKeychainPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoKeychainPlugin"
    public let jsName = "ZinoKeychain"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "set", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "has", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "remove", returnType: CAPPluginReturnPromise)
    ]

    private func account(_ call: CAPPluginCall) -> String? {
        guard let a = call.getString("account"),
              a.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else { return nil }
        return a
    }

    @objc func set(_ call: CAPPluginCall) {
        guard let account = account(call) else { call.reject("Invalid account", "INVALID_ARGUMENT"); return }
        guard let secret = call.getString("secret"), !secret.isEmpty else { call.reject("Secret is empty", "INVALID_ARGUMENT"); return }
        do {
            try ZinoKeychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            call.resolve(["masked": ZinoKeychain.masked(secret)])
        } catch { call.zinoReject(error) }
    }

    /// Returns only existence + a masked hint, never the secret itself.
    @objc func has(_ call: CAPPluginCall) {
        guard let account = account(call) else { call.reject("Invalid account", "INVALID_ARGUMENT"); return }
        if let s = ZinoKeychain.get(account: account) {
            call.resolve(["exists": true, "masked": ZinoKeychain.masked(s)])
        } else {
            call.resolve(["exists": false])
        }
    }

    @objc func remove(_ call: CAPPluginCall) {
        guard let account = account(call) else { call.reject("Invalid account", "INVALID_ARGUMENT"); return }
        do { try ZinoKeychain.remove(account: account); call.resolve() } catch { call.zinoReject(error) }
    }
}
