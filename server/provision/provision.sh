#!/bin/bash
# =============================================================================
# provision.sh — stand up the ColdSpot exit server on Oracle Cloud (no copy-paste)
# =============================================================================
# The ONE thing you do by hand: create a free Oracle Cloud account at
# https://signup.cloud.oracle.com — Oracle requires a human for signup
# (credit-card + SMS verification, by design). Everything after is automated:
#
#   1. installs the OCI CLI and Terraform if they're missing
#   2. logs you into Oracle in the browser ONCE (`oci setup bootstrap`): this
#      generates an API signing key, uploads it to your user, and writes
#      ~/.oci/config for you — so there are NO OCIDs or keys to paste
#   3. reads your tenancy OCID + region back out of that config
#   4. generates an SSH key if you don't have one
#   5. runs Terraform to build the VM, network, and firewall
#   6. waits for SSH, then hands off to ../../mac/install.sh
#
# Usage:  cd server/provision && ./provision.sh
# =============================================================================
set -e

RED=$'\033[91m'; GRN=$'\033[92m'; YLW=$'\033[93m'; BLU=$'\033[96m'; BLD=$'\033[1m'; DIM=$'\033[90m'; RST=$'\033[0m'
header() { echo ""; echo "${BLD}${BLU}── $1 ${RST}"; }
ok()   { echo "  ${GRN}✓${RST} $1"; }
info() { echo "  ${YLW}→${RST} $1"; }
die()  { echo ""; echo "  ${RED}✗ $1${RST}"; echo ""; exit 1; }

# progress BAR — redraws ONE line in place: [####······]  42%  message
progress() {
    local pct=$1 msg=$2 cols filled i bar="" barw reserved=8 pad
    [ "$pct" -gt 100 ] && pct=100
    cols=${COLUMNS:-80}
    barw=$(( cols - reserved )); (( barw < 10 )) && barw=10
    filled=$(( pct * barw / 100 ))
    for ((i = 0; i < barw; i++)); do (( i < filled )) && bar+="#" || bar+="·"; done
    pad=$(( cols - ${#msg} - 1 )); (( pad < 0 )) && pad=0
    printf "\r${BLD}[%s]${RST} %3d%%\033[K\n%*s${GRN}%s${RST}\033[K\033[1A\r" \
        "$bar" "$pct" "$pad" "" "$msg"
}
progress_end() { printf '\n\n'; }

# Turn a Terraform resource address into a human label for the progress line.
friendly() {
    case "$1" in
        *vcn*)              echo "the network (VCN)" ;;
        *subnet*)           echo "the subnet" ;;
        *internet_gateway*) echo "the internet gateway" ;;
        *route_table*)      echo "the routing table" ;;
        *security_list*)    echo "the firewall" ;;
        *instance*)         echo "the VM" ;;
        *)                  echo "$1" ;;
    esac
}

cd "$(dirname "$0")"
LOG="$PWD/provision.log"
: > "$LOG"
PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_CONFIG="$HOME/.oci/config"

export COLUMNS="$(tput cols 2>/dev/null || echo 80)"

# --- Checkpoint 1: Oracle account --------------------------------------------
# The one thing we can't automate: you need a free Oracle Cloud account. If
# ~/.oci/config already has this profile, you've logged in before, so you
# obviously have an account — skip the question and go straight to login.
if [ -f "$OCI_CONFIG" ] && grep -q "^\[$PROFILE\]" "$OCI_CONFIG"; then
    :   # already configured — handled in step 3
else
    header "Checkpoint 1 — Oracle Cloud account"
    echo "  ColdSpot's exit server runs on Oracle's free 'Always-Free' tier, so the"
    echo "  one manual step is a (free) Oracle Cloud account."
    echo ""
    printf "  ${BLD}Do you already have an Oracle Cloud account? [y/N]${RST} "
    read -r HAVE_ACCT
    case "$HAVE_ACCT" in
        [yY]*) ok "great — we'll log you in during step 3" ;;
        *)
            echo ""
            echo "  Create one here (needs a card for ID + an SMS code — Always-Free"
            echo "  doesn't charge you), and pick a ${BLD}Home Region${RST} near you:"
            echo ""
            echo "    ${BLU}https://signup.cloud.oracle.com${RST}"
            echo ""
            echo "  ${DIM}Remember the Home Region — you'll re-pick it during login.${RST}"
            echo ""
            read -rp "  Press Enter once your account is created and the console has loaded... "
            ;;
    esac
fi

# --- 1. OCI CLI ---------------------------------------------------------------
header "OCI CLI"
if command -v oci >/dev/null 2>&1; then
    ok "oci already installed"
else
    command -v brew >/dev/null 2>&1 || die "Homebrew not found — install it from https://brew.sh then re-run."
    info "installing oci-cli via Homebrew..."
    brew install oci-cli
    ok "oci-cli installed"
