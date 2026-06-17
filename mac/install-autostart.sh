#!/bin/bash
# install-autostart.sh — install the ColdSpot auto-start LaunchDaemon.
# RUN WITH SUDO:  sudo bash mac/install-autostart.sh
#
# Portable: the watcher path is computed from THIS script's location, so the
# repo works wherever it's cloned (no hardcoded /Users/... paths).
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"          # .../coldspot/mac
WATCH="$DIR/coldspot-watch.sh"                 # absolute path to the watcher
TEMPLATE="$DIR/com.coldspot.hotspot.plist"
DST="/Library/LaunchDaemons/com.coldspot.hotspot.plist"

[ -f "$WATCH" ] || { echo "[install] ERROR: $WATCH not found"; exit 1; }

echo "[install] writing plist → $DST  (watcher: $WATCH)"
# substitute the placeholder with the real absolute watcher path
sed "s|__COLDSPOT_WATCH__|$WATCH|" "$TEMPLATE" > "$DST"
chown root:wheel "$DST"     # LaunchDaemons must be owned by root
chmod 644 "$DST"

echo "[install] (re)loading the daemon"
launchctl unload "$DST" 2>/dev/null || true
launchctl load -w "$DST"

echo "[install] done ✓"
echo "  • it now auto-starts ColdSpot whenever you join the iPhone hotspot"
echo "  • logs: /tmp/coldspot.log   (and /tmp/coldspot-proxy.log for proxy.py)"
echo "  • to remove: sudo bash mac/uninstall-autostart.sh"
