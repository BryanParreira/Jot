import Cocoa

// MARK: - Data

private struct SidebarItem {
    let title: String
    let symbol: String
    let color: NSColor
}

private let sidebarItems: [SidebarItem] = [
    .init(title: "General",         symbol: "gearshape.fill",     color: .systemGray),
    .init(title: "Model",           symbol: "cpu.fill",           color: .systemPurple),
    .init(title: "Context",         symbol: "doc.text.fill",      color: .systemGreen),
    .init(title: "Personalization", symbol: "person.crop.circle.fill", color: .systemOrange),
    .init(title: "Features",        symbol: "wand.and.stars",     color: .systemPink),
    .init(title: "Statistics",      symbol: "chart.bar.fill",     color: .systemIndigo),
]

struct RecommendedModel {
    let name: String; let ram: String; let quality: String; let note: String
}

let recommendedModels: [RecommendedModel] = [
    .init(name: "qwen2.5:1.5b", ram: "8 GB",  quality: "Fast",   note: "Fastest — good for older Macs"),
    .init(name: "gemma3:2b",    ram: "8 GB",  quality: "Fast",   note: "⭐ Recommended · best quality/speed"),
    .init(name: "qwen2.5:3b",   ram: "16 GB", quality: "Better", note: "Strong code & writing"),
    .init(name: "gemma3:latest", ram: "16 GB", quality: "Better", note: "Gemma 3 4B — excellent fluency"),
    .init(name: "llama3.2:3b",  ram: "16 GB", quality: "Better", note: "Great English fluency"),
    .init(name: "qwen2.5:7b",   ram: "32 GB", quality: "Best",   note: "Near-perfect completions"),
    .init(name: "mistral:7b",   ram: "32 GB", quality: "Best",   note: "Excellent general writing"),
]

// MARK: - Window Controller

class SettingsWindowController: NSWindowController {
    convenience init() {
        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin

        let sidebar = SettingsSidebarVC()
        let pages   = SettingsPagesVC()
        sidebar.onSelect = { [weak pages] idx in pages?.show(idx) }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 190

        let contentItem = NSSplitViewItem(viewController: pages)
        contentItem.minimumThickness = 460

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "Jot Settings"
        w.center()
        w.contentViewController = split
        self.init(window: w)
    }
}

// MARK: - Sidebar

private class SettingsSidebarVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()
    private var selected = 0

    override func loadView() {
        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .sourceList
        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.action = #selector(rowClicked)
        table.target = self

        scroll.documentView = table
        scroll.frame = NSRect(x: 0, y: 0, width: 190, height: 530)
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarItems.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SourceListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sidebarItems[row]
        let cell = NSView()

        // Colored icon chip
        let chip = NSImageView(frame: NSRect(x: 12, y: 6, width: 24, height: 24))
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        chip.layer?.backgroundColor = item.color.cgColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        if let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            chip.image = img
            chip.contentTintColor = .white
        }

        let lbl = NSTextField(labelWithString: item.title)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.frame = NSRect(x: 44, y: 9, width: 130, height: 18)

        cell.addSubview(chip)
        cell.addSubview(lbl)
        return cell
    }

    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        selected = row
        onSelect?(row)
    }
}

private class SourceListRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
        path.fill()
    }
}

// MARK: - Pages Container

private class SettingsPagesVC: NSViewController {
    private var pageVCs: [NSViewController] = []
    private var current: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 530))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageVCs = [
            GeneralPage(), ModelPage(), ContextPage(),
            PersonalizationPage(), FeaturesPage(), StatsPage()
        ]
        show(0)
    }

    func show(_ index: Int) {
        guard index < pageVCs.count else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        let vc = pageVCs[index]
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.width, .height]
        view.addSubview(vc.view)
        current = vc
    }
}

// MARK: - Base Page

private class SettingsPage: NSViewController {
    private(set) var scrollView: NSScrollView!
    private(set) var contentStack: NSStackView!

