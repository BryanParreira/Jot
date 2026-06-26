import Foundation

/// Common interface for all inference backends.
/// Conformers: FoundationModelEngine (macOS 26+), OllamaEngine.
protocol SuggestionEngine: AnyObject, Sendable {
    /// Returns raw completion text, or nil on failure/empty.
    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String?

    /// Streams incremental completion — each yielded value is the full accumulated text so far.
    /// Default implementation wraps `complete` for engines that don't support streaming natively.
    func streamComplete(systemPrompt: String, userMessage: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}

extension SuggestionEngine {
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

/// Selects the best available engine based on user preference + runtime availability.
@MainActor
enum EngineFactory {
    static func make() -> any SuggestionEngine {
        let pref = AppSettings.shared.inferenceEngine
        switch pref {
        case "foundationModels":
            if #available(macOS 26.0, *), FoundationModelEngine.isAvailable {
                DebugLogger.log("[Engine] Using Foundation Models (user override)")
                return FoundationModelEngine()
            }
            DebugLogger.log("[Engine] Foundation Models unavailable, falling back to Ollama")
            return OllamaEngine()
        case "ollama":
            DebugLogger.log("[Engine] Using Ollama (user override)")
            return OllamaEngine()
        default:  // "auto"
            if #available(macOS 26.0, *), FoundationModelEngine.isAvailable {
                DebugLogger.log("[Engine] Auto-selected Foundation Models")
                return FoundationModelEngine()
            }
            DebugLogger.log("[Engine] Auto-selected Ollama")
            return OllamaEngine()
        }
    }
}
