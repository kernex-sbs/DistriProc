# DistriProc: Process-Level Remote Paging for Containers

**A Systems Research Proposal**

---

## Status Note

This document now serves two purposes:

1. It preserves the original broader vision for DistriProc.
2. It records the narrower paper direction that matches the current repository.

The current codebase already supports post-restore remote paging over TCP with `CRIU` and `userfaultfd`, plus fixed policy variants such as synchronous prefetch and eager hot-page fetch. It does **not** yet implement writable remote-memory coherence, a complete adaptive controller, or the full evaluation promised by the earliest proposal text.

For the next paper iteration, the active target is:

**an adaptive post-restore remote-memory runtime for restored Linux processes**

The intended contribution is a userspace policy/runtime story on top of CRIU lazy restore, not a general distributed shared-memory system.

---

## One-Line Thesis

**We show that restored Linux processes can enter a managed remote-memory phase, where page-fetch policy after restore is chosen adaptively rather than fixed in advance.**

---

## Executive Summary

DistriProc currently demonstrates that Linux processes can be restored quickly and execute while missing pages are fetched on demand over TCP via `userfaultfd`. The prototype already includes a custom lazy-pages handler, fixed prefetch modes, hot-page eager fetch, and initial evaluation on Redis, PyTorch, and a small synthetic loop workload.

The next paper should focus on a narrower and stronger claim:

**Core contribution**: an adaptive userspace runtime for post-restore remote memory, built on top of CRIU lazy restore.

The central hypothesis is that restored processes pass through distinct startup and steady-state phases, and that a fixed page-fetch policy is therefore the wrong abstraction. Instead, the runtime should adapt among demand paging, asynchronous prefetch, and eager hot-page installation based on observed fault patterns and network cost.

The current baseline result motivating this direction is simple: plain demand paging works reasonably well, while synchronous prefetch can reduce fault counts yet still degrade TTFR and throughput badly. The adaptive runtime is intended to recover the useful cases for prefetching without paying those worst-case stalls.

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

CRIU lazy restore already shows that processes can *start* before all memory arrives. The research gap is no longer whether post-restore paging is possible, but how the runtime should behave after restore.

We observe:

> **A restored process does not need one fixed paging policy; it needs the right policy for its current phase.**

This motivates a runtime shift:

```
Traditional lazy restore:     One fixed fault-handling policy
DistriProc target:            Adaptive post-restore policy runtime
```

Not just mechanism. **Policy becomes the contribution.**

### 1.3 Our Approach

**We build an adaptive post-restore runtime on three Linux primitives:**

1. **CRIU** checkpoint/restore and lazy restore
2. **userfaultfd** for user-space page-fault handling
3. **Network page serving** over TCP in the current prototype

**Result**: a restored process begins in a remote-memory phase, and the runtime decides whether to demand-page, prefetch asynchronously, or eagerly install pages based on observed behavior.

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

## 3. Scope Boundary for the Current Paper

The current paper target is intentionally narrower than the original vision.

### 3.1 In Scope

1. Read-dominant restored processes
2. Post-restore page fetch over TCP
3. Userspace runtime policy over CRIU lazy restore
4. Demand paging, asynchronous prefetch, hot-page eager fetch
5. Characterization of startup vs steady-state behavior

### 3.2 Explicitly Out of Scope for This Iteration

1. Writable remote-memory coherence
2. Write-through or write-back propagation protocols
3. Multi-node distributed shared memory semantics
4. RDMA/NIC-offloaded data paths
5. Replication and high-availability mechanisms

### 3.3 Failure Semantics

The current prototype assumes a simple post-restore execution model:

| Failure | Current stance |
|---------|----------------|
| Destination crashes | Re-run restore from checkpoint |
| Source/page server crashes | Restored process can no longer fault in missing pages |
| Network partition | Process stalls or fails once faults can no longer be served |

These are baseline prototype semantics, not the main paper contribution.

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
| **Small service workloads** | Early startup touches limited hot state | Low TTFR with adaptive paging |

### 5.3 What Doesn't Work

❌ **Write-heavy DBs** (Postgres with transactions) → current prototype does not target writable remote-memory coherence
❌ **HPC random access** (graph analytics) → No locality, thrashing
❌ **Real-time systems** (trading) → Cannot tolerate 100μs faults
❌ **Memory-bound loops** (matrix multiply) → Too many faults

**Philosophy**: DistriProc is for compute-bound tasks with I/O-like memory access.

---

## 6. Contributions

### 6.1 Research Contributions

**C1: Demonstrate post-restore remote execution**

We show Linux processes can restore successfully and continue executing while missing pages are served remotely on demand.

**C2: Design process-aware remote paging**

Unlike VM-based DSM, we preserve:
- Process tree (parent/child, sessions)
- Namespace isolation (PID, mount, network, IPC)
- File descriptor semantics
- Signal handling

This enables container orchestration (Kubernetes) integration.

**C3: Build a policy runtime over CRIU lazy-pages**

We take CRIU's underused feature and add:
- Hot/cold classification (via /proc/pid/smaps)
- Sequential + stride prefetching baselines
- A path toward asynchronous and adaptive policy control
- Instrumentation for fault behavior and startup cost