    override func loadView() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 490, height: 530))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false  // prevent split-view from adding top inset
        scrollView.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()  // flipped so auto layout pins to top-left
        container.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        scrollView.documentView = container
        container.translatesAutoresizingMaskIntoConstraints = false

        view = scrollView
    }

    func pageTitle(_ text: String) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        contentStack.addArrangedSubview(lbl)
        addSpacer(4)
    }

    func sectionLabel(_ text: String) {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(lbl)
    }

    func card(_ rows: [NSView]) {
        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 450).isActive = true
        for (i, row) in rows.enumerated() {
            card.addRow(row, last: i == rows.count - 1)
        }
        contentStack.addArrangedSubview(card)
    }

    func addSpacer(_ height: CGFloat) {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        contentStack.addArrangedSubview(v)
    }

    // Row builders

    func toggleRow(_ label: String, subtitle: String? = nil, getter: @escaping () -> Bool, setter: @escaping (Bool) -> Void) -> NSView {
        let row = SettingsRow()
        row.addLabel(label, subtitle: subtitle)
        let sw = NSSwitch()
        sw.state = getter() ? .on : .off
        sw.onAction { ctrl in setter((ctrl as! NSSwitch).state == .on) }
        row.addControl(sw)
        return row
    }

    func popupRow(_ label: String, items: [String], selected: String, setter: @escaping (String) -> Void) -> (NSView, NSPopUpButton) {
        let row = SettingsRow()
        row.addLabel(label)
        let popup = NSPopUpButton()
        popup.addItems(withTitles: items.isEmpty ? [selected] : items)
        if let idx = items.firstIndex(of: selected) { popup.selectItem(at: idx) }
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        popup.onAction { ctrl in setter((ctrl as! NSPopUpButton).titleOfSelectedItem ?? selected) }
        row.addControl(popup)
        return (row, popup)
    }

    func sliderRow(_ label: String, min: Double, max: Double, current: Double, format: @escaping (Double) -> String, setter: @escaping (Double) -> Void) -> NSView {
        let row = SettingsRow(height: 52)
        row.addLabel(label)
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 2
        let valLbl = NSTextField(labelWithString: format(current))
        valLbl.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valLbl.textColor = .secondaryLabelColor
        valLbl.alignment = .right
        valLbl.widthAnchor.constraint(equalToConstant: 55).isActive = true
        let slider = NSSlider(value: current, minValue: min, maxValue: max, target: nil, action: nil)
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.onAction { s in let v = (s as! NSSlider).doubleValue; valLbl.stringValue = format(v); setter(v) }
        container.addArrangedSubview(slider)
        let controlRow = NSStackView(views: [slider, valLbl])
        controlRow.spacing = 8
        row.addControl(controlRow)
        return row
    }

    func segmentedRow(_ label: String, subtitle: String? = nil, options: [String], selected: Int, setter: @escaping (Int) -> Void) -> NSView {
        let row = SettingsRow()
        row.addLabel(label, subtitle: subtitle)
        let seg = NSSegmentedControl(labels: options, trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = selected
        seg.onAction { c in setter((c as! NSSegmentedControl).selectedSegment) }
        row.addControl(seg)
        return row
    }

    func textFieldRow(_ label: String, value: String, placeholder: String = "", setter: @escaping (String) -> Void) -> NSView {
        let row = SettingsRow()
        row.addLabel(label)
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.onTextChange { setter($0) }
        row.addControl(field)
        return row
    }

    func buttonRow(_ label: String, subtitle: String? = nil, buttonTitle: String, action: @escaping () -> Void) -> NSView {
        let row = SettingsRow()
        row.addLabel(label, subtitle: subtitle)
        let btn = NSButton(title: buttonTitle, target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.onAction { _ in action() }
        row.addControl(btn)
        return row
    }
}

// MARK: - Card View

private class CardView: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5

        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
    }

    func addRow(_ row: NSView, last: Bool) {
        stack.addArrangedSubview(row)
        if !last {
            let sep = SeparatorLine()
            stack.addArrangedSubview(sep)
        }
    }
}

