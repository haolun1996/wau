import Testing
@testable import Core

@Suite("Array.move(from:toInsertionIndex:)")
struct MoveTests {
    @Test("Drops land in the gap they were dropped into", arguments: [
        // (source, insertion gap, expected)
        (0, 0, ["a", "b", "c", "d"]), // onto its own gap
        (0, 1, ["a", "b", "c", "d"]), // just below itself
        (0, 2, ["b", "a", "c", "d"]),
        (0, 4, ["b", "c", "d", "a"]), // to the end
        (3, 0, ["d", "a", "b", "c"]), // to the top
        (2, 1, ["a", "c", "b", "d"]),
        (1, 3, ["a", "c", "b", "d"]),
    ])
    func moves(source: Int, gap: Int, expected: [String]) {
        var items = ["a", "b", "c", "d"]
        items.move(from: source, toInsertionIndex: gap)
        #expect(items == expected)
    }

    @Test func outOfRangeIsIgnored() {
        var items = ["a", "b"]
        items.move(from: 5, toInsertionIndex: 0)
        items.move(from: 0, toInsertionIndex: 9)
        items.move(from: -1, toInsertionIndex: 0)
        #expect(items == ["a", "b"])
    }
}
