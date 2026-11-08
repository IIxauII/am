//! PROTOTYPE: throwaway, never merged (branch `prototype/settings-screen`).
//!
//! Three takes on am's settings screen, mounted in the real TUI, for the wayfinder ticket
//! "Settings screen and key rebinding flow" (https://github.com/IIxauII/am/issues/2):
//!
//!   A  Settings page: a sidebar entry (`,`) that fills the list pane; every change applies at once.
//!   B  Settings dialog: a modal box with tabs (`,`); changes wait for `w` (save).
//!   C  Editable help: `?` lists every binding and edits it in place; changes apply at once, `z` undoes.
//!
//! `{` and `}` switch variants; `AM_PROTO_SETTINGS=A|B|C` picks the first one. Nothing is written
//! to disk. Rebinding is live for the session, the artwork choice is live, keep-alive is a stub.
const std = @import("std");
const input = @import("input.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
const screen_mod = @import("screen.zig");
const views = @import("views.zig");
const width = @import("width.zig");

const Key = input.Key;
const Rect = layout.Rect;
const Screen = screen_mod.Screen;
const Style = screen_mod.Style;
const Theme = views.Theme;

// ---- The bindings table ----

pub const Do = union(enum) {
    list: keys.Command,
    text: keys.TextCommand,
    /// Open (or close) the settings.
    settings,
};

pub const Group = enum {
    move,
    sections,
    play,
    library,
    app,
    typing,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .move => "Move",
            .sections => "Sections",
            .play => "Play",
            .library => "Library",
            .app => "App",
            .typing => "In search and filter",
        };
    }
};

const groups = [_]Group{ .move, .sections, .play, .library, .app, .typing };

/// Where a binding works: outside text input (lists, help, details, the picker), or while
/// typing in search and filter.
pub const Ctx = enum { lists, typing };

pub const Action = struct {
    name: []const u8,
    group: Group,
    do: Do,
    defaults: []const Key,
    /// Can't be changed: ^c quits and ^z suspends from anywhere.
    fixed: bool = false,

    pub fn ctx(a: Action) Ctx {
        return if (a.do == .text) .typing else .lists;
    }
};

fn ch(c: u21) Key {
    return .char(c);
}
fn ctl(c: u21) Key {
    return .ctrlChar(c);
}
fn code(c: Key.Code) Key {
    return .{ .code = c };
}
fn shifted(c: Key.Code) Key {
    return .{ .code = c, .shift = true };
}

/// Every action with its default keys: today's `keys.command` and `keys.textCommand`, one row
/// per action, plus `,` for the settings.
pub const actions = [_]Action{
    .{ .name = "Move down", .group = .move, .do = .{ .list = .{ .move = 1 } }, .defaults = &.{ ch('j'), code(.down), ctl('n') } },
    .{ .name = "Move up", .group = .move, .do = .{ .list = .{ .move = -1 } }, .defaults = &.{ ch('k'), code(.up), ctl('p') } },
    .{ .name = "Top", .group = .move, .do = .{ .list = .top }, .defaults = &.{ ch('g'), code(.home) } },
    .{ .name = "Bottom", .group = .move, .do = .{ .list = .bottom }, .defaults = &.{ ch('G'), code(.end) } },
    .{ .name = "Page down", .group = .move, .do = .{ .list = .{ .page = 1 } }, .defaults = &.{code(.page_down)} },
    .{ .name = "Page up", .group = .move, .do = .{ .list = .{ .page = -1 } }, .defaults = &.{code(.page_up)} },
    .{ .name = "Half page down", .group = .move, .do = .{ .list = .{ .half = 1 } }, .defaults = &.{ctl('d')} },
    .{ .name = "Half page up", .group = .move, .do = .{ .list = .{ .half = -1 } }, .defaults = &.{ctl('u')} },
    .{ .name = "Other pane", .group = .move, .do = .{ .list = .focus_next }, .defaults = &.{code(.tab)} },
    .{ .name = "Other pane, backwards", .group = .move, .do = .{ .list = .focus_prev }, .defaults = &.{shifted(.tab)} },
    .{ .name = "To the sidebar", .group = .move, .do = .{ .list = .focus_left }, .defaults = &.{ch('h')} },
    .{ .name = "To the list", .group = .move, .do = .{ .list = .focus_right }, .defaults = &.{ch('l')} },
    .{ .name = "Open, or play from here", .group = .move, .do = .{ .list = .open }, .defaults = &.{code(.enter)} },
    .{ .name = "Back", .group = .move, .do = .{ .list = .back }, .defaults = &.{ code(.esc), code(.backspace) } },
    .{ .name = "Filter this list", .group = .move, .do = .{ .list = .filter }, .defaults = &.{ctl('f')} },
    .{ .name = "Go to album", .group = .move, .do = .{ .list = .go_album }, .defaults = &.{ch('o')} },
    .{ .name = "Go to artist", .group = .move, .do = .{ .list = .go_artist }, .defaults = &.{ch('O')} },
    .{ .name = "Go to what's playing", .group = .move, .do = .{ .list = .jump_now }, .defaults = &.{ch('c')} },

    .{ .name = "Home", .group = .sections, .do = .{ .list = .{ .section = .home } }, .defaults = &.{ch('1')} },
    .{ .name = "Recently Played", .group = .sections, .do = .{ .list = .{ .section = .recent } }, .defaults = &.{ch('2')} },
    .{ .name = "Songs", .group = .sections, .do = .{ .list = .{ .section = .songs } }, .defaults = &.{ch('3')} },
    .{ .name = "Albums", .group = .sections, .do = .{ .list = .{ .section = .albums } }, .defaults = &.{ch('4')} },
    .{ .name = "Artists", .group = .sections, .do = .{ .list = .{ .section = .artists } }, .defaults = &.{ch('5')} },
    .{ .name = "Playlists", .group = .sections, .do = .{ .list = .{ .section = .playlists } }, .defaults = &.{ch('6')} },
    .{ .name = "Favorites", .group = .sections, .do = .{ .list = .{ .section = .favorites } }, .defaults = &.{ch('7')} },
    .{ .name = "Radio", .group = .sections, .do = .{ .list = .{ .section = .radio } }, .defaults = &.{ch('8')} },
    .{ .name = "Charts", .group = .sections, .do = .{ .list = .{ .section = .charts } }, .defaults = &.{ch('9')} },
    .{ .name = "Recently Added", .group = .sections, .do = .{ .list = .{ .section = .recently_added } }, .defaults = &.{} },
    .{ .name = "Up Next", .group = .sections, .do = .{ .list = .{ .section = .queue } }, .defaults = &.{ch('0')} },
    .{ .name = "Search", .group = .sections, .do = .{ .list = .search }, .defaults = &.{ch('/')} },

    .{ .name = "Play / pause", .group = .play, .do = .{ .list = .toggle }, .defaults = &.{ch(' ')} },
    .{ .name = "Next", .group = .play, .do = .{ .list = .next }, .defaults = &.{ ch('n'), ch('>') } },
    .{ .name = "Previous", .group = .play, .do = .{ .list = .previous }, .defaults = &.{ ch('p'), ch('<') } },
    .{ .name = "Seek back 5 s", .group = .play, .do = .{ .list = .{ .seek = -5 } }, .defaults = &.{code(.left)} },
    .{ .name = "Seek forward 5 s", .group = .play, .do = .{ .list = .{ .seek = 5 } }, .defaults = &.{code(.right)} },
    .{ .name = "Seek back 30 s", .group = .play, .do = .{ .list = .{ .seek = -30 } }, .defaults = &.{ ch('['), shifted(.left) } },
    .{ .name = "Seek forward 30 s", .group = .play, .do = .{ .list = .{ .seek = 30 } }, .defaults = &.{ ch(']'), shifted(.right) } },
    .{ .name = "Volume up", .group = .play, .do = .{ .list = .{ .volume = 5 } }, .defaults = &.{ ch('+'), ch('=') } },
    .{ .name = "Volume down", .group = .play, .do = .{ .list = .{ .volume = -5 } }, .defaults = &.{ch('-')} },
    .{ .name = "Mute", .group = .play, .do = .{ .list = .mute }, .defaults = &.{ch('m')} },
    .{ .name = "Shuffle", .group = .play, .do = .{ .list = .shuffle }, .defaults = &.{ch('s')} },
    .{ .name = "Repeat: off, all, one", .group = .play, .do = .{ .list = .repeat }, .defaults = &.{ch('r')} },
    .{ .name = "Play album or playlist from the top", .group = .play, .do = .{ .list = .play_container }, .defaults = &.{ch('P')} },
    .{ .name = "Play later", .group = .play, .do = .{ .list = .play_later }, .defaults = &.{ch('e')} },
    .{ .name = "Play next", .group = .play, .do = .{ .list = .play_next }, .defaults = &.{ch('E')} },
    .{ .name = "Station from the selection", .group = .play, .do = .{ .list = .station }, .defaults = &.{ch('R')} },
    .{ .name = "Remove from Up Next", .group = .play, .do = .{ .list = .remove }, .defaults = &.{ ch('d'), code(.delete) } },

    .{ .name = "Favorite the selection", .group = .library, .do = .{ .list = .favorite }, .defaults = &.{ch('f')} },
    .{ .name = "Favorite what's playing", .group = .library, .do = .{ .list = .favorite_now }, .defaults = &.{ch('F')} },
    .{ .name = "Add to library", .group = .library, .do = .{ .list = .add_library }, .defaults = &.{ch('a')} },
    .{ .name = "Add to a playlist", .group = .library, .do = .{ .list = .add_playlist }, .defaults = &.{ch('A')} },
    .{ .name = "Details", .group = .library, .do = .{ .list = .info }, .defaults = &.{ch('i')} },

    .{ .name = "Settings", .group = .app, .do = .settings, .defaults = &.{ch(',')} },
    .{ .name = "Help", .group = .app, .do = .{ .list = .help }, .defaults = &.{ch('?')} },
    .{ .name = "Artwork: images, blocks, off", .group = .app, .do = .{ .list = .image_mode }, .defaults = &.{ch('v')} },
    .{ .name = "Reload view", .group = .app, .do = .{ .list = .refresh }, .defaults = &.{ctl('r')} },
    .{ .name = "Redraw", .group = .app, .do = .{ .list = .redraw }, .defaults = &.{ctl('l')} },
    .{ .name = "Sign in to Apple Music again", .group = .app, .do = .{ .list = .signin }, .defaults = &.{ch('S')} },
    .{ .name = "Quit (the music goes on)", .group = .app, .do = .{ .list = .quit }, .defaults = &.{ch('q')} },
    .{ .name = "Quit and stop the music", .group = .app, .do = .{ .list = .quit_stop }, .defaults = &.{ch('Q')} },
    .{ .name = "Quit, from anywhere", .group = .app, .do = .{ .list = .quit }, .defaults = &.{ctl('c')}, .fixed = true },
    .{ .name = "Suspend", .group = .app, .do = .{ .list = .suspend_process }, .defaults = &.{ctl('z')}, .fixed = true },

    .{ .name = "Search, or submit", .group = .typing, .do = .{ .text = .submit }, .defaults = &.{code(.enter)} },
    .{ .name = "Leave the field", .group = .typing, .do = .{ .text = .leave }, .defaults = &.{code(.esc)} },
    .{ .name = "Down to the list", .group = .typing, .do = .{ .text = .down }, .defaults = &.{code(.down)} },
    .{ .name = "Up", .group = .typing, .do = .{ .text = .up }, .defaults = &.{code(.up)} },
    .{ .name = "Delete back", .group = .typing, .do = .{ .text = .delete_back }, .defaults = &.{ code(.backspace), ctl('h') } },
    .{ .name = "Clear the field", .group = .typing, .do = .{ .text = .clear }, .defaults = &.{ctl('u')} },
    .{ .name = "Catalog or library search", .group = .typing, .do = .{ .text = .toggle_scope }, .defaults = &.{code(.tab)} },
    .{ .name = "Quit, from anywhere", .group = .typing, .do = .{ .text = .quit }, .defaults = &.{ctl('c')}, .fixed = true },
};

