import Foundation

/// Adapter for OpenAI, OpenRouter (with Free/Paid model pricing metadata), and OpenAI-compatible endpoints
/// (Ollama, LM Studio, Groq, Together, custom servers).
public final class OpenAIProviderAdapter: OnlineAIProviderAdapter {
    public let providerType: ProviderType
    public let supportsModelDiscovery = true
    public let supportsStreaming = true
    public let supportsVision = true
    public let supportsImageGeneration: Bool

    private let http: HTTPClient

    public init(providerType: ProviderType = .openAI, http: HTTPClient = HTTPClient()) {
        self.providerType = providerType
        self.supportsImageGeneration = (providerType == .openAI || providerType == .openAICompatible || providerType == .openRouter)
        self.http = http
    }

    public func testConnection(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor] {
        try await fetchModels(config: config, apiKey: apiKey)
    }

    public func fetchModels(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor] {
        guard let url = URL(string: "\(config.baseURL)/models") else {
            throw ZinoError(.invalidArgument, "Invalid provider base URL: \(config.baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req, apiKey: apiKey)

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let code: ZinoError.Code = (resp.statusCode == 401 || resp.statusCode == 403) ? .authenticationFailure : .networkFailure
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(300) ?? ""
            throw ZinoError(code, "Model discovery failed (HTTP \(resp.statusCode)): \(detail)")
        }

        let isLocalServer = URL(string: config.baseURL)?.host.map(HTTPClient.isLocalNetworkHost) ?? false
        return try Self.parseModelsResponse(data: resp.data, providerType: providerType, isLocalServer: isLocalServer)
    }

    public static func parseModelsResponse(
        data: Data,
        providerType: ProviderType,
        isLocalServer: Bool = false
    ) throws -> [AIModelDescriptor] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "Unexpected response format from /models endpoint.")
        }

        return list.compactMap { item -> AIModelDescriptor? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String)?.isEmpty == false ? (item["name"] as! String) : id
            let lower = id.lowercased()
            let isImageModel = lower.contains("dall-e") || lower.contains("gpt-image") || lower.contains("flux") || lower.contains("imagen")

            var isVision = lower.contains("gpt-4") || lower.contains("gpt-5") || lower.contains("o1") || lower.contains("o3") || lower.contains("o4") || lower.contains("vision") || lower.contains("llava") || lower.contains("claude-3") || lower.contains("claude-sonnet-4") || lower.contains("claude-opus-4") || lower.contains("gemini")
            if let arch = item["architecture"] as? [String: Any],
               let modality = (arch["modality"] as? String)?.lowercased() {
                if modality.contains("image") { isVision = true }
            }

            let ctx = (item["context_length"] as? Int)
                ?? ((item["top_provider"] as? [String: Any])?["context_length"] as? Int)
                ?? (lower.contains("gpt-4o") || lower.contains("gpt-4.1") || lower.contains("o3") ? 128_000 : 32_768)

            // Determine Free vs Paid tier accurately.
            let tier: ModelPricingTier
            let pricingLabel: String?

            if let pricing = item["pricing"] as? [String: Any] {
                let promptVal = Double("\(pricing["prompt"] ?? "")") ?? -1
                let compVal = Double("\(pricing["completion"] ?? "")") ?? -1
                if lower.hasSuffix(":free") || (promptVal == 0 && compVal == 0) {
                    tier = .free
                    pricingLabel = "Free"
                } else if promptVal >= 0 && compVal >= 0 {
                    tier = .paid
                    let inPerM = promptVal * 1_000_000
                    let outPerM = compVal * 1_000_000
                    pricingLabel = String(format: "$%.2f / $%.2f per 1M", inPerM, outPerM)
                } else {
                    tier = lower.hasSuffix(":free") ? .free : .paid
                    pricingLabel = tier == .free ? "Free" : "Paid"
                }
            } else if providerType == .openAICompatible && isLocalServer {
                tier = .free
                pricingLabel = "Local (Free)"
            } else if lower.hasSuffix(":free") || lower.contains("-free") {
                tier = .free
                pricingLabel = "Free"
            } else {
                tier = .paid
                pricingLabel = "Paid API"
            }

            return AIModelDescriptor(
                id: id,
                displayName: name,
                contextWindow: ctx,
                supportsVision: isVision,
                supportsTools: !isImageModel,
                supportsImageGeneration: isImageModel,
                pricingTier: tier,
                pricingLabel: pricingLabel
            )
        }.sorted { a, b in
            if a.pricingTier != b.pricingTier { return a.pricingTier == .free }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    public func streamChat(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildChatURLRequest(request: request, config: config, apiKey: apiKey)
                    var pendingTools: [Int: (id: String, name: String, args: String)] = [:]
                    var finishReason = "stop"

                    for try await event in http.streamSSE(for: urlRequest) {
                        if event.data == "[DONE]" { break }
                        let parsed = Self.parseSSEPayload(event.data, pendingTools: &pendingTools)
                        for chunk in parsed.chunks {
                            continuation.yield(chunk)
                        }
                        if let reason = parsed.finishReason {
                            finishReason = reason
                        }
                    }

                    for key in pendingTools.keys.sorted() {
                        if let tool = pendingTools[key], !tool.name.isEmpty {
                            continuation.yield(.toolCall(ToolCallRequest(
                                id: tool.id.isEmpty ? UUID().uuidString : tool.id,
                                name: tool.name,
                                argumentsJSON: tool.args.isEmpty ? "{}" : tool.args
                            )))
                        }
                    }

                    continuation.yield(.done(stopReason: finishReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateImage(request: OnlineImageRequest, config: ProviderConfiguration, apiKey: String?) async throws -> [GeneratedImagePayload] {
        guard let url = URL(string: "\(config.baseURL)/images/generations") else {
            throw ZinoError(.invalidArgument, "Invalid image generation URL.")
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "prompt": request.prompt,
            "n": 1,
            "size": "\(request.width)x\(request.height)"
        ]
        if !request.modelID.lowercased().contains("gpt-image") {
            body["response_format"] = "b64_json"
        }
        if let quality = request.quality, !quality.isEmpty {
            body["quality"] = quality
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, apiKey: apiKey)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(400) ?? ""
            throw ZinoError(.networkFailure, "Image generation failed (HTTP \(resp.statusCode)): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "Unexpected image generation response.")
        }

        var results: [GeneratedImagePayload] = []
        for item in items {
            let revised = item["revised_prompt"] as? String
            if let b64 = item["b64_json"] as? String, let data = Data(base64Encoded: b64) {
                results.append(GeneratedImagePayload(imageData: data, mimeType: "image/png", revisedPrompt: revised))
            } else if let urlStr = item["url"] as? String, let imgURL = URL(string: urlStr) {
                let imgResp = try await http.data(for: URLRequest(url: imgURL))
                results.append(GeneratedImagePayload(imageData: imgResp.data, mimeType: "image/png", revisedPrompt: revised))
            }
        }
        guard !results.isEmpty else {
            throw ZinoError(.networkFailure, "Provider returned no image data.")
        }
        return results
    }

    // MARK: - Request & SSE Parsing (Internal for Unit Testing)

    public func buildChatURLRequest(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) throws -> URLRequest {
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw ZinoError(.invalidArgument, "Invalid chat completions URL.")
        }
        var payloadMessages: [[String: Any]] = []
        for msg in request.messages {
            if !msg.images.isEmpty && msg.role == .user {
                var parts: [[String: Any]] = [["type": "text", "text": msg.content]]
                for img in msg.images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64Data)"]
                    ])
                }
                payloadMessages.append(["role": msg.role.rawValue, "content": parts])
            } else if msg.role == .tool, let callID = msg.toolCallID {
                payloadMessages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": msg.content
                ])
            } else {
                payloadMessages.append(["role": msg.role.rawValue, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "messages": payloadMessages,
            "stream": true,
            "temperature": request.config.temperature,
            "max_tokens": request.config.maxTokens
        ]
        if providerType == .openAI {
            body["stream_options"] = ["include_usage": true]
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersFoundationDictionary
                    ]
                ]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, apiKey: apiKey)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public static func parseSSEPayload(
        _ jsonString: String,
        pendingTools: inout [Int: (id: String, name: String, args: String)]
    ) -> (chunks: [StreamChunk], finishReason: String?) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }

        var chunks: [StreamChunk] = []
        var finishReason: String?

        if let usage = json["usage"] as? [String: Any],
           let prompt = usage["prompt_tokens"] as? Int,
           let completion = usage["completion_tokens"] as? Int {
            chunks.append(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion)))
        }

        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let reason = first["finish_reason"] as? String {
                finishReason = reason
            }
            if let delta = first["delta"] as? [String: Any] {
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    chunks.append(.thinking(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    chunks.append(.text(content))
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        let idx = (tc["index"] as? Int) ?? 0
                        var entry = pendingTools[idx] ?? (id: "", name: "", args: "")
                        if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String { entry.name += name }
                            if let args = fn["arguments"] as? String { entry.args += args }
                        }
                        pendingTools[idx] = entry
                    }
                }
            }
        }
        return (chunks, finishReason)
    }

    private func applyAuth(_ request: inout URLRequest, apiKey: String?) {
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if providerType == .openRouter {
            request.setValue("https://zinoagent.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("ZinoAgent 2.0", forHTTPHeaderField: "X-Title")
        }
    }
}
