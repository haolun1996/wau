import Foundation

/// One visited page.
public struct HistoryEntry: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var lastVisitedAt: Date

    public init(url: URL, title: String, visitCount: Int, lastVisitedAt: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }
}

/// Ranks history for the command bar by "frecency": pages visited often and
/// recently come first, as in Firefox's address bar.
public enum HistoryRanking {
    public static func frecency(visitCount: Int, lastVisitedAt: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(lastVisitedAt) / 86_400)
        let recency: Double = switch days {
        case ..<4: 100
        case ..<14: 70
        case ..<31: 50
        case ..<90: 30
        default: 10
        }
        return Double(max(1, visitCount)) * recency
    }

    /// Entries matching every word of `query` (in the URL or title), best first.
    public static func rank(_ entries: [HistoryEntry], query: String, now: Date = Date()) -> [HistoryEntry] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let scored: [(HistoryEntry, Double)] = entries.compactMap { entry in
            let address = displayAddress(entry.url)
            let title = entry.title.lowercased()
            guard tokens.allSatisfy({ address.contains($0) || title.contains($0) }) else { return nil }

            let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let bonus: Double
            if address.hasPrefix(tokens[0]) {
                bonus = 8 // typing the start of a domain is a strong signal
            } else if tokens.allSatisfy({ token in titleWords.contains { $0.hasPrefix(token) } }) {
                bonus = 2
            } else {
                bonus = 1
            }
            let score = frecency(visitCount: entry.visitCount, lastVisitedAt: entry.lastVisitedAt, now: now) * bonus
            return (entry, score)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastVisitedAt > $1.0.lastVisitedAt }
            .map(\.0)
    }

    /// `https://www.example.com/a` → `example.com/a`, lowercased.
    public static func displayAddress(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }
}
