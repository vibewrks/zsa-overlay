import CoreGraphics
@testable import MoonlanderOverlayKit
import Testing

@Suite("Overlay resize maths")
struct OverlayResizeTests {
    private let initial = CGRect(x: 800, y: 400, width: 1000, height: 400)
    private let minimum = CGSize(width: 420, height: 150)
    private let maximum = CGSize(width: 1920, height: 1200)

    private func resized(
        _ edges: OverlayResize.Edges,
        dx: CGFloat = 0,
        dy: CGFloat = 0
    ) -> CGRect {
        OverlayResize.frame(
            from: initial,
            edges: edges,
            delta: CGSize(width: dx, height: dy),
            minimum: minimum,
            maximum: maximum
        )
    }

    @Test("dragging the trailing edge grows width and leaves the origin alone")
    func trailingEdge() {
        let result = resized(.trailing, dx: 120)
        #expect(result.size.width == 1120)
        #expect(result.origin == initial.origin)
    }

    @Test("dragging the leading edge moves the origin and keeps the right edge anchored")
    func leadingEdge() {
        let result = resized(.leading, dx: -120)
        #expect(result.origin.x == 680)
        #expect(result.size.width == 1120)
        #expect(result.maxX == initial.maxX)
    }

    @Test("dragging the screen-bottom edge moves the origin up and keeps the top anchored")
    func bottomEdge() {
        let result = resized(.bottom, dy: -50)
        #expect(result.origin.y == 350)
        #expect(result.size.height == 450)
        #expect(result.maxY == initial.maxY)
    }

    @Test("dragging the screen-top edge grows height without moving the origin")
    func topEdge() {
        let result = resized(.top, dy: 60)
        #expect(result.size.height == 460)
        #expect(result.origin.y == initial.origin.y)
    }

    @Test("dragging a corner moves both axes")
    func corner() {
        let result = resized([.trailing, .top], dx: 40, dy: 25)
        #expect(result.size.width == 1040)
        #expect(result.size.height == 425)
        #expect(result.origin == initial.origin)
    }

    @Test("minimum size clamps without detaching the anchored edge")
    func minimumClamp() {
        let fromTrailing = resized(.trailing, dx: -5000)
        #expect(fromTrailing.size.width == minimum.width)
        #expect(fromTrailing.origin.x == initial.origin.x)

        let fromLeading = resized(.leading, dx: 5000)
        #expect(fromLeading.size.width == minimum.width)
        #expect(fromLeading.maxX == initial.maxX)

        let fromBottom = resized(.bottom, dy: 5000)
        #expect(fromBottom.size.height == minimum.height)
        #expect(fromBottom.maxY == initial.maxY)
    }

    @Test("maximum size clamps to the screen")
    func maximumClamp() {
        let result = resized(.trailing, dx: 5000)
        #expect(result.size.width == maximum.width)

        let tall = resized(.top, dy: 5000)
        #expect(tall.size.height == maximum.height)
    }

    @Test("no edge dragged means no change")
    func noEdges() {
        let result = resized([], dx: 100, dy: 100)
        #expect(result == initial)
    }
}

@Suite("Overlay resize hit zones")
struct OverlayResizeHitZoneTests {
    private let size = CGSize(width: 900, height: 360)

    private func edges(
        at point: CGPoint,
        excluding handles: [CGRect] = []
    ) -> OverlayResize.Edges {
        OverlayResize.edges(at: point, size: size, grabInset: 10, excluding: handles)
    }

    @Test("the outer band of each side resizes, corners on both axes")
    func borderBand() {
        #expect(edges(at: CGPoint(x: 4, y: 180)) == .leading)
        #expect(edges(at: CGPoint(x: 896, y: 180)) == .trailing)
        #expect(edges(at: CGPoint(x: 450, y: 4)) == .top)
        #expect(edges(at: CGPoint(x: 450, y: 356)) == .bottom)
        #expect(edges(at: CGPoint(x: 4, y: 4)) == [.leading, .top])
    }

    @Test("the interior is not an edge")
    func interior() {
        #expect(edges(at: CGPoint(x: 450, y: 180)).isEmpty)
    }

    @Test("a drag handle over the top edge suppresses the resize edge it covers")
    func handleBeatsOverlappingEdge() {
        let pill = CGRect(x: 400, y: 0, width: 100, height: 17)
        #expect(edges(at: CGPoint(x: 450, y: 5), excluding: [pill]).isEmpty)
        // Beside the handle the top edge still resizes.
        #expect(edges(at: CGPoint(x: 200, y: 5), excluding: [pill]) == .top)
        #expect(edges(at: CGPoint(x: 700, y: 5), excluding: [pill]) == .top)
    }
}