const settings_action: usize = blk: {
    for (actions, 0..) |a, i| if (a.do == .settings) break :blk i;
    unreachable;
};
const help_action: usize = blk: {
    for (actions, 0..) |a, i| if (a.do == .list and a.do.list == .help) break :blk i;
    unreachable;
};

pub const max_keys = 4;

pub const KeySet = struct {
    buf: [max_keys]Key = undefined,
    len: u8 = 0,

    pub fn of(ks: []const Key) KeySet {
        var s: KeySet = .{};
        for (ks) |k| s.add(k);
        return s;
    }

    pub fn slice(s: *const KeySet) []const Key {
        return s.buf[0..s.len];
    }

    pub fn has(s: *const KeySet, k: Key) bool {
        for (s.slice()) |x| if (x.eql(k)) return true;
        return false;
    }

    pub fn add(s: *KeySet, k: Key) void {
        if (s.has(k) or s.len == max_keys) return;
        s.buf[s.len] = k;
        s.len += 1;
    }

    pub fn remove(s: *KeySet, k: Key) void {
        var i: usize = 0;
        while (i < s.len) {
            if (s.buf[i].eql(k)) {
                var j = i;
                while (j + 1 < s.len) : (j += 1) s.buf[j] = s.buf[j + 1];
                s.len -= 1;
            } else i += 1;
        }
    }

    pub fn same(s: *const KeySet, other: []const Key) bool {
        if (s.len != other.len) return false;
        for (other) |k| if (!s.has(k)) return false;
        return true;
    }
};

pub const Bindings = [actions.len]KeySet;

pub fn defaultBindings() Bindings {
    var b: Bindings = undefined;
    for (actions, 0..) |a, i| b[i] = .of(a.defaults);
    return b;
}

fn isDefault(b: *const Bindings, i: usize) bool {
    return b[i].same(actions[i].defaults);
}

fn changedCount(b: *const Bindings) usize {
    var n: usize = 0;
    for (0..actions.len) |i| n += @intFromBool(!isDefault(b, i));
    return n;
}

/// The action `k` does in `cx`, other than `except`.
fn find(b: *const Bindings, cx: Ctx, k: Key, except: ?usize) ?usize {
    for (actions, 0..) |a, i| {
        if (except) |e| if (e == i) continue;
        if (a.ctx() == cx and b[i].has(k)) return i;
    }
    return null;
}

fn defaultSomewhere(cx: Ctx, k: Key) bool {
    for (actions) |a| if (a.ctx() == cx) for (a.defaults) |d| if (d.eql(k)) return true;
    return false;
}

fn printable(k: Key) bool {
    return k.code == .char and !k.ctrl and k.code.char >= 0x20;
}

/// Why `k` can't be bound to action `i`, if it can't.
fn refuse(i: usize, k: Key) ?[]const u8 {
    if (k.ctrl and k.code == .char and (k.code.char == 'c' or k.code.char == 'z')) return "^c and ^z can't be bound: they always quit and suspend";
    if (actions[i].ctx() == .typing and printable(k)) return "That key types in search and filter; pick one that doesn't type";
    return null;
}

pub fn keyName(buf: []u8, k: Key) []const u8 {
    var cbuf: [8]u8 = undefined;
    const base: []const u8 = switch (k.code) {
        .char => |c| if (c == ' ') "Space" else blk: {
            const n = std.unicode.utf8Encode(c, &cbuf) catch break :blk "?";
            break :blk cbuf[0..n];
        },
        .enter => "Enter",
        .esc => "Esc",
        .tab => "Tab",
        .backspace => "Backspace",
        .delete => "Del",
        .insert => "Ins",
        .up => "↑",
        .down => "↓",
        .left => "←",
        .right => "→",
        .home => "Home",
        .end => "End",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .f => |n| std.fmt.bufPrint(&cbuf, "F{d}", .{n}) catch "F?",
    };
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ if (k.alt) "M-" else "", if (k.ctrl) "^" else "", if (k.shift) "⇧" else "", base }) catch "?";
}

/// The keys' names joined by `sep`.
fn keysText(buf: []u8, ks: []const Key, sep: []const u8) []const u8 {
    var len: usize = 0;
    for (ks, 0..) |k, i| {
        var nb: [24]u8 = undefined;
        const name = keyName(&nb, k);
        const extra = if (i > 0) sep.len else 0;
        if (len + extra + name.len > buf.len) break;
        if (i > 0) {
            @memcpy(buf[len..][0..sep.len], sep);
            len += sep.len;
        }
        @memcpy(buf[len..][0..name.len], name);
        len += name.len;
    }
    return buf[0..len];
}

// ---- State ----

pub const Variant = enum {
    a,
    b,
    c,

    pub fn name(v: Variant) []const u8 {
        return switch (v) {
            .a => "A settings page",
            .b => "B settings dialog",
            .c => "C editable help",
        };
    }

    pub fn parse(s: ?[]const u8) Variant {
        const t = s orelse return .a;
        if (t.len == 0) return .a;
        return switch (std.ascii.toLower(t[0])) {
            'b' => .b,
            'c' => .c,
            else => .a,
        };
    }
};

pub const Art = enum { auto, images, blocks, off };

fn artName(a: Art) []const u8 {
    return switch (a) {
        .auto => "auto",
        .images => "images",
        .blocks => "blocks",
        .off => "off",
    };
}

/// What the app knows about artwork right now.
pub const Facts = struct {
    /// What shows: images, blocks or off.
    showing: Art = .blocks,
    /// The terminal answered the image query at startup (or AM_IMAGES asks for kitty).
    images_ok: bool = false,
};

const Capture = struct {
    action: usize,
    /// Keep the action's other keys.
    add: bool = false,
    /// B: the key chip it replaces.
    chip: ?usize = null,
};

const Mode = union(enum) {
    browse,
    capture: Capture,
    /// B: the key arrived; Enter takes it.
    captured: struct { cap: Capture, key: Key },
    /// A: the key is another action's; Enter takes it.
    conflict: struct { cap: Capture, key: Key, other: usize },
    confirm_reset,
    confirm_discard,
    finding,
};

pub const Tab = enum { keys, engine, artwork };

const Clash = enum { ask, steal };

const row_cap = actions.len + 32;

