import Foundation
import CotabbyInference

// MARK: - Errors

enum LlamaError: Error, LocalizedError {
    case noModelSelected
    case modelFileNotFound(String)
    case modelLoadFailed(String)
    case runtimeError(String)

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No model selected. Pick a GGUF file in Settings → AI."
        case .modelFileNotFound(let p):
            return "Model file not found: \(p)"
        case .modelLoadFailed(let msg):
            return "Model load failed: \(msg)"
        case .runtimeError(let msg):
            return "Runtime error: \(msg)"
        }
    }
}

// MARK: - Engine

/// In-process llama.cpp inference via CotabbyInference.
/// Replaces Ollama: no external process, no HTTP, first token in <50 ms on Apple Silicon.
/// KV cache reuse: successive keystrokes decode only the typed delta, not the full prompt.
final class LlamaEngine: SuggestionEngine, @unchecked Sendable {

    let promptStyle: PromptStyle = .baseText

    private let core = LlamaCore()

    static var isAvailable: Bool {
        let path = AppSettings.shared.llamaModelPath
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String? {
        let capturedCore = core
        let task = Task.detached {
            try capturedCore.generate(prompt: userMessage, maxTokens: maxTokens)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            capturedCore.abortInFlight()
        }
    }

    func streamComplete(systemPrompt: String, userMessage: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let capturedCore = self.core
            let generateTask = Task.detached {
                do {
                    _ = try capturedCore.generate(prompt: userMessage, maxTokens: maxTokens) { partial in
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                generateTask.cancel()
                capturedCore.abortInFlight()
            }
        }
    }
}

// MARK: - Core runtime

/// Synchronous llama.cpp wrapper. Always call generate() from a detached Task.
/// Holds autocompleteLock for the full operation to protect KV cache state from concurrent mutation.
private final class LlamaCore: @unchecked Sendable {

    private var engine = CotabbyInferenceEngine()
    private var loadedModelPath = ""

    // Protects KV cache sequence state for the duration of generate().
    private let autocompleteLock = NSLock()
    private var sequenceID: Int32 = -1
    private var cachedBytes: [UInt8] = []
    private var cachedTokens: [Int32] = []

    // Separate lock so abortInFlight() can fire from any thread without waiting on autocompleteLock.
    private let abortLock = NSLock()
    private var abortTarget: Int32 = -1

    // Offload all layers to ANE/GPU on Apple Silicon; fall back to CPU if count exceeds the model.
    private static let gpuLayers: Int32 = 999
    private static let contextTokens: Int32 = 2048
    private static let batchSize: Int32 = 512
    // Stable seed: identical context produces identical completions across keystrokes.
    private static let defaultSeed: UInt32 = 0x00C0_FFEE

    // MARK: - Generate

    /// Synchronous generate. Returns the cumulative completion; onPartial receives each new token.
    /// Must be called from a detached Task so autocompleteLock does not block the main actor.
    func generate(
        prompt: String,
        maxTokens: Int,
        onPartial: ((String) -> Void)? = nil
    ) throws -> String? {
        try ensureModelLoaded()

        let promptBytes = Array(prompt.utf8)
        let allTokens = tokenize(prompt)
        guard !allTokens.isEmpty else { return nil }

        autocompleteLock.lock()
        defer {
            clearAbortTarget()
            autocompleteLock.unlock()
        }

        let seqID = try obtainSequence(promptBytes: promptBytes, allTokens: allTokens, maxTokens: maxTokens)

        var generated = ""
        var engineCancelled = false

        for _ in 0 ..< maxTokens {
            if Task.isCancelled { break }
            let result = engine.sampleNext(seqID)
            if result.was_cancelled { engineCancelled = true; break }
            if result.is_eos || result.argmax_is_eog { break }

            let piece = Self.extractPiece(result)
            generated += piece
            onPartial?(generated)

            // Stop at paragraph boundary — the normalizer handles sentence truncation downstream.
            if generated.hasSuffix("\n\n") { break }
        }

        // Preserve KV state for next keystroke's prefix reuse, or clear if the sequence is unusable.
        if engineCancelled {
            engine.destroySequence(seqID)
            sequenceID = -1
            cachedBytes = []
            cachedTokens = []
        } else {
            _ = engine.trimKV(seqID, Int32(allTokens.count))
            cachedBytes = promptBytes
            cachedTokens = allTokens
            sequenceID = seqID
        }

        return generated.isEmpty ? nil : generated
    }

    // MARK: - Abort

    /// Interrupts the in-flight decode at its next token. Safe from any thread.
    func abortInFlight() {
        abortLock.lock()
        let target = abortTarget
        abortLock.unlock()
        guard target >= 0 else { return }
        engine.cancelSequence(target)
    }

    // MARK: - Cache reset

    func resetCache() {
        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }
        if sequenceID >= 0 {
            engine.destroySequence(sequenceID)
            sequenceID = -1
        }
        cachedBytes = []
        cachedTokens = []
    }

    // MARK: - Model loading

    private func ensureModelLoaded() throws {
        let path = AppSettings.shared.llamaModelPath
        guard !path.isEmpty else { throw LlamaError.noModelSelected }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaError.modelFileNotFound(path)
        }
        guard path != loadedModelPath else { return }

        // New path — unload previous model and reset KV before loading.
        resetCache()
        engine.unloadModel()

        let status = engine.loadModel(path, Self.gpuLayers, Self.contextTokens, Self.batchSize)
        guard status == .ok else {
            loadedModelPath = ""
            throw LlamaError.modelLoadFailed("CotabbyInferenceEngine rejected the model at \(path)")
        }
        loadedModelPath = path
        let name = URL(fileURLWithPath: path).lastPathComponent
        DebugLogger.log("[LlamaEngine] Loaded: \(name) ctx=\(engine.getContextWindowTokens()) gpu=\(engine.getGPULayerCount())")
    }

