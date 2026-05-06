#!/usr/bin/env python3
"""eval/figures.py — Generate paper figures from benchmark CSV and handler logs.

Usage:
    python3 eval/figures.py \
        --csv eval/results/results.csv \
        --logs eval/results/logs \
        --out  eval/results/figures
"""

import argparse
import csv
import os
import re
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

# ── Style ────────────────────────────────────────────────────────────────────

COLORS = {
    "full":          "#888888",
    "lazy":          "#0072B2",
    "lazy-prefetch": "#D55E00",
    "lazy-adaptive": "#009E73",
}
HATCHES = {
    "full":          "",
    "lazy":          "",
    "lazy-prefetch": "///",
    "lazy-adaptive": "...",
}
LABELS = {
    "full":          "Full restore",
    "lazy":          "Lazy (demand-only)",
    "lazy-prefetch": "Lazy + fixed prefetch",
    "lazy-adaptive": "Lazy + adaptive",
}

plt.rcParams.update({
    "font.family":    "serif",
    "font.size":      11,
    "axes.titlesize": 12,
    "axes.labelsize": 11,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
    "legend.fontsize": 10,
    "figure.dpi":     150,
    "savefig.dpi":    300,
    "savefig.bbox":   "tight",
})

# ── Data helpers ─────────────────────────────────────────────────────────────

def load_csv(path):
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            for field in ["ttfr_ms", "throughput_ops_sec", "page_faults",
                          "pages_prefetched", "total_pages_served", "checkpoint_time_ms"]:
                try:
                    row[field] = float(row[field])
                except (ValueError, KeyError):
                    row[field] = 0.0
            rows.append(row)
    return rows


def group(rows, *keys):
    g = defaultdict(list)
    for r in rows:
        g[tuple(r[k] for k in keys)].append(r)
    return g


def ms(values, field="ttfr_ms"):
    vs = [v[field] for v in values if v[field] >= 0]
    if not vs:
        return 0.0, 0.0
    return statistics.mean(vs), (statistics.stdev(vs) if len(vs) > 1 else 0.0)


# ── Figure 1: pytorch TTFR — main claim figure ───────────────────────────────

def fig_pytorch_ttfr(rows, out):
    g = group(rows, "workload", "mode")
    modes = ["full", "lazy", "lazy-prefetch", "lazy-adaptive"]
    means, errs = [], []
    for m in modes:
        key = ("pytorch", m)
        if key in g:
            mu, sd = ms(g[key])
            means.append(mu)
            errs.append(sd)
        else:
            means.append(0.0)
            errs.append(0.0)

    fig, ax = plt.subplots(figsize=(6, 4))
    x = np.arange(len(modes))
    bars = ax.bar(x, means, yerr=errs, capsize=4, width=0.55,
                  color=[COLORS[m] for m in modes],
                  hatch=[HATCHES[m] for m in modes],
                  edgecolor="black", linewidth=0.8, error_kw={"linewidth": 1.2})

    # H1 threshold line
    ax.axhline(1000, color="red", linewidth=1, linestyle="--", alpha=0.7, label="H1 threshold (1000ms)")

    # Value labels
    for bar, mean in zip(bars, means):
        if mean > 0:
            ax.text(bar.get_x() + bar.get_width() / 2, mean + 15,
                    f"{mean:.0f}ms", ha="center", va="bottom", fontsize=9)

    ax.set_xticks(x)
    ax.set_xticklabels([LABELS[m] for m in modes], rotation=15, ha="right")
    ax.set_ylabel("Time to First Request (ms)")
    ax.set_title("PyTorch: TTFR across restore modes\n(lower is better)")
    ax.legend(loc="upper left")
    ax.set_ylim(0, max(means) * 1.25)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"fig1_pytorch_ttfr.{fmt}"))
    plt.close(fig)
    print("fig1_pytorch_ttfr — done")


# ── Figure 2: TTFR all workloads — grouped bar ───────────────────────────────

def fig_ttfr_all(rows, out):
    g = group(rows, "workload", "mode")
    workloads = ["test_loop", "redis", "pytorch"]
    modes = ["full", "lazy", "lazy-prefetch", "lazy-adaptive"]
    wl_labels = {"test_loop": "test_loop\n(synthetic)", "redis": "Redis\n(10k keys)", "pytorch": "PyTorch\n(inference)"}

    n_wl = len(workloads)
    n_mode = len(modes)
    width = 0.18
    x = np.arange(n_wl)

    fig, ax = plt.subplots(figsize=(8, 4.5))

    for i, mode in enumerate(modes):
        means, errs = [], []
        for wl in workloads:
            key = (wl, mode)
            if key in g:
                mu, sd = ms(g[key])
                means.append(mu)
                errs.append(sd)
            else:
                means.append(0.0)
                errs.append(0.0)

        offset = (i - n_mode / 2 + 0.5) * width
        ax.bar(x + offset, means, width=width, yerr=errs, capsize=3,
               color=COLORS[mode], hatch=HATCHES[mode],
               edgecolor="black", linewidth=0.7,
               label=LABELS[mode], error_kw={"linewidth": 1})

    ax.axhline(1000, color="red", linewidth=1, linestyle="--", alpha=0.7, label="H1 threshold")
    ax.set_xticks(x)
    ax.set_xticklabels([wl_labels[w] for w in workloads])
    ax.set_ylabel("Time to First Request (ms)")
    ax.set_title("TTFR by workload and restore mode (lower is better)")
    ax.legend(loc="upper right", ncol=2)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"fig2_ttfr_all.{fmt}"))
    plt.close(fig)
    print("fig2_ttfr_all — done")


