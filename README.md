# DistriProc — When Prefetch Hurts

**An RTT-dependent study of speculative paging in CRIU lazy restore, plus a
userspace runtime that acts on it.**

DistriProc is a research prototype built on `CRIU` and `userfaultfd`. It restores
Linux processes with lazy paging, serves missing pages over TCP, and runs an adaptive
controller that decides when to prefetch and when to back off — based on duplicate
pressure and queue depth signals observed during the post-restore remote-memory phase.

**Headline finding:** whether fixed sequential prefetch *helps or hurts* TTFR is
governed by round-trip time. At loopback RTT it **increases** PyTorch TTFR by
**88%** (650 → 1227 ms) — while *cutting page faults 85%*, so fault count is not a
proxy for latency. Inject RTT and the effect **crosses over near ~125 µs**: above
that, prefetch *reduces* TTFR (−37% at 1 ms; demand-only lazy times out at 2 ms).
The adaptive controller recovers the loopback regression (to within 5.5 ms of
demand-only lazy, p = 0.42) and is the right policy below the crossover.

## What It Does

After a CRIU lazy restore, a process's pages live on a remote page server. DistriProc
intercepts page faults via `userfaultfd`, fetches faulted pages synchronously, and
optionally prefetches additional pages asynchronously on a background thread. An
adaptive controller monitors per-window signals and disables prefetch when it detects
the policy is causing more harm than benefit.

Three modes are supported:

| Mode | Behavior |
|------|----------|
| `lazy` | Demand-only. Fetch exactly the faulted page, nothing more. |
| `lazy-prefetch` | Fixed sequential prefetch. Fetch nearby pages speculatively after each fault. |
| `lazy-adaptive` | Adaptive. Start with prefetch; back off when duplicate pressure or queue depth signal waste. |

## Final Evaluation Results

All numbers: 20 iterations, loopback TCP, AMD Ryzen 7 7735HS, mainline Linux
6.18.7, CRIU 4.2, CPU PyTorch 2.12. (The regression magnitude is
kernel-dependent — see *Cross-kernel* below.)

### Time-to-First-Request (ms) — lower is better

| Workload | Full restore | Lazy | Fixed prefetch | **Adaptive** |
|----------|-------------|------|----------------|-------------|
| test\_loop | 1019 ± 2 | 42 ± 1 | 43 ± 3 | **42 ± 2** |
| Redis | 32 ± 2 | 37 ± 2 | 39 ± 2 | **38 ± 2** |
| PyTorch | 191 ± 7 | 650 ± 10 | 1227 ± 24 ❌ | **655 ± 9** ✓ |

**Key results:**
- Lazy restore cuts TTFR **24.5×** for memory-light workloads (test\_loop: 1019 → 42 ms).
- At loopback, fixed prefetch **increases** PyTorch TTFR **88%** (650 → 1227 ms, Welch *t* = −45.9) by congesting the fault-path TCP channel — while reducing page faults 85% (15,515 → 2,322).
- Adaptive controller recovers to **655 ms**, statistically indistinguishable from demand-only lazy (*t* = −0.82, *p* = 0.42), and cuts prefetch volume 52–55% on the memory-light workloads.

### RTT crossover (PyTorch, netem on loopback, n = 10)

| RTT | Lazy | Fixed prefetch | verdict |
|-----|------|------|---------|
| 0 (loopback) | 626 | 1198 | prefetch **−91% worse** |
| ~125 µs | — | — | **crossover** |
| 1 ms | 16700 | 10462 | prefetch **+37% better** |
| 2 ms | timeout | 12807 | prefetch finishes; lazy doesn't |

The paradox is a property of the congestion-bound (near-zero-RTT) regime; above
the crossover prefetch's latency-hiding wins.

### Cross-kernel

The paradox and the controller's recovery hold on both kernels; only the
magnitude differs: **+88%** on Linux 6.18.7 vs **+37%** on Linux 7.0.9 (n = 20),
on a ~3× higher 7.0.9 lazy baseline.

### Throughput (% of full restore baseline)

| Workload | Lazy | Fixed prefetch | Adaptive |
|----------|------|----------------|----------|
| test\_loop | 100% | 100% | 100% |
| Redis | 84% | 84% | 85% |
| PyTorch | 103% | 103% | 102% |

Redis throughput shortfall (~84%) reflects TCP loopback overhead on a
high-throughput in-memory workload, not a policy effect.

