# am

`am` plays Apple Music from the command line and a TUI, through a page that runs MusicKit JS in a headless browser. These are the words the code, the tests and the docs use for that page and for what is done to it.

## Language

### The engine page

**Engine page**:
The page (`poc/web/app.js`) that runs MusicKit JS in the browser the daemon launches. Commands reach it over the channel's event stream, and it reports its state back about once a second.
_Avoid_: player, browser tab

**Engine mode**:
The engine page as the daemon opens it (`?engine=<nonce>`), as against the sign-in page (`?signin`, opened for `am signin`). In engine mode the page draws nothing: it only reports. The sign-in page shows its status and event log.
_Avoid_: headless mode (the engine may be visible, `ENGINE_HEADLESS=0`)

**Launch**:
One start of the engine (the browser) by the daemon, with a nonce of its own: only a page that carries it may use the channel.
_Avoid_: session, boot

**Page load**:
One load of the engine page within a launch, named by the `load` id in its reports. A reload keeps the launch's nonce and starts a new page load.
_Avoid_: refresh

**Engine page module**:
The one place (`src/daemon/engine_page.zig`) that owns the engine page from a launch until MusicKit is fit for the caller: the wait for the page, the Widevine wait, every reload, the check of the page's developer token, and the mark that a page load is behind on the Music User Token.
_Avoid_: page manager, sync

### What the page holds

**Holds music**:
The engine page has something a reload would lose: music that plays or is starting, a song still loaded (paused, rewound by `am stop`, or left in place after it ended), a queue on its way, or stopped live radio (`playback.Report.holdsMusic`).
_Avoid_: busy

**On its way**:
A play that has begun and not yet ended, so it may be about to send music to the page (`Plays.activity`). A queue on its way is one the page is still loading.
_Avoid_: pending

### Repairs

**Repair for a play**:
What `am play` and the TUI's queue ask for before they play: a reload for whatever the page needs, whatever it holds, because the play replaces it.
_Avoid_: refresh, fix-up

**Repair if idle**:
What `am doctor` asks for: the same repairs, made only while the page holds no music and no play is on its way.
_Avoid_: health check, sync

**Reload in flight**:
A reload of the engine page that went out and whose new page load hasn't landed, run out its wait, or ended with its launch.
_Avoid_: pending reload, refresh

**Joining a reload**:
Waiting for a reload in flight that another caller sent, then deciding again on its new page load, instead of sending a reload of one's own. A control play (Space, `am resume`, play-next, play-later) joins one too, but decides nothing: it makes its page call on the new page load and never repairs.

**Left alone**:
A page that a repair if idle or the sign-in didn't reload, because it holds music, a play is on its way, or it didn't answer; the sign-in also leaves alone a page that is reloading or isn't connected yet. The repair it needed is left for the next play.
_Avoid_: kept, skipped

**Behind on the Music User Token**:
A page load whose MusicKit doesn't hold the stored Music User Token: its report names another one (`musicUserToken`, a hash as for the developer token). A page load that names none (an older page, a browser that can't hash, MusicKit holding none) is behind when it began before the last sign-in stored a new token, since it may still use the old one. The next repair for a play reloads it first.
_Avoid_: stale token, page token
