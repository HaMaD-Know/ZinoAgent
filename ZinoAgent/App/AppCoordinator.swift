import Foundation
import SwiftUI
import Combine

/// Root dependency container and cross-feature navigation coordinator for ZinoAgent 2.0.
@MainActor
public final class AppCoordinator: ObservableObject {
    // Navigation state
    @Published public var selectedSection: NavigationSection = .home
    @Published public var storageBreakdown: StorageBreakdown
    @Published public var systemBannerMessage: String?

    // Cross-feature handoff triggers
    @Published public var pendingChatDraft: String?
    @Published public var pendingChatAttachments: [ChatAttachment] = []
    /// Ephemeral browser screenshot kept strictly in RAM for AI vision — NEVER written to disk.
    @Published public var pendingEphemeralBrowserImage: ChatImagePayload?
    @Published public var pendingThreeDFileURL: URL?
    @Published public var requestNewChatID: UUID?
    @Published public var requestOpenProviderSetup: Bool = false
    @Published public var requestOpenModelCatalog: Bool = false
    @Published public var requestOpenFolderPicker: Bool = false

    // Core infrastructure
    public let storagePaths: AppStoragePaths
    public let database: AppDatabase
    public let settings: SettingsManager
    public let keychain: KeychainStoring
    public let resourceMonitor: SystemResourceMonitor

    // Services
    public let conversationRepository: ConversationRepository
    public let bookmarkManager: SecurityScopedBookmarkManager
    public let fileService: FileManagerService
    public let permissionService: PermissionService
    public let exportService: ExportService

    // Browser, Local Server, Terminal, Skills & Plugins
    public let localHTTPServer: LocalHTTPServer
    public let browserService: ZinoBrowserService
    public let skillRegistry: SkillRegistryService
    public let githubPlugin: GitHubPluginService
    public let cloudflarePlugin: CloudflarePluginService
    public let terminalService: ZinoTerminalService

    // AI Subsystems
    public let modelRegistry: ModelRegistryService
    public let downloadManager: ModelDownloadManager
    public let offlineEngine: LlamaCppEngine
    public let providerRegistry: ProviderRegistry
    public let onlineEngine: OnlineAIEngine
    public let smartContextEngine: SmartContextEngine
    public let fileToolExecutor: FileToolExecutor

    // Studios
    public let imageGenerationService: ImageGenerationService
    public let threeDService: ThreeDService

    private var cancellables: Set<AnyCancellable> = []

    public init(inMemory: Bool = false) {
        let paths = AppStoragePaths()
        self.storagePaths = paths

        let db: AppDatabase
        do {
            db = inMemory ? try AppDatabase.inMemory() : try AppDatabase(path: paths.databaseFileURL.path)
        } catch {
            AppLogger.shared.error("App", "Failed to open primary database (\(error.localizedDescription)); falling back to in-memory store.")
            db = try! AppDatabase.inMemory()
        }
        self.database = db

        let settingsManager = SettingsManager(database: db)
        self.settings = settingsManager
        self.selectedSection = settingsManager.defaultSection

        let keychainStore: KeychainStoring = inMemory ? InMemoryKeychainService() : KeychainService()
        self.keychain = keychainStore

        let monitor = SystemResourceMonitor()
        self.resourceMonitor = monitor

        let convRepo = ConversationRepository(database: db)
        self.conversationRepository = convRepo

        let bm = SecurityScopedBookmarkManager(database: db, defaultWorkspaceURL: paths.workspaceDirectory)
        self.bookmarkManager = bm
        let fmService = FileManagerService(database: db, bookmarks: bm)
        self.fileService = fmService
        let permService = PermissionService(database: db)
        self.permissionService = permService
        self.exportService = ExportService(storagePaths: paths, conversationRepository: convRepo)

        // Browser, Local Server, Skills, Plugins & Terminal
        let httpServer = LocalHTTPServer(bookmarks: bm)
        self.localHTTPServer = httpServer
        let browser = ZinoBrowserService(localServer: httpServer, bookmarks: bm)
        self.browserService = browser
        let skills = SkillRegistryService(database: db)
        self.skillRegistry = skills
        let gh = GitHubPluginService(database: db, keychain: keychainStore)
        self.githubPlugin = gh
        let cf = CloudflarePluginService(database: db, keychain: keychainStore)
        self.cloudflarePlugin = cf
        let terminal = ZinoTerminalService(
            fileService: fmService,
            browserService: browser,
            githubPlugin: gh,
            cloudflarePlugin: cf,
            skillRegistry: skills,
            resourceMonitor: monitor
        )
        self.terminalService = terminal

        let mRegistry = ModelRegistryService(database: db, storagePaths: paths, resourceMonitor: monitor)
        self.modelRegistry = mRegistry
        let dlManager = ModelDownloadManager(storagePaths: paths)
        self.downloadManager = dlManager

        let llama = LlamaCppEngine()
        self.offlineEngine = llama

        let pRegistry = ProviderRegistry(database: db, keychain: keychainStore)
        self.providerRegistry = pRegistry
        let online = OnlineAIEngine(providerRegistry: pRegistry)
        self.onlineEngine = online

        let contextEngine = SmartContextEngine(database: db, conversationRepository: convRepo)
        contextEngine.syncConfiguration(from: settingsManager)
        self.smartContextEngine = contextEngine

        let toolExec = FileToolExecutor(
            fileService: fmService,
            permissionService: permService,
            storagePaths: paths
        )
        toolExec.browserService = browser
        toolExec.terminalService = terminal
        toolExec.githubPlugin = gh
        toolExec.cloudflarePlugin = cf
        self.fileToolExecutor = toolExec

        self.imageGenerationService = ImageGenerationService(
            database: db,
            storagePaths: paths,
            onlineEngine: online
        )
        self.threeDService = ThreeDService(database: db, storagePaths: paths)
        self.storageBreakdown = paths.computeStorageBreakdown()

        wireBindings()
    }

