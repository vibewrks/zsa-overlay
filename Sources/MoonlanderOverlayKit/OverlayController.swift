import AppKit

/// Owns the overlay window, the keymap, and the live layer source.
@MainActor
public final class OverlayController: NSObject, NSWindowDelegate {
    public struct LayerChoice: Sendable, Equatable {
        public let index: Int
        public let title: String
    }

    /// Fired whenever menu-visible state changes.
    public var onStateChange: (() -> Void)?

    public var isVisible: Bool { panel.isVisible }
    public var isPinned: Bool { panel.ignoresMouseEvents }
    public var isFollowingKeyboard: Bool { followingKeyboard }
    public var keymapTitle: String { keymap.map { "\($0.title) · \($0.revision)" } ?? "no layout loaded" }
    public var layerChoices: [LayerChoice] {
        (keymap?.layers ?? []).map { LayerChoice(index: $0.index, title: $0.title) }
    }
    public var currentLayerTitle: String {
        if followingKeyboard, let reportedLayer, let title = title(forLayer: reportedLayer) {
            return "\(title) (\(reportedLayer))"
        }
        return "\(title(forLayer: manualLayer) ?? "layer") (\(manualLayer)) · manual"
    }
    public var statusSummary: String {
        switch availability {
        case .live(let message) where message.state == .connected:
            return "following keyboard"
        case .live(let message):
            return message.message
        case .stale:
            return "layer status unavailable"
        case .starting:
            return "connecting…"
        case .stopped:
            return "not following"
        }
    }

    /// Non-nil when the board reports a revision the overlay was not built from,
    /// in which case the keycaps may not match what the keyboard actually does.
    public var revisionWarning: String? {
        guard let keymap, let flashedIdentity, !flashedIdentity.matches(revision: keymap.revision) else {
            return nil
        }
        return "⚠️ board \(flashedIdentity.revision) · overlay \(keymap.revision) — re-import layout"
    }

    public var boardSummary: String {
        guard let flashedIdentity else { return "board: flashed revision not readable" }
        guard let keymap else { return "board: \(flashedIdentity.serialNumber)" }
        let mark = flashedIdentity.matches(revision: keymap.revision) ? "✓" : "⚠️"
        return "board: \(flashedIdentity.serialNumber) · overlay: \(keymap.revision) \(mark)"
    }

    private func refreshFlashedIdentity() {
        flashedIdentity = KeyboardIdentityReader.flashedIdentity()
    }

    private let view = KeyboardView()
    private let panel: OverlayPanel
    private var client: LayerStatusClient?
    private var keymap: Keymap?
    private var followingKeyboard = true
    private var manualLayer = 0
    private var reportedLayer: Int?
    private var availability: LayerStatusClient.Availability = .stopped
    private var loadFailure: String?
    private var flashedIdentity: KeyboardIdentity?

    private static let frameDefaultsKey = "OverlayPanelFrame"
    private static let manualLayerKey = "ManualLayerIndex"
    private static let followsKeyboardKey = "FollowsKeyboard"

