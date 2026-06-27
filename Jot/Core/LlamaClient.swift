import Foundation
import CotabbyInference

// MARK: - Errors

enum LlamaClientError: Error, LocalizedError {
    case noModelSelected
    case modelFileNotFound(String)
    case modelLoadFailed(String)
    case runtimeError(String)

    var errorDescription: String? {
        switch self {
        case .noModelSelected:         return "No model selected. Pick a GGUF file in Settings → AI."
        case .modelFileNotFound(let p): return "Model file not found: \(p)"
        case .modelLoadFailed(let m):   return "Model load failed: \(m)"
        case .runtimeError(let m):      return "Runtime error: \(m)"
        }
    }
}

// MARK: - LlamaClient

/// In-process llama.cpp inference via CotabbyInference SPM package.
/// No HTTP server required — the model runs directly inside the app process.
/// KV cache is preserved across successive keystrokes; only the new token delta
/// is decoded on each call, giving sub-50ms first-token latency on Apple Silicon.
final class LlamaClient: @unchecked Sendable {

    static var isModelAvailable: Bool {
        let path = AppSettings.shared.llamaModelPath
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    var currentModelName: String {
        let path = AppSettings.shared.llamaModelPath
        return path.isEmpty ? "No model" : URL(fileURLWithPath: path).lastPathComponent
    }

    /// True when the loaded model ships a built-in chat template (instruction-tuned models).
    /// Base models return false — use plain-text prompts. Checked lazily after first model load.
    var hasChatTemplate: Bool { core.hasChatTemplate }

    /// Builds a prompt using the model's built-in chat template (IT models only).
    /// Returns nil if no model is loaded or the model has no chat template.
    func applyModelChatTemplate(system: String, user: String) -> String? {
        core.applyTemplate(system: system, user: user)
    }

    private let core = LlamaCore()

    // MARK: - Streaming API

    /// Streams incremental completions. Each yielded value is the full accumulated text so far.
    /// Cancel the Task to abort mid-stream; the KV cache is invalidated automatically.
    func streamComplete(
        prompt: String,
        maxTokens: Int,
        temperature: Float = 0.0
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let capturedCore = self.core
            let task = Task.detached {
                do {
                    _ = try capturedCore.generate(
                        prompt: prompt,
                        maxTokens: maxTokens,
                        temperature: temperature
                    ) { partial in
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                capturedCore.abortInFlight()
            }
        }
    }

    /// Non-streaming completion. Prefer streamComplete for overlay updates.
    func complete(prompt: String, maxTokens: Int, temperature: Float = 0.0) async throws -> String? {
        let capturedCore = core
        let task = Task.detached {
            try capturedCore.generate(prompt: prompt, maxTokens: maxTokens, temperature: temperature)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            capturedCore.abortInFlight()
        }
    }

    func resetCache() {
        core.resetCache()
    }
}

// MARK: - LlamaCore (synchronous runtime)

/// Synchronous llama.cpp wrapper. Always call generate() from a detached Task.
/// autocompleteLock guards KV cache state for the full duration of generate().
private final class LlamaCore: @unchecked Sendable {

    private var engine = CotabbyInferenceEngine()
    private var loadedModelPath = ""

    private let autocompleteLock = NSLock()
    private var sequenceID: Int32 = -1
    private var cachedBytes: [UInt8] = []
    private var cachedTokens: [Int32] = []

    private let abortLock = NSLock()
    private var abortTarget: Int32 = -1

    private static let gpuLayers: Int32 = 999     // offload all layers to ANE/GPU
    private static let contextTokens: Int32 = 2048
    private static let batchSize: Int32 = 512
    private static let seed: UInt32 = 0x00C0_FFEE // stable seed → identical context = identical output

    // MARK: - Generate

    /// Synchronous generate. Returns cumulative completion text; onPartial fires per token.
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float = 0.0,
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

            if generated.hasSuffix("\n\n") { break }
        }

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

    func abortInFlight() {
        abortLock.lock()
        let target = abortTarget
        abortLock.unlock()
        guard target >= 0 else { return }
        engine.cancelSequence(target)
    }

    // MARK: - Cache

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
        guard !path.isEmpty else { throw LlamaClientError.noModelSelected }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaClientError.modelFileNotFound(path)
        }
        guard path != loadedModelPath else { return }

        resetCache()
        engine.unloadModel()

        let status = engine.loadModel(path, Self.gpuLayers, Self.contextTokens, Self.batchSize)
        guard status == .ok else {
            loadedModelPath = ""
            throw LlamaClientError.modelLoadFailed("CotabbyInferenceEngine rejected model at \(path)")
        }
        loadedModelPath = path
        DebugLogger.log("[LlamaClient] Loaded: \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    // MARK: - Sequence management

    private func obtainSequence(promptBytes: [UInt8], allTokens: [Int32], maxTokens: Int) throws -> Int32 {
        if sequenceID >= 0 {
            let commonBytes = Self.commonPrefixCount(cachedBytes, promptBytes)
            if commonBytes > 0 {
                let commonTokens = Self.commonPrefixCount(cachedTokens, allTokens)
                let reusable = min(commonTokens, allTokens.count - 1)

                if reusable > 0, engine.trimKV(sequenceID, Int32(reusable)) {
                    let delta = Array(allTokens[reusable...])
                    if !delta.isEmpty {
                        setAbortTarget(sequenceID)
                        var mutableDelta = delta
                        let status = engine.decodePrompt(sequenceID, &mutableDelta, Int32(mutableDelta.count), Int32(reusable))
                        if status == .cancelled { throw CancellationError() }
                        if status == .ok { return sequenceID }
                    } else {
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
            temperature: 0.0,
            top_k: 40,
            top_p: 0.95,
            min_p: 0.05,
            repetition_penalty: 1.0,
            seed: Self.seed,
            single_line: false
        )
        let seqID = engine.createSequence(config)
        guard seqID >= 0 else { throw LlamaClientError.runtimeError("Failed to create inference sequence") }

        setAbortTarget(seqID)
        var mutableTokens = tokens
        let status = engine.decodePrompt(seqID, &mutableTokens, Int32(mutableTokens.count), 0)
        if status == .cancelled {
            engine.destroySequence(seqID)
            throw CancellationError()
        }
        guard status == .ok else {
            engine.destroySequence(seqID)
            throw LlamaClientError.runtimeError("Prompt decoding failed")
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

    private func setAbortTarget(_ id: Int32) {
        abortLock.lock()
        abortTarget = id
        abortLock.unlock()
    }

    private func clearAbortTarget() {
        abortLock.lock()
        abortTarget = -1
        abortLock.unlock()
    }
}
