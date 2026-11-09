#!/bin/bash
# The last steps of the run, at fixed wall times: plain reports, the reload, then
# "minimize memory report" (GC/CC, heap-minimize, free dirty pages, then report).
ulimit -f 2000000
H=$(cd "$(dirname "$0")" && pwd)
T=${TMP_ROOT:?set TMP_ROOT}
at() { python3 -I -c "
import time,datetime
h,m,s=map(int,'$1'.split(':'))
t=datetime.datetime.now().replace(hour=h,minute=m,second=s,microsecond=0)
time.sleep(max(0,(t-datetime.datetime.now()).total_seconds()))"; }
at 10:28:48
python3 -I "$H/takeall.py" t70 -- $T/mem-stock $T/mem-quiet $T/mem-noka $T/mem-bare $T/mem-reload
at 10:29:30
echo "reload $(date +%H:%M:%S)"; python3 -I "$H/reload.py" $T/mem-reload 47914
at 10:31:00
python3 -I "$H/takeall.py" t70min minimize -- $T/mem-stock $T/mem-quiet $T/mem-noka $T/mem-bare
at 10:33:30
python3 -I "$H/takeall.py" postreload -- $T/mem-reload
at 10:34:00
python3 -I "$H/takeall.py" postreload-min minimize -- $T/mem-reload
echo "done $(date +%H:%M:%S)"
