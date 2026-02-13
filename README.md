# DistriProc

**Process-level remote paging for Linux.**

DistriProc enables Linux processes to execute with partially remote address spaces, fetching memory pages on-demand over TCP via userfaultfd. Instead of waiting for full memory migration (CRIU's 30-60s for large processes), DistriProc restores processes in sub-second time and pages in memory as needed.

## Key Results

| Workload | Lazy TTFR | Full TTFR | Throughput vs Baseline |
|----------|-----------|-----------|----------------------|
| Redis | 29ms | 28ms | 97% |
| PyTorch ResNet-18 | 718ms | 284ms | 102% |
| test_loop (1MB) | 33ms | 1020ms | 100% |

All workloads achieve **sub-second time-to-first-request** with **near-baseline throughput**.

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
  lazy_handler.c         Custom CRIU lazy-pages daemon with prefetching
  hashset.h              Page address tracking (open-addressing hash set)
  page_server.py         Simple TCP page server (test use)
  criu_page_server.py    CRIU-aware TCP page server (reads dump images)
  hot_pages.py           Hot page profiler via /proc/pid/smaps
  distriproc.sh          Orchestration wrapper

tests/                   8 test scripts (run_tests.sh runner)
eval/                    Benchmark suite (bench.sh, 3 workloads, report.py)
docs/
  proposal.md            Research proposal
  evaluation.md          Evaluation methodology and results
  howto.md               Usage guide and demos
```

## Requirements

- Linux 5.7+ (userfaultfd)
- GCC, Python 3
- CRIU 4.x with pycriu (`pip install criu`)
- For benchmarks: `redis` (pacman/apt), `torch torchvision` (pip)

## License

MIT
