# Trace-ordered streaming: pytorch, x86 loopback + netem, 2026-11-03

Builds on `eval/results/regime/pytorch-regime.md`, using the same setup
and cells. Values are median TTFR in ms. "faults" means demand faults.

## Modes

- **lazy-record** is plain lazy with `DISTRIPROC_TRACE`. It logs the
  addresses of demand-fetched pages in fault order. ASLR is off
  (`setarch -R`).
- **lazy-stream** takes the trace from an earlier run and sends it as one
  server-push request. Pages are installed as they land. Demand faults use
  their own connection.
- **lazy-stream-pf** works like lazy-stream, plus sequential/stride
  prefetch, but only around faults that miss the trace.
- **lazy-stream-all** streams the trace first, then every other image page,
  ordered by distance to the nearest traced page.

## Main result: lazy-stream vs the best old policy (5 iterations)

| RTT µs | rate | best old | stream | stream-pf | stream-all | speedup |
|---:|---|---:|---:|---:|---:|---:|
| 0 | 100mbit | 6278 lazy | **5274** | 6033 | 16822 | 1.19× |
| 0 | 1gbit | 873 prefetch | **585** | 651 | 2042 | 1.49× |
| 0 | 10gbit | 335 prefetch | **129** | 132 | 205 | 2.60× |
| 200 | 100mbit | 7855 prefetch | **5292** | 5910 | 18969 | 1.48× |
| 200 | 1gbit | 1134 adaptive | **682** | 696 | 1265 | 1.66× |
| 200 | 10gbit | 521 full-net | 211 | **163** | 243 | 3.20× |
| 1000 | 100mbit | 9005 prefetch | **5751** | 6099 | 17526 | 1.57× |
| 1000 | 1gbit | 2286 adaptive | 933 | **820** | 1517 | 2.79× |
| 1000 | 10gbit | 549 full-net | 518 | 363 | **249** | 2.20× |
| 2000 | 100mbit | 10464 adaptive | **5679** | 6531 | 20990 | 1.84× |
| 2000 | 1gbit | 2982 full-net | 1117 | **1028** | 2265 | 2.90× |
| 2000 | 10gbit | 627 full-net | 815 | 621 | **338** | 1.86× |

A stream mode wins all 12 cells.

## What it took

The first version reused the `--hot-pages` thread: 1024 requests in flight,
one 8 B request per page. Diagnostics (`stream-diag`) found three costs:

1. At 10 Gbit the Python page server capped out at 44k pages/s. Server push
   reached about 275k pages/s at 10 Gbit and line rate at 1 Gbit. The
   0/10G cell dropped from 405 to 129 ms.
2. The stream ran at only 6–17k pages/s once RTT was 2 ms, so the process
   overtook it and faulted on pages still "ahead" in the stream. Server
   push removed the "ahead" faults.
3. The remaining cost is **misses**: pages touched in this run but absent
   from the trace. Each costs about one RTT, one fault at a time.

## Why misses happen: heap divergence, not ASLR

- Two recordings share 98.6–99.0% of pages, with a median rank shift of 4.
- The differences sit in the brk heap (`0x5555…`). One run had a 617-page
  heap region the other lacked.
- Taking the union of three other runs' traces still leaves 85–690 misses
  against a fourth run. Every run allocates some fresh heap.
- **Traces recorded on earlier runs therefore have an irreducible miss
  set.** A same-image trace (REAP-style, recorded on the first restore of
  this image) does not have this problem; see below.

## Same-image traces: lazy-stream-same (`pytorch-same/`, 5 iterations)

Each iteration dumps, runs an untimed record pass (plain lazy restore
with tracing), then restores the same image again, streaming that trace.
Faults are the medians of the "ahead" and "miss" classes.

