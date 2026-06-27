import Foundation

/// Identifies terminal emulator apps by bundle identifier.
///
/// Terminals have their own completion, history, and shell integrations that
/// conflict with ghost-text autocomplete. Jot stays out automatically.
nonisolated enum TerminalAppDetector {
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.rio.terminal",
        "com.nuebling.tabbyml",
        "org.tabletki.tabletki"
    ]

    static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Whether a focused web element's AXDOMClassList marks it as an xterm.js terminal.
    ///
    /// VS Code, Cursor, and browser-hosted terminals all render through xterm.js.
    /// The bundle-level blocklist can't distinguish the integrated terminal from the
    /// editor in the same process; this catches it at the element level instead.
    static func isIntegratedTerminal(domClassList: [String]) -> Bool {
        domClassList.contains { $0.hasPrefix("xterm") }
    }
}
