import Foundation

/// Adapter for Google Gemini API (`https://generativelanguage.googleapis.com/v1beta`).
/// Sends API keys via the `x-goog-api-key` HTTP header (never in URL query parameters).
public final class GeminiProviderAdapter: OnlineAIProviderAdapter {
    public let providerType: ProviderType = .gemini
    public let supportsModelDiscovery = true
    public let supportsStreaming = true
    public let supportsVision = true
    public let supportsImageGeneration = true

    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func testConnection(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor] {
        try await fetchModels(config: config, apiKey: apiKey)
    }

    public func fetchModels(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor] {
        guard let apiKey, !apiKey.isEmpty else {
            throw ZinoError(.authenticationFailure, "Google Gemini API key is required.")
        }
        guard let url = URL(string: "\(config.baseURL)/models?pageSize=100") else {
            throw ZinoError(.invalidArgument, "Invalid Gemini base URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let code: ZinoError.Code = (resp.statusCode == 401 || resp.statusCode == 403) ? .authenticationFailure : .networkFailure
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(300) ?? ""
            throw ZinoError(code, "Gemini model discovery failed (HTTP \(resp.statusCode)): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "Unexpected response from Gemini /models.")
        }

        return list.compactMap { item -> AIModelDescriptor? in
            guard let fullName = item["name"] as? String else { return nil }
            let id = fullName.replacingOccurrences(of: "models/", with: "")
            let methods = (item["supportedGenerationMethods"] as? [String]) ?? []
            let supportsGen = methods.contains("generateContent")
            let supportsPredict = methods.contains("predict") || id.lowercased().contains("imagen") || id.lowercased().contains("image")
            guard supportsGen || supportsPredict else { return nil }
            let display = (item["displayName"] as? String) ?? id
            let inputLimit = (item["inputTokenLimit"] as? Int) ?? 128_000
            let lower = id.lowercased()
            let hasFreeTier = lower.contains("flash") || lower.contains("gemma") || lower.contains("lite")
            return AIModelDescriptor(
                id: id,
                displayName: display,
                contextWindow: inputLimit,
                supportsVision: supportsGen,
                supportsTools: supportsGen,
                supportsImageGeneration: supportsPredict,
                pricingTier: hasFreeTier ? .free : .paid,
                pricingLabel: hasFreeTier ? "Free Tier Available" : "Paid Tier"
            )
        }
    }

    public func streamChat(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildGenerateURLRequest(request: request, config: config, apiKey: apiKey)
                    var stopReason = "STOP"

                    for try await event in http.streamSSE(for: urlRequest) {
                        guard let data = event.data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        if let usage = json["usageMetadata"] as? [String: Any],
                           let prompt = usage["promptTokenCount"] as? Int {
                            let completion = (usage["candidatesTokenCount"] as? Int) ?? 0
                            continuation.yield(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion)))
                        }

                        if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
                            if let reason = first["finishReason"] as? String {
                                stopReason = reason
                            }
                            if let content = first["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]] {
                                for part in parts {
                                    if let thought = part["thought"] as? Bool, thought, let text = part["text"] as? String {
                                        continuation.yield(.thinking(text))
                                    } else if let text = part["text"] as? String, !text.isEmpty {
                                        continuation.yield(.text(text))
                                    } else if let fnCall = part["functionCall"] as? [String: Any],
                                              let name = fnCall["name"] as? String {
                                        let argsObj = fnCall["args"] ?? [:]
                                        let argsData = (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data("{}".utf8)
                                        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                                        continuation.yield(.toolCall(ToolCallRequest(name: name, argumentsJSON: argsJSON)))
                                    }
                                }
                            }
                        }
                    }

                    continuation.yield(.done(stopReason: stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateImage(request: OnlineImageRequest, config: ProviderConfiguration, apiKey: String?) async throws -> [GeneratedImagePayload] {
        guard let apiKey, !apiKey.isEmpty else {
            throw ZinoError(.authenticationFailure, "Google Gemini API key is required.")
        }

        let cleanModel = request.modelID.replacingOccurrences(of: "models/", with: "")
        let isImagen = cleanModel.lowercased().contains("imagen")

        if isImagen {
            guard let url = URL(string: "\(config.baseURL)/models/\(cleanModel):predict") else {
                throw ZinoError(.invalidArgument, "Invalid Imagen endpoint URL.")
            }
            let ratio = Self.closestAspectRatio(width: request.width, height: request.height)
            let body: [String: Any] = [
                "instances": [["prompt": request.prompt]],
                "parameters": ["sampleCount": 1, "aspectRatio": ratio]
            ]
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let resp = try await http.data(for: req)
            guard (200...299).contains(resp.statusCode) else {
                let detail = String(data: resp.data, encoding: .utf8)?.prefix(350) ?? ""
                throw ZinoError(.networkFailure, "Imagen generation failed (HTTP \(resp.statusCode)): \(detail)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
                  let preds = json["predictions"] as? [[String: Any]] else {
                throw ZinoError(.networkFailure, "Unexpected Imagen response.")
            }
            var out: [GeneratedImagePayload] = []
            for p in preds {
                if let b64 = p["bytesBase64Encoded"] as? String, let data = Data(base64Encoded: b64) {
                    let mime = (p["mimeType"] as? String) ?? "image/png"
                    out.append(GeneratedImagePayload(imageData: data, mimeType: mime, revisedPrompt: nil))
                }
            }
            guard !out.isEmpty else { throw ZinoError(.networkFailure, "Imagen returned no images.") }
            return out
        } else {
            // Gemini native multimodal image generation (`responseModalities: ["IMAGE", "TEXT"]`).
            guard let url = URL(string: "\(config.baseURL)/models/\(cleanModel):generateContent") else {
                throw ZinoError(.invalidArgument, "Invalid Gemini image generation URL.")
            }
            let body: [String: Any] = [
                "contents": [["role": "user", "parts": [["text": request.prompt]]]],
                "generationConfig": ["responseModalities": ["IMAGE", "TEXT"]]
            ]
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let resp = try await http.data(for: req)
            guard (200...299).contains(resp.statusCode) else {
                let detail = String(data: resp.data, encoding: .utf8)?.prefix(350) ?? ""
                throw ZinoError(.networkFailure, "Gemini image generation failed (HTTP \(resp.statusCode)): \(detail)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]] else {
                throw ZinoError(.networkFailure, "Unexpected Gemini image response.")
            }
            var out: [GeneratedImagePayload] = []
            for cand in candidates {
                if let content = cand["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let inline = part["inlineData"] as? [String: Any],
                           let b64 = inline["data"] as? String,
                           let data = Data(base64Encoded: b64) {
                            let mime = (inline["mimeType"] as? String) ?? "image/png"
                            out.append(GeneratedImagePayload(imageData: data, mimeType: mime, revisedPrompt: nil))
                        }
                    }
                }
            }
            guard !out.isEmpty else {
                throw ZinoError(.networkFailure, "Selected Gemini model did not return an image. Choose an Imagen or Gemini image-capable model.")
            }
            return out
        }
    }

    public func buildGenerateURLRequest(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else {
            throw ZinoError(.authenticationFailure, "Google Gemini API key is required.")
        }
        let cleanModel = request.modelID.replacingOccurrences(of: "models/", with: "")
        guard let url = URL(string: "\(config.baseURL)/models/\(cleanModel):streamGenerateContent?alt=sse") else {
            throw ZinoError(.invalidArgument, "Invalid Gemini stream URL.")
        }

        let systemText = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var contents: [[String: Any]] = []
        for msg in request.messages where msg.role != .system {
            let role = msg.role == .assistant ? "model" : "user"
            var parts: [[String: Any]] = []
            if msg.role == .tool, let toolName = msg.toolName {
                parts.append([
                    "functionResponse": [
                        "name": toolName,
                        "response": ["result": msg.content]
                    ]
                ])
            } else {
                if !msg.content.isEmpty {
                    parts.append(["text": msg.content])
                }
                for img in msg.images {
                    parts.append([
                        "inlineData": [
                            "mimeType": img.mimeType,
                            "data": img.base64Data
                        ]
                    ])
                }
            }
            contents.append(["role": role, "parts": parts])
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": request.config.temperature,
                "topP": request.config.topP,
                "maxOutputTokens": request.config.maxTokens
            ]
        ]
        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }
        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersFoundationDictionary
                    ]
                }
            ]]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func closestAspectRatio(width: Int, height: Int) -> String {
        guard height > 0 else { return "1:1" }
        let ratio = Double(width) / Double(height)
        if ratio > 1.5 { return "16:9" }
        if ratio > 1.15 { return "4:3" }
        if ratio < 0.65 { return "9:16" }
        if ratio < 0.85 { return "3:4" }
        return "1:1"
    }
}
