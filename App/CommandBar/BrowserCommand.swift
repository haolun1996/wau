import Core

/// An action offered in the command bar, such as "Reload Page" or "Theme: Langkawi".
struct BrowserCommand {
    let title: String
    /// SF Symbol shown beside the title.
    let symbol: String
    /// Keyboard shortcut shown on the right, e.g. "⇧⌘T".
    var shortcut: String?
    /// Extra words that should find this command ("colour" → themes).
    var keywords: [String] = []
    let run: @MainActor () -> Void

    /// How well `query` matches the title or a keyword, or nil when it
    /// doesn't match well enough to show. Scattered single letters don't count.
    func score(for query: String) -> Int? {
        let length = query.filter { !$0.isWhitespace }.count
        guard length >= 2 else { return nil }
        let best = ([title] + keywords).compactMap { FuzzyMatch.score(query, in: $0) }.max()
        guard let best, best >= length * 4 else { return nil }
        return best
    }
}
