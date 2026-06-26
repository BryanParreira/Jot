import Cocoa

class MenuBarController {
    private var statusItem: NSStatusItem?
    private weak var completionEngine: CompletionEngine?
    private var settingsWindow: SettingsWindowController?
    private var ollamaStatusItem: NSMenuItem?
    private var needsAccessibility: Bool = false
    private var pendingUpdate: (version: String, url: String)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            applyStatusBarIcon(to: button)
            button.toolTip = "Jot — AI text suggestions"
        }

        buildMenu()
    }

    func setCompletionEngine(_ engine: CompletionEngine) {
        self.completionEngine = engine
        buildMenu()
    }

    func showUpdateAvailable(version: String, url: String) {
        pendingUpdate = (version, url)
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Update available banner
        if let update = pendingUpdate {
            let item = NSMenuItem(title: "⬆️  Jot \(update.version) available — click to update",
                                  action: #selector(openUpdatePage), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Permission warning banner — shown until Accessibility is granted
        if needsAccessibility {
            let warn = NSMenuItem(title: "⚠️  Accessibility access required", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            let sub = NSMenuItem(title: "   → Open System Settings and enable Jot", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            sub.target = self
            menu.addItem(sub)
            let note = NSMenuItem(title: "   Jot restarts automatically once granted", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }

        let titleItem = NSMenuItem(title: "Jot", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: AppSettings.shared.enabled ? "Pause Jot" : "Enable Jot",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = !needsAccessibility
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let statsToday = StatsTracker.shared.totalAcceptedToday
        let wordsToday = StatsTracker.shared.totalWordsSavedToday
        let statsItem = NSMenuItem(title: "Suggestions today: \(statsToday)", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        let wordsItem = NSMenuItem(title: "Words saved today: ~\(wordsToday)", action: nil, keyEquivalent: "")
        wordsItem.isEnabled = false
        menu.addItem(wordsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Open Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let ollamaItem = NSMenuItem(title: "Check Ollama Connection", action: #selector(checkOllama), keyEquivalent: "")
        ollamaItem.target = self
        menu.addItem(ollamaItem)
        ollamaStatusItem = ollamaItem

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    func showPermissionWarning() {
        needsAccessibility = true
        if let button = statusItem?.button {
            applyStatusBarIcon(to: button)
            button.toolTip = "Jot: Accessibility access needed — click to fix"
        }
        buildMenu()
    }

    func showInputMonitoringWarning() {
        needsAccessibility = true  // re-use banner for both permission types
        if let button = statusItem?.button {
            applyStatusBarIcon(to: button)
            button.toolTip = "Jot: Input Monitoring access needed — click to fix"
        }
        buildMenu()
    }

    func showScreenRecordingWarning() {
        // Non-blocking: app runs fine without it; just note the setting won't work
        if let button = statusItem?.button {
            button.toolTip = "Jot: Screen Recording access needed for visual context (optional)"
        }
    }

    func clearPermissionWarning() {
        needsAccessibility = false
        if let button = statusItem?.button {
            applyStatusBarIcon(to: button)
            button.toolTip = "Jot — AI text suggestions"
        }
        buildMenu()
    }

    private func applyStatusBarIcon(to button: NSStatusBarButton, badge: String? = nil) {
        if let image = NSImage(named: "StatusBarIcon") {
            image.isTemplate = true
            button.image = image
            button.title = badge ?? ""
            button.imagePosition = badge == nil ? .imageOnly : .imageLeft
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            let img = NSImage(systemSymbolName: "character.cursor", accessibilityDescription: "Jot")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
            button.title = badge ?? ""
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleEnabled() {
        AppSettings.shared.enabled.toggle()
        if !AppSettings.shared.enabled {
            Task { @MainActor in self.completionEngine?.dismiss() }
        }
        buildMenu()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openUpdatePage() {
        guard let urlStr = pendingUpdate?.url,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        Task {
            let release = await UpdateChecker.shared.checkForUpdates(force: true)
            await MainActor.run {
                if let r = release {
                    self.showUpdateAvailable(version: r.version, url: r.htmlURL)
                    let alert = NSAlert()
                    alert.messageText = "Jot \(r.version) is available"
                    alert.informativeText = r.body.isEmpty
                        ? "A new version is ready to download."
                        : String(r.body.prefix(300))
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn,
                       let url = URL(string: r.htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Jot is up to date"
                    alert.informativeText = "You're running the latest version."
                    alert.runModal()
                }
            }
        }
    }

    @objc private func checkOllama() {
        ollamaStatusItem?.title = "Checking Ollama..."
        Task {
            let ok = await OllamaClient.shared.ping()
            await MainActor.run {
                let models = AppSettings.shared.model
                self.ollamaStatusItem?.title = ok
                    ? "Ollama ✅  \(models)"
                    : "Ollama ❌  Not running"
            }
        }
    }
}
