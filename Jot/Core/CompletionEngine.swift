import Cocoa
import UserNotifications

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
    private var debounceInterval: TimeInterval { Double(AppSettings.shared.debounceMs) / 1000.0 }

    private var pendingTask: Task<Void, Never>?
    private(set) var currentSuggestion: String?
    private var currentKind: SuggestionKind = .llm
    private var state: CompletionState = .idle
    private var lastElement: AXUIElement?
    private var lastCursorRect: CGRect?

    weak var eventTapManager: EventTapManager?

    var hasSuggestion: Bool { state == .suggestionShown }

    var activeEngineName: String {
        if engine is OllamaEngine { return "Ollama" }
        if #available(macOS 26.0, *), engine is FoundationModelEngine { return "Foundation Models" }
        return "Unknown"
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

        if let bid = accessibilityManager.focusedAppBundleID(),
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

        let (systemPrompt, userMessage) = contextBuilder.build(
            textBefore: textBefore,
            textAfter: textAfter,
            settings: settings,
            personalization: PersonalizationStore.shared,
            clipboard: clipboardMonitor.recentText,
            bundleID: accessibilityManager.focusedAppBundleID(),
            visualContext: visualContext
        )

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

                    let cleaned = self.postProcess(partial, textBefore: textBefore, textAfter: textAfter)
                    guard !cleaned.isEmpty, cleaned != lastCleaned else { continue }
                    lastCleaned = cleaned

                    if !firstShown {
                        // First valid word(s) — show with position
                        let rect = self.accessibilityManager.cursorScreenRect(in: capturedElement)
                            ?? self.lastCursorRect
                        self.showSuggestion(cleaned, kind: .llm, cursorRect: rect, element: capturedElement)
                        StatsTracker.shared.recordLatency(Int(Date().timeIntervalSince(startTime) * 1000))
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

            } catch OllamaError.modelNotFound(let model) {
                self.notifyModelNotFound(model)
                self.state = .idle
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

        // Re-query actual cursor position after insertion — more reliable than
        // estimating pixel width, which diverges when font metrics differ from
        // the target app's rendering (ligatures, kerning, sub-pixel spacing).
        let font = accessibilityManager.fontForElement(element)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let newRect = accessibilityManager.cursorScreenRect(in: element)
        if let rect = newRect ?? lastCursorRect {
            overlay.show(suggestion: rest, at: rect, font: font, color: .placeholderTextColor)
        }

        // Pasteboard-based apps (Chrome, Electron) update AX cursor asynchronously
        // after CMD+V fires. Re-query once the paste has settled.
        let capturedElement = element
        let capturedRest    = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
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

    private func postProcess(_ raw: String, textBefore: String, textAfter: String?) -> String {
        var result = raw

        // Collapse to first line only — never show multi-line ghost text
        if let nl = result.firstIndex(of: "\n") {
            result = String(result[..<nl])
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip wrapping quotes the model sometimes adds
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        // Strip instruction-model preamble artifacts ("Here: X", "Sure, X", etc.)
        let preambles = ["here:", "sure,", "sure:", "certainly,", "certainly:",
                         "of course,", "completion:", "continuing:", "the next words are",
                         "the continuation is", "i'll", "let me"]
        let lower = result.lowercased()
        for p in preambles {
            if lower.hasPrefix(p) {
                result = String(result.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip leading colon/dash that may follow some preambles
                if result.hasPrefix(":") || result.hasPrefix("-") {
                    result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }

        // ── Echo stripping ────────────────────────────────────────────────────
        // 1. Mid-word case: cursor inside a word. Strip any leading chars that
        //    re-emit the partial word the user already typed ("amaz" → "ing").
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        if !endsWithSpace {
            let fragment = textBefore
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .last ?? ""
            if fragment.count >= 2 && result.lowercased().hasPrefix(fragment.lowercased()) {
                result = String(result.dropFirst(fragment.count))
            }
        }

        // 2. Word-by-word suffix-prefix echo: strip words at the start of the
        //    completion that repeat the tail of preceding text.
        //    e.g. preceding="hello world", completion="world is great" → "is great"
        result = stripWordEchoPrefix(result, precedingText: textBefore)

        // 3. Space normalization after echo stripping:
        //    - Mid-word (cursor inside a word): strip any leading space the model added.
        //      "h" + " elp" must become "h" + "elp" → "help", not "h elp".
        //    - Word boundary (cursor after space): strip leading space to prevent double-space.
        //      "Hello " + " world" must become "Hello " + "world".
        //    Both cases → always strip leading spaces here.
        result = String(result.drop(while: { $0 == " " || $0 == "\t" }))

        // 4. Trailing duplication guard: if suggestion duplicates text already
        //    after the cursor, suppress it entirely (mid-text fill-in case).
        if let after = textAfter, !after.isEmpty {
            let foldedResult  = alphanumericFold(result)
            let foldedAfter   = alphanumericFold(String(after.prefix(80)))
            if foldedResult.count >= 4 &&
               (foldedAfter.hasPrefix(foldedResult) || foldedResult.hasPrefix(foldedAfter)) {
                return ""
            }
        }

        // ── Hard word-count cap ───────────────────────────────────────────────
        let maxWords: Int
        switch AppSettings.shared.completionLength {
        case "short": maxWords = 3
        case "long":  maxWords = 8
        default:      maxWords = 5
        }
        let tokens = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if tokens.count > maxWords {
            result = tokens.prefix(maxWords).joined(separator: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : result
    }

    /// Strip any leading words in `suggestion` that repeat the tail of `precedingText`.
    private func stripWordEchoPrefix(_ suggestion: String, precedingText: String) -> String {
        let sWords = suggestion.split(whereSeparator: { $0.isWhitespace })
        guard !sWords.isEmpty else { return suggestion }
        let pWords = precedingText.split(whereSeparator: { $0.isWhitespace })
        guard !pWords.isEmpty else { return suggestion }

        let maxCheck = min(pWords.count, 8)
        var bestOverlap = 0
        for depth in 1...maxCheck {
            let tail = pWords.suffix(depth)
            let head = sWords.prefix(depth)
            guard tail.count == head.count else { continue }
            if zip(tail, head).allSatisfy({ $0.0.caseInsensitiveCompare(String($0.1)) == .orderedSame }) {
                bestOverlap = depth
            }
        }
        guard bestOverlap > 0 else { return suggestion }
        if bestOverlap >= sWords.count { return "" }
        // Use startIndex of the first non-echoed word so we keep it, not skip it.
        // .endIndex pointed past that word — was silently dropping one extra word.
        let from = sWords[bestOverlap].startIndex
        return String(suggestion[from...])
    }

    private func alphanumericFold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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

    private func notifyModelNotFound(_ model: String) {
        let content = UNMutableNotificationContent()
        content.title = "Jot: Model Not Found"
        content.body = "Run: ollama pull \(model)"
        let req = UNNotificationRequest(identifier: "jot.model.notfound", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
