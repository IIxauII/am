#!/bin/bash
# Reports for the "nostore" engine (stock page with cache: 'no-store' on the report fetch), 30 min
# apart like t10/t40 of the others, then a minimize.
ulimit -f 2000000
H=$(cd "$(dirname "$0")" && pwd)
T=${TMP_ROOT:?set TMP_ROOT}
at() { python3 -I -c "
import time,datetime
h,m,s=map(int,'$1'.split(':'))
t=datetime.datetime.now().replace(hour=h,minute=m,second=s,microsecond=0)
time.sleep(max(0,(t-datetime.datetime.now()).total_seconds()))"; }
at 10:21:30
python3 -I "$H/takeall.py" t10 -- $T/mem-nostore
at 10:51:30
python3 -I "$H/takeall.py" t40 -- $T/mem-nostore
python3 -I "$H/takeall.py" t100 -- $T/mem-stock $T/mem-quiet
at 10:52:30
python3 -I "$H/takeall.py" t40min minimize -- $T/mem-nostore
echo "done $(date +%H:%M:%S)"
