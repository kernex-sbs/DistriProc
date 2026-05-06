#!/usr/bin/env python3
"""eval/report.py — Generate markdown report from benchmark CSV results.

Usage:
    python3 eval/report.py --input eval/results/results.csv --output eval/results/report.md
"""

import argparse
import csv
import os
import platform
import statistics
import subprocess
import sys
from collections import defaultdict
from datetime import datetime


def get_system_info():
    """Collect system information for the report header."""
    info = {}
    info["kernel"] = platform.release()
    info["arch"] = platform.machine()
    info["date"] = datetime.now().strftime("%Y-%m-%d %H:%M")

    # CPU model
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    info["cpu"] = line.split(":", 1)[1].strip()
                    break
    except (OSError, IndexError):
        info["cpu"] = platform.processor() or "unknown"

    # CRIU version
    try:
        result = subprocess.run(["criu", "--version"], capture_output=True, text=True)
        info["criu"] = result.stdout.strip().split("\n")[0]
    except (FileNotFoundError, IndexError):
        info["criu"] = "unknown"

    # Memory
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal"):
                    kb = int(line.split()[1])
                    info["memory"] = f"{kb // 1024} MB"
                    break
    except (OSError, ValueError):
        info["memory"] = "unknown"

    return info


def load_csv(path):
    """Load CSV and return list of row dicts with numeric conversions."""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Convert numeric fields
            for field in ["iteration", "ttfr_ms", "throughput_ops_sec", "page_faults",
                          "pages_prefetched", "prefetch_hits", "hit_rate_pct",
                          "total_pages_served", "eager_pages", "checkpoint_time_ms"]:
                try:
                    row[field] = float(row[field])
                except (ValueError, KeyError):
                    row[field] = 0.0
            rows.append(row)
    return rows


def group_by(rows, *keys):
    """Group rows by one or more keys. Returns dict of key-tuple -> [rows]."""
    groups = defaultdict(list)
    for row in rows:
        k = tuple(row[key] for key in keys)
        groups[k] = groups.get(k, [])
        groups[k].append(row)
    return groups


def mean_std(values):
    """Return (mean, stddev) for a list of numbers. Handles n<2 gracefully."""
    values = [v for v in values if v >= 0]  # Filter error values (-1)
    if not values:
        return (0.0, 0.0)
    m = statistics.mean(values)
    s = statistics.stdev(values) if len(values) > 1 else 0.0
    return (m, s)


def fmt_ms(mean, std):
    """Format mean +/- std in ms."""
    if mean <= 0:
        return "FAIL"
    return f"{mean:.0f} ± {std:.0f}"


def fmt_ops(mean, std):
    """Format ops/sec with stddev."""
    if mean <= 0:
        return "N/A"
    return f"{mean:.0f} ± {std:.0f}"


