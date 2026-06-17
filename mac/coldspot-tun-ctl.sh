#!/bin/bash
# coldspot-tun-ctl.sh — non-blocking, idempotent control of the utun "safety net".
#
# The utun catches traffic that ignores the SOCKS5 system setting (CLI tools,
# Apple/iCloud daemons) and routes it: utun123 -> tun2socks -> proxy.py(:1080)
# -> iPhone slot -> phone APN. DNS (UDP) is pinned to the hotspot so it survives.
#
# Used by coldspot-watch.sh (auto up/down on hotspot) AND by hand:
#   sudo bash coldspot-tun-ctl.sh up       # safe: only acts if proxy up + slots>=1
#   sudo bash coldspot-tun-ctl.sh down     # tear down, restore networking
#        bash coldspot-tun-ctl.sh status   # show state (no root needed)
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
TUN2SOCKS="$DIR/tun2socks"
TUN=utun123
TUN_LOCAL=198.18.0.1            # RFC2544 benchmark range — never a real dest
TUN_PEER=198.18.0.2
SOCKS=127.0.0.1:1080
IPHONE_GATEWAY=172.20.10.1
LOG=/tmp/coldspot-tun.log

tun_up()     { ifconfig "$TUN" >/dev/null 2>&1; }
route_live() { netstat -rn 2>/dev/null | grep -qE "^0/1"; }
on_hotspot() { [ "$(netstat -rn 2>/dev/null | awk '/default/{print $2}' | head -1)" = "$IPHONE_GATEWAY" ]; }
slot_count() { netstat -an 2>/dev/null | grep '\.9999 ' | grep -c ESTABLISHED; }
proxy_up()   { nc -z -w1 127.0.0.1 1080 >/dev/null 2>&1; }
dns_ips()    { scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | grep -vE '^(127\.|::1)'; }
log()        { echo "$(date '+%F %T') [tun] $*"; }

cmd_down() {
    local acted=0
    if route_live; then
        route -n delete -net 0.0.0.0/1   >/dev/null 2>&1
        route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
        acted=1
    fi
    for d in $(dns_ips); do route -n delete -host "$d" >/dev/null 2>&1; done
    if pgrep -f "tun2socks .*$TUN" >/dev/null; then pkill -f "tun2socks .*$TUN"; acted=1; fi
    [ "$acted" = 1 ] && log "DOWN — routes removed, tun2socks stopped, networking restored"
    return 0
}

cmd_up() {
    # already fully up? nothing to do.
    if tun_up && route_live; then return 0; fi
    # SAFETY GATES — any failure = skip (the 30s reconcile retries later)
    on_hotspot || { log "skip up: not on hotspot";                 return 1; }
    proxy_up   || { log "skip up: proxy :1080 down";               return 1; }
    local s; s=$(slot_count)
    [ "${s:-0}" -ge 1 ] || { log "skip up: 0 iPhone slots (open app + Start)"; return 1; }

    # start tun2socks if not running (detached; survives caller exit)
    if ! pgrep -f "tun2socks .*$TUN" >/dev/null; then
        "$TUN2SOCKS" -device "$TUN" -proxy "socks5://$SOCKS" -loglevel warn >>"$LOG" 2>&1 &
        disown 2>/dev/null || true
        for i in $(seq 1 50); do tun_up && break; sleep 0.1; done
    fi
    tun_up || { log "FAIL: $TUN never came up (see $LOG)"; return 1; }
    ifconfig "$TUN" "$TUN_LOCAL" "$TUN_PEER" up

    # pin DNS resolvers to the hotspot (UDP can't cross the TCP-only proxy).
    # the iPhone endpoint is a connected /32 on the hotspot — no pin needed.
    local gw; gw=$(netstat -rn | awk '/default/{print $2}' | head -1)
    for d in $(dns_ips); do route -n add -host "$d" "$gw" >/dev/null 2>&1; done
    # capture everything else: 0/1 + 128/1 overrides default without deleting it
    route -n add -net 0.0.0.0/1   -interface "$TUN" >/dev/null 2>&1
    route -n add -net 128.0.0.0/1 -interface "$TUN" >/dev/null 2>&1
    log "UP — slots=$s, all non-DNS traffic now -> phone APN"
}

case "${1:-}" in
    up)     [ "$(id -u)" = 0 ] || { echo "need root: sudo bash $0 up";   exit 1; }; cmd_up ;;
    down)   [ "$(id -u)" = 0 ] || { echo "need root: sudo bash $0 down"; exit 1; }; cmd_down ;;
    status)
        echo "on hotspot : $(on_hotspot && echo yes || echo no)"
        echo "proxy :1080: $(proxy_up && echo up || echo DOWN)"
        echo "iPhone slots: $(slot_count)"
        echo "tun2socks  : $(pgrep -f "tun2socks .*$TUN" >/dev/null && echo running || echo stopped)"
        echo "$TUN     : $(tun_up && echo up || echo absent)"
        echo "0/1 route  : $(route_live && echo present\ \(capturing\) || echo absent)"
        ;;
    *) echo "usage: $0 {up|down|status}"; exit 1 ;;
esac
