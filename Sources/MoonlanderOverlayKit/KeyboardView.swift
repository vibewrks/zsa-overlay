import AppKit

/// Draws keycaps only. Nothing fills the window bounds, so the desktop shows through
/// the gaps between keys and around the board.
public final class KeyboardView: NSView {
    public var keymap: Keymap? {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    public var activeLayerIndex: Int = 0 {
        didSet { if oldValue != activeLayerIndex { needsDisplay = true } }
    }

    /// Physical Oryx key IDs held down, independent of their current-layer binding.
    public var pressedKeyIDs: Set<Int> = [] {
        didSet { if oldValue != pressedKeyIDs { needsDisplay = true } }
    }

    /// Small status line under/above the board: layer name, or why it is not live.
    public var indicator: String? {
        didSet { if oldValue != indicator { needsDisplay = true } }
    }

    /// Whether the drag-to-resize affordance is offered. Hidden in click-through
    /// mode, where no click can reach this view anyway.
    public var showsResizeGrip = true {
        didSet {
            guard oldValue != showsResizeGrip else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Called when a manual resize finishes, so the frame can be persisted.
    public var onFrameChange: (() -> Void)?

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    private static let padding: CGFloat = 12
    private static let indicatorHeight: CGFloat = 18

    /// Width divided by height of the board in key units — used to size the window.
    public var contentAspectRatio: CGFloat {
        guard let keymap, !keymap.keys.isEmpty else { return 2.4 }
        let box = Self.boundingBox(of: keymap.keys)
        guard box.height > 0 else { return 2.4 }
        return box.width / box.height
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let keymap, !keymap.keys.isEmpty else { return }

        drawIndicator()

        let box = Self.boundingBox(of: keymap.keys)
        let available = NSRect(
            x: 0,
            y: Self.indicatorHeight,
            width: bounds.width,
            height: bounds.height - Self.indicatorHeight
        )
        let usableWidth = available.width - Self.padding * 2
        let usableHeight = available.height - Self.padding * 2
        guard usableWidth > 0, usableHeight > 0, box.width > 0, box.height > 0 else { return }

        let scale = min(usableWidth / box.width, usableHeight / box.height)
        guard scale > 0, scale.isFinite else { return }

        let offsetX = available.minX + (available.width - box.width * scale) / 2
        let offsetY = available.minY + (available.height - box.height * scale) / 2
        let activeLayers = [activeLayerIndex]

        for key in keymap.keys {
            let frame = NSRect(
                x: offsetX + (key.x - box.minX) * scale,
                y: offsetY + (key.y - box.minY) * scale,
                width: key.width * scale,
                height: key.height * scale
            ).insetBy(dx: 1.5, dy: 1.5)
            guard frame.width > 2, frame.height > 2 else { continue }
            drawKey(keymap.resolvedBinding(at: key.id, activeLayers: activeLayers),
                    in: frame, pressed: pressedKeyIDs.contains(key.id))
        }
        drawResizeGrip()
    }

    // MARK: - Resize affordance

    private static let grabInset: CGFloat = 10

    private var resizeEdges: OverlayResize.Edges = []
    private var initialFrame: CGRect = .zero
    private var initialMouse: NSPoint = .zero

    /// A borderless window gets no resize affordance from AppKit, so the edges
    /// are ranged here: the outer 10 pt of any side (and therefore the corners)
    /// drags that side.
    private func activeEdges(at point: NSPoint) -> OverlayResize.Edges {
        guard showsResizeGrip else { return [] }
        var edges: OverlayResize.Edges = []
        if point.x <= Self.grabInset { edges.insert(.leading) }
        if point.x >= bounds.width - Self.grabInset { edges.insert(.trailing) }
        if point.y <= Self.grabInset { edges.insert(.top) }
        if point.y >= bounds.height - Self.grabInset { edges.insert(.bottom) }
        return edges
    }

    public override func resetCursorRects() {
        guard showsResizeGrip else { return }
        let inset = Self.grabInset
        addCursorRect(
            NSRect(x: 0, y: 0, width: inset, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: bounds.width - inset, y: 0, width: inset, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: 0, y: 0, width: bounds.width, height: inset),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: bounds.height - inset, width: bounds.width, height: inset),
            cursor: .resizeUpDown
        )
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = activeEdges(at: point)
        guard !edges.isEmpty, let window else {
            // Not an edge: defer to the window, which drags itself by its background.
            super.mouseDown(with: event)
            return
        }
        resizeEdges = edges
        initialFrame = window.frame
        initialMouse = NSEvent.mouseLocation
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !resizeEdges.isEmpty, let window else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        let frame = OverlayResize.frame(
            from: initialFrame,
            edges: resizeEdges,
            delta: CGSize(width: current.x - initialMouse.x, height: current.y - initialMouse.y),
            minimum: window.minSize,
            maximum: window.screen?.visibleFrame.size ?? CGSize(width: 4096, height: 2160)
        )
        window.setFrame(frame, display: true)
    }

    public override func mouseUp(with event: NSEvent) {
        guard !resizeEdges.isEmpty else {
            super.mouseUp(with: event)
            return
        }
        resizeEdges = []
        onFrameChange?()
    }

    /// Two ticks in the bottom-right corner, mirroring the classic resize grip.
    private func drawResizeGrip() {
        guard showsResizeGrip, bounds.width > 60, bounds.height > 60 else { return }
        let corner = NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: corner.x - 10, y: corner.y - 4))
        path.line(to: NSPoint(x: corner.x - 4, y: corner.y - 10))
        path.move(to: NSPoint(x: corner.x - 6, y: corner.y - 4))
        path.line(to: NSPoint(x: corner.x - 4, y: corner.y - 6))
        NSColor.white.withAlphaComponent(0.32).setStroke()
        path.stroke()
    }