pub const Proto = struct {
    variant: Variant,
    open: bool = false,
    live: Bindings,
    keep_alive: bool = false,
    art: Art = .auto,
    facts: Facts = .{},
    mode: Mode = .browse,
    sel: usize = 0,
    top: usize = 0,
    /// List rows shown last time (paging).
    height: usize = 10,
    // B
    tab: Tab = .keys,
    draft: Bindings,
    draft_keep_alive: bool = false,
    draft_art: Art = .auto,
    chip: usize = 0,
    find_buf: [32]u8 = undefined,
    find_len: usize = 0,
    // C
    undo: ?Bindings = null,
    note_buf: [200]u8 = undefined,
    note_len: usize = 0,
    // For the app.
    toast_buf: [256]u8 = undefined,
    toast_len: usize = 0,
    art_changed: bool = false,

    pub fn init(variant: Variant) Proto {
        const d = defaultBindings();
        return .{ .variant = variant, .live = d, .draft = d };
    }

    fn say(p: *Proto, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&p.toast_buf, fmt, args) catch p.toast_buf[0..0];
        p.toast_len = out.len;
    }

    pub fn takeToast(p: *Proto) ?[]const u8 {
        if (p.toast_len == 0) return null;
        defer p.toast_len = 0;
        return p.toast_buf[0..p.toast_len];
    }

    fn setNote(p: *Proto, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&p.note_buf, fmt, args) catch p.note_buf[0..0];
        p.note_len = out.len;
    }

    fn note(p: *const Proto) []const u8 {
        return p.note_buf[0..p.note_len];
    }

    pub fn pageOpen(p: *const Proto) bool {
        return p.open and p.variant == .a;
    }

    pub fn modalOpen(p: *const Proto) bool {
        return p.open and p.variant != .a;
    }

    /// Variant A's sidebar entry: the settings key.
    pub fn sidebarLabel(p: *const Proto, buf: []u8) ?[]const u8 {
        if (p.variant != .a) return null;
        const ks = p.live[settings_action].slice();
        if (ks.len == 0) return " ";
        return keyName(buf, ks[0]);
    }

    // ---- Keys, for the app ----

    /// What a key does outside text input, with this session's bindings.
    pub fn command(p: *const Proto, k: Key) ?Do {
        if (find(&p.live, .lists, k, null)) |i| return actions[i].do;
        if (defaultSomewhere(.lists, k)) return null;
        return if (keys.command(k)) |c| .{ .list = c } else null;
    }

    /// What a key does in a text field, with this session's bindings.
    pub fn textCommand(p: *const Proto, k: Key) ?keys.TextCommand {
        if (printable(k)) return .{ .insert = k.code.char };
        if (find(&p.live, .typing, k, null)) |i| return actions[i].do.text;
        if (defaultSomewhere(.typing, k)) return null;
        return keys.textCommand(k);
    }

    /// A key before the app's own handling (no overlay up). True when the settings took it.
    pub fn key(p: *Proto, k: Key, text_mode: bool) bool {
        const ctrl_c = k.ctrl and k.code == .char and k.code.char == 'c';
        if (!p.open) {
            if (text_mode) return false;
            if (switchDir(k)) |dir| {
                p.switchVariant(dir);
                return true;
            }
            const d = p.command(k) orelse return false;
            if (d == .settings) {
                p.openNow(true);
                return true;
            }
            if (p.variant == .c and d == .list and d.list == .help) {
                p.openNow(false);
                return true;
            }
            return false;
        }
        if (ctrl_c) switch (p.mode) {
            .browse, .finding => return false,
            else => {
                p.mode = .browse;
                p.say("Cancelled", .{});
                return true;
            },
        };
        if (p.mode == .browse) {
            if (switchDir(k)) |dir| {
                p.switchVariant(dir);
                return true;
            }
            if (p.command(k)) |d| if (d == .settings or (p.variant == .c and d == .list and d.list == .help)) {
                if (p.variant == .b and p.unsaved() > 0) p.mode = .confirm_discard else p.close();
                return true;
            };
        }
        return switch (p.variant) {
            .a => p.keyA(k),
            .b => p.keyB(k),
            .c => p.keyC(k),
        };
    }

    fn switchDir(k: Key) ?i32 {
        if (k.eql(.char('{'))) return -1;
        if (k.eql(.char('}'))) return 1;
        return null;
    }

    fn switchVariant(p: *Proto, dir: i32) void {
        const dropped = p.variant == .b and p.open and p.unsaved() > 0;
        p.variant = switch (p.variant) {
            .a => if (dir > 0) .b else .c,
            .b => if (dir > 0) .c else .a,
            .c => if (dir > 0) .a else .b,
        };
        if (p.open) p.openNow(false);
        var kb: [24]u8 = undefined;
        p.say("Prototype {s}: {s} opens it{s}", .{ p.variant.name(), p.opener(&kb), if (dropped) " (B's unsaved changes dropped)" else "" });
    }

    fn opener(p: *const Proto, buf: []u8) []const u8 {
        const i = if (p.variant == .c) help_action else settings_action;
        const ks = p.live[i].slice();
        if (ks.len == 0) return "no key";
        return keyName(buf, ks[0]);
    }

    fn openNow(p: *Proto, at_settings: bool) void {
        p.open = true;
        p.mode = .browse;
        p.top = 0;
        p.note_len = 0;
        p.tab = .keys;
        p.chip = 0;
        p.draft = p.live;
        p.draft_keep_alive = p.keep_alive;
        p.draft_art = p.art;
        p.undo = null;
        switch (p.variant) {
            .a => {
                var rb: [row_cap]RowA = undefined;
                p.sel = firstWhere(RowA, rowsA(&rb), selectableA);
            },
            .b => {
                var rb: [row_cap]RowB = undefined;
                p.sel = firstWhere(RowB, p.rowsB(&rb), selectableB);
            },
            .c => {
                var lb: [row_cap]LineC = undefined;
                const lines = linesC(&lb);
                p.sel = firstWhere(LineC, lines, selectableC);
                if (at_settings) for (lines, 0..) |l, i| if (l == .keep_alive) {
                    p.sel = i;
                };
            },
        }
    }

    fn close(p: *Proto) void {
        p.open = false;
        p.mode = .browse;
    }

    fn editable(p: *Proto, i: usize) bool {
        if (actions[i].fixed) {
            p.say("{s} is fixed: ^c always quits, ^z always suspends", .{actions[i].name});
            return false;
        }
        return true;
    }

    /// Settings (and help, in C) keep a key, or there'd be no way back here.
    fn mustKeep(p: *const Proto, i: usize) bool {
        return i == settings_action or (p.variant == .c and i == help_action);
    }

    fn bindNow(p: *Proto, cap: Capture, k: Key, clash: Clash) void {
        p.mode = .browse;
        const a = actions[cap.action];
        var nb: [24]u8 = undefined;
        const kn = keyName(&nb, k);
        if (refuse(cap.action, k)) |why| return p.tell(clash, "{s}", .{why});
        if (find(&p.live, a.ctx(), k, cap.action)) |other| {
            if (actions[other].fixed) return p.tell(clash, "{s} is {s}, which can't change", .{ kn, actions[other].name });
            if (p.mustKeep(other) and p.live[other].len == 1) return p.tell(clash, "{s} is the only key for {s}, which needs one", .{ kn, actions[other].name });
            switch (clash) {
                .ask => {
                    p.mode = .{ .conflict = .{ .cap = cap, .key = k, .other = other } };
                    return;
                },
                .steal => {
                    p.undo = p.live;
                    p.live[other].remove(k);
                    assign(&p.live, cap, k);
                    var kb: [64]u8 = undefined;
                    const left = keysText(&kb, p.live[other].slice(), " ");
                    p.setNote("{s} is {s} now; {s} {s}{s} · z undo", .{ kn, a.name, actions[other].name, if (left.len == 0) "has no key" else "keeps ", left });
                    return;
                },
            }
        }
        if (clash == .steal) p.undo = p.live;
        assign(&p.live, cap, k);
        var kb: [64]u8 = undefined;
        p.tell(clash, "{s}: {s}{s}", .{ a.name, keysText(&kb, p.live[cap.action].slice(), " "), if (clash == .steal) " · z undo" else "" });
    }

    /// A toast (A) or the help box's note line (C).
    fn tell(p: *Proto, clash: Clash, comptime fmt: []const u8, args: anytype) void {
        if (clash == .steal) p.setNote(fmt, args) else p.say(fmt, args);
    }

    fn take(p: *Proto, cap: Capture, k: Key, other: usize) void {
        p.live[other].remove(k);
        assign(&p.live, cap, k);
        var nb: [24]u8 = undefined;
        var kb: [64]u8 = undefined;
        const left = keysText(&kb, p.live[other].slice(), " ");
        p.say("{s} is {s} now; {s} {s}{s}", .{ keyName(&nb, k), actions[cap.action].name, actions[other].name, if (left.len == 0) "has no key" else "keeps ", left });
    }

    fn unbind(p: *Proto, b: *Bindings, i: usize) bool {
        if (!p.editable(i)) return false;
        if (p.mustKeep(i)) {
            p.say("{s} needs a key, or there'd be no way back here", .{actions[i].name});
            p.setNote("{s} needs a key, or there'd be no way back here", .{actions[i].name});
            return false;
        }
        b[i] = .{};
        return true;
    }

    // ---- Variant A: the settings page ----

    fn keyA(p: *Proto, k: Key) bool {
        switch (p.mode) {
            .capture => |cap| {
                if (k.code == .esc and !k.ctrl and !k.alt) {
                    p.mode = .browse;
                    return true;
                }
                p.bindNow(cap, k, .ask);
                return true;
            },
            .conflict => |c| {
                if (k.code == .enter) p.take(c.cap, c.key, c.other) else p.say("Left {s} as it was", .{actions[c.other].name});
                p.mode = .browse;
                return true;
            },
            .confirm_reset => {
                if (k.code == .enter) {
                    const n = changedCount(&p.live);
                    p.live = defaultBindings();
                    p.say("{d} key{s} back to default", .{ n, plural(n) });
                } else p.say("Kept your keys", .{});
                p.mode = .browse;
                return true;
            },
            else => {},
        }
        var rb: [row_cap]RowA = undefined;
        const rows = rowsA(&rb);
        if (navOf(k)) |nv| {
            p.sel = applyNav(RowA, rows, selectableA, p.sel, nv, p.height);
            return true;
        }
        if (isBack(k)) {
            p.close();
            return true;
        }
        const row = rows[@min(p.sel, rows.len - 1)];
        if (k.code == .enter and !k.ctrl) {
            p.activateA(row);
            return true;
        }
        if (row == .action) {
            const i = row.action;
            if (k.eql(.char('a'))) {
                if (p.editable(i)) p.mode = .{ .capture = .{ .action = i, .add = true } };
                return true;
            }
            if (k.eql(.char('d')) or k.code == .delete) {
                if (p.unbind(&p.live, i)) p.say("{s}: no key now", .{actions[i].name});
                return true;
            }
            if (k.eql(.char('u'))) {
                p.live[i] = .of(actions[i].defaults);
                var kb: [64]u8 = undefined;
                p.say("{s}: back to {s}", .{ actions[i].name, keysText(&kb, actions[i].defaults, " ") });
                return true;
            }
        }
        // Everything else works as on any page: Space plays, n skips, the number keys leave.
        const d = p.command(k) orelse return true;
        switch (d) {
            .list => |c| switch (c) {
                .toggle, .next, .previous, .seek, .volume, .mute, .shuffle, .repeat, .favorite_now, .image_mode, .quit, .quit_stop, .refresh, .redraw, .signin, .suspend_process => return false,
                .section, .search, .jump_now, .help, .focus_left, .focus_next, .focus_prev => {
                    p.close();
                    return false;
                },
                else => return true,
            },
            else => return true,
        }
    }

    fn activateA(p: *Proto, row: RowA) void {
        switch (row) {
            .keep_alive => {
                p.keep_alive = !p.keep_alive;
                if (p.keep_alive)
                    p.say("Keep-alive on: the engine would start now and stay up while am is open (prototype: not wired)", .{})
                else
                    p.say("Keep-alive off: the engine would close after 5 idle minutes (prototype: not wired)", .{});
            },
            .artwork => {
                p.art = nextArt(p.facts.showing, p.facts.images_ok);
                p.art_changed = true;
                p.say("Artwork: {s}", .{artName(p.art)});
            },
            .action => |i| if (p.editable(i)) {
                p.mode = .{ .capture = .{ .action = i } };
            },
            .reset_all => if (changedCount(&p.live) == 0) p.say("Every key is already the default", .{}) else {
                p.mode = .confirm_reset;
            },
            else => {},
        }
    }

    pub fn drawPage(p: *Proto, s: *Screen, t: Theme, r: Rect) void {
        if (!p.pageOpen()) return;
        s.fill(r.x, r.y, r.w, r.h, .{});
        _ = s.print(r.x + 1, r.y, r.w -| 2, "Settings", .{ .bold = true });
        rightText(s, r.right() -| 1, r.y, r.w -| 12, "changes apply at once", dim(t));
        rule(s, r.x, r.y + 1, r.w, t);
        const hint_h: u16 = 3;
        const list_y = r.y + 2;
        const list_h: usize = r.h -| (2 + hint_h);
        p.height = @max(1, list_h);
        var rb: [row_cap]RowA = undefined;
        const rows = rowsA(&rb);
        p.sel = @min(p.sel, rows.len - 1);
        p.top = layout.scroll(p.sel, p.top, list_h, rows.len, 2);
        const name_w: u16 = @min(38, r.w / 2);
        var y = list_y;
        for (rows[p.top..], p.top..) |row, i| {
            if (y >= list_y + list_h) break;
            p.drawRowA(s, t, r.x, y, r.w, row, i == p.sel, name_w);
            y += 1;
        }
        // The hint for the selected row, or what the screen waits for.
        const hy = r.bottom() -| 2;
        rule(s, r.x, hy -| 1, r.w, t);
        var hb: [640]u8 = undefined;
        const hint = p.hintA(&hb, rows[p.sel]);
        _ = views.wrap(s, r.x + 1, hy, r.w -| 2, r.bottom(), hint.text, hint.style(t));
    }

    fn drawRowA(p: *Proto, s: *Screen, t: Theme, x: u16, y: u16, w: u16, row: RowA, sel: bool, name_w: u16) void {
        const base: Style = if (sel) selected(t) else .{};
        if (sel) s.fill(x, y, w, 1, base);
        const vx = x + 3 + name_w;
        const vw = (x + w) -| vx;
        switch (row) {
            .heading => |h| _ = s.print(x + 1, y, w -| 1, h, on(base, accent(t))),
            .keys_heading => |g| {
                var hb: [48]u8 = undefined;
                const h = std.fmt.bufPrint(&hb, "Keys · {s}", .{g.title()}) catch g.title();
                _ = s.print(x + 1, y, w -| 1, h, on(base, accent(t)));
            },
            .gap => {},
            .keep_alive => {
                if (p.keep_alive) marker(s, x + 1, y, base, t);
                _ = s.print(x + 3, y, name_w -| 1, "Keep the engine running", base);
                _ = s.print(vx, y, vw, if (p.keep_alive) "on" else "off", on(base, if (p.keep_alive) Style{ .fg = t.good, .bold = true } else Style{ .bold = true }));
            },
            .artwork => {
                _ = s.print(x + 3, y, name_w -| 1, "Artwork", base);
                var cx = vx;
                for ([_]Art{ .images, .blocks, .off }) |a| {
                    const cur = a == p.facts.showing;
                    const unavailable = a == .images and !p.facts.images_ok;
                    var lb: [32]u8 = undefined;
                    const label = std.fmt.bufPrint(&lb, "{s}{s}", .{ artName(a), if (unavailable) "?" else "" }) catch "";
                    const st: Style = if (cur) .{ .fg = t.accent, .bold = true, .underline = true } else if (unavailable) dim(t) else .{};
                    cx += s.print(cx, y, (x + w) -| cx, label, on(base, st)) + 2;
                }
            },
            .action => |i| {
                const a = actions[i];
                if (!isDefault(&p.live, i)) marker(s, x + 1, y, base, t);
                _ = s.print(x + 3, y, name_w -| 1, a.name, base);
                var kb: [96]u8 = undefined;
                var right: []const u8 = "";
                var db: [96]u8 = undefined;
                if (a.fixed) right = "fixed" else if (!isDefault(&p.live, i)) {
                    right = std.fmt.bufPrint(&db, "default {s}", .{if (a.defaults.len == 0) "none" else keysText(&kb, a.defaults, " ")}) catch "";
                }
                const right_w: u16 = @intCast(width.textWidth(right));
                const keys_w = vw -| (right_w + 2);
                switch (p.mode) {
                    .capture => |cap| if (cap.action == i) {
                        _ = s.print(vx, y, keys_w, if (cap.add) "press a key to add…" else "press a key…", on(base, accent(t)));
                    } else p.drawKeysA(s, t, vx, y, keys_w, i, base),
                    .conflict => |c| if (c.cap.action == i) {
                        var nb: [24]u8 = undefined;
                        var qb: [32]u8 = undefined;
                        _ = s.print(vx, y, keys_w, std.fmt.bufPrint(&qb, "{s}?", .{keyName(&nb, c.key)}) catch "?", on(base, .{ .fg = t.warn, .bold = true }));
                    } else p.drawKeysA(s, t, vx, y, keys_w, i, base),
                    else => p.drawKeysA(s, t, vx, y, keys_w, i, base),
                }
                if (right.len > 0) rightText(s, x + w -| 1, y, right_w, right, on(base, dim(t)));
            },
            .reset_all => {
                _ = s.print(x + 3, y, name_w -| 1, "Reset all keys to default", base);
                const n = changedCount(&p.live);
                var nb: [32]u8 = undefined;
                _ = s.print(vx, y, vw, if (n == 0) "nothing changed" else std.fmt.bufPrint(&nb, "{d} changed", .{n}) catch "", on(base, dim(t)));
            },
        }
    }

    fn drawKeysA(p: *Proto, s: *Screen, t: Theme, x: u16, y: u16, w: u16, i: usize, base: Style) void {
        const ks = p.live[i].slice();
        if (ks.len == 0) {
            _ = s.print(x, y, w, "no key", on(base, .{ .fg = t.bad }));
            return;
        }
        var kb: [96]u8 = undefined;
        _ = s.print(x, y, w, keysText(&kb, ks, "  "), on(base, .{ .bold = true }));
    }

    fn hintA(p: *Proto, buf: []u8, row: RowA) Hint {
        switch (p.mode) {
            .capture => |cap| return .{ .kind = .accent, .text = std.fmt.bufPrint(buf, "{s} “{s}”. Esc cancels.", .{ if (cap.add) "Press a key to add to" else "Press the key for", actions[cap.action].name }) catch "" },
            .conflict => |c| {
                var nb: [24]u8 = undefined;
                var kb: [64]u8 = undefined;
                var rest: KeySet = p.live[c.other];
                rest.remove(c.key);
                const left = keysText(&kb, rest.slice(), " ");
                return .{ .kind = .warn, .text = std.fmt.bufPrint(buf, "{s} is {s}'s key. Enter gives it to {s} ({s} {s}{s}) · any other key leaves it.", .{ keyName(&nb, c.key), actions[c.other].name, actions[c.cap.action].name, actions[c.other].name, if (left.len == 0) "is left with no key" else "keeps ", left }) catch "" };
            },
            .confirm_reset => {
                const n = changedCount(&p.live);
                return .{ .kind = .warn, .text = std.fmt.bufPrint(buf, "Enter again sets {d} changed key{s} back to default · any other key keeps them.", .{ n, plural(n) }) catch "" };
            },
            else => {},
        }
        return switch (row) {
            .keep_alive => .{ .text = "Enter turns it on or off, at once. On: the engine starts with am and stays up while am is open, so the first play is about 1.5 s sooner; it holds about 700 MiB and 0.5 % CPU all that time. Off (default): it starts on the first play and closes after 5 idle minutes." },
            .artwork => .{ .text = if (p.facts.images_ok) "Enter picks the next one, at once. v cycles them too." else "Enter picks the next one, at once. v cycles them too. images?: this terminal didn't answer am's image check when am started, so Enter skips them." },
            .action => |i| blk: {
                const a = actions[i];
                if (a.fixed) break :blk .{ .text = std.fmt.bufPrint(buf, "{s} is fixed: ^c always quits, ^z always suspends.", .{a.name}) catch "" };
                const where = if (a.ctx() == .typing) "Works while typing in search and filter." else "Works in lists, help and details.";
                break :blk .{ .text = std.fmt.bufPrint(buf, "Enter set the key · a add a key · d no key · u default.  {s}", .{where}) catch "" };
            },
            .reset_all => .{ .text = "Enter, then Enter again, sets every key back to its default." },
            else => .{ .text = "" },
        };
    }

    // ---- Variant B: the settings dialog ----

    fn unsaved(p: *const Proto) usize {
        var n: usize = 0;
        for (0..actions.len) |i| n += @intFromBool(!p.draft[i].same(p.live[i].slice()));
        n += @intFromBool(p.draft_keep_alive != p.keep_alive);
        n += @intFromBool(p.draft_art != p.art);
        return n;
    }

    fn save(p: *Proto) void {
        const n = p.unsaved();
        if (n == 0) return p.say("Nothing to save", .{});
        if (p.draft_art != p.art) p.art_changed = true;
        p.live = p.draft;
        p.keep_alive = p.draft_keep_alive;
        p.art = p.draft_art;
        p.say("Saved {d} change{s}; they apply now (prototype: nothing written, keep-alive not wired)", .{ n, plural(n) });
    }

    fn keyB(p: *Proto, k: Key) bool {
        switch (p.mode) {
            .capture => |cap| {
                p.mode = .{ .captured = .{ .cap = cap, .key = k } };
                return true;
            },
            .captured => |c| {
                if (k.code == .enter and !k.ctrl) {
                    if (refuse(c.cap.action, c.key) != null) return true;
                    if (find(&p.draft, actions[c.cap.action].ctx(), c.key, c.cap.action)) |other| {
                        if (actions[other].fixed) return true;
                        if (p.mustKeep(other) and p.draft[other].len == 1) return true;
                        p.draft[other].remove(c.key);
                    }
                    assign(&p.draft, c.cap, c.key);
                    p.mode = .browse;
                } else if (k.code == .backspace) {
                    p.mode = .{ .capture = c.cap };
                } else if (k.code == .esc) {
                    p.mode = .browse;
                }
                return true;
            },
            .confirm_reset => {
                if (k.eql(.char('y'))) p.draft = defaultBindings();
                p.mode = .browse;
                return true;
            },
            .confirm_discard => {
                if (k.eql(.char('y'))) {
                    p.close();
                    p.say("Discarded", .{});
                } else if (k.eql(.char('w'))) {
                    p.save();
                    p.close();
                } else p.mode = .browse;
                return true;
            },
            .finding => {
                if (printable(k) and k.code.char < 0x80) {
                    if (p.find_len < p.find_buf.len) {
                        p.find_buf[p.find_len] = @intCast(k.code.char);
                        p.find_len += 1;
                    }
                } else if (k.code == .backspace) {
                    p.find_len -|= 1;
                } else if (k.ctrl and k.code == .char and k.code.char == 'u') {
                    p.find_len = 0;
                } else if (k.code == .esc) {
                    p.find_len = 0;
                    p.mode = .browse;
                } else if (k.code == .enter or k.code == .down) {
                    p.mode = .browse;
                }
                var rb: [row_cap]RowB = undefined;
                p.sel = firstWhere(RowB, p.rowsB(&rb), selectableB);
                p.top = 0;
                p.chip = 0;
                return true;
            },
            else => {},
        }
        if (k.code == .tab) {
            return p.setTab(switch (p.tab) {
                .keys => if (k.shift) .artwork else .engine,
                .engine => if (k.shift) .keys else .artwork,
                .artwork => if (k.shift) .engine else .keys,
            });
        }
        if (k.eql(.char('1'))) return p.setTab(.keys);
        if (k.eql(.char('2'))) return p.setTab(.engine);
        if (k.eql(.char('3'))) return p.setTab(.artwork);
        if (k.eql(.char('w'))) {
            p.save();
            return true;
        }
        if (k.code == .esc) {
            if (p.unsaved() > 0) p.mode = .confirm_discard else p.close();
            return true;
        }
        switch (p.tab) {
            .keys => {
                var rb: [row_cap]RowB = undefined;
                const rows = p.rowsB(&rb);
                if (navOf(k)) |nv| {
                    p.sel = applyNav(RowB, rows, selectableB, p.sel, nv, p.height);
                    p.chip = 0;
                    return true;
                }
                if (k.eql(.char('/'))) {
                    p.mode = .finding;
                    return true;
                }
                if (k.eql(.char('U'))) {
                    if (changedCount(&p.draft) > 0) p.mode = .confirm_reset;
                    return true;
                }
                if (rows.len == 0) return true;
                const row = rows[@min(p.sel, rows.len - 1)];
                if (row != .action) return true;
                const i = row.action;
                const n = p.draft[i].len;
                const chips: usize = if (actions[i].fixed) n else n + @intFromBool(n < max_keys);
                if (k.code == .left or k.eql(.char('h'))) {
                    p.chip -|= 1;
                } else if (k.code == .right or k.eql(.char('l'))) {
                    p.chip = @min(p.chip + 1, chips -| 1);
                } else if (k.code == .enter) {
                    if (p.editable(i)) p.mode = .{ .capture = .{ .action = i, .add = p.chip >= n, .chip = if (p.chip < n) p.chip else null } };
                } else if (k.code == .delete or k.eql(.char('d'))) {
                    if (p.chip < n and p.editable(i)) {
                        if (p.mustKeep(i) and n == 1) {
                            p.say("{s} needs a key, or there'd be no way back here", .{actions[i].name});
                        } else {
                            p.draft[i].remove(p.draft[i].buf[p.chip]);
                            p.chip = @min(p.chip, p.draft[i].len);
                        }
                    }
                } else if (k.eql(.char('u'))) {
                    p.draft[i] = .of(actions[i].defaults);
                    p.chip = 0;
                }
                return true;
            },
            .engine => {
                if (navOf(k)) |nv| p.sel = switch (nv) {
                    .down, .bottom, .page_down => 1,
                    .up, .top, .page_up => 0,
                };
                if (k.code == .enter or k.eql(.char(' '))) p.draft_keep_alive = p.sel == 1;
                return true;
            },
            .artwork => {
                const opts = [_]Art{ .auto, .images, .blocks, .off };
                if (navOf(k)) |nv| p.sel = switch (nv) {
                    .down => @min(p.sel + 1, opts.len - 1),
                    .up => p.sel -| 1,
                    .bottom, .page_down => opts.len - 1,
                    .top, .page_up => 0,
                };
                if (k.code == .enter or k.eql(.char(' '))) p.draft_art = opts[@min(p.sel, opts.len - 1)];
                return true;
            },
        }
    }

    fn setTab(p: *Proto, tab: Tab) bool {
        p.tab = tab;
        p.top = 0;
        p.chip = 0;
        p.sel = switch (tab) {
            .keys => blk: {
                var rb: [row_cap]RowB = undefined;
                break :blk firstWhere(RowB, p.rowsB(&rb), selectableB);
            },
            .engine => @intFromBool(p.draft_keep_alive),
            .artwork => @backingInt(p.draft_art),
        };
        return true;
    }

    fn rowsB(p: *const Proto, buf: []RowB) []RowB {
        const needle = p.find_buf[0..p.find_len];
        var n: usize = 0;
        for (groups) |g| {
            var any = false;
            for (actions, 0..) |a, i| {
                if (a.group != g) continue;
                if (needle.len > 0 and std.ascii.findIgnoreCase(a.name, needle) == null) continue;
                if (!any) {
                    buf[n] = .{ .heading = g };
                    n += 1;
                    any = true;
                }
                buf[n] = .{ .action = i };
                n += 1;
            }
        }
        return buf[0..n];
    }

    fn drawB(p: *Proto, s: *Screen, t: Theme) void {
        const w: u16 = @min(s.cols -| 4, 112);
        const h: u16 = s.rows -| 2;
        const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows - h) / 2, .w = w, .h = h };
        box(s, r, t, "Settings");
        var x = r.x + 2;
        for ([_]struct { Tab, []const u8 }{ .{ .keys, "1 Keys" }, .{ .engine, "2 Engine" }, .{ .artwork, "3 Artwork" } }) |tb| {
            const cur = tb[0] == p.tab;
            x += s.print(x, r.y + 1, 20, tb[1], if (cur) .{ .fg = t.accent, .bold = true, .underline = true } else dim(t)) + 3;
        }
        const n = p.unsaved();
        var nb: [48]u8 = undefined;
        const status = if (n == 0) "no unsaved changes" else std.fmt.bufPrint(&nb, "{d} unsaved change{s}", .{ n, plural(n) }) catch "";
        rightText(s, r.right() -| 2, r.y + 1, w / 2, status, if (n == 0) dim(t) else .{ .fg = t.warn, .bold = true });
        rule(s, r.x + 1, r.y + 2, w -| 2, t);
        const body: Rect = .{ .x = r.x + 2, .y = r.y + 3, .w = w -| 4, .h = h -| 5 };
        switch (p.tab) {
            .keys => p.drawBKeys(s, t, body),
            .engine => p.drawBEngine(s, t, body),
            .artwork => p.drawBArt(s, t, body),
        }
        const hint = switch (p.tab) {
            .keys => "← → pick a key · Enter change (on [+]: add) · d remove · u row default · U all defaults · / find",
            .engine, .artwork => "j k move · Enter choose",
        };
        _ = s.print(r.x + 2, r.bottom() -| 2, w -| 4, hint, dim(t));
        _ = s.print(r.x + 2, r.bottom() -| 1, w -| 4, " w save · Esc close · Tab next tab ", dim(t));
        switch (p.mode) {
            .capture, .captured => p.drawCaptureB(s, t),
            .confirm_reset => {
                var cb: [96]u8 = undefined;
                const c = changedCount(&p.draft);
                confirmBox(s, t, "Reset keys", std.fmt.bufPrint(&cb, "Set all {d} changed key{s} back to default?", .{ c, plural(c) }) catch "", "y yes · any other key no");
            },
            .confirm_discard => {
                var cb: [96]u8 = undefined;
                confirmBox(s, t, "Unsaved changes", std.fmt.bufPrint(&cb, "Discard {d} unsaved change{s}?", .{ n, plural(n) }) catch "", "y discard · w save · any other key keeps editing");
            },
            else => {},
        }
    }

    fn drawBKeys(p: *Proto, s: *Screen, t: Theme, r: Rect) void {
        var y = r.y;
        const needle = p.find_buf[0..p.find_len];
        if (p.mode == .finding) {
            _ = s.print(r.x, y, 7, "Find: ", .{ .fg = t.accent, .bold = true });
            const used = s.print(r.x + 6, y, r.w -| 6, needle, .{});
            s.showCursor(r.x + 6 + used, y);
        } else if (needle.len > 0) {
            var fb: [64]u8 = undefined;
            _ = s.print(r.x, y, r.w, std.fmt.bufPrint(&fb, "Find: {s}   (/ edits, Esc there clears)", .{needle}) catch "", dim(t));
        } else _ = s.print(r.x, y, r.w, "/ find an action", dim(t));
        y += 2;
        const name_w: u16 = 34;
        const keys_x = r.x + 2 + name_w;
        const keys_w: u16 = 32;
        const def_x = keys_x + keys_w;
        const def_w: u16 = 20;
        const where_x = def_x + def_w;
        const show_def = def_x + 8 < r.right();
        const show_where = where_x + 6 < r.right();
        _ = s.print(r.x + 2, y, name_w, "Action", dim(t));
        _ = s.print(keys_x, y, keys_w, "Keys", dim(t));
        if (show_def) _ = s.print(def_x, y, def_w, "Default", dim(t));
        if (show_where) _ = s.print(where_x, y, r.right() -| where_x, "Where", dim(t));
        y += 1;
        var rb: [row_cap]RowB = undefined;
        const rows = p.rowsB(&rb);
        const list_h: usize = r.bottom() -| y;
        p.height = @max(1, list_h);
        if (rows.len == 0) {
            _ = s.print(r.x + 2, y, r.w, "No action matches.", dim(t));
            return;
        }
        p.sel = @min(p.sel, rows.len - 1);
        p.top = layout.scroll(p.sel, p.top, list_h, rows.len, 2);
        for (rows[p.top..], p.top..) |row, idx| {
            if (y >= r.bottom()) break;
            defer y += 1;
            switch (row) {
                .heading => |g| _ = s.print(r.x, y, r.w, g.title(), accent(t)),
                .action => |i| {
                    const a = actions[i];
                    const sel = idx == p.sel;
                    const base: Style = if (sel) selected(t) else .{};
                    if (sel) s.fill(r.x, y, r.w, 1, base);
                    const unsaved_row = !p.draft[i].same(p.live[i].slice());
                    if (unsaved_row) {
                        _ = s.print(r.x, y, 1, "*", on(base, .{ .fg = t.warn, .bold = true }));
                    } else if (!isDefault(&p.draft, i)) marker(s, r.x, y, base, t);
                    _ = s.print(r.x + 2, y, name_w -| 1, a.name, base);
                    var cx = keys_x;
                    const ks = p.draft[i].slice();
                    for (ks, 0..) |kk, j| {
                        var nb: [24]u8 = undefined;
                        var cb: [32]u8 = undefined;
                        const chip = std.fmt.bufPrint(&cb, "[{s}]", .{keyName(&nb, kk)}) catch "";
                        const st: Style = if (sel and p.chip == j and !a.fixed) .{ .fg = t.accent, .bold = true, .reverse = true } else on(base, .{ .bold = true });
                        cx += s.print(cx, y, (keys_x + keys_w) -| cx, chip, st) + 1;
                    }
                    if (a.fixed) {
                        _ = s.print(cx, y, (keys_x + keys_w) -| cx, "fixed", on(base, dim(t)));
                    } else if (ks.len < max_keys) {
                        const st: Style = if (sel and p.chip == ks.len) .{ .fg = t.accent, .bold = true, .reverse = true } else on(base, dim(t));
                        cx += s.print(cx, y, (keys_x + keys_w) -| cx, "[+]", st) + 1;
                        if (ks.len == 0 and !sel) _ = s.print(cx, y, (keys_x + keys_w) -| cx, "no key", on(base, .{ .fg = t.bad }));
                    }
                    if (show_def) {
                        var kb: [64]u8 = undefined;
                        _ = s.print(def_x, y, def_w -| 1, if (a.defaults.len == 0) "none" else keysText(&kb, a.defaults, " "), on(base, dim(t)));
                    }
                    if (show_where) _ = s.print(where_x, y, r.right() -| where_x, if (a.ctx() == .typing) "typing" else "lists", on(base, dim(t)));
                },
            }
        }
    }

    fn drawBEngine(p: *Proto, s: *Screen, t: Theme, r: Rect) void {
        var y = r.y;
        _ = s.print(r.x, y, r.w, "The engine is the hidden browser that plays the music.", dim(t));
        y += 2;
        const opts = [_][]const u8{ "Start it when needed, close it after 5 idle minutes", "Keep it running while am is open" };
        for (opts, 0..) |label, i| {
            const sel = p.sel == i;
            const base: Style = if (sel) selected(t) else .{};
            if (sel) s.fill(r.x, y, r.w, 1, base);
            const chosen = p.draft_keep_alive == (i == 1);
            var x = r.x + 1;
            x += s.print(x, y, 4, if (chosen) "(•)" else "( )", on(base, if (chosen) accent(t) else Style{})) + 1;
            x += s.print(x, y, r.right() -| x, label, base) + 2;
            if (i == 0) _ = s.print(x, y, r.right() -| x, "default", on(base, dim(t)));
            y += 1;
        }
        y += 1;
        y = views.wrap(s, r.x + 1, y, r.w -| 2, r.bottom(), "Keeping it running: the first play after opening am starts about 1.5 s sooner (1.6 s instead of 4 s, measured on a Mac). The engine then holds about 700 MiB of memory and 0.5 % CPU for as long as am is open, and in a two-hour test its memory grew by 1 to 2 MiB a minute.", dim(t));
        y += 1;
        _ = views.wrap(s, r.x + 1, y, r.w -| 2, r.bottom(), "Applies when you save: on starts the engine at once; off lets it close after 5 idle minutes.", .{});
    }

    fn drawBArt(p: *Proto, s: *Screen, t: Theme, r: Rect) void {
        var y = r.y;
        _ = s.print(r.x, y, r.w, "Album art in the now-playing pane and on album and playlist pages.", dim(t));
        y += 2;
        const opts = [_]struct { Art, []const u8 }{
            .{ .auto, "Auto: images if this terminal shows them, else blocks" },
            .{ .images, "Images (kitty graphics)" },
            .{ .blocks, "Blocks (half-block characters, any color terminal)" },
            .{ .off, "Off" },
        };
        for (opts, 0..) |o, i| {
            const sel = p.sel == i;
            const base: Style = if (sel) selected(t) else .{};
            if (sel) s.fill(r.x, y, r.w, 1, base);
            const chosen = p.draft_art == o[0];
            var x = r.x + 1;
            x += s.print(x, y, 4, if (chosen) "(•)" else "( )", on(base, if (chosen) accent(t) else Style{})) + 1;
            x += s.print(x, y, r.right() -| x, o[1], base) + 2;
            switch (o[0]) {
                .auto => _ = s.print(x, y, r.right() -| x, "default", on(base, dim(t))),
                .images => _ = s.print(x, y, r.right() -| x, if (p.facts.images_ok) "this terminal: yes" else "this terminal didn't answer the image check", on(base, if (p.facts.images_ok) Style{ .fg = t.good } else Style{ .fg = t.warn })),
                else => {},
            }
            y += 1;
        }
        y += 1;
        var sb: [160]u8 = undefined;
        _ = views.wrap(s, r.x + 1, y, r.w -| 2, r.bottom(), std.fmt.bufPrint(&sb, "Showing now: {s}. Applies when you save. v still cycles images, blocks and off, for this session only.", .{artName(p.facts.showing)}) catch "", dim(t));
    }

    fn drawCaptureB(p: *Proto, s: *Screen, t: Theme) void {
        const cap = switch (p.mode) {
            .capture => |c| c,
            .captured => |c| c.cap,
            else => return,
        };
        const a = actions[cap.action];
        const w: u16 = @min(s.cols -| 8, 68);
        const h: u16 = 9;
        const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows -| h) / 2, .w = w, .h = h };
        box(s, r, t, if (cap.add) "Add a key" else "Change a key");
        const x = r.x + 2;
        const iw = w -| 4;
        var used = s.print(x, r.y + 1, iw, a.name, .{ .bold = true });
        _ = s.print(x + used, r.y + 1, iw -| used, if (a.ctx() == .typing) " · in search and filter" else " · in lists, help and details", dim(t));
        var kb: [64]u8 = undefined;
        var nb: [80]u8 = undefined;
        _ = s.print(x, r.y + 2, iw, std.fmt.bufPrint(&nb, "now: {s}", .{if (p.draft[cap.action].len == 0) "no key" else keysText(&kb, p.draft[cap.action].slice(), " ")}) catch "", dim(t));
        switch (p.mode) {
            .capture => {
                _ = s.print(x, r.y + 4, iw, "Press the new key. Any key works, Esc and Enter too.", .{});
                _ = s.print(x, r.y + h - 1, iw, " ^c cancels ", dim(t));
            },
            .captured => |c| {
                var kn: [24]u8 = undefined;
                used = s.print(x, r.y + 4, iw, "New key: ", .{});
                _ = s.print(x + used, r.y + 4, iw -| used, keyName(&kn, c.key), .{ .fg = t.accent, .bold = true });
                var mb: [160]u8 = undefined;
                var ok = true;
                if (refuse(cap.action, c.key)) |why| {
                    ok = false;
                    _ = s.print(x, r.y + 5, iw, why, .{ .fg = t.bad });
                } else if (find(&p.draft, a.ctx(), c.key, cap.action)) |other| {
                    var rest: KeySet = p.draft[other];
                    rest.remove(c.key);
                    var rb: [64]u8 = undefined;
                    const left = keysText(&rb, rest.slice(), " ");
                    if (actions[other].fixed or (p.mustKeep(other) and rest.len == 0)) {
                        ok = false;
                        _ = s.print(x, r.y + 5, iw, std.fmt.bufPrint(&mb, "It's {s}'s, which keeps it.", .{actions[other].name}) catch "", .{ .fg = t.bad });
                    } else {
                        _ = s.print(x, r.y + 5, iw, std.fmt.bufPrint(&mb, "It's {s}'s now. Taking it leaves {s} {s}{s}.", .{ actions[other].name, actions[other].name, if (left.len == 0) "with no key" else "with ", left }) catch "", .{ .fg = t.warn });
                    }
                } else _ = s.print(x, r.y + 5, iw, "No other action uses it.", .{ .fg = t.good });
                _ = s.print(x, r.y + h - 1, iw, if (ok) " Enter use it · Backspace try another · Esc cancel " else " Backspace try another · Esc cancel ", dim(t));
            },
            else => {},
        }
    }

    // ---- Variant C: editable help ----

    fn keyC(p: *Proto, k: Key) bool {
        switch (p.mode) {
            .capture => |cap| {
                if (k.code == .esc and !k.ctrl and !k.alt) {
                    p.mode = .browse;
                    p.note_len = 0;
                    return true;
                }
                p.bindNow(cap, k, .steal);
                return true;
            },
            else => {},
        }
        var lb: [row_cap]LineC = undefined;
        const lines = linesC(&lb);
        if (navOf(k)) |nv| {
            p.note_len = 0;
            p.sel = applyNav(LineC, lines, selectableC, p.sel, nv, p.height);
            return true;
        }
        if (isBack(k)) {
            p.close();
            return true;
        }
        // q quits, as from today's help.
        if (k.eql(.char('q'))) return false;
        p.note_len = 0;
        if (k.eql(.char('z'))) {
            if (p.undo) |u| {
                p.live = u;
                p.undo = null;
                p.setNote("Undone", .{});
            } else p.setNote("Nothing to undo", .{});
            return true;
        }
        if (k.eql(.char('U'))) {
            const n = changedCount(&p.live);
            if (n == 0) return p.noted("Every key is already the default");
            p.undo = p.live;
            p.live = defaultBindings();
            p.setNote("{d} key{s} back to default · z undo", .{ n, plural(n) });
            return true;
        }
        const enter = k.code == .enter and !k.ctrl;
        switch (lines[@min(p.sel, lines.len - 1)]) {
            .keep_alive => if (enter or k.eql(.char(' '))) {
                p.keep_alive = !p.keep_alive;
                p.setNote("{s} (prototype: not wired)", .{if (p.keep_alive) "Keep-alive on: the engine would start now and stay up while am is open" else "Keep-alive off: the engine would close after 5 idle minutes"});
            },
            .artwork => if (enter or k.eql(.char(' '))) {
                p.art = nextArt(p.facts.showing, p.facts.images_ok);
                p.art_changed = true;
                p.setNote("Artwork: {s}", .{artName(p.art)});
            },
            .action => |i| {
                if (enter) {
                    if (p.editable(i)) p.mode = .{ .capture = .{ .action = i } } else p.setNote("{s} is fixed", .{actions[i].name});
                } else if (k.eql(.char('+')) or k.eql(.char('a'))) {
                    if (p.editable(i)) p.mode = .{ .capture = .{ .action = i, .add = true } } else p.setNote("{s} is fixed", .{actions[i].name});
                } else if (k.eql(.char('d')) or k.code == .delete) {
                    const before = p.live;
                    if (p.unbind(&p.live, i)) {
                        p.undo = before;
                        p.setNote("{s}: no key now · z undo", .{actions[i].name});
                    }
                } else if (k.eql(.char('u'))) {
                    p.undo = p.live;
                    p.live[i] = .of(actions[i].defaults);
                    p.setNote("{s}: default again · z undo", .{actions[i].name});
                }
            },
            else => {},
        }
        return true;
    }

    fn noted(p: *Proto, text: []const u8) bool {
        p.setNote("{s}", .{text});
        return true;
    }

    fn drawC(p: *Proto, s: *Screen, t: Theme) void {
        var lb: [row_cap]LineC = undefined;
        const lines = linesC(&lb);
        const split = splitC(lines);
        const key_w: u16 = 14;
        const what_w: u16 = 34;
        const col_w = key_w + what_w;
        const two = s.cols >= col_w * 2 + 10;
        const left_n = if (two) split else lines.len;
        const right_n = if (two) lines.len - split else 0;
        const need = @max(left_n, right_n);
        const w: u16 = @min(s.cols -| 4, if (two) col_w * 2 + 8 else col_w + 4);
        const h: u16 = @intCast(@min(s.rows -| 2, need + 3));
        const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows - h) / 2, .w = w, .h = h };
        box(s, r, t, "Keys and settings");
        _ = s.print(r.x + 2, r.y + 1, w -| 4, "Enter changes the line under the cursor, at once.", dim(t));
        const room: usize = h -| 3;
        p.height = @max(1, room);
        p.sel = @min(p.sel, lines.len - 1);
        // Keep the cursor's line on screen; both columns scroll together.
        const cur_row = if (two and p.sel >= split) p.sel - split else p.sel;
        if (cur_row < p.top) p.top = cur_row;
        if (cur_row >= p.top + room) p.top = cur_row + 1 - room;
        for (lines, 0..) |line, idx| {
            const col: u16 = if (two and idx >= split) 1 else 0;
            const row = if (col == 1) idx - split else idx;
            if (row < p.top or row - p.top >= room) continue;
            const y: u16 = r.y + 2 + @as(u16, @intCast(row - p.top));
            const x: u16 = if (col == 0) r.x + 2 else r.x + 6 + col_w;
            p.drawLineC(s, t, x, y, col_w, key_w, line, idx == p.sel);
        }
        var hb: [200]u8 = undefined;
        const bottom = switch (p.mode) {
            .capture => |cap| std.fmt.bufPrint(&hb, " Press the key for {s} · Esc cancels ", .{actions[cap.action].name}) catch "",
            else => if (p.note_len > 0) std.fmt.bufPrint(&hb, " {s} ", .{p.note()}) catch "" else " Enter change · + add · d remove · u default · U all defaults · z undo · Esc close ",
        };
        const busy = p.mode == .capture or p.note_len > 0;
        _ = s.print(r.x + 2, r.bottom() -| 1, w -| 4, bottom, if (busy) Style{ .fg = t.accent, .bold = true } else dim(t));
    }

    fn drawLineC(p: *Proto, s: *Screen, t: Theme, x: u16, y: u16, col_w: u16, key_w: u16, line: LineC, sel: bool) void {
        const base: Style = if (sel) selected(t) else .{};
        if (sel and line != .heading and line != .gap) s.fill(x -| 1, y, col_w + 1, 1, base);
        const kx = x + 2;
        const kw = key_w -| 3;
        const wx = x + key_w;
        const ww = col_w -| key_w;
        switch (line) {
            .heading => |h| _ = s.print(x, y, col_w, h, accent(t)),
            .gap => {},
            .keep_alive => {
                if (p.keep_alive) marker(s, x, y, base, t);
                _ = s.print(kx, y, kw, if (p.keep_alive) "on" else "off", on(base, accent(t)));
                _ = s.print(wx, y, ww, "keep the engine running while am is open", base);
            },
            .artwork => {
                _ = s.print(kx, y, kw, artName(p.facts.showing), on(base, accent(t)));
                _ = s.print(wx, y, ww, if (p.facts.images_ok) "artwork (v cycles it too)" else "artwork (images: not detected)", base);
            },
            .action => |i| {
                const a = actions[i];
                if (!isDefault(&p.live, i)) marker(s, x, y, base, t);
                const capturing = switch (p.mode) {
                    .capture => |c| c.action == i,
                    else => false,
                };
                const ks = p.live[i].slice();
                var kb: [64]u8 = undefined;
                if (capturing) {
                    _ = s.print(kx, y, kw, "press a key", on(base, .{ .fg = t.accent, .bold = true }));
                } else if (ks.len == 0) {
                    _ = s.print(kx, y, kw, "no key", on(base, .{ .fg = t.bad }));
                } else _ = s.print(kx, y, kw, keysText(&kb, ks, " "), on(base, .{ .bold = true }));
                const used = s.print(wx, y, ww, a.name, base);
                if (a.fixed) _ = s.print(wx + used, y, ww -| used, " (fixed)", on(base, dim(t)));
            },
        }
    }

    // ---- For the app ----

    /// B and C, over everything (after the overlays).
    pub fn drawModal(p: *Proto, s: *Screen, t: Theme) void {
        if (!p.open) return;
        switch (p.variant) {
            .a => {},
            .b => p.drawB(s, t),
            .c => p.drawC(s, t),
        }
    }

    /// Which prototype this is, at the right of the status line.
    pub fn drawPill(p: *const Proto, s: *Screen, t: Theme, r: Rect) void {
        var kb: [24]u8 = undefined;
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " PROTOTYPE {s} · {s} opens · {{ }} switch ", .{ p.variant.name(), p.opener(&kb) }) catch return;
        const tw: u16 = @intCast(width.textWidth(text));
        if (tw + 2 > r.w) return;
        _ = s.print(r.right() - tw, r.y, tw, text, .{ .fg = t.warn, .reverse = true, .bold = true });
    }
};

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn assign(b: *Bindings, cap: Capture, k: Key) void {
    const s = &b[cap.action];
    if (cap.chip) |c| if (c < s.len) {
        if (!s.has(k)) s.buf[c] = k;
        return;
    };
    if (cap.add or cap.chip != null) return s.add(k);
    s.* = .of(&.{k});
}

