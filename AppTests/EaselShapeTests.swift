import AppKit
import Core
import Testing
@testable import Wau

@MainActor
@Suite("Easel shapes")
struct EaselShapeTests {
    @Test func rectanglesSpanTheDragInEitherDirection() {
        let geometry = EaselShapeView.geometry(for: .rectangle, through: [CGPoint(x: 200, y: 150), CGPoint(x: 50, y: 30)])
        #expect(geometry.frame == CGRect(x: 50, y: 30, width: 150, height: 120))
        #expect(geometry.points.isEmpty)
    }

    @Test func arrowsGetRoomForTheirHeadAndKeepTheirDirection() {
        let geometry = EaselShapeView.geometry(for: .arrow, through: [CGPoint(x: 300, y: 100), CGPoint(x: 100, y: 100)])
        #expect(geometry.frame == CGRect(x: 88, y: 88, width: 224, height: 24))
        // Pointing left: the start is on the right.
        #expect(geometry.points.count == 2)
        #expect(geometry.points[0].x > geometry.points[1].x)
        #expect(geometry.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    @Test func strokePointsStayInsideTheirFrame() {
        let stroke = (0...20).map { CGPoint(x: Double($0) * 10, y: 50 + sin(Double($0)) * 30) }
        let geometry = EaselShapeView.geometry(for: .drawing, through: stroke)
        #expect(geometry.points.count == stroke.count)
        #expect(geometry.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        let path = EaselShapeView.path(kind: .drawing, points: geometry.points, in: CGRect(origin: .zero, size: geometry.frame.size))
        #expect(!path.isEmpty)
    }

    @Test func everyToolHasItsOwnKey() {
        let keys = EaselTool.allCases.map(\.shortcut)
        #expect(Set(keys).count == keys.count)
    }
}

@MainActor
@Suite("Easel labels")
struct EaselLabelTests {
    @Test func biggerBoxesGetBiggerText() {
        let small = EaselLabelLayout.fontSize(for: "啊", in: CGSize(width: 200, height: 30))
        let large = EaselLabelLayout.fontSize(for: "啊", in: CGSize(width: 440, height: 240))
        #expect(small < 30)
        #expect(large > 150)
    }

