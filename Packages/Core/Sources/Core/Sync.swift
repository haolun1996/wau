import Foundation

/// A record's synced values, as plain strings so the sync file stays readable.
public typealias SyncFields = [String: String]

/// One record in the sync file. The newest change wins; deletions are kept
/// as tombstones so they reach other devices.
public struct SyncEntry: Codable, Equatable, Sendable {
    public var updatedAt: Date
    /// Breaks ties between changes made at the same instant.
    public var deviceID: String
    public var deleted: Bool
    public var fields: SyncFields

    public init(updatedAt: Date, deviceID: String, deleted: Bool = false, fields: SyncFields = [:]) {
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.deleted = deleted
        self.fields = fields
    }

    /// Whether this entry should win over `other` for the same record.
    func supersedes(_ other: SyncEntry) -> Bool {
        (updatedAt, deviceID) > (other.updatedAt, other.deviceID)
    }
}

/// The whole synced state: records keyed like `space:<uuid>` or `tab:<uuid>`.
public struct SyncDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var entries: [String: SyncEntry]

    public init(entries: [String: SyncEntry] = [:]) {
        self.entries = entries
    }

    /// The records that currently exist (not deleted).
    public var liveFields: [String: SyncFields] {
        entries.compactMapValues { $0.deleted ? nil : $0.fields }
    }

    /// Combines two documents record by record, keeping the newest change.
    /// The result doesn't depend on argument order and merging again changes
    /// nothing, so devices converge however often they sync.
    public static func merge(_ a: SyncDocument, _ b: SyncDocument) -> SyncDocument {
        var entries = a.entries
        for (key, entry) in b.entries {
            if let existing = entries[key], !entry.supersedes(existing) { continue }
            entries[key] = entry
        }
        return SyncDocument(entries: entries)
    }

    /// Records this device's changes since `baseline` (the fields as of the
    /// last sync): changed or new records get fresh entries, records that
    /// disappeared become tombstones.
    public func recording(
        current: [String: SyncFields],
        baseline: [String: SyncFields],
        deviceID: String,
        at now: Date
    ) -> SyncDocument {
        var document = self
        for (key, fields) in current where baseline[key] != fields || document.entries[key]?.deleted != false {
            if let existing = document.entries[key], !existing.deleted, existing.fields == fields { continue }
            document.entries[key] = SyncEntry(updatedAt: now, deviceID: deviceID, fields: fields)
        }
        for key in baseline.keys where current[key] == nil {
            if document.entries[key]?.deleted == true { continue }
            document.entries[key] = SyncEntry(updatedAt: now, deviceID: deviceID, deleted: true)
        }
        return document
    }
}

/// Converts between the browser's saved state and sync records. Spaces,
/// pinned tabs and favorites sync; ordinary tabs stay on each Mac (they are
/// short-lived and get archived anyway), as do logins and history.
public enum SyncMapping {
    static let spacePrefix = "space:"
    static let tabPrefix = "tab:"

    public static func fields(from snapshot: BrowserSnapshot) -> [String: SyncFields] {
        var result: [String: SyncFields] = [:]
        for (position, space) in snapshot.spaces.enumerated() {
            result[spacePrefix + space.id.uuidString] = [
                "name": space.name,
                "icon": space.icon,
                "theme": space.themeID,
                "separateLogins": space.profileID == nil ? "0" : "1",
                "archiveAfter": space.archiveInterval.rawValue,
                "position": String(position),
            ]
        }
        var positions: [String: Int] = [:]
        for tab in snapshot.tabs where tab.isFavorite || tab.isPinned {
            guard let url = tab.pinnedURL ?? tab.url else { continue }
            let group = tab.spaceID?.uuidString ?? ""
            let position = positions[group, default: 0]
            positions[group] = position + 1
            result[tabPrefix + tab.id.uuidString] = [
                "space": group,
                "url": url.absoluteString,
                "position": String(position),
            ]
        }
        return result
    }

