# Does stopping live radio still spin Firefox? (wayfinder ticket #16)

Throwaway branch, never merged. The answer is the resolution comment on
[#16](https://github.com/IIxauII/am/issues/16); this is the method and the data behind it.

Measured 2026-11-09 on an Apple M4 (16 GiB, macOS 26.2): Firefox 159.0.1 (build 20261102144711),
Widevine 4.10.3112.0, MusicKit JS 3.2526.0, `am` at `0d488e7` plus the throwaway hook below, built
with `zig build -Doptimize=ReleaseSafe`. Every play ran at volume 0 on the owner's account.

"The spin" below means what NOTES.md describes: after MusicKit's `stop()`, the web content process
and the Widevine helper (`gmplugin`) keep each other busy at about 120 % CPU until something ends it.

## Answer

- **Stopping live radio doesn't spin.** None of the 6 radio stops or pauses here left any CPU
  behind. They varied the play (2–5 min), the station (four of them), how it was stopped (`am stop`,
  `am pause`, the TUI's stop), a stop after a resume, and a station after a station or after a
  rewound song. Each time the whole engine sat at 0.3–0.6 % for the 1–6 min watched, with one-off
  samples of 1.6 % and 3.2 %. Measured. With the 4 of 4 on 2026-10-21, that's 0 of 10.
- **The spin is real, and it's a song path.** MusicKit's `stop()` on a *playing song* still spins
  on Firefox 159.0.1. The engine sat at 116–119 % for the 5 min watched (web content ~51 %,
  Widevine helper ~43 %, parent ~24 %) with almost no wake-ups, so it's a busy loop. The song's
  `<audio>` stayed stuck in `seeking`. Measured, 1 of 1. A song that played to its own end (MusicKit
  runs the same element reset then) didn't spin: 0.4–0.5 % for 4 min. Measured, 1 of 1.
- **Radio can still set it off, through the song before it.** When a station is queued over a
  song, MusicKit swaps players and calls `stop()` on the song's player. That spun at once when the
  song was playing (C3) or paused mid-way with `am pause` (C4): ~122 % *while the radio played*,
  and still ~121 % minutes after the radio was stopped. A song that `am stop` had already paused
  and rewound to 0:00 didn't spin (C2). Measured, 1 of 1 each. This happens today, without
  keep-alive: the idle close only ends it 5 min after the radio stops.
- **A page reload ends it, and so does the next song.** 10 s after `location.reload()` the engine
  was at 0.4 % and the Widevine helper had exited. On another spinning engine, `am play <song>`
  ended it at once (9 % while playing, then 0.5–0.7 % after `am stop`). Closing the engine isn't
  needed. Measured, 1 of 1 each.
- **Silencing radio without `stop()`:** MusicKit's `pause()` does nothing on a live station
  (measured; the source logs "pause is not supported", and Apple's docs say live radio must end
  with `stop()`). Pausing the `<audio>` element underneath MusicKit does silence it. Over 5 min
  that cost 0.3–0.6 % with nothing more buffered, and `music.play()` resumed in 59 ms at the live
  edge, against 2.1 s for `am resume` re-queuing a stopped station (R2). The price: the Widevine
  helper (75 MiB) and the stream stay loaded, and it works against MusicKit's API, which then
  reports `paused` for a thing it says can't pause (risk inferred, untested beyond 5 min). Muting
  the element just keeps playing at the playing cost (~7 %). Measured, 1 of 1 each. With radio's
  own stop not spinning, there's no need for either.
- **Why radio is safe (source, cause inferred):** MusicKit plays live radio through a separate HLS
  player. Its `stop()` destroys that player, closes the licence session and drops the element.
  Songs use a cached player. Its `stop()` pauses, sets `currentTime = 0`, removes `src` without
  `load()` and ends the MediaSource, but it keeps the element and its MediaKeys. Firefox shuts a
  CDM down only when its MediaKeys object goes away. Read in musickit.js 3.2526.0 and Firefox's
  source (links below).

## For the keep-alive safeguards (#17)

- A reload (or relaunch) some minutes after a *radio stop* guards against nothing measured here:
  radio's own stop didn't spin in 10 tries.
- The case to guard is **a station queued over a song left past 0:00**. It spins while the radio
  plays and afterwards, until a reload, the next song or the engine's close. Today the idle close
  ends it 5 min after playback stops. With keep-alive, nothing would, and in both cases it burns
  ~120 % for as long as the radio plays.
- Cheapest fix: before queuing a station over a song past 0:00, the engine page pauses and
  rewinds the song as `am stop` does. Inferred from C2 (1 of 1); it needs a test with a playing
  song, a paused one and one that ended.
- Broader net, for any path into MusicKit's song `stop()`: the daemon already measures the
  engine's CPU (`src/footprint.zig`, for `am status`). It could reload the page when the engine
  stays far above playing cost, for example > 50 % for a minute (playing is 5–9 %). The reload
  empties the page's queue, which the TUI already handles by re-queuing (NOTES.md); not tried.
- Silencing radio by pausing the element isn't needed, and it works against MusicKit's API.

## Trials

Each trial played at volume 0 and then stopped. Engine CPU is the sum over every process of the
engine, in 10 s windows (`proc_pid_rusage`). The "after" column covers the whole watch: every
sample from 10 s after the action to its end. "Helper" says whether the Widevine helper exited.

| Trial | Engine | Before the action | Action | Watched | CPU after | Helper |
|---|---|---|---|---|---|---|
| A1 | fresh | Apple Music 1 (`ra.978194965`), 3 min | `am stop` | 6 min | 0.3–0.5 % | exited at 1–2 min |
| R1 | fresh | Apple Music Hits (`ra.1498155548`), 4 min | `am pause` (stops radio) | 6 min | 0.3–0.4 % (1.6 % once) | exited by 30 s |
| R2 | R1's | `am resume` (re-queues Hits, 2.1 s), 3 min | TUI stop | 6 min | 0.3–0.4 % | stayed, 0 % |
| R3 | R1's | Apple Music Club (`ra.1740613859`), 5 min | `am stop` | 5 min | 0.4–0.6 % | stayed, 0 % |
| S1 | fresh | Apple Music Chill (`ra.1740614260`), 2 min, element paused 5 min, 2 min more | `am stop` | 1 min | 0.4–0.5 % | stayed, 0 % |
| C2 | fresh | song 1 min, `am stop`, then Apple Music 1, 2 min | `am stop` | 4 min | 0.3–0.5 % (3.2 % once) | stayed, 0 % |
| C5 | fresh | song from 2:40 to its end (autoplay off), `completed` | (none) | 4 min | 0.4–0.5 % | stayed, 0 % |
| **C1** | fresh | song (1561837008), 1.5 min | MusicKit `stop()` | 5 min | **116–119 %** | busy, ~43 % |
| C1 | C1's | spinning | page reload | 3 min | 0.4–0.8 % | exited by 10 s |
| **C3** | fresh | song 1 min, then Apple Music 1 queued over it (playing) | (radio playing) | 2 min | **122–123 %** | busy, ~44 % |
| C3 | C3's | Apple Music 1, 2 min, spinning | `am stop` | 3 min | **120–122 %** | busy, ~44 % |
| C3b | C3's | spinning, then `am play` of the song, 1 min | `am stop` | 2 min | 0.5–0.7 % | stayed, 0 % |
| **C4** | fresh | song 1 min, `am pause` at 1:00, then Apple Music 1 queued over it | (radio playing) | 1 min | **122 %** | busy, ~44 % |
| C4 | C4's | Apple Music 1, 1 min, spinning | `am stop` | 2 min | **120–122 %** | busy, ~44 % |

While playing, the engine took 5–9 % CPU (radio ~6 %), and the content process woke ~35 times a
second. After a stop the engine took 480–670 MiB: footprint grew by about 180 MiB over the three
plays on R1's engine (484 → 666 MiB), partly because the Widevine helper (75 MiB) stayed.

In S1, MusicKit's `pause()` left the station playing (`canPause` false; still playing 1 s later).
`element.pause()` then took 51 ms to silence it. While paused, the buffered end stayed at the
same point for the full 5 min. After 5 min 12 s of pause, `music.play()` played again in 59 ms at
position 472 s, against 159 s at the pause and a seekable end of 519 s. That's 47 s behind the
end, as during normal play (38–48 s), so it rejoined the live broadcast rather than playing stale
audio. Muted (`element.muted = true`), the engine took 7.3 % against 6.7 % playing.

In C3 the page held two `apple-music-player` elements. The song's had `src` removed, was stuck
at 0:00 with `readyState` 1, still had the whole song buffered and still had MediaKeys. The radio's
was playing. C1's spinning element looked the same as that song element. In C2, the song element
after the swap looked the same too, yet nothing spun. The difference: `am stop` had already paused
and rewound it, while C3's played and C4's was paused at 1:00. C5's song had ended, and MusicKit's
`ended` handler runs the same reset (`stopMediaAndCleanup`); nothing spun there either. So it
seems to take the reset's `currentTime = 0` on a song that's mid-way, playing or paused
(inferred from 5 cases).

## Upstream

- **MusicKit JS** (musickit.js 3.2526.0, fetched from `js-cdn.music.apple.com/musickit/v3/musickit.js`
  on 2026-11-09; minified, so these are names in its source):
  - `Factory.createAudioPlayer` gives live radio, radio episodes and HLS offers a new
    `HlsJsAudioPlayer` (Apple's HLS player 2.910.1, loaded from Apple's CDN). Songs get one cached
    `AudioPlayer`.
  - `BasePlayer.stop` → `stopMediaAndCleanup` → `stopMediaElement` calls `element.pause()`, then
    `resetMediaElement`, which sets `currentTime = 0` and removes `src` and `title`. There is no
    `load()` and no `setMediaKeys(null)`.
  - `AudioPlayer.stopMediaElement` then tears down its manifests and calls `buffer.stop()`
    (`setEndOfStream`, then removes the SourceBuffer and the MediaSource). The player and its
    element stay cached.
  - `HlsJsAudioPlayer.stopMediaElement` then calls `destroy()`: `hls.stopLoad()`, `hls.destroy()`,
    the EME extension's `destroy` (which detaches the session), removal of the element from the
    page, and `license.stop()`.
  - `MediaItemPlayback.setCurrentPlayer` calls `stop()` on the old player whenever the player
    changes (song → station), which is the route C3 took.
  - The station controller's `hasCapabilities`: pause, seek and skips are false when live, and
    volume is true. Its `pause()` on a live station only does
    `warn("pause is not supported for this type of playback")`. When pause isn't available,
    MusicKit's own media-session "pause" handler calls `stop()`.
- **Apple's MusicKit JS docs:** "Important: You must call the stop() to end playback for live
  radio" ([live radio article](https://js-cdn.music.apple.com/musickit/v3/docs/index.html?path=/docs/playing-apple-music-live-radio-stations--page)).
  `volume` is set on the media element, and `mute()` sets it to 0
  ([instance reference](https://js-cdn.music.apple.com/musickit/v3/docs/index.html?path=/story/reference-javascript-musickit-instance--page)).
- **Firefox source** (mozilla-firefox/firefox at `a82bcf39`):
  - The Widevine (GMP) process closes only once no CDM or decoder uses it
    ([GMPContentParent.cpp](https://github.com/mozilla-firefox/firefox/blob/a82bcf39e8d23e7b06e021044db52f74210862ce/dom/media/gmp/GMPContentParent.cpp#L51-L120)).
  - A CDM shuts down in `MediaKeys::Shutdown`, when the MediaKeys is destroyed (GC or its window
    goes away), not on a session `close()` or on `src` removal
    ([MediaKeys.cpp](https://github.com/mozilla-firefox/firefox/blob/a82bcf39e8d23e7b06e021044db52f74210862ce/dom/media/eme/MediaKeys.cpp#L84-L198)).
  - Removing `src` doesn't run the load algorithm
    ([HTMLMediaElement.cpp](https://github.com/mozilla-firefox/firefox/blob/a82bcf39e8d23e7b06e021044db52f74210862ce/dom/media/mediaelement/HTMLMediaElement.cpp#L5736-L5797);
    the same as the [HTML spec](https://html.spec.whatwg.org/multipage/media.html#attr-media-src)).
    A reload destroys the window and with it the MediaKeys, which fits it ending the spin
    (inferred).
- **Bugzilla:** no bug matches the spin (searched Core › Audio/Video: GMP, Playback, MSE, for
  CPU / spin / busy / Widevine / CDM / MediaKeys / gmplugin / Apple Music). The nearest:
  - [1984072](https://bugzilla.mozilla.org/show_bug.cgi?id=1984072): Windows Media Foundation CDM at
    30–40 % CPU after Spotify/Tidal until restart; UNCONFIRMED, another CDM path.
  - [1574510](https://bugzilla.mozilla.org/show_bug.cgi?id=1574510): macOS GMP process sometimes
    outlives closed Widevine tabs; NEW, no CPU figures.
  - [1727133](https://bugzilla.mozilla.org/show_bug.cgi?id=1727133): a ClearKey hot loop on CBCS,
    fixed 2021.
  - Filing one would need a reduced test case (MSE + Widevine, then pause, `currentTime = 0`,
    `removeAttribute('src')`, `endOfStream`); not done.
- **Other MusicKit clients:** Cider's live-radio pause button does nothing since 2.4.0
  ([Cider-2 #612](https://github.com/ciderapp/Cider-2/issues/612),
  [#626](https://github.com/ciderapp/Cider-2/issues/626)), which matches the no-op `pause()`. No
  report of CPU after a stop turned up.

## Caveats

- One machine and one Firefox build. Radio: 6 stops or pauses (10 with 2026-10-21), so the
  no-spin claim is solid for this setup. The song cases (C1–C5, C3b) and S1 ran once
  each; C3 and C4 agreeing makes "a station over a song past 0:00 spins" fairly firm, C2's "a
  rewound song doesn't" less so.
- Not tried: a station over a song that ended on its own, an album or playlist instead of one
  song, a radio *episode* (also the HLS player), the TUI itself, and a spin left for longer than
  5 min (it was steady throughout).
- Volume 0 throughout. MusicKit sets it on the element, so decoding and output still run (radio
  costs the same ~6 % as before); audible volume wasn't tried.
- The hook wraps `HTMLMediaElement.prototype.play` to find MusicKit's elements. A1 held them with
  strong references; every later trial used `WeakRef`, so it didn't keep a dropped element alive.
- The engines ran from a private APFS clone of `/Applications/Firefox.app` (`cp -Rc`, same 159.0.1
  build) with app updates off in that clone, except A1, which ran from `/Applications`. At 08:25 UTC the
  shared install's pending self-update killed a running engine and relaunched Firefox outside the
  daemon (`ppid` 1, no `--headless`). That run (A2, A3) was dropped. So was an earlier A1 whose
  harness counted the Widevine helper as the parent: its command line names the profile too.
  - Relevant beyond this research: Firefox's self-update can take the engine down mid-session. Here
    the daemon logged "the engine exited on its own" and left an orphan Firefox running with the
    engine profile.

## Files

- `rs.py`: the harness. It runs an isolated `am` (own `AM_CONFIG_DIR`, `AM_PORT` 47871,
  `ENGINE_IDLE_MINUTES=100000`, `FIREFOX_PATH` to the clone) through the steps named on its command
  line, and samples every engine process. Its docstring lists the steps.
- `summarize.py`: prints `radio.jsonl` as one row per sample or step.
- `stations.py`: lists Apple Music's live stations, using the developer token.
- `radio.jsonl`: raw samples and steps, times in UTC. Tokens, hashes and the radio's song metadata
  are left out; the storefront is masked. CPU values in `by` are `[CPU %, wake-ups/s, MiB]` per
  process.
- The hook in `poc/web/app.js` (on this branch only): `setVolume(code / 10000)` for 0 < code < 100
  runs an experiment instead of setting the volume:

  | Code | Experiment |
  |---|---|
  | 1 | reload |
  | 2 | `music.stop()` |
  | 3 | `music.pause()` |
  | 4 | pause the element |
  | 5 | play the element |
  | 6 | `music.play()` |
  | 8 | mute the element |
  | 9 | unmute the element |
  | 10 | jump to the live edge |

  Code 7, inspect, failed: MusicKit's capabilities object is cyclic. Each report also carries
  `expMedia`, the state of every media element.

## Reproduce

```
zig build -Doptimize=ReleaseSafe
python3 -I research/radio-stop-spin/rs.py C1 fresh doctor song:1561837008 sample:90 exp:2 watch:300
python3 -I research/radio-stop-spin/rs.py C1-reload exp:1 watch:180
python3 -I research/radio-stop-spin/rs.py C3 fresh doctor song:1561837008 sample:60 station:ra.978194965 sample:120 cli:stop watch:180
python3 -I research/radio-stop-spin/rs.py C3b song:1561837008 sample:60 cli:stop watch:120
python3 -I research/radio-stop-spin/rs.py S1 fresh doctor station:ra.1740614260 sample:120 exp:3 sleep:3 state exp:4 watch:300 exp:6 sleep:5 state sample:60 exp:8 sample:60 exp:9 cli:stop watch:60
python3 -I research/radio-stop-spin/rs.py done daemon-stop
```

Set `RS_CONFIG_DIR` to a config dir of its own (never `~/.config/am`) holding
`developer-token.jwt`, `music-user-token` and `env` (symlinks work). Optionally set `RS_FIREFOX`
to a Firefox binary, e.g. a clone made with `cp -Rc /Applications/Firefox.app` and a
`Contents/Resources/distribution/policies.json` of `{"policies": {"DisableAppUpdate": true}}`.
