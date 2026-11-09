# Why does an idle engine's memory keep growing? (#15)

Throwaway research branch, never merged. The answer is the resolution comment on
[#15](https://github.com/IIxauII/am/issues/15); this page holds the method, the numbers and the files.

Measured 2026-11-09, 09:13–10:53, on an Apple M4 (16 GiB, macOS 26.2) with Firefox 159.0.1 and `am` built from
`main` at 0d488e7 (`zig build -Doptimize=ReleaseSafe`). No music played. The OS memory pressure level
(`kern.memorystatus_vm_pressure_level`) was 2 ("warn") the whole time.

## Answer

- **Which process:** the parent process holds about 80 % of the growth and the web content process (the
  engine page) the rest. The extension process, RDD and the two utility processes stay flat. *Measured.*
- **What:** in the parent, mostly `heap-unclassified` (malloc'd memory that no memory reporter claims), plus
  HTTP cache entries for `localhost` and webRequest `ChannelWrapper` objects. In the web process,
  `heap-unclassified` and JIT data. The JS heap of MusicKit and the page barely moves: the engine page's whole
  window is about 3 MiB. *Measured with Firefox's memory reports.* That the parent's share is per-request network
  objects held until a GC/CC is *inferred* from which reporters grow and from the A/B below.
- **Is it am's page?** About 75 % of it is, and the cause is the 1 s report. A page with no 1 s report grows
  like a bare Firefox on `about:blank`: 0.4 MiB/min, in steps. The stock page grows 1.5 MiB/min, steadily.
  Dropping `keepalive: true` from the fetch, or adding `cache: 'no-store'`, changes nothing that matters.
  *Measured.*
- **Is it garbage Firefox reclaims?** It is garbage, but Firefox doesn't reclaim it on its own. "Minimize memory
  usage" (shrinking GC and CC, three rounds, in every process) brings every engine back below its size about
  7 min after launch. Without that, nothing dropped in 60 min, and the earlier soak saw no plateau in about 2 h.
  Release Firefox on macOS does nothing on OS memory pressure by default (`browser.lowMemoryResponseMask` = 0,
  [firefox.js L1248–L1280](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L1248-L1280)).
  *Measured; the pref default is from source.*
- **Does it level off?** Not within 60 min. The parent's `heap-unclassified` grew +26 MiB in the first 30 min,
  +30 MiB in the next 30, and +20 MiB in the 20 min after a minimize. *Measured.*
- **Reload vs relaunch:** a page reload frees the web-process part (−10 MiB) and none of the parent's part (+5 MiB
  in the same 4 min). A relaunch starts again from about 440 MiB. *Measured.*
- **What would stop it:** fewer report requests while nothing plays. See [What would stop it](#what-would-stop-it).

## Setup

Six Firefox instances ran side by side. Each had its own profile under a throwaway config dir
(`AM_CONFIG_DIR`, with the token files symlinked from the real config) and `AM_PORT` 47911–47915. Keep-alive was
simulated with `ENGINE_IDLE_MINUTES=100000`, and each engine was started with `am doctor`:

| Name | Page | Daemon |
|---|---|---|
| stock | `poc/web/app.js` as on `main` | `main` |
| reload | stock page | `main` plus a `research-reload` endpoint (`research-reload.patch`) to reload the page at the end |
| noka | stock, without `keepalive: true` on the report fetch (`app-noka.patch`) | `main` |
| quiet | stock, without `setInterval(report, 1000)`, so it reports only on events (`app-quiet.patch`) | `main` |
| nostore | stock, with `cache: 'no-store'` on the report fetch (`app-nostore.patch`); started an hour later | `main` |
| bare | none: the same Firefox, flags, env and `user.js` as am's engine, on `about:blank` (`launch-bare.sh`) | none |

Firefox ran from a private copy of `/Applications/Firefox.app` (`FIREFOX_PATH`). At the start of the run the
installed app updated itself, and the updater then relaunched Firefox outside the daemon (see
[Side finding](#side-finding-firefoxs-self-update-breaks-an-engine-launch)). The copy kept every engine on one
binary and away from the shared update state.

There were two kinds of measurement:

- `sample.py` read each process's `phys_footprint` every 60 s through `proc_pid_rusage`, as the earlier
  warm-engine measurement did. This is the number Activity Monitor and `am status` show. Output:
  `soak.jsonl` (stock, quiet, noka, bare), `soak-reload.jsonl`, `soak-nostore.jsonl`.
- `memreport.py` and `takeall.py` took Firefox's own memory reports (the data behind about:memory), all processes
  in one file, through Firefox's debug FIFO. Two prefs in the profile's `prefs.js` turn the FIFO on:
  `memory_info_dumper.watch_fifo.directory`, which must come first (the directory is read when `enabled` loads,
  [nsDumpUtils.cpp L222–L231](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsDumpUtils.cpp#L222-L231)),
  then `memory_info_dumper.watch_fifo.enabled`. The reports land in the OS temp dir as
  `unified-memory-report-<time>-<pid>.json.gz`. The schedule was about 7 min after launch (t10), 30 min later
  (t40), 60 min later (t70), then a `minimize memory report` (t70min) and, on `reload`, one 4 min after the
  reload. `reports.jsonl` holds per-process totals and the top `explicit/` paths. The raw reports stay out of
  the repo, since they can hold strings from the page.

A memory report has a side effect on macOS. Before it reads `resident` it calls `jemalloc_purge_freed_pages()`.
That hands back the heap pages Firefox has `madvise(MADV_FREE)`'d but macOS hasn't taken yet
([nsMemoryReporterManager.cpp L432–L444](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsMemoryReporterManager.cpp#L432-L444),
[Constants.h L19–L37](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/memory/build/Constants.h#L19-L37)).
Those pages count in `phys_footprint`. The first report dropped each parent by 46–83 MiB, within about 4 MiB
of its `heap/committed/unused-pages/madvised`: that was start-up churn. Later reports dropped it by only
0.5–9 MiB, so after start-up the growth is live heap, not freed pages. The footprint numbers below are the ones
each report measured, after its purge.

## Results

### Totals (all processes, MiB phys_footprint, from the reports)

| Engine | t10 | t40 | t70 | t10→t70 | after minimize | footprint slope 09:29–10:28 | idle CPU, wake-ups |
|---|---|---|---|---|---|---|---|
| stock | 442.9 | 492.3 | 529.7 | **+86.8** | 408.1 | 1.54 MiB/min | 0.40 %, 6.2/s |
| reload (stock page, 2nd run) | 433.7 | 488.4 | 521.3¹ | +87.6 | 404.6² | 1.54 MiB/min | |
| noka (no `keepalive`) | 447.2 | 499.9 | 541.9 | +94.7 | 409.3 | 1.66 MiB/min | 0.41 %, 5.8/s |
| quiet (no 1 s report) | 442.6 | 461.7 | 465.0 | +22.4 | 390.4 | 0.41 MiB/min | 0.11 %, 0.4/s |
| bare Firefox, `about:blank` | 396.7 | 414.7 | 419.3 | +22.6 | 349.5 | 0.44 MiB/min | 0.09 %, 0.5/s |
| nostore (`cache: 'no-store'`) | 441.6³ | 470.6³ | | +29.0 in 30 min | 396.1 | | |

¹ 55 min after its t10, since it started 4 min later. ² After the reload, then a minimize. ³ 10:21 and 10:51,
a window with no Firefox-own step; stock's comparable window, the 20 min after its minimize, grew
+15.5 MiB (0.76 MiB/min) and quiet's +1.7 MiB.

The earlier measurement (Firefox 158, with the TUI open) saw about 1.0 MiB/min idle, the same order.

### Which process, and what in it (stock, t10 → t70, MiB)

| Process | footprint | explicit | of which |
|---|---|---|---|
| parent | +73.1 | +88.5 | `heap-unclassified` +55.7; a System-principal `ArrayBuffer` +16.8 (in quiet and bare too: Firefox's own); JS strings +4.6 (in quiet too); `network/cache2/memory-storage` for `localhost` +4.4; `xpconnect/scopes` +1.3; `ChannelWrapper` +1.0 |
| web content (engine page) | +13.4 | +14.5 | `heap-unclassified` +10.0; `jit-lazylink` +2.1; the page's JS objects +1.8 |
| extension, RDD, 2× utility | ±0.3 | +0.1 each | — |

The quiet engine's parent grew only by the Firefox-own parts (the `ArrayBuffer` and the strings). Its
`heap-unclassified` stayed at 57–60 MiB and its web process didn't move (29.0 → 28.8). Per 1 s report, the
parent keeps about 16 KiB of unclassified heap and the web process about 3 KiB until a GC/CC.

The Firefox-own part comes in steps that hit the instances in the same wall-clock minute, although they started
minutes apart: 09:39 (+4 MiB, all but the bare one), 09:43–44 (+17–26 MiB, all) and 09:53–57 (+4–10 MiB). That points to
background work triggered from outside the browser. The likeliest cause is a server-pushed sync and download,
since the 16.8 MiB `ArrayBuffer` sits in the privileged JS global, but that is *inferred*. A minimize frees this
part too.

Why the parent: am's engine prefs turn the network process off (`network.process.enabled=false`), so the parent
handles every `fetch('/report')`. Each request gets an HTTP channel and a memory-only cache entry for its POST,
and the daemon's `cache-control: no-store` answer doesn't prevent the entry. It also gets a webRequest
`ChannelWrapper`, because three built-in add-ons in the profile hold the `webRequest` permission: webcompat,
addons-search-detection and ipp-activator (*measured* from `extensions.json`). JS wrappers in the parent's
privileged JS zone keep these objects alive until that zone is garbage-collected and cycle-collected
(*inferred*, from minimize freeing them all). `cache: 'no-store'` on the request removes the cache entries, and
with them the `localhost` cache line of the table. The parent's `heap-unclassified` still grew +26.3 MiB in
30 min, the same as stock's +26.1.

### Reclaimed?

- **On its own:** no. Footprint rose steadily for 60 min in every reporting engine (one sample a minute), with
  no drop except at a memory report. The idle parent likely allocates too little JS to trigger the GC that would
  free these objects (*inferred*).
- **Minimize memory usage:** a `minimize memory report` sends `memory-pressure`/`heap-minimize` three times, each
  answered by a shrinking GC and a CC, then frees dirty heap pages, in every process
  ([nsMemoryReporterManager.cpp L2765–L2831](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsMemoryReporterManager.cpp#L2765-L2831),
  nsJSEnvironment.cpp [L224–L238](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L224-L238) and [L1445–L1456](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1445-L1456),
  [MemoryReportRequest.cpp L53–L68](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/ipc/MemoryReportRequest.cpp#L53-L68)).
  It took stock from 529.7 to 408.1 MiB. The parent's `heap-unclassified` went from 114 to 68 MiB, the `localhost`
  cache entries from 4.8 MiB to 0, and the web process from 44.1 to 30.3 MiB (its t10 was 30.7). It also freed
  about 99 MiB of software WebRender buffers (`gfx/webrender/swgl`) that every engine's parent holds from
  start-up, which is why every engine ends below its t10.
- **After a minimize** the growth resumes at the same rate. In the next 20 min stock's parent
  `heap-unclassified` grew +19.9 MiB and its web process +5.3 MiB explicit. Quiet's grew +0.6 MiB and 0.
- **On OS memory pressure:** Firefox's macOS memory watcher can unload tabs and fire `memory-pressure` at the
  "critical" level, or at "warn" with `browser.lowMemoryResponseOnWarn`. But the action mask
  `browser.lowMemoryResponseMask` is 0 outside Nightly, so release Firefox does nothing
  ([AvailableMemoryWatcherMac.cpp L24–L58](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/AvailableMemoryWatcherMac.cpp#L24-L58),
  [firefox.js L1248–L1280](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L1248-L1280)).
  *Source only, not tested.*

### Reload vs relaunch

On the reload engine: a report at t70 (10:28:54), a page reload at 10:29:30, and a report 4 min later (10:33:30):

| | before | 4 min after the reload |
|---|---|---|
| web content | 43.3 MiB (explicit 26.3) | 33.7 MiB (explicit 16.6) |
| parent | 395.9 MiB (explicit 419.1) | 400.7 MiB (explicit 423.2), still growing |

A reload drops the web process's part: the page gets a new window, and its garbage goes with the old one. It
leaves the parent's ~80 % where it was. A relaunch starts again from about 440 MiB (the t10 of every engine).

### What would stop it

What was measured:

| Page change | Parent `heap-unclassified`, 30 min | Web explicit, 30 min | Stops it? |
|---|---|---|---|
| none (stock) | +26.1 | +8.4 | — |
| no `keepalive: true` | +29.1 | +7.6 | no |
| `cache: 'no-store'` on the fetch | +26.3 | +8.7 | no (only the `localhost` cache entries go) |
| no 1 s report (reports only on events) | −0.2 | 0.0 | **yes** |

The cost scales with the number of report requests, not with how a request is made. One request per second
costs about 1.1 MiB/min until a GC/CC that an idle engine never gets. Ways to cut it, none of them tested
beyond the rows above:

- **Fewer requests while nothing plays.** The page already reports on every event (`note()` → `report()`).
  While no music plays or starts, it could skip the timer's report when the snapshot hasn't changed and send
  a heartbeat every N s instead. The daemon calls a page silent for 5 s stale (`stale_report_ms` in
  `src/daemon.zig`, used by `engineInUse` and `am status`), so the heartbeat needs either N < 5, which leaves
  about a quarter of the growth (*inferred*, linear), or a longer allowance for an idle page (a 60 s heartbeat
  leaves about 1 MiB/h, *inferred*). While music plays the 1 s report stays, and so does its growth: about
  70 MiB/h, plus whatever a bigger snapshot adds (the earlier soak's 1.6–1.8 MiB/min with a song loaded fits
  that, *inferred*).
- **One long-lived connection for reports** (a WebSocket) instead of one HTTP request each. This is *untested*,
  and the daemon has no WebSocket server.
- **Profile prefs, *untested*:** turning off the three built-in webRequest add-ons might cut the parent's cost
  per request. `browser.lowMemoryResponseMask=2` with `browser.lowMemoryResponseOnWarn` would GC only when
  macOS is under pressure.

A page change leaves Firefox's own ~0.4 MiB/min, which a bare Firefox shows too. Only a relaunch, or a
minimize, removes that part. am has no channel that can ask for a minimize: the debug FIFO writes a report file
per use, and NOTES decision 3 rules out an automation protocol.

## Side finding: Firefox's self-update breaks an engine launch

The first engine launches (fresh profiles, 09:13) ran Firefox's update check, which downloaded and staged the
159.0 → 159.0.1 partial update; the app was swapped to 159.0.1 at about 09:14. At 09:15 three engine launches
from `/Applications` ran the updater again on the already-updated app (`failed: 7` in
`~/Library/Caches/Mozilla/updates/Applications/Firefox/updates/last-update.log`). The updater then relaunched
Firefox itself: a new parent with ppid 1 in its own process group, without `--headless` in its argv, though
still background-only. The daemon logged `the engine exited on its own` and cleared the launch's nonce, so the
relaunched page went to `about:blank`. `am daemon stop` didn't kill the relaunched processes, and they had to be
killed by hand. The parallel radio-stop research hit the same at 09:25. This deserves its own ticket: Firefox's
updater can hijack an engine launch.

## Files

- `launch.sh`: starts one research engine (fresh profile with the FIFO prefs, keep-alive, the private Firefox
  copy).
- `launch-bare.sh`, `user.js`: the bare Firefox baseline with am's engine prefs.
- `sample.py` → `soak*.jsonl`: per-process footprint, CPU and wake-ups every 60 s. `slopes.py` computes the
  slope per process. `procs.py` lists the engines' processes.
- `memreport.py`, `takeall.py`, `trigger.py`: take Firefox memory reports through the FIFO, then summarise and
  diff them. → `reports.jsonl`.
- `endgame.sh`, `nostore.sh`: the timed reports, the reload and the minimizes.
- `reload.py`, `research-reload.patch`: the research-only reload endpoint.
- `app-*.patch`: the page variants (diffs against `poc/web/app.js`).
