"""Asks a running Firefox for a memory report through its debug-info FIFO.

usage: python3 -I trigger.py <dumps dir> [memory report | minimize memory report]

The FIFO (<dumps dir>/debug_info_trigger) exists while Firefox runs with
memory_info_dumper.watch_fifo.enabled and .directory set (see launch.sh). The reports land in
MOZ_UPLOAD_DIR (the same dumps dir) as memory-report-*.json.gz, one per process.
"""
import os, sys

d, cmd = sys.argv[1], " ".join(sys.argv[2:]) or "memory report"
fd = os.open(os.path.join(d, "debug_info_trigger"), os.O_WRONLY | os.O_NONBLOCK)  # ENXIO if nobody listens
os.write(fd, (cmd + "\n").encode())
os.close(fd)
print("sent:", cmd)
