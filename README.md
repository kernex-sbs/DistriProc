# DistriProc

**Indefinite execution with remote memory.**

DistriProc is a system that enables Linux processes to execute indefinitely with partially remote address spaces, effectively turning memory into a networked resource. It decouples memory location from execution location, allowing processes to start in sub-second time by fetching pages on-demand via userfaultfd and TCP, rather than waiting for full memory migration.

## Core Value

The ability to start a process immediately (<1s) and keep it running without ever requiring the full address space to be local.

## Status

Currently in active development.

- **Phase 1 (Complete):** Basic userfaultfd proof-of-concept verified.
- **Phase 2 (Next):** Implementing TCP transport for remote page fetching.

## Requirements

- Linux Kernel 5.7+ (for userfaultfd features)
- GCC / Python 3

## Build

```bash
gcc -o src/test_uffd src/test_uffd.c -pthread
```

## Run

```bash
./src/test_uffd
```

## Architecture

DistriProc uses `userfaultfd` to trap page faults in userspace. A background handler thread intercepts these faults and fetches the required page content (currently locally generated, soon over TCP).

## License

MIT
