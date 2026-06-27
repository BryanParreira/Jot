import Cocoa
import ApplicationServices

protocol TextWatcherDelegate: AnyObject {
    func textWatcher(_ watcher: TextWatcher, didUpdate context: TextContext)
    func textWatcherDidLoseContext(_ watcher: TextWatcher)
}

struct TextContext {
    let textBeforeCursor: String
    let element: AXUIElement
    let cursorRect: CGRect?
    let font: NSFont?
}

/// Polls the focused AXUIElement on the main RunLoop every 80ms.
/// Fires textWatcher(_:didUpdate:) immediately on text change — the coordinator owns debouncing.
///
/// IMPORTANT: ALL AX calls happen on @MainActor. The AX API is not thread-safe and fails
/// silently from background queues (calls return .noValue / nil without error). This matches
/// Cotabby's FocusTracker architecture, which also uses a main-thread Timer.
@MainActor
final class TextWatcher {
    weak var delegate: TextWatcherDelegate?

    private var pollTimer: Timer?
    private var lastContext: String = ""
    private var lastElement: AXUIElement?

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        poll()
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Poll (main thread, every 80ms)

    private func poll() {
        guard let element = focusedTextElement() else {
            if !lastContext.isEmpty {
                lastContext = ""
                lastElement = nil
                delegate?.textWatcherDidLoseContext(self)
            }
            return
        }

        guard !isPasswordField(element) else { return }
        guard let text = textBeforeCursor(in: element), text.count >= 3 else { return }
        guard text != lastContext else { return }

        lastContext = text
        lastElement = element

        // Read cursor rect and font here — same AX round-trip, no extra cost
        let rect = cursorScreenRect(in: element)
        let font = fontForElement(element)

        delegate?.textWatcher(self, didUpdate: TextContext(
            textBeforeCursor: text,
            element: element,
            cursorRect: rect,
            font: font
        ))
    }

    // MARK: - Focused element detection

    /// Finds the best editable AX element near the system focus.
    ///
    /// Strategy (matches Cotabby's shallow-candidate resolution):
    ///   1. Direct hit: focused element itself has selection + value.
    ///   2. Shallow: focused element's immediate children (covers AXScrollArea → AXTextArea,
    ///      AXGroup → AXTextField used by many Electron apps).
    ///   3. Parent: one level up + its children (covers some wrapped web editors).
    ///
    /// Chromium/Electron also need their web-accessibility tree primed via AXEnhancedUserInterface
    /// before any of these queries can see web content. That priming is fire-and-forget per app.
    func focusedTextElement() -> AXUIElement? {
        // Prime Chrome/Electron accessibility so web content is AX-readable
        primeChromiumIfNeeded()

        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let el = focused as! AXUIElement

        // 1. Direct hit
        if hasTextCapability(el) { return el }

        // 2. Immediate children (e.g. AXScrollArea → AXTextArea)
        if let hit = firstCapableChild(of: el) { return hit }

        // 3. Parent + parent's children (e.g. some Electron wrappers)
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
           let parentRef {
            let parent = parentRef as! AXUIElement
            if hasTextCapability(parent) { return parent }
            if let hit = firstCapableChild(of: parent) { return hit }
        }

        return nil
    }

    /// Returns true when element can supply cursor position and full text value.
    private func hasTextCapability(_ element: AXUIElement) -> Bool {
        // Block known pure-container roles immediately — avoids 2 IPC calls per container.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        let containerRoles: Set<String> = [
            "AXScrollArea", "AXSplitGroup", "AXGroup", "AXWebArea",
            "AXWindow", "AXApplication", "AXToolbar", "AXSplitter"
        ]
        if containerRoles.contains(role) { return false }

