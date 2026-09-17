#!/usr/bin/env bash
# Build, verify, and install Stay Alive
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_APP="${HOME}/Applications/StayAlive.app"
SYS_APP="/Applications/StayAlive.app"
BUILD_DIR="$ROOT/.build"
CONFIG="${CONFIG:-release}"

echo "==> Building StayAlive ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$BUILD_DIR/$CONFIG/StayAlive"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$BUILD_DIR" -type f -name StayAlive -path "*/$CONFIG/*" | head -1)"
fi
if [[ -z "${BIN:-}" || ! -x "$BIN" ]]; then
  echo "error: StayAlive binary not found after build" >&2
  exit 1
fi
echo "    binary: $BIN"

echo "==> CLI self-test (raw binary)"
if ! "$BIN" --self-test; then
  echo "error: self-test FAILED — refusing to install" >&2
  exit 1
fi

echo "==> Assembling .app bundle"
STAGE="$BUILD_DIR/StayAlive.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/StayAlive"
chmod +x "$STAGE/Contents/MacOS/StayAlive"
cp "$ROOT/StayAlive/Info.plist" "$STAGE/Contents/Info.plist"
echo -n 'APPL????' > "$STAGE/Contents/PkgInfo"

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
  iconutil -c icns "$ICNS_STAGING" -o "$STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

# Ad-hoc sign + strip quarantine
codesign --force --deep --sign - "$STAGE" 2>/dev/null || true
xattr -cr "$STAGE" 2>/dev/null || true

echo "==> App bundle self-test"
if ! "$STAGE/Contents/MacOS/StayAlive" --self-test; then
  echo "error: .app self-test FAILED" >&2
  exit 1
fi

echo "==> Installing"
pkill -x StayAlive 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications"
rm -rf "$HOME_APP"
cp -R "$STAGE" "$HOME_APP"
xattr -cr "$HOME_APP" 2>/dev/null || true
codesign --force --deep --sign - "$HOME_APP" 2>/dev/null || true

if [[ -w /Applications ]]; then
  rm -rf "$SYS_APP"
  cp -R "$STAGE" "$SYS_APP"
  xattr -cr "$SYS_APP" 2>/dev/null || true
  codesign --force --deep --sign - "$SYS_APP" 2>/dev/null || true
  echo "    installed: $SYS_APP"
fi
echo "    installed: $HOME_APP"

# Also keep ROOT-adjacent path used historically
rm -rf /Users/dubsf3/Applications/StayAlive.app
cp -R "$STAGE" /Users/dubsf3/Applications/StayAlive.app
xattr -cr /Users/dubsf3/Applications/StayAlive.app 2>/dev/null || true
codesign --force --deep --sign - /Users/dubsf3/Applications/StayAlive.app 2>/dev/null || true

echo "==> Launch verification (open + live 4s)"
open /Users/dubsf3/Applications/StayAlive.app
sleep 4
if ! pgrep -x StayAlive >/dev/null; then
  echo "error: StayAlive did not stay running after open" >&2
  exit 1
fi
echo "    running pid(s): $(pgrep -x StayAlive | tr '\n' ' ')"
echo "==> Done (verified)"
