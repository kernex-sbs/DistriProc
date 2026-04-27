#!/bin/bash
# Adaptive prefetch integration test
# REQUIRES_ROOT=true
#
# Tests that adaptive prefetch mode restores successfully and emits
# at least one policy decision while serving pages remotely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_loop"
LAZY_HANDLER="$ROOT_DIR/src/lazy_handler"
PAGE_SERVER="$ROOT_DIR/src/criu_page_server.py"
DUMP_DIR="/tmp/distriproc-test-adaptive-$$"
COUNTER_FILE="/tmp/distriproc-test-adaptive-counter-$$"
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

for p in 9989 9988 9987 9986; do
    if ! ss -tln | grep -q ":$p "; then
        PORT=$p
        break
    fi
done

setsid "$BINARY" --output "$COUNTER_FILE" > "$DUMP_DIR/loop.log" 2>&1 &
LOOP_PID=$!
echo "Started test_loop PID=$LOOP_PID"

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

echo "Running criu dump..."
if ! criu dump -t "$LOOP_PID" -D "$DUMP_DIR" -j -v4 --log-file dump.log 2>&1; then
    echo "FAIL: criu dump failed"
    tail -20 "$DUMP_DIR/dump.log" 2>/dev/null || true
    exit 1
fi
LOOP_PID=""

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

echo "Starting lazy_handler with adaptive prefetch..."
"$LAZY_HANDLER" --images-dir "$DUMP_DIR" --address 127.0.0.1 --port "$PORT" \
    --prefetch-seq 16 --prefetch-stride 8 --adaptive-prefetch \
    > "$DUMP_DIR/handler.log" 2>&1 &
HANDLER_PID=$!
sleep 1

if ! kill -0 "$HANDLER_PID" 2>/dev/null; then
    echo "FAIL: lazy_handler died"
    cat "$DUMP_DIR/handler.log" 2>/dev/null
    exit 1
fi

rm -f "$COUNTER_FILE"

echo "Running criu restore --lazy-pages..."
cd "$DUMP_DIR"
criu restore --lazy-pages -D "$DUMP_DIR" -j -v4 \
    --log-file restore.log -d --pidfile restore.pid 2>&1 || {
    echo "FAIL: criu restore --lazy-pages failed"
    tail -20 "$DUMP_DIR/restore.log" 2>/dev/null || true
    echo "--- handler log ---"
    tail -20 "$DUMP_DIR/handler.log" 2>/dev/null || true
    exit 1
}
cd "$ROOT_DIR"

echo "Waiting for restored process to resume counting..."
for i in $(seq 1 15); do
    if [ -f "$COUNTER_FILE" ]; then
        restored_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
        if [ "$restored_counter" -ge "$pre_dump_counter" ] 2>/dev/null; then
            echo "Restored counter: $restored_counter"
            break
        fi
    fi
    if [ "$i" -eq 15 ]; then
        echo "FAIL: restored process did not resume counting"
        tail -20 "$DUMP_DIR/handler.log" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

sleep 2

if [ -f "$DUMP_DIR/restore.pid" ]; then
    kill "$(cat "$DUMP_DIR/restore.pid")" 2>/dev/null || true
fi
sleep 2

echo "--- Handler log ---"
tail -20 "$DUMP_DIR/handler.log" 2>/dev/null || true

if ! grep -q "Policy:" "$DUMP_DIR/handler.log" 2>/dev/null; then
    echo "FAIL: adaptive mode emitted no policy decisions"
    exit 1
fi

echo "OK: Adaptive prefetch restore succeeded and emitted policy decisions"
