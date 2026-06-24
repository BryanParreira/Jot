import Foundation

class DebounceTimer {
    private var timer: Timer?
    private let delay: TimeInterval
    private let queue: DispatchQueue

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(action: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            action()
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    func updateDelay(_ ms: Int) -> DebounceTimer {
        return DebounceTimer(delay: Double(ms) / 1000.0, queue: queue)
    }
}
