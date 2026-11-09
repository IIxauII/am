## Resolution

Only a small core of keys reaches am the same way everywhere; most combinations differ by terminal or OS, or never arrive. Without a keyboard protocol several keys send the same bytes, so the Settings page records the name of what arrived (Tab for Ctrl+i) and can't tell what was pressed. The kitty keyboard protocol (an opt-in mode where the terminal sends ambiguous keys as `ESC [ code ; modifiers u`) separates them in most current terminals, but not in Terminal.app, GNOME Terminal, xterm or tmux.

Gathered 2026-11-09 on macOS 26.2. *Measured*: am's decoder at `31a0ddf` (a Zig test feeding it each sequence), Ghostty 1.3.1's CLI, terminfo, the Terminal.app and iTerm2 bundles, macOS's shortcut tables. No key was pressed in any terminal; the rest is *source*, at release tags.

Context: https://github.com/IIxauII/am/tree/research/portable-keys/research/portable-keys (all tables and sources).

**Safe to bind**
- Characters, Space, Enter, Tab, Shift+Tab, Esc, Backspace, plain arrows, Home, End, PgUp, PgDn, Delete, F1–F9, F12, and Ctrl+letter except Ctrl+h/i/j/m, tmux's Ctrl+b and Windows Terminal's Ctrl+v. *Source*; decoding *measured*.
- Mac keyboards need Fn for F-keys and Home/End/PgUp/PgDn, and have no Insert. *Measured*.

**Differ per terminal or OS**
- Alt/Option: composes `ƒ` in Terminal.app, iTerm2, kitty and Alacritty on macOS, and in Ghostty on non-US Mac layouts; `æ` in xterm; ESC+key elsewhere. *Measured* (Ghostty, Terminal.app, iTerm2), else *source*.
- Ctrl+digit, Ctrl+punctuation: a control byte, the plain character (Ctrl+1 opens Home), an extended code (Ghostty, foot), or taken. Ctrl+Shift+letter: Ctrl+letter in most, distinct in Ghostty and kitty. Shift/Ctrl+Enter: Enter except in Ghostty and foot. *Source*.
- Modified arrows, Home/End/PgUp/PgDn, F-keys: Terminal.app drops Shift on ↑↓; Option+←/→ arrive as Alt+b/f in Terminal.app and Ghostty; Konsole's Shift+F3 decodes as three keys and starts a station. *Measured* (Terminal.app, decoder), *source* (Konsole).
- At capture the page sees only the decoded key. It could see the encoding form (`CSI u` or `CSI 27~` means only some terminals send it), a collision class, several keys in one read, or a non-ASCII character that may be Option. *Inferred*.

**Never arrive**
- macOS: Cmd (Ghostty turns Cmd+⌫ into Ctrl+u), Ctrl+arrows, Ctrl+Space, Ctrl+F1–F8, F11. *Measured*.
- Terminals: Linux Ctrl+Shift shortcuts, zoom keys, Ctrl+Tab, Alt+Enter, Shift+PgUp/PgDn in four, GNOME Terminal's F10, Windows Terminal's defaults, tmux's prefix; some only with several tabs or a selection. Desktops: Alt+Tab, Alt+Space, Super, GNOME's Alt+Esc, KDE's Ctrl+F1–F4. *Source*.

**Collisions and naming**
- Most terminals record as Tab: Ctrl+i. Enter: Ctrl+m, Ctrl+j. Backspace: Ctrl+h, Ctrl+Backspace, Ctrl+8. Esc: Ctrl+[, Ctrl+3. `ctrl+space`: Ctrl+2, Ctrl+@. `ctrl+_`: Ctrl+/, Ctrl+7. Ctrl+a: Ctrl+Shift+a. Space: Shift+Space. *Measured*.
- Inside tmux, every terminal falls back to this set. *Source*.
- One key, several names: Alt+Shift+a is `alt+A` without a protocol and `alt+shift+a` under kitty's; Ctrl+Shift+a is `ctrl+a`, `ctrl+shift+a` or `ctrl+shift+A`. Super decodes as Alt. *Measured*.

**kitty protocol (flag 1)**
- Supported: iTerm2, Ghostty, kitty, Alacritty, Konsole 26.08+, foot, Windows Terminal 1.25 (through ConPTY: *inferred*). Off by default in WezTerm; absent in Terminal.app (*measured*), GNOME Terminal, xterm, tmux. *Source*.
- Fixes the collisions above except Shift+Space, and the 30 ms Esc wait (Konsole still sends a bare Esc). Not Option composing, taken keys, or terminals without it. *Source*.
- Cost: a query added to the startup DA1, push/pop around the alternate screen, a reply event, mapping private-use codes (keypad Enter breaks otherwise), bit 8 as Super, one spelling for shifted names. Default keys stay (only flag 8 would report Shift+a as `a`+Shift). *Inferred*.

**modifyOtherKeys (`\e[>4;2m`)**
- Supported: xterm, iTerm2, Ghostty, WezTerm, foot, tmux with `extended-keys on`. *Source*.
- Fixes the Ctrl, Enter and Shift+Space collisions, not the Esc wait; names Ctrl+Shift+a `ctrl+shift+A` (`ctrl+A` in WezTerm). The decoder already reads it. *Source*; decoding *measured*.
