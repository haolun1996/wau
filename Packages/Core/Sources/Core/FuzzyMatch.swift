import Foundation

/// Subsequence matching for short labels like command names:
/// "tgsb" matches "Toggle Sidebar".
public enum FuzzyMatch {
    /// A score (higher is better) if every non-space character of `query`
    /// appears in `text` in order, or nil if it doesn't match.
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(text)
        let haystack = Array(text.lowercased())
        // Case mapping can change length for a few scripts; skip the camel-case bonus then.
        let canCheckCase = original.count == haystack.count

        var score = 0
        var next = 0
        var previousMatch = -2
        for (index, character) in haystack.enumerated() where next < needle.count {
            guard character == needle[next] else { continue }
            var points = 1
            if index == previousMatch + 1 { points += 5 } // runs of letters
            if index == 0 || !(haystack[index - 1].isLetter || haystack[index - 1].isNumber) {
                points += 8 // start of a word
            } else if canCheckCase, original[index].isUppercase, original[index - 1].isLowercase {
                points += 6 // camelCase hump
            }
            score += points
            previousMatch = index
            next += 1
        }
        guard next == needle.count else { return nil }
        return score - haystack.count / 10 // prefer shorter labels
    }
}