    public override init() {
        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
            contentView: view
        )
        super.init()
        panel.onEscape = { [weak self] in self?.hide() }
        panel.delegate = self
        view.onFrameChange = { [weak self] in self?.saveFrame() }
        view.showsResizeGrip = !panel.ignoresMouseEvents
        let defaults = UserDefaults.standard
        followingKeyboard = defaults.object(forKey: Self.followsKeyboardKey) as? Bool ?? true
        manualLayer = defaults.integer(forKey: Self.manualLayerKey)
        refreshFlashedIdentity()
        loadKeymap()
        applyState()
    }

    // MARK: - Visibility

    public func show() {
        refreshFlashedIdentity()
        if let saved = savedFrame() {
            panel.setFrame(saved, display: false)
        } else if let screen = NSScreen.main {
            panel.setFrame(defaultFrame(on: screen), display: false)
        }
        panel.orderFrontRegardless()
        updateClientLifecycle()
        applyState()
    }

    public func hide() {
        saveFrame()
        panel.orderOut(nil)
        updateClientLifecycle()
        onStateChange?()
    }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func shutdown() {
        saveFrame()
        client?.stop()
        client = nil
    }

    // MARK: - Mode switches

    public func setPinned(_ pinned: Bool) {
        panel.ignoresMouseEvents = pinned
        view.showsResizeGrip = !pinned
        applyState()
    }

    /// The caps scale to whatever size the panel has; drag its edges, or use the menu.
    public func grow() { scalePanel(by: 1.15) }
    public func shrink() { scalePanel(by: 1 / 1.15) }

    public func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    private func scalePanel(by factor: CGFloat) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let current = panel.frame
        let width = min(max(current.width * factor, panel.minSize.width), visible.width * 0.95)
        let height = min(max(current.height * factor, panel.minSize.height), visible.height * 0.95)
        var origin = current.origin
        origin.x = max(visible.minX, min(origin.x, visible.maxX - width))
        origin.y = max(visible.minY, min(origin.y + current.height - height, visible.maxY - height))
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        saveFrame()
    }

    public func followKeyboard() {
        followingKeyboard = true
        UserDefaults.standard.set(true, forKey: Self.followsKeyboardKey)
        updateClientLifecycle()
        applyState()
    }

    public func selectLayer(_ index: Int) {
        followingKeyboard = false
        manualLayer = index
        UserDefaults.standard.set(false, forKey: Self.followsKeyboardKey)
        UserDefaults.standard.set(index, forKey: Self.manualLayerKey)
        updateClientLifecycle()
        applyState()
    }

    public func reloadKeymap() {
        refreshFlashedIdentity()
        loadKeymap()
        applyState()
    }

    public func revealLayoutFile() {
        guard let url = Self.resolvedKeymapURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func retryStatus() {
        client?.restartNow()
    }

    // MARK: - Wiring

    private func loadKeymap() {
        do {
            let keymap = try Self.loadKeymapFromDisk()
            try keymap.validate()
            self.keymap = keymap
            view.keymap = keymap
            loadFailure = nil
            if keymap.layers.allSatisfy({ $0.index != manualLayer }) {
                manualLayer = keymap.layers.first?.index ?? 0
            }
        } catch {
            loadFailure = "layout error: \(error)"
            keymap = nil
            view.keymap = nil
        }
    }

    private func updateClientLifecycle() {
        guard followingKeyboard, isVisible else {
            client?.stop()
            return
        }
        guard let sidecarURL = LayerStatusClient.resolveSidecarURL() else {
            availability = .stale
            return
        }
        if client == nil {
            let client = LayerStatusClient(sidecarURL: sidecarURL)
            client.onUpdate = { [weak self] availability in
                self?.handle(availability)
            }
            self.client = client
        }
        client?.start()
    }

    private func handle(_ availability: LayerStatusClient.Availability) {
        self.availability = availability
        switch availability {
        case .live(let message):
            if message.state == .connected, let layer = message.layer {
                reportedLayer = layer
            } else {
                reportedLayer = nil
            }
        case .starting, .stale, .stopped:
            reportedLayer = nil
        }
        applyState()
    }

    private func applyState() {
        if let loadFailure {
            view.indicator = loadFailure
        } else if let revisionWarning {
            view.indicator = revisionWarning
        } else if followingKeyboard {
            switch availability {
            case .live(let message) where message.state == .connected && message.layer != nil:
                view.indicator = "layer \(displayLayerIndex) · \(title(forLayer: displayLayerIndex) ?? "?")"
            case .live(let message) where message.state == .disconnected:
                view.indicator = "⚠️ No keyboard connected · showing layer \(manualLayer) (not live)"
            case .live:
                view.indicator = "⚠️ Keymapp not reachable · showing layer \(manualLayer) (not live)"
            case .stale:
                view.indicator = "⚠️ no layer status — showing layer \(manualLayer) (manual); Keymapp may be closed"
            case .starting:
                view.indicator = "connecting to Keymapp…"
            case .stopped:
                view.indicator = "not following keyboard — layer \(manualLayer) · \(title(forLayer: manualLayer) ?? "?")"
            }
        } else {
            view.indicator = "layer \(manualLayer) · \(title(forLayer: manualLayer) ?? "?") · manual"
        }
        view.activeLayerIndex = displayLayerIndex
        onStateChange?()
    }

    private var displayLayerIndex: Int {
        if followingKeyboard, let reportedLayer { return reportedLayer }
        return manualLayer
    }

    private func title(forLayer index: Int) -> String? {
        keymap?.layers.first { $0.index == index }?.title
    }

    // MARK: - Geometry

    private func defaultFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(1000, visible.width * 0.62)
        let height = width / max(view.contentAspectRatio, 0.5) + 34
        return NSRect(
            x: visible.maxX - width - 24,
            y: visible.maxY - height - 24,
            width: width,
            height: height
        )
    }

    private func savedFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else { return nil }
        let frame = NSRectFromString(raw)
        guard frame.width > 200, frame.height > 100 else { return nil }
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    private func saveFrame() {
        guard isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
    }

    /// Environment override, then the app bundle's Resources, then the SwiftPM resource
    /// bundle (which covers `swift run` and `swift test`).
    private static func resolvedKeymapURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MOONLANDER_KEYMAP"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let url = Bundle.main.url(forResource: "keymap", withExtension: "json") { return url }
        return Bundle.module.url(forResource: "keymap", withExtension: "json")
    }

    private static func loadKeymapFromDisk() throws -> Keymap {
        if let url = resolvedKeymapURL() { return try Keymap.load(url: url) }
        return try Keymap.bundled()
    }
}
