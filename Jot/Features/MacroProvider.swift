import Foundation

struct MacroResult {
    let suggestion: String
    let triggerText: String
}

/// Detects inline `/command` triggers and evaluates them through `MacroEngine`.
///
/// Supported formats (all evaluated offline, no network):
/// - Date/time: /today, /now, /tomorrow, /+3d, /next-fri, /today(iso)
/// - Random: /random, /d20, /coin, /uuid, /random(1,100)
/// - Unit conversion: /10km->mi, /100f->c, /5ft->m
/// - Currency: /100usd->eur, /100 dollars to eur
/// - Arithmetic: /5+5=, /(3*4)^2=, /20%=
class MacroProvider {
    private let engine = MacroEngine.standard()

    func check(textBefore: String) -> MacroResult? {
        guard !textBefore.isEmpty else { return nil }
        guard let (trigger, query) = findMacroTrigger(textBefore) else { return nil }
        guard let result = engine.evaluate(query) else { return nil }
        return MacroResult(suggestion: result.insertionText, triggerText: trigger)
    }

    // MARK: - Trigger detection

    /// Scans backwards for the last `/` preceded by whitespace or start of text,
    /// then returns everything from that slash to the end as the trigger.
    /// Handles multi-word queries like `/100 usd to eur` by scanning back past spaces.
    private func findMacroTrigger(_ text: String) -> (trigger: String, query: String)? {
        // Cap scan to avoid slow paths on very long text
        let window = text.count <= 80 ? text : String(text.suffix(80))

        var lastSlashIdx: String.Index? = nil
        var prevWasSpaceOrStart = true
        var idx = window.startIndex

        while idx < window.endIndex {
            let ch = window[idx]
            if ch == "/" && prevWasSpaceOrStart {
                // Exclude `//` (URL protocol) and path fragments that look like /Users
                let nextIdx = window.index(after: idx)
                if nextIdx < window.endIndex && window[nextIdx] == "/" {
                    prevWasSpaceOrStart = false
                    idx = nextIdx
                    continue
                }
                lastSlashIdx = idx
            }
            prevWasSpaceOrStart = ch.isWhitespace
            idx = window.index(after: idx)
        }

        guard let slashIdx = lastSlashIdx else { return nil }

        let trigger = String(window[slashIdx...])
        guard trigger.count >= 2 else { return nil }

        let query = String(trigger.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        return (trigger, query)
    }
}
