import BrainDumpCore
import Foundation
import llama

public enum LocalLLMError: LocalizedError, Equatable {
    case modelMissing(String)
    case loadFailed(String)
    case contextFailed
    case contextOverflow(promptTokens: Int, maxTokens: Int, contextTokens: Int)
    case tokenizeFailed
    case grammarInvalid
    case decodeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path): return "Model file not found at \(path). Download it first."
        case .loadFailed(let path): return "llama.cpp could not load the model at \(path)."
        case .contextFailed: return "llama.cpp could not create a context (out of memory?)."
        case .contextOverflow(let p, let m, let c):
            return "Prompt (\(p) tokens) plus \(m) output tokens exceeds the \(c)-token context."
        case .tokenizeFailed: return "Tokenization failed."
        case .grammarInvalid: return "The output grammar could not be parsed."
        case .decodeFailed(let code): return "llama_decode failed with code \(code)."
        }
    }
}

/// Cumulative counters since the last `resetStats()`.
public struct LLMStats: Sendable {
    public var calls = 0
    public var promptTokens = 0
    /// Prompt tokens served from the kept KV cache instead of being decoded.
    public var reusedTokens = 0
    public var generatedTokens = 0
    public var promptSeconds: Double = 0
    public var generateSeconds: Double = 0
    public var loadSeconds: Double = 0

    public init() {}

    public var generationTokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
}

private let backendReady: Void = {
    llama_log_set({ _, _, _ in }, nil)
    llama_backend_init()
}()

