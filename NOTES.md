# Design and research notes

The first goal, for the Node prototype (`poc/`): play **one full-length Apple Music track** (not the 30 s preview) on Linux, driven from a terminal.
Constraint: no DRM circumvention. Audio is decrypted only inside a stock browser's Widevine module and goes browser → PipeWire.

Research ran on 2026-10-15, with every claim re-checked independently. The Firefox findings were also reproduced hands-on on a 4 GiB Debian 13 laptop.
Setup steps are in [SETUP.md](SETUP.md).

## Result (2026-10-15): goal reached

`node poc/am.mjs play --headless` played *Shy Away* (twenty one pilots, 2:55, id 1561837008) as **`encryptedFull`**, past 1:40, audibly, on a real account:

- Engine: stock firefox-esr 140, headless, with the **Widevine 4.10.3050.0 that Mozilla serves**. Apple's licence server accepted it; neither `FIREFOX_WIDEVINE=google` nor Chrome was needed.
- Audio path: Firefox's own CDM decrypts → Firefox audio stream → PipeWire → default sink. No stream extraction.
- Sign-in: `signin` via xdg-open in the desktop's normal Firefox, first try.
- Footprint while playing: 8 processes, 432 MiB PSS, 17 % of one core. Teardown leaves no processes.
- `doctor` on the signed-in setup: every check ✔ (codecs, Widevine, `browserSupportsVideoDrm`, MUT 200, authorized, subscription active).

## Architecture as built

```
node poc/am.mjs ──┬─ REST (search, token checks) ──────────▶ api.music.apple.com   (no browser)
                  │
                  └─ localhost:47823 (poc/server.mjs) ◀──▶ engine page (poc/web/) in a hidden browser
                       SSE /events  → commands (play, pause, drmProbe…)
                       WS /reports  ← state once a second + on events, one socket per page load
                       GET /user-token → Music User Token injected into MusicKit
```

- **No browser automation protocol.** The CLI launches a stock browser with a URL. The page connects back over Server-Sent Events, so Firefox and Chrome work the same way, `navigator.webdriver` stays false, and the port needs no chromedp/BiDi library.
- **Sign-in happens in the user's normal browser** (`xdg-open`). The page POSTs the Music User Token (MUT) to the CLI, which checks it with Apple and stores it in `~/.config/am/music-user-token`. The engine gets it injected. The same pattern is used by vibez and applemusic-mcp.
- **Each launch carries a nonce.** Firefox can restore the previous engine page next to the new one, and a second MusicKit instance would take over playback. Only the page with the current nonce runs.

## Verified facts the POC relies on