# ── Figure 3: Prefetch volume reduction ──────────────────────────────────────

def fig_prefetch_volume(rows, out):
    g = group(rows, "workload", "mode")
    workloads = ["test_loop", "redis", "pytorch"]
    wl_labels = {"test_loop": "test_loop", "redis": "Redis", "pytorch": "PyTorch"}
    modes = ["lazy-prefetch", "lazy-adaptive"]

    x = np.arange(len(workloads))
    width = 0.32

    fig, ax = plt.subplots(figsize=(6, 4))

    for i, mode in enumerate(modes):
        means, errs = [], []
        for wl in workloads:
            key = (wl, mode)
            if key in g:
                mu, sd = ms(g[key], "pages_prefetched")
                means.append(mu)
                errs.append(sd)
            else:
                means.append(0.0)
                errs.append(0.0)

        offset = (i - 0.5) * width
        ax.bar(x + offset, means, width=width, yerr=errs, capsize=4,
               color=COLORS[mode], hatch=HATCHES[mode],
               edgecolor="black", linewidth=0.8,
               label=LABELS[mode], error_kw={"linewidth": 1})

    # Reduction annotations
    for j, wl in enumerate(workloads):
        pre_key = (wl, "lazy-prefetch")
        ada_key = (wl, "lazy-adaptive")
        if pre_key in g and ada_key in g:
            pre_mu, _ = ms(g[pre_key], "pages_prefetched")
            ada_mu, _ = ms(g[ada_key], "pages_prefetched")
            if pre_mu > 0:
                pct = (pre_mu - ada_mu) / pre_mu * 100
                ax.text(j, max(pre_mu, ada_mu) + 30, f"−{pct:.0f}%",
                        ha="center", va="bottom", fontsize=9, color="#009E73", fontweight="bold")

    ax.set_xticks(x)
    ax.set_xticklabels([wl_labels[w] for w in workloads])
    ax.set_ylabel("Pages prefetched (mean per restore)")
    ax.set_title("Prefetch volume: fixed vs adaptive\n(adaptive reduces unnecessary traffic)")
    ax.legend()
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"fig3_prefetch_volume.{fmt}"))
    plt.close(fig)
    print("fig3_prefetch_volume — done")


# ── Figure 4: pytorch — fault count vs TTFR ─────────────────────────────────

def fig_faults_vs_ttfr(rows, out):
    g = group(rows, "workload", "mode")
    modes = ["lazy", "lazy-prefetch", "lazy-adaptive"]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(8, 4))

    # Left: page faults
    faults = []
    for m in modes:
        key = ("pytorch", m)
        mu, sd = ms(g[key], "pages_prefetched") if key in g else (0.0, 0.0)
        fault_mu, fault_sd = ms(g[key]) if key in g else (0.0, 0.0)
        f_mu, f_sd = ms(g[key], "page_faults") if key in g else (0.0, 0.0)
        faults.append((f_mu, f_sd))

    x = np.arange(len(modes))
    ax1.bar(x, [f[0] for f in faults], yerr=[f[1] for f in faults], capsize=4,
            color=[COLORS[m] for m in modes], hatch=[HATCHES[m] for m in modes],
            edgecolor="black", linewidth=0.8, error_kw={"linewidth": 1})
    ax1.set_xticks(x)
    ax1.set_xticklabels([LABELS[m] for m in modes], rotation=15, ha="right")
    ax1.set_ylabel("Page faults (mean)")
    ax1.set_title("Page faults")
    ax1.spines["top"].set_visible(False)
    ax1.spines["right"].set_visible(False)
    # Label values
    for i, (f_mu, _) in enumerate(faults):
        ax1.text(i, f_mu + 100, f"{f_mu:.0f}", ha="center", va="bottom", fontsize=8)

    # Right: TTFR
    ttfrs = []
    for m in modes:
        key = ("pytorch", m)
        ttfrs.append(ms(g[key]) if key in g else (0.0, 0.0))

    ax2.bar(x, [t[0] for t in ttfrs], yerr=[t[1] for t in ttfrs], capsize=4,
            color=[COLORS[m] for m in modes], hatch=[HATCHES[m] for m in modes],
            edgecolor="black", linewidth=0.8, error_kw={"linewidth": 1})
    ax2.axhline(1000, color="red", linewidth=1, linestyle="--", alpha=0.7)
    ax2.set_xticks(x)
    ax2.set_xticklabels([LABELS[m] for m in modes], rotation=15, ha="right")
    ax2.set_ylabel("TTFR (ms)")
    ax2.set_title("TTFR")
    ax2.spines["top"].set_visible(False)
    ax2.spines["right"].set_visible(False)
    for i, (t_mu, _) in enumerate(ttfrs):
        ax2.text(i, t_mu + 10, f"{t_mu:.0f}ms", ha="center", va="bottom", fontsize=8)

    fig.suptitle("PyTorch: fewer faults ≠ better TTFR\n(fixed prefetch reduces faults 60% but doubles TTFR)",
                 fontsize=11)
    plt.tight_layout()

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"fig4_faults_vs_ttfr.{fmt}"))
    plt.close(fig)
    print("fig4_faults_vs_ttfr — done")


