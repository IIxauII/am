# Why an idle headless Firefox 159 parent never GCs: source reading

All links point at tag `FIREFOX_159_0_1_RELEASE` of `mozilla-firefox/firefox`. Line numbers were checked
in a sparse checkout of that tag (commit `6181e6b5f28a`). "Measured" here means read in source; nothing
was run. Where a claim depends on runtime state that the source can't settle, it says so.

Short version: in 159 nothing starts a **major** GC just because time passes. Every trigger needs either
JS-heap growth past a threshold that scales with the retained heap (at least +50 %, never less than 40.5 MiB
of GC heap or 57 MiB of counted malloc), or an event: a page load or unload, an input-driven inactive
transition, memory pressure, or a GC/CC that something else already started. Most of the parent's growth
is XPCOM malloc (`heap-unclassified`), and the JS engine doesn't see it. A JS reflector reports either
nothing or only 2 × sizeof(XPCWrappedNative) for the native it keeps alive, so the malloc trigger never
fires. A CC on its own can't free natives kept alive by JS wrappers created since the last GC, because
those wrappers are not gray.

## 1. GC triggers for the parent main-thread runtime

### JS-engine triggers (allocation-driven)

- **GC-heap threshold (`ALLOC_TRIGGER`)**. This is checked when a new arena is allocated
  ([Allocator.cpp#L494-L501](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Allocator.cpp#L494-L501))
  and after every minor GC
  ([GC.cpp#L5563-L5566](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L5563-L5566)).
  It fires when a zone's tenured `gcHeapSize >= startBytes`
  ([GC.cpp#L2133-L2148](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L2133-L2148),
  [GC.cpp#L2190-L2203](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L2190-L2203)),
  then schedules that zone and requests a major GC through the interrupt
  ([GC.cpp#L2205-L2231](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L2205-L2231)).
  - `startBytes = max(retained, gc_allocation_threshold) × growth`
    ([Scheduling.cpp#L501-L510](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L501-L510)).
    It is recomputed only at GC end from the bytes retained by that GC
    ([GC.cpp#L3992-L4003](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L3992-L4003),
    [Zone.cpp#L62-L71](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Zone.cpp#L62-L71)),
    at zone creation
    ([Zone.cpp#L185](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Zone.cpp#L185)),
    and when a GC parameter is set
    ([GC.cpp#L1317-L1326](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L1317-L1326)).
  - `growth` is the low-frequency factor unless two GCs started less than 1 s apart, and always when
    `retained < 1 MiB`
    ([Scheduling.cpp#L467-L499](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L467-L499),
    [Scheduling.cpp#L297-L319](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L297-L319)).
- **Malloc threshold (`TOO_MUCH_MALLOC`)**. `mallocHeapSize >= max(retainedMalloc, gc_malloc_threshold_base) × growth`
  ([Scheduling.cpp#L579-L597](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L579-L597),
  [ZoneAllocator.h#L155-L169](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/ZoneAllocator.h#L155-L169)).
  `mallocHeapSize` counts only "malloc data owned by tenured GC things … including external allocations
  supplied by JS::AddAssociatedMemory"
  ([ZoneAllocator.h#L183-L188](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/ZoneAllocator.h#L183-L188)).
- **Does the malloc of XPCOM natives held by JS wrappers count?** Barely:
  - An XPCWrappedNative reports `sizeof(*this) * 2`, the wrapper struct and not the native behind it (e.g. an
    nsHttpChannel). The source labels this "A hack for bug 517665"
    ([XPCWrappedNative.cpp#L534-L547](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/xpconnect/src/XPCWrappedNative.cpp#L534-L547)).
  - WebIDL reflectors report `BindingJSObjectMallocBytes()`, which defaults to `0`
    ([BindingUtils.h#L2820-L2826](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/bindings/BindingUtils.h#L2820-L2826),
    [BindingUtils.h#L2870-L2873](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/bindings/BindingUtils.h#L2870-L2873)).
  - `toolkit/components/extensions/webrequest/` (ChannelWrapper) has no `AddAssociatedMemory` or
    `MallocBytes` hit, so ChannelWrapper reports 0.
- **Eager trigger (`EAGER_ALLOC_TRIGGER`, 0.85×/0.9× of start)**
  ([Scheduling.cpp#L31-L45](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L31-L45)).
  It is evaluated only in `maybeGC`/`wantMajorGC`
  ([GC.cpp#L2233-L2282](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L2233-L2282)).
  Gecko's main thread doesn't poll it: "Bug 1772638: For now, only do eager minor GCs"
  ([nsJSEnvironment.cpp#L1427-L1443](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1427-L1443)).
  The only `JS_MaybeGC` caller in the checkout is the PAC runtime
  ([ProxyAutoConfig.cpp#L703-L708](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/base/ProxyAutoConfig.cpp#L703-L708)).
  Even so, when a GC does start, zones above the eager level are added to it
  ([GC.cpp#L4969-L4977](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L4969-L4977)).
- **Defaults and accepted ranges.** Firefox values come from
  [all.js#L938-L975](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L938-L975);
  JS defaults from
  [Scheduling.h#L355-L431](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.h#L355-L431).
  The Gecko callback passes an int pref only if `0 <= v < 10000` and otherwise resets it to the default
  ([nsJSEnvironment.cpp#L1659-L1668](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1659-L1668)).
  The engine then validates the value
  ([Scheduling.cpp#L132-L158](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L132-L158))
  and silently ignores anything invalid
  ([jsapi.cpp#L1441-L1447](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/jsapi.cpp#L1441-L1447)).

| pref (`javascript.options.mem.*`) | default | engine accepts |
|---|---|---|
| `gc_allocation_threshold_mb` | 27 | any MB ≤ 4095 (no check; 0 means threshold 0, so a GC on every arena) |
| `gc_malloc_threshold_base_mb` | 38 | same |
| `gc_low_frequency_heap_growth` (÷100) | 150 | 118…10000 (min 1/0.85 ≈ 1.1765, max 100) |
| `gc_high_frequency_small/large_heap_growth` | 300 / 150 | 118…10000 |
| `gc_high_frequency_time_limit_ms` | 1000 | any |
| `gc_small_heap_size_max_mb` / `gc_large_heap_size_min_mb` | 100 / 500 | large must be non-zero |
| `gc_small/large_heap_incremental_limit` (÷100) | 150 / 110 | 100…10000 |
| `gc_balanced_heap_limits` / `gc_heap_growth_factor` | false / 50 | bool / any (used as-is, not ÷100) |

- **Balanced heap limits** (off by default) replace the GC-heap start threshold with
  `W + min(d·sqrt((W+5)·g/s), 3W)`, floored at `max(10 MiB, W + 3 MiB)`. `g` is the smoothed allocation rate
  measured at GC start, and `s` the collection rate, 200 MB/s until measured
  ([Scheduling.cpp#L512-L577](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.cpp#L512-L577),
  [GC.cpp#L5320-L5321](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L5320-L5321)).
  The malloc threshold is unaffected.

### Gecko-side triggers (`dom/base/CCGCScheduler.cpp`, `nsJSEnvironment.cpp`)

The overview of the five ways a GC starts is at
[CCGCScheduler.cpp#L40-L135](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L40-L135).
The delay prefs are at
[StaticPrefList.yaml#L9964-L9987](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L9964-L9987).
The parent never asks permission before a major GC
([CCGCScheduler.cpp#L380-L415](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L380-L415)).
A Gecko-poked GC with no "waiting zones" becomes a full GC
([CycleCollectedJSRuntime.cpp#L2202-L2214](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/CycleCollectedJSRuntime.cpp#L2202-L2214)).

| reason | who calls it | delay / pref | fires in an idle, input-free parent? |
|---|---|---|---|
| `LOAD_END` | document load finished ([nsDocumentViewer.cpp#L980-L983](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/layout/base/nsDocumentViewer.cpp#L980-L983)) | first poke in the process `gc_delay.first` = 10000 ms, later `gc_delay` = 4000 ms ([CCGCScheduler.cpp#L489-L532](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L489-L532)) | only when a chrome document loads (startup) |
| `PAGE_HIDE` | unload, history entry cleared ([nsDocumentViewer.cpp#L1207-L1213](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/layout/base/nsDocumentViewer.cpp#L1207-L1213), [#L1790-L1797](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/layout/base/nsDocumentViewer.cpp#L1790-L1797)) | 2 × `gc_delay` | no |
| `SET_DOC_SHELL`, `NSJSCONTEXT_DESTROY` | window teardown ([nsGlobalWindowOuter.cpp#L2787-L2795](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsGlobalWindowOuter.cpp#L2787-L2795), [nsJSEnvironment.cpp#L489-L492](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L489-L492)) | `gc_delay` | no |
| `FULL_GC_TIMER` | armed **only** at the end of a zone (non-full) GC ([nsJSEnvironment.cpp#L1521-L1529](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1521-L1529)) | `gc_delay.full` = 60000 ms ([CCGCScheduler.cpp#L466-L487](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L466-L487)) | only after an allocation-triggered zone GC |
| `CC_FINISHED` | end of a CC, if `NeedsGCAfterCC()`: >250 GC things freed, any JS zone freed, >2500 touch objects, or a pending request ([nsJSEnvironment.cpp#L1241-L1263](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1241-L1263), [CCGCScheduler.h#L386-L391](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.h#L386-L391)) | `gc_delay` minus CC time, or `gc_delay.interslice` = 250 ms | only after a CC that freed a lot |
| `USER_INACTIVE` (shrinking) | `user-interaction-inactive` topic, see below ([CCGCScheduler.cpp#L594-L602](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L594-L602)) | `compact_on_user_inactive_delay` = 300000 ms (15000 on Nightly) ([StaticPrefList.yaml#L9736-L9745](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L9736-L9745)) | **once** per process, ~5 s + 5 min after the first EventStateManager, and only if no regular-rate refresh-driver timer is ticking |
| `MEM_PRESSURE` | `memory-pressure` observer ([nsJSEnvironment.cpp#L224-L246](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L224-L246)) | immediate | only when something sends the topic, see section 4 |

- **`user-interaction-inactive`** comes from `UITimerCallback` in
  [EventStateManager.cpp#L319-L363](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/events/EventStateManager.cpp#L319-L363).
  - The first EventStateManager in a process starts a one-shot timer of `dom.events.user_interaction_interval`
    = 5000 ms
    ([EventStateManager.cpp#L677-L704](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/events/EventStateManager.cpp#L677-L704),
    [StaticPrefList.yaml#L3186-L3189](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L3186-L3189)).
  - With no input in the interval, the timer sends `user-interaction-inactive` and **releases itself**.
  - Only a trusted mouse, key, wheel, pointer, touch, drop or gamepad event sends `user-interaction-active`
    and re-arms it
    ([EventStateManager.cpp#L979-L999](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/events/EventStateManager.cpp#L979-L999)).
  - So the topic fires once, even though `user-interaction-active` never came. The scheduler starts with
    `mUserIsActive = true`
    ([CCGCScheduler.h#L531](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.h#L531)).
- **How `UserIsInactive` gets to a GC.** It arms the shrinking timer.
  - When the timer fires, it GCs only if `!nsRefreshDriver::IsRegularRateTimerTicking()`; otherwise it
    re-arms for another full delay
    ([CCGCScheduler.cpp#L441-L464](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L441-L464),
    [CCGCScheduler.cpp#L333-L362](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L333-L362),
    [nsRefreshDriver.cpp#L3047-L3065](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/layout/base/nsRefreshDriver.cpp#L3047-L3065)).
  - Nothing re-arms it after the GC runs.
  - Whether the headless parent's refresh driver ticks can't be settled from source; a `USER_INACTIVE` line
    at about T+305 s in the logs (or its absence) settles it.
- **No idle-service trigger.** nsJSEnvironment observes only `memory-pressure`, `memory-pressure-stop`,
  `user-interaction-*`, `quit-application`, `xpcom-shutdown` and `content-child-will-shutdown`
  ([nsJSEnvironment.cpp#L1994-L2005](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1994-L2005)).
  No `idle`/`idle-daily` handler that GCs was found in `dom/`, `js/`, `xpcom/`, `toolkit/`, `widget/`,
  `layout/base`, `docshell/` or `netwerk/base`.
- **No time-based major GC.** The idle-time GC task is minor-only
  ([CycleCollectedJSContext.cpp#L594-L618](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/CycleCollectedJSContext.cpp#L594-L618),
  [CycleCollectedJSRuntime.h#L498-L501](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/CycleCollectedJSRuntime.h#L498-L501)).
  `kMaxCCLockedoutTime` (30 s) only finishes an incremental GC that is blocking a CC; it never starts one
  ([CCGCScheduler.cpp#L35-L37](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L35-L37),
  [#L853-L858](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L853-L858)).
  The JS tunables include nothing time-based for major GCs
  ([Scheduling.h#L336-L517](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Scheduling.h#L336-L517)).

## 2. CC triggers, and CC vs GC

- **`MaybePokeCC` call sites.** It runs after **every** main-thread task
  ([XPCJSContext.cpp#L1540-L1543](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/xpconnect/src/XPCJSContext.cpp#L1540-L1543))
  and at every GC end
  ([nsJSEnvironment.cpp#L1516](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1516)).
  When a reason applies, it starts the CC runner
  ([CCGCScheduler.cpp#L658-L673](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L658-L673)).
- **Gates.** No CC runs before the first GC (`mHasRunGC`), and a new one waits ≥ `kCCDelay` = 6 s after the
  last CC ([CCGCScheduler.cpp#L764-L788](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L764-L788),
  [#L20](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L20)).
- **Reasons**
  ([CCGCScheduler.h#L365-L381](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.h#L365-L381)):
  - `GC_FINISHED`: set by every major GC end
    ([CCGCScheduler.cpp#L162-L185](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L162-L185)).
  - `MANY_SUSPECTED`: purple buffer > 200.
  - `TIMED`: purple buffer > 10 and > 2 min since the last CC
    ([CCGCScheduler.h#L49-L58](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.h#L49-L58),
    [CCGCScheduler.cpp#L35](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L35)).
  - The runner spends ~6 s running forget-skippable, then aborts if the reason has gone away
    ([CCGCScheduler.cpp#L861-L913](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/CCGCScheduler.cpp#L861-L913)).
  - So an idle parent with a trickle of purple objects can CC every ~2 min **without** any GC.
- **A CC without a GC can't free what JS wrappers keep alive.** The CC traverses a JS thing only if it is
  marked gray ([nsCycleCollector.cpp#L2016-L2023](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsCycleCollector.cpp#L2016-L2023)).
  - Gray means `!black && grayOrBlack`, and nursery cells are never gray
    ([HeapAPI.h#L353-L357](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/public/HeapAPI.h#L353-L357),
    [HeapAPI.h#L844-L852](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/public/HeapAPI.h#L844-L852)).
  - Only a major GC sets gray bits. Wrappers allocated since the last GC are therefore treated as live, and
    so are the natives they hold.
  - The CC forces a GC only when gray bits are invalid
    ([nsCycleCollector.cpp#L3536-L3573](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsCycleCollector.cpp#L3536-L3573)).
  - The JS objects themselves (e.g. ChannelWrapper reflectors) are freed only by a GC.
- **GC → CC → GC chain.** A major GC sets `GC_FINISHED` and then a CC follows. The CC pokes `CC_FINISHED` only
  if it freed > 250 GC things or a zone. A zone GC also arms `FULL_GC_TIMER` (60 s). The chain stops at the
  first CC that frees little, and nothing restarts it except a new trigger from section 1.

## 3. Logging that works in a release build

- **`MOZ_GCTIMER`**, unconditional in release
  ([Statistics.cpp#L815](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L815)).
  - Values ([Statistics.cpp#L110-L142](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L110-L142)):
    `none`, `stdout`, `stderr`, or a path. A relative path is joined to `MOZ_UPLOAD_DIR` if that is set,
    otherwise resolved against the cwd.
  - A path is opened with `fopen(…, "a")` and line buffering, once per JSRuntime (main and each worker), so
    every process appends to the same file.
  - **If the open fails, the process aborts with `MOZ_CRASH("Failed to open log file.")`.**
  - Output is one multi-line block per finished GC
    ([Statistics.cpp#L964-L979](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L964-L979)).
    The block has "GC(T+s)", Reason, Incremental, "Zones Collected: x of y", HeapSize, and per slice its
    reason and "Trigger: X MiB of Y MiB threshold"
    ([Statistics.cpp#L479-L554](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L479-L554)).
    It carries **no PID**.
- **`JS_GC_PROFILE=N[,main|all]`** (N = min slice length in **ms**; `main` is the default; `help` prints and
  **exits the process**)
  ([GC.cpp#L618-L679](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L618-L679)).
  - Writes one `MajorGC:` line per slice: PID, Runtime, Timestamp, Reason, States, FSNR flags
    (Full/Shrink/Nonincremental/Reset), SizeKB, MllcKB, Zs/Cs/Rs (all zones, compartments and realms in the
    runtime), Budget, then phase times
    ([Statistics.cpp#L1664-L1678](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L1664-L1678),
    [#L1719-L1755](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L1719-L1755)).
  - Output goes to `JS_GC_PROFILE_FILE`, which takes the same syntax and has the same crash-on-fail;
    default **stderr**
    ([Statistics.cpp#L816-L821](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Statistics.cpp#L816-L821)).
- **`JS_GC_PROFILE_NURSERY=N[,main|all]`** uses the same parser, so N is in ms too, although its help text
  says microseconds ([Nursery.cpp#L323-L326](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Nursery.cpp#L323-L326)).
  It writes one `MinorGC:` line per minor GC: PID, Timestamp, Reason, PRate (promotion %), OldKB/NewKB
  nursery size, then phase times
  ([Nursery.cpp#L1112-L1126](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/Nursery.cpp#L1112-L1126)).
  PRate shows whether the per-request objects get tenured.
- **`JS_GC_DEBUG`**: not found in 159. **`JS_GC_ZEAL`** exists only with `--enable-gczeal`, which defaults to
  on only in debug builds
  ([js/moz.configure#L475-L481](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/moz.configure#L475-L481),
  [GC.cpp#L1070-L1075](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L1070-L1075)).
  A release build has no env var or pref that forces periodic GC.
- **`MOZ_CCTIMER`** accepts `none`/`stdout`/`stderr`/path
  ([CycleCollectorStats.cpp#L21-L45](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/CycleCollectorStats.cpp#L21-L45)).
  - A path is opened with `fopen(path, "a")`, with no `MOZ_UPLOAD_DIR` join, and closed and reopened after
    every CC. If the open fails it only warns.
  - One line per CC
    ([nsJSEnvironment.cpp#L1006-L1039](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1006-L1039)):
    `CC(T+s)[default|content-PID] … suspected … collected: N RCed and M GCed (…waiting for GC), forced a GC`,
    plus a ForgetSkippable line.
- **`javascript.options.mem.log=true`** sends GC summary, GC slice and CC lines to the console service
  ([nsJSEnvironment.cpp#L1496-L1509](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1496-L1509),
  [#L1581-L1593](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1581-L1593),
  [#L1030-L1036](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1030-L1036)).
  - The console service echoes messages only to MOZ_LOG module `PageMessages`, at Info level
    ([nsConsoleService.cpp#L58](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsConsoleService.cpp#L58),
    [#L378-L404](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsConsoleService.cpp#L378-L404),
    [nsConsoleMessage.cpp#L30-L33](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsConsoleMessage.cpp#L30-L33)).
    Use `MOZ_LOG=PageMessages:3` or higher.
  - `devtools.console.stdout.chrome` covers only the `console.*` API object, not nsIConsoleService
    ([Console.cpp#L904-L909](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/console/Console.cpp#L904-L909)).
  - **`javascript.options.mem.notify`** only emits a `cycle-collection-statistics` observer topic with CC
    JSON ([nsJSEnvironment.cpp#L1042-L1099](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1042-L1099)).
- **MOZ_LOG modules**:
  - **`gc`** is SpiderMonkey's: `begin slice for reason X in state Y`, `minor GC for reason X`, at Info level
    ([Logging.h#L92-L103](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/vm/Logging.h#L92-L103),
    [GC.cpp#L5313-L5314](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/gc/GC.cpp#L5313-L5314)).
    It is wired to Gecko logging in
    [XPCJSContext.cpp#L1214-L1249](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/xpconnect/src/XPCJSContext.cpp#L1214-L1249).
  - **`MemoryPressure`** covers the macOS watcher
    ([AvailableMemoryWatcherMac.cpp#L19-L20](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/AvailableMemoryWatcherMac.cpp#L19-L20)).
  - CCGCScheduler has no log module, so its PokeGC and timer decisions are invisible except through the
    reason on the resulting GC.
- **Sandboxed macOS content processes.**
  - The sandbox starts in `XRE_InitChildProcess`, before XPCOM and JS init
    ([nsEmbedFunctions.cpp#L342-L348](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/xre/nsEmbedFunctions.cpp#L342-L348)).
  - Its policy is `deny default`, with file writes allowed only to `/dev/null` and `/dev/zero`
    ([SandboxPolicyContent.h#L39](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/sandbox/mac/SandboxPolicyContent.h#L39),
    [#L81-L84](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/sandbox/mac/SandboxPolicyContent.h#L81-L84)).
    The write-dir exception exists only in DEBUG builds
    ([Sandbox.mm#L674-L680](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/sandbox/mac/Sandbox.mm#L674-L680)).
  - Children inherit the parent environment
    ([process_util_posix.cc#L349-L362](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/ipc/chromium/src/base/process_util_posix.cc#L349-L362)).
  - Consequence: **`MOZ_GCTIMER=<path>` or `JS_GC_PROFILE_FILE=<path>` should crash the content process at
    startup** (inferred from fopen under deny-default plus MOZ_CRASH; not run). `MOZ_CCTIMER=<path>` silently
    logs nothing from content.
  - Use `stderr`; I inferred that writing to the inherited stderr fd works under the sandbox. The other way
    is `MOZ_DISABLE_CONTENT_SANDBOX=1`, which drops the effective level to 0 even in release
    ([SandboxSettings.cpp#L115-L118](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/sandbox/common/SandboxSettings.cpp#L115-L118)),
    but it changes the system under test.

## 4. Prefs or env vars that could make an idle engine collect

- **Lower the allocation triggers.** Set `javascript.options.mem.gc_low_frequency_heap_growth=118` (the
  minimum), `gc_allocation_threshold_mb=1` and `gc_malloc_threshold_base_mb=1`.
  - A zone then GCs after ~18 % growth over its retained size instead of 50 %, with no 27/38 MiB floor.
  - Each such zone GC arms `FULL_GC_TIMER` (60 s, `javascript.options.gc_delay.full`) and a CC.
  - Cost: more frequent small zone GCs while active. Never use 0 for the thresholds.
  - It works only if the tenured GC heap or JS-counted malloc actually grows; XPCOM malloc stays invisible.
- **`javascript.options.mem.gc_balanced_heap_limits=true`** (optionally `gc_heap_growth_factor` lower than 50).
  - At an idle allocation rate the GC-heap limit falls toward `retained + 3 MiB` (minimum 10 MiB), which is
    the smallest headroom any pref can reach.
  - It affects only the GC heap, not malloc. It is experimental and off by default.
- **`javascript.options.compact_on_user_inactive_delay`**, e.g. 30000. This only moves the single
  `USER_INACTIVE` shrinking GC earlier; it is one-shot, not periodic. It is useful as a probe of whether the
  refresh driver blocks that GC.
- **macOS memory pressure.**
  - `browser.lowMemoryResponseMask` is **0 in release** (3 only on Nightly), so release ignores OS pressure
    ([firefox.js#L1248-L1280](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L1248-L1280)).
  - Bit `0x1` unloads tabs, if `browser.tabs.unloadOnLowMemory`, which is true on macOS; bit `0x2` sends
    `memory-pressure`
    ([AvailableMemoryWatcherMac.cpp#L112-L122](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/AvailableMemoryWatcherMac.cpp#L112-L122),
    [#L462-L520](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/AvailableMemoryWatcherMac.cpp#L462-L520)).
  - The response starts when the OS level crosses into warn (with `browser.lowMemoryResponseOnWarn=true`) or
    critical, then repeats every `browser.lowMemoryPollingIntervalMS` (10000 ms, clamped 100…600000) while
    the level stays there
    ([AvailableMemoryWatcherMac.cpp#L396-L441](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/AvailableMemoryWatcherMac.cpp#L396-L441)).
  - Only the first notification is `low-memory`; repeats are `low-memory-ongoing`
    ([nsMemoryPressure.cpp#L67-L86](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/threads/nsMemoryPressure.cpp#L67-L86)),
    and nsJSEnvironment ignores those.
  - On `low-memory` or `heap-minimize` the parent runs a shrinking GC, a CC, and a second shrinking GC if
    needed ([nsJSEnvironment.cpp#L1445-L1471](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/nsJSEnvironment.cpp#L1445-L1471))
    and forwards the topic to content
    ([ContentParent.cpp#L3888-L3892](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/ipc/ContentParent.cpp#L3888-L3892)).
  - cache2 purges memory entries on any `memory-pressure`, including `ongoing`
    ([CacheObserver.cpp#L251-L258](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheObserver.cpp#L251-L258)).
  - All of this needs real OS pressure, so it is not a periodic trigger on a healthy Mac. The gate pref is
    `javascript.options.gc_on_memory_pressure` (default true off Android)
    ([StaticPrefList.yaml#L9989-L9998](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L9989-L9998)).
- **`dom.memory.memory_pressure_on_background`** = 2 or 3 makes a content process send itself
  `heap-minimize` or `low-memory` once, when its priority drops to BACKGROUND
  ([ContentChild.cpp#L2920-L2934](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/ipc/ContentChild.cpp#L2920-L2934),
  [StaticPrefList.yaml#L4015-L4022](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L4015-L4022)).
  It is one-shot and content-only.
- **Not found in 159**: `memory.free_dirty_pages`, `memory.low_memory_notification_interval_ms`, and any time-based
  `javascript.options.mem.*` major-GC pref.
- **The only periodic option** is an outside poke of the path already measured: `memory-pressure` /
  `heap-minimize` from privileged code, or `minimizeMemoryUsage`, which sends it 3 times
  ([nsMemoryReporterManager.cpp#L2774-L2808](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsMemoryReporterManager.cpp#L2774-L2808)).

## 5. Why the idle parent never GCs

- Gecko's event triggers don't recur here:
  - `LOAD_END`, `PAGE_HIDE` and `SET_DOC_SHELL` need navigation.
  - `USER_INACTIVE` fires once, ~5 min 5 s after startup, and only if no regular-rate refresh-driver timer
    is ticking. After that, nothing re-arms it without real input.
  - `FULL_GC_TIMER` and `CC_FINISHED` only follow a GC or CC that already happened.
  - Memory pressure is off in release (`lowMemoryResponseMask=0`).
- The JS triggers scale with the heap. A zone GCs only when its tenured GC heap reaches
  `max(retained, 27 MiB) × 1.5`, i.e. +50 % over what the last GC kept and at least 40.5 MiB. Its counted
  malloc must reach `max(retained, 38 MiB) × 1.5` (at least 57 MiB) for the malloc trigger. Per-request JS
  garbage mostly dies in the nursery; minor GCs clear it without growing the tenured heap, and only promoted
  survivors count.
- The parent `heap-unclassified` growth (~80 % of the ~90 MiB/h measured earlier) is XPCOM malloc. The JS engine never sees it:
  XPCWrappedNative reports twice the wrapper struct, and WebIDL objects such as ChannelWrapper report 0.
  So a channel kept alive only by a dead JS reflector costs the JS heap a few hundred bytes at most, and the
  malloc trigger is never approached.
- Periodic `TIMED` CCs can run, but they can't free natives behind wrappers created since the last GC,
  because those wrappers aren't gray. They free too little to trigger `CC_FINISHED`.
- Whether the tenured heap grows at all in the engine is the open measured question. `JS_GC_PROFILE=0` plus
  `JS_GC_PROFILE_NURSERY=0` on stderr answers it: SizeKB/MllcKB on major GCs, PRate on minor ones.