## How It Works

```
Page Server (serves CRIU images)
        │
        │  TCP connection 1 — synchronous fault resolution
        │  TCP connection 2 — async prefetch (background thread)
        ▼
lazy_handler (userfaultfd)
        │
        ├── fault path: fetch page → UFFDIO_COPY → unblock process
        ├── prefetch path: queue candidates → worker → fetch → install
        └── adaptive controller: every 128 faults, check dup_rate + qdepth
                                  → disable prefetch if wasteful
                                  → re-enable via probe window when queue drains
```

## Quick Start

```bash
# Build
make all

# Non-root tests
make test

# Full paper benchmark (all workloads × 4 modes × 5 iterations).
# Use the env wrapper so root sees torch + pycriu and the protobuf backend
# is correct; running eval/bench.sh under bare sudo will fail to import deps.
sudo bash eval/run_bench_env.sh --iterations 5

# Generate report
make report

# Generate figures (requires matplotlib)
make figures
```

> **Reproducing the paper's results requires Linux 6.18.7.** See `REPRODUCE.md`
> for building/booting that kernel and the full run procedure.

## Lazy Handler Options

```
src/lazy_handler [OPTIONS]
  --images-dir DIR       CRIU images directory (required)
  --address ADDR         Page server address (default: 127.0.0.1)
  --port PORT            Page server port (default: 9999)
  --no-prefetch          Demand-only mode (lazy)
  --prefetch-seq N       Sequential prefetch window (default: 16)
  --prefetch-stride N    Stride prefetch window (default: 8)
  --adaptive-prefetch    Enable adaptive controller
  --hot-pages FILE       Eager-fetch hot pages at restore time
```

## Benchmark Options

```bash
sudo bash eval/bench.sh [OPTIONS]
  --workloads LIST    Comma-separated (default: test_loop,redis,pytorch)
  --modes LIST        Comma-separated (default: full,lazy,lazy-prefetch,lazy-adaptive,lazy-hot)
  --iterations N      Runs per config (default: 5)
  --output-dir DIR    Results directory (default: eval/results)
  --append            Append to existing results.csv instead of overwriting
```

## Project Structure

```
src/
  lazy_handler.c         Fault handler and adaptive policy runtime
  criu_page_server.py    CRIU-aware TCP page server
  hot_pages.py           Hot page profiler via /proc/pid/smaps
  hashset.h              Served-page tracking (open-addressing hash set)
  test_loop.c            Synthetic benchmark workload

eval/
  bench.sh               Benchmark harness
  lib.sh                 Shared helpers
  report.py              CSV → markdown report
  figures.py             CSV + logs → paper figures
  workloads/             Per-workload scripts (test_loop, redis, pytorch)
  results/
    results.csv          Final combined dataset (60 rows)
    report.md            Generated report
    figures/             Generated paper figures (fig1–fig5)

tests/                   Integration tests (run_tests.sh)
paper/
  draft.md               Paper draft
  CLAIMS.md              Locked claims and out-of-scope list
  TODO.md                Paper checklist
docs/
  howto.md               Detailed usage guide
  evaluation.md          Final evaluation results
```

## Requirements

- Linux 5.7+ (userfaultfd). **Paper numbers are canonical to Linux 6.18.7**;
  the prefetch regression is kernel-sensitive (see `REPRODUCE.md`).
- GCC, Python 3
- CRIU 4.x. On Arch: `sudo pacman -S criu` — this also installs the `pycriu`
  Python module (there is **no** `pip install criu` package; that command fails).
- For benchmarks: `redis` (`sudo pacman -S redis`), CPU `torch torchvision`
  (`pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision`),
  `matplotlib` (`pip install matplotlib`)
- For the paper PDF: [tectonic](https://tectonic-typesetting.github.io/)

### protobuf compatibility note

`pycriu` 4.2's image parser uses `FieldDescriptor.label`, removed from
protobuf 6.x's C/upb backend. The page server (`src/criu_page_server.py`)
restores it with a shim, but the benchmark must also force the pure-Python
protobuf backend:

```bash
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
```

`eval/run_bench_env.sh` sets this (and makes a CPU-torch venv + `pycriu`
visible to root) automatically — prefer it over calling `eval/bench.sh`
directly under `sudo`.

## Scope

This prototype operates on the post-restore phase only. Out of scope:
writable remote-memory coherence, RDMA transport, multi-node DSM, replication.

## License

MIT