// MARK: - Settings Row

private class SettingsRow: NSView {
    private let rowHeight: CGFloat
    private let labelStack = NSStackView()
    private let controlContainer = NSView()

    init(height: CGFloat = 44) {
        self.rowHeight = height
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        translatesAutoresizingMaskIntoConstraints = false

        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        controlContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelStack)
        addSubview(controlContainer)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -8),

            controlContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            controlContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func addLabel(_ text: String, subtitle: String? = nil) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStack.addArrangedSubview(lbl)

        if let sub = subtitle {
            let sub = NSTextField(labelWithString: sub)
            sub.font = NSFont.systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            labelStack.addArrangedSubview(sub)
        }
    }

    func addControl(_ control: NSView) {
        controlContainer.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.centerYAnchor.constraint(equalTo: controlContainer.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: controlContainer.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: controlContainer.trailingAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: controlContainer.topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: controlContainer.bottomAnchor),
        ])
        // Let control size itself
        let hug = NSLayoutConstraint(item: controlContainer, attribute: .width, relatedBy: .equal, toItem: control, attribute: .width, multiplier: 1, constant: 0)
        hug.priority = .defaultHigh
        controlContainer.addConstraint(hug)
        let h = NSLayoutConstraint(item: controlContainer, attribute: .height, relatedBy: .greaterThanOrEqual, toItem: control, attribute: .height, multiplier: 1, constant: 0)
        controlContainer.addConstraint(h)
    }
}

// NSScrollView document view that places origin at top-left (like UIScrollView).
// Without this, Cocoa's default coordinate system puts content at the bottom.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private class SeparatorLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - Pages

// General

private class GeneralPage: SettingsPage {
    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle("General")

        sectionLabel("Behavior")
        card([
            toggleRow("Enable Jot", subtitle: "Toggle all suggestions on or off",
                      getter: { AppSettings.shared.enabled },
                      setter: { AppSettings.shared.enabled = $0 }),
            toggleRow("Launch at Login",
                      getter: { AppSettings.shared.launchAtLogin },
                      setter: { AppSettings.shared.launchAtLogin = $0 }),
        ])

        addSpacer(10)
        sectionLabel("Suggestions")
        card([
            sliderRow("Suggestion Delay", min: 100, max: 1000,
                      current: Double(AppSettings.shared.debounceMs),
                      format: { "\(Int($0)) ms" }) {
                AppSettings.shared.debounceMs = Int($0)
            },
            segmentedRow("Completion Length",
                         subtitle: "Short ~1–2 words · Medium ~2–4 words · Long ~6–8 words",
                         options: ["Short", "Medium", "Long"],
                         selected: ["short": 0, "medium": 1, "long": 2][AppSettings.shared.completionLength] ?? 1) {
                AppSettings.shared.completionLength = ["short", "medium", "long"][$0]
            },
        ])

        addSpacer(10)
        sectionLabel("Connection")
        card([
            textFieldRow("Ollama URL", value: AppSettings.shared.ollamaURL,
                         placeholder: "http://localhost:11434") {
                AppSettings.shared.ollamaURL = $0
            },
        ])
    }
}

// Model

private class ModelPage: SettingsPage {
    private var popup: NSPopUpButton?
    private var statusLabel: NSTextField?
    private var installedModels: Set<String> = []
    private var recommendedStack: NSStackView?

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle("Model")

        sectionLabel("Active Model")
        buildModelCard()

        addSpacer(10)
        sectionLabel("Recommended Models")
        buildRecommendedSection()

