import SwiftUI

public struct ProviderEditorSheet: View {
    public let existing: ProviderConfiguration?
    public let registry: ProviderRegistry
    public let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var providerType: ProviderType
    @State private var baseURL: String
    @State private var apiKeyInput: String = ""
    @State private var defaultModelID: String
    @State private var isDefault: Bool
    @State private var discoveredModels: [AIModelDescriptor]
    @State private var isTesting = false
    @State private var testStatusMessage: String?
    @State private var errorMessage: String?

    public init(existing: ProviderConfiguration?, registry: ProviderRegistry, onSaved: @escaping () -> Void) {
        self.existing = existing
        self.registry = registry
        self.onSaved = onSaved

        _name = State(initialValue: existing?.name ?? "OpenAI")
        _providerType = State(initialValue: existing?.providerType ?? .openAI)
        _baseURL = State(initialValue: existing?.baseURL ?? ProviderType.openAI.defaultBaseURL)
        _defaultModelID = State(initialValue: existing?.defaultModelID ?? "")
        _isDefault = State(initialValue: existing?.isDefault ?? registry.providers.isEmpty)
        _discoveredModels = State(initialValue: existing?.cachedModels ?? [])
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Provider Identity") {
                    Picker("Provider Type", selection: $providerType) {
                        ForEach(ProviderType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .onChange(of: providerType) { _, newType in
                        if existing == nil {
                            baseURL = newType.defaultBaseURL
                            switch newType {
                            case .openAI: name = "OpenAI"
                            case .anthropic: name = "Anthropic"
                            case .gemini: name = "Google Gemini"
                            case .openAICompatible: name = "Local Server"
                            }
                        }
                    }

                    TextField("Display Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Set as Default Online Provider", isOn: $isDefault)
                }

                Section("Authentication (iOS Keychain)") {
                    if let existing, let masked = registry.maskedCredential(for: existing) {
                        LabeledContent("Saved Key", value: masked)
                    }
                    SecureField(
                        existing == nil ? "Enter API Key" : "Enter new API Key to replace (leave blank to keep existing)",
                        text: $apiKeyInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Text("Credentials are stored encrypted in the iOS Keychain (ThisDeviceOnly) and are never written to SQLite, logs, or exported conversations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Connection & Models") {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView().controlSize(.small)
                                Text("Testing Connection...")
                            } else {
                                Label("Test Connection & Fetch Models", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                    }
                    .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let status = testStatusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(ZinoTheme.statusPositive)
                    }
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(ZinoTheme.statusCritical)
                    }

                    if !discoveredModels.isEmpty {
                        Picker("Default Model", selection: $defaultModelID) {
                            ForEach(discoveredModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                    } else {
                        TextField("Default Model ID (e.g. gpt-4o, claude-sonnet-4-5, gemini-2.5-pro)", text: $defaultModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add AI Provider" : "Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProvider()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func buildDraftConfig() -> ProviderConfiguration {
        let adapter = registry.adapter(for: providerType)
        return ProviderConfiguration(
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerType: providerType,
            baseURL: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
            keychainAccount: existing?.keychainAccount,
            defaultModelID: defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            cachedModels: discoveredModels,
            isDefault: isDefault,
            supportsVision: adapter.supportsVision,
            supportsImageGeneration: adapter.supportsImageGeneration,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
    }

    private func testConnection() {
        isTesting = true
        errorMessage = nil
        testStatusMessage = nil
        let draft = buildDraftConfig()
        let keyOverride = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            defer { isTesting = false }
            do {
                let models = try await registry.testAndDiscoverModels(
                    for: draft,
                    overrideAPIKey: keyOverride.isEmpty ? nil : keyOverride
                )
                discoveredModels = models
                if defaultModelID.isEmpty, let first = models.first(where: { !$0.supportsImageGeneration }) ?? models.first {
                    defaultModelID = first.id
                }
                testStatusMessage = "Connected! Discovered \(models.count) model(s)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveProvider() {
        errorMessage = nil
        let config = buildDraftConfig()
        let keyToSave = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try registry.saveProvider(config, apiKey: keyToSave.isEmpty ? nil : keyToSave)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
