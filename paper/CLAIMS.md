# DistriProc — Locked Claims

This file is the paper's contract with the artifact. Every sentence in the paper must
be consistent with this document. If a draft claim is not listed here, it should not
appear in the paper without updating this file first.

---

## What The System Is

An adaptive post-restore remote-memory runtime for Linux processes checkpointed with CRIU.

After a lazy restore, a process's pages live on a remote page server. The runtime intercepts
page faults via `userfaultfd`, fetches faulted pages from the server over TCP, and optionally
prefetches additional pages asynchronously. An adaptive controller observes duplicate pressure
and async queue depth within a sliding window of faults, and disables prefetch when those
signals indicate it is causing more harm than benefit.

---

## What The System Does — Precisely

- Intercepts page faults on lazily-restored processes via `userfaultfd`
- Serves faulted pages synchronously from a TCP page server (loopback in all experiments)
- Prefetches sequential pages asynchronously off the fault path (configurable window/stride)
- Tracks duplicate fetch requests and async queue depth per 128-fault control window
- Disables prefetch when duplicate pressure exceeds threshold or queue depth is large
- Re-enables prefetch via a small probe window once the async queue drains
- Supports three policy modes: `lazy` (demand-only), `lazy-prefetch` (fixed), `lazy-adaptive`

---

## What The System Does NOT Do

The following are explicitly out of scope for this paper:

- Writable remote-memory coherence (no write-through or write-back protocol)
- RDMA or any transport other than TCP
- Multi-node or distributed shared memory
- Replication or high availability
- Persistent remote state (pages are not written back to the server)
- Cross-process or OS-level integration (no kernel patches)
- General-purpose remote paging (scope is the post-restore phase only)

---

## Contribution Statement

One sentence:

> We present an adaptive userspace runtime that selects prefetch policy per control window
> during the post-restore remote-memory phase of CRIU lazy restore, using duplicate-fetch
> pressure and async queue depth as lightweight signals, and show that this avoids the TTFR
> degradation caused by fixed prefetch policies on memory-heavy workloads while preserving
> benefit on memory-light ones.

---

## Headline Claims (3, locked)

### C1 — Lazy restore provides significant TTFR benefit for memory-light workloads

**Precise statement:**
For workloads whose active footprint at restore time is small, lazy restore allows the
process to begin serving requests before all pages are transferred, cutting TTFR
substantially compared to full restore.

**Evidence:**
- test_loop: full=1020ms, lazy=48ms → 21x reduction

**Caveat the paper must state:**
This benefit inverts for workloads that must page in their entire working set before
serving (e.g. a model inference server). pytorch: full=209ms, lazy=625ms → lazy 3x slower.
The benefit is workload-dependent and the paper does not claim lazy restore is universally
faster.

---

### C2 — Fixed prefetch policies can significantly degrade TTFR in the post-restore phase

**Precise statement:**
A fixed sequential prefetch policy that is always enabled causes TTFR regression on
memory-heavy workloads because async prefetch traffic competes with fault-path traffic
over the same TCP connection, increasing queue backlog and delaying fault resolution.

**Evidence:**
- pytorch lazy=625ms, lazy-prefetch=1159ms → fixed prefetch doubles TTFR
- pytorch page faults: lazy=15743, lazy-prefetch=6352 (prefetch reduces faults 60%
  but increases TTFR 85% — reduced faults do not imply better latency)

**Caveat the paper must state:**
On memory-light workloads (redis, test_loop) fixed prefetch is not harmful (TTFR delta
is within noise). The failure mode is specific to workloads with large working sets.

---

### C3 — An adaptive controller using duplicate pressure and queue depth avoids prefetch harm while preserving benefit

**Precise statement:**
A lightweight per-window controller that monitors duplicate fetch requests and async queue
depth can identify when prefetch is harmful and disable it, recovering near-demand-only
performance on memory-heavy workloads and reducing prefetch volume on all workloads,
without regressing memory-light workloads.

**Evidence:**
- pytorch: lazy-adaptive=686ms vs lazy-prefetch=1159ms (recovers 473ms, −41%)
- pytorch: adaptive faults≈lazy faults (15888 vs 15743) — controller backed off completely
- pytorch: adaptive prefetched=1695 pages (probe window before disable) vs fixed=2121
- redis: adaptive prefetch volume −45% vs fixed, TTFR delta +6ms (noise)
- test_loop: adaptive prefetch volume −58% vs fixed, TTFR delta +1ms (noise)

**Caveat the paper must state:**
Adaptive mode does not always outperform plain lazy on TTFR. pytorch adaptive=686ms vs
lazy=625ms (+10%). The claim is "avoids the worst outcome and reduces waste," not "adaptive
always wins." The controller is a heuristic; it is not learned or predicted.

---

## Metrics Used — Definitions

**TTFR (Time To First Request):** Wall-clock time from CRIU restore invocation to first
successful application-level response (workload-specific probe). Measured per iteration,
reported as mean ± stddev across 5 iterations.

**Throughput:** Application-level ops/sec measured after TTFR probe, on the restored process
(redis, test_loop) or a fresh inference process (pytorch — known limitation, stated in paper).

**Prefetch volume:** Total pages sent by the async prefetch worker per restore session, from
handler stats log.

**Duplicate pressure:** Count of prefetch requests for pages already served, within one
128-fault control window. Used as the primary adaptive signal. Not cited as "hit rate"
(which is unreliable for async prefetch — see below).

---

## Metrics The Paper Must NOT Misuse

**Hit rate / prefetch_hits:** Always 0% in all experiments. This is expected: if async
prefetch wins the race, the page is installed before the fault fires, so there is no fault
to count as a "hit." This metric is not a useful success indicator for async prefetch and
must not be cited as one. The paper should explain why the controller moved to duplicate
pressure instead.

**Throughput baseline for redis/test_loop:** redis lazy modes achieve ~68-69% of full
restore throughput (107k → 73k ops/sec). This fails the H2 threshold (>70%) and is a real
cost of the TCP page server on a high-throughput in-memory workload. The paper must
acknowledge this as a transport-layer limitation, not a policy failure. The adaptive
controller does not fix TCP overhead.

---

## What The Paper May Not Claim

- "First remote paging system for Linux"
- "General distributed shared memory"
- "RDMA-capable" or "low-latency network"
- "Writable remote memory"
- "Production-ready"
- "Adaptive always outperforms fixed prefetch" — only on memory-heavy workloads
- Prefetch hit rate as evidence of adaptive success