fn nextArt(showing: Art, images_ok: bool) Art {
    return switch (showing) {
        .images => .blocks,
        .blocks => .off,
        .off, .auto => if (images_ok) .images else .blocks,
    };
}

// ---- Rows ----

const RowA = union(enum) { heading: []const u8, keys_heading: Group, gap, keep_alive, artwork, action: usize, reset_all };

fn rowsA(buf: []RowA) []RowA {
    var n: usize = 0;
    const put = struct {
        fn f(b: []RowA, i: *usize, r: RowA) void {
            b[i.*] = r;
            i.* += 1;
        }
    }.f;
    put(buf, &n, .{ .heading = "Engine" });
    put(buf, &n, .keep_alive);
    put(buf, &n, .gap);
    put(buf, &n, .{ .heading = "Artwork" });
    put(buf, &n, .artwork);
    for (groups) |g| {
        put(buf, &n, .gap);
        put(buf, &n, .{ .keys_heading = g });
        for (actions, 0..) |a, i| if (a.group == g) put(buf, &n, .{ .action = i });
    }
    put(buf, &n, .gap);
    put(buf, &n, .reset_all);
    return buf[0..n];
}

fn selectableA(r: RowA) bool {
    return switch (r) {
        .heading, .keys_heading, .gap => false,
        else => true,
    };
}

