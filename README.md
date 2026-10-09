# Moonlander Overlay

A macOS menu-bar app that draws the Moonlander's keycaps as a transparent, always-on-top
overlay and follows the keyboard's active layer live. Built because Keymapp's own window is
opaque and cannot be made transparent.

Two pieces:

| Piece | Language | Responsibility |
|---|---|---|
| `Sources/` | Swift 6 / AppKit | Transparent window, keycap rendering, layers, geometry, IPC with the helper |
| `Sidecar/` | Rust | Polls the Keymapp API over its Unix socket and prints one JSON status line per tick |

The split exists because the Keymapp API is gRPC over a Unix domain socket. The Rust helper
uses `tonic` with ZSA's protobuf contract; AppKit provides the native transparent panel.

---

## Quick start

```sh
cd ~/dev/apps/moonlander-overlay
./scripts/build-app.sh                  # builds Swift + Rust, assembles and ad-hoc signs the .app
open "build/Moonlander Overlay.app"     # menu-bar only — no Dock icon
```

- **Toggle:** ⌃⌥K, or the menu-bar keyboard icon. **Hide:** Escape.
- **Quit:** menu → Quit, or `pkill -f 'Contents/MacOS/MoonlanderOverlay'`.
- **Tests:** `swift test`

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 6.2+)
- Rust toolchain (`cargo`)
- `protoc` (`brew install protobuf`) — needed to rebuild the sidecar's gRPC bindings
- Keymapp 1.3.7+ **running**, with **the API enabled** and **the keyboard connected**

## Keymapp setup (read this first)

