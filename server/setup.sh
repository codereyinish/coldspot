#!/bin/bash
# =============================================================================
# server/setup.sh — ColdSpot exit server setup (runs on the Oracle VM)
# =============================================================================
# Installs the ColdSpot exit (server/exit.py) on a fresh Ubuntu VPS and brings
# it up as a systemd service. Designed for Oracle Cloud Always-Free, works on
# any Ubuntu box.
#
# What it does:
#   - waits for network/DNS (fresh cloud VMs boot sshd before DNS is ready)
#   - generates a self-signed TLS cert + a random SOCKS username/password ONCE,
#     persisting them under /etc/coldspot and REUSING them on re-runs (so an
#     already-configured Mac never goes stale)
#   - installs exit.py to /opt/coldspot
#   - writes + starts the coldspot-exit systemd service
#   - opens the OS firewall for the exit port (Oracle's stock image REJECTs by
#     default, so the cloud Security List alone isn't enough)
#
# Runs UNATTENDED — no prompts. The Mac's install.sh pushes this over SSH on a
# fresh server, then reads the cert + credentials back. You can also run it by
# hand:  sudo bash setup.sh
#
# Requirements: Ubuntu, root, python3 (preinstalled), TCP <port> open in the
# cloud Security List (Terraform opens 443 for you).
#
# Author: github.com/codereyinish
# =============================================================================

set -e

RED=$'\033[91m'; GRN=$'\033[92m'; YLW=$'\033[93m'; BLU=$'\033[96m'; BLD=$'\033[1m'; RST=$'\033[0m'

EXIT_PORT="${EXIT_PORT:-443}"          # TCP port the exit listens on (TLS)
CONF_DIR=/etc/coldspot                 # cert, key, credentials live here (root-only)
APP_DIR=/opt/coldspot                  # exit.py lives here
SERVICE=coldspot-exit

LOG=/var/log/coldspot-setup.log
: > "$LOG" 2>/dev/null || { LOG=/tmp/coldspot-setup.log; : > "$LOG"; }

ok()   { echo "  ${GRN}✓${RST} $1"; }
info() { echo "  ${YLW}→${RST} $1"; }
die()  { echo ""; echo "  ${RED}✗ $1${RST}"; [ -s "$LOG" ] && tail -n 15 "$LOG" | sed 's/^/    /'; echo ""; exit 1; }
run()  { local l=$1; shift; info "$l"; "$@" >> "$LOG" 2>&1 || die "$l — failed (see $LOG)"; }
step() {
    local n=$1 msg=$2 total=8 width=22 pct filled i bar=""
    pct=$(( n * 100 / total )); filled=$(( pct * width / 100 ))
    for ((i=0;i<width;i++)); do (( i<filled )) && bar+="#" || bar+="·"; done
    echo ""; echo "  ${BLD}[${bar}] ${pct}%${RST}  ${BLU}${msg}${RST}"
}

echo ""
echo "${BLD}  ColdSpot — Exit Server Setup${RST}"
echo "  ────────────────────────────────────────"
echo "  Installs the ColdSpot exit on this Ubuntu server. Runs unattended."

# --- 1. system checks --------------------------------------------------------
step 1 "Checking system"
[ "$(uname)" = "Linux" ] || die "Run this on your Linux server, not your Mac."
[ "$EUID" -eq 0 ] || die "Run as root: sudo bash setup.sh"
command -v python3 >/dev/null 2>&1 || die "python3 not found (expected on Ubuntu)."
ok "Ubuntu $(lsb_release -rs 2>/dev/null || echo '?'), python3 $(python3 -V 2>&1 | awk '{print $2}')"

# --- 2. wait for network/DNS -------------------------------------------------
# A freshly-booted cloud VM brings up sshd BEFORE its resolver is ready.
step 2 "Waiting for network"
n=0
until getent hosts oracle.com >/dev/null 2>&1 || getent hosts cloudflare.com >/dev/null 2>&1; do
    n=$((n+1)); [ "$n" -ge 36 ] && die "network/DNS never came up after ~3 min."
    sleep 5
done
ok "network is up"

# --- 3. install exit.py ------------------------------------------------------
step 3 "Installing exit program"
mkdir -p "$APP_DIR" "$CONF_DIR"
chmod 700 "$CONF_DIR"
# This script is PUSHED over SSH together with exit.py by install.sh, which
# copies exit.py next to it first. Support both that layout and a manual clone.
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SRC_DIR/exit.py" ]; then
    cp "$SRC_DIR/exit.py" "$APP_DIR/exit.py"
elif [ -f /tmp/coldspot-exit.py ]; then
    cp /tmp/coldspot-exit.py "$APP_DIR/exit.py"
