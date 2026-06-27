import Cocoa
import ApplicationServices

/// Injects text into the focused AXUIElement using the best available method.
///
/// Priority order:
/// 1. kAXSelectedTextAttribute — direct AX write (AppKit, TextEdit, Mail, etc.)
/// 2. Pasteboard + ⌘V synthesis — fallback for Electron, web, Chromium apps
///
/// All methods restore any pre-existing pasteboard contents after a brief delay
/// so the user's clipboard is not corrupted.
final class TextInjector {

    // MARK: - Insert

    func insertText(_ text: String, into element: AXUIElement) {
        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if result == .success { return }
        // Native AX failed — fall back to pasteboard paste
        insertViaPasteboard(text)
    }

    // MARK: - Delete before cursor

    /// Deletes `count` characters immediately before the cursor.
    func deleteTextBeforeCursor(count: Int, in element: AXUIElement) {
        guard count > 0 else { return }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef else { return }
        var cfRange = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) else { return }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef) == .success,
              let text = textRef as? String else { return }

        let safeEnd   = min(cfRange.location, text.count)
        let safeStart = max(0, safeEnd - count)
        guard safeStart < safeEnd else { return }

        var delRange = CFRange(location: safeStart, length: safeEnd - safeStart)
        if let rangeValue = AXValueCreate(.cfRange, &delRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }

        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, "" as CFTypeRef
        )
        if result != .success {
            // Simulate Delete key presses as last resort
            let source = CGEventSource(stateID: .hidSystemState)
            for _ in 0..<count {
                CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Pasteboard paste

    /// Universal insertion: snapshot pasteboard → write text → synthesize ⌘V → restore pasteboard.
    /// Works in every app including Chrome, Electron, Slack, and all web text fields.
    func insertViaPasteboard(_ text: String) {
        let pb = NSPasteboard.general

        // Snapshot current pasteboard
        struct SavedItem {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }
        let saved: [SavedItem] = pb.pasteboardItems?.map { item in
            SavedItem(types: item.types, data: item.types.reduce(into: [:]) {
                if let d = item.data(forType: $1) { $0[$1] = d }
            })
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Synthesize ⌘V with our marker so KeyInterceptor ignores it
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = SynthesizedEventMarker.userData

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        // Restore pasteboard after app has had time to read it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pb.clearContents()
            for item in saved {
                let pbItem = NSPasteboardItem()
                for (type, data) in item.data { pbItem.setData(data, forType: type) }
                pb.writeObjects([pbItem])
            }
        }
    }

    // MARK: - Character-by-character typing (last resort for exotic apps)

    func simulateTyping(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = SynthesizedEventMarker.userData
        for scalar in text.unicodeScalars {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            let code = [UniChar(scalar.value)]
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: code)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: code)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
