#!/bin/bash
# Packs "build/VPN Guard.app" into dist/VPN-Guard-<version>.dmg (drag to Applications),
# plus a SHA-256 checksum file. Build the app first:
#   UNIVERSAL=1 SIGN_IDENTITY=- scripts/build.sh && scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP="$PWD/build/VPN Guard.app"
[ -d "$APP" ] || { echo "Build the app first: UNIVERSAL=1 SIGN_IDENTITY=- scripts/build.sh" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="VPN-Guard-$VERSION"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/VPN Guard.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open VPN Guard.txt" <<TXT
VPN Guard $VERSION — free and open source (GPL v3)

This copy is not notarized by Apple, so macOS asks you once before the first start:

1. Drag "VPN Guard" onto "Applications".
2. Open VPN Guard from Applications. macOS says it was not opened. Click "Done".
3. Open System Settings > Privacy & Security. Scroll down and click "Open Anyway"
   next to VPN Guard, then confirm with your password.
4. VPN Guard starts. Follow the 3 setup steps in the welcome window.

Protection stays off until you turn it on, so installing never cuts your internet.

Source code, checksums and help: https://github.com/hkvn/vpn-guard
TXT

mkdir -p dist
rm -f "dist/$NAME.dmg" "dist/$NAME.dmg.sha256"
hdiutil create -quiet -volname "VPN Guard $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 "dist/$NAME.dmg"
hdiutil verify -quiet "dist/$NAME.dmg"
(cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "==> Done: dist/$NAME.dmg ($(du -h "dist/$NAME.dmg" | cut -f1))"
cat "dist/$NAME.dmg.sha256"
