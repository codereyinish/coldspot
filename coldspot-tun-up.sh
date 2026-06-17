#!/bin/bash
# coldspot-tun-up.sh — manual "bring the utun up now" (thin wrapper).
# All logic lives in coldspot-tun-ctl.sh so manual + automated paths match.
#   sudo bash coldspot-tun-up.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/coldspot-tun-ctl.sh" up
