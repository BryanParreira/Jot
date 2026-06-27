import Foundation

/// Classifies apps by browser family from their bundle identifier.
///
/// `isBrowser` is the broad "typing in a web browser" check used for prompt
/// tone hints. `needsWebAccessibilityPriming` is the narrower Chromium/Electron
/// check that gates expensive AX recovery paths — Safari/Firefox are excluded
/// because WebKit builds its tree without a priming flag.
nonisolated enum BrowserAppDetector {
    private static let browserBundlePrefixes: [String] = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.google.chrome",
        "org.mozilla.firefox",
        "company.thebrowser.browser",  // Arc
        "com.brave.browser",
        "com.microsoft.edgemac"
    ]

    private static let chromiumBundlePrefixes: [String] = [
        "com.google.chrome",
        "company.thebrowser.browser",  // Arc
        "com.brave.browser",
        "com.microsoft.edgemac"
    ]

    // Named Electron editors that benefit from web-AX priming. Intentionally an
    // allowlist, not a blanket Electron match, to limit unexpected AX side effects.
    private static let electronEditorBundleIdentifiers: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.vscodium",
        "com.clickup.desktop-app"
    ]

    static func isBrowser(bundleIdentifier: String?) -> Bool {
        hasMatchingPrefix(bundleIdentifier, in: browserBundlePrefixes)
    }

    static func isChromiumBrowser(bundleIdentifier: String?) -> Bool {
        hasMatchingPrefix(bundleIdentifier, in: chromiumBundlePrefixes)
    }

    static func isElectronEditor(bundleIdentifier: String?) -> Bool {
        guard let lowered = bundleIdentifier?.lowercased() else { return false }
        return electronEditorBundleIdentifiers.contains(lowered)
    }

    static func needsWebAccessibilityPriming(bundleIdentifier: String?) -> Bool {
        isChromiumBrowser(bundleIdentifier: bundleIdentifier)
            || isElectronEditor(bundleIdentifier: bundleIdentifier)
    }

    private static func hasMatchingPrefix(_ bundleIdentifier: String?, in prefixes: [String]) -> Bool {
        guard let lower = bundleIdentifier?.lowercased() else { return false }
        return prefixes.contains { lower.hasPrefix($0) }
    }
}
