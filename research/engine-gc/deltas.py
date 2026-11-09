"""Per-process change between two labelled memory reports in reports.jsonl, as MiB and MiB/h.

usage: python3 -I deltas.py <reports.jsonl> <label a> <label b> [engine ...]

Columns per engine: all processes' phys_footprint at a and b (as each report measured it, after
its purge of freed pages), the change per hour, and the parent's and the web content process's
change in footprint, heap-allocated and heap-unclassified.
"""
import json, sys


def main():
    path, la, lb = sys.argv[1], sys.argv[2], sys.argv[3]
    only = set(sys.argv[4:])
    rec = {}
    for line in open(path):
        r = json.loads(line)
        rec[(r["engine"], r["label"])] = r
    engines = []
    for (e, _l) in rec:
        if e not in engines and (not only or e in only):
            engines.append(e)
    print(f"{'engine':12} {'a':>6} {'b':>6} {'h':>5} {'all/h':>7} | parent/h: {'fp':>6} {'heap':>6} {'h-unc':>6} | web/h: {'fp':>5} {'heap':>5} {'h-unc':>5}")
    for e in engines:
        a, b = rec.get((e, la)), rec.get((e, lb))
        if not a or not b:
            continue
        h = (b["t"] - a["t"]) / 3600
        fp = lambda r: sum(v.get("resident-phys-footprint", 0) for v in r["summary"].values())
        row = f"{e:12} {fp(a):6.0f} {fp(b):6.0f} {h:5.2f} {(fp(b) - fp(a)) / h:+7.1f} |"
        for kind in ("parent", "web"):
            pa, pb = a["summary"].get(kind, {}), b["summary"].get(kind, {})
            d = [(pb.get(k, 0) - pa.get(k, 0)) / h for k in ("resident-phys-footprint", "heap-allocated", "heap-unclassified")]
            row += (f"           {d[0]:+6.1f} {d[1]:+6.1f} {d[2]:+6.1f} |" if kind == "parent" else f"        {d[0]:+5.1f} {d[1]:+5.1f} {d[2]:+5.1f}")
        print(row)


if __name__ == "__main__":
    main()
