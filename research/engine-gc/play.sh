#!/bin/bash
# The playing trial on one engine: report, play the default song at volume 0 on repeat for
# <minutes>, report, stop, then a minimize report.
#   play.sh <engine dir> <port> <minutes>
# The queue sets the volume before play() (QueueRequest.volume), so nothing is audible.
ulimit -f 2000000
export PYTHONDONTWRITEBYTECODE=1
H=$(cd "$(dirname "$0")" && pwd)
d=$1 port=$2 min=$3
echo "preplay $(date +%H:%M:%S)"
python3 -I "$H/takeall.py" preplay -- "$d"
python3 -I "$H/cli.py" "$d" "$port" queue '{"songs":["1561837008"],"repeat":"one","volume":0}'
echo "playing $(date +%H:%M:%S)"
python3 -I "$H/cli.py" "$d" "$port" state '{}' | head -c 600; echo
sleep $((min * 60))
python3 -I "$H/cli.py" "$d" "$port" state '{}' | head -c 600; echo
python3 -I "$H/takeall.py" play -- "$d"
python3 -I "$H/cli.py" "$d" "$port" control '{"action":"stop"}'
echo "stopped $(date +%H:%M:%S)"
python3 -I "$H/takeall.py" playmin minimize -- "$d"
echo "done $(date +%H:%M:%S)"
