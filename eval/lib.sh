#!/bin/bash
# eval/lib.sh — Shared library for benchmark suite
# Sourced by bench.sh and workload scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAZY_HANDLER="$ROOT_DIR/src/lazy_handler"
PAGE_SERVER="$ROOT_DIR/src/criu_page_server.py"
HOT_PAGES="$ROOT_DIR/src/hot_pages.py"

# PIDs to clean up on exit
TRACKED_PIDS=()

# ── Timing ──────────────────────────────────────────────────────────────────

time_ms() {
    date +%s%3N
}

# ── Port discovery ──────────────────────────────────────────────────────────

find_available_port() {
    local start="${1:-9999}"
    local p
    for p in $(seq "$start" -1 $((start - 20))); do
        if ! ss -tln | grep -q ":${p} "; then
            echo "$p"
            return 0
        fi
    done
    echo "ERROR: no free port found near $start" >&2
    return 1
}

# ── Polling helpers ─────────────────────────────────────────────────────────

wait_for_file() {
    local file="$1" timeout_s="${2:-10}"
    local deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -s "$file" ]; then
            return 0
        fi
        sleep 0.1
    done
    echo "ERROR: wait_for_file $file timed out after ${timeout_s}s" >&2
    return 1
}

wait_for_counter() {
    local file="$1" min="$2" timeout_s="${3:-15}"
    local deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$file" ]; then
            local val
            val=$(cat "$file" 2>/dev/null || echo "0")
            if [ "$val" -ge "$min" ] 2>/dev/null; then
                return 0
            fi
        fi
        sleep 0.5
    done
    echo "ERROR: wait_for_counter $file >= $min timed out after ${timeout_s}s" >&2
    return 1
}

# ── Process management ──────────────────────────────────────────────────────

track_pid() {
    TRACKED_PIDS+=("$1")
}

cleanup_pids() {
    local pid
    for pid in "${TRACKED_PIDS[@]+"${TRACKED_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    TRACKED_PIDS=()
}

# ── CRIU operations ─────────────────────────────────────────────────────────

start_page_server() {
    local dir="$1" port="$2"
    python3 "$PAGE_SERVER" --images-dir "$dir" --port "$port" \
        > "$dir/page_server.log" 2>&1 &
    local pid=$!
    track_pid "$pid"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: criu_page_server.py died on startup" >&2
        cat "$dir/page_server.log" >&2
        return 1
    fi
    echo "$pid"
}

start_lazy_handler() {
    local dir="$1" addr="$2" port="$3"
    shift 3
    # Remaining args are extra flags (e.g. --no-prefetch, --hot-pages FILE)
    "$LAZY_HANDLER" --images-dir "$dir" --address "$addr" --port "$port" "$@" \
        > "$dir/handler.log" 2>&1 &
    local pid=$!
    track_pid "$pid"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: lazy_handler died on startup" >&2
        cat "$dir/handler.log" >&2
        return 1
    fi
    echo "$pid"
}

criu_dump() {
    local pid="$1" dir="$2"
    local t_start t_end
    t_start=$(time_ms)
    if ! criu dump -t "$pid" -D "$dir" -j -v4 --log-file dump.log 2>&1; then
        echo "ERROR: criu dump failed" >&2
        tail -20 "$dir/dump.log" >&2 2>/dev/null || true
        return 1
    fi
    t_end=$(time_ms)
    echo $(( t_end - t_start ))
}

criu_restore_full() {
    local dir="$1"
    local prev_dir
    prev_dir=$(pwd)
    cd "$dir"
    if ! criu restore -D "$dir" -j -v4 \
        --log-file restore.log -d --pidfile restore.pid 2>&1; then
        echo "ERROR: criu restore (full) failed" >&2
        tail -20 "$dir/restore.log" >&2 2>/dev/null || true
        cd "$prev_dir"
        return 1
    fi
    cd "$prev_dir"
    local rpid
    rpid=$(cat "$dir/restore.pid" 2>/dev/null || echo "")
    track_pid "$rpid"
    echo "$rpid"
}

criu_restore_lazy() {
    local dir="$1"
    local prev_dir
    prev_dir=$(pwd)
    cd "$dir"
    if ! criu restore --lazy-pages -D "$dir" -j -v4 \
        --log-file restore.log -d --pidfile restore.pid 2>&1; then
        echo "ERROR: criu restore --lazy-pages failed" >&2
        tail -20 "$dir/restore.log" >&2 2>/dev/null || true
        cd "$prev_dir"
        return 1
    fi
    cd "$prev_dir"
    local rpid
    rpid=$(cat "$dir/restore.pid" 2>/dev/null || echo "")
    track_pid "$rpid"
    echo "$rpid"
}

# ── Log parsing ─────────────────────────────────────────────────────────────

parse_handler_stats() {
    local log="$1"
    local faults=0 prefetched=0 hits=0 hit_rate=0 total_pages=0 eager_pages=0

    if [ -f "$log" ]; then
        # "Prefetch stats: N faults, N prefetched, N hits (N% hit rate)"
        local line
        line=$(grep "Prefetch stats:" "$log" 2>/dev/null | tail -1 || true)
        if [ -n "$line" ]; then
            faults=$(echo "$line" | sed 's/.*: \([0-9]*\) faults.*/\1/')
            prefetched=$(echo "$line" | sed 's/.*, \([0-9]*\) prefetched.*/\1/')
            hits=$(echo "$line" | sed 's/.*, \([0-9]*\) hits.*/\1/')
            hit_rate=$(echo "$line" | sed 's/.*(\([0-9]*\)% hit rate).*/\1/')
        fi

        # "Total pages served: N"
        line=$(grep "Total pages served:" "$log" 2>/dev/null | tail -1 || true)
        if [ -n "$line" ]; then
            total_pages=$(echo "$line" | sed 's/.*: \([0-9]*\)/\1/')
        fi

        # "Eager fetch: installed N hot pages"
        line=$(grep "Eager fetch: installed" "$log" 2>/dev/null | tail -1 || true)
        if [ -n "$line" ]; then
            eager_pages=$(echo "$line" | sed 's/.*installed \([0-9]*\) hot pages/\1/')
        fi
    fi

    echo "${faults},${prefetched},${hits},${hit_rate},${total_pages},${eager_pages}"
}

# ── CSV helpers ─────────────────────────────────────────────────────────────

csv_header() {
    local file="$1"
    # Always write fresh header (overwrite existing file)
    echo "workload,mode,iteration,ttfr_ms,throughput_ops_sec,page_faults,pages_prefetched,prefetch_hits,hit_rate_pct,total_pages_served,eager_pages,checkpoint_time_ms" > "$file"
}

csv_append() {
    local file="$1" row="$2"
    echo "$row" >> "$file"
}

# ── Logging ─────────────────────────────────────────────────────────────────

log_info() {
    echo "[$(date '+%H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

log_warn() {
    echo "[$(date '+%H:%M:%S')] WARN: $*" >&2
}