        fetchModels()
    }

    private func buildModelCard() {
        let row = SettingsRow(height: 52)
        row.addLabel("Model", subtitle: "Select from models installed in Ollama")

        let rhs = NSStackView()
        rhs.orientation = .vertical
        rhs.spacing = 4
        rhs.alignment = .trailing

        let pu = NSPopUpButton()
        pu.addItem(withTitle: AppSettings.shared.model)
        pu.widthAnchor.constraint(equalToConstant: 200).isActive = true
        pu.onAction { ctrl in
            AppSettings.shared.model = (ctrl as! NSPopUpButton).titleOfSelectedItem ?? AppSettings.shared.model
        }
        self.popup = pu

        let refreshBtn = NSButton(title: "↻  Refresh", target: nil, action: nil)
        refreshBtn.bezelStyle = .inline
        refreshBtn.font = NSFont.systemFont(ofSize: 11)
        refreshBtn.onAction { [weak self] _ in self?.fetchModels() }

        rhs.addArrangedSubview(pu)
        rhs.addArrangedSubview(refreshBtn)
        row.addControl(rhs)

        let statusLbl = NSTextField(labelWithString: "Checking Ollama…")
        statusLbl.font = NSFont.systemFont(ofSize: 11)
        statusLbl.textColor = .secondaryLabelColor
        self.statusLabel = statusLbl

        let statusRow = SettingsRow()
        statusRow.addLabel("Status")
        statusRow.addControl(statusLbl)

        card([row, statusRow])
    }

    private func buildRecommendedSection() {
        let rs = NSStackView()
        rs.orientation = .vertical
        rs.spacing = 0
        rs.widthAnchor.constraint(equalToConstant: 450).isActive = true
        rs.wantsLayer = true
        rs.layer?.cornerRadius = 10
        rs.layer?.borderWidth = 0.5
        rs.layer?.masksToBounds = true
        rs.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        rs.layer?.borderColor = NSColor.separatorColor.cgColor
        self.recommendedStack = rs

        for (i, model) in recommendedModels.enumerated() {
            let row = buildRecommendedRow(model: model, isLast: i == recommendedModels.count - 1)
            rs.addArrangedSubview(row)
        }
        contentStack.addArrangedSubview(rs)
    }

    private func buildRecommendedRow(model: RecommendedModel, isLast: Bool) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.widthAnchor.constraint(equalToConstant: 450).isActive = true

        let row = NSView()
        row.heightAnchor.constraint(equalToConstant: 52).isActive = true
        row.widthAnchor.constraint(equalToConstant: 450).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false

        // Left: name + note
        let nameLabel = NSTextField(labelWithString: model.name)
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let noteLabel = NSTextField(labelWithString: model.note)
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView(views: [nameLabel, noteLabel])
        labelStack.orientation = .vertical
        labelStack.spacing = 2
        labelStack.alignment = .leading
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        // Middle: badges
        let ramBadge = badge(model.ram, color: .systemBlue)
        let qualityColor: NSColor = model.quality == "Fast" ? .systemGreen : model.quality == "Better" ? .systemOrange : .systemPurple
        let qualityBadge = badge(model.quality, color: qualityColor)
        let badgeStack = NSStackView(views: [ramBadge, qualityBadge])
        badgeStack.spacing = 4
        badgeStack.translatesAutoresizingMaskIntoConstraints = false

        // Right: action button (built later with tag for installed state)
        let actionBtn = NSButton(title: "", target: nil, action: nil)
        actionBtn.bezelStyle = .rounded
        actionBtn.font = NSFont.systemFont(ofSize: 12)
        actionBtn.widthAnchor.constraint(equalToConstant: 130).isActive = true
        actionBtn.translatesAutoresizingMaskIntoConstraints = false
        actionBtn.identifier = NSUserInterfaceItemIdentifier(model.name)
        let modelName = model.name
        actionBtn.onAction { [weak self] btn in
            guard let btn = btn as? NSButton else { return }
            if self?.installedModels.contains(modelName) == true {
                AppSettings.shared.model = modelName
                self?.popup?.selectItem(withTitle: modelName)
                self?.refreshButtons()
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ollama pull \(modelName)", forType: .string)
                btn.title = "✓ Copied!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.refreshButtons()
                }
            }
        }

        row.addSubview(labelStack)
        row.addSubview(badgeStack)
        row.addSubview(actionBtn)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            labelStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labelStack.widthAnchor.constraint(equalToConstant: 160),

            badgeStack.leadingAnchor.constraint(equalTo: labelStack.trailingAnchor, constant: 8),
            badgeStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            actionBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            actionBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        container.addArrangedSubview(row)
        if !isLast {
            let sep = SeparatorLine()
            container.addArrangedSubview(sep)
        }
        return container
    }

    private func badge(_ text: String, color: NSColor) -> NSView {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = color
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 4
        bg.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        lbl.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 5),
            lbl.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -5),
            lbl.topAnchor.constraint(equalTo: bg.topAnchor, constant: 2),
            lbl.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -2),
        ])
        return bg
    }

    private func fetchModels() {
        statusLabel?.stringValue = "Connecting to Ollama…"
        statusLabel?.textColor = .secondaryLabelColor
        Task {
            do {
                let models = try await OllamaClient.shared.availableModels()
                await MainActor.run {
                    self.installedModels = Set(models)
                    self.popup?.removeAllItems()
                    if models.isEmpty {
                        self.popup?.addItem(withTitle: AppSettings.shared.model)
                        self.statusLabel?.stringValue = "No models found — run: ollama pull qwen2.5:1.5b"
                        self.statusLabel?.textColor = .systemOrange
                    } else {
                        self.popup?.addItems(withTitles: models)
                        if let idx = models.firstIndex(of: AppSettings.shared.model) {
                            self.popup?.selectItem(at: idx)
                        }
                        let plural = models.count == 1 ? "model" : "models"
                        self.statusLabel?.stringValue = "● Ollama running — \(models.count) \(plural) installed"
                        self.statusLabel?.textColor = .systemGreen
                    }
                    self.refreshButtons()
                }
            } catch {
                await MainActor.run {
                    self.statusLabel?.stringValue = "● Ollama not running — start with: ollama serve"
                    self.statusLabel?.textColor = .systemRed
                    self.popup?.addItem(withTitle: AppSettings.shared.model)
                }
            }
        }
    }

    private func refreshButtons() {
        guard let stack = recommendedStack else { return }
        for sub in stack.arrangedSubviews {
            for row in (sub as? NSStackView)?.arrangedSubviews ?? [sub] {
                if let btn = row.subviews.first(where: { $0 is NSButton }) as? NSButton,
                   let modelName = btn.identifier?.rawValue {
                    let installed = installedModels.contains(modelName)
                    let isActive  = AppSettings.shared.model == modelName
                    if installed {
                        btn.title = isActive ? "✓ Active" : "Use"
                        btn.isEnabled = !isActive
                    } else {
                        btn.title = "Copy install command"
                        btn.isEnabled = true
                    }
                }
            }
        }
    }
}

