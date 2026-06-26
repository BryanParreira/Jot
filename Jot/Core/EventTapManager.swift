import Cocoa
import Carbon

/// Two-tap architecture:
///
/// 1. **Observer tap** — listen-only, head-inserted. Detects all keystrokes and triggers
///    completions. Never stalls other apps regardless of main-thread load.
///
/// 2. **Consumer tap** — active, tail-appended. Consumes Tab / Backtick / Escape only
///    when a suggestion is visible. Minimal, fast callback.
class EventTapManager {
    private var observerTap: CFMachPort?
    private var consumerTap: CFMachPort?
    private var observerSource: CFRunLoopSource?
    private var consumerSource: CFRunLoopSource?
    private weak var completionEngine: CompletionEngine?

    /// Written from main thread; read from event tap thread.
    /// One stale read is acceptable — the next key re-syncs state.
    var hasPendingSuggestion: Bool = false

    private static var sharedInstance: EventTapManager?

    init(completionEngine: CompletionEngine) {
        self.completionEngine = completionEngine
        EventTapManager.sharedInstance = self
    }

    func start() {
        startObserverTap()
        startConsumerTap()
    }

    func stop() {
        if let tap = observerTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tap = consumerTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = observerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let src = consumerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        observerTap = nil; consumerTap = nil
        observerSource = nil; consumerSource = nil
    }

    // MARK: - Setup

    private func startObserverTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // listenOnly: callback return value is ignored — can never stall other apps
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
                EventTapManager.sharedInstance?.observerCallback(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            DebugLogger.log("Failed to create observer event tap — check Input Monitoring permission")
            return
        }

        observerTap = tap
        observerSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), observerSource!, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.log("Observer tap started")
    }

    private func startConsumerTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // defaultTap + tailAppend: runs after other taps; can return nil to consume
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, _ -> Unmanaged<CGEvent>? in
                EventTapManager.sharedInstance?.consumerCallback(proxy: proxy, type: type, event: event)
            },
            userInfo: nil
        ) else {
            DebugLogger.log("Failed to create consumer event tap")
            return
        }

        consumerTap = tap
        consumerSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), consumerSource!, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.log("Consumer tap started")
    }

    // MARK: - Observer callback (listen-only, never stalls)

    private func observerCallback(_ event: CGEvent) {
        // Ignore our own synthesized keystrokes
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags
        let hasCmd  = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)

        // Tab / Backtick / Escape are handled by the consumer tap — skip here
        let isAcceptOrDismiss = (keyCode == 48 || keyCode == 50 || keyCode == 53)

        // Delete / Backspace — dismiss without retriggering
        if keyCode == 51 {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.onDismissKey() }
            }
            return
        }

        // Arrow keys — dismiss
        let isArrow = (keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126)
        if isArrow {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            }
            return
        }

        // Nav keys (PgUp/Dn, Home, End, FwdDel) — dismiss
        let navKeys: Set<Int64> = [116, 121, 115, 119, 117]
        if navKeys.contains(keyCode) {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            }
            return
        }

        // Cmd / Ctrl combos — dismiss, no retrigger
        if hasCmd || hasCtrl {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            }
            return
        }

        // Regular printable key — trigger completion
        if !isAcceptOrDismiss {
            let character = unicodeChar(from: event)
            DispatchQueue.main.async { [weak self] in
                self?.completionEngine?.onKeystroke(character: character)
            }
        }
    }

    // MARK: - Consumer callback (active, tail-appended, can consume)

    private func consumerCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it (security timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = consumerTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Ignore synthesized keystrokes
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData {
            return Unmanaged.passRetained(event)
        }

        // Only act when a suggestion is visible
        guard hasPendingSuggestion else { return Unmanaged.passRetained(event) }

        let keyCode  = event.getIntegerValueField(.keyboardEventKeycode)
        let hasShift = event.flags.contains(.maskShift)

        switch keyCode {
        case 48:  // Tab — accept next word; Shift+Tab — accept full
            if hasShift {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.acceptFull() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.completionEngine?.acceptNextWord() }
            }
            return nil  // consume Tab

        case 50:  // Backtick — accept full
            DispatchQueue.main.async { [weak self] in self?.completionEngine?.acceptFull() }
            return nil  // consume backtick

        case 53:  // Escape — dismiss
            DispatchQueue.main.async { [weak self] in self?.completionEngine?.dismiss() }
            return nil  // consume Escape

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Helpers

    private func unicodeChar(from event: CGEvent) -> Character? {
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actualLength, unicodeString: &chars)
        guard actualLength > 0 else { return nil }
        let trimmed = Array(chars.prefix(actualLength))
        return String(utf16CodeUnits: trimmed, count: trimmed.count).first
    }
}
