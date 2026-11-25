import Foundation
import Testing
@testable import Core

@Suite("Easel sync mapping")
struct EaselSyncTests {
    let space = UUID()

    var sample: EaselSnapshot {
        let easel = Easel(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!, spaceID: space, title: "Ideas",
                          createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        return EaselSnapshot(easels: [easel], items: [
            EaselItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, easelID: easel.id, kind: .image,
                      x: 10, y: 20, width: 300, height: 200, z: 0, text: "Wau bulan",
                      url: URL(string: "https://en.wikipedia.org/wiki/Wau_bulan"), imageHash: "abc123"),
            EaselItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, easelID: easel.id, kind: .text,
                      x: 40, y: 260, width: 180, height: 40, z: 1, text: "Kite colours"),
        ])
    }

    @Test func roundTripsThroughSyncFields() {
        let fields = SyncMapping.fields(from: sample)
        #expect(fields.count == 3)
        #expect(SyncMapping.easels(from: fields) == sample)
        #expect(sample.imageHashes == ["abc123"])
    }

    @Test func positionsAreWholePoints() {
        var snapshot = sample
        snapshot.items[0].x = 10.4
        snapshot.items[0].width = 299.6
        let fields = SyncMapping.fields(from: snapshot)
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000001"]?["frame"] == "10,20,300,200")
    }

    @Test func orphanedAndMalformedItemsAreDropped() {
        var fields = SyncMapping.fields(from: sample)
        fields["easel:00000000-0000-0000-0000-0000000000E1"] = nil // the Easel was deleted elsewhere
        fields["easelItem:\(UUID().uuidString)"] = ["easel": UUID().uuidString, "kind": "text", "frame": "1,2"]
        #expect(SyncMapping.easels(from: fields) == EaselSnapshot())
    }

    @Test func browserMappingIgnoresEaselRecords() {
        let spaceRecord = SpaceRecord(id: space, name: "Home", icon: "🪁", themeID: "bulan")
        let browser = BrowserSnapshot(spaces: [spaceRecord], tabs: [], selectedSpaceID: space)
        let fields = SyncMapping.fields(from: browser).merging(SyncMapping.fields(from: sample)) { $1 }
        #expect(SyncMapping.apply(fields, to: browser) == browser)
    }
}
