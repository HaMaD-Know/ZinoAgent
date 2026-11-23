import Foundation
import Combine
#if canImport(llama)
import llama
#endif

public struct LocalModelRuntimeInfo: Sendable, Equatable {
    public let modelID: String
    public let modelName: String
    public let architecture: String
    public let contextLength: Int
    public let trainedContextLength: Int
    public let gpuOffloadEnabled: Bool
    public let loadDurationMs: Int
}

public struct LocalBenchmarkResult: Sendable, Equatable {
    public let promptTokens: Int
    public let promptTokensPerSecond: Double
    public let generatedTokens: Int
    public let generationTokensPerSecond: Double
}

public enum LocalModelLoadState: Equatable, Sendable {
    case unloaded
    case loading(modelName: String, progress: Double)
    case loaded(LocalModelRuntimeInfo)
    case failed(String)

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// Offline GGUF inference engine powered by llama.cpp with Metal GPU acceleration.
/// Uses per-generation cancellation IDs (eliminating cross-turn cancellation races),
/// normalizes chat turns for all GGUF templates (Qwen, Llama, Gemma, Phi, Mistral),
/// automatically recovers KV-cache mismatches, and safely handles context headroom.
@MainActor
public final class LlamaCppEngine: ObservableObject {
    @Published public private(set) var loadState: LocalModelLoadState = .unloaded
    @Published public private(set) var loadedModel: LocalModelRecord?
    @Published public private(set) var isGenerating: Bool = false

    private let worker = LlamaWorker()
    private var currentGenerationID: UUID?

    public init() {}

    public static var isRuntimeCompiledIn: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    /// Normalizes chat messages so strict GGUF Jinja templates (Gemma, Mistral, Llama-3, Phi-3, Qwen)
    /// never fail on multiple `system` messages, `tool` roles, or consecutive same-role turns.
    public nonisolated static func normalizeMessagesForLocalTemplate(
        _ messages: [ChatTemplateFormatter.PromptMessage]
    ) -> [ChatTemplateFormatter.PromptMessage] {
        var systemParts: [String] = []
        var turns: [ChatTemplateFormatter.PromptMessage] = []

        for msg in messages {
            let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let roleLower = msg.role.lowercased()
            if roleLower == "system" {
                systemParts.append(trimmed)
                continue
            }

            let normalizedRole: String
            let normalizedContent: String
            if roleLower == "tool" {
                normalizedRole = "user"
                normalizedContent = "[Tool Result]\n\(trimmed)"
            } else if roleLower == "assistant" {
                normalizedRole = "assistant"
                normalizedContent = trimmed
            } else {
                normalizedRole = "user"
                normalizedContent = trimmed
            }

            if let last = turns.last, last.role == normalizedRole {
                turns[turns.count - 1] = ChatTemplateFormatter.PromptMessage(
                    role: normalizedRole,
                    content: last.content + "\n\n" + normalizedContent
                )
            } else {
                turns.append(ChatTemplateFormatter.PromptMessage(role: normalizedRole, content: normalizedContent))
            }
        }

        var result: [ChatTemplateFormatter.PromptMessage] = []
        if !systemParts.isEmpty {
            result.append(ChatTemplateFormatter.PromptMessage(role: "system", content: systemParts.joined(separator: "\n\n")))
        }
        result.append(contentsOf: turns)
        return result
    }

    public func loadModel(
        _ model: LocalModelRecord,
        fileURL: URL,
        contextLength: Int,
        useMetalGPU: Bool
    ) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ZinoError(.fileNotFound, "Model file '\(model.filename)' is missing from app storage.")
        }
        guard model.compatibilityStatus.canAttemptLoad else {
            throw ZinoError(.incompatibleModel, model.compatibilityNotes)
        }

        await unload()
        loadState = .loading(modelName: model.name, progress: 0.02)

