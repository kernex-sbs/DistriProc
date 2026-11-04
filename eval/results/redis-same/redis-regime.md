# Redis regime map + same-image traces: x86 loopback + netem, 2026-11-04

Cells, modes and harness as in `regime-stream/pytorch-stream.md`.
Workload: the `redis` workload, 200k keys. On this laptop `redis-server`
is **Valkey 9.1.2** (Arch ships Valkey under that name); the Pi runs
Redis 8.0.2. Probe: 20k fixed keys as MGET batches of 100
over a unix socket (so probe traffic is not shaped on `lo`).
No throughput phase. 5 iterations, median TTFR in ms.

- `redis-v2/`: full, full-net, lazy, lazy-prefetch, lazy-adaptive and the
  three cross-run stream modes. Trace overlap between the two recordings:
  64.5%.
- `redis-same/`: lazy-stream-same. Each iteration first runs an untimed
  record pass on the same image, then restores again streaming that trace
  (REAP-style upper bound).

| RTT µs | rate | best old | best cross-run stream | stream-same | same faults | vs old | vs stream |
|---:|---|---:|---:|---:|---:|---:|---:|
| 0 | 100mbit | 12331 lazy | 13234 stream | **9855** | 58 | 1.25× | 1.34× |
| 0 | 1gbit | 2427 full-net | 1814 stream | **1011** | 117 | 2.40× | 1.79× |
| 0 | 10gbit | 440 full-net | 331 all | **131** | 66 | 3.36× | 2.53× |
| 200 | 100mbit | 18192 lazy | 14632 stream | **9860** | 54 | 1.85× | 1.48× |
| 200 | 1gbit | 2435 full-net | 2506 all | **1024** | 79 | 2.38× | 2.45× |
| 200 | 10gbit | 436 full-net | 331 all | **129** | 45 | 3.38× | 2.57× |
| 1000 | 100mbit | 22330 full-net | 22023 stream | **9875** | 51 | 2.26× | 2.23× |
| 1000 | 1gbit | 2464 full-net | 2569 all | **1046** | 51 | 2.36× | 2.46× |
| 1000 | 10gbit | 478 full-net | 357 all | **140** | 37 | 3.41× | 2.55× |
| 2000 | 100mbit | 22354 full-net | 24372 all | **9899** | 51 | 2.26× | 2.46× |
| 2000 | 1gbit | 2496 full-net | 2647 all | **1073** | 49 | 2.33× | 2.47× |
| 2000 | 10gbit | 533 full-net | 437 all | **214** | 57 | 2.49× | 2.04× |

## Findings

1. **Cross-run streaming is a coin flip for Redis on loopback.** With 64.5%
   trace overlap, a stream mode wins only 6 of 12 cells (1.22–1.34×);
   full-net wins the rest by 1–8%. Misses (thousands, one RTT each) eat
   the gain. PyTorch, with 98.6–99% overlap, won all 12.
2. **A same-image trace wins every cell, 1.25–3.41× over the best old
   policy and 1.34–2.57× over cross-run streaming.** Misses drop from
   thousands to under 120. TTFR is flat in RTT and tracks bandwidth
   (about 9.9 s at 100 Mbit for the ~120 MB working set).
3. **The cost moves to the record pass.** It is a plain lazy restore with
   tracing: about 65 s at 2 ms RTT. stream-same is an upper bound for a
   second restore of the same image, not a first-restore number.
4. **Low cross-run overlap comes from heap-layout jitter on the laptop,
   not from the working set.** (Checked 2026-11-04; test scripts not
   committed.)
   - Per 256 MB region, both laptop traces have the same page counts
     (27210 vs 27212), but the long runs sit a few pages apart (a
     1313-page run at `…2f8e000` vs `…2f7b000`). The process maps are
     identical under `setarch -R`; placement inside the jemalloc arena
     shifts.
   - Test: start the server three times with ASLR off, load 200k keys,
     read `DEBUG OBJECT` addresses of 201 sampled keys. Valkey 9.1.2 on
     the laptop: 87–183/201 at the same address. Redis 8.0.2 on Pi A:
     193–197/201.
   - On the laptop, Valkey's random hash seed contributes: its hashtable allocates
     overflow buckets depending on where keys hash, so table overhead
     differs per run (5,878,672 / 5,875,408 / 5,875,536 B). Pinning the
     seed (LD_PRELOAD shim on `/dev/urandom`) makes overhead identical
     and raises matches to 154–182/201, but not to 201.
   - Disabling active rehash or jemalloc decay/background purging does
     not help.
   - **Valkey itself is deterministic on the Pi.** Valkey 8.1.1 (Debian,
     jemalloc 5.3.0) on Pi A: 197–201/201, same as Redis 8.0.2
     (195–199/201). So the laptop, not the Valkey hashtable, is what
     breaks reproducibility.
   - On the laptop, not the cause: CPU count (`taskset -c 0-3`: 65–135;
     `-c 0`: 25–146). Partly the cause: the jemalloc build. Valkey links
     the system jemalloc, upgraded to 5.4.0 on 2026-10-24; swapping in
     5.3.1 via `LD_LIBRARY_PATH` gives 142–156/201 (5.4.0: 64–130).
   - The shifts are whole pages (4, 8 or 20 KB) that appear and vanish
     along the insertion order rather than accumulating, i.e. freed
     multi-page extents get reused in a timing-dependent order. Not
     isolated further; Valkey 9.1 vs 8.1 is also not separated.
   - Implication: cross-run traces only work for applications whose heap
     layout is reproducible. Same-image traces do not depend on it.
