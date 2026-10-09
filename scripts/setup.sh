#!/usr/bin/env bash
# First-run setup: checks prerequisites, builds the app, imports YOUR
# Keymapp/Oryx layout revision, and rebuilds with it bundled.
#
# Usage:
#   ./scripts/setup.sh
#
# The bundled keymap.json that ships with a fresh clone is the author's own
# layout. Every other user should run this once so the overlay shows their
# legends. Keymapp is needed only during this import (to have synced the
# layout into its local cache); it is not a runtime dependency.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYMAP="$ROOT/Sources/MoonlanderOverlayKit/Resources/keymap.json"

fail() { echo "error: $*" >&2; exit 1; }

echo "==> Checking prerequisites"
command -v swift >/dev/null || fail "Swift not found (install Xcode command-line tools)"
command -v cargo >/dev/null || fail "Cargo not found (install Rust)"
command -v python3 >/dev/null || fail "Python 3 not found"

echo "==> Building (needed for --print-identity)"
"$ROOT/scripts/build-app.sh"

APP_BIN="$ROOT/build/Moonlander Overlay.app/Contents/MacOS/MoonlanderOverlay"
[ -x "$APP_BIN" ] || fail "build did not produce $APP_BIN"

echo "==> Reading board identity"
echo "    If Keymapp currently holds the board, quit/disconnect it first,"
echo "    then press Enter."
read -r _
IDENTITY="$("$APP_BIN" --print-identity 2>/dev/null || true)"
if [ -n "$IDENTITY" ]; then
  echo "    board reports: $IDENTITY"
  SUGGESTED="${IDENTITY##*/}"
  echo "    suggested revision: $SUGGESTED"
else
  echo "    warning: board identity not readable (board unplugged or busy?)"
  SUGGESTED=""
fi

echo "==> Cached Keymapp revisions"
CACHED="$(python3 -c "
import sqlite3
from pathlib import Path
cands = [
    Path.home() / 'Library/Application Support/.keymapp/keymapp.sqlite3',
    Path.home() / 'Library/Containers/io.zsa.keymapp/Data/Library/Application Support/.keymapp/keymapp.sqlite3',
]
for p in cands:
    if p.is_file():
        try:
            con = sqlite3.connect('file:%s?mode=ro' % p.as_uri()[5:], uri=True)
            rows = [r[0] for r in con.execute('SELECT revisionId FROM revision ORDER BY revisionId')]
            print('cache: %s' % p)
            print('revisions: %s' % (', '.join(rows) or 'none'))
        except Exception as e:
            print('cache: %s (unreadable: %s)' % (p, e))
        break
else:
    print('no Keymapp cache found')
" 2>&1)"
echo "$CACHED"
if echo "$CACHED" | grep -q "no Keymapp cache found"; then
  fail "install Keymapp, open it, connect the Moonlander to sync, then re-run this script"
fi

if [ -n "$SUGGESTED" ]; then
  printf 'Revision to import [%s]: ' "$SUGGESTED"
else
  printf 'Revision to import: '
fi
read -r REVISION
[ -z "${REVISION:-}" ] && REVISION="$SUGGESTED"
[ -z "${REVISION:-}" ] && fail "no revision given"

echo "==> Importing revision $REVISION"
python3 "$ROOT/scripts/import-keymapp.py" --revision "$REVISION" --output "$KEYMAP"

echo "==> Rebuilding with your layout"
"$ROOT/scripts/build-app.sh"

echo "Done. Launch with: open \"$ROOT/build/Moonlander Overlay.app\""
