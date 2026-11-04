#!/bin/bash
# eval/crosshost_2machine.sh — REAL two-machine cross-host validation of the
# RTT crossover. Page server runs on a second machine (B) over a wired LAN; the
# restore + lazy_handler + PyTorch workload run here on machine A, exactly as in
# the loopback runs. Only the transport changes, so TTFR stays comparable.
#
# Topology:
#   A (this host): criu restore --lazy-pages + lazy_handler + workload (WORKLOAD)
#   B (PAGE_SERVER_SSH): criu_page_server.py bound to 0.0.0.0, serving over LAN
#
# This is intentionally standalone (it does NOT touch bench.sh) so the validated
# loopback harness cannot regress. It reuses lib.sh helpers and the eval/workloads
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
#   NODELAY_ARMS      TCP_NODELAY arms, interleaved per iteration (default: "0 1";
#                     0 = original Nagle-on transport, 1 = fixed)
#   OUT_DIR           results dir                 (default: eval/results/crosshost-2machine)
#   DELAYS_US         extra one-way delay on A's IFACE egress (requests, ACKs),
#                     interleaved per iteration   (default: "0"). B's egress,
#                     the data bottleneck, keeps its own qdisc.
#   IFACE             A's interface to B          (default: eth0)
#
#   WORKLOAD          eval/workloads/<name>.sh    (default: pytorch)
#   NO_THROUGHPUT     set to skip the throughput step (see bench.sh)
#
# Extra modes: full (local images), full-net (stream images B->A, then full
# restore), lazy-stream / -pf / -all (stream a demand-fault trace recorded
# twice at delay 0 before the loop; trace-a is used, trace-b checks stability),
# lazy-stream-same (trace recorded on an untimed first restore of the same
# image, then streamed on a second restore: REAP-style upper bound).

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
SCRIPT_DIR="$ROOT_DIR/eval"          # workloads expect SCRIPT_DIR/workloads/...
WORKLOAD="${WORKLOAD:-pytorch}"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/workloads/$WORKLOAD.sh"

# ── Config ────────────────────────────────────────────────────────────────────
: "${PAGE_SERVER_SSH:?set PAGE_SERVER_SSH=user@B_LAN_IP}"
PAGE_SERVER_HOST="${PAGE_SERVER_HOST:-${PAGE_SERVER_SSH#*@}}"
REMOTE_ROOT="${REMOTE_ROOT:-DistriProc}"          # relative => B's home dir
REMOTE_WORK="${REMOTE_WORK:-/tmp/distriproc-xh-2m}"
B_PYTHONPATH="${B_PYTHONPATH:-}"
PORT="${PORT:-9999}"
ITERS="${ITERS:-10}"
MODES="${MODES:-lazy lazy-prefetch lazy-adaptive}"
NODELAY_ARMS="${NODELAY_ARMS:-0 1}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/eval/results/crosshost-2machine}"
DELAYS_US="${DELAYS_US:-0}"
IFACE="${IFACE:-eth0}"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/results.csv"
TRACE="$OUT_DIR/trace-a.trace"
echo "workload,mode,iteration,ttfr_ms,throughput_ops_sec,page_faults,pages_prefetched,prefetch_hits,hit_rate_pct,total_pages_served,eager_pages,checkpoint_time_ms,rtt_us,tcp_nodelay,delay_us" > "$CSV"

REMOTE_PS="$REMOTE_ROOT/src/criu_page_server.py"
REMOTE_PID_FILE="$REMOTE_WORK/page_server.pid"

handler_args() {  # mode -> lazy_handler flags
    case "$1" in
        lazy)          echo "--no-prefetch" ;;
        lazy-prefetch) echo "--prefetch-seq 16 --prefetch-stride 8" ;;
        lazy-adaptive) echo "--prefetch-seq 16 --prefetch-stride 8 --adaptive-prefetch" ;;
        lazy-record)   echo "--no-prefetch" ;;
        lazy-stream|lazy-stream-all) echo "--no-prefetch --hot-pages $TRACE" ;;
        lazy-stream-pf) echo "--prefetch-seq 16 --prefetch-stride 8 --hot-pages $TRACE" ;;
        lazy-stream-same) echo "--no-prefetch --hot-pages $work_dir/same.trace" ;;  # run_one's local
        *) echo "ERROR: unknown mode $1" >&2; return 1 ;;
    esac
}

