import Cocoa

enum CompletionState {
    case idle, debouncing, requesting, suggestionShown
}

enum SuggestionKind {
    case llm
    case emoji(triggerText: String)
    case typo(badWord: String)
    case macro(triggerText: String)
}

@MainActor
class CompletionEngine: ObservableObject {

    private let accessibilityManager: AccessibilityManager
    private let clipboardMonitor: ClipboardMonitor
    private let contextBuilder = ContextBuilder()
    private let emojiProvider = EmojiProvider()
    private let typoDetector = TypoDetector()
    private let macroProvider = MacroProvider()
    private let overlay = SuggestionOverlay.shared
    private let engine: any SuggestionEngine

    // Single reusable debounce timer — cancel/reschedule, never recreate
    private var debounceTimer: Timer?
    private var lastGenerationLatencyMs: Int?
    private var debounceInterval: TimeInterval {
        let ms = DebouncePolicy.milliseconds(
            lastGenerationLatencyMilliseconds: lastGenerationLatencyMs,
            fallback: AppSettings.shared.debounceMs
        )
        return Double(ms) / 1000.0
    }

    private var pendingTask: Task<Void, Never>?
    private(set) var currentSuggestion: String?
    private var currentKind: SuggestionKind = .llm
    private var state: CompletionState = .idle
    private var lastElement: AXUIElement?
    private var lastCursorRect: CGRect?

    weak var eventTapManager: EventTapManager?

    var hasSuggestion: Bool { state == .suggestionShown }

    var activeEngineName: String {
        if engine is LlamaEngine { return "llama.cpp" }
        if #available(macOS 26.0, *), engine is FoundationModelEngine { return "Apple Intelligence" }
        return "Unavailable"
    }

    init(accessibilityManager: AccessibilityManager, clipboardMonitor: ClipboardMonitor) {
        self.accessibilityManager = accessibilityManager
        self.clipboardMonitor = clipboardMonitor
        self.engine = EngineFactory.make()
    }

    // MARK: - Keystroke handling

    func onKeystroke(character: Character?) {
        guard AppSettings.shared.enabled else {
            if hasSuggestion { clearSuggestion() }
            return
        }

        // ── Suggestion tracking ────────────────────────────────────────────────
        // If typed char matches the first char of the current suggestion, advance
        // it in-place — no new LLM call needed. This gives the "keeps up with
        // your thinking" feel (Cotypist-style live tracking).
        if let char = character,
           state == .suggestionShown,
           let current = currentSuggestion,
           !current.isEmpty {
            let charStr = String(char)
            let head    = String(current.prefix(1))
            if charStr.caseInsensitiveCompare(head) == .orderedSame {
                let remaining = String(current.dropFirst())
                if remaining.isEmpty {
                    // Suggestion fully typed — clear and speculate the next phrase
                    clearSuggestion()
                    scheduleDebounce(fast: true)
                } else {
                    currentSuggestion = remaining
                    overlay.update(suggestion: remaining)
                    // Re-query cursor position after keypress lands in the target app
                    let snap = remaining
                    let el   = lastElement
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                        guard let self,
                              self.state == .suggestionShown,
                              self.currentSuggestion == snap,
                              let el,
                              let rect = self.accessibilityManager.cursorScreenRect(in: el)
                        else { return }
                        let font = self.accessibilityManager.fontForElement(el)
                            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                        self.overlay.show(suggestion: snap, at: rect, font: font,
                                          color: .placeholderTextColor)
                    }
                }
                return  // handled — skip normal debounce
            }
        }

        if hasSuggestion { clearSuggestion() }

