import Foundation
import UIKit
import WebKit
import Combine

public struct BrowserConsoleEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let level: String
    public let message: String
}

public struct EphemeralBrowserVisionSnapshot: Sendable {
    public let capturedAt: Date
    public let pageTitle: String
    public let pageURL: String
    public let visibleTextExcerpt: String
    public let domSummary: String
    public let consoleLogs: [String]
    /// Kept strictly in RAM; never written to disk or Photo Library.
    public let inMemoryPNGData: Data?
    public let inMemoryImage: UIImage?
}

/// Built-in custom WebKit browser controller with LocalHTTPServer integration, JavaScript console capture,
/// DOM inspection, and strictly ephemeral in-memory screenshot capture (never saved to device storage).
@MainActor
public final class ZinoBrowserService: NSObject, ObservableObject {
    @Published public var addressBarText: String = "http://127.0.0.1:8080"
    @Published public private(set) var currentURLString: String = "about:blank"
    @Published public private(set) var pageTitle: String = "ZinoAgent Browser"
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var canGoBack: Bool = false
    @Published public private(set) var canGoForward: Bool = false
    @Published public private(set) var consoleLogs: [BrowserConsoleEntry] = []

    /// Ephemeral screenshot held strictly in RAM for AI vision & live inspection — NEVER written to disk.
    @Published public private(set) var latestEphemeralScreenshot: UIImage?
    @Published public private(set) var latestEphemeralPNGData: Data?
    @Published public private(set) var latestEphemeralCapturedAt: Date?

    public let localServer: LocalHTTPServer
    private let bookmarks: SecurityScopedBookmarkManager
    public private(set) var webView: WKWebView!

    public init(localServer: LocalHTTPServer, bookmarks: SecurityScopedBookmarkManager) {
        self.localServer = localServer
        self.bookmarks = bookmarks
        super.init()
        configureWebView()
    }

    private func configureWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let contentController = WKUserContentController()

        // Inject console.log / warn / error interceptor so AI and user can see page console output & errors.
        let consoleScript = """
        (function() {
            const origLog = console.log, origWarn = console.warn, origErr = console.error;
            function send(level, args) {
                try {
                    const text = Array.from(args).map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
                    window.webkit.messageHandlers.zinoConsole.postMessage({level: level, message: text});
                } catch (_) {}
            }
            console.log = function() { send('INFO', arguments); origLog.apply(console, arguments); };
            console.warn = function() { send('WARN', arguments); origWarn.apply(console, arguments); };
            console.error = function() { send('ERROR', arguments); origErr.apply(console, arguments); };
            window.addEventListener('error', function(e) {
                send('ERROR', [e.message + ' (' + (e.filename || '') + ':' + (e.lineno || 0) + ')']);
            });
        })();
        """
        contentController.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        contentController.add(ConsoleScriptMessageHandler(owner: self), name: "zinoConsole")
        config.userContentController = contentController

