import AppKit

/// Builds the prompt for in-process base/IT models (llama.cpp).
///
/// Model-variant detection by filename:
///   - Gemma IT (-it, -instruct suffix) → Gemma chat template
///   - Gemma base / everything else     → plain text continuation (base-model style)
///
/// FIM tokens (<|fim_prefix|> / <|fim_suffix|> / <|fim_middle|>) work for both
/// Gemma base and most other FIM-capable models (CodeGemma, DeepSeek, Qwen, etc.).
struct PromptBuilder {

    // MARK: - Model variant

    private enum ModelVariant {
        case gemmaIT    // Gemma instruction-tuned — needs <start_of_turn> template
        case gemmaBase  // Gemma pretrained — plain text, same as other base models
        case base       // Any other base model
    }

    private var modelVariant: ModelVariant {
        let name = AppSettings.shared.llamaModelPath.lowercased()
        guard name.contains("gemma") else { return .base }
        return (name.contains("-it") || name.contains("instruct")) ? .gemmaIT : .gemmaBase
    }

    // MARK: - Build

    func build(
        textBefore: String,
        textAfter: String? = nil,
        bundleID: String? = nil
    ) -> String {
        // Trim trailing whitespace so the model starts at a clean word boundary.
        // This stabilises the KV prefix across keystrokes (no trailing-space difference) and
        // ensures the model's first token is a word, not a space echo.
        let raw = trimmedContext(textBefore, limit: AppSettings.shared.contextChars)
        var view = Substring(raw)
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        let context = String(view)

        // FIM — same token set for Gemma base, CodeGemma, Qwen, DeepSeek, etc.
        if AppSettings.shared.enableMidLine,
           let after = textAfter,
           !after.isEmpty,
           !after.hasPrefix("\n") {
            switch modelVariant {
            case .gemmaIT:
                // Gemma IT FIM: wrap the FIM block inside the instruction template
                let fim = "<|fim_prefix|>\(context)<|fim_suffix|>\(String(after.prefix(200)))<|fim_middle|>"
                return "<start_of_turn>user\n\(fim)<end_of_turn>\n<start_of_turn>model\n"
            case .gemmaBase, .base:
                return "<|fim_prefix|>\(context)<|fim_suffix|>\(String(after.prefix(200)))<|fim_middle|>"
            }
        }

        switch modelVariant {
        case .gemmaIT:
            // Instruction template: ask the model to continue naturally without meta-commentary
            let systemHint = appToneHint(bundleID: bundleID)
            let instruction: String
            if let hint = systemHint {
                instruction = "\(hint) Continue writing from where the text ends. Output only the continuation:\n\n\(context)"
            } else {
                instruction = "Continue writing from where the text ends. Output only the continuation:\n\n\(context)"
            }
            return "<start_of_turn>user\n\(instruction)<end_of_turn>\n<start_of_turn>model\n"

        case .gemmaBase, .base:
            if let hint = appToneHint(bundleID: bundleID) {
                return "// \(hint)\n\(context)"
            }
            return context
        }
    }

    // MARK: - App-aware tone hints

    private func appToneHint(bundleID: String?) -> String? {
        guard let bid = bundleID?.lowercased() else { return nil }
        if bid.contains("mail")                                              { return "Email context. Professional tone." }
        if bid.contains("slack") || bid.contains("discord") || bid.contains("telegram") { return "Chat context. Casual, concise." }
        if bid.contains("messages")                                          { return "Message context. Conversational." }
        if bid.contains("xcode") || bid.contains("vscode") || bid.contains("nova") || bid.contains("sublime") {
            return "Code context. Complete the expression logically."
        }
        if bid.contains("notes") || bid.contains("notion") || bid.contains("obsidian") || bid.contains("bear") {
            return "Notes context. Clear, direct prose."
        }
        return nil
    }

    // MARK: - Context trimming

    private func trimmedContext(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let tail = String(text.suffix(limit))
        if let r = tail.range(of: ". ")  { return String(tail[r.upperBound...]) }
        if let r = tail.range(of: "\n")  { return String(tail[r.upperBound...]) }
        if let idx = tail.firstIndex(of: " ") { return String(tail[tail.index(after: idx)...]) }
        return tail
    }
}
