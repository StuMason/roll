#!/usr/bin/env bash
# Build the native roll-capture sidecar (macOS only) so the Tauri app can find
# and run it. Run this once before `npm run tauri dev` / build.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ building roll-capture (release)…"
( cd capture-swift && swift build -c release )
BIN="capture-swift/.build/release/roll-capture"
echo "▸ built: $BIN"

# Stage a target-triple-named copy for Tauri externalBin bundling (used later
# when we package for distribution; the app also resolves the path above in dev).
if command -v rustc >/dev/null 2>&1; then
  TRIPLE="$(rustc -Vv | sed -n 's/^host: //p')"
  mkdir -p src-tauri/binaries
  cp "$BIN" "src-tauri/binaries/roll-capture-${TRIPLE}"
  echo "▸ staged: src-tauri/binaries/roll-capture-${TRIPLE}"
fi

echo "✓ done — now run: npm run tauri dev"
