import Foundation

/// Safe arithmetic for `/` macros: `+ - * / ^`, parentheses, unary sign,
/// decimals, and a trailing `%` (value ÷ 100). `x`, `X`, `×` mean multiply;
/// `÷` means divide.
///
/// Does NOT use NSExpression — that can evaluate arbitrary key paths and
/// function calls, which is an injection risk for user text. This
/// recursive-descent parser only ever produces a number.
///
/// A bare number with no operator (`/5`) is intentionally not a result so
/// the macro doesn't fire on ordinary typing. A trailing `=` triggers
/// computation: `/5+5=` becomes `10`.
struct ArithmeticEvaluator: MacroEvaluating {
    func evaluate(_ query: String) -> MacroEvalResult? {
        let literal = query.hasSuffix("=") ? String(query.dropLast()) : query
        guard !literal.isEmpty else { return nil }

        let normalized = literal
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")

        var parser = Parser(normalized)
        guard let value = parser.parse(), parser.usedOperator, value.isFinite else { return nil }
        guard let resultText = Self.format(value) else { return nil }

        return MacroEvalResult(previewText: "= \(resultText)", insertionText: resultText)
    }

    static func format(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == value.rounded(), value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.10g", value)
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private(set) var usedOperator = false
        private var valid = true

        init(_ string: String) {
            characters = Array(string.filter { !$0.isWhitespace })
        }

        mutating func parse() -> Double? {
            let value = parseExpression()
            guard valid, index == characters.count else { return nil }
            return value
        }

        private mutating func parseExpression() -> Double {
            var value = parseTerm()
            while let op = peek(), op == "+" || op == "-" {
                advance(); usedOperator = true
                let rhs = parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double {
            var value = parsePower()
            while let op = peek(), op == "*" || op == "/" {
                advance(); usedOperator = true
                let rhs = parsePower()
                if op == "/" {
                    guard rhs != 0 else { valid = false; return 0 }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func parsePower() -> Double {
            let base = parseUnary()
            if peek() == "^" {
                advance(); usedOperator = true
                return pow(base, parsePower())
            }
            return base
        }

        private mutating func parseUnary() -> Double {
            if peek() == "-" { advance(); return -parsePostfix() }
            if peek() == "+" { advance(); return parsePostfix() }
            return parsePostfix()
        }

        private mutating func parsePostfix() -> Double {
            var value = parsePrimary()
            while peek() == "%" { advance(); usedOperator = true; value /= 100 }
            return value
        }

        private mutating func parsePrimary() -> Double {
            if peek() == "(" {
                advance()
                let value = parseExpression()
                if peek() == ")" { advance() } else { valid = false }
                return value
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double {
            var digits = ""
            while let ch = peek(), ch.isNumber || ch == "." { digits.append(ch); advance() }
            guard let value = Double(digits) else { valid = false; return 0 }
            return value
        }

        private func peek() -> Character? { index < characters.count ? characters[index] : nil }
        private mutating func advance() { index += 1 }
    }
}
