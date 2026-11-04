#!/bin/bash
# eval/workloads/webapp.sh — Python web-app workload (http.server + in-memory
# SQLite + Jinja2) for benchmarks. Sourced by bench.sh. Implements the
# standard workload interface.
#
# Env: WEBAPP_ORDERS (4000000), WEBAPP_PROBE_REQS (200: TTFR covers that many
#      fixed customer pages), WEBAPP_PROBE_TIMEOUT_S (300),
#      WEBAPP_CLIENT_TCP=1: TCP instead of a unix socket (as REDIS_CLIENT_TCP:
#      hosts without unix_diag, netem not on lo).

_WEB_SCRIPT="$SCRIPT_DIR/workloads/webapp_server.py"
_WEB_PID=""
_WEB_WORK_DIR=""
_WEB_CURL=()

workload_name() {
    echo "webapp"
}

workload_setup() {
    if ! python3 -c "import jinja2, sqlite3" 2>/dev/null; then
        log_error "python3 lacks jinja2 or sqlite3"
        return 1
    fi
    command -v curl &>/dev/null || { log_error "curl not found"; return 1; }
    [ -f "$_WEB_SCRIPT" ] || { log_error "webapp_server.py not found at $_WEB_SCRIPT"; return 1; }
}

workload_start() {
    local work_dir="$1"
    _WEB_WORK_DIR="$work_dir"
    rm -f "$work_dir/web_ready"
    local listen
    if [ -n "${WEBAPP_CLIENT_TCP:-}" ]; then
        local port
        port=$(find_available_port 8080)
        listen=(--port "$port")
        _WEB_BASE="http://127.0.0.1:$port"
        _WEB_CURL=(-s)
    else
        listen=(--unix-socket "$work_dir/web.sock")
        _WEB_BASE="http://localhost"
        _WEB_CURL=(-s --unix-socket "$work_dir/web.sock")
    fi

    # shellcheck disable=SC2086  # WL_LAUNCH: optional prefix, e.g. "setarch -R"
    setsid ${WL_LAUNCH:-} python3 "$_WEB_SCRIPT" --ready-file "$work_dir/web_ready" \
        "${listen[@]}" --orders "${WEBAPP_ORDERS:-4000000}" \
        > "$work_dir/workload.log" 2>&1 &
    _WEB_PID=$!
    track_pid "$_WEB_PID"
    WORKLOAD_PID="$_WEB_PID"
}

# curl config: n fixed pseudo-random customer pages (seeded), bodies dropped.
_web_urls() {
    python3 -c "
import random, sys
for i in random.Random(int(sys.argv[2])).sample(range(50000), int(sys.argv[1])):
    print(f'url = \"$_WEB_BASE/customer/{i}\"\noutput = \"/dev/null\"')" "$1" "$2"
}

# Runs a curl config; true iff every one of its n requests returned 200.
_web_run() {
    [ "$(curl "${_WEB_CURL[@]}" -K "$1" -w '%{http_code}\n' 2>/dev/null | grep -c '^200$')" -eq "$2" ]
}

workload_warmup() {
    wait_for_file "$_WEB_WORK_DIR/web_ready" 180 || return 1
    _web_urls "${WEBAPP_PROBE_REQS:-200}" 42 > "$_WEB_WORK_DIR/probe.cfg"
    _web_urls 1000 7 > "$_WEB_WORK_DIR/tput.cfg"
    _web_run "$_WEB_WORK_DIR/probe.cfg" "${WEBAPP_PROBE_REQS:-200}" ||
        { log_error "webapp warmup probe failed"; return 1; }
    log_info "webapp ready, RSS $(awk '/VmRSS/ {print $2 " " $3}' "/proc/$_WEB_PID/status")"
}

workload_profile() {
    local work_dir="$1"
    HOT_PAGES_FILE="$work_dir/hot_pages.bin"
    python3 "$HOT_PAGES" --pid "$WORKLOAD_PID" --output "$HOT_PAGES_FILE" \
        --samples 3 --interval 1
}

workload_ttfr_probe() {
    # TTFR = time from RESTORE_T_START until all probe pages have been served.
    # A failed attempt (socket not restored yet) is retried until the deadline.
    local deadline=$(( $(date +%s) + ${WEBAPP_PROBE_TIMEOUT_S:-300} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if _web_run "$_WEB_WORK_DIR/probe.cfg" "${WEBAPP_PROBE_REQS:-200}"; then
            TTFR_MS=$(( $(time_ms) - RESTORE_T_START ))
            return 0
        fi
        sleep 0.01
    done
    log_error "TTFR probe timed out for webapp"
    TTFR_MS=-1
    return 1
}

workload_throughput() {
    # Post-restore: 1000 other customer pages on the restored process, req/s.
    local t0 t1
    t0=$(time_ms)
    if _web_run "$_WEB_WORK_DIR/tput.cfg" 1000; then
        t1=$(time_ms)
        THROUGHPUT=$(( 1000000 / (t1 - t0 > 0 ? t1 - t0 : 1) ))
    else
        log_warn "webapp throughput run failed"
        THROUGHPUT=0
    fi
}

workload_cleanup() {
    if [ -n "$_WEB_PID" ]; then
        kill "$_WEB_PID" 2>/dev/null || true
        _WEB_PID=""
    fi
}
