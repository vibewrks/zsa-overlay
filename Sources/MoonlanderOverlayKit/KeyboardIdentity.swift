import Foundation
import IOKit

/// What the board says it is running.
///
/// ZSA puts the Oryx layout hash and the flashed revision into the USB serial
/// number, e.g. `GMrOw/rba3al` — so the flashed revision can be read straight off
/// the device, with no permissions, no Keymapp, and no claim on its HID interfaces.
public struct KeyboardIdentity: Sendable, Equatable {
    public let layoutHash: String
    public let revision: String

    public init(layoutHash: String, revision: String) {
        self.layoutHash = layoutHash
        self.revision = revision
    }

    /// Parses the `<layout hash>/<revision>` serial form; nil for anything else.
    public init?(usbSerialNumber: String) {
        let parts = usbSerialNumber
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(layoutHash: parts[0], revision: parts[1])
    }

    public var serialNumber: String { "\(layoutHash)/\(revision)" }

    /// True when the overlay was built from exactly the revision the board reports.
    public func matches(revision other: String) -> Bool {
        revision == other
    }
}

public enum KeyboardIdentityReader {
    /// Reads the connected ZSA board's serial number from IOKit. Returns nil when no
    /// board is attached or its serial is not in the layout/revision form.
    public static func flashedIdentity() -> KeyboardIdentity? {
        guard let serialNumber = zsaUSBDeviceSerialNumber() else { return nil }
        return KeyboardIdentity(usbSerialNumber: serialNumber)
    }

    private static func zsaUSBDeviceSerialNumber() -> String? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let vendor = dictionary["USB Vendor Name"] as? String,
                  vendor.contains("ZSA"),
                  let serialNumber = dictionary["USB Serial Number"] as? String
            else { continue }
            return serialNumber
        }
        return nil
    }
}
