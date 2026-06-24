import Foundation

/// Checks GitHub Releases for a newer version and reports back.
/// Configure `githubRepo` (owner/repo) before first launch.
actor UpdateChecker {

    static let shared = UpdateChecker()

    // ── Change these two values to match your GitHub repo ──
    static let githubRepo = "BryanParreira/Jot"
    static let releasesPage = "https://github.com/\(githubRepo)/releases/latest"
    // ────────────────────────────────────────────────────────

    private var lastCheckDate: Date?
    private let checkIntervalSeconds: TimeInterval = 60 * 60 * 6  // every 6 h

    struct Release {
        let version: String   // e.g. "1.2.0"
        let tagName: String   // e.g. "v1.2.0"
        let htmlURL: String
        let body: String
    }

    /// Check for updates. Returns a `Release` if a newer version is available, else `nil`.
    func checkForUpdates(force: Bool = false) async -> Release? {
        if !force, let last = lastCheckDate,
           Date().timeIntervalSince(last) < checkIntervalSeconds { return nil }

        lastCheckDate = Date()

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let apiURL = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Jot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let tagName = json?["tag_name"] as? String,
                  let htmlURL = json?["html_url"] as? String else { return nil }

            let remoteVersion = tagName.hasPrefix("v")
                ? String(tagName.dropFirst()) : tagName
            let body = json?["body"] as? String ?? ""

            guard isNewer(remoteVersion, than: currentVersion) else { return nil }

            return Release(version: remoteVersion, tagName: tagName, htmlURL: htmlURL, body: body)
        } catch {
            return nil
        }
    }

    // Simple semver compare: split on ".", compare major/minor/patch numerically
    private func isNewer(_ remote: String, than current: String) -> Bool {
        let r = components(remote)
        let c = components(current)
        for i in 0..<3 {
            let rv = r[safe: i] ?? 0, cv = c[safe: i] ?? 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    private func components(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