// Context

private class ContextPage: SettingsPage {
    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle("Context")

        sectionLabel("Awareness")
        card([
            toggleRow("Clipboard Awareness",
                      subtitle: "Include recently copied text in suggestions",
                      getter: { AppSettings.shared.clipboardAwareness },
                      setter: { AppSettings.shared.clipboardAwareness = $0 }),
            toggleRow("Screen-Aware Mode",
                      subtitle: "Suppress suggestions in non-text contexts",
                      getter: { AppSettings.shared.screenAwareMode },
                      setter: { AppSettings.shared.screenAwareMode = $0 }),
        ])

        addSpacer(10)
        sectionLabel("Context Window")
        card([
            segmentedRow("Characters Sent",
                         options: ["500", "1 000", "2 000", "4 000"],
                         selected: [500:0, 1000:1, 2000:2, 4000:3][AppSettings.shared.contextChars] ?? 2) {
                AppSettings.shared.contextChars = [500, 1000, 2000, 4000][$0]
            },
        ])
    }
}

// Personalization

private class PersonalizationPage: SettingsPage {
    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle("Personalization")

        sectionLabel("Learning")
        card([
            sliderRow("Word Choice Learning", min: 0, max: 6,
                      current: Double(AppSettings.shared.personalizationLevel),
                      format: { v in
                          let labels = ["Off", "Minimal", "Low", "Medium", "High", "Very High", "Max"]
                          return labels[min(Int(v), labels.count - 1)]
                      }) {
                AppSettings.shared.personalizationLevel = Int($0)
            },
        ])

