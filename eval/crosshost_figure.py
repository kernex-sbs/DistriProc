#!/usr/bin/env python3
"""eval/crosshost_figure.py — the RTT-crossover figure (fig6).

Remade from scratch to match the house style of eval/figures.py (the
"BeautifulFigures" principles, A. Churkin): the shared muted palette, decluttered
axes (top/right spines dropped, softened grey spines), subtle grids behind the
data, a frameon-less legend placed in the empty upper-left, no in-figure title
(the caption carries the message), and vector output. Importing eval/figures.py
applies its rcParams and reuses its exact COLORS/EDGECOLORS so this figure is
visually consistent with fig1-fig5.

Plots PyTorch TTFR vs. injected RTT (log-log) for lazy / fixed prefetch /
adaptive from the netem sweeps, marks the 100-150 us crossover band, and overlays
the real two-machine LAN run (stars) from eval/results/crosshost-2machine/.

    ./venv-cpu/bin/python eval/crosshost_figure.py
"""
import csv
import os
import statistics as st
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

# Reuse the shared palette + rcParams (importing applies figures.py rcParams).
from figures import COLORS, EDGECOLORS, LABELS, THRESHOLD_COLOR, TEXT_COLOR

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "eval/results/figures")
MODES = ["lazy", "lazy-prefetch", "lazy-adaptive"]
REGIME_COLOR = "#666666"


def load_netem():
    """Merge coarse + fine netem sweeps: {(rtt_us, mode): [ttfr,...]}."""
    d = defaultdict(list)
    for sub in ("crosshost", "crosshost-fine"):
        p = os.path.join(ROOT, "eval/results", sub, "results-crosshost.csv")
        if not os.path.exists(p):
            continue
        for r in csv.DictReader(open(p)):
            v = int(r["ttfr_ms"])
            if v >= 0:
                d[(int(r["rtt_us"]), r["mode"])].append(v)
    return d


def load_2machine():
    """Real two-machine run: (rtt_us, {mode: mean_ttfr})."""
    p = os.path.join(ROOT, "eval/results", "crosshost-2machine", "results.csv")
    if not os.path.exists(p):
        return None
    vals, rtt = defaultdict(list), None
    for r in csv.DictReader(open(p)):
        v = int(r["ttfr_ms"])
        if v >= 0:
            vals[r["mode"]].append(v)
            rtt = int(r["rtt_us"])
    return rtt, {m: st.mean(xs) for m, xs in vals.items() if xs}


def main():
    d = load_netem()
    rtts = sorted({k[0] for k in d})

    def series(mode):
        xs, ys = [], []
        for rt in rtts:
            vals = d.get((rt, mode))
            if vals:
                xs.append(rt if rt > 0 else 10)  # show loopback at 10us on log axis
                ys.append(st.mean(vals))
        return xs, ys

    fig, ax = plt.subplots(figsize=(7.0, 4.3))

    # Crossover band first, so it sits behind the data.
    ax.axvspan(100, 150, color=THRESHOLD_COLOR, alpha=0.07, zorder=0)
    ax.axvline(125, color=THRESHOLD_COLOR, linewidth=1.0, linestyle=(0, (5, 4)),
               alpha=0.55, zorder=1)

    # Netem sweep lines.
    line_handles = []
    for m in MODES:
        xs, ys = series(m)
        (ln,) = ax.plot(xs, ys, marker="o", markersize=5, linewidth=1.8,
                        color=COLORS[m], markeredgecolor=EDGECOLORS[m],
                        markeredgewidth=0.7, label=LABELS[m], zorder=3)
        line_handles.append(ln)

    # Real two-machine overlay: lazy + fixed stars (their contrast is the point;
    # adaptive overlaps fixed and is in the table).
    tm = load_2machine()
    if tm:
        tm_rtt, tm_means = tm
        for m in ("lazy", "lazy-prefetch"):
            if m in tm_means:
                ax.scatter(tm_rtt, tm_means[m], marker="*", s=230,
                           color=COLORS[m], edgecolor="black", linewidth=0.7,
                           zorder=6)
        if "lazy-prefetch" in tm_means:
            ax.annotate(f"real LAN, {tm_rtt} µs",
                        xy=(tm_rtt, tm_means["lazy-prefetch"]),
                        xytext=(tm_rtt, tm_means["lazy-prefetch"] * 0.52),
                        fontsize=9, color=TEXT_COLOR, ha="center", va="top",
                        arrowprops=dict(arrowstyle="->", color=TEXT_COLOR, lw=0.8))

    # Axes: log-log, decluttered (match figures.py style_axes look).
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(8, 2600)
    ax.set_ylim(480, 23000)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#888888")
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=TEXT_COLOR, length=3, width=0.8)
    ax.grid(True, which="major", linestyle="-", linewidth=0.7, alpha=0.18)
    ax.grid(True, which="minor", linestyle="-", linewidth=0.4, alpha=0.08)

    ax.set_xlabel("Injected round-trip time (µs, log scale; leftmost = loopback)")
    ax.set_ylabel("PyTorch TTFR (ms, log scale)")

    # Crossover label, top, clear of the upper-left legend.
    ax.text(132, 19500, "crossover\n100–150 µs", color=THRESHOLD_COLOR,
            fontsize=9, ha="left", va="top")

    # Regime labels in the empty strips below the curves.
    ax.text(10, 530, "congestion-bound:\nprefetch harmful", color=REGIME_COLOR,
            fontsize=9, ha="left", va="bottom", style="italic")
    ax.text(2300, 560, "latency-bound:\nprefetch wins", color=REGIME_COLOR,
            fontsize=9, ha="right", va="bottom", style="italic")

    # Legend in the empty upper-left, with a neutral star proxy for the real run.
    star_proxy = Line2D([], [], marker="*", linestyle="none", markersize=12,
                        markerfacecolor="#9aa0a6", markeredgecolor="black",
                        markeredgewidth=0.7, label="Real two-machine (LAN)")
    ax.legend(handles=line_handles + [star_proxy], loc="upper left",
              frameon=False, handlelength=1.8, labelspacing=0.4)

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(OUT, f"fig6_crosshost_rtt.{fmt}"))
    plt.close(fig)
    print("fig6_crosshost_rtt — done")


if __name__ == "__main__":
    main()