    /// `snapshot` changed to match `fields` (the merged, live sync records).
    /// Local-only details (open pages, history, which tab is selected) are
    /// kept. Ordinary tabs in a Space deleted elsewhere move to the first
    /// remaining Space rather than closing.
    public static func apply(
        _ fields: [String: SyncFields],
        to snapshot: BrowserSnapshot,
        makeProfileID: () -> UUID = UUID.init
    ) -> BrowserSnapshot {
        let localSpaces = Dictionary(snapshot.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var spaces: [(position: Int, record: SpaceRecord)] = []
        for (key, values) in fields where key.hasPrefix(spacePrefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(spacePrefix.count))) else { continue }
            var record = localSpaces[id] ?? SpaceRecord(
                id: id, name: "", icon: "", themeID: "",
                // A Space's separate logins can't move between devices; this
                // Mac gets its own, empty profile for it.
                profileID: values["separateLogins"] == "1" ? makeProfileID() : nil
            )
            record.name = values["name"] ?? record.name
            record.icon = values["icon"] ?? record.icon
            record.themeID = values["theme"] ?? record.themeID
            record.archiveInterval = values["archiveAfter"].flatMap(ArchiveInterval.init(rawValue:)) ?? record.archiveInterval
            spaces.append((Int(values["position"] ?? "") ?? .max, record))
        }
        var orderedSpaces = spaces
            .sorted { ($0.position, $0.record.id.uuidString) < ($1.position, $1.record.id.uuidString) }
            .map(\.record)
        if orderedSpaces.isEmpty { orderedSpaces = [snapshot.spaces.first ?? .makeDefault()] }
        let spaceIDs = Set(orderedSpaces.map(\.id))

        let localTabs = Dictionary(snapshot.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var syncedTabs: [(group: String, position: Int, record: TabRecord)] = []
        for (key, values) in fields where key.hasPrefix(tabPrefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(tabPrefix.count))),
                  let url = values["url"].flatMap(URL.init(string:))
            else { continue }
            let group = values["space"] ?? ""
            let spaceID = UUID(uuidString: group)
            if !group.isEmpty, !(spaceID.map(spaceIDs.contains) ?? false) { continue } // its Space is gone
            var record = localTabs[id] ?? TabRecord(id: id, url: url, title: url.host() ?? url.absoluteString)
            record.spaceID = spaceID
            record.isPinned = spaceID != nil
            record.pinnedURL = url
            syncedTabs.append((group, Int(values["position"] ?? "") ?? .max, record))
        }
        syncedTabs.sort { ($0.position, $0.record.id.uuidString) < ($1.position, $1.record.id.uuidString) }

        let fallbackSpace = orderedSpaces[0].id
        let regularTabs = snapshot.tabs
            .filter { !$0.isFavorite && !$0.isPinned }
            .map { tab -> TabRecord in
                var tab = tab
                if !(tab.spaceID.map(spaceIDs.contains) ?? false) { tab.spaceID = fallbackSpace }
                return tab
            }

        var tabs = syncedTabs.filter { $0.group.isEmpty }.map(\.record)
        for space in orderedSpaces {
            tabs += syncedTabs.filter { $0.group == space.id.uuidString }.map(\.record)
            tabs += regularTabs.filter { $0.spaceID == space.id }
        }
        let selected = snapshot.selectedSpaceID.flatMap { spaceIDs.contains($0) ? $0 : nil } ?? fallbackSpace
        // Splits are local; keep those whose Space and tabs survived. Members
        // that were never tabs here (Easels) are left for the app to check.
        var splits: [UUID: [SplitGroup]] = [:]
        let localTabIDs = Set(snapshot.tabs.map(\.id))
        for (spaceID, groups) in snapshot.splits where spaceIDs.contains(spaceID) {
            let tabIDs = Set(tabs.filter { $0.spaceID == spaceID }.map(\.id))
            let kept = groups.map { group -> SplitGroup in
                var group = group
                group.retain(Set(group.tabIDs.filter { tabIDs.contains($0) || !localTabIDs.contains($0) }))
                return group
            }.filter(\.isValid)
            if !kept.isEmpty { splits[spaceID] = kept }
        }
        return BrowserSnapshot(spaces: orderedSpaces, tabs: tabs, selectedSpaceID: selected, splits: splits)
    }
}
