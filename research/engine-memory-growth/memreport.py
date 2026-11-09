"""Firefox memory reports of the research engines: take them and compare them.

  python3 -I memreport.py take <engine dir> <label> [minimize]
      Writes "memory report" (or "minimize memory report") to <engine dir>/dumps/debug_info_trigger,
      waits for Firefox's unified-memory-report-<ts>-<parent pid>.json.gz (it lands in the OS temp
      dir, NS_OS_TEMP_DIR, whatever MOZ_UPLOAD_DIR says), moves it to <engine dir>/dumps/<label>.json.gz
      and prints its summary.
  python3 -I memreport.py summary <a.json.gz>
  python3 -I memreport.py diff <a.json.gz> <b.json.gz> [depth] [top]

Raw dumps stay out of the repo: unanonymized reports can name strings and URLs the page holds.
A summary keeps only per-process totals and explicit/ paths cut to a depth, with any string(...)
or URL in a path replaced.
"""
import glob, gzip, json, os, re, sys, tempfile, time

MIB = 2 ** 20
TMPDIR = os.path.realpath(tempfile.gettempdir())


def load(path):
    with gzip.open(path) as f:
        return json.load(f)


def proc_kind(name):
    # "Main Process (pid 1)", "web (pid 2)", "extension (pid 3)", "RDD (pid 4)", "Utility (pid 5, sandboxingKind 1)"
    m = re.match(r"(.+?) \(pid (\d+)", name)
    kind = m.group(1) if m else name
    if kind == "Main Process":
        kind = "parent"
    if kind == "Utility":
        sk = re.search(r"sandboxingKind (\d+)", name)
        kind = f"utility{sk.group(1) if sk else ''}"
    return kind


def scrub(seg):
    seg = re.sub(r'string\(length=\d+, copies=\d+, ".*', "string(...)", seg)
    seg = re.sub(r"(https?|blob|moz-extension|resource|chrome|about|file):[^ )\]]*", r"\1:<url>", seg)
    return seg


def by_process(d):
    procs = {}
    for r in d["reports"]:
        procs.setdefault(proc_kind(r["process"]), []).append(r)
    return procs


def totals(reports):
    t = {}
    explicit = heap_explicit = 0
    for r in reports:
        p, a = r["path"], r["amount"]
        if r["units"] != 0:
            continue
        if p.startswith("explicit/"):
            explicit += a
            if r["kind"] == 1:
                heap_explicit += a
        elif "/" not in p:
            t[p] = a
    t["explicit"] = explicit
    if "heap-allocated" in t:
        t["heap-unclassified"] = t["heap-allocated"] - heap_explicit
        t["explicit"] = explicit + t["heap-unclassified"]
    return t


def tree(reports, depth):
    agg = {}
    for r in reports:
        if r["units"] != 0 or not r["path"].startswith("explicit/"):
            continue
        segs = [scrub(s) for s in r["path"].split("/")[:depth]]
        k = "/".join(segs)
        agg[k] = agg.get(k, 0) + r["amount"]
    return agg


def summary(d, depth=3, top=12):
    out = {}
    for kind, reps in sorted(by_process(d).items()):
        t = totals(reps)
        keep = ("resident-phys-footprint", "resident", "resident-unique", "heap-allocated", "explicit", "heap-unclassified")
        s = {k: round(t[k] / MIB, 2) for k in keep if k in t}
        tr = tree(reps, depth)
        if "heap-unclassified" in t:
            tr["explicit/heap-unclassified"] = t["heap-unclassified"]
        s["top"] = [[k, round(v / MIB, 2)] for k, v in sorted(tr.items(), key=lambda kv: -kv[1])[:top]]
        out[kind] = s
    return out


def diff(a, b, depth=4, top=15):
    pa, pb = by_process(a), by_process(b)
    out = {}
    for kind in sorted(set(pa) | set(pb)):
        ta, tb = totals(pa.get(kind, [])), totals(pb.get(kind, []))
        tot = {k: round((tb.get(k, 0) - ta.get(k, 0)) / MIB, 2)
               for k in ("resident-phys-footprint", "heap-allocated", "explicit", "heap-unclassified")}
        xa, xb = tree(pa.get(kind, []), depth), tree(pb.get(kind, []), depth)
        if "heap-unclassified" in ta:
            xa["explicit/heap-unclassified"] = ta["heap-unclassified"]
        if "heap-unclassified" in tb:
            xb["explicit/heap-unclassified"] = tb["heap-unclassified"]
        d = {k: xb.get(k, 0) - xa.get(k, 0) for k in set(xa) | set(xb)}
        grew = sorted(d.items(), key=lambda kv: -abs(kv[1]))[:top]
        out[kind] = {"delta_mib": tot, "paths": [[k, round(v / MIB, 3)] for k, v in grew if abs(v) >= 0.01 * MIB]}
    return out


def take(engine_dir, label, minimize=False):
    # Parent pid: the process holding the FIFO is the one we ask; its file names it.
    before = set(glob.glob(os.path.join(TMPDIR, "unified-memory-report-*.json.gz")))
    fifo = os.path.join(engine_dir, "dumps", "debug_info_trigger")
    fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    os.write(fd, (b"minimize memory report" if minimize else b"memory report") + b"\n")
    os.close(fd)
    pid = parent_pid(engine_dir)
    pattern = os.path.join(TMPDIR, f"unified-memory-report-*-{pid}.json.gz")
    end = time.time() + 120
    while time.time() < end:
        new = [p for p in glob.glob(pattern) if p not in before]
        if new:
            time.sleep(1)
            dest = os.path.join(engine_dir, "dumps", label + ".json.gz")
            os.replace(new[0], dest)
            return dest
        time.sleep(0.5)
    raise SystemExit(f"no report from pid {pid} within 120 s")


def parent_pid(engine_dir):
    import subprocess
    prof = os.path.join(engine_dir, "firefox-profile")
    out = subprocess.run(["ps", "-A", "-ww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if prof in cmd and cmd.split()[0].endswith("/firefox"):
            return int(pid)
    raise SystemExit("no Firefox on " + prof)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "take":
        dest = take(sys.argv[2], sys.argv[3], len(sys.argv) > 4 and sys.argv[4] == "minimize")
        print(json.dumps({"file": dest, "summary": summary(load(dest))}))
    elif cmd == "summary":
        print(json.dumps(summary(load(sys.argv[2])), indent=1))
    elif cmd == "diff":
        depth = int(sys.argv[4]) if len(sys.argv) > 4 else 4
        top = int(sys.argv[5]) if len(sys.argv) > 5 else 15
        print(json.dumps(diff(load(sys.argv[2]), load(sys.argv[3]), depth, top), indent=1))
