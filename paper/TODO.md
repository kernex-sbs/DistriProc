# DistriProc Paper Checklist

This checklist tracks the path from the current research prototype to a draftable paper.

## 1. Lock The System

- [x] Async prefetch moved off the fault path
- [x] Adaptive mode implemented
- [x] Redis workload uses a real working set
- [x] Per-iteration handler logs are preserved
- [x] Decide whether the current adaptive policy is the paper baseline — YES, current controller is the baseline
- [x] Avoid further core behavior changes unless results justify them

## 2. Stabilize The Evaluation Pipeline

- [x] Stop overwriting `eval/results/results.csv` across separate runs (`--append` flag)
- [x] Support one combined dataset covering `test_loop`, `redis`, and `pytorch`
- [x] Ensure `lazy`, `lazy-prefetch`, and `lazy-adaptive` all appear in the final report
- [x] Preserve per-iteration logs under `eval/results/logs/`
- [x] Verify `make report` reflects the combined dataset, not only the most recent run

## 3. Produce The Final Experimental Dataset

- [x] Run `test_loop` with `full`, `lazy`, `lazy-prefetch`, `lazy-adaptive` (5 iterations)
- [x] Run `redis` with `full`, `lazy`, `lazy-prefetch`, `lazy-adaptive` (5 iterations)
- [x] Run `pytorch` with `full`, `lazy`, `lazy-prefetch`, `lazy-adaptive` (5 iterations)
- [x] Use stable iteration counts (5 per config)
- [x] Save raw CSV and logs for all runs (`eval/results/results.csv`, `eval/results/logs/`)
- [x] Regenerate the report from the combined dataset (`eval/results/report.md`)

## 4. Lock The Claims

- [x] State exactly what the current system does — `paper/CLAIMS.md`
- [x] State exactly what it does not do — `paper/CLAIMS.md`
- [x] Keep writable remote-memory coherence out of scope — `paper/CLAIMS.md`
- [x] Keep RDMA and DSM claims out of scope — `paper/CLAIMS.md`
- [x] Frame the contribution as an adaptive post-restore remote-memory runtime — `paper/CLAIMS.md`
- [x] Decide the 2-3 headline claims the paper will defend — C1/C2/C3 in `paper/CLAIMS.md`

## 5. Prepare Figures And Tables

- [ ] TTFR table for all workloads and modes — data in `eval/results/report.md`
- [ ] Throughput table for all workloads and modes — data in `eval/results/report.md`
- [ ] Page-fault / prefetched-pages table — data in `eval/results/report.md`
- [ ] Figure showing why fixed prefetch fails (pytorch TTFR bar chart: 209/625/1159/686)
- [ ] Figure showing adaptive backoff decisions from handler logs (`eval/results/logs/`)
- [ ] Summary comparison: `lazy` vs `lazy-prefetch` vs `lazy-adaptive`

## 6. Tighten Methodology

- [ ] Document hardware and software exactly (CPU: AMD Ryzen 7 7735HS, 15GB RAM, kernel 6.18.7, CRIU 4.2)
- [ ] Document benchmark procedure exactly (`make bench-paper` → `make report`)
- [ ] Explain TTFR per workload (why pytorch lazy > full; why test_loop lazy << full)
- [ ] Explain hit rate = 0% for all modes (async prefetch wins race; metric unreliable; paper must not cite it)
- [ ] Explain Redis throughput shortfall: all lazy modes ~68% of full — TCP loopback overhead, not a claim failure
- [ ] Explain why the Redis workload is now meaningful (10k keys, 13.77MB working set)
- [ ] Write threats to validity

## 7. Update Repo Docs

- [ ] Update `README.md` with adaptive mode and final evaluated findings
- [ ] Update `docs/howto.md` with `lazy-adaptive`
- [ ] Update `docs/evaluation.md` with the final combined results
- [ ] Verify all docs match the implementation and final claims

## 8. Write The Paper

- [ ] Title
- [ ] Abstract
- [ ] Introduction
- [ ] Motivation
- [ ] Background on CRIU lazy restore and `userfaultfd`
- [ ] Design
- [ ] Implementation
- [ ] Evaluation
- [ ] Discussion
- [ ] Related work
- [ ] Limitations
- [ ] Conclusion

## 9. Final Paper Sanity Check

- [ ] Every claim maps to a result
- [ ] Every result maps to a reproducible command
- [ ] No stale claims remain from the earlier broader proposal
- [ ] Novelty statement is precise and defensible
- [ ] The abstract matches the actual artifact

## 10. Submission Readiness

- [ ] Final combined results checked into a stable location ✓ (`eval/results/results.csv` committed)
- [ ] Final report generated ✓ (`eval/results/report.md` committed)
- [ ] Paper draft complete
- [ ] Technical accuracy review done
- [ ] Overclaiming review done
- [ ] Artifact instructions tested from scratch

## Immediate Next Step

Start section 4 (Lock The Claims) then section 8 (Write The Paper).
Recommended order: claims → methodology notes → figures → paper draft → docs.
