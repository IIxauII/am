"""GC/CC probes through Firefox's debug FIFO, and a count of what a GC log holds.

  python3 -I gcdump.py take <engine dir> gc|cc
      gc: writes "gc log" to the FIFO. An all-traces CC log forces a full GC first (CC_FORCED),
          then a CC, in every process; no memory-pressure, so no cache purge.
      cc: writes "abbreviated gc log": a CC with logging and no GC, unless the gray bits are invalid.
      Waits for the gc-edges/cc-edges logs (Firefox writes them to the OS temp dir) and moves
      them to <engine dir>/dumps/gclog-<mode>/.
  python3 -I gcdump.py count <gc-edges log> [top]
      JS cells by mark color (B black, G gray, W white) and kind, e.g. XPCWrappedNative_NoHelper,
      ChannelWrapper, Promise. Prints names and counts only: the logs hold string contents and
      stay out of the repo.
"""
import glob, os, re, shutil, sys, tempfile, time
from collections import Counter

TMPDIR = os.path.realpath(tempfile.gettempdir())


def take(engine_dir, mode):
    pattern = os.path.join(TMPDIR, "*edges*.log")
    before = set(glob.glob(pattern))
    fd = os.open(os.path.join(engine_dir, "dumps", "debug_info_trigger"), os.O_WRONLY | os.O_NONBLOCK)
    os.write(fd, b"gc log\n" if mode == "gc" else b"abbreviated gc log\n")
    os.close(fd)
    out = os.path.join(engine_dir, "dumps", f"gclog-{mode}")
    os.makedirs(out, exist_ok=True)
    end, quiet_since, seen = time.time() + 180, None, set()
    while time.time() < end:
        now = set(glob.glob(pattern)) - before
        done = {p for p in now if not os.path.basename(p).startswith("incomplete-")}
        if now and now == done and done == seen:
            quiet_since = quiet_since or time.time()
            if time.time() - quiet_since > 5:
                break
        else:
            quiet_since = None
        seen = done
        time.sleep(0.5)
    for p in seen:
        shutil.move(p, os.path.join(out, os.path.basename(p)))
    return sorted(os.listdir(out))


def count(path, top=25):
    kinds = Counter()
    line_rx = re.compile(r"^0x[0-9a-f]+ ([BGW]) (\S+)")
    with open(path, "rb") as f:
        for raw in f:
            m = line_rx.match(raw.decode("utf-8", "replace"))
            if m:
                kinds[(m.group(1), m.group(2))] += 1
    return kinds.most_common(top)


if __name__ == "__main__":
    if sys.argv[1] == "take":
        for name in take(sys.argv[2], sys.argv[3]):
            print(name)
    else:
        for (color, kind), n in count(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 25):
            print(f"{n:8} {color} {kind}")
