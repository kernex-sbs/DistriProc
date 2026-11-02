# TCP_NODELAY remeasure — 2026-11-02, kernel 7.2.8, CPU torch 2.15

Run: `sudo bash eval/remeasure_nodelay.sh` (07:59–10:29). Regenerate: `python3 eval/analyze_nodelay.py`.
Failures: lazy @ RTT 2000 µs, all 10 iters both arms — 30 s probe timeout (paper: same).

```
## Matrix (TTFR ms, mean±95%CI)
wl mode | paper | nd0 | nd1 | n
test_loop full | 1019±1 | 17±0 | 18±0 | 20
test_loop lazy | 42±1 | 41±1 | 42±2 | 20
test_loop lazy-prefetch | 43±3 | 41±1 | 27±1 | 20
test_loop lazy-adaptive | 41±1 | 40±2 | 29±1 | 20
   paper: prefetch vs lazy +4% p=0.29; adaptive vs lazy -0%
   nd0: prefetch vs lazy -0% p=0.87; adaptive vs lazy -1%
   nd1: prefetch vs lazy -35% p=0; adaptive vs lazy -31%
redis full | 32±2 | 31±1 | 31±0 | 20
redis lazy | 37±2 | 35±1 | 35±2 | 20
redis lazy-prefetch | 39±2 | 37±2 | 37±1 | 20
redis lazy-adaptive | 38±2 | 34±1 | 34±1 | 20
   paper: prefetch vs lazy +4% p=0.19; adaptive vs lazy +3%
   nd0: prefetch vs lazy +6% p=0.067; adaptive vs lazy -3%
   nd1: prefetch vs lazy +4% p=0.2; adaptive vs lazy -3%
pytorch full | 191±7 | 202±5 | 208±2 | 20
pytorch lazy | 650±10 | 618±8 | 618±16 | 20
pytorch lazy-prefetch | 1227±23 | 1146±15 | 311±11 | 20
pytorch lazy-adaptive | 655±9 | 594±7 | 352±55 | 20
   paper: prefetch vs lazy +89% p=0; adaptive vs lazy +1%
   nd0: prefetch vs lazy +85% p=0; adaptive vs lazy -4%
   nd1: prefetch vs lazy -50% p=0; adaptive vs lazy -43%

## Sweep pytorch (TTFR ms)

### paper
rtt | full | lazy | lazy-prefetch | lazy-adaptive | pf/lazy | ad/lazy
0 | 196±8 | 635±7 | 1220±15 | 666±21 | 1.92 | 1.05
500 | 176±8 | 8792±19 | 6832±114 | 7065±206 | 0.78 | 0.80
1000 | 224±9 | 16700±78 | 10462±382 | 10906±612 | 0.63 | 0.65
2000 | 181±3 | — | 12807±424 | 16409±496 | — | —

### fine
rtt | full | lazy | lazy-prefetch | lazy-adaptive | pf/lazy | ad/lazy
0 | 162±3 | 617±5 | 1175±17 | 614±6 | 1.90 | 0.99
30 | 158±2 | 1165±11 | 1703±10 | 1160±5 | 1.46 | 1.00
60 | 153±1 | 1649±13 | 2346±56 | 1642±7 | 1.42 | 1.00
100 | 154±1 | 2300±6 | 2455±62 | 2230±22 | 1.07 | 0.97
150 | 165±3 | 3126±16 | 2919±51 | 3208±64 | 0.93 | 1.03
200 | 218±8 | 4353±272 | 3640±85 | 3871±37 | 0.84 | 0.89
300 | 212±7 | 5850±47 | 4896±95 | 5263±56 | 0.84 | 0.90
500 | 202±6 | 9121±50 | 7209±224 | 7319±156 | 0.79 | 0.80

### nd0
rtt | full | lazy | lazy-prefetch | lazy-adaptive | pf/lazy | ad/lazy
0 | 218±2 | 651±27 | 1197±11 | 623±11 | 1.84 | 0.96
30 | 202±3 | 1189±33 | 1782±44 | 1215±37 | 1.50 | 1.02
60 | 222±10 | 1712±40 | 2467±102 | 1623±20 | 1.44 | 0.95
100 | 201±2 | 2272±15 | 2498±126 | 2250±18 | 1.10 | 0.99
150 | 213±3 | 3653±145 | 3643±155 | 2944±64 | 1.00 | 0.81
200 | 203±5 | 3906±9 | 3446±78 | 3739±56 | 0.88 | 0.96
300 | 213±2 | 5611±46 | 4614±61 | 5052±77 | 0.82 | 0.90
500 | 211±2 | 8942±114 | 6609±228 | 6991±149 | 0.74 | 0.78
1000 | 208±2 | 16712±132 | 10359±429 | 10728±815 | 0.62 | 0.64
2000 | 201±1 | — | 12576±695 | 16704±642 | — | —

### nd1
rtt | full | lazy | lazy-prefetch | lazy-adaptive | pf/lazy | ad/lazy
0 | 228±19 | 638±25 | 330±18 | 327±12 | 0.52 | 0.51
30 | 212±2 | 1194±24 | 406±10 | 405±5 | 0.34 | 0.34
60 | 202±2 | 1606±6 | 410±8 | 400±3 | 0.26 | 0.25
100 | 212±1 | 2270±23 | 460±4 | 549±170 | 0.20 | 0.24
150 | 203±2 | 3171±60 | 545±12 | 512±6 | 0.17 | 0.16
200 | 210±3 | 3918±20 | 604±6 | 586±3 | 0.15 | 0.15
300 | 207±1 | 5587±10 | 785±3 | 716±5 | 0.14 | 0.13
500 | 212±6 | 8788±20 | 1192±6 | 997±24 | 0.14 | 0.11
1000 | 200±2 | 16672±141 | 2192±11 | 1719±29 | 0.13 | 0.10
2000 | 206±4 | — | 4210±13 | 3208±37 | — | —
```