        do {
            let info = try await worker.load(
                modelID: model.id,
                modelName: model.name,
                architecture: model.architecture,
                path: fileURL.path,
                nCtx: contextLength,
                useMetalGPU: useMetalGPU
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.loadState = .loading(modelName: model.name, progress: Double(progress))
                }
            }
            loadedModel = model
            loadState = .loaded(info)
            AppLogger.shared.info("OfflineAI", "Loaded '\(model.name)' (ctx=\(info.contextLength), Metal=\(info.gpuOffloadEnabled)) in \(info.loadDurationMs)ms")
        } catch {
            loadedModel = nil
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    public func unload() async {
        cancelGeneration()
        await worker.unload()
        loadedModel = nil
        isGenerating = false
        loadState = .unloaded
        AppLogger.shared.info("OfflineAI", "Unloaded local model and freed memory.")
    }

    public func cancelGeneration() {
        if let id = currentGenerationID {
            worker.cancel(generationID: id)
            currentGenerationID = nil
        }
        isGenerating = false
    }

    /// Exact token count using the currently loaded GGUF model's tokenizer (nil if no model is loaded).
    public func exactTokenCount(for text: String) async -> Int? {
        await worker.tokenCount(for: text)
    }

    public func runBenchmark(promptTokens: Int = 128, genTokens: Int = 48) async throws -> LocalBenchmarkResult {
        try await worker.benchmark(promptTokens: promptTokens, genTokens: genTokens)
    }

    public func streamChat(
        messages: [ChatTemplateFormatter.PromptMessage],
        config: GenerationConfig
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let modelArch = loadedModel?.architecture ?? "chatml"
        let normalized = Self.normalizeMessagesForLocalTemplate(messages)
        let genID = UUID()

        // Cancel any previous generation strictly by its own ID (never clobbering `genID`).
        if let prevID = currentGenerationID {
            worker.cancel(generationID: prevID)
        }
        currentGenerationID = genID
        isGenerating = true

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    Task { @MainActor in
                        if self.currentGenerationID == genID {
                            self.currentGenerationID = nil
                            self.isGenerating = false
                        }
                    }
                }
                do {
                    let result = try await self.worker.generate(
                        generationID: genID,
                        messages: normalized,
                        architecture: modelArch,
                        config: config
                    ) { tokenPiece in
                        continuation.yield(.text(tokenPiece))
                    }
                    continuation.yield(.usage(result.usage))
                    continuation.yield(.done(stopReason: result.stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                self.worker.cancel(generationID: genID)
                task.cancel()
            }
        }
    }
}

// MARK: - Thread-Safe Serial Worker

