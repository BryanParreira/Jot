import Foundation

/// Currency conversion macros: `/123.45CAD->USD`, `/100 usd to eur`, `/$100 to eur`.
/// Tokens resolve through an alias table (names, symbols, short forms) plus any
/// 3-letter ISO code. Rates are bundled and offline — never touches the network.
struct CurrencyEvaluator: MacroEvaluating {
    private let locale: Locale
    private let table: CurrencyRateTable

    init(locale: Locale = .current, table: CurrencyRateTable = .bundled) {
        self.locale = locale
        self.table = table
    }

    func evaluate(_ query: String) -> MacroEvalResult? {
        guard let (lhsRaw, rhsRaw) = ConversionSeparator.split(query),
              let (amount, fromToken) = Self.parseAmount(lhsRaw),
              let fromCode = Self.resolveCode(fromToken),
              let toCode = Self.resolveCode(rhsRaw.trimmingCharacters(in: .whitespaces)),
              let fromRate = table.rate(for: fromCode),
              let toRate = table.rate(for: toCode) else {
            return nil
        }
        // Rates are units-per-USD; convert through USD.
        let converted = (amount / fromRate) * toRate
        let formatted = formatCurrency(converted, code: toCode)
        return MacroEvalResult(formatted)
    }

    private static func parseAmount(_ lhs: String) -> (amount: Double, token: String)? {
        let trimmed = lhs.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let first = trimmed.first, aliases[String(first)] != nil {
            guard let amount = Double(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return (amount, String(first))
        }
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let amount = Double(numberPart) else { return nil }
        return (amount, trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces))
    }

    private static func resolveCode(_ token: String) -> String? {
        if let code = aliases[token.lowercased()] { return code }
        let upper = token.uppercased()
        return upper.count == 3 ? upper : nil
    }

    private static let aliases: [String: String] = [
        "us": "USD", "usa": "USD", "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD", "$": "USD",
        "euro": "EUR", "euros": "EUR", "€": "EUR",
        "pound": "GBP", "pounds": "GBP", "quid": "GBP", "sterling": "GBP", "£": "GBP",
        "yen": "JPY", "¥": "JPY",
        "yuan": "CNY", "rmb": "CNY", "renminbi": "CNY",
        "rupee": "INR", "rupees": "INR", "₹": "INR",
        "peso": "MXN", "pesos": "MXN",
        "real": "BRL", "reais": "BRL", "r$": "BRL",
        "rand": "ZAR",
        "won": "KRW", "₩": "KRW",
        "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "₽": "RUB",
        "baht": "THB", "฿": "THB",
        "shekel": "ILS", "shekels": "ILS", "₪": "ILS",
        "forint": "HUF",
        "zloty": "PLN", "zł": "PLN",
        "ringgit": "MYR",
        "rupiah": "IDR",
        "dirham": "AED", "dirhams": "AED",
        "riyal": "SAR", "rial": "SAR",
        "franc": "CHF", "francs": "CHF",
        "₱": "PHP",
        "c$": "CAD", "a$": "AUD", "hk$": "HKD", "nz$": "NZD", "nt$": "TWD", "s$": "SGD"
    ]

    private func formatCurrency(_ value: Double, code: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = code
        fmt.locale = locale
        return fmt.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }
}

// MARK: - CurrencyRateTable

/// Bundled, offline, approximate exchange rates (units per USD).
/// Refreshed with each app update; never reaches the network.
struct CurrencyRateTable {
    let asOf: String
    private let ratesPerUSD: [String: Double]

    init(asOf: String, ratesPerUSD: [String: Double]) {
        self.asOf = asOf
        self.ratesPerUSD = ratesPerUSD
    }

    func rate(for code: String) -> Double? {
        ratesPerUSD[code.uppercased()]
    }

    static let bundled = CurrencyRateTable(
        asOf: "2026-06",
        ratesPerUSD: [
            "USD": 1.0,    "EUR": 0.92,   "GBP": 0.79,   "JPY": 151.0,  "CAD": 1.36,
            "AUD": 1.51,   "CHF": 0.90,   "CNY": 7.24,   "INR": 83.4,   "MXN": 17.1,
            "BRL": 5.05,   "ZAR": 18.6,   "KRW": 1360.0, "SGD": 1.35,   "HKD": 7.82,
            "NZD": 1.63,   "SEK": 10.5,   "NOK": 10.7,   "DKK": 6.87,   "PLN": 3.95,
            "TRY": 32.1,   "RUB": 90.0,   "AED": 3.67,   "SAR": 3.75,   "THB": 36.5,
            "IDR": 15800.0,"MYR": 4.70,   "PHP": 56.5,   "CZK": 23.2,   "HUF": 360.0,
            "ILS": 3.70,   "TWD": 32.3
        ]
    )
}
