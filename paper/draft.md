# DistriProc: An Adaptive Post-Restore Remote-Memory Runtime for Linux Processes

> **⚠️ SUPERSEDED.** Early prose draft with stale (n=5) numbers and the pre-RTT
> framing. Canonical paper is `paper/paper.tex` — *"When Prefetch Hurts:
> RTT-Dependent Speculative Paging in CRIU Lazy Restore"* (n=20, RTT crossover,
> cross-kernel). Kept for history only; do not cite from here.

---

## Abstract

Checkpoint/Restore In Userspace (CRIU) supports lazy restore, which allows a process
to resume execution before all its pages have been transferred from a remote page
server. This reduces time-to-first-request (TTFR) dramatically for workloads with
small active footprints at restore time, but leaves the policy question open: should
the runtime prefetch additional pages speculatively, and if so, how many?

We show that a fixed sequential prefetch policy can nearly double TTFR for
memory-heavy workloads by congesting the TCP channel shared between fault resolution
and speculative prefetch. We present DistriProc, an adaptive userspace runtime that
monitors duplicate-fetch pressure and async queue depth within a sliding window of
page faults, and disables prefetch when those signals indicate it is causing harm.
Evaluated on three workloads (a synthetic loop, Redis with a 10,000-key dataset, and
PyTorch inference), the adaptive policy reduces fixed-prefetch TTFR by 41%
(1,159 → 686 ms) on the memory-heavy workload while reducing prefetch volume by
20–58% across all workloads, without regressing the others.

---

## 1. Introduction

Cloud platforms routinely checkpoint and migrate running processes for load balancing,
preemption recovery, and live migration. CRIU [CRIU] provides this capability for
Linux processes without application modification. Its lazy restore mode is particularly
attractive: rather than waiting for all memory pages to be copied before resuming the
process, CRIU installs a userfaultfd [userfaultfd] handler that fetches pages on
demand from a remote page server. The process begins running immediately, and pages
arrive as they are accessed.

The central operational question is what fetching policy the runtime should use during
this post-restore phase. Three options exist. Pure demand paging fetches only what
the process explicitly faults on, contributing no extra network traffic but potentially
stalling on every new page. Sequential prefetch speculatively fetches nearby pages
after each fault, reducing future fault latency at the cost of additional network
traffic. An adaptive policy monitors runtime signals and switches between these
behaviors based on observed conditions.

Prior deployments of CRIU lazy restore [Runc-lazy, CRIU-lazy] have not systematically
studied the policy question. In particular, the assumption that prefetch is always
beneficial turns out to be incorrect. We demonstrate empirically that a fixed
sequential prefetch policy can nearly double TTFR for workloads with large working
sets, because speculative traffic competes with fault-path traffic over the same TCP
connection, building up an async queue backlog that delays synchronous fault resolution.

We make three contributions:

1. We demonstrate that lazy restore provides a 21× TTFR reduction for memory-light
   workloads, but that this benefit inverts for memory-heavy workloads where the
   process must page in its full working set before serving (§5).

2. We show that fixed sequential prefetch increases TTFR by 85% for a PyTorch inference
   server (625 ms → 1,159 ms) by reducing page faults 60% while simultaneously
   congesting the fault path — establishing that fault reduction is not a reliable proxy
   for latency improvement (§5).

3. We present an adaptive controller that uses duplicate-fetch pressure and async queue
   depth as lightweight signals within a 128-fault sliding window, and show that it
   recovers 473 ms of the TTFR degradation caused by fixed prefetch on the
   memory-heavy workload while cutting prefetch volume 20–58% across all workloads (§5).

DistriProc is implemented as a userspace daemon in approximately 1,200 lines of C and
300 lines of Python. All experiments use a TCP loopback page server; RDMA, writable
remote-memory coherence, and multi-node distribution are out of scope for this paper.

---

## 2. Background

### 2.1 CRIU and Lazy Restore

