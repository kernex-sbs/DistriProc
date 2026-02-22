#!/usr/bin/env python3
"""CRIU image-aware TCP page server.

Reads CRIU dump images (pagemap-*.img, pages-*.img) and serves pages
over TCP using the same protocol as page_server.py:
  - Request:  8 bytes (uint64 virtual address)
  - Response: 4096 bytes (page data, or zeros if not in pagemap)

Supports pipelined requests (multiple 8-byte requests before reading
responses) and multiple concurrent clients via asyncio.

Usage:
    criu_page_server.py --images-dir DIR [--port PORT]
"""

import argparse
import glob
import os
import struct
import sys
import asyncio

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

async def handle_client(reader, writer, page_map):
    addr = writer.get_extra_info('peername')
    print(f"Connected by {addr}")
    
    response_queue = asyncio.Queue()
    fd_cache = {}

    async def write_loop():
        try:
            while True:
                response = await response_queue.get()
                if response is None:
                    break
                writer.write(response)
                await writer.drain()
        except ConnectionError:
            pass

    writer_task = asyncio.create_task(write_loop())

    try:
        while True:
            try:
                data = await reader.readexactly(8)
            except asyncio.IncompleteReadError:
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

            await response_queue.put(page_data)

    except ConnectionResetError:
        print(f"Connection reset by {addr}")
    except Exception as e:
        print(f"Error serving {addr}: {e}")
    finally:
        await response_queue.put(None)
        await writer_task
        writer.close()
        await writer.wait_closed()
        for fh in fd_cache.values():
            fh.close()
        print(f"Connection closed from {addr}")

async def main_server(images_dir, host, port):
    page_map = build_page_map(images_dir)
    print(f"Total pages indexed: {len(page_map)}")

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, page_map),
        host, port
    )

    addrs = ', '.join(str(sock.getsockname()) for sock in server.sockets)
    print(f"Page server listening on {addrs}")

    async with server:
        await server.serve_forever()

def main():
    parser = argparse.ArgumentParser(description="CRIU image-aware TCP page server")
    parser.add_argument("--images-dir", required=True, help="CRIU images directory")
    parser.add_argument("--port", type=int, default=9999, help="TCP port (default: 9999)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    args = parser.parse_args()

    if not os.path.isdir(args.images_dir):
        print(f"ERROR: {args.images_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    try:
        asyncio.run(main_server(args.images_dir, args.host, args.port))
    except KeyboardInterrupt:
        print("\nServer shutting down.")


if __name__ == "__main__":
    main()
