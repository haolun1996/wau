import Core
import Foundation
import Testing
@testable import Storage

@Suite("History storage")
struct HistoryTests {
    let day1 = Date(timeIntervalSince1970: 1_790_000_000)
    let day2 = Date(timeIntervalSince1970: 1_790_086_400)

    @Test func visitsCountUpAndKeepTitles() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://example.com/a")!
        try await database.recordVisit(url: url, title: "First", at: day1)
        try await database.recordVisit(url: url, title: "", at: day2) // empty title keeps "First"

        let entries = try database.recentHistory(limit: 10)
        #expect(entries == [HistoryEntry(url: url, title: "First", visitCount: 2, lastVisitedAt: day2)])

        try await database.updateHistoryTitle(url: url, title: "Final")
        #expect(try database.recentHistory(limit: 1).first?.title == "Final")
    }

    @Test func candidatesMatchEveryTokenInURLOrTitle() async throws {
        let database = try AppDatabase.inMemory()
        try await database.recordVisit(url: URL(string: "https://en.wikipedia.org/wiki/Wau_bulan")!, title: "Wau bulan", at: day1)
        try await database.recordVisit(url: URL(string: "https://github.com")!, title: "GitHub", at: day2)

        #expect(try database.historyCandidates(matching: ["wiki", "wau"]).map(\.title) == ["Wau bulan"])
        #expect(try database.historyCandidates(matching: ["GITHUB"]).map(\.title) == ["GitHub"]) // case-insensitive
        #expect(try database.historyCandidates(matching: []).isEmpty)
    }

    @Test func likeWildcardsAreLiteral() async throws {
        let database = try AppDatabase.inMemory()
        try await database.recordVisit(url: URL(string: "https://a.com/100%25")!, title: "100% done", at: day1)
        try await database.recordVisit(url: URL(string: "https://b.com")!, title: "Plain", at: day1)
        try await database.recordVisit(url: URL(string: "https://c.com/a_b")!, title: "Underscore", at: day1)

        #expect(try database.historyCandidates(matching: ["%"]).map(\.title) == ["100% done"])
        #expect(try database.historyCandidates(matching: ["_"]).map(\.title) == ["Underscore"])
    }

    @Test func recentHistoryIsNewestFirstAndClearable() async throws {
        let database = try AppDatabase.inMemory()
        try await database.recordVisit(url: URL(string: "https://old.com")!, title: "Old", at: day1)
        try await database.recordVisit(url: URL(string: "https://new.com")!, title: "New", at: day2)
        #expect(try database.recentHistory(limit: 10).map(\.title) == ["New", "Old"])

        try database.clearHistory()
        #expect(try database.recentHistory(limit: 10).isEmpty)
    }
}

@Suite("Sync state storage")
struct SyncStateStorageTests {
    @Test func valuesRoundTripAndClear() throws {
        let database = try AppDatabase.inMemory()
        #expect(try database.syncValue(forKey: "state") == nil)
        try database.setSyncValue(Data([1, 2]), forKey: "state")
        try database.setSyncValue(Data([3]), forKey: "state")
        #expect(try database.syncValue(forKey: "state") == Data([3]))
        try database.setSyncValue(nil, forKey: "state")
        #expect(try database.syncValue(forKey: "state") == nil)
    }
}
