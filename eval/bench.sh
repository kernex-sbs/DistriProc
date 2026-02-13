#!/bin/bash
# eval/bench.sh — Main benchmark harness for DistriProc evaluation
#
# Usage: sudo bash eval/bench.sh [OPTIONS]
#   --workloads LIST    Comma-separated (default: test_loop,redis,pytorch)
#   --modes LIST        Comma-separated (default: full,lazy,lazy-prefetch,lazy-hot)
#   --iterations N      Runs per config (default: 5)
#   --output-dir DIR    Results directory (default: eval/results)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# When running under sudo, include the invoking user's Python packages
if [ -n "${SUDO_USER:-}" ]; then
    USER_SITE=$(sudo -u "$SUDO_USER" python3 -m site --user-site 2>/dev/null || true)
    if [ -n "$USER_SITE" ] && [ -d "$USER_SITE" ]; then
        export PYTHONPATH="${USER_SITE}${PYTHONPATH:+:$PYTHONPATH}"
    fi
fi

# ── Defaults ────────────────────────────────────────────────────────────────

WORKLOADS="test_loop,redis,pytorch"
MODES="full,lazy,lazy-prefetch,lazy-hot"
ITERATIONS=5
OUTPUT_DIR="$ROOT_DIR/eval/results"

# ── Parse arguments ─────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --workloads)  WORKLOADS="$2"; shift 2 ;;
        --modes)      MODES="$2"; shift 2 ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: sudo bash $0 [OPTIONS]"
            echo "  --workloads LIST    Comma-separated (default: test_loop,redis,pytorch)"
            echo "  --modes LIST        Comma-separated (default: full,lazy,lazy-prefetch,lazy-hot)"
            echo "  --iterations N      Runs per config (default: 5)"
            echo "  --output-dir DIR    Results directory (default: eval/results)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Preflight checks ───────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (criu requires it)"
    exit 1
fi

if ! command -v criu &>/dev/null; then
    echo "ERROR: criu not found in PATH"
    exit 1
fi

if ! python3 -c "from pycriu import images" 2>/dev/null; then
    echo "ERROR: pycriu not installed"
    exit 1
fi

for bin in "$LAZY_HANDLER"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: $bin not found or not executable (run 'make all' first)"
        exit 1
    fi
done

if [ ! -f "$PAGE_SERVER" ]; then
    echo "ERROR: $PAGE_SERVER not found"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

CSV_FILE="$OUTPUT_DIR/results.csv"
csv_header "$CSV_FILE"

IFS=',' read -ra WORKLOAD_LIST <<< "$WORKLOADS"
IFS=',' read -ra MODE_LIST <<< "$MODES"

# ── Print banner ────────────────────────────────────────────────────────────

log_info "DistriProc Benchmark Suite"
log_info "Workloads:  ${WORKLOAD_LIST[*]}"
log_info "Modes:      ${MODE_LIST[*]}"
log_info "Iterations: $ITERATIONS"
log_info "Output:     $CSV_FILE"
echo "────────────────────────────────────────────────────"

# ── Handler args for each mode ──────────────────────────────────────────────

handler_args_for_mode() {
    local mode="$1"
    case "$mode" in
        full)           echo "__FULL__" ;;
        lazy)           echo "--no-prefetch" ;;
        lazy-prefetch)  echo "--prefetch-seq 16 --prefetch-stride 8" ;;
        lazy-hot)       echo "--prefetch-seq 16 --prefetch-stride 8" ;;
        *)              echo "ERROR: unknown mode $mode" >&2; return 1 ;;
    esac
}

# ── Run one benchmark iteration ─────────────────────────────────────────────

