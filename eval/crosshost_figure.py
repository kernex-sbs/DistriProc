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


def load_2machine():
    """Real two-machine run: {mode: (rtt_us, mean_ttfr)} from results.csv."""
    p = os.path.join(ROOT, "eval/results", "crosshost-2machine", "results.csv")
    if not os.path.exists(p):
        return None
    vals = defaultdict(list)
    rtt = None
    for r in csv.DictReader(open(p)):
        v = int(r["ttfr_ms"])
        if v >= 0:
            vals[r["mode"]].append(v)
            rtt = int(r["rtt_us"])
    return rtt, {m: st.mean(xs) for m, xs in vals.items() if xs}


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

    # Overlay the real two-machine points (star markers) at the measured LAN RTT.
    tm = load_2machine()
    if tm:
        tm_rtt, tm_means = tm
        first = True
        # Only the lazy and fixed stars: their contrast (lazy on its curve, fixed
        # well below) is the message; adaptive overlaps fixed and is in the table.
        for m in ("lazy", "lazy-prefetch"):
            if m in tm_means:
                ax.scatter(tm_rtt, tm_means[m], marker="*", s=220,
                           color=COLORS[m], edgecolor="black", linewidth=0.7,
                           zorder=6, label="Real two-machine (LAN)" if first else None)
                first = False
        # Tag the fixed-prefetch star (the "emulation conservative" point is in
        # the caption). Short label, centered, kept inside the axes.
        if "lazy-prefetch" in tm_means:
            ax.annotate("real LAN\n%d µs" % tm_rtt,
                        xy=(tm_rtt, tm_means["lazy-prefetch"]),
                        xytext=(tm_rtt * 1.9, tm_means["lazy-prefetch"] * 0.62),
                        fontsize=8.5, color="#222222", ha="center", va="top",
                        arrowprops=dict(arrowstyle="->", color="#222222", lw=0.8))

    # Crossover band: prefetch flips between RTT 100 and 150 us.
    ax.axvspan(100, 150, color="#c0392b", alpha=0.08, zorder=0)
    ax.axvline(125, color="#c0392b", linewidth=1.0, linestyle="--", alpha=0.6, zorder=1)
    ax.text(125, ax.get_ylim()[1] * 0.92, " crossover\n ~125 us RTT",
            color="#c0392b", fontsize=9, va="top", ha="left")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Injected round-trip time (µs, log scale; leftmost = loopback)")
    ax.set_ylabel("PyTorch TTFR (ms, log scale)")
    ax.legend(loc="upper left", frameon=True, facecolor="white",
              framealpha=0.92, edgecolor="none")

    # Annotate the two regimes (placed in empty zones, clear of the curves/stars).
    ax.text(13, 430, "congestion-bound\n(prefetch harmful)", fontsize=8.5,
            color="#333333", ha="left")
    ax.text(1050, 1250, "latency-bound\n(prefetch wins)", fontsize=8.5,
            color="#333333", ha="center")

    for fmt in ("pdf", "png"):
        fig.savefig(os.path.join(OUT, f"fig6_crosshost_rtt.{fmt}"))
    plt.close(fig)
    print("fig6_crosshost_rtt — done")


if __name__ == "__main__":
    main()
