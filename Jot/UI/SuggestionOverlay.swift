import Cocoa

/// Borderless non-activating panel that renders inline ghost text next to the cursor.
/// Lives at .screenSaver window level so it floats above all normal windows.
class SuggestionOverlay: NSPanel {

    static let shared = SuggestionOverlay()

    private let label = NSTextField(labelWithString: "")
    private(set) var currentSuggestion: String?

    // MARK: - Init

    private override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                          backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        setup()
    }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: true)
    }

    private func setup() {
        isOpaque             = false
        backgroundColor      = .clear
        level                = .screenSaver         // above all normal windows
        ignoresMouseEvents   = true
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hasShadow            = false
        hidesOnDeactivate    = false
        animationBehavior    = .none
        isFloatingPanel      = true
        isReleasedWhenClosed = false

        let cv = NSView(frame: .zero)
        cv.wantsLayer = true
        contentView = cv

        label.isBezeled            = false
        label.isEditable           = false
        label.isSelectable         = false
        label.backgroundColor      = .clear
        label.drawsBackground      = false
        label.lineBreakMode        = .byTruncatingTail
        label.maximumNumberOfLines = 1
        cv.addSubview(label)
    }

    // MARK: - Public API

    /// Show ghost text. `axRect` is in Quartz / Core Graphics coordinates (y=0 top, y↓).
    func show(suggestion: String, at axRect: CGRect, font: NSFont, color: NSColor) {
        guard !suggestion.isEmpty else { dismiss(); return }
        currentSuggestion = suggestion

        // Scale font to match visual line height from the caret rect.
        // Many apps report wrong font size via AX; caret height is more reliable.
        let displayFont = fontMatchingCaretHeight(axRect.height, preferred: font)

        label.stringValue = suggestion
        label.font        = displayFont
        label.textColor   = color.withAlphaComponent(0.42)

        let attrs = [NSAttributedString.Key.font: displayFont]
        let textW = min((suggestion as NSString).size(withAttributes: attrs).width + 2, 720)

        // Line height from font metrics when caret rect has no height (some apps return 0)
        let lineH = axRect.height > 2
            ? axRect.height
            : ceil(displayFont.ascender - displayFont.descender + displayFont.leading)

        // Convert AX Quartz Y → Cocoa Y: cocoaBottom = primaryH − (axY + lineH)
        let primaryH = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let cocoaY   = primaryH - axRect.origin.y - lineH

        // axRect.origin.x is already the cursor X (right edge of last char, from strategy 1)
        setFrame(CGRect(x: axRect.origin.x, y: cocoaY, width: textW, height: ceil(lineH)),
                 display: false)
        label.frame = CGRect(x: 0, y: 0, width: textW, height: ceil(lineH))

        if !isVisible {
            alphaValue = 0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.05
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            display()
        }
    }

    /// Grow suggestion text in-place during streaming.
    func update(suggestion: String) {
        guard isVisible else { return }
        currentSuggestion = suggestion
        label.stringValue = suggestion
        if let font = label.font {
            let attrs = [NSAttributedString.Key.font: font]
            let newW  = min((suggestion as NSString).size(withAttributes: attrs).width + 2, 720)
            if abs(newW - frame.width) > 4 {
                var r = frame; r.size.width = newW
                setFrame(r, display: false)
                label.frame.size.width = newW
            }
        }
        display()
    }

    /// Atomically shift overlay right AND update remaining text — single render, no flicker.
    func advanceAfterAccepting(remaining: String, acceptedWidth: CGFloat) {
        guard isVisible else { return }

        if remaining.isEmpty {
            dismiss()
            return
        }

        currentSuggestion = remaining
        label.stringValue  = remaining

        let font  = label.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrs = [NSAttributedString.Key.font: font]
        let newW  = min((remaining as NSString).size(withAttributes: attrs).width + 2, 720)

        // All geometry changes before the single display() call — no intermediate frame shown
        var r = frame
        r.origin.x   += acceptedWidth
        r.size.width  = newW
        setFrame(r, display: false)
        label.frame   = CGRect(x: 0, y: 0, width: newW, height: r.size.height)
        display()
    }

    func dismiss(animated: Bool = false) {
        currentSuggestion = nil
        guard isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.06
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.alphaValue < 0.1 else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            })
        } else {
            orderOut(nil)
            alphaValue = 1
        }
    }

    // MARK: - Private

    private func fontMatchingCaretHeight(_ caretH: CGFloat, preferred font: NSFont) -> NSFont {
        guard caretH > 4 else { return font }
        let metricsH = font.ascender - font.descender
        guard metricsH > 0 else { return font }
        let scaled  = caretH * font.pointSize / metricsH
        let clamped = max(8, min(scaled, 48))
        return NSFont(name: font.fontName, size: clamped) ?? NSFont.systemFont(ofSize: clamped)
    }
}
