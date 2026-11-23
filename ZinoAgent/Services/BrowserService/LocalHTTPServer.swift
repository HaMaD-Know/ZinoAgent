import Foundation
import Network
import Combine

public struct HTTPServerLogEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let method: String
    public let path: String
    public let statusCode: Int
    public let bytesSent: Int
}

/// Real local HTTP development server built on Apple's `Network` (`NWListener`) framework.
/// Serves files directly from the user's selected/mounted folder on `http://127.0.0.1:<port>`
/// so HTML5 apps, games (e.g. Snake), ES modules, and WebGL/Canvas projects run with a genuine HTTP origin.
@MainActor
public final class LocalHTTPServer: ObservableObject {
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var port: UInt16 = 8080
    @Published public private(set) var activeFolder: MountedFolder?
    @Published public private(set) var rootDirectoryURL: URL?
    @Published public private(set) var requestLogs: [HTTPServerLogEntry] = []

    private let bookmarks: SecurityScopedBookmarkManager
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.zinoagent.localhttpserver", qos: .userInitiated)

    public init(bookmarks: SecurityScopedBookmarkManager) {
        self.bookmarks = bookmarks
    }

    public var baseURLString: String {
        "http://127.0.0.1:\(port)"
    }

    /// Starts the local HTTP server serving `folder` on `preferredPort` (or the next free port in `8080...8099`).
    @discardableResult
    public func start(serving folder: MountedFolder, preferredPort: UInt16 = 8080) throws -> String {
        let resolvedRoot = try bookmarks.resolveURL(for: folder)
        if isRunning, activeFolder?.id == folder.id, rootDirectoryURL == resolvedRoot {
            return baseURLString
        }
        stop()

        var boundListener: NWListener?
        var chosenPort: UInt16 = preferredPort

        for candidate in preferredPort...max(preferredPort, 8099) {
            if let nwPort = NWEndpoint.Port(rawValue: candidate),
               let l = try? NWListener(using: .tcp, on: nwPort) {
                boundListener = l
                chosenPort = candidate
                break
            }
        }

        guard let listener = boundListener else {
            throw ZinoError(.networkFailure, "Could not bind Local HTTP Server on ports \(preferredPort)..8099.")
        }

        self.listener = listener
        self.port = chosenPort
        self.activeFolder = folder
        self.rootDirectoryURL = resolvedRoot
        self.isRunning = true

        let rootCopy = resolvedRoot
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection, rootURL: rootCopy)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                case .failed, .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }
        listener.start(queue: serverQueue)
        AppLogger.shared.info("HTTPServer", "Started local HTTP server at http://127.0.0.1:\(chosenPort) serving '\(folder.displayName)'")
        return "http://127.0.0.1:\(chosenPort)"
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    public func clearLogs() {
        requestLogs.removeAll()
    }

    // MARK: - Connection & HTTP Request Handling

    private nonisolated func handleConnection(_ connection: NWConnection, rootURL: URL) {
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil, let data, !data.isEmpty,
                  let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let response = Self.processHTTPRequest(requestString, rootURL: rootURL)
            Task { @MainActor in
                self.appendLog(response.logEntry)
            }

            connection.send(content: response.rawBytes, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func appendLog(_ entry: HTTPServerLogEntry) {
        requestLogs.insert(entry, at: 0)
        if requestLogs.count > 120 {
            requestLogs.removeLast(requestLogs.count - 120)
        }
    }

    private nonisolated static func processHTTPRequest(
        _ rawRequest: String,
        rootURL: URL
    ) -> (rawBytes: Data, logEntry: HTTPServerLogEntry) {
        let firstLine = rawRequest.components(separatedBy: "\r\n").first ?? "GET / HTTP/1.1"
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let rawTarget = parts.count > 1 ? String(parts[1]) : "/"
        let cleanPathOnly = rawTarget.split(separator: "?").first.map(String.init) ?? "/"
        let decodedPath = cleanPathOnly.removingPercentEncoding ?? cleanPathOnly

        guard method == "GET" || method == "HEAD" else {
            let body = Data("Method Not Allowed".utf8)
            return (
                buildHTTPResponse(status: 405, statusText: "Method Not Allowed", contentType: "text/plain", body: body, headOnly: false),
                HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 405, bytesSent: body.count)
            )
        }

        let relative = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relative.contains("..") {
            let body = Data("403 Forbidden: Path traversal blocked".utf8)
            return (
                buildHTTPResponse(status: 403, statusText: "Forbidden", contentType: "text/plain", body: body, headOnly: method == "HEAD"),
                HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 403, bytesSent: body.count)
            )
        }

        let candidate = relative.isEmpty ? rootURL : rootURL.appendingPathComponent(relative)
        guard let safeURL = try? SecurityScopedBookmarkManager.ensureInsideScope(candidate: candidate, root: rootURL) else {
            let body = Data("403 Forbidden".utf8)
            return (
                buildHTTPResponse(status: 403, statusText: "Forbidden", contentType: "text/plain", body: body, headOnly: method == "HEAD"),
                HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 403, bytesSent: body.count)
            )
        }

        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: safeURL.path, isDirectory: &isDir) else {
            let body = Data("404 Not Found: \(decodedPath)".utf8)
            return (
                buildHTTPResponse(status: 404, statusText: "Not Found", contentType: "text/plain; charset=utf-8", body: body, headOnly: method == "HEAD"),
                HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 404, bytesSent: body.count)
            )
        }

        if isDir.boolValue {
            let indexURL = safeURL.appendingPathComponent("index.html")
            if fm.fileExists(atPath: indexURL.path), let indexData = try? Data(contentsOf: indexURL) {
                return (
                    buildHTTPResponse(status: 200, statusText: "OK", contentType: "text/html; charset=utf-8", body: indexData, headOnly: method == "HEAD"),
                    HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 200, bytesSent: indexData.count)
                )
            }
            let listingHTML = generateDirectoryListingHTML(dirURL: safeURL, requestPath: decodedPath)
            let body = Data(listingHTML.utf8)
            return (
                buildHTTPResponse(status: 200, statusText: "OK", contentType: "text/html; charset=utf-8", body: body, headOnly: method == "HEAD"),
                HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 200, bytesSent: body.count)
            )
        }

        guard let fileData = try? Data(contentsOf: safeURL) else {
            let body = Data("500 Internal Server Error".utf8)
            return (
                buildHTTPResponse(status: 500, statusText: "Internal Server Error", contentType: "text/plain", body: body, headOnly: method == "HEAD"),
                HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 500, bytesSent: body.count)
            )
        }

        let mime = mimeType(forExtension: safeURL.pathExtension.lowercased())
        return (
            buildHTTPResponse(status: 200, statusText: "OK", contentType: mime, body: fileData, headOnly: method == "HEAD"),
            HTTPServerLogEntry(timestamp: Date(), method: method, path: decodedPath, statusCode: 200, bytesSent: fileData.count)
        )
    }

    private nonisolated static func buildHTTPResponse(
        status: Int,
        statusText: String,
        contentType: String,
        body: Data,
        headOnly: Bool
    ) -> Data {
        let headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var out = Data(headers.utf8)
        if !headOnly {
            out.append(body)
        }
        return out
    }

    private nonisolated static func generateDirectoryListingHTML(dirURL: URL, requestPath: String) -> String {
        let items = (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let links = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url -> String in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent + (isDir ? "/" : "")
            let base = requestPath.hasSuffix("/") ? requestPath : (requestPath + "/")
            return "<li><a href=\"\(base)\(url.lastPathComponent)\">\(name)</a></li>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>ZinoAgent Local Server — \(requestPath)</title>
        <style>body{font-family:-apple-system,system-ui,sans-serif;padding:24px;background:#121317;color:#eef1f6}a{color:#58a6ff;text-decoration:none}li{margin:8px 0}</style>
        </head>
        <body>
        <h2>Directory: \(requestPath)</h2>
        <ul>\(links.isEmpty ? "<li><em>Empty folder</em></li>" : links)</ul>
        </body></html>
        """
    }

    public nonisolated static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "txt", "md", "py", "swift", "lua": return "text/plain; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "wasm": return "application/wasm"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "usdz": return "model/vnd.usdz+zip"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}
