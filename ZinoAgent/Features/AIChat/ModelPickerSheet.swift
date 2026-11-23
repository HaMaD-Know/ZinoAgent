import SwiftUI

public enum ModelPricingFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case free = "Free"
    case paid = "Paid"

    public var id: String { rawValue }
}

/// Searchable Free / Paid model selector supporting OpenRouter, OpenAI, Anthropic, Gemini,
/// and OpenAI-compatible providers with clear visual separation between Free and Paid models.
public struct OnlineModelPickerSheet: View {
    public let providers: [ProviderConfiguration]
    public let initialProviderID: String?
    public let selectedModelID: String?
    public let includeImageModels: Bool
    public let onSelect: (ProviderConfiguration, AIModelDescriptor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var activeProviderID: String
    @State private var searchText: String = ""
    @State private var pricingFilter: ModelPricingFilter = .all

    public init(
        providers: [ProviderConfiguration],
        initialProviderID: String?,
        selectedModelID: String?,
        includeImageModels: Bool = false,
        onSelect: @escaping (ProviderConfiguration, AIModelDescriptor) -> Void
    ) {
        self.providers = providers
        self.initialProviderID = initialProviderID
        self.selectedModelID = selectedModelID
        self.includeImageModels = includeImageModels
        self.onSelect = onSelect
        _activeProviderID = State(initialValue: initialProviderID ?? providers.first?.id ?? "")
    }

    private var activeProvider: ProviderConfiguration? {
        providers.first(where: { $0.id == activeProviderID }) ?? providers.first
    }

    private var filteredModels: [AIModelDescriptor] {
        guard let provider = activeProvider else { return [] }
        let base = provider.cachedModels.filter { includeImageModels ? true : !$0.supportsImageGeneration }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return base.filter { model in
            let matchesTier: Bool
            switch pricingFilter {
            case .all: matchesTier = true
            case .free: matchesTier = (model.pricingTier == .free)
            case .paid: matchesTier = (model.pricingTier == .paid)
            }
            guard matchesTier else { return false }
            if query.isEmpty { return true }
            return model.id.lowercased().contains(query)
                || model.displayName.lowercased().contains(query)
                || (model.pricingLabel?.lowercased().contains(query) ?? false)
                || (query == "vision" && model.supportsVision)
                || (query == "free" && model.pricingTier == .free)
                || (query == "paid" && model.pricingTier == .paid)
        }
    }

    private var freeModels: [AIModelDescriptor] {
        filteredModels.filter { $0.pricingTier == .free }
    }

    private var paidModels: [AIModelDescriptor] {
        filteredModels.filter { $0.pricingTier == .paid }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if providers.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(providers) { p in
                                let isSelected = p.id == activeProvider?.id
                                Button {
                                    activeProviderID = p.id
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: p.providerType == .openRouter ? "network" : "cloud")
                                        Text(p.name)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.accentColor : ZinoTheme.surfaceSecondary)
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    Divider()
                }

                Picker("Pricing Filter", selection: $pricingFilter) {
                    ForEach(ModelPricingFilter.allCases) { f in
                        Text(filterLabel(for: f)).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    if let provider = activeProvider {
                        if provider.cachedModels.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "No Models Discovered Yet",
                                    systemImage: "arrow.triangle.2.circlepath",
                                    description: Text("Open Settings > AI Providers > Edit '\(provider.name)' and tap 'Test Connection & Fetch Models' to load its Free & Paid models.")
                                )
                            }
                        } else if filteredModels.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "No Matching Models",
                                    systemImage: "magnifyingglass",
                                    description: Text("Try clearing your search or switching the Free / Paid filter.")
                                )
                            }
                        } else {
                            if !freeModels.isEmpty {
                                Section {
                                    ForEach(freeModels) { model in
                                        modelRow(model, provider: provider)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(ZinoTheme.statusPositive)
                                        Text("Free Models (\(freeModels.count))")
                                            .foregroundStyle(ZinoTheme.statusPositive)
                                    }
                                }
                            }

                            if !paidModels.isEmpty {
                                Section {
                                    ForEach(paidModels) { model in
                                        modelRow(model, provider: provider)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "creditcard")
                                            .foregroundStyle(ZinoTheme.statusWarning)
                                        Text("Paid Models (\(paidModels.count))")
                                            .foregroundStyle(ZinoTheme.statusWarning)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Select Online Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models (e.g. free, llama, deepseek, claude, gemini, gpt)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func filterLabel(for filter: ModelPricingFilter) -> String {
        guard let provider = activeProvider else { return filter.rawValue }
        let all = provider.cachedModels.filter { includeImageModels ? true : !$0.supportsImageGeneration }
        switch filter {
        case .all: return "All (\(all.count))"
        case .free: return "Free (\(all.filter { $0.pricingTier == .free }.count))"
        case .paid: return "Paid (\(all.filter { $0.pricingTier == .paid }.count))"
        }
    }

    private func modelRow(_ model: AIModelDescriptor, provider: ProviderConfiguration) -> some View {
        let isSelected = (model.id == selectedModelID && provider.id == initialProviderID)
        return Button {
            onSelect(provider, model)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        StatusBadge(
                            model.pricingTier == .free ? "FREE" : "PAID",
                            tint: model.pricingTier == .free ? ZinoTheme.statusPositive : ZinoTheme.statusWarning
                        )
                    }
                    Text(model.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text("Ctx: \(Formatters.tokens(model.contextWindow))")
                        if let price = model.pricingLabel, !price.isEmpty {
                            Text("• \(price)")
                        }
                        if model.supportsVision {
                            Text("• Vision")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