CRIU checkpoints a Linux process by dumping its memory pages, file descriptors, and
kernel state to an image on disk. Restore replays this image to reconstruct the process.
Full restore copies all memory pages into the restored process before resuming
execution. This can take hundreds of milliseconds for processes with large address spaces.

Lazy restore defers page transfer. At restore time, CRIU marks the process's virtual
memory regions as unpopulated and registers a userfaultfd file descriptor that
intercepts page faults. When the process accesses an unpopulated page, the kernel
delivers a `UFFD_EVENT_PAGEFAULT` event to the handler instead of raising a SIGSEGV.
The handler fetches the missing page from a remote page server over TCP, installs it
via `ioctl(UFFDIO_COPY)`, and returns control to the process. The process resumes
execution at the faulting instruction without any application-level change.

This model allows the process to begin executing within tens of milliseconds of restore,
because only a small number of pages (stack, entry-point code, initial data) must be
present before the first instruction runs. The remaining pages arrive on demand.

### 2.2 Userfaultfd

`userfaultfd(2)` is a Linux kernel mechanism (available since kernel 4.3) that allows
userspace to handle page faults for a given virtual memory range. A process registers
memory regions with a userfaultfd file descriptor, then reads fault events from it.
For each fault, the handler must install a page via `UFFDIO_COPY` (zero-copy from a
userspace buffer) or `UFFDIO_ZEROPAGE` before returning. The faulting thread is
blocked until the handler resolves the fault.

DistriProc's lazy handler polls the userfaultfd file descriptor on the main thread,
resolves each fault synchronously, and dispatches prefetch work to a background
thread via a bounded queue. The background thread uses a separate TCP connection to
the page server to avoid contending with synchronous fault resolution on the primary
connection.

### 2.3 The Post-Restore Remote-Memory Phase

After lazy restore, the process operates in a remote-memory phase: some pages reside
locally (those already faulted in) and the remainder reside on the page server.
This phase ends when all pages have been accessed at least once. The duration and
character of this phase depend entirely on the workload's access pattern:

- A process that immediately touches all its memory (e.g., a model server loading
  weights) will fault on virtually every page before it can serve its first request.
  Lazy restore provides little TTFR benefit and exposes the full RTT of fetching
  each page over TCP.

- A process that can serve requests using a small active footprint (e.g., a loop
  server that touches only its stack) will complete TTFR in milliseconds, because
  only a handful of pages are needed before the first response.

This distinction motivates workload-aware policy.

---

## 3. Design

### 3.1 System Architecture

DistriProc consists of three components:

**Page server** (`src/criu_page_server.py`): A TCP server that reads CRIU page image
files and serves individual pages on request. It accepts two connections per restore
session: one for synchronous fault resolution and one for async prefetch.

**Lazy handler** (`src/lazy_handler.c`): A userspace daemon that registers the
restored process's memory regions with `userfaultfd`, then runs a main loop that
reads fault events, fetches faulted pages synchronously over TCP, and optionally
queues prefetch work for a background thread.

**Hot-page profiler** (`src/hot_pages.py`): An optional profiling pass (not evaluated
in this paper) that runs the workload before checkpointing, records the most-accessed
pages, and passes them to the handler as a set to be eagerly prefetched at restore time.

### 3.2 Prefetch Modes

The handler supports three policy modes, selectable at invocation time:

**Lazy (demand-only).** No speculative fetching. Each page fault is resolved by
fetching exactly the faulted page. This minimizes network traffic but may stall on
every unique page access.

**Fixed prefetch.** After each fault on page P, the handler queues pages P+1 through
P+S (configurable stride S, window W) to the background prefetch thread. The prefetch
thread dequeues these requests and fetches them over the secondary TCP connection if
they have not already been served. This is fixed: the policy does not observe whether
prefetch is beneficial.

