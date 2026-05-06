# DistriProc How-To Guide

## 1. Building

```bash
make all
```

Produces binaries in `src/`:
- `test_loop` — synthetic benchmark workload (1MB heap, counter loop)
- `lazy_handler` — CRIU lazy-pages daemon and adaptive policy runtime
- `test_uffd`, `test_uffd_tcp` — userfaultfd proof-of-concept tools

## 2. Running Tests

```bash
make test          # non-root tests
sudo bash tests/run_tests.sh           # all tests including CRIU paths
sudo bash tests/test_adaptive_prefetch.sh   # adaptive controller integration test
```

## 3. Lazy Restore Walkthrough

Full end-to-end pipeline: checkpoint a process, serve its pages over TCP, restore with
on-demand or adaptive paging.

### Step 1: Start a workload

```bash
setsid src/test_loop --output /tmp/counter &
LOOP_PID=$!
sleep 3
cat /tmp/counter   # should show 2 or 3
```

### Step 2: Checkpoint

```bash
DUMP_DIR=/tmp/distriproc-demo
mkdir -p $DUMP_DIR
sudo criu dump -t $LOOP_PID -D $DUMP_DIR -j -v4 --log-file dump.log
```

### Step 3: Start page server

```bash
python3 src/criu_page_server.py --images-dir $DUMP_DIR --port 9999 &
```

### Step 4: Start lazy handler (choose a mode)

**Demand-only (lowest overhead):**
```bash
sudo src/lazy_handler --images-dir $DUMP_DIR --address 127.0.0.1 --port 9999 \
    --no-prefetch &
```

**Fixed prefetch:**
```bash
sudo src/lazy_handler --images-dir $DUMP_DIR --address 127.0.0.1 --port 9999 \
    --prefetch-seq 16 --prefetch-stride 8 &
```

**Adaptive (recommended for unknown workloads):**
```bash
sudo src/lazy_handler --images-dir $DUMP_DIR --address 127.0.0.1 --port 9999 \
    --prefetch-seq 16 --prefetch-stride 8 --adaptive-prefetch &
```

### Step 5: Restore

```bash
cd $DUMP_DIR
sudo criu restore --lazy-pages -D $DUMP_DIR -j -d --pidfile restore.pid
cd -
sleep 2
cat /tmp/counter   # counter advancing again
```

### Step 6: Cleanup

```bash
kill $(cat $DUMP_DIR/restore.pid) 2>/dev/null
sudo rm -rf $DUMP_DIR /tmp/counter
```

## 4. Lazy Handler Reference

```
src/lazy_handler [OPTIONS]
  --images-dir DIR       CRIU images directory (required)
  --address ADDR         Page server address (default: 127.0.0.1)
  --port PORT            Page server port (default: 9999)
  --no-prefetch          Demand-only mode — fetch exactly the faulted page
  --prefetch-seq N       Sequential pages to prefetch per fault (default: 16)
  --prefetch-stride N    Stride-predicted pages to prefetch (default: 8)
  --adaptive-prefetch    Enable adaptive controller (use with --prefetch-seq/stride)
  --hot-pages FILE       Binary file of hot page addresses for eager fetch at restore time
```

### Mode summary

| Flag combination | Mode | Best for |
|-----------------|------|----------|
| `--no-prefetch` | `lazy` | Memory-heavy workloads; unknown workloads |
| `--prefetch-seq 16 --prefetch-stride 8` | `lazy-prefetch` | Memory-light, sequential access |
| `--prefetch-seq 16 --prefetch-stride 8 --adaptive-prefetch` | `lazy-adaptive` | Default recommendation for mixed workloads |

### Adaptive controller behavior

With `--adaptive-prefetch`, the controller runs every 128 faults and checks:
- **Duplicate rate**: fraction of prefetch requests for already-served pages
- **Queue depth**: outstanding prefetch requests in the async queue

If either signal exceeds threshold, prefetch is disabled. It re-enables via a small
probe window once the queue drains. Handler logs show per-window decisions:

```
Policy: faults=128 hits=0 prefetched=80 drops=0 dup=294 dup_rate=78% qdepth=3288 => prefetch=on
Policy: faults=128 hits=0 prefetched=0 drops=0 dup=191 dup_rate=100% qdepth=3552 => prefetch=on
Policy: faults=128 hits=0 prefetched=0 drops=0 dup=46 dup_rate=100% qdepth=3796 => prefetch=off
```

## 5. Benchmarks

### Final paper benchmark (all workloads × 4 modes × 5 iterations)

```bash
make bench-paper
```

This runs `test_loop`, `redis`, and `pytorch` across `full`, `lazy`, `lazy-prefetch`,
and `lazy-adaptive` modes. Results written to `eval/results/results.csv`.

### Partial runs with accumulation

Run one workload at a time and accumulate results:

```bash
# Start fresh
sudo bash eval/bench.sh --workloads test_loop --modes lazy,lazy-prefetch,lazy-adaptive \
    --iterations 5 --output-dir eval/results

# Append redis without overwriting test_loop results
sudo bash eval/bench.sh --workloads redis --modes lazy,lazy-prefetch,lazy-adaptive \
    --iterations 5 --output-dir eval/results --append

# Append pytorch
sudo bash eval/bench.sh --workloads pytorch --modes full,lazy,lazy-prefetch,lazy-adaptive \
    --iterations 5 --output-dir eval/results --append
```

### Quick smoke test

```bash
make bench-quick    # test_loop only, 2 iterations
```

### All bench.sh options

```bash
sudo bash eval/bench.sh [OPTIONS]
  --workloads LIST    Comma-separated (default: test_loop,redis,pytorch)
  --modes LIST        Comma-separated (default: full,lazy,lazy-prefetch,lazy-adaptive,lazy-hot)
  --iterations N      Runs per config (default: 5)
  --output-dir DIR    Results directory (default: eval/results)
  --append            Append to existing results.csv (skip overwrite)
```

### Prerequisites

```bash
sudo pacman -S redis            # or: apt install redis-server
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
pip install matplotlib          # for make figures
pip install criu                # pycriu, needed by bench.sh
```

## 6. Report and Figures

```bash
make report     # CSV → eval/results/report.md
make figures    # CSV + logs → eval/results/figures/fig1–fig5 (PDF + PNG)
make docs       # both report and figures
```

The report includes TTFR and throughput tables, page fault analysis, hypothesis
validation, and research question analysis. The figures script produces publication-
ready PDF and PNG files from the committed dataset.

## 7. Understanding Handler Logs

Each iteration saves logs under `eval/results/logs/`:

```
{workload}_{mode}_iter{N}_handler.log
{workload}_{mode}_iter{N}_dump.log
{workload}_{mode}_iter{N}_restore.log
{workload}_{mode}_iter{N}_page_server.log
```

Inspect adaptive controller decisions across runs:

```bash
rg "Policy:|Prefetch stats" eval/results/logs/*_handler.log
```

Final stats line per run:
```
Prefetch stats: 15743 faults, 0 prefetched, 0 hits (0% hit rate)
Total pages served: 15743
```

Note: hit rate is always 0% for async prefetch — this is expected. If prefetch installs
a page before the fault fires, there is no fault to count as a hit. The adaptive
controller uses duplicate pressure and queue depth instead (see paper/CLAIMS.md).

## 8. Adding a New Workload

Create `eval/workloads/myworkload.sh` implementing:

```bash
workload_name()          # echo "myworkload"
workload_setup()         # check deps, return 0 if ready
workload_start DIR       # start process, set WORKLOAD_PID
workload_warmup()        # wait for steady state
workload_profile DIR     # run hot_pages.py, set HOT_PAGES_FILE
workload_ttfr_probe DIR  # probe until response, set TTFR_MS from RESTORE_T_START
workload_throughput()    # measure ops/sec, set THROUGHPUT
workload_cleanup()       # kill process, remove temp files
```

Then:
```bash
sudo bash eval/bench.sh --workloads myworkload --iterations 3
```
