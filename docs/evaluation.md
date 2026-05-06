# DistriProc Final Evaluation

**Date**: 2026-05-07
**System**: AMD Ryzen 7 7735HS (8 cores), 15 GB RAM, Linux 6.18.7-arch1-1, CRIU 4.2
**Transport**: TCP loopback (127.0.0.1)
**Iterations**: 5 per configuration
**Reproducible**: `make bench-paper && make report && make figures`

This document records the final evaluation used for the paper. Raw data is in
`eval/results/results.csv`. Figures are in `eval/results/figures/`. For methodology
and full analysis see `paper/draft.md`.

---

## 1. Setup

### Workloads

| Workload | Description | Working set | TTFR probe |
|----------|-------------|------------|------------|
| `test_loop` | C process, 1MB heap, 1Hz counter loop | ~266 pages (~1 MB) | UDP ping |
| `redis` | Redis 7.x, 10,000 keys pre-loaded (~13.77 MB) | ~281 pages at checkpoint | `PING` |
| `pytorch` | ResNet-18 loaded in CPU memory, awaiting inference | ~15,743 pages (~61 MB) | Result file |

### Modes

| Mode | Handler flags | Description |
|------|--------------|-------------|
| `full` | *(none)* | CRIU full restore — all pages before execution |
| `lazy` | `--no-prefetch` | Demand-only paging |
| `lazy-prefetch` | `--prefetch-seq 16 --prefetch-stride 8` | Fixed async prefetch |
| `lazy-adaptive` | `--prefetch-seq 16 --prefetch-stride 8 --adaptive-prefetch` | Adaptive controller |

---

## 2. Time-to-First-Request

| Workload | Full | Lazy | Fixed prefetch | Adaptive |
|----------|------|------|----------------|----------|
| test\_loop | 1020 ± 2 ms | 48 ± 4 ms | 48 ± 4 ms | 49 ± 6 ms |
| Redis | 32 ± 1 ms | 46 ± 10 ms | 38 ± 9 ms | 44 ± 6 ms |
| PyTorch | 209 ± 11 ms | 625 ± 18 ms | **1159 ± 24 ms** | **686 ± 67 ms** |

*Figure: fig1\_pytorch\_ttfr.pdf (pytorch only), fig2\_ttfr\_all.pdf (all workloads)*

**test\_loop**: Lazy restore is 21× faster than full (48 ms vs. 1020 ms). All lazy modes
identical — the working set is too small for prefetch to matter.

**Redis**: Lazy marginally slower than full (46 vs. 32 ms). Fixed prefetch gives a small
TTFR reduction (38 ms) within variance. Adaptive is 44 ms. All modes comfortably pass H1.

**PyTorch**: Fixed prefetch doubles TTFR over demand-only (1159 vs. 625 ms, H1 FAIL).
Adaptive recovers to 686 ms (H1 PASS), 473 ms better than fixed prefetch, only 61 ms
worse than demand-only. See §4 for the mechanism.

---

## 3. Throughput

| Workload | Full | Lazy | Fixed prefetch | Adaptive |
|----------|------|------|----------------|----------|
| test\_loop | 1 op/s | 1 op/s (100%) | 1 op/s (100%) | 1 op/s (100%) |
| Redis | 107,146 op/s | 72,937 (68%) | 70,556 (66%) | 73,885 (69%) |
| PyTorch | 84 op/s | 84 (100%) | 82 (97%) | 79 (94%) |

**Redis throughput shortfall (~68%)**: All lazy modes achieve ~68–69% of full restore
throughput. This is a TCP transport overhead: Redis access patterns touch pages across
the full 13.77 MB working set, each requiring a TCP round-trip to the page server. This
is not a policy failure — all three lazy modes show roughly equal throughput. On RDMA or
a higher-bandwidth link this gap would shrink.

**PyTorch**: All modes converge after restore; throughput reflects CPU-bound inference.
Note: throughput is measured on the restored process after the remote-memory phase ends.

---

## 4. The Fixed Prefetch Paradox (PyTorch)

Fixed prefetch reduces PyTorch page faults by 60% (15,743 → 6,352) yet doubles TTFR.

| Mode | Faults | Prefetched | TTFR |
|------|--------|-----------|------|
| lazy | 15,743 | 0 | 625 ms |
| lazy-prefetch | 6,352 | 2,121 | 1,159 ms |
| lazy-adaptive | 15,888 | 1,695 | 686 ms |

