#!/usr/bin/env bash
# Build Stay Alive into /Users/dubsf3/Applications/StayAlive.app
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_OUT="${APP_OUT:-/Users/dubsf3/Applications/StayAlive.app}"
BUILD_DIR="$ROOT/.build"
CONFIG="${CONFIG:-release}"

echo "==> Building StayAlive ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" 2>&1

BIN="$BUILD_DIR/$CONFIG/StayAlive"
if [[ ! -x "$BIN" ]]; then
  # SPM may nest under apple/ or arm64-apple-macosx
  BIN="$(find "$BUILD_DIR" -type f -name StayAlive -path "*/$CONFIG/*" | head -1)"
fi
if [[ -z "${BIN:-}" || ! -x "$BIN" ]]; then
  echo "error: StayAlive binary not found after build" >&2
  exit 1
fi
echo "    binary: $BIN"

echo "==> Assembling .app bundle at $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS"
mkdir -p "$APP_OUT/Contents/Resources"

cp "$BIN" "$APP_OUT/Contents/MacOS/StayAlive"
chmod +x "$APP_OUT/Contents/MacOS/StayAlive"
cp "$ROOT/StayAlive/Info.plist" "$APP_OUT/Contents/Info.plist"
echo -n 'APPL????' > "$APP_OUT/Contents/PkgInfo"

# Icons
ICONSET="$ROOT/StayAlive/Assets.xcassets/AppIcon.appiconset"
ICNS_STAGING="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICNS_STAGING"
mkdir -p "$ICNS_STAGING"
if [[ -f "$ICONSET/icon_16.png" ]]; then
  cp "$ICONSET/icon_16.png"  "$ICNS_STAGING/icon_16x16.png"
  cp "$ICONSET/icon_32.png"  "$ICNS_STAGING/icon_16x16@2x.png"
  cp "$ICONSET/icon_32.png"  "$ICNS_STAGING/icon_32x32.png"
  cp "$ICONSET/icon_64.png"  "$ICNS_STAGING/icon_32x32@2x.png"
  cp "$ICONSET/icon_128.png" "$ICNS_STAGING/icon_128x128.png"
  cp "$ICONSET/icon_256.png" "$ICNS_STAGING/icon_128x128@2x.png"
  cp "$ICONSET/icon_256.png" "$ICNS_STAGING/icon_256x256.png"
  cp "$ICONSET/icon_512.png" "$ICNS_STAGING/icon_256x256@2x.png"
  cp "$ICONSET/icon_512.png" "$ICNS_STAGING/icon_512x512.png"
  cp "$ICONSET/icon_1024.png" "$ICNS_STAGING/icon_512x512@2x.png"
  iconutil -c icns "$ICNS_STAGING" -o "$APP_OUT/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

# Ad-hoc sign so Gatekeeper is less noisy for local use
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_OUT" 2>/dev/null || true
fi

echo "==> Done: $APP_OUT"
echo "    open -a '$APP_OUT'"
