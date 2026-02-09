---
phase: 01-poc-basic-uffd
plan: 01
subsystem: systems
tags: [userfaultfd, mmap, linux-kernel, poc]

# Dependency graph
requires:
  - phase: PROJECT-INIT
    provides: Project structure and roadmap
provides:
  - Local userfaultfd page fault interception
  - Local page serving mechanism (UFFDIO_COPY)
affects:
  - phase: 02-tcp-transport

# Tech tracking
tech-stack:
  added: [userfaultfd, poll.h]
  patterns: [Background fault handler thread, userspace page fault handling]

key-files:
  created: [/home/utkarsh/Work/kernex/DistriProc/src/test_uffd.c]
  modified: []

key-decisions:
  - "Used UFFD_USER_MODE_ONLY to allow execution without root/sysctl changes on modern kernels (where supported)."
  - "Used poll() in the handler thread to handle O_NONBLOCK userfaultfd descriptor correctly."

patterns-established:
  - "Fault handling: Background thread with poll loop reading uffd_msg."

issues-created: []

# Metrics
duration: 10min
completed: 2026-02-09
---

# Phase 01 Plan 01: Basic userfaultfd PoC Summary

**Successfully verified userfaultfd page fault interception and local page serving on Linux 6.18.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-02-09T12:35:00Z
- **Completed:** 2026-02-09T12:45:00Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- Implemented `src/test_uffd.c` which demonstrates userspace page fault handling.
- Verified `UFFDIO_REGISTER_MODE_MISSING` correctly traps read/write access to unmapped memory.
- Verified `UFFDIO_COPY` successfully installs pages and allows process execution to resume.

## Task Commits

Each task was committed atomically:

1. **Task 1: Create test_uffd.c source** - `780c88e` (feat)
2. **Task 2: Compile and run PoC** - `566e0f8` (test)

## Files Created/Modified
- `/home/utkarsh/Work/kernex/DistriProc/src/test_uffd.c` - Minimal PoC for local userfaultfd handling.

## Decisions Made
- **UFFD_USER_MODE_ONLY**: Added this flag to the `userfaultfd` syscall to support unprivileged execution on kernels that restrict userfaultfd to root by default but allow it for user-mode faults.
- **Handler Loop**: Implemented a `poll()` loop in the handler thread because the descriptor was opened with `O_NONBLOCK`, preventing a busy-wait or "resource unavailable" errors.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing <poll.h> and poll() call**
- **Found during:** Task 2 (Compile and run PoC)
- **Issue:** `struct pollfd` was unknown and `read()` on non-blocking UFFD failed with EAGAIN.
- **Fix:** Added `#include <poll.h>` and wrapped `read()` in a `poll()` loop.
- **Files modified:** `/home/utkarsh/Work/kernex/DistriProc/src/test_uffd.c`
- **Verification:** Compilation succeeded and runtime execution proceeded without EAGAIN.
- **Committed in:** `566e0f8` (Task 2 commit)

**2. [Rule 3 - Blocking] syscall-userfaultfd: Operation not permitted**
- **Found during:** Task 2 (Compile and run PoC)
- **Issue:** Kernel `vm.unprivileged_userfaultfd` set to 0, blocking the syscall for non-root users.
- **Fix:** Added `UFFD_USER_MODE_ONLY` flag to the syscall.
- **Files modified:** `/home/utkarsh/Work/kernex/DistriProc/src/test_uffd.c`
- **Verification:** Program successfully created the UFFD object without root.
- **Committed in:** `566e0f8` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 blocking), 0 deferred
**Impact on plan:** Essential fixes for portability and correctness on modern Linux kernels. No scope creep.

## Issues Encountered
- `sudo sysctl` failed because of missing terminal/password interaction. Switched to `UFFD_USER_MODE_ONLY` as a more robust programmatic workaround.

## Next Phase Readiness
- Ready for Phase 2: TCP Transport. The foundation for trapping faults and serving pages is solid.

---
*Phase: 01-poc-basic-uffd*
*Completed: 2026-02-09*
