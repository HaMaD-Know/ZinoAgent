import XCTest
@testable import ZinoAgent

final class ProviderAdapterTests: XCTestCase {
    func testOpenAIRequestAndSSEParsingWithToolCallAndUsage() throws {
        let adapter = OpenAIProviderAdapter(providerType: .openAI)
        let config = ProviderConfiguration(name: "OpenAI", providerType: .openAI)
        let req = OnlineChatRequest(
            modelID: "gpt-4o",
            messages: [
                ProviderChatMessage(role: .system, content: "Be concise."),
                ProviderChatMessage(role: .user, content: "List my files.")
            ],
            config: GenerationConfig(),
            tools: FileToolDefinitions.schemas(for: .confirm)
        )

        let urlReq = try adapter.buildChatURLRequest(request: req, config: config, apiKey: "sk-test-1234567890abcdef")
        XCTAssertEqual(urlReq.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-1234567890abcdef")

        var pending: [Int: (id: String, name: String, args: String)] = [:]
        let textEvent = #"{"choices":[{"delta":{"content":"Hello "},"finish_reason":null}]}"#
        let parsed1 = OpenAIProviderAdapter.parseSSEPayload(textEvent, pendingTools: &pending)
        if case let .text(s)? = parsed1.chunks.first {
            XCTAssertEqual(s, "Hello ")
        } else {
            XCTFail("Expected text delta chunk.")
        }

        let toolEvent = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list_files","arguments":"{\"relative_path\":\"\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":40,"completion_tokens":12}}"#
        let parsed2 = OpenAIProviderAdapter.parseSSEPayload(toolEvent, pendingTools: &pending)
        XCTAssertEqual(parsed2.finishReason, "tool_calls")
        XCTAssertEqual(pending[0]?.name, "list_files")
        XCTAssertTrue(parsed2.chunks.contains(where: {
            if case let .usage(u) = $0 { return u.promptTokens == 40 && u.completionTokens == 12 }
            return false
        }))
    }

    func testGeminiSendsKeyInHeaderNotQueryString() throws {
        let adapter = GeminiProviderAdapter()
        let config = ProviderConfiguration(name: "Gemini", providerType: .gemini)
        let req = OnlineChatRequest(
            modelID: "gemini-2.5-pro",
            messages: [ProviderChatMessage(role: .user, content: "Hi")],
            config: GenerationConfig()
        )
        let urlReq = try adapter.buildGenerateURLRequest(request: req, config: config, apiKey: "AIzaSyFakeKeyForUnitTestOnly12345")
        XCTAssertFalse(urlReq.url?.absoluteString.contains("AIza") ?? true, "API key must never be placed in URL query parameters.")
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "x-goog-api-key"), "AIzaSyFakeKeyForUnitTestOnly12345")
    }

    func testSecretRedactorScrubsKeysFromLogsAndErrors() {
        let fakeKey = "sk-ant-api03-secretvalue1234567890"
        SecretRedactor.register(secret: fakeKey)
        let err = ZinoError(.networkFailure, "Failed with key \(fakeKey) and Bearer tok_abcdefghijk123456")
        XCTAssertFalse(err.message.contains(fakeKey))
        XCTAssertTrue(err.message.contains("[REDACTED]"))
    }

    func testHTTPClientBlocksInsecureRemoteHTTPButAllowsLocalhost() throws {
        XCTAssertThrowsError(try HTTPClient.validateURL(URL(string: "http://api.example.com/v1/models")!))
        XCTAssertNoThrow(try HTTPClient.validateURL(URL(string: "https://api.openai.com/v1/models")!))
        XCTAssertNoThrow(try HTTPClient.validateURL(URL(string: "http://localhost:11434/v1/models")!))
        XCTAssertNoThrow(try HTTPClient.validateURL(URL(string: "http://192.168.1.42:1234/v1/models")!))
    }
}