const RowB = union(enum) { heading: Group, action: usize };

fn selectableB(r: RowB) bool {
    return r == .action;
}

const LineC = union(enum) { heading: []const u8, gap, action: usize, keep_alive, artwork };

/// Column one: Move, Sections, Library; column two: Play, App, typing, and the settings.
const c_order = [_]Group{ .move, .sections, .library, .play, .app, .typing };

fn linesC(buf: []LineC) []LineC {
    var n: usize = 0;
    for (c_order, 0..) |g, gi| {
        if (gi != 0 and gi != 3) {
            buf[n] = .gap;
            n += 1;
        }
        buf[n] = .{ .heading = g.title() };
        n += 1;
        for (actions, 0..) |a, i| if (a.group == g) {
            buf[n] = .{ .action = i };
            n += 1;
        };
    }
    buf[n] = .gap;
    buf[n + 1] = .{ .heading = "Settings" };
    buf[n + 2] = .keep_alive;
    buf[n + 3] = .artwork;
    return buf[0 .. n + 4];
}

/// Where column two starts: the Play heading.
fn splitC(lines: []const LineC) usize {
    for (lines, 0..) |l, i| if (l == .heading and std.mem.eql(u8, l.heading, Group.play.title())) return i;
    return lines.len;
}

fn selectableC(l: LineC) bool {
    return switch (l) {
        .heading, .gap => false,
        else => true,
    };
}

