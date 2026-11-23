import SwiftUI
import UniformTypeIdentifiers

public struct SkillsPluginsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var skillRegistry: SkillRegistryService
    @ObservedObject var githubPlugin: GitHubPluginService
    @ObservedObject var cloudflarePlugin: CloudflarePluginService

    public enum SectionTab: String, CaseIterable, Identifiable {
        case skills = "AI Skills"
        case github = "GitHub Plugin"
        case cloudflare = "Cloudflare Plugin"

        public var id: String { rawValue }
    }

    @State private var selectedTab: SectionTab = .skills
    @State private var showCreateSkillSheet = false
    @State private var showImportSkillPicker = false

    // Skill Editor State
    @State private var newSkillName = ""
    @State private var newSkillCategory = "Custom"
    @State private var newSkillDescription = ""
    @State private var newSkillKeywords = ""
    @State private var newSkillInstructions = ""

    // GitHub State
    @State private var githubTokenInput = ""
    @State private var githubDefaultRepoInput = ""
    @State private var isTestingGitHub = false

    // Cloudflare State
    @State private var cloudflareTokenInput = ""
    @State private var cloudflareAccountIDInput = ""
    @State private var isTestingCloudflare = false

    @State private var statusMessage: String?
    @State private var errorMessage: String?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.skillRegistry = coordinator.skillRegistry
        self.githubPlugin = coordinator.githubPlugin
        self.cloudflarePlugin = coordinator.cloudflarePlugin
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(SectionTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, ZinoTheme.Spacing.md)
                .padding(.vertical, 10)

                if let status = statusMessage {
                    bannerBar(status, isError: false) { statusMessage = nil }
                }
                if let err = errorMessage {
                    bannerBar(err, isError: true) { errorMessage = nil }
                }

                switch selectedTab {
                case .skills:
                    skillsTabContent
                case .github:
                    githubTabContent
                case .cloudflare:
                    cloudflareTabContent
                }
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle("Skills & Plugins")
            .toolbar {
                if selectedTab == .skills {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showImportSkillPicker = true
                        } label: {
                            Label("Import SKILL.md", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showCreateSkillSheet = true
                        } label: {
                            Label("New Skill", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showImportSkillPicker) {
                DocumentPickerView(contentTypes: [.item], allowsMultipleSelection: false) { urls in
                    if let first = urls.first {
                        do {
                            let s = try skillRegistry.importSkillMarkdown(from: first)
                            statusMessage = "Imported skill '\(s.name)'."
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreateSkillSheet) {
                createSkillSheet
            }
            .onAppear {
                githubDefaultRepoInput = githubPlugin.defaultRepository
                cloudflareAccountIDInput = cloudflarePlugin.accountID
            }
        }
    }

    // MARK: - AI Skills Tab

    private var skillsTabContent: some View {
        List {
            Section {
                Text("Enabled skills automatically guide **both Offline (llama.cpp) and Online AI** models when building web apps/games, organizing your mounted folder, running terminal workflows, or calling GitHub & Cloudflare plugins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installed Skills (\(skillRegistry.skills.count))") {
                ForEach(skillRegistry.skills) { skill in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(skill.name).font(.headline)
                                    StatusBadge(skill.category, tint: .secondary)
                                    if skill.isBuiltIn {
                                        StatusBadge("Built-in", tint: ZinoTheme.statusInfo)
                                    }
                                }
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { _ in try? skillRegistry.toggleSkill(skill) }
                            ))
                            .labelsHidden()
                        }

                        if !skill.triggerKeywords.isEmpty {
                            Text("Triggers: " + skill.triggerKeywords.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        DisclosureGroup("View Skill Instructions") {
                            Text(skill.instructionsPrompt)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        .font(.caption.weight(.medium))
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        if !skill.isBuiltIn {
                            Button("Delete", role: .destructive) {
                                try? skillRegistry.deleteSkill(skill)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - GitHub Plugin Tab

    private var githubTabContent: some View {
        List {
            Section("GitHub Connection (iOS Keychain)") {
                if let user = githubPlugin.connectedUsername, !user.isEmpty {
                    LabeledContent("Connected Account", value: "@\(user)")
                }
                if let masked = githubPlugin.maskedToken {
                    LabeledContent("Keychain Token", value: masked)
                }
                SecureField("GitHub Personal Access Token (ghp_... / github_pat_...)", text: $githubTokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Default Repository (e.g. HaMaD-Know/ZinoAgent)", text: $githubDefaultRepoInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button {
                        connectAndVerifyGitHub()
                    } label: {
                        if isTestingGitHub {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Save & Verify GitHub", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestingGitHub)

                    Spacer()

                    if githubPlugin.hasToken {
                        Button("Disconnect", role: .destructive) {
                            try? githubPlugin.disconnect()
                            statusMessage = "Disconnected GitHub plugin."
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("AI & Terminal Capabilities") {
                Text("Once connected, both **Offline** and **Online** AI can call `github_plugin` (and you can run `gh` in the Terminal) to list repos, read files, push files from your mounted folder directly to GitHub, and manage issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !githubPlugin.repositories.isEmpty {
                Section("Recent Repositories (\(githubPlugin.repositories.count))") {
                    ForEach(githubPlugin.repositories) { repo in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(repo.fullName).font(.subheadline.weight(.semibold))
                                Spacer()
                                StatusBadge(repo.isPrivate ? "Private" : "Public", tint: repo.isPrivate ? ZinoTheme.statusWarning : ZinoTheme.statusPositive)
                            }
                            if let desc = repo.description, !desc.isEmpty {
                                Text(desc).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Default branch: \(repo.defaultBranch)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Cloudflare Plugin Tab

    private var cloudflareTabContent: some View {
        List {
            Section("Cloudflare Connection (iOS Keychain)") {
                if let name = cloudflarePlugin.accountName, !name.isEmpty {
                    LabeledContent("Account", value: name)
                }
                if let masked = cloudflarePlugin.maskedToken {
                    LabeledContent("Keychain API Token", value: masked)
                }
                SecureField("Cloudflare API Token", text: $cloudflareTokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Account ID (auto-discovered on Verify if blank)", text: $cloudflareAccountIDInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button {
                        connectAndVerifyCloudflare()
                    } label: {
                        if isTestingCloudflare {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Save & Verify Cloudflare", systemImage: "cloud.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestingCloudflare)

                    Spacer()

                    if cloudflarePlugin.hasToken {
                        Button("Disconnect", role: .destructive) {
                            try? cloudflarePlugin.disconnect()
                            statusMessage = "Disconnected Cloudflare plugin."
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("AI & Terminal Capabilities") {
                Text("Both **Offline** and **Online** AI can invoke `cloudflare_plugin` (and you can run `cf` in the Terminal) to inspect Zones, manage DNS records, list/deploy Cloudflare Workers from your mounted folder, and inspect Pages & D1 databases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !cloudflarePlugin.zones.isEmpty {
                Section("Zones (\(cloudflarePlugin.zones.count))") {
                    ForEach(cloudflarePlugin.zones) { zone in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(zone.name).font(.subheadline.weight(.semibold))
                                Text("Zone ID: \(zone.id)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(zone.status, tint: ZinoTheme.statusPositive)
                        }
                    }
                }
            }

            if !cloudflarePlugin.workers.isEmpty {
                Section("Cloudflare Workers (\(cloudflarePlugin.workers.count))") {
                    ForEach(cloudflarePlugin.workers) { worker in
                        LabeledContent(worker.id, value: worker.modifiedOn)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Create Skill Sheet

    private var createSkillSheet: some View {
        NavigationStack {
            Form {
                Section("Skill Identity") {
                    TextField("Skill Name (e.g. Python Data Analyst)", text: $newSkillName)
                    TextField("Category", text: $newSkillCategory)
                    TextField("Short Description", text: $newSkillDescription)
                    TextField("Trigger Keywords (comma-separated, e.g. csv, chart, analyze)", text: $newSkillKeywords)
                }
                Section("AI Instructions Prompt") {
                    TextEditor(text: $newSkillInstructions)
                        .frame(minHeight: 150)
                }
            }
            .navigationTitle("Create Custom Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreateSkillSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let slug = newSkillName.lowercased().replacingOccurrences(of: " ", with: "-")
                        let keywords = newSkillKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let skill = WorkspaceSkill(
                            name: newSkillName,
                            slug: slug,
                            category: newSkillCategory,
                            description: newSkillDescription,
                            instructionsPrompt: newSkillInstructions,
                            triggerKeywords: keywords.isEmpty ? [slug] : keywords,
                            isEnabled: true,
                            isBuiltIn: false
                        )
                        try? skillRegistry.saveSkill(skill)
                        newSkillName = ""
                        newSkillDescription = ""
                        newSkillKeywords = ""
                        newSkillInstructions = ""
                        showCreateSkillSheet = false
                        statusMessage = "Saved custom skill '\(skill.name)'."
                    }
                    .disabled(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newSkillInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func connectAndVerifyGitHub() {
        errorMessage = nil
        statusMessage = nil
        isTestingGitHub = true
        Task {
            defer { isTestingGitHub = false }
            do {
                if !githubTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try githubPlugin.saveToken(githubTokenInput, defaultRepo: githubDefaultRepoInput)
                    githubTokenInput = ""
                } else if !githubDefaultRepoInput.isEmpty {
                    try githubPlugin.saveToken(
                        coordinator.keychain.getSecret(forAccount: GitHubPluginService.keychainAccount) ?? "",
                        defaultRepo: githubDefaultRepoInput
                    )
                }
                let user = try await githubPlugin.verifyAndFetchUser()
                let repos = try await githubPlugin.listRepositories()
                statusMessage = "Connected GitHub as @\(user) (\(repos.count) repos loaded)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func connectAndVerifyCloudflare() {
        errorMessage = nil
        statusMessage = nil
        isTestingCloudflare = true
        Task {
            defer { isTestingCloudflare = false }
            do {
                try cloudflarePlugin.saveCredentials(
                    apiToken: cloudflareTokenInput,
                    accountID: cloudflareAccountIDInput
                )
                cloudflareTokenInput = ""
                let accountInfo = try await cloudflarePlugin.verifyAndDiscoverAccounts()
                cloudflareAccountIDInput = cloudflarePlugin.accountID
                _ = try? await cloudflarePlugin.listZones()
                _ = try? await cloudflarePlugin.listWorkers()
                statusMessage = "Connected Cloudflare account: \(accountInfo)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bannerBar(_ text: String, isError: Bool, dismissAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? ZinoTheme.statusCritical : ZinoTheme.statusPositive)
            Text(text).font(.caption).lineLimit(3)
            Spacer()
            Button(action: dismissAction) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((isError ? ZinoTheme.statusCritical : ZinoTheme.statusPositive).opacity(0.10))
    }
}
