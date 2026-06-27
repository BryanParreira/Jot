import AppKit
import Foundation

struct ContextBuilder {

    // MARK: - Base model format (llama.cpp, raw text continuation)

    /// Builds a raw continuation prompt for in-process base models.
    /// Base models predict what comes next from plain text — no system/instruct template overhead.
    /// FIM tokens are injected when the cursor is mid-line and mid-line completion is enabled.
    func buildForBaseModel(
        textBefore: String,
        textAfter: String?,
        settings: AppSettings,
        visualContext: String? = nil
    ) -> (systemPrompt: String, userMessage: String) {
        let before = trimmedContext(textBefore, limit: settings.contextChars)

        // Optional visual context as a comment header — many base models parse this naturally.
        var prefix = before
        if let visual = visualContext, !visual.isEmpty {
            prefix = "// Context: \(visual.prefix(200))\n\(before)"
        }

        // FIM (Fill-in-Middle) format when there's meaningful text after the cursor.
        if let after = textAfter,
           !after.isEmpty,
           !after.hasPrefix("\n"),
           settings.enableMidLine {
            let fimPrompt = "<|fim_prefix|>\(prefix)<|fim_suffix|>\(String(after.prefix(200)))<|fim_middle|>"
            return ("", fimPrompt)
        }

        return ("", prefix)
    }

    // MARK: - Foundation Models format

    /// Returns (instructions, prompt) for Apple's FoundationModels framework.
    ///
    /// Instructions go into `LanguageModelSession(instructions:)` — stable across keystrokes,
    /// cached by the engine. Per-request context (screen, clipboard, text) goes in the prompt
    /// passed to `streamResponse`, so the session cache doesn't invalidate every keystroke.
    func buildForFoundationModel(
        textBefore: String,
        textAfter: String?,
        settings: AppSettings,
        personalization: PersonalizationStore,
        clipboard: String?,
        bundleID: String?,
        visualContext: String?
    ) -> (systemPrompt: String, userMessage: String) {
        // INSTRUCTIONS — stable; drives session caching.
        // Keep instructions free of volatile data (personalization, app name) so the
        // session is reused across keystrokes instead of rebuilt each time.
        var instrLines: [String] = [
            "You complete partially-typed text in the user's exact voice.",
            "Output the continuation only — no greeting, no sign-off, no quotes, no markdown, no labels.",
            "Continue from immediately after the existing text. Never repeat or requote it.",
            "Continue the current sentence or thought. Do not start a new sentence unless the existing text clearly ends one.",
            "Match the existing language, register, casing, and punctuation exactly.",
            "Examples:",
            "Existing: \"I wanted to follow up on the \" → Continuation: proposal we discussed last week.",
            "Existing: \"def total(items): return \" → Continuation: sum(item.price for item in items)",
            "Existing: \"Thanks for your \" → Continuation: patience with this.",
        ]

        if !settings.customInstructions.isEmpty {
            instrLines.append("Style preference: \(settings.customInstructions.prefix(200))")
        }

        if let bid = bundleID,
           let appInstr = settings.perAppInstructions[bid],
           !appInstr.isEmpty {
            instrLines.append("App-specific rule: \(appInstr.prefix(100))")
        }

        let instructions = instrLines.joined(separator: "\n")

        // PROMPT — per request; volatile context lives here so instructions stay stable.
        var promptLines: [String] = []

        if let bid = bundleID, !bid.isEmpty {
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bid })?.localizedName {
                promptLines.append("App: \(app)")
            }
            if let tone = Self.appToneHint(bundleID: bid) {
                promptLines.append(tone)
            }
        }

        // Personalization in prompt (not instructions) so the session cache stays valid
        if settings.personalizationLevel > 0 {
            let phrases = personalization.topPhrases(n: 6)
            if !phrases.isEmpty {
                promptLines.append("User's frequent phrases: \(phrases.joined(separator: "; "))")
            }
            let terms = personalization.topTerms(n: 8)
            if !terms.isEmpty {
                promptLines.append("User's preferred terms: \(terms.joined(separator: ", "))")
            }
            let sample = personalization.historySample(tokenBudget: 80)
            if !sample.isEmpty {
                promptLines.append("Style reference: \(sample)")
            }
        }

        if let visual = visualContext, !visual.isEmpty {
            promptLines.append("Screen context: \(visual.prefix(300))")
        }

        if settings.clipboardAwareness,
           let clip = clipboard,
           clip.count >= 5, clip.count <= 200 {
            promptLines.append("Clipboard: \"\(clip)\"")
        }

        let before = trimmedContext(textBefore, limit: settings.contextChars)
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        let midWordNote = endsWithSpace ? "" : " (cursor is mid-word — finish the current word first)"

        promptLines.append("")
        promptLines.append("Text before cursor\(midWordNote):")
        promptLines.append(before)

        if let after = textAfter,
           !after.isEmpty,
           !after.hasPrefix("\n"),
           settings.enableMidLine {
            promptLines.append("")
            promptLines.append("Text after cursor:")
            promptLines.append(String(after.prefix(100)))
        }

        let lengthInstruction: String
        switch settings.completionLength {
        case "short": lengthInstruction = "Write the next 1–3 words."
        case "long":  lengthInstruction = "Write the next 5–8 words."
        default:      lengthInstruction = "Write the next 2–5 words."
        }

        promptLines.append("")
        promptLines.append(lengthInstruction)

        return (instructions, promptLines.joined(separator: "\n"))
    }

    // MARK: - Shared

    private static func appToneHint(bundleID: String) -> String? {
        let b = bundleID.lowercased()
        if b.contains("mail")                                           { return "Tone: professional email." }
        if b.contains("slack") || b.contains("discord") || b.contains("telegram") || b.contains("whatsapp") {
            return "Tone: casual, concise."
        }
        if b.contains("messages")                                       { return "Tone: conversational." }
        if b.contains("xcode") || b.contains("nova") || b.contains("vscode") || b.contains("sublime") {
            return "Tone: complete the code logically."
        }
        if b.contains("notes") || b.contains("notion") || b.contains("obsidian") || b.contains("bear") {
            return "Tone: clear notes or documentation."
        }
        if b.contains("safari") || b.contains("chrome") || b.contains("firefox") || b.contains("arc") {
            return "Tone: match the form or page context."
        }
        return nil
    }

    /// Trim context to `limit` chars, starting at a clean sentence/paragraph boundary.
    private func trimmedContext(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let tail = String(text.suffix(limit))
        if let r = tail.range(of: ". ") { return String(tail[r.upperBound...]) }
        if let r = tail.range(of: "\n")  { return String(tail[r.upperBound...]) }
        if let idx = tail.firstIndex(of: " ") { return String(tail[tail.index(after: idx)...]) }
        return tail
    }
}
