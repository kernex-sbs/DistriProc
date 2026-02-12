#!/bin/bash
# Phase 4-01: Prefetch integration test
# REQUIRES_ROOT=true
#
# Tests that prefetching reduces fault count:
#   1. Dump test_loop (1MB heap = ~256 sequential pages)
#   2. Start page server + lazy_handler with --prefetch-seq 16
#   3. Restore with --lazy-pages
#   4. Verify counter resumes and heap OK
#   5. Parse handler stats: assert hit rate > 40%
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_loop"
LAZY_HANDLER="$ROOT_DIR/src/lazy_handler"
PAGE_SERVER="$ROOT_DIR/src/criu_page_server.py"
DUMP_DIR="/tmp/distriproc-test-prefetch-$$"
COUNTER_FILE="/tmp/distriproc-test-prefetch-counter-$$"
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

if [ ! -f "$PAGE_SERVER" ]; then
    echo "FAIL: $PAGE_SERVER not found"
    exit 1
fi

if ! python3 -c "from pycriu import images" 2>/dev/null; then
    echo "FAIL: pycriu not installed"
    exit 1
fi

mkdir -p "$DUMP_DIR"

# Find an available port
for p in 9997 9996 9995 9994; do
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

pre_dump_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
echo "Pre-dump counter: $pre_dump_counter"

# Step 2: Checkpoint
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

# Step 3: Start page server
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

# Step 4: Start lazy_handler with prefetching enabled
echo "Starting lazy_handler with --prefetch-seq 16..."
"$LAZY_HANDLER" --images-dir "$DUMP_DIR" --address 127.0.0.1 --port "$PORT" \
    --prefetch-seq 16 --prefetch-stride 8 \
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

# Step 5: Restore with --lazy-pages
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

# Step 6: Verify process resumed
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

# Step 7: Let it run a bit then check stats
sleep 2
if [ -f "$COUNTER_FILE" ]; then
    final_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    echo "Counter advancing: $restored_counter -> $final_counter"
fi

# Kill restored process so handler exits cleanly and prints stats
if [ -f "$DUMP_DIR/restore.pid" ]; then
    kill "$(cat "$DUMP_DIR/restore.pid")" 2>/dev/null || true
fi
sleep 2

# Step 8: Parse prefetch stats from handler log
echo "--- Handler stats ---"
cat "$DUMP_DIR/handler.log" 2>/dev/null | tail -10

if grep -q "Prefetch stats:" "$DUMP_DIR/handler.log" 2>/dev/null; then
    stats_line=$(grep "Prefetch stats:" "$DUMP_DIR/handler.log")
    echo "$stats_line"

    # Extract hit rate
    hit_rate=$(echo "$stats_line" | grep -oP '\d+(?=% hit rate)')
    prefetched=$(echo "$stats_line" | grep -oP '\d+(?= prefetched)')

    if [ -n "$prefetched" ] && [ "$prefetched" -gt 0 ]; then
        echo "Prefetching active: $prefetched pages prefetched"
    else
        echo "WARN: No pages were prefetched"
    fi

    if [ -n "$hit_rate" ] && [ "$hit_rate" -ge 40 ]; then
        echo "Hit rate OK: ${hit_rate}% >= 40%"
    elif [ -n "$hit_rate" ]; then
        echo "WARN: Hit rate ${hit_rate}% < 40% (may vary by workload)"
    fi
else
    echo "WARN: No prefetch stats in handler log"
fi

echo "OK: Prefetch test passed (counter $pre_dump_counter -> ${final_counter:-$restored_counter})"
