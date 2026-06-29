#!/bin/bash
# =============================================================================
# install.sh — ColdSpot installer (Mac)
# =============================================================================
# Wires up THIS Mac to use a ColdSpot exit server. It SSHes into the server,
# installs the exit (server/setup.sh + server/exit.py) if it isn't running yet,
# fetches the server's TLS cert + credentials back over that same SSH, and saves
# them locally — then installs the menu-bar toggle + auto-start daemon.
#
# The data path it sets up:
#   Mac apps → utun123/tun2socks → proxy.py → iPhone (relay) → exit server → internet
#
# You provide:  the server's IP (and SSH access). `provision.sh` runs this for you
# on a freshly-built server, passing SERVER_IP/SSH_USER so it skips the prompts.
#
# SECURITY: SSH host-key checking stays ON (we never pass StrictHostKeyChecking=no).
# A first-ever connect prompts you once; provision.sh pre-seeds the freshly-built
# server's key. Same authority as you SSHing in by hand.
#
# Usage:  bash mac/install.sh        (or: SERVER_IP=1.2.3.4 bash mac/install.sh)
#
# Author: github.com/codereyinish
# =============================================================================
set -e

RED=$'\033[91m'; GRN=$'\033[92m'; YLW=$'\033[93m'; BLU=$'\033[96m'; BLD=$'\033[1m'; DIM=$'\033[90m'; RST=$'\033[0m'
header() { echo ""; echo "${BLD}${BLU}── $1 ${RST}"; }
ok()     { echo "  ${GRN}✓${RST} $1"; }
info()   { echo "  ${YLW}→${RST} $1"; }
die()    { echo ""; echo "  ${RED}✗ Error: $1${RST}"; echo ""; exit 1; }
narrate(){ echo "  ${BLU}→${RST} $1"; sleep 0.3; }

# Run as YOU, not root — we sudo only the daemon step (Step 8). Running the whole
# thing under sudo would write the exit config into root's home, not yours.
if [ "$(id -u)" = 0 ]; then
    die "Run me WITHOUT sudo (I'll ask for your password only where needed): bash mac/install.sh"
fi

DIR="$(cd "$(dirname "$0")" && pwd)"           # .../coldspot/mac
REPO="$(cd "$DIR/.." && pwd)"
source "$DIR/lib/prompt.sh"

# Where the Mac keeps its copy of the exit config (same folder as the menu-bar
# on/off flag). proxy.py reads exit.conf from here.
CONF_DIR="$HOME/.coldspot"
CONF="$CONF_DIR/exit.conf"
CERT="$CONF_DIR/exit.crt"

EXIT_PORT="${EXIT_PORT:-443}"                   # must match server/setup.sh
SERVER_IP="${SERVER_IP:-}"
SSH_USER="${SSH_USER:-}"

# =============================================================================
# STEP 0 — Welcome
# =============================================================================
clear
echo ""
echo "${BLD}  ColdSpot — Installer${RST}"
echo "  ────────────────────────────────────────"
echo "  Routes this Mac's traffic out through your own exit server"
echo "  (reached via the iPhone relay). Toggle it from the menu bar;"
echo "  after a reboot it's off until you turn it on."
echo ""
echo "  You'll need your exit server's IP (and SSH access)."
echo ""
read -rp "  Press Enter to start..."

# =============================================================================
# STEP 1 — System
# =============================================================================
header "Step 1/8 — Checking system"
[ "$(uname)" = "Darwin" ] || die "This installer only supports macOS."
ok "macOS detected"
if [ "$(uname -m)" = "arm64" ]; then BREW_PREFIX="/opt/homebrew"; ok "Apple Silicon"; else BREW_PREFIX="/usr/local"; ok "Intel Mac"; fi

