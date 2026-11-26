#!/bin/bash
# Installs (or updates) the VPN Guard root helper. Run as root:
#   sudo bash install-helper.sh <folder with local.vpnguard.helper and its plist>
# The app runs this through the macOS admin password dialog.
set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")" && pwd)}"
LABEL="local.vpnguard.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$(id -u)" != "0" ]; then
  echo "Run this as root (sudo)." >&2
  exit 1
fi
for f in "$SRC/$LABEL" "$SRC/$LABEL.plist"; do
  [ -f "$f" ] || { echo "Missing $f" >&2; exit 1; }
done

# Stop the old helper. Its firewall rules stay loaded, so there is no gap.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  for _ in $(seq 1 50); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

mkdir -p /Library/PrivilegedHelperTools "/Library/Application Support/VPNGuard"
install -m 0755 -o root -g wheel "$SRC/$LABEL" "$BIN"
install -m 0644 -o root -g wheel "$SRC/$LABEL.plist" "$PLIST"
# Built-in WireGuard engine.
if [ -f "$SRC/local.vpnguard.wireguard-go" ]; then
  install -m 0755 -o root -g wheel "$SRC/local.vpnguard.wireguard-go" /Library/PrivilegedHelperTools/local.vpnguard.wireguard-go
fi
# Files from a downloaded DMG carry the quarantine flag; launchd would refuse to run them.
xattr -c "$BIN" /Library/PrivilegedHelperTools/local.vpnguard.wireguard-go 2>/dev/null || true

# Remember which app copy installed the helper. Ad-hoc builds (the free DMG) only accept XPC
# calls from exactly this copy and from the vpnguard tool itself.
APP_BUNDLE="$(cd "$SRC/../../.." 2>/dev/null && pwd -P || true)"
if [[ "$APP_BUNDLE" == *.app && -x "$APP_BUNDLE/Contents/MacOS/VPNGuard" ]]; then
  "$BIN" pin-app "$APP_BUNDLE" || echo "Warning: could not pin the app; it may need a helper reinstall." >&2
fi
touch /var/log/vpnguard.log
chmod 0644 /var/log/vpnguard.log

# Command line tool: `vpnguard status`
mkdir -p /usr/local/bin
ln -sfn "$BIN" /usr/local/bin/vpnguard

launchctl bootstrap system "$PLIST"
echo "VPN Guard helper installed."
