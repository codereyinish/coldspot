#!/bin/bash
# coldspot-watch.sh — auto start/stop ColdSpot based on whether we're on the
# iPhone hotspot. Triggered by launchd (WatchPaths on SystemConfiguration) and
# at boot (RunAtLoad). Idempotent, modeled on the WireGuard hotspot script:
#   • lock file   → no overlapping runs (WatchPaths can fire many times)
#   • state check → only start/stop if not already in the right state
#   • sleep       → let the network settle before reading state

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
sleep 3

LOCKFILE="/tmp/coldspot.lock"
[ -f "$LOCKFILE" ] && exit 0
touch "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY="$DIR/../server/proxy.py"
TUNCTL="$DIR/coldspot-tun-ctl.sh"
LOG="/tmp/coldspot-proxy.log"
IPHONE_GATEWAY="172.20.10.1"
WIFI="Wi-Fi"

# MASTER SWITCH (the menu-bar toggle). The flag file is the user's saved intent:
#   present = ColdSpot ON,  absent = OFF.  It lives in the logged-in user's home
# (this script runs as root under launchd, so resolve the console user's home).
# The menu-bar app only ever creates/deletes this file — the daemon does the work.
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null)"
USER_HOME="$(eval echo "~${CONSOLE_USER}" 2>/dev/null)"
FLAG="$USER_HOME/.coldspot/enabled"

# is the SOCKS5 system proxy currently ON?  (used to avoid needless networksetup
# calls — networksetup writes SystemConfiguration, which would re-trigger us)
socks_is_on() {
    networksetup -getsocksfirewallproxy "$WIFI" 2>/dev/null | grep -q "Enabled: Yes"
}

# bring EVERYTHING down — utun first (restores other networks instantly), then
# proxy + leak monitor, then SOCKS5. Reused by the toggle-OFF and off-hotspot paths.
tear_down() {
    bash "$TUNCTL" down
    if pgrep -f "proxy.py" >/dev/null; then
        echo "  stopping proxy.py + leak monitor"
        pkill -f "proxy.py"
        pkill -f "tcpdump -i en0"
    fi
    if socks_is_on; then
        echo "  disabling SOCKS5"
        networksetup -setsocksfirewallproxystate "$WIFI" off 2>/dev/null
    fi
}

# toggle OFF? then nothing else matters — ensure all is down and stop here.
# (on reboot RunAtLoad fires this too, so a Mac that booted with the toggle OFF
#  simply does nothing; with it ON it proceeds to the hotspot check below.)
if [ ! -f "$FLAG" ]; then
    echo "$(date '+%F %T') → toggle OFF (no $FLAG) — ensuring everything down"
    tear_down
    exit 0
fi

current_gateway=$(netstat -rn | awk '/default/{print $2}' | head -1)
echo "$(date '+%F %T') gateway=$current_gateway"

if [ "$current_gateway" = "$IPHONE_GATEWAY" ]; then
    echo "→ on iPhone hotspot"
    if ! pgrep -f "proxy.py" >/dev/null; then
        echo "  starting proxy.py"
        # NO nohup (fails under launchd: no console). AbandonProcessGroup=true in
        # the plist keeps this alive after the watcher exits.
        python3 "$PROXY" >"$LOG" 2>&1 &
    else
        echo "  proxy.py already running — skip"
    fi
    # enable SOCKS5 ONLY if not already on (avoids re-triggering WatchPaths)
    if ! socks_is_on; then
        echo "  enabling SOCKS5"
        networksetup -setsocksfirewallproxy "$WIFI" 127.0.0.1 1080 2>/dev/null
        networksetup -setsocksfirewallproxystate "$WIFI" on 2>/dev/null
    fi
    # SAFETY NET: bring up the utun for anything that ignores SOCKS5. This is
    # idempotent and self-gating — it only acts once proxy is up AND the iPhone
    # has >=1 slot, otherwise it skips and the next reconcile (StartInterval)
    # retries. So it can never blackout the Mac while slots aren't ready.
    echo "  reconciling utun safety-net"
    bash "$TUNCTL" up
else
    # toggle is ON but we're not on the hotspot — stay down and wait for it.
    echo "→ toggle ON but off hotspot — ensuring everything down"
    tear_down
fi
