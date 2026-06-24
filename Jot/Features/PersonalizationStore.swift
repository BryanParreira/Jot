import Foundation

class PersonalizationStore {
    static let shared = PersonalizationStore()

    private let acceptedHistoryKey = "personalization_acceptedHistory"
    private let vocabularyKey = "personalization_vocabulary"
    private let maxHistorySize = 500

    private(set) var acceptedHistory: [String] = []
    private(set) var vocabularyFrequency: [String: Int] = [:]

    private init() {
        load()
    }

    private func load() {
        acceptedHistory = UserDefaults.standard.stringArray(forKey: acceptedHistoryKey) ?? []
        vocabularyFrequency = UserDefaults.standard.dictionary(forKey: vocabularyKey) as? [String: Int] ?? [:]
    }

    private func save() {
        UserDefaults.standard.set(acceptedHistory, forKey: acceptedHistoryKey)
        UserDefaults.standard.set(vocabularyFrequency, forKey: vocabularyKey)
    }

    func recordAccepted(_ text: String) {
        acceptedHistory.append(text)
        if acceptedHistory.count > maxHistorySize {
            acceptedHistory.removeFirst(acceptedHistory.count - maxHistorySize)
        }

        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { $0.count >= 4 && !Self.stopWords.contains($0) }

        for word in words {
            vocabularyFrequency[word, default: 0] += 1
        }

        save()
    }

    func isKnownTerm(_ word: String) -> Bool {
        return vocabularyFrequency[word.lowercased(), default: 0] > 0
    }

    func historySample(tokenBudget: Int) -> String {
        guard !acceptedHistory.isEmpty else { return "" }

        var samples: [String] = []
        var budget = tokenBudget
        var indices = Array(0..<acceptedHistory.count)
        indices.shuffle()

        for idx in indices {
            let item = acceptedHistory[idx]
            let cost = item.count / 4
            if budget - cost < 0 { break }
            samples.append(item)
            budget -= cost
        }

        return samples.joined(separator: "\n")
    }

    func topTerms(n: Int) -> [String] {
        return vocabularyFrequency
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { $0.key }
    }

    func clearAll() {
        acceptedHistory = []
        vocabularyFrequency = [:]
        save()
    }

    private static let stopWords: Set<String> = [
        "this", "that", "with", "from", "they", "them", "their", "then",
        "than", "when", "what", "which", "will", "have", "been", "were",
        "said", "each", "some", "your", "more", "also", "into", "over",
        "just", "like", "time", "very", "even", "back", "only", "come",
        "could", "would", "should", "there", "these", "those", "other",
        "about", "after", "before", "while", "where", "here"
    ]
}
