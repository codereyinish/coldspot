# ColdSpot — Transparent System-Wide Proxy (macOS → iPhone phone-APN)

Capture **all** of a Mac's network traffic at the IP layer and route it through a
reverse tunnel to the iPhone, which re-originates it over its **phone APN** —
automatically, for every app, including ones that ignore proxy settings.

## What it does (plain version)
Most proxies are *opt-in*: an app has to choose to use them. Browsers cooperate;
command-line tools and system daemons don't, so they "leak" around the proxy.
This captures traffic **below** the app — at the network (IP) layer — using a
virtual interface, so nothing can opt out. It then rebuilds those packets into
connections and forwards them through a pool of reverse-tunnel slots on the phone.

## How it works
```
app ─┬─ SOCKS5 :1080 (cooperating apps) ─────────────┐
     └─ utun123 (L3 capture) → tun2socks → :1080 ─────┤
                                                       ▼
                                                   proxy.py
                                          (SOCKS5 + 30-slot pool + leak dashboard)
                                                       │
              iPhone opens 30 TCP slots INBOUND to :9999 over en0/hotspot
                                                       ▼
                              iPhone app → phone APN → internet
```
- **utun123** — virtual interface made the default route (`0/1`+`128/1`), so it captures everything
- **tun2socks** — turns raw IP packets back into TCP connections (userspace TCP/IP stack)
- **proxy.py** — SOCKS5 server + pool of reverse-tunnel "slots" + live leak dashboard
- **iPhone app** — dials 30 slots into the Mac and relays each out its phone APN
- **launchd** — auto-starts/stops the whole thing based on whether you're on the hotspot

No WireGuard is involved — the "tunnel" is the plain TCP slots to the phone. The
loop (proxy's own traffic falling back into utun123) is prevented structurally by
longest-prefix routing: the hotspot subnet `172.20.10.0/28` and loopback `127/8`
are more specific than the `/1` capture, so they stay on `en0`/`lo0`.

📐 **Full walkthrough + diagrams:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
🛠 **Setup:** [docs/SETUP.md](docs/SETUP.md)

## Repository layout
```
coldspot/
├── server/        the proxy server program
│   └── proxy.py           SOCKS5 + 30-slot iPhone pool + live leak dashboard
│
├── mac/           host-side networking & orchestration (runs on the Mac)
│   ├── coldspot.sh             one-command launcher (sudo → runs server/proxy.py)
│   ├── coldspot-watch.sh       launchd watcher: hotspot → start, off-hotspot → tear down
│   ├── coldspot-tun-ctl.sh     utun123 up/down/status engine (idempotent, safety-gated)
│   ├── coldspot-tun-up.sh      thin manual wrapper → tun-ctl up
│   ├── coldspot-tun-down.sh    thin manual wrapper → tun-ctl down
│   ├── com.coldspot.hotspot.plist   LaunchDaemon (templated at install time)
│   ├── install-autostart.sh    install + load the LaunchDaemon (portable paths)
│   ├── uninstall-autostart.sh  unload + remove it (back to fully manual)
│   ├── pf_rules.conf           (legacy/unused — old pf rdr approach)
│   └── tun2socks               L3<->L5 translator (binary; xjasonlyu/tun2socks)
│
├── ios/           the iPhone app (the 30-slot reverse tunnel)
│   ├── ProxyTest/             Swift sources
│   └── ProxyTest.xcodeproj
│
└── docs/          ARCHITECTURE.md, SETUP.md
```

## Quick start
```bash
# 1. On the iPhone: open ios/ProxyTest.xcodeproj in Xcode, Run on your phone, tap Start.
# 2. Connect the Mac to the iPhone Personal Hotspot (Mac should get 172.20.10.2).
# 3. On the Mac, either run manually:
sudo bash mac/coldspot.sh           # runs server/proxy.py + leak dashboard
sudo bash mac/coldspot-tun-up.sh    # bring up the utun safety-net

#    …or install the auto-start daemon (starts/stops itself on the hotspot):
sudo bash mac/install-autostart.sh
```

## Concepts it demonstrates
- Layer-3 vs Layer-5 interception (and why lower = unavoidable)
- routing-table internals — longest-prefix match, non-destructive default override
- sockets, ports, and the 4-tuple; listening vs connection sockets
- file-descriptor limits & connection-pool management
- traffic prioritization (foreground vs background)
- fail-safe, self-healing background services (launchd, idempotent reconcile)
