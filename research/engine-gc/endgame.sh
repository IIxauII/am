#!/bin/bash
# The rest of the run after schedule.sh's t10 (local wall times): t70 and tend plain reports of
# all instances, then the probes, then a "minimize memory report" of all (tendmin):
#   stock, noaddons: "gc log" = a forced full GC and a CC, no memory-pressure (tendgc report)
#   gclow: "abbreviated gc log" = a CC without a GC (tendcc report)
ulimit -f 2000000
export PYTHONDONTWRITEBYTECODE=1
H=$(cd "$(dirname "$0")" && pwd)
T=${TMP_ROOT:?set TMP_ROOT}
ALL="$T/mem-stock $T/mem-noaddons $T/mem-netproc $T/mem-ws $T/mem-gclow $T/mem-gcbal $T/mem-bare-warm $T/mem-bare-fresh $T/mem-bare-nopush"
python3 -I "$H/at.py" 13:02:00
python3 -I "$H/takeall.py" t70 -- $ALL
python3 -I "$H/at.py" 13:50:00
python3 -I "$H/takeall.py" tend -- $ALL
for n in stock noaddons; do
  echo "gc log $n $(date +%H:%M:%S)"; python3 -I "$H/gcdump.py" take "$T/mem-$n" gc
  python3 -I "$H/takeall.py" tendgc -- "$T/mem-$n"
done
echo "abbreviated gc log gclow $(date +%H:%M:%S)"; python3 -I "$H/gcdump.py" take "$T/mem-gclow" cc
python3 -I "$H/takeall.py" tendcc -- "$T/mem-gclow"
python3 -I "$H/takeall.py" tendmin minimize -- $ALL
echo "done $(date +%H:%M:%S)"
