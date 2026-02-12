#!/bin/bash
# Phase 1 regression test: basic userfaultfd page fault handling
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$ROOT_DIR/src/test_uffd"

if [ ! -x "$BINARY" ]; then
    echo "FAIL: $BINARY not found or not executable"
    exit 1
fi

output=$(timeout 5 "$BINARY" 2>&1) || {
    echo "FAIL: test_uffd timed out or crashed"
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

check_output "Handler ready"
check_output "Page served"
check_output "Write successful"

if [ "$errors" -gt 0 ]; then
    echo "Output was:"
    echo "$output"
    exit 1
fi

echo "OK: userfaultfd local page handling works"