/// llama.cpp in-process. Loads on first `complete`, frees on `unload`.
public actor LocalLLM: LLMProvider {
    public let modelPath: URL
    public let contextTokens: Int
    /// Keep the KV cache for the prompt prefix shared with the previous call.
    public var prefixCache = true

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var template: String?
    /// Tokens whose state is currently in the context's memory, in order.
    private var cached: [llama_token] = []
    /// Hybrid and recurrent models cannot truncate their memory, so the shared prefix state is saved and restored.
    private var snapshots: [(tokens: [llama_token], data: [UInt8])] = []
    private var lastPrompt: [llama_token] = []
    private var counters = LLMStats()

    public init(modelPath: URL, contextTokens: Int = 4096) {
        self.modelPath = modelPath
        self.contextTokens = contextTokens
    }

    public func setPrefixCache(_ enabled: Bool) {
        prefixCache = enabled
        resetMemory()
    }

    public func stats() -> LLMStats { counters }
    public func resetStats() { counters = LLMStats() }

    public func complete(turns: [ChatTurn], grammar: String?, maxTokens: Int) async throws -> String {
        try load()
        guard let ctx, let vocab else { throw LocalLLMError.contextFailed }
        let prompt = try tokenize(render(turns))
        guard prompt.count + maxTokens <= contextTokens else {
            throw LocalLLMError.contextOverflow(promptTokens: prompt.count, maxTokens: maxTokens, contextTokens: contextTokens)
        }

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if let grammar {
            guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw LocalLLMError.grammarInvalid }
            llama_sampler_chain_add(chain, g)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        let t0 = Date()
        try preparePrompt(prompt)
        let t1 = Date()

        var bytes: [UInt8] = []
        var generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        while generated < maxTokens {
            // llama_sampler_sample also accepts the token into every sampler in the chain (the grammar included).
            var token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { bytes.append(contentsOf: piece[0..<Int(n)].map { UInt8(bitPattern: $0) }) }
            generated += 1
            let rc = llama_decode(ctx, llama_batch_get_one(&token, 1))
            if rc != 0 { resetMemory(); throw LocalLLMError.decodeFailed(rc) }
            cached.append(token)
        }
        counters.calls += 1
        counters.generatedTokens += generated
        counters.promptSeconds += t1.timeIntervalSince(t0)
        counters.generateSeconds += Date().timeIntervalSince(t1)
        return String(decoding: bytes, as: UTF8.self)
    }

    public func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        cached = []
        snapshots = []
        lastPrompt = []
    }

    // MARK: - Internals

    private func load() throws {
        guard model == nil else { return }
        _ = backendReady
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw LocalLLMError.modelMissing(modelPath.path)
        }
        let t0 = Date()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        guard let m = llama_model_load_from_file(modelPath.path, mp) else {
            throw LocalLLMError.loadFailed(modelPath.path)
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = 512
        cp.n_ubatch = 512
        cp.n_seq_max = 1
        cp.no_perf = true
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw LocalLLMError.contextFailed
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        if let t = llama_model_chat_template(m, nil) { template = String(cString: t) }
        counters.loadSeconds += Date().timeIntervalSince(t0)
    }

    private func resetMemory() {
        if let ctx { llama_memory_clear(llama_get_memory(ctx), true) }
        cached = []
        snapshots = []
        lastPrompt = []
    }

    /// Leaves the memory holding exactly `prompt`, decoding as little as possible.
    private func preparePrompt(_ prompt: [llama_token]) throws {
        guard let ctx else { return }
        let mem = llama_get_memory(ctx)
        defer { lastPrompt = prompt }
        counters.promptTokens += prompt.count
        guard prefixCache else {
            llama_memory_clear(mem, true)
            cached = []
            try decode(prompt[...])
            return
        }
        // At least one prompt token must be decoded to get logits.
        let keep = min(commonPrefix(cached, prompt), prompt.count - 1)
        if keep > 0, keep == cached.count || llama_memory_seq_rm(mem, 0, Int32(keep), -1) {
            cached.removeLast(cached.count - keep)
            counters.reusedTokens += keep
            try decode(prompt[keep...])
            return
        }
        if let snap = snapshots.filter({ $0.tokens.count < prompt.count && prompt.starts(with: $0.tokens) })
            .max(by: { $0.tokens.count < $1.tokens.count })
        {
            llama_memory_clear(mem, true)
            let ok = snap.data.withUnsafeBufferPointer { llama_state_seq_set_data(ctx, $0.baseAddress, $0.count, 0) }
            if ok > 0 {
                cached = snap.tokens
                counters.reusedTokens += snap.tokens.count
                try decode(prompt[snap.tokens.count...])
                return
            }
        }
        llama_memory_clear(mem, true)
        cached = []
        let shared = min(commonPrefix(lastPrompt, prompt), prompt.count - 1)
        if shared >= 64 {
            try decode(prompt[..<shared])
            let size = llama_state_seq_get_size(ctx, 0)
            var data = [UInt8](repeating: 0, count: size)
            let written = data.withUnsafeMutableBufferPointer { llama_state_seq_get_data(ctx, $0.baseAddress, size, 0) }
            if written > 0 {
                snapshots.append((Array(prompt[..<shared]), Array(data[..<written])))
                if snapshots.count > 3 { snapshots.removeFirst() }
            }
            try decode(prompt[shared...])
        } else {
            try decode(prompt[...])
        }
    }

    private func decode(_ tokens: ArraySlice<llama_token>) throws {
        guard let ctx else { return }
        var start = tokens.startIndex
        while start < tokens.endIndex {
            let end = min(start + 512, tokens.endIndex)
            var piece = Array(tokens[start..<end])
            let rc = piece.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            if rc != 0 {
                resetMemory()
                throw LocalLLMError.decodeFailed(rc)
            }
            cached.append(contentsOf: piece)
            start = end
        }
    }

    private func commonPrefix(_ a: [llama_token], _ b: [llama_token]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let vocab else { throw LocalLLMError.tokenizeFailed }
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        }
        guard n >= 0 else { throw LocalLLMError.tokenizeFailed }
        return Array(tokens[0..<Int(n)])
    }

    func render(_ turns: [ChatTurn]) -> String {
        var text = applyTemplate(turns) ?? chatML(turns)
        // Thinking templates (Qwen) expect an empty think block when thinking is off.
        if let template, template.contains("<think>"), text.hasSuffix("<|im_start|>assistant\n") {
            text += "<think>\n\n</think>\n\n"
        }
        return text
    }

    private func applyTemplate(_ turns: [ChatTurn]) -> String? {
        guard let template else { return nil }
        let roles = turns.map { strdup($0.role.rawValue)! }
        let contents = turns.map { strdup($0.content)! }
        defer { (roles + contents).forEach { free($0) } }
        let messages = (0..<turns.count).map { llama_chat_message(role: roles[$0], content: contents[$0]) }
        var capacity = turns.reduce(1024) { $0 + $1.content.utf8.count * 2 }
        for _ in 0..<2 {
            var buf = [CChar](repeating: 0, count: capacity)
            let n = llama_chat_apply_template(template, messages, messages.count, true, &buf, Int32(capacity))
            if n < 0 { return nil }
            if Int(n) <= capacity {
                return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = Int(n) + 1
        }
        return nil
    }

    private func chatML(_ turns: [ChatTurn]) -> String {
        turns.map { "<|im_start|>\($0.role.rawValue)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
    }
}
