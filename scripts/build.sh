#!/bin/bash
# Builds "build/VPN Guard.app" (menu bar app with the root helper inside it).
#
#   scripts/build.sh                      # release build, signed with your Apple Development cert if found
#   SIGN_IDENTITY=- scripts/build.sh      # force ad-hoc signing
#   UNIVERSAL=1 SIGN_IDENTITY=- scripts/build.sh   # what the downloadable DMG ships (arm64 + x86_64)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/VPNGuardCore/Constants.swift)
APP="$ROOT/build/VPN Guard.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
ARCH_FLAGS=()
for a in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$a"); done

echo "==> Building VPN Guard $VERSION ($CONFIG, ${ARCHS[*]})"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

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
WG_SLICES=()
for a in "${ARCHS[@]}"; do
  GOARCH=$([ "$a" = "x86_64" ] && echo amd64 || echo "$a")
  WG_BIN="build/go-bin/wireguard-$GOARCH"
  if [ ! -x "$WG_BIN" ] || [ "$(cat "$WG_BIN.version" 2>/dev/null)" != "$WG_MODULE" ]; then
    echo "==> Building the WireGuard engine ($WG_MODULE, $GOARCH)"
    command -v go >/dev/null || { echo "Go is needed to build the WireGuard engine: brew install go" >&2; exit 1; }
    mkdir -p build/go-bin
    WG_SRC=$(go mod download -json "$WG_MODULE" | sed -nE 's/^[[:space:]]*"Dir": "(.*)",?$/\1/p')
    [ -d "$WG_SRC" ] || { echo "Could not download $WG_MODULE" >&2; exit 1; }
    (cd "$WG_SRC" && GOOS=darwin GOARCH="$GOARCH" CGO_ENABLED=0 GOFLAGS=-mod=readonly \
      go build -trimpath -ldflags "-s -w" -o "$ROOT/$WG_BIN" .)
    echo "$WG_MODULE" > "$WG_BIN.version"
  fi
  WG_SLICES+=("$WG_BIN")
done
lipo -create "${WG_SLICES[@]}" -output "$HELPER/local.vpnguard.wireguard-go"
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

# Signing, always with the hardened runtime (no code injection, no debugger attach).
# With a certificate the helper accepts XPC calls from code of the same team; ad-hoc builds pin
# the exact app copy that installed the helper (see ClientTrust in VPNGuardCore).
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"(Apple Development|Developer ID Application)/ { print $2; exit }')
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing (identity ${SIGN_IDENTITY:0:8}…)"
SIGN=(codesign --force --timestamp=none --options runtime --sign "$SIGN_IDENTITY")
"${SIGN[@]}" --identifier local.vpnguard.helper "$HELPER/local.vpnguard.helper"
"${SIGN[@]}" --identifier local.vpnguard.wireguard-go "$HELPER/local.vpnguard.wireguard-go"
"${SIGN[@]}" "$APP"
codesign --verify --strict "$HELPER/local.vpnguard.helper"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"
