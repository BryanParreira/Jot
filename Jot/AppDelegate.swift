import Cocoa
import ApplicationServices
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    private var menuBarController: MenuBarController?
    private var coordinator: CompletionCoordinator?
    private var onboardingWindow: OnboardingWindowController?
    private var permissionPollTimer: Timer?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        menuBarController = MenuBarController()
        menuBarController?.setup()

        checkFirstLaunch()
        checkAccessibilityPermission()
        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        permissionPollTimer?.invalidate()
    }

    // MARK: - First launch

    @MainActor
    private func checkFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: SettingsKeys.hasLaunchedBefore) else { return }
        onboardingWindow = OnboardingWindowController()
        onboardingWindow?.showWindow(nil)
        onboardingWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permission flow

    @MainActor
    func checkAccessibilityPermission() {
        if AXIsProcessTrusted() {
            checkInputMonitoringPermission()
        } else {
            menuBarController?.showPermissionWarning()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            startPermissionPolling()
        }
    }

    @MainActor
    private func checkInputMonitoringPermission() {
        if CGPreflightListenEventAccess() {
            initializeCore()
        } else {
            menuBarController?.showInputMonitoringWarning()
            CGRequestListenEventAccess()
            startInputMonitoringPolling()
        }
    }

    @MainActor
    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            DispatchQueue.main.async { self?.permissionPollTimer?.invalidate(); self?.relaunch() }
        }
    }

    @MainActor
    private func startInputMonitoringPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard CGPreflightListenEventAccess() else { return }
            DispatchQueue.main.async { self?.permissionPollTimer?.invalidate(); self?.relaunch() }
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    // MARK: - Core init

    @MainActor
    private func initializeCore() {
        guard coordinator == nil else { return }

        let c = CompletionCoordinator()
        coordinator = c
        c.start()

        menuBarController?.setCoordinator(c)

        // Dismiss and reset on app switch
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator?.cancelAll() }
        }
    }

    // MARK: - Update checks

    @MainActor
    private func scheduleUpdateChecks() {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await runUpdateCheck()
        }
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
}

// MARK: - CompletionCoordinator

/// Wires TextWatcher + LlamaClient + OverlayController + KeyInterceptor + TextInjector + PromptBuilder.
/// Owns the state machine: idle → debouncing → inferring → shown.
@MainActor
final class CompletionCoordinator: TextWatcherDelegate, KeyInterceptorDelegate {

    let watcher:     TextWatcher
    let client:      LlamaClient
    let overlay:     OverlayController
    let interceptor: KeyInterceptor
    let injector:    TextInjector
    let builder:     PromptBuilder

    private var debounceTimer: Timer?
    private var inferenceTask: Task<Void, Never>?

    private(set) var currentSuggestion: String?
    private var currentElement:    AXUIElement?
    private var currentCursorRect: CGRect?

    var isShown: Bool { currentSuggestion != nil }

    var engineName: String { client.currentModelName }

    init() {
        watcher     = TextWatcher()
        client      = LlamaClient()
        overlay     = .shared
        interceptor = KeyInterceptor()
        injector    = TextInjector()
        builder     = PromptBuilder()

        watcher.delegate     = self
        interceptor.delegate = self
    }

    func start() {
        watcher.start()
        interceptor.start()
    }

    func stop() {
        watcher.stop()
        interceptor.stop()
        cancelAll()
    }

    // MARK: - TextWatcherDelegate

    /// Sole entry point for prediction scheduling. TextWatcher is the single source of truth
    /// for "what text is in the field right now." No other path schedules predictions so there
    /// is exactly one debounce timer and no double-request races.
    func textWatcher(_ watcher: TextWatcher, didUpdate context: TextContext) {
        guard AppSettings.shared.enabled else { if isShown { clearSuggestion() }; return }

        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bid, AppSettings.shared.blockedBundleIDs.contains(bid) {
            if isShown { clearSuggestion() }
            return
        }
        if TerminalAppDetector.isTerminal(bundleIdentifier: bid) { return }

        currentElement    = context.element
        currentCursorRect = context.cursorRect

        DebugLogger.log("[TW] text changed → debounce \(Int(debounceInterval * 1000))ms chars=\(context.textBeforeCursor.count)")

        debounceTimer?.invalidate()
        // Capture context now — TextWatcher keeps resetting the timer on each change,
        // so when this fires, `context` is always from the most recent poll.
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { _ in
            Task { @MainActor [weak self] in
                await self?.requestCompletion(context: context)
            }
        }
    }

