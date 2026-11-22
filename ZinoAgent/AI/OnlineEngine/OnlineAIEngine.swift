import Foundation
import Combine

/// Coordinates online AI chat streaming and image generation across configured providers.
@MainActor
public final class OnlineAIEngine: ObservableObject {
    @Published public private(set) var isStreaming: Bool = false

    private let providerRegistry: ProviderRegistry
    private var activeTask: Task<Void, Never>?

    public init(providerRegistry: ProviderRegistry) {
        self.providerRegistry = providerRegistry
    }

    public func streamChat(
        provider: ProviderConfiguration,
        request: OnlineChatRequest
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let adapter = providerRegistry.adapter(for: provider.providerType)
        let apiKey = providerRegistry.credential(for: provider)

        if provider.providerType.requiresAPIKey && (apiKey == nil || apiKey?.isEmpty == true) {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ZinoError(
                    .authenticationFailure,
                    "No API key saved in Keychain for '\(provider.name)'. Configure your key in Settings > AI Providers."
                ))
            }
        }

        isStreaming = true
        let inner = adapter.streamChat(request: request, config: provider, apiKey: apiKey)

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    Task { @MainActor in self.isStreaming = false }
                }
                do {
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.activeTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancelStreaming() {
        activeTask?.cancel()
        activeTask = nil
        isStreaming = false
    }

    public func generateImage(
        provider: ProviderConfiguration,
        request: OnlineImageRequest
    ) async throws -> [GeneratedImagePayload] {
        let adapter = providerRegistry.adapter(for: provider.providerType)
        guard adapter.supportsImageGeneration else {
            throw ZinoError(.unsupportedFormat, "'\(provider.name)' does not support image generation.")
        }
        let apiKey = providerRegistry.credential(for: provider)
        if provider.providerType.requiresAPIKey && (apiKey == nil || apiKey?.isEmpty == true) {
            throw ZinoError(.authenticationFailure, "No API key configured for '\(provider.name)'.")
        }
        return try await adapter.generateImage(request: request, config: provider, apiKey: apiKey)
    }
}
