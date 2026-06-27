import Foundation

/// Decides whether the first generated token should be constrained to continue
/// the word in progress (no leading whitespace).
///
/// Only fires when the caret sits strictly inside a word — a word character on
/// both sides. At a word end it returns false so the model generates the next
/// word naturally with its own leading space.
enum MidWordContinuationPolicy {
    static func shouldForceContinuation(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else {
            return false
        }
        guard let after = trailingText.first, isWordCharacter(after) else {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
