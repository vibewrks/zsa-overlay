import Foundation
import Testing

@testable import MoonlanderOverlayKit

@Suite("Sidecar status stream")
struct LayerStatusTests {
    @Test("decodes a complete connected record")
    func decodesConnectedRecord() {
        let line = Data(#"{"state":"connected","layer":3,"message":"ok","keyboard":"Moonlander"}"#.utf8)
        let message = StatusLineParser.parse(line: line)
        #expect(message?.state == .connected)
        #expect(message?.layer == 3)
        #expect(message?.keyboard == "Moonlander")
    }

    @Test("decodes a disconnected record with no layer")
    func decodesDisconnectedRecord() {
        let line = Data(#"{"state":"disconnected","layer":null,"message":"no keyboard","keyboard":null}"#.utf8)
        let message = StatusLineParser.parse(line: line)
        #expect(message?.state == .disconnected)
        #expect(message?.layer == nil)
    }

    @Test("reassembles a record split across chunks")
    func reassemblesPartialLine() {
        var parser = StatusLineParser()
        let full = Data(#"{"state":"connected","layer":2,"message":"ok","keyboard":null}"#.utf8)
        let splitPoint = full.count / 2

        let first = parser.consume(full.prefix(splitPoint))
        #expect(first.isEmpty)

        var remainder = full.suffix(from: splitPoint)
        remainder.append(contentsOf: Data("\n".utf8))
        let second = parser.consume(remainder)
        #expect(second.count == 1)
        #expect(second.first?.layer == 2)
    }

    @Test("handles several records and a trailing partial in one chunk")
    func handlesMultipleRecordsPerChunk() {
        var parser = StatusLineParser()
        let chunk = Data("""
        {"state":"unavailable","layer":null,"message":"connecting","keyboard":null}\n
        {"state":"connected","layer":0,"message":"ok","keyboard":"Moonlander"}\n
        {"state":"connected","layer":1,
        """.utf8)

        let messages = parser.consume(chunk)
        #expect(messages.count == 2)
        #expect(messages.first?.state == .unavailable)
        #expect(messages.last?.layer == 0)

        let tail = parser.consume(Data((#""message":"ok","keyboard":"Moonlander"}"# + "\n").utf8))
        #expect(tail.count == 1)
        #expect(tail.first?.layer == 1)
    }

    @Test("skips blank and malformed lines without losing later records")
    func skipsNoise() {
        var parser = StatusLineParser()
        let messages = parser.consume(Data("""
        \n
        not json\n
        {"state":"connected","layer":5,"message":"ok","keyboard":null}\n
        """.utf8))
        #expect(messages.count == 1)
        #expect(messages.first?.layer == 5)
    }

    @Test("decode failure is nil rather than a fabricated layer")
    func neverFabricatesLayer() {
        #expect(StatusLineParser.parse(line: Data(#"{"layer":9}"#.utf8)) == nil)
    }
}
