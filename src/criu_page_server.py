#!/usr/bin/env python3
"""CRIU image-aware TCP page server.

Reads CRIU dump images (pagemap-*.img, pages-*.img) and serves pages
over TCP using the same protocol as page_server.py:
  - Request:  8 bytes (uint64 virtual address)
  - Response: 4096 bytes (page data, or zeros if not in pagemap)

Supports pipelined requests (multiple 8-byte requests before reading
responses) and multiple concurrent clients via threading.

Usage:
    criu_page_server.py --images-dir DIR [--port PORT]
"""

import argparse
import bisect
import glob
import os
import socket
import struct
import sys
import threading

# protobuf 6.x removed FieldDescriptor.label, which pycriu 4.2's pb2dict.py
# still relies on (field.label == FD.LABEL_REPEATED). Restore it as a
# compatibility shim before importing pycriu so image parsing works on
# current protobuf. The new API exposes the same information via is_repeated.
try:
    from google.protobuf.descriptor import FieldDescriptor as _FD

    # Old protobuf (e.g. Debian's 3.21) also lacks a class-level `label`: it
    # assigns it per instance in __init__, which a read-only property breaks.
    # Only new protobuf has is_repeated, so gate on that.
    if not hasattr(_FD, "label") and hasattr(_FD, "is_repeated"):
        def _compat_label(self):
            if getattr(self, "is_repeated", False):
                return _FD.LABEL_REPEATED
            if getattr(self, "is_required", False):
                return _FD.LABEL_REQUIRED
            return _FD.LABEL_OPTIONAL

        _FD.label = property(_compat_label)
except Exception:
    pass

from pycriu import images as criu_images

PAGE_SIZE = 4096


def _varint(buf, i):
    v = shift = 0
    while True:
        b = buf[i]
        i += 1
        v |= (b & 0x7F) << shift
        shift += 7
        if b < 0x80:
            return v, i


def raw_image_varints(path):
    """Varint fields of each entry of a CRIU image, decoded by hand.

    CRIU >= 4.2 writes pagemap_entry.nr_pages as field 5 and leaves the old
    field 2 (compat_nr_pages) 0; pycriu < 4.2 drops field 5, so every entry
    looks empty. Layout: 8 magic bytes, then (u32 len, protobuf msg)*.
    """
    data = open(path, "rb").read()
    out, i = [], 8
    while i < len(data):
        (n,) = struct.unpack_from("<I", data, i)
        msg, i = data[i + 4:i + 4 + n], i + 4 + n
        fields, j = {}, 0
        while j < len(msg):
            key, j = _varint(msg, j)
            wt = key & 7
            if wt == 0:
                fields[key >> 3], j = _varint(msg, j)
            elif wt == 2:
                ln, j = _varint(msg, j)
                j += ln
            else:
                j += 8 if wt == 1 else 4
        out.append(fields)
    return out


def build_page_map(images_dir):
    """Parse pagemap-*.img files and build vaddr -> (pages_file, file_offset) map.

    CRIU pagemap format:
    - Header: pagemap_head with pages_id (identifies which pages-N.img to read)
    - Entries: sequential pagemap_entry with vaddr + nr_pages
    - Pages are stored sequentially in pages-N.img in the same order as entries
    """
    page_map = {}  # vaddr -> (pages_file_path, file_offset)

    pagemap_files = sorted(glob.glob(os.path.join(images_dir, "pagemap-*.img")))
    if not pagemap_files:
        print(f"ERROR: No pagemap-*.img files found in {images_dir}", file=sys.stderr)
        sys.exit(1)

    for pmf in pagemap_files:
        with open(pmf, "rb") as f:
            pm = criu_images.load(f)

        pages_id = pm["entries"][0]["pages_id"]
        pages_path = os.path.join(images_dir, f"pages-{pages_id}.img")

        if not os.path.exists(pages_path):
            print(f"WARNING: {pages_path} not found, skipping", file=sys.stderr)
            continue

        # Walk entries (skip first entry which is the header)
        file_offset = 0
        raw = None
        for k, entry in enumerate(pm["entries"][1:], 1):
            vaddr = entry["vaddr"]
            nr_pages = entry.get("nr_pages", entry.get("compat_nr_pages", 1))
            if nr_pages == 0:  # old pycriu on a CRIU >= 4.2 image
                raw = raw or raw_image_varints(pmf)
                nr_pages = raw[k].get(5, 0)

            # If pages are in parent image, skip (no data in this pages file)
            if entry.get("in_parent", False):
                continue

            for p in range(nr_pages):
                addr = vaddr + p * PAGE_SIZE
                page_map[addr] = (pages_path, file_offset)
                file_offset += PAGE_SIZE

        print(f"Loaded {pmf}: pages_id={pages_id}, {len(page_map)} pages mapped")

    return page_map


def recv_exact(conn, n):
    """Receive exactly n bytes from conn, looping until complete."""
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


STREAM_MAGIC = 0xFFFFFFFFFFFFFFFF  # never a user page address
STREAM_ALL_MAGIC = STREAM_MAGIC - 1  # same, then every other image page
STREAM_CHUNK = 256                   # pages per sendall
SO_MAX_PACING_RATE = getattr(socket, "SO_MAX_PACING_RATE", 47)  # Linux


def read_page(page_map, fd_cache, page_addr):
    if page_addr not in page_map:
        return b"\x00" * PAGE_SIZE
    pages_path, offset = page_map[page_addr]
    if pages_path not in fd_cache:
        fd_cache[pages_path] = open(pages_path, "rb")
    return os.pread(fd_cache[pages_path].fileno(), PAGE_SIZE, offset).ljust(PAGE_SIZE, b"\x00")


