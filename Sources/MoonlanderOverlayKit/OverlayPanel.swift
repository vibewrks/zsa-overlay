import AppKit

/// Borderless, non-activating window that draws only keycaps — no panel background —
/// so the desktop stays visible through and around the keys.
public final class OverlayPanel: NSPanel {
    /// Called when Escape is pressed while the panel is key.
    public var onEscape: (() -> Void)?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: NSRect, contentView: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        minSize = NSSize(width: 420, height: 150)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.contentView = contentView
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
