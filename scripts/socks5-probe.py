#!/usr/bin/env python3
"""Multi-port TCP probe through the tailnet SOCKS5 relay (userspace networking).

Usage: socks5-probe.py <peer-ip> [port ...]
Default ports: 22 6800 80 443. Relay override via SOCKS5_PROXY env
(default 127.0.0.1:1055 -- tailscaled --socks5-server on this box).

Output per port: OPEN <secs> | code=<N> <secs> | TIMEOUT <secs>
  code 0 = open; code 1 = refused (closed port / dead host);
  timeout = filtered/unreachable. Fast code-1 on a reachable peer = closed port.

ALWAYS probe a known-good peer (repl-test) first as control: control opens and the
suspect refuses everything -> the local relay is fine and the suspect's host is
dead; both fail identically -> the break is on this box, not the peer.
"""
import os, socket, struct, sys, time

_SOCKS = os.environ.get('SOCKS5_PROXY', '127.0.0.1:1055')
_SHOST, _SPORT = _SOCKS.rsplit(':', 1)
_SPORT = int(_SPORT)


def probe(host, port, timeout=2.0):
    s = socket.socket()
    s.settimeout(timeout)
    t0 = time.time()
    try:
        s.connect((_SHOST, _SPORT))
        s.sendall(b'\x05\x01\x00')  # SOCKS5, no auth
        if s.recv(2) != b'\x05\x00':
            return 'noauth-fail'
        s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton(host) + struct.pack('>H', port))
        r = s.recv(2)
        code = r[1] if len(r) == 2 else 'short'
        dt = time.time() - t0
        return ('OPEN %.2fs' % dt) if code == 0 else ('code=%s %.2fs' % (code, dt))
    except Exception as e:
        return 'TIMEOUT %.2fs (%s)' % (time.time() - t0, e)
    finally:
        s.close()


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    host = sys.argv[1]
    ports = [int(p) for p in sys.argv[2:]] or [22, 6800, 80, 443]
    for p in ports:
        print('%-16s :%-5d %s' % (host, p, probe(host, p)))
