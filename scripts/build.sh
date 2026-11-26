#!/bin/bash
# Builds "build/VPN Guard.app" (menu bar app with the root helper inside it).
#
#   scripts/build.sh                      # release build, signed with your Apple Development cert if found
#   SIGN_IDENTITY=- scripts/build.sh      # force ad-hoc signing
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/VPNGuardCore/Constants.swift)
APP="$ROOT/build/VPN Guard.app"

echo "==> Building VPN Guard $VERSION ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Making the app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cp "$BIN/VPNGuard" "$APP/Contents/MacOS/VPNGuard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

HELPER="$APP/Contents/Resources/helper"
cp "$BIN/VPNGuardHelper" "$HELPER/local.vpnguard.helper"

# WireGuard engine (wireguard-go, MIT license), built from source and shipped inside the app,
# so users install nothing else. Building needs Go; users don't.
WG_MODULE="golang.zx2c4.com/wireguard@v0.0.0-20261024220952-b3bc704ef0ee"
WG_BIN="build/go-bin/wireguard"
if [ ! -x "$WG_BIN" ] || ! go version -m "$WG_BIN" 2>/dev/null | grep -q "${WG_MODULE#*@}"; then
  echo "==> Building the WireGuard engine ($WG_MODULE)"
  command -v go >/dev/null || { echo "Go is needed to build the WireGuard engine: brew install go" >&2; exit 1; }
  mkdir -p build/go-bin
  GOBIN="$ROOT/build/go-bin" GOFLAGS=-trimpath CGO_ENABLED=0 go install "$WG_MODULE"
fi
cp "$WG_BIN" "$HELPER/local.vpnguard.wireguard-go"
cp Resources/helper/local.vpnguard.helper.plist Resources/helper/install-helper.sh Resources/helper/uninstall-helper.sh "$HELPER/"

if [ ! -f build/AppIcon.icns ]; then
  echo "==> Drawing the app icon"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/AppIcon-1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# License texts travel with the binaries (GPL v3, plus MIT/BSD for the WireGuard engine).
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Signing. With a real certificate the helper only accepts XPC calls from code signed by
# the same team; with ad-hoc signing it can only check the identifiers.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"(Apple Development|Developer ID Application)/ { print $2; exit }')
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing (identity ${SIGN_IDENTITY:0:8}…)"
codesign --force --timestamp=none --identifier local.vpnguard.helper \
  --sign "$SIGN_IDENTITY" "$HELPER/local.vpnguard.helper"
codesign --force --timestamp=none --identifier local.vpnguard.wireguard-go \
  --sign "$SIGN_IDENTITY" "$HELPER/local.vpnguard.wireguard-go"
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$HELPER/local.vpnguard.helper"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"
