#!/bin/bash
# eval/ablate_dedup.sh — Causal test for the loopback "paradox" mechanism.
# 2x2: TCP_NODELAY {0,1} x prefetch-enqueue duplicate scan {linear, off},
# PyTorch fixed prefetch at RTT 0, plus a lazy baseline per NODELAY arm.
# Hypothesis: Nagle stalls the prefetch worker, the queue backs up, and the
# O(depth) scan in async_prefetch_enqueue taxes every fault. Then dedup=off
# with Nagle on should drop TTFR toward lazy.
#
# Usage:  sudo bash eval/ablate_dedup.sh          (ITERS default 10)
# Output: eval/results/ablate-dedup/nd<0|1>-dedup<1|0>/, .../nd<0|1>-lazy/
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT_DIR/eval/results/ablate-dedup"
ITERS="${ITERS:-10}"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }
tc qdisc del dev lo root 2>/dev/null || true
echo "kernel: $(uname -r)  started: $(date -Is)"

arm() {  # arm <nodelay> <dedup> <mode> <dir>
    DISTRIPROC_TCP_NODELAY="$1" DISTRIPROC_PREFETCH_DEDUP="$2" \
        bash "$ROOT_DIR/eval/run_bench_env.sh" --workloads pytorch \
        --modes "$3" --iterations "$ITERS" --output-dir "$OUT/$4"
}
for nd in 0 1; do
    arm "$nd" 1 lazy "nd$nd-lazy"
    arm "$nd" 1 lazy-prefetch "nd$nd-dedup1"
    arm "$nd" 0 lazy-prefetch "nd$nd-dedup0"
done

for d in "$OUT"/nd*; do
    printf '%-10s ttfr_ms ' "$(basename "$d")"
    awk -F, 'NR>1 && $4>=0 {s+=$4; n++} END {printf "%.0f (n=%d)  ", s/n, n}' "$d/results.csv"
    { grep -h "^Enqueue" "$d"/logs/*_handler.log 2>/dev/null || true; } |
        awk '{ms+=$4; dp+=$11; n++} END {if (n) printf "enqueue %.0f ms, depth %.0f (n=%d)", ms/n, dp/n, n}'
    echo
done
echo "finished: $(date -Is)"
