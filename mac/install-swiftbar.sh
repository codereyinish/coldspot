#!/bin/bash
# install-swiftbar.sh — symlink the ColdSpot SwiftBar plugin into SwiftBar's
# plugin folder. Run as YOU (no sudo):  bash mac/install-swiftbar.sh
#
# Prereqs:
#   • SwiftBar installed (brew install --cask swiftbar) and opened once so it has
#     a plugin folder configured.
#   • the auto-start daemon installed:  sudo bash mac/install-autostart.sh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"          # .../coldspot/mac
PLUGIN="$DIR/swiftbar/coldspot.5s.sh"

chmod +x "$PLUGIN" "$DIR/coldspot-toggle.sh"

# SwiftBar stores its plugin folder in user defaults
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$PLUGIN_DIR" ]; then
    echo "[swiftbar] Couldn't find SwiftBar's plugin folder."
    echo "           Open SwiftBar once and set a Plugin Folder, then re-run this."
    exit 1
fi

mkdir -p "$PLUGIN_DIR"
ln -sf "$PLUGIN" "$PLUGIN_DIR/coldspot.5s.sh"
echo "[swiftbar] linked → $PLUGIN_DIR/coldspot.5s.sh"
echo "[swiftbar] done ✓ — click SwiftBar ▸ Refresh All (or wait 5s) to see ❄️"
