import socket
import threading
import struct
import time
import os
import sys
import subprocess
import ipaddress

TUNNEL_PORT = 9999   # iPhone connects here
SOCKS_PORT  = 1080   # SOCKS5 (for GUI apps via system proxy setting)

IFACE  = "en0"             # hotspot interface
IPHONE = "172.20.10.1"     # iPhone (tunnel = phone APN)

# ── Slot priority: keep foreground/user traffic from being starved by chatty
# background services (iCloud sync, cert checks, push). Low-priority connections
# are capped so RESERVED_HIGH slots always stay free for user traffic.
POOL_SIZE     = 30         # MUST match the iPhone app's slot count — rebuild app to 30!
RESERVED_HIGH = 15         # slots kept for high-priority (user) traffic
LOW_PRIORITY_SUFFIXES = (  # background/telemetry/sync domains -> [bg]
    "apple.com", "icloud.com", "safebrowsing.apple",
    "aaplimg.com", "mzstatic.com", "spotify.com",
)
LOW_PRIORITY_NETS = (ipaddress.ip_network("17.0.0.0/8"),)   # Apple owns all of 17.x


# Pool of available iPhone tunnel slots
available_slots = []
slots_lock = threading.Lock()

# Low-priority (background) connections are capped to (POOL_SIZE - RESERVED_HIGH)
# concurrent, leaving RESERVED_HIGH slots always free for user/foreground traffic.
low_prio_sem = threading.Semaphore(max(1, POOL_SIZE - RESERVED_HIGH))

def is_low_priority(host):
    h = host.lower()
    if any(h == s or h.endswith("." + s) for s in LOW_PRIORITY_SUFFIXES):
        return True
    try:                              # also demote known background IP ranges (Apple 17.x)
        ip = ipaddress.ip_address(host)
        return any(ip in net for net in LOW_PRIORITY_NETS)
    except ValueError:
        return False

def is_private(host):
    """True if host is a private/local IP that can't be reached over cellular —
    tunneling it would just hang at 0 bytes and clog a slot. Hostnames return
    False (they resolve to public IPs via real DNS)."""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False   # a hostname, not an IP → public destination, tunnel it
    return (ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_multicast or ip.is_reserved or ip.is_unspecified)

# Byte counters — how much we carried through the phone (phone APN)
bytes_through_proxy = 0
bytes_lock = threading.Lock()

def add_bytes(n):
    global bytes_through_proxy
    with bytes_lock:
        bytes_through_proxy += n

def stats_printer():
    last = 0
    while True:
        time.sleep(10)
        with bytes_lock:
            total = bytes_through_proxy
        delta = total - last
        last = total
        log(f"📊 Through phone APN: {total/1048576:.1f} MB total "
            f"(+{delta/1048576:.1f} MB in last 10s) | active slots: {len(available_slots)}")

def log(msg):
    print(f"[proxy] {msg}", flush=True)

# ── Live leak finder: what's escaping to hotspot, by RESOURCE NAME ────────────
#
# Sniffs en0 with tcpdump. Any traffic whose non-Mac end is a public internet IP
# = LEAK (tethered, bypassing the tunnel). Tallies bytes per resource, resolves
# IPs to hostnames (reverse-DNS, cached), and prints the top leakers live.

leak_bytes = {}            # ip -> {"TCP": n, "UDP": n}   (tethered = leak)
tunnel_total = 0           # bytes to/from iPhone on en0 (phone APN) — for leak %
leak_lock = threading.Lock()
dns_cache = {}             # ip -> hostname  (filled by passive DNS, then reverse DNS)
dns_pending = {}           # dns transaction id -> the queried hostname

def mac_ip():
    try:
        out = subprocess.check_output(["ifconfig", IFACE], text=True)
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("inet ") and "172.20.10" in line:
                return line.split()[1]
    except Exception:
        pass
    return "172.20.10.2"