**Adaptive prefetch.** Begins like fixed prefetch but activates a controller that
monitors signals within a sliding window of N faults. When the controller determines
that prefetch is wasteful, it disables the prefetch thread until conditions improve.

### 3.3 Adaptive Controller

The adaptive controller runs at the end of every N-fault window (N = 128 in all
experiments). It observes three signals:

**Duplicate pressure** (`dup_rate`): The fraction of prefetch requests within the
current window that were for pages already served. A high duplicate rate indicates
that the prefetch worker is re-requesting pages that the fault path already resolved,
contributing traffic without benefit.

**Queue depth** (`qdepth`): The number of unprocessed prefetch requests currently
waiting in the bounded queue. A large queue indicates that the prefetch worker cannot
keep pace with fault generation, meaning outstanding prefetch traffic is occupying TCP
bandwidth and adding latency to the fault path.

**Queue drops**: Prefetch requests dropped because the queue was full. A nonzero drop
count confirms that the queue is saturated.

The controller logic is:

```
if dup_rate > DUP_THRESHOLD or qdepth > QDEPTH_THRESHOLD:
    disable prefetch
    wait until qdepth < DRAIN_THRESHOLD
    re-enable with probe window (small W, S=1)
    observe one window
    if not wasteful: restore full W, S
    else: disable again
```

Current thresholds: `DUP_THRESHOLD` = 70%, `QDEPTH_THRESHOLD` = 500,
`DRAIN_THRESHOLD` = 64. These were set by inspection of early runs and were not
tuned further. The controller is intentionally simple: it is a first paper-worthy
policy, not a final production one.

**Why not hit rate?** An intuitive signal for prefetch usefulness would be the
fraction of prefetched pages that were subsequently faulted on (the "hit rate"). In
practice this metric is unreliable for async prefetch: if the prefetch worker installs
a page before the process faults on it, no fault event fires and the installation does
not register as a hit. In all our experiments, the reported hit rate is 0% despite the
prefetch worker being active. The controller therefore uses duplicate pressure and
queue depth, which are observable without relying on post-hoc fault interception.

---

## 4. Implementation

### 4.1 Fault Path

The main handler thread polls the userfaultfd file descriptor with a 1-second timeout.
On each fault event, it checks a shared hash set of already-served pages (§4.3). If
the page has been served (by the prefetch thread), it calls `ioctl(UFFDIO_COPY)` from
local cache. Otherwise it sends a page request over the primary TCP connection, reads
the page data, and installs it via `UFFDIO_COPY`. The faulting thread is unblocked
as soon as `UFFDIO_COPY` returns.

### 4.2 Async Prefetch Path

After resolving a fault on page P, the handler computes a set of prefetch candidates
(P+stride, P+2·stride, ..., up to the configured window) and attempts to push each
to a bounded MPSC queue shared with the prefetch thread. If the queue is full, the
request is dropped and a drop counter is incremented.

The prefetch thread dequeues candidates in order. For each candidate, it checks the
shared hash set. If the page is already served, it increments the duplicate counter
and discards the request. Otherwise it sends a prefetch request over the secondary TCP
connection, reads the page, installs it via `UFFDIO_COPY`, and marks it as served.

This architecture ensures that the primary fault path is never blocked by prefetch
activity: the two TCP connections are independent, and the queue bounds the memory
footprint of outstanding requests.

### 4.3 Shared State

The served-page set is a fixed-size open-addressing hash set (`src/hashset.h`).
Access is protected by a mutex. The hash set is checked by both the fault path (to
avoid re-fetching pages already installed by the prefetch thread) and the prefetch
thread (to skip duplicate requests). Contention on this mutex is low because the
prefetch thread operates at a slower pace than the fault path on most workloads.

### 4.4 Lifecycle Events

The userfaultfd protocol generates non-fault events (`UFFD_EVENT_UNMAP`,
`UFFD_EVENT_REMAP`, `UFFD_EVENT_REMOVE`, `UFFD_EVENT_FORK`) in addition to page
faults. DistriProc handles these explicitly: it logs `UNMAP` events and exits cleanly,
preventing the spurious log noise that earlier versions produced.

