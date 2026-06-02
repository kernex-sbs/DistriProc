#!/bin/bash
# eval/crosshost_2machine.sh — REAL two-machine cross-host validation of the
# RTT crossover. Page server runs on a second machine (B) over a wired LAN; the
# restore + lazy_handler + PyTorch workload run here on machine A, exactly as in
# the loopback runs. Only the transport changes, so TTFR stays comparable.
#
# Topology:
#   A (this host): criu restore --lazy-pages + lazy_handler + pytorch workload
#   B (PAGE_SERVER_SSH): criu_page_server.py bound to 0.0.0.0, serving over LAN
#
# This is intentionally standalone (it does NOT touch bench.sh) so the validated
# loopback harness cannot regress. It reuses lib.sh helpers and the pytorch
# workload functions.
#
# Prereqs (see REPRODUCE-2machine.md):
#   - Passwordless ssh + rsync from A (as root) to PAGE_SERVER_SSH.
#   - Repo cloned on B at REMOTE_ROOT, with pycriu importable there.
#   - B firewall allows inbound TCP on PORT from A.
#   - Run as root on A (criu requires it).
#
# Usage:
#   sudo PAGE_SERVER_SSH=user@192.168.1.50 PAGE_SERVER_HOST=192.168.1.50 \
#        REMOTE_ROOT=/home/user/DistriProc \
#        bash eval/crosshost_2machine.sh
#
# Tunables (env):
#   PAGE_SERVER_SSH   ssh target for B            (required, e.g. user@192.168.1.50)
#   PAGE_SERVER_HOST  B's LAN IP for handler      (default: host part of PAGE_SERVER_SSH)
#   REMOTE_ROOT       repo path on B              (default: ~/DistriProc on B)
#   REMOTE_WORK       scratch image dir on B      (default: /tmp/distriproc-xh-2m)
#   B_PYTHONPATH      extra PYTHONPATH on B for pycriu (default: empty)
#   PORT              page-server TCP port        (default: 9999)
#   ITERS             iterations per mode         (default: 10)
#   MODES             space-separated             (default: "lazy lazy-prefetch lazy-adaptive")
#   OUT_DIR           results dir                 (default: eval/results/crosshost-2machine)

set -euo pipefail

# ── A-side Python env (mirror run_bench_env.sh: venv torch + pycriu + protobuf) ─
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
if [ "$(id -u)" -ne 0 ]; then echo "ERROR: run as root (criu requires it)"; exit 1; fi

VENV_DIR="${DISTRIPROC_VENV:-}"
if [ -z "$VENV_DIR" ]; then
    [ -d "$ROOT_DIR/venv-cpu" ] && VENV_DIR="$ROOT_DIR/venv-cpu" || VENV_DIR="$ROOT_DIR/venv"
fi
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    for u_site in "$USER_HOME"/.local/lib/python*/site-packages; do
        [ -d "$u_site" ] && export PYTHONPATH="${u_site}${PYTHONPATH:+:$PYTHONPATH}"
    done
    for venv_site in "$VENV_DIR"/lib/python*/site-packages; do
        [ -d "$venv_site" ] && export PYTHONPATH="${venv_site}${PYTHONPATH:+:$PYTHONPATH}"
    done
fi
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

# ── Shared harness + workload ─────────────────────────────────────────────────
SCRIPT_DIR="$ROOT_DIR/eval"          # pytorch.sh expects SCRIPT_DIR/workloads/...
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/workloads/pytorch.sh"

# ── Config ────────────────────────────────────────────────────────────────────
: "${PAGE_SERVER_SSH:?set PAGE_SERVER_SSH=user@B_LAN_IP}"
PAGE_SERVER_HOST="${PAGE_SERVER_HOST:-${PAGE_SERVER_SSH#*@}}"
REMOTE_ROOT="${REMOTE_ROOT:-DistriProc}"          # relative => B's home dir
REMOTE_WORK="${REMOTE_WORK:-/tmp/distriproc-xh-2m}"
B_PYTHONPATH="${B_PYTHONPATH:-}"
PORT="${PORT:-9999}"
ITERS="${ITERS:-10}"
MODES="${MODES:-lazy lazy-prefetch lazy-adaptive}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/eval/results/crosshost-2machine}"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/results.csv"
echo "workload,mode,iteration,ttfr_ms,throughput_ops_sec,page_faults,pages_prefetched,prefetch_hits,hit_rate_pct,total_pages_served,eager_pages,checkpoint_time_ms,rtt_us" > "$CSV"

REMOTE_PS="$REMOTE_ROOT/src/criu_page_server.py"
REMOTE_PID_FILE="$REMOTE_WORK/page_server.pid"

handler_args() {  # mode -> lazy_handler flags
    case "$1" in
        lazy)          echo "--no-prefetch" ;;
        lazy-prefetch) echo "--prefetch-seq 16 --prefetch-stride 8" ;;
        lazy-adaptive) echo "--prefetch-seq 16 --prefetch-stride 8 --adaptive-prefetch" ;;
        *) echo "ERROR: unknown mode $1" >&2; return 1 ;;
    esac
}