| RTT µs | rate | best old | best stream | stream-same | ahead / miss | vs old | vs stream |
|---:|---|---:|---:|---:|---:|---:|---:|
| 0 | 100mbit | 6278 lazy | 5274 | **5129** ±34 | 31 / 0 | 1.22× | 1.03× |
| 0 | 1gbit | 873 prefetch | 585 | **546** ±3 | 25 / 0 | 1.60× | 1.07× |
| 0 | 10gbit | 335 prefetch | 129 | **93** ±6 | 0 / 0 | 3.60× | 1.39× |
| 200 | 100mbit | 7855 prefetch | 5292 | **5136** ±33 | 27 / 1 | 1.53× | 1.03× |
| 200 | 1gbit | 1134 adaptive | 682 | **544** ±5 | 24 / 0 | 2.08× | 1.25× |
| 200 | 10gbit | 521 full-net | 163 | **92** ±4 | 11 / 0 | 5.66× | 1.77× |
| 1000 | 100mbit | 9005 prefetch | 5751 | **5130** ±8 | 28 / 2 | 1.76× | 1.12× |
| 1000 | 1gbit | 2286 adaptive | 820 | **554** ±4 | 21 / 2 | 4.13× | 1.48× |
| 1000 | 10gbit | 549 full-net | 249 | **99** ±7 | 17 / 3 | 5.55× | 2.52× |
| 2000 | 100mbit | 10464 adaptive | 5679 | **5147** ±9 | 28 / 4 | 2.03× | 1.10× |
| 2000 | 1gbit | 2982 full-net | 1028 | **561** ±2 | 22 / 4 | 5.32× | 1.83× |
| 2000 | 10gbit | 627 full-net | 338 | **109** ±3 | 18 / 4 | 5.75× | 3.10× |

- stream-same wins all 12 cells: 1.22–5.75× over the best old policy and
  1.03–3.10× over the best cross-run stream mode.
- Misses drop from hundreds to 0–4. TTFR is nearly flat in RTT (93 →
  109 ms at 10 Gbit, 546 → 561 ms at 1 Gbit) and tracks bandwidth: the
  ~63 MB working set takes about 5.1 s at 100 Mbit.
- The gain over cross-run streaming grows with bandwidth × RTT, where
  misses (one RTT each) dominate. At 100 Mbit the stream itself is the
  cost and the trace source barely matters (1.03–1.12×).
- Record-pass cost (median, untimed): 6.3 / 1.3 / 0.8 s at RTT 0;
  9.4 / 4.5 / 3.9 s at 200 µs; 21.8 / 17.1 / 16.6 s at 1 ms; 37.6 /
  32.6 / 32.2 s at 2 ms (100 Mbit / 1 Gbit / 10 Gbit). It needs
  `PT_PROBE_TIMEOUT_S=300`.
- Harness fix this needed: the record pass appends to the process's
  stdout log, and CRIU refuses to restore an open file whose size changed
  ("has bad size 44 (expect 18)"). Both harnesses truncate `workload.log`
  back to its dump-time size between the passes.

## Covering misses with the rest of the image: the FIFO bottleneck

lazy-stream-all cuts faults to about 50, but every demand reply then waits
behind the background stream in the bottleneck queue. At 100 Mbit with
cubic, 55 misses cost 12.4 s (about 225 ms each).

3 iterations; RTT 2000 µs = netem delay 1000.

| cell | stream | all: cubic | vegas | bbr | lp | pace 0.85 | pace 0.7 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0 / 100M | **5437** | 11894 | 7685 | 8128 | 11832 | 6423 | 5861 |
| 0 / 1G | **600** | 1076 | 823 | 953 | 1114 | 752 | 824 |
| 0 / 10G | **169** | 186 | 195 | 187 | 191 | 192 | 204 |
| 2000 / 100M | **6187** | 10806 | 7420 | 8626 | 11776 | 7178 | 7400 |
| 2000 / 1G | 1342 | 1176 | 954 | 1121 | 1264 | **843** | 1710 |
| 2000 / 10G | 846 | **243** | 251 | 249 | 262 | 247 | 335 |

- In the "all" columns, vegas, bbr and lp are TCP congestion controls set
  on the stream socket only (`DISTRIPROC_STREAM_CC`).
- In the pace columns, the rest is paced at f × the delivery rate measured
  during the trace phase (`DISTRIPROC_STREAM_PACE`, `TCP_INFO` →
  `SO_MAX_PACING_RATE`). The measured rate was accurate: 103–111 Mbit/s
  on the 100M link.
- Delay-based congestion control and pacing roughly halve the damage. No
  variant matches plain stream at 100 Mbit or at 1 Gbit with zero RTT.
- TCP-LP does nothing, because it yields only to competing TCP flows, and
  the demand traffic is too small to count as one.
- Rest-streaming wins only where misses × RTT outweighs the queue it
  builds, which means high bandwidth at high RTT.
- **Open problem:** demand and background traffic share one FIFO queue at
  the bottleneck, and no endpoint-only mechanism tried here isolates them.

## Caveats

- netem on `lo` gives a single FIFO per direction. Real egress queues
  (fq_codel, fq) isolate flows. The Pi link will show whether the FIFO
  effect survives there.
- One workload so far.
