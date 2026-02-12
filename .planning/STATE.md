# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-09)

**Core value:** Indefinite execution with remote memory.
**Current focus:** Phase 5 — Evaluation

## Current Position

Phase: 5 of 5 (Evaluation)
Plan: 0 of 1 in current phase
Status: Pending
Last activity: 2026-02-13 - Completed Phase 4 (Performance Tuning)

Progress: ▓▓▓▓▓▓▓▓░░ 80%

## Performance Metrics

**Velocity:**
- Total plans completed: 6
- Average duration: ~15 min
- Total execution time: ~1.5 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1. Basic userfaultfd PoC | 1 | 10m | 10m |
| 2. TCP Transport | 1 | 15m | 15m |
| 3. CRIU Integration | 2 | ~30m | ~15m |
| 4. Performance Tuning | 2 | ~30m | ~15m |

**Recent Trend:**
- Last 5 plans: 10m, 15m, ~15m, ~15m, ~15m
- Trend: Stable

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Phase 4: Pipelined prefetch (send all requests, then recv all) for latency hiding.
- Phase 4: Fibonacci hashing with atomic ops for lock-free hashset (no mutex needed).
- Phase 4: Eager fetch on separate TCP connection to avoid contention with fault handler.
- Phase 4: Only hashset_insert on successful UFFDIO_COPY to prevent false hits causing deadlocks.
- Phase 3: Custom lazy_handler replaces CRIU's built-in lazy-pages daemon.
- Phase 3: CRIU page server (Python) reads pagemap-*.img to serve pages over TCP.
- Phase 2: Implemented simple TCP request/response protocol for page fetching.
- Phase 1: Used UFFD_USER_MODE_ONLY flag to allow running without root/sysctl modification.

### Key Files

- `src/lazy_handler.c` — Custom uffd handler with prefetch + eager fetch
- `src/criu_page_server.py` — Threaded TCP page server reading CRIU images
- `src/hashset.h` — Lock-free open-addressing hash set for page tracking
- `src/hot_pages.py` — Smaps-based hot page profiler
- `src/test_loop.c` — Test process with 1MB heap for checkpoint/restore testing
- `tests/test_criu_custom_lazy.sh` — End-to-end CRIU lazy restore test
- `tests/test_prefetch.sh` — Prefetch integration test
- `tests/test_hot_cold.sh` — Hot/cold eager fetch test

### Deferred Issues

None.

### Blockers/Concerns

- Phase 5 needs real workloads (Redis, PyTorch) — need to verify they can be checkpointed with CRIU.

## Session Continuity

Last session: 2026-02-13
Stopped at: Completed Phase 4, updated roadmap
Resume file: None
