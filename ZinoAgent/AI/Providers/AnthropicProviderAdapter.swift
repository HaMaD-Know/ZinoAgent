import Foundation

/// Adapter for Anthropic's official Messages API (`https://api.anthropic.com/v1/messages`).
public final class AnthropicProviderAdapter: OnlineAIProviderAdapter {
    public let providerType: ProviderType = .anthropic
    public let supportsModelDiscovery = true
    public let supportsStreaming = true
    public let supportsVision = true
    public let supportsImageGeneration = false

    private let apiVersion = "2023-06-01"
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func testConnection(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor] {
        try await fetchModels(config: config, apiKey: apiKey)
    }

    public func fetchModels(config: ProviderConfiguration, apiKey: String?) async throws -> [AIModelDescriptor] {
        guard let apiKey, !apiKey.isEmpty else {
            throw ZinoError(.authenticationFailure, "Anthropic API key is required.")
        }
        guard let url = URL(string: "\(config.baseURL)/models") else {
            throw ZinoError(.invalidArgument, "Invalid Anthropic base URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let code: ZinoError.Code = (resp.statusCode == 401 || resp.statusCode == 403) ? .authenticationFailure : .networkFailure
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(300) ?? ""
            throw ZinoError(code, "Anthropic model listing failed (HTTP \(resp.statusCode)): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "Unexpected response from Anthropic /models.")
        }

        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let display = (item["display_name"] as? String) ?? id
            return AIModelDescriptor(
                id: id,
                displayName: display,
                contextWindow: 200_000,
                supportsVision: true,
                supportsTools: true,
                supportsImageGeneration: false
            )
        }
    }

    public func streamChat(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildMessagesURLRequest(request: request, config: config, apiKey: apiKey)
                    var inputTokens = 0
                    var outputTokens = 0
                    var stopReason = "end_turn"
                    var activeTool: (id: String, name: String, args: String)?

                    for try await event in http.streamSSE(for: urlRequest) {
                        guard let data = event.data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        let eventType = event.event ?? (json["type"] as? String) ?? ""
                        switch eventType {
                        case "message_start":
                            if let msg = json["message"] as? [String: Any],
                               let usage = msg["usage"] as? [String: Any],
                               let inp = usage["input_tokens"] as? Int {
                                inputTokens = inp
                            }
                        case "content_block_start":
                            if let block = json["content_block"] as? [String: Any],
                               (block["type"] as? String) == "tool_use",
                               let id = block["id"] as? String,
                               let name = block["name"] as? String {
                                activeTool = (id, name, "")
                            }
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let deltaType = delta["type"] as? String {
                                if deltaType == "text_delta", let text = delta["text"] as? String {
                                    continuation.yield(.text(text))
                                } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                                    continuation.yield(.thinking(thinking))
                                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                                    activeTool?.args += partial
                                }
                            }
                        case "content_block_stop":
                            if let tool = activeTool {
                                continuation.yield(.toolCall(ToolCallRequest(
                                    id: tool.id,
                                    name: tool.name,
                                    argumentsJSON: tool.args.isEmpty ? "{}" : tool.args
                                )))
                                activeTool = nil
                            }
                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }
                            if let usage = json["usage"] as? [String: Any],
                               let out = usage["output_tokens"] as? Int {
                                outputTokens = out
                            }
                        case "error":
                            let errObj = json["error"] as? [String: Any]
                            let msg = (errObj?["message"] as? String) ?? "Anthropic stream error."
                            throw ZinoError(.networkFailure, msg)
                        default:
                            break
                        }
                    }

                    if inputTokens > 0 || outputTokens > 0 {
                        continuation.yield(.usage(TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)))
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
        throw ZinoError(.unsupportedFormat, "Anthropic does not provide a native image generation endpoint.")
    }

    public func buildMessagesURLRequest(request: OnlineChatRequest, config: ProviderConfiguration, apiKey: String?) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else {
            throw ZinoError(.authenticationFailure, "Anthropic API key is required.")
        }
        guard let url = URL(string: "\(config.baseURL)/messages") else {
            throw ZinoError(.invalidArgument, "Invalid Anthropic messages URL.")
        }

        let systemText = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var anthropicMessages: [[String: Any]] = []
        for msg in request.messages where msg.role != .system {
            if msg.role == .tool, let callID = msg.toolCallID {
                anthropicMessages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": callID,
                        "content": msg.content
                    ]]
                ])
            } else if !msg.images.isEmpty && msg.role == .user {
                var blocks: [[String: Any]] = []
                for img in msg.images {
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": img.mimeType,
                            "data": img.base64Data
                        ]
                    ])
                }
                blocks.append(["type": "text", "text": msg.content])
                anthropicMessages.append(["role": "user", "content": blocks])
            } else {
                let role = msg.role == .assistant ? "assistant" : "user"
                anthropicMessages.append(["role": role, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "max_tokens": request.config.maxTokens,
            "stream": true,
            "messages": anthropicMessages
        ]
        if !systemText.isEmpty {
            body["system"] = systemText
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parametersFoundationDictionary
                ]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}
