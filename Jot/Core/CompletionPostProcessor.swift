import AppKit
import Foundation

/// Post-generation quality pipeline for raw LLM output.
///
/// Modeled on cotabby's InsertionSafetyGate, ControlTokenMarkers, CompletionSeamGuard,
/// and SuggestionTextNormalizer. All stages are pure so they're easy to test and debug.
enum CompletionPostProcessor {

    // MARK: - Main pipeline

    /// Returns cleaned suggestion text, or empty string if the completion fails any quality gate.
    static func process(
        raw: String,
        textBefore: String,
        textAfter: String?,
        maxWords: Int
    ) -> String {
        var result = raw

        // 1. Strip chat-template control tokens and <think> reasoning blocks
        result = sanitizeControlTokens(result)
        result = stripThinkBlocks(result)

        // 2. Strip scaffolding labels the model echoed from the prompt
        result = stripLeadingScaffoldingLabels(result)

        // 3. Strip wrapping quotes the model sometimes adds
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        // 4. Collapse to first line — never show multi-line ghost text in single-line mode.
        // Only strip TRAILING whitespace here. Leading whitespace (the word-boundary space the
        // model outputs after completing a word) must survive to step 7 which decides whether to
        // keep or strip it based on whether the preceding text already ends with whitespace.
        // Stripping it here caused "The quick brown" + " fox" → "foxes" to insert "brownfox".
        if let nl = result.firstIndex(of: "\n") {
            result = String(result[..<nl])
        }
        while result.last.map({ $0.isWhitespace }) == true { result.removeLast() }

        // 5. Echo stripping: mid-word case
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        if !endsWithSpace {
            let fragment = textBefore
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .last ?? ""
            if fragment.count >= 2 && result.lowercased().hasPrefix(fragment.lowercased()) {
                result = String(result.dropFirst(fragment.count))
            }
        }

        // 6. Echo stripping: word-by-word tail overlap
        result = stripWordEchoPrefix(result, precedingText: textBefore)

        // 7. Space normalization after echo stripping.
        // Only strip a leading space when the preceding text ALREADY ends with whitespace —
        // preventing a double-space. When preceding text ends WITHOUT whitespace (cursor mid-word
        // or right after a word with no space), the model's leading space is the word boundary
        // the user needs: stripping it would produce "The quick brownfox" instead of " fox".
        // This matches Cotabby's SuggestionTextNormalizer deterministic-space-management rule.
        let precedingEndsWithSpace = textBefore.unicodeScalars.last.map {
            CharacterSet.whitespaces.contains($0)
        } ?? false
        if precedingEndsWithSpace {
            result = String(result.drop(while: { $0 == " " || $0 == "\t" }))
        }

        // 8. Trailing duplication guard (mid-text fill-in)
        if let after = textAfter, !after.isEmpty {
            let foldedResult = alphanumericFold(result)
            let foldedAfter  = alphanumericFold(String(after.prefix(80)))
            if foldedResult.count >= 4 &&
                (foldedAfter.hasPrefix(foldedResult) || foldedResult.hasPrefix(foldedAfter)) {
                return ""
            }
        }

        // 9. Hard word-count cap
        let tokens = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if tokens.count > maxWords {
            result = tokens.prefix(maxWords).joined(separator: " ")
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // 10. InsertionSafetyGate — rejects control chars, whitespace-only, U+FFFD glyphs
        guard isSafeToInsert(result) else { return "" }

        // 11. SeamGuard — rejects junk punctuation runs (e.g. ".....", "$$$$")
        guard !introducesJunkPunctuationRun(precedingText: textBefore, completion: result) else { return "" }

        return result
    }

    // MARK: - Control token sanitization (cotabby: ControlTokenMarkers)

    private static let openingMarkers = [
        "<|im_start|>", "<start_of_turn>", "<|user|>", "<|assistant|>",
        "<|system|>", "<|start_header_id|>", "<|end_header_id|>",
        "[INST]", "[/INST]"
    ]
    private static let stopMarkers = [
        "<|im_end|>", "<|endoftext|>", "<|end|>", "<end_of_turn>", "<|eot_id|>"
    ]
    private static let roleHeaderPattern = "<\\|start_header_id\\|>.*?<\\|end_header_id\\|>"

    private static func sanitizeControlTokens(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: roleHeaderPattern, with: "", options: .regularExpression
        )
        for marker in openingMarkers {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        for marker in stopMarkers {
            if let range = result.range(of: marker) {
                result = String(result[..<range.lowerBound])
                break
            }
        }
        return result
    }

    // MARK: - Think block stripping

    private static func stripThinkBlocks(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound...close.upperBound)
        }
        // Strip unclosed opening tag if no closing tag exists
        if let open = result.range(of: "<think>") {
            result = String(result[..<open.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scaffolding label stripping

    private static let scaffoldingLabels = [
        // Standard preamble artifacts
        "here:", "sure,", "sure:", "certainly,", "certainly:", "of course,",
        "completion:", "continuing:", "the next words are", "the continuation is",
        "i'll", "let me",
        // Prompt-section labels the model echoed back
        "text before cursor:", "text after cursor:", "screen context:", "clipboard:",
        "app:", "style preference:", "continuation:", "write only the next"
    ]

    private static func stripLeadingScaffoldingLabels(_ text: String) -> String {
        var result = text
        let lower = result.lowercased()
        for label in scaffoldingLabels {
            if lower.hasPrefix(label) {
                result = String(result.dropFirst(label.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result.hasPrefix(":") || result.hasPrefix("-") {
                    result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }
        return result
    }

    // MARK: - InsertionSafetyGate (cotabby: InsertionSafetyGate.isSafeToInsert)

    private static func isSafeToInsert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var sawNonWhitespace = false
        for scalar in text.unicodeScalars {
            if scalar == "\u{FFFD}" { return false }
            if scalar.value != 0x0A, scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { sawNonWhitespace = true }
        }
        return sawNonWhitespace
    }

    // MARK: - SeamGuard: junk punctuation runs (cotabby: CompletionSeamGuard)

    private static func introducesJunkPunctuationRun(precedingText: String, completion: String) -> Bool {
        let junkRunLength = 4
        var runChar: Character?
        var runLen = 0
        var runStartsAtHead = false
        var idx = 0

        for ch in completion {
            if ch == runChar {
                runLen += 1
            } else {
                runChar = ch
                runLen = 1
                runStartsAtHead = idx == 0
            }
            idx += 1

            guard runLen >= junkRunLength,
                  let current = runChar,
                  current.isPunctuation || current.isSymbol else { continue }

            // Extending an existing run of 2+ at the caret is legitimate (e.g. "----" divider)
            if runStartsAtHead, trailingRunLength(of: precedingText, character: current) >= 2 { continue }
            return true
        }
        return false
    }

    private static func trailingRunLength(of text: String, character: Character) -> Int {
        text.reversed().prefix(while: { $0 == character }).count
    }

    // MARK: - Echo helpers

    private static func stripWordEchoPrefix(_ suggestion: String, precedingText: String) -> String {
        let sWords = suggestion.split(whereSeparator: { $0.isWhitespace })
        guard !sWords.isEmpty else { return suggestion }
        let pWords = precedingText.split(whereSeparator: { $0.isWhitespace })
        guard !pWords.isEmpty else { return suggestion }

        let maxCheck = min(pWords.count, 8)
        var bestOverlap = 0
        for depth in 1...maxCheck {
            let tail = pWords.suffix(depth)
            let head = sWords.prefix(depth)
            guard tail.count == head.count else { continue }
            if zip(tail, head).allSatisfy({ $0.0.caseInsensitiveCompare(String($0.1)) == .orderedSame }) {
                bestOverlap = depth
            }
        }
        guard bestOverlap > 0, bestOverlap < sWords.count else {
            return bestOverlap >= sWords.count ? "" : suggestion
        }
        let from = sWords[bestOverlap].startIndex
        return String(suggestion[from...])
    }

    private static func alphanumericFold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

// MARK: - Secure field detection (cotabby: SecureFieldDetector)

enum SecureFieldMarkers {
    static let sensitiveSubstrings: [String] = [
        "secure", "password", "passcode", "passphrase",
        "cvv", "cvc", "security code", "verification code",
        "one-time code", "one time code", "social security",
        "card number", "credit card"
    ]

    static func isSecure(role: String?, subrole: String?, roleDescription: String?,
                         title: String?, label: String?) -> Bool {
        [role, subrole, roleDescription, title, label]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
            .contains { marker in sensitiveSubstrings.contains { marker.contains($0) } }
    }
}