**C4: Characterize workload suitability**

We evaluate Redis, PyTorch, and small synthetic workloads and show:
- Which workloads tolerate remote memory
- Bottleneck analysis (fault rate, network, prefetch)
- Why fixed synchronous prefetch can be actively harmful

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

**Our position**: go beyond basic lazy restore by treating the post-restore period as a runtime-policy problem.

### 7.2 Memory Disaggregation

**CXL** (Pond, TPP, Rcmp): Rack-scale pooling, 150-200ns latency, requires hardware.

**RDMA** (Infiniswap, Fastswap): VM-level or swap-level, 100μs+, no process semantics.

**Our position**: software-defined, process-aware, userspace policy over restored processes rather than kernel swap replacement.

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

**Success**: asynchronous prefetch beats fixed synchronous prefetch on at least one workload without severely regressing the others.

### Week 9-10: Evaluation

**Workloads**:
1. Redis (read-dominant service workload)
2. PyTorch ResNet-50 inference
3. Synthetic loop / pointer-chasing restore workload

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

**RQ1**: Can restored processes execute stably while serving missing pages remotely?
- Measure: extended uptime, crash rate, memory distribution

**RQ2**: What is time-to-first-request improvement?
- Compare: CRIU (30-60s) vs. DistriProc (<1s)
- **Careful wording**: "Time until process accepts requests" (not "startup" which implies full equivalence)

**RQ3**: When does adaptive policy beat fixed policy?
- Vary: workload phase, prefetch aggressiveness, and network latency
- Plot: TTFR / throughput / tail latency vs. policy choice

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

**Hypothesis 1**: Time-to-first-request remains < 1s for selected read-dominant workloads under lazy restore.

**Hypothesis 2**: Adaptive asynchronous policy outperforms fixed synchronous prefetch on TTFR and throughput.

**Hypothesis 3**: Startup and steady-state phases favor different paging policies, so online adaptation outperforms any single fixed mode.

**Hypothesis 4**: Read-heavy workloads with structured access patterns benefit more than irregular or write-heavy workloads.

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
✅ Demand paging baseline
✅ Asynchronous/adaptive prefetch policy
✅ Redis + PyTorch + synthetic restore-time evaluation

### 10.2 Explicitly OUT of Scope (Future Work)

❌ Writable remote-memory coherence
❌ RDMA transport
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
- [ ] Process restores and runs stably under remote paging for an extended run
- [ ] Time-to-first-request < 1s for at least two read-dominant workloads
- [ ] Adaptive mode beats fixed synchronous prefetch on TTFR and throughput

**Target** (strong paper):
- [ ] Throughput near plain lazy baseline while reducing startup stalls
- [ ] P99 latency < 2x plain lazy mode
- [ ] Adaptive policy beats both fixed-off and fixed-on prefetch across multiple workloads

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
- Asynchronous prefetch instead of blocking per-fault prefetch
- Local caching after first access
- Hot page eager fetch for predictable startup state

**Acceptable**: 100-500μs for cold pages (like disk I/O).

**Risk 2: Fixed prefetch hurts more than it helps**

The current prototype already shows that synchronous prefetch can create long restore stalls.

**Mitigation**:
- Treat fixed prefetch only as a baseline
- Build policy feedback around usefulness and stall cost
- Disable prefetch aggressively when it becomes harmful

**Risk 3: Working set > local memory → thrashing**

**Mitigation**:
- Measure working set before deployment
- Ensure local memory ≥ 50% working set
- Report negative results if unsuitable

### 12.2 Research Risks

**Risk**: "Just CRIU lazy-pages"

**Response**: We add a userspace policy runtime, not just another restore wrapper.

**Risk**: "Latency unacceptable"

**Response**: Trade-off: 100μs latency for instant startup + zero migration time. Suitable for specific workloads.

**Risk**: "CXL makes this obsolete"

**Response**: CXL is rack-scale, we're cross-datacenter. Different use cases.

---

## 13. Abstract (working draft)

CRIU lazy restore can resume a Linux process before all of its memory has arrived, but today it offers little control over how missing pages should be fetched once execution resumes. We present DistriProc, a userspace runtime for post-restore remote memory built on CRIU and userfaultfd. DistriProc serves pages over TCP, observes restore-time page-fault behavior, and is designed to adapt among demand paging, asynchronous prefetch, and eager hot-page installation. Our current prototype and baseline evaluation show two motivating results: first, restored processes can achieve sub-second time-to-first-request on selected read-dominant workloads; second, fixed synchronous prefetch can reduce fault counts while still causing severe restore stalls and throughput collapse. These results motivate an adaptive policy runtime rather than a single fixed paging strategy. DistriProc targets the gap between mechanism and policy in process-level lazy restore and aims to characterize when adaptive post-restore paging is beneficial for real Linux workloads.

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

> *We show that restored Linux processes can benefit from an adaptive remote-memory phase, where paging policy after restore is chosen online rather than fixed in advance.*

---

**End of Proposal**

**Contact Information**:
- Project Lead: [Utkarsh Maurya]
- Email: [utkarsh@kernex.sbs]
- GitHub: https://github.com/kernex-sbs/distri-proc

**Last Updated**: February 9, 2026
