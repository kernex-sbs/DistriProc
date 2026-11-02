#!/bin/bash
# eval/remeasure_nodelay.sh — Re-run the paper's loopback matrix and RTT sweep
# with TCP_NODELAY off (the original transport, Nagle on) and on, in one
# session on one kernel. Arms are interleaved per workload (matrix) and per
# RTT point (sweep) so drift hits both equally.
#
# Usage:  sudo bash eval/remeasure_nodelay.sh [matrix] [sweep]   (default: both)
# Output: eval/results/nodelay{0,1}/matrix/results.csv
#         eval/results/nodelay{0,1}/sweep/results-crosshost.csv  (adds rtt_us)
# Env:    ITERS_MATRIX (20), ITERS_SWEEP (10),
#         DELAYS_US one-way, RTT = 2x (default spans the paper's two sweeps:
#         RTT 0 30 60 100 150 200 300 500 1000 2000 us)

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT_DIR/eval/results"
IFACE=lo
MODES="full,lazy,lazy-prefetch,lazy-adaptive"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (tc + criu)"; exit 1
fi

PHASES="${*:-matrix sweep}"
ITERS_MATRIX="${ITERS_MATRIX:-20}"
ITERS_SWEEP="${ITERS_SWEEP:-10}"
read -r -a DELAYS <<< "${DELAYS_US:-0 15 30 50 75 100 150 250 500 1000}"

cleanup() { tc qdisc del dev "$IFACE" root 2>/dev/null || true; }
trap cleanup EXIT INT TERM
cleanup

echo "kernel: $(uname -r)  phases: $PHASES  started: $(date -Is)"

run_arm() {  # run_arm <nodelay> <output-dir> <iters> <workloads>
    DISTRIPROC_TCP_NODELAY="$1" bash "$ROOT_DIR/eval/run_bench_env.sh" \
        --workloads "$4" --modes "$MODES" --iterations "$3" --output-dir "$2"
}

if [[ " $PHASES " == *" matrix "* ]]; then
    for w in test_loop redis pytorch; do
        for nd in 0 1; do
            echo "=== matrix: $w  TCP_NODELAY=$nd ==="
            run_arm "$nd" "$RES/nodelay$nd/matrix/$w" "$ITERS_MATRIX" "$w"
        done
    done
    for nd in 0 1; do
        out="$RES/nodelay$nd/matrix/results.csv"
        head -1 "$RES/nodelay$nd/matrix/test_loop/results.csv" > "$out"
        for w in test_loop redis pytorch; do
            tail -n +2 "$RES/nodelay$nd/matrix/$w/results.csv" >> "$out"
        done
        echo "matrix nodelay=$nd: $out"
    done
fi

if [[ " $PHASES " == *" sweep "* ]]; then
    for d in "${DELAYS[@]}"; do
        if [ "$d" -eq 0 ]; then
            tc qdisc del dev "$IFACE" root 2>/dev/null || true
        else
            tc qdisc replace dev "$IFACE" root netem delay "${d}us"
        fi
        for nd in 0 1; do
            echo "=== sweep: RTT $((d * 2))us  TCP_NODELAY=$nd ==="
            run_arm "$nd" "$RES/nodelay$nd/sweep/d$d" "$ITERS_SWEEP" pytorch
        done
    done
    cleanup
    for nd in 0 1; do
        out="$RES/nodelay$nd/sweep/results-crosshost.csv"
        head -1 "$RES/nodelay$nd/sweep/d${DELAYS[0]}/results.csv" |
            awk -F, -v OFS=, '{ $3 = "rtt_us," $3; print }' > "$out"
        for d in "${DELAYS[@]}"; do
            tail -n +2 "$RES/nodelay$nd/sweep/d$d/results.csv" |
                awk -F, -v OFS=, -v r=$((d * 2)) '{ $3 = r "," $3; print }' >> "$out"
        done
        echo "sweep nodelay=$nd: $out"
    done
fi

echo "finished: $(date -Is)"
