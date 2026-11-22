import Foundation

public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

public struct HTTPResponseData: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data
}

/// URLSession-based HTTP client with HTTPS validation, local-network exception for self-hosted servers,
/// SSE streaming support, and automatic secret redaction in errors.
public final class HTTPClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 600
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public static func validateURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw ZinoError(.invalidArgument, "URL is missing a scheme (use https://).")
        }
        if scheme == "https" { return }
        if scheme == "http", let host = url.host?.lowercased(), isLocalNetworkHost(host) {
            return
        }
        throw ZinoError(
            .networkFailure,
            "Insecure HTTP is blocked for remote hosts. Use HTTPS (HTTP is permitted only for local-network hosts such as localhost, 127.0.0.1, or .local)."
        )
    }

    public static func isLocalNetworkHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    public func data(for request: URLRequest) async throws -> HTTPResponseData {
        guard let url = request.url else {
            throw ZinoError(.invalidArgument, "Request URL is missing.")
        }
        try Self.validateURL(url)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ZinoError(.networkFailure, "Invalid server response.")
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                headers[String(describing: k).lowercased()] = String(describing: v)
            }
            return HTTPResponseData(statusCode: http.statusCode, headers: headers, data: data)
        } catch let err as ZinoError {
            throw err
        } catch is CancellationError {
            throw ZinoError(.cancelled, "Request cancelled.")
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ZinoError(.cancelled, "Request cancelled.")
        } catch {
            throw ZinoError(.networkFailure, "Network request failed: \(SecretRedactor.redact(error.localizedDescription))")
        }
    }

    public func streamSSE(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = request.url else {
                        throw ZinoError(.invalidArgument, "Request URL is missing.")
                    }
                    try Self.validateURL(url)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ZinoError(.networkFailure, "Invalid streaming response.")
                    }

                    if !(200...299).contains(http.statusCode) {
                        var bodyBytes: [UInt8] = []
                        bodyBytes.reserveCapacity(4096)
                        for try await byte in bytes {
                            bodyBytes.append(byte)
                            if bodyBytes.count >= 16_384 { break }
                        }
                        let bodyText = String(bytes: bodyBytes, encoding: .utf8) ?? ""
                        let code: ZinoError.Code = (http.statusCode == 401 || http.statusCode == 403)
                            ? .authenticationFailure
                            : .networkFailure
                        throw ZinoError(code, "Provider returned HTTP \(http.statusCode): \(SecretRedactor.redact(bodyText.prefix(500).description))")
                    }

                    var currentEvent: String?
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            throw ZinoError(.cancelled, "Stream cancelled.")
                        }
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                continuation.yield(SSEEvent(event: currentEvent, data: payload))
                                currentEvent = nil
                                dataLines.removeAll(keepingCapacity: true)
                            }
                            continue
                        }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("event:") {
                            currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let raw = line.dropFirst(5)
                            let cleaned = raw.first == " " ? String(raw.dropFirst()) : String(raw)
                            dataLines.append(cleaned)
                        }
                    }

                    if !dataLines.isEmpty {
                        continuation.yield(SSEEvent(event: currentEvent, data: dataLines.joined(separator: "\n")))
                    }
                    continuation.finish()
                } catch let err as ZinoError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: ZinoError(.cancelled, "Stream cancelled."))
                } catch let urlErr as URLError where urlErr.code == .cancelled {
                    continuation.finish(throwing: ZinoError(.cancelled, "Stream cancelled."))
                } catch {
                    continuation.finish(throwing: ZinoError(.networkFailure, "Streaming error: \(SecretRedactor.redact(error.localizedDescription))"))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