def leak_sniffer():
    global tunnel_total
    mac = mac_ip()
    log(f"Leak monitor watching {IFACE} (Mac={mac})")
    try:
        proc = subprocess.Popen(
            ["tcpdump", "-i", IFACE, "-nn", "-q", "-l"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except Exception as e:
        log(f"Leak monitor failed to start tcpdump: {e}")
        return

    for line in proc.stdout:
        p = line.split()
        if len(p) < 6 or p[1] != "IP":
            continue
        try:
            length = int(p[-1])           # last field = byte length
        except ValueError:
            continue
        proto = "UDP" if "UDP" in line else ("TCP" if " tcp" in line else "OTH")
        if proto == "OTH":
            continue
        src = p[2]; dst = p[4].rstrip(":")
        sip = src.rsplit(".", 1)[0]       # strip ".port" → src IP
        dip = dst.rsplit(".", 1)[0]       # strip ".port" → dst IP
        if   sip == mac: other = dip
        elif dip == mac: other = sip
        else:            continue
        # phone APN = the tunnel (other end is the iPhone)
        if other == IPHONE:
            with leak_lock:
                tunnel_total += length
            continue
        # local/broadcast noise → ignore
        if other.startswith("172.20.10.") or other.startswith(("224.", "239.", "255.")):
            continue
        # everything else = LEAK (tethered to a public internet IP)
        with leak_lock:
            d = leak_bytes.setdefault(other, {"TCP": 0, "UDP": 0})
            d[proto] += length

def _is_ipv4(s):
    p = s.split(".")
    return len(p) == 4 and all(x.isdigit() and 0 <= int(x) <= 255 for x in p)

def dns_sniffer():
    # PASSIVE DNS: overhear DNS lookups on en0 → map IP → the hostname the app
    # actually asked for (more accurate than reverse-DNS). Queries carry the name
    # + a transaction id; responses carry the same id + the resolved IP(s).
    try:
        proc = subprocess.Popen(
            ["tcpdump", "-i", IFACE, "-nn", "-l", "port", "53"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except Exception as e:
        log(f"DNS sniffer failed: {e}")
        return
    for line in proc.stdout:
        toks = line.split()
        if "A?" in toks:                                   # a QUERY: id → name
            i = toks.index("A?")
            if 0 < i and i + 1 < len(toks):
                name = toks[i + 1].rstrip(".")
                qid = "".join(c for c in toks[i - 1] if c.isdigit())
                if qid and name:
                    dns_pending[qid] = name
        else:                                              # maybe a RESPONSE: id … A <ip>
            qid = ""
            for j, t in enumerate(toks):
                if t.endswith(":") and j + 1 < len(toks):
                    qid = "".join(c for c in toks[j + 1] if c.isdigit())
                    break
            name = dns_pending.get(qid)
            if not name:
                continue
            for k, t in enumerate(toks):
                if t == "A" and k + 1 < len(toks) and _is_ipv4(toks[k + 1]):
                    dns_cache[toks[k + 1]] = name          # IP → real hostname

def leak_resolver():
    # FALLBACK: for leak IPs that passive DNS didn't catch, try reverse-DNS.
    # (passive DNS is more accurate, so we only fill gaps here.)
    while True:
        with leak_lock:
            todo = [ip for ip in leak_bytes if ip not in dns_cache]
        for ip in todo:
            try:
                name = socket.gethostbyaddr(ip)[0]
            except Exception:
                name = ip
            dns_cache.setdefault(ip, name)   # don't overwrite a passive-DNS name
        time.sleep(3)

def _c(code, s):
    return f"\033[{code}m{s}\033[0m"   # wrap text in an ANSI color/style

def leak_printer():
    GREEN, RED, YEL, CYAN, BOLD, DIM = "32", "31", "33", "36", "1", "2"
    while True:
        time.sleep(10)
        with leak_lock:
            snap = {ip: dict(d) for ip, d in leak_bytes.items()}
            phone = tunnel_total
        hotspot = sum(d["TCP"] + d["UDP"] for d in snap.values())
        pct = (100 * hotspot / (phone + hotspot)) if (phone + hotspot) else 0
        if   pct < 10: light, pcol = "🟢", GREEN
        elif pct < 40: light, pcol = "🟡", YEL
        else:          light, pcol = "🔴", RED

        bar = _c(CYAN, "━" * 14)
        print(f"\n{bar} {_c(BOLD, '📡 COLDSPOT LEAK DASHBOARD')} {bar}", flush=True)
        print(f"  📱 PHONE APN: {_c(GREEN, f'{phone/1048576:7.2f} MB')}     "
              f"🔥 HOTSPOT: {_c(RED, f'{hotspot/1048576:7.2f} MB')}", flush=True)
        print(f"  📊 LEAK: {_c(pcol, f'{pct:5.1f}%')} {light}", flush=True)
        if snap:
            print(_c(DIM, "  ── top leaking resources ──────────────────"), flush=True)
            items = sorted(snap.items(), key=lambda kv: kv[1]["TCP"] + kv[1]["UDP"], reverse=True)
            shown = False
            for ip, d in items[:6]:
                mb = (d["TCP"] + d["UDP"]) / 1048576
                if mb < 0.01:
                    continue
                shown = True
                udp = d["UDP"] > d["TCP"]
                kind = "QUIC" if udp else "TCP "
                name = dns_cache.get(ip, ip)
                icon = "🔍" if "dns" in name else ("🎥" if udp else "🌐")
                print(f"   {icon} {_c(RED, f'{mb:6.2f} MB')}  {_c(DIM, kind)}  {name}", flush=True)
            if not shown:
                print(_c(DIM, "   (nothing significant leaking 🎉)"), flush=True)
        print(_c(CYAN, "━" * 56) + "\n", flush=True)

# ── iPhone tunnel pool ────────────────────────────────────────────────────────

def accept_iphone_slots():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", TUNNEL_PORT))
    srv.listen(POOL_SIZE)
    log(f"Waiting for iPhone slots on :{TUNNEL_PORT}")
    while True:
        conn, addr = srv.accept()
        with slots_lock:
            # Pool looks full? Some entries may be CORPSES — slots the iPhone
            # already closed (we only learn by peeking). Evict the dead ones so
            # healthy reconnects aren't rejected behind dead slots. An idle LIVE
            # slot has no data waiting (peek would-block); a DEAD one returns EOF.
            if len(available_slots) >= POOL_SIZE:
                alive = []
                for s in available_slots:
                    try:
                        if s.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b'':
                            s.close()             # EOF → dead, evict
                        else:
                            alive.append(s)       # unexpected data → keep
                    except BlockingIOError:
                        alive.append(s)           # no data waiting → alive & idle
                    except OSError:
                        try: s.close()
                        except: pass              # errored → dead, evict
                available_slots[:] = alive
            if len(available_slots) >= POOL_SIZE:
                log(f"Pool full, rejecting slot from {addr}")   # genuinely full of LIVE slots
                conn.close()
                continue
            log(f"iPhone slot connected from {addr}")
            available_slots.append(conn)

def grab_slot():
    while True:
        with slots_lock:
            if available_slots:
                return available_slots.pop(0)
        time.sleep(0.05)

def send_connect(host, port):
    """Grab a live slot and send CONNECT command. Returns the slot."""
    while True:
        slot = grab_slot()
        try:
            slot.sendall(f"CONNECT {host}:{port}\n".encode())
            return slot
        except OSError:
            # Just THIS slot is dead — drop only it and grab the next one.
            # (Previously we cleared the WHOLE pool here, which made the iPhone
            #  flood-reconnect all 20 slots → socket churn → FD leak →
            #  "Too many open files" wedged accept(). Drop one, keep the other 19.)
            try: slot.close()
            except: pass

def wait_connected(slot):
    """Wait for CONNECTED or FAILED from iPhone. Returns True if connected."""
    response = b""
    while b"\n" not in response:
        chunk = slot.recv(1)
        if not chunk:
            return False
        response += chunk
    return b"CONNECTED" in response

def pipe(a, b):
    def forward(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data: break
                dst.sendall(data)
                add_bytes(len(data))
        except: pass
        finally:
            try: src.close()
            except: pass
            try: dst.close()
            except: pass

    t1 = threading.Thread(target=forward, args=(a, b), daemon=True)
    t2 = threading.Thread(target=forward, args=(b, a), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

# ── SOCKS5 proxy (GUI apps via system proxy setting) ─────────────────────────

def handle_socks(client):
    try:
        data = client.recv(3)
        if not data or data[0] != 5:
            client.close()
            return
        client.send(b"\x05\x00")

        data = client.recv(4)
        if not data or data[1] != 1:
            client.close()
            return

        atype = data[3]
        if atype == 1:
            host = socket.inet_ntoa(client.recv(4))
        elif atype == 3:
            length = client.recv(1)[0]
            host = client.recv(length).decode()
        else:
            client.close()
            return

        port = struct.unpack("!H", client.recv(2))[0]

        # Private/local IPs (192.168.x, 10.x, 172.20.10.1, link-local...) can't be
        # reached over cellular — tunneling them just hangs at 0 bytes and clogs a
        # slot. Refuse fast, no slot used. (This lives in proxy.py, so it ONLY
        # applies while the proxy runs — off the hotspot your LAN works normally.)
        if is_private(host):
            log(f"[SOCKS5] reject LOCAL {host}:{port} (private, not tunneled)")
            client.send(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")   # 0x05 = refused
            client.close()
            return

        low = is_low_priority(host)
        tag = "bg" if low else "user"
        log(f"[SOCKS5] CONNECT {host}:{port} [{tag}]")

        # PRIORITY: background traffic must not starve foreground. Low-priority
        # connections wait on a semaphore capped at (POOL_SIZE - RESERVED_HIGH),
        # so RESERVED_HIGH slots always stay free for user traffic. High-priority
        # is uncapped (skips the gate).
        if low:
            low_prio_sem.acquire()
        try:
            slot = send_connect(host, port)

            if not wait_connected(slot):
                log(f"iPhone failed to connect to {host}:{port}")
                client.send(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
                client.close()
                slot.close()
                return

            log(f"[SOCKS5] Piping {host}:{port} via phone APN [{tag}]")
            client.send(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            pipe(client, slot)
        finally:
            if low:
                low_prio_sem.release()

    except Exception as e:
        log(f"SOCKS5 error: {e}")
        try: client.close()
        except: pass

def accept_socks():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", SOCKS_PORT))
    srv.listen(50)
    log(f"SOCKS5 proxy on 127.0.0.1:{SOCKS_PORT}")
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle_socks, args=(client,), daemon=True).start()

# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # single-instance guard: if something is already serving SOCKS on :1080,
    # another proxy.py is running → don't start a duplicate.
    try:
        _s = socket.create_connection(("127.0.0.1", SOCKS_PORT), timeout=0.3)
        _s.close()
        print("[proxy] another instance already running on :1080 — exiting", flush=True)
        sys.exit(0)
    except OSError:
        pass   # nothing listening → we're the only one

    # Raise the open-file limit. Each slot/client socket is one file descriptor,
    # and macOS defaults to a low soft limit (~256). A brief connection burst
    # could otherwise hit it → "Too many open files" → accept() fails → no new
    # slots. This is headroom only; it costs ~0 memory unless sockets are opened.
    try:
        import resource
        _soft, _hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        _want = min(4096, _hard)
        resource.setrlimit(resource.RLIMIT_NOFILE, (_want, _hard))
        log(f"FD limit raised: {_soft} -> {_want} (hard {_hard})")
    except Exception as _e:
        log(f"could not raise FD limit: {_e}")

    threading.Thread(target=accept_iphone_slots, daemon=True).start()
    threading.Thread(target=accept_socks, daemon=True).start()
    threading.Thread(target=stats_printer, daemon=True).start()
    # live leak finder (needs root for tcpdump; proxy.py runs under sudo)
    threading.Thread(target=leak_sniffer, daemon=True).start()
    threading.Thread(target=dns_sniffer, daemon=True).start()    # passive DNS (names)
    threading.Thread(target=leak_resolver, daemon=True).start()  # reverse-DNS fallback
    threading.Thread(target=leak_printer, daemon=True).start()
    log("📊 = bytes through phone APN | 🚨 = what's leaking to hotspot (by resource)")
    # keep the main thread alive (daemon threads do the work)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