---

## 5. Evaluation

### 5.1 Setup

**Hardware:** AMD Ryzen 7 7735HS (8 cores), 15 GB RAM, x86\_64.
**Software:** Linux 6.18.7, CRIU 4.2, Python 3.x, PyTorch (CPU-only).
**Transport:** TCP loopback (127.0.0.1). All experiments run on a single machine;
the page server and handler communicate over localhost. This represents best-case
network conditions; production latency over a real network would be higher.
**Methodology:** Each configuration runs 5 iterations. We report mean ± standard
deviation. TTFR is measured from the moment `criu restore` is invoked to the moment
the workload responds to a probe request. Throughput is measured after TTFR on the
restored process (Redis, test\_loop) or on a fresh process (PyTorch — see §5.5).

**Workloads:**

- **test\_loop**: A synthetic C process that increments a counter in a tight loop and
  responds to a UDP probe. Represents a memory-light, CPU-bound server with a
  footprint of ~266 pages (~1 MB).

- **Redis**: A Redis 7.x instance pre-warmed with 10,000 unique keys (~13.77 MB
  working set). Throughput measured as GET ops/sec via `redis-benchmark`.

- **PyTorch**: A ResNet-18 model loaded into memory, checkpointed, and lazily restored.
  Throughput is measured by running batch inference on the restored model.

**Modes evaluated:** `full` (CRIU full restore, no page server), `lazy` (demand-only),
`lazy-prefetch` (fixed window=16, stride=8), `lazy-adaptive` (same window/stride as
fixed, with adaptive controller enabled).

### 5.2 Time-to-First-Request (TTFR)

| Workload   | Full        | Lazy        | Fixed prefetch | Adaptive    |
|------------|-------------|-------------|----------------|-------------|
| test\_loop | 1020 ± 2 ms | 48 ± 4 ms   | 48 ± 4 ms      | 49 ± 6 ms   |
| Redis      | 32 ± 1 ms   | 46 ± 10 ms  | 38 ± 9 ms      | 44 ± 6 ms   |
| PyTorch    | 209 ± 11 ms | 625 ± 18 ms | 1159 ± 24 ms   | 686 ± 67 ms |

*Table 1: Mean TTFR ± stddev across 5 iterations. Lower is better.*

**test\_loop (C1).** Lazy restore reduces TTFR 21× relative to full restore (48 ms
vs. 1,020 ms). The process's active footprint at restore time is tiny — only stack
and code pages are needed before the first response. Full restore must copy all 266
pages before execution resumes, producing the 1-second delay. Fixed and adaptive
prefetch show no measurable difference from demand-only (48, 48, 49 ms), confirming
that prefetch has neither benefit nor harm on a small working set.

**Redis.** Lazy restore is marginally slower than full restore (46 ms vs. 32 ms). Redis
accesses a 13.77 MB working set almost immediately after restore; the small footprint
means the process can respond before most pages are faulted in, but demand-paging
still incurs slightly more latency than full restore's immediate availability. Fixed
prefetch reduces TTFR to 38 ms (−17% vs. lazy), but not significantly so given the
variance. Adaptive prefetch shows 44 ms.

**PyTorch (C2 and C3).** This workload exhibits the failure mode of fixed prefetch.
Full restore completes in 209 ms. Lazy restore takes 625 ms because the ResNet-18
model weights (~60 MB, ~15,000 pages) must all be paged in before the first inference
can run. Fixed prefetch worsens TTFR to 1,159 ms — a 85% regression over demand-only
and a 5.5× overhead vs. full restore — despite reducing page fault count by 60% (from
15,743 to 6,352). The adaptive controller brings TTFR back to 686 ms (−473 ms vs.
fixed prefetch, −41%), within 10% of the demand-only baseline.

