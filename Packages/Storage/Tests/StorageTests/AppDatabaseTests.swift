import Core
import Foundation
import GRDB
import Testing
@testable import Storage

@Suite("AppDatabase")
struct AppDatabaseTests {
    // Whole seconds: the database stores milliseconds.
    let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func tab(_ title: String, _ url: String?, space: UUID?, pinned: Bool = false, state: Data? = nil) -> TabRecord {
        TabRecord(
            spaceID: space,
            isPinned: pinned,
            pinnedURL: pinned ? url.flatMap(URL.init(string:)) : nil,
            url: url.flatMap(URL.init(string:)),
            title: title,
            lastActiveAt: date,
            sessionState: state
        )
    }

    @Test func emptyDatabaseHasEmptyBrowser() throws {
        let database = try AppDatabase.inMemory()
        #expect(try database.loadBrowser() == BrowserSnapshot())
    }

    @Test func browserRoundTripKeepsSpacesTabsAndSelection() throws {
        let database = try AppDatabase.inMemory()
        let work = SpaceRecord(name: "Work", icon: "💼", themeID: "melaka", profileID: UUID())
        let home = SpaceRecord(name: "Home", icon: "🪁", themeID: "langkawi")
        let tabs = [
            tab("Mail", "https://mail.example.com", space: nil), // favorite
            tab("Docs", "https://docs.example.com", space: work.id, pinned: true),
            tab("Wau bulan", "https://en.wikipedia.org/wiki/Wau_bulan", space: work.id, state: Data([1, 2, 3])),
            tab("Blank", nil, space: home.id),
        ]
        var workSelected = work
        workSelected.selectedTabID = tabs[2].id
        let snapshot = BrowserSnapshot(spaces: [workSelected, home], tabs: tabs, selectedSpaceID: home.id)

        try database.saveBrowser(snapshot)
        #expect(try database.loadBrowser() == snapshot)
    }

    @Test func savingReplacesThePreviousState() async throws {
        let database = try AppDatabase.inMemory()
        let space = SpaceRecord.makeDefault()
        try await database.saveBrowser(BrowserSnapshot(
            spaces: [space],
            tabs: [tab("A", "https://a.com", space: space.id), tab("B", "https://b.com", space: space.id)],
            selectedSpaceID: space.id
        ))
        let other = SpaceRecord(name: "Other", icon: "🌙", themeID: "bulan")
        let replacement = BrowserSnapshot(spaces: [other], tabs: [tab("C", "https://c.com", space: other.id)])
        try await database.saveBrowser(replacement)
        #expect(try database.loadBrowser() == replacement)
    }

    /// Tabs saved by the pre-Spaces version end up in one "Personal" Space.
    @Test func migrationMovesOldTabsIntoAFirstSpace() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2: history")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tab (id, position, url, title, lastActiveAt) VALUES
                ('11111111-1111-1111-1111-111111111111', 0, 'https://a.com', 'A', '2026-11-25 00:00:00.000'),
                ('22222222-2222-2222-2222-222222222222', 1, 'https://b.com', 'B', '2026-11-25 00:00:00.000');
                INSERT INTO appState (key, value) VALUES ('selectedTabID', '22222222-2222-2222-2222-222222222222');
                """)
        }

        let browser = try AppDatabase(queue).loadBrowser()
        #expect(browser.spaces.count == 1)
        let space = try #require(browser.spaces.first)
        #expect(space.name == "Personal")
        #expect(space.selectedTabID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(browser.selectedSpaceID == space.id)
        #expect(browser.tabs.map(\.title) == ["A", "B"])
        #expect(browser.tabs.allSatisfy { $0.spaceID == space.id && !$0.isPinned })
    }

    @Test func faviconsUpsertByHost() throws {
        let database = try AppDatabase.inMemory()
        #expect(try database.favicon(host: "example.com") == nil)
        try database.saveFavicon(host: "example.com", png: Data([1]))
        try database.saveFavicon(host: "example.com", png: Data([2]))
        #expect(try database.favicon(host: "example.com") == Data([2]))
    }

    @Test func reopeningAFileKeepsData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("wau.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let space = SpaceRecord.makeDefault()
        let snapshot = BrowserSnapshot(spaces: [space], tabs: [tab("Kept", "https://kept.example", space: space.id)], selectedSpaceID: space.id)
        try AppDatabase.open(at: url).saveBrowser(snapshot)
        // Opening again runs migrations again; they must be idempotent.
        #expect(try AppDatabase.open(at: url).loadBrowser() == snapshot)
    }
}
