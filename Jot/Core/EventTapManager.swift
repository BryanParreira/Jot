import Cocoa
import Carbon

class EventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var completionEngine: CompletionEngine?

    // Written from main thread, read from event tap thread.
    // Worst-case: one stale read — acceptable for UX.
    var hasPendingSuggestion: Bool = false

    private static var sharedInstance: EventTapManager?

    init(completionEngine: CompletionEngine) {
        self.completionEngine = completionEngine
        EventTapManager.sharedInstance = self
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, _ in
                EventTapManager.sharedInstance?.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: nil
        ) else {
            DebugLogger.log("Failed to create event tap — check Accessibility permission")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.log("Event tap started")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handler (NOT on main thread)

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it (security timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Ignore our own synthesized keystrokes (⌘V paste, simulateTyping, etc.)
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData {
            return Unmanaged.passRetained(event)
        }

        let keyCode   = event.getIntegerValueField(.keyboardEventKeycode)
        let flags     = event.flags
        let hasSuggestion = hasPendingSuggestion

        let hasCmd   = flags.contains(.maskCommand)
        let hasCtrl  = flags.contains(.maskControl)
        let hasShift = flags.contains(.maskShift)

        // ── Tab ────────────────────────────────────────────────────────────────
        // Tab = accept next word (less aggressive, matches KeyType / Cotypist)
        // Shift+Tab = accept full suggestion
        if keyCode == 48 {
            guard hasSuggestion else { return Unmanaged.passRetained(event) }
            if hasShift {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.acceptFull() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.acceptNextWord() }
            }
            return nil  // consume — do not pass Tab to the app
        }

        // ── Backtick ───────────────────────────────────────────────────────────
        // Backtick = accept full suggestion (matches cotabby UX)
        if keyCode == 50 {
            guard hasSuggestion else { return Unmanaged.passRetained(event) }
            DispatchQueue.main.async { [weak self] in self?.completionEngine?.acceptFull() }
            return nil
        }

        // ── Escape ─────────────────────────────────────────────────────────────
        if keyCode == 53 {
            guard hasSuggestion else { return Unmanaged.passRetained(event) }
            DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            return nil
        }

        // ── Delete / Backspace (keyCode 51) ────────────────────────────────────
        // Forward the key normally but dismiss the suggestion without retriggering.
        if keyCode == 51 {
            if hasSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.onDismissKey() }
            }
            return Unmanaged.passRetained(event)
        }

        // ── Arrow keys ─────────────────────────────────────────────────────────
        let isArrow = (keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126)
        if isArrow {
            if hasSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            }
            return Unmanaged.passRetained(event)
        }

        // ── Cmd / Ctrl combos — dismiss, don't retrigger ───────────────────────
        if hasCmd || hasCtrl {
            if hasSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            }
            return Unmanaged.passRetained(event)
        }

        // ── Page Up / Down, Home, End, Forward-Delete ──────────────────────────
        let navKeys: Set<Int64> = [116, 121, 115, 119, 117]  // PgUp, PgDn, Home, End, FwdDel
        if navKeys.contains(keyCode) {
            if hasSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            }
            return Unmanaged.passRetained(event)
        }

        // ── Regular printable key — trigger completion ─────────────────────────
        let character = unicodeChar(from: event)
        DispatchQueue.main.async { [weak self] in
            self?.completionEngine?.onKeystroke(character: character)
        }
        return Unmanaged.passRetained(event)
    }

    private func unicodeChar(from event: CGEvent) -> Character? {
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actualLength, unicodeString: &chars)
        guard actualLength > 0 else { return nil }
        let trimmed = Array(chars.prefix(actualLength))
        return String(utf16CodeUnits: trimmed, count: trimmed.count).first
    }
}
