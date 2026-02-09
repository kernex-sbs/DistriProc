# DistriProc

## What This Is

DistriProc is a system that enables Linux processes to execute indefinitely with partially remote address spaces, effectively turning memory into a networked resource. It decouples memory location from execution location, allowing processes to start in sub-second time by fetching pages on-demand via userfaultfd and TCP, rather than waiting for full memory migration.

## Core Value

**Indefinite execution with remote memory.**
The ability to start a process immediately (<1s) and keep it running without ever requiring the full address space to be local.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] **Week 1 PoC**: Minimal `test_uffd.c` demonstrating userfaultfd trapping faults and serving pages.
- [ ] **TCP Transport**: Implement `page_server.py` and C client to fetch pages over network.
- [ ] **CRIU Integration**: Restore a process (Redis) with lazy-pages using a remote source.
- [ ] **Single-Writer Consistency**: Implement write-through to source node for correctness.

### Out of Scope

- **RDMA Transport** — Explicitly excluded for v1 to focus on logic over optimization.
- **Write-back Consistency** — Complexity of coherence protocols is out of scope for 15-week timeline.
- **Multi-node graphs** — Single source, single destination only.
- **Kubernetes Integration** — Focus on core runtime mechanics first.
- **High Availability** — No replication or failover in v1.

## Context

- **Environment**: Developing on Arch Linux (Kernel 6.18.3).
- **Dependencies**:
  - `userfaultfd` is supported in current kernel.
  - `criu` is currently missing and needs installation/compilation.
- **Research Basis**: Based on "DistriProc: Process-Level Remote Paging for Containers" proposal.
- **Key Metric**: Time-to-first-request < 1s (vs CRIU's 30s+).

## Constraints

- **Compatibility**: Must work on Linux 6.18+ (Arch).
- **Transport**: TCP only for v1.
- **Timeline**: Structured around a 15-week implementation plan, starting with Week 1 PoC.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| **Write-through** | Simplifies consistency model; safe (source always authoritative). | — Pending |
| **TCP Transport** | Universal compatibility and ease of debugging over RDMA. | — Pending |
| **Arch Linux** | Using current environment instead of strict Ubuntu 24.04 from proposal (Kernel is newer, should work). | — Pending |

---
*Last updated: 2026-02-09 after initialization*
