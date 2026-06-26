import Foundation

/// Inference engine backed by a local Ollama server.
/// Fallback when Foundation Models is unavailable (macOS < 26, no Apple Intelligence).
final class OllamaEngine: SuggestionEngine, @unchecked Sendable {

    func streamComplete(systemPrompt: String, userMessage: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        let settings = AppSettings.shared
        let options = OllamaOptions(
            temperature: 0.10,
            topP: 0.85,
            numPredict: maxTokens,
            numCtx: 2048,
            stop: ["\n", "\n\n", "```", "  "]
        )
        return AsyncThrowingStream { continuation in
            Task {
                let baseStream = await OllamaClient.shared.generateStream(
                    model: settings.model,
                    systemPrompt: systemPrompt,
                    userMessage: userMessage,
                    options: options
                )
                do {
                    for try await partial in baseStream {
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String? {
        var last = ""
        for try await partial in streamComplete(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            maxTokens: maxTokens
        ) {
            if Task.isCancelled { return nil }
            last = partial
        }
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
