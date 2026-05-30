# DistriProc Handoff

This file is the fastest way for a new model or engineer to understand the current state of the project, what has been built, what the paper is now about, what results we have, and what should happen next.

## 1. What This Project Is

DistriProc is a research prototype built on:

- `CRIU` for checkpoint/restore
- `userfaultfd` for user-space page fault handling
- a TCP page server that serves pages from CRIU images

The original idea was broad process-level remote paging / remote memory. The current paper is a **measurement study**:

`When Prefetch Hurts: RTT-Dependent Speculative Paging in CRIU Lazy Restore`

Central finding: whether fixed sequential prefetch helps or hurts post-restore TTFR is governed by round-trip time. At loopback it hurts (PyTorch +88%, n=20) while cutting page faults 85%; above a ~125 µs RTT crossover it helps (−37% at 1 ms). Holds on both Linux 6.18.7 (+88%) and 7.0.9 (+37%). DistriProc is the userspace runtime that acts on it — a controller that disables prefetch in the congestion-bound regime. It decides how to fetch pages after lazy restore:

- demand paging
- asynchronous prefetch
- hot-page eager fetch
- adaptive backoff when prefetch becomes wasteful

## 2. What The System Does Today

Implemented:

- custom lazy-pages daemon in `src/lazy_handler.c`
- TCP page server in `src/criu_page_server.py`
- end-to-end CRIU lazy restore pipeline
- async prefetch off the fault path
- adaptive prefetch mode
- hot-page eager fetch
- benchmark harness in `eval/bench.sh`
- workloads:
  - `test_loop`
  - `redis`
  - `pytorch`
- root integration tests for CRIU/lazy restore paths

Not implemented / intentionally out of scope for this paper:

- writable remote-memory coherence
- write-through/write-back propagation protocol
- RDMA transport
- multi-node DSM
- replication / HA

## 3. Important Files

Core runtime:

- `src/lazy_handler.c`
- `src/criu_page_server.py`
- `src/hot_pages.py`
- `src/hashset.h`

Benchmarks:

- `eval/bench.sh`
- `eval/lib.sh`
- `eval/workloads/test_loop.sh`
- `eval/workloads/redis.sh`
- `eval/workloads/pytorch.sh`
- `eval/report.py`

Tests:

- `tests/run_tests.sh`
- `tests/test_criu_custom_lazy.sh`
- `tests/test_prefetch.sh`
- `tests/test_hot_cold.sh`
- `tests/test_adaptive_prefetch.sh`

Docs:

- `README.md`
- `docs/proposal.md`
- `docs/evaluation.md`
- `docs/howto.md`
- `paper/TODO.md`

## 4. Paper Direction

The repo was explicitly reframed away from overclaiming. The correct paper framing is:

- restored processes enter a remote-memory phase after lazy restore
- fixed prefetch policies are often wrong
- an adaptive userspace runtime can back off from wasteful prefetch and preserve good TTFR / throughput

The paper should not claim:

- “first remote paging system”
- “general distributed memory for Linux processes”
- implemented writable coherence

The paper should claim something like:

`an adaptive post-restore policy runtime on top of CRIU lazy restore that switches behavior based on observed fault and queue signals`

## 5. Major Repo Changes Already Made

### Documentation / framing

The docs were rewritten so the repo no longer claims more than the code supports.

Relevant commits:

- `359e414` `docs: reframe project around adaptive runtime`
- `4a86eac` `paper: add submission checklist`

### Async prefetch architecture

Original behavior:

- prefetch pages were fetched synchronously on the page-fault critical path
- this made prefetch catastrophically bad in earlier results

Current behavior:

- faulted page is handled synchronously
- prefetched pages are queued to a background worker
- worker uses a separate TCP connection
- shared “served page” state is synchronized

Relevant commits:

- `e48c60d` `lazy_handler: move prefetch off the fault path`
- `760e4e1` `lazy_handler: harden async prefetch queueing`
- `6cf2a49` `lazy_handler: handle non-pagefault uffd events`

### Adaptive controller

Adaptive prefetch mode was added:

