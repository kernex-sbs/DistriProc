#!/usr/bin/env python3
"""Hot page profiler — identifies frequently accessed pages via /proc/PID/smaps.

Algorithm:
  1. Clear accessed bits: echo 4 > /proc/PID/clear_refs
  2. Sleep for interval seconds
  3. Parse smaps: if VMA has Referenced > 50% of size → all pages are "hot"
  4. Repeat for samples rounds; page is hot if hot in majority of samples

Output: Binary file of uint64_t page addresses (easy for C to parse).

Usage:
    hot_pages.py --pid PID --output FILE [--samples 3] [--interval 1]
"""

import argparse
import os
import struct
import sys
import time

PAGE_SIZE = 4096


def clear_refs(pid):
    """Clear accessed/referenced bits for all VMAs."""
    path = f"/proc/{pid}/clear_refs"
    try:
        with open(path, "w") as f:
            f.write("4\n")
    except PermissionError:
        print(f"ERROR: Cannot write to {path} (need root)", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print(f"ERROR: {path} not found (PID {pid} gone?)", file=sys.stderr)
        sys.exit(1)


def parse_smaps(pid):
    """Parse /proc/PID/smaps and return list of (start, end, referenced, size) for each VMA."""
    path = f"/proc/{pid}/smaps"
    vmas = []
    current_start = None
    current_end = None
    current_size = 0
    current_referenced = 0

    try:
        with open(path, "r") as f:
            for line in f:
                # VMA header line: "start-end perms offset dev inode pathname"
                if "-" in line and not line.startswith(" ") and len(line.split()) >= 5:
                    parts = line.split()
                    addr_range = parts[0]
                    if "-" in addr_range:
                        try:
                            start_s, end_s = addr_range.split("-", 1)
                            start = int(start_s, 16)
                            end = int(end_s, 16)
                            # Save previous VMA
                            if current_start is not None:
                                vmas.append((current_start, current_end,
                                             current_referenced, current_size))
                            current_start = start
                            current_end = end
                            current_size = 0
                            current_referenced = 0
                        except ValueError:
                            pass
                elif line.startswith("Size:"):
                    current_size = int(line.split()[1]) * 1024  # kB -> bytes
                elif line.startswith("Referenced:"):
                    current_referenced = int(line.split()[1]) * 1024

        # Don't forget the last VMA
        if current_start is not None:
            vmas.append((current_start, current_end, current_referenced, current_size))

    except FileNotFoundError:
        print(f"ERROR: {path} not found (PID {pid} gone?)", file=sys.stderr)
        sys.exit(1)

    return vmas


def get_hot_pages_from_sample(pid):
    """Return set of page addresses from VMAs where Referenced > 50% of Size."""
    vmas = parse_smaps(pid)
    hot_pages = set()

    for start, end, referenced, size in vmas:
        if size == 0:
            continue
        if referenced > size // 2:
            # All pages in this VMA are "hot"
            for addr in range(start, end, PAGE_SIZE):
                hot_pages.add(addr)

    return hot_pages


def main():
    parser = argparse.ArgumentParser(description="Hot page profiler via smaps")
    parser.add_argument("--pid", type=int, required=True, help="Target process PID")
    parser.add_argument("--output", required=True, help="Output binary file path")
    parser.add_argument("--samples", type=int, default=3, help="Number of sampling rounds (default: 3)")
    parser.add_argument("--interval", type=float, default=1.0, help="Seconds between samples (default: 1)")
    args = parser.parse_args()

    if not os.path.exists(f"/proc/{args.pid}"):
        print(f"ERROR: PID {args.pid} does not exist", file=sys.stderr)
        sys.exit(1)

    # Count how many times each page is hot across samples
    page_counts = {}  # addr -> count of samples where it was hot

    for sample_idx in range(args.samples):
        clear_refs(args.pid)
        time.sleep(args.interval)
        hot = get_hot_pages_from_sample(args.pid)
        print(f"Sample {sample_idx + 1}/{args.samples}: {len(hot)} hot pages")
        for addr in hot:
            page_counts[addr] = page_counts.get(addr, 0) + 1

    # Page is hot if hot in majority of samples
    threshold = args.samples // 2 + 1
    hot_pages = sorted(addr for addr, count in page_counts.items() if count >= threshold)

    print(f"Total hot pages (majority vote, >= {threshold}/{args.samples}): {len(hot_pages)}")

    # Write binary output: array of uint64_t
    with open(args.output, "wb") as f:
        for addr in hot_pages:
            f.write(struct.pack("Q", addr))

    print(f"Written {len(hot_pages)} hot page addresses to {args.output}")


if __name__ == "__main__":
    main()
