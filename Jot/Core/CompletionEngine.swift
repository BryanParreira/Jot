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

        // Cotypist uses 2–4 word target for Medium — fewer tokens = faster first token = snappier UX
        let numPredict: Int
        switch settings.completionLength {
        case "short": numPredict = 6   // ~1–2 words
        case "long":  numPredict = 20  // ~6–8 words
        default:      numPredict = 10  // ~2–4 words (Cotypist Medium)
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

                for try await partial in stream {
                    guard !Task.isCancelled else { return }

                    let cleaned = self.postProcess(partial, textBefore: textBefore)
                    guard !cleaned.isEmpty else { continue }

                    if self.state == .requesting {
                        // First useful token — show overlay
                        let rect = self.accessibilityManager.cursorScreenRect(in: capturedElement)
                            ?? self.lastCursorRect
                        self.showSuggestion(cleaned, kind: .llm, cursorRect: rect, element: capturedElement)
                        StatsTracker.shared.recordLatency(Int(Date().timeIntervalSince(startTime) * 1000))
                    } else if self.state == .suggestionShown {
                        // Stream update — grow the suggestion in-place
                        self.currentSuggestion = cleaned
                        self.overlay.update(suggestion: cleaned)
                    } else {
                        return
                    }
                }

                // Stream finished — record final suggestion for stats
                if let final = self.currentSuggestion, self.state == .suggestionShown {
                    DebugLogger.log("← complete: \(final.prefix(80))")
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
    }

    func acceptNextWord() {
        guard let suggestion = currentSuggestion, let element = lastElement else { return }

        switch currentKind {
        case .emoji, .typo, .macro: acceptFull(); return
        case .llm: break
        }

        // Split at first space boundary
        let trimmed = suggestion.hasPrefix(" ") ? String(suggestion.dropFirst()) : suggestion
        let words   = trimmed.components(separatedBy: " ")
        guard let first = words.first, !first.isEmpty else { acceptFull(); return }

        // Preserve leading space if present (e.g. " world" after "Hello")
        let leadingSpace = suggestion.hasPrefix(" ") ? " " : ""
        let toInsert = leadingSpace + first + " "

        accessibilityManager.insertText(toInsert, into: element)
        PersonalizationStore.shared.recordAccepted(toInsert)
        StatsTracker.shared.recordAccepted(text: toInsert)

        // Build remaining suggestion
        var rest = suggestion
        if let r = rest.range(of: toInsert) { rest.removeSubrange(r) }
        else if let r = rest.range(of: first) { rest.removeSubrange(r) }
        rest = rest.trimmingCharacters(in: .init(charactersIn: " "))

        if rest.isEmpty {
            clearSuggestion()
            return
        }

        // Single atomic render: shift overlay right + update remaining text (no flicker)
        let font = accessibilityManager.fontForElement(element)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrs = [NSAttributedString.Key.font: font]
        let acceptedWidth = (toInsert as NSString).size(withAttributes: attrs).width
        currentSuggestion = rest
        overlay.advanceAfterAccepting(remaining: rest, acceptedWidth: acceptedWidth)
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

    private func postProcess(_ raw: String, textBefore: String) -> String {
        var result = raw

        // Strip surrounding newlines
        while result.hasSuffix("\n") || result.hasSuffix("\r") { result = String(result.dropLast()) }
        while result.hasPrefix("\n") || result.hasPrefix("\r") { result = String(result.dropFirst()) }

        // Strip wrapping quotes
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        // Mid-word dedup: model echoed the fragment already typed.
        // e.g. user typed "amaz", model emits "amazing" → show only "ing"
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        if !endsWithSpace {
            let fragment = textBefore
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .last ?? ""
            if fragment.count >= 2 && result.lowercased().hasPrefix(fragment.lowercased()) {
                result = String(result.dropFirst(fragment.count))
            }
        }

        // Reject empty result only
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : result
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