stop_remote_server() {
    ssh "$PAGE_SERVER_SSH" "test -f '$REMOTE_PID_FILE' && kill \$(cat '$REMOTE_PID_FILE') 2>/dev/null; rm -f '$REMOTE_PID_FILE'" 2>/dev/null || true
}
cleanup() { cleanup_pids; stop_remote_server; }
trap cleanup EXIT INT TERM

# ── Preflight ─────────────────────────────────────────────────────────────────
log_info "Preflight: ssh + remote page server + RTT"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$PAGE_SERVER_SSH" "test -f '$REMOTE_PS'" \
    || { log_error "cannot ssh $PAGE_SERVER_SSH or $REMOTE_PS missing (set REMOTE_ROOT)"; exit 1; }
ssh "$PAGE_SERVER_SSH" "${B_PYTHONPATH:+PYTHONPATH=$B_PYTHONPATH }PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python python3 -c 'from pycriu import images'" \
    || { log_error "pycriu not importable on B (set B_PYTHONPATH)"; exit 1; }
workload_setup || exit 1

# Measure LAN RTT once (constant for this link); store microseconds.
RTT_US=$(ping -c 20 -i 0.2 "$PAGE_SERVER_HOST" 2>/dev/null \
    | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5*1000}')
[ -z "$RTT_US" ] && RTT_US=-1
log_info "Measured LAN RTT to $PAGE_SERVER_HOST: ${RTT_US} us"

start_remote_server() {  # $1=local image dir
    local dir="$1"
    ssh "$PAGE_SERVER_SSH" "mkdir -p '$REMOTE_WORK'"
    rsync -a --delete -e ssh "$dir/" "$PAGE_SERVER_SSH:$REMOTE_WORK/"
    ssh "$PAGE_SERVER_SSH" "cd '$REMOTE_ROOT' && ${B_PYTHONPATH:+PYTHONPATH=$B_PYTHONPATH }PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python nohup python3 '$REMOTE_PS' --host 0.0.0.0 --images-dir '$REMOTE_WORK' --port '$PORT' > '$REMOTE_WORK/page_server.log' 2>&1 & echo \$! > '$REMOTE_PID_FILE'" >/dev/null 2>&1 &
    # Wait until A can connect to B:PORT.
    local deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if python3 -c "import socket,sys; socket.create_connection(('$PAGE_SERVER_HOST',$PORT),2).close()" 2>/dev/null; then
            return 0
        fi
        sleep 0.3
    done
    log_error "remote page server never accepted connections on $PAGE_SERVER_HOST:$PORT"
    ssh "$PAGE_SERVER_SSH" "tail -20 '$REMOTE_WORK/page_server.log'" 2>/dev/null >&2 || true
    return 1
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for mode in $MODES; do
  for iter in $(seq 1 "$ITERS"); do
    work_dir=$(mktemp -d "/tmp/distriproc-2m-${mode}-XXXXXX")
    log_info "[pytorch/$mode] iter $iter"

    workload_start "$work_dir"
    workload_warmup
    dump_pid="$WORKLOAD_PID"
    checkpoint_ms=$(criu_dump "$WORKLOAD_PID" "$work_dir")
    wait "$dump_pid" 2>/dev/null || true
    WORKLOAD_PID=""

    if ! start_remote_server "$work_dir"; then
        log_error "[pytorch/$mode] iter $iter: skipping (server failed)"
        rm -rf "$work_dir"; stop_remote_server; continue
    fi

    args=$(handler_args "$mode")
    # shellcheck disable=SC2086
    handler_pid=$(start_lazy_handler "$work_dir" "$PAGE_SERVER_HOST" "$PORT" $args)

    RESTORE_T_START=$(time_ms)
    restored_pid=$(criu_restore_lazy "$work_dir")

    TTFR_MS=0; workload_ttfr_probe "$work_dir" || true; ttfr_ms="$TTFR_MS"
    THROUGHPUT=0; workload_throughput || true; throughput="$THROUGHPUT"
    log_info "[pytorch/$mode] iter $iter TTFR=${ttfr_ms}ms"

    [ -n "$restored_pid" ] && kill -9 "$restored_pid" 2>/dev/null || true
    if [ -n "${handler_pid:-}" ]; then
        kill "$handler_pid" 2>/dev/null || true
        sleep 1; kill -9 "$handler_pid" 2>/dev/null || true; sleep 0.2
    fi
    stats=$(parse_handler_stats "$work_dir/handler.log")
    stop_remote_server

    csv_append "$CSV" "pytorch,${mode},${iter},${ttfr_ms},${throughput},${stats},${checkpoint_ms},${RTT_US}"
    cp "$work_dir/handler.log" "$OUT_DIR/pytorch_${mode}_iter${iter}_handler.log" 2>/dev/null || true
    workload_cleanup
    rm -rf "$work_dir"
  done
done

log_info "Done. Results: $CSV  (LAN RTT ${RTT_US} us, n=${ITERS}/mode)"
log_info "Compare these TTFRs to the netem prediction at ~${RTT_US} us in Table tab:crosshost."
