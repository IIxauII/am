"""What grew between two raw memory reports of one engine, by JS class and by reporter path.

usage: python3 -I classes.py <a.json.gz> <b.json.gz> [process kind, default parent] [top]

JS objects: every explicit/ path with /classes/class(NAME)/objects/ is summed per NAME over all
zones and realms, so a growing wrapper class (ChannelWrapper, XPCWrappedNative_*, Promise...)
shows up even when spread over realms. Other paths: realm/zone/string addresses and URLs are
folded so the same reporter in different zones adds up. Prints only names and sizes (MiB), never
string contents.
"""
import os, re, sys
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memreport  # noqa: E402

FOLD = [(re.compile(r"0x[0-9a-f]+"), "0x…"), (re.compile(r"realm\([^)]*\)"), "realm(…)"),
        (re.compile(r"zone\([^)]*\)"), "zone(…)"), (re.compile(r'string\(length=\d+, copies=\d+, ".*'), "string(…)")]
CLASS = re.compile(r"/classes/class\(([^)]*)\)/objects/")


def fold(path):
    path = memreport.scrub(path)
    for rx, rep in FOLD:
        path = rx.sub(rep, path)
    return path


def tally(report, kind):
    classes, paths = defaultdict(int), defaultdict(int)
    for r in memreport.by_process(report).get(kind, []):
        if r["units"] != 0 or not r["path"].startswith("explicit/"):
            continue
        m = CLASS.search(r["path"])
        if m:
            classes[m.group(1)] += r["amount"]
        paths[fold(r["path"])] += r["amount"]
    t = memreport.totals(memreport.by_process(report).get(kind, []))
    paths["explicit/heap-unclassified"] = t.get("heap-unclassified", 0)
    return classes, paths


def main():
    a, b = memreport.load(sys.argv[1]), memreport.load(sys.argv[2])
    kind = sys.argv[3] if len(sys.argv) > 3 else "parent"
    top = int(sys.argv[4]) if len(sys.argv) > 4 else 15
    ca, pa = tally(a, kind)
    cb, pb = tally(b, kind)
    for title, x, y in (("JS classes", ca, cb), ("paths", pa, pb)):
        d = {k: y.get(k, 0) - x.get(k, 0) for k in set(x) | set(y)}
        print(f"== {kind}: {title} (MiB, b - a)")
        for k, v in sorted(d.items(), key=lambda kv: -abs(kv[1]))[:top]:
            print(f"  {v / 2**20:+8.3f}  {y.get(k, 0) / 2**20:8.3f}  {k}")


if __name__ == "__main__":
    main()
