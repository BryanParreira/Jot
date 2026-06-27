import Foundation

/// Random and generator macros: `/random`, `/rand(n)`, `/random(a,b)`,
/// `/dice` (`/roll`, `/d20`, `/d6`…), `/coin` (`/flip`), `/uuid` (`/guid`).
struct RandomMacroEvaluator: MacroEvaluating {
    private let randomSource: (ClosedRange<Int>) -> Int
    private let uuidSource: () -> String

    init(
        randomSource: @escaping (ClosedRange<Int>) -> Int = { Int.random(in: $0) },
        uuidSource: @escaping () -> String = { UUID().uuidString }
    ) {
        self.randomSource = randomSource
        self.uuidSource = uuidSource
    }

    func evaluate(_ query: String) -> MacroEvalResult? {
        let lower = query.lowercased()
        switch lower {
        case "uuid", "guid":
            return MacroEvalResult(uuidSource())
        case "dice", "die", "roll":
            return MacroEvalResult(String(randomSource(1...6)))
        case "coin", "flip", "coinflip", "coin-flip":
            return MacroEvalResult(randomSource(0...1) == 0 ? "Heads" : "Tails")
        case "random", "rand", "rnd":
            return MacroEvalResult(String(randomSource(0...100)))
        default:
            if let sides = Self.diceSides(lower) {
                return MacroEvalResult(String(randomSource(1...sides)))
            }
            return parameterizedRandom(lower)
        }
    }

    /// `dN` dice notation: `/d20` rolls 1...20.
    private static func diceSides(_ lower: String) -> Int? {
        guard lower.hasPrefix("d"), lower.count > 1, let sides = Int(lower.dropFirst()), sides >= 1 else {
            return nil
        }
        return sides
    }

    /// `/random(n)` / `/random(a,b)` with integer arguments, normalizing reversed bounds.
    private func parameterizedRandom(_ lower: String) -> MacroEvalResult? {
        let prefixes = ["random(", "rand(", "rnd("]
        guard prefixes.contains(where: { lower.hasPrefix($0) }),
              lower.hasSuffix(")"), let open = lower.firstIndex(of: "(") else {
            return nil
        }
        let inner = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, !values.isEmpty else { return nil }

        switch values.count {
        case 1:
            guard values[0] >= 1 else { return nil }
            return MacroEvalResult(String(randomSource(1...values[0])))
        case 2:
            let low = min(values[0], values[1])
            let high = max(values[0], values[1])
            return MacroEvalResult(String(randomSource(low...high)))
        default:
            return nil
        }
    }
}
