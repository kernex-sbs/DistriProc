# DistriProc Paper Status

The draftable-paper checklist this file used to track is **done**. The paper is
written, the canonical dataset is locked (n=20 on Linux 6.18.7), figures and tables
are generated, and the artifact is reproducible. The live document is
`paper/paper.tex`; claims contract is `paper/CLAIMS.md`. This file now tracks only what
remains before submission.

## Done (was the old checklist §1-§9)

- System locked: async prefetch off fault path, adaptive controller, real Redis/Valkey
  working set, preserved per-iteration logs.
- Evaluation pipeline: combined dataset across `test_loop`, `redis`, `pytorch`; logs
  under `eval/results/logs/`.
- Canonical dataset: **n=20** loopback matrix (`eval/results/results.csv`), RTT sweep
  **n=10** (`eval/results/crosshost*/`), cross-kernel 7.0.9 (`eval/results/kernel7/`).
- Claims locked and reframed around **C0 (the RTT crossover)**; C1-C3 are the loopback
  findings it contextualizes (`paper/CLAIMS.md`).
- Paper written end to end (title -> conclusion + appendices), builds clean under
  tectonic: ~15 pp, 0 undefined refs, all citations used.
- Docs synced (`README.md`, `docs/howto.md`, `docs/evaluation.md`, `paper/CLAIMS.md`).
- Three review passes applied (logic, consistency, em-dash sweep, RTT-narrative vs
  Table VII, cost-model honesty, CIs on the RTT sweep, shared-transport terminology,
  causal hedging, kernel-confound on the two-machine run).

## Open before submission

- [ ] **Venue.** Targeting a traditional (subscription, no-APC) peer-reviewed venue.
      Shortlist parked in `paper/VENUE_OPTIONS.md`. Decision pending. Drives the
      running head, page-limit/overlength check, and double-blind (`\anontrue`) build.
- [x] **Two-machine cross-host run.** DONE (commits fa8c460, 7333c6c). Real LAN
      A<->B, page server on a second physical host, measured RTT 311us, n=50:
      lazy 7073+-124, fixed 1985+-28 (-71.9%), adaptive 2133+-30. Confirms the
      above-crossover regime on real hardware. NOTE: both hosts ran Linux 7.0.x
      (not 6.18.7), so magnitudes are NOT cross-comparable to the netem sweep — the
      earlier "netem conservative" framing was retracted. Folded into §V-J
      "Real Two-Machine Validation" (Table tab:twomachine) + fig6 overlay.
      Data: `eval/results/crosshost-2machine/results.csv`. Open follow-on (future
      work, not a blocker): a full *physical* RTT sweep on a fixed kernel, and RDMA.
      Still to add (user input): NIC type / link speed / switch-vs-cable for §V-J.
- [ ] **Final human proofread** for tone/flow (mechanical + logical layers are clean).
- [ ] **Packaging** once venue is set: arXiv source tarball + camera-ready PDF, and the
      submission `\anontrue` build if the venue is double-blind.

## Not blockers (scoped as future work in the paper)

RTT-aware controller, RDMA validation, writable coherence, learned thresholds,
cross-architecture (ARM64 page sizes), PSI integration.
