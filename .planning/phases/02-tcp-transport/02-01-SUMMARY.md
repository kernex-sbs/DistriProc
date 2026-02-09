---
phase: 02-tcp-transport
plan: 01
subsystem: networking
tags: [tcp, userfaultfd, python, c]

# Dependency graph
requires:
  - phase: 01-poc-basic-uffd
    provides: Local userfaultfd handling
provides:
  - Remote page fetching mechanism
  - Split architecture (Client execution / Server memory)
affects:
  - phase: 03-criu-integration

# Tech tracking
tech-stack:
  added: [python-socket, c-socket]
  patterns: [Request-Response Page Protocol]

key-files:
  created:
    - /home/utkarsh/Work/kernex/DistriProc/src/page_server.py
    - /home/utkarsh/Work/kernex/DistriProc/src/test_uffd_tcp.c
  modified: []

key-decisions:
  - "Protocol: Simple 8-byte address request, 4KB raw data response."
  - "Server Logic: Generates deterministic pattern based on address for verification."
  - "Client Logic: Blocking `recv` in fault handler (acceptable for PoC, will need async for performance later)."

patterns-established:
  - "Remote Fault Resolution: Fault -> UFFD -> Handler -> TCP Send -> TCP Recv -> UFFDIO_COPY"

issues-created: []

# Metrics
duration: 15min
completed: 2026-02-09
---

# Phase 02 Plan 01: TCP Transport Summary

**Successfully implemented remote page fetching over TCP.**

## Performance

- **Duration:** 15 min
- **Started:** 2026-02-09
- **Completed:** 2026-02-09
- **Tasks:** 3
- **Files modified:** 2 (created)

## Accomplishments
- Implemented `src/page_server.py`: A Python-based TCP server that listens for page requests and serves generated content.
- Implemented `src/test_uffd_tcp.c`: A modified C client that connects to the server, registers userfaultfd, and fetches pages over the network upon faulting.
- **Verification**: Confirmed that the C client successfully receives data (values 65 'A', 81 'Q', 97 'a') from the Python server corresponding to the requested addresses.

## Architecture Change
Moved from **Local Generation** (memset in handler) to **Remote Fetching** (TCP Request/Response).
- **Before**: `Fault -> Handler -> memset(0) -> UFFDIO_COPY`
- **After**: `Fault -> Handler -> send(addr) -> recv(page) -> UFFDIO_COPY`

## Deviations from Plan
None. The implementation followed the plan exactly.

## Issues Encountered
- **Connection Refused**: Initial run failed because I forgot to start the background server (classic).
- **Fix**: Started `page_server.py` in the background and re-ran the client.

## Next Phase Readiness
- Ready for Phase 3: CRIU Integration. We now have the "Transport" part of the system. The next challenge is hooking this into a real process restore flow.

---
*Phase: 02-tcp-transport*
*Completed: 2026-02-09*
