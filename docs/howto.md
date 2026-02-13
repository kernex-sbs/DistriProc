# DistriProc How-To Guide

## 1. Building

```bash
make all
```

This produces four binaries in `src/`:
- `test_uffd` — userfaultfd PoC (local page faults)
- `test_uffd_tcp` — userfaultfd + TCP page fetching
- `test_loop` — simple workload for testing (1MB heap, counter)
- `lazy_handler` — custom CRIU lazy-pages daemon

## 2. Running Tests

```bash
make test
```

Non-root tests run automatically. CRIU tests require root:

```bash
sudo bash tests/run_tests.sh
```

## 3. Lazy Restore Walkthrough

This demonstrates the full DistriProc pipeline: checkpoint a process, serve its pages over TCP, and restore it with on-demand paging.

### Step 1: Start a workload

```bash
setsid src/test_loop --output /tmp/counter &
LOOP_PID=$!
# Wait for it to warm up
sleep 3
cat /tmp/counter   # Should show 2 or 3
```

### Step 2: Checkpoint

```bash
DUMP_DIR=/tmp/distriproc-demo
mkdir -p $DUMP_DIR
sudo criu dump -t $LOOP_PID -D $DUMP_DIR -j -v4 --log-file dump.log
```

The process is now frozen. Its memory is saved in `$DUMP_DIR/pages-*.img`.

### Step 3: Start the page server

```bash
python3 src/criu_page_server.py --images-dir $DUMP_DIR --port 9999 &
```

This parses the CRIU dump images and serves pages over TCP.

### Step 4: Start the lazy handler

```bash
sudo src/lazy_handler --images-dir $DUMP_DIR --address 127.0.0.1 --port 9999 --no-prefetch &
```

The handler listens on a Unix socket for CRIU restore to connect. When a page fault occurs, it fetches the page from the TCP server and installs it.

### Step 5: Restore with lazy pages

```bash
rm -f /tmp/counter
cd $DUMP_DIR
sudo criu restore --lazy-pages -D $DUMP_DIR -j -d --pidfile restore.pid
cd -
```

The process resumes immediately. Watch the counter:

```bash
sleep 2
cat /tmp/counter   # Counter is advancing again
```

### Step 6: Cleanup

```bash
kill $(cat $DUMP_DIR/restore.pid) 2>/dev/null
sudo rm -rf $DUMP_DIR /tmp/counter
```

## 4. Lazy Handler Options

```
src/lazy_handler [OPTIONS]
  --images-dir DIR       CRIU images directory (required)
  --address ADDR         Page server address (default: 127.0.0.1)
  --port PORT            Page server port (default: 9999)
  --no-prefetch          Disable all prefetching (best for most workloads)
  --prefetch-seq N       Sequential pages to prefetch per fault (default: 16)
  --prefetch-stride N    Stride-predicted pages to prefetch (default: 8)
  --hot-pages FILE       Binary file of hot page addresses for eager fetch
```

### Recommended configurations

**Best for most workloads** (lowest TTFR, highest throughput):
```bash
lazy_handler --images-dir DIR --address ADDR --port PORT --no-prefetch
```

**With prefetching** (reduces fault count but adds latency per fault):
```bash
lazy_handler --images-dir DIR --address ADDR --port PORT \
    --prefetch-seq 16 --prefetch-stride 8
```

**With hot page eager fetch** (pre-loads profiled pages at restore time):
```bash
# First, profile the running process
sudo python3 src/hot_pages.py --pid $PID --output /tmp/hot.bin --samples 3 --interval 1

# Then checkpoint and restore with hot pages
lazy_handler --images-dir DIR --address ADDR --port PORT \
    --prefetch-seq 16 --prefetch-stride 8 --hot-pages /tmp/hot.bin
```

## 5. Running Benchmarks

### Quick smoke test (test_loop only)

```bash
make bench-quick
```

### Full benchmark (test_loop + Redis + PyTorch)

```bash
make bench
```

Prerequisites for full benchmark:
```bash
sudo pacman -S redis                    # or: apt install redis-server
pip install torch torchvision           # PyTorch for inference workload
```

### Options

```bash
sudo bash eval/bench.sh [OPTIONS]
  --workloads LIST    Comma-separated (default: test_loop,redis,pytorch)
  --modes LIST        Comma-separated (default: full,lazy,lazy-prefetch,lazy-hot)
  --iterations N      Runs per config (default: 5)
  --output-dir DIR    Results directory (default: eval/results)
```

Examples:
```bash
# Redis only, 3 iterations, lazy modes only
sudo bash eval/bench.sh --workloads redis --modes lazy,lazy-prefetch --iterations 3

# All workloads, full and lazy only
sudo bash eval/bench.sh --modes full,lazy
```

### Generate report

```bash
make report
cat eval/results/report.md
```

The report includes:
- TTFR comparison table (workload x mode)
- Throughput table with % of baseline
- Page fault analysis
- Hypothesis validation (H1: TTFR < 1s, H2: throughput > 70%)
- Research question analysis

## 6. Understanding the Output

### Handler log

During lazy restore, the handler prints:
```
Config: prefetch=off seq=16 stride=8 hot_pages=(none)
Listening on /tmp/.../lazy-pages.socket
Connected to page server at 127.0.0.1:9999
CRIU restore connected
Received PID: 12345
Received userfaultfd: 3
Handling page faults...
Fault 1: 0x7f47541be000 (prefetched 0)
Fault 2: 0x7ffeb2b79000 (prefetched 0)
...
Prefetch stats: 266 faults, 0 prefetched, 0 hits (0% hit rate)
Total pages served: 266
```

### CSV schema

Benchmark results in `eval/results/results.csv`:
```
workload,mode,iteration,ttfr_ms,throughput_ops_sec,page_faults,
pages_prefetched,prefetch_hits,hit_rate_pct,total_pages_served,
eager_pages,checkpoint_time_ms
```

## 7. Adding a New Workload

Create `eval/workloads/myworkload.sh` implementing these functions:

```bash
workload_name()          # echo "myworkload"
workload_setup()         # Check deps, return 0 if ready
workload_start DIR       # Start process, set WORKLOAD_PID
workload_warmup()        # Wait for steady state
workload_profile DIR     # Run hot_pages.py, set HOT_PAGES_FILE
workload_ttfr_probe DIR  # Wait for response, set TTFR_MS from RESTORE_T_START
workload_throughput()    # Measure ops/sec, set THROUGHPUT
workload_cleanup()       # Kill process, remove temp files
```

Then run:
```bash
sudo bash eval/bench.sh --workloads myworkload --iterations 3
```
