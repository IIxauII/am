"""Takes a memory report of each named engine, one after the other, and appends its summary to
reports.jsonl (beside this script).

usage: python3 -I takeall.py <label> [minimize] -- <engine dir> [<engine dir> ...]
"""
import datetime, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memreport  # noqa: E402

args = sys.argv[1:]
label = args[0]
minimize = len(args) > 1 and args[1] == "minimize"
dirs = args[args.index("--") + 1:]
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports.jsonl")
for d in dirs:
    name = os.path.basename(d.rstrip("/")).removeprefix("mem-")
    t = time.time()
    dest = memreport.take(d, label, minimize)
    rec = {"engine": name, "label": label, "minimize": minimize, "t": round(t, 1),
           "wall": datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S"),
           "took_s": round(time.time() - t, 1), "summary": memreport.summary(memreport.load(dest))}
    with open(out, "a") as f:
        f.write(json.dumps(rec) + "\n")
    s = rec["summary"]
    print(name, label, rec["wall"], {k: (v.get("resident-phys-footprint"), v.get("explicit"), v.get("heap-unclassified")) for k, v in s.items()})
