import Cocoa
import ApplicationServices
import FoundationModels

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
        case 3: showScreenRecordingStep()
        case 4: showAppleIntelligenceStep()
        default: finish()
        }
    }

    // MARK: - Steps

    private func showWelcomeStep() {
        let stack = centeredStack()

        let icon = permissionIcon("keyboard", color: .systemBlue)
        let title = heading("Welcome to Jot")
        let body = paragraph("System-wide inline text completions powered by Gemma 4 running locally on your Mac.\n\n100% on-device · no cloud · no accounts · ~1–2.5 GB RAM")

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

    private func showScreenRecordingStep() {
        let stack = centeredStack()

        let icon = permissionIcon("camera.fill", color: .systemTeal)
        let title = heading("Screen Recording")
        let body = paragraph("Reads a screenshot around the focused field to give Jot visual context — making suggestions smarter in web apps, editors, and anything where labels live outside the text field.\n\nThis is optional. Disable in Settings → Context if you'd rather skip it.")

        let statusLabel = statusBadge("Optional — enhances suggestions with on-screen context")

        let btn = primaryButton("Grant Screen Recording Access")
        btn.onAction { [weak self] _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            CGRequestScreenCaptureAccess()
            self?.waitForScreenRecording(label: statusLabel)
        }

        let skipBtn = secondaryButton("Skip — don't use visual context")
        skipBtn.onAction { [weak self] _ in
            AppSettings.shared.screenAwareMode = false
            self?.showStep(4)
        }

        let alreadyBtn = secondaryButton("Already granted — continue")
        alreadyBtn.onAction { [weak self] _ in self?.showStep(4) }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(btn)
        stack.addArrangedSubview(alreadyBtn)
        stack.addArrangedSubview(skipBtn)
    }

    private func waitForScreenRecording(label: NSTextField) {
        label.stringValue = "Waiting for permission…"
        label.textColor = .systemOrange
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] timer in
            guard CGPreflightScreenCaptureAccess() else { return }
            timer.invalidate()
            DispatchQueue.main.async {
                label.stringValue = "✓ Screen Recording granted"
                label.textColor = .systemGreen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.showStep(4)
                }
            }
        }
    }

    private func showAppleIntelligenceStep() {
        let stack = centeredStack()

        let hasModel = !AppSettings.shared.llamaModelPath.isEmpty
        let modelName = AppSettings.shared.llamaModelName

        let icon = permissionIcon(hasModel ? "checkmark.seal.fill" : "cpu.fill", color: .systemPurple)
        let title = heading("Choose your AI Model")
        let body = paragraph(hasModel
            ? "Model ready: \(modelName)\n\nJot runs Gemma 4 locally — no cloud, no subscriptions."
            : "Jot runs Gemma 4 locally on your Mac.\n\nDownload a GGUF model from Hugging Face, then pick it below.\n\nRecommended: gemma-4-E2B-i1-Q4_K_M.gguf (~1.5 GB)"
        )

        let statusLabel = statusBadge(hasModel ? "● Model ready" : "● No model selected — pick a GGUF file below")
        statusLabel.textColor = hasModel ? .systemGreen : .systemOrange

        let doneBtn = primaryButton("Start Using Jot")
        doneBtn.onAction { [weak self] _ in self?.finish() }

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(statusLabel)

        if !hasModel {
            let pickBtn = secondaryButton("Choose GGUF…")
            pickBtn.onAction { [weak self] _ in self?.pickGGUFFromOnboarding() }
            stack.addArrangedSubview(pickBtn)
        }

        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(doneBtn)
    }

    private func pickGGUFFromOnboarding() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GGUF model file"
        panel.message = "Recommended: gemma-4-E2B-i1-Q4_K_M.gguf (~1.5 GB) or gemma-4-4b-it-Q4_K_M.gguf (~2.5 GB)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "gguf" else { return }

        AppSettings.shared.llamaModelPath = url.path
        // Refresh step to show updated status
        showStep(4)
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

