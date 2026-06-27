import Cocoa
import ApplicationServices

class AccessibilityManager {

    func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let element = focused else { return nil }
        let axElement = element as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        let textRoles: Set<String> = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
            "AXWebArea", "AXScrollArea"
        ]

        if textRoles.contains(role) || role.contains("Text") || role.contains("Field") {
            return axElement
        }

        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success {
            return axElement
        }

        return nil
    }

    func isPasswordField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        if role == "AXSecureTextField" { return true }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String

        var roleDescRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDescRef)
        let roleDesc = roleDescRef as? String

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = descRef as? String

        return SecureFieldMarkers.isSecure(
            role: role, subrole: subrole, roleDescription: roleDesc,
            title: title, label: desc
        )
    }

    func textValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard result == .success else { return nil }
        return valueRef as? String
    }

    func cursorPosition(in element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard result == .success, let value = rangeRef else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    func textBeforeCursor(in element: AXUIElement) -> String? {
        guard let fullText = textValue(of: element),
              let pos = cursorPosition(in: element) else { return nil }

        let safePos = min(pos, fullText.count)
        let idx = fullText.index(fullText.startIndex, offsetBy: safePos)
        return String(fullText[..<idx])
    }

    func textAfterCursor(in element: AXUIElement) -> String? {
        guard let fullText = textValue(of: element),
              let pos = cursorPosition(in: element) else { return nil }

        let safePos = min(pos, fullText.count)
        let idx = fullText.index(fullText.startIndex, offsetBy: safePos)
        return String(fullText[idx...])
    }

    func cursorScreenRect(in element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }

        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) else { return nil }

        // Strategy 1: character BEFORE the cursor — has real height and reliable X position.
        // A zero-length caret range often returns origin (0,0) or the element's top-left in many apps.
        if cfRange.location > 0 {
            var charRange = CFRange(location: cfRange.location - 1, length: 1)
            if let axRange = AXValueCreate(.cfRange, &charRange) {
                var boundsRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef
                ) == .success, let bv = boundsRef {
                    var r = CGRect.zero
                    if AXValueGetValue(bv as! AXValue, .cgRect, &r),
                       r.height > 0, r.origin.x > 0 || r.origin.y > 0 {
                        // Return position at right edge of last char — that's where cursor is
                        return CGRect(x: r.maxX, y: r.origin.y, width: 1, height: r.height)
                    }
                }
            }
        }

        // Strategy 2: next character after cursor
        var nextRange = CFRange(location: cfRange.location, length: 1)
        if let axRange = AXValueCreate(.cfRange, &nextRange) {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef
            ) == .success, let bv = boundsRef {
                var r = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &r),
                   r.height > 0, r.origin.x > 0 || r.origin.y > 0 {
                    return CGRect(x: r.origin.x, y: r.origin.y, width: 1, height: r.height)
                }
            }
        }

        // Strategy 3: zero-length caret (original fallback)
        var insertionRange = CFRange(location: cfRange.location, length: 0)
        if let axRange = AXValueCreate(.cfRange, &insertionRange) {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef
            ) == .success, let bv = boundsRef {
                var r = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &r) {
                    return r
                }
            }
        }

        return nil
    }

    func insertText(_ text: String, into element: AXUIElement) {
        // Try AX direct insert (works for native AppKit fields)
        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if result == .success { return }
        // Fall back to pasteboard paste (works in Chrome, Electron, web, etc.)
        insertTextViaPasteboard(text)
    }

    /// Universal insertion: save pasteboard → write text → ⌘V → restore pasteboard.
    /// Works in every app including Chrome, Electron, and web text fields.
    func insertTextViaPasteboard(_ text: String) {
        let pb = NSPasteboard.general

        // Snapshot current pasteboard so we can restore it
        struct SavedItem { let types: [NSPasteboard.PasteboardType]; let data: [NSPasteboard.PasteboardType: Data] }
        let saved: [SavedItem] = pb.pasteboardItems?.map { item in
            SavedItem(types: item.types, data: item.types.reduce(into: [:]) {
                if let d = item.data(forType: $1) { $0[$1] = d }
            })
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Synthesize ⌘V with our marker so the event tap ignores it
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = SynthesizedEventMarker.userData

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        // Restore pasteboard after 150ms (app needs time to read it before we restore)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pb.clearContents()
            for item in saved {
                let pbItem = NSPasteboardItem()
                for (type, data) in item.data { pbItem.setData(data, forType: type) }
                pb.writeObjects([pbItem])
            }
        }
    }

    // Deletes `count` characters immediately before the cursor by
    // selecting that range then replacing it with empty string.
    func deleteTextBeforeCursor(count: Int, in element: AXUIElement) {
        guard count > 0,
              let pos = cursorPosition(in: element),
              let fullText = textValue(of: element) else { return }

        let safeEnd = min(pos, fullText.count)
        let safeStart = max(0, safeEnd - count)
        guard safeStart < safeEnd else { return }

        // Set selected range to the chars we want to delete
        var delRange = CFRange(location: safeStart, length: safeEnd - safeStart)
        if let rangeValue = AXValueCreate(.cfRange, &delRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }

        // Replace selected text with empty string
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            "" as CFTypeRef
        )
        if result != .success {
            // Fallback: simulate Delete key presses
            let source = CGEventSource(stateID: .hidSystemState)
            for _ in 0..<count {
                let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
                let up   = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    func replaceTextRange(_ range: NSRange, with replacement: String, in element: AXUIElement) {
        guard let fullText = textValue(of: element) else { return }
        guard range.location != NSNotFound,
              range.location + range.length <= fullText.count else { return }

        let startIndex = fullText.index(fullText.startIndex, offsetBy: range.location)
        let endIndex = fullText.index(startIndex, offsetBy: range.length)
        var newText = fullText
        newText.replaceSubrange(startIndex..<endIndex, with: replacement)

        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newText as CFTypeRef)
        if result == .success {
            var newRange = CFRange(location: range.location + replacement.count, length: 0)
            if let rangeValue = AXValueCreate(.cfRange, &newRange) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            }
        } else {
            simulateTyping(replacement)
        }
    }

    private func simulateTyping(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = SynthesizedEventMarker.userData  // prevent event tap from intercepting
        for char in text.unicodeScalars {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
            keyUp?.keyboardSetUnicodeString(stringLength: 1,   unicodeString: [UniChar(char.value)])
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    func focusedAppBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func fontForElement(_ element: AXUIElement) -> NSFont? {
        var fontRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFont" as CFString, &fontRef) == .success,
              let fontDict = fontRef as? [String: Any] else { return nil }

        let nameKey = kAXFontNameKey.takeUnretainedValue() as String
        let sizeKey = kAXFontSizeKey.takeUnretainedValue() as String
        let name = fontDict[nameKey] as? String ?? ""
        let size = fontDict[sizeKey] as? CGFloat ?? NSFont.systemFontSize

        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}