    // MARK: - Keycap drawing

    private func drawKey(_ binding: KeyBinding?, in rect: NSRect, pressed: Bool) {
        let radius = min(rect.height * 0.22, 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let kind = binding?.kind ?? .transparent

        switch kind {
        case .mapped:
            NSColor.black.withAlphaComponent(0.55).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.30).setStroke()
            path.lineWidth = 1
            path.stroke()

        case .disabled:
            // Ghosted: position is visible, the key itself is not part of this layer.
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 1
            path.stroke()

        case .transparent:
            // Inherits a lower layer; we cannot show the true legend from a single
            // reported layer, so mark it rather than showing a wrong label.
            NSColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 3], count: 2, phase: 0)
            path.stroke()
        }

        if pressed {
            NSColor.controlAccentColor.withAlphaComponent(0.60).setFill()
            path.fill()
            path.setLineDash([], count: 0, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        guard rect.height >= 16 else { return }

        let primarySize = min(max(rect.height * 0.34, 7), 13)
        let borderColor: NSColor = kind == .mapped || pressed
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.white.withAlphaComponent(0.28)

        if kind == .transparent {
            drawText("↧", in: rect.insetBy(dx: 2, dy: 2), size: primarySize, color: borderColor)
            return
        }

        guard let binding else { return }
        let primary = binding.tap.isEmpty ? binding.hold : binding.tap
        let secondary = binding.tap.isEmpty ? "" : binding.hold

        // Reserve a band per legend so nothing overlaps: primary centred in whatever is
        // left after the secondary (top) and extra (bottom) bands.
        let smallSize = max(primarySize * 0.68, 6)
        let showsBands = rect.height >= 26
        let hasSecondary = showsBands && !secondary.isEmpty
        let hasExtra = showsBands && !binding.extra.isEmpty
        let bandHeight = smallSize + 4
        let secondaryColor = kind == .mapped
            ? NSColor.white.withAlphaComponent(0.62)
            : NSColor.white.withAlphaComponent(0.22)

        var primaryRect = rect.insetBy(dx: 2, dy: 1)

        if hasSecondary {
            drawText(
                secondary,
                in: NSRect(x: rect.minX + 3, y: rect.minY + 2, width: rect.width - 6, height: bandHeight),
                size: smallSize,
                color: secondaryColor,
                alignment: .left
            )
            primaryRect.origin.y += bandHeight
            primaryRect.size.height -= bandHeight
        }
        if hasExtra {
            drawText(
                binding.extra,
                in: NSRect(x: rect.minX + 3, y: rect.maxY - bandHeight - 2, width: rect.width - 6, height: bandHeight),
                size: smallSize,
                color: secondaryColor,
                alignment: .right
            )
            primaryRect.size.height -= bandHeight
        }

        drawText(primary, in: primaryRect, size: primarySize, color: borderColor)
    }

    private func drawIndicator() {
        guard let text = indicator, !text.isEmpty else { return }
        drawText(
            text,
            in: NSRect(x: Self.padding, y: 2, width: bounds.width - Self.padding * 2, height: Self.indicatorHeight - 4),
            size: 11,
            color: NSColor.white.withAlphaComponent(0.55),
            alignment: .left
        )
    }

    private func drawText(
        _ string: String,
        in rect: NSRect,
        size: CGFloat,
        color: NSColor,
        alignment: NSTextAlignment = .center
    ) {
        guard !string.isEmpty, size >= 6, rect.width > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(
            in: rect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    // MARK: - Geometry

    private static func boundingBox(of keys: [PhysicalKey]) -> NSRect {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for key in keys {
            minX = min(minX, key.x)
            minY = min(minY, key.y)
            maxX = max(maxX, key.x + key.width)
            maxY = max(maxY, key.y + key.height)
        }
        guard minX <= maxX, minY <= maxY else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
