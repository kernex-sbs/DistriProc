# Paper vs TCP_NODELAY=0/1 remeasure: TTFR mean±95% CI, Welch p (normal approx).
# Usage: python3 eval/analyze_nodelay.py
import csv, sys, statistics as st, math
from collections import defaultdict
R = "/home/utkarsh/Work/proc/distriProc/eval/results/"
def load(p, key):
    d = defaultdict(list)
    for r in csv.DictReader(open(R + p)):
        if float(r["ttfr_ms"]) < 0: continue
        d[tuple(r[k] for k in key)].append(float(r["ttfr_ms"]))
    return d
def ms(x):
    if not x: return "—"
    m = st.mean(x); h = 1.96*st.stdev(x)/math.sqrt(len(x)) if len(x) > 1 else 0
    return f"{m:.0f}±{h:.0f}"
def welch_p(a, b):
    from math import erf
    va, vb = st.variance(a)/len(a), st.variance(b)/len(b)
    t = (st.mean(a)-st.mean(b))/math.sqrt(va+vb)
    return 2*(1-0.5*(1+erf(abs(t)/math.sqrt(2))))  # normal approx
MODES = ["full","lazy","lazy-prefetch","lazy-adaptive"]
print("## Matrix (TTFR ms, mean±95%CI)")
P, N0, N1 = load("results.csv",["workload","mode"]), load("nodelay0/matrix/results.csv",["workload","mode"]), load("nodelay1/matrix/results.csv",["workload","mode"])
print("wl mode | paper | nd0 | nd1 | n")
for w in ["test_loop","redis","pytorch"]:
    for m in MODES:
        k=(w,m); print(w,m,"|",ms(P.get(k)),"|",ms(N0.get(k)),"|",ms(N1.get(k)),"|",len(N1.get(k,[])))
    for name,D in [("paper",P),("nd0",N0),("nd1",N1)]:
        l, p = D.get((w,"lazy")), D.get((w,"lazy-prefetch"))
        a = D.get((w,"lazy-adaptive"))
        if l and p: print(f"   {name}: prefetch vs lazy {100*(st.mean(p)/st.mean(l)-1):+.0f}% p={welch_p(p,l):.2g}; adaptive vs lazy {100*(st.mean(a)/st.mean(l)-1):+.0f}%")
print("\n## Sweep pytorch (TTFR ms)")
S = {n: load(f, ["mode","rtt_us"]) for n,f in [("paper","crosshost/results-crosshost.csv"),("fine","crosshost-fine/results-crosshost.csv"),("nd0","nodelay0/sweep/results-crosshost.csv"),("nd1","nodelay1/sweep/results-crosshost.csv")]}
for n,D in S.items():
    rtts = sorted({int(k[1]) for k in D})
    print(f"\n### {n}")
    print("rtt | " + " | ".join(MODES) + " | pf/lazy | ad/lazy")
    for r in rtts:
        v = [D.get((m,str(r))) for m in MODES]
        rat = lambda a,b: f"{st.mean(a)/st.mean(b):.2f}" if a and b else "—"
        print(r,"|"," | ".join(ms(x) for x in v),"|",rat(v[2],v[1]),"|",rat(v[3],v[1]))
