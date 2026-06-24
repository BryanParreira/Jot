import Foundation

struct ContextBuilder {

    func build(
        textBefore: String,
        textAfter: String?,
        settings: AppSettings,
        personalization: PersonalizationStore,
        clipboard: String?,
        bundleID: String?
    ) -> (systemPrompt: String, userMessage: String) {
        let (wordMin, wordMax): (Int, Int)
        switch settings.completionLength {
        case "short": (wordMin, wordMax) = (1, 4)
        case "long":  (wordMin, wordMax) = (8, 18)
        default:      (wordMin, wordMax) = (3, 8)
        }

        // Detect mid-word (text ends without whitespace)
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        let midWordNote = endsWithSpace ? "" : " If input ends mid-word, complete that word first."

        var parts: [String] = []
        parts.append("""
        You are an inline text completion engine. \
        Output ONLY the continuation — \(wordMin)–\(wordMax) words maximum.\(midWordNote) \
        Never repeat text from input. Never add preamble or quotes. \
        Match tone, style, and language exactly. Stop at a natural phrase boundary.
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