        // Secure fields are excluded at the poll() level; allow them through here.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else {
            return false
        }
        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef) == .success else {
            return false
        }
        return true
    }

    /// Searches the direct children of `element` for the first one with text capability.
    /// Capped at 12 children to stay off the per-keystroke hot path.
    private func firstCapableChild(of element: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children.prefix(12) {
            if hasTextCapability(child) { return child }
        }
        return nil
    }

    // MARK: - Chromium/Electron accessibility priming

    /// (bid, pid) pairs already primed this session. PID alone can be reused after process exit.
    private var primedApps = Set<String>()

    /// Sets AXEnhancedUserInterface on the frontmost Chromium/Electron app so its web content
    /// becomes accessible. Without this, Chrome's renderer AX tree shows only native chrome UI.
    /// This is idempotent — safe to call repeatedly; cached per (bid+pid) to avoid per-poll IPC.
    private func primeChromiumIfNeeded() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bid = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier
        let key = "\(bid):\(pid)"
        guard primedApps.insert(key).inserted else { return }

        let chromiumBundles: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
            "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.nightly",
            "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
            "com.github.GitHubClient",
            "com.tinyspeck.slackmacgap",       // Slack
            "com.microsoft.VSCode",             // VS Code
            "com.microsoft.VSCodeInsiders",
            "com.todesktop.230313mzl4w4u92",   // Linear
            "com.figma.Desktop",
            "notion.id", "com.notion.id",
            "com.discord.Discord",
            "com.lasso.zoom",                   // Zoom chat
        ]
        let isChromium = chromiumBundles.contains(bid)
            || bid.contains("electron") || bid.contains("chromium")
        guard isChromium else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
    }

    // MARK: - Password detection

    func isPasswordField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == "AXSecureTextField" { return true }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return subroleRef as? String == "AXSecureTextField"
    }

    // MARK: - Text extraction

    func textBeforeCursor(in element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) else { return nil }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef) == .success,
              let text = textRef as? String else { return nil }

        // AX selection range is in UTF-16 code units — use NSString to slice correctly.
        // Swift's String index arithmetic counts Unicode scalars and disagrees with UTF-16
        // counts for emoji and CJK characters, giving wrong offsets or crashing.
        let nsText = text as NSString
        let safeLocation = min(max(cfRange.location, 0), nsText.length)
        let prefix = nsText.substring(to: safeLocation)

        let limit = AppSettings.shared.contextChars
        return prefix.count > limit ? String(prefix.suffix(limit)) : prefix
    }

    func textAfterCursor(in element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) else { return nil }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef) == .success,
              let text = textRef as? String else { return nil }

        let nsText = text as NSString
        let safeLocation = min(max(cfRange.location, 0), nsText.length)
        let suffix = nsText.substring(from: safeLocation)
        return suffix.isEmpty ? nil : String(suffix.prefix(400))
    }

    func cursorPosition(in element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) else { return nil }
        return cfRange.location
    }

    // MARK: - Cursor screen rect

    /// Returns cursor position in Quartz screen coordinates (y=0 at top of primary screen).
    /// Three strategies in priority order to handle apps that report bounds differently.
    func cursorScreenRect(in element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) else { return nil }

        // Strategy 1: character before cursor — reliable height and x
        if cfRange.location > 0 {
            var r = CFRange(location: cfRange.location - 1, length: 1)
            if let axr = AXValueCreate(.cfRange, &r) {
                var boundsRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, axr, &boundsRef
                ) == .success, let bv = boundsRef {
                    var rect = CGRect.zero
                    if AXValueGetValue(bv as! AXValue, .cgRect, &rect),
                       rect.height > 0, rect.origin.x > 0 || rect.origin.y > 0 {
                        return CGRect(x: rect.maxX, y: rect.origin.y, width: 1, height: rect.height)
                    }
                }
            }
        }

        // Strategy 2: character at cursor
        var r2 = CFRange(location: cfRange.location, length: 1)
        if let axr = AXValueCreate(.cfRange, &r2) {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axr, &boundsRef
            ) == .success, let bv = boundsRef {
                var rect = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &rect),
                   rect.height > 0, rect.origin.x > 0 || rect.origin.y > 0 {
                    return CGRect(x: rect.origin.x, y: rect.origin.y, width: 1, height: rect.height)
                }
            }
        }

        // Strategy 3: zero-length caret
        var r3 = CFRange(location: cfRange.location, length: 0)
        if let axr = AXValueCreate(.cfRange, &r3) {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axr, &boundsRef
            ) == .success, let bv = boundsRef {
                var rect = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &rect) { return rect }
            }
        }

        return nil
    }

    // MARK: - Font

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
