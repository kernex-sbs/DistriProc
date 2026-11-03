#!/bin/bash
# eval/regime_sweep.sh — When does lazy restore beat moving the whole image?
# Sweeps RTT x bandwidth with netem (delay + rate) on loopback and compares
# full-net (stream image, then full restore) against lazy / prefetch /
# adaptive. full (local images, no transfer) is kept as the floor.
#
# Usage:  sudo bash eval/regime_sweep.sh
# Env:    WORKLOAD (pytorch), ITERS (5), DELAYS_US one-way ("0 100 500 1000"),
#         RATES ("100mbit 1gbit 10gbit"), LAZY_MAX_DELAY_US (250: demand-only
#         lazy beyond this exceeds the 30 s probe timeout),
#         MODES ("full,full-net,lazy-prefetch,lazy-adaptive,lazy-stream"),
#         SWEEP_NAME (regime)
# lazy-stream first records the demand-fault trace twice on an unshaped link
# (trace-a is streamed, trace-b only measures how stable the trace is).
# Output: eval/results/<SWEEP_NAME>/<workload>/d<delay>-<rate>/results.csv,
#         merged into .../<workload>/results.csv (+rtt_us,rate)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKLOAD="${WORKLOAD:-pytorch}"
OUT="$ROOT_DIR/eval/results/${SWEEP_NAME:-regime}/$WORKLOAD"
ITERS="${ITERS:-5}"
read -r -a DELAYS <<< "${DELAYS_US:-0 100 500 1000}"
read -r -a RATES <<< "${RATES:-100mbit 1gbit 10gbit}"
LAZY_MAX_DELAY_US="${LAZY_MAX_DELAY_US:-250}"
MODES="${MODES:-full,full-net,lazy-prefetch,lazy-adaptive,lazy-stream}"
export TRACE_DIR="$OUT/trace-a"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (tc + criu)"; exit 1; }

cleanup() { tc qdisc del dev lo root 2>/dev/null || true; }
trap cleanup EXIT INT TERM
echo "kernel: $(uname -r)  workload: $WORKLOAD  started: $(date -Is)"

if [[ ",$MODES," == *,lazy-stream* ]]; then
    tc qdisc del dev lo root 2>/dev/null || true
    for t in a b; do
        TRACE_DIR="$OUT/trace-$t" bash "$ROOT_DIR/eval/run_bench_env.sh" \
            --workloads "$WORKLOAD" --modes lazy-record --iterations 1 \
            --output-dir "$OUT/record-$t"
    done
    python3 - "$OUT/trace-a/$WORKLOAD.trace" "$OUT/trace-b/$WORKLOAD.trace" <<'PY'
import sys
a, b = (open(p, "rb").read() for p in sys.argv[1:])
a, b = ([x[i:i+8] for i in range(0, len(x), 8)] for x in (a, b))
print(f"trace: a={len(a)} b={len(b)} pages, {len(set(a) & set(b)) / len(set(a)):.1%} of a also in b")
PY
fi

for d in "${DELAYS[@]}"; do
    for r in "${RATES[@]}"; do
        # limit: enough queue for a full BDP at the slowest rate and longest delay
        tc qdisc replace dev lo root netem delay "${d}us" rate "$r" limit 100000
        modes="$MODES"
        [ "$d" -le "$LAZY_MAX_DELAY_US" ] && modes="$modes,lazy"
        echo "=== RTT $((d * 2))us  rate $r  modes $modes ==="
        DISTRIPROC_TCP_NODELAY=1 bash "$ROOT_DIR/eval/run_bench_env.sh" \
            --workloads "$WORKLOAD" --modes "$modes" --iterations "$ITERS" \
            --output-dir "$OUT/d$d-$r"
    done
done
cleanup

merged="$OUT/results.csv"
first=$(ls "$OUT"/d*-*/results.csv | head -1)
head -1 "$first" | awk -F, -v OFS=, '{ $3 = "rtt_us,rate," $3; print }' > "$merged"
for d in "${DELAYS[@]}"; do
    for r in "${RATES[@]}"; do
        tail -n +2 "$OUT/d$d-$r/results.csv" |
            awk -F, -v OFS=, -v t=$((d * 2)) -v r="$r" '{ $3 = t "," r "," $3; print }' >> "$merged"
    done
done
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER:" "$ROOT_DIR/eval/results/${SWEEP_NAME:-regime}"
echo "merged: $merged  finished: $(date -Is)"