private final class LlamaWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zinoagent.llama.worker", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var cancelledIDs: Set<UUID> = []

    #if canImport(llama)
    private static var backendInitialized = false
    private var runtime: LlamaNativeRuntime?
    #endif

    func cancel(generationID: UUID) {
        cancelLock.lock()
        cancelledIDs.insert(generationID)
        cancelLock.unlock()
    }

    private func cleanupCancel(generationID: UUID) {
        cancelLock.lock()
        cancelledIDs.remove(generationID)
        cancelLock.unlock()
    }

    private func isCancelled(_ generationID: UUID) -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelledIDs.contains(generationID)
    }

    func load(
        modelID: String,
        modelName: String,
        architecture: String,
        path: String,
        nCtx: Int,
        useMetalGPU: Bool,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> LocalModelRuntimeInfo {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                #if canImport(llama)
                if !Self.backendInitialized {
                    llama_backend_init()
                    Self.backendInitialized = true
                }
                self.runtime = nil
                let started = Date()
                #if targetEnvironment(simulator)
                let gpuLayers = 0
                #else
                let gpuLayers = useMetalGPU ? 999 : 0
                #endif
                let threads = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
                do {
                    let rt = try LlamaNativeRuntime(
                        path: path,
                        nCtx: nCtx,
                        nBatch: 512,
                        nThreads: threads,
                        gpuLayers: gpuLayers,
                        flashAttention: true,
                        onProgress: onProgress
                    )
                    self.runtime = rt
                    let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                    let info = LocalModelRuntimeInfo(
                        modelID: modelID,
                        modelName: modelName,
                        architecture: rt.meta("general.architecture") ?? architecture,
                        contextLength: rt.nCtx,
                        trainedContextLength: Int(llama_model_n_ctx_train(rt.model)),
                        gpuOffloadEnabled: gpuLayers > 0 && llama_supports_gpu_offload(),
                        loadDurationMs: elapsedMs
                    )
                    cont.resume(returning: info)
                } catch {
                    cont.resume(throwing: error)
                }
                #else
                cont.resume(throwing: ZinoError(
                    .modelLoadFailed,
                    "llama.xcframework is not linked in this build. Run scripts/build-llama-xcframework.sh (or build via GitHub Actions) to enable Metal-accelerated local inference."
                ))
                #endif
            }
        }
    }

    func unload() async {
        await withCheckedContinuation { cont in
            queue.async {
                #if canImport(llama)
                self.runtime = nil
                #endif
                cont.resume()
            }
        }
    }

    func tokenCount(for text: String) async -> Int? {
        await withCheckedContinuation { cont in
            queue.async {
                #if canImport(llama)
                guard let rt = self.runtime else { cont.resume(returning: nil); return }
                cont.resume(returning: rt.tokenize(text, addSpecial: false).count)
                #else
                cont.resume(returning: nil)
                #endif
            }
        }
    }

    func generate(
        generationID: UUID,
        messages: [ChatTemplateFormatter.PromptMessage],
        architecture: String,
        config: GenerationConfig,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> (usage: TokenUsage, stopReason: String) {
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                defer { self.cleanupCancel(generationID: generationID) }
                #if canImport(llama)
                guard let rt = self.runtime else {
                    cont.resume(throwing: ZinoError(.modelNotLoaded, "No local model is loaded. Open Models to load a GGUF model."))
                    return
                }
                let prompt: String
                let stops: [String]
                let pairs = messages.map { ($0.role, $0.content) }
                if let templated = rt.applyTemplate(pairs, addAssistant: true),
                   !templated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prompt = templated
                    stops = ["<|im_end|>", "<|eot_id|>", "<end_of_turn>", "<|end|>", "<|endoftext|>"]
                } else {
                    let formatted = ChatTemplateFormatter.fallbackFormat(messages: messages, architecture: architecture)
                    prompt = formatted.prompt
                    stops = formatted.stopSequences
                }

                do {
                    let result = try rt.generate(
                        prompt: prompt,
                        config: config,
                        stopSequences: stops,
                        isCancelled: { self.isCancelled(generationID) },
                        onText: onText
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
                #else
                cont.resume(throwing: ZinoError(.modelNotLoaded, "llama.xcframework is not linked in this build."))
                #endif
            }
        }
    }

    func benchmark(promptTokens: Int, genTokens: Int) async throws -> LocalBenchmarkResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                #if canImport(llama)
                guard let rt = self.runtime else {
                    cont.resume(throwing: ZinoError(.modelNotLoaded, "Load a local model before running a benchmark."))
                    return
                }
                do {
                    cont.resume(returning: try rt.benchmark(promptTokens: promptTokens, genTokens: genTokens))
                } catch {
                    cont.resume(throwing: error)
                }
                #else
                cont.resume(throwing: ZinoError(.modelNotLoaded, "llama.xcframework is not linked in this build."))
                #endif
            }
        }
    }
}

#if canImport(llama)
private final class LlamaProgressBox {
    let handler: (Float) -> Void
    var lastReported: Float = -1
    init(_ handler: @escaping (Float) -> Void) { self.handler = handler }
}

/// Direct llama.cpp C API runtime verified against llama.cpp tag `b12020`.
private final class LlamaNativeRuntime {
    let model: OpaquePointer
    let ctx: OpaquePointer
    let vocab: OpaquePointer
    let nCtx: Int
    let nBatch: Int
    private var cachedTokens: [llama_token] = []

    init(
        path: String,
        nCtx: Int,
        nBatch: Int,
        nThreads: Int,
        gpuLayers: Int,
        flashAttention: Bool,
        onProgress: @escaping (Float) -> Void
    ) throws {
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(gpuLayers)

        let box = LlamaProgressBox(onProgress)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<LlamaProgressBox>.fromOpaque(boxPtr).release() }
        mparams.progress_callback = { progress, userData in
            guard let userData else { return true }
            let b = Unmanaged<LlamaProgressBox>.fromOpaque(userData).takeUnretainedValue()
            if progress - b.lastReported >= 0.05 || progress >= 1.0 {
                b.lastReported = progress
                b.handler(progress)
            }
            return true
        }
        mparams.progress_callback_user_data = boxPtr

        guard let m = llama_model_load_from_file(path, mparams) else {
            throw ZinoError(
                .modelLoadFailed,
                "llama.cpp could not load this model. The architecture or quantization may be unsupported, or memory was exhausted."
            )
        }

