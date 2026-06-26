import Foundation

struct ContextBuilder {

    func build(
        textBefore: String,
        textAfter: String?,
        settings: AppSettings,
        personalization: PersonalizationStore,
        clipboard: String?,
        bundleID: String?,
        visualContext: String? = nil
    ) -> (systemPrompt: String, userMessage: String) {
        let (wordMin, wordMax): (Int, Int)
        switch settings.completionLength {
        case "short": (wordMin, wordMax) = (2, 3)
        case "long":  (wordMin, wordMax) = (5, 8)
        default:      (wordMin, wordMax) = (3, 5)
        }

        // Detect mid-word (text ends without whitespace)
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        // Tell the model to finish the partial word AND keep going — not stop at word boundary
        let midWordNote = endsWithSpace ? "" :
            " Input ends mid-word — finish that word then continue with the next words."

        var parts: [String] = []
        parts.append("""
        You are a phrase-completion engine embedded in macOS. \
        Output the next \(wordMin)–\(wordMax) words that would naturally follow the given text. \
        Raw words only — no quotes, no preamble, no explanation, no punctuation unless it fits naturally.\(midWordNote) \
        Never echo text already present. Match the writer's tone, language, and style exactly.
        """)

        if !settings.customInstructions.isEmpty {
            parts.append("Context: \(settings.customInstructions.prefix(200))")
        }

        if let bid = bundleID,
           let appInstr = settings.perAppInstructions[bid],
           !appInstr.isEmpty {
            parts.append("App: \(appInstr.prefix(100))")
        }

        if settings.personalizationLevel > 0 {
            let terms = personalization.topTerms(n: 20)
            if !terms.isEmpty {
                parts.append("Preferred terms: \(terms.joined(separator: ", "))")
            }
        }

        if settings.personalizationLevel > 3 {
            let sample = personalization.historySample(tokenBudget: settings.personalizationLevel * 120)
            if !sample.isEmpty {
                parts.append("Writing style examples:\n\(sample)")
            }
        }

        if settings.clipboardAwareness,
           let clip = clipboard,
           clip.count >= 5, clip.count <= 300 {
            parts.append("Clipboard: \"\(clip)\"")
        }

        if let visual = visualContext, !visual.isEmpty {
            parts.append("Screen context (visible text near caret): \(visual.prefix(300))")
        }

        let systemPrompt = parts.joined(separator: "\n\n")

        // Smart context trim: start at a sentence boundary for cleaner context
        let limit = settings.contextChars
        let before: String
        if textBefore.count > limit {
            let tail = String(textBefore.suffix(limit))
            // Walk forward to find a clean start (sentence end or paragraph)
            if let range = tail.range(of: ". ") {
                before = String(tail[range.upperBound...])
            } else if let range = tail.range(of: "\n") {
                before = String(tail[range.upperBound...])
            } else {
                // Fall back to first word boundary
                if let spaceIdx = tail.firstIndex(of: " ") {
                    before = String(tail[tail.index(after: spaceIdx)...])
                } else {
                    before = tail
                }
            }
        } else {
            before = textBefore
        }

        let userMessage: String
        if let after = textAfter,
           !after.isEmpty,
           !after.hasPrefix("\n"),
           settings.enableMidLine {
            let trimmedAfter = String(after.prefix(120))
            userMessage = "\(before)[FILL]\(trimmedAfter)\n\n(Output only the [FILL] text)"
        } else {
            userMessage = before
        }

        return (systemPrompt, userMessage)
    }
}
