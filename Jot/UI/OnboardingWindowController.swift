import Cocoa
import ApplicationServices

class OnboardingWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Jot"
        window.center()
        self.init(window: window)
        window.contentViewController = OnboardingViewController()
    }
}

class OnboardingViewController: NSViewController {
    private var step = 0
    private var pollTimer: Timer?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showStep(0)
    }

    private func showStep(_ step: Int) {
        view.subviews.forEach { $0.removeFromSuperview() }

        switch step {
        case 0: showWelcomeStep()
        case 1: showAccessibilityStep()
        case 2: showOllamaStep()
        default: finish()
        }
    }

    private func showWelcomeStep() {
        let stack = centeredStack()

        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) {
            icon.image = img
        }
        icon.frame.size = CGSize(width: 64, height: 64)

        let title = heading("Welcome to Jot")
        let body = paragraph("Jot watches what you type and suggests completions using a local AI model via Ollama.\n\nEverything runs on your Mac — no cloud, no accounts, no data leaves your device.")

        let btn = primaryButton("Get Started")
        btn.onAction { [weak self] _ in self?.showStep(1) }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(btn)
    }

    private func showAccessibilityStep() {
        let stack = centeredStack()

        let title = heading("Grant Accessibility Access")
        let body = paragraph("Jot needs Accessibility permission to read text from apps and insert suggestions.\n\nYou'll see a system dialog — click Open System Preferences, then enable Jot.")

        let btn = primaryButton("Grant Accessibility Access")
        btn.onAction { [weak self] _ in
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            self?.waitForAccessibility()
        }

        let skipBtn = NSButton(title: "Already granted — skip", target: nil, action: nil)
        skipBtn.bezelStyle = .inline
        skipBtn.onAction { [weak self] _ in self?.showStep(2) }

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(btn)
        stack.addArrangedSubview(skipBtn)
    }

    private func waitForAccessibility() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.showStep(2)
            }
        }
    }

    private func showOllamaStep() {
        let stack = centeredStack()

        let title = heading("Check Ollama")
        let body = paragraph("Jot uses Ollama as its local AI backend. Make sure Ollama is running and you have a model installed.\n\nRecommended: qwen2.5:1.5b (fast) or phi3.5:mini (better quality)")

        let codeBlock = NSTextField(labelWithString: "ollama pull qwen2.5:1.5b")
        codeBlock.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeBlock.backgroundColor = NSColor.controlBackgroundColor
        codeBlock.drawsBackground = true
        codeBlock.isBezeled = true

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.isEditable = false
        statusLabel.isBezeled = false
        statusLabel.backgroundColor = .clear

        let checkBtn = primaryButton("Check Ollama Connection")
        checkBtn.onAction { _ in
            statusLabel.stringValue = "Checking..."
            Task {
                let ok = await OllamaClient.shared.ping()
                await MainActor.run {
                    statusLabel.stringValue = ok ? "✅ Ollama is running!" : "❌ Ollama not found. Install from ollama.com"
                }
            }
        }

        let doneBtn = NSButton(title: "Done — Start Using Jot", target: nil, action: nil)
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.onAction { [weak self] _ in self?.finish() }

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(codeBlock)
        stack.addArrangedSubview(checkBtn)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(doneBtn)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: SettingsKeys.hasLaunchedBefore)
        view.window?.close()
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.checkAccessibilityPermission()
        }
    }

    // MARK: - Layout helpers
    private func centeredStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 40, bottom: 30, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        return label
    }

    private func paragraph(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 380
        return label
    }

    private func primaryButton(_ title: String) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\r"
        return btn
    }
}
