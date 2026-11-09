# Why does Firefox never free an idle engine's garbage, and what would?

Throwaway research branch, never merged. It answers
[Why does Firefox never free an idle engine's garbage, and what would?](https://github.com/IIxauII/am/issues/19);
the answer for that issue is [RESOLUTION.md](RESOLUTION.md). This page holds the method, the numbers and the files.
It builds on [Why does an idle engine's memory keep growing?](https://github.com/IIxauII/am/issues/15) and its
branch `research/engine-memory-growth`, whose scripts it reuses.

Measured 2026-11-09, 11:33–13:58 local time, on an Apple M4 (16 GiB, macOS 26.2) with Firefox 159.0.1 and `am`
built from `main` at 31a0ddf (`zig build -Doptimize=ReleaseSafe`). The OS memory pressure level was 2 ("warn") in
every sample. Every claim is marked *measured*, *source* (Firefox at tag `FIREFOX_159_0_1_RELEASE`) or *inferred*.
The source reading is in [source-gc.md](source-gc.md) (GC/CC scheduling, logging, prefs) and
[source-net.md](source-net.md) (webRequest, add-ons, network process, WebSocket, Remote Settings, cache).

## Setup

Eleven Firefox instances ran side by side from a private APFS clone of `/Applications/Firefox.app` with
`distribution/policies.json` = `{"policies": {"DisableAppUpdate": true}}`. Each engine had its own `AM_CONFIG_DIR`
(token and env files symlinked from the real config; am replaces files by rename, so the real ones were never
written), its own `AM_PORT`, `ENGINE_IDLE_MINUTES=100000` (keep-alive simulated) and was started with `am doctor`.
`FIREFOX_PATH` was [ffwrap.sh](ffwrap.sh), which appends the instance's extra prefs to the `user.js` am writes, so
am's code and prefs stayed as on `main`.

"Warm" profiles are clones of one profile that ran as an engine for 12 min first (Widevine, `musickit.js` cache,
Remote Settings data), minus its push UAID; that is closer to am's persistent profile. "Fresh" is an empty profile.

| Name | Page | Profile | Extra prefs |
|---|---|---|---|
| stock | `poc/web/app.js` as on `main` | warm | none |
| noaddons | stock | warm, add-on cache dropped | `extensions.webcompat.enabled`, `extensions.addons-search-detection.enabled`, `extensions.ipp-activator.enabled` = false ([noaddons.prefs](noaddons.prefs)); `extensions.json` showed all three inactive |
| netproc | stock | warm | `network.process.enabled` and `network.http.network_access_on_socket_process.enabled` = true ([netproc.prefs](netproc.prefs)); HTTP transactions ran in the socket process |
| ws | reports over one WebSocket ([app-ws.patch](app-ws.patch)) to a throwaway relay ([wsrelay.py](wsrelay.py)) that POSTs each one to the daemon's `/report`, so the daemon works as with the stock page | warm | none |
| gclow | stock | warm | `javascript.options.mem.gc_low_frequency_heap_growth=118`, `gc_allocation_threshold_mb=1`, `gc_malloc_threshold_base_mb=1` ([gclow.prefs](gclow.prefs)) |
| gcbal | stock | warm | `javascript.options.mem.gc_balanced_heap_limits=true` ([gcbal.prefs](gcbal.prefs)) |
| bare-warm | none: same Firefox, flags, env and `user.js` on `about:blank` ([launch-bare.sh](launch-bare.sh)) | warm | none |
| bare-fresh | none | fresh | none |
| bare-nopush | none | fresh | `dom.push.connection.enabled=false` ([nopush.prefs](nopush.prefs)) |
| stock-wv (`wvtest`) | stock | warm, config under `/private/tmp` | none |
| ws-wv (`wsw`) | ws | warm, config under `/private/tmp` | none |

Widevine failed (`NS_ERROR_FAILURE`, "GetContentParent rejects") in the nine instances whose config dir was under
`/tmp`, a symlink to `/private/tmp`; with the real path it worked (`am doctor` ✔). *Measured.* The GMP sandbox
likely rejects the symlinked profile path (*inferred*). So those nine lack the two utility processes (~31 MiB);
the earlier research found those flat. stock-wv and ws-wv, started 13 min later, are the same as stock and ws with
a working Widevine, and they ran the playing trial.

Logging, in every instance (*source*: [Statistics.cpp#L110-L142](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L110-L142), [#L815-L821](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L815-L821), [nsJSEnvironment.cpp#L1030-L1036](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1030-L1036), [#L1496-L1509](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1496-L1509), [nsConsoleService.cpp#L378-L404](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsConsoleService.cpp#L378-L404), [HttpBaseChannel.cpp#L366](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/HttpBaseChannel.cpp#L366)):

- `javascript.options.mem.log=true` with `MOZ_LOG=timestamp,PageMessages:5`: one line per GC (reason of slice 0,
  heap size after) and per CC (suspected, freed), with process and pid, on the engine's stderr (`engine.log`).
  [gclog.py](gclog.py) parses them → [gc-events.jsonl](gc-events.jsonl).
- `JS_GC_PROFILE=0` and `MOZ_GCTIMER=stderr`: per-slice lines and per-GC blocks with the trigger and threshold.
  Only `stderr` is safe: a file path crashes a sandboxed content process (*source*).
- `nsHttp:1` in the same `MOZ_LOG`: each HTTP channel's URI. [hosts.py](hosts.py) → [hosts.txt](hosts.txt)
  (hosts and Remote Settings collections per minute; no query strings).
- `services.settings.loglevel`, `dom.push.loglevel` = debug and `devtools.console.stdout.chrome`: push broadcasts.

Measurements:

- [sample.py](sample.py): each process's `phys_footprint`, CPU and wake-ups every 60 s → [soak.jsonl](soak.jsonl),
  [soak-wv.jsonl](soak-wv.jsonl). [analyze.py](analyze.py) gives slope, CPU and wake-ups per window.
- [takeall.py](takeall.py) / [memreport.py](memreport.py): Firefox memory reports through the debug FIFO, as in the
  earlier research → [reports.jsonl](reports.jsonl) (totals and top paths per process). Labels: t10 (12:02), t70
  (13:02), tend (13:50), tendmin (minimize, 13:50:38); for the two `-wv` engines t10 12:07, t70 13:07, tend 13:50.
  [deltas.py](deltas.py) diffs two labels; [classes.py](classes.py) diffs raw reports by JS class and path.
  Raw reports, logs and GC/CC edge logs stayed out of the repo (they can hold page strings and tokens).
- Each report purges freed pages first, so the footprint it measures is comparable between reports. The
  per-minute footprint right after a report or a GC rises while freed pages get reused, so growth rates below come
  from the reports, not from the samples.
- Probes at tend ([endgame.sh](endgame.sh), [gcdump.py](gcdump.py)): the FIFO's `gc log` runs an all-traces CC,
  which forces a full non-shrinking GC first and sends no memory-pressure
  ([nsCycleCollector.cpp#L3538-L3573](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsCycleCollector.cpp#L3538-L3573),
  [nsMemoryInfoDumper.cpp#L189](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsMemoryInfoDumper.cpp#L189));
  `abbreviated gc log` runs a CC without a GC while gray bits are valid. Each probe was followed by a report, then a
  minimize report.
- Playing trial ([plays.sh](plays.sh), [play.sh](play.sh), [cli.py](cli.py)): on stock-wv (13:09–13:15), then
  ws-wv (13:20–13:26), one at a time: report, queue song 1561837008 on repeat with `"volume": 0` (set before
  `play()`), 6 min, report, stop, minimize report. The report showed `playing`, `encryptedFull`, volume 0.

## Results

### Growth with no GC in the window (t10 → t70, 1.00 h, MiB/h, from the reports)

| Engine | all processes | parent | parent heap-unclassified | web content | CPU, wake-ups (12:10–13:00) |
|---|---|---|---|---|---|
| stock | +132.3 | +118.8 | +60.5 | +13.5 | 0.49 %, 6.0/s |
| stock-wv | +129.9 | +115.3 | +61.5 | +14.5 | 0.45 %, 7.0/s |
| noaddons | +130.9 | +116.5 | +61.2 | +14.4 | 0.48 %, 6.3/s |
| netproc | +128.8 | +114.0 | +61.1 | +14.5 | 0.57 %, 7.2/s |
| ws | +55.4 | +51.6 | +9.5 | +3.9 | 0.15 %, 3.8/s |
| ws-wv | +56.9 | +52.6 | +8.8 | +4.2 | 0.15 %, 4.4/s |
| gclow¹ | +45.2 | +36.6 | +13.2 | +8.7 | 0.52 %, 6.9/s |
| gcbal¹ | +59.8 | +45.4 | +13.3 | +14.4 | 0.50 %, 6.1/s |
| bare-warm | +53.6 | +53.6 | +10.4 | 0.0 | 0.05 %, 0.2/s |
| bare-fresh | +9.4 | +9.5 | +6.2 | 0.0 | 0.03 %, 0.1/s |
| bare-nopush | +6.8 | +6.8 | +5.1 | 0.0 | 0.02 %, 0.1/s |

¹ These two GC'd inside the window (below). *Measured.* Over the whole run (t10 → tend, 1.8 h, one
Firefox-triggered GC each): stock +70.7, noaddons +63.4, netproc +61.9, ws +31.2, gclow +38.4, gcbal +77.0,
bare-warm +28.2, bare-fresh +5.4, bare-nopush +3.0 MiB/h.

- **am's share** is stock − ws: about 77 MiB/h, 19 KiB in the parent and 3 KiB in the web process per report
  (3,600 an hour). ws is within 2 MiB/h of bare-warm, so one WebSocket removes it. *Measured.*
- The 54 MiB/h of bare-warm (and so of every warm instance) in this hour is Firefox's own: an 18.5 MiB
  `ArrayBuffer`, 9 MiB of strings and 7 MiB of objects in the parent's privileged JS (see Firefox's own share).
  *Measured.*

### GCs in the parent (from gc-events.jsonl)

Every parent but netproc's GC'd at startup, and every parent once more about 5 min 5 s after start (`USER_INACTIVE`, then `CC_FINISHED` and
`FULL_GC_TIMER`), and then not again until:

| Engine | next parent GC after the 5-min one |
|---|---|
| stock | 13:02 `TOO_MUCH_MALLOC` (74 min later) |
| stock-wv | none until the playing trial's minimize at 13:15 (73 min); next 13:56 `TOO_MUCH_MALLOC` |
| noaddons, netproc | 13:10 `TOO_MUCH_MALLOC` |
| ws, bare-warm | 13:05 `TOO_MUCH_MALLOC` |
| ws-wv | 13:16 `TOO_MUCH_MALLOC` |
| gclow | 12:48, 12:50, 12:55 `TOO_MUCH_MALLOC`, then CC_FINISHED/FULL_GC_TIMER until 12:57; 13:10 |
| gcbal | 12:55 `ALLOC_TRIGGER` and its chain |
| bare-fresh, bare-nopush | none from 11:50 to 13:50 |

*Measured.* In between, the parent CC'd every ~2 min (the `TIMED` reason: more than 10 suspected objects and 2 min
since the last CC) and freed a few dozen objects each time. Each malloc-triggered GC came after Firefox's own
Remote Settings work had left multi-MiB `ArrayBuffer`s, which count as JS malloc. A parent GC chain (malloc
trigger, 2 × `CC_FINISHED`, `FULL_GC_TIMER`) took about 130 ms (stock, 13:02). *Measured.* Why nothing else
fires, from source: [source-gc.md §5](source-gc.md#5-why-the-idle-parent-never-gcs).

### What frees it (MiB)

| Engine, step | all processes | parent heap-allocated | parent heap-unclassified | web heap-allocated |
|---|---|---|---|---|
| stock, tend | 492.4 | 364.1 | 111.4 | 33.8 |
| stock, after GC+CC (`gc log`) | 443.4 | 293.7 | 77.6 | 9.4 |
| stock, then minimize | 347.2 | 177.0 | 76.3 | 8.0 |
| noaddons, tend | 455.1 | 336.3 | 101.8 | 31.6 |
| noaddons, after GC+CC | 426.5 | 289.2 | 74.0 | 8.8 |
| noaddons, then minimize | 334.5 | 173.5 | 73.0 | 7.3 |
| gclow, tend | 416.7 | 306.6 | 91.0 | 25.7 |
| gclow, after a CC alone | 417.9 | 307.6 | 91.9 | 25.7 |
| gclow, then minimize | 333.7 | 175.7 | 75.4 | 7.6 |

- A GC plus a CC, with no memory-pressure, frees am's garbage in both processes. A CC alone frees nothing.
  *Measured.* The minimize after it frees ~115 MiB more in the parent, but not heap-unclassified: that is the
  software WebRender buffers (`gfx/webrender/swgl`, ~99 MiB) and caches that only memory-pressure drops (earlier
  research).
- In stock's parent the GC freed: heap-unclassified −33.8 MiB, `ArrayBuffer` −33.4 (Firefox's own),
  `ChannelWrapper` −0.76 MiB to 0, `XPCWrappedNative_NoHelper` −0.49 MiB to 0.02, `xpconnect/scopes` −1.05.
  In the web process: heap-unclassified −18.9, `Iterator` −3.6, `SavedFrame` −0.6, `Response` −0.3,
  `jit-lazylink` −2.1. *Measured* ([classes.py](classes.py) on the raw reports).
- Between t10 and t70, stock's parent grew `ChannelWrapper` +0.97 and `XPCWrappedNative_NoHelper` +0.70 MiB, and
  noaddons' +0.97 and +0.47: the add-ons were off, the wrappers were not. ws grew neither. *Measured.* The other
  per-channel JS observer is `SearchSERPTelemetry`, which BrowserGlue starts for every window and which calls
  `ChannelWrapper.get()` on every `http-on-examine-response`
  ([BrowserGlue.sys.mjs#L833](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/BrowserGlue.sys.mjs#L833),
  [SearchSERPTelemetry.sys.mjs#L1537-L1538](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/search/SearchSERPTelemetry.sys.mjs#L1537-L1538),
  [#L1559-L1583](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/search/SearchSERPTelemetry.sys.mjs#L1559-L1583)).
  No pref gates it there (*source*, `init()` has no check).

### Firefox's own share

- Steps, from hosts.txt and the memory reports (*measured*):
  - About 60 min after each start (12:42 in stock, 12:44 in the bare ones, push off included): a Remote Settings
    `changes` poll and a fetch of the `bounce-tracking-protection-exceptions` collection. In the warm profiles it
    also downloaded the startup bundle `startup.json.mozlz4` and was followed by the parent's step (bare-warm
    +12.5 MiB at 12:45).
  - A push broadcast for a new Remote Settings version (published 12:35:37) reached the warm instances; they synced
    `url-classifier-exceptions` at 12:54–12:57, followed by bare-warm's +42 MiB step at 12:55. Another broadcast
    (13:37) reached stock.
  - bare-fresh and bare-nopush grew 5–9 MiB/h: they had synced everything at start (11:44–11:45: tracking
    protection lists, 46 CRLite files, search icons), and bare-fresh logged no broadcast after its first one.
- That the hour-after-start task is per profile and the broadcast is what lines instances up in the same
  wall-clock minute (as in the earlier research) is *inferred* from these times. Which code path reads the bundle
  into the 18.5 MiB `ArrayBuffer` is not traced (*inferred*: Remote Settings; CRLite also reads its whole filter
  into a JS array after every poll, [source-net.md §5](source-net.md#5-remote-settings-push-and-timers)).
- This garbage is JS-visible, so it ends in its own GC: bare-warm grew +53.6 MiB/h from t10 to t70, GC'd at
  13:05 and changed −3.6 MiB/h from t70 to tend. *Measured.*
- `dom.push.connection.enabled=false` stopped broadcasts only; the hour-after-start poll still ran. *Measured.*
  It delays Remote Settings, CRLite and intermediate-certificate updates included, to the 24 h poll; Widevine
  updates don't use Remote Settings. *Source* ([source-net.md §5](source-net.md#5-remote-settings-push-and-timers)).

### Playing (6 min each, volume 0)

| Engine | before | after 6 min | parent | web | after minimize |
|---|---|---|---|---|---|
| stock-wv | 547.3 | 600.6 (+53.3) | +10.6 | +41.8 | 429.9 |
| ws-wv | 430.1 | 475.1 (+45.0) | +3.3 | +40.7 | 401.2 |

- No major GC in any process during either trial. *Measured.*
- The parent's growth while playing is about 105 MiB/h with the 1 s report and 33 MiB/h over the WebSocket; the rest
  comes from the song's segment, play and activity requests (about 0.3 a second, hosts.txt). *Measured*; that
  these leave the same pinned-channel garbage is *inferred*.
- The web process gained +26.3 MiB of `ArrayBuffer` (segment data), +10.2 MiB `media/resources` and +4.5 MiB
  heap-unclassified in stock-wv; a minimize freed it. *Measured.* `ArrayBuffer`s count as JS malloc, so the content
  process should GC once they pass about 57 MiB, about 13 min into playing. *Inferred* from the trigger in
  [source-gc.md §1](source-gc.md); trials were limited to a few minutes.

## Deviations and caveats

- The `-wv` engines and nine `/tmp` engines differ only in Widevine and the two utility processes (see Setup).
- netproc's parent logged no GC before its `USER_INACTIVE` one, 5 min after start; the other engines' parents
  GC'd at load. Its growth and later GCs look like stock's. *Measured*; the cause is not known.
- The first launch script was stopped by a tool timeout, which also killed the first `ws` daemon and relay; both
  were restarted at 11:44–11:47 (ws reported from 11:48). Reports at t10 and later are unaffected.
- Footprint per minute right after a report or GC is not growth (freed pages get reused first); use the reports.
- One run, about 2 h. Beyond 2 h idle and 6 min playing is *inferred*.

## Files

- Launch: [launch.sh](launch.sh), [launch-bare.sh](launch-bare.sh), [ffwrap.sh](ffwrap.sh), [user.js](user.js)
  (am's engine prefs), [log.prefs](log.prefs) and the `*.prefs` variants, [app-ws.patch](app-ws.patch),
  [wsrelay.py](wsrelay.py) → [relay-ws.jsonl](relay-ws.jsonl), [relay-ws-wv.jsonl](relay-ws-wv.jsonl) (messages
  relayed per minute).
- Schedules: [schedule.sh](schedule.sh) (t10), [endgame.sh](endgame.sh), [schedule-wv.sh](schedule-wv.sh),
  [plays.sh](plays.sh), [play.sh](play.sh), [at.py](at.py), [cli.py](cli.py).
- Measurement and analysis: [sample.py](sample.py), [analyze.py](analyze.py), [slopes.py](slopes.py),
  [procs.py](procs.py), [memreport.py](memreport.py), [takeall.py](takeall.py), [trigger.py](trigger.py),
  [deltas.py](deltas.py), [classes.py](classes.py), [gclog.py](gclog.py), [gcdump.py](gcdump.py),
  [hosts.py](hosts.py).
- Data: [soak.jsonl](soak.jsonl), [soak-wv.jsonl](soak-wv.jsonl), [reports.jsonl](reports.jsonl),
  [gc-events.jsonl](gc-events.jsonl), [hosts.txt](hosts.txt). In reports.jsonl, `wvtest` is stock-wv and `wsw` is
  ws-wv; gc-events.jsonl also holds the 12-min seed run (`seed`).