- new handler flag: `--adaptive-prefetch`
- new benchmark mode: `lazy-adaptive`
- root integration test: `tests/test_adaptive_prefetch.sh`

Then the controller was refined several times:

- preserve handler logs across benchmark runs
- fix Redis warmup so the dataset is real
- base adaptive decisions on duplicate pressure and queue depth instead of bogus async “hit rate”
- disable prefetch decisively under sustained waste
- avoid premature re-enable while backlog is still large
- unify the controller window to a real 128-fault window

Relevant commits:

- `0afe796` `lazy_handler: add adaptive prefetch controller`
- `0419aaa` `eval: populate a real Redis working set`
- `50033e3` `eval: retain handler logs for adaptive tuning`
- `484d96a` `lazy_handler: back off adaptive prefetch sooner`

There are also later uncommitted controller refinements after `484d96a` in `src/lazy_handler.c` if this file was written before another commit. Always check `git status`.

## 6. Current Adaptive Controller Behavior

The current controller logic is in `src/lazy_handler.c`.

Main signals:

- prefetched pages in current control window
- duplicate requests in current control window
- queue depth
- queue drops

Key design choices:

- one control window = `ADAPT_WINDOW_FAULTS` faults
- if duplicate pressure is extreme and/or queue depth is large, adaptive mode disables prefetch
- once disabled, it stays off until the async queue drains sufficiently
- then it can re-enable using a tiny probe window

This controller is intentionally simple. It is a first paper-worthy policy, not a final sophisticated one.

## 7. Userfaultfd Event Note

The handler used to log:

- `Unexpected uffd event: 22`

That was identified as:

- `UFFD_EVENT_UNMAP`

The handler now treats `UNMAP`, `REMOVE`, `REMAP`, and `FORK` as explicit lifecycle events and exits cleanly on `UNMAP` after restore is finished.

## 8. Benchmark Harness State

`eval/bench.sh`:

- supports modes:
  - `full`
  - `lazy`
  - `lazy-prefetch`
  - `lazy-adaptive`
  - `lazy-hot`
- currently overwrites `eval/results/results.csv` on each run
- now preserves per-iteration logs in:
  - `eval/results/logs/`

Important limitation:

- report generation is still not paper-ready because results across separate runs are overwritten unless all desired workloads/modes are run together or the harness/reporting is improved

This is one of the next high-priority tasks.

## 9. Redis Workload State

This changed materially during the session.

Old problem:

- Redis warmup used `redis-benchmark -t set`
- benchmark logs showed `dbsize=1`
- the Redis experiment was weak and not representative

Current fix:

- `eval/workloads/redis.sh` now populates `10000` unique keys via `redis-cli --pipe`
- warmup verifies `dbsize >= 10000`
- logs `used_memory_human`
- throughput benchmark uses `-r "$_REDIS_KEY_COUNT"`

Now Redis is meaningful:

- `dbsize=10000`
- around `13.77M` memory used in the observed runs

## 10. Observed Experimental Results

These numbers are from the interactive work during this session, not all of them are yet captured in a single final combined report.

### Redis

Important result:

- adaptive mode became competitive and sometimes strong
- fixed prefetch is no longer catastrophically bad after async refactor, but still shows high waste

Observed later Redis runs:

- `lazy` TTFR roughly in the `32-57ms` band
- `lazy-prefetch` TTFR roughly in the `31-44ms` band
- `lazy-adaptive` TTFR roughly in the `38-49ms` band in one set, then around `36-48ms` in another run

Observed later Redis throughput:

- `lazy` roughly `62k-97k ops/sec` in one later 5-iteration run
- `lazy-prefetch` roughly `65k-85k ops/sec`
- `lazy-adaptive` roughly `59k-97k ops/sec`

Interpretation:

- adaptive is not universally dominant
- adaptive is now clearly viable
- adaptive can back off aggressively under extreme duplicate pressure
- the current story is “adaptive avoids waste and remains competitive,” not “adaptive always wins”

Important handler-log evidence:

