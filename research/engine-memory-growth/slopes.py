"""Growth per process from soak.jsonl: least-squares slope (MiB/min) of phys_footprint over a window.

usage: python3 -I slopes.py <soak.jsonl> [from_wall HH:MM] [to_wall HH:MM]

Processes are keyed by engine, type and pid (the two `tab`s and two `utility`s are told apart by
pid; memreport.py's dumps say which tab is web content and which the extension).
"""
import json, sys
from collections import defaultdict


def hm(s):
    h, m = s.split(":")[:2]
    return int(h) * 60 + int(m)


def fit(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx


def main():
    path = sys.argv[1]
    lo = hm(sys.argv[2]) if len(sys.argv) > 2 else None
    hi = hm(sys.argv[3]) if len(sys.argv) > 3 else None
    series = defaultdict(list)
    totals = defaultdict(list)
    for line in open(path):
        r = json.loads(line)
        t = r["t"] / 60
        w = hm(r["wall"])
        if (lo is not None and w < lo) or (hi is not None and w > hi):
            continue
        totals[r["engine"]].append((t, r["total_mib"], r["n"]))
        for p in r["procs"]:
            series[(r["engine"], p["type"], p["pid"])].append((t, p["fp_mib"]))
    for eng, pts in totals.items():
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        print(f"{eng:6} total  n={len(pts):3}  first {ys[0]:7.1f}  last {ys[-1]:7.1f}  min {min(ys):7.1f}  max {max(ys):7.1f}  "
              f"slope {fit(xs, ys):+.3f} MiB/min  procs {sorted(set(p[2] for p in pts))}")
        for (e, kind, pid), s in sorted(series.items()):
            if e != eng or len(s) < 3:
                continue
            xs, ys = [p[0] for p in s], [p[1] for p in s]
            print(f"        {kind:8} {pid:>6}  first {ys[0]:7.1f}  last {ys[-1]:7.1f}  slope {fit(xs, ys):+.3f} MiB/min")


if __name__ == "__main__":
    main()