        var cparams = llama_context_default_params()
        let trained = Int(llama_model_n_ctx_train(m))
        let effectiveCtx = trained > 0 ? min(nCtx, trained) : nCtx
        cparams.n_ctx = UInt32(max(512, effectiveCtx))
        cparams.n_batch = UInt32(nBatch)
        cparams.n_ubatch = UInt32(min(nBatch, 512))
        cparams.n_threads = Int32(nThreads)
        cparams.n_threads_batch = Int32(nThreads)
        cparams.flash_attn_type = flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED

        var c = llama_init_from_model(m, cparams)
        if c == nil && flashAttention {
            // Retry cleanly without flash attention for architectures that disallow it on Metal.
            cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
            c = llama_init_from_model(m, cparams)
        }
        guard let validCtx = c else {
            llama_model_free(m)
            throw ZinoError(
                .insufficientMemory,
                "Could not allocate a \(effectiveCtx)-token inference context. Try lowering the context length or using a smaller model."
            )
        }

        self.model = m
        self.ctx = validCtx
        self.vocab = llama_model_get_vocab(m)!
        self.nCtx = Int(llama_n_ctx(validCtx))
        self.nBatch = nBatch
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    func meta(_ key: String) -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        let n = llama_model_meta_val_str(model, key, &buf, buf.count)
        return n >= 0 ? String(cString: buf) : nil
    }

    func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        var tokens = [llama_token](repeating: 0, count: utf8Count + 8)
        var n = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(tokens.count), addSpecial, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(tokens.count), addSpecial, true)
        }
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }

    func applyTemplate(_ messages: [(String, String)], addAssistant: Bool) -> String? {
        guard let tmpl = llama_model_chat_template(model, nil) else { return nil }
        let cRoles = messages.map { strdup($0.0) }
        let cContents = messages.map { strdup($0.1) }
        defer {
            cRoles.forEach { free($0) }
            cContents.forEach { free($0) }
        }
        var chat: [llama_chat_message] = []
        chat.reserveCapacity(messages.count)
        for i in 0..<messages.count {
            chat.append(llama_chat_message(role: UnsafePointer(cRoles[i]), content: UnsafePointer(cContents[i])))
        }
        let estimated = messages.reduce(0) { $0 + $1.1.utf8.count } * 2 + 4096
        var buf = [CChar](repeating: 0, count: estimated)
        var n = llama_chat_apply_template(tmpl, &chat, chat.count, addAssistant, &buf, Int32(buf.count))
        if n < 0 { return nil }
        if Int(n) > buf.count {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(tmpl, &chat, chat.count, addAssistant, &buf, Int32(buf.count))
            if n < 0 { return nil }
        }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func pieceBytes(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return n > 0 ? buf.prefix(Int(n)).map { UInt8(bitPattern: $0) } : []
    }

    private func decode(_ tokens: inout [llama_token], from start: Int) throws {
        var i = start
        while i < tokens.count {
            let n = min(nBatch, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(buf.baseAddress! + i, Int32(n))
                return llama_decode(ctx, batch)
            }
            if rc != 0 {
                cachedTokens = []
                llama_memory_clear(llama_get_memory(ctx), true)
                throw ZinoError(rc == 1 ? .contextFull : .inferenceFailed, "llama_decode failed (code \(rc)).")
            }
            i += n
        }
    }

    private func preparePrompt(_ tokens: inout [llama_token]) throws {
        var common = 0
        while common < min(cachedTokens.count, tokens.count) - 1 && cachedTokens[common] == tokens[common] {
            common += 1
        }
        let mem = llama_get_memory(ctx)
        if common == 0 || !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
            llama_memory_clear(mem, true)
            common = 0
        }
        do {
            try decode(&tokens, from: common)
        } catch {
            // If prefix-reused KV cache became inconsistent (e.g. after cancellation or sliding window),
            // clear memory and perform a clean full-prompt decode once before surfacing an error.
            if common > 0 {
                llama_memory_clear(mem, true)
                cachedTokens = []
                try decode(&tokens, from: 0)
            } else {
                throw error
            }
        }
        cachedTokens = tokens
    }

    private func makeSampler(config: GenerationConfig) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, Float(config.repeatPenalty), 0, 0)
        )
        if config.temperature <= 0.01 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(config.topK)))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(config.topP), 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.05, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(config.temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        }
        return chain
    }

    func generate(
        prompt: String,
        config: GenerationConfig,
        stopSequences: [String],
        isCancelled: () -> Bool,
        onText: (String) -> Void
    ) throws -> (usage: TokenUsage, stopReason: String) {
        var tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else {
            throw ZinoError(.invalidArgument, "Prompt tokenized to zero tokens.")
        }

        // Safely guarantee completion headroom inside nCtx so slight estimation drift never crashes generation.
        let maxPromptTokens = max(256, nCtx - 128)
        if tokens.count > maxPromptTokens {
            let keepHead = min(220, maxPromptTokens / 4)
            let keepTail = maxPromptTokens - keepHead
            tokens = Array(tokens.prefix(keepHead)) + Array(tokens.suffix(keepTail))
            cachedTokens = []
            llama_memory_clear(llama_get_memory(ctx), true)
        }

        try preparePrompt(&tokens)
        let promptTokenCount = tokens.count

        let sampler = makeSampler(config: config)
        defer { llama_sampler_free(sampler) }

        var utf8 = UTF8StreamAccumulator()
        var held = ""
        var generated = 0
        var stopReason = "max_tokens"
        let maxStopLen = stopSequences.map(\.count).max() ?? 0
        let genStart = Date()

        func flushHeld(keep: Int) {
            guard held.count > keep else { return }
            let cut = held.index(held.endIndex, offsetBy: -keep)
            let piece = String(held[..<cut])
            if !piece.isEmpty { onText(piece) }
            held = String(held[cut...])
        }

        while generated < config.maxTokens {
            if isCancelled() { stopReason = "cancelled"; break }
            if tokens.count + 1 >= nCtx { stopReason = "context_full"; break }

            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { stopReason = "eos"; break }

            generated += 1
            held += utf8.append(pieceBytes(token))
            tokens.append(token)

            if maxStopLen > 0,
               let hit = stopSequences.compactMap({ held.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                held = String(held[..<hit.lowerBound])
                flushHeld(keep: 0)
                stopReason = "stop"
                break
            }
            flushHeld(keep: maxStopLen)

            var next = [token]
            let rc = next.withUnsafeMutableBufferPointer { buf -> Int32 in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress!, 1))
            }
            if rc != 0 {
                stopReason = rc == 1 ? "context_full" : "error"
                break
            }
            cachedTokens.append(token)
        }

        if stopReason != "stop" {
            held += utf8.flush()
            flushHeld(keep: 0)
        }
        if stopReason == "error" || stopReason == "context_full" || stopReason == "cancelled" {
            cachedTokens = []
            llama_memory_clear(llama_get_memory(ctx), true)
        }

        let elapsed = Date().timeIntervalSince(genStart)
        let tps = elapsed > 0 ? Double(generated) / elapsed : 0
        let usage = TokenUsage(
            promptTokens: promptTokenCount,
            completionTokens: generated,
            tokensPerSecond: tps
        )
        return (usage, stopReason)
    }

    func benchmark(promptTokens: Int, genTokens: Int) throws -> LocalBenchmarkResult {
        let n = min(promptTokens, nCtx - genTokens - 8)
        guard n > 8 else {
            throw ZinoError(.invalidArgument, "Context window is too small to run benchmark.")
        }
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var tokens: [llama_token] = (0..<n).map { llama_token(1000 + ($0 * 7919) % max(1, vocabSize - 1000)) }
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []

        let t0 = Date()
        try decode(&tokens, from: 0)
        let ppElapsed = Date().timeIntervalSince(t0)

        let sampler = makeSampler(config: GenerationConfig(temperature: 0, maxTokens: genTokens))
        defer { llama_sampler_free(sampler) }

        let t1 = Date()
        var produced = 0
        for _ in 0..<genTokens {
            var next = [llama_sampler_sample(sampler, ctx, -1)]
            let rc = next.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress!, 1)) }
            if rc != 0 { break }
            produced += 1
        }
        let tgElapsed = Date().timeIntervalSince(t1)
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []

        return LocalBenchmarkResult(
            promptTokens: n,
            promptTokensPerSecond: ppElapsed > 0 ? Double(n) / ppElapsed : 0,
            generatedTokens: produced,
            generationTokensPerSecond: tgElapsed > 0 ? Double(produced) / tgElapsed : 0
        )
    }
}
#endif