stop_remote_server() {
    # Kill by pidfile AND pkill any stray page servers: a survivor keeps cached
    # fds to the previous iteration's (now rsync-replaced) images and serves
    # garbage, crashing the next restore. Belt and suspenders.
    ssh "$PAGE_SERVER_SSH" "test -f '$REMOTE_PID_FILE' && kill \$(cat '$REMOTE_PID_FILE') 2>/dev/null; pkill -f 'criu_page_server.py.*--port $PORT' 2>/dev/null; rm -f '$REMOTE_PID_FILE'" 2>/dev/null || true
}
set_delay() {  # one-way delay on A's egress; 0 restores the default qdisc
    if [ "$1" -eq 0 ]; then tc qdisc replace dev "$IFACE" root fq_codel
    else tc qdisc replace dev "$IFACE" root netem delay "${1}us" limit 100000; fi
}
cleanup() { cleanup_pids; stop_remote_server; set_delay 0 2>/dev/null || true; }
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
    # Kill any survivor on this port first, so the fresh server binds and serves
    # the images we are about to rsync (not stale cached fds).
    ssh "$PAGE_SERVER_SSH" "pkill -f 'criu_page_server.py.*--port $PORT' 2>/dev/null; rm -rf '$REMOTE_WORK'; mkdir -p '$REMOTE_WORK'"
    sleep 0.5
    if ! rsync -a --delete -e ssh "$dir/" "$PAGE_SERVER_SSH:$REMOTE_WORK/"; then
        log_error "rsync of images A->B failed (partial copy would stall page serving)"; return 1
    fi
    # Verify B sees the same image files A dumped (catch silent partial copies).
    local na nb
    na=$(ls "$dir"/*.img 2>/dev/null | wc -l)
    nb=$(ssh "$PAGE_SERVER_SSH" "ls '$REMOTE_WORK'/*.img 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    if [ "$na" != "$nb" ]; then
        log_error "image-file count mismatch A=$na B=$nb after rsync"; return 1
    fi
    # -u = unbuffered, so the startup banner + any traceback survive in the log.
    ssh "$PAGE_SERVER_SSH" "cd '$REMOTE_ROOT' && ${B_PYTHONPATH:+PYTHONPATH=$B_PYTHONPATH }PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python DISTRIPROC_TCP_NODELAY=$DISTRIPROC_TCP_NODELAY nohup python3 -u src/criu_page_server.py --host 0.0.0.0 --images-dir '$REMOTE_WORK' --port '$PORT' > '$REMOTE_WORK/page_server.log' 2>&1 & echo \$! > '$REMOTE_PID_FILE'" >/dev/null 2>&1 &
    # Wait until A can connect to B:PORT.
    local deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if python3 -c "import socket,sys; socket.create_connection(('$PAGE_SERVER_HOST',$PORT),2).close()" 2>/dev/null; then
            log_info "B page_map: $(ssh "$PAGE_SERVER_SSH" "grep -hE 'Total pages indexed|pages mapped|Error|Traceback' '$REMOTE_WORK/page_server.log'" 2>/dev/null | tr '\n' ' | ')"
            return 0
        fi
        sleep 0.3
    done
    log_error "remote page server never accepted connections on $PAGE_SERVER_HOST:$PORT"
    ssh "$PAGE_SERVER_SSH" "tail -20 '$REMOTE_WORK/page_server.log'" 2>/dev/null >&2 || true
    return 1
}

start_remote_xfer() {  # serve B's copy of the images on PORT+1 (one client)
    ssh "$PAGE_SERVER_SSH" "rm -f /tmp/distriproc-xfer.log"  # no stale "ready"
    ssh "$PAGE_SERVER_SSH" "cd '$REMOTE_ROOT' && nohup python3 -u eval/xfer_images.py serve '$REMOTE_WORK' $((PORT + 1)) > /tmp/distriproc-xfer.log 2>&1 &" >/dev/null 2>&1 &
    for _ in $(seq 50); do
        ssh "$PAGE_SERVER_SSH" "grep -q ready /tmp/distriproc-xfer.log" 2>/dev/null && return 0
        sleep 0.2
    done
    log_error "remote xfer server never became ready"; return 1
}

run_one() {  # $1=mode $2=iteration $3=delay_us; env DISTRIPROC_TCP_NODELAY
    local mode="$1" iter="$2" delay="$3" nd="$DISTRIPROC_TCP_NODELAY"
    local tag="${mode}_nd${nd}_d${delay}_iter${iter}"
    local work_dir handler_pid="" restored_pid="" stats="-1,-1,-1,-1,-1,0"
    work_dir=$(mktemp -d "/tmp/distriproc-2m-${mode}-XXXXXX")
    log_info "[$WORKLOAD/$mode/nd$nd/d$delay] iter $iter"

    WL_LAUNCH=""
    case "$mode" in lazy-record|lazy-stream*) WL_LAUNCH="setarch -R" ;; esac
    workload_start "$work_dir"
    workload_warmup
    local dump_pid="$WORKLOAD_PID"
    checkpoint_ms=$(criu_dump "$WORKLOAD_PID" "$work_dir")
    wait "$dump_pid" 2>/dev/null || true
    WORKLOAD_PID=""

    if [ "$mode" = "full" ]; then
        RESTORE_T_START=$(time_ms)
        restored_pid=$(criu_restore_full "$work_dir")
    else
        if ! start_remote_server "$work_dir"; then
            log_error "[$WORKLOAD/$mode] iter $iter: skipping (server failed)"
            rm -rf "$work_dir"; stop_remote_server; return 0
        fi
        if [ "$mode" = "full-net" ]; then
            start_remote_xfer || { rm -rf "$work_dir"; stop_remote_server; return 0; }
            RESTORE_T_START=$(time_ms)
            python3 "$SCRIPT_DIR/xfer_images.py" recv "$PAGE_SERVER_HOST" $((PORT + 1)) "$work_dir/net-images"
            restored_pid=$(criu_restore_full "$work_dir/net-images")
            cp "$work_dir/net-images/restore.log" "$work_dir/" 2>/dev/null || true
        else
            if [ "$mode" = "lazy-stream-same" ]; then  # untimed record pass, same image
                local rpid hpid wl_size
                # CRIU checks the size of files the process has open (its stdout log)
                wl_size=$(stat -c %s "$work_dir/workload.log")
                hpid=$(DISTRIPROC_TRACE="$work_dir/same.trace" \
                    start_lazy_handler "$work_dir" "$PAGE_SERVER_HOST" "$PORT" --no-prefetch)
                RESTORE_T_START=$(time_ms); rpid=$(criu_restore_lazy "$work_dir")
                TTFR_MS=0; workload_ttfr_probe "$work_dir" || true
                log_info "[$WORKLOAD/$mode/nd$nd/d$delay] iter $iter record pass TTFR=${TTFR_MS}ms"
                kill -9 "$rpid" 2>/dev/null || true; kill "$hpid" 2>/dev/null || true
                for _ in $(seq 50); do
                    kill -0 "$hpid" 2>/dev/null || kill -0 "$rpid" 2>/dev/null || break; sleep 0.2
                done
                kill -9 "$hpid" 2>/dev/null || true
                mv "$work_dir/handler.log" "$work_dir/record_handler.log"
                rm -f "$work_dir/restore.pid"  # CRIU 4.2 won't overwrite a pidfile
                truncate -s "$wl_size" "$work_dir/workload.log"
            fi
            local args rest=0 trace_env=""
            args=$(handler_args "$mode")
            [ "$mode" = "lazy-stream-all" ] && rest=1
            [ "$mode" = "lazy-record" ] && trace_env="$RECORD_TO"
            # shellcheck disable=SC2086
            handler_pid=$(DISTRIPROC_TRACE="$trace_env" DISTRIPROC_STREAM_REST=$rest \
                start_lazy_handler "$work_dir" "$PAGE_SERVER_HOST" "$PORT" $args)
            RESTORE_T_START=$(time_ms)
            restored_pid=$(criu_restore_lazy "$work_dir")
        fi
    fi

    TTFR_MS=0; workload_ttfr_probe "$work_dir" || true; local ttfr_ms="$TTFR_MS"
    if [ "$ttfr_ms" = "-1" ]; then
        log_warn "[$WORKLOAD/$mode] iter $iter probe FAILED: restored pid=$restored_pid"
        tail -15 "$work_dir/restore.log" >&2 2>/dev/null || true
    fi
    THROUGHPUT=0; [ -n "${NO_THROUGHPUT:-}" ] || workload_throughput || true
    log_info "[$WORKLOAD/$mode/nd$nd/d$delay] iter $iter TTFR=${ttfr_ms}ms"

    [ -n "$restored_pid" ] && kill -9 "$restored_pid" 2>/dev/null || true
    if [ -n "$handler_pid" ]; then
        kill "$handler_pid" 2>/dev/null || true
        # The handler polls for SIGTERM about once a second; 1 s was too
        # short and its stats were lost (recorded as -1).
        for _ in $(seq 25); do kill -0 "$handler_pid" 2>/dev/null || break; sleep 0.2; done
        kill -9 "$handler_pid" 2>/dev/null || true; sleep 0.2
        stats=$(parse_handler_stats "$work_dir/handler.log")
    fi
    ssh "$PAGE_SERVER_SSH" "cat '$REMOTE_WORK/page_server.log'" > "$work_dir/page_server.log" 2>/dev/null || true
    stop_remote_server
    for lg in handler record_handler page_server; do
        cp "$work_dir/$lg.log" "$OUT_DIR/${WORKLOAD}_${tag}_${lg}.log" 2>/dev/null || true
    done

    csv_append "$CSV" "${WORKLOAD},${mode},${iter},${ttfr_ms},${THROUGHPUT},${stats},${checkpoint_ms},$((RTT_US + delay)),${nd},${delay}"
    workload_cleanup
    rm -rf "$work_dir"
}

# ── Trace (once, at delay 0) ──────────────────────────────────────────────────
if [[ " $MODES " == *" lazy-stream"* ]]; then
    set_delay 0
    export DISTRIPROC_TCP_NODELAY=1
    for t in a b; do RECORD_TO="$OUT_DIR/trace-$t.trace" run_one lazy-record "rec-$t" 0; done
    python3 - "$OUT_DIR/trace-a.trace" "$OUT_DIR/trace-b.trace" <<'PY'
import sys
a, b = (open(p, "rb").read() for p in sys.argv[1:])
a, b = ([x[i:i+8] for i in range(0, len(x), 8)] for x in (a, b))
print(f"trace: a={len(a)} b={len(b)} pages, {len(set(a) & set(b)) / len(set(a)):.1%} of a also in b")
PY
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
for iter in $(seq 1 "$ITERS"); do
  for delay in $DELAYS_US; do
    set_delay "$delay"
    for mode in $MODES; do
      # Demand-only lazy pays ~1 RTT per page: skip it once delay is added.
      [ "$mode" = "lazy" ] && [ "$delay" -gt 0 ] && continue
      for nd in $NODELAY_ARMS; do
        export DISTRIPROC_TCP_NODELAY="$nd"   # handler inherits; ssh passes it to B
        run_one "$mode" "$iter" "$delay"
      done
    done
  done
done
set_delay 0

log_info "Done. Results: $CSV  (base LAN RTT ${RTT_US} us + delay_us, n=${ITERS}/mode)"