        addSpacer(10)
        sectionLabel("Instructions")
        card([
            textAreaRow("Custom Instructions",
                        value: AppSettings.shared.customInstructions,
                        placeholder: "Describe your role, audience, and writing tone…") {
                AppSettings.shared.customInstructions = $0
            },
        ])

        addSpacer(10)
        sectionLabel("Data")
        card([
            buttonRow("Writing History",
                      subtitle: "Accepted completions used to personalise suggestions",
                      buttonTitle: "Clear History") { [weak self] in
                self?.confirmClearHistory()
            },
        ])
    }

    private func textAreaRow(_ label: String, value: String, placeholder: String, setter: @escaping (String) -> Void) -> NSView {
        let container = NSView()
        container.heightAnchor.constraint(equalToConstant: 90).isActive = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.string = value
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        sv.documentView = tv

        let delegate = TextAreaDelegate(setter: setter)
        tv.delegate = delegate
        objc_setAssociatedObject(container, &textAreaDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        container.addSubview(lbl)
        container.addSubview(sv)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sv.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 110),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sv.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Writing History?"
        alert.informativeText = "All personalization data will be permanently deleted. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PersonalizationStore.shared.clearAll()
        }
    }
}

// Features

private class FeaturesPage: SettingsPage {
    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle("Features")

        sectionLabel("Suggestions")
        card([
            toggleRow("Inline Macros",
                      subtitle: "/date, /time, /now, /uuid, /rand, /year — Tab to expand",
                      getter: { AppSettings.shared.enableMacros },
                      setter: { AppSettings.shared.enableMacros = $0 }),
            toggleRow("Emoji Shortcuts",
                      subtitle: "Type :rocket and Tab inserts 🚀",
                      getter: { AppSettings.shared.enableEmoji },
                      setter: { AppSettings.shared.enableEmoji = $0 }),
            toggleRow("Typo Correction",
                      subtitle: "Detects misspellings and suggests fixes",
                      getter: { AppSettings.shared.enableTypoDetection },
                      setter: { AppSettings.shared.enableTypoDetection = $0 }),
            toggleRow("Mid-Line Completion",
                      subtitle: "Fill-in-the-middle when cursor is not at end",
                      getter: { AppSettings.shared.enableMidLine },
                      setter: { AppSettings.shared.enableMidLine = $0 }),
        ])

        addSpacer(10)
        sectionLabel("Ghost Text")
        card([
            sliderRow("Opacity", min: 0.15, max: 0.80,
                      current: AppSettings.shared.overlayOpacity,
                      format: { "\(Int($0 * 100))%" }) {
                AppSettings.shared.overlayOpacity = $0
            },
        ])

