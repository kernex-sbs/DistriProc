# Trace-ordered streaming on real hardware: 2× Raspberry Pi 5, 2026-11-03

Setup:

- `eval/crosshost_2machine.sh`. Pi A runs the workload and restores it.
  Pi B runs the page server.
- The link is direct 1 GbE (macb driver, fq_codel, BQL on).
- Base RTT is 164 µs. netem delay goes on A's egress only, so B→A data
  keeps B's real qdisc. RTT = 164 µs + delay.
- TCP_NODELAY is on. 5 iterations. The image is 74.7k pages.
- The traces are recorded at delay 0. Overlap is 97%, and both record
  TTFRs are 2597 and 2688 ms (the same as plain lazy).
- Values are median TTFR in ms (± population sd).

| mode | RTT 0.16 ms | 1.16 ms | 2.16 ms |
|---|---:|---:|---:|
| full (local floor) | 277 ±7 | 269 ±12 | 275 ±9 |
| full-net | 2939 ±7 | 2937 ±10 | 2947 ±11 |
| lazy | 2588 ±18 | – | – |
| lazy-prefetch | 1023 ±4 | 2850 ±24 | 5014 ±20 |
| lazy-adaptive | 1029 ±5 | 2569 ±21 | 4226 ±50 |
| lazy-stream | 728 ±10 | 1127 ±39 | 1594 ±59 |
| **lazy-stream-pf** | **700** ±29 | **867** ±45 | **1076** ±30 |
| lazy-stream-all | 1145 ±64 | 1249 ±34 | 1372 ±48 |
| speedup vs best old | 1.46× (prefetch) | 2.96× (adaptive) | 2.74× (full-net) |

## Findings

1. **The loopback result holds on real hardware.** lazy-stream-pf wins
   every delay. The speedup matches the x86 1 Gbit cells (1.49×, 2.79×,
   2.90×). The old-policy ordering is the same too: prefetch wins at low
   RTT and full-net wins from about 2 ms.
2. **Misses are the remaining cost.** In iteration 3, each miss costs about
   one RTT plus 0.7 ms of service time:

   | mode | misses @0.16 | ms/miss | @2.16 | ms/miss |
   |---|---:|---:|---:|---:|
   | stream | 611 | 0.86 | 529 | 2.50 |
   | stream-pf | 401 | 1.39 | 330 | 2.82 |
   | stream-all | 398 | 1.99 | 296 | 3.54 |

   Prefetching around misses removes about a third of them. That is where
   stream-pf's lead comes from.
3. **Streaming the rest of the image does not pay at 1 Gbit.**
   - The whole image takes about 2.7 s at line rate, which is longer than
     the TTFR. Most miss pages are still in flight when they are faulted.
     The "miss" count covers any page outside the trace, including
     in-flight rest pages.
   - Each miss also costs about 1.1 ms more than under plain stream.
   - The loopback runs showed the same pattern: stream-all won only at
     10 Gbit.
4. **Flow isolation reduces the shared-queue penalty but does not remove
   it.**
   - On loopback (a single FIFO), demand replies queued behind the stream
     for about 225 ms each at 100 Mbit.
   - Here, with fq_codel and BQL, the queue adds about 1.1 ms per miss.
   - That fits the BQL limit (130 KB, about 1 ms at 1 Gbit) plus TSO
     bursts of up to 64 KB under the qdisc.
