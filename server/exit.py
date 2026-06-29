#!/usr/bin/env python3
# =============================================================================
# server/exit.py — ColdSpot exit server (runs on the Oracle VM)
# =============================================================================
# The egress hop of ColdSpot. Mac traffic arrives here (relayed by the iPhone)
# and is re-originated to the internet from THIS server's address.
#
#   Mac proxy.py  ──TLS──▶  [ this server ]  ──▶  internet
#                 (authenticated SOCKS5 over TLS, end-to-end through the relay)
#
# Why SOCKS5-over-TLS:
#   • SOCKS5 is the same connection-oriented CONNECT protocol the Mac proxy.py
#     already speaks, so the Mac talks to us end-to-end (the iPhone is a dumb
#     TCP relay and never parses anything).
#   • TLS wraps the whole thing, so an observer on the path sees only an
#     encrypted stream to this server — not which sites are being reached.
#   • Username/password auth (RFC 1929): the listen port is open to the whole
#     internet (it has to be — the phone's cellular IP keeps changing, so it
#     can't be firewalled to a fixed source). The password is what stands in
#     for that missing firewall rule, so only this user's Mac can use the box
#     (an open exit would get the server's IP abused / blocklisted).
#
# Credentials + TLS cert are NOT hard-coded — they're passed in by the systemd
# unit (written by setup.sh) via environment variables:
#   COLDSPOT_USER, COLDSPOT_PASS, COLDSPOT_CERT, COLDSPOT_KEY, COLDSPOT_PORT
#
# Stdlib only (socket, ssl, threading) — Ubuntu ships python3, nothing to apt.
#
# Author: github.com/codereyinish
# =============================================================================

import os
import socket
import ssl
import struct
import sys
import threading

# --- config from environment (set by the systemd unit) -----------------------
PORT = int(os.environ.get("COLDSPOT_PORT", "443"))
USER = os.environ.get("COLDSPOT_USER", "")
PASS = os.environ.get("COLDSPOT_PASS", "")
CERT = os.environ.get("COLDSPOT_CERT", "/etc/coldspot/exit.crt")
KEY  = os.environ.get("COLDSPOT_KEY",  "/etc/coldspot/exit.key")

BUFSIZE = 65536


def log(msg):
    print(f"[exit] {msg}", flush=True)


# --- SOCKS5 ------------------------------------------------------------------
# We implement only what the Mac proxy.py needs: the username/password auth
# method (RFC 1929) and the CONNECT command (RFC 1928). No BIND, no UDP
# associate, no GSSAPI.

def recv_exact(conn, n):
    """Read exactly n bytes or raise (so a truncated handshake fails loudly)."""
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed mid-handshake")
        buf += chunk
    return buf


def socks5_handshake(conn):
    """Negotiate the auth method and verify the username/password.

    Returns True if the client authenticated, False otherwise (caller closes).
    """
    # greeting: VER=5, NMETHODS, METHODS[NMETHODS]
    ver, nmethods = recv_exact(conn, 2)
    if ver != 0x05:
        return False
    methods = recv_exact(conn, nmethods)

    # We REQUIRE username/password (0x02). If the client didn't offer it, refuse
    # with 0xFF ("no acceptable methods") — this is what blocks unauthenticated
    # open-proxy abuse.
    if 0x02 not in methods:
        conn.sendall(b"\x05\xff")
        return False
    conn.sendall(b"\x05\x02")

    # RFC 1929: VER=1, ULEN, UNAME, PLEN, PASSWD
    ver = recv_exact(conn, 1)[0]
    if ver != 0x01:
        return False
    ulen = recv_exact(conn, 1)[0]
    uname = recv_exact(conn, ulen).decode("utf-8", "replace")
    plen = recv_exact(conn, 1)[0]
    passwd = recv_exact(conn, plen).decode("utf-8", "replace")

    if uname == USER and passwd == PASS:
        conn.sendall(b"\x01\x00")   # status 0 = success
        return True
    conn.sendall(b"\x01\x01")       # status !=0 = failure
    return False


def socks5_read_request(conn):
    """Read a CONNECT request; return (host, port) or None for anything else."""
    # VER, CMD, RSV, ATYP
    ver, cmd, _rsv, atyp = recv_exact(conn, 4)
    if ver != 0x05 or cmd != 0x01:      # only CONNECT
        _reply(conn, 0x07)              # command not supported
        return None

    if atyp == 0x01:                    # IPv4
        host = socket.inet_ntoa(recv_exact(conn, 4))
    elif atyp == 0x03:                  # domain name
        length = recv_exact(conn, 1)[0]
        host = recv_exact(conn, length).decode("utf-8", "replace")
    elif atyp == 0x04:                  # IPv6
        host = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
    else:
        _reply(conn, 0x08)              # address type not supported
        return None

    port = struct.unpack("!H", recv_exact(conn, 2))[0]
    return host, port


def _reply(conn, code):
    """Send a SOCKS5 reply with the given status code and a null BND.ADDR."""
    try:
        conn.sendall(b"\x05" + bytes([code]) + b"\x00\x01\x00\x00\x00\x00\x00\x00")
    except OSError:
        pass


def pipe(a, b):
    """Bidirectionally shovel bytes between two sockets until either closes."""
    def forward(src, dst):
        try:
            while True:
                data = src.recv(BUFSIZE)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    t1 = threading.Thread(target=forward, args=(a, b), daemon=True)
    t2 = threading.Thread(target=forward, args=(b, a), daemon=True)
    t1.start(); t2.start()
    t1.join(); t2.join()


def handle(conn, addr):
    dest = None
    try:
        if not socks5_handshake(conn):
            return
        req = socks5_read_request(conn)
        if req is None:
            return
        host, port = req

        try:
            dest = socket.create_connection((host, port), timeout=15)
        except OSError as e:
            log(f"connect {host}:{port} failed: {e}")
            _reply(conn, 0x05)          # connection refused
            return

        _reply(conn, 0x00)              # success
        pipe(conn, dest)
    except (OSError, ConnectionError):
        pass
    finally:
        for s in (conn, dest):
            if s:
                try:
                    s.close()
                except OSError:
                    pass


def main():
    if not USER or not PASS:
        log("COLDSPOT_USER / COLDSPOT_PASS not set — refusing to start without auth")
        sys.exit(1)
    if not (os.path.exists(CERT) and os.path.exists(KEY)):
        log(f"TLS cert/key missing ({CERT}, {KEY}) — run setup.sh")
        sys.exit(1)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(128)
    log(f"ColdSpot exit listening on :{PORT} (SOCKS5 over TLS, user '{USER}')")

    while True:
        try:
            raw, addr = srv.accept()
        except OSError:
            continue
        # Wrap in TLS first; do the handshake inside the worker so a slow or
        # bogus client can't block accept().
        def worker(raw=raw, addr=addr):
            try:
                conn = ctx.wrap_socket(raw, server_side=True)
            except (ssl.SSLError, OSError):
                try:
                    raw.close()
                except OSError:
                    pass
                return
            handle(conn, addr)
        threading.Thread(target=worker, daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
