import CoreGraphics

/// Frame maths for dragging the overlay's edges and corners.
///
/// Deliberately free of AppKit window state so the behaviour that is hard to
/// exercise by hand (anchoring, clamping, minimum size) is unit-testable.
public enum OverlayResize {
    /// Which edges the current drag is moving. `top`/`bottom` are screen-relative,
    /// matching `NSEvent.mouseLocation`'s y-up coordinates.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let leading = Edges(rawValue: 1 << 0)
        public static let trailing = Edges(rawValue: 1 << 1)
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)

        public static let all: Edges = [.leading, .trailing, .top, .bottom]
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
            if edges.contains(.leading) { frame.origin.x = initial.maxX - minimum.width }
            frame.size.width = minimum.width
        }
        if frame.size.height < minimum.height {
            if edges.contains(.bottom) { frame.origin.y = initial.maxY - minimum.height }
            frame.size.height = minimum.height
        }
        if frame.size.width > maximum.width {
            if edges.contains(.leading) { frame.origin.x = initial.maxX - maximum.width }
            frame.size.width = maximum.width
        }
        if frame.size.height > maximum.height {
            if edges.contains(.bottom) { frame.origin.y = initial.maxY - maximum.height }
            frame.size.height = maximum.height
        }
        return frame
    }
}
