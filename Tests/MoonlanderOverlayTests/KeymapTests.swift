import Foundation
import Testing

import MoonlanderOverlayKit

// MARK: - Fixtures

private func makeKeys() -> [PhysicalKey] {
    (0..<Keymap.moonlanderKeyCount).map { PhysicalKey(id: $0, x: Double($0), y: 0) }
}

private func makeBindings(_ overrides: [Int: KeyBinding] = [:]) -> [KeyBinding] {
    (0..<Keymap.moonlanderKeyCount).map { overrides[$0] ?? KeyBinding(kind: .transparent) }
}

private func makeKeymap(keys: [PhysicalKey]? = nil, layers: [Layer]? = nil) -> Keymap {
    Keymap(
        title: "test layout",
        revision: "test",
        keys: keys ?? makeKeys(),
        layers: layers ?? [Layer(index: 0, title: "base", bindings: makeBindings())]
    )
}

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("keymap-\(UUID().uuidString).json")
}

// MARK: - Bundled keymap

@Suite("Bundled keymap")
struct BundledKeymapTests {
    @Test func loadsTheBundledRevision() throws {
        let keymap = try Keymap.bundled()
        #expect(keymap.title == "learning dvorak")
        #expect(keymap.revision == "rba3al")
        #expect(keymap.keys.count == Keymap.moonlanderKeyCount)
        #expect(keymap.layers.map(\.index) == [0, 1, 2, 3, 4, 5, 6])
        #expect(keymap.layers.map(\.title) == ["qwerty", "command", "media", "mouse", "numpad", "cs2", "dvorak"])
    }

    @Test func physicalKeysAreSequentialAndCoverTheBoard() throws {
        let keymap = try Keymap.bundled()
        #expect(keymap.keys.map(\.id) == Array(0..<Keymap.moonlanderKeyCount))
        #expect(Set(keymap.keys.map(\.id)).count == Keymap.moonlanderKeyCount)
    }

    @Test func everyLayerAlignsWithThePhysicalKeys() throws {
        let keymap = try Keymap.bundled()
        for layer in keymap.layers {
            #expect(layer.bindings.count == keymap.keys.count, "layer \(layer.index)")
        }
    }

    @Test func geometryIsFinitePositiveAndNonOverlapping() throws {
        let keys = try Keymap.bundled().keys
        for key in keys {
            #expect(key.x.isFinite && key.y.isFinite, "key \(key.id)")
            #expect(key.rotation.isFinite && key.rotation == 0, "key \(key.id)")
            #expect(key.width > 0 && key.height > 0, "key \(key.id)")
        }
        for (index, first) in keys.enumerated() {
            for second in keys[(index + 1)...] {
                let overlaps = first.x < second.x + second.width
                    && second.x < first.x + first.width
                    && first.y < second.y + second.height
                    && second.y < first.y + first.height
                #expect(!overlaps, "keys \(first.id) and \(second.id) overlap")
            }
        }
    }

    @Test func thumbKeysKeepTheirWideGeometry() throws {
        let keys = try Keymap.bundled().keys
        #expect(keys[0] == PhysicalKey(id: 0, x: 0, y: 0.375))
        #expect(keys[32].width == 2 && keys[32].x == 5 && keys[32].y == 4.5)
        #expect(keys[33].height == 1.5 && keys[33].y == 5.5)
        #expect(keys[68].width == 2 && keys[68].x == 10 && keys[68].y == 4.5)
        #expect(keys[71].height == 1.5 && keys[71].y == 5.5)
    }

    @Test func bundledDataUsesEveryBindingKind() throws {
        let keymap = try Keymap.bundled()
        let kinds = Set(keymap.layers.flatMap { $0.bindings.map(\.kind) })
        #expect(kinds == [.mapped, .disabled, .transparent])
    }

    @Test func everyMappedBindingHasALegend() throws {
        let keymap = try Keymap.bundled()
        for layer in keymap.layers {
            for (id, binding) in layer.bindings.enumerated() where binding.kind == .mapped {
                let hasLegend = !binding.tap.isEmpty || !binding.hold.isEmpty || !binding.extra.isEmpty
                #expect(hasLegend, "layer \(layer.index), key \(id)")
            }
        }
    }

    @Test func disabledIsDistinctFromTransparent() throws {
        let keymap = try Keymap.bundled()
        let qwerty = keymap.layers[0]
        #expect(qwerty.bindings[6].kind == .disabled)
        #expect(qwerty.bindings[6].tap.isEmpty && qwerty.bindings[6].hold.isEmpty)
        let command = keymap.layers[1]
        #expect(command.bindings[0].kind == .transparent)
        let mouse = keymap.layers[3]
        #expect(mouse.bindings[1].kind == .transparent)
    }

    @Test func holdOnlyKeyStaysMappedWithItsHoldLegend() throws {
        let dvorak = try Keymap.bundled().layers[6]
        let key = dvorak.bindings[21]
        #expect(key.kind == .mapped)
        #expect(key.tap.isEmpty)
        #expect(key.hold == "L⇧")
    }

