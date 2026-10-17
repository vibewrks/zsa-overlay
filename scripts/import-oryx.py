#!/usr/bin/env python3
"""Import a ZSA Oryx layout directly from Oryx into MoonlanderOverlay's keymap JSON.

Reads nothing from Keymapp: resolves the revision over Oryx's public GraphQL API
and downloads the same source zip as Oryx's "Download source" button. The layout
must be public (Oryx > layout settings > privacy).

    python3 scripts/import-oryx.py --layout-id GMrOw --revision rba3al \\
        --output Sources/MoonlanderOverlayKit/Resources/keymap.json

Output shape matches scripts/import-keymapp.py (see Keymap.swift):

    {"title": ..., "revision": ...,
     "keys":   [{"id", "x", "y", "width", "height", "rotation"}, ...],  # 72 keys
     "layers": [{"index", "title", "bindings": [...]}, ...]}           # bindings aligned with keys

Legends come from parsing the exported keymap.c (keycodes, MT/LT/MO/TO/TG dual
roles, Oryx DUAL_FUNC tap/hold branches, tap dances) and colours from its ledmap
table via the Moonlander LED layout. The C parsing approach follows
ggfevans/oryx-overlay's scripts/oryx_layout.py; the binding schema and legend
wording instead match scripts/import-keymapp.py so either importer feeds the app.

Known fidelity gaps versus the Keymapp import (which sees Oryx editor metadata):
  * Oryx custom labels are editor-only and never reach keymap.c; the tap action's
    label is used instead.
  * Shifted hints ("1 !"), Dictation-style metadata labels and tap-dance step
    names fall back to plain labels ("1", "Dance 0"). ZSA's MAC_SIRI is mapped
    to "Dictation" explicitly.
  * Colours are converted from ledmap HSV with float maths, so they may differ
    from Keymapp's hex by a least-significant bit (e.g. #FFBA00 vs #FFB900).
  * Layers without a ledmap entry (e.g. an uncoloured layer) get no colours.
"""
from __future__ import annotations

import argparse
import colorsys
import importlib.util
import io
import json
import re
import sqlite3  # noqa: F401  (kept: sibling importer shares this module's tables)
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent


def _load_sibling_tables():
    """Reuse the hardware tables from scripts/import-keymapp.py (single source)."""
    sibling = SCRIPTS_DIR / "import-keymapp.py"
    spec = importlib.util.spec_from_file_location("import_keymapp", sibling)
    if spec is None or spec.loader is None:
        raise SystemExit(f"error: cannot load sibling tables from {sibling}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_TABLES = _load_sibling_tables()
MATRIX_GEOMETRY = _TABLES.MATRIX_GEOMETRY
KEY_COUNT = _TABLES.KEY_COUNT

GRAPHQL = "https://oryx.zsa.io/graphql"
SOURCE = "https://oryx.zsa.io/source/{revision}"
USER_AGENT = "zsa-overlay/import-oryx (+local build-time import)"

QUERY = """
query getLayout($hashId: String!, $revisionId: String!, $geometry: String) {
  layout(hashId: $hashId, geometry: $geometry, revisionId: $revisionId) {
    title
    geometry
    revision { hashId qmkVersion title createdAt layers { title position } }
  }
}
"""

# Oryx key ids per keymap.c source line: Oryx prints one physical row per line
# in physical x order, left half then right half. Each half-row's ids are
# therefore sorted by key x position (this matters on the bottom rows, where
# the 2u thumb sorts outside numeric id order). Built from the sibling
# ORYX_TO_MATRIX + MATRIX_GEOMETRY tables.

def _half_row_ids() -> list[tuple[list[int], list[int]]]:
    # Oryx editor rows, not QMK matrix rows: the bottom editor row holds the
    # matrix row plus the 2u thumb ((5, 3) -> id 32 on the left).
    blocks = (
        ((0, 7), (36, 43)), ((7, 14), (43, 50)), ((14, 21), (50, 57)),
        ((21, 27), (57, 63)), ((27, 33), (63, 69)), ((33, 36), (69, 72)),
    )
    ordered: list[tuple[list[int], list[int]]] = []
    for (l0, l1), (r0, r1) in blocks:
        x_of = lambda i: MATRIX_GEOMETRY[_TABLES.ORYX_TO_MATRIX[i]][0]  # noqa: E731
        ordered.append((
            sorted(range(l0, l1), key=x_of),
            sorted(range(r0, r1), key=x_of),
        ))
    return ordered

HALF_ROW_IDS = _half_row_ids()

# LED index -> QMK matrix [row, col], in RGB-matrix order. Copied from ZSA's QMK
# fork keyboards/zsa/moonlander/reva/keyboard.json "rgb_matrix.layout"
# (firmware25; reva and revb layouts are identical). Column-major per half.
LED_MATRIX = (
    (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
    (0, 1), (1, 1), (2, 1), (3, 1), (4, 1),
    (0, 2), (1, 2), (2, 2), (3, 2), (4, 2),
    (0, 3), (1, 3), (2, 3), (3, 3), (4, 3),
    (0, 4), (1, 4), (2, 4), (3, 4), (4, 4),
    (0, 5), (1, 5), (2, 5), (3, 5),
    (0, 6), (1, 6), (2, 6),
    (5, 0), (5, 1), (5, 2), (5, 3),
    (6, 6), (7, 6), (8, 6), (9, 6), (10, 6),
    (6, 5), (7, 5), (8, 5), (9, 5), (10, 5),
    (6, 4), (7, 4), (8, 4), (9, 4), (10, 4),
    (6, 3), (7, 3), (8, 3), (9, 3), (10, 3),
    (6, 2), (7, 2), (8, 2), (9, 2), (10, 2),
    (6, 1), (7, 1), (8, 1), (9, 1),
    (6, 0), (7, 0), (8, 0),
    (11, 6), (11, 5), (11, 4), (11, 3),
)


# --------------------------------------------------------------------------
# HTTP + zip
# --------------------------------------------------------------------------

def http(url: str, data: bytes | None = None, timeout: int = 60) -> bytes:
    headers = {"User-Agent": USER_AGENT}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"error: {url} returned HTTP {error.code}") from None
    except urllib.error.URLError as error:
        raise SystemExit(f"error: could not reach {url}: {error.reason}") from None


def fetch_layout(layout_id: str, revision: str) -> dict:
    body = json.dumps(
        {"query": QUERY, "variables": {"hashId": layout_id, "geometry": "moonlander", "revisionId": revision}}
    ).encode()
    reply = json.loads(http(GRAPHQL, body))
    layout = (reply.get("data") or {}).get("layout")
    if not layout:
        message = "; ".join(e.get("message", "?") for e in reply.get("errors", [])) or "no data"
        raise SystemExit(
            f"error: Oryx could not find layout '{layout_id}' ({message}).\n"
            "  - Check --layout-id: the part after /layouts/ in the Oryx URL.\n"
            "  - The layout must be public (Oryx > layout settings > privacy)."
        )
    return layout


def fetch_keymap_c(revision_hash: str) -> str:
    data = http(SOURCE.format(revision=revision_hash))
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = [n for n in archive.namelist() if n.endswith("_source/keymap.c")]
        if not names:
            raise SystemExit("error: Oryx source zip had no *_source/keymap.c")
        return archive.read(names[0]).decode("utf-8")


# --------------------------------------------------------------------------
# C source helpers (bracket-aware splitting for LAYOUT/DUAL_FUNC parsing)
# --------------------------------------------------------------------------

def strip_comments(src: str) -> str:
    out: list[str] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and nxt == "*":
            end = src.find("*/", i + 2)
            i = n if end == -1 else end + 2
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return "".join(out)


_PAIRS = {"(": ")", "{": "}", "[": "]"}


def balanced(src: str, open_idx: int) -> tuple[str, int]:
    opener = src[open_idx]
    closer = _PAIRS[opener]
    depth = 0
    for j in range(open_idx, len(src)):
        ch = src[j]
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return src[open_idx + 1:j], j + 1
    raise ValueError(f"unbalanced {opener!r} at offset {open_idx}")


def split_args(s: str) -> list[str]:
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [" ".join(p.split()) for p in parts if p.strip()]


def call(expr: str) -> tuple[str, list[str]] | None:
    match = re.fullmatch(r"(\w+)\s*\((.*)\)", expr.strip(), re.S)
    if not match:
        return None
    return match.group(1), split_args(match.group(2))


# --------------------------------------------------------------------------
# keymap.c model
# --------------------------------------------------------------------------

_LAYER_CALLS = {"layer_on": "MO", "layer_move": "TO", "layer_invert": "TG"}
_LAYER_FUNCS = {"MO", "TG", "TO", "TT", "OSL", "DF"}


def branch_action(body: str) -> str:
    """First action in a DUAL_FUNC tap/hold branch, as a keycode-ish string."""
    match = re.search(r"\b(register_code16|layer_on|layer_move|layer_invert)\(\s*([^;]+?)\s*\)\s*;", body)
    if not match:
        return ""
    fn, arg = match.groups()
    return arg if fn == "register_code16" else f"{_LAYER_CALLS[fn]}({arg})"


def parse_layers(src: str) -> list[tuple[int, list[str]]]:
    """Layer index -> raw keycode per Oryx key id (0-71)."""
    match = re.search(r"keymaps\s*\[\s*\]\s*\[[^\]]*\]\s*\[[^\]]*\]\s*=\s*\{", src)
    if not match:
        raise ValueError("could not find the keymaps array")
    block, _ = balanced(src, match.end() - 1)
    layers: list[tuple[int, list[str]]] = []
    for lm in re.finditer(r"\[\s*(\d+)\s*\]\s*=\s*LAYOUT\w*\s*\(", block):
        inner, _ = balanced(block, lm.end() - 1)
        index = int(lm.group(1))
        rows = [split_args(line) for line in inner.splitlines() if line.strip()]
        rows = [r for r in rows if r]
        if len(rows) != len(HALF_ROW_IDS):
            raise ValueError(f"layer {index}: expected {len(HALF_ROW_IDS)} rows, found {len(rows)}")
        bindings: list[str | None] = [None] * KEY_COUNT
        for row, keys in enumerate(rows):
            left_ids, right_ids = HALF_ROW_IDS[row]
            half = len(keys) // 2
            left, right = keys[:half], keys[half:]
            if len(left) != len(left_ids) or len(right) != len(right_ids):
                raise ValueError(
                    f"layer {index} row {row}: expected "
                    f"{len(left_ids)}+{len(right_ids)} keys, found {len(left)}+{len(right)}")
            for key_id, raw in zip(left_ids, left):
                bindings[key_id] = raw
            for key_id, raw in zip(right_ids, right):
                bindings[key_id] = raw
        if any(b is None for b in bindings):
            missing = [i for i, b in enumerate(bindings) if b is None]
            raise ValueError(f"layer {index}: unmapped key ids {missing}")
        layers.append((index, [b for b in bindings if b is not None]))
    if not layers:
        raise ValueError("keymaps array contains no LAYOUT(...) entries")
    return sorted(layers)


def parse_dual_funcs(src: str) -> dict[str, tuple[str, str]]:
    """DUAL_FUNC_n -> (tap action, hold action) from process_record_user."""
    dual: dict[str, tuple[str, str]] = {}
    for name in sorted(set(re.findall(r"\b(DUAL_FUNC_\d+)\b", src))):
        cm = re.search(rf"case\s+{name}\s*:.*?tap\.count[^{{]*\{{", src, re.S)
        if not cm:
            continue
        tap_body, after = balanced(src, cm.end() - 1)
        em = re.match(r"\s*else\s*\{", src[after:])
        hold_body = balanced(src, after + em.end() - 1)[0] if em else ""
        tap, hold = branch_action(tap_body), branch_action(hold_body)
        dual[name] = (tap or "KC_NO", hold or "KC_NO")
    return dual


def parse_ledmap(src: str) -> dict[int, list[tuple[int, int, int]]]:
    """Layer index -> 72 (h, s, v) triples in LED order."""
    match = re.search(r"ledmap\s*\[\s*\]\s*\[[^\]]*\]\s*\[\s*3\s*\]\s*=\s*\{", src)
    if not match:
        return {}
    block, _ = balanced(src, match.end() - 1)
    out: dict[int, list[tuple[int, int, int]]] = {}
    for em in re.finditer(r"\[\s*(\d+)\s*\]\s*=\s*\{", block):
        inner, _ = balanced(block, em.end() - 1)
        triples = re.findall(r"\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}", inner)
        out[int(em.group(1))] = [tuple(int(v) for v in t) for t in triples]
    return out


def hsv_hex(h: int, s: int, v: int) -> str | None:
    if v == 0:
        return None
    r, g, b = colorsys.hsv_to_rgb(h / 255, s / 255, 1.0)
    return "#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255))


def led_colours(ledmap: dict[int, list[tuple[int, int, int]]]) -> dict[int, dict[int, str]]:
    """Layer index -> {Oryx key id: #RRGGBB} via the Moonlander LED layout."""
    matrix_to_oryx = {matrix: oryx for oryx, matrix in enumerate(_TABLES.ORYX_TO_MATRIX)}
    out: dict[int, dict[int, str]] = {}
    for layer, triples in ledmap.items():
        colours: dict[int, str] = {}
        for led, (h, s, v) in enumerate(triples):
            if led >= len(LED_MATRIX):
                break
            oryx = matrix_to_oryx.get(LED_MATRIX[led])
            if oryx is None:
                continue
            hexed = hsv_hex(h, s, v)
            if hexed:
                colours[oryx] = hexed
        if colours:
            out[layer] = colours
    return out


# --------------------------------------------------------------------------
# Legends (same binding wording as scripts/import-keymapp.py)
# --------------------------------------------------------------------------

BASIC = {
    "ESCAPE": "Esc", "TAB": "⇥", "ENTER": "⏎", "SPACE": "Space", "BSPC": "⌫",
    "BACKSPACE": "⌫", "DELETE": "⌦", "DEL": "⌦", "CAPS": "Caps", "CAPS_LOCK": "Caps",
    "UP": "↑", "DOWN": "↓", "LEFT": "←", "RIGHT": "→",
    "HOME": "Home", "END": "End", "PAGE_UP": "PgUp", "PGUP": "PgUp",
    "PAGE_DOWN": "PgDn", "PGDN": "PgDn", "INSERT": "Ins", "PRINT_SCREEN": "PrtSc",
    "WWW_BACK": "Back", "WWW_FORWARD": "Fwd", "WWW_REFRESH": "Reload", "WWW_SEARCH": "Search",
    "LEFT_SHIFT": "L⇧", "RIGHT_SHIFT": "R⇧",
    "LEFT_CTRL": "L⌃", "RIGHT_CTRL": "R⌃", "LEFT_ALT": "L⌥", "RIGHT_ALT": "R⌥",
    "LEFT_GUI": "L⌘", "RIGHT_GUI": "R⌘",
    "MINUS": "-", "MINS": "-", "EQUAL": "=", "EQL": "=", "LBRC": "[", "RBRC": "]",
    "BSLS": "\\", "SCLN": ";", "SCOLON": ";", "QUOTE": "'", "QUOT": "'", "GRAVE": "`",
    "GRV": "`", "COMMA": ",", "COMM": ",", "DOT": ".", "SLASH": "/", "SLSH": "/",
    "EXLM": "!", "AT": "@", "HASH": "#", "DLR": "$", "PERC": "%", "CIRC": "^",
    "AMPR": "&", "ASTR": "*", "LPRN": "(", "RPRN": ")", "UNDS": "_", "PLUS": "+",
    "LCBR": "{", "RCBR": "}", "PIPE": "|", "COLN": ":", "DQUO": '"', "TILD": "~",
    "LABK": "<", "RABK": ">", "QUES": "?",
    "MEDIA_NEXT_TRACK": "Next", "MNXT": "Next", "MEDIA_PREV_TRACK": "Prev", "MPRV": "Prev",
    "MEDIA_PLAY_PAUSE": "Play", "MPLY": "Play", "MEDIA_STOP": "Stop", "MSTP": "Stop",
    "AUDIO_VOL_UP": "Vol+", "VOLU": "Vol+", "AUDIO_VOL_DOWN": "Vol−", "VOLD": "Vol−",
    "AUDIO_MUTE": "Mute", "MUTE": "Mute",
    "MS_BTN1": "Click", "BTN1": "Click", "MS_BTN2": "R-Click", "BTN2": "R-Click",
    "MS_UP": "M↑", "MS_DOWN": "M↓", "MS_LEFT": "M←", "MS_RIGHT": "M→",
    "MS_WH_UP": "Wh↑", "MS_WH_DOWN": "Wh↓",
    "BRIGHTNESS_UP": "Bri+", "BRIU": "Bri+", "BRIGHTNESS_DOWN": "Bri−", "BRID": "Bri−",
    "RGB_VAI": "Bri+", "RGB_VAD": "Bri−", "RGB_SAI": "Sat+", "RGB_SAD": "Sat−",
    "RGB_HUI": "Hue+", "RGB_HUD": "Hue−", "RGB_SPI": "Spd+", "RGB_SPD": "Spd−",
    "RGB_TOG": "RGB", "RGB_MODE_FORWARD": "RGB Mode",
    "AU_TOGG": "Audio", "MU_TOGG": "Music", "MU_NEXT": "Music next",
    "QK_BOOT": "Bootloader", "QK_BOOTLOADER": "Bootloader",
    "CW_TOGG": "Caps Word", "MOON_LED_LEVEL": "Indicator toggle",
    "RGB_SLD": "RGB Solid", "RGB_MOD": "RGB Mode", "MAC_SIRI": "Dictation",
}

MOD_SYMBOLS = {"ctrl": "⌃", "alt": "⌥", "shift": "⇧", "gui": "⌘"}
MOD_ORDER = ("ctrl", "alt", "shift", "gui")
MOD_TOKENS = {
    "LCTL": ("ctrl", "L"), "RCTL": ("ctrl", "R"), "LCTRL": ("ctrl", "L"), "RCTRL": ("ctrl", "R"),
    "LSFT": ("shift", "L"), "RSFT": ("shift", "R"), "LSHIFT": ("shift", "L"), "RSHIFT": ("shift", "R"),
    "LALT": ("alt", "L"), "RALT": ("alt", "R"), "LOPT": ("alt", "L"), "ROPT": ("alt", "R"),
    "LGUI": ("gui", "L"), "RGUI": ("gui", "R"), "LCMD": ("gui", "L"), "RCMD": ("gui", "R"),
    "LWIN": ("gui", "L"), "RWIN": ("gui", "R"),
    "C": ("ctrl", ""), "S": ("shift", ""), "A": ("alt", ""), "G": ("gui", ""),
    "MEH": ("ctrl+alt+shift", ""), "HYPR": ("ctrl+alt+shift+gui", ""),
}


def modset(expr: str) -> tuple[set[str], str]:
    """MOD_... expression -> ({ctrl, alt, ...}, side 'L'/'R'/'' )."""
    mods: set[str] = set()
    side = ""
    for tok in re.split(r"[|\s]+", expr.removeprefix("MOD_")):
        tok = tok.strip()
        if not tok:
            continue
        if tok in MOD_TOKENS:
            names, tok_side = MOD_TOKENS[tok]
            mods.update(names.split("+"))
            if len(mods) == 1 and not side:
                side = tok_side
        elif tok in ("MEH",):
            mods.update(("ctrl", "alt", "shift"))
        elif tok in ("HYPR",):
            mods.update(("ctrl", "alt", "shift", "gui"))
    if len(mods) != 1:
        side = ""
    return mods, side


def mod_chord(mods: set[str], inner: str) -> str:
    return "".join(MOD_SYMBOLS[m] for m in MOD_ORDER if m in mods) + inner


class Labeller:
    def __init__(self, dual: dict[str, tuple[str, str]], titles: dict[int, str]):
        self.dual = dual
        self.titles = titles
        self.fallbacks: list[str] = []

    def title(self, arg: str) -> str:
        arg = arg.strip()
        if arg.isdigit() and int(arg) in self.titles:
            return self.titles[int(arg)]
        return arg

    def basic(self, kc: str) -> str:
        kc = kc.strip().removeprefix("KC_")
        if kc in BASIC:
            return BASIC[kc]
        # Single letters/digits before MOD_TOKENS: "C"/"S"/"A"/"G" are keys here,
        # not the mod aliases modset() accepts inside wrapper calls.
        if re.fullmatch(r"[A-Z0-9]", kc) or re.fullmatch(r"F\d{1,2}", kc):
            return kc
        if m := re.fullmatch(r"KP_([0-9])", kc):
            return m.group(1)
        if m := re.fullmatch(r"KP_(\w+)", kc):
            return {"DOT": ".", "PLUS": "+", "MINUS": "-", "ASTERISK": "*",
                    "SLASH": "/", "ENTER": "⏎", "EQUAL": "=", "COMMA": ","}.get(
                        m.group(1), m.group(1).title())
        if kc in ("MEH", "HYPR"):
            return {"MEH": "Meh", "HYPR": "Hyper"}[kc]
        if m := re.fullmatch(r"ST_MACRO_(\d+)", kc):
            return f"Macro {m.group(1)}"
        if re.fullmatch(r"HSV_\d+_\d+_\d+", kc):
            return "Colour"
        if len(kc) > 3:
            labelled = kc.replace("_", " ").title()
            self.fallbacks.append(kc)
            return labelled
        self.fallbacks.append(kc)
        return kc

    def legend(self, raw: str) -> str:
        """One action -> display string ('' for absent/disabled/transparent)."""
        kc = raw.strip()
        if kc in ("", "KC_NO", "XXXXXXX"):
            return ""
        if kc in ("KC_TRANSPARENT", "KC_TRNS", "_______", "TRANSPARENT"):
            return ""
        if kc in self.dual:
            return ""  # handled structurally by classify(); never a bare label
        parsed = call(kc)
        if parsed is None:
            return self.basic(kc)
        fn, args = parsed
        if fn in _LAYER_FUNCS and len(args) == 1:
            return f"{fn} {self.title(args[0])}"
        if fn == "LT" and len(args) == 2:
            return self.basic(args[1])
        if fn == "MT" and len(args) == 2:
            return self.basic(args[1])
        if fn == "OSM" and len(args) == 1:
            mods, _ = modset(args[0])
            return mod_chord(mods, "")
        if fn == "TD" and args:
            n = re.sub(r"\D", "", args[0])
            return f"Dance {n}".strip()
        if fn in MOD_TOKENS and len(args) == 1:
            mods, _ = modset(fn)
            inner = args[0]
            while (nc := call(inner)) and nc[0] in MOD_TOKENS and len(nc[1]) == 1:
                more, _ = modset(nc[0])
                mods |= more
                inner = nc[1][0]
            return mod_chord(mods, self.legend(inner))
        self.fallbacks.append(kc)
        return kc

    def hold_label(self, raw: str) -> str:
        """Hold action -> secondary legend (mod-only holds keep their side)."""
        kc = raw.strip()
        parsed = call(kc)
        if parsed is None:
            if kc.removeprefix("KC_") in MOD_TOKENS:
                mods, side = modset(kc.removeprefix("KC_"))
                if len(mods) == 1:
                    (only,) = mods
                    return f"{side}{MOD_SYMBOLS[only]}"
            return self.basic(kc)
        fn, args = parsed
        if fn == "MT" and len(args) == 2:
            mods, side = modset(args[0])
            if len(mods) == 1:
                (only,) = mods
                return f"{side}{MOD_SYMBOLS[only]}"
            return mod_chord(mods, "")
        if fn == "LT" and len(args) == 2:
            return f"TO {self.title(args[0])}"
        if fn in _LAYER_FUNCS and len(args) == 1:
            return f"{fn} {self.title(args[0])}"
        if fn in MOD_TOKENS and len(args) == 1:
            mods, _ = modset(fn)
            while (nc := call(args[0])) and nc[0] in MOD_TOKENS and len(nc[1]) == 1:
                more, _ = modset(nc[0])
                mods |= more
                args = nc[1]
            return mod_chord(mods, self.legend(args[0]))
        return self.legend(kc)


DISABLED = {"KC_NO", "XXXXXXX"}
TRANSPARENT = {"KC_TRANSPARENT", "KC_TRNS", "_______", "TRANSPARENT"}


def classify(raw: str, lab: Labeller) -> dict:
    """One raw keycode -> KeyBinding dict in the shared schema."""
    kc = raw.strip()
    if kc in lab.dual:
        tap_raw, hold_raw = lab.dual[kc]
        tap = lab.legend(tap_raw) if tap_raw not in DISABLED else ""
        hold = lab.hold_label(hold_raw) if hold_raw not in DISABLED else ""
        if not tap and not hold:
            return {"kind": "transparent", "tap": "", "hold": "", "extra": ""}
        return {"kind": "mapped", "tap": tap, "hold": hold, "extra": ""}
    if kc in DISABLED:
        return {"kind": "disabled", "tap": "", "hold": "", "extra": ""}
    if kc in TRANSPARENT:
        return {"kind": "transparent", "tap": "", "hold": "", "extra": ""}
    parsed = call(kc)
    if parsed is not None:
        fn, args = parsed
        if fn == "MT" and len(args) == 2:
            return {"kind": "mapped", "tap": lab.legend(args[1]),
                    "hold": lab.hold_label(kc), "extra": ""}
        if fn == "LT" and len(args) == 2:
            return {"kind": "mapped", "tap": lab.legend(args[1]),
                    "hold": lab.hold_label(kc), "extra": ""}
        if fn in _LAYER_FUNCS and len(args) == 1:
            return {"kind": "mapped", "tap": lab.legend(kc), "hold": "", "extra": ""}
        if fn == "OSM" and len(args) == 1:
            return {"kind": "mapped", "tap": lab.legend(kc), "hold": "", "extra": "one-shot"}
        if fn == "TD":
            return {"kind": "mapped", "tap": lab.legend(kc), "hold": "", "extra": ""}
        if fn in MOD_TOKENS and len(args) == 1:
            return {"kind": "mapped", "tap": lab.legend(kc), "hold": "", "extra": ""}
    return {"kind": "mapped", "tap": lab.legend(kc), "hold": "", "extra": ""}


# --------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------

def build_keymap(title: str, revision: str, layers: list[tuple[int, list[str]]],
                 lab: Labeller, colours: dict[int, dict[int, str]]) -> dict:
    keys = []
    for index in range(KEY_COUNT):
        row, column = _TABLES.ORYX_TO_MATRIX[index]
        x, y, width, height = MATRIX_GEOMETRY[(row, column)]
        keys.append({"id": index, "x": x, "y": y, "width": width,
                     "height": height, "rotation": 0.0})
    out_layers = []
    for index, raws in layers:
        bindings = []
        layer_colours = colours.get(index, {})
        for key_id, raw in enumerate(raws):
            binding = classify(raw, lab)
            if binding["kind"] == "mapped" and key_id in layer_colours:
                binding["color"] = layer_colours[key_id]
            bindings.append(binding)
        out_layers.append({"index": index, "title": lab.titles.get(index, f"L{index}"),
                           "bindings": bindings})
    return {"title": title, "revision": revision, "keys": keys, "layers": out_layers}


def validate_keymap(keymap: dict) -> None:
    keys = keymap["keys"]
    if len(keys) != KEY_COUNT:
        raise ValueError(f"expected {KEY_COUNT} keys, built {len(keys)}")
    if [k["id"] for k in keys] != list(range(KEY_COUNT)):
        raise ValueError("key ids must be 0...71 in order")
    for layer in keymap["layers"]:
        if len(layer["bindings"]) != KEY_COUNT:
            raise ValueError("layer %d has %d bindings, expected %d"
                             % (layer["index"], len(layer["bindings"]), KEY_COUNT))


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        description="Import a public Oryx layout directly into the MoonlanderOverlay keymap JSON.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--layout-id", required=True,
                        help="Oryx layout id: the part after /layouts/ in the Oryx URL")
    parser.add_argument("--revision", default="latest",
                        help="revision hashId, or 'latest' (default: %(default)s)")
    parser.add_argument("--output", required=True, type=Path,
                        help="path for the generated keymap JSON")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_arguments(argv)

    layout = fetch_layout(args.layout_id, args.revision)
    revision = layout["revision"]
    revision_hash = revision["hashId"]
    titles = {}
    for entry in sorted(revision.get("layers") or [], key=lambda l: l.get("position") or 0):
        title = (entry.get("title") or "").strip()
        titles[int(entry.get("position", -1))] = title or f"L{entry.get('position')}"

    keymap_c = fetch_keymap_c(revision_hash)
    src = strip_comments(keymap_c)
    try:
        layers = parse_layers(src)
        dual = parse_dual_funcs(src)
        colours = led_colours(parse_ledmap(src))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    lab = Labeller(dual, titles)
    keymap = build_keymap(layout.get("title") or "", revision_hash, layers, lab, colours)
    try:
        validate_keymap(keymap)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(keymap, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    counts = {"mapped": 0, "disabled": 0, "transparent": 0}
    for layer in keymap["layers"]:
        for binding in layer["bindings"]:
            counts[binding["kind"]] = counts.get(binding["kind"], 0) + 1
    print(f"wrote {args.output}")
    print("  title: %s | revision: %s | firmware: %s | keys: %d | layers: %d"
          % (keymap["title"], keymap["revision"], revision.get("qmkVersion") or "?",
             len(keymap["keys"]), len(keymap["layers"])))
    print("  layers: %s" % ", ".join("%d=%s" % (layer["index"], layer["title"])
                                     for layer in keymap["layers"]))
    print("  bindings: %d mapped, %d disabled, %d transparent"
          % (counts["mapped"], counts["disabled"], counts["transparent"]))
    fallbacks = sorted(set(lab.fallbacks))[:10]
    if fallbacks:
        print("  legend fallbacks (raw codes kept): %s%s"
              % (", ".join(fallbacks), "…" if len(set(lab.fallbacks)) > 10 else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
