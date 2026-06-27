import Foundation

class PersonalizationStore {
    static let shared = PersonalizationStore()

    private let acceptedHistoryKey  = "personalization_acceptedHistory"
    private let vocabularyKey       = "personalization_vocabulary"
    private let bigramsKey          = "personalization_bigrams"
    private let maxHistorySize      = 200  // trimmed from 500 — negligible accuracy loss, less RAM

    private(set) var acceptedHistory: [String] = []
    private(set) var vocabularyFrequency: [String: Int] = [:]
    private(set) var bigramFrequency: [String: Int] = [:]  // "word1 word2" → count

    private init() { load() }

    private func load() {
        acceptedHistory     = UserDefaults.standard.stringArray(forKey: acceptedHistoryKey) ?? []
        vocabularyFrequency = UserDefaults.standard.dictionary(forKey: vocabularyKey) as? [String: Int] ?? [:]
        bigramFrequency     = UserDefaults.standard.dictionary(forKey: bigramsKey) as? [String: Int] ?? [:]
    }

    private func save() {
        UserDefaults.standard.set(acceptedHistory, forKey: acceptedHistoryKey)
        UserDefaults.standard.set(vocabularyFrequency, forKey: vocabularyKey)
        UserDefaults.standard.set(bigramFrequency, forKey: bigramsKey)
    }

    func recordAccepted(_ text: String) {
        acceptedHistory.append(text)
        if acceptedHistory.count > maxHistorySize {
            acceptedHistory.removeFirst(acceptedHistory.count - maxHistorySize)
        }

        let tokens = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { $0.count >= 3 }

        let meaningful = tokens.filter { !Self.stopWords.contains($0) && $0.count >= 4 }
        for word in meaningful {
            vocabularyFrequency[word, default: 0] += 1
        }

        // Bigram tracking: "word1 word2" captures phrase-level style
        let bigramTokens = tokens.filter { $0.count >= 3 }
        guard bigramTokens.count >= 2 else { save(); return }
        for i in 0..<(bigramTokens.count - 1) {
            let bigram = "\(bigramTokens[i]) \(bigramTokens[i + 1])"
            bigramFrequency[bigram, default: 0] += 1
        }

        // Prune low-frequency bigrams when dict grows large (keeps RAM bounded)
        if bigramFrequency.count > 400 {
            bigramFrequency = bigramFrequency.filter { $0.value >= 2 }
        }

        save()
    }

    func isKnownTerm(_ word: String) -> Bool {
        vocabularyFrequency[word.lowercased(), default: 0] > 0
    }

    /// Random sample of recent accepted completions, limited by token budget.
    /// Used to show the model the user's writing style and preferred phrasing.
    func historySample(tokenBudget: Int) -> String {
        guard !acceptedHistory.isEmpty else { return "" }

        // Weight toward recency: take last 60% preferentially, random-shuffle rest
        let recentCount = max(1, acceptedHistory.count * 60 / 100)
        let recent  = Array(acceptedHistory.suffix(recentCount))
        let older   = Array(acceptedHistory.dropLast(recentCount)).shuffled()
        let ordered = recent + older

        var samples: [String] = []
        var budget = tokenBudget
        for item in ordered {
            let cost = item.count / 4
            guard budget - cost >= 0 else { break }
            samples.append(item)
            budget -= cost
        }
        return samples.joined(separator: " · ")
    }

    /// Top single-word terms the user writes frequently.
    func topTerms(n: Int) -> [String] {
        vocabularyFrequency
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { $0.key }
    }

    /// Top two-word phrases the user writes frequently — more expressive than single words.
    func topPhrases(n: Int) -> [String] {
        bigramFrequency
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { $0.key }
    }

    var historyCount: Int { acceptedHistory.count }
    var uniqueTermsCount: Int { vocabularyFrequency.filter { $0.value >= 2 }.count }

    func clearAll() {
        acceptedHistory     = []
        vocabularyFrequency = [:]
        bigramFrequency     = [:]
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
