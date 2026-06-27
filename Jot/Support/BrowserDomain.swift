import Foundation

/// Pure helpers for parsing a browser tab's URL into a host and checking
/// whether that host is on a per-domain disable list.
enum BrowserDomain {
    /// Extracts the lowercased host, dropping a leading "www." for comparison.
    /// Returns nil for non-network URLs (file://, about:, data:).
    static func host(fromURLString urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        return stripLeadingWWW(host.lowercased())
    }

    /// Whether `host` is covered by `disabledDomains`. Supports exact match and
    /// subdomain match ("mail.bank.com" matches "bank.com").
    static func isHostDisabled(_ host: String?, disabledDomains: Set<String>) -> Bool {
        guard let host, !host.isEmpty, !disabledDomains.isEmpty else {
            return false
        }
        for entry in disabledDomains {
            guard let domain = normalize(entry) else { continue }
            if host == domain || host.hasSuffix("." + domain) {
                return true
            }
        }
        return false
    }

    private static func normalize(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = host(fromURLString: trimmed) { return parsed }
        return stripLeadingWWW(trimmed.lowercased())
    }

    private static func stripLeadingWWW(_ host: String) -> String {
        guard host.hasPrefix("www."), host.count > 4 else { return host }
        return String(host.dropFirst(4))
    }
}
