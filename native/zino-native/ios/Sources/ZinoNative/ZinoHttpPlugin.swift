import Foundation
import Capacitor

/// HTTP client for cloud AI providers.
///
/// Security model: JavaScript never receives API keys. A request names a Keychain account in
/// `auth`; this plugin reads the secret natively, injects it as a header or query parameter,
/// and scrubs it from any error text. Streaming responses (SSE) are forwarded line-by-line
/// through `httpChunk` events so the UI can render tokens as they arrive.
@objc(ZinoHttpPlugin)
public class ZinoHttpPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoHttpPlugin"
    public let jsName = "ZinoHttp"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "request", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise)
    ]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private var tasks: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    @objc func cancel(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("id is required", "INVALID_ARGUMENT"); return }
        lock.lock(); let t = tasks.removeValue(forKey: id); lock.unlock()
        t?.cancel()
        call.resolve(["cancelled": t != nil])
    }

    @objc func request(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? UUID().uuidString
        let stream = call.getBool("stream") ?? false
        let responseType = call.getString("responseType") ?? "text"
        let req: URLRequest
        let secret: String?
        do {
            let built = try buildRequest(call)
            req = built.0
            secret = built.1
        } catch {
            call.zinoReject(error); return
        }
        let scrub: (String) -> String = { text in
            guard let secret, !secret.isEmpty else { return text }
            return text.replacingOccurrences(of: secret, with: "••••")
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.tasks.removeValue(forKey: id); self.lock.unlock() }
            do {
                if stream {
                    try await self.performStream(id: id, req: req, call: call, scrub: scrub)
                } else if responseType == "file" {
                    try await self.performDownload(req: req, call: call, scrub: scrub)
                } else {
                    let (data, response) = try await self.session.data(for: req)
                    let http = response as? HTTPURLResponse
                    var result: [String: Any] = [
                        "status": http?.statusCode ?? 0,
                        "headers": self.headerDict(http)
                    ]
                    if responseType == "base64" {
                        result["base64"] = data.base64EncodedString()
                    } else {
                        result["body"] = scrub(String(decoding: data, as: UTF8.self))
                    }
                    call.resolve(result)
                }
            } catch is CancellationError {
                call.reject("Request cancelled", "CANCELLED")
            } catch let e as URLError where e.code == .cancelled {
                call.reject("Request cancelled", "CANCELLED")
            } catch let e as URLError {
                let code: String
                switch e.code {
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: code = "NETWORK_OFFLINE"
                case .timedOut: code = "NETWORK_TIMEOUT"
                case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: code = "NETWORK_UNREACHABLE"
                case .secureConnectionFailed, .serverCertificateUntrusted, .appTransportSecurityRequiresSecureConnection: code = "NETWORK_INSECURE"
                default: code = "NETWORK_ERROR"
                }
                call.reject(scrub(e.localizedDescription), code)
            } catch {
                call.reject(scrub(error.localizedDescription), (error as? ZinoError)?.code ?? "NETWORK_ERROR")
            }
        }
        lock.lock(); tasks[id] = task; lock.unlock()
    }

    // MARK: - Request construction

    private func buildRequest(_ call: CAPPluginCall) throws -> (URLRequest, String?) {
        guard let urlString = call.getString("url"), var components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ZinoError("INVALID_ARGUMENT", "A valid http(s) URL is required.")
        }
        var secret: String?
        var headers: [String: String] = [:]
        if let h = call.getObject("headers") {
            for (k, v) in h { if let s = v as? String { headers[k] = s } }
        }
        if let auth = call.getObject("auth"), let account = auth["account"] as? String {
            guard let s = ZinoKeychain.get(account: account), !s.isEmpty else {
                throw ZinoError("MISSING_API_KEY", "No API key is stored for this provider.")
            }
            secret = s
            let name = (auth["name"] as? String) ?? "Authorization"
            let prefix = (auth["prefix"] as? String) ?? ""
            if (auth["type"] as? String) == "query" {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: name, value: s))
                components.queryItems = items
            } else {
                headers[name] = prefix + s
            }
        }
        guard let url = components.url else { throw ZinoError("INVALID_ARGUMENT", "Invalid URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = (call.getString("method") ?? "GET").uppercased()
        req.timeoutInterval = TimeInterval(call.getDouble("timeoutSeconds") ?? 600)

        if let parts = call.getArray("multipart") as? [JSObject] {
            let boundary = "ZinoBoundary-\(UUID().uuidString)"
            headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
            req.httpBody = try buildMultipart(parts, boundary: boundary)
        } else if let b64 = call.getString("bodyBase64") {
            req.httpBody = Data(base64Encoded: b64)
        } else if let body = call.getString("body") {
            req.httpBody = body.data(using: .utf8)
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return (req, secret)
    }

    private func buildMultipart(_ parts: [JSObject], boundary: String) throws -> Data {
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .utf8)!) }
        for part in parts {
            guard let name = part["name"] as? String else { continue }
            append("--\(boundary)\r\n")
            if let value = part["value"] as? String {
                append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                append(value)
                append("\r\n")
                continue
            }
            let filename = (part["filename"] as? String) ?? "file"
            let contentType = (part["contentType"] as? String) ?? "application/octet-stream"
            var payload: Data?
            if let b64 = part["base64"] as? String {
                payload = Data(base64Encoded: b64)
            } else if let rel = part["appPath"] as? String {
                payload = try Data(contentsOf: ZinoPaths.resolve(rel))
            }
            guard let payload else { throw ZinoError("INVALID_ARGUMENT", "Multipart part \(name) has no data.") }
            append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            append("Content-Type: \(contentType)\r\n\r\n")
            data.append(payload)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return data
    }

    private func headerDict(_ http: HTTPURLResponse?) -> [String: String] {
        var out: [String: String] = [:]
        http?.allHeaderFields.forEach { k, v in out[String(describing: k).lowercased()] = String(describing: v) }
        return out
    }

    // MARK: - Streaming

    private func performStream(id: String, req: URLRequest, call: CAPPluginCall, scrub: @escaping (String) -> String) async throws {
        let (bytes, response) = try await session.bytes(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if !(200..<300).contains(status) {
            // Error bodies are small JSON documents: read fully and return them.
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 1_000_000 { break } }
            call.resolve(["status": status, "headers": headerDict(http), "body": scrub(String(decoding: data, as: UTF8.self))])
            return
        }
        notifyListeners("httpStart", data: ["id": id, "status": status, "headers": headerDict(http)])
        var buffer = Data()
        var lastFlush = Date()
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            // Newlines are always UTF-8 boundaries, so flushing there never splits a character.
            if byte == 0x0A && (buffer.count > 2048 || Date().timeIntervalSince(lastFlush) > 0.03) {
                notifyListeners("httpChunk", data: ["id": id, "chunk": String(decoding: buffer, as: UTF8.self)])
                buffer.removeAll(keepingCapacity: true)
                lastFlush = Date()
            }
        }
        if !buffer.isEmpty {
            notifyListeners("httpChunk", data: ["id": id, "chunk": String(decoding: buffer, as: UTF8.self)])
        }
        call.resolve(["status": status, "headers": headerDict(http), "streamed": true])
    }

    // MARK: - Download to app storage (generated videos, 3D models)

    private func performDownload(req: URLRequest, call: CAPPluginCall, scrub: (String) -> String) async throws {
        guard let dest = call.getString("saveTo") else { throw ZinoError("INVALID_ARGUMENT", "saveTo is required for file responses.") }
        let destURL = try ZinoPaths.resolve(dest)
        let (tmp, response) = try await session.download(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: tmp)
            call.resolve(["status": status, "headers": headerDict(http), "body": scrub(String(body.prefix(100_000)))])
            return
        }
        try ZinoPaths.ensureParent(destURL)
        if FileManager.default.fileExists(atPath: destURL.path) {
            throw ZinoError("FILE_EXISTS", "Destination already exists.")
        }
        try FileManager.default.moveItem(at: tmp, to: destURL)
        let size = (try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        call.resolve(["status": status, "headers": headerDict(http), "path": dest, "size": size])
    }
}
