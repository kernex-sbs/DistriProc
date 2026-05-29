# DistriProc Benchmark Report

Generated: 2026-05-29 21:21

## System Information

| Property | Value |
|----------|-------|
| Kernel | 6.18.7 |
| CPU | AMD Ryzen 7 7735HS with Radeon Graphics |
| Memory | 15292 MB |
| Arch | x86_64 |
| CRIU | Version: 4.2 |

## Time-to-First-Request (TTFR)

| Workload | full | lazy | lazy-prefetch | lazy-adaptive |
|----------|-------|-------|-------|-------|
| pytorch | 191 ± 15 | 650 ± 22 | 1227 ± 52 | 655 ± 20 |
| redis | 32 ± 5 | 37 ± 4 | 39 ± 4 | 38 ± 4 |
| test_loop | 1019 ± 3 | 42 ± 3 | 43 ± 6 | 41 ± 3 |

## Throughput

| Workload | full | lazy | lazy-prefetch | lazy-adaptive |
|----------|-------|-------|-------|-------|
| pytorch | 71 ± 7 | 73 ± 6 (103%) | 74 ± 10 (103%) | 72 ± 8 (102%) |
| redis | 105050 ± 4620 | 88504 ± 7591 (84%) | 87954 ± 4198 (84%) | 89577 ± 3310 (85%) |
| test_loop | 1 ± 0 | 1 ± 0 (100%) | 1 ± 0 (100%) | 1 ± 0 (100%) |

## Checkpoint Time

| Workload | Mean (ms) |
|----------|-----------|
| pytorch | 294 ± 11 |
| redis | 39 ± 7 |
| test_loop | 24 ± 4 |

## Page Fault Analysis

| Workload | Mode | Faults | Prefetched | Hits | Hit Rate | Total Served | Eager |
|----------|------|--------|------------|------|----------|-------------|-------|
| pytorch | lazy | 15515 | 0 | 0 | 0% | 15515 | 0 |
| pytorch | lazy-prefetch | 2322 | 788 | 0 | 0% | 2805 | 0 |
| pytorch | lazy-adaptive | 15496 | 1466 | 0 | 0% | 16871 | 0 |
| redis | lazy | 293 | 0 | 0 | 0% | 293 | 0 |
| redis | lazy-prefetch | 292 | 1255 | 0 | 0% | 378 | 0 |
| redis | lazy-adaptive | 295 | 602 | 0 | 0% | 380 | 0 |
| test_loop | lazy | 266 | 0 | 0 | 0% | 266 | 0 |
| test_loop | lazy-prefetch | 266 | 76 | 0 | 0% | 270 | 0 |
| test_loop | lazy-adaptive | 266 | 35 | 0 | 0% | 271 | 0 |

## Hypothesis Validation

### H1: Time-to-first-request < 1000ms

| Workload | Mode | Mean TTFR (ms) | Result |
|----------|------|----------------|--------|
| pytorch | lazy | 650 | **PASS** |
| pytorch | lazy-prefetch | 1227 | **FAIL** |
| pytorch | lazy-adaptive | 655 | **PASS** |
| redis | lazy | 37 | **PASS** |
| redis | lazy-prefetch | 39 | **PASS** |
| redis | lazy-adaptive | 38 | **PASS** |
| test_loop | lazy | 42 | **PASS** |
| test_loop | lazy-prefetch | 43 | **PASS** |
| test_loop | lazy-adaptive | 41 | **PASS** |

### H2: Throughput > 70% of full restore baseline

| Workload | Mode | Throughput | Baseline | Ratio | Result |
|----------|------|------------|----------|-------|--------|
| pytorch | lazy | 73 | 71 | 103% | **PASS** |
| pytorch | lazy-prefetch | 74 | 71 | 103% | **PASS** |
| pytorch | lazy-adaptive | 72 | 71 | 102% | **PASS** |
| redis | lazy | 88504 | 105050 | 84% | **PASS** |
| redis | lazy-prefetch | 87954 | 105050 | 84% | **PASS** |
| redis | lazy-adaptive | 89577 | 105050 | 85% | **PASS** |
| test_loop | lazy | 1 | 1 | 100% | **PASS** |
| test_loop | lazy-prefetch | 1 | 1 | 100% | **PASS** |
| test_loop | lazy-adaptive | 1 | 1 | 100% | **PASS** |

## Research Question Analysis

### RQ1: How does lazy restore TTFR compare to full restore?

- **pytorch**: Full=191ms, Lazy=650ms → lazy is 3.4x slower
- **redis**: Full=32ms, Lazy=37ms → lazy is 1.1x slower
- **test_loop**: Full=1019ms, Lazy=42ms → lazy is 24.5x faster

### RQ2: Does prefetching reduce page faults and improve hit rates?

- **pytorch**: Faults 15515 → 2322 (-85%), hit rate 0%
- **redis**: Faults 293 → 292 (-0%), hit rate 0%
- **test_loop**: Faults 266 → 266 (-0%), hit rate 0%

### RQ3: Does eager hot page fetching improve TTFR further?


### RQ5: Does adaptive backoff avoid prefetch waste while preserving TTFR?

- **pytorch**: TTFR 1227ms → 655ms (-571ms), prefetched pages 788 → 1466 (+86% volume)
- **redis**: TTFR 39ms → 38ms (-0ms), prefetched pages 1255 → 602 (-52% volume)
- **test_loop**: TTFR 43ms → 41ms (-2ms), prefetched pages 76 → 35 (-55% volume)

### RQ4: What is the throughput cost of lazy restore?

- **pytorch/lazy**: 73/71 ops/sec = 103% of baseline
- **pytorch/lazy-prefetch**: 74/71 ops/sec = 103% of baseline
- **pytorch/lazy-adaptive**: 72/71 ops/sec = 102% of baseline
- **redis/lazy**: 88504/105050 ops/sec = 84% of baseline
- **redis/lazy-prefetch**: 87954/105050 ops/sec = 84% of baseline
- **redis/lazy-adaptive**: 89577/105050 ops/sec = 85% of baseline
- **test_loop/lazy**: 1/1 ops/sec = 100% of baseline
- **test_loop/lazy-prefetch**: 1/1 ops/sec = 100% of baseline
- **test_loop/lazy-adaptive**: 1/1 ops/sec = 100% of baseline