- duplicate pressure in Redis is very high
- queue depth can become very large
- adaptive mode now disables prefetch after one full control window when conditions are bad

Example pattern from logs:

- `Policy: ... dup_rate=94-98% qdepth~780-830 => prefetch=off`

### test_loop

Result:

- adaptive mode does not regress the simple workload
- TTFR across `lazy`, `lazy-prefetch`, and `lazy-adaptive` stays in the same rough band

This is useful because it shows the backoff policy did not obviously break the easiest case.

### PyTorch

Observed result:

- `lazy` is clearly better than fixed prefetch on TTFR
- `lazy-prefetch` was much worse (`~1.2s-1.6s` TTFR in the observed run)
- `lazy-adaptive` roughly recovered toward plain `lazy` (`~0.95s-1.02s`)

Interpretation:

- adaptive is doing what we wanted philosophically
- it avoids the worst fixed-prefetch behavior
- but the evaluation still needs careful presentation because PyTorch throughput measurement has a known methodological limitation

## 11. Known Methodology Limitations

These matter for the paper.

### Report pipeline

- `make report` currently only reflects whatever is in `eval/results/results.csv`
- separate runs overwrite results
- this must be fixed before paper writing

### PyTorch throughput

- `eval/workloads/pytorch.sh` throughput is not measured on the restored process
- it runs a fresh Python process for batch inference
- this is already called out in the docs and is still a paper caveat unless redesigned

### Async “hit rate”

- current `prefetch_hits` metric is not a reliable usefulness metric for async prefetch
- if async prefetch succeeds early enough, no page fault occurs and there is nothing to count as a “hit”
- this is why controller tuning moved toward duplicate pressure and queue depth

The paper should be careful not to oversell `hit rate` as the main adaptive success metric.

## 12. Important Commands Used Successfully

Build:

```bash
make all
```

Non-root tests:

```bash
make test
```

Root tests:

```bash
sudo bash tests/run_tests.sh
sudo bash tests/test_adaptive_prefetch.sh
```

Redis comparison:

```bash
sudo bash eval/bench.sh --workloads redis --modes lazy,lazy-prefetch,lazy-adaptive --iterations 5
```

test_loop comparison:

```bash
sudo bash eval/bench.sh --workloads test_loop --modes lazy,lazy-prefetch,lazy-adaptive --iterations 3
```

PyTorch comparison:

```bash
sudo bash eval/bench.sh --workloads pytorch --modes lazy,lazy-prefetch,lazy-adaptive --iterations 3
```

Inspect saved handler logs:

```bash
rg -n "Policy:|Prefetch stats|Prefetch queue drops|Prefetch duplicates skipped" eval/results/logs/*_handler.log
```

Generate report:

```bash
make report
cat eval/results/report.md
```

## 13. What Still Needs To Be Done Before Writing The Paper

See `paper/TODO.md` for the checklist. The most important unfinished tasks are:

1. Fix result accumulation / combined reporting
2. Produce one final combined dataset across all workloads and modes
3. Update `docs/evaluation.md`, `docs/howto.md`, and `README.md`
4. Lock the final claims
5. Write the paper from the actual artifact, not the old proposal

## 14. Immediate Next Best Task

The single best next engineering task is:

`fix the results/report pipeline so one final report can cover redis + test_loop + pytorch together`

Why:

- the controller is now in a respectable state
- the missing piece is paper-quality aggregation and presentation
- current reporting still gets overwritten per run

What that likely means:

- change `eval/bench.sh` and/or `eval/report.py`
- support appending or merging results cleanly
- possibly add output subdirs or workload-specific CSVs and a merge step

## 15. If A Fresh Model Picks This Up

Do this first:

1. Read `paper/TODO.md`
2. Read `README.md`
3. Read `docs/evaluation.md`
4. Inspect `git status`
5. Inspect `eval/results/logs/`

Then decide whether you are in:

- `evaluation pipeline work`
- `controller tuning`
- `paper writing/docs`

The current recommended branch of work is:

`evaluation pipeline work`

not more controller tuning unless new combined results reveal a specific weakness.
