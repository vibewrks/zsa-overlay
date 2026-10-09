import AppKit
import Carbon.HIToolbox

/// System-wide hotkey built on Carbon's `RegisterEventHotKey`.
/// Carbon hotkeys do not need Accessibility permission, unlike `NSEvent` global monitors.
public final class GlobalHotKey {
    private let registration: HotKeyRegistration

    public init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        guard HotKeyRegistry.shared.installHandlerIfNeeded() else { return nil }
        let id = HotKeyRegistry.shared.add(action)
        guard let registration = HotKeyRegistration(id: id, keyCode: keyCode, modifiers: modifiers) else {
            HotKeyRegistry.shared.remove(id)
            return nil
        }
        self.registration = registration
    }

    /// ⌃⌥K — toggle the overlay.
    public static func toggleOverlayHotKey(action: @escaping @MainActor () -> Void) -> GlobalHotKey? {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            action: action
        )
    }
}

/// Owns one OS hotkey registration and unregisters it when released.
/// The Carbon reference is a bare pointer, so ownership lives in its own
/// nonisolated object rather than in an actor-isolated property.
private nonisolated final class HotKeyRegistration: @unchecked Sendable {
    private let id: UInt32
    private let reference: EventHotKeyRef

    init?(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: HotKeyRegistry.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return nil }
        self.id = id
        self.reference = reference
    }

    deinit {
        UnregisterEventHotKey(reference)
        HotKeyRegistry.shared.remove(id)
    }
}

/// Holds the registered actions, because the Carbon callback is a C function with no context.
/// Explicitly `nonisolated`: the module defaults to main-actor isolation, but the Carbon
/// callback and `HotKeyRegistration.deinit` both reach this from outside any actor.
private nonisolated final class HotKeyRegistry: @unchecked Sendable {
    static let shared = HotKeyRegistry()
    static let signature: OSType = 0x4D4C_4F56 // 'MLOV'

    private let lock = NSLock()
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    func add(_ action: @escaping @MainActor () -> Void) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        actions[id] = action
        return id
    }

    func remove(_ id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        actions[id] = nil
    }

    func invoke(_ id: UInt32) {
        lock.lock()
        let action = actions[id]
        lock.unlock()
        guard let action else { return }
        MainActor.assumeIsolated { action() }
    }

    func installHandlerIfNeeded() -> Bool {
        lock.lock()
        if handlerInstalled {
            lock.unlock()
            return true
        }
        lock.unlock()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == HotKeyRegistry.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = hotKeyID.id
                DispatchQueue.main.async { HotKeyRegistry.shared.invoke(id) }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
        guard status == noErr else { return false }

        lock.lock()
        handlerInstalled = true
        lock.unlock()
        return true
    }
}
