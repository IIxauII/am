"""Radio stop spin harness (wayfinder ticket #16). macOS only, stdlib only.

Drives an isolated am (its own AM_CONFIG_DIR and AM_PORT, idle close off) through a list of steps
given on the command line, and samples every engine process with proc_pid_rusage (CPU time,
wake-ups, phys_footprint), keyed by the child type Firefox puts on each command line. One JSON
line per sample or step goes to radio.jsonl beside this file.

    python3 -I rs.py <trial> <step> [<step> ...]

Steps:
    fresh              stop this harness's daemon (and engine) if up, start a new one
    doctor             am doctor (starts the engine; a new profile downloads Widevine)
    station:<id>       queue live radio at volume 0 (the TUI's queue endpoint), wait until it plays
    song:<id>          queue one song at volume 0, wait until it plays
    songat:<id>@<s>    the same, starting <s> seconds in
    sample:<secs>      sample every 60 s for <secs> (10 s windows), e.g. while playing
    watch:<secs>       sample at 10, 30, 60 s and then every 60 s until <secs> after the last action
    cli:<cmd>          run `am <cmd>` (stop, pause, resume, status)
    ctl:<action>       the TUI's control endpoint: stop, pause, toggle, play
    ctlv:<action>=<v>  the same with a JSON value, e.g. ctlv:autoplay=false
    exp:<code>         the throwaway experiment hook in poc/web/app.js (setVolume(code / 10000))
    state              log the engine page's state
    sleep:<secs>
    daemon-stop        am daemon stop, then check no engine process survives
"""
import ctypes, ctypes.util, json, os, re, subprocess, sys, time, urllib.request, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
WORKTREE = os.path.dirname(os.path.dirname(HERE))
AM = os.path.join(WORKTREE, "zig-out", "bin", "am")
# A config dir of its own (never ~/.config/am), holding developer-token.jwt, music-user-token
# and env (symlinks work).
CFG = os.environ["RS_CONFIG_DIR"]
PORT = int(os.environ.get("RS_PORT", "47871"))
PROFILE = os.path.join(CFG, "firefox-profile")
OUT = os.path.join(HERE, "radio.jsonl")
ENV = dict(os.environ, AM_CONFIG_DIR=CFG, AM_PORT=str(PORT), ENGINE_IDLE_MINUTES="100000")
# The runs used a private APFS clone of /Applications/Firefox.app (cp -Rc) with app updates off:
# the shared install had a pending self-update that relaunched Firefox outside the daemon.
if os.environ.get("RS_FIREFOX"):
    ENV["FIREFOX_PATH"] = os.environ["RS_FIREFOX"]

trial = sys.argv[1] if len(sys.argv) > 1 else "?"
t_action = time.monotonic()