    func textWatcherDidLoseContext(_ watcher: TextWatcher) {
        DebugLogger.log("[TW] lost context — cancelling all")
        cancelAll()
    }

    // MARK: - KeyInterceptorDelegate
    // Key events ONLY manage overlay state — never schedule predictions.
    // TextWatcher detects the resulting text change within one poll interval (~80ms)
    // and drives the prediction via textWatcher(_:didUpdate:).

    func keyInterceptorDidTypeCharacter(_ char: Character?) {
        guard AppSettings.shared.enabled else { return }
        guard isShown, let char, let current = currentSuggestion, !current.isEmpty,
              let element = currentElement else {
            // No suggestion showing — nothing to advance or dismiss
            if isShown { clearSuggestion() }
            return
        }

        let charStr = String(char)
        let head    = String(current.prefix(1))
        if charStr.caseInsensitiveCompare(head) == .orderedSame {
            // User typed the next character of the suggestion — advance in-place
            let remaining = String(current.dropFirst())
            if remaining.isEmpty {
                clearSuggestion()
                // TextWatcher will schedule the next prediction after detecting the text change
            } else {
                currentSuggestion = remaining
                overlay.update(suggestion: remaining)
                repositionOverlay(element: element, remaining: remaining)
            }
        } else {
            // Typed something that breaks the suggestion — dismiss
            clearSuggestion()
        }
    }

    func keyInterceptorDidPressDismissKey() { cancelAll() }
    func keyInterceptorDidPressTab()        { acceptNextWord() }
    func keyInterceptorDidPressShiftTab()   { acceptFull() }
    func keyInterceptorDidPressEscape()     { dismiss() }
    func keyInterceptorDidPressBacktick()   { acceptFull() }

    // MARK: - Accept

    func acceptFull() {
        guard let suggestion = currentSuggestion, let element = currentElement else { return }
        DebugLogger.log("[Accept] full: \(suggestion.prefix(40))")
        injector.insertText(suggestion, into: element)
        StatsTracker.shared.recordAccepted(text: suggestion)
        clearSuggestion()
        // TextWatcher detects the inserted text and schedules the next prediction automatically
    }

