"""Which non-local HTTP requests an engine's parent made, per minute, from its engine.log
(MOZ_LOG nsHttp:1 logs each channel's URI at creation). Query strings are dropped; for Remote
Settings the collection name is kept. Local requests (the daemon, the relay) are counted apart.

usage: python3 -I hosts.py <engine.log> [from HH:MM] [to HH:MM]
"""
import datetime, re, sys
from collections import Counter, defaultdict

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ UTC - \[Parent \d+: Main Thread\]: E/nsHttp uri=(\S+)")
OFFSET = datetime.datetime.now().astimezone().utcoffset()


def short(uri):
    m = re.match(r"(\w+)://([^/?#]+)([^?#]*)", uri)
    if not m:
        return uri[:40]
    scheme, host, path = m.groups()
    if host.startswith("localhost") or host.startswith("127.0.0.1"):
        return "local"
    c = re.search(r"/collections/([^/]+)", path)
    if c:
        return f"{host} {c.group(1)}"
    return f"{host} {'/'.join(path.split('/')[:3])}"


def main():
    lo = sys.argv[2] if len(sys.argv) > 2 else None
    hi = sys.argv[3] if len(sys.argv) > 3 else None
    per = defaultdict(Counter)
    with open(sys.argv[1], "rb") as f:
        for raw in f:
            m = LINE.match(raw.decode("utf-8", "replace"))
            if not m:
                continue
            t = (datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S") + OFFSET).strftime("%H:%M")
            if (lo and t < lo) or (hi and t > hi):
                continue
            per[t][short(m.group(2))] += 1
    for t in sorted(per):
        local = per[t].pop("local", 0)
        rest = ", ".join(f"{k} ×{v}" for k, v in per[t].most_common())
        print(f"{t} local {local:3}  {rest}")


if __name__ == "__main__":
    main()