# =============================================================================
# STEP 2 — Homebrew
# =============================================================================
header "Step 2/8 — Homebrew"
if command -v brew &>/dev/null; then ok "Homebrew already installed"; else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$("$BREW_PREFIX/bin/brew" shellenv)" 2>/dev/null || true
    ok "Homebrew installed"
fi

# =============================================================================
# STEP 3 — python3
# =============================================================================
header "Step 3/8 — python3"
if command -v python3 &>/dev/null; then ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"; else
    info "Installing python..."; brew install python; ok "python installed"
fi

# =============================================================================
# STEP 4 — SwiftBar (menu-bar app)
# =============================================================================
header "Step 4/8 — SwiftBar"
if [ -d "/Applications/SwiftBar.app" ]; then ok "SwiftBar already installed"; else
    info "Installing SwiftBar..."; brew install --cask swiftbar
    ok "SwiftBar installed"
    info "Open SwiftBar once and choose a plugins folder before continuing"
    read -rp "  Press Enter once you've opened SwiftBar and set a plugins folder..."
fi

# =============================================================================
# STEP 5 — Server details
# =============================================================================
header "Step 5/8 — Your exit server"
echo "  The installer SSHes into the server to finish setup automatically —"
echo "  it installs the exit (if needed) and reads its cert + credentials back."
echo ""
echo "  ${DIM}Server IP → Oracle console → Compute → Instances → 'Public IP address'${RST}"
echo "  ${DIM}            (or the line provision.sh printed at the end)${RST}"
echo "  ${DIM}SSH user  → 'ubuntu' on Oracle's Ubuntu image — just press Enter${RST}"
echo ""
if valid_ipv4 "$SERVER_IP"; then ok "Server IP provided: ${BLU}${SERVER_IP}${RST}"; else
    while :; do
        ask SERVER_IP "Server IP address (e.g. 203.0.113.10)" ""
        [ -z "$SERVER_IP" ] && { info "Server IP can't be empty — try again."; continue; }
        valid_ipv4 "$SERVER_IP" && break
        info "'$SERVER_IP' isn't a valid IPv4 address — try again."
    done
fi
if [ -n "$SSH_USER" ]; then ok "SSH username: ${BLU}${SSH_USER}${RST}"; else ask SSH_USER "SSH username on the server" "ubuntu"; fi

# =============================================================================
# STEP 6 — Install the exit + fetch its cert/credentials (over SSH)
# =============================================================================
# host-key checking stays ON — no StrictHostKeyChecking=no anywhere.
header "Step 6/8 — Configuring the exit server (over SSH)"
SSH_DEST="${SSH_USER}@${SERVER_IP}"
SSH_OPTS="-o ConnectTimeout=15"

echo "  ${BLD}┌─ over SSH ─────────────────────────────────────────${RST}"
narrate "ssh ${SSH_DEST} — connecting..."
ssh $SSH_OPTS "$SSH_DEST" 'true' || die "couldn't SSH to ${SSH_DEST} — check the IP / your SSH key / the security list."
ok "you're on the server"

if ssh $SSH_OPTS "$SSH_DEST" 'systemctl is-active --quiet coldspot-exit'; then
    ok "exit already running — keeping its cert + credentials (skipping setup.sh)"
else
    narrate "fresh server — installing the exit (pushing exit.py + setup.sh over SSH)..."
    [ -f "$REPO/server/exit.py" ]  || die "can't find server/exit.py in the repo."
    [ -f "$REPO/server/setup.sh" ] || die "can't find server/setup.sh in the repo."
    ssh $SSH_OPTS "$SSH_DEST" 'cat > /tmp/coldspot-exit.py' < "$REPO/server/exit.py"
    ssh $SSH_OPTS "$SSH_DEST" "sudo EXIT_PORT=${EXIT_PORT} bash -s" < "$REPO/server/setup.sh"
    ok "exit installed (from your local files — nothing downloaded)"
fi

