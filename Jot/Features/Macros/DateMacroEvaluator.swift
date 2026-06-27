import Foundation

/// Date and time macros: `/today`, `/now`, `/datetime`, `/tomorrow`, `/yesterday`,
/// `/noon`, `/midnight`, weekday navigation (`/next-fri`, `/this-mon`, `/last-wed`),
/// and relative offsets (`/+3d`, `/-5d`, `/+2w`, `/+1mo`, `/+1y`). Common
/// short forms are accepted (`/tdy`, `/tmrw`, `/rn`). An optional format
/// argument tunes output: `/today(iso)`, `/today(long)`, `/today(short)`,
/// `/now(24h)`.
struct DateMacroEvaluator: MacroEvaluating {
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale

    init(now: @escaping () -> Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        var resolved = calendar
        resolved.locale = locale
        self.calendar = resolved
        self.locale = locale
    }

    func evaluate(_ query: String) -> MacroEvalResult? {
        let lower = query.lowercased()
        let (rawBase, argument) = Self.splitArgument(lower)
        let base = Self.canonicalBase(rawBase)

        if let relative = relativeDate(base) {
            return MacroEvalResult(formatDate(relative, style: dateStyle(for: argument)))
        }

        switch base {
        case "today", "date":
            return MacroEvalResult(formatDate(now(), style: dateStyle(for: argument)))
        case "tomorrow":
            return offsetDays(1).map { MacroEvalResult(formatDate($0, style: dateStyle(for: argument))) }
        case "yesterday":
            return offsetDays(-1).map { MacroEvalResult(formatDate($0, style: dateStyle(for: argument))) }
        case "now", "time":
            return MacroEvalResult(formatTime(now(), use24Hour: argument == "24h"))
        case "datetime":
            return MacroEvalResult(formatDateTime(now()))
        case "noon":
            return timeOfDay(hour: 12).map { MacroEvalResult(formatTime($0, use24Hour: argument == "24h")) }
        case "midnight":
            return timeOfDay(hour: 0).map { MacroEvalResult(formatTime($0, use24Hour: argument == "24h")) }
        case "year":
            return MacroEvalResult(String(calendar.component(.year, from: now())))
        case "iso", "isodate":
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            return MacroEvalResult(fmt.string(from: now()))
        default:
            break
        }

        if let weekday = weekdayDate(base) {
            return MacroEvalResult(formatDate(weekday, style: dateStyle(for: argument)))
        }
        return nil
    }

    // MARK: - Date computation

    private func offsetDays(_ days: Int) -> Date? {
        calendar.date(byAdding: .day, value: days, to: now())
    }

    private func timeOfDay(hour: Int) -> Date? {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now())
    }

    private func relativeDate(_ base: String) -> Date? {
        guard let sign = base.first, sign == "+" || sign == "-" else { return nil }
        let rest = base.dropFirst()
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }
        let unit = String(rest.dropFirst(digits.count))
        let value = (sign == "-" ? -1 : 1) * magnitude
        switch unit {
        case "d", "day", "days": return calendar.date(byAdding: .day, value: value, to: now())
        case "w", "wk", "wks", "week", "weeks": return calendar.date(byAdding: .weekOfYear, value: value, to: now())
        case "mo", "month", "months": return calendar.date(byAdding: .month, value: value, to: now())
        case "y", "yr", "yrs", "year", "years": return calendar.date(byAdding: .year, value: value, to: now())
        default: return nil
        }
    }

    private func weekdayDate(_ base: String) -> Date? {
        let parts = base.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let target = Self.weekdays[parts[1]] else { return nil }
        let todayWeekday = calendar.component(.weekday, from: now())
        let forward = (target - todayWeekday + 7) % 7
        let delta: Int
        switch parts[0] {
        case "this": delta = forward
        case "next": delta = forward == 0 ? 7 : forward
        case "last": delta = forward == 0 ? -7 : forward - 7
        default: return nil
        }
        return calendar.date(byAdding: .day, value: delta, to: now())
    }

    // MARK: - Formatting

    private enum Style { case iso, short, medium, long }

    private func dateStyle(for argument: String?) -> Style {
        switch argument {
        case "iso": return .iso
        case "long": return .long
        case "short": return .short
        default: return .medium
        }
    }

    private func formatDate(_ date: Date, style: Style) -> String {
        if style == .iso {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.timeZone = calendar.timeZone
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        }
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.timeStyle = .none
        switch style {
        case .short: fmt.dateStyle = .short
        case .long: fmt.dateStyle = .long
        default: fmt.dateStyle = .medium
        }
        return fmt.string(from: date)
    }

    private func formatTime(_ date: Date, use24Hour: Bool) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = calendar.timeZone
        if use24Hour {
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "HH:mm"
        } else {
            fmt.locale = locale
            fmt.calendar = calendar
            fmt.dateStyle = .none
            fmt.timeStyle = .short
        }
        return fmt.string(from: date)
    }

    private func formatDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // MARK: - Tables

    private static func splitArgument(_ string: String) -> (String, String?) {
        guard let open = string.firstIndex(of: "("), string.hasSuffix(")") else {
            return (string, nil)
        }
        let base = String(string[string.startIndex..<open])
        let argument = String(string[string.index(after: open)..<string.index(before: string.endIndex)])
        return (base, argument.isEmpty ? nil : argument)
    }

    private static let baseAliases: [String: String] = [
        "tdy": "today", "tod": "today", "tody": "today", "2day": "today",
        "tmr": "tomorrow", "tmrw": "tomorrow", "tmw": "tomorrow", "tom": "tomorrow",
        "tomo": "tomorrow", "2moro": "tomorrow", "2mrw": "tomorrow",
        "yest": "yesterday", "yday": "yesterday", "ystdy": "yesterday",
        "rn": "now", "rightnow": "now", "atm": "now",
        "midday": "noon", "noontime": "noon", "midnite": "midnight",
        "dt": "datetime", "yr": "year"
    ]

    private static func canonicalBase(_ base: String) -> String {
        if let alias = baseAliases[base] { return alias }
        for prefix in ["next", "this", "last"] where base.hasPrefix(prefix) && base.count > prefix.count {
            let rest = base.dropFirst(prefix.count).drop { $0 == " " || $0 == "-" || $0 == "_" }
            if !rest.isEmpty { return "\(prefix)-\(rest)" }
        }
        return base
    }

    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7
    ]
}