        addSpacer(10)
        sectionLabel("Keyboard Shortcuts")
        card([
            shortcutRow("Accept Word by Word", key: "Tab"),
            shortcutRow("Accept Full Suggestion", key: "` or Shift + Tab"),
            shortcutRow("Dismiss",               key: "Escape"),
        ])
    }

    private func shortcutRow(_ label: String, key: String) -> NSView {
        let row = SettingsRow()
        row.addLabel(label)
        let badge = keybadge(key)
        row.addControl(badge)
        return row
    }

    private func keybadge(_ text: String) -> NSView {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        lbl.textColor = .secondaryLabelColor
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        bg.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        bg.layer?.borderWidth = 0.5
        bg.translatesAutoresizingMaskIntoConstraints = false
        lbl.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            lbl.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            lbl.topAnchor.constraint(equalTo: bg.topAnchor, constant: 3),
            lbl.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -3),
        ])
        return bg
    }
}

// Stats

private class StatsPage: SettingsPage {
    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle("Statistics")

        let s = StatsTracker.shared

        sectionLabel("Today")
        card([
            infoRow("Completions Accepted", value: "\(s.totalAcceptedToday)"),
            infoRow("Words Saved",           value: "~\(s.totalWordsSavedToday)"),
        ])

        addSpacer(10)
        sectionLabel("All Time")
        card([
            infoRow("Completions Accepted", value: "\(s.totalAcceptedAllTime)"),
            infoRow("Words Saved",           value: "~\(s.totalWordsSavedAllTime)"),
            infoRow("Avg Latency",           value: "\(Int(s.averageLatencyMs)) ms"),
            infoRow("Active Model",          value: AppSettings.shared.model),
        ])

        addSpacer(10)
        sectionLabel("Actions")
        card([
            buttonRow("Usage Data", subtitle: "Reset all counters to zero",
                      buttonTitle: "Reset Statistics") {
                StatsTracker.shared.reset()
            },
        ])

        addSpacer(10)
        sectionLabel("Debug")
        card([
            toggleRow("Debug Logging",
                      subtitle: "Write all prompts and responses to a log file",
                      getter: { AppSettings.shared.debugMode },
                      setter: {
                          AppSettings.shared.debugMode = $0
                          DebugLogger.configure(enabled: $0)
                      }),
            buttonRow("Log File", subtitle: "~/Library/Logs/Jot/debug.log",
                      buttonTitle: "Open Log") {
                DebugLogger.openLogFile()
            },
        ])
    }

    private func infoRow(_ label: String, value: String) -> NSView {
        let row = SettingsRow()
        row.addLabel(label)
        let val = NSTextField(labelWithString: value)
        val.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        val.textColor = .secondaryLabelColor
        row.addControl(val)
        return row
    }
}

// MARK: - NSControl Helpers

private var actionKey: UInt8 = 0

extension NSControl {
    func onAction(_ block: @escaping (NSControl) -> Void) {
        let h = ActionHelper(block: block)
        objc_setAssociatedObject(self, &actionKey, h, .OBJC_ASSOCIATION_RETAIN)
        target = h; action = #selector(ActionHelper.invoke(_:))
    }
}

private class ActionHelper: NSObject {
    let block: (NSControl) -> Void
    init(block: @escaping (NSControl) -> Void) { self.block = block }
    @objc func invoke(_ s: NSControl) { block(s) }
}

private var textChangeKey: UInt8 = 0

extension NSTextField {
    func onTextChange(_ block: @escaping (String) -> Void) {
        let d = TextChangeDelegate(block: block)
        objc_setAssociatedObject(self, &textChangeKey, d, .OBJC_ASSOCIATION_RETAIN)
        delegate = d
    }
}

private class TextChangeDelegate: NSObject, NSTextFieldDelegate {
    let block: (String) -> Void
    init(block: @escaping (String) -> Void) { self.block = block }
    func controlTextDidChange(_ n: Notification) {
        (n.object as? NSTextField).map { block($0.stringValue) }
    }
}

private var textAreaDelegateKey: UInt8 = 0

private class TextAreaDelegate: NSObject, NSTextViewDelegate {
    let setter: (String) -> Void
    init(setter: @escaping (String) -> Void) { self.setter = setter }
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        setter(tv.string)
    }
}
