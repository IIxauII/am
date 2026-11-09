"""Per-process memory sampler for the research engines (one JSON line per engine per sample).

usage: python3 -I sample.py <out.jsonl> <minutes> <every_s> name=profile_path [name=profile_path ...]

Each engine is every process whose command line holds its profile path, plus their descendants.
Per process: Firefox's child type from the command line (last word: tab, rdd, utility, gmplugin,
socket; none for the parent), macOS phys_footprint and resident size, CPU seconds and wake-ups,
from proc_pid_rusage (the method of the earlier warm-engine measurement). Also the OS memory
pressure level (kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical).
Stops early when <out.jsonl>.stop exists.
"""
import ctypes, ctypes.util, json, os, subprocess, sys, time, datetime

libc = ctypes.CDLL(ctypes.util.find_library("c"))
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


class RUsageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64),
                ("pkg_idle_wkups", ctypes.c_uint64), ("interrupt_wkups", ctypes.c_uint64), ("pageins", ctypes.c_uint64),
                ("wired_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64), ("phys_footprint", ctypes.c_uint64),
                ("proc_start_abstime", ctypes.c_uint64), ("proc_exit_abstime", ctypes.c_uint64),
                ("child_user_time", ctypes.c_uint64), ("child_system_time", ctypes.c_uint64),
                ("child_pkg_idle_wkups", ctypes.c_uint64), ("child_interrupt_wkups", ctypes.c_uint64),
                ("child_pageins", ctypes.c_uint64), ("child_elapsed_abstime", ctypes.c_uint64),
                ("diskio_bytesread", ctypes.c_uint64), ("diskio_byteswritten", ctypes.c_uint64)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = Timebase()
libc.mach_timebase_info(ctypes.byref(_tb))
TICK_NS = _tb.numer / _tb.denom
MIB = 2 ** 20


def rusage(pid):
    ru = RUsageV2()
    if libproc.proc_pid_rusage(int(pid), 2, ctypes.byref(ru)) != 0:
        return None
    return {"fp": ru.phys_footprint, "rss": ru.resident_size,
            "cpu_s": (ru.user_time + ru.system_time) * TICK_NS / 1e9,
            "wk": ru.pkg_idle_wkups + ru.interrupt_wkups}


def ps():
    out = subprocess.run(["ps", "-A", "-ww", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            rows[int(parts[0])] = (int(parts[1]), parts[2])
    return rows


CHILD_TYPES = ("tab", "rdd", "utility", "gmplugin", "socket", "gpu", "forkserver")


def engine_procs(rows, profile):
    # Firefox itself (argv[0] .../firefox) on this profile, not a shell whose line names the path.
    roots = {pid for pid, (_, cmd) in rows.items() if profile in cmd and cmd.split()[0].endswith("/firefox")}
    kids = {}
    for pid, (ppid, _) in rows.items():
        kids.setdefault(ppid, []).append(pid)
    seen, stack = set(), list(roots)
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        stack.extend(kids.get(p, []))
    out = []
    for pid in sorted(seen):
        cmd = rows[pid][1]
        last = cmd.split()[-1] if cmd.split() else ""
        kind = last if last in CHILD_TYPES else ("parent" if "plugin-container" not in cmd else "child")
        out.append((pid, kind))
    return out


def pressure():
    try:
        return int(subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True).stdout)
    except ValueError:
        return None


def main():
    out, minutes, every = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    engines = dict(a.split("=", 1) for a in sys.argv[4:])
    t0 = time.time()
    while time.time() - t0 < minutes * 60 and not os.path.exists(out + ".stop"):
        rows = ps()
        lvl = pressure()
        lines = []
        for name, profile in engines.items():
            procs = []
            for pid, kind in engine_procs(rows, profile):
                r = rusage(pid)
                if r:
                    procs.append({"pid": pid, "type": kind, "fp_mib": round(r["fp"] / MIB, 2),
                                  "rss_mib": round(r["rss"] / MIB, 1), "cpu_s": round(r["cpu_s"], 2), "wk": r["wk"]})
            lines.append({"t": round(time.time(), 1), "wall": datetime.datetime.now().strftime("%H:%M:%S"),
                          "engine": name, "pressure": lvl, "n": len(procs),
                          "total_mib": round(sum(p["fp_mib"] for p in procs), 2), "procs": procs})
        with open(out, "a") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")
        time.sleep(max(1.0, every - (time.time() - t0) % every))


if __name__ == "__main__":
    main()