*See Figure 1 (fig1\_pytorch\_ttfr) and Figure 2 (fig2\_ttfr\_all).*

### 5.3 The Fixed Prefetch Paradox

Fixed prefetch on PyTorch reduces page faults by 60% (15,743 → 6,352) yet doubles
TTFR. This apparent paradox is explained by the TCP channel dynamics. The page server
and handler share a loopback TCP connection for synchronous fault resolution. The
prefetch worker uses a second connection, but both connections share the same loopback
bandwidth and the same kernel socket buffers.

When the prefetch window is large relative to the fault rate, the prefetch worker
generates a backlog of pending TCP reads on the secondary connection. This backlog does
not directly block the primary connection, but it does congest the kernel's socket
send buffer for the page server, delaying responses on the primary connection. The
effect manifests as growing `qdepth` in the handler's async queue and ultimately
increases the wall-clock time per fault.

The 60% fault reduction is real: fewer faults fire. But the remaining 40% of faults
take longer to resolve because each resolution is delayed by contention. The net
effect is higher TTFR.

*See Figure 4 (fig4\_faults\_vs\_ttfr).*

### 5.4 Adaptive Controller Behavior

**PyTorch.** The controller observes 5 control windows (640 faults) before disabling
prefetch:

| Window | Dup rate | Queue depth | Decision        |
|--------|----------|-------------|-----------------|
| 1      | 100%     | 2,704       | on (reduce W,S) |
| 2      | 78%      | 3,288       | on (reduce W,S) |
| 3      | 100%     | 3,552       | on (reduce W,S) |
| 4      | 100%     | 3,714       | on (reduce W,S) |
| 5      | 100%     | 3,796       | **off**         |

The controller progressively reduces the prefetch window and stride before disabling.
By window 5, `qdepth` has grown to 3,796 outstanding requests and the duplicate rate
is 100% — every request is for a page already served. Once disabled, prefetch stays
off (the async queue eventually drains). The handler completes the session in demand-
only mode. Adaptive mode's fault count (15,888) is nearly identical to demand-only
(15,743), confirming the controller backed off almost completely after the probe window.

**Redis.** The controller disables prefetch in a single window: 94% duplicate rate
and queue depth 821. Redis's access pattern is essentially random across the 10,000-key
working set; sequential prefetch predicts nothing and every prefetch candidate is
already served by the time the worker processes it.

*See Figure 5 (fig5\_adaptive\_timeline).*

### 5.5 Throughput

| Workload   | Full         | Lazy              | Fixed prefetch    | Adaptive          |
|------------|--------------|-------------------|-------------------|-------------------|
| test\_loop | 1 op/s       | 1 op/s (100%)     | 1 op/s (100%)     | 1 op/s (100%)     |
| Redis      | 107,146 op/s | 72,937 (68%)      | 70,556 (66%)      | 73,885 (69%)      |
| PyTorch    | 84 op/s      | 84 (100%)         | 82 (97%)          | 79 (94%)          |

*Table 2: Throughput. Percentages relative to full restore baseline.*

All lazy modes achieve ≥94% of full restore throughput on PyTorch and test\_loop.
Redis lazy modes reach approximately 68–69% of full restore throughput. This shortfall
reflects the TCP transport overhead: Redis issues random GET operations that touch
pages across the working set, and each uncached page requires a TCP round-trip to the
page server. In production this overhead would be reduced by RDMA or a higher-bandwidth
link; on loopback, the single-machine round-trip is ~5–15 µs per page, which is
measurable at 70,000–80,000 ops/sec. We do not attribute this to the prefetch policy;
all lazy modes show roughly equal throughput on Redis.

**PyTorch throughput caveat.** The PyTorch throughput numbers measure batch inference
on the restored process using the same model. However, throughput is measured after
the post-restore phase concludes, so all modes converge once pages are local. The
throughput numbers (79–84 ops/sec) reflect CPU-bound inference speed, not memory fetch
overhead.

