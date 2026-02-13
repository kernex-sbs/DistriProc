#!/bin/bash
# eval/workloads/test_loop.sh — test_loop workload for benchmarks
# Sourced by bench.sh. Implements the standard workload interface.

BINARY="$ROOT_DIR/src/test_loop"
_COUNTER_FILE=""
_LOOP_PID=""

workload_name() {
    echo "test_loop"
}

workload_setup() {
    if [ ! -x "$BINARY" ]; then
        log_error "test_loop binary not found at $BINARY"
        return 1
    fi
    return 0
}

workload_start() {
    local work_dir="$1"
    _COUNTER_FILE="$work_dir/counter"
    rm -f "$_COUNTER_FILE"
    setsid "$BINARY" --output "$_COUNTER_FILE" > "$work_dir/workload.log" 2>&1 &
    _LOOP_PID=$!
    track_pid "$_LOOP_PID"
    WORKLOAD_PID="$_LOOP_PID"
}

workload_warmup() {
    wait_for_counter "$_COUNTER_FILE" 3 15
}

workload_profile() {
    local work_dir="$1"
    HOT_PAGES_FILE="$work_dir/hot_pages.bin"
    python3 "$HOT_PAGES" --pid "$WORKLOAD_PID" --output "$HOT_PAGES_FILE" \
        --samples 3 --interval 1
}

workload_ttfr_probe() {
    local work_dir="$1"
    local counter_file="$_COUNTER_FILE"
    # TTFR = time from RESTORE_T_START until counter file reappears with a numeric value
    rm -f "$counter_file"
    local deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$counter_file" ]; then
            local val
            val=$(cat "$counter_file" 2>/dev/null || echo "")
            if [ -n "$val" ] && [ "$val" -ge 0 ] 2>/dev/null; then
                TTFR_MS=$(( $(time_ms) - RESTORE_T_START ))
                return 0
            fi
        fi
        sleep 0.01
    done
    log_error "TTFR probe timed out for test_loop"
    TTFR_MS=-1
    return 1
}

workload_throughput() {
    # test_loop runs at ~1 op/sec (fixed by sleep(1)), not a meaningful metric
    THROUGHPUT="1"
}

workload_cleanup() {
    if [ -n "$_LOOP_PID" ]; then
        kill "$_LOOP_PID" 2>/dev/null || true
        _LOOP_PID=""
    fi
    rm -f "$_COUNTER_FILE"
}