Fewer faults do not imply lower latency. When the prefetch window is large relative to
the fault rate, the async prefetch worker builds a large queue of outstanding TCP reads
on the secondary connection. This congests shared kernel socket buffers, increasing
latency on the primary fault-resolution connection. The net effect: each of the
remaining 40% of faults takes longer to resolve, and total TTFR increases.

The adaptive controller's fault count (15,888 ≈ lazy's 15,743) proves it backed off
almost completely after the initial probe windows.

*Figure: fig4\_faults\_vs\_ttfr.pdf*

---

## 5. Prefetch Volume Reduction

| Workload | Fixed prefetch | Adaptive | Reduction |
|----------|----------------|----------|-----------|
| test\_loop | 76 pages | 32 pages | −58% |
| Redis | 1,579 pages | 874 pages | −45% |
| PyTorch | 2,121 pages | 1,695 pages | −20% |

Adaptive reduces prefetch volume on all workloads, even where fixed prefetch is harmless
(test\_loop, Redis). PyTorch reduction is smaller because prefetch volume accumulates
during the 5 probe windows before the controller disables.

*Figure: fig3\_prefetch\_volume.pdf*

---

## 6. Adaptive Controller Decisions

### PyTorch (5 windows before disable)

| Window | Dup rate | Queue depth | Decision |
|--------|----------|-------------|----------|
| 1 | 100% | 2,704 | on (reduce W,S) |
| 2 | 78% | 3,288 | on (reduce W,S) |
| 3 | 100% | 3,552 | on (reduce W,S) |
| 4 | 100% | 3,714 | on (reduce W,S) |
| 5 | 100% | 3,796 | **off** |

The controller reduces window and stride progressively over 4 windows before disabling.
By window 5, duplicate rate is 100% and queue depth has grown to 3,796.

### Redis (immediate disable)

| Window | Dup rate | Queue depth | Decision |
|--------|----------|-------------|----------|
| 1 | 94% | 821 | **off** |

Redis's random access pattern means sequential prefetch candidates are almost always
already served. The controller disables in a single window.

*Figure: fig5\_adaptive\_timeline.pdf*

---

## 7. Hypothesis Validation

### H1: TTFR < 1000 ms

| Workload | Mode | TTFR | Result |
|----------|------|------|--------|
| test\_loop | lazy | 48 ms | **PASS** |
| test\_loop | lazy-prefetch | 48 ms | **PASS** |
| test\_loop | lazy-adaptive | 49 ms | **PASS** |
| Redis | lazy | 46 ms | **PASS** |
| Redis | lazy-prefetch | 38 ms | **PASS** |
| Redis | lazy-adaptive | 44 ms | **PASS** |
| PyTorch | lazy | 625 ms | **PASS** |
| PyTorch | lazy-prefetch | 1159 ms | **FAIL** |
| PyTorch | lazy-adaptive | 686 ms | **PASS** |

Fixed prefetch fails H1 on PyTorch. All other modes pass. Adaptive recovers H1.

### H2: Throughput > 70% of full restore baseline

| Workload | Mode | Ratio | Result |
|----------|------|-------|--------|
| test\_loop | all lazy modes | 100% | **PASS** |
| PyTorch | all lazy modes | 94–100% | **PASS** |
| Redis | all lazy modes | 66–69% | **FAIL** |

Redis H2 FAIL reflects TCP loopback overhead on a high-throughput workload, not a
policy problem. All three lazy Redis modes fail equally — the gap is transport-layer,
not policy-layer. The paper acknowledges this as a known limitation.

---

## 8. Known Limitations

1. **TCP loopback only.** All numbers are best-case. Real network adds RTT and drops
   throughput further. RDMA would change the TTFR and throughput numbers substantially.

2. **Hit rate = 0% for all modes.** Async prefetch installs pages before faults fire, so
   no fault-to-hit correlation exists. The controller correctly uses duplicate pressure
   and queue depth instead. Do not cite hit rate as an adaptive success signal.

3. **PyTorch throughput measurement.** Throughput is measured after the remote-memory
   phase ends, on the restored process. It reflects CPU-bound inference speed, not
   steady-state behavior during page fetching.

4. **No writable coherence.** Pages installed via `UFFDIO_COPY` are local copies.
   Modifications are not propagated back to the page server.

5. **Single-machine.** Page server and restored process run on the same host. Real
   migration would expose network RTT, bandwidth contention, and kernel scheduling
   noise not present in loopback benchmarks.

6. **Controller not cross-validated.** Thresholds (DUP=70%, QDEPTH=500) were set by
   inspection on these three workloads. Behavior on unseen workloads is unknown.