fn firstWhere(comptime T: type, rows: []const T, comptime ok: fn (T) bool) usize {
    for (rows, 0..) |r, i| if (ok(r)) return i;
    return 0;
}

const Nav = enum { down, up, top, bottom, page_down, page_up };

/// The settings screens' own movement keys: fixed, so rebinding can't lock you out of them.
fn navOf(k: Key) ?Nav {
    if (k.ctrl) return switch (k.code) {
        .char => |c| switch (c) {
            'n' => .down,
            'p' => .up,
            'd' => .page_down,
            'u' => .page_up,
            else => null,
        },
        else => null,
    };
    return switch (k.code) {
        .down => .down,
        .up => .up,
        .home => .top,
        .end => .bottom,
        .page_down => .page_down,
        .page_up => .page_up,
        .char => |c| switch (c) {
            'j' => .down,
            'k' => .up,
            'g' => .top,
            'G' => .bottom,
            else => null,
        },
        else => null,
    };
}

fn isBack(k: Key) bool {
    return !k.ctrl and !k.alt and (k.code == .esc or k.code == .backspace);
}

fn applyNav(comptime T: type, rows: []const T, comptime ok: fn (T) bool, sel: usize, nv: Nav, height: usize) usize {
    const page: i32 = @intCast(@max(1, height -| 1));
    return switch (nv) {
        .down => stepSel(T, rows, ok, sel, 1),
        .up => stepSel(T, rows, ok, sel, -1),
        .page_down => stepSel(T, rows, ok, sel, page),
        .page_up => stepSel(T, rows, ok, sel, -page),
        .top => firstWhere(T, rows, ok),
        .bottom => blk: {
            var i = rows.len;
            while (i > 0) {
                i -= 1;
                if (ok(rows[i])) break :blk i;
            }
            break :blk sel;
        },
    };
}

