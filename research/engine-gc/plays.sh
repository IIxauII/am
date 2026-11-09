#!/bin/bash
# The two playing trials, one after the other (one Apple Music stream at a time), after the
# Widevine engines' t70 reports: stock-wv, then ws-wv, 6 min each at volume 0.
ulimit -f 2000000
export PYTHONDONTWRITEBYTECODE=1
H=$(cd "$(dirname "$0")" && pwd)
python3 -I "$H/at.py" 13:09:00
"$H/play.sh" /private/tmp/egc/mem-wvtest 47950 6
python3 -I "$H/at.py" 13:20:00
"$H/play.sh" /private/tmp/egc/mem-wsw 47951 6
