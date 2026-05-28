#!/bin/bash
# eval/ablation_thresholds.sh — Sweep adaptive controller thresholds for §V.G.
#
# Holds dup_halve_pct = dup_disable_pct - 30 and sweeps dup_disable_pct over
# {30, 50, 70, 80, 90}. Runs the PyTorch workload in lazy-adaptive mode for
# n=5 per setting. Default (paper) is dup_disable=80, dup_halve=50.
#
# Usage:
#   sudo bash eval/ablation_thresholds.sh
#
# Output:
#   eval/results/ablation/results-ablation.csv  (workload,mode,dup_disable_pct,dup_halve_pct,iteration,ttfr_ms,...)
#   eval/results/ablation/logs/<setting>/...     (per-run handler logs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ABL_DIR="$ROOT_DIR/eval/results/ablation"
OUT_CSV="$ABL_DIR/results-ablation.csv"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (criu requires it)"
    exit 1
fi

mkdir -p "$ABL_DIR/logs"
echo "workload,mode,dup_disable_pct,dup_halve_pct,iteration,ttfr_ms,throughput_ops_sec,page_faults,pages_prefetched,prefetch_hits,hit_rate_pct,total_pages_served,eager_pages,checkpoint_time_ms" > "$OUT_CSV"

# Sweep: disable / halve pairs. Pair held at disable - 30 to keep gap constant.
SETTINGS=(
    "30 10"
    "50 20"
    "70 40"
    "80 50"   # paper default
    "90 60"
)

for setting in "${SETTINGS[@]}"; do
    read -r DISABLE HALVE <<< "$setting"
    TAG="d${DISABLE}_h${HALVE}"
    LOG_DIR="$ABL_DIR/logs/$TAG"
    mkdir -p "$LOG_DIR"

    echo "=== threshold setting: dup_disable=${DISABLE}%% dup_halve=${HALVE}%% ==="

    export DISTRIPROC_DUP_DISABLE_PCT="$DISABLE"
    export DISTRIPROC_DUP_HALVE_PCT="$HALVE"

    TMP_OUT="$LOG_DIR/results.csv"
    sudo -E bash "$ROOT_DIR/eval/bench.sh" \
        --workloads pytorch \
        --modes lazy-adaptive \
        --iterations 5 \
        --output-dir "$LOG_DIR" \
        2>&1 | tee "$LOG_DIR/bench.log"

    # Append rows with two extra columns inserted between mode and iteration.
    tail -n +2 "$TMP_OUT" | awk -F, -v d="$DISABLE" -v h="$HALVE" '
        { printf "%s,%s,%s,%s", $1, $2, d, h;
          for (i = 3; i <= NF; i++) printf ",%s", $i;
          print "" }
    ' >> "$OUT_CSV"

    unset DISTRIPROC_DUP_DISABLE_PCT
    unset DISTRIPROC_DUP_HALVE_PCT
done

echo
echo "=== ablation complete ==="
echo "results: $OUT_CSV"
echo
echo "summary (mean TTFR per setting):"
awk -F, 'NR>1 { key = $3 "/" $4; sum[key] += $6; n[key]++ }
         END { for (k in sum) printf "  dup_disable/halve = %s%%  mean_TTFR = %.0f ms  (n=%d)\n", k, sum[k]/n[k], n[k] }' "$OUT_CSV" | sort
