import Cocoa

class ClipboardMonitor {
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0
    private var lastChangeDate: Date?
    private(set) var recentText: String?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkClipboard() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty,
              text.count < 500 else {
            return
        }

        recentText = text
        lastChangeDate = Date()
    }

    var hasRecentClipboard: Bool {
        guard let date = lastChangeDate else { return false }
        return Date().timeIntervalSince(date) < 60
    }
}
