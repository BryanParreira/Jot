import Foundation
import FoundationModels

/// Inference engine backed by Apple's on-device Foundation Models (Apple Intelligence).
/// Requires macOS 26+ with Apple Intelligence enabled (Apple Silicon M1+).
///
/// Key design decisions (modeled on cotabby's FoundationModelSuggestionEngine):
/// - Instructions channel holds stable role + few-shot examples. Cached across keystrokes.
/// - Per-request context (screen, clipboard, text) goes in the prompt to `streamResponse`.
/// - Session reuse predicate: same instructions + not mid-stream + transcript pristine.
///   Prevents `.concurrentRequests` and `.exceededContextWindowSize` failures.
/// - `streamResponse` over `respond`: first tokens appear before full decode, lets the
///   coordinator cancel mid-stream when the user types past the in-flight suggestion.
@available(macOS 26.0, *)
final class FoundationModelEngine: SuggestionEngine, @unchecked Sendable {

    // Accessed only from @MainActor tasks — @unchecked Sendable covers this.
    private var cachedSession: CachedSession?

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    init() {}

    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String? {
        var last: String?
        for try await partial in streamComplete(systemPrompt: systemPrompt, userMessage: userMessage, maxTokens: maxTokens) {
            if Task.isCancelled { return nil }
            last = partial
        }
        return last?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    func streamComplete(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }

                let session = self.ensureSession(instructions: systemPrompt)
                let options = GenerationOptions(
                    sampling: .greedy,
                    temperature: 0.0,
                    maximumResponseTokens: max(maxTokens * 4, 32)
                )

                var didReceive = false
                do {
                    for try await partial in session.streamResponse(to: userMessage, options: options) {
                        let text = partial.content
                        didReceive = true
                        try Task.checkCancellation()
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LanguageModelSession.GenerationError {
                    DebugLogger.log("[FM] generation error: \(error)")
                    // If we got partial text before the error, let it stand.
                    if didReceive {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: mapError(error))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Session management

    /// Reuse the cached session when instructions haven't changed, the session isn't
    /// mid-stream (avoids .concurrentRequests), and the transcript is still pristine
    /// (avoids .exceededContextWindowSize from accumulated turns).
    private func ensureSession(instructions: String) -> LanguageModelSession {
        if let cached = cachedSession,
           cached.instructions == instructions,
           !cached.session.isResponding,
           cached.session.transcript.count == cached.pristineTranscriptCount {
            return cached.session
        }
        let session = LanguageModelSession(model: .default, instructions: instructions)
        // Prewarm so the neural engine loads weights before the first generation call.
        session.prewarm()
        cachedSession = CachedSession(
            instructions: instructions,
            session: session,
            pristineTranscriptCount: session.transcript.count
        )
        DebugLogger.log("[FM] Session rebuilt + prewarmed")
        return session
    }

    private func mapError(_ error: LanguageModelSession.GenerationError) -> Error {
        error
    }

    private struct CachedSession {
        let instructions: String
        let session: LanguageModelSession
        let pristineTranscriptCount: Int
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
