import Foundation
import Combine

public struct CloudflareZoneSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: String
}

public struct CloudflareDNSRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let name: String
    public let content: String
    public let proxied: Bool
}

public struct CloudflareWorkerSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let modifiedOn: String
}

/// Official Cloudflare API v4 plugin (`https://api.cloudflare.com/client/v4`).
/// API Token is stored solely in the iOS Keychain (`plugin.cloudflare.token`).
@MainActor
public final class CloudflarePluginService: ObservableObject {
    public static let keychainAccount = "plugin.cloudflare.token"

    @Published public var accountID: String = ""
    @Published public private(set) var accountName: String?
    @Published public private(set) var zones: [CloudflareZoneSummary] = []
    @Published public private(set) var workers: [CloudflareWorkerSummary] = []

    private let keychain: KeychainStoring
    private let http: HTTPClient
    private let database: AppDatabase

    public init(database: AppDatabase, keychain: KeychainStoring, http: HTTPClient = HTTPClient()) {
        self.database = database
        self.keychain = keychain
        self.http = http
        self.accountID = (try? database.getSetting(key: "plugin.cloudflare.accountID")) ?? ""
        self.accountName = try? database.getSetting(key: "plugin.cloudflare.accountName")
    }

    public var hasToken: Bool {
        keychain.hasSecret(forAccount: Self.keychainAccount)
    }

    public var maskedToken: String? {
        keychain.maskedHint(forAccount: Self.keychainAccount)
    }

    public func saveCredentials(apiToken: String, accountID: String?) throws {
        if !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.setSecret(apiToken, forAccount: Self.keychainAccount)
        }
        if let accountID {
            self.accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            try? database.setSetting(key: "plugin.cloudflare.accountID", value: self.accountID)
        }
    }

    public func disconnect() throws {
        try keychain.deleteSecret(forAccount: Self.keychainAccount)
        accountName = nil
        zones = []
        workers = []
        try? database.setSetting(key: "plugin.cloudflare.accountName", value: "")
    }

    /// Verifies token and automatically discovers the user's primary Cloudflare Account ID if not set.
    public func verifyAndDiscoverAccounts() async throws -> String {
        let data = try await request(path: "/accounts?per_page=20")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "Unexpected response from Cloudflare /accounts.")
        }
        if let first = result.first,
           let id = first["id"] as? String,
           let name = first["name"] as? String {
            if accountID.isEmpty {
                accountID = id
                try? database.setSetting(key: "plugin.cloudflare.accountID", value: id)
            }
            accountName = name
            try? database.setSetting(key: "plugin.cloudflare.accountName", value: name)
            return "\(name) (\(id))"
        }
        return "Token verified (0 accounts listed)."
    }

    @discardableResult
    public func listZones() async throws -> [CloudflareZoneSummary] {
        let data = try await request(path: "/zones?per_page=30")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return []
        }
        let parsed = result.compactMap { item -> CloudflareZoneSummary? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String else { return nil }
            return CloudflareZoneSummary(id: id, name: name, status: (item["status"] as? String) ?? "active")
        }
        zones = parsed
        return parsed
    }

    public func listDNSRecords(zoneID: String) async throws -> [CloudflareDNSRecord] {
        let cleanZone = zoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanZone.isEmpty else {
            throw ZinoError(.invalidArgument, "zone_id is required to list DNS records.")
        }
        let data = try await request(path: "/zones/\(cleanZone)/dns_records?per_page=50")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return []
        }
        return result.compactMap { item in
            guard let id = item["id"] as? String,
                  let type = item["type"] as? String,
                  let name = item["name"] as? String,
                  let content = item["content"] as? String else { return nil }
            return CloudflareDNSRecord(
                id: id,
                type: type,
                name: name,
                content: content,
                proxied: (item["proxied"] as? Bool) ?? false
            )
        }
    }

    public func createDNSRecord(zoneID: String, type: String, name: String, content: String, proxied: Bool = true) async throws -> String {
        let body: [String: Any] = [
            "type": type.uppercased(),
            "name": name,
            "content": content,
            "proxied": proxied
        ]
        _ = try await request(path: "/zones/\(zoneID)/dns_records", method: "POST", jsonBody: body)
        return "Created Cloudflare DNS \(type.uppercased()) record '\(name)' -> '\(content)'."
    }

    @discardableResult
    public func listWorkers() async throws -> [CloudflareWorkerSummary] {
        let acc = try requireAccountID()
        let data = try await request(path: "/accounts/\(acc)/workers/scripts")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return []
        }
        let parsed = result.compactMap { item -> CloudflareWorkerSummary? in
            guard let id = item["id"] as? String else { return nil }
            return CloudflareWorkerSummary(id: id, modifiedOn: (item["modified_on"] as? String) ?? "")
        }
        workers = parsed
        return parsed
    }

    /// Deploys a JavaScript Worker script directly to Cloudflare Workers.
    public func deployWorkerScript(scriptName: String, javascriptContent: String) async throws -> String {
        let acc = try requireAccountID()
        let cleanName = scriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ZinoError(.invalidArgument, "Worker script_name is required.")
        }
        guard let token = keychain.getSecret(forAccount: Self.keychainAccount), !token.isEmpty else {
            throw ZinoError(.authenticationFailure, "Cloudflare API token is not configured.")
        }
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(acc)/workers/scripts/\(cleanName)") else {
            throw ZinoError(.invalidArgument, "Invalid Cloudflare Worker URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/javascript", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(javascriptContent.utf8)

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(300) ?? ""
            throw ZinoError(.networkFailure, "Cloudflare Worker deploy failed (HTTP \(resp.statusCode)): \(detail)")
        }
        return "Deployed Cloudflare Worker '\(cleanName)' to account \(acc)."
    }

    public func listPagesProjects() async throws -> [String] {
        let acc = try requireAccountID()
        let data = try await request(path: "/accounts/\(acc)/pages/projects")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return []
        }
        return result.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let sub = (item["subdomain"] as? String) ?? ""
            return "\(name) (\(sub))"
        }
    }

    public func listD1Databases() async throws -> [String] {
        let acc = try requireAccountID()
        let data = try await request(path: "/accounts/\(acc)/d1/database")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return []
        }
        return result.compactMap { item in
            guard let name = item["name"] as? String, let uuid = item["uuid"] as? String else { return nil }
            return "\(name) [\(uuid)]"
        }
    }

    private func requireAccountID() throws -> String {
        let clean = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw ZinoError(.invalidArgument, "Cloudflare Account ID is not set. Tap 'Verify & Discover Account' in Skills & Plugins > Cloudflare.")
        }
        return clean
    }

    private func request(path: String, method: String = "GET", jsonBody: [String: Any]? = nil) async throws -> Data {
        guard let token = keychain.getSecret(forAccount: Self.keychainAccount), !token.isEmpty else {
            throw ZinoError(.authenticationFailure, "Cloudflare plugin is not connected. Add your Cloudflare API Token in Skills & Plugins > Cloudflare.")
        }
        guard let url = URL(string: "https://api.cloudflare.com/client/v4\(path)") else {
            throw ZinoError(.invalidArgument, "Invalid Cloudflare API path: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(300) ?? ""
            let code: ZinoError.Code = (resp.statusCode == 401 || resp.statusCode == 403) ? .authenticationFailure : .networkFailure
            throw ZinoError(code, "Cloudflare API HTTP \(resp.statusCode): \(detail)")
        }
        return resp.data
    }
}
