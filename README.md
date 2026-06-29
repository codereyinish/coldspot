# ColdSpot — Transparent System-Wide Proxy (a hands-on networking project)

Route **all** of a Mac's traffic — every app, even ones that ignore proxy
settings — through a paired iPhone and out to a small **exit server you own**.
A from-scratch look at how a VPN-like data path is actually built.

## What it is
Normal proxies are **opt-in**: each app chooses to use them, so command-line
tools and system daemons just ignore them and leak around. ColdSpot instead
captures traffic **at the IP layer**, below the app — so nothing can opt out —
and carries it over a **reverse tunnel** the iPhone holds open to the Mac. The
iPhone relays it onward to your **exit server**, which sends it to the internet
from an address you control.

Built as **developer/educational material** — a working system to stand up and
learn from, end to end, not a product. The four ideas it ties together:

- **Layer-3 capture** — a virtual interface grabs every packet, so no app escapes.
- **Userspace TCP/IP** (`tun2socks`) — turns those raw packets back into connections.
- **Reverse tunnel** — the iPhone dials *out* to the Mac and holds slots open
  (so a phone behind carrier NAT can still be reached).
- **Self-hosted exit** — your own cloud server is the final hop to the internet.

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
- **utun123** — virtual interface made the default route (`0/1`+`128/1`), so it captures everything
- **tun2socks** — turns raw IP packets back into TCP connections (userspace TCP/IP stack)
- **proxy.py** — SOCKS5 server + pool of reverse-tunnel "slots" + live leak dashboard
- **iPhone app** — holds 30 slots open to the Mac and relays each onward as a plain pipe
- **exit server** — a free Oracle Always-Free VM you own; runs an authenticated
  SOCKS5-over-TLS exit and re-originates traffic to the internet from a stable IP
- **launchd** — auto-starts/stops the whole thing based on whether you're on the hotspot

The iPhone never parses the real destination: the Mac tells it only to dial the
exit, then speaks **TLS + authenticated SOCKS5 to the exit *through* that pipe**,
end-to-end. So the iPhone is a dumb relay, all server config lives on the Mac,
and the connection to your exit is encrypted (an observer on the path sees only
an encrypted stream to your server, not which sites you reach). No WireGuard is
involved — the "tunnel" is the plain TCP slots to the phone, with TLS layered on
top end-to-end. The loop (proxy's own traffic falling back into utun123) is
prevented structurally by longest-prefix routing: the hotspot subnet
`172.20.10.0/28` and loopback `127/8` are more specific than the `/1` capture, so
they stay on `en0`/`lo0`.

📐 **Full walkthrough + diagrams:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
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
