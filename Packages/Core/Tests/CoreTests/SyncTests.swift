import Foundation
import Testing
@testable import Core

@Suite("SyncDocument")
struct SyncDocumentTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var t1: Date { t0.addingTimeInterval(60) }
    var t2: Date { t0.addingTimeInterval(120) }

    func makeEntry(_ at: Date, _ device: String = "A", deleted: Bool = false, name: String = "x") -> SyncEntry {
        SyncEntry(updatedAt: at, deviceID: device, deleted: deleted, fields: deleted ? [:] : ["name": name])
    }

    @Test func newestEntryWinsAndTombstonesCount() {
        let a = SyncDocument(entries: ["k": makeEntry(t1, name: "new"), "gone": makeEntry(t2, deleted: true)])
        let b = SyncDocument(entries: ["k": makeEntry(t0, "B", name: "old"), "gone": makeEntry(t1, "B", name: "alive")])
        let merged = SyncDocument.merge(a, b)
        #expect(merged.entries["k"]?.fields["name"] == "new")
        #expect(merged.entries["gone"]?.deleted == true)
        #expect(merged.liveFields == ["k": ["name": "new"]])
    }

    @Test func mergeIsOrderIndependentAndIdempotent() {
        let a = SyncDocument(entries: ["x": makeEntry(t1, "A", name: "a"), "y": makeEntry(t0, "A")])
        let b = SyncDocument(entries: ["x": makeEntry(t1, "B", name: "b"), "z": makeEntry(t2, "B")]) // same time: device ID breaks the tie
        let ab = SyncDocument.merge(a, b)
        #expect(ab == SyncDocument.merge(b, a))
        #expect(SyncDocument.merge(ab, ab) == ab)
        #expect(SyncDocument.merge(ab, a) == ab)
        #expect(ab.entries["x"]?.fields["name"] == "b")
    }

    @Test func recordingCapturesChangesAdditionsAndDeletions() {
        let synced = SyncDocument(entries: ["same": makeEntry(t0, name: "s"), "edit": makeEntry(t0, name: "before"), "drop": makeEntry(t0)])
        let baseline: [String: SyncFields] = ["same": ["name": "s"], "edit": ["name": "before"], "drop": ["name": "x"]]
        let current: [String: SyncFields] = ["same": ["name": "s"], "edit": ["name": "after"], "add": ["name": "n"]]

        let recorded = synced.recording(current: current, baseline: baseline, deviceID: "A", at: t2)
        #expect(recorded.entries["same"] == synced.entries["same"]) // untouched keeps its old timestamp
        #expect(recorded.entries["edit"] == SyncEntry(updatedAt: t2, deviceID: "A", fields: ["name": "after"]))
        #expect(recorded.entries["add"] == SyncEntry(updatedAt: t2, deviceID: "A", fields: ["name": "n"]))
        #expect(recorded.entries["drop"] == SyncEntry(updatedAt: t2, deviceID: "A", deleted: true))
    }

    /// Two devices edit independently, then sync in turns through a shared
    /// remote copy; both must end up with the same state.
    @Test func twoDevicesConverge() {
        var remote = SyncDocument()
        // Device A creates two records and syncs.
        var docA = SyncDocument().recording(current: ["s1": ["name": "Work"], "s2": ["name": "Home"]], baseline: [:], deviceID: "A", at: t0)
        docA = SyncDocument.merge(docA, remote); remote = docA
        // Device B syncs, receiving them.
        var docB = SyncDocument.merge(SyncDocument(), remote); remote = docB
        let baseA = docA.liveFields, baseB = docB.liveFields
        // A renames s1; B deletes s2 and adds s3.
        docA = docA.recording(current: ["s1": ["name": "Kerja"], "s2": ["name": "Home"]], baseline: baseA, deviceID: "A", at: t1)
        docB = docB.recording(current: ["s1": ["name": "Work"], "s3": ["name": "Play"]], baseline: baseB, deviceID: "B", at: t1)
        docA = SyncDocument.merge(docA, remote); remote = docA
        docB = SyncDocument.merge(docB, remote); remote = docB
        docA = SyncDocument.merge(docA, remote)

        #expect(docA.liveFields == docB.liveFields)
        #expect(docA.liveFields == ["s1": ["name": "Kerja"], "s3": ["name": "Play"]])
    }

    @Test func documentsRoundTripThroughJSON() throws {
        let document = SyncDocument(entries: ["k": makeEntry(t0, name: "Wau"), "d": makeEntry(t1, deleted: true)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SyncDocument.self, from: encoder.encode(document)) == document)
    }
}

