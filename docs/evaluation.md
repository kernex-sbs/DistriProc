# DistriProc Final Evaluation

**System**: AMD Ryzen 7 7735HS (8 cores), 15 GB RAM, mainline Linux 6.18.7, CRIU 4.2, CPU PyTorch 2.12
**Transport**: TCP loopback (127.0.0.1), plus injected RTT via `netem` (§5)
**Iterations**: 20 per configuration (RTT sweep: 10)
**Reproducible**: `sudo bash eval/run_bench_env.sh --iterations 20` then `make report && make figures` (see `REPRODUCE.md`)

The paper (`paper/paper.tex`) is the canonical write-up; this file is a quick
numeric reference. Raw data: `eval/results/results.csv` (loopback matrix),
`eval/results/crosshost*/` (RTT sweeps), `eval/results/kernel7/` (7.0.9).

---

## 1. Setup

| Workload | Description | Working set |
|----------|-------------|-------------|
| `test_loop` | C process, 1 MB heap, 1 Hz counter loop | ~266 pages |
| `redis` | Redis/valkey, 10,000 keys (~13.77 MB) | ~293 pages at checkpoint |
| `pytorch` | ResNet-18 in CPU memory, awaiting inference | ~15,515 pages (~61 MB) |

Modes: `full` (CRIU full restore), `lazy` (`--no-prefetch`), `lazy-prefetch`
(`--prefetch-seq 16 --prefetch-stride 8`), `lazy-adaptive` (+`--adaptive-prefetch`).

---

## 2. Time-to-First-Request (ms, ± 95% CI, n = 20)

| Workload | Full | Lazy | Fixed prefetch | Adaptive |
|----------|------|------|----------------|----------|
| test_loop | 1019 ± 2 | 42 ± 1 | 43 ± 3 | 42 ± 2 |
| Redis | 32 ± 2 | 37 ± 2 | 39 ± 2 | 38 ± 2 |
| PyTorch | 191 ± 7 | 650 ± 10 | **1227 ± 24** | **655 ± 9** |

- test_loop: lazy is **24.5×** faster than full.
- PyTorch: fixed prefetch **+88%** over lazy (Welch *t* = −45.9, *p* < 1e-9);
  adaptive recovers to **655 ms**, indistinguishable from lazy (*t* = −0.82,
  *p* = 0.42) and far better than fixed (*t* = +46.1).

---

## 3. The Fixed-Prefetch Paradox (PyTorch, loopback)

Fixed prefetch reduces page faults **85%** (15,515 → 2,322) yet **increases** TTFR 88%.

| Mode | Faults | Prefetched | TTFR |
|------|--------|-----------|------|
| lazy | 15,515 | 0 | 650 ms |
| lazy-prefetch | 2,322 | 788 | 1227 ms |
| lazy-adaptive | 15,496 | 1,466 | 655 ms |

Fewer faults ≠ lower latency: the async prefetch worker builds a large queue of
outstanding TCP reads on the secondary connection, congesting shared socket
buffers and slowing the primary fault path. Fault count is not a proxy for TTFR.

---

## 4. Adaptive Controller Decisions

The controller (bounded queue Q = 8192; disable at dup ≥ 80% or q > Q/2; halve at
50% or Q/4; grow when dup = 0 and q < Q/32; 16-window cooldown) disables prefetch
in the **first** 128-fault window on both memory-heavy workloads:

| Workload | Window | Dup rate | Queue depth | Decision |
|----------|--------|----------|-------------|----------|
| PyTorch | 1 | 97% | 1,454 | **off** (16-window cooldown) |
| Redis | 1 | 98% | 541 | **off** |

Adaptive's PyTorch fault count (15,496) ≈ lazy's (15,515): it backs off before
congestion accumulates.

---

## 5. RTT Crossover (PyTorch, netem on loopback, n = 10)

The paradox is specific to the congestion-bound, near-zero-RTT regime. Inject RTT
and prefetch flips from harmful to beneficial near **~125 µs**:

| RTT | Lazy | Fixed prefetch | Adaptive | Fixed vs Lazy |
|-----|------|------|----------|------|
| 0 (loopback) | 626 | 1198 | 640 | +91% |
| 60 µs | 1649 | 2346 | 1642 | +42% |
| 100 µs | 2300 | 2455 | 2230 | +7% |
| 150 µs | 3126 | 2919 | 3208 | −7% |
| 1 ms | 16700 | 10462 | 10906 | −37% |
| 2 ms | timeout | 12807 | 16409 | — |

Above the crossover, demand-only lazy serializes one RTT per fault; fixed prefetch
hides it and wins. The controller tracks lazy throughout — optimal below the
crossover, conservative above it (leaves 10–20%; an RTT-aware policy is future work).

---

## 6. Cross-Kernel Robustness (PyTorch, loopback, n = 20)

The paradox and the controller's recovery hold on both kernels; magnitude differs:

| Kernel | Full | Lazy | Fixed | Adaptive | Regression |
|--------|------|------|-------|----------|-----------|
| Linux 6.18.7 | 191 | 650 | 1227 | 655 | +88% |
| Linux 7.0.9 | 176 | 1944 | 2654 | 1907 | +37% |

7.0.9 has a ~3× higher lazy baseline and ~half the relative regression, but it is
still highly significant (*t* = −12.7), and adaptive recovers to lazy parity
(*t* = 0.89, ns; beats fixed *t* = 15.0).

---

## 7. Prefetch Volume + Throughput

Prefetch volume (mean pages): test_loop 76 → 35 (−55%), Redis 1255 → 602 (−52%),
PyTorch 788 → 1466 (**+86%** — the controller re-enables after its cooldown, once
the fault storm is over, so aggregate volume exceeds fixed; the win on PyTorch is
TTFR, not volume).

Throughput (% of full): test_loop 100%, Redis 84–85% (TCP loopback overhead, not a
policy effect), PyTorch 102–103% (CPU-bound, measured after the remote-memory phase).

---

## 8. Known Limitations

1. **Transport.** Baseline is loopback; §5 injects RTT but on one host (not two
   physical machines), and RDMA is untested.
2. **Controller is not RTT-aware.** It disables on congestion signals, so above the
   crossover it is conservative (at 2 ms RTT, worse than fixed prefetch).
3. **Hit rate = 0%** for all modes (async prefetch installs before the fault fires);
   the controller uses duplicate pressure + queue depth instead. Do not cite hit rate.
4. **No writable coherence** — `UFFDIO_COPY` pages are local copies.
5. **Heuristic thresholds** set by inspection (ablation in the paper shows TTFR is
   flat across them); not cross-validated against a holdout workload.
