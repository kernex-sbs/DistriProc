# Redis on real hardware: 2× Raspberry Pi 5, 2026-11-04

Same setup as `pi-stream/pi-stream.md` (direct 1 GbE, fq_codel, netem on
A's egress, TCP_NODELAY, 5 iterations), with these differences:

- Workload: Redis, 200k keys. The probe is 20k fixed keys as MGET batches
  of 100 over TCP (`REDIS_CLIENT_TCP=1`: Pi A's kernel lacks `unix_diag`,
  so CRIU cannot dump unix sockets). No throughput phase (`NO_THROUGHPUT=1`).
- CRIU 4.2.1 (the PyTorch Pi runs used 4.1.1, which fails to dump inet
  sockets on kernel 6.18).
- Image: 106.7k pages (437 MB). Trace: 27.1k pages. The two recordings
  (delay 0) overlap 98.8%.

Median TTFR in ms (± population sd), then median demand faults.

| mode | RTT 0.16 ms | 1.16 ms | 2.16 ms |
|---|---:|---:|---:|
| full (local floor) | 259 ±2 | 260 ±2 | 258 ±2 |
| full-net | 4059 ±3 | 4064 ±4 | 4073 ±8 |
| lazy | 4586 ±11 · 27093 | – | – |
| lazy-prefetch | 3606 ±7 · 8892 | 9989 ±24 · 7998 | 17709 ±25 · 7969 |
| lazy-adaptive | 3616 ±15 · 8738 | 8218 ±71 · 6162 | 13433 ±130 · 5887 |
| lazy-stream | 1018 ±23 · 500 | 1155 ±100 · 467 | 1359 ±210 · 424 |
| lazy-stream-pf | 1021 ±15 · 498 | 1049 ±7 · 398 | 1058 ±65 · 286 |
| lazy-stream-all | 1317 ±145 · 533 | 1715 ±239 · 619 | 1742 ±275 · 454 |
| **lazy-stream-same** | **1002** ±1 · 430 | **1006** ±0 · 371 | **1014** ±1 · 278 |
| speedup vs best old | 3.6× (prefetch) | 4.0× (full-net) | 4.0× (full-net) |

The stream-same record pass (untimed) took 4.6 s, 32.2 s and 59.4 s.

## Findings

1. **Streaming wins every delay by 3.6–4.0×.** Redis touches a quarter of
   its image before the first reply. full-net moves all 437 MB (about
   3.5 s at line rate); streaming moves the 111 MB working set.
2. **stream-same sits on the bandwidth floor.** 111 MB at 1 Gbit is about
   0.9 s. In iteration 3 at delay 0, stream-same had 411 "ahead" faults
   (the process overtook the stream) and 7 misses. RTT barely moves it
   (1002 → 1014 ms).
3. **Cross-run traces are already near the same-image bound here.**
   Overlap is 98.8%, so stream-pf is within 2–4% of stream-same. Plain
   stream degrades with RTT (527 misses at delay 0, about one RTT each);
   prefetching around misses removes most of that.
4. **Old lazy policies collapse with RTT.** Redis's hash table is touched
   at random, so sequential/stride prefetch helps little; adaptive reaches
   13.4 s at 2.16 ms RTT.
5. **stream-all loses again at 1 Gbit**, with high variance, as for PyTorch.

Note (2026-11-04 audit): recomputing the overlap from the committed
trace-a/trace-b with the harness formula gives 99.2% (a in b) / 99.1% (b in a),
not 98.8%. The paper uses 99.2%.
