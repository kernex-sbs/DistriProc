#!/bin/bash
# DistriProc Test Runner
# Runs all tests/test_*.sh scripts, reports pass/fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

passed=0
failed=0
skipped=0

run_test() {
    local test_script="$1"
    local test_name
    test_name="$(basename "$test_script" .sh)"

    printf "${BOLD}%-40s${RESET}" "$test_name"

    # Check if test needs root
    if head -20 "$test_script" | grep -q "REQUIRES_ROOT=true"; then
        if [ "$(id -u)" -ne 0 ]; then
            printf "${YELLOW}SKIP${RESET} (needs root)\n"
            skipped=$((skipped + 1))
            return
        fi
    fi

    # Run test with timeout
    local output
    if output=$(bash "$test_script" 2>&1); then
        printf "${GREEN}PASS${RESET}\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${RESET}\n"
        echo "$output" | tail -5 | sed 's/^/    /'
        failed=$((failed + 1))
    fi
}

echo ""
echo "==============================="
echo " DistriProc Test Suite"
echo "==============================="
echo ""

# Build first
echo "Building..."
make -C "$ROOT_DIR" all > /dev/null 2>&1
echo ""

# Run all test scripts
for test_script in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$test_script" ] || continue
    run_test "$test_script"
done

echo ""
echo "-------------------------------"
printf "Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}\n" \
    "$passed" "$failed" "$skipped"
echo "-------------------------------"
echo ""

[ "$failed" -eq 0 ]