    func acceptNextWord() {
        guard let suggestion = currentSuggestion, let element = currentElement else { return }

        let words = suggestion.components(separatedBy: " ").filter { !$0.isEmpty }
        guard let first = words.first else { acceptFull(); return }

        let toInsert = first + " "
        DebugLogger.log("[Accept] word: \"\(toInsert.trimmingCharacters(in: .whitespaces))\"")
        injector.insertText(toInsert, into: element)
        StatsTracker.shared.recordAccepted(text: toInsert)

        let rest = words.dropFirst().joined(separator: " ")
        if rest.isEmpty {
            clearSuggestion()
            return
        }

        currentSuggestion = rest
        overlay.dismiss(animated: false)

        let capturedElement = element
        let capturedRest    = rest

        // Reposition overlay after AX updates (native ~30ms, Chromium/Electron ~150ms)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, self.currentSuggestion == capturedRest,
                  let rect = self.watcher.cursorScreenRect(in: capturedElement) else { return }
            let font = self.watcher.fontForElement(capturedElement) ?? .systemFont(ofSize: NSFont.systemFontSize)
            self.overlay.show(suggestion: capturedRest, at: rect, font: font)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, self.currentSuggestion == capturedRest,
                  let rect = self.watcher.cursorScreenRect(in: capturedElement) else { return }
            let font = self.watcher.fontForElement(capturedElement) ?? .systemFont(ofSize: NSFont.systemFontSize)
            self.overlay.show(suggestion: capturedRest, at: rect, font: font)
        }
    }

    func dismiss() {
        cancelAll()
        VisualContextProvider.shared.invalidateCache()
    }

    // MARK: - Debounce

    private var debounceInterval: TimeInterval {
        TimeInterval(AppSettings.shared.debounceMs) / 1000.0
    }

    // MARK: - Inference

    private func requestCompletion(context: TextContext) async {
        guard AppSettings.shared.enabled else { return }
        guard !watcher.isPasswordField(context.element) else { return }

        let modelPath = AppSettings.shared.llamaModelPath
        guard !modelPath.isEmpty else {
            DebugLogger.log("[RC] no model selected — pick a GGUF in Settings")
            return
        }

        currentElement    = context.element
        currentCursorRect = context.cursorRect

        let textBefore = context.textBeforeCursor
        let textAfter  = AppSettings.shared.enableMidLine
            ? watcher.textAfterCursor(in: context.element)
            : nil
        let bid        = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let prompt     = builder.build(textBefore: textBefore, textAfter: textAfter, bundleID: bid)

        DebugLogger.log("[RC] start inference — chars=\(textBefore.count) app=\(bid ?? "?")")

        inferenceTask?.cancel()
        let capturedElement    = context.element
        let capturedCursorRect = context.cursorRect
        let startTime          = Date()

        inferenceTask = Task {
            do {
                let stream = self.client.streamComplete(
                    prompt: prompt,
                    maxTokens: AppSettings.shared.numPredictTokens
                )

                var firstShown  = false
                var lastCleaned = ""

                for try await partial in stream {
                    guard !Task.isCancelled else { return }

                    let cleaned = self.postProcess(partial, textBefore: textBefore, textAfter: textAfter)
                    guard !cleaned.isEmpty, cleaned != lastCleaned else { continue }
                    lastCleaned = cleaned

                    if !firstShown {
                        let rect = self.watcher.cursorScreenRect(in: capturedElement) ?? capturedCursorRect
                        self.showSuggestion(cleaned, cursorRect: rect, element: capturedElement)
                        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                        StatsTracker.shared.recordLatency(ms)
                        DebugLogger.log("← first token [\(ms)ms]: \(cleaned.prefix(60))")
                        firstShown = true
                    } else {
                        self.currentSuggestion = cleaned
                        self.overlay.update(suggestion: cleaned)
                    }
                }

                if !firstShown {
                    DebugLogger.log("[RC] stream ended — post-processor filtered all tokens")
                    self.clearSuggestion()
                }

            } catch {
                if !Task.isCancelled { DebugLogger.log("[RC] inference error: \(error)") }
                self.clearSuggestion()
            }
        }
    }

    // MARK: - Overlay management

    private func showSuggestion(_ text: String, cursorRect: CGRect?, element: AXUIElement) {
        currentSuggestion = text
        interceptor.hasPendingSuggestion = true

        let font = watcher.fontForElement(element) ?? .systemFont(ofSize: NSFont.systemFontSize)
        // Try the rect from inference start → last known rect from TextWatcher → fresh AX read.
        // overlay.update() is a no-op when the panel isn't visible yet, so we must always have a
        // position before the first show() call.
        let rect = cursorRect
            ?? currentCursorRect
            ?? watcher.cursorScreenRect(in: element)
        if let rect {
            overlay.show(suggestion: text, at: rect, font: font)
        }
        // If rect is still nil, suggestion is cached in currentSuggestion. The next TextWatcher
        // poll fires within 30ms and will retry repositionOverlay if cursor becomes readable.
    }

    private func repositionOverlay(element: AXUIElement, remaining: String) {
        let snap = remaining
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, self.currentSuggestion == snap,
                  let rect = self.watcher.cursorScreenRect(in: element) else { return }
            let font = self.watcher.fontForElement(element) ?? .systemFont(ofSize: NSFont.systemFontSize)
            self.overlay.show(suggestion: snap, at: rect, font: font)
        }
    }

    private func clearSuggestion() {
        currentSuggestion = nil
        interceptor.hasPendingSuggestion = false
        overlay.dismiss(animated: false)
    }

    func cancelAll() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        clearSuggestion()
    }

    // MARK: - Post-processing

    private func postProcess(_ raw: String, textBefore: String, textAfter: String?) -> String {
        let maxWords: Int
        switch AppSettings.shared.completionLength {
        case "short": maxWords = 3
        case "long":  maxWords = 8
        default:      maxWords = 5
        }
        return CompletionPostProcessor.process(
            raw: raw,
            textBefore: textBefore,
            textAfter: textAfter,
            maxWords: maxWords
        )
    }
}
