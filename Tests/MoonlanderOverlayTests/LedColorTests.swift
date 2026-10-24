import AppKit
import Testing

import MoonlanderOverlayKit

// MARK: - Fixtures

private func requireColor(_ hex: String) throws -> NSColor {
    try #require(NSColor(ledHex: hex))
}

private func components(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
    guard let rgb = color.usingColorSpace(.sRGB) else { return (-1, -1, -1) }
    return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
}

// MARK: - LED hex parsing

@Suite("LED hex parsing")
struct LedHexTests {

    @Test func parsesUppercaseHex() throws {
        let (r, g, b) = components(try requireColor("#FFB900"))
        #expect(abs(r - 1.0) < 0.005)
        #expect(abs(g - 185 / 255) < 0.005)
        #expect(abs(b - 0.0) < 0.005)
    }

    @Test func parsesLowercaseHex() throws {
        let (r, g, b) = components(try requireColor("#00f0ff"))
        #expect(abs(r - 0.0) < 0.005)
        #expect(abs(g - 240 / 255) < 0.005)
        #expect(abs(b - 1.0) < 0.005)
    }

    @Test func trimsSurroundingWhitespace() throws {
        let (r, g, b) = components(try requireColor("  #0075FF  "))
        #expect(abs(r - 0.0) < 0.005)
        #expect(abs(g - 117 / 255) < 0.005)
        #expect(abs(b - 1.0) < 0.005)
    }

    @Test func rejectsMalformedHex() {
        for bad in ["", "FFB900", "#FFF", "#FFB900FF", "#ZZZZZZ", "#FF00G0", "#", "#  "] {
            #expect(NSColor(ledHex: bad) == nil, "rejected \(bad)")
        }
    }
}

// MARK: - Highlight style

@Suite("Highlight style")
struct HighlightStyleTests {

    @Test func rawValuesRoundTrip() {
        #expect(KeyHighlightStyle(rawValue: "ledColor") == .ledColor)
        #expect(KeyHighlightStyle(rawValue: "systemAccent") == .systemAccent)
        #expect(KeyHighlightStyle(rawValue: "neon") == nil)
        #expect(KeyHighlightStyle.ledColor.rawValue == "ledColor")
    }
}
