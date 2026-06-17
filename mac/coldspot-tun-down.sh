#!/bin/bash
# coldspot-tun-down.sh — manual "tear the utun down now" (thin wrapper).
# All logic lives in coldspot-tun-ctl.sh.
#   sudo bash coldspot-tun-down.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/coldspot-tun-ctl.sh" down