fn stepSel(comptime T: type, rows: []const T, comptime ok: fn (T) bool, sel: usize, n: i32) usize {
    var s = sel;
    var left = n;
    while (left != 0) {
        const dir: i64 = if (left > 0) 1 else -1;
        var j: i64 = @as(i64, @intCast(s)) + dir;
        while (j >= 0 and j < rows.len and !ok(rows[@intCast(j)])) j += dir;
        if (j < 0 or j >= rows.len) break;
        s = @intCast(j);
        left -= @intCast(dir);
    }
    return s;
}

// ---- Drawing helpers ----

const Hint = struct {
    text: []const u8,
    kind: enum { plain, accent, warn } = .plain,

    fn style(h: Hint, t: Theme) Style {
        return switch (h.kind) {
            .plain => dim(t),
            .accent => .{ .fg = t.accent, .bold = true },
            .warn => .{ .fg = t.warn, .bold = true },
        };
    }
};

fn dim(t: Theme) Style {
    if (t.mode == .none) return .{ .dim = true };
    return .{ .fg = t.muted };
}

fn accent(t: Theme) Style {
    return .{ .fg = t.accent, .bold = true };
}

fn selected(t: Theme) Style {
    if (t.mode == .ansi16 or t.mode == .none) return .{ .reverse = true };
    return .{ .bg = t.sel_bg, .bold = true };
}

