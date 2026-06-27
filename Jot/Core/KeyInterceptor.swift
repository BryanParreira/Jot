import Cocoa
import Carbon

protocol KeyInterceptorDelegate: AnyObject {
    /// Called for every printable keystroke. Return value unused — observer tap only.
    func keyInterceptorDidTypeCharacter(_ char: Character?)
    /// Called for backspace, arrow keys, delete — dismiss without retriggering.
    func keyInterceptorDidPressDismissKey()
    /// Called for Tab (next word accept).
    func keyInterceptorDidPressTab()
    /// Called for Shift+Tab (full accept).
    func keyInterceptorDidPressShiftTab()
    /// Called for Escape.
    func keyInterceptorDidPressEscape()
    /// Called for backtick (full accept, Cotypist-compatible binding).
    func keyInterceptorDidPressBacktick()
}

/// Two-tap CGEventTap architecture:
///
/// 1. **Observer tap** — listen-only, head-inserted. Detects all keystrokes and notifies
///    the delegate. Never stalls other apps regardless of main-thread load.
///
/// 2. **Consumer tap** — active, tail-appended. Consumes Tab / Backtick / Escape only
///    when `hasPendingSuggestion` is true. Minimal, sub-1ms callback.
final class KeyInterceptor {
    weak var delegate: KeyInterceptorDelegate?

    /// Written from main thread, read from event tap thread.
    /// One stale read is acceptable — next key re-syncs state.
    var hasPendingSuggestion: Bool = false

    private var observerTap: CFMachPort?
    private var consumerTap: CFMachPort?
    private var observerSource: CFRunLoopSource?
    private var consumerSource: CFRunLoopSource?

    private static var sharedInstance: KeyInterceptor?

    init() {
        KeyInterceptor.sharedInstance = self
    }

    // MARK: - Lifecycle

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

    // MARK: - Observer tap (listen-only, never stalls)

    private func startObserverTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
                KeyInterceptor.sharedInstance?.observerCallback(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            DebugLogger.log("[KeyInterceptor] Failed to create observer tap — check Input Monitoring")
            return
        }

        observerTap = tap
        observerSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), observerSource!, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.log("[KeyInterceptor] Observer tap started")
    }

    // MARK: - Consumer tap (active, tail-appended, can consume)

    private func startConsumerTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, _ -> Unmanaged<CGEvent>? in
                KeyInterceptor.sharedInstance?.consumerCallback(proxy: proxy, type: type, event: event)
            },
            userInfo: nil
        ) else {
            DebugLogger.log("[KeyInterceptor] Failed to create consumer tap")
            return
        }

        consumerTap = tap
        consumerSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), consumerSource!, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.log("[KeyInterceptor] Consumer tap started")
    }

    // MARK: - Observer callback

    private func observerCallback(_ event: CGEvent) {
        // Ignore our own synthesized keystrokes
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags
        let hasCmd  = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)

        // Tab / Backtick / Escape — handled by consumer tap
        let isAcceptOrDismiss = keyCode == 48 || keyCode == 50 || keyCode == 53

        // Backspace — dismiss without retriggering
        if keyCode == 51 {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressDismissKey() }
            }
            return
        }

        // Arrow keys — dismiss
        let isArrow = keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126
        if isArrow {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressDismissKey() }
            }
            return
        }

        // Nav keys (PgUp/Dn, Home, End, ForwardDelete) — dismiss
        if [116, 121, 115, 119, 117].contains(Int(keyCode)) {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressDismissKey() }
            }
            return
        }

        // Cmd / Ctrl combos — dismiss, no retrigger
        if hasCmd || hasCtrl {
            if hasPendingSuggestion {
                DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressDismissKey() }
            }
            return
        }

        if !isAcceptOrDismiss {
            let char = unicodeChar(from: event)
            DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidTypeCharacter(char) }
        }
    }

    // MARK: - Consumer callback

    private func consumerCallback(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = consumerTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Ignore synthesized keystrokes
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData {
            return Unmanaged.passRetained(event)
        }

        guard hasPendingSuggestion else { return Unmanaged.passRetained(event) }

        let keyCode  = event.getIntegerValueField(.keyboardEventKeycode)
        let hasShift = event.flags.contains(.maskShift)

        switch keyCode {
        case 48: // Tab
            if hasShift {
                DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressShiftTab() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressTab() }
            }
            return nil // consume

        case 50: // Backtick
            DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressBacktick() }
            return nil

        case 53: // Escape
            DispatchQueue.main.async { [weak self] in self?.delegate?.keyInterceptorDidPressEscape() }
            return nil

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Helpers

    private func unicodeChar(from event: CGEvent) -> Character? {
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return nil }
        return String(utf16CodeUnits: Array(chars.prefix(len)), count: len).first
    }
}
