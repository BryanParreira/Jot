import Foundation
import FoundationModels

/// Inference engine backed by Apple's on-device Foundation Models (Apple Intelligence).
/// Requires macOS 26+ with Apple Intelligence enabled (Apple Silicon M1+).
///
/// - Zero model download: uses the system model already on device.
/// - Neural Engine accelerated: first token typically < 50 ms.
/// - Fresh session per call: no conversation history contamination between completions.
@available(macOS 26.0, *)
final class FoundationModelEngine: SuggestionEngine, @unchecked Sendable {

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    init() {
        // Prewarm Neural Engine at launch so first completion is instant.
        let warmSession = LanguageModelSession(model: .default)
        warmSession.prewarm()
        DebugLogger.log("[FM] Engine initialized, Neural Engine warming up")
    }

    func complete(systemPrompt: String, userMessage: String, maxTokens: Int) async throws -> String? {
        let session = LanguageModelSession(
            model: .default,
            instructions: systemPrompt
        )

        // 4x budget: instruction-tuned models burn tokens on preamble before the actual words.
        // postProcess strips any preamble that slips through.
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.1,
            maximumResponseTokens: max(maxTokens * 4, 32)
        )

        do {
            let response = try await session.respond(to: userMessage, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLogger.log("[FM] ← \(text.prefix(80))")
            return text.isEmpty ? nil : text

        } catch let error as LanguageModelSession.GenerationError {
            // Refusal or model error — log and return nil (not fatal, just skip suggestion)
            DebugLogger.log("[FM] generation error: \(error.localizedDescription)")
            return nil
        }
        // Other errors (cancellation etc.) propagate up to CompletionEngine
    }
}
