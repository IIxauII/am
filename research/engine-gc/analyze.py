"""Growth, CPU and wake-ups per research engine over a window of soak.jsonl.

usage: python3 -I analyze.py <soak.jsonl> <from HH:MM> <to HH:MM> [engine ...]

Per engine: total phys_footprint at both ends, the least-squares slope in MiB/h (all processes,
and the parent alone), and CPU (% of one core) and wake-ups per second, from the cumulative
counters of the processes that live through the whole window.
"""
import json, sys
from collections import defaultdict


def hm(s):
    h, m = s.split(":")[:2]
    return int(h) * 60 + int(m)


def fit(pts):
    n = len(pts)
    if n < 2:
        return 0.0
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx if sxx else 0.0


def main():
    path, lo, hi = sys.argv[1], hm(sys.argv[2]), hm(sys.argv[3])
    only = set(sys.argv[4:])
    rows = defaultdict(list)
    for line in open(path):
        r = json.loads(line)
        if only and r["engine"] not in only:
            continue
        if lo <= hm(r["wall"]) <= hi and r["n"]:
            rows[r["engine"]].append(r)
    print(f"{'engine':12} {'n':>3} {'first':>7} {'last':>7} {'MiB/h':>7} {'parent':>7} {'others':>7} {'CPU%':>6} {'wk/s':>6}")
    for eng, rs in rows.items():
        tot = [(r["t"] / 3600, r["total_mib"]) for r in rs]
        par = [(r["t"] / 3600, sum(p["fp_mib"] for p in r["procs"] if p["type"] == "parent" and p["fp_mib"] > 1)) for r in rs]
        a, b = rs[0], rs[-1]
        pa = {p["pid"]: p for p in a["procs"]}
        dt = b["t"] - a["t"]
        cpu = wk = 0.0
        for p in b["procs"]:
            q = pa.get(p["pid"])
            if q:
                cpu += p["cpu_s"] - q["cpu_s"]
                wk += p["wk"] - q["wk"]
        st, sp = fit(tot), fit(par)
        print(f"{eng:12} {len(rs):3} {a['total_mib']:7.1f} {b['total_mib']:7.1f} {st:+7.1f} {sp:+7.1f} {st - sp:+7.1f} "
              f"{100 * cpu / dt if dt else 0:6.2f} {wk / dt if dt else 0:6.1f}")


if __name__ == "__main__":
    main()
