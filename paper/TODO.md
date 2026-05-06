# DistriProc Paper Checklist

This checklist tracks the path from the current research prototype to a draftable paper.

## 1. Lock The System

- [x] Async prefetch moved off the fault path
- [x] Adaptive mode implemented
- [x] Redis workload uses a real working set
- [x] Per-iteration handler logs are preserved
- [ ] Decide whether the current adaptive policy is the paper baseline
- [ ] Avoid further core behavior changes unless results justify them

## 2. Stabilize The Evaluation Pipeline

- [ ] Stop overwriting `eval/results/results.csv` across separate runs
- [ ] Support one combined dataset covering `test_loop`, `redis`, and `pytorch`
- [ ] Ensure `lazy`, `lazy-prefetch`, and `lazy-adaptive` all appear in the final report
- [ ] Preserve per-iteration logs under `eval/results/logs/`
- [ ] Verify `make report` reflects the combined dataset, not only the most recent run

## 3. Produce The Final Experimental Dataset

- [ ] Run `test_loop` with `lazy`, `lazy-prefetch`, `lazy-adaptive`
- [ ] Run `redis` with `lazy`, `lazy-prefetch`, `lazy-adaptive`
- [ ] Run `pytorch` with `lazy`, `lazy-prefetch`, `lazy-adaptive`
- [ ] Use stable iteration counts
- [ ] Save raw CSV and logs for all runs
- [ ] Regenerate the report from the combined dataset

## 4. Lock The Claims

- [ ] State exactly what the current system does
- [ ] State exactly what it does not do
- [ ] Keep writable remote-memory coherence out of scope
- [ ] Keep RDMA and DSM claims out of scope
- [ ] Frame the contribution as an adaptive post-restore remote-memory runtime
- [ ] Decide the 2-3 headline claims the paper will defend

## 5. Prepare Figures And Tables

- [ ] TTFR table for all workloads and modes
- [ ] Throughput table for all workloads and modes
- [ ] Page-fault / prefetched-pages / duplicate-pressure table
- [ ] Figure showing why fixed prefetch fails
- [ ] Figure showing adaptive backoff decisions from handler logs
- [ ] Summary comparison: `lazy` vs `lazy-prefetch` vs `lazy-adaptive`

## 6. Tighten Methodology

- [ ] Document hardware and software exactly
- [ ] Document benchmark procedure exactly
- [ ] Explain TTFR per workload
- [ ] Explain remaining PyTorch throughput limitations if still present
- [ ] Explain why the Redis workload is now meaningful
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

- [ ] Final combined results checked into a stable location
- [ ] Final report generated
- [ ] Paper draft complete
- [ ] Technical accuracy review done
- [ ] Overclaiming review done
- [ ] Artifact instructions tested from scratch

## Immediate Next Step

- [ ] Fix result accumulation and combined report generation so one final report covers all workloads and modes
