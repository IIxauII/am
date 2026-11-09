#!/bin/bash
# Ran only up to its t10 report (12:02); it was then stopped and endgame.sh did the rest.
# The timed memory reports of the run (local wall times), all instances one after the other:
# t10 and t70 plain reports, tend a plain report, then a "minimize memory report" (tendmin).
# Summaries go to reports.jsonl beside this script; raw reports stay in <engine dir>/dumps/.
ulimit -f 2000000
export PYTHONDONTWRITEBYTECODE=1
H=$(cd "$(dirname "$0")" && pwd)
T=${TMP_ROOT:?set TMP_ROOT}
ALL="$T/mem-stock $T/mem-noaddons $T/mem-netproc $T/mem-ws $T/mem-gclow $T/mem-gcbal $T/mem-bare-warm $T/mem-bare-fresh $T/mem-bare-nopush"
python3 -I "$H/at.py" 12:02:00
python3 -I "$H/takeall.py" t10 -- $ALL
python3 -I "$H/at.py" 13:02:00
python3 -I "$H/takeall.py" t70 -- $ALL
python3 -I "$H/at.py" 13:50:00
python3 -I "$H/takeall.py" tend -- $ALL
python3 -I "$H/takeall.py" tendmin minimize -- $ALL
echo "done $(date +%H:%M:%S)"