# ── Figure 5: Adaptive controller timeline ───────────────────────────────────

def parse_policy_log(log_path):
    """Parse Policy: lines from a handler log. Returns list of window dicts."""
    windows = []
    pattern = re.compile(
        r"Policy: faults=(\d+).*?dup=(\d+) dup_rate=(\d+)%.*?qdepth=(\d+).*?=> prefetch=(on|off)"
    )
    with open(log_path) as f:
        for line in f:
            m = pattern.search(line)
            if m:
                windows.append({
                    "faults":    int(m.group(1)),
                    "dup":       int(m.group(2)),
                    "dup_rate":  int(m.group(3)),
                    "qdepth":    int(m.group(4)),
                    "decision":  m.group(5),
                })
    return windows


def fig_adaptive_timeline(logs_dir, out):
    # Use pytorch iter1 — most illustrative (5 windows before disable)
    log_path = os.path.join(logs_dir, "pytorch_lazy-adaptive_iter1_handler.log")
    if not os.path.exists(log_path):
        print("fig5_adaptive_timeline — log not found, skipping")
        return

    windows = parse_policy_log(log_path)
    if not windows:
        print("fig5_adaptive_timeline — no policy lines found, skipping")
        return

    n = len(windows)
    x = np.arange(1, n + 1)
    dup_rates = [w["dup_rate"] for w in windows]
    qdepths   = [w["qdepth"] for w in windows]
    decisions = [w["decision"] for w in windows]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(7, 5), sharex=True)

    # Top: dup_rate
    bar_colors = ["#D55E00" if d == "on" else "#009E73" for d in decisions]
    ax1.bar(x, dup_rates, color=bar_colors, edgecolor="black", linewidth=0.7, width=0.6)
    ax1.axhline(80, color="gray", linewidth=1, linestyle="--", alpha=0.7, label="threshold ~80%")
    ax1.set_ylabel("Duplicate rate (%)")
    ax1.set_ylim(0, 115)
    ax1.set_title("Adaptive controller: per-window decisions (PyTorch, iteration 1)")
    ax1.legend(loc="upper right")
    ax1.spines["top"].set_visible(False)
    ax1.spines["right"].set_visible(False)
    for i, (dr, dec) in enumerate(zip(dup_rates, decisions)):
        ax1.text(i + 1, dr + 2, f"{dr}%", ha="center", va="bottom", fontsize=8)

    # Bottom: queue depth
    ax2.bar(x, qdepths, color=bar_colors, edgecolor="black", linewidth=0.7, width=0.6)
    ax2.set_ylabel("Async queue depth")
    ax2.set_xlabel("Control window (128 faults each)")
    ax2.spines["top"].set_visible(False)
    ax2.spines["right"].set_visible(False)
    for i, qd in enumerate(qdepths):
        ax2.text(i + 1, qd + 20, f"{qd}", ha="center", va="bottom", fontsize=8)

    # Legend
    on_patch  = mpatches.Patch(color="#D55E00", label="prefetch=on")
    off_patch = mpatches.Patch(color="#009E73", label="prefetch=off (disabled)")
    ax2.legend(handles=[on_patch, off_patch], loc="upper left")

    plt.tight_layout()

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"fig5_adaptive_timeline.{fmt}"))
    plt.close(fig)
    print("fig5_adaptive_timeline — done")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv",  default="eval/results/results.csv")
    parser.add_argument("--logs", default="eval/results/logs")
    parser.add_argument("--out",  default="eval/results/figures")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)

    rows = load_csv(args.csv)
    print(f"Loaded {len(rows)} rows")

    fig_pytorch_ttfr(rows, args.out)
    fig_ttfr_all(rows, args.out)
    fig_prefetch_volume(rows, args.out)
    fig_faults_vs_ttfr(rows, args.out)
    fig_adaptive_timeline(args.logs, args.out)

    print(f"\nAll figures written to {args.out}/")


if __name__ == "__main__":
    main()
