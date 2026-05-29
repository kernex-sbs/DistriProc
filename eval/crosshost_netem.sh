#!/bin/bash
# eval/crosshost_netem.sh — RTT-injection sensitivity for the fixed-prefetch
# paradox. Adds emulated network latency to the TCP page-fetch path with
# `tc netem` on the loopback interface, then runs the PyTorch matrix at each
# RTT. This exercises the real TCP stack under non-trivial latency without a
# second physical machine (true multi-host remains future work).
#
# netem applies to IP traffic on `lo`; the CRIU lazy-pages control socket is
# AF_UNIX and is unaffected. `full` restore uses no page server, so it serves
# as the zero-RTT reference at every setting.
#
# Usage:  sudo bash eval/crosshost_netem.sh
# Output: eval/results/crosshost/results-crosshost.csv  (adds rtt_us column)
#         eval/results/crosshost/d<us>/                 (per-RTT raw + logs)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XH_DIR="$ROOT_DIR/eval/results/${XH_SUBDIR:-crosshost}"
OUT_CSV="$XH_DIR/results-crosshost.csv"
IFACE=lo
ITERS="${ITERS:-10}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (tc + criu)"
    exit 1
fi
if ! command -v tc >/dev/null; then
    echo "ERROR: tc (iproute2) not found"
    exit 1
fi

mkdir -p "$XH_DIR"
echo "workload,mode,rtt_us,iteration,ttfr_ms,throughput_ops_sec,page_faults,pages_prefetched,prefetch_hits,hit_rate_pct,total_pages_served,eager_pages,checkpoint_time_ms" > "$OUT_CSV"

# Always strip any netem qdisc we added, even on error/interrupt.
cleanup() { tc qdisc del dev "$IFACE" root 2>/dev/null || true; }
trap cleanup EXIT INT TERM
cleanup   # start clean

# One-way delays in microseconds; RTT = 2 x delay.
# Override with e.g. DELAYS_US="0 15 30 50 75 100 150 250" to pin the crossover.
read -r -a DELAYS_US <<< "${DELAYS_US:-0 250 500 1000}"

for d in "${DELAYS_US[@]}"; do
    rtt=$(( d * 2 ))
    TAG="d${d}"
    LOG_DIR="$XH_DIR/$TAG"
    mkdir -p "$LOG_DIR"
    echo "=== netem one-way delay ${d}us (RTT ${rtt}us) on ${IFACE} ==="
    if [ "$d" -eq 0 ]; then
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
    else
        tc qdisc replace dev "$IFACE" root netem delay "${d}us"
    fi
    tc qdisc show dev "$IFACE" | sed 's/^/  qdisc: /'

    bash "$ROOT_DIR/eval/run_bench_env.sh" \
        --workloads pytorch \
        --modes full,lazy,lazy-prefetch,lazy-adaptive \
        --iterations "$ITERS" \
        --output-dir "$LOG_DIR" \
        2>&1 | tee "$LOG_DIR/bench.log"

    # Insert rtt_us between mode and iteration.
    tail -n +2 "$LOG_DIR/results.csv" | awk -F, -v r="$rtt" '
        { printf "%s,%s,%s", $1, $2, r;
          for (i = 3; i <= NF; i++) printf ",%s", $i;
          print "" }' >> "$OUT_CSV"
done

cleanup
echo
echo "=== cross-host sweep complete ==="
echo "results: $OUT_CSV"
echo
echo "mean TTFR (ms) by RTT and mode:"
awk -F, 'NR>1 { k=$3"|"$2; s[k]+=$5; n[k]++ }
         END { for (k in s){ split(k,a,"|"); printf "  RTT %5s us  %-14s %6.0f ms (n=%d)\n", a[1], a[2], s[k]/n[k], n[k] } }' "$OUT_CSV" | sort