fi

# --- 2. Terraform -------------------------------------------------------------
header "Terraform"
if command -v terraform >/dev/null 2>&1; then
    ok "terraform already installed"
else
    # brew core dropped terraform and the tap needs Xcode CLT to compile, so we
    # drop the official prebuilt binary into ~/.local/bin (no sudo, no compiler).
    TF_VER="1.9.8"
    case "$(uname -m)" in arm64) TF_ARCH=arm64;; *) TF_ARCH=amd64;; esac
    info "installing Terraform ${TF_VER} (prebuilt binary → ~/.local/bin)..."
    mkdir -p "$HOME/.local/bin"
    TMP=$(mktemp -d)
    curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_darwin_${TF_ARCH}.zip" -o "$TMP/tf.zip"
    unzip -o -q "$TMP/tf.zip" -d "$TMP"
    mv "$TMP/terraform" "$HOME/.local/bin/terraform"
    chmod +x "$HOME/.local/bin/terraform"
    rm -rf "$TMP"
    export PATH="$HOME/.local/bin:$PATH"
    command -v terraform >/dev/null 2>&1 || die "terraform installed to ~/.local/bin but it's not on PATH — add it and re-run."
    ok "terraform ${TF_VER} installed (add ~/.local/bin to your PATH to keep it)"
fi

# --- 3. Oracle credentials (browser login, once) ------------------------------
# This is where the browser session is traded for a PERMANENT API key: oci setup
# bootstrap logs you in once, then generates + uploads an API signing key and
# writes ~/.oci/config. Terraform then authenticates with that key (no pasting).
header "Checkpoint 2 — Oracle login (creates your permanent API key)"
read_fingerprint() {
    awk -F= -v p="[$PROFILE]" '/^\[/{s=$0} s==p && $1=="fingerprint"{gsub(/[ \t\r]/,"",$2);print $2;exit}' "$OCI_CONFIG" 2>/dev/null
}

if [ -f "$OCI_CONFIG" ] && grep -q "^\[$PROFILE\]" "$OCI_CONFIG"; then
    # Reuse the key already in ~/.oci/config — Oracle caps you at 3 API keys per
    # user, so re-bootstrapping every run would fill that quota.
    FP=$(read_fingerprint)
    ok "reusing the API key already in ~/.oci/config${FP:+ (fingerprint $FP)} — no new key created"
else
    echo ""
    echo "  ${BLD}You'll be asked 4 quick things — here's what to do:${RST}"
    echo ""
    echo "  ${BLU}1.${RST} ${BLD}Region${RST}  — type the number of your ${BLD}Home Region${RST} (the one you"
    echo "         picked at signup).  ${DIM}e.g.  72  for us-ashburn-1${RST}"
    echo ""
    echo "  ${BLU}2.${RST} ${BLD}macOS popup${RST}  \"Allow 'Python' to find devices on local networks?\""
    echo "         → click ${GRN}Allow${RST}.  ${YLW}⚠ Don't click \"Don't Allow\" — the browser login${RST}"
    echo "         ${YLW}can't get back to the tool and the whole thing hangs / aborts.${RST}"
    echo ""
    echo "  ${BLU}3.${RST} ${BLD}Browser opens${RST}  → log into Oracle → click ${GRN}Authorize${RST}."
    echo ""
    echo "  ${BLU}4.${RST} ${BLD}Passphrase${RST} prompt  → type ${GRN}N/A${RST}  (no passphrase, so this can run"
    echo "         later without asking you to unlock the key)."
    echo ""
    read -rp "  Press Enter to start the login... "
    echo ""
    set +e
    oci setup bootstrap --profile-name "$PROFILE"
    set -e
    if [ ! -f "$OCI_CONFIG" ]; then
        echo ""
        echo "  ${RED}✗ Login didn't complete — no ~/.oci/config was written.${RST}"
        echo ""
        echo "  ${BLD}Most likely:${RST} your Oracle user already has the max ${BLD}3 API keys${RST}"
        echo "  (repeated runs / Ctrl-C each upload one). Delete the unused ones, then re-run:"
        echo ""
        echo "    ${YLW}Console → Identity → Domains → (your domain) → Users → (you) → API Keys → Delete${RST}"
        die "clear a key slot, then run ./provision.sh again."
    fi
    FP=$(read_fingerprint)
    ok "credentials configured — API key${FP:+ $FP} saved to ~/.oci/config (reused on future runs)"
fi

