#!/bin/bash
# Phase 4-02: Hot/cold eager fetch integration test
# REQUIRES_ROOT=true
#
# Tests the hot page profiler + eager fetch thread:
#   1. Start test_loop, run hot_pages.py to profile it
#   2. Verify hot_pages.bin is non-empty
#   3. Dump, start page server + lazy_handler with --hot-pages
#   4. Restore with --lazy-pages
#   5. Parse handler output: assert "Eager fetch: installed N hot pages" with N > 0
#   6. Verify counter resumes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_loop"
LAZY_HANDLER="$ROOT_DIR/src/lazy_handler"
PAGE_SERVER="$ROOT_DIR/src/criu_page_server.py"
HOT_PAGES_SCRIPT="$ROOT_DIR/src/hot_pages.py"
DUMP_DIR="/tmp/distriproc-test-hotcold-$$"
COUNTER_FILE="/tmp/distriproc-test-hotcold-counter-$$"
HOT_PAGES_BIN="$DUMP_DIR/hot_pages.bin"
LOOP_PID=""
PAGE_SERVER_PID=""
HANDLER_PID=""
PORT=9999

cleanup() {
    [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null || true
    [ -n "$PAGE_SERVER_PID" ] && kill "$PAGE_SERVER_PID" 2>/dev/null || true
    [ -n "$HANDLER_PID" ] && kill "$HANDLER_PID" 2>/dev/null || true
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

for f in "$BINARY" "$LAZY_HANDLER"; do
    if [ ! -x "$f" ]; then
        echo "FAIL: $f not found or not executable"
        exit 1
    fi
done

for f in "$PAGE_SERVER" "$HOT_PAGES_SCRIPT"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f not found"
        exit 1
    fi
done

if ! python3 -c "from pycriu import images" 2>/dev/null; then
    echo "FAIL: pycriu not installed"
    exit 1
fi

mkdir -p "$DUMP_DIR"

# Find an available port
for p in 9993 9992 9991 9990; do
    if ! ss -tln | grep -q ":$p "; then
        PORT=$p
        break
    fi
done

# Step 1: Start test_loop
setsid "$BINARY" --output "$COUNTER_FILE" > "$DUMP_DIR/loop.log" 2>&1 &
LOOP_PID=$!
echo "Started test_loop PID=$LOOP_PID"

# Wait for counter >= 3
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
        exit 1
    fi
    sleep 1
done

# Step 2: Profile hot pages
echo "Profiling hot pages for PID=$LOOP_PID..."
python3 "$HOT_PAGES_SCRIPT" --pid "$LOOP_PID" --output "$HOT_PAGES_BIN" \
    --samples 2 --interval 1 > "$DUMP_DIR/profiler.log" 2>&1 || {
    echo "FAIL: hot_pages.py failed"
    cat "$DUMP_DIR/profiler.log" 2>/dev/null
    exit 1
}
cat "$DUMP_DIR/profiler.log"

# Verify hot_pages.bin is non-empty
if [ ! -s "$HOT_PAGES_BIN" ]; then
    echo "FAIL: hot_pages.bin is empty"
    exit 1
fi
hot_count=$(($(stat -c%s "$HOT_PAGES_BIN") / 8))
echo "Hot pages file: $hot_count addresses"

pre_dump_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
echo "Pre-dump counter: $pre_dump_counter"

# Step 3: Checkpoint
echo "Running criu dump..."
if ! criu dump -t "$LOOP_PID" -D "$DUMP_DIR" -j -v4 --log-file dump.log 2>&1; then
    echo "FAIL: criu dump failed"
    cat "$DUMP_DIR/dump.log" 2>/dev/null | tail -20
    exit 1
fi
LOOP_PID=""
echo "Checkpoint succeeded"

if ! ls "$DUMP_DIR"/pagemap-*.img &>/dev/null; then
    echo "FAIL: no pagemap images in $DUMP_DIR"
    exit 1
fi

# Step 4: Start page server
echo "Starting criu_page_server.py on port $PORT..."
python3 "$PAGE_SERVER" --images-dir "$DUMP_DIR" --port "$PORT" \
    > "$DUMP_DIR/page_server.log" 2>&1 &
PAGE_SERVER_PID=$!
sleep 1

if ! kill -0 "$PAGE_SERVER_PID" 2>/dev/null; then
    echo "FAIL: criu_page_server.py died"
    cat "$DUMP_DIR/page_server.log" 2>/dev/null
    exit 1
fi
echo "Page server running PID=$PAGE_SERVER_PID"

# Step 5: Start lazy_handler with hot pages
echo "Starting lazy_handler with --hot-pages..."
"$LAZY_HANDLER" --images-dir "$DUMP_DIR" --address 127.0.0.1 --port "$PORT" \
    --hot-pages "$HOT_PAGES_BIN" \
    > "$DUMP_DIR/handler.log" 2>&1 &
HANDLER_PID=$!
sleep 1

if ! kill -0 "$HANDLER_PID" 2>/dev/null; then
    echo "FAIL: lazy_handler died"
    cat "$DUMP_DIR/handler.log" 2>/dev/null
    exit 1
fi
echo "Lazy handler running PID=$HANDLER_PID"

# Reset counter file
rm -f "$COUNTER_FILE"

# Step 6: Restore with --lazy-pages
echo "Running criu restore --lazy-pages..."
cd "$DUMP_DIR"
criu restore --lazy-pages -D "$DUMP_DIR" -j -v4 \
    --log-file restore.log -d --pidfile restore.pid 2>&1 || {
    echo "FAIL: criu restore --lazy-pages failed"
    cat "$DUMP_DIR/restore.log" 2>/dev/null | tail -20
    echo "--- handler log ---"
    cat "$DUMP_DIR/handler.log" 2>/dev/null | tail -20
    exit 1
}
cd "$ROOT_DIR"
echo "Lazy restore succeeded"

# Step 7: Verify process resumed
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
        cat "$DUMP_DIR/handler.log" 2>/dev/null | tail -20
        exit 1
    fi
    sleep 1
done

# Let it run a bit
sleep 2
if [ -f "$COUNTER_FILE" ]; then
    final_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    echo "Counter advancing: $restored_counter -> $final_counter"
fi

# Kill restored process so handler exits and prints stats
if [ -f "$DUMP_DIR/restore.pid" ]; then
    kill "$(cat "$DUMP_DIR/restore.pid")" 2>/dev/null || true
fi
sleep 2

# Step 8: Check eager fetch output
echo "--- Handler log ---"
cat "$DUMP_DIR/handler.log" 2>/dev/null | tail -15

if grep -q "Eager fetch: installed" "$DUMP_DIR/handler.log" 2>/dev/null; then
    eager_line=$(grep "Eager fetch: installed" "$DUMP_DIR/handler.log")
    echo "$eager_line"
    eager_count=$(echo "$eager_line" | grep -oP '\d+(?= hot pages)')
    if [ -n "$eager_count" ] && [ "$eager_count" -gt 0 ]; then
        echo "Eager fetch OK: $eager_count hot pages installed"
    else
        echo "FAIL: Eager fetch installed 0 hot pages"
        exit 1
    fi
else
    echo "FAIL: No 'Eager fetch: installed' line in handler log"
    exit 1
fi

echo "OK: Hot/cold eager fetch test passed (counter $pre_dump_counter -> ${final_counter:-$restored_counter})"
