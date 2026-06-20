#!/bin/bash
# coldspot.5s.sh — SwiftBar plugin: ColdSpot menu-bar toggle + status.
# Refreshes every 5s (the ".5s." in the filename tells SwiftBar that).
#
# The button only flips a flag file (via coldspot-toggle.sh, runs as you). The
# root LaunchDaemon watches that file and does all the real work. So this plugin
# stays unprivileged and just shows state + offers ON/OFF.
#
# Install:  bash mac/install-swiftbar.sh   (symlinks this into SwiftBar's plugins)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# --- locate the repo's mac/ dir, even when SwiftBar ran us via a symlink -------
SELF="$0"; [ -L "$SELF" ] && SELF="$(readlink "$SELF")"
MAC_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
TOGGLE="$MAC_DIR/coldspot-toggle.sh"

# --- read current state -------------------------------------------------------
IPHONE_GATEWAY="172.20.10.1"
toggle_state="$(bash "$TOGGLE" status 2>/dev/null)"          # on | off
gateway="$(netstat -rn 2>/dev/null | awk '/default/{print $2}' | head -1)"
on_hotspot=no; [ "$gateway" = "$IPHONE_GATEWAY" ] && on_hotspot=yes
proxy_up=no;   nc -z -w1 127.0.0.1 1080 >/dev/null 2>&1 && proxy_up=yes
slots="$(netstat -an 2>/dev/null | grep '\.9999 ' | grep -c ESTABLISHED)"

# derive a human status (shown in the dropdown)
if [ "$toggle_state" != "on" ]; then
    status="Off"
elif [ "$on_hotspot" = yes ] && [ "$proxy_up" = yes ]; then
    status="Running"
elif [ "$on_hotspot" = yes ]; then
    status="Starting…"
else
    status="Waiting for hotspot"
fi

# menu-bar icon = a square badge, identical size in both states (pre-rendered
# PNGs baked into the repo, so SwiftBar scales them the same):
#   OFF → grey square + white snowflake
#   ON  → green square + white snowflake
if [ "$toggle_state" = "on" ]; then
    badge="$MAC_DIR/swiftbar/coldspot-on.png"
else
    badge="$MAC_DIR/swiftbar/coldspot-off.png"
fi
menubar=" | image=$(base64 < "$badge" | tr -d '\n')"

# --- render -------------------------------------------------------------------
echo "$menubar"
echo "---"
echo "ColdSpot — $status | size=13"
echo "On hotspot: $on_hotspot | color=#888888 size=12"
echo "Proxy :1080: $proxy_up | color=#888888 size=12"
echo "iPhone slots: $slots | color=#888888 size=12"
echo "---"
if [ "$toggle_state" = "on" ]; then
    echo "Turn OFF | bash=\"$TOGGLE\" param1=off terminal=false refresh=true"
else
    echo "Turn ON | bash=\"$TOGGLE\" param1=on terminal=false refresh=true"
fi
echo "---"
echo "Open watcher log | bash=/usr/bin/open param1=/tmp/coldspot.log terminal=false"
echo "Open proxy log | bash=/usr/bin/open param1=/tmp/coldspot-proxy.log terminal=false"
echo "Refresh | refresh=true"