    @Test func longerTextShrinksToStayInside() {
        let box = CGSize(width: 300, height: 120)
        let short = EaselLabelLayout.fontSize(for: "Kite", in: box)
        let long = EaselLabelLayout.fontSize(for: "The wau bulan is a moon kite flown on the east coast of Malaysia", in: box)
        #expect(long < short)
        let font = NSFont.systemFont(ofSize: long, weight: .medium)
        let needed = ("The wau bulan is a moon kite flown on the east coast of Malaysia" as NSString).boundingRect(
            with: NSSize(width: box.width - 6, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        #expect(needed.height <= box.height)
    }

    @Test func sizeStepsMoveToTheNextSizeAndStopAtTheEnds() {
        #expect(EaselLabelLayout.step(from: 18, bigger: true) == 20)
        #expect(EaselLabelLayout.step(from: 21.5, bigger: true) == 24)
        #expect(EaselLabelLayout.step(from: 21.5, bigger: false) == 20)
        #expect(EaselLabelLayout.step(from: 400, bigger: true) == 400)
        #expect(EaselLabelLayout.step(from: 12, bigger: false) == 12)
    }

    @Test func boxesGrowToShowBiggerText() {
        let small = EaselLabelLayout.boxSize(for: "Dada", fontSize: 18, width: 220)
        #expect(small.width == 220)
        let big = EaselLabelLayout.boxSize(for: "Dada", fontSize: 200, width: 220)
        #expect(big.width > 220)
        #expect(big.height > 200)
    }

    @Test func tinyBoxesKeepAReadableMinimum() {
        #expect(EaselLabelLayout.fontSize(for: "Hello there", in: CGSize(width: 20, height: 10)) == 12)
    }
}

@MainActor
@Suite("Easel resizing")
struct EaselResizeTests {
    let size = CGSize(width: 200, height: 100)
    let start = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func edgesAndCornersAreFoundAroundTheBorder() {
        #expect(EaselResize.edges(at: CGPoint(x: 3, y: 3), in: size) == [.top, .left])
        #expect(EaselResize.edges(at: CGPoint(x: 197, y: 97), in: size) == [.bottom, .right])
        #expect(EaselResize.edges(at: CGPoint(x: 100, y: 2), in: size) == .top)
        #expect(EaselResize.edges(at: CGPoint(x: 100, y: 98), in: size) == .bottom)
        #expect(EaselResize.edges(at: CGPoint(x: 2, y: 50), in: size) == .left)
        #expect(EaselResize.edges(at: CGPoint(x: 198, y: 50), in: size) == .right)
        // The middle moves the item.
        #expect(EaselResize.edges(at: CGPoint(x: 100, y: 50), in: size) == [])
    }

    @Test func eachEdgeMovesOnlyItself() {
        let minimum = CGSize(width: 20, height: 20)
        #expect(EaselResize.frame(from: start, edges: .left, dx: -30, dy: 50, minimum: minimum, keepAspect: false)
            == CGRect(x: 70, y: 100, width: 230, height: 100))
        #expect(EaselResize.frame(from: start, edges: .top, dx: 50, dy: 20, minimum: minimum, keepAspect: false)
            == CGRect(x: 100, y: 120, width: 200, height: 80))
        #expect(EaselResize.frame(from: start, edges: [.bottom, .right], dx: 10, dy: 10, minimum: minimum, keepAspect: false)
            == CGRect(x: 100, y: 100, width: 210, height: 110))
    }

    @Test func itemsStayAboveTheirMinimumAndOnTheCanvas() {
        let minimum = CGSize(width: 60, height: 30)
        let squashed = EaselResize.frame(from: start, edges: .left, dx: 500, dy: 0, minimum: minimum, keepAspect: false)
        #expect(squashed == CGRect(x: 240, y: 100, width: 60, height: 100))
        let pastEdge = EaselResize.frame(from: start, edges: [.top, .left], dx: -500, dy: -500, minimum: minimum, keepAspect: false)
        #expect(pastEdge.minX == 0 && pastEdge.minY == 0)
    }

    @Test func picturesKeepTheirShape() {
        let minimum = CGSize(width: 60, height: 30)
        let wider = EaselResize.frame(from: start, edges: .right, dx: 100, dy: 0, minimum: minimum, keepAspect: true)
        #expect(wider == CGRect(x: 100, y: 100, width: 300, height: 150))
        let taller = EaselResize.frame(from: start, edges: .bottom, dx: 0, dy: 50, minimum: minimum, keepAspect: true)
        #expect(taller == CGRect(x: 100, y: 100, width: 300, height: 150))
        // Dragging the top-left corner keeps the bottom-right corner in place.
        let corner = EaselResize.frame(from: start, edges: [.top, .left], dx: -100, dy: 0, minimum: minimum, keepAspect: true)
        #expect(corner == CGRect(x: 0, y: 50, width: 300, height: 150))
    }
}

@MainActor
@Suite("Easel colours")
struct EaselColourTests {
    @Test func hexColoursParseAndBadOnesAreIgnored() {
        let red = EaselPalette.parse("#E5484D")
        #expect(red != nil)
        #expect(abs((red?.redComponent ?? 0) - 229.0 / 255) < 0.001)
        #expect(EaselPalette.parse("#12345") == nil)
        #expect(EaselPalette.parse("#GGGGGG") == nil)
        #expect(EaselPalette.colors.compactMap(\.hex).allSatisfy { EaselPalette.parse($0) != nil })
    }

    @Test func onlyTextAndDrawingsTakeAColour() {
        #expect(EaselPalette.isColorable(.text) && EaselPalette.isColorable(.drawing) && EaselPalette.isColorable(.arrow))
        #expect(!EaselPalette.isColorable(.image) && !EaselPalette.isColorable(.link))
    }
}
