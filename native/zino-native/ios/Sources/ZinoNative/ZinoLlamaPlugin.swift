import Foundation
import Capacitor
import llama

/// Offline GGUF chat inference via llama.cpp (Metal-accelerated on device).
///
/// One model is loaded at a time. Generation runs on a dedicated serial queue and streams
/// text through `token` events. The KV cache is reused across turns when the new prompt
/// shares a prefix with the previous one, which makes multi-turn chat much faster.
@objc(ZinoLlamaPlugin)
public class ZinoLlamaPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoLlamaPlugin"
    public let jsName = "ZinoLlama"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "inspect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tokenize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "applyTemplate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "generate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "benchmark", returnType: CAPPluginReturnPromise)
    ]

    private let queue = DispatchQueue(label: "com.zinoagent.llama", qos: .userInitiated)
    private var runtime: LlamaRuntime?
    private var cancelFlags: [String: Bool] = [:]
    private let flagLock = NSLock()
    private static var backendReady = false

    override public func load() {
        if !Self.backendReady {
            llama_backend_init()
            Self.backendReady = true
        }
    }

    private func isCancelled(_ id: String) -> Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return cancelFlags[id] ?? false
    }

    // MARK: - GGUF metadata (no weights loaded)

    @objc func inspect(_ call: CAPPluginCall) {
        guard let rel = call.getString("path") else { call.reject("path is required", "INVALID_ARGUMENT"); return }
        queue.async {
            do {
                let url = try ZinoPaths.resolve(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { throw ZinoError("FILE_NOT_FOUND", "Model file not found.") }
                call.resolve(try GGUFInspector.inspect(url))
            } catch { call.zinoReject(error) }
        }
    }

    // MARK: - Load / unload

    @objc func load(_ call: CAPPluginCall) {
        guard let rel = call.getString("path") else { call.reject("path is required", "INVALID_ARGUMENT"); return }
        let nCtx = call.getInt("contextLength") ?? 4096
        let nBatch = call.getInt("batchSize") ?? 512
        let nThreads = call.getInt("threads") ?? max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        #if targetEnvironment(simulator)
        let defaultGpu = 0
        #else
        let defaultGpu = 999
        #endif
        let gpuLayers = call.getInt("gpuLayers") ?? defaultGpu
        let flashAttn = call.getBool("flashAttention") ?? true
        queue.async {
            do {
                let url = try ZinoPaths.resolve(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { throw ZinoError("FILE_NOT_FOUND", "Model file not found.") }
                self.runtime = nil // free previous model first: only one heavy model at a time
                let started = Date()
                let rt = try LlamaRuntime(path: url.path, nCtx: nCtx, nBatch: nBatch, nThreads: nThreads,
                                          gpuLayers: gpuLayers, flashAttention: flashAttn) { progress in
                    self.notifyListeners("loadProgress", data: ["progress": progress])
                }
                self.runtime = rt
                var info = rt.info()
                info["loadMs"] = Int(Date().timeIntervalSince(started) * 1000)
                info["path"] = rel
                call.resolve(info)
            } catch { call.zinoReject(error) }
        }
    }

    @objc func unload(_ call: CAPPluginCall) {
        flagLock.lock(); for k in cancelFlags.keys { cancelFlags[k] = true }; flagLock.unlock()
        queue.async {
            self.runtime = nil
            call.resolve(["unloaded": true])
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        queue.async {
            if let rt = self.runtime {
                var info = rt.info(); info["loaded"] = true
                call.resolve(info)
            } else {
                call.resolve(["loaded": false])
            }
        }
    }

    @objc func tokenize(_ call: CAPPluginCall) {
        let texts = (call.getArray("texts") as? [String]) ?? [call.getString("text") ?? ""]
        queue.async {
            guard let rt = self.runtime else { call.reject("No model loaded", "MODEL_NOT_LOADED"); return }
            let counts = texts.map { rt.tokenize($0, addSpecial: false).count }
            call.resolve(["counts": counts, "count": counts.reduce(0, +)])
        }
    }

    @objc func applyTemplate(_ call: CAPPluginCall) {
        guard let msgs = call.getArray("messages") as? [JSObject] else { call.reject("messages required", "INVALID_ARGUMENT"); return }
        let addAssistant = call.getBool("addAssistant") ?? true
        let pairs: [(String, String)] = msgs.map { (($0["role"] as? String) ?? "user", ($0["content"] as? String) ?? "") }
        queue.async {
            guard let rt = self.runtime else { call.reject("No model loaded", "MODEL_NOT_LOADED"); return }
            if let prompt = rt.applyTemplate(pairs, addAssistant: addAssistant) {
                call.resolve(["prompt": prompt, "templateApplied": true])
            } else {
                call.resolve(["templateApplied": false])
            }
        }
    }

    // MARK: - Generation

    @objc func cancel(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("id required", "INVALID_ARGUMENT"); return }
        flagLock.lock(); cancelFlags[id] = true; flagLock.unlock()
        call.resolve()
    }

    @objc func generate(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let prompt = call.getString("prompt") else {
            call.reject("id and prompt are required", "INVALID_ARGUMENT"); return
        }
        let params = SamplingParams(
            maxTokens: call.getInt("maxTokens") ?? 1024,
            temperature: Float(call.getDouble("temperature") ?? 0.7),
            topK: Int32(call.getInt("topK") ?? 40),
            topP: Float(call.getDouble("topP") ?? 0.95),
            minP: Float(call.getDouble("minP") ?? 0.05),
            repeatPenalty: Float(call.getDouble("repeatPenalty") ?? 1.1),
            repeatLastN: Int32(call.getInt("repeatLastN") ?? 64),
            seed: call.getInt("seed").map { UInt32(truncatingIfNeeded: $0) } ?? UInt32.random(in: 0...UInt32.max - 1),
            stop: (call.getArray("stop") as? [String]) ?? []
        )
        flagLock.lock(); cancelFlags[id] = false; flagLock.unlock()
        queue.async {
            defer { self.flagLock.lock(); self.cancelFlags.removeValue(forKey: id); self.flagLock.unlock() }
            guard let rt = self.runtime else { call.reject("No model loaded", "MODEL_NOT_LOADED"); return }
            do {
                var pending = ""
                var lastEmit = Date()
                let result = try rt.generate(prompt: prompt, params: params, isCancelled: { self.isCancelled(id) }) { piece in
                    pending += piece
                    if Date().timeIntervalSince(lastEmit) > 0.04 {
                        self.notifyListeners("token", data: ["id": id, "text": pending])
                        pending = ""
                        lastEmit = Date()
                    }
                }
                if !pending.isEmpty { self.notifyListeners("token", data: ["id": id, "text": pending]) }
                call.resolve(result)
            } catch { call.zinoReject(error) }
        }
    }

    /// Measures real prompt-processing and generation speed on this device.
    @objc func benchmark(_ call: CAPPluginCall) {
        let promptTokens = call.getInt("promptTokens") ?? 256
        let genTokens = call.getInt("genTokens") ?? 64
        queue.async {
            guard let rt = self.runtime else { call.reject("No model loaded", "MODEL_NOT_LOADED"); return }
            do { call.resolve(try rt.benchmark(promptTokens: promptTokens, genTokens: genTokens)) } catch { call.zinoReject(error) }
        }
    }
}

struct SamplingParams {
    var maxTokens: Int
    var temperature: Float
    var topK: Int32
    var topP: Float
    var minP: Float
    var repeatPenalty: Float
    var repeatLastN: Int32
    var seed: UInt32
    var stop: [String]
}

private final class ProgressBox {
    let handler: (Float) -> Void
    var lastReported: Float = -1
    init(_ handler: @escaping (Float) -> Void) { self.handler = handler }
}

/// Owns a llama_model + llama_context. Not thread-safe: use from one serial queue.
final class LlamaRuntime {
    let model: OpaquePointer
    let ctx: OpaquePointer
    let vocab: OpaquePointer
    let nCtx: Int
    let nBatch: Int
    private var cachedTokens: [llama_token] = []

    init(path: String, nCtx: Int, nBatch: Int, nThreads: Int, gpuLayers: Int, flashAttention: Bool,
         onProgress: @escaping (Float) -> Void) throws {
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(gpuLayers)
        let box = ProgressBox(onProgress)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(boxPtr).release() }
        mparams.progress_callback = { progress, userData in
            guard let userData else { return true }
            let b = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
            if progress - b.lastReported >= 0.05 || progress >= 1 {
                b.lastReported = progress
                b.handler(progress)
            }
            return true
        }
        mparams.progress_callback_user_data = boxPtr

        guard let m = llama_model_load_from_file(path, mparams) else {
            throw ZinoError("MODEL_LOAD_FAILED",
                            "llama.cpp could not load this model. The architecture or quantisation may be unsupported by this build, or the file may be incomplete/corrupt.")
        }
        var cparams = llama_context_default_params()
        let trained = Int(llama_model_n_ctx_train(m))
        let effectiveCtx = trained > 0 ? min(nCtx, trained) : nCtx
        cparams.n_ctx = UInt32(effectiveCtx)
        cparams.n_batch = UInt32(nBatch)
        cparams.n_ubatch = UInt32(min(nBatch, 512))
        cparams.n_threads = Int32(nThreads)
        cparams.n_threads_batch = Int32(nThreads)
        cparams.flash_attn_type = flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw ZinoError("INSUFFICIENT_MEMORY",
                            "Could not create an inference context (\(effectiveCtx) tokens). Try a smaller context length or a smaller model.")
        }
        self.model = m
        self.ctx = c
        self.vocab = llama_model_get_vocab(m)!
        self.nCtx = Int(llama_n_ctx(c))
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

    func info() -> [String: Any] {
        var desc = [CChar](repeating: 0, count: 256)
        _ = llama_model_desc(model, &desc, desc.count)
        return [
            "description": String(cString: desc),
            "architecture": meta("general.architecture") ?? "",
            "name": meta("general.name") ?? "",
            "contextLength": nCtx,
            "trainedContextLength": Int(llama_model_n_ctx_train(model)),
            "parameters": Double(llama_model_n_params(model)),
            "modelBytes": Double(llama_model_size(model)),
            "layers": Int(llama_model_n_layer(model)),
            "embedding": Int(llama_model_n_embd(model)),
            "hasChatTemplate": llama_model_chat_template(model, nil) != nil,
            "gpuOffloadSupported": llama_supports_gpu_offload()
        ]
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
        defer { cRoles.forEach { free($0) }; cContents.forEach { free($0) } }
        var chat: [llama_chat_message] = []
        for i in 0..<messages.count {
            chat.append(llama_chat_message(role: UnsafePointer(cRoles[i]), content: UnsafePointer(cContents[i])))
        }
        let total = messages.reduce(0) { $0 + $1.1.utf8.count } * 2 + 4096
        var buf = [CChar](repeating: 0, count: total)
        var n = llama_chat_apply_template(tmpl, &chat, chat.count, addAssistant, &buf, Int32(buf.count))
        if n < 0 { return nil } // template not recognised by llama.cpp's built-in formatter
        if Int(n) > buf.count {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(tmpl, &chat, chat.count, addAssistant, &buf, Int32(buf.count))
            if n < 0 { return nil }
        }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func piece(_ token: llama_token) -> [UInt8] {
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
                throw ZinoError(rc == 1 ? "CONTEXT_FULL" : "INFERENCE_FAILED", "llama_decode failed (code \(rc)).")
            }
            i += n
        }
    }

    /// Reuse the KV cache for the longest common prefix with the previous prompt.
    private func preparePrompt(_ tokens: inout [llama_token]) throws -> Int {
        var common = 0
        while common < min(cachedTokens.count, tokens.count) - 1 && cachedTokens[common] == tokens[common] { common += 1 }
        let mem = llama_get_memory(ctx)
        if common == 0 || !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
            llama_memory_clear(mem, true)
            common = 0
        }
        try decode(&tokens, from: common)
        cachedTokens = tokens
        return common
    }

    private func makeSampler(_ p: SamplingParams) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), p.repeatLastN, p.repeatPenalty, 0, 0))
        if p.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(p.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(p.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(p.minP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(p.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(p.seed))
        }
        return chain
    }

    func generate(prompt: String, params: SamplingParams, isCancelled: () -> Bool, onText: (String) -> Void) throws -> [String: Any] {
        var tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else { throw ZinoError("INVALID_ARGUMENT", "Prompt is empty.") }
        if tokens.count >= nCtx {
            throw ZinoError("CONTEXT_FULL", "Prompt is \(tokens.count) tokens but the context window is \(nCtx). Compact the conversation or increase context length.")
        }
        let t0 = Date()
        let reused = try preparePrompt(&tokens)
        let tPrompt = Date().timeIntervalSince(t0)

        let sampler = makeSampler(params)
        defer { llama_sampler_free(sampler) }

        var utf8 = UTF8Accumulator()
        var emitted = ""   // text already sent to the UI
        var held = ""      // trailing text held back in case it is the start of a stop string
        var generated = 0
        var stopReason = "max_tokens"
        let t1 = Date()
        let maxStop = params.stop.map { $0.count }.max() ?? 0

        func flushHeld(keep: Int) {
            guard held.count > keep else { return }
            let cut = held.index(held.endIndex, offsetBy: -keep)
            let out = String(held[..<cut])
            if !out.isEmpty { onText(out); emitted += out }
            held = String(held[cut...])
        }

        while generated < params.maxTokens {
            if isCancelled() { stopReason = "cancelled"; break }
            if tokens.count + 1 >= nCtx { stopReason = "context_full"; break }
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { stopReason = "eos"; break }
            generated += 1
            held += utf8.append(Data(piece(token)))
            tokens.append(token)

            if maxStop > 0, let hit = params.stop.compactMap({ held.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                held = String(held[..<hit.lowerBound])
                flushHeld(keep: 0)
                stopReason = "stop"
                break
            }
            flushHeld(keep: maxStop)

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
        if stopReason == "error" || stopReason == "context_full" {
            // A failed decode can leave the KV cache inconsistent; force a full re-evaluation next turn.
            cachedTokens = []
            llama_memory_clear(llama_get_memory(ctx), true)
        }
        let output = emitted
        let tGen = Date().timeIntervalSince(t1)
        return [
            "text": output,
            "promptTokens": tokens.count - generated,
            "reusedPromptTokens": reused,
            "completionTokens": generated,
            "stopReason": stopReason,
            "promptMs": Int(tPrompt * 1000),
            "generationMs": Int(tGen * 1000),
            "tokensPerSecond": tGen > 0 ? Double(generated) / tGen : 0,
            "contextUsed": tokens.count,
            "contextLength": nCtx
        ]
    }

    func benchmark(promptTokens: Int, genTokens: Int) throws -> [String: Any] {
        let n = min(promptTokens, nCtx - genTokens - 8)
        guard n > 8 else { throw ZinoError("INVALID_ARGUMENT", "Context too small to benchmark.") }
        // Deterministic synthetic prompt from the vocabulary (avoids special/control tokens near 0).
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var tokens: [llama_token] = (0..<n).map { llama_token(1000 + ($0 * 7919) % max(1, vocabSize - 1000)) }
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []
        let t0 = Date()
        try decode(&tokens, from: 0)
        let pp = Date().timeIntervalSince(t0)
        let sampler = makeSampler(SamplingParams(maxTokens: genTokens, temperature: 0, topK: 1, topP: 1, minP: 0,
                                                 repeatPenalty: 1, repeatLastN: 0, seed: 1, stop: []))
        defer { llama_sampler_free(sampler) }
        let t1 = Date()
        var produced = 0
        for _ in 0..<genTokens {
            var t = [llama_sampler_sample(sampler, ctx, -1)]
            let rc = t.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress!, 1)) }
            if rc != 0 { break }
            produced += 1
        }
        let tg = Date().timeIntervalSince(t1)
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []
        return [
            "promptTokens": n,
            "promptTokensPerSecond": pp > 0 ? Double(n) / pp : 0,
            "generatedTokens": produced,
            "generationTokensPerSecond": tg > 0 ? Double(produced) / tg : 0
        ]
    }
}

