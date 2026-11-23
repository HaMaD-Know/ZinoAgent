import SwiftUI
import WebKit
import UIKit

public struct BrowserStudioView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var browser: ZinoBrowserService

    @State private var mountedFolders: [MountedFolder] = []
    @State private var selectedFolderID: String = ""
    @State private var htmlFilesInFolder: [FileItem] = []
    @State private var showConsoleDrawer: Bool = false
    @State private var showEphemeralInspector: Bool = false
    @State private var statusBanner: String?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.browser = coordinator.browserService
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                serverAndFolderBar
                Divider()
                addressBar
                Divider()

                if let banner = statusBanner {
                    HStack {
                        Image(systemName: "info.circle.fill").foregroundStyle(ZinoTheme.statusInfo)
                        Text(banner).font(.caption).lineLimit(2)
                        Spacer()
                        Button { statusBanner = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(ZinoTheme.statusInfo.opacity(0.10))
                }

                ZStack(alignment: .bottomTrailing) {
                    PersistentWebViewContainer(webView: browser.webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let ramImage = browser.latestEphemeralScreenshot, showEphemeralInspector {
                        ephemeralScreenshotOverlay(image: ramImage)
                            .padding(14)
                    }
                }

                if showConsoleDrawer {
                    Divider()
                    consoleAndServerLogsDrawer
                        .frame(height: 185)
                }
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle(browser.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        captureAndShowEphemeralVision()
                    } label: {
                        Label("AI Vision (RAM Only)", systemImage: "eye.circle")
                    }

                    Button {
                        askAIToInspectCurrentPage()
                    } label: {
                        Label("Ask AI About Page", systemImage: "sparkles")
                    }

                    Button {
                        showConsoleDrawer.toggle()
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }
                }
            }
            .onAppear {
                reloadFoldersAndHTMLFiles()
            }
        }
    }

    // MARK: - Local Server & Folder Bar

    private var serverAndFolderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(browser.localServer.isRunning ? ZinoTheme.statusPositive : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(browser.localServer.isRunning ? "Server: \(browser.localServer.baseURLString)" : "Local Server Stopped")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ZinoTheme.surfaceSecondary)
                .clipShape(Capsule())

                if !mountedFolders.isEmpty {
                    Menu {
                        ForEach(mountedFolders) { folder in
                            Button(folder.displayName) {
                                selectedFolderID = folder.id
                                reloadHTMLFilesForSelectedFolder()
                                if browser.localServer.isRunning {
                                    _ = try? browser.localServer.start(serving: folder)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                            Text(selectedFolder?.displayName ?? "Folder")
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(ZinoTheme.surfaceSecondary)
                        .clipShape(Capsule())
                    }
                }

                if browser.localServer.isRunning {
                    Button("Stop Server", role: .destructive) {
                        browser.localServer.stop()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Button("Start Server") {
                        if let folder = selectedFolder {
                            if let url = try? browser.localServer.start(serving: folder) {
                                browser.loadURLString(url)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(selectedFolder == nil)
                }

                if !htmlFilesInFolder.isEmpty {
                    Menu {
                        ForEach(htmlFilesInFolder) { file in
                            Button {
                                if let folder = selectedFolder {
                                    _ = try? browser.serveAndOpenFile(relativePath: file.name, in: folder)
                                }
                            } label: {
                                Label(file.name, systemImage: "doc.richtext")
                            }
                        }
                    } label: {
                        Label("Open HTML (\(htmlFilesInFolder.count))", systemImage: "doc.text.magnifyingglass")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Button {
                    coordinator.openNewChat(
                        draft: "Build an interactive HTML5 Snake game (snake.html) inside my mounted folder, start the local HTTP server, open it in the browser, and inspect it with an ephemeral screenshot."
                    )
                } label: {
                    Label("Ask AI to Build App/Game", systemImage: "gamecontroller.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Address Bar

    private var addressBar: some View {
        HStack(spacing: 10) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
            Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward)
            Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }

            TextField("http://127.0.0.1:8080/snake.html or https://...", text: $browser.addressBarText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ZinoTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit {
                    browser.loadURLString(browser.addressBarText)
                }

            Button("Go") {
                browser.loadURLString(browser.addressBarText)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Ephemeral RAM-Only Screenshot Overlay

    private func ephemeralScreenshotOverlay(image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusBadge("RAM-Only AI Vision (Not Saved to Device)", icon: "memorychip", tint: ZinoTheme.statusPositive)
                Spacer()
                Button {
                    browser.clearEphemeralScreenshotFromRAM()
                    showEphemeralInspector = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 170)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ZinoTheme.border, lineWidth: 1))

            HStack {
                if let bytes = browser.latestEphemeralPNGData?.count {
                    Text("Buffer: \(Formatters.bytes(Int64(bytes))) in RAM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send to AI Chat") {
                    askAIToInspectCurrentPage()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .frame(width: 290)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZinoTheme.border, lineWidth: 1))
    }

    // MARK: - Console & Server Logs Drawer

    private var consoleAndServerLogsDrawer: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Browser JS Console (\(browser.consoleLogs.count))")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Clear") { browser.clearConsole() }
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(browser.consoleLogs) { log in
                            Text("[\(log.level)] \(log.message)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(log.level == "ERROR" ? ZinoTheme.statusCritical : .primary)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Local HTTP Server Requests (\(browser.localServer.requestLogs.count))")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Clear") { browser.localServer.clearLogs() }
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(browser.localServer.requestLogs) { req in
                            Text("[\(req.statusCode)] \(req.method) \(req.path) (\(Formatters.bytes(Int64(req.bytesSent))))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(req.statusCode >= 400 ? ZinoTheme.statusWarning : .secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(ZinoTheme.surfaceSecondary)
    }

    // MARK: - Helpers

    private var selectedFolder: MountedFolder? {
        mountedFolders.first(where: { $0.id == selectedFolderID }) ?? mountedFolders.first
    }

    private func reloadFoldersAndHTMLFiles() {
        mountedFolders = (try? coordinator.bookmarkManager.loadFolders()) ?? []
        if selectedFolderID.isEmpty, let first = mountedFolders.first {
            selectedFolderID = first.id
        }
        reloadHTMLFilesForSelectedFolder()
    }

    private func reloadHTMLFilesForSelectedFolder() {
        guard let folder = selectedFolder else {
            htmlFilesInFolder = []
            return
        }
        let all = (try? coordinator.fileService.searchFiles(in: folder, query: "", maxResults: 100)) ?? []
        htmlFilesInFolder = all.filter { ["html", "htm"].contains($0.fileExtension.lowercased()) }
    }

    private func captureAndShowEphemeralVision() {
        Task {
            let snap = await browser.captureEphemeralVisionSnapshot()
            showEphemeralInspector = true
            let size = snap.inMemoryPNGData.map { Formatters.bytes(Int64($0.count)) } ?? "0 B"
            statusBanner = "Captured ephemeral screenshot (\(size) in RAM only — never saved to device storage)."
        }
    }

    private func askAIToInspectCurrentPage() {
        Task {
            let snap = await browser.captureEphemeralVisionSnapshot()
            coordinator.pendingEphemeralBrowserImage = snap.inMemoryPNGData.map {
                ChatImagePayload(mimeType: "image/png", base64Data: $0.base64EncodedString())
            }
            let draft = """
            Please inspect the current page running in ZinoAgent's Custom Browser (ephemeral RAM-only screenshot attached in memory):
            \(snap.domSummary)
            Console Logs: \(snap.consoleLogs.isEmpty ? "No errors" : snap.consoleLogs.joined(separator: " | "))
            """
            coordinator.openNewChat(draft: draft)
        }
    }
}

/// Hosts the shared `WKWebView` from `ZinoBrowserService` so page state persists when switching between AI Chat and Browser.
private struct PersistentWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attachWebView(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView {
            attachWebView(to: uiView)
        }
    }

    private func attachWebView(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
