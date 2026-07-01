# ColdSpot — make your Mac disappear 🫥

*Your Mac goes quiet. The network just sees a server somewhere else doing the
talking.*

Route **all** of a Mac's traffic — every app, even ones that ignore proxy
settings — through a paired iPhone and out to a small **exit server you own**, so
the outside world meets your server's address instead of your Mac's. A
from-scratch look at how a VPN-like data path is actually built.

## What it is

A virtual interface captures **all** of a Mac's traffic at Layer 3; `tun2socks`
turns those packets into a SOCKS stream; a reverse tunnel to a paired iPhone
carries each connection onward to a **self-hosted exit server you own**
(authenticated SOCKS5 over TLS) that re-originates it to the internet. Capturing
at Layer 3 means even apps that ignore proxy settings get caught; the iPhone is a
dumb relay, so the Mac↔exit conversation is end-to-end.

Built as **developer/educational material** — a working system to stand up and
learn from, end to end, not a product.

## How it works
```
app ─┬─ SOCKS5 :1080 (cooperating apps) ─────────────┐
     └─ utun123 (L3 capture) → tun2socks → :1080 ─────┤
                                                       ▼
                                                   proxy.py
                                  (SOCKS5 + 30-slot pool + live leak dashboard)
                                                       │
              iPhone opens 30 TCP slots INBOUND to :9999 over the hotspot
                                                       ▼
                            iPhone relays over its mobile uplink (a dumb pipe)
                                                       ▼
                          exit server  (authenticated SOCKS5 over TLS) → internet
```
The iPhone is a **dumb pipe**: the Mac tells it only to dial the exit, then runs
TLS + authenticated SOCKS5 to the exit *through* that pipe, end-to-end — so the
connection to your server is encrypted and all config stays on the Mac.

📐 **Architecture & data-flow diagram:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
🗺 **Roadmap:** [docs/ROADMAP.md](docs/ROADMAP.md) ·
🛠 **Setup:** [docs/SETUP.md](docs/SETUP.md)

## Repository layout
```
coldspot/
├── server/        the cloud exit server (runs on a free Oracle VM you own)
│   ├── exit.py            authenticated SOCKS5-over-TLS exit (re-originates to the internet)
│   ├── setup.sh           installs exit.py + cert + creds + systemd (pushed over SSH)
│   └── provision/         Terraform + provision.sh — one command builds the Oracle VM
│
├── mac/           host-side networking & orchestration (runs on the Mac)
│   ├── install.sh              one-command Mac installer (SSHes the server, fetches config)
│   ├── proxy.py                SOCKS5 + 30-slot iPhone pool + live leak dashboard
│   ├── coldspot.sh             manual launcher (sudo → runs proxy.py)
│   ├── coldspot-watch.sh       launchd watcher: toggle ON + hotspot → start, else tear down
│   ├── coldspot-toggle.sh      flip the menu-bar ON/OFF flag (~/.coldspot/enabled)
│   ├── lib/prompt.sh           interactive prompt helper for the installer
│   ├── swiftbar/coldspot.5s.sh SwiftBar menu-bar plugin (status + ON/OFF button)
│   ├── install-swiftbar.sh     symlink the plugin into SwiftBar's plugin folder
│   ├── coldspot-tun-ctl.sh     utun123 up/down/status engine (idempotent, safety-gated)
│   ├── coldspot-tun-up.sh      thin manual wrapper → tun-ctl up
│   ├── coldspot-tun-down.sh    thin manual wrapper → tun-ctl down
│   ├── com.coldspot.hotspot.plist   LaunchDaemon (templated at install time)
│   ├── install-autostart.sh    install + load the LaunchDaemon (portable paths)
│   ├── uninstall-autostart.sh  unload + remove it (back to fully manual)
│   └── tun2socks               L3<->L5 translator (binary; xjasonlyu/tun2socks)
│
├── ios/           the iPhone app (the 30-slot reverse relay) — unchanged
│   ├── ProxyTest/             Swift sources
│   └── ProxyTest.xcodeproj
│
└── docs/          ARCHITECTURE.md, SETUP.md
```

## Quick start

Create a free cloud account, then run **one command** — it sets up the server,
then your Mac, automatically. Two checkpoints need you: one browser login, and
your iPhone at the end.

### 1 · Create a free Oracle Cloud account

