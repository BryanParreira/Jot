import Foundation

struct MacroResult {
    let suggestion: String
    let triggerText: String
}

class MacroProvider {
    // Matches /keyword at end of text, preceded by whitespace or start-of-string
    private let keywordPattern = try! NSRegularExpression(
        pattern: "(?:^|(?<=\\s))(/[a-zA-Z][a-zA-Z0-9]*)$", options: []
    )

    func check(textBefore: String) -> MacroResult? {
        guard !textBefore.isEmpty else { return nil }

        let ns = textBefore as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let match = keywordPattern.firstMatch(in: textBefore, options: [], range: range) else {
            return nil
        }

        let fullRange = match.range(at: 1)
        guard fullRange.location != NSNotFound else { return nil }

        let trigger = ns.substring(with: fullRange)
        let cmd = String(trigger.dropFirst()).lowercased() // strip leading /

        guard let expansion = expand(cmd) else { return nil }
        return MacroResult(suggestion: expansion, triggerText: trigger)
    }

    private func expand(_ cmd: String) -> String? {
        let now = Date()
        switch cmd {
        case "date":
            let fmt = DateFormatter()
            fmt.dateStyle = .long
            fmt.timeStyle = .none
            return fmt.string(from: now)
        case "time":
            let fmt = DateFormatter()
            fmt.dateStyle = .none
            fmt.timeStyle = .short
            return fmt.string(from: now)
        case "now", "datetime":
            let fmt = DateFormatter()
            fmt.dateStyle = .long
            fmt.timeStyle = .short
            return fmt.string(from: now)
        case "iso", "isodate":
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.string(from: now)
        case "uuid":
            return UUID().uuidString.lowercased()
        case "rand", "random":
            return "\(Int.random(in: 1...100))"
        case "year":
            return String(Calendar.current.component(.year, from: now))
        default:
            return nil
        }
    }
}
