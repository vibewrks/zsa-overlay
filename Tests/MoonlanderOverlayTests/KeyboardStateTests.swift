import Foundation
import Testing

@testable import MoonlanderOverlayKit

/// The helper prints whole snapshots, never events; these tests pin how the client
/// decodes that stream and which records it refuses outright.
@Suite("Keyboard state stream")
struct KeyboardStateTests {
    @Test("decodes a complete connected snapshot")
    func decodesConnectedSnapshot() throws {
        let json = #"{"state":"connected","layer":3,"pressed":[{"row":0,"column":0}],"message":"","keyboard":"Moonlander MK1"}"#
        let message = try #require(KeyboardStateParser.parse(line: Data(json.utf8)))
        #expect(message.state == .connected)
        #expect(message.layer == 3)
        #expect(message.keyboard == "Moonlander MK1")
        #expect(message.pressedKeyIDs == [0])
    }

    @Test(
        "maps matrix positions to Oryx key ids",
        arguments: zip(
            [
                #"{"row":0,"column":0}"#,
                #"{"row":0,"column":6}"#,
                #"{"row":5,"column":3}"#,
                #"{"row":11,"column":3}"#,
                #"{"row":11,"column":6}"#,
                #"{"row":9,"column":1}"#,
            ],
            [0, 6, 32, 68, 71, 57]
        )
    )
    func mapsPositionToOryxKeyID(positionJSON: String, expectedKeyID: Int) throws {
        let json = #"{"state":"connected","layer":0,"pressed":[\#(positionJSON)],"message":"","keyboard":null}"#
        let message = try #require(KeyboardStateParser.parse(line: Data(json.utf8)))
        #expect(message.pressedKeyIDs == [expectedKeyID])
    }

