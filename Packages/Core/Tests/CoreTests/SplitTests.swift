import Foundation
import Testing
@testable import Core

@Suite("SplitGroup")
struct SplitGroupTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test func startsEvenAndInsertsNextToANeighbour() {
        var group = SplitGroup(tabIDs: [a, b])
        #expect(group.fractions == [0.5, 0.5])
        let inserted = group.insert(c, after: a)
        #expect(inserted)
        #expect(group.tabIDs == [a, c, b])
        #expect(group.fractions.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 })
        let again = group.insert(c)
        #expect(!again) // already there
    }

    @Test func holdsAtMostFour() {
        var group = SplitGroup(tabIDs: [a, b, c, d, e])
        #expect(group.tabIDs == [a, b, c, d])
        #expect(group.isFull)
        let overflow = group.insert(e)
        #expect(!overflow)
    }

    @Test func removingSharesTheSpaceOutAndCanInvalidate() {
        var group = SplitGroup(tabIDs: [a, b, c], fractions: [0.5, 0.25, 0.25])
        group.remove(a)
        #expect(group.tabIDs == [b, c])
        #expect(group.fractions == [0.5, 0.5])
        group.retain([c])
        #expect(group.tabIDs == [c])
        #expect(!group.isValid)
    }

    @Test func fractionsAreNormalizedAndClamped() {
        var group = SplitGroup(tabIDs: [a, b])
        group.setFractions([3, 1])
        #expect(group.fractions == [0.75, 0.25])
        group.setFractions([1, 0])
        #expect(group.fractions[1] >= 0.09) // no pane disappears
        #expect(abs(group.fractions.reduce(0, +) - 1) < 1e-9)
        group.setFractions([1, 1, 1]) // wrong count: ignored
        #expect(group.fractions.count == 2)
    }

    @Test func axisToggles() {
        #expect(SplitAxis.horizontal.toggled == .vertical)
        #expect(SplitAxis.vertical.toggled == .horizontal)
    }

    @Test func syncApplyKeepsValidLocalSplits() {
        let space = SpaceRecord.makeDefault()
        let t1 = TabRecord(spaceID: space.id, url: URL(string: "https://a.example"), title: "a")
        let t2 = TabRecord(spaceID: space.id, url: URL(string: "https://b.example"), title: "b")
        let group = SplitGroup(tabIDs: [t1.id, t2.id])
        let snapshot = BrowserSnapshot(spaces: [space], tabs: [t1, t2], selectedSpaceID: space.id, splits: [space.id: [group]])
        #expect(SyncMapping.apply(SyncMapping.fields(from: snapshot), to: snapshot).splits == [space.id: [group]])
    }
}
