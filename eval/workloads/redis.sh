#!/bin/bash
# eval/workloads/redis.sh — Redis workload for benchmarks
# Sourced by bench.sh. Implements the standard workload interface.

_REDIS_PORT=""
_REDIS_PID=""
_REDIS_WORK_DIR=""
_REDIS_KEY_COUNT=10000
_REDIS_VALUE_SIZE=1024

workload_name() {
    echo "redis"
}

workload_setup() {
    if ! command -v redis-server &>/dev/null; then
        log_error "redis-server not found (install: sudo pacman -S redis)"
        return 1
    fi
    if ! command -v redis-cli &>/dev/null; then
        log_error "redis-cli not found"
        return 1
    fi
    if ! command -v redis-benchmark &>/dev/null; then
        log_error "redis-benchmark not found"
        return 1
    fi
    return 0
}

workload_start() {
    local work_dir="$1"
    _REDIS_WORK_DIR="$work_dir"
    _REDIS_PORT=$(find_available_port 6399)

    setsid redis-server \
        --port "$_REDIS_PORT" \
        --save "" \
        --appendonly no \
        --daemonize no \
        --loglevel warning \
        --dir "$work_dir" \
        > "$work_dir/workload.log" 2>&1 &
    _REDIS_PID=$!
    track_pid "$_REDIS_PID"
    WORKLOAD_PID="$_REDIS_PID"
}

workload_warmup() {
    # Wait for PONG
    local deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if redis-cli -p "$_REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
            break
        fi
        sleep 0.1
    done

    if ! redis-cli -p "$_REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
        log_error "Redis did not respond to PING"
        return 1
    fi

    # Populate a real keyspace with unique keys so the checkpointed
    # Redis image contains a meaningful working set.
    log_info "Populating ${_REDIS_KEY_COUNT} unique keys..."
    local value
    printf -v value '%*s' "$_REDIS_VALUE_SIZE" ''
    value=${value// /x}

    {
        for i in $(seq 1 "$_REDIS_KEY_COUNT"); do
            printf 'SET warm:key:%05d %s\n' "$i" "$value"
        done
    } | redis-cli -p "$_REDIS_PORT" --pipe > /dev/null

    local dbsize
    dbsize=$(redis-cli -p "$_REDIS_PORT" dbsize 2>/dev/null || echo "0")
    if [ "$dbsize" -lt "$_REDIS_KEY_COUNT" ] 2>/dev/null; then
        log_error "Redis warmup incomplete: expected >= ${_REDIS_KEY_COUNT} keys, got $dbsize"
        return 1
    fi

    local used_memory
    used_memory=$(redis-cli -p "$_REDIS_PORT" info memory 2>/dev/null | awk -F: '/^used_memory_human:/ {gsub(/\r/, "", $2); print $2}')
    log_info "Redis warmed up, dbsize=$dbsize used_memory=${used_memory:-unknown}"
}

workload_profile() {
    local work_dir="$1"
    HOT_PAGES_FILE="$work_dir/hot_pages.bin"
    python3 "$HOT_PAGES" --pid "$WORKLOAD_PID" --output "$HOT_PAGES_FILE" \
        --samples 3 --interval 1
}

workload_ttfr_probe() {
    local work_dir="$1"
    # TTFR = time from RESTORE_T_START until redis responds to PING
    local deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if redis-cli -p "$_REDIS_PORT" ping 2>/dev/null | grep -q PONG; then
            TTFR_MS=$(( $(time_ms) - RESTORE_T_START ))
            return 0
        fi
        sleep 0.01
    done
    log_error "TTFR probe timed out for Redis"
    TTFR_MS=-1
    return 1
}

workload_throughput() {
    # Run redis-benchmark: get + set, 10 clients, 1K ops each, 30s timeout
    local output
    output=$(timeout 30 redis-benchmark -p "$_REDIS_PORT" -t get,set -c 10 -n 1000 -r "$_REDIS_KEY_COUNT" -q 2>/dev/null || echo "")

    if [ -z "$output" ]; then
        log_warn "redis-benchmark returned no output"
        THROUGHPUT=0
        return
    fi

    # Parse lines like: "SET: 123456.78 requests per second"
    # Average the SET and GET values
    local total=0 count=0
    while IFS= read -r line; do
        local ops
        ops=$(echo "$line" | grep -oP '[\d.]+(?= requests per second)' || true)
        if [ -n "$ops" ]; then
            # Truncate to integer
            ops=${ops%%.*}
            total=$((total + ops))
            count=$((count + 1))
        fi
    done <<< "$output"

    if [ "$count" -gt 0 ]; then
        THROUGHPUT=$((total / count))
    else
        THROUGHPUT=0
    fi
}

workload_cleanup() {
    if [ -n "$_REDIS_PID" ]; then
        redis-cli -p "$_REDIS_PORT" shutdown nosave 2>/dev/null || true
        kill "$_REDIS_PID" 2>/dev/null || true
        _REDIS_PID=""
    fi
}