/// `st` on the selection's background.
fn on(base: Style, st: Style) Style {
    var out = st;
    out.bg = base.bg;
    out.reverse = out.reverse or base.reverse;
    return out;
}

fn marker(s: *Screen, x: u16, y: u16, base: Style, t: Theme) void {
    _ = s.print(x, y, 1, "•", on(base, .{ .fg = t.accent, .bold = true }));
}

fn rightText(s: *Screen, right: u16, y: u16, max_w: u16, text: []const u8, st: Style) void {
    const tw: u16 = @intCast(@min(width.textWidth(text), max_w));
    if (tw == 0 or tw > right) return;
    _ = s.print(right - tw, y, tw, text, st);
}

fn rule(s: *Screen, x: u16, y: u16, w: u16, t: Theme) void {
    var i: u16 = 0;
    while (i < w) : (i += 1) s.put(x + i, y, "─", 1, .{ .fg = t.rule });
}

fn box(s: *Screen, r: Rect, t: Theme, title: []const u8) void {
    const st: Style = .{ .fg = t.rule };
    s.fill(r.x, r.y, r.w, r.h, .{});
    s.put(r.x, r.y, "╭", 1, st);
    s.put(r.right() - 1, r.y, "╮", 1, st);
    s.put(r.x, r.bottom() - 1, "╰", 1, st);
    s.put(r.right() - 1, r.bottom() - 1, "╯", 1, st);
    var i: u16 = 1;
    while (i + 1 < r.w) : (i += 1) {
        s.put(r.x + i, r.y, "─", 1, st);
        s.put(r.x + i, r.bottom() - 1, "─", 1, st);
    }
    var j: u16 = 1;
    while (j + 1 < r.h) : (j += 1) {
        s.put(r.x, r.y + j, "│", 1, st);
        s.put(r.right() - 1, r.y + j, "│", 1, st);
    }
    _ = s.print(r.x + 2, r.y, 1, " ", .{});
    const tw = s.print(r.x + 3, r.y, r.w -| 6, title, .{ .fg = t.accent, .bold = true });
    _ = s.print(r.x + 3 + tw, r.y, 1, " ", .{});
}

fn confirmBox(s: *Screen, t: Theme, title: []const u8, question: []const u8, choices: []const u8) void {
    const w: u16 = @min(s.cols -| 8, 60);
    const h: u16 = 5;
    const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows -| h) / 2, .w = w, .h = h };
    box(s, r, t, title);
    _ = s.print(r.x + 2, r.y + 1, w -| 4, question, .{ .bold = true });
    _ = s.print(r.x + 2, r.y + 3, w -| 4, choices, dim(t));
}

// ---- Snapshots (`zig build test -Dtest-filter=PROTOTYPE 2>&1`) ----

const testing = std.testing;

test "PROTOTYPE rebinding is live: a key moves, the old one stops, defaults come back" {
    var p: Proto = .init(.a);
    try testing.expect(p.key(.char(','), false));
    try testing.expect(p.pageOpen());
    // Shuffle to x.
    var rb: [row_cap]RowA = undefined;
    p.sel = rowIndexA(rowsA(&rb), "Shuffle");
    try testing.expect(p.key(.{ .code = .enter }, false));
    try testing.expect(p.key(.char('x'), false));
    try testing.expectEqual(Do{ .list = .shuffle }, p.command(.char('x')).?);
    try testing.expect(p.command(.char('s')) == null);
    // n for Play / pause asks first, then takes it from Next (which keeps >).
    p.sel = rowIndexA(rowsA(&rb), "Play / pause");
    _ = p.key(.{ .code = .enter }, false);
    _ = p.key(.char('n'), false);
    try testing.expect(p.mode == .conflict);
    _ = p.key(.{ .code = .enter }, false);
    try testing.expectEqual(Do{ .list = .toggle }, p.command(.char('n')).?);
    try testing.expectEqual(Do{ .list = .next }, p.command(.char('>')).?);
    try testing.expectEqual(@as(usize, 3), changedCount(&p.live));
    // Text fields keep typing letters, whatever the bindings.
    try testing.expectEqual(keys.TextCommand{ .insert = 'x' }, p.textCommand(.char('x')).?);
    // Settings can't lose its last key.
    p.sel = rowIndexA(rowsA(&rb), "Settings");
    _ = p.key(.char('d'), false);
    try testing.expectEqual(@as(u8, 1), p.live[settings_action].len);
}

fn rowIndexA(rows: []const RowA, name: []const u8) usize {
    for (rows, 0..) |r, i| if (r == .action and std.mem.eql(u8, actions[r.action].name, name)) return i;
    unreachable;
}

fn rowIndexB(rows: []const RowB, name: []const u8) usize {
    for (rows, 0..) |r, i| if (r == .action and std.mem.eql(u8, actions[r.action].name, name)) return i;
    unreachable;
}

fn lineIndexC(lines: []const LineC, name: []const u8) usize {
    for (lines, 0..) |l, i| if (l == .action and std.mem.eql(u8, actions[l.action].name, name)) return i;
    unreachable;
}

const Shooter = struct {
    s: Screen,
    u: @import("ui.zig").Ui,
    m: @import("auth.zig").Machine = .{},
    slots: std.ArrayList(views.ImageSlot) = .empty,

    fn shoot(sh: *Shooter, p: *Proto, title: []const u8) !void {
        const gpa = testing.allocator;
        var lb: [24]u8 = undefined;
        var f: views.Frame = .{
            .ui = &sh.u,
            .auth = &sh.m,
            .player = null,
            .now_ns = 0,
            .now_ms = 0,
            .color = .ansi256,
            .images = true,
            .slots = &sh.slots,
            .gpa = gpa,
            .storefront = "us",
            .daemon_up = true,
            .proto_page = p.pageOpen(),
            .proto_sidebar = p.sidebarLabel(&lb),
        };
        sh.slots.clearRetainingCapacity();
        views.draw(&sh.s, &f);
        const l = layout.compute(sh.s.cols, sh.s.rows);
        const t = views.theme(.ansi256, null);
        p.drawPage(&sh.s, t, l.main);
        views.drawOverlays(&sh.s, &f);
        p.drawModal(&sh.s, t);
        p.drawPill(&sh.s, t, l.status);
        sh.u.effectsDone();
        std.debug.print("\n#### {s}\n\n```\n", .{title});
        for (0..sh.s.rows) |y| {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(gpa);
            for (0..sh.s.cols) |x| {
                const c = sh.s.cell(@intCast(x), @intCast(y));
                if (c.width == 0) continue;
                try line.appendSlice(gpa, c.text());
            }
            std.debug.print("{s}\n", .{std.mem.trimEnd(u8, line.items, " ")});
        }
        std.debug.print("```\n", .{});
    }
};

test "PROTOTYPE snapshots of the three variants" {
    const gpa = testing.allocator;
    var sh: Shooter = .{ .s = try .init(gpa, 120, 34), .u = .init(gpa) };
    defer sh.s.deinit();
    defer sh.u.deinit();
    defer sh.slots.deinit(gpa);
    sh.m.phase = .ready;
    sh.m.in_session = true;
    const facts: Facts = .{ .showing = .blocks, .images_ok = false };

    // A: the page.
    var a: Proto = .init(.a);
    a.facts = facts;
    _ = a.key(.char(','), false);
    try sh.shoot(&a, "A settings page: opened with `,` (the Settings entry sits under Up Next)");
    var rb: [row_cap]RowA = undefined;
    a.sel = rowIndexA(rowsA(&rb), "Shuffle");
    _ = a.key(.{ .code = .enter }, false);
    try sh.shoot(&a, "A: Enter on Shuffle waits for a key");
    _ = a.key(.char('x'), false);
    a.sel = rowIndexA(rowsA(&rb), "Play / pause");
    _ = a.key(.{ .code = .enter }, false);
    _ = a.key(.char('n'), false);
    try sh.shoot(&a, "A: Shuffle is now x; n for Play / pause belongs to Next, so it asks");
    _ = a.key(.{ .code = .enter }, false);
    _ = a.key(.char('G'), false);
    _ = a.key(.{ .code = .enter }, false);
    try sh.shoot(&a, "A: after taking n; Reset all asks once more");

    // B: the dialog.
    var b: Proto = .init(.b);
    b.facts = facts;
    _ = b.key(.char(','), false);
    var bb: [row_cap]RowB = undefined;
    b.sel = rowIndexB(b.rowsB(&bb), "Shuffle");
    _ = b.key(.{ .code = .enter }, false);
    _ = b.key(.char('n'), false);
    try sh.shoot(&b, "B settings dialog: Enter on Shuffle's [s] chip, then n: it says whose key it is");
    _ = b.key(.{ .code = .enter }, false);
    b.sel = rowIndexB(b.rowsB(&bb), "Next");
    try sh.shoot(&b, "B: n moved to Shuffle in the draft (* = unsaved); nothing applies until w");
    _ = b.key(.char('/'), false);
    for ("vol") |c| _ = b.key(.char(c), false);
    try sh.shoot(&b, "B: / finds actions by name");
    _ = b.key(.{ .code = .esc }, false);
    _ = b.key(.{ .code = .tab }, false);
    _ = b.key(.char('j'), false);
    _ = b.key(.{ .code = .enter }, false);
    try sh.shoot(&b, "B: the Engine tab, keep-alive picked (unsaved)");
    _ = b.key(.{ .code = .tab }, false);
    try sh.shoot(&b, "B: the Artwork tab");
    _ = b.key(.{ .code = .esc }, false);
    try sh.shoot(&b, "B: Esc with unsaved changes asks");

    // C: editable help.
    var c: Proto = .init(.c);
    c.facts = facts;
    _ = c.key(.char('?'), false);
    var cb: [row_cap]LineC = undefined;
    c.sel = lineIndexC(linesC(&cb), "Shuffle");
    _ = c.key(.{ .code = .enter }, false);
    try sh.shoot(&c, "C editable help: opened with `?`, Enter on Shuffle waits for a key");
    _ = c.key(.char('n'), false);
    try sh.shoot(&c, "C: n taken from Next at once; the bottom line offers z undo");
}
