import Foundation

// MARK: - MacroEvalResult

/// Internal result from a macro evaluator. `previewText` is shown in ghost text;
/// `insertionText` is what actually replaces the typed `/command` on accept.
/// They differ for arithmetic: preview shows `= 10`, insertion inserts `10`.
struct MacroEvalResult: Equatable {
    let previewText: String
    let insertionText: String

    init(previewText: String, insertionText: String) {
        self.previewText = previewText
        self.insertionText = insertionText
    }

    /// Convenience for macros whose preview and inserted text are identical.
    init(_ value: String) {
        self.previewText = value
        self.insertionText = value
    }
}

// MARK: - MacroEvaluating

/// A pure macro family. Implementations are deterministic given injected
/// clock/RNG, making them unit-testable without AX, CGEvent, or UI.
protocol MacroEvaluating {
    func evaluate(_ query: String) -> MacroEvalResult?
}

// MARK: - ConversionSeparator

/// Splits a conversion query (`<value><from> <sep> <to>`) on the first
/// accepted separator: `->`, `→`, or space-delimited `to`. Shared by
/// unit and currency evaluators.
enum ConversionSeparator {
    static func split(_ query: String) -> (left: String, right: String)? {
        for token in ["->", "→"] where query.contains(token) {
            if let range = query.range(of: token) {
                return (String(query[..<range.lowerBound]), String(query[range.upperBound...]))
            }
        }
        if let range = query.range(of: " to ", options: [.caseInsensitive]) {
            return (String(query[..<range.lowerBound]), String(query[range.upperBound...]))
        }
        return nil
    }
}

// MARK: - MacroEngine

/// Aggregates all macro families and tries them in priority order.
struct MacroEngine {
    private let evaluators: [MacroEvaluating]

    init(evaluators: [MacroEvaluating]) {
        self.evaluators = evaluators
    }

    /// Production engine with all families wired up.
    static func standard(
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        locale: Locale = .current,
        randomSource: @escaping (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
    ) -> MacroEngine {
        MacroEngine(evaluators: [
            DateMacroEvaluator(now: now, calendar: calendar, locale: locale),
            RandomMacroEvaluator(randomSource: randomSource),
            UnitConversionEvaluator(locale: locale),
            CurrencyEvaluator(locale: locale),
            ArithmeticEvaluator()
        ])
    }

    /// Returns the result for the typed `/query` (without the `/`), or nil when nothing matches.
    func evaluate(_ query: String) -> MacroEvalResult? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for evaluator in evaluators {
            if let result = evaluator.evaluate(trimmed) {
                return result
            }
        }
        return nil
    }
}