        // Word-boundary keys get a faster debounce — skip the speedup under power constraints.
        let isBoundary = !isConservingPower
            && (character.map { $0 == " " || $0 == "." || $0 == "," || $0 == "\n" } ?? false)
        scheduleDebounce(fast: isBoundary)
    }

    func onDismissKey() {
        cancelAll()
    }

    private func scheduleDebounce(fast: Bool = false) {
        state = .debouncing
        let interval = fast ? 0.06 : debounceInterval
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.requestCompletion() }
        }
    }

    /// After accepting a suggestion, immediately pre-fetch the next completion.
    /// The cursor has moved, so we wait briefly for the AX element to update.
    /// Skipped under low-power / thermal stress — the user can always trigger manually by typing.
    private func scheduleSpeculativeFetch() {
        guard !isConservingPower else { return }
        state = .debouncing
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.requestCompletion() }
        }
    }

    private var isConservingPower: Bool {
        let proc = ProcessInfo.processInfo
        return proc.isLowPowerModeEnabled
            || proc.thermalState == .serious
            || proc.thermalState == .critical
    }

    // MARK: - Completion request

    private func requestCompletion() async {
        guard AppSettings.shared.enabled else { return }

        guard let element = accessibilityManager.focusedTextElement() else { return }
        guard !accessibilityManager.isPasswordField(element) else { return }

        let bid = accessibilityManager.focusedAppBundleID()

        // Never suggest inside terminal emulators — they have their own completion
        if TerminalAppDetector.isTerminal(bundleIdentifier: bid) { return }

        if let bid,
           AppSettings.shared.blockedBundleIDs.contains(bid) { return }

        guard let textBefore = accessibilityManager.textBeforeCursor(in: element),
              textBefore.count >= 3 else { return }

        lastElement = element
        lastCursorRect = accessibilityManager.cursorScreenRect(in: element)

        // Macros — instant, no network (/date, /time, /now, /uuid, /rand, /year)
        if AppSettings.shared.enableMacros,
           let macro = macroProvider.check(textBefore: textBefore) {
            showSuggestion(macro.suggestion,
                           kind: .macro(triggerText: macro.triggerText),
                           cursorRect: lastCursorRect,
                           element: element)
            return
        }

        // Emoji — instant, no network
        if AppSettings.shared.enableEmoji,
           let emoji = emojiProvider.check(textBefore: textBefore) {
            showSuggestion(emoji.suggestion,
                           kind: .emoji(triggerText: emoji.triggerText),
                           cursorRect: lastCursorRect,
                           element: element)
            return
        }

        // Typo correction — instant, no network
        if AppSettings.shared.enableTypoDetection,
           let typo = typoDetector.check(textBefore: textBefore) {
            showSuggestion(typo.correction,
                           kind: .typo(badWord: typo.badWord),
                           cursorRect: lastCursorRect,
                           element: element)
            return
        }

        let textAfter: String? = AppSettings.shared.enableMidLine
            ? accessibilityManager.textAfterCursor(in: element)
            : nil

        let settings = AppSettings.shared

        let visualContext: String? = settings.screenAwareMode
            ? await VisualContextProvider.shared.context(caretRect: lastCursorRect)
            : nil

        let (systemPrompt, userMessage): (String, String)
        if engine.promptStyle == .baseText {
            (systemPrompt, userMessage) = contextBuilder.buildForBaseModel(
                textBefore: textBefore,
                textAfter: textAfter,
                settings: settings,
                visualContext: visualContext
            )
        } else {
            (systemPrompt, userMessage) = contextBuilder.buildForFoundationModel(
                textBefore: textBefore,
                textAfter: textAfter,
                settings: settings,
                personalization: PersonalizationStore.shared,
                clipboard: clipboardMonitor.recentText,
                bundleID: bid,
                visualContext: visualContext
            )
        }

        let numPredict: Int
        switch settings.completionLength {
        case "short": numPredict = 12   // ~2–3 words
        case "long":  numPredict = 40   // ~5–8 words
        default:      numPredict = 20   // ~3–5 words (default)
        }

        pendingTask?.cancel()
        state = .requesting
        let startTime = Date()
        let capturedElement = element
        let capturedEngine = engine

        pendingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let stream = capturedEngine.streamComplete(
                    systemPrompt: systemPrompt,
                    userMessage: userMessage,
                    maxTokens: numPredict
                )

                var firstShown = false
                var lastCleaned = ""

                for try await partial in stream {
                    guard !Task.isCancelled else { return }
                    // Stop if user dismissed or another request started
                    guard self.state == .requesting
                        || (firstShown && self.state == .suggestionShown) else { return }

                    let cleaned = self.postProcess(partial, textBefore: textBefore, textAfter: textAfter, allowStreaming: !firstShown)
                    guard !cleaned.isEmpty, cleaned != lastCleaned else { continue }
                    lastCleaned = cleaned

                    if !firstShown {
                        // First valid word(s) — show with position
                        let rect = self.accessibilityManager.cursorScreenRect(in: capturedElement)
                            ?? self.lastCursorRect
                        self.showSuggestion(cleaned, kind: .llm, cursorRect: rect, element: capturedElement)
                        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                        StatsTracker.shared.recordLatency(latencyMs)
                        self.lastGenerationLatencyMs = latencyMs
                        firstShown = true
                    } else {
                        // Subsequent stream ticks — update text, keep position
                        self.currentSuggestion = cleaned
                        self.overlay.update(suggestion: cleaned)
                    }
                }

                if !firstShown { self.state = .idle }
                if !lastCleaned.isEmpty {
                    DebugLogger.log("← complete [\(self.activeEngineName)]: \(lastCleaned.prefix(80))")
                }

            } catch {
                if !Task.isCancelled {
                    DebugLogger.log("Completion error: \(error)")
                }
                if self.state == .requesting { self.state = .idle }
            }
        }
    }

    // MARK: - Accept / Dismiss

    func acceptFull() {
        guard let suggestion = currentSuggestion, let element = lastElement else { return }

        switch currentKind {
        case .llm:
            accessibilityManager.insertText(suggestion, into: element)

        case .emoji(let triggerText):
            accessibilityManager.deleteTextBeforeCursor(count: triggerText.count, in: element)
            accessibilityManager.insertText(suggestion, into: element)

        case .typo(let badWord):
            accessibilityManager.deleteTextBeforeCursor(count: badWord.count, in: element)
            accessibilityManager.insertText(suggestion, into: element)

        case .macro(let triggerText):
            accessibilityManager.deleteTextBeforeCursor(count: triggerText.count, in: element)
            accessibilityManager.insertText(suggestion, into: element)
        }

        PersonalizationStore.shared.recordAccepted(suggestion)
        StatsTracker.shared.recordAccepted(text: suggestion)
        clearSuggestion()
        scheduleSpeculativeFetch()
    }

    func acceptNextWord() {
        guard let suggestion = currentSuggestion, let element = lastElement else { return }

        switch currentKind {
        case .emoji, .typo, .macro: acceptFull(); return
        case .llm: break
        }

        // Suggestion never has a leading space (postProcess strips it).
        // Split at first space to get the next word.
        let words = suggestion.components(separatedBy: " ").filter { !$0.isEmpty }
        guard let first = words.first else { acceptFull(); return }

        // Always append a trailing space — completes mid-word fragments too:
        // "h" + "elp " = "help " (cursor lands at word boundary, ready for next word).
        let toInsert = first + " "

        accessibilityManager.insertText(toInsert, into: element)
        PersonalizationStore.shared.recordAccepted(toInsert)
        StatsTracker.shared.recordAccepted(text: toInsert)

        // Build remaining suggestion — drop the accepted word and its trailing space.
        let rest = words.dropFirst().joined(separator: " ")

        if rest.isEmpty {
            clearSuggestion()
            scheduleSpeculativeFetch()  // fetch the next phrase immediately
            return
        }

        currentSuggestion = rest
        // Dismiss immediately — prevents overlap at stale cursor position.
        // AX cursor rect hasn't updated yet synchronously after insertText.
        overlay.dismiss(animated: false)

        let capturedElement = element
        let capturedRest    = rest

        // Native apps (Mail, TextEdit): AX updates within ~30ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self,
                  self.hasSuggestion,
                  self.currentSuggestion == capturedRest,
                  let rect = self.accessibilityManager.cursorScreenRect(in: capturedElement)
            else { return }
            let f = self.accessibilityManager.fontForElement(capturedElement)
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            self.overlay.show(suggestion: capturedRest, at: rect, font: f,
                              color: .placeholderTextColor)
        }

        // Chromium/Electron: pasteboard paste settles later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self,
                  self.hasSuggestion,
                  self.currentSuggestion == capturedRest,
                  let rect = self.accessibilityManager.cursorScreenRect(in: capturedElement)
            else { return }
            let f = self.accessibilityManager.fontForElement(capturedElement)
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            self.overlay.show(suggestion: capturedRest, at: rect, font: f,
                              color: .placeholderTextColor)
        }
    }

    func dismiss() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingTask?.cancel()
        pendingTask = nil
        currentSuggestion = nil
        currentKind = .llm
        state = .idle
        eventTapManager?.hasPendingSuggestion = false
        overlay.dismiss(animated: true)  // user pressed Escape — smooth fade
        VisualContextProvider.shared.invalidateCache()
    }

    // MARK: - Internals

    private func showSuggestion(_ text: String, kind: SuggestionKind, cursorRect: CGRect?, element: AXUIElement) {
        currentSuggestion = text
        currentKind = kind
        state = .suggestionShown
        eventTapManager?.hasPendingSuggestion = true

        let font = accessibilityManager.fontForElement(element)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

        if let rect = cursorRect {
            overlay.show(suggestion: text, at: rect, font: font, color: .placeholderTextColor)
        } else {
            overlay.update(suggestion: text)
        }
    }

    private func postProcess(_ raw: String, textBefore: String, textAfter: String?, allowStreaming: Bool = false) -> String {
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

    private func cancelAll() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingTask?.cancel()
        pendingTask = nil
        clearSuggestion()
    }

    private func clearSuggestion() {
        currentSuggestion = nil
        currentKind = .llm
        state = .idle
        eventTapManager?.hasPendingSuggestion = false
        overlay.dismiss(animated: false)  // instant — typing continues
    }

}
