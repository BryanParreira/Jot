import Cocoa

class SuggestionOverlay: NSWindow {
    static let shared = SuggestionOverlay()

    private let label = NSTextField(labelWithString: "")
    private(set) var currentSuggestion: String?
    private var dismissTimer: Timer?

    private override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                          backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        setup()
    }

    private init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        setup()
    }

    private func setup() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hasShadow = false
        animationBehavior = .none

        let contentView = NSView(frame: .zero)
        contentView.wantsLayer = true
        self.contentView = contentView

        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        contentView.addSubview(label)
    }

    // MARK: - Public API

    /// Show suggestion at cursor. axRect is in Quartz screen coordinates (y from top-left, y↓).
    func show(suggestion: String, at axRect: CGRect, font: NSFont, color: NSColor) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        currentSuggestion = suggestion

        label.stringValue = suggestion
        label.font = font
        label.textColor = color.withAlphaComponent(0.45)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (suggestion as NSString).size(withAttributes: attrs)

        // Derive line height from font metrics — don't trust axRect.height which can be 0
        // for some apps (Chrome, Electron, etc.)
        let fontLineH = ceil(font.ascender - font.descender + font.leading)
        let lineH = axRect.height > 2 ? axRect.height : fontLineH

        let windowW = min(textSize.width + 2, 720)
        let windowH = ceil(lineH)

        // AX returns Quartz coords (y=0 at TOP of primary screen, increasing downward).
        // NSWindow.setFrame wants Cocoa coords (y=0 at BOTTOM of primary screen, increasing upward).
        // Cocoa-Y of cursor bottom = primaryH − (axQuartzY + lineH)
        let primaryH = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let cocoaY = primaryH - axRect.origin.y - lineH

        setFrame(CGRect(x: axRect.maxX + 1, y: cocoaY, width: windowW, height: windowH),
                 display: false)
        label.frame = CGRect(x: 0, y: 0, width: windowW, height: windowH)

        if !isVisible {
            alphaValue = 0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.06
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
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let newW = min((suggestion as NSString).size(withAttributes: attrs).width + 2, 720)
            if abs(newW - frame.width) > 4 {
                var r = frame; r.size.width = newW
                setFrame(r, display: false)
                label.frame.size.width = newW
            }
        }
        display()
    }

    func dismiss(animated: Bool = false) {
        dismissTimer?.invalidate()
        dismissTimer = nil
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
}
