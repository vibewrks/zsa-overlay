#!/usr/bin/env bash
# Builds the Swift app and the Rust sidecar, then assembles and signs the .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Moonlander Overlay"
APP="$ROOT/build/$APP_NAME.app"

echo "==> Building Swift package ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --package-path "$ROOT"
BIN_PATH="$(swift build -c "$CONFIGURATION" --package-path "$ROOT" --show-bin-path)"

echo "==> Building Rust sidecar (release)"
cargo build --release --manifest-path "$ROOT/Sidecar/Cargo.toml"

SIDECAR="$ROOT/Sidecar/target/release/moonlander-layer-status"
KEYMAP="$ROOT/Sources/MoonlanderOverlayKit/Resources/keymap.json"

for required in "$BIN_PATH/MoonlanderOverlay" "$SIDECAR" "$KEYMAP"; do
    if [ ! -e "$required" ]; then
        echo "missing build product: $required" >&2
        exit 1
    fi
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN_PATH/MoonlanderOverlay" "$APP/Contents/MacOS/MoonlanderOverlay"
cp "$SIDECAR" "$APP/Contents/Helpers/moonlander-layer-status"
cp "$KEYMAP" "$APP/Contents/Resources/keymap.json"

# SwiftPM resource bundle, so Bundle.module also resolves inside the .app.
if [ -d "$BIN_PATH/MoonlanderOverlay_MoonlanderOverlayKit.bundle" ]; then
    cp -R "$BIN_PATH/MoonlanderOverlay_MoonlanderOverlayKit.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Moonlander Overlay</string>
	<key>CFBundleDisplayName</key>
	<string>Moonlander Overlay</string>
	<key>CFBundleIdentifier</key>
	<string>com.vibewrks.MoonlanderOverlay</string>
	<key>CFBundleExecutable</key>
	<string>MoonlanderOverlay</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

chmod +x "$APP/Contents/MacOS/MoonlanderOverlay" "$APP/Contents/Helpers/moonlander-layer-status"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