The only account you need: <https://signup.cloud.oracle.com>. Signup needs a card
+ SMS (the **Always-Free** tier doesn't charge you) and asks you to pick a **Home
Region** — choose one near you; it's **permanent** and your server lives in it.

<details>
<summary>The full signup walkthrough</summary>

1. Email + country + name → verify your email
2. Set a password + an account name
3. **Choose a Home Region** — permanent on a free account; your server lives in it
4. Phone / SMS code
5. Credit card (identity check only — Always-Free doesn't charge you)
6. Accept → the account provisions in a few minutes, then the console loads

</details>

### 2 · Clone + run one command — builds the server, then sets up your Mac

```bash
git clone https://github.com/codereyinish/coldspot.git
cd coldspot/server/provision
./provision.sh
```

It runs in this order, hands-off except where noted:

1. **Server** — installs the tools it needs, logs you into Oracle in the browser
   **once** (your only checkpoint here), builds a free VM, and installs the exit
   on it over SSH.
2. **Mac** — automatically hands off to `mac/install.sh`, which fetches the
   server's cert + credentials and installs the ❄️ menu-bar toggle.

During the one login it walks you through four prompts: pick your **Home Region**,
click **Allow** on the macOS *"Allow Python…"* popup (don't skip it — the login
needs it), **log in + Authorize** in the browser, and type **`N/A`** at the
passphrase prompt. After that it's automatic.

> Already have an Ubuntu server? Skip provisioning and run `bash mac/install.sh`
> from the repo — it asks for the server's IP and does the rest.

### 3 · Checkpoint — set up your iPhone (one-time)

ColdSpot's relay is a tiny app you run on your own phone from Xcode (free Apple ID
is fine):

1. Plug the iPhone into the Mac; enable **Developer Mode** (Settings → Privacy &
   Security → Developer Mode) and trust the computer.
2. Open `ios/ProxyTest.xcodeproj` in Xcode → select the **ProxyTest** target →
   **Signing & Capabilities** → set **Team** to your Apple ID.
3. Pick your iPhone in the device menu and click **Run ▶**.
4. On the phone: **Settings → General → VPN & Device Management** → trust your
   developer app.
5. Open the app and tap **Start** (it opens its relay slots).

Full walkthrough (creating the project, permissions): [docs/SETUP.md](docs/SETUP.md).

### 4 · Turn it on

Connect the Mac to the iPhone's **Personal Hotspot** (the Mac should get address
`172.20.10.2`), then click the ❄️ in your menu bar → **ON**.

```bash
curl https://ifconfig.me      # should print your EXIT SERVER's IP, not your home one
```

If that shows the Oracle server's address, traffic is flowing the whole way
through. After a reboot ColdSpot stays **off** until you flip ❄️ ON again.

## Menu-bar toggle (SwiftBar)
A ❄️ menu-bar switch turns ColdSpot on/off. The button never does privileged work
— it just creates/deletes a flag file (`~/.coldspot/enabled`) = your saved intent.
The root daemon watches that file and reconciles. The rule:

| Toggle | On hotspot? | Result |
|--------|-------------|--------|
| OFF    | anything    | everything torn down |
| ON     | yes         | ColdSpot runs |
| ON     | no          | stays down, waits for the hotspot |

So it only runs on the hotspot, re-runs on any network change, and on reboot it
checks the toggle first (RunAtLoad): booted OFF → does nothing. `install.sh` sets
up the daemon and the plugin for you.

## Security model
- **SSH config exchange** (Mac ↔ exit server): host-key checking stays **on** —
  `install.sh` never passes `StrictHostKeyChecking=no`. The same authority as
  SSHing in by hand, with the first-connect prompt removed by pre-seeding the
  freshly-built server's key (`provision.sh`), not by disabling the check.
- **Data plane** (Mac → iPhone relay → exit): **TLS with a pinned self-signed
  cert** + **SOCKS5 username/password auth**. The exit port is open to the whole
  internet (a phone's mobile IP can't be firewalled to a fixed source), so the
  password is what restricts use to your Mac and the TLS pin is what proves the
  exit is yours. Credentials + cert are generated once on the server and reused,
  so re-installs never break a configured Mac. No secrets are committed; they live
  under `~/.coldspot/` on the Mac (mode 600) and `/etc/coldspot/` on the server.

## Concepts it demonstrates
- Layer-3 vs Layer-5 interception (and why lower = unavoidable)
- routing-table internals — longest-prefix match, non-destructive default override
- sockets, ports, and the 4-tuple; listening vs connection sockets
- reverse-tunnel design (inbound slots a NAT'd device can hold open)
- SOCKS5 (CONNECT + RFC 1929 auth) and TLS with certificate pinning
- self-hosted cloud infrastructure as code (Terraform on Oracle Always-Free)
- automated, host-key-safe SSH config exchange
- file-descriptor limits & connection-pool management
- traffic prioritization (foreground vs background)
- fail-safe, self-healing background services (launchd, idempotent reconcile)
