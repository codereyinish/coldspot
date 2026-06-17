#!/bin/bash
# install-autostart.sh — install the ColdSpot auto-start LaunchDaemon.
# RUN WITH SUDO:  sudo bash install-autostart.sh
set -e

SRC="/Users/inishbista/wg-hotspot-mac/ios-proxy-test/com.coldspot.hotspot.plist"
DST="/Library/LaunchDaemons/com.coldspot.hotspot.plist"

echo "[install] copying plist → $DST"
cp "$SRC" "$DST"
chown root:wheel "$DST"     # LaunchDaemons must be owned by root
chmod 644 "$DST"

echo "[install] (re)loading the daemon"
launchctl unload "$DST" 2>/dev/null || true
launchctl load -w "$DST"

echo "[install] done ✓"
echo "  • it now auto-starts ColdSpot whenever you join the iPhone hotspot"
echo "  • logs: /tmp/coldspot.log   (and /tmp/coldspot-proxy.log for proxy.py)"
echo "  • to remove: sudo bash uninstall-autostart.sh"
