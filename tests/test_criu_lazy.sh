#!/bin/bash
# Phase 3: CRIU lazy-pages end-to-end test
# REQUIRES_ROOT=true
#
# Correct CRIU lazy-pages workflow (local):
#   1. criu dump -t PID -D DIR           (normal checkpoint, pages saved to images)
#   2. criu lazy-pages -D DIR            (daemon that serves pages on demand via uffd)
#   3. criu restore --lazy-pages -D DIR  (restore, fetching pages lazily from daemon)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_loop"
DUMP_DIR="/tmp/distriproc-test-lazy-$$"
COUNTER_FILE="/tmp/distriproc-test-lazy-counter-$$"
LOOP_PID=""
LAZY_PID=""

cleanup() {
    [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null || true
    [ -n "$LAZY_PID" ] && kill "$LAZY_PID" 2>/dev/null || true
    # Kill restored process
    if [ -f "$DUMP_DIR/restore.pid" ]; then
        kill "$(cat "$DUMP_DIR/restore.pid")" 2>/dev/null || true
    fi
    rm -rf "$DUMP_DIR" "$COUNTER_FILE"
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "SKIP: requires root"
    exit 0
fi

if ! command -v criu &>/dev/null; then
    echo "FAIL: criu not found in PATH"
    exit 1
fi

if [ ! -x "$BINARY" ]; then
    echo "FAIL: $BINARY not found or not executable"
    exit 1
fi

mkdir -p "$DUMP_DIR"

# Start test_loop
setsid "$BINARY" --output "$COUNTER_FILE" > "$DUMP_DIR/loop.log" 2>&1 &
LOOP_PID=$!
echo "Started test_loop PID=$LOOP_PID"

# Wait for counter to reach at least 3
echo "Waiting for counter >= 3..."
for i in $(seq 1 15); do
    if [ -f "$COUNTER_FILE" ]; then
        counter_val=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
        if [ "$counter_val" -ge 3 ] 2>/dev/null; then
            echo "Counter reached $counter_val"
            break
        fi
    fi
    if [ "$i" -eq 15 ]; then
        echo "FAIL: counter did not reach 3 in time"
        cat "$DUMP_DIR/loop.log" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

pre_dump_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
echo "Pre-dump counter: $pre_dump_counter"

# Step 1: Normal checkpoint (pages saved to image files)
echo "Running criu dump..."
if ! criu dump -t "$LOOP_PID" -D "$DUMP_DIR" -j -v4 --log-file dump.log 2>&1; then
    echo "FAIL: criu dump failed"
    cat "$DUMP_DIR/dump.log" 2>/dev/null | tail -20
    exit 1
fi
LOOP_PID=""
echo "Checkpoint succeeded"

# Step 2: Start lazy-pages daemon (serves pages on demand from images)
echo "Starting criu lazy-pages daemon..."
criu lazy-pages -D "$DUMP_DIR" -v4 --log-file lazy-pages.log &
LAZY_PID=$!
sleep 1

if ! kill -0 "$LAZY_PID" 2>/dev/null; then
    echo "FAIL: criu lazy-pages daemon died"
    cat "$DUMP_DIR/lazy-pages.log" 2>/dev/null | tail -20
    exit 1
fi
echo "Lazy-pages daemon running PID=$LAZY_PID"

# Reset counter file
rm -f "$COUNTER_FILE"

# Step 3: Restore with lazy-pages (pages fetched on demand via userfaultfd)
echo "Running criu restore with --lazy-pages..."
cd "$DUMP_DIR"
criu restore --lazy-pages -D "$DUMP_DIR" -j -v4 \
    --log-file restore.log -d --pidfile restore.pid 2>&1 || {
    echo "FAIL: criu restore --lazy-pages failed"
    cat "$DUMP_DIR/restore.log" 2>/dev/null | tail -20
    exit 1
}
cd "$ROOT_DIR"
echo "Lazy restore succeeded"

# Wait for restored process to resume
echo "Waiting for restored process to resume counting..."
for i in $(seq 1 15); do
    if [ -f "$COUNTER_FILE" ]; then
        restored_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
        if [ "$restored_counter" -ge "$pre_dump_counter" ] 2>/dev/null; then
            echo "Restored counter: $restored_counter (was $pre_dump_counter before dump)"
            break
        fi
    fi
    if [ "$i" -eq 15 ]; then
        echo "FAIL: restored process did not resume counting"
        cat "$DUMP_DIR/restore.log" 2>/dev/null | tail -20
        exit 1
    fi
    sleep 1
done

# Verify counter is still advancing (process is alive and fetching pages)
sleep 2
if [ -f "$COUNTER_FILE" ]; then
    final_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if [ "$final_counter" -gt "$restored_counter" ]; then
        echo "Counter advancing: $restored_counter -> $final_counter"
    else
        echo "WARN: counter not advancing ($final_counter)"
    fi
fi

echo "OK: CRIU lazy-pages end-to-end works (counter $pre_dump_counter -> ${final_counter:-$restored_counter})"