# --- 4. read tenancy OCID + region from the config ----------------------------
read_cfg() {
    awk -v p="[$PROFILE]" -v k="$1" '
        /^\[/ { sec=$0 }
        sec==p && index($0, k"=")==1 { sub("^"k"=",""); gsub(/[ \t\r]/,""); print; exit }
    ' "$OCI_CONFIG"
}
TENANCY=$(read_cfg tenancy)
REGION=$(read_cfg region)
[ -n "$TENANCY" ] || die "couldn't read tenancy OCID from $OCI_CONFIG profile [$PROFILE]."
ok "tenancy ${BLU}${TENANCY}${RST}"
ok "region  ${BLU}${REGION}${RST}"

# --- 5. SSH key ---------------------------------------------------------------
header "SSH key"
SSH_KEY="$HOME/.ssh/id_ed25519"
if [ -f "$SSH_KEY.pub" ]; then
    ok "using existing $SSH_KEY.pub"
else
    info "no SSH key found — generating $SSH_KEY"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "coldspot@$(hostname)"
    ok "SSH key generated"
fi

# --- 6. Terraform apply -------------------------------------------------------
# Credentials are fed to Terraform as TF_VAR_* env vars — nothing is written to
# terraform.tfvars, so no secrets land on disk in the repo.
header "Building the server with Terraform"
echo "  ${DIM}(full output streams to $LOG)${RST}"
echo ""
export TF_VAR_oci_profile="$PROFILE"
export TF_VAR_compartment_ocid="$TENANCY"
export TF_VAR_ssh_public_key="$(cat "$SSH_KEY.pub")"

progress 12 "initializing Terraform…"
terraform init -input=false >> "$LOG" 2>&1 \
    || { printf '\n\n'; tail -n 15 "$LOG"; die "terraform init failed — full log: $LOG"; }

progress 18 "planning the build…"
set -o pipefail
if ! terraform apply -auto-approve -no-color 2>&1 | (
        cnt=0 total=6
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$LOG"
            res=$(printf '%s' "$line" | sed -E 's/:.*//; s/\..*//; s/^oci_core_//')
            case "$line" in
                *"Plan: "*" to add"*)
                    n=$(printf '%s' "$line" | grep -oE '[0-9]+ to add' | grep -oE '^[0-9]+')
                    [ -n "$n" ] && [ "$n" -gt 0 ] && total=$n ;;
                *": Creating..."*)
                    progress $(( 18 + cnt * 52 / total )) "creating $(friendly "$res")…" ;;
                *"Still creating"*)
                    el=$(printf '%s' "$line" | grep -oE '[0-9]+m[0-9]+s elapsed' | head -1)
                    progress $(( 18 + cnt * 52 / total )) "creating $(friendly "$res")… ${el}" ;;
                *"Creation complete"*)
                    cnt=$((cnt + 1))
                    progress $(( 18 + cnt * 52 / total )) "created $(friendly "$res")" ;;
                *"Apply complete"*)
                    progress 70 "server built" ;;
            esac
        done
    ); then
    printf '\n\n'; tail -n 20 "$LOG"; die "terraform apply failed — full log: $LOG"
fi
set +o pipefail
printf '\n\n'

# --- 7. wait until the server is reachable over SSH ---------------------------
IP=$(terraform output -raw public_ip 2>/dev/null || true)
[ -n "$IP" ] || die "apply finished but no public IP in terraform output — check 'terraform output'."

SSH_DEST="ubuntu@${IP}"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

wait_for() {
    local desc=$1 tries=$2 cmd=$3 pct=$4 n=0
    until eval "$cmd" >/dev/null 2>&1; do
        n=$((n + 1)); [ "$n" -ge "$tries" ] && return 1
        progress "$pct" "${desc} … (${n}×5s)"; sleep 5
    done
    return 0
}

header "Waiting for the server to boot (${IP})"
echo "  ${DIM}waiting for SSH — the exit is installed next, by install.sh over SSH${RST}"
echo ""
progress 80 "waiting for SSH to come up…"
wait_for "waiting for SSH" 36 "ssh $SSH_OPTS $SSH_DEST true" 90 \
    || { printf '\n\n'; die "SSH never came up at ${IP} — check the instance + security list in the OCI console, then re-run install.sh with SERVER_IP=${IP}."; }
progress 100 "server is up"
printf '\n\n'
ok "server up at ${BLU}${IP}${RST} — handing off to install.sh"

# --- 8. hand off to install.sh ------------------------------------------------
INSTALL_SH="$(cd ../../mac && pwd)/install.sh"
header "Set up this Mac"
echo "  The server is ready at ${BLU}${IP}${RST}. install.sh will now configure"
echo "  THIS Mac to use it (installs the exit on the server over SSH, fetches its"
echo "  cert + credentials, and wires up ColdSpot)."
echo ""
printf "  ${BLD}Configure this Mac now? [Y/n]${RST} "
read -r REPLY
case "$REPLY" in
    [nN]*)
        info "skipped. To do it later, run:"
        echo "     ${YLW}SERVER_IP=${IP} ${INSTALL_SH}${RST}"
        ;;
    *)
        SERVER_IP="$IP" SSH_USER="ubuntu" "$INSTALL_SH"
        ;;
esac
