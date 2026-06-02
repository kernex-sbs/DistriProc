# Venue Options (parked — decide later)

Goal: a **respected, peer-reviewed venue that costs the author $0**. Discussion paused;
this file holds the shortlist so we can resume without re-deriving it.

## Key clarification (resolves the IEEE confusion)

"Free to the author" comes in two models, both $0 out of pocket:

- **Subscription** — free to publish, paywalled to read (libraries pay). This includes
  **all traditional IEEE/ACM Transactions**. Only **IEEE *Access*** (gold OA) charges the
  ~$1,995 APC. So a regular IEEE *Transactions* is free to publish; the earlier "no paying
  IEEE" worry only applied to *Access*.
- **Diamond / Platinum OA** — free to publish **and** free to read.

Watch for hidden costs even in "free" venues: **overlength page charges** (IEEE/ACM beyond
~12-14 pp; our paper is ~13 pp, so check), legacy color fees. And avoid **predatory**
"free + instant accept" journals: filter by **DOAJ** listing (with seal), **COPE**
membership, and run **Think-Check-Submit**. Fee models change — confirm "no APC" on the
journal's current author page before committing.

## Best fit for this paper (systems / OS / CRIU / remote memory)

### Free + open + highest prestige -> conferences (CS weights these above journals)
- **USENIX ATC, FAST, OSDI, NSDI** — free to publish, **free to read** (USENIX is fully
  OA). Top tier, competitive.
- **EuroSys, SoCC, Middleware, IPDPS, ICDCS** — free to publish (some OA).
- Workshops (lower bar, fast): **HotOS, HotStorage, APSys, SYSTOR**.

### Subscription journals — $0 author cost, reputable, on-topic
- **IEEE TPDS** (Parallel & Distributed Systems) — strongest journal fit. Free to publish.
- **IEEE TC** (Computers), **IEEE TCC** (Cloud Computing) — free.
- **ACM TOCS** (Computer Systems), **ACM TOS** (Storage) — free to author.
- **Elsevier**: JPDC, Journal of Systems Architecture (JSA), Future Generation Computer
  Systems (FGCS), Performance Evaluation — free (optional OA).
- **Springer**: Computing, Cluster Computing, The Journal of Supercomputing.
- **Wiley**: Concurrency and Computation: Practice & Experience (CCPE).

### Diamond OA journals — free both ways
- **Journal of Systems Research (JSys)** — systems-focused, diamond OA, run by systems
  academics. Direct topical fit; newer, lower citation weight.
- **The Art, Science & Engineering of Programming (Programming)** — diamond OA.

### Software-artifact venue (bonus, free, peer-reviewed)
- **JOSS** (Journal of Open Source Software) — publishes the `DistriProc` *code*, not the
  measurement study. Complements a paper; does not replace it.

## Leading candidates

- **Ambitious + free + open:** USENIX ATC or FAST. Conference, OA, top prestige, $0.
- **Journal route, free + respected:** **IEEE TPDS** (free to publish — APC was an
  *Access*-only concern).
- **Free + fully open journal:** **JSys**.

## Decision

Pending. When chosen, this drives: running head (`\markboth`), page-limit/overlength
check, and the double-blind (`\anontrue`) build. The paper is already in
`\documentclass[journal]{IEEEtran}`, so an IEEE/most-journal target needs no reformat;
a conference target needs trimming + the conference `IEEEtran`/ACM template.

> TODO when resuming: pick 2-3, verify each one's current fee/blind/page-limit on its
> author page, then set the venue in `paper/TODO.md` and update `\markboth`.
