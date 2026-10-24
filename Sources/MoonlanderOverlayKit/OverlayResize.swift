import CoreGraphics

/// Frame maths and hit zones for dragging the overlay's edges and corners.
///
/// Deliberately free of AppKit window state so the behaviour that is hard to
/// exercise by hand (anchoring, clamping, minimum size, hit zones) is unit-testable.
public enum OverlayResize {
    /// Which edges a drag is moving. `top`/`bottom` always mean the visually top
    /// and bottom edges; the coordinate system differs per entry point —
    /// `frame(from:)` takes screen coordinates, `edges(at:)` flipped view ones.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let leading = Edges(rawValue: 1 << 0)
        public static let trailing = Edges(rawValue: 1 << 1)
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)

        public static let all: Edges = [.leading, .trailing, .top, .bottom]
    }

    /// Which edges a borderless view should treat as resize handles at `point`.
    ///
    /// `point` is in flipped view coordinates (origin top-left), matching
    /// `NSView.isFlipped`. The outer `grabInset` points of each side resize, so
    /// corners resize both axes. Hits inside `handles` are excluded entirely:
    /// those regions drag the window instead of resizing it.
    public static func edges(
        at point: CGPoint,
        size: CGSize,
        grabInset: CGFloat,
        excluding handles: [CGRect] = []
    ) -> Edges {
        guard !handles.contains(where: { $0.contains(point) }) else { return [] }
        var edges: Edges = []
        if point.x <= grabInset {
            edges.insert(.leading)
        }
        if point.x >= size.width - grabInset {
            edges.insert(.trailing)
        }
        if point.y <= grabInset {
            edges.insert(.top)
        }
        if point.y >= size.height - grabInset {
            edges.insert(.bottom)
        }
        return edges
    }

    /// Returns the frame produced by dragging `edges` of `initial` by `delta`.
    /// The edge opposite the one being dragged stays put when a limit is hit.
    public static func frame(
        from initial: CGRect,
        edges: Edges,
        delta: CGSize,
        minimum: CGSize,
        maximum: CGSize
    ) -> CGRect {
        var frame = initial
        if edges.contains(.leading) {
            frame.origin.x += delta.width
            frame.size.width -= delta.width
        }
        if edges.contains(.trailing) {
            frame.size.width += delta.width
        }
        if edges.contains(.bottom) {
            frame.origin.y += delta.height
            frame.size.height -= delta.height
        }
        if edges.contains(.top) {
            frame.size.height += delta.height
        }

        if frame.size.width < minimum.width {
            if edges.contains(.leading) {
                frame.origin.x = initial.maxX - minimum.width
            }
            frame.size.width = minimum.width
        }
        if frame.size.height < minimum.height {
            if edges.contains(.bottom) {
                frame.origin.y = initial.maxY - minimum.height
            }
            frame.size.height = minimum.height
        }
        if frame.size.width > maximum.width {
            if edges.contains(.leading) {
                frame.origin.x = initial.maxX - maximum.width
            }
            frame.size.width = maximum.width
        }
        if frame.size.height > maximum.height {
            if edges.contains(.bottom) {
                frame.origin.y = initial.maxY - maximum.height
            }
            frame.size.height = maximum.height
        }
        return frame
    }
}