    @Test func customLabelsAndModifierCombosSurviveTheImport() throws {
        let qwerty = try Keymap.bundled().layers[0]
        #expect(qwerty.bindings[1].tap == "1 !")
        #expect(qwerty.bindings[42].tap == "⇧ 📸")
        #expect(qwerty.bindings[42].extra == "⇧⌘4")
        #expect(qwerty.bindings[32].tap == "Prev")
        #expect(qwerty.bindings[32].hold == "⌃⌘Q")
        #expect(qwerty.bindings[14].tap == "⇥")
        #expect(qwerty.bindings[14].hold == "Caps")
    }

    @Test func keycapLabelsAreCompact() throws {
        let keymap = try Keymap.bundled()
        let qwerty = keymap.layers[0]
        // Modifier chords use macOS symbols, no "+".
        #expect(qwerty.bindings[27].tap == "⌃S")
        #expect(qwerty.bindings[42].extra == "⇧⌘4")
        #expect(qwerty.bindings[70].tap == "⌘⇥")
        #expect(qwerty.bindings[32].hold == "⌃⌘Q")
        // Side-specific modifiers stay distinguishable.
        #expect(qwerty.bindings[21].tap == "L⇧")
        #expect(qwerty.bindings[29].tap == "L⌘")
        #expect(qwerty.bindings[27].hold == "L⌃")
        // Named keys and arrows use glyphs.
        #expect(qwerty.bindings[64].tap == "←")
        #expect(qwerty.bindings[67].tap == "→")
        #expect(qwerty.bindings[31].tap == "⌫")
        #expect(qwerty.bindings[71].tap == "⏎")
        #expect(qwerty.bindings[36].tap == "Dictation")
        // Mouse wheel chords keep the modifier prefix.
        let mouse = keymap.layers[3]
        #expect(mouse.bindings[44].tap == "⌃Wheel Up")
        #expect(mouse.bindings[51].tap == "⌃Wheel Down")
    }

    @Test func layerLinksNameTheirTargetLayer() throws {
        let keymap = try Keymap.bundled()
        #expect(keymap.layers[0].bindings[35].tap == "TO command")
        #expect(keymap.layers[0].bindings[35].hold == "MO media")
        #expect(keymap.layers[1].bindings[9].tap == "TO numpad")
        #expect(keymap.layers[3].bindings[69].tap == "TO command")
    }

    @Test func bindingColoursComeFromTheLayout() throws {
        let qwerty = try Keymap.bundled().layers[0]
        #expect(qwerty.bindings[0].color == "#FF0000")
        #expect(qwerty.bindings[6].color == nil)
    }
}

// MARK: - Validation

@Suite("Validation")
struct ValidationTests {
    @Test func acceptsAWellFormedKeymap() {
        let keymap = makeKeymap(layers: [
            Layer(index: 0, title: "base", bindings: makeBindings()),
            Layer(index: 1, title: "raise", bindings: makeBindings()),
        ])
        #expect(throws: Never.self) { try keymap.validate() }
    }

    @Test func rejectsTheWrongKeyCount() {
        let keymap = makeKeymap(keys: Array(makeKeys().dropLast()))
        #expect(throws: KeymapError.unsupportedKeyCount(expected: 72, actual: 71)) {
            try keymap.validate()
        }
    }

    @Test func rejectsDuplicateKeyIDs() {
        var keys = makeKeys()
        keys[5].id = 4
        #expect(throws: KeymapError.duplicateKeyID(4)) {
            try makeKeymap(keys: keys).validate()
        }
    }

    @Test func rejectsKeyIDsOutsideTheBoard() {
        var keys = makeKeys()
        keys[70].id = 99
        #expect(throws: KeymapError.keyIDOutOfRange(99)) {
            try makeKeymap(keys: keys).validate()
        }
    }

    @Test func rejectsMisalignedKeyIDs() {
        var keys = makeKeys()
        keys.swapAt(3, 4)
        #expect(throws: KeymapError.misalignedKeyID(index: 3, id: 4)) {
            try makeKeymap(keys: keys).validate()
        }
    }

    @Test func rejectsNonFiniteGeometry() {
        var keys = makeKeys()
        keys[3].x = .nan
        #expect(throws: KeymapError.nonFiniteGeometry(keyID: 3, field: "x")) {
            try makeKeymap(keys: keys).validate()
        }
        keys[3].x = 0
        keys[7].width = .infinity
        #expect(throws: KeymapError.nonFiniteGeometry(keyID: 7, field: "width")) {
            try makeKeymap(keys: keys).validate()
        }
    }

    @Test func rejectsNonPositiveDimensions() {
        var keys = makeKeys()
        keys[3].width = 0
        #expect(throws: KeymapError.nonPositiveDimension(keyID: 3, field: "width")) {
            try makeKeymap(keys: keys).validate()
        }
        keys[3].width = 1
        keys[9].height = -1
        #expect(throws: KeymapError.nonPositiveDimension(keyID: 9, field: "height")) {
            try makeKeymap(keys: keys).validate()
        }
    }

    @Test func rejectsBindingsThatDoNotCoverEveryKey() {
        let layers = [
            Layer(index: 0, title: "base", bindings: makeBindings()),
            Layer(index: 2, title: "media", bindings: Array(makeBindings().dropLast())),
        ]
        #expect(throws: KeymapError.bindingCountMismatch(layer: 2, expected: 72, actual: 71)) {
            try makeKeymap(layers: layers).validate()
        }
    }

    @Test func rejectsDuplicateLayerIndices() {
        let layers = [
            Layer(index: 0, title: "base", bindings: makeBindings()),
            Layer(index: 0, title: "duplicate", bindings: makeBindings()),
        ]
        #expect(throws: KeymapError.duplicateLayerIndex(0)) {
            try makeKeymap(layers: layers).validate()
        }
    }
}

