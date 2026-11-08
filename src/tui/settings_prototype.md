# PROTOTYPE: settings screen, three variants (throwaway)

Throwaway prototype for the wayfinder ticket "Settings screen and key rebinding flow"
(https://github.com/IIxauII/am/issues/2). Branch `prototype/settings-screen`, never merged.
Code: `src/tui/settings_prototype.zig`, hooked into `app.zig` and `views.zig`.

Run it: `zig build run` (or `AM_PROTO_SETTINGS=B zig build run`). `,` opens settings
(in C, `?` does), `{` and `}` switch variant. Nothing is written to disk; rebinding and the
artwork choice are live for the session; keep-alive is a stub.

- **A, settings page**: a sidebar entry (`, Settings`) that fills the list pane; one list
  (Engine, Artwork, then every key by group); Enter sets a key, `a` adds one, `d` removes,
  `u` resets the row; a conflict asks first; every change applies at once (toast).
- **B, settings dialog**: a modal box with tabs (Keys, Engine, Artwork); keys as chips
  (`[j] [↓] [^n] [+]`), Default and Where columns, `/` to find; capture shows the key and
  whose it is before Enter takes it; nothing applies until `w`; Esc with changes asks.
- **C, editable help**: the `?` overlay lists every binding, one per action, generated from
  the table, with a Settings section; Enter rebinds in place; a conflict just moves the key
  and offers `z` undo; changes apply at once.

## Rendered by the test (120×34, empty Home, images not detected)

Regenerate: `zig build test -Dtest-filter=PROTOTYPE`, then run the test binary it built
(`.zig-cache/o/*/test`) directly: the build runner hides a passing test's output.

#### A settings page: opened with `,` (the Settings entry sits under Up Next)

```
 am                   │ Settings                             changes apply at once │ Now Playing
                      │────────────────────────────────────────────────────────────│
 1 Home               │ Engine                                                     │
 2 Recently Played    │   Keep the engine running       off                        │
 Library              │                                                            │
   3 Songs            │ Artwork                                                    │
   4 Albums           │   Artwork                       images?  blocks  off       │
   5 Artists          │                                                            │
   6 Playlists        │ Keys · Move                                                │
     Recently Added   │   Move down                     j  ↓  ^n                   │                  ♪
 7 Favorites          │   Move up                       k  ↑  ^p                   │
 8 Radio              │   Top                           g  Home                    │
 9 Charts             │   Bottom                        G  End                     │
 / Search             │   Page down                     PgDn                       │
 0 Up Next            │   Page up                       PgUp                       │
                      │   Half page down                ^d                         │
▌, Settings           │   Half page up                  ^u                         │
                      │   Other pane                    Tab                        │
                      │   Other pane, backwards         ⇧Tab                       │ Nothing playing
                      │   To the sidebar                h                          │
                      │   To the list                   l                          │ Pick a song and press Enter: it
                      │   Open, or play from here       Enter                      │ plays with the rest of its album
                      │   Back                          Esc  Backspace             │ or list.
                      │   Filter this list              ^f                         │
                      │   Go to album                   o                          │
                      │   Go to artist                  O                          │
                      │   Go to what's playing          c                          │
                      │────────────────────────────────────────────────────────────│
                      │ Enter turns it on or off, at once. On: the engine starts   │
                      │ with am and stays up while am is open, so the first play   │
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ■ Nothing playing                                                                                        ⇄ ↻   vol 50%
 -:--                                                                                                              -:--
 ● us  connecting                                                      PROTOTYPE A settings page · , opens · { } switch
```

#### A: Enter on Shuffle waits for a key

```
 am                   │ Settings                             changes apply at once │ Now Playing
                      │────────────────────────────────────────────────────────────│
 1 Home               │   Songs                         3                          │
 2 Recently Played    │   Albums                        4                          │
 Library              │   Artists                       5                          │
   3 Songs            │   Playlists                     6                          │
   4 Albums           │   Favorites                     7                          │
   5 Artists          │   Radio                         8                          │
   6 Playlists        │   Charts                        9                          │
     Recently Added   │   Recently Added                no key                     │                  ♪
 7 Favorites          │   Up Next                       0                          │
 8 Radio              │   Search                        /                          │
 9 Charts             │                                                            │
 / Search             │ Keys · Play                                                │
 0 Up Next            │   Play / pause                  Space                      │
                      │   Next                          n  >                       │
▌, Settings           │   Previous                      p  <                       │
                      │   Seek back 5 s                 ←                          │
                      │   Seek forward 5 s              →                          │ Nothing playing
                      │   Seek back 30 s                [  ⇧←                      │
                      │   Seek forward 30 s             ]  ⇧→                      │ Pick a song and press Enter: it
                      │   Volume up                     +  =                       │ plays with the rest of its album
                      │   Volume down                   -                          │ or list.
                      │   Mute                          m                          │
                      │   Shuffle                       press a key…               │
                      │   Repeat: off, all, one         r                          │
                      │   Play album or playlist from … P                          │
                      │────────────────────────────────────────────────────────────│
                      │ Press the key for “Shuffle”. Esc cancels.                  │
                      │                                                            │
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ■ Nothing playing                                                                                        ⇄ ↻   vol 50%
 -:--                                                                                                              -:--
 ● us  connecting                                                      PROTOTYPE A settings page · , opens · { } switch
```

#### A: Shuffle is now x; n for Play / pause belongs to Next, so it asks

```
 am                   │ Settings                             changes apply at once │ Now Playing
                      │────────────────────────────────────────────────────────────│
 1 Home               │   Songs                         3                          │
 2 Recently Played    │   Albums                        4                          │
 Library              │   Artists                       5                          │
   3 Songs            │   Playlists                     6                          │
   4 Albums           │   Favorites                     7                          │
   5 Artists          │   Radio                         8                          │
   6 Playlists        │   Charts                        9                          │
     Recently Added   │   Recently Added                no key                     │                  ♪
 7 Favorites          │   Up Next                       0                          │
 8 Radio              │   Search                        /                          │
 9 Charts             │                                                            │
 / Search             │ Keys · Play                                                │
 0 Up Next            │   Play / pause                  n?                         │
                      │   Next                          n  >                       │
▌, Settings           │   Previous                      p  <                       │
                      │   Seek back 5 s                 ←                          │
                      │   Seek forward 5 s              →                          │ Nothing playing
                      │   Seek back 30 s                [  ⇧←                      │
                      │   Seek forward 30 s             ]  ⇧→                      │ Pick a song and press Enter: it
                      │   Volume up                     +  =                       │ plays with the rest of its album
                      │   Volume down                   -                          │ or list.
                      │   Mute                          m                          │
                      │ • Shuffle                       x                default s │
                      │   Repeat: off, all, one         r                          │
                      │   Play album or playlist from … P                          │
                      │────────────────────────────────────────────────────────────│
                      │ n is Next's key. Enter gives it to Play / pause (Next      │
                      │ keeps >) · any other key leaves it.                        │
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ■ Nothing playing                                                                                        ⇄ ↻   vol 50%
 -:--                                                                                                              -:--
 ● us  connecting                                                      PROTOTYPE A settings page · , opens · { } switch
```

#### A: after taking n; Reset all asks once more

```
 am                   │ Settings                             changes apply at once │ Now Playing
                      │────────────────────────────────────────────────────────────│
 1 Home               │   Details                       i                          │
 2 Recently Played    │                                                            │
 Library              │ Keys · App                                                 │
   3 Songs            │   Settings                      ,                          │
   4 Albums           │   Help                          ?                          │
   5 Artists          │   Artwork: images, blocks, off  v                          │
   6 Playlists        │   Reload view                   ^r                         │
     Recently Added   │   Redraw                        ^l                         │                  ♪
 7 Favorites          │   Sign in to Apple Music again  S                          │
 8 Radio              │   Quit (the music goes on)      q                          │
 9 Charts             │   Quit and stop the music       Q                          │
 / Search             │   Quit, from anywhere           ^c                   fixed │
 0 Up Next            │   Suspend                       ^z                   fixed │
                      │                                                            │
▌, Settings           │ Keys · In search and filter                                │
                      │   Search, or submit             Enter                      │
                      │   Leave the field               Esc                        │ Nothing playing
                      │   Down to the list              ↓                          │
                      │   Up                            ↑                          │ Pick a song and press Enter: it
                      │   Delete back                   Backspace  ^h              │ plays with the rest of its album
                      │   Clear the field               ^u                         │ or list.
                      │   Catalog or library search     Tab                        │
                      │   Quit, from anywhere           ^c                   fixed │
                      │                                                            │
                      │   Reset all keys to default     3 changed                  │
                      │────────────────────────────────────────────────────────────│
                      │ Enter again sets 3 changed keys back to default · any      │
                      │ other key keeps them.                                      │
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ■ Nothing playing                                                                                        ⇄ ↻   vol 50%
 -:--                                                                                                              -:--
 ● us  connecting                                                      PROTOTYPE A settings page · , opens · { } switch
```

#### B settings dialog: Enter on Shuffle's [s] chip, then n: it says whose key it is

```
 am                   │ Home                                                     ⠋ │ Now Playing
    ╭─ Settings ───────────────────────────────────────────────────────────────────────────────────────────────────╮
▌1 H│ 1 Keys   2 Engine   3 Artwork                                                             no unsaved changes │
 2 R│──────────────────────────────────────────────────────────────────────────────────────────────────────────────│
 Lib│ / find an action                                                                                             │
   3│                                                                                                              │
   4│   Action                            Keys                            Default             Where                │
   5│   Songs                             [3] [+]                         3                   lists                │
   6│   Albums                            [4] [+]                         4                   lists                │
    │   Artists                           [5] [+]                         5                   lists                │
 7 F│   Playlists                         [6] [+]                         6                   lists                │
 8 R│   Favorites                         [7] [+]                         7                   lists                │
 9 C│   Radio             ╭─ Change a key ───────────────────────────────────────────────────╮lists                │
 / S│   Charts            │ Shuffle · in lists, help and details                             │lists                │
 0 U│   Recently Added    │ now: s                                                           │lists                │
    │   Up Next           │                                                                  │lists                │
    │   Search            │ New key: n                                                       │lists                │
    │ Play                │ It's Next's now. Taking it leaves Next with >.                   │                     │
    │   Play / pause      │                                                                  │lists                │
    │   Next              │                                                                  │lists                │
    │   Previous          ╰─ Enter use it · Backspace try another · Esc cancel ──────────────╯lists                │
    │   Seek back 5 s                     [←] [+]                         ←                   lists                │m
    │   Seek forward 5 s                  [→] [+]                         →                   lists                │
    │   Seek back 30 s                    [[] [⇧←] [+]                    [ ⇧←                lists                │
    │   Seek forward 30 s                 []] [⇧→] [+]                    ] ⇧→                lists                │
    │   Volume up                         [+] [=] [+]                     + =                 lists                │
    │   Volume down                       [-] [+]                         -                   lists                │
    │   Mute                              [m] [+]                         m                   lists                │
    │   Shuffle                           [s] [+]                         s                   lists                │
    │   Repeat: off, all, one             [r] [+]                         r                   lists                │
────│   Play album or playlist from the … [P] [+]                         P                   lists                │────
 ■ N│ ← → pick a key · Enter change (on [+]: add) · d remove · u row default · U all defaults · / find             │50%
 -:-╰─ w save · Esc close · Tab next tab ──────────────────────────────────────────────────────────────────────────╯:--
 ● us  connecting                                                    PROTOTYPE B settings dialog · , opens · { } switch
```

#### B: n moved to Shuffle in the draft (* = unsaved); nothing applies until w

```
 am                   │ Home                                                     ⠋ │ Now Playing
    ╭─ Settings ───────────────────────────────────────────────────────────────────────────────────────────────────╮
▌1 H│ 1 Keys   2 Engine   3 Artwork                                                              2 unsaved changes │
 2 R│──────────────────────────────────────────────────────────────────────────────────────────────────────────────│
 Lib│ / find an action                                                                                             │
   3│                                                                                                              │
   4│   Action                            Keys                            Default             Where                │
   5│   Songs                             [3] [+]                         3                   lists                │
   6│   Albums                            [4] [+]                         4                   lists                │
    │   Artists                           [5] [+]                         5                   lists                │
 7 F│   Playlists                         [6] [+]                         6                   lists                │
 8 R│   Favorites                         [7] [+]                         7                   lists                │
 9 C│   Radio                             [8] [+]                         8                   lists                │
 / S│   Charts                            [9] [+]                         9                   lists                │
 0 U│   Recently Added                    [+] no key                      none                lists                │
    │   Up Next                           [0] [+]                         0                   lists                │
    │   Search                            [/] [+]                         /                   lists                │
    │ Play                                                                                                         │
    │   Play / pause                      [Space] [+]                     Space               lists                │
    │ * Next                              [>] [+]                         n >                 lists                │
    │   Previous                          [p] [<] [+]                     p <                 lists                │
    │   Seek back 5 s                     [←] [+]                         ←                   lists                │m
    │   Seek forward 5 s                  [→] [+]                         →                   lists                │
    │   Seek back 30 s                    [[] [⇧←] [+]                    [ ⇧←                lists                │
    │   Seek forward 30 s                 []] [⇧→] [+]                    ] ⇧→                lists                │
    │   Volume up                         [+] [=] [+]                     + =                 lists                │
    │   Volume down                       [-] [+]                         -                   lists                │
    │   Mute                              [m] [+]                         m                   lists                │
    │ * Shuffle                           [n] [+]                         s                   lists                │
    │   Repeat: off, all, one             [r] [+]                         r                   lists                │
────│   Play album or playlist from the … [P] [+]                         P                   lists                │────
 ■ N│ ← → pick a key · Enter change (on [+]: add) · d remove · u row default · U all defaults · / find             │50%
 -:-╰─ w save · Esc close · Tab next tab ──────────────────────────────────────────────────────────────────────────╯:--
 ● us  connecting                                                    PROTOTYPE B settings dialog · , opens · { } switch
```

#### B: / finds actions by name

```
 am                   │ Home                                                     ⠋ │ Now Playing
    ╭─ Settings ───────────────────────────────────────────────────────────────────────────────────────────────────╮
▌1 H│ 1 Keys   2 Engine   3 Artwork                                                              2 unsaved changes │
 2 R│──────────────────────────────────────────────────────────────────────────────────────────────────────────────│
 Lib│ Find: vol                                                                                                    │
   3│                                                                                                              │
   4│   Action                            Keys                            Default             Where                │
   5│ Play                                                                                                         │
   6│   Volume up                         [+] [=] [+]                     + =                 lists                │
    │   Volume down                       [-] [+]                         -                   lists                │
 7 F│                                                                                                              │
 8 R│                                                                                                              │
 9 C│                                                                                                              │
 / S│                                                                                                              │
 0 U│                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │m
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
────│                                                                                                              │────
 ■ N│ ← → pick a key · Enter change (on [+]: add) · d remove · u row default · U all defaults · / find             │50%
 -:-╰─ w save · Esc close · Tab next tab ──────────────────────────────────────────────────────────────────────────╯:--
 ● us  connecting                                                    PROTOTYPE B settings dialog · , opens · { } switch
```

#### B: the Engine tab, keep-alive picked (unsaved)

```
 am                   │ Home                                                     ⠋ │ Now Playing
    ╭─ Settings ───────────────────────────────────────────────────────────────────────────────────────────────────╮
▌1 H│ 1 Keys   2 Engine   3 Artwork                                                              3 unsaved changes │
 2 R│──────────────────────────────────────────────────────────────────────────────────────────────────────────────│
 Lib│ The engine is the hidden browser that plays the music.                                                       │
   3│                                                                                                              │
   4│  ( ) Start it when needed, close it after 5 idle minutes  default                                            │
   5│  (•) Keep it running while am is open                                                                        │
   6│                                                                                                              │
    │  Keeping it running: the first play after opening am starts about 1.5 s sooner (1.6 s instead of 4 s,        │
 7 F│  measured on a Mac). The engine then holds about 700 MiB of memory and 0.5 % CPU for as long as am is        │
 8 R│  open, and in a two-hour test its memory grew by 1 to 2 MiB a minute.                                        │
 9 C│                                                                                                              │
 / S│  Applies when you save: on starts the engine at once; off lets it close after 5 idle minutes.                │
 0 U│                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │m
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
────│                                                                                                              │────
 ■ N│ j k move · Enter choose                                                                                      │50%
 -:-╰─ w save · Esc close · Tab next tab ──────────────────────────────────────────────────────────────────────────╯:--
 ● us  connecting                                                    PROTOTYPE B settings dialog · , opens · { } switch
```

#### B: the Artwork tab

```
 am                   │ Home                                                     ⠋ │ Now Playing
    ╭─ Settings ───────────────────────────────────────────────────────────────────────────────────────────────────╮
▌1 H│ 1 Keys   2 Engine   3 Artwork                                                              3 unsaved changes │
 2 R│──────────────────────────────────────────────────────────────────────────────────────────────────────────────│
 Lib│ Album art in the now-playing pane and on album and playlist pages.                                           │
   3│                                                                                                              │
   4│  (•) Auto: images if this terminal shows them, else blocks  default                                          │
   5│  ( ) Images (kitty graphics)  this terminal didn't answer the image check                                    │
   6│  ( ) Blocks (half-block characters, any color terminal)                                                      │
    │  ( ) Off                                                                                                     │
 7 F│                                                                                                              │
 8 R│  Showing now: blocks. Applies when you save. v still cycles images, blocks and off, for this session only.   │
 9 C│                                                                                                              │
 / S│                                                                                                              │
 0 U│                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │m
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
────│                                                                                                              │────
 ■ N│ j k move · Enter choose                                                                                      │50%
 -:-╰─ w save · Esc close · Tab next tab ──────────────────────────────────────────────────────────────────────────╯:--
 ● us  connecting                                                    PROTOTYPE B settings dialog · , opens · { } switch
```

#### B: Esc with unsaved changes asks

```
 am                   │ Home                                                     ⠋ │ Now Playing
    ╭─ Settings ───────────────────────────────────────────────────────────────────────────────────────────────────╮
▌1 H│ 1 Keys   2 Engine   3 Artwork                                                              3 unsaved changes │
 2 R│──────────────────────────────────────────────────────────────────────────────────────────────────────────────│
 Lib│ Album art in the now-playing pane and on album and playlist pages.                                           │
   3│                                                                                                              │
   4│  (•) Auto: images if this terminal shows them, else blocks  default                                          │
   5│  ( ) Images (kitty graphics)  this terminal didn't answer the image check                                    │
   6│  ( ) Blocks (half-block characters, any color terminal)                                                      │
    │  ( ) Off                                                                                                     │
 7 F│                                                                                                              │
 8 R│  Showing now: blocks. Applies when you save. v still cycles images, blocks and off, for this session only.   │
 9 C│                                                                                                              │
 / S│                                                                                                              │
 0 U│                         ╭─ Unsaved changes ────────────────────────────────────────╮                         │
    │                         │ Discard 3 unsaved changes?                               │                         │
    │                         │                                                          │                         │
    │                         │ y discard · w save · any other key keeps editing         │                         │
    │                         ╰──────────────────────────────────────────────────────────╯                         │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │m
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
    │                                                                                                              │
────│                                                                                                              │────
 ■ N│ j k move · Enter choose                                                                                      │50%
 -:-╰─ w save · Esc close · Tab next tab ──────────────────────────────────────────────────────────────────────────╯:--
 ● us  connecting                                                    PROTOTYPE B settings dialog · , opens · { } switch
```

#### C editable help: opened with `?`, Enter on Shuffle waits for a key

```
 am                   │ Home                                                     ⠋ │ Now Playing
        ╭─ Keys and settings ──────────────────────────────────────────────────────────────────────────────────╮
▌1 Home │ Enter changes the line under the cursor, at once.                                                    │
 2 Recen│ Move                                                Play                                             │
 Library│   j ↓ ^n      Move down                               Space       Play / pause                       │
   3 Son│   k ↑ ^p      Move up                                 n >         Next                               │
   4 Alb│   g Home      Top                                     p <         Previous                           │
   5 Art│   G End       Bottom                                  ←           Seek back 5 s                      │
   6 Pla│   PgDn        Page down                               →           Seek forward 5 s                   │
     Rec│   PgUp        Page up                                 [ ⇧←        Seek back 30 s                     │
 7 Favor│   ^d          Half page down                          ] ⇧→        Seek forward 30 s                  │
 8 Radio│   ^u          Half page up                            + =         Volume up                          │
 9 Chart│   Tab         Other pane                              -           Volume down                        │
 / Searc│   ⇧Tab        Other pane, backwards                   m           Mute                               │
 0 Up Ne│   h           To the sidebar                          press a key Shuffle                            │
        │   l           To the list                             r           Repeat: off, all, one              │
        │   Enter       Open, or play from here                 P           Play album or playlist from the t… │
        │   Esc Backsp… Back                                    e           Play later                         │
        │   ^f          Filter this list                        E           Play next                          │
        │   o           Go to album                             R           Station from the selection         │
        │   O           Go to artist                            d Del       Remove from Up Next                │: it
        │   c           Go to what's playing                                                                   │album
        │                                                     App                                              │
        │ Sections                                              ,           Settings                           │
        │   1           Home                                    ?           Help                               │
        │   2           Recently Played                         v           Artwork: images, blocks, off       │
        │   3           Songs                                   ^r          Reload view                        │
        │   4           Albums                                  ^l          Redraw                             │
        │   5           Artists                                 S           Sign in to Apple Music again       │
        │   6           Playlists                               q           Quit (the music goes on)           │
────────│   7           Favorites                               Q           Quit and stop the music            │────────
 ■ Nothi│   8           Radio                                   ^c          Quit, from anywhere (fixed)        │vol 50%
 -:--   ╰─ Press the key for Shuffle · Esc cancels ────────────────────────────────────────────────────────────╯   -:--
 ● us  connecting                                                      PROTOTYPE C editable help · ? opens · { } switch
```

#### C: n taken from Next at once; the bottom line offers z undo

```
 am                   │ Home                                                     ⠋ │ Now Playing
        ╭─ Keys and settings ──────────────────────────────────────────────────────────────────────────────────╮
▌1 Home │ Enter changes the line under the cursor, at once.                                                    │
 2 Recen│ Move                                                Play                                             │
 Library│   j ↓ ^n      Move down                               Space       Play / pause                       │
   3 Son│   k ↑ ^p      Move up                               • >           Next                               │
   4 Alb│   g Home      Top                                     p <         Previous                           │
   5 Art│   G End       Bottom                                  ←           Seek back 5 s                      │
   6 Pla│   PgDn        Page down                               →           Seek forward 5 s                   │
     Rec│   PgUp        Page up                                 [ ⇧←        Seek back 30 s                     │
 7 Favor│   ^d          Half page down                          ] ⇧→        Seek forward 30 s                  │
 8 Radio│   ^u          Half page up                            + =         Volume up                          │
 9 Chart│   Tab         Other pane                              -           Volume down                        │
 / Searc│   ⇧Tab        Other pane, backwards                   m           Mute                               │
 0 Up Ne│   h           To the sidebar                        • n           Shuffle                            │
        │   l           To the list                             r           Repeat: off, all, one              │
        │   Enter       Open, or play from here                 P           Play album or playlist from the t… │
        │   Esc Backsp… Back                                    e           Play later                         │
        │   ^f          Filter this list                        E           Play next                          │
        │   o           Go to album                             R           Station from the selection         │
        │   O           Go to artist                            d Del       Remove from Up Next                │: it
        │   c           Go to what's playing                                                                   │album
        │                                                     App                                              │
        │ Sections                                              ,           Settings                           │
        │   1           Home                                    ?           Help                               │
        │   2           Recently Played                         v           Artwork: images, blocks, off       │
        │   3           Songs                                   ^r          Reload view                        │
        │   4           Albums                                  ^l          Redraw                             │
        │   5           Artists                                 S           Sign in to Apple Music again       │
        │   6           Playlists                               q           Quit (the music goes on)           │
────────│   7           Favorites                               Q           Quit and stop the music            │────────
 ■ Nothi│   8           Radio                                   ^c          Quit, from anywhere (fixed)        │vol 50%
 -:--   ╰─ n is Shuffle now; Next keeps > · z undo ────────────────────────────────────────────────────────────╯   -:--
 ● us  connecting                                                      PROTOTYPE C editable help · ? opens · { } switch
```