    private func wireBindings() {
        downloadManager.onDownloadCompleted = { [weak self] fileURL, name, sourceURL, shaPrefix in
            guard let self else { return }
            do {
                _ = try self.modelRegistry.registerModelFile(
                    at: fileURL,
                    displayName: name,
                    sourceURL: sourceURL,
                    sha256Prefix: shaPrefix,
                    targetContextLength: self.settings.localContextLength
                )
                self.refreshStorage()
                self.systemBannerMessage = "Downloaded and verified '\(name)'."
            } catch {
                self.systemBannerMessage = "Model downloaded but failed verification: \(error.localizedDescription)"
            }
        }

        resourceMonitor.onCriticalMemoryPressure = { [weak self] in
            guard let self else { return }
            guard self.settings.autoUnloadOnMemoryWarning else { return }
            Task { @MainActor in
                // Free ephemeral in-memory browser screenshot buffer first under critical memory pressure.
                self.browserService.clearEphemeralScreenshotFromRAM()
                if self.offlineEngine.loadState.isLoaded && !self.offlineEngine.isGenerating {
                    await self.offlineEngine.unload()
                    self.systemBannerMessage = "Unloaded idle local LLM due to iPadOS memory pressure."
                }
                if self.imageGenerationService.coreMLEngine.loadedModel != nil && !self.imageGenerationService.coreMLEngine.isGenerating {
                    await self.imageGenerationService.coreMLEngine.unload()
                }
            }
        }

        offlineEngine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        providerRegistry.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        smartContextEngine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        resourceMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        browserService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public func refreshStorage() {
        let paths = self.storagePaths
        Task.detached(priority: .utility) {
            let breakdown = paths.computeStorageBreakdown()
            await MainActor.run {
                self.storageBreakdown = breakdown
            }
        }
    }

    // MARK: - Active AI Summary Helpers

    public var activeModelDisplayName: String {
        if settings.defaultAIMode == .offline {
            if let loaded = offlineEngine.loadedModel {
                return loaded.name
            }
            if let first = modelRegistry.models.first {
                return "\(first.name) (Unloaded)"
            }
            return "No Local Model"
        } else {
            if let provider = providerRegistry.defaultProvider {
                return provider.defaultModelID ?? provider.name
            }
            return "No Provider Configured"
        }
    }

    // MARK: - Cross-Section Actions

    public func openNewChat(draft: String? = nil, attachments: [ChatAttachment] = []) {
        pendingChatDraft = draft
        pendingChatAttachments = attachments
        requestNewChatID = UUID()
        selectedSection = .aiChat
    }

    public func openInThreeDStudio(fileURL: URL) {
        pendingThreeDFileURL = fileURL
        selectedSection = .threeDStudio
    }

    public func openModelCatalog() {
        requestOpenModelCatalog = true
        selectedSection = .models
    }

    public func openProviderSetup() {
        requestOpenProviderSetup = true
        selectedSection = .settings
    }
}
