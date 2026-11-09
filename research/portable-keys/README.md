# Which keys reach am the same way in every terminal? (wayfinder ticket #22)

Throwaway branch, never merged. The answer is the resolution comment on
[#22](https://github.com/IIxauII/am/issues/22); this is the data behind it, for
[#23](https://github.com/IIxauII/am/issues/23) (which keys a binding may use, and how
`settings.json` names them).

Gathered 2026-11-09 on an Apple M4 with macOS 26.2 (25C56), against am at
[`31a0ddf`](https://github.com/IIxauII/am/tree/31a0ddfdf8fe8b6f378ffbff561712fb11572323).

Every fact is tagged:

- *measured*: run or read on this Mac. That covers am's decoder (run), Ghostty's CLI, the
  terminfo database, the installed Terminal.app and iTerm2 bundles and binaries, and macOS's
  shortcut tables. No keystroke was sent to any window, no terminal window was opened, and no
  setting was changed, so no terminal's live output was captured.
- *source*: read in a terminal's source or docs, pinned to a release tag (links).
- *inferred*: reasoned from the above; the basis is given.

Byte notation: `\e` is ESC (0x1b), `\x7f` DEL, `\r` CR. "C0 byte" means a control byte 0x00–0x1f.
"`m`" is the xterm modifier parameter, 1 + Shift 1 + Alt 2 + Ctrl 4 (+ 8 for Meta in xterm, Super
in kitty's protocol). "Taken" means the terminal, desktop or OS keeps the key and am never sees it.

Terms: *legacy encoding* is what terminals send when no app asks for more: text as UTF-8,
Ctrl+letter as a C0 byte, Alt as an ESC prefix, named keys as xterm-style escape sequences. The
*kitty keyboard protocol* is kitty's opt-in encoding, turned on by an app with `CSI > flags u`;
flag 1 ("disambiguate") sends every ambiguous key as `CSI <code>;<m> u`. *modifyOtherKeys* is
xterm's older opt-in (`CSI > 4 ; 2 m`), which sends modified keys as `CSI 27;<m>;<code> ~`.
*win32-input-mode* is Windows Terminal's private encoding of raw Windows key events.

## Answer

- **The same everywhere** (same bytes, same decoded key, kept by no listed terminal at defaults):
  printable characters, Space, Enter, Tab, Shift+Tab, Esc (after am's 30 ms wait), Backspace, the
  four unmodified arrows, Home, End, PgUp, PgDn, Delete, F1–F9 and F12, and Ctrl+letter except
  the collisions below and the few a terminal keeps (Ctrl+b in tmux, Ctrl+v in Windows Terminal).
  am binds characters, so `/` works whether a layout types it with Shift+7 or a key of its own. On
  a Mac keyboard the F-keys need Fn, Home/End/PgUp/PgDn are Fn+arrows, and there's no Insert.
- **Differ by terminal or OS:** anything with Alt/Option; Ctrl+digit and Ctrl+punctuation;
  Ctrl+Shift+letter; Shift/Ctrl+Enter; Alt+Backspace; modified Home, End, PgUp, PgDn and F-keys;
  Shift/Ctrl/Alt+arrows; F10, F11, Ctrl+Tab, Alt+Enter. [Across terminals](#across-terminals-what-a-recorded-key-means-elsewhere)
  has one row per key.
- **Never arrive somewhere:** Cmd on macOS (a few are rewritten into Ctrl keys), Ctrl+arrows,
  Ctrl+Space, Ctrl+F1–F8 and F11 on macOS, the Linux terminals' Ctrl+Shift shortcuts, zoom keys,
  Ctrl+Tab, Alt+Enter, Shift+PgUp/PgDn in several, the desktops' Alt and Super shortcuts, Windows
  Terminal's defaults, tmux's prefix. [Keys that never reach am](#keys-that-never-reach-am).
- **Legacy collisions:** Ctrl+i is Tab, Ctrl+m and Ctrl+j are Enter, Ctrl+h, Ctrl+Backspace and
  Ctrl+8 are Backspace, Ctrl+[ and Ctrl+3 are Esc, Ctrl+Space, Ctrl+2 and Ctrl+@ are `ctrl+space`,
  Ctrl+/ and Ctrl+7 are `ctrl+_`, Ctrl+Shift+letter is Ctrl+letter, Shift+Space is Space,
  Shift+Enter is Enter. Ghostty and foot break some of these even without a protocol (Ghostty
  sends Ctrl+i, Ctrl+m, Ctrl+[ and Ctrl+Shift+letter as `CSI u`; Ghostty and foot send Shift+Enter
  as `CSI 27`), so a key recorded there can be one the others never send.
- **Keyboard protocols:** the kitty protocol works in iTerm2, Ghostty, kitty, Alacritty, Konsole
  26.08+, foot and (*inferred*) Windows Terminal 1.25; it is off by default in WezTerm and missing
  in Terminal.app, GNOME Terminal, xterm and tmux. Flag 1 removes the collisions except
  Shift+Space, and the Esc wait, where it works. It doesn't touch macOS Option, taken keys, or
  terminals without it. modifyOtherKeys (xterm, iTerm2, Ghostty, WezTerm, foot, tmux on request)
  removes the collisions, Shift+Space included, but not the Esc wait.

## What am's decoder makes of each sequence

*Measured*: [`probe.zig`](probe.zig) feeds each byte sequence to the `Decoder` in
`src/tui/input.zig` at `31a0ddf`, flushes it as the 30 ms timeout would, and passes each key to
`keys.command` (lists) and `keys.textCommand` (typing). Run with Zig 0.17.0: copy
`src/tui/input.zig` and `src/tui/keys.zig` from `31a0ddf` next to `probe.zig`, then
`zig test probe.zig` (the table goes to stderr). `-` means the key does nothing there today.

| Key | Bytes | am decodes | `command` (lists) | `textCommand` (typing) |
|---|---|---|---|---|
| a | `a` | 'a' | add_library | insert 'a' |
| Shift+a | `A` | 'A' | add_playlist | insert 'A' |
| Option+f composed (US) | `\xc6\x92` | 'ƒ' | - | insert 'ƒ' |
| Option+a composed (US) | `\xc3\xa5` | 'å' | - | insert 'å' |
| Option+5 composed (German: [) | `[` | '[' | seek=-30 | insert '[' |
| Alt+a (ESC prefix) | `\ea` | alt+'a' | add_library | insert 'a' |
| Alt+Shift+a (ESC prefix) | `\eA` | alt+'A' | add_playlist | insert 'A' |
| Alt+1 | `\e1` | alt+'1' | section=home | insert '1' |
| Alt+[ alone (flushed) | `\e[` | alt+'[' | seek=-30 | insert '[' |
| Alt+[ then A within 30 ms | `\e[A` | up | move=-1 | up |
| Alt+O then P within 30 ms | `\eOP` | F1 | - | - |
| Alt+Shift+O alone (flushed) | `\eO` | alt+'O' | go_artist | insert 'O' |
| Alt+_ alone (flushed) | `\e_` | alt+'_' | - | insert '_' |
| Alt+Esc | `\e\e` | alt+esc | back | leave |
| Alt+a 8-bit meta (xterm eightBitInput) | `\xe1` | (nothing) |  |  |
| Alt+a 8-bit meta, UTF-8 encoded | `\xc3\xa1` | 'á' | - | insert 'á' |
| xterm Alt+Backspace (U+0088) | `\xc2\x88` | U+0088 | - | insert U+0088 |
| xterm Alt+Esc (U+009B) | `\xc2\x9b` | U+009B | - | insert U+009B |
| Konsole Super+a | `\x18@sa` | ctrl+'x', '@', 's', 'a' | -, -, shuffle, add_library | -, insert '@', insert 's', insert 'a' |
| Konsole Super+Up | `\e[1;1A` | up | move=-1 | up |
| 0x00 (Ctrl+Space, Ctrl+@, Ctrl+2) | `\x00` | ctrl+' ' | - | - |
| 0x08 (Ctrl+h, Ctrl+Backspace, BS key) | `\x08` | backspace | back | delete_back |
| 0x09 (Tab, Ctrl+i) | `\x09` | tab | focus_next | toggle_scope |
| 0x0a (Ctrl+j, LF) | `\x0a` | enter | open | submit |
| 0x0d (Enter, Ctrl+m) | `\x0d` | enter | open | submit |
| 0x1b alone (Esc, Ctrl+[, Ctrl+3) | `\e` | esc | back | leave |
| 0x1c (Ctrl+\, Ctrl+4) | `\x1c` | ctrl+'\' | - | - |
| 0x1d (Ctrl+], Ctrl+5) | `\x1d` | ctrl+']' | - | - |
| 0x1e (Ctrl+^, Ctrl+6) | `\x1e` | ctrl+'^' | - | - |
| 0x1f (Ctrl+/, Ctrl+_, Ctrl+7, Ctrl+-) | `\x1f` | ctrl+'_' | - | - |
| 0x7f (Backspace, Ctrl+8, Ctrl+?) | `\x7f` | backspace | back | delete_back |
| 0x17 (Ctrl+w; some send for Ctrl+Backspace) | `\x17` | ctrl+'w' | - | - |
| 0x03 (Ctrl+c) | `\x03` | ctrl+'c' | quit | quit |
| 0x1a (Ctrl+z) | `\x1a` | ctrl+'z' | suspend_process | - |
| Alt+Backspace | `\e\x7f` | alt+backspace | back | delete_back |
| Alt+Ctrl+h / Alt+Ctrl+Backspace | `\e\x08` | alt+backspace | back | delete_back |
| Ctrl+Alt+a | `\e\x01` | ctrl+alt+'a' | - | - |
| Up (normal mode) | `\e[A` | up | move=-1 | up |
| Up (application mode) | `\eOA` | up | move=-1 | up |
| Shift+Up | `\e[1;2A` | shift+up | move=-1 | up |
| Alt+Up | `\e[1;3A` | alt+up | move=-1 | up |
| Ctrl+Up | `\e[1;5A` | ctrl+up | - | - |
| Ctrl+Shift+Up | `\e[1;6A` | ctrl+shift+up | - | - |
| Meta+Up (xterm 9) | `\e[1;9A` | alt+up | move=-1 | up |
| Shift+Left | `\e[1;2D` | shift+left | seek=-30 | - |
| Alt+Left (ESC ESC [ D) | `\e\e[D` | alt+left | seek=-5 | - |
| Option+Left (Terminal.app ESC b) | `\eb` | alt+'b' | - | insert 'b' |
| Option+Right (Terminal.app ESC f) | `\ef` | alt+'f' | favorite | insert 'f' |
| Home CSI H | `\e[H` | home | top | - |
| Home SS3 H | `\eOH` | home | top | - |
| Home CSI 1~ | `\e[1~` | home | top | - |
| Home CSI 7~ (rxvt) | `\e[7~` | home | top | - |
| End CSI F | `\e[F` | end | bottom | - |
| End CSI 4~ | `\e[4~` | end | bottom | - |
| Shift+Home | `\e[1;2H` | shift+home | top | - |
| Insert | `\e[2~` | insert | - | - |
| Delete | `\e[3~` | delete | remove | - |
| Shift+Delete | `\e[3;2~` | shift+delete | remove | - |
| PgUp | `\e[5~` | page_up | page=-1 | - |
| Shift+PgUp | `\e[5;2~` | shift+page_up | page=-1 | - |
| F1 SS3 | `\eOP` | F1 | - | - |
| F1 CSI 11~ | `\e[11~` | F1 | - | - |
| F1 linux console | `\e[[A` | 'A' | add_playlist | insert 'A' |
| F3 SS3 | `\eOR` | F3 | - | - |
| F5 | `\e[15~` | F5 | - | - |
| F12 | `\e[24~` | F12 | - | - |
| Shift+F1 xterm | `\e[1;2P` | shift+F1 | - | - |
| Shift+F1 SS3 2P (old Konsole/xterm) | `\eO2P` | alt+'O', '2', 'P' | go_artist, section=recent, play_container | insert 'O', insert '2', insert 'P' |
| Ctrl+F1 Konsole | `\eO5P` | alt+'O', '5', 'P' | go_artist, section=artists, play_container | insert 'O', insert '5', insert 'P' |
| Shift+F3 Konsole | `\eO2R` | alt+'O', '2', 'R' | go_artist, section=recent, station | insert 'O', insert '2', insert 'R' |
| Shift+F3 xterm | `\e[1;2R` | shift+F3 | - | - |
| Ctrl+F3 xterm | `\e[1;5R` | ctrl+F3 | - | - |
| Shift+F5 | `\e[15;2~` | shift+F5 | - | - |
| F13 (CSI 25~) | `\e[25~` | F13 | - | - |
| Shift+F1 as F11 (VT220 shifted) | `\e[23~` | F11 | - | - |
| Shift+Tab | `\e[Z` | shift+tab | focus_prev | toggle_scope |
| Keypad Enter (application keypad) | `\eOM` | enter | open | submit |
| kitty Esc | `\e[27u` | esc | back | leave |
| kitty Ctrl+i | `\e[105;5u` | ctrl+'i' | - | - |
| kitty Ctrl+h | `\e[104;5u` | ctrl+'h' | - | delete_back |
| kitty Ctrl+m | `\e[109;5u` | ctrl+'m' | - | - |
| kitty Ctrl+j | `\e[106;5u` | ctrl+'j' | - | - |
| kitty Ctrl+[ | `\e[91;5u` | ctrl+'[' | - | - |
| kitty Ctrl+Space | `\e[32;5u` | ctrl+' ' | - | - |
| kitty Ctrl+c | `\e[99;5u` | ctrl+'c' | quit | quit |
| kitty Ctrl+z | `\e[122;5u` | ctrl+'z' | suspend_process | - |
| kitty Ctrl+Shift+a | `\e[97;6u` | ctrl+shift+'a' | - | - |
| kitty Alt+a | `\e[97;3u` | alt+'a' | add_library | insert 'a' |
| kitty Alt+Shift+a | `\e[97;4u` | alt+shift+'a' | add_library | insert 'a' |
| kitty Alt+Shift+a, flag 4 alternate | `\e[97:65;4u` | alt+shift+'a' | add_library | insert 'a' |
| kitty Ctrl+1 | `\e[49;5u` | ctrl+'1' | - | - |
| kitty Ctrl+2 | `\e[50;5u` | ctrl+'2' | - | - |
| kitty Ctrl+3 | `\e[51;5u` | ctrl+'3' | - | - |
| kitty Ctrl+8 | `\e[56;5u` | ctrl+'8' | - | - |
| kitty Alt+[ | `\e[91;3u` | alt+'[' | seek=-30 | insert '[' |
| kitty Ctrl+Shift+3 (legacy mode too) | `\e[51;6u` | ctrl+shift+'3' | - | - |
| kitty Ctrl+/ | `\e[47;5u` | ctrl+'/' | - | - |
| kitty Shift+Enter | `\e[13;2u` | shift+enter | open | submit |
| kitty Ctrl+Enter | `\e[13;5u` | ctrl+enter | - | - |
| kitty Shift+Space (flag 8 only) | `\e[32;2u` | shift+' ' | toggle | insert ' ' |
| kitty Shift+Backspace | `\e[127;2u` | shift+backspace | back | delete_back |
| kitty Ctrl+Backspace | `\e[127;5u` | ctrl+backspace | - | - |
| kitty Shift+Tab | `\e[9;2u` | shift+tab | focus_prev | toggle_scope |
| kitty Ctrl+Tab | `\e[9;5u` | ctrl+tab | - | - |
| kitty Super+a (Cmd) | `\e[97;9u` | alt+'a' | add_library | insert 'a' |
| kitty Hyper+a | `\e[97;17u` | 'a' | add_library | insert 'a' |
| kitty Meta+a (bit 32) | `\e[97;33u` | 'a' | add_library | insert 'a' |
| kitty Ctrl+a, Caps Lock on | `\e[97;69u` | ctrl+'a' | - | - |
| kitty Ctrl+a, Num Lock on | `\e[97;133u` | ctrl+'a' | - | - |
| kitty Ctrl+Up | `\e[1;5A` | ctrl+up | - | - |
| kitty F3 | `\e[13~` | F3 | - | - |
| kitty F13 | `\e[57376u` | char(U+E020 private use) | - | insert U+E020 |
| kitty KP_Enter | `\e[57414u` | char(U+E046 private use) | - | insert U+E046 |
| kitty KP_1 | `\e[57400u` | char(U+E038 private use) | - | insert U+E038 |
| kitty KP_Up | `\e[57419u` | char(U+E04B private use) | - | insert U+E04B |
| kitty Menu | `\e[57363u` | char(U+E013 private use) | - | insert U+E013 |
| kitty Media play/pause | `\e[57430u` | char(U+E056 private use) | - | insert U+E056 |
| kitty Ctrl+ä (German, U+00E4) | `\e[228;5u` | ctrl+'ä' | - | - |
| mOK Ctrl+a | `\e[27;5;97~` | ctrl+'a' | - | - |
| mOK Ctrl+Shift+a (code 65) | `\e[27;6;65~` | ctrl+shift+'A' | - | - |
| mOK Ctrl+Shift+a (code 97) | `\e[27;6;97~` | ctrl+shift+'a' | - | - |
| mOK Ctrl+i | `\e[27;5;105~` | ctrl+'i' | - | - |
| mOK Ctrl+h | `\e[27;5;104~` | ctrl+'h' | - | delete_back |
| mOK Ctrl+m | `\e[27;5;109~` | ctrl+'m' | - | - |
| mOK Ctrl+[ | `\e[27;5;91~` | ctrl+'[' | - | - |
| mOK Ctrl+Space | `\e[27;5;32~` | ctrl+' ' | - | - |
| mOK Shift+Enter | `\e[27;2;13~` | shift+enter | open | submit |
| mOK Ctrl+Enter | `\e[27;5;13~` | ctrl+enter | - | - |
| mOK Shift+Space | `\e[27;2;32~` | shift+' ' | toggle | insert ' ' |
| mOK Alt+a | `\e[27;3;97~` | alt+'a' | add_library | insert 'a' |
| mOK Ctrl+1 | `\e[27;5;49~` | ctrl+'1' | - | - |
| mOK Ctrl+Tab | `\e[27;5;9~` | ctrl+tab | - | - |
| mOK Ctrl+Backspace | `\e[27;5;127~` | ctrl+backspace | - | - |
| mOK Ctrl+Backspace (code 8) | `\e[27;5;8~` | ctrl+backspace | - | - |
| mOK fmt1 Ctrl+Shift+a | `\e[65;6u` | ctrl+shift+'A' | - | - |
| mOK Ctrl+Shift+a, Shift dropped (WezTerm) | `\e[27;5;65~` | ctrl+'A' | - | - |
| Ghostty legacy Super+Enter | `\e[27;9;13~` | alt+enter | open | submit |
| Ghostty legacy Ctrl+; | `\e[59;5u` | ctrl+';' | - | - |
| foot legacy Ctrl+1 | `\e[27;5;49~` | ctrl+'1' | - | - |
| win32-input-mode 'a' down | `\e[65;30;97;1;0;1_` | (nothing) |  |  |
| kitty flags reply CSI ? 1 u | `\e[?1u` | (nothing) |  |  |
| XTQMODKEYS reply CSI > 4;2 m | `\e[>4;2m` | (nothing) |  |  |

What the table shows, beyond the ticket's facts:

- **Today's keymap drops Alt, and Shift on most keys.**
  [`command`](https://github.com/IIxauII/am/blob/31a0ddf/src/tui/keys.zig#L126) branches on Ctrl
  only, so Alt+a does what `a` does (`add_library`) and Alt+↑ moves like ↑. In a text field Alt+a
  types `a` ([`textCommand`](https://github.com/IIxauII/am/blob/31a0ddf/src/tui/keys.zig#L224)).
  Shift is read only on Tab and ←/→, so Shift+↑, Shift+PgUp, Shift+Delete and Shift+Enter act like
  the plain key.
- **A C0 byte has one name, whatever was pressed.** 0x1f decodes as `ctrl+_` (what Ctrl+/,
  Ctrl+7, Ctrl+- and Ctrl+_ send in most terminals), 0x1c as `ctrl+\`, 0x1d as `ctrl+]`, 0x1e as
  `ctrl+^`, 0x00 as `ctrl+space`. 0x0a (Ctrl+j) decodes as Enter, like 0x0d (Ctrl+m). 0x08 and 0x7f
  are both Backspace, so `textCommand`'s `^h` branch is reachable only when a terminal sends
  `\e[104;5u` or `\e[27;5;104~`.
- **ESC-prefix Alt is ambiguous for `[` and `O`.** Alt+[ followed within 30 ms by `A` decodes as
  ↑, and Alt+O followed by `P` as F1. Alone, they decode as `alt+[` and `alt+O`.
- **Konsole's modified F1–F4 decode as three keys.** `\eO2P` (Shift+F1) is Alt+O, `2`, `P`, which
  in lists is go to artist, Recently Played, play container. Shift+F3 (`\eO2R`) ends in `R`: start
  a station.
- **Konsole's Super adds `\x18@s`**, so Super+a decodes as `ctrl+x`, `@`, `s` (shuffle), `a`
  (add to library).
- **kitty's private-use key codes decode as characters.** F13 (`\e[57376u`), keypad Enter
  (`\e[57414u`), media keys and Menu become a private-use character that a text field inserts.
  kitty sends F13–F35 and media keys this way even without a protocol.
- **Modifier bit 8 decodes as Alt.** `applyModifiers` counts xterm's Meta bit as Alt, but Super is
  bit 8 in kitty's protocol, in Ghostty, kitty and Alacritty legacy (`\e[1;9A` for Super+↑) and in
  foot. So Super+↑ decodes as Alt+↑, and Ghostty's Super+Enter (`\e[27;9;13~`) as Alt+Enter.
  Hyper (16) and Meta (32) are dropped, so `\e[97;17u` is a plain `a`. Caps Lock (64) and Num
  Lock (128) are dropped, as they should be.
- **xterm's 8-bit Alt arrives as Latin-1 text**: Alt+a is `á`, Alt+Backspace U+0088 and Alt+Esc
  U+009B, which a text field inserts.
- **The protocols name Ctrl+Shift+a three ways**: kitty's `\e[97;6u` is `ctrl+shift+a`,
  modifyOtherKeys' `\e[27;6;65~` is `ctrl+shift+A`, and WezTerm's `\e[27;5;65~` is `ctrl+A`.
- **Replies and foreign records produce nothing**: kitty's flags reply `\e[?1u`, xterm's
  `\e[>4;2m`, and a win32-input-mode record (`\e[65;30;97;1;0;1_`) are skipped.

## Measured on this Mac

Apple M4, macOS 26.2 (25C56). Installed: Terminal.app 2.15, iTerm2 3.6.9, Ghostty 1.3.1 (stable,
built with Zig 0.15.2). Not installed: kitty, WezTerm, Alacritty, tmux. No keystrokes were sent and
no terminal window was opened; everything below is read from the installed apps, their CLIs and
the terminfo database.

### Ghostty 1.3.1, from its own CLI

`ghostty +show-config --default --docs` and `ghostty +list-keybinds --default` (CLI actions, no
window):

- `macos-option-as-alt` is unset by default, and unset means: **true on the U.S. Standard and U.S.
  International layouts, false on every other layout**. "If an Option-sequence doesn't produce a
  printable character, it will be treated as Alt regardless" (e.g. Ctrl+Option+a). So the same
  Ghostty sends `\ef` for Option+f on a US Mac and `ƒ` on a German one.
- 93 default keybinds. The ones without Cmd that touch keys am could bind:
  - `alt+arrow_left=esc:b`, `alt+arrow_right=esc:f`: Option+←/→ send `\eb` / `\ef`, which am
    reads as Alt+b / Alt+f, not as Alt+arrow.
  - `ctrl+tab=next_tab`, `ctrl+shift+tab=previous_tab`.
  - `shift+arrow_*`, `shift+page_up/down`, `shift+home/end` = `adjust_selection`, and
    `escape=end_search`. These are "performable" binds: the key reaches am when there is no
    selection or search (*source*, Ghostty section below).
- Cmd bindings that send text: `super+arrow_left=text:\x01`, `super+arrow_right=text:\x05`,
  `super+backspace=text:\x15`. am reads them as Ctrl+a, Ctrl+e and Ctrl+u, so **Cmd+Backspace in
  Ghostty does what `^u` does in am** (half page up in lists, clear in a text field).
- Every other default bind uses Cmd (`super`): tabs `super+1…9`, `super+t/w/n/d`, font size
  `super+= - 0`, `super+enter` fullscreen, `super+k` clear, `super+f/g/e` search, `super+[ ]`
  splits, `super+alt+arrows`, `super+ctrl+arrows`, `super+shift+arrows`, `super+home/end/page_up/
  page_down` scrolling, `super+c/v/a/z/q`.

### terminfo entries (ncurses 6.6.20251230 from Homebrew, `infocmp -1 -x`)

What each entry's authors record that the terminal sends. am doesn't send `smkx`, so the keys
arrive in their normal-mode form (`\e[A` rather than `\eOA`); am decodes both.

| Entry (terminal) | kbs | khome / kend | kf1 / kf13 (Shift+F1) | kent (keypad Enter) |
|---|---|---|---|---|
| `xterm-256color` | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | `\eOM` |
| `nsterm-256color` (Terminal.app) | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[25~` | `\eOM` |
| `iTerm2.app` | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | — |
| `xterm-ghostty` (Ghostty) | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | `\eOM` |
| `wezterm` | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | — |
| `alacritty` | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | `\eOM` |
| `foot` | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | — |
| `vte-256color` (GNOME Terminal) | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | `\eOM` |
| `konsole-256color` | `^?` | `\eOH` / `\eOF` | `\eOP` / **`\eO2P`** | — |
| `tmux-256color` | `^?` | **`\e[1~` / `\e[4~`** | `\eOP` / `\e[1;2P` | — |
| `screen-256color` | `^?` | `\e[1~` / `\e[4~` | `\eOP` / — | — |
| `ms-terminal` (Windows Terminal) | `^?` | `\eOH` / `\eOF` | `\eOP` / `\e[1;2P` | — |

Every entry records Backspace as DEL (0x7f), Shift+Tab as `\e[Z`, Ctrl+Delete as `\e[3;5~` where
it records one, and Ctrl+→ as `\e[1;5C`. For `nsterm`, `kf13` is the F13 key (Terminal.app's
Shift+F1 sends nothing, below). Konsole's `\eO2P` for Shift+F1 is the one form am misreads (three
keys, see the probe).

## Per terminal

### Terminal.app 2.15 and iTerm2 3.6.9 (macOS 26.2)

Both are installed here. The owner's settings match the defaults for keys (*measured*:
`com.apple.Terminal` has no key override; iTerm2's "Option Key Sends" and "Right Option Key Sends"
are 0 = Normal, the profile key map is empty, no global key map override). Tags used here:

- *measured (plist)*: `Terminal.app/Contents/Resources/keyMappings.plist`.
- *measured (binary)*: read from the Terminal binary (arm64e) by disassembly: built-in profile
  defaults, key-down handler, key encoder, `MainMenu.nib`.
- *measured (event)*: NSEvents built in memory from CGEvents, reading their `characters` on the US
  layout; nothing was posted to any window. *measured (layout)*: `UCKeyTranslate` on the US and
  German layout data.
- *source*: iTerm2 at [`v3.6.9`](https://github.com/gnachman/iTerm2/tree/v3.6.9/sources) (commit
  `c30dfc5`), mainly `iTermStandardKeyMapper.m`, `VT100Output.m`, `iTermProfilePreferences.m`,
  `iTermModernKeyMapper.swift`; iTerm2's bundled `DefaultBookmark.plist` and
  `DefaultGlobalKeyMap.plist` were also read (*measured*). iTerm2's newest stable is 3.7.7
  (2026-11-03).
- *inferred*: Cocoa text-system fallbacks that no key press verified.

Terminal.app defaults (*measured, binary*): `useOptionAsMetaKey=NO`, `ScrollAlternateScreen=YES`,
`deleteSendsBackspace=NO`. iTerm2 defaults: both Option keys Normal, "Apps can change how keys are
reported" on, "Report keys using CSI u" off (*source*, `iTermProfilePreferences.m` L644–657).

| Key | Terminal.app | iTerm2 |
|---|---|---|
| Option+letter / digit / punctuation | composed UTF-8 (US: Option+a `å`, Option+f `ƒ`, Option+1 `¡`, Option+[ `“`, Option+Space U+00A0); German: Option+5…9 type `[ ] \| { }`, Option+l `@`; dead keys send nothing until the next key (*measured, layout*) | same (*source*, `iTermStandardKeyMapper.m` L162–242) |
| …with "Option as Meta" / "Esc+" turned on | `\e` + the plain key; Option+↑/↓ `\e\e[A` / `\e\e[B` | `\e` + the plain key |
| Ctrl+a…z, Ctrl+h/i/m | `\x01`…`\x1a`, `\x08` `\t` `\r` | same |
| Ctrl+Shift+letter | not encoded: handed to Cocoa, most likely nothing (beep) (*inferred*) | `\x01`…`\x1a` (Shift ignored) |
| Ctrl+[ ] \ - / | `\e` `\x1d` `\x1c` `\x1f`; Ctrl+/ likely `/` (*inferred*) | `\e` `\x1d` `\x1c` `\x1f` `\x1f` |
| Ctrl+Space, Ctrl+@ | `\x00` (but macOS takes Ctrl+Space) | `\x00` (same) |
| Ctrl+0…9 | the plain digit, as far as the event shows (*measured, event*; final bytes *inferred*) | Ctrl+2 `\x00`, Ctrl+3 `\e`, Ctrl+4…7 `\x1c`…`\x1f`, Ctrl+8 `\x7f`; Ctrl+1, 9, 0 the digit |
| Ctrl+; ' , . = ` | likely the plain character (*inferred*) | the plain character |
| Enter, Shift/Ctrl/Option+Enter | `\r` | `\r` |
| Backspace, Shift/Ctrl/Option+Backspace | all `\x7f` (modifiers ignored) | `\x7f`; Ctrl+Backspace `\x08`; Ctrl+Option+Backspace `\e[3;7~` |
| Tab / Shift+Tab / Ctrl+Tab | `\t` / `\e[Z` / `\t` | `\t` / `\e[Z` / taken |
| Arrows | `\e[A`… | `\e[A`…, modified `\e[1;mA` |
| Shift+←/→ | `\e[1;2D` / `\e[1;2C` | `\e[1;2D` / `\e[1;2C` |
| **Shift+↑/↓, Option+↑/↓** | **`\e[A` / `\e[B` (modifier dropped)** | `\e[1;2A`, `\e[1;3A` |
| Option+←/→ | `\eb` / `\ef` | `\e[1;3D` / `\e[1;3C` |
| Ctrl+arrows | `\e[1;5D`… in the table, but macOS takes them first | `\e[1;5A`… (macOS takes them first) |
| **Home/End/PgUp/PgDn in the alternate screen (am)** | plain, Ctrl or Option: `\eOH`/`\e[H`, `\eOF`/`\e[F`, `\e[5~`, `\e[6~`, **modifier dropped**; **with Shift: Terminal scrolls, nothing sent** (reversed in the normal screen) | `\e[H` `\e[F` `\e[5~` `\e[6~`, modified `\e[1;mH`, `\e[5;m~`; **Shift+PgUp/PgDn: iTerm2 scrolls, nothing sent** |
| Forward Delete (Fn+Delete) | `\e[3~`, Shift `\e[3;2~`, Ctrl `\e[3;5~` | `\e[3~`, `\e[3;m~` |
| Insert | none on Mac keyboards; the Help key sends nothing (*inferred*) | Help key sends U+F746 `\xef\x9d\x86` (*inferred* from source) |
| F1–F12 (with Fn) | `\eOP`…`\eOS`, `\e[15~`…`\e[24~` | same |
| Shift+F1–F4 | nothing (*inferred*) | `\e[1;2P`… |
| Shift+F5–F12 | `\e[25~`…`\e[34~` = the same bytes as F13–F20 | `\e[15;2~`… |
| Option+F1–F12 | `\e[17~`…`\e[31~` = the same bytes as F6–F17 | `\e[1;3P`… |
| F13–F20 | `\e[25~` `\e[26~` `\e[28~` `\e[29~` `\e[31~`… | **the same bytes as Shift+F1–F8** |
| Cmd+. | `\x03` (`sendInterrupt:`) | menu |

Keys these terminals keep: every Cmd combination goes to the menus (Terminal.app beeps on an
unbound one, iTerm2 drops it), except Terminal.app's Cmd+. (`\x03`) and Cmd+Return (`\r`).
Terminal.app scrolls on the Home/End/PgUp/PgDn rule above. iTerm2's global key map keeps
Shift+PgUp/PgDn, Ctrl+Tab and Ctrl+Shift+Tab, and Cmd+arrows/Home/End/PgUp/PgDn.

### Ghostty, kitty, WezTerm, Alacritty (macOS and Linux)

Versions: Ghostty 1.3.1 (installed; 1.4.0 is the latest stable, 2026-10-27, diffed against 1.3.1),
kitty 0.50.0 (2026-11-03), WezTerm 20240203-110809-5046fc22 (still its latest tag; `main` at
`458a100c`, 2026-11-08, has the same legacy encoder and default keys), Alacritty 0.17.0
(2026-04-06). All *source* unless tagged; Ghostty's defaults are also *measured* (above). Nothing
was run on Linux.

Sources: Ghostty [key_encode.zig](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/input/key_encode.zig)
(`legacy()` L318–540, C0 table [L761–L812](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/input/key_encode.zig#L761-L812),
tests L1880–2367), [function_keys.zig](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/input/function_keys.zig#L132-L239),
[Config.zig default binds](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/config/Config.zig#L6392-L7147),
[keyboard.zig (Option default by layout)](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/input/keyboard.zig#L45-L57);
kitty [key_encoding.c](https://github.com/kovidgoyal/kitty/blob/v0.50.0/kitty/key_encoding.c#L139-L351),
[kitty_tests/keys.py](https://github.com/kovidgoyal/kitty/blob/v0.50.0/kitty_tests/keys.py#L90-L475);
WezTerm [termwiz input.rs](https://github.com/wezterm/wezterm/blob/20240203-110809-5046fc22/termwiz/src/input.rs#L255-L632),
[wezterm-input-types lib.rs](https://github.com/wezterm/wezterm/blob/20240203-110809-5046fc22/wezterm-input-types/src/lib.rs#L2151-L2188),
[default-keys.md](https://github.com/wezterm/wezterm/blob/20240203-110809-5046fc22/docs/config/default-keys.md),
[macOS Option handling](https://github.com/wezterm/wezterm/blob/20240203-110809-5046fc22/window/src/os/macos/window.rs#L2598-L2626);
Alacritty [keyboard.rs](https://github.com/alacritty/alacritty/blob/v0.17.0/alacritty/src/input/keyboard.rs#L77-L172),
[bindings.rs](https://github.com/alacritty/alacritty/blob/v0.17.0/alacritty/src/config/bindings.rs#L430-L621),
[window.rs (option_as_alt)](https://github.com/alacritty/alacritty/blob/v0.17.0/alacritty/src/config/window.rs#L280-L294).
Alacritty sends whatever text winit hands it for ordinary keys; on Linux that comes from xkb's Ctrl
transform, so Alacritty's Ctrl+punctuation cells are *inferred*.

"eaten" = the terminal keeps the key (next section). `m` = xterm modifier parameter.

| Key | Ghostty | kitty | WezTerm | Alacritty |
|---|---|---|---|---|
| Option on macOS (default) | Alt on U.S. / U.S. International layouts, composes on every other layout | composes (`macos_option_as_alt no`) | left Option = Alt, right Option composes | composes (`option_as_alt None`) |
| Alt+f | `\ef` (macOS non-US: `ƒ`) | macOS `ƒ` / Linux `\ef` | macOS left `\ef`, right `ƒ` / Linux `\ef` | macOS `ƒ` / Linux `\ef` |
| Alt+Shift+a, Alt+1, Alt+`[ ] , . / -` | `\eA`, `\e1`, `\e[` … where Option is Alt; else the composed character | same | same | same |
| Ctrl+1 / Ctrl+9 / Ctrl+0 | `1` / `9` / `0` (Linux: Ctrl+0 eaten) | `1` `9` `0` | `1` `9`, Ctrl+0 eaten | Linux `1` `9`, Ctrl+0 eaten (*inferred*) |
| Ctrl+2 … Ctrl+8 | `\x00 \e \x1c \x1d \x1e \x1f \x7f` | same | same | same on Linux (*inferred*) |
| Ctrl+/ | `\x1f` | `\x1f` | `\x1f` | `\x1f` (*inferred*) |
| Ctrl+; / Ctrl+' / Ctrl+. | `\e[59;5u` / `\e[39;5u` / `\e[46;5u` | `;` `'` `.` | `;` `'` `.` | `;` `'` `.` (*inferred*) |
| Ctrl+, | macOS `\e[44;5u` / Linux eaten | `,` | `,` | `,` (*inferred*) |
| Ctrl+- / Ctrl+= | macOS `\e[45;5u` / `\e[61;5u`; Linux eaten | `-` / `=` | eaten | Linux eaten; macOS `-` `=` (*inferred*) |
| Ctrl+[ / Ctrl+] / Ctrl+\ | **`\e[91;5u`** / `\x1d` / `\x1c` | `\e` `\x1d` `\x1c` | same as kitty | same as kitty |
| Ctrl+Shift+a | `\e[97;6u` (Linux: Ctrl+Shift+a c e f i j n o p q t v w eaten) | `\e[97;6u` (only d i m y reach the app) | `\x01` (= Ctrl+a); many eaten | `\x01` (*inferred*); Linux: c v f b eaten |
| Ctrl+h / Ctrl+i / Ctrl+m | `\x08` / **`\e[105;5u`** / **`\e[109;5u`** | `\x08` `\t` `\r` | `\x08` `\t` `\r` | `\x08` `\t` `\r` |
| Ctrl+Space / Ctrl+@ | `\x00` / `\e[64;5u` | `\x00` / eaten | `\x00` / eaten | `\x00` / `\x00` (*inferred*) |
| Backspace, Shift+, Alt+, Ctrl+, Ctrl+Alt+Backspace | `\x7f` `\x7f` `\e\x7f` `\x08` `\e\x08` | same | same | same |
| Shift+Enter | **`\e[27;2;13~`** | `\r` | `\r` | `\r` |
| Ctrl+Enter | macOS `\e[27;5;13~` / Linux eaten | `\r` | `\r` | `\r` |
| Alt+Enter | `\e\r` | `\e\r` | eaten | Linux `\e\r` / macOS `\r` |
| Shift+Space | ` ` | ` ` | ` ` | ` ` |
| Tab / Shift+Tab / Ctrl+Tab | `\t` / `\e[Z` / eaten | same | same | `\t` / `\e[Z` / `\t` |
| Esc / Alt+Esc / Shift+Esc / Ctrl+Esc | `\e` `\e\e` `\e[27;2;27~` `\e[27;5;27~` | `\e` `\e\e` `\e` `\e` | as kitty | as kitty |
| Home End Ins Del PgUp PgDn | `\e[H` `\e[F` `\e[2~` `\e[3~` `\e[5~` `\e[6~`, modified `\e[1;mH`, `\e[n;m~` | same | same | same |
| F1–F4 / F5–F12 | `\eOP`…`\eOS` / `\e[15~` … `\e[24~` | same | same | same |
| Modified F3 | `\e[13;m~` | `\e[13;m~` | `\e[1;mR` | `\e[1;mR` |
| Shift/Alt/Ctrl/Ctrl+Shift + arrows | `\e[1;mA`; **macOS Option+←/→ send `\eb` / `\ef`** (a default bind) | `\e[1;mA` | `\e[1;mA` | `\e[1;mA` |
| Super+Up (Linux) | `\e[1;9A` | `\e[1;9A` | `\e[A` (Super dropped) | `\e[1;9A` |
| Super+a (Linux) | `a` | `\e[97;9u` | `a` | `a` (*inferred*) |
| Unbound Cmd+b (macOS) | nothing | `\e[98;9u` (*inferred*) | `b` (*inferred*) | not determined |
| Keypad Enter | `\r` | `\r` | `\r` | **`\n`** |

kitty also sends keys with no legacy encoding (F13–F35, media keys) as `CSI u` in legacy mode
([spec](https://github.com/kovidgoyal/kitty/blob/v0.50.0/docs/keyboard-protocol.rst?plain=1#L544-L548)).

### GNOME Terminal (VTE), Konsole, xterm, foot (Linux)

Versions (latest releases as of 2026-11-09): VTE 0.84.1 with GNOME Terminal 3.60.0, Konsole
26.08.3, xterm patch 412 (Debian ships 412-1), foot 1.28.0; desktops GNOME 51 and KDE Plasma 6.8.2.
All *source* unless tagged (none of them runs on this Mac); their terminfo entries (above) are
*measured* and agree.

Sources: VTE [`src/` at 0.84.1](https://gitlab.gnome.org/GNOME/vte/-/blob/0.84.1/src/) (`keymap.cc`,
`vte.cc#L5049-L5275`, `modes.py`), GNOME Terminal [gschema at 3.60.0](https://gitlab.gnome.org/GNOME/gnome-terminal/-/blob/3.60.0/src/org.gnome.Terminal.gschema.xml)
(`#L330` backspace, `#L362-L630` shortcuts, `#L657` F10), Konsole
[`default.keytab` at v26.08.3](https://invent.kde.org/utilities/konsole/-/blob/v26.08.3/data/keyboard-layouts/default.keytab)
and [`src/Vt102Emulation.cpp`](https://invent.kde.org/utilities/konsole/-/blob/v26.08.3/src/Vt102Emulation.cpp),
xterm [xterm-412.tgz](https://invisible-island.net/archives/xterm/xterm-412.tgz) (`input.c`,
`charproc.c`, `main.h`, `ctlseqs.txt`) with Debian's
[`debian/rules#L51-L52`](https://salsa.debian.org/xorg-team/app/xterm/-/blob/debian-unstable/debian/rules#L51-L52),
foot [`input.c`, `keymap.h`, `foot.ini` at 1.28.0](https://codeberg.org/dnkl/foot/src/tag/1.28.0/).
The Ctrl table that xterm, Konsole (through Qt) and foot share is libX11 `KeyBind.c#L896-L902` /
libxkbcommon `state.c#L2327-L2343`.

**The same in all four** (legacy, normal cursor mode): Ctrl+a…z = `\x01`…`\x1a`, and Ctrl+Shift+letter
sends the same byte; Ctrl+h/i/m/[ = `\x08`/`\t`/`\r`/`\e`; Ctrl+Space, Ctrl+@, Ctrl+2 = `\x00`;
Ctrl+3…7 = `\e \x1c \x1d \x1e \x1f`, Ctrl+8 = `\x7f`; Ctrl+\ / ] / / = `\x1c` / `\x1d` / `\x1f`;
Esc / Tab / Shift+Tab = `\e` / `\t` / `\e[Z`; arrows `\e[A`… and `\e[1;mA` with Shift (2), Alt
(3), Ctrl (5), Ctrl+Shift (6); Home/End `\e[H` / `\e[F` (`\e[1;mH`); Insert/Delete/PgUp/PgDn
`\e[2~ 3~ 5~ 6~` (`\e[n;m~`); F1–F4 `\eOP`…`\eOS`; F5–F12 `\e[15~`…`\e[24~` (`\e[15;m~`); Shift+Space
= space.

| Key | xterm (upstream) | xterm (Debian) | GNOME Terminal | Konsole | foot |
|---|---|---|---|---|---|
| Backspace | **`\x08`** | `\x7f` | `\x7f` | `\x7f` | `\x7f` |
| Ctrl+Backspace | `\x7f` | `\x08` | `\x08` | `\x08` | `\x08` |
| Alt+Backspace | **`\xc2\x88`** (U+0088) | **`\xc3\xbf`** (ÿ) | `\e\x7f` | `\e\x7f` | `\e\x7f` |
| Alt+a / Alt+Shift+a | **`á`** / `Á` (UTF-8 of the 8th-bit byte) | same | `\ea` / `\eA` | same | same |
| Alt+1 | `±` | same | `\e1` (taken with 2+ tabs) | `\e1` (taken with 2+ tabs) | `\e1` |
| Alt+[ ] , . / - | `Û Ý ¬ ® ¯ ­` | same | `\e[` `\e]` `\e,` `\e.` `\e/` `\e-` | same | same |
| Ctrl+Alt+a / Alt+Esc | U+0081 / U+009B | same | `\e\x01` / `\e\e` (GNOME desktop takes Alt+Esc) | `\e\x01` / `\e\e` | `\e\x01` / `\e\e` |
| Shift+Enter | `\r` | `\r` | `\r` | **`\eOM`** | **`\e[27;2;13~`** |
| Ctrl+Enter | `\r` | `\r` | `\r` | `\r` | `\e[27;5;13~` |
| Alt+Enter | taken (fullscreen) | taken | `\e\r` | `\e\r` | `\e\r` |
| Ctrl+Tab / Ctrl+Shift+Tab | `\t` / `\e[Z` (*inferred*) | same | `\t` / `\e[Z` | taken | `\e[27;5;9~` / `\e[27;6;9~` |
| Ctrl+1, Ctrl+9 | `1`, `9` | same | `1`, `9` | `1`, `9` | `\e[27;5;49~`, `\e[27;5;57~` |
| Ctrl+0 | `0` | same | taken (zoom) | `0` | taken (font) |
| Ctrl+; ' , . | the plain character | same | the plain character | the plain character | `\e[27;5;59~` / `39` / `44` / `46` |
| Ctrl+= / Ctrl+- | `=` / `-` | same | `=` (*inferred*) / taken | taken | taken |
| Shift+F1 / Ctrl+F1 | `\e[1;2P` / `\e[1;5P` | same | same | **`\eO2P` / `\eO5P`** | `\e[1;2P` / `\e[1;5P` |
| Super+Up | `\e[A` (*inferred*) | same | `\e[A` | `\e[1;1A` | `\e[1;9A` |
| Super+a | `a` (*inferred*) | same | `a` | **`\x18@sa`** | `a` |

Notes, all *source*:
- xterm upstream's Backspace is BS because `backarrowKey` defaults true; Debian builds with
  `--enable-backarrow-is-erase --enable-pty-erase` and gets DEL. xterm's Alt goes through
  `insert-eight-bit` with `eightBitInput` true and `metaSendsEscape` false, so the key's byte gets
  the 8th bit and is sent UTF-8 encoded. An app can switch that to an ESC prefix with
  `\e[?1036h` (metaSendsEscape); VTE and foot already default to it and Konsole ESC-prefixes
  regardless.
- Konsole's keytab writes modified F1–F4 as `\EO*P` (L180–L183): Shift+F1 `\eO2P`, Alt+F1 `\eO3P`,
  Ctrl+F1 `\eO5P`. Same on Konsole's master on 2026-11-09. With the kitty protocol on, Konsole
  sends `\e[1;mP` instead. Konsole adds `\x18@s` (Emacs' Ctrl+x @ s) for Super.
- foot sends `CSI 27;m;c~` for Ctrl plus any key that has no control byte (Ctrl+digit,
  Ctrl+punctuation, Ctrl/Shift+Enter, Ctrl+Tab) without being asked: its baseline is xterm's
  modifyOtherKeys level 1. Super is xterm's Meta in foot (`m` 9–16), which am reads as Alt.

### Windows Terminal and the classic console (conhost)

Windows Terminal 1.25.2733.0 (stable, 2026-10-02; 1.26 is in preview). *Source*, read at tag
[`v1.25.2733.0`](https://github.com/microsoft/terminal/tree/v1.25.2733.0); nothing runs on Windows
here, and am's Windows build isn't released.

**Who makes the bytes.** am reads the console with `ReadFile` and VT input on. The console host
turns each key event into VT bytes with its `TerminalInput` encoder when the reader has VT input
on ([inputBuffer.cpp#L682-L713](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/host/inputBuffer.cpp#L682-L713)).
In Windows Terminal that host is ConPTY, run from the OpenConsole.exe that ships with Windows
Terminal ([winconpty.cpp#L49-L98](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/winconpty/winconpty.cpp#L49-L98));
Windows Terminal sends it keys as win32-input-mode records. In a classic console window it's the
conhost.exe that ships with Windows, whose encoder version follows the Windows build (*inferred*;
which Windows build carries which encoder wasn't established). The bytes below are the encoder at
v1.25.2733.0 ([terminalInput.cpp](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp)).

| Key | Bytes am reads |
|---|---|
| Alt+letter / Alt+Shift+a / Alt+digit / Alt+punctuation | `\e` + the character (`\ea`, `\eA`, `\e1`, `\e[`) ([#L1323-L1329](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L1308-L1329)) |
| AltGr+key (Ctrl+Alt on European layouts) | the AltGr character, e.g. `@` for AltGr+q on German; Ctrl+Alt+key without one is `\e` + C0 ([#L384-L400](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L384-L400)) |
| Alt+keypad digits | nothing (Alt+numpad character entry) ([#L269-L276](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L262-L268)) |
| Ctrl+a…z, Ctrl+Shift+letter | `\x01`…`\x1a` (Shift lost, *inferred* from Windows' character for the key) |
| Ctrl+2…8 / Ctrl+1, 9, 0 | `\x00 \e \x1c \x1d \x1e \x1f \x7f` / the digit ([`_makeCtrlChar` #L499-L527](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L499-L527)) |
| Ctrl+/ / Ctrl+? / Ctrl+Space / Ctrl+[ ] \ | `\x1f` / `\x7f` / `\x00` / `\e` `\x1d` `\x1c` |
| Ctrl+; ' , . = - | the plain character unless the layout gives Windows a control character for it (*inferred*) |
| Enter / Shift+Enter / Ctrl+Enter / Alt+Enter | `\r` / `\r` / **`\n`** / `\e\r` ([#L940-L966](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L940-L966)) |
| Backspace / Ctrl+Backspace / Alt+Backspace | `\x7f` / `\x08` / `\e\x7f` ([#L912-L922](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L912-L922)) |
| Tab / Shift+Tab / Ctrl+Tab | `\t` / `\e[Z` / `\t` |
| Pause | `\x1a`, the same byte as Ctrl+z |
| Arrows, Home, End | `\e[A`, `\e[H`, `\e[F`; modified `\e[1;mA` |
| Insert, Delete, PgUp, PgDn | `\e[2~ 3~ 5~ 6~`; modified `\e[n;m~` |
| F1–F4 / F5–F20 | `\eOP`…, modified `\e[1;mP`; `\e[15~`…`\e[34~` (F13 = `\e[25~`) |
| Ctrl+C | `\x03` (am clears processed input, so no Ctrl+C event) ([input.cpp#L107-L131](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/host/input.cpp#L107-L131)) |

**Taken by Windows Terminal** ([defaults.json#L723-L802](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/cascadia/TerminalSettingsModel/defaults.json#L723-L802),
plus the first-run `settings.json` from
[userDefaults.json#L26-L28](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/cascadia/TerminalSettingsModel/userDefaults.json#L26-L28)):
Alt+Enter and F11 (fullscreen), Alt+F4, Alt+Space, Win+`, Ctrl+, (settings), Ctrl+Shift+, and
Ctrl+Alt+,, Ctrl+Shift+F/P/T/N/D/W/A/M/K/C/V/Space/., Ctrl+Shift+1…9, Ctrl+Alt+1…9, Ctrl+Tab and
Ctrl+Shift+Tab, Alt+Shift+-/+/D/arrows (panes), Ctrl+Alt+←, Ctrl+Shift+↑/↓/PgUp/PgDn/Home/End
(scrolling), Ctrl+= / Ctrl+- / Ctrl+0 (font size), Ctrl+Insert, Shift+Insert, the Menu key, and
**Ctrl+V** (paste). An action that can't run passes the key on: Alt+arrows (move focus) reach am
with one pane, and Ctrl+C and Enter (copy) reach am when nothing is selected
([AppActionHandlers.cpp#L508-L557](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/cascadia/TerminalApp/AppActionHandlers.cpp#L508-L557)).

**Taken by the classic console** with am's input mode
([windowio.cpp#L264-L273, #L450-L467](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/interactivity/win32/windowio.cpp#L450-L467),
[input.cpp#L100-L159](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/host/input.cpp#L100-L159)):
Alt+Enter (fullscreen) always; Ctrl+Esc and Alt+Esc are dropped; Ctrl+Break is a console event
(am restores the terminal and the process ends). F11, Shift+Insert, Ctrl+C and Alt+F4 are only
taken with processed input, which am turns off, so they reach am; Alt+Space reaches am too in VT
input mode. Windows itself keeps Win+…, Alt+Tab, Ctrl+Alt+Del, Ctrl+Shift+Esc and, with several
layouts or a CJK input method, its layout and IME switch keys (*not checked here*).

**Protocols on Windows.**
- Windows Terminal 1.25 has the kitty protocol: PR
  [#19817](https://github.com/microsoft/terminal/pull/19817), merged 2026-02-17, first in the 1.25
  previews ([release notes](https://github.com/microsoft/terminal/releases/tag/v1.25.1241.0)), on by
  default (`compatibility.kittyKeyboardMode`,
  [MTSMSettings.h#L107](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/cascadia/TerminalSettingsModel/MTSMSettings.h#L107)).
  It has no modifyOtherKeys (no code for it).
- Behind ConPTY the console host ignores `\e[>1u` and `\e[?u` itself
  ([adaptDispatch.cpp#L2078-L2120](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/adapter/adaptDispatch.cpp#L2078-L2120))
  and doesn't turn win32-input-mode records into kitty codes
  ([VtIo.cpp#L125-L131](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/host/VtIo.cpp#L125-L131)).
  Windows Terminal handles them: once flags are set it sends kitty codes instead of win32-input-mode
  ([terminalInput.cpp#L229-L235](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/input/terminalInput.cpp#L229-L235)),
  and ConPTY passes sequences it doesn't translate straight to a reader with VT input on
  ([InputStateMachineEngine.cpp#L387-L398](https://github.com/microsoft/terminal/blob/v1.25.2733.0/src/terminal/parser/InputStateMachineEngine.cpp#L387-L398)).
  So am's push should reach Windows Terminal and the `CSI u` keys and the `\e[?flags u` reply should
  come back (*inferred*; the whole chain wasn't run).
- The classic console window: whether the conhost.exe in a given Windows build has the kitty code
  wasn't established.
- win32-input-mode (`\e[?9001h`) is Windows Terminal's raw-key encoding between it and ConPTY. An app
  could ask the console host for it; am doesn't, and its decoder skips such records (probe).

### tmux in between

tmux 3.8 (the latest tag). *Source*, read at tag
[`3.8`](https://github.com/tmux/tmux/tree/3.8); tmux isn't installed here.

tmux reads the outer terminal's keys into its own key codes, then writes each key to the pane
again in its own encoding. So inside tmux, am sees tmux's encoding, not the outer terminal's.

- **The pane encoding is legacy unless the app asks and the user allows it.** With
  `extended-keys` at its default `off`
  ([options-table.c#L416-L423](https://github.com/tmux/tmux/blob/3.8/options-table.c#L416-L423)),
  tmux ignores an app's `\e[>4;1m` / `\e[>4;2m`
  ([input.c#L1527-L1544](https://github.com/tmux/tmux/blob/3.8/input.c#L1527-L1544)) and writes keys
  with `input_key_vt10x`
  ([input-keys.c#L481-L542](https://github.com/tmux/tmux/blob/3.8/input-keys.c#L481-L542)):
  - Alt = ESC prefix. Ctrl+letter = C0. Ctrl+Space and Ctrl+2 = `\x00`, Ctrl+3…7 =
    `\e \x1c \x1d \x1e \x1f`, Ctrl+8 and Ctrl+? = `\x7f`, Ctrl+/ and Ctrl+- = `\x1f`; Ctrl+1, 9, 0,
    = + ; : ' " , < . > = the plain (unshifted) character. Shift on Enter is dropped (`\r`).
  - Home `\e[1~`, End `\e[4~`, Insert/Delete/PgUp/PgDn `\e[2~ 3~ 5~ 6~`, F1–F4 `\eOP`…, F5–F12
    `\e[15~`… ([#L66-L126](https://github.com/tmux/tmux/blob/3.8/input-keys.c#L66-L126)); modified
    arrows, Home/End and F-keys keep the xterm `\e[1;mX` / `\e[n;m~` forms. Backspace is `\x7f`
    (option `backspace`).
  - So **tmux evens terminals out**: Ghostty's `\e[105;5u` for Ctrl+i reaches the pane as `\t`,
    foot's `\e[27;5;49~` for Ctrl+1 as `1`, kitty's `\e[97;6u` for Ctrl+Shift+a as `\x01`
    (*inferred* from the code above). tmux parses both extended forms from the outer terminal
    whatever the option says
    ([tty-keys.c#L1088-L1140](https://github.com/tmux/tmux/blob/3.8/tty-keys.c#L1088-L1140)), and
    asks the outer terminal for modifyOtherKeys 2 only when `extended-keys` is on
    ([tty.c#L561](https://github.com/tmux/tmux/blob/3.8/tty.c#L561)).
- **No kitty protocol for apps.** tmux's CSI table maps `u` only to "restore cursor"; `\e[>1u` and
  `\e[?u` do nothing and get no reply
  ([input.c#L330-L347](https://github.com/tmux/tmux/blob/3.8/input.c#L330-L347)). CHANGES has no
  entry for it up to 3.8.
- **With `extended-keys on`**, an app's `\e[>4;2m` gets every modified key as `\e[27;m;c~` (the
  default `extended-keys-format` is `xterm`; `csi-u` gives `\e[c;mu`), and `\e[>4;1m` keeps
  Ctrl+letter as C0. `always` forces mode 1 for every pane.
- **`escape-time`** is 10 ms by default since 3.5 (500 ms before, so in 3.4 and older)
  ([options-table.c#L391-L397](https://github.com/tmux/tmux/blob/3.8/options-table.c#L391-L397),
  [CHANGES#L917](https://github.com/tmux/tmux/blob/3.8/CHANGES#L917)). It is how long tmux waits
  after an ESC from the outer terminal before deciding it was the Esc key. Esc then reaches am
  that much later, and on top of am's own 30 ms wait.
- **Taken:** the prefix, Ctrl+b, and whatever key follows it.

## Keys that never reach am

At default settings. Per-terminal detail and links are in the sections above; this is the union,
by where the key is kept.

**macOS** (*measured* from this Mac's shortcut tables, `DefaultShortcutsTable.xml` and
`DefaultSpacesShortcuts.xml` in `KeyboardSettings.appex`, with the live on/off state from
`CGSIsSymbolicHotKeyEnabled`; the owner's only change is the Zoom/Contrast group, off by default):

- On by default: Ctrl+←/→ (switch Space) and with Shift, Ctrl+↑ (Mission Control), Ctrl+↓ (App
  windows) and with Shift; Ctrl+Space and Ctrl+Option+Space (input sources; this Mac has two
  layouts enabled, a single-layout Mac is untested); Ctrl+F1–F8 (keyboard focus); F11 and Shift+F11
  (Show Desktop); Fn/Globe+Ctrl+arrows (tiling, macOS 15+); Fn+Q; Ctrl+Return ("Show contextual
  menu", whether it swallows Ctrl+Enter in a terminal is untested); many Cmd shortcuts.
- Off by default: Ctrl+1…0 (Switch to Desktop N), Ctrl+Shift+Space.
- F1–F12 act as media keys unless Fn is held (`com.apple.keyboard.fnState` unset). Mac keyboards
  have no Insert key, and Home/End/PgUp/PgDn are Fn+arrows on laptops.
- **Every Cmd combination** goes to the terminal's menus or keybinds. The exceptions that send
  bytes are rewrites: Terminal.app's Cmd+. (`\x03`, so am quits), Ghostty's Cmd+←/→/Backspace
  (`\x01` / `\x05` / `\x15`, so am sees Ctrl+a, Ctrl+e, Ctrl+u), and kitty, which may send an
  unbound Cmd+key as `CSI u` with the Super bit (*inferred*).

**macOS terminals:** Terminal.app scrolls on Shift+Home/End/PgUp/PgDn in the alternate screen;
iTerm2 keeps Shift+PgUp/PgDn, Ctrl+Tab and Ctrl+Shift+Tab; Ghostty keeps Ctrl+Tab and Ctrl+Shift+Tab
always, and Shift+arrows/Home/End/PgUp/PgDn only while text is selected; kitty keeps most
Ctrl+Shift combinations (its `kitty_mod`) and Ctrl+Tab; WezTerm keeps most Ctrl+Shift+letters,
Ctrl+- / Ctrl+= / Ctrl+0, Ctrl+Tab, Shift+PgUp/PgDn and Alt+Enter; Alacritty keeps Ctrl+Shift+Space.

**Linux terminals:** Ctrl+Shift+C/V and friends in GNOME Terminal, Konsole, Ghostty, kitty, WezTerm,
foot, Alacritty (GNOME Terminal swallows Ctrl+Shift+C even with nothing selected); F11 in GNOME
Terminal and Konsole; F10 and Shift+F10 in GNOME Terminal; Ctrl+Tab in Konsole, Ghostty, kitty,
WezTerm; Ctrl+= / Ctrl+- / Ctrl+0 (zoom) in most; Alt+Enter in xterm and WezTerm; Shift+PgUp/PgDn
in xterm (on the alternate screen too); Shift+Insert everywhere. **Depends on the tab count:** in
GNOME Terminal and Konsole, Alt+1…0 and Ctrl+PgUp/PgDn (Konsole also Shift+←/→ and Ctrl+Alt+←/→)
reach am with one tab and are taken with two or more.

**Linux desktops:** GNOME 51 keeps Alt+Tab, Alt+` , **Alt+Esc**, Alt+Space, Alt+F2/F4/F5/F6/F7/F8/
F10, Ctrl+Alt+arrows, Super+Space (input source) and most Super combinations; KDE Plasma 6.8 keeps
Alt+Tab, Alt+`, Alt+Space, Alt+F2/F3/F4, **Ctrl+F1–F4** (desktops) and Meta combinations. fcitx5,
when running, keeps Ctrl+Space; GTK and IBus keep Ctrl+Shift+U.

**Windows and tmux:** see their sections.

## Across terminals: what a recorded key means elsewhere

What am records for each key the ticket lists, by terminal, at default settings, without a
keyboard protocol. Assembled from the per-terminal tables (each cell's tag is there) and the probe
(*measured* decoding). "elsewhere" means every other listed terminal.

Inside tmux at its defaults, whatever the outer terminal, keys arrive in tmux's own legacy
encoding (tmux section), so the legacy answer applies: Ghostty's Ctrl+i is Tab again, foot's
Ctrl+1 is `1`, kitty's Ctrl+Shift+a is Ctrl+a. Only the tmux prefix is added to what's taken.

| Key pressed | am records | Where |
|---|---|---|
| Option/Alt+f | `alt+f` | GNOME Terminal, Konsole, foot, Linux Ghostty/kitty/WezTerm/Alacritty, Ghostty on a U.S. or U.S. International Mac layout, WezTerm's left Option, Windows Terminal, conhost |
| | `ƒ` (a character) | Terminal.app, iTerm2, kitty and Alacritty on macOS, Ghostty on any other Mac layout, WezTerm's right Option |
| | `æ` (Latin-1) | xterm |
| Alt+[ / Alt+Shift+o | `alt+[` / `alt+O`, or the start of a sequence when the next key follows within 30 ms | where Alt is an ESC prefix (above) |
| | `“` / `Ø` | where Option composes (macOS, US layout) |
| Ctrl+1, Ctrl+9, Ctrl+0 | `1`, `9`, `0` (so Ctrl+1 opens Home) | Terminal.app, iTerm2, Ghostty, kitty, WezTerm, Alacritty, GNOME Terminal, Konsole, xterm, Windows Terminal, conhost |
| | `ctrl+1` … | foot |
| | taken | Ctrl+0 in GNOME Terminal, foot, WezTerm, Linux Ghostty and Alacritty (zoom) |
| Ctrl+2 / Ctrl+3 / Ctrl+8 | `ctrl+space` / Esc / Backspace | iTerm2, Ghostty, kitty, WezTerm, Alacritty, the Linux four, Windows Terminal, conhost |
| | `2` / `3` / `8` | Terminal.app (*inferred* from the event's characters) |
| Ctrl+/ | `ctrl+_` | elsewhere |
| | `/` | Terminal.app (*inferred*) |
| Ctrl+; ' , . | the plain character | Terminal.app (*inferred*), iTerm2, kitty, WezTerm, Alacritty, GNOME Terminal, Konsole, xterm |
| | `ctrl+;` … | Ghostty (`\e[59;5u`; Ctrl+, taken on Linux), foot (`\e[27;5;59~`) |
| Ctrl+= / Ctrl+- | `=` / `-` (volume up / down today) | kitty, xterm, iTerm2 (Ctrl+= only; Ctrl+- is `ctrl+_`), macOS Alacritty |
| | `ctrl+=` / `ctrl+-` | Ghostty on macOS |
| | taken (zoom) | GNOME Terminal (Ctrl+-), Konsole, foot, WezTerm, Ghostty and Alacritty on Linux |
| Ctrl+Shift+a | `ctrl+a` | iTerm2, WezTerm, Alacritty, GNOME Terminal, Konsole, xterm, foot |
| | `ctrl+shift+a` | Ghostty, kitty (both send `\e[97;6u` without a protocol) |
| | nothing (*inferred*) | Terminal.app |
| | taken, for many letters | GNOME Terminal (T N W Q C V F G H J), Konsole (T N W Q M C V F K D P R A I B), kitty (most), WezTerm (most), Ghostty on Linux, foot (C V R N O Z X U) |
| Shift+Enter | Enter | Terminal.app, iTerm2, kitty, WezTerm, Alacritty, GNOME Terminal, xterm, Konsole (`\eOM`) |
| | `shift+enter` | Ghostty, foot |
| Ctrl+Enter | Enter | Terminal.app, iTerm2, kitty, WezTerm, Alacritty, GNOME Terminal, Konsole, xterm, Windows Terminal and conhost (`\n`) |
| | `ctrl+enter` | Ghostty on macOS, foot |
| | taken | Ghostty on Linux |
| Shift+Space | Space | everywhere |
| Shift+Backspace, Ctrl+Backspace | Backspace | everywhere (0x7f or 0x08) |
| Alt+Backspace | `alt+backspace` | where Alt is an ESC prefix |
| | Backspace | Terminal.app, iTerm2 (Option = Normal) |
| | U+0088 / `ÿ` | xterm upstream / Debian |
| Ctrl+h, Ctrl+i, Ctrl+m, Ctrl+[ | Backspace, Tab, Enter, Esc | elsewhere |
| | Backspace, `ctrl+i`, `ctrl+m`, `ctrl+[` | Ghostty |
| Ctrl+Space | `ctrl+space` | Linux terminals without an input method that takes it, Windows Terminal, conhost (unless a CJK input method takes it) |
| | taken | macOS (input sources), fcitx5 |
| Home, End, PgUp, PgDn, Delete | the key | everywhere (Fn+arrows / Fn+Backspace on a Mac laptop) |
| Insert | `insert` | PC keyboards; Mac keyboards have none |
| Shift+PgUp | `shift+page_up` | Ghostty (no selection), kitty, Alacritty, GNOME Terminal, Konsole, foot |
| | taken (scrollback) | Terminal.app, iTerm2, xterm, WezTerm |
| Ctrl/Option+Home, End, PgUp, PgDn | the plain key | Terminal.app (modifier dropped) |
| | `ctrl+home` … | elsewhere |
| F1–F10, F12 | `F1`… | everywhere (Fn on a Mac); F10 taken by GNOME Terminal |
| F11 | taken | macOS (Show Desktop), GNOME Terminal, Konsole, Windows Terminal |
| | `F11` | xterm, foot, Linux Ghostty/kitty/WezTerm/Alacritty, conhost |
| Alt+Enter | `alt+enter` | GNOME Terminal, Konsole, foot, Ghostty, kitty, Linux Alacritty |
| | taken (fullscreen) | Windows Terminal, conhost, xterm, WezTerm |
| Ctrl+Tab | `tab` | Terminal.app, GNOME Terminal, xterm, Alacritty |
| | `ctrl+tab` | foot (`\e[27;5;9~`) |
| | taken | iTerm2, Ghostty, kitty, WezTerm, Konsole, Windows Terminal |
| Shift+F1 | `shift+F1` | iTerm2, Ghostty, kitty, WezTerm, Alacritty, GNOME Terminal, xterm, foot |
| | Alt+O, `2`, `P` | Konsole |
| | nothing (*inferred*) | Terminal.app |
| Shift+F5 | `shift+F5` | elsewhere |
| | `F13` | Terminal.app (`\e[25~`) |
| F13 | `F13` | Terminal.app |
| | `shift+F1` | iTerm2 |
| | a private-use character | kitty |
| Shift+↑ | `shift+up` | elsewhere |
| | ↑ | Terminal.app (Shift dropped) |
| | taken while text is selected | Ghostty on macOS |
| Ctrl+↑ / Ctrl+← | `ctrl+up` / `ctrl+left` | Linux terminals, Windows Terminal, conhost |
| | taken | macOS (Mission Control, Spaces), so every Mac terminal |
| Alt+← | `alt+left` | iTerm2, kitty, WezTerm, Alacritty, Linux terminals, Windows Terminal with one pane, conhost |
| | `alt+b` | Terminal.app, Ghostty on macOS |
| Super+↑ | `alt+up` | Ghostty, kitty, Alacritty, foot on Linux (bit 8 read as Alt) |
| | ↑ | GNOME Terminal, WezTerm, Konsole (Super dropped) |
| Ctrl+c, Ctrl+z | `ctrl+c`, `ctrl+z` | everywhere it isn't taken (raw mode turns ISIG off), Windows Terminal when nothing is selected, conhost |
| Ctrl+v | `ctrl+v` | elsewhere (raw mode turns IEXTEN off) |
| | taken (paste) | Windows Terminal |
| Pause | `ctrl+z` (suspend, which does nothing on Windows) | Windows Terminal, conhost |
| Ctrl+b | `ctrl+b` | outside tmux |
| | taken (prefix) | tmux |

## What the Settings page can see when it records a key

The page receives one decoded key: a code plus Ctrl, Alt and Shift flags. Everything below is
*inferred* from the decoder (read and run) and the tables above.

It **can't see**:

- **Which of the colliding keys was pressed.** A legacy terminal sends one byte for Ctrl+i and
  Tab, so the page records Tab either way; likewise Backspace for Ctrl+h, Ctrl+Backspace and
  Ctrl+8; Enter for Ctrl+m, Ctrl+j and (in most) Shift/Ctrl+Enter; Esc for Ctrl+[ and Ctrl+3;
  `ctrl+space` for Ctrl+2 and Ctrl+@; `ctrl+_` for Ctrl+/ and Ctrl+7; Ctrl+a for Ctrl+Shift+a;
  Space for Shift+Space. The user can see that the row says "Tab" after pressing Ctrl+i; the page
  can't.
- **That a character came from Option.** `ƒ` is a character key like any other. The page can tell
  it isn't ASCII, but not Option+f on a US Mac from a key that types `ö` on a German keyboard.
- **A modifier the terminal dropped or a key it rewrote**: Terminal.app's Shift+↑ (recorded as ↑)
  and Ctrl/Option+Home/End/PgUp/PgDn; Terminal.app's and Ghostty's Option+←/→ (`alt+b` / `alt+f`);
  Ghostty's Cmd+←/→/Backspace (`ctrl+a` / `ctrl+e` / `ctrl+u`); Terminal.app's Shift+F5 (`F13`);
  iTerm2's F13 (`shift+F1`); Super read as Alt.
- **A key that never arrives.** Nothing comes, so the page keeps waiting; it can't tell a taken key
  from no key.
- **What another terminal or OS sends for the key just recorded.** One `settings.json` serves all
  of them, and the page runs in one.

It **could see**, with small decoder changes:

- **The form the key arrived in.** Every key that only some terminals can send arrives in an
  extended form: `CSI u` (Ghostty's Ctrl+i, kitty's Ctrl+Shift+a) or `CSI 27;m;c~` (Ghostty's
  Shift+Enter, foot's Ctrl+1). A legacy form (a plain byte, ESC + key, `CSI 1;mX`, `CSI n;m~`)
  is one most terminals share. The decoder knows the form while parsing (`parseCsi`'s `u` and
  `27~` branches) but doesn't keep it in `Key` today.
- **That the key is in a collision class**: a Tab, Enter, Backspace, Esc, `ctrl+space`, `ctrl+_`,
  `ctrl+\`, `ctrl+]` or `ctrl+^` can be labelled with the keys that send the same byte.
- **That several keys arrived at once.** Konsole's Shift+F1 comes as one read of three keys
  (`\eO2P`); the page would record Alt+O, and `2` and `P` would act as ordinary keys after it.
  Two keys within a few milliseconds is a sign of a sequence am misread.
- **Whether this terminal speaks the kitty protocol**, once am asks (`\e[?u`, below).
- **Whether the key could be Option-composed**: a non-ASCII character recorded on macOS. Only a hint,
  since it can't tell Option from a layout key.

## Keyboard protocols

### Who supports what

| Terminal (version) | kitty protocol | modifyOtherKeys | Answers `\e[?u` |
|---|---|---|---|
| Terminal.app 2.15 | no | no | no; DA1 is `\e[?1;2c` (*measured, binary*) |
| iTerm2 3.6.9 | yes, all 5 flags, separate stacks per screen; on by default behind "Apps can change how keys are reported" (*source*) | modes 1 and 2, same gate | yes |
| Ghostty 1.3.1 | yes, always on, all flags | mode 2 only (`\e[>4;1m` counts as off) | yes |
| kitty 0.50.0 | yes (since 0.20.0) | no, ignored | yes |
| WezTerm 20240203 | **off by default** (`enable_kitty_keyboard = false`); when on, stable sends Esc raw, Delete as `\x08`, ↑ as `\e[1;1A` | modes 1 and 2, on by default | **no** (pushes ignored) |
| Alacritty 0.17.0 | yes (since 0.13.0), all flags | no | yes |
| GNOME Terminal 3.60 / VTE 0.84.1 | no (VTE MR !14 open since 2025-12) | no | no |
| Konsole 26.08.3 | yes, on by default since 26.08.0; **Esc stays `\e`**, Caps/Num Lock bits always added, modified F3 `\e[1;mR` | no | yes |
| xterm 412 | no | yes: resource default 0; `\e[>4;1\|2\|3m`; query XTQMODKEYS `\e[?4m` (since 377) | no |
| foot 1.28.0 | yes (since 1.10.3), all flags | level 1 always (hence `CSI 27` for Ctrl+digit), level 2 on request; XTQMODKEYS since 1.15.0 | yes |
| Windows Terminal 1.25 | yes (new in 1.25, on by default); reaches am through ConPTY (*inferred*) | no | yes, through ConPTY (*inferred*) |
| classic conhost | not established (depends on the Windows build) | no | not established |
| tmux 3.8 | no | yes, when the user sets `extended-keys on` | no |

Sources: the per-terminal sections above; kitty's list of implementations is in
[its spec](https://github.com/kovidgoyal/kitty/blob/v0.50.0/docs/keyboard-protocol.rst?plain=1#L35-L48).

### kitty protocol, flag 1 ("disambiguate escape codes")

How it works (*source*, [kitty's spec at v0.50.0](https://github.com/kovidgoyal/kitty/blob/v0.50.0/docs/keyboard-protocol.rst?plain=1#L314-L373)):

- An app pushes flags with `\e[>1u` and pops them with `\e[<u`. The main and alternate screens
  keep separate stacks, so flags pushed on am's alternate screen don't leak into the shell. `\e[?u`
  asks for the current flags; a terminal with the protocol answers `\e[?<flags>u` before its answer
  to DA1 (`\e[c`), so DA1 alone means "no protocol".
- Esc, and Alt+key, Ctrl+key, Ctrl+Alt+key and Shift+Alt+key on the ASCII keys, arrive as
  `\e[<code>;<m>u`, where `<code>` is the *unshifted* key (`97` for a). Non-text keypad keys get
  private-use codes (keypad Enter `57414`).
- Keys that type text are unchanged: `a`, `A` (Shift+a), `é`, and what Option composes on macOS.
- Unmodified Enter, Tab and Backspace stay `\r`, `\t`, `\x7f`, so a shell stays usable if an app
  crashes with the flag on. Modified ones become `CSI u`: Shift+Enter `\e[13;2u`, Shift+Tab
  `\e[9;2u`, Ctrl+Backspace `\e[127;5u` (*source*: kitty's
  [tests](https://github.com/kovidgoyal/kitty/blob/v0.50.0/kitty_tests/keys.py#L429-L433) and
  [encoder](https://github.com/kovidgoyal/kitty/blob/v0.50.0/kitty/key_encoding.c#L204-L232); Ghostty,
  Alacritty and WezTerm do the same).
- Modifier bits: Shift 1, Alt 2, Ctrl 4, **Super 8**, Hyper 16, Meta 32, Caps Lock 64, Num Lock 128.

What it changes for am (the bytes from the spec and the terminals' sources; what am makes of them
*measured* with the probe):

| Key | Legacy → am | Flag 1 → am |
|---|---|---|
| Esc | `\e` → Esc after 30 ms | `\e[27u` → Esc at once (not in Konsole, which keeps `\e`) |
| Ctrl+i / Ctrl+h / Ctrl+m / Ctrl+[ | Tab / Backspace / Enter / Esc | `ctrl+i` / `ctrl+h` / `ctrl+m` / `ctrl+[` |
| Ctrl+Space | `\x00` → `ctrl+space` | `\e[32;5u` → `ctrl+space` |
| Ctrl+2 / Ctrl+3 / Ctrl+8 | `ctrl+space` / Esc / Backspace | `ctrl+2` / `ctrl+3` / `ctrl+8` |
| Ctrl+/ | `ctrl+_` | `ctrl+/` |
| Ctrl+1, Ctrl+; | `1`, `;` (most) | `ctrl+1`, `ctrl+;` |
| Ctrl+Shift+a | `ctrl+a` (most) | `ctrl+shift+a` |
| Alt+Shift+a | `alt+A` | `alt+shift+a` |
| Alt+[ | `alt+[`, or the start of a sequence | `\e[91;3u` → `alt+[`, never ambiguous |
| Shift+Enter / Ctrl+Enter | Enter | `shift+enter` / `ctrl+enter` |
| Ctrl+Backspace | Backspace | `ctrl+backspace` |
| Ctrl+c / Ctrl+z | `\x03` / `\x1a` | `\e[99;5u` / `\e[122;5u` → still `ctrl+c` / `ctrl+z` |
| Keypad Enter | Enter | `\e[57414u` → a private-use character (Alacritty also sends keypad digits this way) |
| Super+a | usually `a` or nothing | `\e[97;9u` → `alt+a` |

What it doesn't change (*source* for the terminals, *inferred* for am):

- **macOS Option.** Where the terminal composes `ƒ` for Option+f, the protocol sends `ƒ` as text
  (iTerm2 with Option = Normal, kitty, Alacritty, Ghostty on non-US layouts). Only the terminal's own
  option-as-alt setting changes that.
- **Shift+Space** still types a space: Shift alone on a text key isn't covered by flag 1.
- **Taken keys** stay taken: the terminals' shortcuts win before any encoding.
- **Terminals without it** (Terminal.app, GNOME Terminal, xterm, WezTerm by default, tmux,
  possibly the classic console) keep sending legacy bytes. A key recorded through the protocol (Ctrl+i, Shift+Enter,
  Ctrl+Shift+a) then does nothing there, or does what its legacy twin does (Ctrl+i → Tab). With
  one `settings.json`, the dividing line for such keys moves from "which OS" to "which terminal".

What it would cost in am (*inferred* from the code at `31a0ddf`):

- **Terminal setup.** Put `\e[?u` before the DA1 that already ends the startup query
  ([`graphics.query`](https://github.com/IIxauII/am/blob/31a0ddf/src/tui/graphics.zig#L44)), so
  detection costs no extra round trip. Push `\e[>1u` after entering the alternate screen and add
  `\e[<u` to [`leave_sequence`](https://github.com/IIxauII/am/blob/31a0ddf/src/tui/term.zig#L35),
  which the suspend, signal and panic paths already send.
- **Decoder.**
  - A new event for the `\e[?<flags>u` reply, which is skipped today.
  - Map the private-use codes ([table](https://github.com/kovidgoyal/kitty/blob/v0.50.0/docs/keyboard-protocol.rst?plain=1#L600-L654)):
    keypad keys to their main keys, or keypad Enter stops being Enter; F13–F35, media keys and
    Menu to named keys or to nothing. kitty sends these even in legacy mode, so a text field inserts
    them today.
  - Read bit 8 as Super, not Alt, in `CSI u`, and don't let Hyper or Meta turn a modified key into
    a plain one. Konsole adds the lock bits always; masking them is already what am does.
  - Normalize names: today Alt+Shift+a is `alt+A`; under flag 1 it's `alt+shift+a`. Ctrl+Shift+a is
    `ctrl+a` in legacy, `ctrl+shift+a` under flag 1, `ctrl+shift+A` under modifyOtherKeys. One
    spelling in the file has to match all of them.
- **The 30 ms wait.** With flag 1 confirmed, no key press sends a lone `\e` (Konsole excepted), so
  Esc stops waiting. The timer stays for sequences split across reads and for terminals without
  the protocol.
- **Today's default keys.** Plain and Shift-only keys don't change (`G`, `F`, `Q` still arrive as
  capitals), and quit and suspend keep working. `^h` in text fields starts to work as Ctrl+h, apart
  from Backspace.
- **Flag 8 ("report all keys as escape codes")** is what the ticket's "Shift+a as `a` with Shift"
  example needs. Then every key, plain letters, Enter, Tab and Backspace included, arrives as
  `CSI u`. Text is lost unless flag 16 adds it back, and the shifted key on a non-US layout needs
  flag 4. `textCommand` would have to rebuild text from key codes. Flag 1 needs none of that.

### xterm modifyOtherKeys, mode 2

How it works (*source*: xterm 412 `input.c`, `ctlseqs.txt` L849–875 and L1330–1375 in
[xterm-412.tgz](https://invisible-island.net/archives/xterm/xterm-412.tgz); Ghostty
[`key_encode.zig` L408–465](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/input/key_encode.zig#L408-L465)):
`\e[>4;2m` turns it on, `\e[>4m` off. Modified keys become `\e[27;<m>;<code>~` (`\e[<code>;<m>u`
with xterm's `formatOtherKeys` 1, which am also reads). The code is the *shifted* character:
Ctrl+Shift+a is `\e[27;6;65~` in xterm, Ghostty and foot, and `\e[27;5;65~` in WezTerm (Shift
dropped, *inferred*).

What it fixes: Ctrl+i/h/m/[ (`\e[27;5;105~` …), Ctrl+Space (`\e[27;5;32~`), Shift+Space,
Shift/Ctrl+Enter, Ctrl+digit and Ctrl+punctuation, Ctrl+Shift+letter (*source*, xterm).

What it doesn't (*source*; kitty's spec lists the same
[objections](https://github.com/kovidgoyal/kitty/blob/v0.50.0/docs/keyboard-protocol.rst?plain=1#L765-L790)):

- **Esc stays `\e`**, so the 30 ms wait stays. Whether Alt+key is encoded varies: Ghostty sends
  Alt+8 as `\e[27;3;56~` when Option is Alt; xterm's mode 1 leaves Alt alone, and mode 2's Alt
  wasn't checked.
- macOS Option still composes (Ghostty's test with option-as-alt off sends `[` for Option+8).
- No Super, no lock keys, and detection only where XTQMODKEYS exists (xterm 377+, foot 1.15+).
- Ghostty 1.3.1 still sends Ctrl+c as `\x03` under mode 2; 1.4.0 sends `\e[27;5;99~`.
- In iTerm2 3.6.9, `\e[>4;nm` clears the kitty flags and stack, so asking for both falls back to
  legacy (fixed in 3.7.7 per its notes).

Support: xterm, iTerm2, Ghostty, WezTerm and foot (table above). It's the only extension xterm
has, and WezTerm's default; GNOME Terminal has neither.

What it would cost in am (*inferred*): send `\e[>4;2m` at start and `\e[>4m` in `leave_sequence`.
The decoder already reads both formats; it would need to turn the shifted code back into
"letter + Shift" (65 → `a` with Shift) to match kitty's names, and to read bit 8 as Super where the
terminal means Super (Ghostty, foot).

## Method and limits

- **Measured here:** am's decoder and keymap (the probe above); Ghostty 1.3.1's defaults through
  its own CLI; terminfo entries with ncurses 6.6; Terminal.app's `keyMappings.plist`, built-in
  defaults and key encoder (read from its arm64e binary); NSEvents built in memory and
  `UCKeyTranslate` for what Option and Ctrl produce on the US and German layouts; iTerm2's bundled
  default profile and global key map; macOS's shortcut tables and their on/off state; the owner's
  Terminal.app, iTerm2 and Ghostty settings (no key overrides). This Mac's current layout is
  `com.apple.keylayout.US` (`defaults read com.apple.HIToolbox`).
- **Not measured:** the bytes any terminal actually writes when a key is pressed. That needs key
  presses, which this run didn't send. kitty, WezTerm, Alacritty and tmux aren't installed here,
  and the Linux and Windows terminals can't run on this Mac. Apart from Terminal.app's (read from
  its binary and plist), every terminal's bytes are *source*, read from its encoder and tests at a
  release tag.
- **Weakest cells:** Terminal.app's Cocoa fallbacks (Ctrl+digit, Ctrl+punctuation, Ctrl+Shift+letter)
  and Alacritty's Ctrl+punctuation are *inferred*, and so is the kitty protocol's round trip through
  ConPTY in Windows Terminal. A press-and-record pass with `cat -v` or kitty's `kitten show-key` in
  each terminal would settle them.
- Sources were cloned depth 1 at the tags named in each section and only read. No build tool or
  script from a clone was run.
