## Resolution

Firefox doesn't free it because nothing it measures grows. Each 1 s `fetch('/report')` leaves an HTTP channel
(about 19 KiB in the parent, 3 KiB in the web process) that a small JS wrapper keeps alive, and the JS engine
counts only the wrapper, so no GC trigger fires. A GC plus a CC frees all of it, but no pref makes an idle engine
run one. Sending the reports over one WebSocket removes am's share entirely. Firefox's own share is
JS-visible and triggers its own GC, about once an hour in this run.

Measured on macOS 26.2 (Apple M4) with Firefox 159.0.1: eleven instances side by side for about 2 h, with GC/CC
logging, plus two 6-min playing trials at volume 0. Source citations are at tag `FIREFOX_159_0_1_RELEASE`.

**Why no GC/CC.**
- Every engine's parent GC'd at startup (netproc's not until 5 min) and once more 5 min after start, then not
  again for 60–80 min while it grew.
  That one is `USER_INACTIVE`, which fires once per process because input never comes. The CC ran every ~2 min
  and freed a few dozen objects each time. *Measured* with `javascript.options.mem.log` +
  `MOZ_LOG=PageMessages:5`, `JS_GC_PROFILE=0` and `MOZ_GCTIMER=stderr` (all work in release; give them `stderr`,
  since a file path crashes the sandboxed content process).
- Why, from source:
  - The JS engine GCs a zone when its GC heap reaches max(retained, 27 MiB) × 1.5, or its JS-counted malloc
    reaches max(retained, 38 MiB) × 1.5
    ([Scheduling.cpp#L501-L510](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L501-L510),
    [#L579-L597](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L579-L597)).
  - A channel's memory is XPCOM malloc. Its wrapper counts only twice its own struct
    ([XPCWrappedNative.cpp#L534-L547](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/xpconnect/src/XPCWrappedNative.cpp#L534-L547)),
    and a `ChannelWrapper` counts 0.
  - Gecko's own triggers don't come back in a headless engine with no input. Page loads need navigation.
    `user-interaction-inactive` fires once
    ([EventStateManager.cpp#L319-L363](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/events/EventStateManager.cpp#L319-L363)).
    The full-GC timer and the GC after a CC only follow a GC, or a CC that freed more than 250 GC things
    ([nsJSEnvironment.cpp#L1521-L1529](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1521-L1529),
    [CCGCScheduler.h#L386-L391](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.h#L386-L391)).
  - A CC can't free objects held by wrappers made since the last GC
    ([nsCycleCollector.cpp#L2016-L2023](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsCycleCollector.cpp#L2016-L2023)).
- What GC'd them in the end was Firefox's own Remote Settings work. Every warm-profile engine with default GC
  prefs got a `TOO_MUCH_MALLOC` GC between 13:02 and 13:16, after Firefox had left multi-MiB `ArrayBuffer`s in
  its JS, and that GC freed am's garbage too. A bare Firefox with a fresh profile had no GC from 11:50 to 13:50. *Measured.*
- A forced GC plus a CC, without memory-pressure (the debug FIFO's `gc log`), took stock's parent
  heap-unclassified from 111 to 78 MiB and its web heap from 34 to 9 MiB. A "minimize" afterwards freed only
  1–2 MiB more of those. A CC alone freed nothing. *Measured.*

**A pref that makes it collect.** None.
- 159 has no time-based major GC, and no pref or release-build env var adds one. `JS_GC_ZEAL` is debug-only.
  *Source* ([source-gc.md §4](https://github.com/IIxauII/am/blob/research/engine-gc/research/engine-gc/source-gc.md#4-prefs-or-env-vars-that-could-make-an-idle-engine-collect)).
- Lower triggers (`javascript.options.mem.gc_low_frequency_heap_growth=118`, `gc_allocation_threshold_mb=1`,
  `gc_malloc_threshold_base_mb=1`):
  - No GC came from am's garbage: none from 12:05 to 12:47.
  - It GC'd earlier and more often once Firefox's own work allocated (5 triggers, 12:48–12:57).
  - It grew +38 MiB/h over 1.8 h, against stock's +71. CPU and wake-ups stayed the same: 0.52 % and 6.9/s
    against 0.49 % and 6.0/s.
  - It only shortens the wait for Firefox's next burst. *Measured.*
- `javascript.options.mem.gc_balanced_heap_limits=true`: one GC at 12:55, +77 MiB/h over 1.8 h. No help.
  *Measured.*
- `browser.lowMemoryResponseMask=2` with `browser.lowMemoryResponseOnWarn=true` sends one GC/CC when the OS
  pressure level enters warn or critical. Repeats every 10 s are ignored by JS. *Source*, not tested. The OS sat at
  warn for the whole run, so this would have fired once.
- A parent GC chain costs about 130 ms of CPU (*measured*). One every few minutes would be under 0.1 % CPU
  (*inferred*), but nothing in Firefox schedules it.

**What the `heap-unclassified` is.**
- It is the per-request HTTP channels in the parent: nsHttpChannel with its URI, headers and LoadInfo. Each is
  kept alive by the XPConnect wrapper a JS observer gets for it, until a GC. *Inferred* from source, consistent with
  the measurements: a GC+CC frees it, and the parent's `ChannelWrapper` (+0.97 MiB/h) and
  `XPCWrappedNative_NoHelper` (+0.7 MiB/h) objects grow alongside and drop to about 0 in the same GC.
- Two observers wrap every channel. webRequest (from webcompat and search-detection) is one. `SearchSERPTelemetry`
  is the other: BrowserGlue starts it for every window, with no pref, and it calls `ChannelWrapper.get()` on every
  `http-on-examine-response`
  ([BrowserGlue.sys.mjs#L833](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/BrowserGlue.sys.mjs#L833),
  [SearchSERPTelemetry.sys.mjs#L1537-L1538](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/search/SearchSERPTelemetry.sys.mjs#L1537-L1538),
  [#L1559-L1583](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/search/SearchSERPTelemetry.sys.mjs#L1559-L1583)).
- In the web process it is the fetch's `Response`, iterators and saved stack frames, and the channel's child side.
  The GC freed 24 MiB of them. *Measured.*
- The localhost cache entries (+4.3 MiB/h) are POST answers kept as memory-only entries until memory-pressure.
  `cache: 'no-store'` on the fetch skips them. *Source*, and measured in the earlier research.
- DMD, the tool that names heap-unclassified, needs a special build, so it wasn't used.

**A cheaper report path.** (MiB/h, all processes, the hour with no GC; CPU and wake-ups)
- Stock: +132, 0.49 %, 6.0/s.
- The three webRequest add-ons off (`extensions.webcompat.enabled`, `extensions.addons-search-detection.enabled`,
  `extensions.ipp-activator.enabled` = false): +131. No change, because `SearchSERPTelemetry` still wraps every
  channel. *Measured.*
- Network process on (`network.process.enabled` plus `network.http.network_access_on_socket_process.enabled`):
  +129. The channel and its observers stay in the parent. *Measured*, *source*.
- One WebSocket for the reports (page change, plus a throwaway relay that POSTs each one to the daemon): +55, the
  same as a bare Firefox with the same profile (+54). Parent heap-unclassified +9.5 against stock's +60.5.
  0.15 %, 3.8/s. *Measured.* A WebSocket message creates no channel, observer call or JS object in the parent
  (*source*).

**Firefox's own share.**
- The steps are Remote Settings work in the parent (*measured*):
  - About 60 min after each start, a poll with a collection fetch. In warm profiles it also fetched the startup
    bundle. It ran with push off too.
  - A push broadcast (server version from 12:35) made the warm engines sync `url-classifier-exceptions` around
    12:55.
  - The parent gained an 18.5 MiB `ArrayBuffer` (likely the earlier research's 16.8 MiB one), 9 MiB of strings
    and 7 MiB of objects.
- The broadcast is what lines instances up in the same wall-clock minute (*inferred*).
- It is JS-visible, so it ends in its own GC (*measured*). A bare Firefox with a warm profile grew +54 MiB/h for an
  hour, GC'd at 13:05, then went −4 MiB/h. Fresh profiles grew 3–9 MiB/h.
- `dom.push.connection.enabled=false` stops only the broadcast-driven syncs; the hourly poll still ran
  (*measured*). It delays all Remote Settings updates, CRLite revocations and intermediate certificates included,
  to the 24 h poll. Widevine updates don't use Remote Settings. *Source.*
- Not worth a pref, since this share collects itself.

**While music plays.** (6 min each at volume 0, full DRM tracks)
- No major GC in any process in either trial. *Measured.*
- Stock page: +53 MiB in 6 min (parent +10.6, web +41.8). WebSocket page: +45 MiB (parent +3.3, web +40.7). A
  minimize freed it (601 → 430 and 475 → 401 MiB). *Measured.*
- The WebSocket covers the report share while playing too. The parent's remaining ~33 MiB/h comes from the
  song's own requests, about 0.3 a second. *Measured*; that they leave the same pinned channels is *inferred*.
- The web process's gain is mostly segment `ArrayBuffer`s (+26 MiB) and media resources (+10 MiB). The
  `ArrayBuffer`s count as JS malloc, so a content GC should come after about 13 min of playing. *Inferred* from the
  trigger; not measured past 6 min.

Context: https://github.com/IIxauII/am/tree/research/engine-gc/research/engine-gc (method, every table, source
notes, scripts and samples).

### What this means for [Keep-alive safeguards: memory ceiling and radio stop](https://github.com/IIxauII/am/issues/17)

- **No fix:**
  - An idle kept-alive engine grows about 130 MiB/h (am's report about 77, Firefox's own the rest).
  - It drops back only when Firefox's own background work happens to trigger a GC: after 74 min in this run,
    after none in 60 min in the earlier one.
  - The period is not am's to set. It peaked near 500 MiB here.
- **Transport change: reports over one WebSocket.**
  - Idle: am's share goes to about 0 MiB/h. What's left is Firefox's own: 3–54 MiB/h by the hour, and it
    collects itself.
  - Costs 0.15 % CPU and 3.8 wake-ups/s, against 0.49 % and 6.0/s today.
  - While playing, the parent grows about 33 MiB/h instead of about 105.
  - The 1 s cadence and the daemon's 5 s staleness rule stay as they are.
  - Cost: a WebSocket endpoint in the daemon (handshake and frames) and a small page change.
- **Page fix: fewer reports while idle.** From the earlier research:
  - The page without the 1 s timer grows like a bare Firefox, at 0.11 % CPU and 0.4 wake-ups/s.
  - A 60 s heartbeat would leave about 1.3 MiB/h at ~22 KiB a request (*inferred*).
  - It needs a longer staleness allowance in the daemon.
  - While playing, nothing changes (about 105 MiB/h in the parent until a Firefox-driven GC).
- **A pref:** none bounds it. The lowered GC triggers only shorten the wait for Firefox's next burst.
- **Relaunch every N hours:** frees everything; the engine restarts at about 440 MiB (earlier research). With
  either fix above it is only a safety net.
- **Combination:**
  - Pair the WebSocket or the page fix with a memory ceiling (relaunch when the idle engine passes a limit)
    instead of a timer, because what remains is Firefox's own, self-collecting garbage.
  - The WebSocket also covers playing.
  - Behaviour past 2 h idle and past 6 min playing is *inferred*.
