# DistriProc Benchmark Report

Generated: 2026-05-07 03:32

## System Information

| Property | Value |
|----------|-------|
| Kernel | 6.18.7-arch1-1 |
| CPU | AMD Ryzen 7 7735HS with Radeon Graphics |
| Memory | 15284 MB |
| Arch | x86_64 |
| CRIU | Version: 4.2 |

## Time-to-First-Request (TTFR)

| Workload | full | lazy | lazy-prefetch | lazy-adaptive |
|----------|-------|-------|-------|-------|
| pytorch | 209 ± 11 | 625 ± 18 | 1159 ± 24 | 686 ± 67 |
| redis | 32 ± 1 | 46 ± 10 | 38 ± 9 | 44 ± 6 |
| test_loop | 1020 ± 2 | 48 ± 4 | 48 ± 4 | 49 ± 6 |

## Throughput

| Workload | full | lazy | lazy-prefetch | lazy-adaptive |
|----------|-------|-------|-------|-------|
| pytorch | 84 ± 1 | 84 ± 1 (100%) | 82 ± 4 (97%) | 79 ± 8 (94%) |
| redis | 107146 ± 7516 | 72937 ± 8387 (68%) | 70556 ± 7201 (66%) | 73885 ± 5590 (69%) |
| test_loop | 1 ± 0 | 1 ± 0 (100%) | 1 ± 0 (100%) | 1 ± 0 (100%) |

## Checkpoint Time

| Workload | Mean (ms) |
|----------|-----------|
| pytorch | 288 ± 19 |
| redis | 45 ± 8 |
| test_loop | 32 ± 4 |

## Page Fault Analysis

| Workload | Mode | Faults | Prefetched | Hits | Hit Rate | Total Served | Eager |
|----------|------|--------|------------|------|----------|-------------|-------|
| pytorch | lazy | 15743 | 0 | 0 | 0% | 15743 | 0 |
| pytorch | lazy-prefetch | 6352 | 2121 | 0 | 0% | 7583 | 0 |
| pytorch | lazy-adaptive | 15888 | 1695 | 0 | 0% | 17484 | 0 |
| redis | lazy | 282 | 0 | 0 | 0% | 282 | 0 |
| redis | lazy-prefetch | 281 | 1579 | 0 | 0% | 334 | 0 |
| redis | lazy-adaptive | 281 | 874 | 0 | 0% | 335 | 0 |
| test_loop | lazy | 266 | 0 | 0 | 0% | 266 | 0 |
| test_loop | lazy-prefetch | 265 | 76 | 0 | 0% | 269 | 0 |
| test_loop | lazy-adaptive | 265 | 32 | 0 | 0% | 268 | 0 |

## Hypothesis Validation

### H1: Time-to-first-request < 1000ms

| Workload | Mode | Mean TTFR (ms) | Result |
|----------|------|----------------|--------|
| pytorch | lazy | 625 | **PASS** |
| pytorch | lazy-prefetch | 1159 | **FAIL** |
| pytorch | lazy-adaptive | 686 | **PASS** |
| redis | lazy | 46 | **PASS** |
| redis | lazy-prefetch | 38 | **PASS** |
| redis | lazy-adaptive | 44 | **PASS** |
| test_loop | lazy | 48 | **PASS** |
| test_loop | lazy-prefetch | 48 | **PASS** |
| test_loop | lazy-adaptive | 49 | **PASS** |

### H2: Throughput > 70% of full restore baseline

| Workload | Mode | Throughput | Baseline | Ratio | Result |
|----------|------|------------|----------|-------|--------|
| pytorch | lazy | 84 | 84 | 100% | **PASS** |
| pytorch | lazy-prefetch | 82 | 84 | 97% | **PASS** |
| pytorch | lazy-adaptive | 79 | 84 | 94% | **PASS** |
| redis | lazy | 72937 | 107146 | 68% | **FAIL** |
| redis | lazy-prefetch | 70556 | 107146 | 66% | **FAIL** |
| redis | lazy-adaptive | 73885 | 107146 | 69% | **FAIL** |
| test_loop | lazy | 1 | 1 | 100% | **PASS** |
| test_loop | lazy-prefetch | 1 | 1 | 100% | **PASS** |
| test_loop | lazy-adaptive | 1 | 1 | 100% | **PASS** |

## Research Question Analysis

### RQ1: How does lazy restore TTFR compare to full restore?

- **pytorch**: Full=209ms, Lazy=625ms → lazy is 3.0x slower
- **redis**: Full=32ms, Lazy=46ms → lazy is 1.4x slower
- **test_loop**: Full=1020ms, Lazy=48ms → lazy is 21.1x faster

### RQ2: Does prefetching reduce page faults and improve hit rates?

- **pytorch**: Faults 15743 → 6352 (-60%), hit rate 0%
- **redis**: Faults 282 → 281 (-0%), hit rate 0%
- **test_loop**: Faults 266 → 265 (-0%), hit rate 0%

### RQ3: Does eager hot page fetching improve TTFR further?


### RQ5: Does adaptive backoff avoid prefetch waste while preserving TTFR?

- **pytorch**: TTFR 1159ms → 686ms (-473ms), prefetched pages 2121 → 1695 (-20% volume)
- **redis**: TTFR 38ms → 44ms (+6ms), prefetched pages 1579 → 874 (-45% volume)
- **test_loop**: TTFR 48ms → 49ms (+1ms), prefetched pages 76 → 32 (-58% volume)

### RQ4: What is the throughput cost of lazy restore?

- **pytorch/lazy**: 84/84 ops/sec = 100% of baseline
- **pytorch/lazy-prefetch**: 82/84 ops/sec = 97% of baseline
- **pytorch/lazy-adaptive**: 79/84 ops/sec = 94% of baseline
- **redis/lazy**: 72937/107146 ops/sec = 68% of baseline
- **redis/lazy-prefetch**: 70556/107146 ops/sec = 66% of baseline
- **redis/lazy-adaptive**: 73885/107146 ops/sec = 69% of baseline
- **test_loop/lazy**: 1/1 ops/sec = 100% of baseline
- **test_loop/lazy-prefetch**: 1/1 ops/sec = 100% of baseline
- **test_loop/lazy-adaptive**: 1/1 ops/sec = 100% of baseline

