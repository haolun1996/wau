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

    @Test func shapesAndDrawingsRoundTripWithTheirPoints() {
        var snapshot = sample
        let easelID = snapshot.easels[0].id
        snapshot.items += [
            EaselItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, easelID: easelID, kind: .ellipse,
                      x: 0, y: 0, width: 120, height: 80, z: 2),
            EaselItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, easelID: easelID, kind: .arrow,
                      x: 10, y: 10, width: 200, height: 40, z: 3,
                      points: [EaselPoint(x: 0.05, y: 0.5), EaselPoint(x: 0.95, y: 0.5)]),
            EaselItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, easelID: easelID, kind: .drawing,
                      x: 50, y: 60, width: 90, height: 90, z: 4,
                      points: [EaselPoint(x: 0, y: 1), EaselPoint(x: 0.33333333, y: 0.25), EaselPoint(x: 1, y: 0)]),
        ]
        let fields = SyncMapping.fields(from: snapshot)
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000003"]?["points"] == nil)
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000005"]?["points"] == "0,1 0.3333,0.25 1,0")
        #expect(SyncMapping.easels(from: fields) == snapshot)
    }

    @Test func labelSizesRoundTripAndFittingLabelsStoreNone() {
        var snapshot = sample
        snapshot.items[1].fontSize = 48
        let fields = SyncMapping.fields(from: snapshot)
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000002"]?["fontSize"] == "48")
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000001"]?["fontSize"] == nil)
        #expect(SyncMapping.easels(from: fields) == snapshot)
    }

    @Test func coloursRoundTripAndAutomaticStoresNone() {
        var snapshot = sample
        snapshot.items[1].color = "#E5484D"
        let fields = SyncMapping.fields(from: snapshot)
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000002"]?["color"] == "#E5484D")
        #expect(fields["easelItem:00000000-0000-0000-0000-000000000001"]?["color"] == nil)
        #expect(SyncMapping.easels(from: fields) == snapshot)
    }

    @Test func easelPositionsRoundTrip() {
        var snapshot = sample
        snapshot.easels[0].position = 3
        let fields = SyncMapping.fields(from: snapshot)
        #expect(fields["easel:00000000-0000-0000-0000-0000000000E1"]?["position"] == "3")
        #expect(SyncMapping.easels(from: fields) == snapshot)
        // Records from before positions existed sort as 0.
        var old = fields
        old["easel:00000000-0000-0000-0000-0000000000E1"]?["position"] = nil
        #expect(SyncMapping.easels(from: old).easels.first?.position == 0)
    }

    @Test func pointDecodingSkipsMalformedPairs() {
        #expect(EaselPoint.decode("0.5,0.5 junk 1,2,3 0,1") == [EaselPoint(x: 0.5, y: 0.5), EaselPoint(x: 0, y: 1)])
        #expect(EaselPoint.decode("") == [])
    }

    @Test func browserMappingIgnoresEaselRecords() {
        let spaceRecord = SpaceRecord(id: space, name: "Home", icon: "🪁", themeID: "bulan")
        let browser = BrowserSnapshot(spaces: [spaceRecord], tabs: [], selectedSpaceID: space)
        let fields = SyncMapping.fields(from: browser).merging(SyncMapping.fields(from: sample)) { $1 }
        #expect(SyncMapping.apply(fields, to: browser) == browser)
    }
}