1. **Use the direct-download build from [zsa.io/keymapp](https://www.zsa.io/keymapp), not the
   Mac App Store build.** The App Store build is sandboxed, so its socket lives under
   `~/Library/Containers/io.zsa.keymapp/Data/Library/Application Support/.keymapp/keymapp.sock`
   — a path of `96 + <username length>` characters. macOS caps a Unix socket path at 103
   characters (`sun_path` is 104 bytes including the NUL), so with a username of **8 or more
   characters** the `bind()` fails and the API never starts. Keymapp reports:

   ```
   Failed to start API: listen unix /Users/<user>/Library/Containers/.../keymapp.sock: bind: invalid argument
   ```

   The direct-download build is not sandboxed; it uses
   `~/Library/Application Support/.keymapp/keymapp.sock` (65 characters here) and works.
2. In Keymapp's settings, **enable the API**.
3. **Connect the keyboard in Keymapp.** With `startup_autoconnect` off it will not happen by
   itself, and the API then reports `connected_keyboard: none` (the overlay shows
   `⚠️ No keyboard connected`).
4. Verify:

   ```sh
   ./Sidecar/target/release/moonlander-layer-status --once
   # {"state":"connected","layer":0,"message":"","keyboard":"Moonlander MK1"}
   ```

The sidecar probes both socket paths, so either build works as long as the API actually binds.

## Controls

| Action | How |
|---|---|
| Show / hide | ⌃⌥K or menu → Show/Hide Overlay |
| Hide (when visible) | Escape |
| Follow the keyboard's layer | Menu → **Follow Keyboard** (default) |
| Pin one layer | Menu → **Layer** ▸ pick a layer (works with Keymapp closed; remembered across launches) |
| Never intercept clicks | Menu → **Pinned (click-through)** |
| Resize | Drag any edge or corner; the bottom-right notch is the affordance. Or menu → Larger / Smaller |
| Re-read `keymap.json` | Menu → Reload Layout |
| Re-dial the helper | Menu → Retry Layer Status |
| Find the layout file | Menu → Reveal Layout File |

The notch is hidden in click-through mode, where no click can reach the window anyway.
Minimum size is 420×150; the caps scale to whatever size the window is and drop to
primary-only legends before they would collide.

## Updating the layout data

The overlay renders the **cached Oryx revision** from Keymapp's database — it never talks to
Oryx and never flashes. After changing the layout in Oryx:

```sh
python3 scripts/import-keymapp.py --revision <revision-id> \
  --output Sources/MoonlanderOverlayKit/Resources/keymap.json
./scripts/build-app.sh
```

- The importer finds Keymapp's cache automatically — the direct-download build keeps it in
  `~/Library/Application Support/.keymapp/`, the sandboxed App Store build inside its
  container — and opens it **read-only**. Pass `--cache PATH` if it lives elsewhere.
- The menu shows both sides: the loaded revision, and `board: <layout hash>/<revision>` read from
  the keyboard's USB serial, with a ⚠️ when they differ.
- The importer is a one-time converter for ZSA's export format: physical geometry comes from
  QMK's `keyboards/zsa/moonlander/keyboard.json`, key indices from the matrix→Oryx table in
  Keymapp's own frontend, legends from the cache's metadata.

**Flashing** is out of scope: use `zapp` (`zapp flash`) or Keymapp, then import the revision
you flashed so the overlay matches the board.

## Architecture

```
Sources/MoonlanderOverlay/App.swift        menu bar, single-instance hand-off
Sources/MoonlanderOverlayKit/
  Keymap.swift              layout model: keys, layers, bindings, resolution, validation
  KeyboardView.swift        keycap renderer (transparent), edge/corner resize handling
  OverlayResize.swift       pure frame maths for dragging edges (unit-tested)
  OverlayPanel.swift        borderless, non-activating, clear NSPanel
  OverlayController.swift   state: live vs manual layer, geometry, persistence, menu state
  LayerStatusClient.swift   helper process lifecycle + newline-JSON stream parsing
  GlobalHotKey.swift        Carbon ⌃⌥K (no Accessibility permission needed)
Sidecar/                    Rust helper: gRPC client for the Keymapp API
```

- The app spawns the helper and reads its stdout. The helper stops when the overlay is hidden
  and exits on its own if the app dies (its stdout pipe closes).
- Helper contract, one JSON object per line:
  `{"state":"connected|disconnected|unavailable","layer":<int|null>,"message":"","keyboard":<string|null>}`
  `--once` exits 1 when the status is unavailable; `--watch [--interval-ms MS]` streams.
- RPCs used: `GetStatus` (the only source of live layer). The API exposes no key events, RGB
  readback, or keymap — see below.

### Direct-HID spike results

Verified on the attached Moonlander (`GMrOw/rba3al`) without Keymapp running:

| Report prefix | Meaning |
|---|---|
| `fe 05 fe` | Protocol-version response: version 5 |
| `04 fe` | Pairing/session established |
| `05 <layer> fe` | Highest active layer, including the initial layer after pairing |
| `06 <column> <row> fe` | Physical key down |
| `07 <column> <row> fe` | Physical key up |

The captured media hold emitted `05 02 fe`, then `05 00 fe` on release.
Sending protocol-version (`0xfe`) and session-init (`0x01`) requests returned
the version, pairing acknowledgement, and initial layer 0 immediately.
No firmware, layer-selection or RGB commands were sent.

These definitions are published in ZSA's
[Oryx protocol header](https://github.com/zsa/qmk_modules/blob/13890cd7856175de20798689d15ba6a46bf0c5c7/oryx/oryx.h)
and [firmware implementation](https://github.com/zsa/qmk_modules/blob/13890cd7856175de20798689d15ba6a46bf0c5c7/oryx/oryx.c).
Only the fields before the `0xfe` terminator are defined; trailing bytes must be
ignored, not decoded as timestamps or state. Capture times came from the host clock.

A direct-HID helper could therefore replace the API helper and provide press highlighting
without Keymapp running. Keymapp and the probe could not open the raw interface concurrently
with the tested `hidapi` backend; the future reader must release it before using Keymapp
to sync the layout cache. The current overlay still uses the API, not this spike.


## Known limitations

- **No key-press highlighting.** The Keymapp API (enumerated from the shipped binary:
  `GetStatus`, `GetKeyboards`, `ConnectKeyboard`, `ConnectAnyKeyboard`, `DisconnectKeyboard`,
  `SetLayer`, `UnsetLayer`, `SetRGBLed`, `SetRGBAll`, `SetStatusLed`, `IncreaseBrightness`,
  `DecreaseBrightness`) carries no per-key state, so presses cannot be observed through it.
  A separate HID spike verified that the board supplies both key events and layer changes
  directly; that reader has not replaced the API helper in the shipped overlay.
- **Inherited keys show `↧` instead of a guessed legend.** The API reports a single layer
  index; with `TO(layer)` switches the base layer is not necessarily active underneath, so we
  mark inheritance rather than print a label we cannot verify.
- **Click-through disables resizing** (and hides the notch).
- **Revision drift is detected; Oryx is not polled.** The board's USB serial number carries
  `<layout hash>/<revision>` (e.g. `GMrOw/rba3al`); the overlay reads it and warns when the layout
  it was built from differs from what is flashed. It cannot know whether a *newer* Oryx revision
  exists — sync Keymapp and re-run the importer when you change the layout.
  The USB identity is refreshed on launch, when showing the overlay, and on Reload Layout.
- Manual layer mode is what you get when Keymapp is absent; the overlay remembers your choice.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `⚠️ Keymapp not reachable · showing layer 0 (not live)` | API disabled, Keymapp not running, or the socket never bound (see the App Store path limit above). Check with `--once` |
| `⚠️ No keyboard connected` | Connect the keyboard in Keymapp |
| `Failed to start API: ... bind: invalid argument` | App Store (sandboxed) build; install the direct-download build |
| Overlay looks frozen after being hidden | By design: polling stops while hidden, resumes on show |
| Layer does not change live | The keyboard must be connected in Keymapp, not just plugged in |
| ⌃⌥K does nothing | The shortcut is already taken; use the menu (registration failure is reported on stderr) |
| Layout looks stale | Re-run the importer for the revision you flashed, then `Reload Layout` or rebuild |
| `⚠️ board <rev> · overlay <rev> — re-import layout` | The board is flashed with a different Oryx revision than `keymap.json`; re-run the importer for that revision and rebuild |
| Want to know what the board is flashed with | `"build/Moonlander Overlay.app/Contents/MacOS/MoonlanderOverlay" --print-identity` prints `<layout hash>/<revision>` |
| Importer: `revision 'x' not in cache (available: none)` | It is reading the wrong cache — usually the abandoned App Store container after switching to the direct-download build. The default probes both; pass `--cache` explicitly if needed |

## Tests

`swift test` covers the layout import and validation, binding resolution (mapped / disabled /
transparent precedence), the sidecar JSON stream (partial lines, multiple records per chunk,
malformed input), and the resize frame maths (anchoring, minimum/maximum clamping).

The sidecar is exercised separately:

```sh
cargo build --release --manifest-path Sidecar/Cargo.toml
./Sidecar/target/release/moonlander-layer-status --help
```