        // Give the WKWebView a real initial viewport size (1024×768) so offscreen rendering & snapshots work even before opening the Browser tab.
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.navigationDelegate = self
        wv.isInspectable = true
        self.webView = wv
    }

    // MARK: - Navigation & Local Server Integration

    public func loadURLString(_ rawInput: String) {
        var trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !trimmed.contains("://") {
            if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
                trimmed = "http://" + trimmed
            } else {
                trimmed = "https://" + trimmed
            }
        }
        guard let url = URL(string: trimmed) else { return }
        addressBarText = url.absoluteString
        currentURLString = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Starts the local HTTP server for `folder` and opens `relativePath` (e.g. `snake.html`) in the Custom Browser.
    @discardableResult
    public func serveAndOpenFile(relativePath: String, in folder: MountedFolder, preferredPort: UInt16 = 8080) throws -> String {
        let baseURL = try localServer.start(serving: folder, preferredPort: preferredPort)
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let targetURL = cleanRel.isEmpty ? baseURL : "\(baseURL)/\(cleanRel)"
        loadURLString(targetURL)
        return targetURL
    }

    public func reload() {
        webView.reload()
    }

    public func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    public func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    public func clearConsole() {
        consoleLogs.removeAll()
    }

    public func evaluateJavaScript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    cont.resume(throwing: ZinoError(.inferenceFailed, "Browser JS error: \(error.localizedDescription)"))
                } else if let result {
                    cont.resume(returning: String(describing: result))
                } else {
                    cont.resume(returning: "undefined")
                }
            }
        }
    }

    /// Captures a live screenshot and DOM state of the browser **strictly in RAM**.
    /// The screenshot is NEVER written to the device's filesystem or Photo Library.
    public func captureEphemeralVisionSnapshot() async -> EphemeralBrowserVisionSnapshot {
        // Wait briefly if page is still finishing initial render.
        if isLoading {
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        let domScript = """
        (function() {
            const title = document.title || '';
            const url = location.href || '';
            const text = (document.body ? document.body.innerText : '').slice(0, 4000);
            const canvases = Array.from(document.querySelectorAll('canvas')).map(c => ({
                id: c.id || 'canvas',
                width: c.width,
                height: c.height
            }));
            const buttons = Array.from(document.querySelectorAll('button,input,a')).slice(0, 25).map(el => el.innerText || el.value || el.id || el.tagName);
            return JSON.stringify({
                title: title,
                url: url,
                text: text,
                canvasCount: canvases.length,
                canvases: canvases,
                interactiveElements: buttons
            });
        })();
        """

        let rawDOMJSON = (try? await evaluateJavaScript(domScript)) ?? "{}"
        var visibleText = ""
        var domSummary = rawDOMJSON
        if let data = rawDOMJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            visibleText = (parsed["text"] as? String) ?? ""
            let canvasCount = (parsed["canvasCount"] as? Int) ?? 0
            let canvases = (parsed["canvases"] as? [[String: Any]]) ?? []
            let canvasDesc = canvases.map { "\($0["id"] ?? "canvas") (\($0["width"] ?? 0)×\($0["height"] ?? 0))" }.joined(separator: ", ")
            let interactive = ((parsed["interactiveElements"] as? [String]) ?? []).filter { !$0.isEmpty }.joined(separator: ", ")
            domSummary = """
            Title: \(parsed["title"] as? String ?? pageTitle)
            URL: \(parsed["url"] as? String ?? currentURLString)
            Canvas Elements (\(canvasCount)): \(canvasDesc.isEmpty ? "None" : canvasDesc)
            Interactive Elements: \(interactive.isEmpty ? "None" : interactive)
            Visible Page Text:
            \(visibleText.isEmpty ? "(No plain text / canvas-rendered view)" : visibleText)
            """
        }

        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: UIImage? = await withCheckedContinuation { cont in
            webView.takeSnapshot(with: config) { img, _ in
                cont.resume(returning: img)
            }
        }

        // Convert to PNG Data in memory ONLY (never saved to disk!).
        let pngData = image?.pngData()
        self.latestEphemeralScreenshot = image
        self.latestEphemeralPNGData = pngData
        self.latestEphemeralCapturedAt = Date()

        let recentConsole = consoleLogs.prefix(20).map { "[\($0.level)] \($0.message)" }
        return EphemeralBrowserVisionSnapshot(
            capturedAt: Date(),
            pageTitle: pageTitle,
            pageURL: currentURLString,
            visibleTextExcerpt: visibleText,
            domSummary: domSummary,
            consoleLogs: Array(recentConsole),
            inMemoryPNGData: pngData,
            inMemoryImage: image
        )
    }

    public func clearEphemeralScreenshotFromRAM() {
        latestEphemeralScreenshot = nil
        latestEphemeralPNGData = nil
        latestEphemeralCapturedAt = nil
    }

    fileprivate func recordConsole(level: String, message: String) {
        consoleLogs.insert(BrowserConsoleEntry(timestamp: Date(), level: level, message: message), at: 0)
        if consoleLogs.count > 150 {
            consoleLogs.removeLast(consoleLogs.count - 150)
        }
    }
}

extension ZinoBrowserService: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentURLString = webView.url?.absoluteString ?? currentURLString
        addressBarText = currentURLString
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURLString = webView.url?.absoluteString ?? currentURLString
        addressBarText = currentURLString
        pageTitle = (webView.title?.isEmpty == false) ? webView.title! : currentURLString
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        recordConsole(level: "ERROR", message: "Navigation failed: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        recordConsole(level: "ERROR", message: "Load failed: \(error.localizedDescription)")
    }
}

private final class ConsoleScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ZinoBrowserService?
    init(owner: ZinoBrowserService) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let level = (body["level"] as? String) ?? "INFO"
        let text = (body["message"] as? String) ?? ""
        Task { @MainActor in
            self.owner?.recordConsole(level: level, message: text)
        }
    }
}
