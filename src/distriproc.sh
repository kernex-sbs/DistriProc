#!/bin/bash
# DistriProc - Lazy migration orchestration
# Wraps CRIU's multi-step lazy-pages commands into a single interface.
#
# CRIU lazy-pages workflow:
#   1. criu dump -t PID -D DIR              (checkpoint, pages saved to images)
#   2. criu lazy-pages -D DIR               (daemon serving pages on demand)
#   3. criu restore --lazy-pages -D DIR     (restore with on-demand page fetching)
#
# For remote migration, use --page-server on dump to send pages to a remote
# page server, then run lazy-pages + restore on the destination.
#
# Usage:
#   distriproc.sh dump    --pid <PID> --dir <DIR>
#   distriproc.sh restore --dir <DIR>
set -euo pipefail

usage() {
    echo "Usage:"
    echo "  $0 dump    --pid <PID> --dir <DIR>"
    echo "  $0 restore --dir <DIR>"
    echo ""
    echo "Commands:"
    echo "  dump     Checkpoint a process and start lazy-pages daemon"
    echo "  restore  Restore a process with on-demand page fetching"
    exit 1
}

cmd_dump() {
    local pid="" dir=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --pid)   pid="$2"; shift 2 ;;
            --dir)   dir="$2"; shift 2 ;;
            *)       echo "Unknown option: $1"; usage ;;
        esac
    done

    [ -z "$pid" ] && { echo "Error: --pid required"; usage; }
    [ -z "$dir" ] && { echo "Error: --dir required"; usage; }

    mkdir -p "$dir"

    echo "[distriproc] Checkpointing PID $pid..."
    criu dump -t "$pid" -D "$dir" -j -v4 --log-file dump.log
    echo "[distriproc] Checkpoint complete. Images in $dir"

    echo "[distriproc] Starting lazy-pages daemon..."
    criu lazy-pages -D "$dir" -v4 --log-file lazy-pages.log &
    local lazy_pid=$!
    echo "$lazy_pid" > "$dir/lazy-pages.pid"
    sleep 1

    if ! kill -0 "$lazy_pid" 2>/dev/null; then
        echo "[distriproc] ERROR: lazy-pages daemon failed to start"
        cat "$dir/lazy-pages.log" 2>/dev/null | tail -10
        exit 1
    fi

    echo "[distriproc] Lazy-pages daemon running (PID $lazy_pid)"
    echo "[distriproc] Ready for restore."
}

cmd_restore() {
    local dir=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)   dir="$2"; shift 2 ;;
            *)       echo "Unknown option: $1"; usage ;;
        esac
    done

    [ -z "$dir" ] && { echo "Error: --dir required"; usage; }

    echo "[distriproc] Restoring process with lazy-pages from $dir..."

    cd "$dir"
    criu restore --lazy-pages -D "$dir" -j -v4 \
        --log-file restore.log -d --pidfile restore.pid

    local restored_pid
    restored_pid=$(cat "$dir/restore.pid")
    echo "[distriproc] Process restored (PID $restored_pid)"
    echo "[distriproc] Pages are being fetched on-demand via userfaultfd"
}

[ $# -lt 1 ] && usage

command="$1"
shift

case "$command" in
    dump)    cmd_dump "$@" ;;
    restore) cmd_restore "$@" ;;
    *)       echo "Unknown command: $command"; usage ;;
esac
