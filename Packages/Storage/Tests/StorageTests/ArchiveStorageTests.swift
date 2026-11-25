import Core
import Foundation
import Testing
@testable import Storage

@Suite("Archive storage")
struct ArchiveStorageTests {
    let day1 = Date(timeIntervalSince1970: 1_790_000_000)
    let day2 = Date(timeIntervalSince1970: 1_790_086_400)

    func tab(_ title: String, url: String) -> TabRecord {
        TabRecord(spaceID: UUID(), url: URL(string: url), title: title, lastActiveAt: day1, sessionState: Data([7]))
    }

    @Test func archiveSearchAndUnarchive() async throws {
        let database = try AppDatabase.inMemory()
        let old = tab("Wau bulan", url: "https://en.wikipedia.org/wiki/Wau_bulan")
        let new = tab("Teh tarik", url: "https://example.com/teh")
        try await database.archive([old], at: day1)
        try await database.archive([new], at: day2)

        let recent = try database.recentArchivedTabs(limit: 10)
        #expect(recent.map(\.record.title) == ["Teh tarik", "Wau bulan"])
        #expect(recent.last == ArchivedTab(record: old, archivedAt: day1)) // keeps history and Space
        #expect(try database.archivedTabs(matching: ["wiki", "wau"]).map(\.id) == [old.id])

        try database.unarchive(id: old.id)
        #expect(try database.recentArchivedTabs(limit: 10).map(\.id) == [new.id])
        try database.clearArchive()
        #expect(try database.recentArchivedTabs(limit: 10).isEmpty)
    }

    @Test func spaceArchiveSettingIsSaved() throws {
        let database = try AppDatabase.inMemory()
        let space = SpaceRecord(name: "Work", icon: "💼", themeID: "melaka", archiveInterval: .month)
        try database.saveBrowser(BrowserSnapshot(spaces: [space], tabs: [], selectedSpaceID: space.id))
        #expect(try database.loadBrowser().spaces.first?.archiveInterval == .month)
    }
}

@Suite("Split storage")
struct SplitStorageTests {
    @Test func splitsRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        let space = SpaceRecord.makeDefault()
        let tabs = (0..<3).map { TabRecord(spaceID: space.id, url: URL(string: "https://\($0).example"), title: "\($0)",
                                           lastActiveAt: Date(timeIntervalSince1970: 1_790_000_000)) }
        let group = SplitGroup(tabIDs: tabs.map(\.id), axis: .vertical, fractions: [0.5, 0.25, 0.25])
        let snapshot = BrowserSnapshot(spaces: [space], tabs: tabs, selectedSpaceID: space.id, splits: [space.id: [group]])
        try database.saveBrowser(snapshot)
        #expect(try database.loadBrowser() == snapshot)
    }
}
