#!/usr/bin/env bash
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "==> build"
swift build -c release
BIN=".build/release/StayAlive"
[[ -x "$BIN" ]] || BIN="$(find .build -type f -name StayAlive -path '*/release/*' | head -1)"
[[ -x "$BIN" ]] || { echo "no binary"; exit 1; }

echo "==> self-test"
"$BIN" --self-test || { echo "self-test failed"; exit 1; }

echo "==> package"
STAGE=".build/StayAlive.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/StayAlive"
chmod +x "$STAGE/Contents/MacOS/StayAlive"
cp StayAlive/Info.plist "$STAGE/Contents/Info.plist"
echo -n 'APPL????' > "$STAGE/Contents/PkgInfo"
ICONSET="StayAlive/Assets.xcassets/AppIcon.appiconset"
if [[ -f "$ICONSET/icon_1024.png" ]]; then
  ICNS=".build/AppIcon.iconset"
  rm -rf "$ICNS"; mkdir -p "$ICNS"
  cp "$ICONSET/icon_16.png"   "$ICNS/icon_16x16.png"
  cp "$ICONSET/icon_32.png"   "$ICNS/icon_16x16@2x.png"
  cp "$ICONSET/icon_32.png"   "$ICNS/icon_32x32.png"
  cp "$ICONSET/icon_64.png"   "$ICNS/icon_32x32@2x.png"
  cp "$ICONSET/icon_128.png"  "$ICNS/icon_128x128.png"
  cp "$ICONSET/icon_256.png"  "$ICNS/icon_128x128@2x.png"
  cp "$ICONSET/icon_256.png"  "$ICNS/icon_256x256.png"
  cp "$ICONSET/icon_512.png"  "$ICNS/icon_256x256@2x.png"
  cp "$ICONSET/icon_512.png"  "$ICNS/icon_512x512.png"
  cp "$ICONSET/icon_1024.png" "$ICNS/icon_512x512@2x.png"
  iconutil -c icns "$ICNS" -o "$STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi
codesign --force --deep --sign - "$STAGE" 2>/dev/null || true
xattr -cr "$STAGE" 2>/dev/null || true

echo "==> app self-test"
"$STAGE/Contents/MacOS/StayAlive" --self-test || exit 1

echo "==> install"
pkill -x StayAlive 2>/dev/null || true
sleep 0.3
rm -rf /Applications/StayAlive.app "$HOME/Applications/StayAlive.app" /Users/dubsf3/Applications/StayAlive.app
cp -R "$STAGE" /Applications/StayAlive.app
cp -R "$STAGE" "$HOME/Applications/StayAlive.app"
cp -R "$STAGE" /Users/dubsf3/Applications/StayAlive.app
xattr -cr /Applications/StayAlive.app 2>/dev/null || true
codesign --force --deep --sign - /Applications/StayAlive.app 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/StayAlive.app

echo "==> launch verify"
open /Applications/StayAlive.app
sleep 2
pgrep -x StayAlive >/dev/null || { echo "did not stay running"; exit 1; }
echo "OK pid=$(pgrep -x StayAlive | tr '\n' ' ')"