run_iteration() {
    local wl_name="$1" mode="$2" iter="$3"
    local work_dir
    work_dir=$(mktemp -d "/tmp/distriproc-bench-${wl_name}-${mode}-XXXXXX")

    local checkpoint_ms=0 ttfr_ms=-1 throughput=0
    local handler_stats="0,0,0,0,0,0"
    local port page_server_pid handler_pid restored_pid

    log_info "[$wl_name/$mode] iteration $iter — starting workload"

    # 1. Start and warm up workload
    workload_start "$work_dir"
    workload_warmup

    # 2. Profile for hot pages if lazy-hot mode
    local hot_file_arg=""
    if [ "$mode" = "lazy-hot" ]; then
        log_info "[$wl_name/$mode] profiling hot pages..."
        workload_profile "$work_dir"
        hot_file_arg="--hot-pages $HOT_PAGES_FILE"
    fi

    # 3. Checkpoint
    log_info "[$wl_name/$mode] checkpointing PID=$WORKLOAD_PID..."
    local dump_pid="$WORKLOAD_PID"
    checkpoint_ms=$(criu_dump "$WORKLOAD_PID" "$work_dir")
    # criu dump kills the process — reap to suppress "Killed" noise
    wait "$dump_pid" 2>/dev/null || true
    WORKLOAD_PID=""
    log_info "[$wl_name/$mode] checkpoint took ${checkpoint_ms}ms"

    # 4. Restore — record t_start for TTFR measurement
    RESTORE_T_START=0
    if [ "$mode" = "full" ]; then
        # Full restore — no page server or handler
        RESTORE_T_START=$(time_ms)
        restored_pid=$(criu_restore_full "$work_dir")
        log_info "[$wl_name/$mode] full restore done, PID=$restored_pid"
    else
        # Lazy restore — start page server + handler, then restore
        port=$(find_available_port 9999)

        page_server_pid=$(start_page_server "$work_dir" "$port")
        log_info "[$wl_name/$mode] page server on port $port (PID=$page_server_pid)"

        local handler_extra
        handler_extra=$(handler_args_for_mode "$mode")
        # shellcheck disable=SC2086
        handler_pid=$(start_lazy_handler "$work_dir" "127.0.0.1" "$port" $handler_extra $hot_file_arg)
        log_info "[$wl_name/$mode] lazy handler PID=$handler_pid"

        RESTORE_T_START=$(time_ms)
        restored_pid=$(criu_restore_lazy "$work_dir")
        log_info "[$wl_name/$mode] lazy restore done, PID=$restored_pid"
    fi

    # 5. Measure TTFR (from restore start to first workload response)
    log_info "[$wl_name/$mode] measuring TTFR..."
    TTFR_MS=0
    workload_ttfr_probe "$work_dir" || true
    ttfr_ms="$TTFR_MS"
    log_info "[$wl_name/$mode] TTFR = ${ttfr_ms}ms"

    # 6. Measure throughput
    log_info "[$wl_name/$mode] measuring throughput..."
    THROUGHPUT=0
    workload_throughput || true
    throughput="$THROUGHPUT"
    log_info "[$wl_name/$mode] throughput = ${throughput} ops/sec"

    # 7. Kill restored process, then signal handler to exit and print stats
    if [ -n "$restored_pid" ]; then
        kill -9 "$restored_pid" 2>/dev/null || true
    fi

    if [ "$mode" != "full" ] && [ -n "${handler_pid:-}" ]; then
        # Send SIGTERM — handler checks got_signal on next poll timeout (≤1s),
        # then prints stats and exits cleanly
        kill "$handler_pid" 2>/dev/null || true
        # Wait up to 3s for clean exit
        local wait_deadline=$(( $(date +%s) + 3 ))
        while kill -0 "$handler_pid" 2>/dev/null && [ "$(date +%s)" -lt "$wait_deadline" ]; do
            sleep 0.2
        done
        # Force kill if still stuck
        kill -9 "$handler_pid" 2>/dev/null || true
        sleep 0.2
        handler_stats=$(parse_handler_stats "$work_dir/handler.log")
    fi

    # Kill page server
    if [ -n "${page_server_pid:-}" ]; then
        kill "$page_server_pid" 2>/dev/null || true
    fi

    # 8. Record CSV
    csv_append "$CSV_FILE" "${wl_name},${mode},${iter},${ttfr_ms},${throughput},${handler_stats},${checkpoint_ms}"

    # 9. Cleanup
    rm -rf "$work_dir"
    log_info "[$wl_name/$mode] iteration $iter done"
}

# ── Main loop ───────────────────────────────────────────────────────────────

TOTAL_RUNS=$(( ${#WORKLOAD_LIST[@]} * ${#MODE_LIST[@]} * ITERATIONS ))
RUN_NUM=0

for wl in "${WORKLOAD_LIST[@]}"; do
    # Source workload script
    wl_script="$SCRIPT_DIR/workloads/${wl}.sh"
    if [ ! -f "$wl_script" ]; then
        log_warn "Workload script $wl_script not found, skipping"
        continue
    fi
    source "$wl_script"

    # Check dependencies
    if ! workload_setup; then
        log_warn "Workload $wl setup failed (missing deps?), skipping"
        continue
    fi

    log_info "=== Workload: $wl ==="

    for mode in "${MODE_LIST[@]}"; do
        log_info "--- Mode: $mode ---"
        for iter in $(seq 1 "$ITERATIONS"); do
            RUN_NUM=$((RUN_NUM + 1))
            echo ""
            log_info "[$RUN_NUM/$TOTAL_RUNS] $wl / $mode / iteration $iter"

            # Reset tracked PIDs for this iteration
            cleanup_pids
            TRACKED_PIDS=()

            if ! run_iteration "$wl" "$mode" "$iter"; then
                log_error "[$wl/$mode] iteration $iter FAILED — recording error row"
                csv_append "$CSV_FILE" "${wl},${mode},${iter},-1,0,0,0,0,0,0,0,0"
                cleanup_pids
            fi

            workload_cleanup 2>/dev/null || true
            cleanup_pids
        done
    done
done

echo ""
echo "════════════════════════════════════════════════════"
log_info "Benchmark complete. Results: $CSV_FILE"
log_info "Runs: $TOTAL_RUNS total, $(wc -l < "$CSV_FILE") data rows (incl. header)"
echo "════════════════════════════════════════════════════"
