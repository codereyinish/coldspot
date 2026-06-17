#!/bin/bash
# coldspot.sh — ONE command. Runs proxy.py, which now does it ALL in one process:
#   • SOCKS5 proxy (apps → phone APN via the iPhone tunnel)
#   • 📊 phone-APN byte counter
#   • 🚨 live leak finder — en0 split (PHONE APN vs HOTSPOT + leak %)
#        AND the top leaking RESOURCES by name (reverse-DNS), every 10s
#
# Needs root (tcpdump for the leak finder lives inside proxy.py now).
#
# Usage:  sudo bash mac/coldspot.sh

DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/../server/proxy.py"