@Suite("SyncMapping")
struct SyncMappingTests {
    let work = SpaceRecord(name: "Work", icon: "💼", themeID: "melaka", profileID: UUID())
    let home = SpaceRecord(name: "Home", icon: "🪁", themeID: "langkawi")
    let snapshot: BrowserSnapshot

    init() {
        func tab(_ name: String, space: UUID?, pinned: Bool = false) -> TabRecord {
            let url = URL(string: "https://\(name).example")!
            return TabRecord(spaceID: space, isPinned: pinned, pinnedURL: pinned || space == nil ? url : nil, url: url, title: name)
        }
        snapshot = BrowserSnapshot(
            spaces: [work, home],
            tabs: [
                tab("fav", space: nil),
                tab("pin", space: work.id, pinned: true),
                tab("open", space: work.id),
                tab("other", space: home.id),
            ],
            selectedSpaceID: home.id
        )
    }

    @Test func onlySpacesPinnedTabsAndFavoritesSync() {
        let fields = SyncMapping.fields(from: snapshot)
        #expect(fields.count == 4) // 2 spaces + pinned + favorite
        #expect(fields["space:\(work.id.uuidString)"]?["separateLogins"] == "1")
        #expect(fields["space:\(home.id.uuidString)"]?["position"] == "1")
        let favorite = snapshot.tabs[0]
        #expect(fields["tab:\(favorite.id.uuidString)"] == ["space": "", "url": "https://fav.example", "position": "0"])
    }

    @Test func applyingOwnFieldsChangesNothing() {
        let fields = SyncMapping.fields(from: snapshot)
        #expect(SyncMapping.apply(fields, to: snapshot) == snapshot)
    }

    @Test func remoteAdditionsAndEditsArrive() throws {
        var fields = SyncMapping.fields(from: snapshot)
        let newSpace = UUID(), newTab = UUID(), profile = UUID()
        fields["space:\(newSpace.uuidString)"] = ["name": "Kopi", "icon": "☕️", "theme": "nyonya", "separateLogins": "1", "position": "0"]
        fields["space:\(work.id.uuidString)"]?["name"] = "Kerja"
        fields["space:\(work.id.uuidString)"]?["position"] = "1"
        fields["space:\(home.id.uuidString)"]?["position"] = "2"
        fields["tab:\(newTab.uuidString)"] = ["space": newSpace.uuidString, "url": "https://kopi.example", "position": "0"]

        let result = SyncMapping.apply(fields, to: snapshot, makeProfileID: { profile })
        #expect(result.spaces.map(\.name) == ["Kopi", "Kerja", "Home"])
        #expect(result.spaces[0].profileID == profile) // a fresh local profile for separate logins
        #expect(result.spaces[1].profileID == work.profileID) // existing ones are kept
        let added = try #require(result.tabs.first { $0.id == newTab })
        #expect(added.isPinned && added.spaceID == newSpace && added.title == "kopi.example")
        #expect(result.selectedSpaceID == home.id)
    }

    @Test func remoteDeletionMovesOrdinaryTabsInsteadOfClosingThem() {
        var fields = SyncMapping.fields(from: snapshot)
        fields["space:\(work.id.uuidString)"] = nil // Work deleted elsewhere
        let pinned = snapshot.tabs[1]
        fields["tab:\(pinned.id.uuidString)"] = nil

        let result = SyncMapping.apply(fields, to: snapshot)
        #expect(result.spaces.map(\.name) == ["Home"])
        #expect(!result.tabs.contains { $0.id == pinned.id })
        let open = result.tabs.first { $0.title == "open" }
        #expect(open?.spaceID == home.id)
    }

    @Test func deletingEverySpaceKeepsOne() {
        let result = SyncMapping.apply([:], to: snapshot)
        #expect(result.spaces.count == 1)
        #expect(result.tabs.allSatisfy { !$0.isPinned && !$0.isFavorite })
    }
}
