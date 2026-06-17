#!/bin/bash
# uninstall-autostart.sh — remove the ColdSpot auto-start LaunchDaemon.
# RUN WITH SUDO:  sudo bash uninstall-autostart.sh

DST="/Library/LaunchDaemons/com.coldspot.hotspot.plist"
WIFI="Wi-Fi"

echo "[uninstall] unloading + removing the daemon"
launchctl unload "$DST" 2>/dev/null || true
rm -f "$DST"

echo "[uninstall] stopping proxy + disabling SOCKS5"
pkill -f "proxy.py" 2>/dev/null || true
pkill -f "tcpdump -i en0" 2>/dev/null || true
networksetup -setsocksfirewallproxystate "$WIFI" off 2>/dev/null || true

echo "[uninstall] done ✓ — back to fully manual."