    @Test("a full 72-key snapshot maps every position exactly once")
    func mapsEveryMatrixPosition() throws {
        let pressed = MoonlanderMatrix.oryxToMatrix
            .map { #"{"row":\#($0.row),"column":\#($0.column)}"# }
            .joined(separator: ",")
        let json = #"{"state":"connected","layer":6,"pressed":[\#(pressed)],"message":"","keyboard":null}"#
        let message = try #require(KeyboardStateParser.parse(line: Data(json.utf8)))
        #expect(message.pressedKeyIDs == Set(0..<72))
    }

    @Test("held keys survive a layer switch")
    func heldKeysSurviveLayerSwitch() throws {
        let held = #""pressed":[{"row":3,"column":3},{"row":4,"column":4}]"#
        let before = try #require(KeyboardStateParser.parse(line: Data(#"{"state":"connected","layer":2,\#(held),"message":"","keyboard":null}"#.utf8)))
        let after = try #require(KeyboardStateParser.parse(line: Data(#"{"state":"connected","layer":4,\#(held),"message":"","keyboard":null}"#.utf8)))
        #expect(before.layer == 2)
        #expect(after.layer == 4)
        #expect(before.pressedKeyIDs == [24, 31])
        #expect(after.pressedKeyIDs == before.pressedKeyIDs)
    }

    @Test("a non-connected snapshot never carries layer or held keys", arguments: [
        "busy", "disconnected", "unavailable",
    ])
    func nonConnectedSnapshotIsCleared(state: String) throws {
        let clean = #"{"state":"\#(state)","layer":null,"pressed":[],"message":"not live","keyboard":null}"#
        let message = try #require(KeyboardStateParser.parse(line: Data(clean.utf8)))
        #expect(message.state == KeyboardConnectionState(rawValue: state))
        #expect(message.layer == nil)
        #expect(message.pressedKeyIDs.isEmpty)

        // Even a self-contradicting record — a layer, or key data — while not connected
        // becomes a cleared snapshot instead of stale highlights; the payload is ignored.
        let stray = #"{"state":"\#(state)","layer":2,"pressed":[{"row":99,"column":99}],"message":"","keyboard":null}"#
        let strayMessage = try #require(KeyboardStateParser.parse(line: Data(stray.utf8)))
        #expect(strayMessage.layer == nil)
        #expect(strayMessage.pressedKeyIDs.isEmpty)
    }

    @Test("an unknown state is refused, not guessed", arguments: ["sleeping", "Connected", ""])
    func rejectsUnknownState(state: String) {
        let json = #"{"state":"\#(state)","layer":null,"pressed":[],"message":"","keyboard":null}"#
        #expect(KeyboardStateParser.parse(line: Data(json.utf8)) == nil)
    }

    @Test("a record without a state is refused")
    func rejectsMissingState() {
        #expect(KeyboardStateParser.parse(line: Data(#"{"layer":9}"#.utf8)) == nil)
        #expect(KeyboardStateParser.parse(line: Data(#"{"state":null,"layer":0,"pressed":[],"message":""}"#.utf8)) == nil)
    }

    @Test("connected snapshots require a byte-sized layer", arguments: ["null", "256", "-1", "3.5", "1e3", "\"2\""])
    func rejectsInvalidLayer(layerJSON: String) {
        let json = #"{"state":"connected","layer":\#(layerJSON),"pressed":[],"message":"","keyboard":null}"#
        #expect(KeyboardStateParser.parse(line: Data(json.utf8)) == nil)
    }

    @Test("a connected snapshot must carry the pressed array")
    func rejectsConnectedWithoutPressed() {
        let missing = #"{"state":"connected","layer":0,"message":"","keyboard":null}"#
        #expect(KeyboardStateParser.parse(line: Data(missing.utf8)) == nil)

        let null = #"{"state":"connected","layer":0,"pressed":null,"message":"","keyboard":null}"#
        #expect(KeyboardStateParser.parse(line: Data(null.utf8)) == nil)
    }

    @Test("layers are accepted across the whole byte range", arguments: [0, 1, 128, 255])
    func acceptsByteSizedLayer(layer: Int) throws {
        let json = #"{"state":"connected","layer":\#(layer),"pressed":[],"message":"","keyboard":null}"#
        let message = try #require(KeyboardStateParser.parse(line: Data(json.utf8)))
        #expect(message.layer == layer)
    }

    @Test("matrix positions outside the verified table are rejected", arguments: [
        #"{"row":9,"column":0}"#,
        #"{"row":4,"column":5}"#,
        #"{"row":0,"column":7}"#,
        #"{"row":12,"column":0}"#,
        #"{"row":-1,"column":0}"#,
        #"{"row":0,"column":-1}"#,
        #"{"row":0.5,"column":0}"#,
        #"{"row":0,"column":null}"#,
    ])
    func rejectsUnknownMatrixPosition(positionJSON: String) {
        let json = #"{"state":"connected","layer":0,"pressed":[\#(positionJSON)],"message":"","keyboard":null}"#
        #expect(KeyboardStateParser.parse(line: Data(json.utf8)) == nil)
    }

    @Test("several snapshots per read and a trailing partial record")
    func handlesMultipleRecordsPerRead() throws {
        var parser = KeyboardStateParser()
        let first = #"{"state":"unavailable","layer":null,"pressed":[],"message":"connecting","keyboard":null}"# + "\n"
        let second = #"{"state":"connected","layer":0,"pressed":[],"message":"","keyboard":"Moonlander MK1"}"#
        let messages = parser.consume(Data((first + second).utf8))
        #expect(messages.count == 1)
        #expect(messages.first?.state == .unavailable)

        let tail = parser.consume(Data("\n".utf8))
        #expect(tail.count == 1)
        #expect(tail.first?.layer == 0)
    }

    @Test("skips blank and malformed lines without losing later snapshots")
    func skipsNoise() throws {
        var parser = KeyboardStateParser()
        let chunk = "\r\nnot json\n\r\n" + #"{"state":"connected","layer":5,"pressed":[],"message":"","keyboard":null}"# + "\r\n"
        let messages = parser.consume(Data(chunk.utf8))
        #expect(messages.count == 1)
        #expect(messages.first?.layer == 5)
    }

    @Test("a snapshot split anywhere still decodes, including inside a multibyte label")
    func reassemblesSplitSnapshot() throws {
        let label = "übergrößenträger ⌘⌥⇧⌃ — キー"
        let json = #"{"state":"connected","layer":1,"pressed":[{"row":3,"column":3}],"message":"\#(label)","keyboard":"Moonlander MK1"}"# + "\n"
        let bytes = Data(json.utf8)

        for split in 1..<bytes.count {
            var parser = KeyboardStateParser()
            #expect(parser.consume(bytes.prefix(split)).isEmpty, "split \(split) emitted a partial snapshot")
            let messages = parser.consume(bytes.suffix(from: split))
            #expect(messages.count == 1, "split \(split)")
            let message = try #require(messages.first)
            #expect(message.message == label)
            #expect(message.layer == 1)
            #expect(message.pressedKeyIDs == [24])
        }
    }

    @Test("a fresh helper session cannot inherit a truncated record")
    func resetDropsPartialRecord() throws {
        var parser = KeyboardStateParser()
        #expect(parser.consume(Data(#"{"state":"connected","layer":9,"pressed":["#.utf8)).isEmpty)

        parser.reset()
        let next = #"{"state":"connected","layer":1,"pressed":[],"message":"","keyboard":null}"# + "\n"
        let messages = parser.consume(Data(next.utf8))
        #expect(messages.count == 1)
        #expect(messages.first?.layer == 1)
    }

    @Test("an unterminated record cannot grow the buffer without bound")
    func dropsRunawayUnterminatedRecord() throws {
        var parser = KeyboardStateParser()
        #expect(parser.consume(Data(repeating: 0x78, count: 128 * 1024)).isEmpty)

        let json = #"{"state":"disconnected","layer":null,"pressed":[],"message":"","keyboard":null}"# + "\n"
        let messages = parser.consume(Data(json.utf8))
        #expect(messages.count == 1)
        #expect(messages.first?.state == .disconnected)
    }
}
