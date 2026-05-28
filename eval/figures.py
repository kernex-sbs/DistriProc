#!/usr/bin/env python3
"""eval/figures.py — Generate paper figures from benchmark CSV and handler logs.

Design follows the "BeautifulFigures" principles (A. Churkin): a harmonious
muted palette, decluttered axes, subtle grids behind the data, legends placed
outside the plotting area, and vector output. In-figure titles are omitted —
the paper captions carry the message.

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

# ── Palette ──────────────────────────────────────────────────────────────────
# Muted, harmonious fills with darker edge variants. Semantics: grey baseline,
# blue lazy, warm amber for the "costly" fixed prefetch, calm teal for adaptive.

COLORS = {
    "full":          "#bdbdbd",
    "lazy":          "#6f9bd1",
    "lazy-prefetch": "#e0995e",
    "lazy-adaptive": "#5fa89f",
}
EDGECOLORS = {
    "full":          "#8a8a8a",
    "lazy":          "#3f6fa3",
    "lazy-prefetch": "#b06a2e",
    "lazy-adaptive": "#357a71",
}
LABELS = {
    "full":          "Full restore",
    "lazy":          "Lazy (demand-only)",
    "lazy-prefetch": "Lazy + fixed prefetch",
    "lazy-adaptive": "Lazy + adaptive",
}
SHORT = {
    "full":          "Full\nrestore",
    "lazy":          "Lazy\n(demand)",
    "lazy-prefetch": "Lazy +\nprefetch",
    "lazy-adaptive": "Lazy +\nadaptive",
}

THRESHOLD_COLOR = "#c0392b"   # muted red for the H1 reference line
ANNOTATE_COLOR  = "#357a71"   # teal for reduction callouts
TEXT_COLOR      = "#333333"

plt.rcParams.update({
    "font.family":     "serif",
    "font.size":       12,
    "axes.titlesize":  13,
    "axes.labelsize":  12,
    "xtick.labelsize": 11,
    "ytick.labelsize": 11,
    "legend.fontsize": 10.5,
    "axes.linewidth":  0.8,
    "axes.edgecolor":  "#888888",
    "figure.dpi":      150,
    "savefig.dpi":     300,
    "savefig.bbox":    "tight",
    "svg.fonttype":    "none",
})

ERR_KW = {"linewidth": 1.0, "ecolor": "#555555"}


def style_axes(ax, ygrid=True):
    """Declutter an axis: drop top/right spines, soften the rest, subtle y-grid."""
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#888888")
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=TEXT_COLOR, length=3, width=0.8)
    if ygrid:
        ax.grid(True, axis="y", which="major", linestyle="-", linewidth=0.7, alpha=0.18)
        ax.minorticks_on()
        ax.grid(True, axis="y", which="minor", linestyle="-", linewidth=0.4, alpha=0.10)
        # No minor ticks on a categorical x-axis.
        ax.tick_params(axis="x", which="minor", bottom=False, top=False)


def colors_for(modes):
    return [COLORS[m] for m in modes]


def edges_for(modes):
    return [EDGECOLORS[m] for m in modes]


def save(fig, out, name):
    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(out, f"{name}.{fmt}"))
    plt.close(fig)
    print(f"{name} — done")


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
        mu, sd = ms(g[key]) if key in g else (0.0, 0.0)
        means.append(mu)
        errs.append(sd)

    fig, ax = plt.subplots(figsize=(6.2, 4.2))
    x = np.arange(len(modes))
    bars = ax.bar(x, means, yerr=errs, capsize=3, width=0.62,
                  color=colors_for(modes), edgecolor=edges_for(modes),
                  linewidth=1.0, error_kw=ERR_KW)

    ax.axhline(1000, color=THRESHOLD_COLOR, linewidth=1.1, linestyle=(0, (5, 4)),
               alpha=0.7, label="H1 threshold (1000 ms)")

    top = max(means) * 1.22
    for bar, mean, err in zip(bars, means, errs):
        if mean > 0:
            ax.text(bar.get_x() + bar.get_width() / 2, mean + err + top * 0.012,
                    f"{mean:.0f}", ha="center", va="bottom",
                    fontsize=10, color=TEXT_COLOR)

    ax.set_xticks(x)
    ax.set_xticklabels([SHORT[m] for m in modes])
    ax.set_ylabel("Time to first request (ms)")
    ax.set_ylim(0, top)
    ax.legend(loc="upper left", frameon=False)
    style_axes(ax)

    save(fig, out, "fig1_pytorch_ttfr")


# ── Figure 2: TTFR all workloads — grouped bar ───────────────────────────────

def fig_ttfr_all(rows, out):
    g = group(rows, "workload", "mode")
    workloads = ["test_loop", "redis", "pytorch"]
    modes = ["full", "lazy", "lazy-prefetch", "lazy-adaptive"]
    wl_labels = {"test_loop": "test_loop\n(synthetic)", "redis": "Redis\n(10k keys)",
                 "pytorch": "PyTorch\n(inference)"}

    n_mode = len(modes)
    width = 0.19
    x = np.arange(len(workloads))

    fig, ax = plt.subplots(figsize=(8.2, 4.6))

    for i, mode in enumerate(modes):
        means, errs = [], []
        for wl in workloads:
            key = (wl, mode)
            mu, sd = ms(g[key]) if key in g else (0.0, 0.0)
            means.append(mu)
            errs.append(sd)

        offset = (i - n_mode / 2 + 0.5) * width
        ax.bar(x + offset, means, width=width, yerr=errs, capsize=2.5,
               color=COLORS[mode], edgecolor=EDGECOLORS[mode], linewidth=0.8,
               label=LABELS[mode], error_kw=ERR_KW)

    ax.axhline(1000, color=THRESHOLD_COLOR, linewidth=1.1, linestyle=(0, (5, 4)),
               alpha=0.7, label="H1 threshold")
    ax.set_xticks(x)
    ax.set_xticklabels([wl_labels[w] for w in workloads])
    ax.set_ylabel("Time to first request (ms)")
    # Legend above the plot so it never sits on top of the bars.
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.01), ncol=5,
              frameon=False, columnspacing=1.4, handlelength=1.4)
    style_axes(ax)

    save(fig, out, "fig2_ttfr_all")


# ── Figure 3: Prefetch volume reduction ──────────────────────────────────────

def fig_prefetch_volume(rows, out):
    g = group(rows, "workload", "mode")
    workloads = ["test_loop", "redis", "pytorch"]
    wl_labels = {"test_loop": "test_loop", "redis": "Redis", "pytorch": "PyTorch"}
    modes = ["lazy-prefetch", "lazy-adaptive"]

    x = np.arange(len(workloads))
    width = 0.34

    fig, ax = plt.subplots(figsize=(6.2, 4.2))

    peak = 0.0
    for i, mode in enumerate(modes):
        means, errs = [], []
        for wl in workloads:
            key = (wl, mode)
            mu, sd = ms(g[key], "pages_prefetched") if key in g else (0.0, 0.0)
            means.append(mu)
            errs.append(sd)
        peak = max(peak, max(m + e for m, e in zip(means, errs)))

        offset = (i - 0.5) * width
        ax.bar(x + offset, means, width=width, yerr=errs, capsize=3,
               color=COLORS[mode], edgecolor=EDGECOLORS[mode], linewidth=0.9,
               label=LABELS[mode], error_kw=ERR_KW)

    # Reduction annotations.
    for j, wl in enumerate(workloads):
        pre_key, ada_key = (wl, "lazy-prefetch"), (wl, "lazy-adaptive")
        if pre_key in g and ada_key in g:
            pre_mu, _ = ms(g[pre_key], "pages_prefetched")
            ada_mu, _ = ms(g[ada_key], "pages_prefetched")
            if pre_mu > 0:
                pct = (pre_mu - ada_mu) / pre_mu * 100
                ax.text(j, max(pre_mu, ada_mu) + peak * 0.03, f"−{pct:.0f}%",
                        ha="center", va="bottom", fontsize=10.5,
                        color=ANNOTATE_COLOR, fontweight="bold")

    ax.set_xticks(x)
    ax.set_xticklabels([wl_labels[w] for w in workloads])
    ax.set_ylabel("Pages prefetched (mean per restore)")
    ax.set_ylim(0, peak * 1.18)          # volume is non-negative — no negative axis
    ax.legend(loc="upper left", frameon=False)
    style_axes(ax)

    save(fig, out, "fig3_prefetch_volume")


# ── Figure 4: pytorch — fault count vs TTFR ─────────────────────────────────

def fig_faults_vs_ttfr(rows, out):
    g = group(rows, "workload", "mode")
    modes = ["lazy", "lazy-prefetch", "lazy-adaptive"]
    x = np.arange(len(modes))

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(8.2, 4.2))

    # Left: page faults.
    faults = [ms(g[("pytorch", m)], "page_faults") if ("pytorch", m) in g else (0.0, 0.0)
              for m in modes]
    f_means = [f[0] for f in faults]
    ax1.bar(x, f_means, yerr=[f[1] for f in faults], capsize=3,
            color=colors_for(modes), edgecolor=edges_for(modes),
            linewidth=0.9, error_kw=ERR_KW)
    ax1.set_xticks(x)
    ax1.set_xticklabels([SHORT[m] for m in modes])
    ax1.set_ylabel("Page faults (mean)")
    top1 = max(f_means) * 1.18
    ax1.set_ylim(0, top1)
    for i, (mu, err) in enumerate(faults):
        ax1.text(i, mu + err + top1 * 0.012, f"{mu:.0f}",
                 ha="center", va="bottom", fontsize=9.5, color=TEXT_COLOR)
    style_axes(ax1)

    # Right: TTFR.
    ttfrs = [ms(g[("pytorch", m)]) if ("pytorch", m) in g else (0.0, 0.0) for m in modes]
    t_means = [t[0] for t in ttfrs]
    ax2.bar(x, t_means, yerr=[t[1] for t in ttfrs], capsize=3,
            color=colors_for(modes), edgecolor=edges_for(modes),
            linewidth=0.9, error_kw=ERR_KW)
    ax2.axhline(1000, color=THRESHOLD_COLOR, linewidth=1.1, linestyle=(0, (5, 4)),
                alpha=0.7, label="H1 threshold")
    ax2.set_xticks(x)
    ax2.set_xticklabels([SHORT[m] for m in modes])
    ax2.set_ylabel("TTFR (ms)")
    top2 = max(t_means) * 1.20
    ax2.set_ylim(0, top2)
    ax2.legend(loc="upper right", frameon=False)
    for i, (mu, err) in enumerate(ttfrs):
        ax2.text(i, mu + err + top2 * 0.012, f"{mu:.0f}",
                 ha="center", va="bottom", fontsize=9.5, color=TEXT_COLOR)
    style_axes(ax2)

    fig.tight_layout()
    save(fig, out, "fig4_faults_vs_ttfr")


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
                    "faults":   int(m.group(1)),
                    "dup":      int(m.group(2)),
                    "dup_rate": int(m.group(3)),
                    "qdepth":   int(m.group(4)),
                    "decision": m.group(5),
                })
    return windows


def fig_adaptive_timeline(logs_dir, out):
    # Use pytorch iter1 — most illustrative (5 windows before disable).
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

    on_fill,  on_edge  = COLORS["lazy-prefetch"], EDGECOLORS["lazy-prefetch"]
    off_fill, off_edge = COLORS["lazy-adaptive"], EDGECOLORS["lazy-adaptive"]
    fills = [on_fill if d == "on" else off_fill for d in decisions]
    edges = [on_edge if d == "on" else off_edge for d in decisions]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(7.2, 5.0), sharex=True)

    # Top: duplicate rate with the disable threshold.
    ax1.bar(x, dup_rates, color=fills, edgecolor=edges, linewidth=0.9, width=0.6)
    thr = ax1.axhline(80, color="#777777", linewidth=1.1, linestyle=(0, (5, 4)),
                      alpha=0.8, label="disable threshold (~80%)")
    ax1.set_ylabel("Duplicate rate (%)")
    ax1.set_ylim(0, 118)
    for i, dr in enumerate(dup_rates):
        ax1.text(i + 1, dr + 2, f"{dr}%", ha="center", va="bottom",
                 fontsize=9.5, color=TEXT_COLOR)
    style_axes(ax1)

    # Bottom: async queue depth.
    ax2.bar(x, qdepths, color=fills, edgecolor=edges, linewidth=0.9, width=0.6)
    ax2.set_ylabel("Async queue depth")
    ax2.set_xlabel("Control window (128 faults each)")
    ax2.set_xticks(x)
    ax2.set_ylim(0, max(qdepths) * 1.18)
    for i, qd in enumerate(qdepths):
        ax2.text(i + 1, qd + max(qdepths) * 0.02, f"{qd}", ha="center", va="bottom",
                 fontsize=9.5, color=TEXT_COLOR)
    style_axes(ax2)

    # One combined legend above the figure, outside the data.
    on_patch  = mpatches.Patch(facecolor=on_fill,  edgecolor=on_edge,  label="prefetch on")
    off_patch = mpatches.Patch(facecolor=off_fill, edgecolor=off_edge, label="prefetch off (disabled)")
    ax1.legend(handles=[on_patch, off_patch, thr], loc="lower center",
               bbox_to_anchor=(0.5, 1.02), ncol=3, frameon=False,
               columnspacing=1.4, handlelength=1.4)

    fig.tight_layout()
    save(fig, out, "fig5_adaptive_timeline")


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