def rest_by_proximity(page_map, addrs):
    """Image pages not in addrs, nearest to a listed page first: a heap
    region the trace missed sits next to traced heap pages."""
    listed = sorted(set(addrs))
    def dist(p):
        i = bisect.bisect_left(listed, p)
        return min(abs(p - listed[j]) for j in (i - 1, i) if 0 <= j < len(listed))
    seen = set(listed)
    return sorted((p for p in page_map if p not in seen), key=dist) if listed else sorted(page_map)


def send_pages(conn, page_map, fd_cache, addrs):
    for i in range(0, len(addrs), STREAM_CHUNK):
        conn.sendall(b"".join(read_page(page_map, fd_cache, a & ~(PAGE_SIZE - 1))
                              for a in addrs[i:i + STREAM_CHUNK]))


def stream_pages(conn, page_map, fd_cache, rest):
    """Server push: after STREAM_MAGIC the client sends u64 count and count
    addresses; reply with the pages back to back, in that order. With rest
    (STREAM_ALL_MAGIC), follow with u64 m, m addresses, and their pages."""
    # DISTRIPROC_STREAM_CC (e.g. vegas, lp, bbr): congestion control for the
    # stream only, so it keeps the bottleneck queue short for demand replies.
    cc = os.environ.get("DISTRIPROC_STREAM_CC")
    if cc:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, cc.encode())
        print(f"stream congestion control: {cc}", flush=True)
    (count,) = struct.unpack("Q", recv_exact(conn, 8))
    addrs = struct.unpack(f"{count}Q", recv_exact(conn, 8 * count))
    order = []
    t = threading.Thread(target=lambda: order.extend(rest_by_proximity(page_map, addrs)))
    if rest:
        t.start()  # ponytail: overlaps the trace send; GIL makes it ~60 ms of contention
    send_pages(conn, page_map, fd_cache, addrs)
    if rest:
        # DISTRIPROC_STREAM_PACE=f: pace the rest at f x the delivery rate the
        # trace phase measured, so it never builds a queue at the bottleneck
        # and demand replies pass at ~1 RTT.
        pace = float(os.environ.get("DISTRIPROC_STREAM_PACE", "0"))
        if pace > 0:
            info = conn.getsockopt(socket.IPPROTO_TCP, socket.TCP_INFO, 232)
            (rate,) = struct.unpack_from("Q", info, 160)  # tcpi_delivery_rate, B/s
            conn.setsockopt(socket.SOL_SOCKET, SO_MAX_PACING_RATE, int(rate * pace))
            print(f"rest paced at {rate * pace * 8 / 1e6:.0f} Mbit/s "
                  f"({pace} x delivery {rate * 8 / 1e6:.0f})", flush=True)
        t.join()
        conn.sendall(struct.pack(f"Q{len(order)}Q", len(order), *order))
        send_pages(conn, page_map, fd_cache, order)


def handle_client(conn, addr, page_map, fd_cache):
    """Handle a single client connection with pipelined request support."""
    print(f"Connected by {addr}")
    try:
        while True:
            data = recv_exact(conn, 8)
            if data is None:
                break

            fault_addr = struct.unpack("Q", data)[0]
            if fault_addr in (STREAM_MAGIC, STREAM_ALL_MAGIC):
                stream_pages(conn, page_map, fd_cache, fault_addr == STREAM_ALL_MAGIC)
                continue
            # Align to page boundary
            page_addr = fault_addr & ~(PAGE_SIZE - 1)

            if page_addr in page_map:
                pages_path, offset = page_map[page_addr]
                # Use cached file handle
                if pages_path not in fd_cache:
                    fd_cache[pages_path] = open(pages_path, "rb")
                pf = fd_cache[pages_path]
                pf.seek(offset)
                page_data = pf.read(PAGE_SIZE)
                if len(page_data) != PAGE_SIZE:
                    print(f"WARNING: Short read for {page_addr:#x}: {len(page_data)} bytes")
                    page_data = page_data.ljust(PAGE_SIZE, b"\x00")
            else:
                page_data = b"\x00" * PAGE_SIZE

            conn.sendall(page_data)

    except ConnectionResetError:
        print(f"Connection reset by {addr}")
    except BrokenPipeError:
        print(f"Broken pipe from {addr}")
    finally:
        conn.close()
        # Close cached file handles for this client thread
        for fh in fd_cache.values():
            fh.close()
        print(f"Connection closed from {addr}")


def main():
    parser = argparse.ArgumentParser(description="CRIU image-aware TCP page server")
    parser.add_argument("--images-dir", required=True, help="CRIU images directory")
    parser.add_argument("--port", type=int, default=9999, help="TCP port (default: 9999)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    args = parser.parse_args()

    if not os.path.isdir(args.images_dir):
        print(f"ERROR: {args.images_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    page_map = build_page_map(args.images_dir)
    print(f"Total pages indexed: {len(page_map)}")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((args.host, args.port))
        s.listen()
        print(f"Page server listening on {args.host}:{args.port}")

        while True:
            conn, addr = s.accept()
            # A 4 KB page is sub-MSS on loopback (and its tail is on a real
            # NIC), so Nagle holds pipelined responses for the client's
            # delayed ACK: ~41 ms per batch. DISTRIPROC_TCP_NODELAY=0 restores
            # the original transport.
            nodelay = os.environ.get("DISTRIPROC_TCP_NODELAY", "1") != "0"
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, int(nodelay))
            # Each client in its own thread (needed for eager fetch + fault handler)
            fd_cache = {}  # per-thread file handle cache
            t = threading.Thread(
                target=handle_client,
                args=(conn, addr, page_map, fd_cache),
                daemon=True,
            )
            t.start()


if __name__ == "__main__":
    main()
