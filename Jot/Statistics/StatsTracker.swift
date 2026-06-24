import Foundation

class StatsTracker {
    static let shared = StatsTracker()

    private var midnightTimer: Timer?
    private let todayKey: String

    private init() {
        todayKey = Self.dateKey(for: Date())
        scheduleMidnightReset()
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return SettingsKeys.statsDailyPrefix + formatter.string(from: date)
    }

    // MARK: - Recording
    func recordAccepted(text: String) {
        let words = max(1, text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count)

        let allTimeAccepted = UserDefaults.standard.integer(forKey: SettingsKeys.statsAcceptedAllTime)
        UserDefaults.standard.set(allTimeAccepted + 1, forKey: SettingsKeys.statsAcceptedAllTime)

        let allTimeWords = UserDefaults.standard.integer(forKey: SettingsKeys.statsWordsSavedAllTime)
        UserDefaults.standard.set(allTimeWords + words, forKey: SettingsKeys.statsWordsSavedAllTime)

        var daily = dailyData()
        daily["accepted"] = (daily["accepted"] ?? 0) + 1
        daily["wordsSaved"] = (daily["wordsSaved"] ?? 0) + words
        saveDailyData(daily)
    }

    func recordLatency(_ ms: Int) {
        var samples = UserDefaults.standard.array(forKey: SettingsKeys.statsLatencySamples) as? [Int] ?? []
        samples.append(ms)
        if samples.count > 100 { samples.removeFirst(samples.count - 100) }
        UserDefaults.standard.set(samples, forKey: SettingsKeys.statsLatencySamples)
    }

    // MARK: - Reading
    var totalAcceptedAllTime: Int {
        UserDefaults.standard.integer(forKey: SettingsKeys.statsAcceptedAllTime)
    }

    var totalAcceptedToday: Int {
        dailyData()["accepted"] ?? 0
    }

    var totalWordsSavedAllTime: Int {
        UserDefaults.standard.integer(forKey: SettingsKeys.statsWordsSavedAllTime)
    }

    var totalWordsSavedToday: Int {
        dailyData()["wordsSaved"] ?? 0
    }

    var averageLatencyMs: Double {
        let samples = UserDefaults.standard.array(forKey: SettingsKeys.statsLatencySamples) as? [Int] ?? []
        guard !samples.isEmpty else { return 0 }
        return Double(samples.reduce(0, +)) / Double(samples.count)
    }

    // MARK: - Reset
    func reset() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.statsAcceptedAllTime)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.statsWordsSavedAllTime)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.statsLatencySamples)
        saveDailyData([:])
    }

    // MARK: - Daily data
    private func dailyData() -> [String: Int] {
        let key = Self.dateKey(for: Date())
        return UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    private func saveDailyData(_ data: [String: Int]) {
        let key = Self.dateKey(for: Date())
        UserDefaults.standard.set(data, forKey: key)
    }

    private func scheduleMidnightReset() {
        let cal = Calendar.current
        guard let tomorrow = cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else { return }
        let interval = tomorrow.timeIntervalSinceNow
        midnightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.scheduleMidnightReset()
        }
    }
}