/// Reads GGUF metadata with gguf_init_from_file(no_alloc) — no tensor data is loaded.
enum GGUFInspector {
    static func inspect(_ url: URL) throws -> [String: Any] {
        let params = gguf_init_params(no_alloc: true, ctx: nil)
        guard let g = gguf_init_from_file(url.path, params) else {
            throw ZinoError("UNSUPPORTED_FORMAT", "Not a valid GGUF file (or it is truncated).")
        }
        defer { gguf_free(g) }
        func value(_ key: String) -> Any? {
            let id = gguf_find_key(g, key)
            guard id >= 0 else { return nil }
            switch gguf_get_kv_type(g, id) {
            case GGUF_TYPE_STRING: return String(cString: gguf_get_val_str(g, id))
            case GGUF_TYPE_UINT8: return Int(gguf_get_val_u8(g, id))
            case GGUF_TYPE_INT8: return Int(gguf_get_val_i8(g, id))
            case GGUF_TYPE_UINT16: return Int(gguf_get_val_u16(g, id))
            case GGUF_TYPE_INT16: return Int(gguf_get_val_i16(g, id))
            case GGUF_TYPE_UINT32: return Int(gguf_get_val_u32(g, id))
            case GGUF_TYPE_INT32: return Int(gguf_get_val_i32(g, id))
            case GGUF_TYPE_UINT64: return Double(gguf_get_val_u64(g, id))
            case GGUF_TYPE_INT64: return Double(gguf_get_val_i64(g, id))
            case GGUF_TYPE_FLOAT32: return Double(gguf_get_val_f32(g, id))
            case GGUF_TYPE_FLOAT64: return gguf_get_val_f64(g, id)
            case GGUF_TYPE_BOOL: return gguf_get_val_bool(g, id)
            case GGUF_TYPE_ARRAY: return ["arrayLength": gguf_get_arr_n(g, id)]
            default: return nil
            }
        }
        let arch = (value("general.architecture") as? String) ?? ""
        var out: [String: Any] = [
            "architecture": arch,
            "version": Int(gguf_get_version(g)),
            "tensorCount": Int(gguf_get_n_tensors(g)),
            "fileSize": (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        ]
        let keys: [(String, String)] = [
            ("name", "general.name"), ("basename", "general.basename"), ("sizeLabel", "general.size_label"),
            ("license", "general.license"), ("fileType", "general.file_type"), ("quantizationVersion", "general.quantization_version"),
            ("contextLength", "\(arch).context_length"), ("blockCount", "\(arch).block_count"),
            ("embeddingLength", "\(arch).embedding_length"), ("headCount", "\(arch).attention.head_count"),
            ("headCountKv", "\(arch).attention.head_count_kv"), ("keyLength", "\(arch).attention.key_length"),
            ("valueLength", "\(arch).attention.value_length"), ("slidingWindow", "\(arch).attention.sliding_window"),
            ("expertCount", "\(arch).expert_count"), ("chatTemplate", "tokenizer.chat_template"),
            ("tokenizerModel", "tokenizer.ggml.model")
        ]
        for (name, key) in keys {
            if let v = value(key) {
                if name == "chatTemplate", let s = v as? String { out["hasChatTemplate"] = true; out["chatTemplate"] = String(s.prefix(20000)) }
                else { out[name] = v }
            }
        }
        if out["hasChatTemplate"] == nil { out["hasChatTemplate"] = false }
        // Split GGUF ("-00001-of-00003") must be loaded from the first shard with siblings present.
        out["isSplit"] = value("split.count") != nil
        return out
    }
}