def generate_report(rows, output_path):
    """Generate the full markdown report."""
    sys_info = get_system_info()

    workloads = sorted(set(r["workload"] for r in rows))
    modes = []
    # Preserve logical order
    for m in ["full", "lazy", "lazy-prefetch", "lazy-adaptive", "lazy-hot"]:
        if any(r["mode"] == m for r in rows):
            modes.append(m)

    groups = group_by(rows, "workload", "mode")

    lines = []

    def add(line=""):
        lines.append(line)

    # ── Header ──────────────────────────────────────────────────────────
    add("# DistriProc Benchmark Report")
    add()
    add(f"Generated: {sys_info['date']}")
    add()
    add("## System Information")
    add()
    add(f"| Property | Value |")
    add(f"|----------|-------|")
    add(f"| Kernel | {sys_info['kernel']} |")
    add(f"| CPU | {sys_info['cpu']} |")
    add(f"| Memory | {sys_info['memory']} |")
    add(f"| Arch | {sys_info['arch']} |")
    add(f"| CRIU | {sys_info['criu']} |")
    add()

    # ── TTFR Comparison ─────────────────────────────────────────────────
    add("## Time-to-First-Request (TTFR)")
    add()
    add("| Workload | " + " | ".join(modes) + " |")
    add("|----------|" + "|".join(["-------"] * len(modes)) + "|")

    for wl in workloads:
        cells = []
        for mode in modes:
            key = (wl, mode)
            if key in groups:
                m, s = mean_std([r["ttfr_ms"] for r in groups[key]])
                cells.append(fmt_ms(m, s))
            else:
                cells.append("—")
        add(f"| {wl} | " + " | ".join(cells) + " |")
    add()

    # ── Throughput ──────────────────────────────────────────────────────
    add("## Throughput")
    add()
    add("| Workload | " + " | ".join(modes) + " |")
    add("|----------|" + "|".join(["-------"] * len(modes)) + "|")

    # Compute baseline (full mode) throughput for percentage
    baseline_tp = {}
    for wl in workloads:
        key = (wl, "full")
        if key in groups:
            m, _ = mean_std([r["throughput_ops_sec"] for r in groups[key]])
            baseline_tp[wl] = m

    for wl in workloads:
        cells = []
        for mode in modes:
            key = (wl, mode)
            if key in groups:
                m, s = mean_std([r["throughput_ops_sec"] for r in groups[key]])
                cell = fmt_ops(m, s)
                if mode != "full" and wl in baseline_tp and baseline_tp[wl] > 0:
                    pct = (m / baseline_tp[wl]) * 100
                    cell += f" ({pct:.0f}%)"
                cells.append(cell)
            else:
                cells.append("—")
        add(f"| {wl} | " + " | ".join(cells) + " |")
    add()

    # ── Checkpoint Time ─────────────────────────────────────────────────
    add("## Checkpoint Time")
    add()
    add("| Workload | Mean (ms) |")
    add("|----------|-----------|")
    for wl in workloads:
        all_ckpt = []
        for mode in modes:
            key = (wl, mode)
            if key in groups:
                all_ckpt.extend([r["checkpoint_time_ms"] for r in groups[key]])
        m, s = mean_std(all_ckpt)
        add(f"| {wl} | {fmt_ms(m, s)} |")
    add()

    # ── Page Fault Analysis ─────────────────────────────────────────────
    add("## Page Fault Analysis")
    add()
    add("| Workload | Mode | Faults | Prefetched | Hits | Hit Rate | Total Served | Eager |")
    add("|----------|------|--------|------------|------|----------|-------------|-------|")

    for wl in workloads:
        for mode in modes:
            if mode == "full":
                continue
            key = (wl, mode)
            if key not in groups:
                continue
            g = groups[key]
            faults_m, _ = mean_std([r["page_faults"] for r in g])
            pre_m, _ = mean_std([r["pages_prefetched"] for r in g])
            hits_m, _ = mean_std([r["prefetch_hits"] for r in g])
            hr_m, _ = mean_std([r["hit_rate_pct"] for r in g])
            total_m, _ = mean_std([r["total_pages_served"] for r in g])
            eager_m, _ = mean_std([r["eager_pages"] for r in g])

            add(f"| {wl} | {mode} | {faults_m:.0f} | {pre_m:.0f} | {hits_m:.0f} | {hr_m:.0f}% | {total_m:.0f} | {eager_m:.0f} |")
    add()

    # ── Hypothesis Validation ───────────────────────────────────────────
    add("## Hypothesis Validation")
    add()
    add("### H1: Time-to-first-request < 1000ms")
    add()
    add("| Workload | Mode | Mean TTFR (ms) | Result |")
    add("|----------|------|----------------|--------|")

    for wl in workloads:
        for mode in modes:
            if mode == "full":
                continue
            key = (wl, mode)
            if key not in groups:
                continue
            m, _ = mean_std([r["ttfr_ms"] for r in groups[key]])
            result = "PASS" if 0 < m < 1000 else "FAIL"
            add(f"| {wl} | {mode} | {m:.0f} | **{result}** |")
    add()

    add("### H2: Throughput > 70% of full restore baseline")
    add()
    add("| Workload | Mode | Throughput | Baseline | Ratio | Result |")
    add("|----------|------|------------|----------|-------|--------|")

    for wl in workloads:
        base = baseline_tp.get(wl, 0)
        for mode in modes:
            if mode == "full":
                continue
            key = (wl, mode)
            if key not in groups:
                continue
            m, _ = mean_std([r["throughput_ops_sec"] for r in groups[key]])
            if base > 0:
                ratio = m / base
                result = "PASS" if ratio >= 0.70 else "FAIL"
                add(f"| {wl} | {mode} | {m:.0f} | {base:.0f} | {ratio:.0%} | **{result}** |")
            else:
                add(f"| {wl} | {mode} | {m:.0f} | N/A | N/A | **N/A** |")
    add()

    # ── Research Questions ──────────────────────────────────────────────
    add("## Research Question Analysis")
    add()

    # RQ1: Lazy vs full restore TTFR
    add("### RQ1: How does lazy restore TTFR compare to full restore?")
    add()
    for wl in workloads:
        full_key = (wl, "full")
        lazy_key = (wl, "lazy")
        if full_key in groups and lazy_key in groups:
            full_m, _ = mean_std([r["ttfr_ms"] for r in groups[full_key]])
            lazy_m, _ = mean_std([r["ttfr_ms"] for r in groups[lazy_key]])
            if full_m > 0 and lazy_m > 0:
                overhead = lazy_m / full_m
                direction = f"{overhead:.1f}x slower" if overhead > 1 else f"{1/overhead:.1f}x faster"
                add(f"- **{wl}**: Full={full_m:.0f}ms, Lazy={lazy_m:.0f}ms → lazy is {direction}")
            else:
                add(f"- **{wl}**: Full={full_m:.0f}ms, Lazy={lazy_m:.0f}ms")
    add()

    # RQ2: Prefetching impact
    add("### RQ2: Does prefetching reduce page faults and improve hit rates?")
    add()
    for wl in workloads:
        lazy_key = (wl, "lazy")
        pre_key = (wl, "lazy-prefetch")
        if lazy_key in groups and pre_key in groups:
            lazy_faults, _ = mean_std([r["page_faults"] for r in groups[lazy_key]])
            pre_faults, _ = mean_std([r["page_faults"] for r in groups[pre_key]])
            pre_hr, _ = mean_std([r["hit_rate_pct"] for r in groups[pre_key]])
            change_pct = ((pre_faults - lazy_faults) / lazy_faults * 100) if lazy_faults > 0 else 0
            add(f"- **{wl}**: Faults {lazy_faults:.0f} → {pre_faults:.0f} ({change_pct:+.0f}%), hit rate {pre_hr:.0f}%")
    add()

    # RQ3: Hot page eager fetch impact
    add("### RQ3: Does eager hot page fetching improve TTFR further?")
    add()
    for wl in workloads:
        pre_key = (wl, "lazy-prefetch")
        hot_key = (wl, "lazy-hot")
        if pre_key in groups and hot_key in groups:
            pre_ttfr, _ = mean_std([r["ttfr_ms"] for r in groups[pre_key]])
            hot_ttfr, _ = mean_std([r["ttfr_ms"] for r in groups[hot_key]])
            eager_m, _ = mean_std([r["eager_pages"] for r in groups[hot_key]])
            improvement = ((pre_ttfr - hot_ttfr) / pre_ttfr * 100) if pre_ttfr > 0 else 0
            add(f"- **{wl}**: TTFR {pre_ttfr:.0f}ms → {hot_ttfr:.0f}ms ({improvement:+.0f}%), {eager_m:.0f} eager pages")
    add()

    # RQ5: Adaptive vs fixed prefetch
    add("### RQ5: Does adaptive backoff avoid prefetch waste while preserving TTFR?")
    add()
    for wl in workloads:
        pre_key = (wl, "lazy-prefetch")
        ada_key = (wl, "lazy-adaptive")
        if pre_key not in groups or ada_key not in groups:
            continue
        pre_ttfr, _ = mean_std([r["ttfr_ms"] for r in groups[pre_key]])
        ada_ttfr, _ = mean_std([r["ttfr_ms"] for r in groups[ada_key]])
        pre_dup, _ = mean_std([r["pages_prefetched"] for r in groups[pre_key]])
        ada_dup, _ = mean_std([r["pages_prefetched"] for r in groups[ada_key]])
        ttfr_delta = ada_ttfr - pre_ttfr
        prefetch_change = ((ada_dup - pre_dup) / pre_dup * 100) if pre_dup > 0 else 0
        add(f"- **{wl}**: TTFR {pre_ttfr:.0f}ms → {ada_ttfr:.0f}ms ({ttfr_delta:+.0f}ms), "
            f"prefetched pages {pre_dup:.0f} → {ada_dup:.0f} ({prefetch_change:+.0f}% volume)")
    add()

    # RQ4: Throughput cost of lazy restore
    add("### RQ4: What is the throughput cost of lazy restore?")
    add()
    for wl in workloads:
        base = baseline_tp.get(wl, 0)
        if base <= 0:
            continue
        for mode in ["lazy", "lazy-prefetch", "lazy-adaptive", "lazy-hot"]:
            key = (wl, mode)
            if key not in groups:
                continue
            m, _ = mean_std([r["throughput_ops_sec"] for r in groups[key]])
            ratio = (m / base * 100) if base > 0 else 0
            add(f"- **{wl}/{mode}**: {m:.0f}/{base:.0f} ops/sec = {ratio:.0f}% of baseline")
    add()

    # ── Write output ────────────────────────────────────────────────────
    report = "\n".join(lines) + "\n"

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        f.write(report)

    print(f"Report written to {output_path}")
    return report


def main():
    parser = argparse.ArgumentParser(description="Generate benchmark report from CSV")
    parser.add_argument("--input", required=True, help="Input CSV file")
    parser.add_argument("--output", required=True, help="Output markdown file")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"ERROR: {args.input} not found", file=sys.stderr)
        sys.exit(1)

    rows = load_csv(args.input)
    if not rows:
        print("ERROR: no data rows in CSV", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded {len(rows)} data rows")
    generate_report(rows, args.output)


if __name__ == "__main__":
    main()
