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

# the real (non-root) user, even when this runs under sudo, plus their home.
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~${REAL_USER}")"
FLAGDIR="$USER_HOME/.coldspot"                  # holds the menu-bar on/off flag

[ -f "$WATCH" ] || { echo "[install] ERROR: $WATCH not found"; exit 1; }

# create the flag folder owned by the user so the menu-bar app can write it, and
# so launchd's WatchPaths has a path to watch from the very first toggle.
echo "[install] flag folder → $FLAGDIR (owner: $REAL_USER)"
mkdir -p "$FLAGDIR"
chown "$REAL_USER" "$FLAGDIR"

echo "[install] writing plist → $DST  (watcher: $WATCH)"
# substitute both placeholders: the watcher path and the flag folder to watch
sed -e "s|__COLDSPOT_WATCH__|$WATCH|" \
    -e "s|__COLDSPOT_FLAGDIR__|$FLAGDIR|" "$TEMPLATE" > "$DST"
chown root:wheel "$DST"     # LaunchDaemons must be owned by root
chmod 644 "$DST"

echo "[install] (re)loading the daemon"
launchctl unload "$DST" 2>/dev/null || true
launchctl load -w "$DST"

echo "[install] done ✓"
echo "  • it now auto-starts ColdSpot whenever you join the iPhone hotspot"
echo "  • logs: /tmp/coldspot.log   (and /tmp/coldspot-proxy.log for proxy.py)"
echo "  • to remove: sudo bash mac/uninstall-autostart.sh"
