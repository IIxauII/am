"""Prints each trial in radio.jsonl as rows: step, time, total CPU %, processes, MiB, state, and
the CPU % of the web content process and the Widevine helper (gmplugin)."""
import json, os, sys

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "radio.jsonl")
only = set(sys.argv[2:])
for line in open(path):
    r = json.loads(line)
    if only and r["trial"] not in only:
        continue
    by = r.get("by") or {}
    # The web content process is the tab that works while playing: the busiest tab in this window.
    tabs = sorted(((v[0], k) for k, v in by.items() if k.startswith("tab")), reverse=True)
    if "cpu_pct" in r:
        print(f'{r["trial"]:>4} {r["wall"]} {r["step"]:<7} {str(r.get("at_s", r.get("after_s", ""))):>5}s  '
              f'cpu {r["cpu_pct"]:>5}%  procs {r["procs"]}  {r["footprint_mib"]} MiB  {r.get("state")}  '
              f'tab {tabs[0][0] if tabs else "-"}  gmp {by.get("gmplugin", ["gone"])[0]}  parent {by.get("parent", ["-"])[0]}')
    else:
        extra = {k: r[k] for k in ("to_playing_s", "took_s", "playbackState", "t", "out", "error", "playing") if k in r}
        media = r.get("media") or []
        if media:
            m = media[0]
            extra["media"] = {k: m.get(k) for k in ("inDoc", "paused", "t", "bufEnd", "seekEnd", "readyState", "networkState", "mediaKeys")}
        ev = [e for e in r.get("events") or [] if " exp " in e or "gaveUp" in e or "Error" in e]
        if ev:
            extra["events"] = ev
        print(f'{r["trial"]:>4} {r["wall"]} {r["step"]:<7} {json.dumps(extra, ensure_ascii=False)[:600]}')
