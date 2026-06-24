import Cocoa
import ApplicationServices

class OnboardingWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showStep(0)
    }

    private func showStep(_ step: Int) {
        self.step = step
        view.subviews.forEach { $0.removeFromSuperview() }
        pollTimer?.invalidate()
        pollTimer = nil

        switch step {
        case 0: showWelcomeStep()
        case 1: showAccessibilityStep()
        case 2: showInputMonitoringStep()
        case 3: showOllamaStep()
        default: finish()
        }
    }

    // MARK: - Steps

    private func showWelcomeStep() {
        let stack = centeredStack()

        let icon = permissionIcon("keyboard", color: .systemBlue)
        let title = heading("Welcome to Jot")
        let body = paragraph("Jot watches what you type and suggests completions using a local AI model.\n\nEverything runs on your Mac — no cloud, no accounts, no data leaves your device.")

        let btn = primaryButton("Get Started")
        btn.onAction { [weak self] _ in self?.showStep(1) }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(btn)
    }

    private func showAccessibilityStep() {
        let stack = centeredStack()

        let icon = permissionIcon("hand.raised.fill", color: .systemOrange)
        let title = heading("Accessibility Access")
        let body = paragraph("Finds the focused text field and places ghost text right at your caret.\n\nYou'll see a system dialog — click Open System Settings, then enable Jot.")

        let statusLabel = statusBadge("Required for Jot to read text from apps")

        let btn = primaryButton("Open Accessibility Settings")
        btn.onAction { [weak self] _ in
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            self?.waitForAccessibility(label: statusLabel)
        }

        let skipBtn = secondaryButton("Already granted — continue")
        skipBtn.onAction { [weak self] _ in self?.showStep(2) }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(btn)
        stack.addArrangedSubview(skipBtn)
    }

    private func waitForAccessibility(label: NSTextField) {
        label.stringValue = "Waiting for permission…"
        label.textColor = .systemOrange
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            DispatchQueue.main.async { self?.showStep(2) }
        }
    }

    private func showInputMonitoringStep() {
        let stack = centeredStack()

        let icon = permissionIcon("keyboard.fill", color: .systemPurple)
        let title = heading("Input Monitoring")
        let body = paragraph("Detects typing and lets Tab accept the suggestion.\n\nOpen System Settings → Privacy & Security → Input Monitoring, then enable Jot.")

        let statusLabel = statusBadge("Required for Tab key interception")

        let btn = primaryButton("Open Input Monitoring Settings")
        btn.onAction { [weak self] _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
            CGRequestListenEventAccess()
            self?.waitForInputMonitoring(label: statusLabel)
        }

        let skipBtn = secondaryButton("Already granted — continue")
        skipBtn.onAction { [weak self] _ in self?.showStep(3) }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(btn)
        stack.addArrangedSubview(skipBtn)
    }

    private func waitForInputMonitoring(label: NSTextField) {
        label.stringValue = "Waiting for permission…"
        label.textColor = .systemOrange
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] timer in
            guard CGPreflightListenEventAccess() else { return }
            timer.invalidate()
            DispatchQueue.main.async { self?.showStep(3) }
        }
    }

    private func showOllamaStep() {
        let stack = centeredStack()

        let icon = permissionIcon("cpu.fill", color: .systemGreen)
        let title = heading("Set Up Ollama")
        let body = paragraph("Jot uses Ollama as its local AI backend. Make sure Ollama is running and you have a model installed.")

        let codeBlock = NSTextField(labelWithString: "ollama pull qwen2.5:1.5b")
        codeBlock.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeBlock.backgroundColor = NSColor.controlBackgroundColor
        codeBlock.drawsBackground = true
        codeBlock.isBezeled = false
        codeBlock.wantsLayer = true
        codeBlock.layer?.cornerRadius = 6
        codeBlock.layer?.borderWidth = 1
        codeBlock.layer?.borderColor = NSColor.separatorColor.cgColor

        let statusLabel = statusBadge("Not checked yet")

        let checkBtn = secondaryButton("Check Ollama Connection")
        checkBtn.onAction { _ in
            statusLabel.stringValue = "Checking…"
            statusLabel.textColor = .secondaryLabelColor
            Task {
                let ok = await OllamaClient.shared.ping()
                await MainActor.run {
                    if ok {
                        statusLabel.stringValue = "✓ Ollama is running"
                        statusLabel.textColor = .systemGreen
                    } else {
                        statusLabel.stringValue = "✗ Ollama not found — install from ollama.com"
                        statusLabel.textColor = .systemRed
                    }
                }
            }
        }

        let doneBtn = primaryButton("Done — Start Using Jot")
        doneBtn.onAction { [weak self] _ in self?.finish() }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(codeBlock)
        stack.addArrangedSubview(checkBtn)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(doneBtn)
    }

    private func finish() {
        pollTimer?.invalidate()
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
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 48, bottom: 32, right: 48)
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

    private func permissionIcon(_ symbol: String, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        container.widthAnchor.constraint(equalToConstant: 64).isActive = true
        container.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = color
        iv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func statusBadge(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
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
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func primaryButton(_ title: String) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\r"
        return btn
    }

    private func secondaryButton(_ title: String) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.bezelStyle = .inline
        return btn
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
}

