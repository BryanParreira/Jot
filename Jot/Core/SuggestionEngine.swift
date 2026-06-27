import Foundation

// Determines how CompletionEngine formats the prompt for this engine.
enum PromptStyle {
    case foundationModel  // Instruction-following format (Apple Intelligence)
    case baseText         // Raw text continuation (llama.cpp base models)
}

/// Common interface for all inference backends.
/// Conformers: LlamaEngine, FoundationModelEngine (macOS 26+).
protocol SuggestionEngine: AnyObject, Sendable {
    var promptStyle: PromptStyle { get }

    /// Returns raw completion text, or nil on failure/empty.
    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String?

    /// Streams incremental completion — each yielded value is the full accumulated text so far.
    /// Default implementation wraps `complete` for engines that don't support streaming natively.
    func streamComplete(systemPrompt: String, userMessage: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}

extension SuggestionEngine {
    var promptStyle: PromptStyle { .foundationModel }

    func streamComplete(systemPrompt: String, userMessage: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if let result = try await self.complete(
                        systemPrompt: systemPrompt,
                        userMessage: userMessage,
                        maxTokens: maxTokens
                    ) {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Selects the best available engine at runtime.
/// LlamaEngine is always returned — it loads its model lazily so picking a model mid-session
/// just works without restarting the app. It throws gracefully when no model is set.
@MainActor
enum EngineFactory {
    static func make() -> any SuggestionEngine {
        DebugLogger.log("[Engine] Using llama.cpp (model loaded lazily on first request)")
        return LlamaEngine()
    }
}

/// Placeholder returned when no engine is configured.
final class DisabledEngine: SuggestionEngine, @unchecked Sendable {
    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String? { nil }
    func streamComplete(systemPrompt: String, userMessage: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
