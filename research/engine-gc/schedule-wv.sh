#!/bin/bash
# The timed memory reports of the two engines with a working Widevine (config dirs under
# /private/tmp, see README). No minimize here: the playing trial starts from them.
ulimit -f 2000000
export PYTHONDONTWRITEBYTECODE=1
H=$(cd "$(dirname "$0")" && pwd)
WV="/private/tmp/egc/mem-wvtest /private/tmp/egc/mem-wsw"
python3 -I "$H/at.py" 12:07:00
python3 -I "$H/takeall.py" t10 -- $WV
python3 -I "$H/at.py" 13:07:00
python3 -I "$H/takeall.py" t70 -- $WV
python3 -I "$H/at.py" 13:50:00
python3 -I "$H/takeall.py" tend -- $WV
echo "done $(date +%H:%M:%S)"
