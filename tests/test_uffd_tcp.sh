#!/bin/bash
# Phase 2 regression test: TCP remote page fetching
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_uffd_tcp"
SERVER="$ROOT_DIR/src/page_server.py"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ ! -x "$BINARY" ]; then
    echo "FAIL: $BINARY not found or not executable"
    exit 1
fi

if [ ! -f "$SERVER" ]; then
    echo "FAIL: $SERVER not found"
    exit 1
fi

# Start page server in background
python3 "$SERVER" &
SERVER_PID=$!
sleep 0.5

# Verify server started
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: page_server.py failed to start"
    exit 1
fi

output=$(timeout 10 "$BINARY" 2>&1) || {
    echo "FAIL: test_uffd_tcp timed out or crashed"
    echo "$output"
    exit 1
}

errors=0

check_output() {
    if ! echo "$output" | grep -q "$1"; then
        echo "FAIL: expected output to contain: $1"
        ((errors++))
    fi
}

check_output "Connected to page server"
check_output "Received 4096 bytes"

if [ "$errors" -gt 0 ]; then
    echo "Output was:"
    echo "$output"
    exit 1
fi

echo "OK: TCP remote page fetching works"
