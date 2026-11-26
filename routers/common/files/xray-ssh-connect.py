#!/usr/bin/env python3
"""SSH ProxyCommand carrying the VPS control plane over the router's Xray tunnel.

The router's external SSH sessions can be throttled or penalised (OpenSSH
PerSourcePenalties, ISP session policies). The existing Xray tunnel already
reaches the VPS's localhost, so control/inspection sessions reuse it instead
of opening another external SSH connection. The target host/port argv is
ignored: the VPS sshd is reached through its own loopback.
"""
import os
import select
import socket
import sys

PROXY_HOST = "127.0.0.1"
PROXY_PORT = 1083
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 22


def _relay(sock):
    out = sys.stdout.buffer
    in_fd = sys.stdin.buffer.fileno()
    while True:
        ready, _, _ = select.select([sock, in_fd], [], [])
        if sock in ready:
            data = sock.recv(65536)
            if not data:
                return
            out.write(data)
            out.flush()
        if in_fd in ready:
            data = os.read(in_fd, 65536)
            if not data:
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                # Drain the remaining VPS output, then let EOF close us.
                while True:
                    data = sock.recv(65536)
                    if not data:
                        return
                    out.write(data)
                    out.flush()
            else:
                sock.sendall(data)


def main():
    if len(sys.argv) < 3:
        return 2
    sock = socket.create_connection((PROXY_HOST, PROXY_PORT), 10)
    try:
        request = "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" % (
            TARGET_HOST, TARGET_PORT, TARGET_HOST, TARGET_PORT)
        sock.sendall(request.encode("ascii"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1)
            if not chunk:
                return 1
            head += chunk
        if not head.startswith(b"HTTP/1.1 200"):
            return 1
        _relay(sock)
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
