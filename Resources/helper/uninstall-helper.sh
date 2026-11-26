#!/bin/bash
# Removes the VPN Guard root helper and its firewall rules. Run as root.
# Add --purge to also delete the trusted networks and settings.
set -uo pipefail

LABEL="local.vpnguard.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ANCHOR="com.apple/000.vpnguard"
TOKEN_FILE="/var/run/vpnguard.pftoken"

if [ "$(id -u)" != "0" ]; then
  echo "Run this as root (sudo)." >&2
  exit 1
fi

# Stop the helper first, so it cannot put the rules back.
launchctl bootout "system/$LABEL" 2>/dev/null || true

/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
if [ -f "$TOKEN_FILE" ]; then
  /sbin/pfctl -X "$(cat "$TOKEN_FILE")" >/dev/null 2>&1 || true
  rm -f "$TOKEN_FILE"
fi

# Remove our files in /etc/resolver (the ones that start with our marker).
for f in /etc/resolver/*; do
  [ -f "$f" ] && head -1 "$f" | grep -q '^# VPN Guard' && rm -f "$f"
done
killall -HUP mDNSResponder 2>/dev/null || true

# WireGuard: stop the engine, drop its socket and the DNS settings it published.
pkill -f /Library/PrivilegedHelperTools/local.vpnguard.wireguard-go 2>/dev/null || true
rm -f /Library/PrivilegedHelperTools/local.vpnguard.wireguard-go /var/run/wireguard/vpnguard.name /var/run/vpnguard-dns.json
printf 'remove State:/Network/Service/VPNGuard-WireGuard/IPv4\nremove State:/Network/Service/VPNGuard-WireGuard/DNS\nquit\n' | scutil >/dev/null 2>&1 || true

rm -f "$BIN" "$PLIST"
if [ -L /usr/local/bin/vpnguard ]; then rm -f /usr/local/bin/vpnguard; fi

for arg in "$@"; do
  if [ "$arg" = "--purge" ]; then
    rm -rf "/Library/Application Support/VPNGuard" /var/log/vpnguard.log
  fi
done

echo "VPN Guard helper removed. The internet works normally again."