narrate "reading the server's TLS cert + credentials back..."
SERVER_CERT=$(ssh $SSH_OPTS "$SSH_DEST" 'sudo cat /etc/coldspot/exit.crt')
EXIT_USER=$(ssh $SSH_OPTS "$SSH_DEST" 'sudo sed -n "s/^COLDSPOT_USER=//p" /etc/coldspot/creds.env' | tr -d '[:space:]')
EXIT_PASS=$(ssh $SSH_OPTS "$SSH_DEST" 'sudo sed -n "s/^COLDSPOT_PASS=//p" /etc/coldspot/creds.env' | tr -d '[:space:]')
[ -n "$SERVER_CERT" ] || die "couldn't read the server's TLS cert."
[ -n "$EXIT_USER" ] && [ -n "$EXIT_PASS" ] || die "couldn't read the server's credentials."
echo "       cert + creds ${GRN}<--${RST} fetched"
echo "  ${BLD}└────────────────────────────────────────────────────${RST}"

# =============================================================================
# STEP 7 — Save the exit config on this Mac
# =============================================================================
header "Step 7/8 — Saving the exit config"
mkdir -p "$CONF_DIR"
printf '%s\n' "$SERVER_CERT" > "$CERT"
chmod 600 "$CERT"
cat > "$CONF" << EOF
# ColdSpot exit config — written by install.sh. proxy.py reads this.
EXIT_IP=${SERVER_IP}
EXIT_PORT=${EXIT_PORT}
EXIT_USER=${EXIT_USER}
EXIT_PASS=${EXIT_PASS}
EXIT_CERT=${CERT}
EOF
chmod 600 "$CONF"
ok "exit config → $CONF"
ok "pinned cert → $CERT"

# =============================================================================
# STEP 8 — Menu-bar toggle + auto-start daemon
# =============================================================================
header "Step 8/8 — Menu-bar toggle + auto-start"
info "Installing the auto-start daemon (needs your password)..."
sudo bash "$DIR/install-autostart.sh"
info "Linking the SwiftBar menu-bar plugin..."
bash "$DIR/install-swiftbar.sh" || info "SwiftBar plugin not linked yet — open SwiftBar, set a plugin folder, then re-run: bash mac/install-swiftbar.sh"

echo ""
echo "${GRN}${BLD}  ✓ Server + Mac are set up${RST}"
echo "    • Exit server  → ${SERVER_IP}:${EXIT_PORT}"
echo "    • Exit config  → $CONF"
echo "    • Menu-bar ❄️ toggle installed"
echo ""
echo "${BLD}${BLU}── Last checkpoint — your iPhone ${RST}"
echo "  ColdSpot's relay runs as a small app on your phone:"
echo ""
echo "  ${BLD}1.${RST} Plug in the iPhone; enable ${BLD}Developer Mode${RST}"
echo "     ${DIM}(Settings → Privacy & Security → Developer Mode) and trust the Mac.${RST}"
echo "  ${BLD}2.${RST} Open ${YLW}ios/ProxyTest.xcodeproj${RST} in Xcode → target ${BLD}ProxyTest${RST}"
echo "     → ${BLD}Signing & Capabilities${RST} → set ${BLD}Team${RST} to your Apple ID."
echo "  ${BLD}3.${RST} Pick your iPhone and click ${GRN}Run ▶${RST}, then ${BLD}Trust${RST} the app on the phone"
echo "     ${DIM}(Settings → General → VPN & Device Management).${RST}"
echo "  ${BLD}4.${RST} Open the app and tap ${GRN}Start${RST}."
echo ""
echo "${BLD}${BLU}── Then turn it on ${RST}"
echo "  Connect this Mac to the iPhone's Personal Hotspot, then flip ❄️ ${GRN}ON${RST}."
echo "  Verify with:  ${YLW}curl https://ifconfig.me${RST}  → should print ${SERVER_IP}."
echo "  ${DIM}After a reboot ColdSpot stays off until you flip ❄️ ON again.${RST}"
echo ""
