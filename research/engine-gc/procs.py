"""Lists the research engines' processes: pid, ppid, age, type, footprint, and whether --headless.

usage: python3 -I procs.py <substring of the profile paths, e.g. tmp/mem->
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sample import ps, engine_procs, rusage, MIB  # noqa: E402

needle = sys.argv[1]
rows = ps()
profiles = sorted({w for _, (_, cmd) in rows.items() for w in cmd.split() if needle in w and w.endswith("firefox-profile")})
for prof in profiles:
    print(prof)
    for pid, kind in engine_procs(rows, prof):
        ppid, cmd = rows[pid]
        r = rusage(pid) or {"fp": 0}
        print(f"  {pid:>6} ppid {ppid:>6} {kind:<9} {r['fp'] / MIB:7.1f} MiB  headless={'--headless' in cmd}")
