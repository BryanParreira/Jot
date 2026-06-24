import Cocoa

struct TypoResult {
    let correction: String
    let badWord: String
}

class TypoDetector {
    private let checker = NSSpellChecker.shared

    func check(textBefore: String) -> TypoResult? {
        guard !textBefore.isEmpty else { return nil }

        let components = textBefore.components(separatedBy: .whitespacesAndNewlines)
        let words = components.filter { !$0.isEmpty }

        // Need at least 2 words; we check the last completed word (before the cursor's trailing space)
        guard words.count >= 2 else { return nil }

        let lastChar = textBefore.last
        let targetWord: String
        if lastChar == " " || lastChar == "\n" {
            // Cursor is right after a space — last word in array is completed
            targetWord = words[words.count - 1]
        } else {
            // Still typing — check second-to-last (the one before current partial word)
            targetWord = words[words.count - 2]
        }

        // Skip short, capitalized (proper noun), or numeric words
        guard targetWord.count >= 4 else { return nil }
        guard targetWord.first?.isUppercase == false else { return nil }
        guard !targetWord.contains(where: { $0.isNumber }) else { return nil }

        // Skip words the user has accepted before (their vocabulary)
        let clean = targetWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !PersonalizationStore.shared.isKnownTerm(clean) else { return nil }

        // Use NSSpellChecker
        var wordCount: Int = 0
        let range = checker.checkSpelling(
            of: clean, startingAt: 0, language: "en",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: &wordCount
        )
        guard range.location != NSNotFound else { return nil }

        let guesses = checker.guesses(
            forWordRange: NSRange(location: 0, length: clean.count),
            in: clean, language: "en", inSpellDocumentWithTag: 0
        )
        guard let correction = guesses?.first else { return nil }
        guard editDistance(clean, correction) <= 2 else { return nil }

        return TypoResult(correction: correction, badWord: clean)
    }

    private func editDistance(_ s: String, _ t: String) -> Int {
        let s = Array(s), t = Array(t)
        let m = s.count, n = t.count
        if m == 0 { return n }; if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m { for j in 1...n {
            dp[i][j] = s[i-1] == t[j-1] ? dp[i-1][j-1] : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
        }}
        return dp[m][n]
    }
}