### 5.6 Prefetch Volume Reduction

| Workload   | Fixed prefetch | Adaptive   | Reduction |
|------------|----------------|------------|-----------|
| test\_loop | 76 pages       | 32 pages   | −58%      |
| Redis      | 1,579 pages    | 874 pages  | −45%      |
| PyTorch    | 2,121 pages    | 1,695 pages| −20%      |

*Table 3: Mean prefetch volume per restore session.*

The adaptive controller reduces prefetch volume on all three workloads, even on
test\_loop where fixed prefetch causes no measurable harm. The PyTorch reduction is
smaller (−20%) because most of the prefetch volume occurs in the early probe windows
before the controller disables it.

*See Figure 3 (fig3\_prefetch\_volume).*

---

## 6. Discussion

### 6.1 When Lazy Restore Helps and When It Does Not

Lazy restore is most beneficial for processes that can satisfy their first requests
using a small fraction of their address space. For test\_loop, the entire TTFR is
determined by kernel restore overhead and the handful of stack/code pages needed
before the loop body runs. Lazy restore eliminates the page-copy phase entirely and
cuts TTFR 21×.

For PyTorch inference, the situation is the opposite. A ResNet-18 model requires its
full set of weight tensors to be present in memory before a single forward pass can
complete. The process cannot serve its first request until all ~15,000 pages are local.
Lazy restore imposes a 3× TTFR overhead relative to full restore in this scenario
because it adds per-page TCP round-trips to the inherent page loading time.

This workload dependence is fundamental and the paper does not claim that lazy restore
universally reduces TTFR. The benefit is conditional on working set locality at the
time of the first request.

### 6.2 Why Adaptive Recovers But Does Not Fully Match Lazy

On PyTorch, adaptive mode (686 ms) does not fully recover to demand-only lazy (625 ms).
The gap (61 ms) comes from the probe windows before the controller disables prefetch.
During those 5 × 128 = 640 faults, the prefetch worker is active and building queue
depth, adding latency to fault resolution. A more aggressive threshold would disable
prefetch sooner at the cost of false positives on workloads where prefetch is genuinely
useful. The current threshold is conservative.

A future controller with workload classification or lookahead could shorten the probe
phase. We leave this as future work.

### 6.3 Duplicate Pressure as an Adaptive Signal

Duplicate pressure is an effective signal because it directly measures wasted work
without requiring knowledge of the workload's access pattern. A high duplicate rate
means the prefetch worker is fetching pages the fault path has already resolved — the
workload is accessing memory in an order that the sequential prefetch policy did not
predict. Queue depth amplifies this signal: even moderate duplicate pressure becomes
harmful when the queue is large, because queued-but-useless requests occupy the
prefetch thread and TCP bandwidth.

The combination of the two signals handles both fast-working-set workloads (Redis:
duplicate rate spikes immediately to 94%, queue depth modest) and slow-to-saturate
workloads (PyTorch: queue depth grows over multiple windows before the rate stabilizes).

---

## 7. Related Work

**CRIU and lazy restore.** CRIU [CRIU] is the standard checkpoint/restore tool for
Linux. Lazy restore via userfaultfd was introduced to avoid blocking restore on large
memory copies [CRIU-lazy]. Existing CRIU deployments do not include an adaptive
prefetch policy; the default behavior is demand-only.

**Remote memory systems.** InfiniSwap [Gu17] and Fastswap [Amaro20] implement
transparent remote memory over RDMA by replacing kernel swap with remote page fetch.
AIFM [Ruan20] exposes far memory to applications via a runtime API. These systems
operate at the swap or application level and are not specific to the post-restore
phase. DistriProc operates entirely in userspace and targets the transient remote-
memory state that exists between restore and working-set convergence.

