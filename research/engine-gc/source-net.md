# Engine memory: what Firefox 159.0.1 source says (network, webRequest, Remote Settings)

All links point at tag `FIREFOX_159_0_1_RELEASE` of mozilla-firefox/firefox, and the line numbers were checked against that tag.
Read from a sparse clone at `/tmp/egc-src2/firefox`. Text marked "inference" is my reading and is not spelled out in the source.

Base: `https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/`

## 1. webRequest and ChannelWrapper

**Process.** webRequest runs in the parent.
- The parent API passes every extension listener on to `WebRequest[eventName].addListener` ([parent/ext-webRequest.js#L36-L106](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/parent/ext-webRequest.js#L36-L106)).
- The parent `nsHttpChannel` fires `http-on-modify-request` through the global observer service. This is the parent side of every content HTTP load ([nsHttpChannel.cpp#L828-L834](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L828-L834), [HttpBaseChannel.h#L666-L670](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/HttpBaseChannel.h#L666-L670), [nsHttpHandler.h#L368-L370](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpHandler.h#L368-L370), [nsHttpHandler.cpp#L908-L913](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpHandler.cpp#L908-L913)).

**Observers.** `HttpObserverManager.addOrRemove()` subscribes to global topics. Nothing is subscribed per URL ([WebRequest.sys.mjs#L662-L730](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L662-L730)):
- `http-on-modify-request`: when any `onBeforeRequest` or `onErrorOccurred` listener exists, or DNR (declarativeNetRequest) is active.
- `http-on-before-connect`: for `onBeforeSendHeaders` and `onSendHeaders`.
- `http-on-examine-response`, `-cached-response` and `-merged-response`: when any listener is blocking-allowed, or any `onHeadersReceived`, `onAuthRequired`, `onResponseStarted`, `onCompleted` or `onErrorOccurred` listener exists.
- A global ChannelEventSink for redirects, whenever any of the above is on.
- `http-on-stop-request` is not used. Start, stop and error come as DOM events on the ChannelWrapper ([L637-L655](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L637-L655), [L815-L830](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L815-L830)).

**Every HTTP channel gets a ChannelWrapper, not only the channels that match a filter.**
- `observe()` calls `getWrapper(subject)`, and so `ChannelWrapper.get()`, for every channel the topic fires on. It does this before it checks any filter ([L747-L764](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L747-L764), [L637-L655](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L637-L655)).
- The filter (URL patterns, types, tab, `canModify`) is checked later, per listener, in `runChannelListener` through `channel.matches()` ([L878-L897](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L878-L897)).
- So once one such listener is registered, by any add-on and with any filter, every parent HTTP channel is wrapped at every observed stage. That includes am's `POST /report` every second and its EventSource.

**JS garbage for every channel, matched or not:**
- the expando `wrapper._addedListeners = true` ([L652](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L652));
- a Promise per event, because `runChannelListener` returns the `async` `applyChanges(...)` ([L964-L981](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L964-L981));
- the URL read into a JS string (`finalURL`) ([L980](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L980)).

**Matched channels only:**
- `getRequestData` builds a details object and wraps `channel.channel` in XPConnect for a QueryInterface ([L766-L768](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L766-L768), [L910-L918](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L910-L918)).
- Blocking listeners also call `registerTraceableChannel`, which adds a WebRequestService entry ([L920-L922](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L920-L922), [ChannelWrapper.cpp#L846-L873](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L846-L873)).

**References:**
- **ChannelWrapper to channel is weak**: an `nsWeakPtr` plus a non-owning raw pointer ([ChannelWrapper.h#L49-L106](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.h#L49-L106)).
- **Channel to ChannelWrapper is strong.** `Get()` stores a `ChannelWrapperStub` in the channel's property bag under `ChannelWrapper::CachedInstance`, and the stub holds a `RefPtr` to the wrapper ([ChannelWrapper.cpp#L52](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L52), [L149-L171](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L149-L171), [ChannelWrapper.h#L291-L308](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.h#L291-L308)). The wrapper therefore lives as long as the channel.
- Each wrapper also sits in a static linked list. The list does not own it, and the destructor removes it ([ChannelWrapper.cpp#L84-L110](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L84-L110), [L127-L140](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L127-L140)).
- **The JS reflector is preserved.**
  - ChannelWrapper is a wrapper-cached `DOMEventTargetHelper` ([ChannelWrapper.h#L111-L117](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.h#L111-L117)). Such classes get `JSCLASS_PRESERVES_WRAPPER` ([Codegen.py#L293-L297](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/bindings/Codegen.py#L293-L297), [L735-L736](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/bindings/Codegen.py#L735-L736)).
  - Adding an own property, such as `_addedListeners` or `_browserData` ([L848-L859](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/WebRequest.sys.mjs#L848-L859)), preserves the reflector ([NativeObject.cpp#L1199-L1240](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/src/vm/NativeObject.cpp#L1199-L1240)).
  - Inference: once the channel lets go of the stub, a preserved reflector and its C++ object form a pair that only the cycle collector frees.
- **What keeps the `nsHttpChannel` alive until a GC** (inference from XPConnect, not webRequest-specific code):
  - A JS observer receives the `subject` as an XPConnect wrapped native. An `XPCWrappedNative` holds its native (`mIdentity`) and its tear-off natives until GC finalizes its JS object ([XPCWrappedNative.cpp#L680-L690](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/xpconnect/src/XPCWrappedNative.cpp#L680-L690), [L731-L777](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/js/xpconnect/src/XPCWrappedNative.cpp#L731-L777)).
  - So each channel the webRequest observer touches lives until the next parent GC. Then the channel dies, its property bag drops the stub and the wrapper, and a CC frees the preserved reflector. This matches "a forced GC+CC frees it all".
- **What a lingering channel still holds.**
  - It has already dropped its cache entry in `CloseCacheEntry` ([nsHttpChannel.cpp#L6175-L6260](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L6175-L6260)).
  - It has dropped its listener and callbacks, where `HttpChannelParent` sits, in `ReleaseListeners` ([HttpBaseChannel.cpp#L4777-L4786](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/HttpBaseChannel.cpp#L4777-L4786)).
  - It still holds its own URI, headers, LoadInfo and so on. I did not trace these member by member (inference).
- **Maps keyed by channel id.**
  - None in the WebRequest core for unmatched channels (not found).
  - `addons-search-detection` keeps `firstMatchedUrls[requestId]` only for matched `main_frame` requests, and deletes it on stop ([search-detection api.js#L216-L218](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/search-detection/extension/api.js#L216-L218), [L242-L243](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/search-detection/extension/api.js#L242-L243)).

## 2. The three add-ons with `webRequest`

**How they ship.**
- All three are "built-in system add-ons". `browser/extensions/moz.build` builds them ([L5-L12](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/moz.build#L5-L12)), and each jar.mn copies its files to `builtin-addons/<dir>/` ([webcompat jar.mn#L10-L16](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/jar.mn#L10-L16), [search-detection jar.mn#L6](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/search-detection/jar.mn#L6), [ipp-activator jar.mn#L6-L7](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/jar.mn#L6-L7)).
- The build writes every `builtin-addons/*/manifest.json` into `built_in_addons.json` ([gen_built_in_addons.py#L88-L105](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/gen_built_in_addons.py#L88-L105)).
- The XPI provider loads that file as the location `app-builtin-addons` (scope `SCOPE_APPLICATION` = 4), which is locked, hidden and counts as system ([XPIProvider.sys.mjs#L101-L105](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L101-L105), [L1035-L1100](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L1035-L1100), [L2722-L2731](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L2722-L2731)).
- These are not `maybeInstallBuiltinAddon` installs; that path is for the default theme ([L2786-L2790](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L2786-L2790)).
- Updated copies can also arrive from Balrog into `app-system-addons` (scope PROFILE), via `extensions.systemAddon.update.enabled` = true ([firefox.js#L54-L56](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L54-L56), [XPIProvider.sys.mjs#L2568-L2574](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L2568-L2574)).

**The off switch for all three: `extensions.<id before "@">.enabled = false`.**
- During add-on DB reconciliation, every add-on in a system location (`app-system-addons` or `app-builtin-addons`) gets `userDisabled = !getBoolPref("extensions." + id.split("@")[0] + ".enabled", true)` ([XPIDatabase.sys.mjs#L3639-L3644](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIDatabase.sys.mjs#L3639-L3644), [L3822-L3827](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIDatabase.sys.mjs#L3822-L3827)). That gives:
  - `extensions.webcompat.enabled = false` (webcompat@mozilla.org)
  - `extensions.addons-search-detection.enabled = false` (addons-search-detection@mozilla.com)
  - `extensions.ipp-activator.enabled = false` (ipp-activator@mozilla.com)
- The value is read only inside `processFileChanges`, which runs at startup when something changed. A fresh profile counts, and so do an app change or a directory change ([XPIProvider.sys.mjs#L3334-L3416](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L3334-L3416)). Put it in `user.js` before the profile's first start. No pref observer for it was found.
- Inference: on a reused profile, deleting `addonStartup.json.lz4` forces a full rescan ([L1564-L1571](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L1564-L1571)).

**`extensions.enabledScopes` and `extensions.startupScanScopes`.**
- A location is added only if `enabledScopes & scope`, and the profile scope is always on ([L161-L166](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L161-L166), [L2635-L2649](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L2635-L2649)). The scope values are PROFILE 1, USER 2, APPLICATION 4, SYSTEM 8 ([AddonManager.sys.mjs#L4247-L4257](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/AddonManager.sys.mjs#L4247-L4257)).
- am's `enabledScopes = 5` contains APPLICATION, so the built-ins load.
- `enabledScopes = 1` would drop `app-builtin-addons`, and with it every built-in (also formautofill, pictureinpicture, newtab). It would also skip the default-theme install ([L3295-L3309](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L3295-L3309)). It would still keep Balrog-updated system add-ons, because their scope is PROFILE.
- `startupScanScopes` (firefox.js default 0, [L61-L62](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L61-L62)) only limits sideload scanning. Missing built-in location data is rescanned anyway ([XPIProvider.sys.mjs#L1559-L1601](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/XPIProvider.sys.mjs#L1559-L1601)).

### webcompat (`browser/extensions/webcompat`, id `webcompat@mozilla.org`, version 159.3.0)
- Permissions: `webRequest`, `webRequestBlocking`, `<all_urls>`, among others ([manifest.json#L82-L91](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/manifest.json#L82-L91)).
- Interventions register:
  - `onBeforeRequest` blocking, for request blocks;
  - `onBeforeSendHeaders` blocking with `requestHeaders`, for UA overrides.
  - Both use the URL patterns of the active interventions as their filter, and no listener at all when the list is empty ([lib/interventions.js#L66-L80](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/interventions.js#L66-L80), [L302-L328](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/interventions.js#L302-L328)).
  - Custom functions add more `onBeforeRequest` and header listeners on their own URL lists ([lib/custom_functions.js#L126-L193](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/custom_functions.js#L126-L193)).
  - 231 intervention files carry a `ua_string` (counted in `data/interventions/`).
- Shims register at construction (all blocking, each filtered to the shims' URL lists) ([lib/shims.js#L642-L784](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/shims.js#L642-L784)):
  - `onBeforeRequest` for storage-access redirects (`main_frame`);
  - `onBeforeRequest` for logos (`image`);
  - `onBeforeSendHeaders` and `onHeadersReceived` for header shims;
  - `onBeforeRequest` on all shim match patterns.
- Prefs (`extensions.webcompat.` prefix, [experiment-apis/aboutConfigPrefs.js#L26](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/experiment-apis/aboutConfigPrefs.js#L26); defaults [all.js#L4220-L4225](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L4220-L4225)):
  - `extensions.webcompat.enable_interventions = false` disables the interventions. Their listeners are removed, because the pattern set empties ([interventions.js#L443-L458](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/interventions.js#L443-L458)).
  - `extensions.webcompat.enable_shims = false` only flips `this.enabled`. The shim webRequest listeners stay registered and return early ([shims.js#L505-L512](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/shims.js#L505-L512), [L797-L799](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/shims.js#L797-L799), [L1159-L1164](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/lib/shims.js#L1159-L1164)). It therefore does not stop the per-channel ChannelWrapper.
  - Only `extensions.webcompat.enabled = false` removes all of webcompat's listeners.
- Apple: the only apple.com intervention is `developer.apple.com`, which is Android-only CSS ([data/interventions/1925508-developer.apple.com.json](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/data/interventions/1925508-developer.apple.com.json)). No intervention or shim names music.apple.com, js-cdn.music.apple.com, itunes or mzstatic (grep of `data/`, `shims/`, `injections/`, `lib/`).
- New interventions can arrive later through the Remote Settings collection `webcompat-interventions` ([experiment-apis/remoteSettings.js#L17](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/webcompat/experiment-apis/remoteSettings.js#L17)).
- What am would lose: nothing Apple-specific today. It would lose generic SmartBlock shims for trackers blocked by ETP (Enhanced Tracking Protection) and any future Apple Music fix.

### addons-search-detection (`browser/extensions/search-detection`, id `addons-search-detection@mozilla.com`)
- Its background script listens to its own experiment event, filtered to the base URLs of the search engines ([extension/background.js#L35-L64](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/search-detection/extension/background.js#L35-L64)).
- That event registers two parent-process listeners, both limited to `main_frame` plus the engine URL patterns ([extension/api.js#L267-L294](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/search-detection/extension/api.js#L267-L294)):
  - `WebRequest.onBeforeRequest`, blocking, with a no-op body;
  - `WebRequest.onBeforeRedirect`.
- Engines are fetched after first paint, if SearchService is not loaded yet ([L55-L70](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/search-detection/extension/api.js#L55-L70)).
- Purpose: telemetry when an add-on redirects searches. am loses nothing.
- Off switch: only `extensions.addons-search-detection.enabled = false`. No add-on-specific pref was found.

### ipp-activator (`browser/extensions/ipp-activator`, id `ipp-activator@mozilla.com`)
- Manifest: permissions `tabs`, `cookies`, `webRequest`, `<all_urls>` ([manifest.json#L6-L9](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/manifest.json#L6-L9)).
- It shows "this site may break with IP Protection" notices.
- Its one webRequest listener is `onBeforeRequest` on `<all_urls>` with types `media`, `sub_frame`, `xmlhttprequest` (which would cover `fetch`). It registers that listener only if the webRequest breakage list is non-empty ([extension/bg.js#L110-L136](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/extension/bg.js#L110-L136)).
- The list is empty by default:
  - The base list `breakages/webrequest.json` is not in the tree; only `tab.json` ships ([extension/breakages/](https://github.com/mozilla-firefox/firefox/tree/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/extension/breakages)). The fetch fails and the code returns `[]` ([bg.js#L57-L80](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/extension/bg.js#L57-L80)).
  - The dynamic list `extensions.ippactivator.dynamicWebRequestBreakages` defaults to `"[]"` ([api/parent/ext-ipp.js#L32-L39](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/extension/api/parent/ext-ipp.js#L32-L39), [L110-L121](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/extensions/ipp-activator/extension/api/parent/ext-ipp.js#L110-L121)).
- So by default it holds the permission but registers no webRequest listener. It does register `tabs.onUpdated`, because `tab.json` is non-empty.
- `browser.ipProtection.enabled` defaults to false ([firefox.js#L3785](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L3785)). No pref inside the add-on gates its startup.
- Off switch: `extensions.ipp-activator.enabled = false`. am loses nothing.

**Net for the measurement:**
- webcompat and search-detection both register parent webRequest listeners, so either one alone keeps the per-channel ChannelWrapper going.
- Disabling both removes the observers, because `addOrRemove` unsubscribes when no listeners are left.
- ipp-activator does not matter for webRequest unless its breakage pref is set.

## 3. Network process

**Which pref moves HTTP.**
- HTTP leaves the parent only when `network.process.enabled` **and** `network.http.network_access_on_socket_process.enabled` are both true ([nsIOService.cpp#L665-L691](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/base/nsIOService.cpp#L665-L691)).
- Defaults: `network.process.enabled` = true on desktop ([StaticPrefList.yaml#L15594-L15601](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L15594-L15601)); `network.http.network_access_on_socket_process.enabled` = false ([L15652-L15655](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L15652-L15655)).
- `network.process.enabled` alone only launches the socket process ([nsIOService.cpp#L598-L640](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/base/nsIOService.cpp#L598-L640)). Inference: am's `false` changes nothing for HTTP.

**Where the per-request objects live.**
- **Default:** the parent owns the connection manager ([nsHttpHandler.cpp#L640-L660](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpHandler.cpp#L640-L660)). Each nsHttpChannel creates its own `nsHttpTransaction` ([nsHttpChannel.cpp#L2205-L2209](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L2205-L2209)), so transactions, connections and sockets are all in the parent.
- **Both prefs true:**
  - The parent keeps an `HttpTransactionParent` proxy per request ([nsHttpChannel.cpp#L2162-L2204](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L2162-L2204)).
  - The socket process creates `HttpTransactionChild` → `nsHttpTransaction` and owns the sockets ([SocketProcessChild.cpp#L419-L420](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/ipc/SocketProcessChild.cpp#L419-L420), [HttpTransactionChild.cpp#L161](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/HttpTransactionChild.cpp#L161)).
- **Always in the parent:**
  - nsHttpChannel and LoadInfo; HttpChannelParent builds the real channel ([HttpChannelParent.cpp#L499-L516](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/HttpChannelParent.cpp#L499-L516)).
  - cache2 entries (§6).
  - All `http-on-*` notifications, and so webRequest and ChannelWrapper ([nsHttpHandler.h#L368-L408](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpHandler.h#L368-L408)).
  - A weak channel-id map entry that lives until `~nsHttpChannel` ([nsHttpChannel.cpp#L2213](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L2213), [L485-L508](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L485-L508), [nsHttpHandler.cpp#L2962-L2986](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpHandler.cpp#L2962-L2986)).

**`keepalive:true` runs the whole fetch in the parent.**
- A main-thread fetch without keepalive uses a FetchDriver in content ([Fetch.cpp#L568](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/fetch/Fetch.cpp#L568)). With keepalive it goes over PFetch instead ([Fetch.cpp#L625-L667](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/fetch/Fetch.cpp#L625-L667)), and FetchParent hands it to FetchService ([FetchParent.cpp#L220-L240](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/fetch/FetchParent.cpp#L220-L240)).
- FetchService then builds, per request, a principal, a new LoadGroup, a FetchDriver and a channel in the parent ([FetchService.cpp#L171-L194](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/fetch/FetchService.cpp#L171-L194), [L226-L300](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/fetch/FetchService.cpp#L226-L300)).
- Inference: dropping `keepalive` moves the FetchDriver, InternalRequest and InternalResponse, and LoadGroup back to content.

**The socket process runs no JS by default.**
- It starts with `NS_InitMinimalXPCOM` ([SocketProcessChild.cpp#L174](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/ipc/SocketProcessChild.cpp#L174)).
- It starts JS only to parse PAC files ([L731-L750](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/ipc/SocketProcessChild.cpp#L731-L750)), and only when `network.proxy.parse_pac_on_socket_process` is true (default false, [StaticPrefList.yaml#L16065-L16068](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L16065-L16068)).
- So it has no XPConnect and no GC.

## 4. WebSocket and localhost

**The handshake is one HTTP channel per connection, in the parent.**
- `WebSocketChannelParent::RecvAsyncOpen` rebuilds the LoadInfo in the parent ([WebSocketChannelParent.cpp#L55-L100](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannelParent.cpp#L55-L100)).
- `WebSocketChannel::AsyncOpen` rewrites ws to http and creates an HTTP channel ([WebSocketChannel.cpp#L3585-L3604](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannel.cpp#L3585-L3604)).
- That channel uses `LOAD_BACKGROUND | INHIBIT_CACHING | LOAD_BYPASS_CACHE` and `HTTPUpgrade("websocket")` ([L2834-L2859](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannel.cpp#L2834-L2859)), so it gets no cache entry ([nsHttpChannel.cpp#L5073-L5078](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5073-L5078)).
- webRequest sees it as type `websocket`, with a ws:// URL ([WebSocket.cpp#L1729](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/websocket/WebSocket.cpp#L1729), [ChannelWrapper.cpp#L954-L955](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L954-L955), [L602-L614](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/extensions/webrequest/ChannelWrapper.cpp#L602-L614)).
- So the §1 per-channel cost happens once per connect or reconnect, not once per message.

**Cost per sent message in the parent.**
- Content's `SendMsg` sends one IPC message ([WebSocketChannelChild.cpp#L639-L657](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannelChild.cpp#L639-L657)). The parent forwards it to `WebSocketChannel::SendMsg` ([WebSocketChannelParent.cpp#L175-L183](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannelParent.cpp#L175-L183)).
- That allocates one C++ `OutboundMessage` holding a payload copy, plus a runnable for the socket thread ([WebSocketChannel.cpp#L3737-L3776](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannel.cpp#L3737-L3776)). Both are deleted once written ([L2281-L2285](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannel.cpp#L2281-L2285)).
- A `WebSocketFrame` is built only while a devtools WebSocketEventService listener exists ([WebSocketEventService.cpp#L518-L527](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketEventService.cpp#L518-L527), [WebSocketChannel.cpp#L2238-L2251](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/websocket/WebSocketChannel.cpp#L2238-L2251)).
- No channel, observer notification, JS object or webRequest event is created per message.

**EventSource** opens with `LOAD_BYPASS_CACHE | INHIBIT_CACHING`, so it gets no cache entry ([EventSource.cpp#L1055-L1058](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/base/EventSource.cpp#L1055-L1058)). Inference: it is one long-lived channel and one ChannelWrapper per connection.

**Mixed content.** ws:// is refused only from a secure context, and never for a loopback host ([WebSocket.cpp#L1866-L1882](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/websocket/WebSocket.cpp#L1866-L1882)). An http page calling http is not mixed content.

**LNA (Local Network Access) does not block or prompt localhost to localhost, for ws:// or fetch.**
- `network.lna.enabled` and `network.lna.blocking` both default to true ([StaticPrefList.yaml#L15918-L15927](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L15918-L15927)).
- But an LNA request is only Public→Private, Public→Local or Private→Local ([nsNetUtil.cpp#L4334-L4368](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/base/nsNetUtil.cpp#L4334-L4368)). Local→Local is allowed ([nsHttpTransaction.cpp#L4258-L4338](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpTransaction.cpp#L4258-L4338)).
- Escape hatches if ever needed: `network.lna.websocket.enabled`, `network.lna.skip-domains` ([StaticPrefList.yaml#L15943-L15955](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L15943-L15955)).
- Same-origin `/report` needs no CORS preflight.

## 5. Remote Settings, push and timers

**How a push broadcast triggers a sync.**
- Remote Settings (RS) listens on the broadcast ID `remote-settings/monitor_changes` ([remote-settings.sys.mjs#L37-L38](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/remote-settings.sys.mjs#L37-L38)).
- `RemoteSettings.init()` registers it with `pushBroadcastService.addListener`. A fresh profile sends version `"0"`, so the server answers with the current version ([L744-L770](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/remote-settings.sys.mjs#L744-L770)).
- `init()` is a BrowserGlue best-effort idle task. It runs after 20 s of user idle ([BrowserGlue.sys.mjs#L142](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/BrowserGlue.sys.mjs#L142), [L1241-L1262](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/BrowserGlue.sys.mjs#L1241-L1262)).
- The handler calls `pollChanges` with trigger `"startup"` in the hello/register phase and `"broadcast"` otherwise ([L775-L792](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/remote-settings.sys.mjs#L775-L792)). The push hello carries all broadcast IDs ([PushServiceWebSocket.sys.mjs#L1096-L1100](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/push/PushServiceWebSocket.sys.mjs#L1096-L1100)); later server pushes arrive as BROADCAST ([L839-L853](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/push/PushServiceWebSocket.sys.mjs#L839-L853)).
- `pollChanges` fetches `monitor/changes`, runs `maybeSync` for each changed collection, and fires `remote-settings:changes-poll-end` after every successful poll, even when nothing changed ([remote-settings.sys.mjs#L349-L621](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/remote-settings.sys.mjs#L349-L621)).

**Fresh profile.**
- The `update-timer` entry `services-settings-poll-changes` uses `services.settings.poll_interval` ([servicesSettings.manifest#L4-L7](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/servicesSettings.manifest#L4-L7)). all.js sets it to 86400 s, which is 24 h ([all.js#L1739](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L1739)).
- A timer that has no lastUpdateTime pref counts as overdue ([UpdateTimerManager.sys.mjs#L205-L207](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/timermanager/UpdateTimerManager.sys.mjs#L205-L207)). It fires on the first tick, which comes after `app.update.timerFirstInterval` = 30 s ([L97-L107](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/timermanager/UpdateTimerManager.sys.mjs#L97-L107), [firefox.js#L97-L102](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L97-L102)).
- A `.get()` on an empty collection without a dump also syncs it ([RemoteSettingsClient.sys.mjs#L476-L499](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/RemoteSettingsClient.sys.mjs#L476-L499)).

**Prefs that stop push-triggered syncs:**
- `dom.push.connection.enabled = false` (default true; "should be used in UX to enable/disable push", [all.js#L3216-L3218](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L3216-L3218)).
  - PushService goes to CONNECTION_DISABLE and the WebSocket closes ([PushService.sys.mjs#L243-L262](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/push/PushService.sys.mjs#L243-L262)). The pref is watched live.
  - It takes away site Web Push, which am doesn't use, and instant RS updates.
- `dom.push.enabled = false` (default true, [StaticPrefList.yaml#L4321-L4325](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L4321-L4325)).
  - PushService never initializes ([PushComponents.sys.mjs#L19-L28](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/push/PushComponents.sys.mjs#L19-L28)). Broadcast subscription is a no-op unless push is running ([PushService.sys.mjs#L1197-L1206](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/push/PushService.sys.mjs#L1197-L1206)).
  - It takes away the same two things.
- `dom.push.serverURL = ""` also leaves push with no service ([PushService.sys.mjs#L388-L391](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/push/PushService.sys.mjs#L388-L391)).
- With push off, RS still polls on the 24 h timer above.
- `services.settings.server` can't turn RS off on release builds; the override is ignored ([Utils.sys.mjs#L43-L78](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/Utils.sys.mjs#L43-L78)).
- The only full off switch is the enterprise policy `DisableRemoteSettingsAndAcceptSecurityConsequences` ([Policies.sys.mjs#L1390-L1396](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/enterprisepolicies/Policies.sys.mjs#L1390-L1396), [Utils.sys.mjs#L121-L129](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/Utils.sys.mjs#L121-L129)).

**Security collections (bucket `security-state`).**
- `RemoteSecuritySettings.init` creates the clients `onecrl`, `intermediates` and `cert-revocations` (CRLite) ([RemoteSecuritySettings.sys.mjs#L244-L289](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L244-L289)).
- Intermediates and CRLite run on every `changes-poll-end`, whether the poll came from push or the timer ([L293-L306](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L293-L306), [L578-L590](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L578-L590)). Turning push off delays them to the 24 h poll but does not stop them.
- **Intermediates** (`security.remote_settings.intermediates.enabled` = true; `downloads_per_poll` 5000; `parallel_downloads` 8; [all.js#L53-L58](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L53-L58)).
  - On a fresh profile it runs `attachments.cacheAll()`, which downloads a zip bundle via `resp.arrayBuffer()` ([L379-L388](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L379-L388), [Attachments.sys.mjs#L183-L271](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/Attachments.sys.mjs#L183-L271)).
- **CRLite** (`security.remote_settings.crlite_filters.enabled` = true, [all.js#L58](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L58); `security.pki.crlite_mode` = 2, [StaticPrefList.yaml#L19226-L19247](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L19226-L19247)).
  - On every poll-end, `isFilterOnDisk` reads the whole `crlite.filter` into a JS Uint8Array and SHA-256-hashes it ([L559-L576](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L559-L576)).
  - Missing filters are downloaded as an ArrayBuffer ([L598-L618](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L598-L618), [Attachments.sys.mjs#L547-L596](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/services/settings/Attachments.sys.mjs#L547-L596)). No `cert-revocations` dump ships ([dumps/security-state](https://github.com/mozilla-firefox/firefox/tree/FIREFOX_159_0_1_RELEASE/services/settings/dumps/security-state)).
  - The source has no size comment. Inference: a filter of about 16.8 MiB would explain the System-global ArrayBuffer.
  - `crlite_filters.enabled = false` skips download and install ([L631-L640](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/security/manager/ssl/RemoteSecuritySettings.sys.mjs#L631-L640)).
- **OneCRL** updates `cert_storage` on each sync and from its bundled dump.

**Widevine/GMP is independent of RS and push.**
- `GMPInstallManager.checkForAddons` fetches Balrog `media.gmp-manager.url` (aus5) and checks the content signature itself ([all.js#L3478](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L3478), [GMPInstallManager.sys.mjs#L283-L313](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/modules/GMPInstallManager.sys.mjs#L283-L313)).
- It runs from the same 20 s-idle BrowserGlue task, at most once per `media.gmp-manager.secondsBetweenChecks` (86400 s) ([BrowserGlue.sys.mjs#L1243-L1251](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/components/BrowserGlue.sys.mjs#L1243-L1251), [GMPInstallManager.sys.mjs#L564-L588](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/modules/GMPInstallManager.sys.mjs#L564-L588)).
- It also runs on `EMEVideo:CDMMissing` ([GMPProvider.sys.mjs#L636-L638](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/internal/GMPProvider.sys.mjs#L636-L638)).

**Other fresh-profile timers in the first hour that could explain multi-MiB allocations:**
- At the first tick (~30 s): app update `background-update-timer` ([nsUpdateService.manifest#L1](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/update/nsUpdateService.manifest#L1)), the add-on update and `glean-addons-daily` timers ([extensions.manifest#L2-L4](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/mozapps/extensions/extensions.manifest#L2-L4)), and the RS poll.
- Normandy (`app.normandy.enabled` = true, 6 h interval, runs at once on first run) ([firefox.js#L3091-L3099](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/browser/app/profile/firefox.js#L3091-L3099), [RecipeRunner.sys.mjs#L96-L127](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/normandy/lib/RecipeRunner.sys.mjs#L96-L127)).
  - After an RS sync of its collection it re-runs, with a random 1–600 s delay ([L255-L281](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/normandy/lib/RecipeRunner.sys.mjs#L255-L281)).
- Nimbus `rs-experiment-loader-timer` (6 h, fires soon after registration) ([RemoteSettingsExperimentLoader.sys.mjs#L1002-L1025](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/nimbus/lib/RemoteSettingsExperimentLoader.sys.mjs#L1002-L1025)).
- Safe Browsing:
  - The tracking-protection lists come from RS, each list as an ArrayBuffer turned byte by byte into one large JS string. They are forced on new profiles and repeat every 6 h ([UrlClassifierRemoteSettingsService.sys.mjs#L95-L112](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/url-classifier/UrlClassifierRemoteSettingsService.sys.mjs#L95-L112), [all.js#L3433-L3439](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/all.js#L3433-L3439)).
  - Google v4/v5 lists update every 30 min by default and are parsed in C++ ([UrlClassifierListManager.sys.mjs#L18-L24](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/url-classifier/UrlClassifierListManager.sys.mjs#L18-L24)).
- Region: a 7-day timer, small ([Region.sys.mjs#L100-L107](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/modules/Region.sys.mjs#L100-L107)).
- Telemetry scheduler: 5 min ticks, not tied to the wall clock ([TelemetryScheduler.sys.mjs#L33-L51](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/toolkit/components/telemetry/app/TelemetryScheduler.sys.mjs#L33-L51)).

**Why steps could line up across instances in the same wall-clock minute (inference):**
- **Server-driven.** A megaphone broadcast reaches every connected client at once. Each one then polls, and the poll-end triggers the CRLite read and the intermediates check.
- **Machine-wide idle.** macOS idle time is system-wide HID idle ([nsUserIdleServiceX.mm#L9-L37](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/widget/cocoa/nsUserIdleServiceX.mm#L9-L37)). So the 20 s-idle BrowserGlue tasks and the first `idle-daily` (after 3 min idle) fire in every instance when the user stops typing ([nsUserIdleService.cpp#L171-L184](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/widget/nsUserIdleService.cpp#L171-L184)).
- **Per-profile timers** count from each instance's own start, so they would not line up.

## 6. HTTP cache

**Every POST gets its own key.**
- A POST channel gets a unique `mPostID` ([nsHttpChannel.cpp#L1450-L1457](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L1450-L1457)), which is appended to the cache id. POST is allowed to open an entry ([L5025-L5031](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5025-L5031), [L5111-L5113](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5111-L5113)).
- So each `/report` makes one entry that is never reused.

**Why the entry is memory-only.**
- It is opened through disk storage ([L5200-L5208](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5200-L5208)).
- `no-store` sets `INHIBIT_PERSISTENT_CACHING` ([L6345-L6351](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L6345-L6351)).
- `InitCacheEntry` then reopens it as memory-only ([L6296-L6320](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L6296-L6320), [CacheEntry.cpp#L589-L617](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheEntry.cpp#L589-L617)).
- This is on purpose: "all responses are cached", for Save As and View Source ([nsHttpResponseHead.cpp#L748-L754](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpResponseHead.cpp#L748-L754)).
- A 204 also goes through `ProcessNormal` → `InitCacheEntry` ([L3587-L3596](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L3587-L3596), [L3897-L3899](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L3897-L3899)).

**It is not freed when the request ends.**
- `CloseCacheEntry` dooms only failed or partial writes, and otherwise just `Dismiss()`es the handle ([L6175-L6261](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L6175-L6261)).
- The entry's expiration is 0 ([L5827-L5873](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5827-L5873)).

**When it is freed:**
- On `memory-pressure`, through `PurgeFromMemory(PURGE_EVERYTHING)` ([CacheObserver.cpp#L251-L258](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheObserver.cpp#L251-L258), [CacheStorageService.cpp#L954-L975](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheStorageService.cpp#L954-L975)). "Minimize memory usage" sends that signal and also frees jemalloc dirty pages ([nsMemoryReporterManager.cpp#L2766-L2809](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/xpcom/base/nsMemoryReporterManager.cpp#L2766-L2809)).
- When the memory pool goes over its limit:
  - The check runs only when an entry's size grows. The purge then runs on a 1 s timer, at most every 4 s, expired entries first ([CacheStorageService.cpp#L1293-L1459](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheStorageService.cpp#L1293-L1459)).
  - The limit is `browser.cache.memory.capacity` (-1 = automatic, capped at 32 MiB) ([CacheObserver.cpp#L99-L138](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheObserver.cpp#L99-L138), [StaticPrefList.yaml#L1166-L1170](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/modules/libpref/init/StaticPrefList.yaml#L1166-L1170)).
  - Only metadata and body buffers count toward the limit ([CacheFileMetadata.h#L213-L215](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheFileMetadata.h#L213-L215)). Inference: tiny entries take hours to reach 32 MiB, and nothing purges them before that.
- `browser.cache.memory.enable` = false is checked only when a memory storage is first opened, not on the disk→memory reopen ([CacheStorage.cpp#L64-L74](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/cache2/CacheStorage.cpp#L64-L74)). Inference: it does not stop these entries.

**Fixes:**
- Page-side, no pref needed: `fetch('/report', {method:'POST', keepalive:true, cache:'no-store'})`.
  - The cache mode reaches the channel ([FetchDriver.cpp#L790-L792](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/dom/fetch/FetchDriver.cpp#L790-L792)) and becomes `INHIBIT_CACHING | LOAD_BYPASS_CACHE` ([HttpBaseChannel.cpp#L4336-L4340](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/HttpBaseChannel.cpp#L4336-L4340)).
  - With those flags `OpenCacheEntryInternal` returns without opening an entry ([nsHttpChannel.cpp#L5073-L5078](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5073-L5078)). A request header `Cache-Control: no-store` also skips it ([L5065-L5071](https://github.com/mozilla-firefox/firefox/blob/FIREFOX_159_0_1_RELEASE/netwerk/protocol/http/nsHttpChannel.cpp#L5065-L5071)).
- Pref-side (inference): a small `browser.cache.memory.capacity`, such as 1024 KB, gets these entries purged within seconds.
