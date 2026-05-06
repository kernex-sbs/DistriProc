# DistriProc

**Adaptive post-restore remote memory for Linux processes.**

DistriProc is a research prototype built on `CRIU` and `userfaultfd`. It restores
Linux processes with lazy paging, serves missing pages over TCP, and runs an adaptive
controller that decides when to prefetch and when to back off — based on duplicate
pressure and queue depth signals observed during the post-restore remote-memory phase.

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

All numbers: 5 iterations, loopback TCP, AMD Ryzen 7 7735HS, Linux 6.18.7, CRIU 4.2.

### Time-to-First-Request (ms) — lower is better

| Workload | Full restore | Lazy | Fixed prefetch | **Adaptive** |
|----------|-------------|------|----------------|-------------|
| test\_loop | 1020 ± 2 | 48 ± 4 | 48 ± 4 | **49 ± 6** |
| Redis | 32 ± 1 | 46 ± 10 | 38 ± 9 | **44 ± 6** |
| PyTorch | 209 ± 11 | 625 ± 18 | 1159 ± 24 ❌ | **686 ± 67** ✓ |

**Key results:**
- Lazy restore cuts TTFR 21× for memory-light workloads (test\_loop: 1020 → 48 ms)
- Fixed prefetch doubles TTFR for memory-heavy workloads (PyTorch: 625 → 1159 ms) by congesting the fault-path TCP channel
- Adaptive controller recovers 473 ms of the PyTorch regression (1159 → 686 ms) and cuts prefetch volume 45–58% across all workloads

### Throughput (% of full restore baseline)

| Workload | Lazy | Fixed prefetch | Adaptive |
|----------|------|----------------|----------|
| test\_loop | 100% | 100% | 100% |
| Redis | 68% | 66% | 69% |
| PyTorch | 100% | 97% | 94% |

Redis throughput shortfall (~68%) reflects TCP loopback overhead on a
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

# Full paper benchmark (all workloads × 4 modes × 5 iterations)
make bench-paper

# Generate report
make report

# Generate figures (requires matplotlib)
make figures
```

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

- Linux 5.7+ (userfaultfd)
- GCC, Python 3, pycriu (`pip install criu`)
- CRIU 4.x
- For benchmarks: `redis`, `torch torchvision` (pip), `matplotlib` (pip)

## Scope

This prototype operates on the post-restore phase only. Out of scope:
writable remote-memory coherence, RDMA transport, multi-node DSM, replication.

## License

MIT