else
    die "exit.py not found next to setup.sh — push it alongside this script."
fi
chmod 755 "$APP_DIR/exit.py"
ok "exit.py → $APP_DIR/exit.py"

# --- 4. TLS cert (generate once, reuse forever) ------------------------------
# The cert is the ANCHOR: the Mac pins it, so regenerating it would break an
# already-installed Mac. Only create it when truly absent.
step 4 "TLS certificate"
if [ -f "$CONF_DIR/exit.crt" ] && [ -f "$CONF_DIR/exit.key" ]; then
    ok "reusing existing TLS cert (kept intact)"
else
    PUBIP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "")
    run "generating self-signed TLS cert..." \
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$CONF_DIR/exit.key" -out "$CONF_DIR/exit.crt" \
            -days 3650 -subj "/CN=coldspot-exit${PUBIP:+/O=$PUBIP}"
    chmod 600 "$CONF_DIR/exit.key"; chmod 644 "$CONF_DIR/exit.crt"
    ok "TLS cert generated (valid 10 years)"
fi

# --- 5. credentials (generate once, reuse forever) ---------------------------
step 5 "Exit credentials"
if [ -f "$CONF_DIR/creds.env" ]; then
    ok "reusing existing credentials (kept intact)"
else
    EXIT_USER="coldspot"
    EXIT_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    {
        echo "COLDSPOT_USER=$EXIT_USER"
        echo "COLDSPOT_PASS=$EXIT_PASS"
    } > "$CONF_DIR/creds.env"
    chmod 600 "$CONF_DIR/creds.env"
    ok "random credentials generated"
fi

# --- 6. systemd service ------------------------------------------------------
step 6 "Service"
cat > /etc/systemd/system/${SERVICE}.service << EOF
[Unit]
Description=ColdSpot exit (SOCKS5 over TLS)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${CONF_DIR}/creds.env
Environment=COLDSPOT_PORT=${EXIT_PORT}
Environment=COLDSPOT_CERT=${CONF_DIR}/exit.crt
Environment=COLDSPOT_KEY=${CONF_DIR}/exit.key
ExecStart=/usr/bin/python3 ${APP_DIR}/exit.py
Restart=always
RestartSec=2
# Let a non-root service bind the privileged port 443.
AmbientCapabilities=CAP_NET_BIND_SERVICE
DynamicUser=yes
# DynamicUser can't read root-only files — grant just this service access.
SupplementaryGroups=coldspot

[Install]
WantedBy=multi-user.target
EOF

# A dedicated group so the sandboxed DynamicUser can read the cert/key/creds
# without making them world-readable.
getent group coldspot >/dev/null 2>&1 || groupadd --system coldspot
chgrp coldspot "$CONF_DIR"/exit.key "$CONF_DIR"/exit.crt "$CONF_DIR"/creds.env
chmod 640 "$CONF_DIR"/exit.key "$CONF_DIR"/creds.env
chmod 644 "$CONF_DIR"/exit.crt
chmod 750 "$CONF_DIR"

run "reloading systemd..." systemctl daemon-reload
run "enabling service (auto-start on reboot)..." systemctl enable ${SERVICE}
run "starting service..." systemctl restart ${SERVICE}
sleep 1
systemctl is-active --quiet ${SERVICE} || die "service failed to start — check: journalctl -u ${SERVICE}"
ok "${SERVICE} running + enabled"

# --- 7. OS firewall ----------------------------------------------------------
# Oracle's stock Ubuntu image ships a restrictive iptables INPUT chain ending in
# REJECT. Insert an ACCEPT at the TOP so the exit port is reachable. (The cloud
# Security List opening 443 is necessary but NOT sufficient — the OS firewall
# blocks it too.) Persist it if iptables-persistent is available.
step 7 "Firewall"
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$EXIT_PORT" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$EXIT_PORT" -j ACCEPT
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    ok "iptables: TCP $EXIT_PORT accepted on INPUT"
else
    info "iptables not present — skipping (ensure the cloud Security List allows TCP $EXIT_PORT)"
fi
echo ""
echo "  ${YLW}⚠ Cloud firewall reminder:${RST} the Oracle Security List must allow"
echo "    TCP ${EXIT_PORT} (Terraform does this for you)."

# --- 8. done -----------------------------------------------------------------
step 8 "Done"
echo ""
echo "${GRN}${BLD}  ✓ ColdSpot exit ready${RST}"
echo ""
echo "  Listening on TCP ${EXIT_PORT} (SOCKS5 over TLS)."
echo "  Your Mac's install.sh reads the cert + credentials from ${CONF_DIR} over SSH."
echo ""
