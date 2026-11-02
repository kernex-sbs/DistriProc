#!/usr/bin/env python3
"""Stream a CRIU image directory over TCP: the eager-over-network baseline.

  xfer_images.py serve DIR PORT       send DIR's files to one client, then exit
  xfer_images.py recv HOST PORT DIR   receive into DIR (created), then exit

Wire format per file: u16 name length, name, u64 size, bytes; a zero-length
name ends the stream. Logs (*.log) are skipped: restore needs only images.
"""
import os
import socket
import struct
import sys


def serve(src, port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(1)
    print("ready", flush=True)
    c, _ = s.accept()
    for name in sorted(os.listdir(src)):
        path = os.path.join(src, name)
        if name.endswith(".log") or not os.path.isfile(path):
            continue
        size = os.path.getsize(path)
        c.sendall(struct.pack("<H", len(name)) + name.encode() + struct.pack("<Q", size))
        with open(path, "rb") as f:
            sent = 0
            while sent < size:
                sent += os.sendfile(c.fileno(), f.fileno(), sent, size - sent)
    c.sendall(struct.pack("<H", 0))
    c.close()


def recv_exact(c, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = c.recv(min(n - len(buf), 1 << 20))
        if not chunk:
            raise EOFError("stream ended early")
        buf += chunk
    return bytes(buf)


def recv(host, port, dst):
    os.makedirs(dst, exist_ok=True)
    c = socket.create_connection((host, port))
    while True:
        (n,) = struct.unpack("<H", recv_exact(c, 2))
        if n == 0:
            break
        name = recv_exact(c, n).decode()
        if "/" in name or name in (".", ".."):
            raise ValueError(f"bad file name {name!r}")
        (size,) = struct.unpack("<Q", recv_exact(c, 8))
        with open(os.path.join(dst, name), "wb") as f:
            left = size
            while left:
                chunk = c.recv(min(left, 1 << 20))
                if not chunk:
                    raise EOFError("stream ended mid-file")
                f.write(chunk)
                left -= len(chunk)


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1] == "recv":
        recv(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    else:
        sys.exit(__doc__)