**Prefetch policies.** Sequential and stride prefetching in virtual memory systems
are well-studied [Chen95, Srinath07]. Adaptive prefetch has been explored in hardware
prefetchers [Srinath07] and in database buffer management [Cao94]. To our knowledge,
adaptive prefetch policy for the userfaultfd post-restore phase has not been previously
studied.

**Container live migration.** RunC and Podman support CRIU-based container migration
[Runc-lazy]. Page server implementations in these systems are typically stateless TCP
servers similar to ours. No published work evaluates adaptive fetch policy for
container migration TTFR.

**Disaggregated memory.** LegoOS [Shan18] disaggregates CPU, memory, and storage
across separate physical components. CXL-based memory pooling [CXL] is an emerging
hardware approach. DistriProc is complementary: it provides a userspace runtime policy
layer that could sit above a CXL-backed or RDMA-backed far-memory transport.

---

## 8. Limitations

**Transport.** All experiments use a TCP loopback page server. Production deployments
would use a real network link, potentially RDMA. RDMA would reduce per-page RTT from
~10 µs to ~1–2 µs, which would change the absolute TTFR numbers and likely reduce the
congestion effect that makes fixed prefetch harmful. Whether the adaptive controller
remains necessary under RDMA is an open question.

**Writable coherence.** DistriProc does not implement write-back or write-through to
the page server. Pages installed via `UFFDIO_COPY` are local copies; modifications are
not propagated. The system supports read-only remote memory only.

**Controller generalization.** The adaptive controller thresholds were set by inspection
on these three workloads and were not cross-validated. A workload with a mixed access
pattern (partly sequential, partly random) may behave unpredictably. The controller is
a heuristic; it is not learned.

**PyTorch throughput measurement.** Throughput for the PyTorch workload is measured
on the restored process after all pages are local. It does not capture inference
throughput during the remote-memory phase. A production evaluation would measure
throughput continuously from restore time.

**Single-machine evaluation.** The page server and process run on the same physical
machine. True live migration across machines would expose real network RTT and
bandwidth constraints not present in loopback experiments.

---

## 9. Conclusion

We presented DistriProc, an adaptive post-restore remote-memory runtime built on CRIU
lazy restore and userfaultfd. We showed that fixed sequential prefetch can double TTFR
for memory-heavy workloads by congesting the fault-path TCP channel, and that a simple
per-window controller using duplicate pressure and queue depth can detect and disable
wasteful prefetch, recovering the majority of the performance loss. On three workloads,
the adaptive policy reduces prefetch volume 20–58% relative to fixed prefetch while
matching or recovering near-lazy performance on TTFR. The system is implemented in
userspace without kernel modifications and is reproducible from a single `make bench-paper`
invocation.

---

## References

[CRIU] Checkpoint/Restore In Userspace. https://criu.org

[CRIU-lazy] CRIU Lazy Migration. https://criu.org/Lazy_migration

[userfaultfd] userfaultfd(2) Linux man page. https://man7.org/linux/man-pages/man2/userfaultfd.2.html

[Gu17] Gu et al., "Efficient Memory Disaggregation with Infiniswap," NSDI 2017.

[Amaro20] Amaro et al., "Can Far Memory Improve Job Throughput?" EuroSys 2020.

[Ruan20] Ruan et al., "AIFM: High-Performance, Application-Integrated Far Memory," OSDI 2020.

[Chen95] Chen and Baer, "Effective Hardware-Based Data Prefetching for High-Performance Processors," IEEE TC 1995.

[Srinath07] Srinath et al., "Feedback Directed Prefetching," HPCA 2007.

[Cao94] Cao et al., "The Influence of Caching on the Performance of Query Result Caches," VLDB 1994.

[Runc-lazy] Lazy restore support in runc. https://github.com/opencontainers/runc

[Shan18] Shan et al., "LegoOS: A Disseminated, Distributed OS for Hardware Resource Disaggregation," OSDI 2018.

[CXL] Compute Express Link Specification. https://www.computeexpresslink.org
