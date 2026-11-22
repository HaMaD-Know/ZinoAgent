import Foundation
import Combine

/// Registry of user-configured online AI providers.
/// Provider metadata lives in SQLite; API keys live exclusively in the iOS Keychain.
@MainActor
public final class ProviderRegistry: ObservableObject {
    @Published public private(set) var providers: [ProviderConfiguration] = []

    private let database: AppDatabase
    private let keychain: KeychainStoring
    private let http: HTTPClient

    public init(database: AppDatabase, keychain: KeychainStoring, http: HTTPClient = HTTPClient()) {
        self.database = database
        self.keychain = keychain
        self.http = http
        reload()
    }

    public var defaultProvider: ProviderConfiguration? {
        providers.first(where: \.isDefault) ?? providers.first
    }

    public func adapter(for type: ProviderType) -> OnlineAIProviderAdapter {
        switch type {
        case .openAI: return OpenAIProviderAdapter(providerType: .openAI, http: http)
        case .openAICompatible: return OpenAIProviderAdapter(providerType: .openAICompatible, http: http)
        case .anthropic: return AnthropicProviderAdapter(http: http)
        case .gemini: return GeminiProviderAdapter(http: http)
        }
    }

    public func reload() {
        do {
            let rows = try database.sqlite.query("SELECT * FROM ai_providers ORDER BY is_default DESC, created_at ASC;")
            let decoder = JSONDecoder()
            self.providers = rows.compactMap { row in
                guard let id = row.string("id"),
                      let name = row.string("name"),
                      let typeRaw = row.string("provider_type"),
                      let type = ProviderType(rawValue: typeRaw),
                      let baseURL = row.string("base_url"),
                      let account = row.string("keychain_account"),
                      let created = row.date("created_at"),
                      let updated = row.date("updated_at") else { return nil }
                let cachedModels: [AIModelDescriptor]
                if let json = row.string("cached_models_json"),
                   let data = json.data(using: .utf8),
                   let decoded = try? decoder.decode([AIModelDescriptor].self, from: data) {
                    cachedModels = decoded
                } else {
                    cachedModels = []
                }
                return ProviderConfiguration(
                    id: id,
                    name: name,
                    providerType: type,
                    baseURL: baseURL,
                    keychainAccount: account,
                    defaultModelID: row.string("default_model_id"),
                    cachedModels: cachedModels,
                    isDefault: row.bool("is_default"),
                    supportsVision: row.bool("supports_vision"),
                    supportsImageGeneration: row.bool("supports_image_generation"),
                    createdAt: created,
                    updatedAt: updated
                )
            }
        } catch {
            AppLogger.shared.error("Providers", "Failed to load providers: \(error.localizedDescription)")
        }
    }

    public func saveProvider(_ config: ProviderConfiguration, apiKey: String?) throws {
        guard let url = URL(string: config.baseURL) else {
            throw ZinoError(.invalidArgument, "Invalid base URL.")
        }
        try HTTPClient.validateURL(url)

        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            try keychain.setSecret(key, forAccount: config.keychainAccount)
        }

        var updated = config
        if providers.isEmpty {
            updated.isDefault = true
        }
        updated.updatedAt = Date()

        let modelsData = (try? JSONEncoder().encode(updated.cachedModels)) ?? Data("[]".utf8)
        let modelsJSON = String(data: modelsData, encoding: .utf8) ?? "[]"

        try database.sqlite.transaction {
            if updated.isDefault {
                try database.sqlite.executeInTransaction("UPDATE ai_providers SET is_default = 0;")
            }
            try database.sqlite.executeInTransaction(
                """
                INSERT INTO ai_providers (
                    id, name, provider_type, base_url, keychain_account, default_model_id,
                    cached_models_json, is_default, supports_vision, supports_image_generation,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    provider_type = excluded.provider_type,
                    base_url = excluded.base_url,
                    default_model_id = excluded.default_model_id,
                    cached_models_json = excluded.cached_models_json,
                    is_default = excluded.is_default,
                    supports_vision = excluded.supports_vision,
                    supports_image_generation = excluded.supports_image_generation,
                    updated_at = excluded.updated_at;
                """,
                bindings: [
                    .text(updated.id),
                    .text(updated.name),
                    .text(updated.providerType.rawValue),
                    .text(updated.baseURL),
                    .text(updated.keychainAccount),
                    updated.defaultModelID.map { .text($0) } ?? .null,
                    .text(modelsJSON),
                    .integer(updated.isDefault ? 1 : 0),
                    .integer(updated.supportsVision ? 1 : 0),
                    .integer(updated.supportsImageGeneration ? 1 : 0),
                    .real(updated.createdAt.timeIntervalSince1970),
                    .real(updated.updatedAt.timeIntervalSince1970)
                ]
            )
        }
        reload()
    }

    public func deleteProvider(id: String) throws {
        if let existing = providers.first(where: { $0.id == id }) {
            try? keychain.deleteSecret(forAccount: existing.keychainAccount)
        }
        try database.sqlite.execute("DELETE FROM ai_providers WHERE id = ?;", bindings: [.text(id)])
        reload()
        if let first = providers.first, !providers.contains(where: \.isDefault) {
            try setDefaultProvider(id: first.id)
        }
    }

    public func setDefaultProvider(id: String) throws {
        try database.sqlite.transaction {
            try database.sqlite.executeInTransaction("UPDATE ai_providers SET is_default = 0;")
            try database.sqlite.executeInTransaction("UPDATE ai_providers SET is_default = 1 WHERE id = ?;", bindings: [.text(id)])
        }
        reload()
    }

    public func hasCredential(for provider: ProviderConfiguration) -> Bool {
        keychain.hasSecret(forAccount: provider.keychainAccount)
    }

    public func maskedCredential(for provider: ProviderConfiguration) -> String? {
        keychain.maskedHint(forAccount: provider.keychainAccount)
    }

    public func credential(for provider: ProviderConfiguration) -> String? {
        keychain.getSecret(forAccount: provider.keychainAccount)
    }

    public func testAndDiscoverModels(for provider: ProviderConfiguration, overrideAPIKey: String? = nil) async throws -> [AIModelDescriptor] {
        let adapter = adapter(for: provider.providerType)
        let key = overrideAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? credential(for: provider)
        let discovered = try await adapter.testConnection(config: provider, apiKey: key)

        if var stored = providers.first(where: { $0.id == provider.id }) {
            stored.cachedModels = discovered
            if stored.defaultModelID == nil {
                stored.defaultModelID = discovered.first(where: { !$0.supportsImageGeneration })?.id ?? discovered.first?.id
            }
            stored.supportsImageGeneration = adapter.supportsImageGeneration
            stored.supportsVision = adapter.supportsVision
            try saveProvider(stored, apiKey: nil)
        }
        return discovered
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
