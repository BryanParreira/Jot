import Cocoa
import UserNotifications

enum CompletionState {
    case idle, debouncing, requesting, suggestionShown
}

enum SuggestionKind {
    case llm
    case emoji(triggerText: String)
    case typo(badWord: String)
}

@MainActor
class CompletionEngine: ObservableObject {

    private let accessibilityManager: AccessibilityManager
    private let clipboardMonitor: ClipboardMonitor
    private let contextBuilder = ContextBuilder()
    private let emojiProvider = EmojiProvider()
    private let typoDetector = TypoDetector()
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
        case "short": numPredict = 10
        case "long":  numPredict = 40
        default:      numPredict = 20
        }

        let options = OllamaOptions(
            temperature: 0.12,
            topP: 0.9,
            numPredict: numPredict,
            numCtx: 2048,
            stop: ["\n", "\n\n", "```", " ---", "  "]
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
        }

        PersonalizationStore.shared.recordAccepted(suggestion)
        StatsTracker.shared.recordAccepted(text: suggestion)
        clearSuggestion()
    }

    func acceptNextWord() {
        guard var suggestion = currentSuggestion, let element = lastElement else { return }

        // Emoji / typo — accept all at once
        switch currentKind {
        case .emoji, .typo:
            acceptFull()
            return
        case .llm:
            break
        }

        // Split on first word boundary
        let words = suggestion.components(separatedBy: " ").filter { !$0.isEmpty }
        guard let firstWord = words.first else { acceptFull(); return }

        let toInsert = firstWord + " "
        accessibilityManager.insertText(toInsert, into: element)
        PersonalizationStore.shared.recordAccepted(toInsert)
        StatsTracker.shared.recordAccepted(text: toInsert)

        // Update remaining suggestion
        if let range = suggestion.range(of: toInsert) {
            suggestion.removeSubrange(range)
        } else if let range = suggestion.range(of: firstWord) {
            suggestion.removeSubrange(range)
        }

        let remaining = suggestion.trimmingCharacters(in: .init(charactersIn: " "))
        if remaining.isEmpty {
            clearSuggestion()
        } else {
            currentSuggestion = remaining
            let font = accessibilityManager.fontForElement(element)
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let rect = accessibilityManager.cursorScreenRect(in: element) ?? lastCursorRect
            if let rect = rect {
                overlay.show(suggestion: remaining, at: rect, font: font, color: .placeholderTextColor)
            } else {
                overlay.update(suggestion: remaining)
            }
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

    private func postProcess(_ raw: String, textBefore: String) -> String {
        var result = raw

        // Strip trailing newlines the model emits at stop sequence
        while result.hasSuffix("\n") || result.hasSuffix("\r") {
            result = String(result.dropLast())
        }

        // Strip leading newlines
        while result.hasPrefix("\n") || result.hasPrefix("\r") {
            result = String(result.dropFirst())
        }

        // Strip leading space only when text already ends with whitespace
        let endsWithSpace = textBefore.last.map(\.isWhitespace) ?? false
        if endsWithSpace {
            while result.hasPrefix(" ") { result = String(result.dropFirst()) }
        }

        // Strip wrapping quotes the model sometimes adds
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        // Mid-word dedup: model sometimes echoes the partial word being typed.
        // e.g. user typed "amaz", model emits "amazing things" → strip "amaz" prefix → "ing things"
        if !endsWithSpace {
            let fragment = textBefore
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .last ?? ""
            if fragment.count >= 2 {
                let fLower = fragment.lowercased()
                let rLower = result.lowercased()
                if rLower.hasPrefix(fLower) {
                    result = String(result.dropFirst(fragment.count))
                }
            }
        }

        // Reject obviously bad completions (pure punctuation or empty)
        let stripped = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }
        let firstChar = stripped.unicodeScalars.first.map { CharacterSet.letters.contains($0) } ?? false
        let firstIsDigit = stripped.first?.isNumber ?? false
        if !firstChar && !firstIsDigit && !endsWithSpace { return "" }

        return result
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
