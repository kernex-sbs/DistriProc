#!/usr/bin/env python3
"""Generate the cross-host RTT-crossover figure (fig6) from the netem sweeps.

Merges eval/results/crosshost/ (coarse) and crosshost-fine/ into one
TTFR-vs-RTT plot for lazy / fixed-prefetch / adaptive, marking the crossover
where fixed prefetch flips from harmful to beneficial.

    ./venv-cpu/bin/python eval/crosshost_figure.py
"""
import csv, os, statistics as st
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

COLORS = {"lazy": "#6f9bd1", "lazy-prefetch": "#e0995e", "lazy-adaptive": "#5fa89f", "full": "#bdbdbd"}
LABELS = {"lazy": "Lazy (demand-only)", "lazy-prefetch": "Lazy + fixed prefetch",
          "lazy-adaptive": "Lazy + adaptive", "full": "Full restore"}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "eval/results/figures")

plt.rcParams.update({
    "font.family": "serif", "font.size": 12, "axes.labelsize": 12,
    "xtick.labelsize": 11, "ytick.labelsize": 11, "legend.fontsize": 10,
    "axes.linewidth": 0.8, "axes.edgecolor": "#888888",
    "figure.dpi": 150, "savefig.dpi": 300, "savefig.bbox": "tight",
})


def load():
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


def main():
    d = load()
    rtts = sorted({k[0] for k in d})
    modes = ["lazy", "lazy-prefetch", "lazy-adaptive"]

    def series(mode):
        xs, ys = [], []
        for rt in rtts:
            vals = d.get((rt, mode))
            if vals:
                xs.append(rt if rt > 0 else 10)  # place RTT=0 at 10us on log axis
                ys.append(st.mean(vals))
        return xs, ys

    fig, ax = plt.subplots(figsize=(7.0, 4.2))
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#888888")
    ax.grid(True, which="major", linestyle="-", linewidth=0.7, alpha=0.18)

    for m in modes:
        xs, ys = series(m)
        ax.plot(xs, ys, marker="o", markersize=5, linewidth=1.8,
                color=COLORS[m], label=LABELS[m], zorder=3)

    # Crossover band: prefetch flips between RTT 100 and 150 us.
    ax.axvspan(100, 150, color="#c0392b", alpha=0.08, zorder=0)
    ax.axvline(125, color="#c0392b", linewidth=1.0, linestyle="--", alpha=0.6, zorder=1)
    ax.text(125, ax.get_ylim()[1] * 0.92, " crossover\n ~125 us RTT",
            color="#c0392b", fontsize=9, va="top", ha="left")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Injected round-trip time (µs, log scale; leftmost = loopback)")
    ax.set_ylabel("PyTorch TTFR (ms, log scale)")
    ax.legend(frameon=False, loc="upper left")

    # Annotate the two regimes.
    ax.text(35, 480, "congestion-bound\n(prefetch harmful)", fontsize=8.5,
            color="#333333", ha="center")
    ax.text(330, 2600, "latency-bound\n(prefetch wins)", fontsize=8.5,
            color="#333333", ha="center")

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(OUT, f"fig6_crosshost_rtt.{fmt}"))
    plt.close(fig)
    print("fig6_crosshost_rtt — done")


if __name__ == "__main__":
    main()