// MARK: - Resolution

@Suite("Binding resolution")
struct BindingResolutionTests {
    private var base: Layer {
        Layer(index: 0, title: "base", bindings: makeBindings([10: KeyBinding(kind: .mapped, tap: "A")]))
    }

    @Test func topmostSuppliedLayerWins() {
        let upper = Layer(index: 4, title: "numpad", bindings: makeBindings([10: KeyBinding(kind: .mapped, tap: "7")]))
        let keymap = makeKeymap(layers: [base, upper])
        #expect(keymap.resolvedBinding(at: 10, activeLayers: [0, 4])?.tap == "7")
        #expect(keymap.resolvedBinding(at: 10, activeLayers: [4, 0])?.tap == "A")
    }

    @Test func transparentIsReturnedVerbatimInsteadOfFallingThrough() {
        let upper = Layer(index: 1, title: "command", bindings: makeBindings())
        let keymap = makeKeymap(layers: [base, upper])
        #expect(keymap.resolvedBinding(at: 10, activeLayers: [0, 1]) == KeyBinding(kind: .transparent))
        #expect(keymap.resolvedBinding(at: 10, activeLayers: [1]) == KeyBinding(kind: .transparent))
    }

    @Test func disabledBlocksLowerLayers() {
        let upper = Layer(index: 1, title: "command", bindings: makeBindings([10: KeyBinding(kind: .disabled)]))
        let keymap = makeKeymap(layers: [base, upper])
        #expect(keymap.resolvedBinding(at: 10, activeLayers: [0, 1])?.kind == .disabled)
    }

    @Test func unknownLayerIndicesAreSkipped() {
        let mouse = Layer(index: 3, title: "mouse", bindings: makeBindings([0: KeyBinding(kind: .mapped, tap: "Move up")]))
        let keymap = makeKeymap(layers: [mouse])
        #expect(keymap.resolvedBinding(at: 0, activeLayers: [7, 3])?.tap == "Move up")
        #expect(keymap.resolvedBinding(at: 0, activeLayers: [9]) == nil)
    }

    @Test func returnsNilWhenNothingCanBeResolved() {
        let keymap = makeKeymap()
        #expect(keymap.resolvedBinding(at: 0, activeLayers: []) == nil)
        #expect(keymap.resolvedBinding(at: 0, activeLayers: [5]) == nil)
        #expect(keymap.resolvedBinding(at: -1, activeLayers: [0]) == nil)
        #expect(keymap.resolvedBinding(at: 72, activeLayers: [0]) == nil)
    }
}

// MARK: - Codable

@Suite("Codable")
struct CodableTests {
    @Test func roundTripsThroughDisk() throws {
        let original = makeKeymap(
            keys: makeKeys(),
            layers: [
                Layer(index: 0, title: "base", bindings: makeBindings([0: KeyBinding(kind: .mapped, tap: "Esc", color: "#FF0000")])),
                Layer(index: 1, title: "command", bindings: makeBindings()),
            ]
        )
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(original).write(to: url)
        let loaded = try Keymap.load(url: url)
        #expect(loaded.title == original.title)
        #expect(loaded.revision == original.revision)
        #expect(loaded.keys == original.keys)
        #expect(loaded.layers == original.layers)
    }

    @Test func loadValidatesTheDecodedKeymap() throws {
        let invalid = makeKeymap(keys: Array(makeKeys().dropLast()))
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(invalid).write(to: url)
        #expect(throws: KeymapError.unsupportedKeyCount(expected: 72, actual: 71)) {
            try Keymap.load(url: url)
        }
    }

    @Test func loadRejectsMalformedJSON() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Keymap.load(url: url) }
    }

    @Test func decodesBindingsWithoutAColour() throws {
        let json = #"{"kind":"mapped","tap":"Enter","hold":"","extra":""}"#
        let binding = try JSONDecoder().decode(KeyBinding.self, from: Data(json.utf8))
        #expect(binding == KeyBinding(kind: .mapped, tap: "Enter"))
        #expect(binding.color == nil)
    }
}