| Fact | Confidence |
|---|---|
| Full-track proof is `nowPlayingItem.playbackType === 3` (encryptedFull). Without DRM, auth or subscription, MusicKit **silently** plays previews (`playbackType 1`); it doesn't throw. | high (musickit.js 3.2526.0 source) |
| When a track ends, MusicKit clears `nowPlayingItem` **before** it reports `ended`/`completed`, so the verdict uses the last item seen while playing. Setting `musicUserToken` doesn't load the storefront; `music.me()` does (and returns `subscription.active`). With `suppressErrorDialog`, `play()` swallows most errors; `logHandler` is the only trace. | high (source, review-verified) |
| MusicKit decides DRM support once, in `configure()`, with `requestMediaKeySystemAccess('com.widevine.alpha', {persistentState:'required', video robustness SW_SECURE_CRYPTO, avc1 + mp4a})`. | high (source) |
| **Firefox ESR 140 works headless**: it fetches Widevine by itself on first use (5–20 s), passes MusicKit's exact probe, and decrypts and plays Widevine AAC to PipeWire. | high (reproduced 3× independently) |
| Firefox on Linux ships with `media.eme.enabled=false` (upstream default). It **must** be set in the engine profile, or MusicKit silently plays previews. `media.autoplay.default=0` is needed for headless audio. | high (source + runs) |
| Firefox gets Widevine **4.10.3050.0** from Mozilla; Chrome 155 bundles **4.10.3112.0**. `media.gmp-widevinecdm.force-chromium-update=true` (stock pref; skips Mozilla's hash check) gets 3112 from Google. Mozilla's rollout of 3112 is on Nightly since 2026-10-09. | high |
| Apple refuses outdated CDMs with `WIDEVINE_CDM_EXPIRED` (190121), decided server-side only. Firefox's 3050 was **accepted** on 2026-10-15. | high; it can change server-side at any time |
| Headless Chrome 155 (`.deb`, bundled Widevine) also works; vibez has done it since 2026-04. Playwright would mute it in headless (`--mute-audio`). | high (source); not run on the Linux test machine, which had no Chrome |
| Developer token: ES256, `{alg,kid}` + `{iss,iat,exp}`, max 15 777 000 s; no `origin` claim; extra claims (`aud`/`sub`) break the sign-in popup. Check with `GET /v1/test`. | high |
| The shared developer token (token-worker/, SETUP.md section 6) adds the `origin` claim Apple documents for web clients: `["http://localhost:47823","http://127.0.0.1:47823","http://[::1]:47823"]`. Apple should accept it only on requests whose Origin header is one of those, so the CLI, daemon and TUI send `Origin: http://localhost:47823` on every request to Apple (the engine page's browser sends its own). A token without the claim doesn't mind the header: `GET /v1/test` with it answered 200 (2026-10-26). | high (live, 2026-10-26, Worker deployed): `npm run check:token-service` (200 with `Origin: http://localhost:47823` on `/v1/test` and a catalog search; 401 with no Origin and with `https://example.com`), and `am token`, `am search`, `am signin` (Apple's popup) and `am play` (`encryptedFull`) on the shared token with an empty config dir |
| MusicKit reads its developer token once, at `configure()`: it checks the format and `exp` locally, never the signature, and has no setter. Apple refusing it shows only when MusicKit uses it. The account check then answers 401 and MusicKit signs the page out without an event (`isAuthorized` false, `me()` rejects `AUTHORIZATION_ERROR` "Unauthorized", the same as for a bad Music User Token), and plays fall back to previews. `music.api.music()` is the one call that rejects with the HTTP status (`UNAUTHORIZED_ERROR` for 401). So `am play` and the TUI's queue check the page before playing (the engine page module, `src/daemon/engine_page.zig`), right after Apple accepted the Music User Token with the current developer token (renewing a refused shared one once): a page MusicKit signed out reloads once, and so does one on another developer token than the current one whose own Apple refuses (the page's `checkDeveloperToken`). The page reports its token's `kid`, `exp` and the first 8 bytes of its SHA-256, never the token. `am doctor` does the same while the page holds no music and no play is on its way (`playback.Report.holdsMusic`, `Plays`): nothing that plays or is starting, no song paused, rewound or left in place after it ended, no queue on its way, no stopped live radio. One reload runs at a time: a play or `am doctor` that finds one in flight waits for its new load and decides again on it. A reload that doesn't come back within 60 s fails the play as not configured. Nothing reloads in the background, so a token refused mid-queue fails the next tracks until the next play. | high (live, 2026-10-27, Firefox 158): a page started on a token with a broken signature was signed out at configure (`meError` `AUTHORIZATION_ERROR | Unauthorized`), and the next `am play` downloaded once, reloaded once and played `encryptedFull`; `checkDeveloperToken` answered `refused` with `UNAUTHORIZED_ERROR | 401` on that token and `refused: false` on a good one (sign-in page in Chrome); a page on the shared token kept playing, with no reload, after an own token appeared. The source side: musickit.js 3.2526.0. One reload at a time and doctor's hold against plays: source and tests only |
| MUT lasts about 6 months. MusicKit counts any non-empty stored string as "authorized", so validity is checked with `GET /v1/me/storefront` (200 ok, 403 means sign in again). | high |
| Engine footprint (Firefox, lean prefs): about 420–470 MiB idle, 430–550 MiB while decrypting, 13–17 % of one core. | high (measured during real playback: 432 MiB PSS, 17 %) |
| Apple's terms forbid automated "measurement or monitoring" of Content, so the POC checks only PipeWire stream **metadata**, never the audio. | high |
| **macOS: Apple accepts Firefox's Widevine, and headless Firefox plays audio** with no window (Firefox 158, macOS 26.2): `encryptedFull` to 2:55, heard. Firefox already had Widevine on `doctor`'s first run. | high (Zig port, 2026-10-16) |
| macOS: after MusicKit's `stop()` on a song, Firefox's content process and Widevine helper often keep messaging each other at ~120 % CPU until a page reload, the next song or the engine's close. Pause + seek to 0:00 idles at ~0.5 %; the engine page's `stop` does that. A station queued over a song past 0:00 (playing, or paused mid-way) gets the same `stop()` as MusicKit swaps players, so the engine page pauses and rewinds a loaded song first. Live radio's own `stop()` doesn't spin. | high (reproduced 3/3 vs 0/3, Firefox 158); the station case, and a reload or the next song ending it: 1 of 1 each (Firefox 159.0.1, 2026-11-09, the `research/radio-stop-spin` branch); radio's own stop: 0 of 10 |
| MusicKit's step promises can stay pending: its buffered `seekToTime` resolves only once the target time is buffered again, and `pause()` first waits for a pending `play()`. `am stop` on a song paused at 0:12 never answered and stayed at 0:12 (2026-10-20). The engine page gives every pause, seek, skip, jump, stop and play 2 s (5 s for one that starts an item), then answers anyway; loading a queue (`setQueue`, `setStationQueue`, `playNext`, `playLater` and the API reads) stays unbounded, except re-queuing stopped live radio on resume, under the daemon's 60–120 s timeouts. A `stop` whose seek gives up leaves the song paused where it was; a `stop` or `pause` that leaves MusicKit playing fails with the reason. Each give-up and each page call that times out is a line in `daemon.log`. | the hang: seen once; the code paths: musickit.js 3.2526.0 source; that the seek was the step that hung: inferred (the position never moved) |
| A play takes seconds to reach the music (the daemon's token check and engine launch, then the page's API reads, `setQueue` and `play()`), and until then a stop finds nothing loaded to pause. One cancel generation travels with every play, from the daemon to the engine page (`Plays` in `src/daemon/host.zig`, `load` in `poc/web/app.js`): a play (`am play`, `am resume`, the TUI's queue, Space on a paused song or stopped live radio, play-next and play-later on an empty queue) takes the current one, a stop (`am stop` or the TUI's) the next. Only a stop that succeeds cancels, and only plays older than it: they stop at their next step (before the engine launch, before the page call, at the page call's start, between its API pages and MusicKit steps), and one whose `play()` already started the music silences it. One whose `play()` starts the music only later silences it then, unless a newer play has since handed MusicKit its queue or sent its own `play()`; a newer play still reading from Apple doesn't count, and it waits (bounded) for such a silence still running before it queues or plays. With no engine page connected, a stop cancels on its own only the plays on their way whose page call hasn't gone out, not one that already ended; with one that has, it asks the page anyway and fails if the page doesn't answer. A connected page that doesn't answer `am stop`'s first look gets the stop all the same. `am stop` then says the loading queue won't start, `am play` prints "stopped before it started" and exits 0, and the TUI's requests answer the state with nothing playing. A play begun during a slow stop has the stop's generation and plays; a stop that fails cancels nothing. The TUI's q stops a play of its own that is still on its way or starting before it asks the daemon to stop, so Space or Enter then q at once leaves nothing playing and no background process; a play another client sent, or music already audible, keeps the daemon (#55). A stop whose answer is lost (a timeout, a disconnect) fails and cancels nothing in the daemon, yet the page may have stopped and cancelled its older loads, warm or cold: accepted, not reconciled. A page whose MusicKit isn't configured yet (a cold engine) answers a stop as succeeded without touching MusicKit and keeps its generation for an older play that reaches it later: still cold, the play answers that it stopped before it started; configured by then, the page cancels it as after any stop. A play a stop cancelled during the engine start ends as stopped even when the engine then isn't ready (MusicKit not configured or not authorized); that problem shows on the next play or in `am doctor`. Appending to a queue that has music starts nothing, so a stop leaves the append alone. Play-next and play-later count as a load from their start, their API read included, for as long as the queue is empty (the page reports `loadPending`, and a stop cancels them between API pages); they decide in arrival order once no load is under way, so several on an empty queue start one queue and add the rest to it. | high: fake-driven tests of both sides, and run on macOS (Firefox 158, 2026-10-20): `am play` then `am stop` at 0.5, 1 and 3 s on a warm and a cold engine; the TUI's Enter then a stop; Space on stopped live radio then `am stop` at once (silent for 30 s, twice; MusicKit's `stop()` while the radio's `play()` is pending keeps it from starting); `am play` 0.15 s into a stop (it plays); `am stop` right after play-later on a playing queue (the song is added). A cancelled play's `play()` that starts the music during a newer play's API read: fake-driven only, not seen live |
| `setQueue({playlist})` and `setQueue({album})` keep only the first 100 tracks. The engine page pages the tracks with `music.api.music()` and queues them with `setQueue({items})`; MusicKit drops unplayable library tracks, so queue positions can differ from track indexes (start by `startId`). | high (musickit.js 3.2526.0 source; a 120+ track library playlist played past track 100, TUI port) |
| A reloaded engine page has an empty queue and volume 1, and a warm engine keeps the Music User Token it loaded at start. After a new sign-in the daemon reloads the page only when it is behind on the Music User Token (its report names another one than the stored one, by a hash; a page that names none counts as behind when it loaded before the sign-in), holds no music, or a preview, and no play is on its way (the engine page module, `src/daemon/engine_page.zig`); the TUI re-queues where the music was. A page that already has the new token (its own sign-in, or a reload or launch that read it) isn't reloaded. Otherwise the page is left alone and stays behind: one that holds other music (playing, starting, a song paused, rewound by `am stop` or left in place after it ended, a queue on its way, stopped live radio), one a play is on its way to, or one that didn't answer. One already reloading, or not connected yet, is left alone too, and the next play reloads it only if its report doesn't name the new token. The next play (`am play`, the TUI's queue) reloads a page first if it is behind, if MusicKit signed it out, or if Apple refuses its developer token, and `am doctor` does so while the page holds no music and no play is on its way. Until then a page left alone plays on the old token: `am resume` and Space don't repair. | high (reload: run; sign-in reload, what it leaves alone and the next play's reload of a page behind: source and tests only; the page naming its Music User Token: tests, and MusicKit 3.2526.0's source for its `musicUserToken` returning the token as set, not seen live) |
| Favorites: `extend=inFavorites` reads the state on catalog and library songs, albums, artists and playlists. The Favorite Songs playlist is the library playlist whose `tags` (`extend[library-playlists]=tags`) contain `favorited`. `POST /v1/me/favorites?ids[<type>]=<id>` favorites with our token. `DELETE` on the same URL answers 400 `40012` "Insufficient Permissions" to a third-party token (it works only with Apple's own web-player token). Un-favoriting deletes the rating instead, `DELETE /v1/me/ratings/<type>/<id>` (documented; other clients do the same): for a song, the rating GET answered 200 value 1, the DELETE 204 with no body, and then the rating GET 404, `inFavorites` false and the song gone from Favorite Songs, also 10 s later. Artists have no rating route. | reads: high (live GETs); POST: high (live, 2026-10-20); favorites DELETE refused: high (live, 2026-10-20); ratings DELETE: high for songs (live, 2026-10-20), albums and playlists not run (docs, other clients, and all 99 favorites having rating 1) |
| The API answered 429 "API capacity exceeded" after about 27 back-to-back GETs. The TUI paces requests (≤ 8/s) and backs off 1, 2, 4 s. | medium (seen twice) |
| Ghostty 1.3.1 shows kitty images through Unicode placeholders and never draws a placeholder cell's own diacritics. With autowrap off (the TUI's `?7l`) and grapheme clustering on (mode 2027, from Ghostty's default `grapheme-width-method = unicode`), a combining mark that arrives with the cursor in the last column joins that column's cell when it holds text, not the cell just written. So a cell with marks ending one column before the edge (the Now Playing cover's last placeholder column, a decomposed "é") left its marks on the last column's space: a column of marks right of the cover, until Ctrl-L. The TUI writes such a cell with autowrap on (`?7h` … `?7l`) after a cursor move. The conceal (SGR 8) on placeholder cells doesn't matter here and stays, as it's free. Ghostty's `TERM` is `xterm-256color`, so the TUI detects graphics with the `a=q` query plus `TERM_PROGRAM`. | high (the TUI's bytes replayed through Ghostty 1.3.1's `Terminal` code: 16 of 16 cover rows with marks before, 0 after; none with mode 2027 off; source, 2026-10-20) |

## Time to audio (Zig port)

`am play` until playback starts, middle of three runs. Cold includes starting `am daemon` and the engine; warm
has the engine loaded and stopped. Idle: the warm engine 10 s after `am stop`.

| OS | Machine | Cold (s) | Warm (s) | Idle engine |
|---|---|---|---|---|
| macOS 26.2 | Apple M4, 16 GiB | 3.96 | 1.57 | 9 processes, 705 MiB phys_footprint, 0.3 % CPU (2026-10-16); 7 processes, 525 MiB, 0.3 % CPU after the footprint levers below (2026-11-01) |

Settled 2026-10-16: `ENGINE_IDLE_MINUTES` stays 5. Warm saves about 2.4 s per play, and the idle engine costs memory
but almost no CPU.

Settled 2026-10-20: `am daemon` exits on its own once its engine is closed and nothing used it for
`ENGINE_IDLE_MINUTES`: no music, no CLI request, no TUI connected (an open TUI keeps it). The next command starts
a fresh one.

## Engine footprint on macOS (#1)

Firefox 159, macOS 26.2, Apple M4, 2026-11-01. One run each of `am play 1561837008 --seconds 150`, every process of
the engine sampled over 10 s with `proc_pid_rusage` (phys_footprint, CPU, interrupt wake-ups) about 30 s into the
song, then again 10 s after `am stop`. Before: `main` at 8d688b4. After: the engine page does no DOM work in engine
mode (no `render()` on `playbackTimeDidChange`, no `#log` rebuilds; the sign-in page keeps both), plus the prefs
`browser.newtab.preload=false`, `browser.newtabpage.enabled=false` and `network.process.enabled=false`. The machine
was busy (load average above 10), so CPU % is rough; wake-ups and memory are not. Firefox names a child's type in its
command line (`tab`, `rdd`, `socket`, `utility`, `gmplugin`) but not which `tab` is which: web content is the one
that wakes while playing; the other two are the extension process and the preloaded new tab, told apart by which one
the new-tab prefs remove.

| Process | Before (MiB, wake-ups/s while playing) | After |
|---|---|---|
| parent | 309, 55.6 | 303, 5.0 |
| web content (`tab`) | 56, 26.8 | 55, 27.6 |
| Widevine (`gmplugin`) | 75, 0.1 | 75, 0.1 |
| extension (`tab`) | 47–49, about 1 | 45, 1.3 |
| preloaded new tab (`tab`, privilegedabout) | 47–49, about 1 | gone |
| `socket` | 15, 0.1 | gone |
| `rdd` | 15, 0.1 | 15, 0.1 |
| `utility` ×2 | 16 each, 0.1 | 16 each, 0.1 |
| **total, playing** | 9 processes, 598 MiB, 85 wake-ups/s, 6.4 % CPU | 7 processes, 525 MiB, 34 wake-ups/s, 5.1 % CPU |
| **total, idle** (10 s after `am stop`) | 9 processes, 599 MiB, 5.3 wake-ups/s, 0.5 % CPU | 7 processes, 525 MiB, 5.7 wake-ups/s, 0.3 % CPU |

The parent's wake-ups while playing came from repainting the engine page: on macOS the parent runs a CVDisplayLink
vsync even headless, so every `playbackTimeDidChange` repaint cost it a frame. The prefs cut memory and processes,
not CPU. Both runs played `encryptedFull`. On a fresh profile (the engine profile moved aside) with the new prefs,
Widevine 4.10.3112.0 installed by itself, `am doctor` was all ✔ in 4.6 s and `am play` played `encryptedFull`.

Not adopted, from the measurements on #1 (Firefox 158, same machine):

- **`media.rdd-process.enabled=false` (no RDD process): rejected.** MusicKit's key-system probe asks for avc1 video
  support, which only the RDD process provides, so `requestMediaKeySystemAccess` fails ("Key system configuration
  is not supported") and MusicKit plays the 30 s preview.
- `extensions.webextensions.remote=false`: one process fewer, but the parent grows, about 10 MiB net, on a path
  desktop Firefox tests less.
- A 5 s report interval (parent 4 → 2.8 wake-ups/s): `am status` would lag up to 5 s, so it needs the CLI to work
  the position out from position + timestamp first.
- The background-service prefs (safe browsing, Normandy, push, connectivity checks) and
  `media.cubeb_latency_playback_ms`: no measurable change on macOS (the AudioUnit backend clamps the buffer to
  128–512 frames).
- Keep `extensions.update.enabled`, every `media.gmp-*` pref and `media.utility-process.enabled` as they are: Widevine
  updates ride on the add-on update check, and AAC may decode in the utility process.

## Decisions

1. **Engine: Firefox ESR first.** It's often already installed on Linux, needs no root and no automation protocol, and passed everything testable without an account. Chrome stays a drop-in fallback (`--engine chrome`) if Apple rejects Firefox's licence requests.
2. **Widevine 3050 first, 3112 as a fallback.** If `play` reports `WIDEVINE_CDM_EXPIRED`, set `FIREFOX_WIDEVINE=google` in `~/.config/am/env`.
3. **Control via SSE + POST, not Playwright/BiDi.** Playwright's stock-Firefox channel needs Firefox 143+. Its Firefox build has no DRM. Its Chrome mode sets `navigator.webdriver`.

## Open risks, and how the POC settles them

| Risk | Test | Pass | Status |
|---|---|---|---|
| Apple's licence server rejects Firefox's CDM (3050 or 3112) | `play --headless` | `playbackType = encryptedFull`, time passes 1:35 on the 2:55 test song | ✔ passed (3050) |
| Sign-in popup misbehaves in the user's Firefox (strict tracking protection, blocker add-ons) | `signin` | terminal prints `✔ signed in` | ✔ passed |
| Memory pressure on a 4 GiB machine with a desktop Firefox open | `play` prints the engine footprint and warns below 700 MiB free | no OOM, footprint ≤ 600 MiB | ✔ 432 MiB, no OOM |
| Firefox ESR 153 (already in Debian 13's security updates) changes behaviour | re-run `doctor` after the upgrade | same checks pass | open |
| Apple later starts rejecting 3050 | `play` reports `WIDEVINE_CDM_EXPIRED` | set `FIREFOX_WIDEVINE=google` | open |

## Later (out of the prototype's scope)

- A compiled port (now done, in Zig): an HTTP server + SSE, and a child process for the engine; no browser library needed.
- MPRIS: Firefox exposes the engine as `org.mpris.MediaPlayer2.firefox.instance_*`, with the same Identity as the user's normal Firefox. Pick it by owner PID.
- Pre-warm the CDM once at install time, and handle `WIDEVINE_CDM_EXPIRED` by flipping the Widevine source.
- Lifecycle lessons from the code review, to carry into the port: kill the engine's whole process group (Firefox can fork and exit), handle SIGTERM/SIGHUP not just SIGINT, kill leftover engines by binary + profile path at start, set `toolkit.startup.max_resumed_crashes=-1` (short SIGTERM'd sessions count as startup crashes and trigger safe mode), and watch report freshness during playback.
