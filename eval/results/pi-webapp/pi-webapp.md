# Web app on real hardware: 2× Raspberry Pi 5, 2026-11-04

Same setup as `pi-redis/pi-redis.md` (direct 1 GbE, fq_codel, netem on A's
egress, TCP_NODELAY, CRIU 4.2.1, 5 iterations).

- Workload: `webapp` (`eval/workloads/webapp_server.py`): Python
  `http.server` + in-memory SQLite (4M orders, 50k customers, 20k products)
  + Jinja2. The probe fetches 200 fixed customer pages over TCP on
  loopback (`WEBAPP_CLIENT_TCP=1`). No throughput phase.
- Image: 63.3k pages (259 MB). Trace: 26.6k pages (109 MB, 42% of the
  image). The two recordings overlap 99.9%, despite Python's per-run hash
  randomization.

Median TTFR in ms (± population sd), then median demand faults.

| mode | RTT 0.16 ms | 1.16 ms | 2.16 ms |
|---|---:|---:|---:|
| full (local floor) | 323 ±1 | 323 ±2 | 325 ±1 |
| full-net | 2601 ±2 | 2607 ±4 | 2607 ±1 |
| lazy | 4854 ±46 · 26656 | – | – |
| lazy-prefetch | 2505 ±867 · 8512 | 10396 ±13 · 8446 | 18892 ±18 · 8443 |
| lazy-adaptive | 2484 ±77 · 8158 | 8008 ±94 · 6366 | 13490 ±72 · 5979 |
| lazy-stream | **966** ±0 · 360 | 973 ±1 · 281 | 989 ±4 · 211 |
| lazy-stream-pf | 1127 ±3 · 526 | 1313 ±8 · 474 | 1591 ±42 · 443 |
| lazy-stream-all | 1322 ±3 · 511 | 1454 ±8 · 429 | 1526 ±12 · 344 |
| lazy-stream-same | 972 ±0 · 388 | **979** ±0 · 338 | **985** ±0 · 263 |
| speedup vs best old | 2.57× (adaptive) | 2.66× (full-net) | 2.65× (full-net) |

## Findings

1. **Streaming wins every delay by 2.6–2.7×.** The gain is smaller than
   Redis's 3.6–4.0× because the web app touches 42% of its image before
   the first response (Redis: 25%).
2. **A cross-run trace is as good as a same-image one here.** Overlap is
   99.9%. Plain stream misses about 133 pages per run against 0–2 for
   stream-same, yet TTFR differs by under 1%. Most faults in both are
   "ahead" (the process overtakes the stream), so TTFR sits 11–13% above
   the working set's transfer time (109 MB at 1 Gbit ≈ 0.87 s).
3. **Prefetching around misses hurts.** stream-pf is 17–61% slower than
   plain stream and stream-all 37–54% slower: both put extra pages on the
   link ahead of pages the process needs.
4. **Old lazy policies collapse with RTT**, as for Redis: B-tree and
   object-heap accesses defeat sequential prefetch, which still leaves
   6–8.5k faults (adaptive: 13.5 s at 2.16 ms).

## After the first response (`pi-webapp-tput/`, `pi-webapp-tput-all2/`)

Same setup with the throughput phase on: right after TTFR the restored
process serves 1000 other customer pages (fixed seed, disjoint from the
probe's). Record runs never run it, so traces still stop at the first
response. "1200 done" = TTFR + time for the 1000 requests, i.e. when the
probe plus the follow-up load has been served. 5 iterations, medians.

| mode | TTFR @0.16 | req/s | 1200 done | TTFR @2.16 | req/s | 1200 done |
|---|---:|---:|---:|---:|---:|---:|
| full (local) | 325 | 1071 | 1259 | 324 | 1077 | 1253 |
| full-net | 2597 | 1072 | 3530 | 2610 | 1074 | 3541 |
| lazy-adaptive | 2462 | 701 | 3889 | 13406 | 237 | 17625 |
| lazy-stream | 965 | 219 | 5531 | 980 | 21 | 48599 |
| lazy-stream-pf | 1019 | 414 | 3434 | 1149 | 62 | 17278 |
| lazy-stream-same | 970 | 209 | 5755 | 983 | 21 | 48602 |
| **lazy-stream-all** | 1045 | 497 | **3057** | 1134 | 498 | **3142** |

1. **Streaming only the trace wins the first response and loses the
   rest.** The trace covers what the probe touched. Each later request
   reads cold pages, every one a demand fault at one RTT with nothing in
   flight: 21 req/s at 2.16 ms, 50× below eager, and 1200 requests take
   48.6 s against 3.5 s for full-net.
2. **stream-all gets both.** Its TTFR is 2.3–2.5× better than eager, and it
   finishes 1200 requests 11–13% sooner, because the rest of the image
   arrives in the background (done about 2.3 s in) while requests are
   served. Throughput while the rest is still arriving is about half of
   eager's.
3. Once a process has all its pages, it runs at full speed: full-net and
   full serve 1071–1077 req/s.
4. stream-all TTFR here (1045 / 1134 ms) is lower than in the main run
   above (1322 / 1526 ms); both runs have sd under 2%. Not explained.
5. A first attempt (`pi-webapp-tput-all/`, discarded) recorded 5-page
   traces: both record passes finished in about 330 ms with 5 faults, as if
   restored eagerly. It started a minute after the previous run ended; the
   rerun two minutes later was normal. Cause not found.
