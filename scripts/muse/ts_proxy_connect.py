#!/usr/bin/env python3
"""ProxyCommand helper: CONNECT through the runtime tunnel proxy (port 3130).

Usage: ts_proxy_connect.py <host> <port>
Reads HTTPS_PROXY from the environment, swaps its port to 3130, issues an
HTTP CONNECT for host:port, then shuttles bytes between the tunnel socket
and stdin/stdout (the ssh ProxyCommand contract).
"""
import base64
import os
import select
import socket
import sys
from urllib.parse import urlparse


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    proxy = urlparse(os.environ["HTTPS_PROXY"])
    tunnel = f"{proxy.scheme}://{proxy.hostname}:3130"
    p = urlparse(tunnel)
    auth = ""
    if proxy.username:
        creds = proxy.username + ((":" + proxy.password) if proxy.password else "")
        auth = "Proxy-Authorization: Basic " + base64.b64encode(creds.encode()).decode() + "\r\n"
    s = socket.create_connection((p.hostname, 3130), timeout=30)
    target = f"{host}:{port}"
    s.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n{auth}\r\n".encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            sys.stderr.write(f"proxy closed before CONNECT reply for {target}\n")
            return 1
        resp += chunk
    status = resp.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 200 " not in status:
        sys.stderr.write(f"CONNECT {target} -> {status}\n")
        return 1
    # Any bytes after the header belong to the tunnel stream.
    head, _, rest = resp.partition(b"\r\n\r\n")
    s.setblocking(False)
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    fds = [s, stdin]
    pending = rest
    while True:
        if pending:
            stdout.write(pending)
            stdout.flush()
            pending = b""
        r, _, _ = select.select(fds, [], [], 60)
        if not r:
            return 0
        for fd in r:
            if fd is s:
                data = s.recv(65536)
                if not data:
                    return 0
                stdout.write(data)
                stdout.flush()
            else:
                data = stdin.read1(65536) if hasattr(stdin, "read1") else stdin.read(65536)
                if not data:
                    try:
                        s.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    fds.remove(stdin)
                else:
                    s.sendall(data)


if __name__ == "__main__":
    sys.exit(main())
