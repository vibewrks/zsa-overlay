import Testing

@testable import MoonlanderOverlayKit

@Suite("Keyboard identity")
struct KeyboardIdentityTests {
    @Test("parses the ZSA layout/revision serial form")
    func parsesSerial() {
        let identity = KeyboardIdentity(usbSerialNumber: "GMrOw/rba3al")
        #expect(identity?.layoutHash == "GMrOw")
        #expect(identity?.revision == "rba3al")
        #expect(identity?.serialNumber == "GMrOw/rba3al")
    }

    @Test("tolerates surrounding whitespace")
    func toleratesWhitespace() {
        #expect(KeyboardIdentity(usbSerialNumber: " GMrOw / rba3al ")?.revision == "rba3al")
    }

    @Test(
        "rejects anything that is not a layout/revision pair",
        arguments: ["", "/", "GMrOw", "GMrOw/", "/rba3al", "plainserialnumber", "GMrOw//rba3al", "GMrOw/rba3al/extra", "/GMrOw/rba3al", "GMrOw/rba3al/"]
    )
    func rejectsOtherForms(serial: String) {
        #expect(KeyboardIdentity(usbSerialNumber: serial) == nil)
    }

    @Test("revision comparison drives the drift warning")
    func revisionComparison() {
        let identity = KeyboardIdentity(usbSerialNumber: "GMrOw/rba3al")
        #expect(identity?.matches(revision: "rba3al") == true)
        #expect(identity?.matches(revision: "5pWAmQ") == false)
    }
}
