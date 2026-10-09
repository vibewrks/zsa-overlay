#!/usr/bin/env python3
"""Import one ZSA Keymapp/Oryx layout revision into MoonlanderOverlay's bundled Keymap JSON.

The Keymapp cache (SQLite) is opened strictly read-only ("mode=ro", SELECT only): this
script never writes to the cache, never touches Keymapp configuration and never flashes
firmware.

The revision id is always explicit (--revision), so a newer cache entry can never
silently change the bundled keymap.

The cache is located automatically: the direct-download Keymapp keeps it in
~/Library/Application Support/.keymapp/, the sandboxed App Store build inside its
container. Pass --cache PATH to point somewhere else.

    python3 scripts/import-keymapp.py --revision rba3al \
        --output Sources/MoonlanderOverlayKit/Resources/keymap.json

Output shape (matches Sources/MoonlanderOverlayKit/Keymap.swift):

    {"title": ..., "revision": ...,
     "keys":   [{"id", "x", "y", "width", "height", "rotation"}, ...],  # 72 keys
     "layers": [{"index", "title", "bindings": [...]}, ...]}           # bindings aligned with keys

Binding normalization (see classify_key):
  * mapped      - at least one action that is neither KC_NO nor KC_TRANSPARENT; a hold-only
                  key is mapped, with tap "" so the legend stays on the hold
  * disabled    - only KC_NO actions
  * transparent - no actions at all, or every action is KC_TRANSPARENT
  * tap         - customLabel when the user set one, else the tap action's label
  * hold        - the hold action's label
  * extra       - doubleTap and tapHold labels, joined with " / "
  * layer links render as "TO <layer title>"; modifier chords as macOS symbols ("\u2303\u2318Q")
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

# Where Keymapp keeps its cache: the direct-download build in Application Support, the
# sandboxed App Store build inside its container. Prefer whichever actually exists —
# switching builds leaves the other one behind, often empty.
CACHE_CANDIDATES = (
    Path.home() / "Library/Application Support/.keymapp/keymapp.sqlite3",
    Path.home() / "Library/Containers/io.zsa.keymapp/Data/Library/Application Support/.keymapp/keymapp.sqlite3",
)
DEFAULT_CACHE = next((path for path in CACHE_CANDIDATES if path.is_file()), CACHE_CANDIDATES[0])

KEY_COUNT = 72
SLOTS = ("tap", "hold", "doubleTap", "tapHold")
DISABLED_CODE = "KC_NO"
TRANSPARENT_CODE = "KC_TRANSPARENT"
LAYER_LINK_CODES = frozenset({"TO", "MO", "OSL", "TG", "TT", "DF", "LT", "LM", "PDF"})

# Oryx key index (position in a revision's "keys" array; 0 = left half, top-left)
# -> QMK matrix (row, col). Taken from the Keymapp frontend bundle shipped inside
# Keymapp.app ("moonlander" -> G[a][t] matrix-to-index table), i.e. Keymapp's own
# mapping between device matrix positions and layout indices; cross-checked against
# the cached rba3al bindings (numpad grid, mouse cluster, thumb keys 32/68).
ORYX_TO_MATRIX = (
    (0, 0),  # 0
    (0, 1),  # 1
    (0, 2),  # 2
    (0, 3),  # 3
    (0, 4),  # 4
    (0, 5),  # 5
    (0, 6),  # 6
    (1, 0),  # 7
    (1, 1),  # 8
    (1, 2),  # 9
    (1, 3),  # 10
    (1, 4),  # 11
    (1, 5),  # 12
    (1, 6),  # 13
    (2, 0),  # 14
    (2, 1),  # 15
    (2, 2),  # 16
    (2, 3),  # 17
    (2, 4),  # 18
    (2, 5),  # 19
    (2, 6),  # 20
    (3, 0),  # 21
    (3, 1),  # 22
    (3, 2),  # 23
    (3, 3),  # 24
    (3, 4),  # 25
    (3, 5),  # 26
    (4, 0),  # 27
    (4, 1),  # 28
    (4, 2),  # 29
    (4, 3),  # 30
    (4, 4),  # 31
    (5, 3),  # 32
    (5, 0),  # 33
    (5, 1),  # 34
    (5, 2),  # 35
    (6, 0),  # 36
    (6, 1),  # 37
    (6, 2),  # 38
    (6, 3),  # 39
    (6, 4),  # 40
    (6, 5),  # 41
    (6, 6),  # 42
    (7, 0),  # 43
    (7, 1),  # 44
    (7, 2),  # 45
    (7, 3),  # 46
    (7, 4),  # 47
    (7, 5),  # 48
    (7, 6),  # 49
    (8, 0),  # 50
    (8, 1),  # 51
    (8, 2),  # 52
    (8, 3),  # 53
    (8, 4),  # 54
    (8, 5),  # 55
    (8, 6),  # 56
    (9, 1),  # 57
    (9, 2),  # 58
    (9, 3),  # 59
    (9, 4),  # 60
    (9, 5),  # 61
    (9, 6),  # 62
    (10, 2),  # 63
    (10, 3),  # 64
    (10, 4),  # 65
    (10, 5),  # 66
    (10, 6),  # 67
    (11, 3),  # 68
    (11, 4),  # 69
    (11, 5),  # 70
    (11, 6),  # 71
)

# QMK matrix (row, col) -> (x, y, width, height, rotation) in key units, from
# keyboards/zsa/moonlander/keyboard.json "layouts.LAYOUT" (Moonlander Mark I; no key
# carries a rotation). Left half rows 0...5, right half rows 6...11. The board spans
# 17 x 7 key units; the two 2u thumb keys are index 32 ([5, 3]) and index 68 ([11, 3]).
MATRIX_GEOMETRY = {
    (0, 0): (0.0, 0.375, 1.0, 1.0),
    (0, 1): (1.0, 0.375, 1.0, 1.0),
    (0, 2): (2.0, 0.125, 1.0, 1.0),
    (0, 3): (3.0, 0.0, 1.0, 1.0),
    (0, 4): (4.0, 0.125, 1.0, 1.0),
    (0, 5): (5.0, 0.25, 1.0, 1.0),
    (0, 6): (6.0, 0.25, 1.0, 1.0),
    (1, 0): (0.0, 1.375, 1.0, 1.0),
    (1, 1): (1.0, 1.375, 1.0, 1.0),
    (1, 2): (2.0, 1.125, 1.0, 1.0),
    (1, 3): (3.0, 1.0, 1.0, 1.0),
    (1, 4): (4.0, 1.125, 1.0, 1.0),
    (1, 5): (5.0, 1.25, 1.0, 1.0),
    (1, 6): (6.0, 1.25, 1.0, 1.0),
    (2, 0): (0.0, 2.375, 1.0, 1.0),
    (2, 1): (1.0, 2.375, 1.0, 1.0),
    (2, 2): (2.0, 2.125, 1.0, 1.0),
    (2, 3): (3.0, 2.0, 1.0, 1.0),
    (2, 4): (4.0, 2.125, 1.0, 1.0),
    (2, 5): (5.0, 2.25, 1.0, 1.0),
    (2, 6): (6.0, 2.25, 1.0, 1.0),
    (3, 0): (0.0, 3.375, 1.0, 1.0),
    (3, 1): (1.0, 3.375, 1.0, 1.0),
    (3, 2): (2.0, 3.125, 1.0, 1.0),
    (3, 3): (3.0, 3.0, 1.0, 1.0),
    (3, 4): (4.0, 3.125, 1.0, 1.0),
    (3, 5): (5.0, 3.25, 1.0, 1.0),
    (4, 0): (0.0, 4.375, 1.0, 1.0),
    (4, 1): (1.0, 4.375, 1.0, 1.0),
    (4, 2): (2.0, 4.125, 1.0, 1.0),
    (4, 3): (3.0, 4.0, 1.0, 1.0),
    (4, 4): (4.0, 4.125, 1.0, 1.0),
    (5, 0): (5.0, 5.5, 1.0, 1.5),
    (5, 1): (6.0, 5.5, 1.0, 1.5),
    (5, 2): (7.0, 5.5, 1.0, 1.5),
    (5, 3): (5.0, 4.5, 2.0, 1.0),
    (6, 0): (10.0, 0.25, 1.0, 1.0),
    (6, 1): (11.0, 0.25, 1.0, 1.0),
    (6, 2): (12.0, 0.125, 1.0, 1.0),
    (6, 3): (13.0, 0.0, 1.0, 1.0),
    (6, 4): (14.0, 0.125, 1.0, 1.0),
    (6, 5): (15.0, 0.375, 1.0, 1.0),
    (6, 6): (16.0, 0.375, 1.0, 1.0),
    (7, 0): (10.0, 1.25, 1.0, 1.0),
    (7, 1): (11.0, 1.25, 1.0, 1.0),
    (7, 2): (12.0, 1.125, 1.0, 1.0),
    (7, 3): (13.0, 1.0, 1.0, 1.0),
    (7, 4): (14.0, 1.125, 1.0, 1.0),
    (7, 5): (15.0, 1.375, 1.0, 1.0),
    (7, 6): (16.0, 1.375, 1.0, 1.0),
    (8, 0): (10.0, 2.25, 1.0, 1.0),
    (8, 1): (11.0, 2.25, 1.0, 1.0),
    (8, 2): (12.0, 2.125, 1.0, 1.0),
    (8, 3): (13.0, 2.0, 1.0, 1.0),
    (8, 4): (14.0, 2.125, 1.0, 1.0),
    (8, 5): (15.0, 2.375, 1.0, 1.0),
    (8, 6): (16.0, 2.375, 1.0, 1.0),
    (9, 1): (11.0, 3.25, 1.0, 1.0),
    (9, 2): (12.0, 3.125, 1.0, 1.0),
    (9, 3): (13.0, 3.0, 1.0, 1.0),
    (9, 4): (14.0, 3.125, 1.0, 1.0),
    (9, 5): (15.0, 3.375, 1.0, 1.0),
    (9, 6): (16.0, 3.375, 1.0, 1.0),
    (10, 2): (12.0, 4.125, 1.0, 1.0),
    (10, 3): (13.0, 4.0, 1.0, 1.0),
    (10, 4): (14.0, 4.125, 1.0, 1.0),
    (10, 5): (15.0, 4.375, 1.0, 1.0),
    (10, 6): (16.0, 4.375, 1.0, 1.0),
    (11, 3): (10.0, 4.5, 2.0, 1.0),
    (11, 4): (9.0, 5.5, 1.0, 1.5),
    (11, 5): (10.0, 5.5, 1.0, 1.5),
    (11, 6): (11.0, 5.5, 1.0, 1.5),
}

# Revision codes that Oryx's metadata table spells differently.
CODE_ALIASES = {
    "AU_TOGG": "AU_TOG",
    "KC_BSPC": "KC_BSPACE",
    "KC_BSLS": "KC_BSLASH",
    "KC_CAPS": "KC_CAPSLOCK",
    "KC_LBRC": "KC_LBRACKET",
    "KC_LEFT_ALT": "KC_LALT",
    "KC_LEFT_CTRL": "KC_LCTRL",
    "KC_LEFT_GUI": "KC_LGUI",
    "KC_LEFT_SHIFT": "KC_LSHIFT",
    "KC_PGDN": "KC_PGDOWN",
    "KC_PAGE_UP": "KC_PGUP",
    # Common QMK spellings that Oryx never emits today but a hand-edited revision may.
    "KC_ESC": "KC_ESCAPE",
    "KC_ENT": "KC_ENTER",
    "KC_DEL": "KC_DELETE",
    "KC_SPC": "KC_SPACE",
    "KC_LSFT": "KC_LSHIFT",
    "KC_RSFT": "KC_RSHIFT",
    "KC_PAGE_DOWN": "KC_PGDOWN",
    "KC_QUOT": "KC_QUOTE",
    "KC_GRV": "KC_GRAVE",
    "KC_COMM": "KC_COMMA",
    "KC_SLSH": "KC_SLASH",
    "KC_EQL": "KC_EQUAL",
    "KC_MINS": "KC_MINUS",
    "KC_RBRC": "KC_RBRACKET",
    "KC_RIGHT_ALT": "KC_RALT",
    "KC_RIGHT_CTRL": "KC_RCTRL",
    "KC_RIGHT_GUI": "KC_RGUI",
    "KC_RIGHT_SHIFT": "KC_RSHIFT",
    "KC_SCLN": "KC_SCOLON",
    "MU_TOGG": "MU_TOG",
}

# Codes with no Oryx metadata entry at all; labels written out here.
FALLBACK_LABELS = {
    "MU_NEXT": "Music next",
    "QK_BOOT": "Bootloader",
}

# Metadata labels rewritten to fit a keycap (the overlay truncates long words).
# Unlisted labels keep their Oryx wording verbatim.
DISPLAY_LABELS = {
    "Arrow up": "\u2191",
    "Arrow down": "\u2193",
    "Arrow left": "\u2190",
    "Arrow right": "\u2192",
    "Backspace": "\u232b",
    "Delete": "\u2326",
    "Del": "\u2326",
    "Enter": "\u23ce",
    "Tab": "\u21e5",
    "Caps lock": "Caps",
    "Dictation (macOS)": "Dictation",
    "Left shift": "L\u21e7",
    "Right shift": "R\u21e7",
    "Left Ctrl": "L\u2303",
    "Right Ctrl": "R\u2303",
    "Left Option": "L\u2325",
    "Right Option (macOS)": "R\u2325",
    "Left Command": "L\u2318",
    "Right Command": "R\u2318",
}

# action.modifiers flags -> keycap symbols, in the macOS order (Ctrl/Opt/Shift/Cmd).
MODIFIER_ORDER = (
    ("leftCtrl", "\u2303"),
    ("rightCtrl", "\u2303"),
    ("leftAlt", "\u2325"),
    ("rightAlt", "\u2325"),
    ("leftShift", "\u21e7"),
    ("rightShift", "\u21e7"),
    ("leftGui", "\u2318"),
    ("rightGui", "\u2318"),
)


def read_blob_json(connection, query, parameters=()):
    """Run one SELECT and decode the single BLOB column as UTF-8 JSON."""
    row = connection.execute(query, parameters).fetchone()
    if row is None or row[0] is None:
        return None
    blob = row[0]
    if not isinstance(blob, (bytes, bytearray, memoryview)):
        raise ValueError("expected a BLOB, got %s" % type(blob).__name__)
    return json.loads(bytes(blob).decode("utf-8"))


def entry_label(entry):
    """Display label of a metadata entry: plain label, else the macOS variant."""
    if entry.get("label"):
        return str(entry["label"])
    variants = entry.get("os") or {}
    for name in ("osx", "others", "win", "linux"):
        variant = variants.get(name) or {}
        if variant.get("label"):
            return str(variant["label"])
    return None


def metadata_index(metadata):
    """code -> metadata entry (first entry wins; used codes are not duplicated)."""
    by_code = {}
    for entry in metadata.get("keys", []):
        code = entry.get("code")
        if code and code not in by_code:
            by_code[code] = entry
    return by_code


def label_for(code, by_code):
    for candidate in (code, CODE_ALIASES.get(code)):
        if candidate is None:
            continue
        entry = by_code.get(candidate)
        if entry is None:
            continue
        label = entry_label(entry)
        if label:
            return DISPLAY_LABELS.get(label, label)
    if code in FALLBACK_LABELS:
        return FALLBACK_LABELS[code]
    return code  # unknown code: show the raw QMK code instead of inventing a label


def render_action(action, by_code, layer_titles):
    """One action slot -> display string ("" for absent / disabled / transparent)."""
    code = action.get("code") or ""
    if code in (DISABLED_CODE, TRANSPARENT_CODE):
        return ""
    parts = [name for flag, name in MODIFIER_ORDER if (action.get("modifiers") or {}).get(flag)]
    layer = action.get("layer")
    if code in LAYER_LINK_CODES and isinstance(layer, int):
        parts.append("%s %s" % (label_for(code, by_code), layer_titles.get(layer, str(layer))))
    else:
        parts.append(label_for(code, by_code))
    return "".join(parts)


def classify_key(key, by_code, layer_titles):
    """Normalize one physical key into a KeyBinding dict."""
    actions = {slot: key.get(slot) for slot in SLOTS}
    present = [action for action in actions.values() if action]
    actionable = [action for action in present if (action.get("code") or "") not in (DISABLED_CODE, TRANSPARENT_CODE)]
    if not actionable:
        transparent = (not present) or any((action.get("code") or "") == TRANSPARENT_CODE for action in present)
        return {"kind": "transparent" if transparent else "disabled", "tap": "", "hold": "", "extra": ""}
    custom = key.get("customLabel")
    tap = custom if custom else render_action(actions["tap"], by_code, layer_titles) if actions["tap"] else ""
    hold = render_action(actions["hold"], by_code, layer_titles) if actions["hold"] else ""
    extra = " / ".join(part for part in (
        render_action(actions["doubleTap"], by_code, layer_titles) if actions["doubleTap"] else "",
        render_action(actions["tapHold"], by_code, layer_titles) if actions["tapHold"] else "",
    ) if part)
    return {"kind": "mapped", "tap": tap or "", "hold": hold or "", "extra": extra}


def build_keymap(layout, metadata, revision_id):
    revision = layout.get("revision") or {}
    by_code = metadata_index(metadata)
    layers = sorted(revision.get("layers") or [], key=lambda layer: layer["position"])
    layer_titles = {layer["position"]: layer["title"] for layer in layers}

    keys = []
    for index in range(KEY_COUNT):
        row, column = ORYX_TO_MATRIX[index]
        x, y, width, height = MATRIX_GEOMETRY[(row, column)]
        keys.append({"id": index, "x": x, "y": y, "width": width, "height": height, "rotation": 0.0})

    out_layers = []
    for layer in layers:
        bindings = []
        for key in layer["keys"]:
            binding = classify_key(key, by_code, layer_titles)
            color = key.get("glowColor")
            if not isinstance(color, str) or not color:
                color = layer.get("color") if isinstance(layer.get("color"), str) else None
            if color:
                binding["color"] = color
            bindings.append(binding)
        out_layers.append({"index": layer["position"], "title": layer["title"], "bindings": bindings})

    return {
        "title": layout.get("title") or "",
        "revision": revision.get("hashId") or revision_id,
        "keys": keys,
        "layers": out_layers,
    }


def validate_keymap(keymap):
    keys = keymap["keys"]
    if len(keys) != KEY_COUNT:
        raise ValueError("expected %d keys, built %d" % (KEY_COUNT, len(keys)))
    ids = [key["id"] for key in keys]
    if ids != list(range(KEY_COUNT)):
        raise ValueError("key ids must be 0...%d in order" % (KEY_COUNT - 1))
    for layer in keymap["layers"]:
        if len(layer["bindings"]) != KEY_COUNT:
            raise ValueError("layer %d has %d bindings, expected %d"
                             % (layer["index"], len(layer["bindings"]), KEY_COUNT))


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        description="Import one Keymapp/Oryx revision into the MoonlanderOverlay keymap JSON.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--revision", required=True, help="revision hashId in the Keymapp cache (e.g. rba3al)")
    parser.add_argument("--output", required=True, type=Path, help="path for the generated keymap JSON")
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE, help="Keymapp SQLite cache (default: %(default)s)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv)
    if not args.cache.is_file():
        print("error: Keymapp cache not found at %s" % args.cache, file=sys.stderr)
        print("       looked in: %s" % ", ".join(str(p) for p in CACHE_CANDIDATES), file=sys.stderr)
        print("       pass --cache PATH if Keymapp keeps its cache elsewhere", file=sys.stderr)
        return 1
    connection = sqlite3.connect(args.cache.as_uri() + "?mode=ro", uri=True)
    try:
        blob = read_blob_json(connection, "SELECT data FROM revision WHERE revisionId = ?", (args.revision,))
        if blob is None:
            known = [row[0] for row in connection.execute("SELECT revisionId FROM revision ORDER BY revisionId")]
            print("error: revision %r not in cache (available: %s)" % (args.revision, ", ".join(known) or "none"), file=sys.stderr)
            return 1
        metadata = read_blob_json(connection, "SELECT data FROM metadata LIMIT 1") or {"keys": [], "categories": []}
    finally:
        connection.close()

    layout = blob.get("layout")
    if not isinstance(layout, dict):
        print("error: revision %r has no layout" % args.revision, file=sys.stderr)
        return 1

    try:
        keymap = build_keymap(layout, metadata, args.revision)
        validate_keymap(keymap)
    except (KeyError, TypeError, ValueError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(keymap, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    counts = {"mapped": 0, "disabled": 0, "transparent": 0}
    for layer in keymap["layers"]:
        for binding in layer["bindings"]:
            counts[binding["kind"]] = counts.get(binding["kind"], 0) + 1
    print("wrote %s" % args.output)
    print("  title: %s | revision: %s | keys: %d | layers: %d"
          % (keymap["title"], keymap["revision"], len(keymap["keys"]), len(keymap["layers"])))
    print("  layers: %s" % ", ".join("%d=%s" % (layer["index"], layer["title"]) for layer in keymap["layers"]))
    print("  bindings: %d mapped, %d disabled, %d transparent"
          % (counts["mapped"], counts["disabled"], counts["transparent"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
