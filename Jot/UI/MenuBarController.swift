import Cocoa

class MenuBarController {
    private var statusItem: NSStatusItem?
    private weak var coordinator: CompletionCoordinator?
    private var settingsWindow: SettingsWindowController?
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

    func setCoordinator(_ coordinator: CompletionCoordinator) {
        self.coordinator = coordinator
        buildMenu()
    }

    func showUpdateAvailable(version: String, url: String) {
        pendingUpdate = (version, url)
        buildMenu()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        // Update banner
        if let update = pendingUpdate {
            let item = NSMenuItem(
                title: "⬆️  Jot \(update.version) available — click to update",
                action: #selector(openUpdatePage), keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Permission warning
        if needsAccessibility {
            let warn = NSMenuItem(title: "⚠️  Accessibility access required",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            let sub = NSMenuItem(title: "   → Open System Settings and enable Jot",
                                 action: #selector(openAccessibilitySettings), keyEquivalent: "")
            sub.target = self
            menu.addItem(sub)
            let note = NSMenuItem(title: "   Jot restarts automatically once granted",
                                  action: nil, keyEquivalent: "")
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

        // Model name
        let modelName = AppSettings.shared.llamaModelName
        let modelTitle = modelName.isEmpty ? "Model: not set" : "Model: \(modelName)"
        let modelItem = NSMenuItem(title: modelTitle, action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        menu.addItem(.separator())

        // Stats
        let statsItem = NSMenuItem(title: "Suggestions today: \(StatsTracker.shared.totalAcceptedToday)",
                                   action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        let wordsItem = NSMenuItem(title: "Words saved today: ~\(StatsTracker.shared.totalWordsSavedToday)",
                                   action: nil, keyEquivalent: "")
        wordsItem.isEnabled = false
        menu.addItem(wordsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Open Settings...", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates),
                                    keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Jot",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Permission banners

    func showPermissionWarning() {
        needsAccessibility = true
        statusItem?.button?.toolTip = "Jot: Accessibility access needed — click to fix"
        buildMenu()
    }

    func showInputMonitoringWarning() {
        needsAccessibility = true
        statusItem?.button?.toolTip = "Jot: Input Monitoring access needed — click to fix"
        buildMenu()
    }

    func showScreenRecordingWarning() {
        statusItem?.button?.toolTip = "Jot: Screen Recording needed for visual context (optional)"
    }

    func clearPermissionWarning() {
        needsAccessibility = false
        statusItem?.button?.toolTip = "Jot — AI text suggestions"
        buildMenu()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        AppSettings.shared.enabled.toggle()
        if !AppSettings.shared.enabled {
            Task { @MainActor in self.coordinator?.cancelAll() }
        }
        buildMenu()
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openUpdatePage() {
        guard let urlStr = pendingUpdate?.url, let url = URL(string: urlStr) else { return }
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

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Icon

    private func applyStatusBarIcon(to button: NSStatusBarButton) {
        if let image = NSImage(named: "StatusBarIcon") {
            image.isTemplate = true
            button.image = image
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            let img = NSImage(systemSymbolName: "character.cursor", accessibilityDescription: "Jot")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
        }
    }
}
