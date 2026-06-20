#!/bin/bash
# install.sh — ONE command to set up ColdSpot + the ❄️ menu-bar toggle.
# Run as YOU (NOT sudo) — it asks for your password only for the daemon part:
#
#     bash mac/install.sh
#
# It does two things:
#   1) installs the root LaunchDaemon (the brains: watches network + flag,
#      starts/stops proxy + SOCKS5 + tunnel) — needs sudo, prompts once.
#   2) links the SwiftBar plugin (the ❄️ button) into your SwiftBar folder —
#      runs as you, so it can read your SwiftBar settings.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" = 0 ]; then
    echo "[install] Run me WITHOUT sudo (I'll sudo only the part that needs it):"
    echo "          bash mac/install.sh"
    exit 1
fi

echo "[install] 1/2 — installing the background daemon (needs your password)…"
sudo bash "$DIR/install-autostart.sh"

echo
echo "[install] 2/2 — linking the SwiftBar menu-bar plugin…"
bash "$DIR/install-swiftbar.sh"

echo
echo "[install] all set ✓"
echo "  • The ❄️ appears in your menu bar (SwiftBar must be installed + opened)."
echo "  • Click it ▸ Turn ON to enable ColdSpot. It runs only on the iPhone hotspot."
echo "  • Toggle OFF (or leave the hotspot) tears everything down → normal browsing."
