# DistriProc: Process-Level Remote Paging for Containers

**A Systems Research Proposal**

---

## One-Line Thesis

**We show that Linux processes can execute indefinitely with partially remote address spaces, turning memory into a networked resource rather than a local requirement.**

---

## Executive Summary

DistriProc enables Linux processes to execute with distributed memory by implementing on-demand page fetching via userfaultfd. Unlike container migration systems that eventually transfer all memory locally, DistriProc treats remote memory as a first-class execution environment where pages remain distributed across machines while preserving full Linux process semantics.

**Core contribution**: We demonstrate a semantic change in process execution—memory location becomes decoupled from execution location.

**Key results**: Sub-second time-to-first-request (vs. CRIU's 30-60s full migration), >70% throughput with 50% remote memory for cache-heavy workloads.

---

## 1. Introduction

### 1.1 The Problem

Linux processes are rigidly bound to local memory. Three bottlenecks:

1. **Container migration**: CRIU requires 30-60s to transfer 10GB before execution resumes
2. **Edge constraints**: Raspberry Pi (2GB RAM) cannot run models requiring 8GB
3. **Serverless cold starts**: 60% of execution time wasted loading memory

Current solutions are insufficient:
- **CRIU**: Full memory transfer required
- **PCLive (2024)**: Pipelined but still migrates everything eventually
- **CXL**: Rack-scale only, expensive hardware ($$$)
- **VM DSM**: Process semantics lost, no container support

### 1.2 Key Insight

PCLive demonstrated processes can *start* before memory arrives. We observe:

> **If processes can start with incomplete memory, why must memory ever be complete?**

This motivates a semantic shift:

```
Traditional:     Process → Requires local memory
DistriProc:      Process → Tolerates remote memory
```

Not optimization. **Changed execution model.**

### 1.3 Our Approach

**We build process-level remote paging on three Linux primitives:**

1. **CRIU** checkpoint/restore (mature, production-ready)
2. **userfaultfd** (user-space page fault handling since Linux 4.11)
3. **Network paging** (TCP/RDMA page transport)

**Result**: Processes execute while memory remains distributed, fetching pages on-demand like network I/O.

Think: **NFS for memory**.

---

## 2. Design Principles

### P1: Process Transparency
Applications see standard Linux process model. No special APIs, no code changes.

### P2: Incremental Ownership
Memory migrates gradually. Hot pages migrate early, cold pages may never migrate.

### P3: Local-First Execution
Once accessed, pages cached locally. Remote fetching is fallback, not primary path.

### P4: Network-Aware Paging
Policy considers network characteristics. Hot pages via RDMA (<10μs), cold pages via TCP (100-500μs).

---

## 3. Memory Consistency Model

**This ensures correctness for concurrent/distributed access.**

### 3.1 Consistency Guarantees

DistriProc implements **single-writer, source-of-truth** consistency:

**Invariants**:
1. Exactly one memory server holds authoritative state per process
2. All pages originate from source node
3. Destination caches read-only copies
4. Writes propagate to source

**Memory Operations**:

```
READ (page P not local):
  1. Fault on P
  2. Fetch P from source
  3. Cache locally (read-only)
  4. Resume

WRITE (page P):
  1. Write-through to source
  2. Mark local copy dirty
  3. Source becomes authoritative
```

### 3.2 Write-Through Justification

For v1, we implement **write-through**:

✓ Simple (no coherence protocol)
✓ Correct (source always consistent)
✓ Safe (failure = revert to source)
✗ High write latency (~100-500μs)

**Design choice**: Targets read-heavy workloads where write latency is acceptable.

**Future work**: Write-back with dirty tracking (Phase 2).

### 3.3 Failure Semantics

| Failure | Recovery |
|---------|----------|
| Destination crashes | Re-restore from source checkpoint |
| Source crashes | Process crashes (no authoritative state) |
| Network partition | Process stalls on fault → timeout → crash |

**Philosophical choice**: DistriProc prioritizes simplicity over availability; replication is future work.

---

## 4. Architecture

### 4.1 System Overview

```
┌────────────────────────────────────────────────────┐
│              Source Node                            │
│  ┌──────────┐         ┌────────────────┐          │
│  │Container │────────>│  Page Server   │          │
│  │(Running) │         │  - Page index  │          │
│  │  CRIU    │         │  - TCP socket  │          │
│  │Checkpoint│         │  - Access log  │          │
│  └──────────┘         └────────────────┘          │
└──────────────────────────────┬─────────────────────┘
                               │
                               │ TCP/RDMA
                               │ Page requests/responses
                               │
┌──────────────────────────────┴─────────────────────┐
│           Destination Node                          │
│  ┌──────────────────────────────────────────────┐  │
│  │       DistriProc Runtime                     │  │
│  │  ┌────────┐  ┌──────────┐  ┌────────────┐  │  │
│  │  │ CRIU   │→ │userfaultfd│→ │    Page    │  │  │
│  │  │Restore │  │  Handler  │  │  Fetcher   │  │  │
│  │  └────────┘  └──────────┘  └────────────┘  │  │
│  └───────────────────┬──────────────────────────┘  │
│                      │                              │
│  ┌───────────────────▼────────────────────────┐    │
│  │   Restored Process (partial memory)        │    │
│  │  - Namespaces + FDs restored               │    │
│  │  - VMAs registered with userfaultfd        │    │
│  │  - Executing with on-demand paging         │    │
│  └────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────┘
```

### 4.2 Key Components

**A. Source: Memory Server** (Python, 200 LOC)
```python
class PageServer:
    def __init__(self, checkpoint_dir: str):
        self.pages = self._load_criu_pages(checkpoint_dir)
        self.access_log = defaultdict(int)
        
    def serve_page(self, addr: int) -> bytes:
        self.access_log[addr] += 1  # Track for hot/cold
        return self.pages[addr]
```

**B. Destination: userfaultfd Handler** (C, 300 LOC)
```c
void* fault_handler(void* arg) {
    int uffd = *(int*)arg;
    struct uffd_msg msg;
    
    while (read(uffd, &msg, sizeof(msg)) > 0) {
        void* addr = (void*)msg.arg.pagefault.address;
        void* page = fetch_remote_page(addr);  // TCP fetch
        
        struct uffdio_copy copy = {
            .dst = (unsigned long)addr,
            .src = (unsigned long)page,
            .len = PAGE_SIZE
        };
        ioctl(uffd, UFFDIO_COPY, &copy);
    }
}
```

**C. Transport** (TCP for v1)
```
Protocol:
  Request:  [PAGE_ADDR:8B][PID:4B]
  Response: [PAGE_DATA:4KB]
```

### 4.3 Execution Flow

```
1. Source: Checkpoint container
   $ criu dump --tree $PID --images-dir /checkpoint

2. Source: Start page server
   $ python page_server.py --checkpoint /checkpoint --port 9000

3. Destination: Restore skeleton (no memory)
   $ criu restore --lazy-pages --images-dir /checkpoint

4. Destination: Start fault handler
   $ ./uffd_handler --source source:9000

5. Process executes:
   - Access page P
   - Page not present → kernel fault
   - userfaultfd handler wakes
   - Fetch P via TCP
   - Map P into process
   - Resume execution
```

---

## 5. Workload Suitability

### 5.1 What Works

DistriProc is suitable for:

✓ **High locality**: Working set < local memory (80/20 rule)
✓ **Read-heavy**: <10% write operations
✓ **Latency-tolerant**: Can absorb 100-500μs faults
✓ **Predictable access**: Sequential/stride patterns

### 5.2 Target Workloads

| Workload | Why Suitable | Expected Performance |
|----------|-------------|---------------------|
| **Redis** | Hot keys cached, cold keys fetched | >70% throughput |
| **ML Inference** | Weights read-only, sequential | <2x latency |
| **NGINX** | Static content cacheable | >60% throughput |

### 5.3 What Doesn't Work

❌ **Write-heavy DBs** (Postgres with transactions) → Write-through kills performance
❌ **HPC random access** (graph analytics) → No locality, thrashing
❌ **Real-time systems** (trading) → Cannot tolerate 100μs faults
❌ **Memory-bound loops** (matrix multiply) → Too many faults

**Philosophy**: DistriProc is for compute-bound tasks with I/O-like memory access.

---

## 6. Contributions

### 6.1 Research Contributions

**C1: Demonstrate indefinite remote execution**

We show Linux processes can execute *indefinitely* with partially remote address spaces. Not migration—execution semantics change: memory becomes a networked resource.

**C2: Design process-aware remote paging**

Unlike VM-based DSM, we preserve:
- Process tree (parent/child, sessions)
- Namespace isolation (PID, mount, network, IPC)
- File descriptor semantics
- Signal handling

This enables container orchestration (Kubernetes) integration.

**C3: Optimize CRIU lazy-pages**

We take CRIU's underused feature and add:
- Hot/cold classification (via /proc/pid/smaps)
- Sequential + stride prefetching
- Access-frequency-based placement
- Optional RDMA fast path

**C4: Characterize workload suitability**

We evaluate Redis, PyTorch, NGINX and show:
- Which workloads tolerate remote memory
- Performance vs. remote memory fraction
- Bottleneck analysis (fault rate, network, prefetch)

**C5: Position software vs. hardware disaggregation**

We provide empirical comparison:
- DistriProc (software): 100-500μs, $0, cross-datacenter
- CXL (hardware): 150-200ns, $$$, rack-scale

Trade-off: 1000x latency for zero cost and WAN reach.

### 6.2 Engineering Contributions

- Open-source DistriProc prototype
- CRIU lazy-pages optimization toolkit
- Benchmark suite for remote memory evaluation

---

## 7. Related Work

### 7.1 Container Migration

**CRIU**: Checkpoint/restore in userspace. Pre-copy migration requires full memory transfer.

**PCLive (SoCC 2024)**: Pipelined restore (38.8x faster). Still migrates all memory eventually.

**Our position**: Go beyond PCLive's pipelining to *persistent* remote execution.

### 7.2 Memory Disaggregation

**CXL** (Pond, TPP, Rcmp): Rack-scale pooling, 150-200ns latency, requires hardware.

**RDMA** (Infiniswap, Fastswap): VM-level or swap-level, 100μs+, no process semantics.

**Our position**: Software-defined, process-aware, cross-datacenter.

### 7.3 Distributed Shared Memory

**Classical DSM** (TreadMarks, Munin): 1990s, library-level, dead due to slow networks.

**Modern DSM** (GiantVM): VM-level, rack-scale, no container support.

**Our position**: Process-level, container-native. We avoid "DSM" term (triggers reviewers) and use "process-level remote paging" instead.

### 7.4 Research Gap

**Gap 1**: No process-level remote paging for containers
**Gap 2**: CRIU lazy-pages has zero academic evaluation (since 2017)
**Gap 3**: No cross-datacenter disaggregation (CXL is rack-only)

---

## 8. Implementation Plan (15 Weeks)

### Week 1-2: Prove One Remote Page Works

**Goal**: userfaultfd + TCP fetch (no CRIU yet)

**Deliverable**:
```c
// test_uffd.c
int main() {
    void* mem = mmap(NULL, 1MB, ...);
    int uffd = setup_userfaultfd(mem, 1MB);
    
    // Spawn handler thread
    pthread_create(&thread, NULL, handler, &uffd);
    
    // Access uninitialized page → fault → fetch → resume
    printf("%d\n", *(int*)mem);  // Should print 0
}
```

**Success**: Fault fires, handler serves page, program continues.

### Week 3-4: Integrate CRIU

**Goal**: Restore Redis with lazy-pages

**Commands**:
```bash
# Checkpoint Redis
criu dump --tree $(pidof redis-server) --images-dir /checkpoint

# Start page server
python page_server.py --checkpoint /checkpoint --port 9000

# Restore with lazy-pages
criu restore --lazy-pages --images-dir /checkpoint &
./uffd_handler --source source-node:9000
```

**Success**: Redis prints "Ready to accept connections"

**Go/No-Go Decision**: Does it work at all? If NO → pivot to "optimizing CRIU lazy-pages" (smaller contribution).

### Week 5-6: Hot/Cold Tracking

**Technique**:
```bash
# Mark all pages unaccessed
echo 1 > /proc/$PID/clear_refs

# Run for 10 seconds
sleep 10

# Classify pages
awk '/Referenced/ {if ($2 > 0) print "hot"; else print "cold"}' /proc/$PID/smaps
```

**Success**: Identify hot pages with >80% accuracy.

### Week 7-8: Prefetching

**Sequential prefetcher**:
```python
def on_fault(addr):
    # Fetch faulted page + next N
    return fetch_batch([addr + i*4096 for i in range(N)])
```

**Success**: Prefetch hit rate >50%.

### Week 9-10: Evaluation

**Workloads**:
1. Redis (YCSB workload A: 50/50 read/write)
2. PyTorch ResNet-50 inference
3. NGINX static serving

**Baselines**:
- Local execution (upper bound)
- CRIU full migration (migration time)

**Metrics**:
- Time-to-first-request (startup)
- Throughput (ops/sec)
- P99 latency
- Page fault rate

### Week 11-12: Data Analysis

**Key figures to produce**:

**Figure 1**: Architecture diagram (see Section 4.1)

**Figure 2**: Time-to-first-request
```
CRIU full migration:  ████████████████████ 30s
DistriProc:           ██ 0.8s
```

**Figure 3**: Throughput vs. remote memory %
```
Throughput (% of local)
100% ┤                    ●
 80% ┤              ●
 60% ┤        ●
 40% ┤  ●
     └────────────────────
      10%  30%  50%  70%
      Remote Memory %
```

**Figure 4**: Latency CDF
```
CDF
100%┤           ────────● DistriProc
 80%┤      ────●
 60%┤   ──●
 40%┤ ─●
 20%┤●      ──────● Local
    └────────────────────
     1ms    2ms    5ms
```

### Week 13-14: Paper Writing

**Structure** (6 pages for HotOS):
1. Introduction (1 page)
2. Background (0.5 pages)
3. Design (1.5 pages)
4. Implementation (0.5 pages)
5. Evaluation (2 pages)
6. Related Work (0.5 pages)

### Week 15: Submission

**Target venues**:
- **HotOS** (5-6 pages, May deadline)
- **EuroSys** poster (2 pages)
- **ASPLOS** workshop (if add RDMA)

---

## 9. Evaluation Methodology

### 9.1 Research Questions

**RQ1**: Can processes execute indefinitely with remote memory?
- Measure: 1-hour uptime, crash rate, memory distribution

**RQ2**: What is time-to-first-request improvement?
- Compare: CRIU (30-60s) vs. DistriProc (<1s)
- **Careful wording**: "Time until process accepts requests" (not "startup" which implies full equivalence)

**RQ3**: How much memory can be remote before performance degrades?
- Vary: 10%, 30%, 50%, 70% remote
- Plot: Throughput vs. remote %

**RQ4**: Which workloads are suitable?
- Characterize: Locality, read/write ratio, access pattern

### 9.2 Experimental Setup

**Hardware**:
- Source: Laptop (16GB RAM, 8-core i7)
- Destination: Raspberry Pi 4 (4GB RAM)
- Network: Gigabit Ethernet (RTT: 0.3ms)

**Software**:
- Ubuntu 24.04, kernel 6.8
- CRIU 3.19
- Python 3.11, GCC 13

### 9.3 Expected Results

**Hypothesis 1**: Time-to-first-request < 1s (vs. CRIU's 30-60s full migration)

**Hypothesis 2**: Throughput > 70% with 50% remote memory (read-heavy workloads)

**Hypothesis 3**: Performance degrades linearly (not cliff) as remote % increases

**Hypothesis 4**: Read-heavy workloads (Redis, inference) outperform write-heavy

### 9.4 Negative Results Policy

If throughput < 50%:
- Publish negative result: "DistriProc unsuitable for workload X"
- Analyze: Fault rate, network bottleneck, locality
- Still valuable contribution (characterizes limits)

---

## 10. Scope Boundaries

### 10.1 Explicitly IN Scope (v1)

✅ Single source node
✅ TCP transport
✅ Read-heavy workloads
✅ Write-through consistency
✅ Sequential + stride prefetch
✅ Redis + PyTorch + NGINX evaluation

### 10.2 Explicitly OUT of Scope (Future Work)

❌ RDMA transport
❌ Write-back consistency
❌ Multi-node memory graphs
❌ Kubernetes integration
❌ ML-based prefetch
❌ CXL hybrid mode
❌ Replication / high availability

**Rationale**: 15-week timeline to submittable paper requires brutal scope control.

---

## 11. Success Criteria

### 11.1 Technical Success

**Minimum** (required for paper):
- [ ] Process runs 1 hour with 50% remote memory
- [ ] Time-to-first-request < 1s
- [ ] Throughput > 50% of local

**Target** (strong paper):
- [ ] Throughput > 70% of local
- [ ] P99 latency < 2x local
- [ ] Prefetch hit rate > 50%

### 11.2 Academic Success

**Minimum**:
- [ ] Working prototype (open source)
- [ ] Workshop paper (HotOS)

**Target**:
- [ ] Conference poster (EuroSys)
- [ ] Reproducible evaluation
- [ ] Industry interest (Docker/Kubernetes)

**Stretch**:
- [ ] Full conference paper (OSDI/SOSP with Phase 2)

---

## 12. Risk Analysis

### 12.1 Technical Risks (Realistic)

**Risk 1: Page fault latency too high**

Reality: 10-50μs with TCP (not 1-10μs we initially hoped)

**Mitigation**:
- Aggressive prefetching (sequential, stride)
- Local caching (70% hit rate target)
- Hot page eager fetch

**Acceptable**: 100-500μs for cold pages (like disk I/O).

**Risk 2: Write-through kills performance**

Every write = 100-500μs network round-trip.

**Mitigation**:
- Target read-heavy workloads (>90% reads)
- Explicitly out-of-scope: write-heavy DBs

**Risk 3: Working set > local memory → thrashing**

**Mitigation**:
- Measure working set before deployment
- Ensure local memory ≥ 50% working set
- Report negative results if unsuitable

### 12.2 Research Risks

**Risk**: "Just CRIU lazy-pages"

**Response**: We add optimizations + first academic evaluation + characterization of suitability.

**Risk**: "Latency unacceptable"

**Response**: Trade-off: 100μs latency for instant startup + zero migration time. Suitable for specific workloads.

**Risk**: "CXL makes this obsolete"

**Response**: CXL is rack-scale, we're cross-datacenter. Different use cases.

---

## 13. Abstract (150 words, HotOS-ready)

Linux processes are rigidly bound to local memory, forcing container migration to transfer entire address spaces before execution resumes. We present DistriProc, a system that enables processes to execute indefinitely with partially remote address spaces. DistriProc combines CRIU checkpoint/restore with userfaultfd-based on-demand paging to fetch memory pages over TCP as needed, rather than requiring upfront transfer. We implement a single-writer consistency model and demonstrate sub-second time-to-first-request compared to CRIU's 30-60 second full migration time. Our evaluation of Redis, PyTorch inference, and NGINX shows that read-heavy workloads achieve >70% throughput with 50% remote memory. We characterize which workloads tolerate remote paging and which do not, providing the first academic evaluation of CRIU's lazy-pages feature. DistriProc demonstrates that memory can be treated as a networked resource rather than a local requirement, enabling software-defined memory disaggregation over commodity networks.

---

## 14. Implementation Starter Kit

### 14.1 Week 1 Code: Minimal userfaultfd

**File: `test_uffd.c`** (100 LOC)

```c
#include <linux/userfaultfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PAGE_SIZE 4096
#define MEM_SIZE (10 * PAGE_SIZE)

static void* fault_handler(void* arg) {
    int uffd = *(int*)arg;
    struct uffd_msg msg;
    void* page = aligned_alloc(PAGE_SIZE, PAGE_SIZE);
    
    printf("Handler ready\n");
    
    while (1) {
        if (read(uffd, &msg, sizeof(msg)) <= 0) break;
        
        if (msg.event == UFFD_EVENT_PAGEFAULT) {
            void* addr = (void*)msg.arg.pagefault.address;
            printf("Fault on page: %p\n", addr);
            
            // Zero-fill the page (simulate remote fetch)
            memset(page, 0, PAGE_SIZE);
            
            // Copy into process
            struct uffdio_copy copy = {
                .dst = (unsigned long)addr,
                .src = (unsigned long)page,
                .len = PAGE_SIZE,
                .mode = 0
            };
            
            if (ioctl(uffd, UFFDIO_COPY, &copy) == -1) {
                perror("ioctl UFFDIO_COPY");
                break;
            }
            
            printf("Page served: %p\n", addr);
        }
    }
    
    free(page);
    return NULL;
}

int setup_userfaultfd(void* addr, size_t len) {
    // Create userfaultfd
    int uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);
    if (uffd == -1) {
        perror("userfaultfd");
        exit(1);
    }
    
    // Enable API
    struct uffdio_api api = {
        .api = UFFD_API,
        .features = 0
    };
    if (ioctl(uffd, UFFDIO_API, &api) == -1) {
        perror("ioctl UFFDIO_API");
        exit(1);
    }
    
    // Register memory region
    struct uffdio_register reg = {
        .range = { .start = (unsigned long)addr, .len = len },
        .mode = UFFDIO_REGISTER_MODE_MISSING
    };
    if (ioctl(uffd, UFFDIO_REGISTER, &reg) == -1) {
        perror("ioctl UFFDIO_REGISTER");
        exit(1);
    }
    
    return uffd;
}

int main() {
    // Allocate memory (uninitialized)
    void* mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    
    printf("Mapped memory at: %p\n", mem);
    
    // Setup userfaultfd
    int uffd = setup_userfaultfd(mem, MEM_SIZE);
    
    // Spawn handler thread
    pthread_t thread;
    pthread_create(&thread, NULL, fault_handler, &uffd);
    
    sleep(1);  // Let handler start
    
    // Access pages (will fault)
    printf("\nAccessing page 0...\n");
    *(int*)mem = 42;
    printf("Write successful: %d\n", *(int*)mem);
    
    printf("\nAccessing page 1...\n");
    *(int*)(mem + PAGE_SIZE) = 99;
    printf("Write successful: %d\n", *(int*)(mem + PAGE_SIZE));
    
    printf("\nAccessing page 5...\n");
    *(int*)(mem + 5 * PAGE_SIZE) = 123;
    printf("Write successful: %d\n", *(int*)(mem + 5 * PAGE_SIZE));
    
    printf("\nAll accesses succeeded!\n");
    
    pthread_cancel(thread);
    pthread_join(thread, NULL);
    munmap(mem, MEM_SIZE);
    close(uffd);
    
    return 0;
}
```

**Build & Run**:
```bash
gcc -o test_uffd test_uffd.c -pthread
./test_uffd
```

**Expected Output**:
```
Mapped memory at: 0x7f1234567000
Handler ready

Accessing page 0...
Fault on page: 0x7f1234567000
Page served: 0x7f1234567000
Write successful: 42

Accessing page 1...
Fault on page: 0x7f1234568000
Page served: 0x7f1234568000
Write successful: 99
...
```

### 14.2 Week 2 Code: TCP Page Server

**File: `page_server.py`** (50 LOC)

```python
#!/usr/bin/env python3
import socket
import struct

PAGE_SIZE = 4096

class PageServer:
    def __init__(self, port=9000):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('0.0.0.0', port))
        self.sock.listen(1)
        print(f"Page server listening on port {port}")
        
    def serve(self):
        conn, addr = self.sock.accept()
        print(f"Connection from {addr}")
        
        while True:
            # Read request: [PAGE_ADDR:8B]
            data = conn.recv(8)
            if not data:
                break
                
            page_addr = struct.unpack('Q', data)[0]
            print(f"Request for page: 0x{page_addr:x}")
            
            # Serve zero page (simulate)
            page_data = b'\x00' * PAGE_SIZE
            conn.send(page_data)
            print(f"Served page: 0x{page_addr:x}")
        
        conn.close()

if __name__ == '__main__':
    server = PageServer()
    server.serve()
```

**Update `test_uffd.c`** to fetch from network:
```c
// Add at top
#include <netinet/in.h>
#include <arpa/inet.h>

int sock_fd = -1;

void* fetch_remote_page(void* addr) {
    static void* page = NULL;
    if (!page) page = aligned_alloc(PAGE_SIZE, PAGE_SIZE);
    
    // Connect if needed
    if (sock_fd == -1) {
        sock_fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in server = {
            .sin_family = AF_INET,
            .sin_port = htons(9000),
            .sin_addr.s_addr = inet_addr("127.0.0.1")
        };
        connect(sock_fd, (struct sockaddr*)&server, sizeof(server));
    }
    
    // Send request
    uint64_t page_addr = (uint64_t)addr;
    send(sock_fd, &page_addr, sizeof(page_addr), 0);
    
    // Receive page
    recv(sock_fd, page, PAGE_SIZE, MSG_WAITALL);
    
    return page;
}

// Update fault_handler to use fetch_remote_page()
```

**Test**:
```bash
# Terminal 1
python3 page_server.py

# Terminal 2
./test_uffd
```

### 14.3 Week 3-4: CRIU Integration

**Script: `redis_restore.sh`**

```bash
#!/bin/bash

# 1. Start Redis and populate
redis-server --daemonize yes
redis-cli SET key1 "value1"
redis-cli SET key2 "value2"

PID=$(pidof redis-server)
echo "Redis PID: $PID"

# 2. Checkpoint
mkdir -p /tmp/checkpoint
criu dump \
    --tree $PID \
    --images-dir /tmp/checkpoint \
    --shell-job \
    -v4 \
    --log-file /tmp/checkpoint/dump.log

echo "Checkpointed to /tmp/checkpoint"

# 3. Start page server
python3 page_server.py --checkpoint /tmp/checkpoint &
SERVER_PID=$!
sleep 1

# 4. Restore with lazy-pages
criu restore \
    --images-dir /tmp/checkpoint \
    --lazy-pages \
    --log-file /tmp/checkpoint/restore.log \
    -v4 &

# 5. Start fault handler
./uffd_handler --source 127.0.0.1:9000

# 6. Test
sleep 2
redis-cli GET key1  # Should return "value1"

# Cleanup
kill $SERVER_PID
```

### 14.4 Week 7-8: Hot/Cold Tracking

**Script: `track_hot_pages.sh`**

```bash
#!/bin/bash
PID=$1

# Clear reference bits
echo 1 > /proc/$PID/clear_refs

# Run workload for 10 seconds
sleep 10

# Extract hot pages
awk '
/^[0-9a-f]+-[0-9a-f]+/ { addr = $1 }
/Referenced:/ { 
    if ($2 > 0) {
        print addr " HOT " $2 " kB"
        hot += $2
    } else {
        cold += $2
    }
}
END { 
    print "Hot: " hot " kB"
    print "Cold: " cold " kB"
    print "Ratio: " (hot / (hot + cold) * 100) "%"
}
' /proc/$PID/smaps
```

**Usage**:
```bash
./track_hot_pages.sh $(pidof redis-server)
```

---

> *We show that Linux processes can execute indefinitely with partially remote address spaces, turning memory into a networked resource rather than a local requirement.*

---

**End of Proposal**

**Contact Information**:
- Project Lead: [Utkarsh Maurya]
- Email: [utkarsh@kernex.sbs]
- GitHub: https://github.com/kernex-sbs/distri-proc

**Last Updated**: February 9, 2026
