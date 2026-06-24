import Cocoa
import ApplicationServices
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    private var menuBarController: MenuBarController?
    private var completionEngine: CompletionEngine?
    private var accessibilityManager: AccessibilityManager?
    private var eventTapManager: EventTapManager?
    private var clipboardMonitor: ClipboardMonitor?
    private var permissionPollTimer: Timer?
    private var ollamaRetryTimer: Timer?
    private var onboardingWindow: OnboardingWindowController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Request notification permission (needed for Ollama/model alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        menuBarController = MenuBarController()
        menuBarController?.setup()

        checkFirstLaunch()
        checkAccessibilityPermission()
        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTapManager?.stop()
        clipboardMonitor?.stop()
        permissionPollTimer?.invalidate()
        ollamaRetryTimer?.invalidate()
    }

    @MainActor
    private func checkFirstLaunch() {
        let hasLaunched = UserDefaults.standard.bool(forKey: SettingsKeys.hasLaunchedBefore)
        if !hasLaunched {
            onboardingWindow = OnboardingWindowController()
            onboardingWindow?.showWindow(nil)
            onboardingWindow?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    func checkAccessibilityPermission() {
        if AXIsProcessTrusted() {
            initializeCore()
        } else {
            menuBarController?.showPermissionWarning()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            startPermissionPolling()
        }
    }

    @MainActor
    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            // Permission just granted — relaunch so TCC changes take full effect
            DispatchQueue.main.async {
                self?.permissionPollTimer?.invalidate()
                self?.relaunch()
            }
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func initializeCore() {
        guard completionEngine == nil else { return }

        accessibilityManager = AccessibilityManager()
        clipboardMonitor = ClipboardMonitor()
        clipboardMonitor?.start()

        completionEngine = CompletionEngine(
            accessibilityManager: accessibilityManager!,
            clipboardMonitor: clipboardMonitor!
        )

        eventTapManager = EventTapManager(completionEngine: completionEngine!)
        completionEngine!.eventTapManager = eventTapManager
        eventTapManager?.start()

        menuBarController?.setCompletionEngine(completionEngine!)

        startOllamaMonitoring()
    }

    @MainActor
    private func scheduleUpdateChecks() {
        // First check: 5s after launch (non-blocking)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await runUpdateCheck()
        }
        // Repeat every 6 hours
        Timer.scheduledTimer(withTimeInterval: 60 * 60 * 6, repeats: true) { [weak self] _ in
            Task { await self?.runUpdateCheck() }
        }
    }

    private func runUpdateCheck() async {
        guard let release = await UpdateChecker.shared.checkForUpdates() else { return }
        await MainActor.run { [weak self] in
            self?.menuBarController?.showUpdateAvailable(version: release.version, url: release.htmlURL)
        }
    }

    private func startOllamaMonitoring() {
        Task {
            let reachable = await OllamaClient.shared.ping()
            if !reachable {
                let content = UNMutableNotificationContent()
                content.title = "Jot: Ollama Not Running"
                content.body = "Start Ollama to enable suggestions. Jot will retry automatically."
                let request = UNNotificationRequest(identifier: "jot.ollama.unreachable", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }

        ollamaRetryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { _ = await OllamaClient.shared.ping() }
        }
    }
}
