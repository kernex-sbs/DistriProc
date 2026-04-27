# DistriProc

**Adaptive post-restore remote memory for Linux processes.**

DistriProc is a research prototype built on `CRIU` and `userfaultfd`. It restores Linux processes quickly, serves missing pages over TCP, and is being extended into an adaptive runtime that chooses when to demand-page, prefetch, or eagerly install hot pages after restore.

## Project Status

The current repo already demonstrates:

- End-to-end lazy restore with a custom `userfaultfd` handler
- TCP page serving from CRIU images
- Baseline policy modes: demand paging, synchronous prefetch, and eager hot-page fetch
- Initial benchmark workloads and reports

The current repo does **not** yet claim:

- Writable remote-memory coherence
- A finished adaptive controller
- A complete paper-grade evaluation across real networks and tail latency

## Current Baseline Results

These numbers describe the current prototype baseline, not the final target paper:

| Workload | Lazy TTFR | Full TTFR | Notes |
|----------|-----------|-----------|-------|
| Redis | 29ms | 28ms | Demand paging matches full restore TTFR |
| PyTorch ResNet-18 | 718ms | 284ms | Restores under 1s, but startup faults are expensive |
| test_loop (1MB) | 33ms | 1020ms | Simple proof that post-restore paging works |

The main result so far is that **plain lazy restore works well, while synchronous prefetch is often harmful**. The next step is to replace fixed prefetching with an adaptive asynchronous policy.

## How It Works

```
Source Node                          Destination Node
┌──────────────┐                     ┌──────────────────────┐
│ criu dump     │                     │ criu restore         │
│    ↓          │                     │   --lazy-pages       │
│ Page Server   │◄── TCP pages ──────►│ lazy_handler (uffd)  │
│ (serves CRIU  │    on demand        │   ↓                  │
│  page images) │                     │ Process runs with    │
└──────────────┘                     │ on-demand paging     │
                                     └──────────────────────┘
```

1. **Checkpoint** process with CRIU (`criu dump`)
2. **Start page server** — parses CRIU images, serves pages over TCP
3. **Start lazy handler** — listens for userfaultfd from CRIU restore
4. **Restore** with `--lazy-pages` — process starts immediately
5. Page faults are intercepted by the handler, which fetches pages from the server

## Research Direction

The paper direction for this repo is:

`adaptive post-restore remote-memory runtime`

The intended contribution is not “remote paging exists,” because CRIU and prior memory-disaggregation systems already establish that. The intended contribution is a userspace runtime that adapts paging policy online for restored Linux processes based on fault behavior and network cost.

## Quick Start

```bash
# Build
make all

# Run tests (non-root tests only)
make test

# Run benchmarks (requires root for CRIU)
make bench-quick    # test_loop, 2 iterations
make bench          # all workloads, 5 iterations

# Generate report
make report
```

See [docs/howto.md](docs/howto.md) for detailed usage instructions.

## Project Structure

```
src/
  test_uffd.c           Phase 1 PoC — local userfaultfd page fault handling
  test_uffd_tcp.c        Phase 2 — TCP remote page fetching
  test_loop.c            Benchmark workload (1MB heap, counter loop)
  lazy_handler.c         Custom CRIU lazy-pages daemon and policy runtime
  hashset.h              Page address tracking (open-addressing hash set)
  page_server.py         Simple TCP page server (test use)
  criu_page_server.py    CRIU-aware TCP page server (reads dump images)
  hot_pages.py           Hot page profiler via /proc/pid/smaps
  distriproc.sh          Orchestration wrapper

tests/                   8 test scripts (run_tests.sh runner)
eval/                    Benchmark suite (bench.sh, 3 workloads, report.py)
docs/
  proposal.md            Paper direction and research plan
  evaluation.md          Baseline evaluation and current limitations
  howto.md               Usage guide and demos
```

## Requirements

- Linux 5.7+ (userfaultfd)
- GCC, Python 3
- CRIU 4.x with pycriu (`pip install criu`)
- For benchmarks: `redis` (pacman/apt), `torch torchvision` (pip)

## License

MIT