    // MARK: - Sequence management

    /// Returns a sequence whose KV state represents the full prompt, reusing cached tokens where safe.
    /// Must be called while holding autocompleteLock.
    private func obtainSequence(promptBytes: [UInt8], allTokens: [Int32], maxTokens: Int) throws -> Int32 {
        if sequenceID >= 0 {
            let commonBytes = Self.commonPrefixCount(cachedBytes, promptBytes)
            if commonBytes > 0 {
                let commonTokens = Self.commonPrefixCount(cachedTokens, allTokens)
                // Keep at least one slot free for the first sampled token.
                let reusable = min(commonTokens, allTokens.count - 1)

                if reusable > 0, engine.trimKV(sequenceID, Int32(reusable)) {
                    let delta = Array(allTokens[reusable...])
                    if !delta.isEmpty {
                        setAbortTarget(sequenceID)
                        var mutableDelta = delta
                        let status = engine.decodePrompt(
                            sequenceID, &mutableDelta, Int32(mutableDelta.count), Int32(reusable)
                        )
                        if status == .cancelled { throw CancellationError() }
                        if status == .ok { return sequenceID }
                        // Delta decode failed — fall through to fresh build.
                    } else {
                        // Full reuse: nothing new to decode.
                        return sequenceID
                    }
                }
            }
            engine.destroySequence(sequenceID)
            sequenceID = -1
        }
        return try buildFreshSequence(tokens: allTokens, maxTokens: maxTokens)
    }

    private func buildFreshSequence(tokens: [Int32], maxTokens: Int) throws -> Int32 {
        let config = SamplingConfig(
            max_prediction_tokens: Int32(maxTokens),
            temperature: 0.0,           // Greedy: deterministic, no hallucination drift.
            top_k: 40,
            top_p: 0.95,
            min_p: 0.05,
            repetition_penalty: 1.0,
            seed: Self.defaultSeed,
            single_line: false
        )
        let seqID = engine.createSequence(config)
        guard seqID >= 0 else {
            throw LlamaError.runtimeError("Failed to create inference sequence")
        }
        setAbortTarget(seqID)
        var mutableTokens = tokens
        let status = engine.decodePrompt(seqID, &mutableTokens, Int32(mutableTokens.count), 0)
        if status == .cancelled {
            engine.destroySequence(seqID)
            throw CancellationError()
        }
        guard status == .ok else {
            engine.destroySequence(seqID)
            throw LlamaError.runtimeError("Prompt decoding failed")
        }
        sequenceID = seqID
        return seqID
    }

    // MARK: - Helpers

    private func tokenize(_ text: String) -> [Int32] {
        let count = text.utf8.count
        guard count > 0 else { return [] }
        return Array(engine.tokenize(text, Int32(count)))
    }

    private static func extractPiece(_ result: SampleResult) -> String {
        guard let piece = result.piece, result.piece_length > 0 else { return "" }
        let buf = UnsafeBufferPointer(
            start: UnsafeRawPointer(piece).assumingMemoryBound(to: UInt8.self),
            count: Int(result.piece_length)
        )
        return String(bytes: buf, encoding: .utf8) ?? ""
    }

    private static func commonPrefixCount<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        var i = 0
        let limit = min(lhs.count, rhs.count)
        while i < limit, lhs[i] == rhs[i] { i += 1 }
        return i
    }

    private func setAbortTarget(_ seqID: Int32) {
        abortLock.lock()
        abortTarget = seqID
        abortLock.unlock()
    }

    private func clearAbortTarget() {
        abortLock.lock()
        abortTarget = -1
        abortLock.unlock()
    }
}
