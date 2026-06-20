#!/bin/bash
# coldspot-toggle.sh — flip the ColdSpot menu-bar ON/OFF flag.
#
# This is the ONLY thing the menu-bar button does. It just creates or deletes a
# small flag file = your saved intent. The root LaunchDaemon (coldspot-watch.sh)
# watches this folder, so the moment the flag changes it reconciles: brings
# ColdSpot up (if also on the hotspot) or tears it fully down.
#
# Runs as YOU — no root, no sudo. The privileged work stays in the daemon.
#
#   coldspot-toggle.sh on       # turn ColdSpot on
#   coldspot-toggle.sh off      # turn it off
#   coldspot-toggle.sh toggle   # flip whichever it is
#   coldspot-toggle.sh status   # print "on" or "off" (for the plugin)

FLAGDIR="$HOME/.coldspot"
FLAG="$FLAGDIR/enabled"
mkdir -p "$FLAGDIR"

case "${1:-toggle}" in
    on)     touch "$FLAG" ;;
    off)    rm -f "$FLAG" ;;
    toggle) [ -f "$FLAG" ] && rm -f "$FLAG" || touch "$FLAG" ;;
    status) [ -f "$FLAG" ] && echo on || echo off ;;
    *)      echo "usage: $0 {on|off|toggle|status}"; exit 1 ;;
esac
