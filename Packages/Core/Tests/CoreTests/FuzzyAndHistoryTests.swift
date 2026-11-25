import Foundation
import Testing
@testable import Core

@Suite("FuzzyMatch")
struct FuzzyMatchTests {
    @Test func subsequencesMatchAndOthersDont() {
        #expect(FuzzyMatch.score("tgsb", in: "Toggle Sidebar") != nil)
        #expect(FuzzyMatch.score("reload", in: "Reload Page") != nil)
        #expect(FuzzyMatch.score("xyz", in: "Reload Page") == nil)
        #expect(FuzzyMatch.score("pager", in: "Reload Page") == nil) // order matters
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }

    @Test func wordStartsBeatScatteredLetters() throws {
        let initials = try #require(FuzzyMatch.score("cl", in: "Close Tab · Langkawi"))
        let prefix = try #require(FuzzyMatch.score("cl", in: "Clear History"))
        let scattered = try #require(FuzzyMatch.score("cl", in: "Reload All Tabs Locally"))
        #expect(prefix > scattered)
        #expect(initials > scattered)
    }

    @Test func caseAndSpacesAreIgnored() {
        #expect(FuzzyMatch.score("TOGGLE side", in: "Toggle Sidebar") != nil)
    }
}

@Suite("HistoryRanking")
struct HistoryRankingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ url: String, _ title: String, visits: Int, daysAgo: Double) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: visits, lastVisitedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func frecencyFavoursRecentAndFrequent() {
        let recent = HistoryRanking.frecency(visitCount: 1, lastVisitedAt: now, now: now)
        let old = HistoryRanking.frecency(visitCount: 1, lastVisitedAt: now.addingTimeInterval(-200 * 86_400), now: now)
        let frequentOld = HistoryRanking.frecency(visitCount: 20, lastVisitedAt: now.addingTimeInterval(-200 * 86_400), now: now)
        #expect(recent > old)
        #expect(frequentOld > recent)
    }

    @Test func everyWordMustMatchURLOrTitle() {
        let entries = [
            entry("https://en.wikipedia.org/wiki/Wau_bulan", "Wau bulan - Wikipedia", visits: 1, daysAgo: 1),
            entry("https://github.com", "GitHub", visits: 1, daysAgo: 1),
        ]
        #expect(HistoryRanking.rank(entries, query: "wau wiki", now: now).map(\.title) == ["Wau bulan - Wikipedia"])
        #expect(HistoryRanking.rank(entries, query: "nothing", now: now).isEmpty)
        #expect(HistoryRanking.rank(entries, query: "  ", now: now).isEmpty)
    }

    @Test func domainPrefixOutranksMoreVisitedMidStringMatch() {
        let entries = [
            entry("https://news.example.com/github-story", "A story about GitHub", visits: 3, daysAgo: 1),
            entry("https://www.github.com/", "GitHub", visits: 1, daysAgo: 1),
        ]
        #expect(HistoryRanking.rank(entries, query: "git", now: now).first?.title == "GitHub")
    }

    @Test func displayAddressDropsSchemeAndWWW() {
        #expect(HistoryRanking.displayAddress(URL(string: "https://www.Example.com/A")!) == "example.com/a")
        #expect(HistoryRanking.displayAddress(URL(string: "http://localhost:3000")!) == "localhost:3000")
    }
}
