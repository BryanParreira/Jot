import Foundation

// MidLineCompletion logic is integrated into ContextBuilder and CompletionEngine.
// This file provides utilities for detecting and handling mid-line context.

struct MidLineCompletion {

    static func isMidLine(textAfter: String?) -> Bool {
        guard let after = textAfter, !after.isEmpty else { return false }
        return !after.hasPrefix("\n") && !after.hasPrefix("\r")
    }

    static func trimSuffix(_ text: String, maxChars: Int = 200) -> String {
        return String(text.prefix(maxChars))
    }
}
