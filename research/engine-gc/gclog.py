"""GC and CC events from a research engine's stderr (engine.log), as javascript.options.mem.log
writes them to the console service and MOZ_LOG=PageMessages:5 prints them.

usage: python3 -I gclog.py events <engine.log> [from HH:MM] [to HH:MM]   -> one JSON line per GC/CC
       python3 -I gclog.py summary <engine.log> [from HH:MM] [to HH:MM]  -> counts per process

Times are UTC as MOZ_LOG prints them; HH:MM filters are local time (the machine's zone).
A GC is its slice 0 (reason) plus its Summary line (heap size after, change); a CC is its line
(suspected, collected refcounted and GC'd objects, and whether it forced a GC).
"""
import datetime, json, re, sys
from collections import Counter, defaultdict

TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) UTC - \[(\w+) (\d+): Main Thread\]: I/PageMessages (.*)$")
SLICE0 = re.compile(r"^\[(\w+)-(\d+)\] GC Slice 0 - .*?Reason: (\w+);")
SUMMARY = re.compile(r"^GC\(T\+[\d.]+\)\[(\w+)-(\d+)\] Summary - (?:.*?Total: |Non-Incremental: )([\d.]+)ms.*?HeapSize: ([\d.]+) MiB; HeapChange \(abs\): ([+-]?\d+)")
CC = re.compile(r"^CC\(T\+[\d.]+\)\[(\w+)-(\d+)\] max pause: (\d+)ms, total time: (\d+)ms, slices: (\d+), suspected: (\d+), "
                r"visited: (\d+) RCed and (\d+)(?: merged)? GCed, collected: (\d+) RCed and (\d+) GCed(?:.*?(forced a GC))?")
OFFSET = datetime.datetime.now().astimezone().utcoffset()


def events(path, lo=None, hi=None):
    pending = {}
    with open(path, "rb") as f:
        for raw in f:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            m = TS.match(line)
            if not m:
                continue
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f") + OFFSET
            hm = t.strftime("%H:%M")
            if (lo and hm < lo) or (hi and hm > hi):
                continue
            msg = m.group(4)
            wall = t.strftime("%H:%M:%S")
            if s := SLICE0.match(msg):
                pending[s.group(2)] = s.group(3)
            elif s := SUMMARY.match(msg):
                yield {"wall": wall, "kind": "GC", "proc": s.group(1), "pid": int(s.group(2)),
                       "reason": pending.pop(s.group(2), "?"), "ms": float(s.group(3)),
                       "heap_mib": float(s.group(4)), "change_chunks": int(s.group(5))}
            elif s := CC.match(msg):
                yield {"wall": wall, "kind": "CC", "proc": s.group(1), "pid": int(s.group(2)), "ms": int(s.group(4)),
                       "suspected": int(s.group(6)), "visited_rc": int(s.group(7)), "visited_gc": int(s.group(8)),
                       "freed_rc": int(s.group(9)), "freed_gc": int(s.group(10)), "forced_gc": bool(s.group(11))}


def summary(path, lo=None, hi=None):
    out = defaultdict(lambda: {"gc": Counter(), "cc": 0, "cc_freed_rc": 0, "cc_freed_gc": 0, "gc_ms": 0.0, "cc_ms": 0,
                               "first": None, "last": None, "heap_last": None})
    for e in events(path, lo, hi):
        o = out[f"{e['proc']}-{e['pid']}"]
        o["first"] = o["first"] or e["wall"]
        o["last"] = e["wall"]
        if e["kind"] == "GC":
            o["gc"][e["reason"]] += 1
            o["gc_ms"] += e["ms"]
            o["heap_last"] = e["heap_mib"]
        else:
            o["cc"] += 1
            o["cc_ms"] += e["ms"]
            o["cc_freed_rc"] += e["freed_rc"]
            o["cc_freed_gc"] += e["freed_gc"]
    return {k: {**v, "gc": dict(v["gc"]), "gc_ms": round(v["gc_ms"], 1)} for k, v in out.items()}


if __name__ == "__main__":
    cmd, path = sys.argv[1], sys.argv[2]
    lo = sys.argv[3] if len(sys.argv) > 3 else None
    hi = sys.argv[4] if len(sys.argv) > 4 else None
    if cmd == "events":
        for e in events(path, lo, hi):
            print(json.dumps(e))
    else:
        print(json.dumps(summary(path, lo, hi), indent=1))
