#!/bin/bash
# Builds the app, copies it to /Applications and opens it.
# The app then asks for your admin password once to install the helper.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

DEST="/Applications/VPN Guard.app"
osascript -e 'tell application id "local.vpnguard.app" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 50); do pgrep -qf "VPN Guard.app/Contents/MacOS/VPNGuard" || break; sleep 0.1; done
rm -rf "$DEST"
cp -R "build/VPN Guard.app" "$DEST"
echo "==> Installed $DEST"

# If the helper is already installed, update it in place (asks for the admin password).
if [ -f /Library/PrivilegedHelperTools/local.vpnguard.helper ] && [ "${SKIP_HELPER:-0}" != "1" ]; then
  echo "==> Updating the helper (admin password needed)"
  H="$DEST/Contents/Resources/helper"
  osascript -e "do shell script \"/bin/bash '$H/install-helper.sh' '$H'\" with administrator privileges"
fi

open "$DEST"
