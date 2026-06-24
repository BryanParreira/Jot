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

    init(accessibilityManager: AccessibilityManager, clipboardMonitor: ClipboardMonitor) {
        self.accessibilityManager = accessibilityManager
        self.clipboardMonitor = clipboardMonitor
    }

    // MARK: - Keystroke handling

    func onKeystroke(character: Character?) {
        guard AppSettings.shared.enabled else {
            if hasSuggestion { clearSuggestion() }
            return
        }
        if hasSuggestion { clearSuggestion() }
        scheduleDebounce()
    }

    func onDismissKey() {
        cancelAll()
    }

    private func scheduleDebounce() {
        state = .debouncing
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.requestCompletion() }
        }
    }

    // MARK: - Completion request

    private func requestCompletion() async {
        guard AppSettings.shared.enabled else { return }

        guard let element = accessibilityManager.focusedTextElement() else { return }
        guard !accessibilityManager.isPasswordField(element) else { return }

        if let bid = accessibilityManager.focusedAppBundleID(),
           AppSettings.shared.blockedBundleIDs.contains(bid) { return }

        guard let textBefore = accessibilityManager.textBeforeCursor(in: element),
              textBefore.count >= 5 else { return }

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
        let (systemPrompt, userMessage) = contextBuilder.build(
            textBefore: textBefore,
            textAfter: textAfter,
            settings: settings,
            personalization: PersonalizationStore.shared,
            clipboard: clipboardMonitor.recentText,
            bundleID: accessibilityManager.focusedAppBundleID()
        )

        let numPredict: Int
        switch settings.completionLength {
        case "short": numPredict = 5   // ~1–2 words
        case "long":  numPredict = 16  // ~4–6 words
        default:      numPredict = 8   // ~2–3 words (default)
        }

        let options = OllamaOptions(
            temperature: 0.10,
            topP: 0.85,
            numPredict: numPredict,
            numCtx: 2048,
            stop: ["\n", "\n\n", "```", "  "]
        )

        pendingTask?.cancel()
        state = .requesting
        let startTime = Date()
        let capturedElement = element

        pendingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let stream = await OllamaClient.shared.generateStream(
                    model: settings.model,
                    systemPrompt: systemPrompt,
                    userMessage: userMessage,
                    options: options
                )

                // Collect full stream before showing — eliminates mid-stream flicker / word glitches
                var accumulated = ""
                for try await partial in stream {
                    guard !Task.isCancelled, self.state == .requesting else { return }
                    accumulated = partial  // partial is always the full accumulated text
                }

                guard !Task.isCancelled, self.state == .requesting else { return }
                guard !accumulated.isEmpty else { self.state = .idle; return }

                let cleaned = self.postProcess(accumulated, textBefore: textBefore, textAfter: textAfter)
                guard !cleaned.isEmpty else { self.state = .idle; return }

                let rect = self.accessibilityManager.cursorScreenRect(in: capturedElement)
                    ?? self.lastCursorRect
                self.showSuggestion(cleaned, kind: .llm, cursorRect: rect, element: capturedElement)
                StatsTracker.shared.recordLatency(Int(Date().timeIntervalSince(startTime) * 1000))
                DebugLogger.log("← complete: \(cleaned.prefix(80))")

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
        case "short": maxWords = 2
        case "long":  maxWords = 6
        default:      maxWords = 3  // 2-3 words for medium
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
