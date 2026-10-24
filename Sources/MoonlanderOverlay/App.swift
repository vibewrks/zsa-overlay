import AppKit
import MoonlanderOverlayKit

@main
enum MoonlanderOverlayApp {
    @MainActor static let delegate = AppDelegate()

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--print-identity") {
            if let identity = KeyboardIdentityReader.flashedIdentity() {
                print(identity.serialNumber)
            } else {
                print("no ZSA board found, or its USB serial is not in <layout>/<revision> form")
            }
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instanceNotification = Notification.Name("com.vibewrks.MoonlanderOverlay.toggle")
    private static let opacityValueTag = 1001

    private let controller = OverlayController()
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handOffToRunningInstance() else { return }

        controller.onStateChange = { [weak self] in self?.rebuildMenu() }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.instanceNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.controller.toggle() }
        }

        buildStatusItem()
        rebuildMenu()
        controller.show()

        hotKey = GlobalHotKey.toggleOverlayHotKey { [weak self] in self?.controller.toggle() }
        if hotKey == nil {
            FileHandle.standardError.write(Data("warning: ⌃⌥K is already taken\n".utf8))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// A second launch should surface the running overlay rather than start a second helper.
    private func handOffToRunningInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.vibewrks.MoonlanderOverlay"
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current }
        guard !others.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Self.instanceNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "Moonlander layout overlay"
        )
        statusItem = item
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        menu.addItem(menuItem(controller.isVisible ? "Hide Overlay  (⌃⌥K)" : "Show Overlay  (⌃⌥K)",
                              action: #selector(toggleOverlay)))
        menu.addItem(menuItem("Reveal Layout File", action: #selector(revealLayoutFile)))
        menu.addItem(.separator())

        let follow = menuItem("Follow Keyboard", action: #selector(followKeyboard))
        follow.state = controller.isFollowingKeyboard ? .on : .off
        menu.addItem(follow)

        let release = menuItem("Release Keyboard (Manual Reference)", action: #selector(releaseKeyboard))
        release.isEnabled = controller.isFollowingKeyboard
        menu.addItem(release)

        let layerItem = NSMenuItem(title: "Layer", action: nil, keyEquivalent: "")
        let layerMenu = NSMenu()
        for choice in controller.layerChoices {
            let item = menuItem("\(choice.index) · \(choice.title)", action: #selector(selectLayer(_:)))
            item.representedObject = choice.index
            item.state = choice.index == controller.currentLayerIndex ? .on : .off
            layerMenu.addItem(item)
        }
        layerItem.submenu = layerMenu
        menu.addItem(layerItem)

        let pinned = menuItem("Pinned (click-through)", action: #selector(togglePinned))
        pinned.state = controller.isPinned ? .on : .off
        menu.addItem(pinned)

        let ledColors = menuItem("Use LED Colors", action: #selector(toggleLedColors))
        ledColors.state = controller.highlightStyle == .ledColor ? .on : .off
        menu.addItem(ledColors)

        let layerName = menuItem("Show Layer Name", action: #selector(toggleLayerName))
        layerName.state = controller.showsLayerName ? .on : .off
        menu.addItem(layerName)

        menu.addItem(opacityMenuItem())

        menu.addItem(menuItem("Larger  (drag edges to resize)", action: #selector(growOverlay)))
        menu.addItem(menuItem("Smaller", action: #selector(shrinkOverlay)))

        menu.addItem(.separator())

        let status = NSMenuItem(title: "\(controller.statusSummary) — \(controller.currentLayerTitle)",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let board = NSMenuItem(title: controller.boardSummary, action: nil, keyEquivalent: "")
        board.isEnabled = false
        menu.addItem(board)

        let retry = menuItem("Retry Keyboard Connection", action: #selector(retryStatus))
        retry.isEnabled = controller.isFollowingKeyboard
        menu.addItem(retry)

        menu.addItem(menuItem("Reload Layout", action: #selector(reloadKeymap)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", action: #selector(quit), key: "q"))

        statusItem.menu = menu
    }


    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// A menu item whose content is a live slider. A custom view replaces the
    /// item's title, so the label and percentage live inside the view.
    private func opacityMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 28))

        let label = NSTextField(labelWithString: "Opacity")
        label.frame = NSRect(x: 14, y: 6, width: 56, height: 17)
        label.font = .menuFont(ofSize: 0)
        container.addSubview(label)

        let slider = NSSlider(
            value: Double(controller.opacity),
            minValue: Double(OverlayController.opacityRange.lowerBound),
            maxValue: Double(OverlayController.opacityRange.upperBound),
            target: self,
            action: #selector(opacityChanged(_:))
        )
        slider.frame = NSRect(x: 74, y: 3, width: 150, height: 22)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("Overlay opacity")
        container.addSubview(slider)

        let value = NSTextField(labelWithString: Self.percentString(controller.opacity))
        value.frame = NSRect(x: 228, y: 6, width: 34, height: 17)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.tag = Self.opacityValueTag
        container.addSubview(value)

        item.view = container
        return item
    }

    private static func percentString(_ opacity: CGFloat) -> String {
        "\(Int((opacity * 100).rounded()))%"
    }

    @objc private func toggleOverlay() { controller.toggle() }
    @objc private func revealLayoutFile() { controller.revealLayoutFile() }
    @objc private func followKeyboard() { controller.followKeyboard() }
    @objc private func releaseKeyboard() { controller.selectLayer(controller.currentLayerIndex) }
    @objc private func togglePinned() { controller.setPinned(!controller.isPinned) }
    @objc private func toggleLedColors() {
        controller.setHighlightStyle(controller.highlightStyle == .ledColor ? .systemAccent : .ledColor)
    }

    @objc private func toggleLayerName() {
        controller.setShowsLayerName(!controller.showsLayerName)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        controller.setOpacity(CGFloat(sender.doubleValue))
        if let value = sender.superview?.viewWithTag(Self.opacityValueTag) as? NSTextField {
            value.stringValue = Self.percentString(controller.opacity)
        }
    }
    @objc private func growOverlay() { controller.grow() }
    @objc private func shrinkOverlay() { controller.shrink() }
    @objc private func retryStatus() { controller.retryStatus() }
    @objc private func reloadKeymap() { controller.reloadKeymap() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectLayer(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        controller.selectLayer(index)
    }
}
