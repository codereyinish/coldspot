# ColdSpot — Roadmap & future security updates

Ideas deliberately **not** in the current build, with the reasoning, so they can
be picked up later without re-deriving the trade-offs. Nothing here is shipped.

For what *is* shipped, see the **Security model** in the [README](../README.md)
and the data path in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. UDP / QUIC support (the real functional gap)

**Today:** the exit speaks SOCKS5 **CONNECT**, which is TCP-only. UDP traffic
(QUIC / HTTP-3, DNS-over-UDP, VoIP) can't traverse it, so apps fall back to TCP.
For a learning project that's fine; for daily use it leaves QUIC on the table.

**Future:** add a datagram path — SOCKS5 **UDP-ASSOCIATE**, or a small dedicated
UDP-relay channel — so UDP flows reach the exit too. This is the highest-value
future change and is **independent of WireGuard** (see §2).

## 2. WireGuard at the exit — considered, deferred

The question: instead of SOCKS5-over-TLS, run **WireGuard** Mac↔exit (like the
sibling project coldvpn) and carry "double-level" packets through the phone.

**Doable, but deferred — here's why:**

- **WireGuard is UDP; the phone relay is TCP.** The iPhone holds *reverse TCP*
  slots open because it sits behind carrier NAT and must dial out. Pushing
  WireGuard through that means **UDP-in-TCP** → the classic **TCP-over-TCP
  meltdown**: WireGuard retransmits the inner stream, the outer TCP retransmits
  too, and on lossy cellular throughput collapses.
- **It's double encryption for no added secrecy.** Mac↔exit is *already*
  encrypted end-to-end (TLS, pinned cert). WireGuard on top = encrypt twice.
- **It barely changes the privacy story.** "Encrypted tunnel to a server you own"
  is already what TLS-to-your-own-exit gives.
- **Why it was clean in coldvpn but not here:** coldvpn was `Mac → Oracle` over
  UDP *directly* — no phone in the middle forcing TCP. ColdSpot's phone-relay
  constraint is exactly what makes WireGuard awkward.

**The one thing WireGuard would add** is native UDP — but §1 delivers that more
cheaply without the UDP-in-TCP penalty. So: pursue §1, not WireGuard, unless the
topology changes (e.g. a direct Mac↔exit UDP path that bypasses the relay).

## 3. Per-device credentials (instead of one shared password)

**Today:** the exit authenticates with a single shared SOCKS username/password +
a pinned TLS cert. Simple, and fine for a single owner.

**Future:** give each client (Mac, and conceptually each phone) its **own**
credential the exit authorizes — closer to coldvpn's per-peer public-key model.
Benefits: revoke one device without rotating everyone; per-device attribution.
Cost: a small credential-registry + handoff step on the server (the SSH config
exchange already exists to carry it).

## 4. Smaller hardening ideas
- Rotate the exit's TLS cert / SOCKS password on a schedule (re-fetched by
  `install.sh`; the reuse-on-disk anchor pattern already keeps re-runs safe).
- Optional `fail2ban`-style throttling on the exit's auth failures.
- Pin the exit cert by fingerprint in `exit.conf` (in addition to the cert file)
  so a swapped cert file is detected.