def log(r):
    r = {"trial": trial, "wall": datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%SZ"), **r}
    line = json.dumps(r, separators=(",", ":"))
    line = re.sub(r"storefront([ =])[a-z]{2}\b", r"storefront\1xx", line)  # no location in the data
    print(line, flush=True)
    with open(OUT, "a") as f:
        f.write(line + "\n")


# ---- daemon ----

def secret():
    with open(os.path.join(CFG, "daemon-secret")) as f:
        return f.read().strip()


def call(endpoint, body=None, timeout=130):
    req = urllib.request.Request(f"http://localhost:{PORT}/cli/{endpoint}", data=json.dumps(body or {}).encode(),
                                 headers={"X-AM-Secret": secret(), "Content-Type": "application/json"}, method="POST")
    lines = []
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            raw = raw.strip()
            if raw:
                lines.append(json.loads(raw))
    return lines


def daemon_up():
    try:
        call("ping", timeout=2)
        return True
    except Exception:
        return False


def am(*args, timeout=180):
    p = subprocess.run([AM, *args], capture_output=True, text=True, env=ENV, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def state():
    for l in call("state", timeout=10):
        if "data" in l:
            return l["data"]
    return None


def summary(st):
    """What a state says, without tokens, hashes or the radio's song metadata."""
    st = st or {}
    rep = st.get("report") or {}
    np_ = rep.get("nowPlaying") or {}
    ev = [e for e in rep.get("lastEvents") or [] if e.get("type") not in ("timedMetadata",)]
    return {
        "engine_pid": (st.get("engine") or {}).get("pid"),
        "load": rep.get("load"),
        "playbackState": rep.get("playbackState"),
        "t": rep.get("currentPlaybackTime"),
        "item": {k: np_.get(k) for k in ("id", "isLive", "playbackType")} if np_ else None,
        "stoppedLive": (rep.get("stoppedLive") or {}).get("id"),
        "media": rep.get("expMedia"),
        "events": [f"{e.get('t')} {e.get('type')} {(e.get('detail') or '')[:300]}" for e in ev[-6:]],
    }


def wait_playing(timeout=90):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            rep = (state() or {}).get("report") or {}
        except Exception:
            rep = {}
        if rep.get("playbackState") == "playing" and (rep.get("nowPlaying") or {}).get("playbackType"):
            return True
        time.sleep(0.2)
    return False


# ---- processes (macOS proc_pid_rusage) ----

libc = ctypes.CDLL(ctypes.util.find_library("c"))


class RUsageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64),
                ("pkg_idle_wkups", ctypes.c_uint64), ("interrupt_wkups", ctypes.c_uint64), ("pageins", ctypes.c_uint64),
                ("wired_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64), ("phys_footprint", ctypes.c_uint64),
                ("proc_start_abstime", ctypes.c_uint64), ("proc_exit_abstime", ctypes.c_uint64),
                ("child_user_time", ctypes.c_uint64), ("child_system_time", ctypes.c_uint64),
                ("child_pkg_idle_wkups", ctypes.c_uint64), ("child_interrupt_wkups", ctypes.c_uint64),
                ("child_pageins", ctypes.c_uint64), ("child_elapsed_abstime", ctypes.c_uint64),
                ("diskio_bytesread", ctypes.c_uint64), ("diskio_byteswritten", ctypes.c_uint64)]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = Timebase()
libc.mach_timebase_info(ctypes.byref(_tb))
TICK_NS = _tb.numer / _tb.denom


def rusage(pid):
    ru = RUsageV2()
    if libproc.proc_pid_rusage(int(pid), 2, ctypes.byref(ru)) != 0:
        return None
    return {"cpu_ns": (ru.user_time + ru.system_time) * TICK_NS, "footprint": ru.phys_footprint,
            "wakeups": ru.pkg_idle_wkups + ru.interrupt_wkups}


KINDS = ("tab", "rdd", "socket", "utility", "gmplugin", "gpu")


def engine_procs():
    """{pid: kind} for every process of this harness's engine: the Firefox started with our
    profile, and its descendants. Kind is the child type Firefox puts on the command line."""
    out = subprocess.run(["ps", "-A", "-ww", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows[int(parts[0])] = (int(parts[1]), parts[2])
    # The Widevine helper's command line names the profile too (its plugin path), so the parent
    # is the one with our profile whose own parent doesn't have it.
    mine = {p for p, (_, cmd) in rows.items() if PROFILE in cmd}
    roots = [p for p in mine if rows[p][0] not in mine and "--profile" in rows[p][1]]
    kids = {}
    for p, (pp, _) in rows.items():
        kids.setdefault(pp, []).append(p)
    procs, stack = {}, list(roots)
    while stack:
        p = stack.pop()
        if p in procs:
            continue
        cmd = rows[p][1]
        kind = "parent" if p in roots else next((t for t in reversed(cmd.split()) if t in KINDS), "other")
        procs[p] = kind
        stack.extend(kids.get(p, []))
    return procs


def window(seconds=10):
    procs = engine_procs()
    a = {p: r for p in procs if (r := rusage(p))}
    t = time.monotonic()
    time.sleep(seconds)
    procs_b = engine_procs()
    b = {p: r for p in procs_b if (r := rusage(p))}
    el = time.monotonic() - t
    by = {}
    for p, r in b.items():
        kind = procs_b[p]
        cpu = (r["cpu_ns"] - a[p]["cpu_ns"]) / (el * 1e9) * 100 if p in a else 0.0
        wk = (r["wakeups"] - a[p]["wakeups"]) / el if p in a else 0.0
        key = kind if kind in ("parent", "gmplugin", "rdd") else f"{kind}{p}"
        if key in by:
            key = f"{kind}{p}"
        by[key] = [round(cpu, 1), round(wk, 1), round(r["footprint"] / 2**20)]
    tot_cpu = round(sum(v[0] for v in by.values()), 1)
    return {"procs": len(b), "cpu_pct": tot_cpu, "wakeups_per_s": round(sum(v[1] for v in by.values()), 1),
            "footprint_mib": round(sum(v[2] for v in by.values())),
            "by": by, "spin": tot_cpu > 40}


# ---- steps ----

def step_fresh():
    if daemon_up():
        log({"step": "fresh", "daemon_stop": am("daemon", "stop", timeout=90)})
    for _ in range(300):
        if not daemon_up() and not engine_procs():
            break
        time.sleep(0.2)
    left = engine_procs()
    if left:
        log({"step": "fresh", "error": f"engine processes left: {left}"})
        sys.exit(1)
    logf = open(os.path.join(CFG, "daemon-stdout.log"), "a")
    subprocess.Popen([AM, "daemon"], stdin=subprocess.DEVNULL, stdout=logf, stderr=logf, env=ENV, start_new_session=True)
    for _ in range(100):
        if daemon_up():
            break
        time.sleep(0.1)
    log({"step": "fresh", "daemon_up": daemon_up()})


def step_queue(body, what):
    global t_action
    t0 = time.monotonic()
    try:
        res = call("queue", {**body, "volume": 0}, timeout=180)
    except Exception as ex:
        log({"step": what, "error": f"queue: {ex}"})
        sys.exit(1)
    ok = wait_playing()
    t_action = time.monotonic()
    log({"step": what, "playing": ok, "to_playing_s": round(time.monotonic() - t0, 2),
         "reply": [l for l in res if "exit" in l or "err" in l][-2:], **summary(state())})
    if not ok:
        sys.exit(1)


def step_sample(secs):
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs - 1:
        log({"step": "sample", "at_s": round(time.monotonic() - t_action), **window(10), "state": summary(state())["playbackState"]})
        rest = 60 - ((time.monotonic() - t0) % 60)
        if time.monotonic() - t0 + rest >= secs:
            break
        time.sleep(rest)
    time.sleep(max(0, secs - (time.monotonic() - t0)))


def step_watch(secs):
    marks = [10, 30, 60] + list(range(120, secs + 1, 60))
    for m in marks:
        if m > secs:
            break
        time.sleep(max(0, m - (time.monotonic() - t_action)))
        s = state()
        log({"step": "watch", "after_s": m, **window(10), "state": summary(s)["playbackState"],
             "media": summary(s)["media"]})


def act(name, fn):
    global t_action
    t0 = time.monotonic()
    out = fn()
    t_action = time.monotonic()
    time.sleep(2)
    log({"step": name, "took_s": round(t_action - t0, 2), "out": out, **summary(state())})


def main():
    for s in sys.argv[2:]:
        kind, _, arg = s.partition(":")
        if kind == "fresh":
            step_fresh()
        elif kind == "doctor":
            t0 = time.monotonic()
            code, out = am("doctor", timeout=400)
            log({"step": "doctor", "exit": code, "took_s": round(time.monotonic() - t0, 1),
                 "out": [l for l in out.splitlines() if "token" not in l.lower()][:40]})
        elif kind == "station":
            step_queue({"station": arg}, s)
        elif kind == "song":
            step_queue({"songs": [arg]}, s)
        elif kind == "songat":  # songat:<id>@<start seconds>, autoplay off: it ends on its own
            sid, _, at = arg.partition("@")
            step_queue({"songs": [sid], "startTime": float(at)}, s)
        elif kind == "sample":
            step_sample(int(arg))
        elif kind == "watch":
            step_watch(int(arg))
        elif kind == "cli":
            act(s, lambda: am(*arg.split()))
        elif kind == "ctl":
            act(s, lambda: [l for l in call("control", {"action": arg}) if "exit" in l or "err" in l][-2:])
        elif kind == "ctlv":  # ctlv:<action>=<JSON value>, e.g. ctlv:autoplay=false
            name, _, value = arg.partition("=")
            act(s, lambda: [l for l in call("control", {"action": name, "value": json.loads(value)}) if "exit" in l or "err" in l][-2:])
        elif kind == "exp":
            act(s, lambda: [l for l in call("control", {"action": "volume", "value": int(arg) / 10000}) if "exit" in l or "err" in l][-2:])
        elif kind == "state":
            log({"step": "state", **summary(state())})
        elif kind == "sleep":
            time.sleep(float(arg))
        elif kind == "daemon-stop":
            log({"step": "daemon-stop", "out": am("daemon", "stop", timeout=90)})
            for _ in range(150):
                if not engine_procs():
                    break
                time.sleep(0.2)
            log({"step": "daemon-stop", "left": engine_procs(), "daemon_up": daemon_up()})
        else:
            log({"step": s, "error": "unknown step"})
            sys.exit(2)


main()
