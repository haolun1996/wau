import Core
import Foundation
import GRDB

/// Wau's local SQLite database: the source of truth for Spaces, tabs, history and favicons
/// (and later Spaces, history and Easels, which sync to Google Drive).
public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter

    /// Wraps an open database and brings its schema up to date.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database file at `url`.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(DatabasePool(path: url.path))
    }

    /// A throwaway database for tests and as a fallback when the file can't be opened.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1: tabs, app state, favicons") { db in
            try db.create(table: "tab") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.column("url", .text)
                t.column("title", .text).notNull()
                t.column("lastActiveAt", .datetime).notNull()
                t.column("sessionState", .blob)
            }
            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "favicon") { t in
                t.primaryKey("host", .text)
                t.column("png", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2: history") { db in
            try db.create(table: "history") { t in
                t.primaryKey("url", .text)
                t.column("title", .text).notNull()
                t.column("visitCount", .integer).notNull()
                t.column("firstVisitedAt", .datetime).notNull()
                t.column("lastVisitedAt", .datetime).notNull().indexed()
            }
        }
        migrator.registerMigration("v3: spaces") { db in
            try db.create(table: "space") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull()
                t.column("themeID", .text).notNull()
                t.column("profileID", .text)
                t.column("selectedTabID", .text)
            }
            try db.alter(table: "tab") { t in
                t.add(column: "spaceID", .text)
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
                t.add(column: "pinnedURL", .text)
            }
            // Tabs saved before Spaces existed move into a first Space,
            // keeping the tab that was selected.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab") ?? 0 > 0 else { return }
            // Values are spelled out so this migration never changes.
            let spaceID = UUID().uuidString
            let selectedTab = try String.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'selectedTabID'")
            try db.execute(
                sql: "INSERT INTO space (id, position, name, icon, themeID, selectedTabID) VALUES (?, 0, 'Personal', '🪁', 'bulan', ?)",
                arguments: [spaceID, selectedTab]
            )
            try db.execute(sql: "UPDATE tab SET spaceID = ?", arguments: [spaceID])
            try db.execute(
                sql: "INSERT OR REPLACE INTO appState (key, value) VALUES ('selectedSpaceID', ?)",
                arguments: [spaceID]
            )
            try db.execute(sql: "DELETE FROM appState WHERE key = 'selectedTabID'")
        }
        migrator.registerMigration("v4: sync state") { db in
            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }
        migrator.registerMigration("v5: archive") { db in
            try db.alter(table: "space") { t in
                t.add(column: "archiveInterval", .text).notNull().defaults(to: "12h")
            }
            try db.create(table: "archivedTab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text)
                t.column("url", .text)
                t.column("title", .text).notNull()
                t.column("lastActiveAt", .datetime).notNull()
                t.column("archivedAt", .datetime).notNull().indexed()
                t.column("sessionState", .blob)
            }
        }
        migrator.registerMigration("v6: split view") { db in
            try db.create(table: "split") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("axis", .text).notNull()
                // Comma-separated tab UUIDs and pane fractions, in order.
                t.column("tabIDs", .text).notNull()
                t.column("fractions", .text).notNull()
            }
        }
        migrator.registerMigration("v7: easels") { db in
            try db.create(table: "easel") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "easelItem") { t in
                t.primaryKey("id", .text)
                t.column("easelID", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("z", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("url", .text)
                t.column("imageHash", .text)
            }
        }
        migrator.registerMigration("v8: easel drawings") { db in
            // Arrow ends and freehand strokes, as `EaselPoint.encode` writes them.
            try db.alter(table: "easelItem") { t in
                t.add(column: "points", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v9: label sizes") { db in
            // Null means the label's text fills its box.
            try db.alter(table: "easelItem") { t in
                t.add(column: "fontSize", .double)
            }
        }
        migrator.registerMigration("v10: item colours") { db in
            // `#RRGGBB`; null is the usual text colour.
            try db.alter(table: "easelItem") { t in
                t.add(column: "color", .text)
            }
        }
        migrator.registerMigration("v11: easel order") { db in
            try db.alter(table: "easel") { t in
                t.add(column: "position", .integer).notNull().defaults(to: 0)
            }
        }
        return migrator
    }

    // MARK: Browser state (Spaces and tabs)

    private static let selectedSpaceKey = "selectedSpaceID"

    /// Replaces the saved Spaces and tabs with `snapshot`.
    public func saveBrowser(_ snapshot: BrowserSnapshot) throws {
        try writer.write { db in try Self.write(snapshot, to: db) }
    }

    /// Same as `saveBrowser(_:)`, without blocking the caller.
    public func saveBrowser(_ snapshot: BrowserSnapshot) async throws {
        try await writer.write { db in try Self.write(snapshot, to: db) }
    }

    public func loadBrowser() throws -> BrowserSnapshot {
        try writer.read { db in
            let spaces = try Row.fetchAll(db, sql: "SELECT * FROM space ORDER BY position").compactMap { row -> SpaceRecord? in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return SpaceRecord(
                    id: id,
                    name: row["name"],
                    icon: row["icon"],
                    themeID: row["themeID"],
                    profileID: (row["profileID"] as String?).flatMap(UUID.init(uuidString:)),
                    selectedTabID: (row["selectedTabID"] as String?).flatMap(UUID.init(uuidString:)),
                    archiveInterval: ArchiveInterval(rawValue: row["archiveInterval"]) ?? .default
                )
            }
            let tabs = try Row.fetchAll(db, sql: "SELECT * FROM tab ORDER BY position").compactMap { row -> TabRecord? in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return TabRecord(
                    id: id,
                    spaceID: (row["spaceID"] as String?).flatMap(UUID.init(uuidString:)),
                    isPinned: row["isPinned"],
                    pinnedURL: (row["pinnedURL"] as String?).flatMap(URL.init(string:)),
                    url: (row["url"] as String?).flatMap(URL.init(string:)),
                    title: row["title"],
                    lastActiveAt: row["lastActiveAt"],
                    sessionState: row["sessionState"]
                )
            }
            let selected = try String.fetchOne(
                db, sql: "SELECT value FROM appState WHERE key = ?", arguments: [Self.selectedSpaceKey]
            ).flatMap(UUID.init(uuidString:))
            var splits: [UUID: [SplitGroup]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM split ORDER BY position") {
                guard let id = UUID(uuidString: row["id"]), let spaceID = UUID(uuidString: row["spaceID"]) else { continue }
                let tabIDs = (row["tabIDs"] as String).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                let fractions = (row["fractions"] as String).split(separator: ",").compactMap { Double(String($0)) }
                let group = SplitGroup(id: id, tabIDs: tabIDs, axis: SplitAxis(rawValue: row["axis"]) ?? .horizontal, fractions: fractions)
                if group.isValid { splits[spaceID, default: []].append(group) }
            }
            return BrowserSnapshot(spaces: spaces, tabs: tabs, selectedSpaceID: selected, splits: splits)
        }
    }

    private static func write(_ snapshot: BrowserSnapshot, to db: Database) throws {
        try db.execute(sql: "DELETE FROM space")
        for (position, space) in snapshot.spaces.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO space (id, position, name, icon, themeID, profileID, selectedTabID, archiveInterval)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    space.id.uuidString, position, space.name, space.icon, space.themeID,
                    space.profileID?.uuidString, space.selectedTabID?.uuidString, space.archiveInterval.rawValue,
                ]
            )
        }
        try db.execute(sql: "DELETE FROM tab")
        for (position, tab) in snapshot.tabs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO tab (id, position, spaceID, isPinned, pinnedURL, url, title, lastActiveAt, sessionState)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    tab.id.uuidString, position, tab.spaceID?.uuidString, tab.isPinned,
                    tab.pinnedURL?.absoluteString, tab.url?.absoluteString, tab.title,
                    tab.lastActiveAt, tab.sessionState,
                ]
            )
        }
        try db.execute(sql: "DELETE FROM split")
        var position = 0
        for (spaceID, groups) in snapshot.splits.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for group in groups {
                try db.execute(
                    sql: "INSERT INTO split (id, spaceID, position, axis, tabIDs, fractions) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [
                        group.id.uuidString, spaceID.uuidString, position, group.axis.rawValue,
                        group.tabIDs.map(\.uuidString).joined(separator: ","),
                        group.fractions.map { String($0) }.joined(separator: ","),
                    ]
                )
                position += 1
            }
        }
        if let selected = snapshot.selectedSpaceID {
            try db.execute(
                sql: "INSERT OR REPLACE INTO appState (key, value) VALUES (?, ?)",
                arguments: [selectedSpaceKey, selected.uuidString]
            )
        } else {
            try db.execute(sql: "DELETE FROM appState WHERE key = ?", arguments: [selectedSpaceKey])
        }
    }

    // MARK: Favicons

    public func saveFavicon(host: String, png: Data) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO favicon (host, png, updatedAt) VALUES (?, ?, ?)",
                arguments: [host, png, Date()]
            )
        }
    }

    public func favicon(host: String) throws -> Data? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT png FROM favicon WHERE host = ?", arguments: [host])
        }
    }

    // MARK: History

    /// Counts a visit to `url`. An empty `title` keeps the one already stored.
    public func recordVisit(url: URL, title: String, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO history (url, title, visitCount, firstVisitedAt, lastVisitedAt)
                VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visitCount = visitCount + 1,
                    lastVisitedAt = excluded.lastVisitedAt,
                    title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END
                """,
                arguments: [url.absoluteString, title, date, date]
            )
        }
    }

    /// Pages often get their final title after loading finishes.
    public func updateHistoryTitle(url: URL, title: String) async throws {
        guard !title.isEmpty else { return }
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE history SET title = ? WHERE url = ?",
                arguments: [title, url.absoluteString]
            )
        }
    }

    /// Recent entries whose URL or title contains every token; the caller
    /// ranks them (see `HistoryRanking`).
    public func historyCandidates(matching tokens: [String], limit: Int = 200) throws -> [HistoryEntry] {
        let tokens = tokens.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let clause = Array(repeating: "(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')", count: tokens.count)
            .joined(separator: " AND ")
        var arguments: [String] = []
        for token in tokens {
            let pattern = "%" + Self.escapeLike(token) + "%"
            arguments += [pattern, pattern]
        }
        return try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM history WHERE \(clause) ORDER BY lastVisitedAt DESC LIMIT \(limit)",
                arguments: StatementArguments(arguments)
            ).compactMap(Self.historyEntry)
        }
    }

    public func recentHistory(limit: Int) throws -> [HistoryEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM history ORDER BY lastVisitedAt DESC LIMIT ?", arguments: [limit])
                .compactMap(Self.historyEntry)
        }
    }

    public func clearHistory() throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM history") }
    }

    private static func historyEntry(_ row: Row) -> HistoryEntry? {
        guard let url = URL(string: row["url"]) else { return nil }
        return HistoryEntry(url: url, title: row["title"], visitCount: row["visitCount"], lastVisitedAt: row["lastVisitedAt"])
    }

    /// LIKE treats `%` and `_` as wildcards; match them literally.
    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Sync state

    /// Small blobs the sync engine keeps between runs (its last merged copy).
    public func syncValue(forKey key: String) throws -> Data? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key])
        }
    }

    public func setSyncValue(_ value: Data?, forKey key: String) throws {
        try writer.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: Archived tabs

    /// Keeps at most this many archived tabs; the oldest are dropped.
    static let archiveLimit = 1000

    public func archive(_ tabs: [TabRecord], at date: Date = Date()) async throws {
        guard !tabs.isEmpty else { return }
        try await writer.write { db in
            for tab in tabs {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO archivedTab (id, spaceID, url, title, lastActiveAt, archivedAt, sessionState)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [tab.id.uuidString, tab.spaceID?.uuidString, tab.url?.absoluteString,
                                tab.title, tab.lastActiveAt, date, tab.sessionState]
                )
            }
            try db.execute(
                sql: "DELETE FROM archivedTab WHERE id NOT IN (SELECT id FROM archivedTab ORDER BY archivedAt DESC LIMIT ?)",
                arguments: [Self.archiveLimit]
            )
        }
    }

    public func recentArchivedTabs(limit: Int) throws -> [ArchivedTab] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM archivedTab ORDER BY archivedAt DESC LIMIT ?", arguments: [limit])
                .compactMap(Self.archivedTab)
        }
    }

    /// Archived tabs whose URL or title contains every token, newest first.
    public func archivedTabs(matching tokens: [String], limit: Int = 50) throws -> [ArchivedTab] {
        let tokens = tokens.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let clause = Array(repeating: "(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')", count: tokens.count)
            .joined(separator: " AND ")
        let arguments = tokens.flatMap { token -> [String] in
            let pattern = "%" + Self.escapeLike(token) + "%"
            return [pattern, pattern]
        }
        return try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM archivedTab WHERE \(clause) ORDER BY archivedAt DESC LIMIT \(limit)",
                arguments: StatementArguments(arguments)
            ).compactMap(Self.archivedTab)
        }
    }

    /// Removes a tab from the archive (when it's brought back).
    public func unarchive(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM archivedTab WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func clearArchive() throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM archivedTab") }
    }

    private static func archivedTab(_ row: Row) -> ArchivedTab? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let record = TabRecord(
            id: id,
            spaceID: (row["spaceID"] as String?).flatMap(UUID.init(uuidString:)),
            url: (row["url"] as String?).flatMap(URL.init(string:)),
            title: row["title"],
            lastActiveAt: row["lastActiveAt"],
            sessionState: row["sessionState"]
        )
        return ArchivedTab(record: record, archivedAt: row["archivedAt"])
    }

    // MARK: Easels

    public func loadEasels() throws -> EaselSnapshot {
        try writer.read { db in
            let easels = try Row.fetchAll(db, sql: "SELECT * FROM easel ORDER BY createdAt").compactMap { row -> Easel? in
                guard let id = UUID(uuidString: row["id"]), let space = UUID(uuidString: row["spaceID"]) else { return nil }
                return Easel(id: id, spaceID: space, title: row["title"], createdAt: row["createdAt"], position: row["position"])
            }
            let items = try Row.fetchAll(db, sql: "SELECT * FROM easelItem ORDER BY z").compactMap { row -> EaselItem? in
                guard let id = UUID(uuidString: row["id"]), let easel = UUID(uuidString: row["easelID"]),
                      let kind = EaselItemKind(rawValue: row["kind"])
                else { return nil }
                return EaselItem(
                    id: id, easelID: easel, kind: kind,
                    x: row["x"], y: row["y"], width: row["width"], height: row["height"], z: row["z"],
                    text: row["text"], url: (row["url"] as String?).flatMap(URL.init(string:)), imageHash: row["imageHash"],
                    points: EaselPoint.decode(row["points"]),
                    fontSize: row["fontSize"],
                    color: row["color"]
                )
            }
            return EaselSnapshot(easels: easels, items: items)
        }
    }

    /// Replaces every Easel and item (used when sync brings a new state).
    public func saveEasels(_ snapshot: EaselSnapshot) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM easel")
            try db.execute(sql: "DELETE FROM easelItem")
            for easel in snapshot.easels { try Self.upsert(easel, in: db) }
            for item in snapshot.items { try Self.upsert(item, in: db) }
        }
    }

    public func saveEasel(_ easel: Easel) throws {
        try writer.write { db in try Self.upsert(easel, in: db) }
    }

    public func saveEaselItem(_ item: EaselItem) throws {
        try writer.write { db in try Self.upsert(item, in: db) }
    }

    public func deleteEasel(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM easelItem WHERE easelID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM easel WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func deleteEaselItem(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM easelItem WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private static func upsert(_ easel: Easel, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO easel (id, spaceID, title, createdAt, position) VALUES (?, ?, ?, ?, ?)",
            arguments: [easel.id.uuidString, easel.spaceID.uuidString, easel.title, easel.createdAt, easel.position]
        )
    }

    private static func upsert(_ item: EaselItem, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO easelItem (id, easelID, kind, x, y, width, height, z, text, url, imageHash, points, fontSize, color)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                item.id.uuidString, item.easelID.uuidString, item.kind.rawValue,
                item.x, item.y, item.width, item.height, item.z, item.text,
                item.url?.absoluteString, item.imageHash, EaselPoint.encode(item.points), item.fontSize, item.color,
            ]
        )
    }
}
