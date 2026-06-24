import Foundation

struct EmojiResult {
    let suggestion: String
    let triggerRange: NSRange
    let triggerText: String
}

class EmojiProvider {
    private var shortcodes: [String: String] = [:]
    private let triggerPattern = try! NSRegularExpression(pattern: ":(\\w+)$", options: [])

    init() {
        loadShortcodes()
    }

    private func loadShortcodes() {
        guard let url = Bundle.main.url(forResource: "emoji-shortcodes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        shortcodes = dict
    }

    func check(textBefore: String) -> EmojiResult? {
        let nsText = textBefore as NSString
        let range = NSRange(location: 0, length: nsText.length)

        guard let match = triggerPattern.firstMatch(in: textBefore, options: [], range: range) else {
            return nil
        }

        let codeRange = match.range(at: 1)
        guard codeRange.location != NSNotFound else { return nil }
        let typedCode = nsText.substring(with: codeRange).lowercased()

        guard typedCode.count >= 2 else { return nil }

        let fullMatchRange = match.range(at: 0)

        if let exact = shortcodes[typedCode] {
            return EmojiResult(suggestion: exact, triggerRange: fullMatchRange, triggerText: nsText.substring(with: fullMatchRange))
        }

        // Fuzzy prefix match
        let matches = shortcodes.keys.filter { $0.hasPrefix(typedCode) }.sorted()
        if let first = matches.first, let emoji = shortcodes[first] {
            return EmojiResult(suggestion: emoji, triggerRange: fullMatchRange, triggerText: nsText.substring(with: fullMatchRange))
        }

        return nil
    }
}
