# Regime map: pytorch (ResNet), x86 loopback + netem, 2026-11-03

Setup: `eval/regime_sweep.sh`, 5 iterations per cell, TCP_NODELAY on.
RTT = 2 × netem one-way delay. Image 80.4k pages (329 MB). Working set
before first response 15.5k pages (63 MB, 19%). Values are median TTFR
in ms (± population sd). `full` reads local images: the floor, not a
contender.

| RTT µs | rate | full | full-net | lazy | prefetch | adaptive | best |
|---:|---|---:|---:|---:|---:|---:|---|
| 0 | 100mbit | 207 | 26664 | **6278** | 7706 | 7898 | lazy |
| 0 | 1gbit | 206 | 2899 | 1388 | **873** | 889 | prefetch |
| 0 | 10gbit | 212 | 509 | 800 | **335** | 341 | prefetch |
| 200 | 100mbit | 210 | 26749 | 9405 | **7855** | 8060 | prefetch |
| 200 | 1gbit | 213 | 2904 | 4544 | 1153 | **1134** | adaptive |
| 200 | 10gbit | 222 | **521** | 3966 | 628 | 606 | full-net |
| 1000 | 100mbit | 222 | 26763 | – | **9005** | 9096 | prefetch |
| 1000 | 1gbit | 208 | 2928 | – | 2550 | **2286** | adaptive |
| 1000 | 10gbit | 212 | **549** | – | 2188 | 1711 | full-net |
| 2000 | 100mbit | 220 | 26765 | – | 10853 | **10464** | adaptive |
| 2000 | 1gbit | 210 | **2982** | – | 4414 | 3726 | full-net |
| 2000 | 10gbit | 215 | **627** | – | 4231 | 3223 | full-net |

Sd is under 1.5% of the median in every cell. Demand-only lazy is skipped
above 250 µs one-way, where it exceeds the 30 s probe timeout.

## Findings

1. **No single policy wins.** There are three zones. Lazy wins when
   bandwidth is scarce and RTT is near zero. Prefetch or adaptive wins in
   the middle. Full-net wins when bandwidth × RTT is high.
2. **Prefetch overfetches about 42%.** It serves around 22k pages against a
   15.5k-page working set. At 100 Mbit/RTT 0 that makes it slower than
   demand-only lazy (7706 vs 6278).
3. **Cost grows by about one RTT per demand fault.** Lazy takes 15.5k
   faults, adding 3.2 s at 200 µs. Prefetch still takes about 2k faults,
   adding 3.5 s between RTT 0 and 2 ms, which works out to 1.77k RTTs.
4. **There is a large gap to the bound.** The bound is full + working-set
   bytes ÷ bandwidth, with zero RTTs, so it is optimistic.

   | rate | bound | env@0 | env@200 | env@1000 | env@2000 |
   |---|---:|---:|---:|---:|---:|
   | 100mbit | 5.27 s | 1.19× | 1.49× | 1.71× | 1.99× |
   | 1gbit | 0.72 s | 1.21× | 1.58× | 3.18× | 4.14× |
   | 10gbit | 0.26 s | 1.29× | 2.00× | 2.11× | 2.41× |

   The envelope is the best of full-net, lazy, prefetch and adaptive.
   A hybrid that streams the recorded working set at line rate and serves
   only true misses on demand targets this gap, which is largest at
   1 Gbit with RTT of 1 ms or more.
