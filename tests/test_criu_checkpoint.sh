#!/bin/bash
# Phase 3: CRIU basic checkpoint/restore test
# REQUIRES_ROOT=true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_loop"
DUMP_DIR="/tmp/distriproc-test-checkpoint-$$"
COUNTER_FILE="/tmp/distriproc-test-counter-$$"
RESTORE_LOG="/tmp/distriproc-test-restore-$$.log"
LOOP_PID=""

cleanup() {
    [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null || true
    # Kill any restored process too
    if [ -f "$DUMP_DIR/restore.pid" ]; then
        kill "$(cat "$DUMP_DIR/restore.pid")" 2>/dev/null || true
    fi
    rm -rf "$DUMP_DIR" "$COUNTER_FILE" "$RESTORE_LOG"
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

# Start test_loop with counter output file
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

# Record counter before checkpoint
pre_dump_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
echo "Pre-dump counter: $pre_dump_counter"

# Checkpoint
echo "Running criu dump..."
if ! criu dump -t "$LOOP_PID" -D "$DUMP_DIR" -j -v4 --log-file dump.log 2>&1; then
    echo "FAIL: criu dump failed"
    cat "$DUMP_DIR/dump.log" 2>/dev/null | tail -20
    exit 1
fi
LOOP_PID=""  # Process is gone after dump
echo "Checkpoint succeeded"

# Verify dump images exist
if [ ! -f "$DUMP_DIR/core-"*.img ] 2>/dev/null; then
    echo "FAIL: no core image files in $DUMP_DIR"
    ls -la "$DUMP_DIR/"
    exit 1
fi
echo "Dump images present"

# Reset counter file so we can detect restore writes
rm -f "$COUNTER_FILE"

# Restore
echo "Running criu restore..."
cd "$DUMP_DIR"
criu restore -D "$DUMP_DIR" -j -v4 --log-file restore.log -d --pidfile restore.pid 2>&1 || {
    echo "FAIL: criu restore failed"
    cat "$DUMP_DIR/restore.log" 2>/dev/null | tail -20
    exit 1
}
cd "$ROOT_DIR"
echo "Restore succeeded"

# Wait for restored process to write a new counter value
echo "Waiting for restored process..."
for i in $(seq 1 10); do
    if [ -f "$COUNTER_FILE" ]; then
        restored_counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
        if [ "$restored_counter" -ge "$pre_dump_counter" ] 2>/dev/null; then
            echo "Restored counter: $restored_counter (was $pre_dump_counter before dump)"
            break
        fi
    fi
    if [ "$i" -eq 10 ]; then
        echo "FAIL: restored process did not resume counting"
        exit 1
    fi
    sleep 1
done

# Kill restored process
if [ -f "$DUMP_DIR/restore.pid" ]; then
    RESTORED_PID=$(cat "$DUMP_DIR/restore.pid")
    kill "$RESTORED_PID" 2>/dev/null || true
fi

echo "OK: CRIU checkpoint/restore works (counter $pre_dump_counter -> $restored_counter)"
