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
- Serves faulted pages synchronously from a TCP page server (loopback baseline;
  netem-injected RTT in §V-H, and a real two-machine LAN in §V-J)
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

> We show that whether fixed sequential prefetch helps or hurts post-restore TTFR in CRIU
> lazy restore is governed by round-trip time, with a crossover between 100 and 150 us
> (harmful below, where speculation contends with fault resolution for the shared
> page-server transport; beneficial above, where it hides serial fault latency), and
> present DistriProc, a userspace runtime whose duplicate-pressure/queue-depth controller
> recovers the congestion-bound regression as one workable operating point in that space.

---

## Headline Claims

> **Updated to the n=20 mainline-6.18.7 dataset, the netem RTT sweep, the
> cross-kernel results, and the real two-machine LAN validation (§V-J).
> Canonical numbers live in `paper/paper.tex`.** The central claim is now C0
> (the RTT crossover); C1–C3 are the loopback findings it contextualizes.

### C0 — Whether fixed prefetch helps or hurts post-restore TTFR is governed by RTT

**Precise statement:**
Fixed sequential prefetch is harmful below an RTT crossover (between 100 and
150 µs) and beneficial above it. At loopback it increases PyTorch TTFR +88%
(650→1227 ms); at 1 ms RTT it reduces TTFR −37% (16700→10462 ms); at 2 ms
demand-only lazy times out while prefetch completes. Measured by injecting RTT
with `netem` (`eval/crosshost_netem.sh`, n=10), and confirmed on real hardware:
a two-machine LAN run at 311 µs (both hosts Linux 7.0.x, n=50) gives fixed
1985±28 ms vs lazy 7073±124 ms, −71.9% (`eval/crosshost_2machine.sh`).

**Caveat:** the netem sweep is emulated on one host; the two-machine run
confirms the direction on real hardware but at a single RTT and on a different
kernel (7.0.x vs 6.18.7), so absolute magnitudes are not cross-comparable. RDMA
untested. The controller is tuned for the sub-crossover (congestion-bound)
regime; above the crossover its congestion-only signals behave erratically (not
"conservative").

---

### C1 — Lazy restore provides significant TTFR benefit for memory-light workloads

**Precise statement:**
For workloads whose active footprint at restore time is small, lazy restore allows the
process to begin serving requests before all pages are transferred, cutting TTFR
substantially compared to full restore.

**Evidence:**
- test_loop: full=1019ms, lazy=42ms → 24.3x reduction (n=20)

**Caveat the paper must state:**
This benefit inverts for workloads that must page in their entire working set before
serving (e.g. a model inference server). pytorch: full=191ms, lazy=650ms → lazy 3.4x slower.
The benefit is workload-dependent and the paper does not claim lazy restore is universally
faster.

---

### C2 — Fixed prefetch policies can significantly degrade TTFR in the post-restore phase

**Precise statement:**
A fixed sequential prefetch policy that is always enabled causes TTFR regression on
memory-heavy workloads because async prefetch traffic competes with fault-path traffic
for the shared page-server transport (the two TCP connections are independent but
converge at one page server), increasing queue backlog and delaying fault resolution.

**Evidence (loopback):**
- pytorch lazy=650ms, lazy-prefetch=1227ms → fixed prefetch +88% (Welch t=−45.9)
- pytorch page faults: lazy=15515, lazy-prefetch=2322 (prefetch reduces faults 85%
  yet increases TTFR — reduced faults do not imply better latency)

**Caveat the paper must state:**
On memory-light workloads (redis, test_loop) fixed prefetch is not harmful (TTFR delta
within noise). The failure mode is specific to large working sets AND to the
sub-crossover RTT regime — above the 100–150 µs crossover fixed prefetch is
beneficial (see C0).

---

### C3 — An adaptive controller using duplicate pressure and queue depth avoids prefetch harm while preserving benefit

**Precise statement:**
A lightweight per-window controller that monitors duplicate fetch requests and async queue
depth can identify when prefetch is harmful and disable it, recovering near-demand-only
performance on memory-heavy workloads and reducing prefetch volume on all workloads,
without regressing memory-light workloads.

**Evidence (loopback):**
- pytorch: lazy-adaptive=655ms vs lazy-prefetch=1227ms (recovers 572ms; t=+46.1)
- pytorch: adaptive faults≈lazy faults (15496 vs 15515) — controller backed off completely
- pytorch: adaptive prefetched=1466 pages vs fixed=788 (re-enables post-cooldown after
  the fault storm; the win on pytorch is TTFR, not volume)
- redis: adaptive prefetch volume −52% vs fixed, TTFR delta +1ms (noise)
- test_loop: adaptive prefetch volume −55% vs fixed, TTFR delta within noise

**Caveat the paper must state:**
Adaptive ≈ plain lazy on TTFR: pytorch adaptive=655ms vs lazy=650ms (+5.5ms,
t=−0.82, p=0.42 → statistically indistinguishable). The claim is "recovers the
congestion-bound regression and reduces waste," not "adaptive always wins." Above the
RTT crossover (C0) the controller's congestion-only signals behave erratically (it can
flap near the crossover and mis-disable at high RTT). It is a heuristic, not learned.

---

## Metrics Used — Definitions

**TTFR (Time To First Request):** Wall-clock time from CRIU restore invocation to first
successful application-level response (workload-specific probe). Measured per iteration,
reported as mean ± 95% CI across n=20 iterations (RTT sweep: n=10).

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

**Throughput baseline for redis/test_loop:** redis lazy modes achieve ~84-85% of full
restore throughput (full=105,050 ops/sec; n=20 canonical dataset). This is a real cost
of the TCP page server on a high-throughput in-memory workload. The paper must
acknowledge this as a transport-layer limitation, not a policy failure. The adaptive
controller does not fix TCP overhead. (An earlier small-sample pilot reported a lower
ratio; superseded by the n=20 6.18.7 matrix in paper.tex Table tab:throughput.)

---

## What The Paper May Not Claim

- "First remote paging system for Linux"
- "General distributed shared memory"
- "RDMA-capable" or "low-latency network"
- "Writable remote memory"
- "Production-ready"
- "Adaptive always outperforms fixed prefetch" — only on memory-heavy workloads
- Prefetch hit rate as evidence of adaptive success
