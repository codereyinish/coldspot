# Transparent System-Wide Proxy (macOS)

Capture **all** of a Mac's network traffic at the IP layer and route it through a
reverse tunnel to a second device — automatically, for every app, including ones
that ignore proxy settings.

## What it does (plain version)
Most proxies are *opt-in*: an app has to choose to use them. Browsers cooperate;
command-line tools and system daemons don't, so they "leak" around the proxy.
This captures traffic **below** the app — at the network (IP) layer — using a
virtual interface, so nothing can opt out. It then rebuilds those packets into
connections and forwards them through a reverse tunnel.

## How it works
```
app → utun123 (L3 capture) → tun2socks → proxy.py (SOCKS5) → reverse tunnel → internet
```
- **utun** — a virtual network interface, made the default route, so it captures everything
- **tun2socks** — turns raw IP packets back into TCP connections (a userspace TCP/IP stack)
- **proxy.py** — SOCKS5 server + a pool of reverse-tunnel "slots" + a live dashboard
- **launchd** — auto-starts/stops the whole thing based on network state

📐 **Full walkthrough + diagrams:** [ARCHITECTURE.md](ARCHITECTURE.md)

## Concepts it demonstrates
- Layer-3 vs Layer-5 interception (and why lower = unavoidable)
- routing-table internals — longest-prefix match, non-destructive default override
- sockets, ports, and the 4-tuple; listening vs connection sockets
- file-descriptor limits & connection-pool management
- traffic prioritization (foreground vs background)
- fail-safe, self-healing background services (launchd, idempotent reconcile)

## Status
Working: ~0% leak, self-healing, 30-slot pool, foreground priority.
Planned improvements: [ARCHITECTURE.md §11](ARCHITECTURE.md).

## Components
```
proxy.py             SOCKS5 server + slot pool + live dashboard (Mac)
tun2socks            L3<->L5 translator (binary; from xjasonlyu/tun2socks)
coldspot-tun-ctl.sh  utun up/down/status engine (idempotent, safety-gated)
coldspot-watch.sh    launchd-driven start/stop
ProxyTest/           iPhone app (the 30-slot reverse tunnel)
```
