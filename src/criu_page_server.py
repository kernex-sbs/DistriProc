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

    if not hasattr(_FD, "label"):
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
        for entry in pm["entries"][1:]:
            vaddr = entry["vaddr"]
            nr_pages = entry.get("nr_pages", entry.get("compat_nr_pages", 1))

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


def handle_client(conn, addr, page_map, fd_cache):
    """Handle a single client connection with pipelined request support."""
    print(f"Connected by {addr}")
    try:
        while True:
            data = recv_exact(conn, 8)
            if data is None:
                break

            fault_addr = struct.unpack("Q", data)[0]
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
