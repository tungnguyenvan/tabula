import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates
import llama

/// Runs GGUF models inside the app with llama.cpp: no server or other app to install.
///
/// llama.cpp calls block and its objects aren't thread-safe, so everything runs on one serial queue.
/// The loaded model stays in memory between requests (loading takes a moment) and is released after
/// a while without use.
public final class LocalModelRunner: @unchecked Sendable {
    public static let shared = LocalModelRunner()

    private let queue = DispatchQueue(label: "app.tabula.local-model", qos: .userInitiated)
    // Only touched on `queue`.
    private var loaded: (path: String, model: OpaquePointer, context: OpaquePointer)?
    private var unloadWork: DispatchWorkItem?

    private init() {
        queue.async {
            llama_backend_init()
            // llama.cpp logs every layer it loads; keep the app's output quiet.
            llama_log_set({ _, _, _ in }, nil)
        }
    }

    /// Generates a reply to `prompt` with the model at `path`. Cancelling the calling task stops
    /// generation at the next token. `onText` receives the reply as it grows, a piece at a time.
    public func generate(path: String, instructions: String, prompt: String, maxTokens: Int,
                         stopAtNewline: Bool = false, onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try self.run(path: path, instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                                     stopAtNewline: stopAtNewline, cancelled: cancelled, onText: onText)
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Code completion the way coding models are trained for it ("fill in the middle"): the text before
    /// and after the caret go in, the model writes what belongs between. Nil when the model has no
    /// fill-in-the-middle tokens; use `generate` then.
    public func fill(path: String, prefix: String, suffix: String, maxTokens: Int) async throws -> String? {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try self.runFill(path: path, prefix: prefix, suffix: suffix, maxTokens: maxTokens, cancelled: cancelled)
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Releases the model now (e.g. before its file is deleted).
    public func unload() {
        queue.sync { release() }
    }

    // MARK: On the queue

    private func run(path: String, instructions: String, prompt: String, maxTokens: Int,
                     stopAtNewline: Bool, cancelled: CancelFlag, onText: (@Sendable (String) -> Void)?) throws -> String {
        unloadWork?.cancel()
        defer { scheduleUnload() }
        let (model, context) = try load(path)
        guard let vocab = llama_model_get_vocab(model) else { throw AIError.server("The model has no vocabulary.") }
        llama_memory_clear(llama_get_memory(context), true)

        let formatted = chat(model: model, instructions: instructions, prompt: prompt)
        // Some chat templates (DeepSeek-R1 distills, Qwen3) open the reasoning block themselves, so the model's
        // output starts inside it; say so to whoever splits the reasoning out.
        if formatted.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>") { onText?("<think>") }
        let tokens = tokenize(formatted, vocab: vocab, special: true)
        return try complete(tokens, context: context, vocab: vocab, maxTokens: maxTokens, stopAtNewline: stopAtNewline,
                            cancelled: cancelled, onText: onText)
    }

    private func runFill(path: String, prefix: String, suffix: String, maxTokens: Int, cancelled: CancelFlag) throws -> String? {
        unloadWork?.cancel()
        defer { scheduleUnload() }
        let (model, context) = try load(path)
        guard let vocab = llama_model_get_vocab(model) else { throw AIError.server("The model has no vocabulary.") }
        let pre = llama_vocab_fim_pre(vocab), suf = llama_vocab_fim_suf(vocab), mid = llama_vocab_fim_mid(vocab)
        guard pre >= 0, suf >= 0, mid >= 0 else { return nil }
        llama_memory_clear(llama_get_memory(context), true)
        // <fim_prefix>before<fim_suffix>after<fim_middle> - the user's text is never parsed for special tokens.
        let tokens = [pre] + tokenize(prefix, vocab: vocab, special: false) + [suf] + tokenize(suffix, vocab: vocab, special: false) + [mid]
        return try complete(tokens, context: context, vocab: vocab, maxTokens: maxTokens, stopAtNewline: true, cancelled: cancelled)
    }

    /// Feeds `prompt` to the model and samples up to `maxTokens` tokens of answer.
    private func complete(_ prompt: [llama_token], context: OpaquePointer, vocab: OpaquePointer, maxTokens: Int,
                          stopAtNewline: Bool, cancelled: CancelFlag, onText: (@Sendable (String) -> Void)? = nil) throws -> String {
        var tokens = prompt
        // Keep the end of an over-long prompt (the question, or the text at the caret, is last) and leave
        // room for the answer.
        let room = Int(llama_n_ctx(context)) - maxTokens - 1
        guard room > 0 else { throw AIError.server("The model's context is too small.") }
        if tokens.count > room { tokens = Array(tokens.suffix(room)) }

        // The prompt goes in batches no larger than the context's batch size.
        let batchSize = Int(Defaults.AI.localBatchSize)
        var start = 0
        while start < tokens.count {
            if cancelled.isSet { throw CancellationError() }
            let end = min(start + batchSize, tokens.count)
            var chunk = Array(tokens[start..<end])
            let status = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard status == 0 else { throw AIError.server("The model couldn't read the prompt (error \(status)).") }
            start = end
        }

        // Greedy sampling: SQL wants the most likely token, not variety.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw AIError.server("Couldn't start the sampler.")
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output = Data()
        var piece = [CChar](repeating: 0, count: Int(Defaults.AI.localPieceLength))
        let fimPad = llama_vocab_fim_pad(vocab)
        var previous: llama_token = -1
        var repeats = 0
        /// Bytes already passed to `onText`; a token can end in the middle of a UTF-8 character.
        var sent = 0
        for _ in 0..<maxTokens {
            if cancelled.isSet { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) || (fimPad >= 0 && token == fimPad) { break }
            // Small models sometimes loop on one token ("1000000…"); stop before the run gets long.
            repeats = token == previous ? repeats + 1 : 0
            previous = token
            if repeats >= Defaults.AI.localRepeatLimit { break }
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length > 0 { output.append(contentsOf: piece[0..<Int(length)].map { UInt8(bitPattern: $0) }) }
            if let onText {
                let complete = Self.completeUTF8Length(output)
                if complete > sent {
                    onText(String(decoding: output[sent..<complete], as: UTF8.self))
                    sent = complete
                }
            }
            if stopAtNewline, output.contains(UInt8(ascii: "\n")) { break }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The length of `data` without a UTF-8 character cut off at its end.
    static func completeUTF8Length(_ data: Data) -> Int {
        var index = data.count
        // Walk back over continuation bytes (10xxxxxx) to the lead byte of the last character.
        while index > 0, data.count - index < 4, data[data.startIndex + index - 1] & 0xC0 == 0x80 { index -= 1 }
        guard index > 0 else { return data.count }
        let lead = data[data.startIndex + index - 1]
        let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return data.count - (index - 1) >= needed ? data.count : index - 1
    }

    private func load(_ path: String) throws -> (OpaquePointer, OpaquePointer) {
        if let loaded, loaded.path == path { return (loaded.model, loaded.context) }
        release()
        guard FileManager.default.fileExists(atPath: path) else {
            throw AIError.notConfigured("The model file is missing. Download it again in Settings › AI.")
        }
        var modelParams = llama_model_default_params()
        #if arch(x86_64)
        modelParams.n_gpu_layers = 0  // Intel Macs: run on the CPU
        #else
        modelParams.n_gpu_layers = -1  // Apple silicon: every layer on the GPU
        #endif
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw AIError.server("Couldn't load the model. The file may be damaged or not a GGUF model.")
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Defaults.AI.localContextLength
        contextParams.n_batch = Defaults.AI.localBatchSize
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw AIError.server("Not enough memory to run this model.")
        }
        loaded = (path, model, context)
        return (model, context)
    }

    private func release() {
        guard let loaded else { return }
        llama_free(loaded.context)
        llama_model_free(loaded.model)
        self.loaded = nil
    }

    private func scheduleUnload() {
        let work = DispatchWorkItem { [weak self] in self?.release() }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + Defaults.AI.localUnloadDelay, execute: work)
    }

    /// The prompt in the model's own chat format, or a plain fallback for models without one.
    private func chat(model: OpaquePointer, instructions: String, prompt: String) -> String {
        let fallback = "\(instructions)\n\n\(prompt)\n\n"
        guard let template = llama_model_chat_template(model, nil) else { return fallback }
        return instructions.withCString { system in
            prompt.withCString { user in
                "system".withCString { systemRole in
                    "user".withCString { userRole in
                        var messages = [llama_chat_message(role: systemRole, content: system),
                                        llama_chat_message(role: userRole, content: user)]
                        var buffer = [CChar](repeating: 0, count: (instructions.utf8.count + prompt.utf8.count) * 2 + 512)
                        var length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                        if length > Int32(buffer.count) {
                            buffer = [CChar](repeating: 0, count: Int(length) + 1)
                            length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                        }
                        guard length > 0 else { return fallback }
                        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
            }
        }
    }

    /// `special`: the text is a prompt we built (chat template markup, BOS); off for the user's own text.
    private func tokenize(_ text: String, vocab: OpaquePointer, special: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString.dropLast())
        guard !utf8.isEmpty else { return [] }
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), special, special)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), special, special)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }
}

/// Set from a cancellation handler, read on the model queue.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
