import AppKit

/// Owns the overlay window, keymap, and direct-HID layer/physical-key source.
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
    public private(set) var opacity: CGFloat = 1
    /// Zero would make the overlay vanish, so the menu slider stops at ten percent.
    public static let opacityRange: ClosedRange<CGFloat> = 0.1...1.0
    public private(set) var showsLayerName = true
    public var currentLayerIndex: Int { displayLayerIndex }
    public private(set) var highlightStyle: KeyHighlightStyle = .ledColor
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
            return "following keyboard · direct HID"
        case .live(let message):
            return message.message
        case .stale:
            return "keyboard state unavailable"
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
    private var client: KeyboardStateClient?
    private var keymap: Keymap?
    private var followingKeyboard = true
    private var manualLayer = 0
    private var reportedLayer: Int?
    private var availability: KeyboardStateClient.Availability = .stopped
    private var loadFailure: String?
    private var flashedIdentity: KeyboardIdentity?

    private static let frameDefaultsKey = "OverlayPanelFrame"
    private static let manualLayerKey = "ManualLayerIndex"
    private static let followsKeyboardKey = "FollowsKeyboard"
    private static let highlightStyleKey = "KeyHighlightStyle"
    private static let opacityKey = "OverlayOpacity"
    private static let showsLayerNameKey = "ShowsLayerName"

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
        highlightStyle = KeyHighlightStyle(
            rawValue: defaults.string(forKey: Self.highlightStyleKey) ?? "") ?? .ledColor
        let savedOpacity = defaults.object(forKey: Self.opacityKey) as? Double ?? 1
        opacity = Self.clampedOpacity(CGFloat(savedOpacity))
        panel.alphaValue = opacity
        showsLayerName = defaults.object(forKey: Self.showsLayerNameKey) as? Bool ?? true
        view.showsLayerName = showsLayerName
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

    public func setHighlightStyle(_ style: KeyHighlightStyle) {
        highlightStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.highlightStyleKey)
        applyState()
    }

    /// Applies immediately and persists for the next launch. Deliberately does not
    /// fire `onStateChange`, so dragging the menu slider does not rebuild the menu.
    public func setOpacity(_ value: CGFloat) {
        let clamped = Self.clampedOpacity(value)
        guard clamped != opacity else { return }
        opacity = clamped
        panel.alphaValue = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.opacityKey)
    }

    private static func clampedOpacity(_ value: CGFloat) -> CGFloat {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    public func setShowsLayerName(_ shows: Bool) {
        showsLayerName = shows
        UserDefaults.standard.set(shows, forKey: Self.showsLayerNameKey)
        view.showsLayerName = shows
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
            availability = .stopped
            reportedLayer = nil
            view.pressedKeyIDs = []
            return
        }
        guard let sidecarURL = KeyboardStateClient.resolveSidecarURL() else {
            handle(.stale)
            return
        }
        if client == nil {
            let client = KeyboardStateClient(sidecarURL: sidecarURL)
            client.onUpdate = { [weak self] availability in
                self?.handle(availability)
            }
            self.client = client
        }
        client?.start()
    }

    private func handle(_ availability: KeyboardStateClient.Availability) {
        let previousLayer = displayLayerIndex
        let previousSummary = statusSummary
        let previousBoard = boardSummary
        let wasConnected: Bool
        if case .live(let message) = self.availability, message.state == .connected {
            wasConnected = true
        } else {
            wasConnected = false
        }
        self.availability = availability
        var pressed: Set<Int> = []
        reportedLayer = nil
        if followingKeyboard, isVisible, case .live(let message) = availability,
           message.state == .connected, let layer = message.layer {
            reportedLayer = layer
            pressed = message.pressedKeyIDs
            if !wasConnected { refreshFlashedIdentity() }
        }
        view.pressedKeyIDs = pressed
        applyState(notifyMenu: previousLayer != displayLayerIndex
            || previousSummary != statusSummary || previousBoard != boardSummary)
    }

    private func applyState(notifyMenu: Bool = true) {
        let layerName = "[\(displayLayerIndex)] \(title(forLayer: displayLayerIndex) ?? "?")"
        view.layerName = followingKeyboard ? layerName : "\(layerName) · manual"
        view.showsLayerName = showsLayerName
        view.indicator = statusWarning
        view.activeLayerIndex = displayLayerIndex
        view.highlightStyle = highlightStyle
        if notifyMenu { onStateChange?() }
    }

    /// Warning/error text that takes over the top strip; nil while live.
    private var statusWarning: String? {
        if let loadFailure { return loadFailure }
        if let revisionWarning { return revisionWarning }
        guard followingKeyboard else { return nil }
        switch availability {
        case .live(let message) where message.state == .connected && message.layer != nil:
            return nil
        case .live(let message) where message.state == .disconnected:
            return "⚠️ No Moonlander connected · showing layer \(manualLayer) (not live)"
        case .live(let message) where message.state == .busy:
            return "⚠️ Keyboard in use — disconnect/quit Keymapp · not live"
        case .live(let message):
            return "⚠️ \(message.message) · not live"
        case .stale:
            return "⚠️ No keyboard state · showing layer \(manualLayer) (not live)"
        case .starting:
            return "connecting directly to Moonlander…"
        case .stopped:
            return "not following keyboard — layer \(manualLayer) · \(title(forLayer: manualLayer) ?? "?")"
        }
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
