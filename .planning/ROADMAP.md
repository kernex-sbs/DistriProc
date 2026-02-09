# Roadmap: DistriProc

## Overview

DistriProc decouples memory from execution, allowing Linux processes to start immediately with partially remote address spaces. This roadmap implements the core mechanics: trapping page faults with userfaultfd, fetching pages over TCP, and integrating with CRIU to restore processes with distributed memory. The goal is to demonstrate sub-second startup times for containerized workloads.

## Domain Expertise

- None (Systems programming/Linux kernel focus)

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Basic userfaultfd PoC** - Verify local page fault handling and zero-page serving
- [ ] **Phase 2: TCP Transport** - Implement remote page fetching over TCP
- [ ] **Phase 3: CRIU Integration** - Restore process with lazy-pages from remote source
- [ ] **Phase 4: Performance Tuning** - Implement prefetching and hot/cold tracking
- [ ] **Phase 5: Evaluation** - Benchmark against CRIU migration (Redis/inference)

## Phase Details

### Phase 1: Basic userfaultfd PoC
**Goal**: Verify that we can trap page faults in userspace and serve pages (locally) on the current kernel.
**Depends on**: Nothing (first phase)
**Research**: Unlikely (Standard Linux API)
**Plans**: 1 plan

Plans:
- [ ] 01-01: Implement `test_uffd.c` to trap faults and serve zero-filled pages locally

### Phase 2: TCP Transport
**Goal**: Fetch pages from a remote Python server over TCP instead of generating them locally.
**Depends on**: Phase 1
**Research**: Unlikely (Standard socket programming)
**Plans**: 1 plan

Plans:
- [ ] 02-01: Implement `page_server.py` and update C client to fetch pages over network

### Phase 3: CRIU Integration
**Goal**: Restore a real process (Redis) using CRIU lazy-pages connected to our page server.
**Depends on**: Phase 2
**Research**: Likely (CRIU internals)
**Research topics**: CRIU lazy-pages protocol details, integrating custom uffd handler with CRIU restore
**Plans**: 2 plans

Plans:
- [ ] 03-01: Install/compile CRIU and verify basic checkpoint/restore
- [ ] 03-02: Integrate custom uffd handler with CRIU restore process

### Phase 4: Performance Tuning
**Goal**: Optimize page fetching to handle latency.
**Depends on**: Phase 3
**Research**: Unlikely (Algorithms defined in proposal)
**Plans**: 2 plans

Plans:
- [ ] 04-01: Implement sequential and stride prefetching
- [ ] 04-02: Implement hot/cold page tracking via smaps

### Phase 5: Evaluation
**Goal**: Measure time-to-first-request and throughput.
**Depends on**: Phase 4
**Research**: Unlikely (Benchmarking standard workloads)
**Plans**: 1 plan

Plans:
- [ ] 05-01: Run benchmarks (Redis, PyTorch) and generate performance report

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Basic userfaultfd PoC | 0/1 | Not started | - |
| 2. TCP Transport | 0/1 | Not started | - |
| 3. CRIU Integration | 0/2 | Not started | - |
| 4. Performance Tuning | 0/2 | Not started | - |
| 5. Evaluation | 0/1 | Not started | - |
