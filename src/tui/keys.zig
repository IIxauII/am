//! The key table: every action the TUI's keys run, with its fixed name, its group on the
//! Settings page, its context, its default keys and its help text; the folding of keys only
//! some terminals tell apart; and the bindings, looked up per context. One meaning per key
//! across views: lower case acts on the selection, upper case on what is playing (or is the
//! stronger variant). The help overlay is still kept by hand below, next to the table.
const std = @import("std");
const input = @import("input.zig");

const Key = input.Key;

/// The sections, in sidebar order. The number keys reach the first nine; `0` is the queue.
pub const Section = enum {
    home,
    recent,
    songs,
    albums,
    artists,
    playlists,
    favorites,
    radio,
    charts,
    recently_added,
    search,
    queue,

    pub fn title(s: Section) []const u8 {
        return switch (s) {
            .home => "Home",
            .recent => "Recently Played",
            .songs => "Songs",
            .albums => "Albums",
            .artists => "Artists",
            .playlists => "Playlists",
            .favorites => "Favorites",
            .radio => "Radio",
            .charts => "Charts",
            .recently_added => "Recently Added",
            .search => "Search",
            .queue => "Up Next",
        };
    }

    /// The key that jumps to it by default, if any, for the sidebar and tab labels: its
    /// action's first default key, when that is a plain ASCII character.
    pub fn defaultKey(s: Section) ?u8 {
        const want: Command = if (s == .search) .search else .{ .section = s };
        for (actions) |a| switch (a.does) {
            .lists => |cmd| if (std.meta.eql(cmd, want)) {
                if (a.defaults.len == 0) return null;
                const k = a.defaults[0];
                if (k.ctrl or k.alt) return null;
                return switch (k.code) {
                    .char => |c| if (c < 0x80) @intCast(c) else null,
                    else => null,
                };
            },
            .typing => {},
        };
        return null;
    }

    /// Library sections are grouped under a heading in the sidebar.
    pub fn inLibrary(s: Section) bool {
        return switch (s) {
            .songs, .albums, .artists, .playlists, .recently_added => true,
            else => false,
        };
    }
};

/// Sidebar order.
pub const sidebar = [_]Section{ .home, .recent, .songs, .albums, .artists, .playlists, .recently_added, .favorites, .radio, .charts, .search, .queue };

pub const Command = union(enum) {
    /// Selection by this many rows.
    move: i32,
    top,
    bottom,
    /// Pages (+1 down, -1 up).
    page: i32,
    /// Half pages.
    half: i32,
    focus_next,
    focus_prev,
    focus_left,
    focus_right,
    open,
    back,
    section: Section,
    search,
    filter,
    toggle,
    next,
    previous,
    /// Seconds, negative is back.
    seek: i32,
    /// Percent points.
    volume: i32,
    mute,
    shuffle,
    repeat,
    favorite,
    favorite_now,
    add_library,
    add_playlist,
    play_later,
    play_next,
    play_container,
    station,
    go_album,
    go_artist,
    jump_now,
    remove,
    info,
    image_mode,
    help,
    /// Quit; playback keeps going in the background process.
    quit,
    /// Quit and stop playback.
    quit_stop,
    refresh,
    redraw,
    /// Sign in to Apple Music again (after closing the sign-in during the session).
    signin,
};

/// What a key does while a text field (search, filter) has the focus.
pub const TextCommand = union(enum) {
    insert: u21,
    delete_back,
    clear,
    submit,
    /// Leave the field, keeping its text.
    leave,
    /// Leave the field towards the list below.
    down,
    up,
    /// Switch catalog / library search.
    toggle_scope,
};

// ---- Actions ----

/// Where a binding works: `lists` everywhere outside text input (the help, details and
/// playlist-picker overlays too), `typing` in search and filter.
pub const Context = enum { lists, typing };

/// An action's group on the Settings page, in page order.
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

/// What an action does: a command in lists, a text command while typing.
pub const Does = union(Context) {
    lists: Command,
    typing: TextCommand,
};

/// What a binding runs.
pub const Action = struct {
    /// The action's name in `settings.json`. A public format: never renamed (a test pins it).
    name: []const u8,
    group: Group,
    does: Does,
    /// Its keys until the settings file changes them, folded (`fold`). Empty: no key.
    defaults: []const Key,
    /// What it does, in a few words.
    help: []const u8,

    pub fn context(a: Action) Context {
        return a.does;
    }
};

fn named(c: Key.Code) Key {
    return .{ .code = c };
}

fn shifted(c: Key.Code) Key {
    return .{ .code = c, .shift = true };
}

fn listsAction(name: []const u8, group: Group, cmd: Command, defaults: []const Key, help_text: []const u8) Action {
    return .{ .name = name, .group = group, .does = .{ .lists = cmd }, .defaults = defaults, .help = help_text };
}

fn typingAction(name: []const u8, cmd: TextCommand, defaults: []const Key, help_text: []const u8) Action {
    return .{ .name = name, .group = .typing, .does = .{ .typing = cmd }, .defaults = defaults, .help = help_text };
}

/// Every action, in Settings page order. `^c` and `^z` are fixed (`fixed`), so they're not here.
pub const actions = [_]Action{
    listsAction("move_down", .move, .{ .move = 1 }, &.{ .char('j'), named(.down), .ctrlChar('n') }, "Move down"),
    listsAction("move_up", .move, .{ .move = -1 }, &.{ .char('k'), named(.up), .ctrlChar('p') }, "Move up"),
    listsAction("top", .move, .top, &.{ .char('g'), named(.home) }, "Top"),
    listsAction("bottom", .move, .bottom, &.{ .char('G'), named(.end) }, "Bottom"),
    listsAction("page_down", .move, .{ .page = 1 }, &.{named(.page_down)}, "Page down"),
    listsAction("page_up", .move, .{ .page = -1 }, &.{named(.page_up)}, "Page up"),
    listsAction("half_page_down", .move, .{ .half = 1 }, &.{.ctrlChar('d')}, "Half page down"),
    listsAction("half_page_up", .move, .{ .half = -1 }, &.{.ctrlChar('u')}, "Half page up"),
    listsAction("focus_next", .move, .focus_next, &.{named(.tab)}, "Other pane"),
    listsAction("focus_previous", .move, .focus_prev, &.{shifted(.tab)}, "Other pane, backwards"),
    listsAction("focus_left", .move, .focus_left, &.{.char('h')}, "To the sidebar"),
    listsAction("focus_right", .move, .focus_right, &.{.char('l')}, "To the list"),
    listsAction("open", .move, .open, &.{named(.enter)}, "Open, or play from here"),
    listsAction("back", .move, .back, &.{ named(.esc), named(.backspace) }, "Back"),
    listsAction("filter", .move, .filter, &.{.ctrlChar('f')}, "Filter this list"),
    listsAction("go_album", .move, .go_album, &.{.char('o')}, "Go to album"),
    listsAction("go_artist", .move, .go_artist, &.{.char('O')}, "Go to artist"),
    listsAction("go_playing", .move, .jump_now, &.{.char('c')}, "Go to what's playing"),

    listsAction("section_home", .sections, .{ .section = .home }, &.{.char('1')}, "Home"),
    listsAction("section_recent", .sections, .{ .section = .recent }, &.{.char('2')}, "Recently Played"),
    listsAction("section_songs", .sections, .{ .section = .songs }, &.{.char('3')}, "Songs"),
    listsAction("section_albums", .sections, .{ .section = .albums }, &.{.char('4')}, "Albums"),
    listsAction("section_artists", .sections, .{ .section = .artists }, &.{.char('5')}, "Artists"),
    listsAction("section_playlists", .sections, .{ .section = .playlists }, &.{.char('6')}, "Playlists"),
    listsAction("section_favorites", .sections, .{ .section = .favorites }, &.{.char('7')}, "Favorites"),
    listsAction("section_radio", .sections, .{ .section = .radio }, &.{.char('8')}, "Radio"),
    listsAction("section_charts", .sections, .{ .section = .charts }, &.{.char('9')}, "Charts"),
    listsAction("section_recently_added", .sections, .{ .section = .recently_added }, &.{}, "Recently Added"),
    listsAction("section_queue", .sections, .{ .section = .queue }, &.{.char('0')}, "Up Next"),
    listsAction("search", .sections, .search, &.{.char('/')}, "Search"),

    listsAction("play_pause", .play, .toggle, &.{.char(' ')}, "Play / pause"),
    listsAction("next", .play, .next, &.{ .char('n'), .char('>') }, "Next"),
    listsAction("previous", .play, .previous, &.{ .char('p'), .char('<') }, "Previous"),
    listsAction("seek_back_5", .play, .{ .seek = -5 }, &.{named(.left)}, "Seek back 5 s"),
    listsAction("seek_forward_5", .play, .{ .seek = 5 }, &.{named(.right)}, "Seek forward 5 s"),
    listsAction("seek_back_30", .play, .{ .seek = -30 }, &.{ .char('['), shifted(.left) }, "Seek back 30 s"),
    listsAction("seek_forward_30", .play, .{ .seek = 30 }, &.{ .char(']'), shifted(.right) }, "Seek forward 30 s"),
    listsAction("volume_up", .play, .{ .volume = 5 }, &.{ .char('+'), .char('=') }, "Volume up"),
    listsAction("volume_down", .play, .{ .volume = -5 }, &.{.char('-')}, "Volume down"),
    listsAction("mute", .play, .mute, &.{.char('m')}, "Mute"),
    listsAction("shuffle", .play, .shuffle, &.{.char('s')}, "Shuffle"),
    listsAction("repeat", .play, .repeat, &.{.char('r')}, "Repeat: off, all, one"),
    listsAction("play_from_top", .play, .play_container, &.{.char('P')}, "Play album or playlist from the top"),
    listsAction("play_later", .play, .play_later, &.{.char('e')}, "Play later"),
    listsAction("play_next", .play, .play_next, &.{.char('E')}, "Play next"),
    listsAction("station", .play, .station, &.{.char('R')}, "Station from the selection"),
    listsAction("remove", .play, .remove, &.{ .char('d'), named(.delete) }, "Remove from Up Next"),

    listsAction("favorite", .library, .favorite, &.{.char('f')}, "Favorite the selection"),
    listsAction("favorite_playing", .library, .favorite_now, &.{.char('F')}, "Favorite what's playing"),
    listsAction("add_to_library", .library, .add_library, &.{.char('a')}, "Add to library"),
    listsAction("add_to_playlist", .library, .add_playlist, &.{.char('A')}, "Add to a playlist"),
    listsAction("details", .library, .info, &.{.char('i')}, "Details"),

    listsAction("artwork", .app, .image_mode, &.{.char('v')}, "Artwork: images, blocks, off"),
    listsAction("reload_view", .app, .refresh, &.{.ctrlChar('r')}, "Reload view"),
    listsAction("redraw", .app, .redraw, &.{.ctrlChar('l')}, "Redraw"),
    listsAction("quit", .app, .quit, &.{.char('q')}, "Quit (the music goes on)"),
    listsAction("quit_and_stop", .app, .quit_stop, &.{.char('Q')}, "Quit and stop the music"),
    listsAction("sign_in", .app, .signin, &.{.char('S')}, "Sign in to Apple Music again"),
    listsAction("help", .app, .help, &.{.char('?')}, "Help"),

    typingAction("delete_back", .delete_back, &.{named(.backspace)}, "Delete back"),
    typingAction("clear", .clear, &.{.ctrlChar('u')}, "Clear the field"),
    typingAction("submit", .submit, &.{named(.enter)}, "Search, or submit"),
    typingAction("leave", .leave, &.{named(.esc)}, "Leave the field"),
    typingAction("move_down", .down, &.{named(.down)}, "Down to the list"),
    typingAction("move_up", .up, &.{named(.up)}, "Up"),
    typingAction("switch_scope", .toggle_scope, &.{named(.tab)}, "Catalog or library search"),
};

/// The keys each action has, by its place in `actions`: the defaults, until the settings file
/// changes them.
pub const Bindings = struct {
    keys: [actions.len][]const Key,

    pub const defaults: Bindings = blk: {
        var b: Bindings = undefined;
        for (actions, 0..) |a, i| b.keys[i] = a.defaults;
        break :blk b;
    };

    /// The action `key` runs in `context`, or null when it runs none. The folded key must match
    /// a binding whole, modifiers included: Alt+j is a key of its own.
    pub fn lookup(b: *const Bindings, context: Context, key: Key) ?*const Action {
        const folded = fold(key);
        for (&actions, b.keys) |*a, ks| {
            if (a.context() != context) continue;
            for (ks) |k| if (k.eql(folded)) return a;
        }
        return null;
    }
};

/// The key as every terminal sends it. Without a keyboard protocol several keys send the same
/// bytes (Ctrl+i is Tab), and Ghostty, kitty and foot send some of them apart anyway; reading
/// them as the shared key makes a binding work the same in every terminal and inside tmux.
/// Other modifiers stay: Alt+Ctrl+i is Alt+Tab.
pub fn fold(key: Key) Key {
    var k = key;
    switch (k.code) {
        .char => |c| {
            if (k.shift) {
                // A shifted character is the character. Ctrl+Shift+letter is Ctrl+letter.
                k.shift = false;
                if (!k.ctrl) k.code = .{ .char = upper(c) };
            }
            if (!k.ctrl) return k;
            const lower: u21 = if (c < 0x80) std.ascii.toLower(@intCast(c)) else c;
            k.ctrl = false;
            k.code = switch (lower) {
                'i' => .tab,
                'm', 'j' => .enter,
                'h' => .backspace,
                '[' => .esc,
                else => blk: {
                    k.ctrl = true;
                    break :blk .{ .char = lower };
                },
            };
        },
        .enter => {
            k.shift = false;
            k.ctrl = false;
        },
        else => {},
    }
    return k;
}

/// The keys no binding can change, so the terminal's usual escape hatches always work.
pub const Fixed = enum {
    /// `^c`, everywhere in the main UI, text fields included.
    quit,
    /// `^z`, on every screen.
    suspend_process,
};

/// The fixed key `key` is, after folding, if it is one. It must match whole: Ctrl+Alt+c isn't `^c`.
pub fn fixed(key: Key) ?Fixed {
    const k = fold(key);
    if (k.eql(.ctrlChar('c'))) return .quit;
    if (k.eql(.ctrlChar('z'))) return .suspend_process;
    return null;
}

/// The character `key` types in a text field, if it types one. Such keys can't be bound while
/// typing, so every character can be typed in search.
pub fn typed(key: Key) ?u21 {
    const k = fold(key);
    if (k.ctrl or k.alt) return null;
    return switch (k.code) {
        .char => |c| if (c >= 0x20 and c != 0x7f) c else null,
        else => null,
    };
}

/// The upper case of an ASCII or Latin-1 letter (what Shift types), else `c`.
fn upper(c: u21) u21 {
    return switch (c) {
        'a'...'z', 0xe0...0xf6, 0xf8...0xfe => c - 0x20,
        else => c,
    };
}

pub const HelpLine = struct { keys: []const u8, what: []const u8 };
pub const HelpSection = struct { title: []const u8, lines: []const HelpLine };

/// The help overlay, kept next to the table above so they agree.
pub const help = [_]HelpSection{
    .{ .title = "Move", .lines = &.{
        .{ .keys = "j k ↑ ↓", .what = "move the selection" },
        .{ .keys = "g G Home End", .what = "top / bottom" },
        .{ .keys = "PgUp PgDn ^u ^d", .what = "page / half page" },
        .{ .keys = "Tab h l", .what = "sidebar / list (narrow: sections)" },
        .{ .keys = "Enter", .what = "open, or play from here" },
        .{ .keys = "Esc Backspace", .what = "back" },
        .{ .keys = "1–9 0 /", .what = "sections, Up Next, search" },
        .{ .keys = "^f", .what = "filter this list" },
        .{ .keys = "o O", .what = "go to album / artist" },
        .{ .keys = "c", .what = "go to what's playing" },
    } },
    .{ .title = "Play", .lines = &.{
        .{ .keys = "Space", .what = "play / pause" },
        .{ .keys = "n p", .what = "next / previous" },
        .{ .keys = "← → [ ]", .what = "seek 5 s / 30 s" },
        .{ .keys = "+ -  m", .what = "volume, mute" },
        .{ .keys = "s r", .what = "shuffle, repeat (off/all/one)" },
        .{ .keys = "P", .what = "play album / playlist from the top" },
        .{ .keys = "e E", .what = "play later / play next" },
        .{ .keys = "R", .what = "station from the selection" },
        .{ .keys = "d", .what = "remove from Up Next" },
    } },
    .{ .title = "Library", .lines = &.{
        .{ .keys = "f F", .what = "favorite: selection / playing" },
        .{ .keys = "a", .what = "add to library" },
        .{ .keys = "A", .what = "add to a playlist" },
        .{ .keys = "i", .what = "details" },
    } },
    .{ .title = "App", .lines = &.{
        .{ .keys = "v", .what = "artwork: images → blocks → off" },
        .{ .keys = "^r ^l", .what = "reload view, redraw" },
        .{ .keys = "^z", .what = "suspend" },
        .{ .keys = "q", .what = "quit (playing music goes on)" },
        .{ .keys = "Q", .what = "quit, stop the music and daemon" },
        .{ .keys = "S", .what = "sign in to Apple Music again" },
        .{ .keys = "?", .what = "this help (j k scroll)" },
    } },
};

const testing = std.testing;

test "the sidebar and tabs label each section with its default key" {
    try testing.expectEqual(@as(?u8, '1'), Section.home.defaultKey());
    try testing.expectEqual(@as(?u8, '9'), Section.charts.defaultKey());
    try testing.expectEqual(@as(?u8, '0'), Section.queue.defaultKey());
    try testing.expectEqual(@as(?u8, '/'), Section.search.defaultKey());
    try testing.expectEqual(@as(?u8, null), Section.recently_added.defaultKey());
}

test "every help key names a binding" {
    // A spot check that the help table and the bindings agree on the main keys.
    for ([_]u21{ 'f', 'F', 'a', 'A', 'e', 'E', 'P', 'R', 'o', 'O', 'c', 'd', 'i', 'v', '?', 'q', 'Q', 's', 'r', 'm', 'n', 'p', 'S' }) |c|
        try testing.expect(Bindings.defaults.lookup(.lists, .char(c)) != null);
}

/// The names `settings.json` gives the actions, each with what it runs. They are a public
/// format: a user's file names them. Add a new action here; never rename, remove or repoint
/// one. Renaming a command in the code only means renaming it here too.
const Pin = struct { []const u8, Does };
const pinned = [_]Pin{
    .{ "move_down", .{ .lists = .{ .move = 1 } } },
    .{ "move_up", .{ .lists = .{ .move = -1 } } },
    .{ "top", .{ .lists = .top } },
    .{ "bottom", .{ .lists = .bottom } },
    .{ "page_down", .{ .lists = .{ .page = 1 } } },
    .{ "page_up", .{ .lists = .{ .page = -1 } } },
    .{ "half_page_down", .{ .lists = .{ .half = 1 } } },
    .{ "half_page_up", .{ .lists = .{ .half = -1 } } },
    .{ "focus_next", .{ .lists = .focus_next } },
    .{ "focus_previous", .{ .lists = .focus_prev } },
    .{ "focus_left", .{ .lists = .focus_left } },
    .{ "focus_right", .{ .lists = .focus_right } },
    .{ "open", .{ .lists = .open } },
    .{ "back", .{ .lists = .back } },
    .{ "filter", .{ .lists = .filter } },
    .{ "go_album", .{ .lists = .go_album } },
    .{ "go_artist", .{ .lists = .go_artist } },
    .{ "go_playing", .{ .lists = .jump_now } },

    .{ "section_home", .{ .lists = .{ .section = .home } } },
    .{ "section_recent", .{ .lists = .{ .section = .recent } } },
    .{ "section_songs", .{ .lists = .{ .section = .songs } } },
    .{ "section_albums", .{ .lists = .{ .section = .albums } } },
    .{ "section_artists", .{ .lists = .{ .section = .artists } } },
    .{ "section_playlists", .{ .lists = .{ .section = .playlists } } },
    .{ "section_favorites", .{ .lists = .{ .section = .favorites } } },
    .{ "section_radio", .{ .lists = .{ .section = .radio } } },
    .{ "section_charts", .{ .lists = .{ .section = .charts } } },
    .{ "section_recently_added", .{ .lists = .{ .section = .recently_added } } },
    .{ "section_queue", .{ .lists = .{ .section = .queue } } },
    .{ "search", .{ .lists = .search } },

    .{ "play_pause", .{ .lists = .toggle } },
    .{ "next", .{ .lists = .next } },
    .{ "previous", .{ .lists = .previous } },
    .{ "seek_back_5", .{ .lists = .{ .seek = -5 } } },
    .{ "seek_forward_5", .{ .lists = .{ .seek = 5 } } },
    .{ "seek_back_30", .{ .lists = .{ .seek = -30 } } },
    .{ "seek_forward_30", .{ .lists = .{ .seek = 30 } } },
    .{ "volume_up", .{ .lists = .{ .volume = 5 } } },
    .{ "volume_down", .{ .lists = .{ .volume = -5 } } },
    .{ "mute", .{ .lists = .mute } },
    .{ "shuffle", .{ .lists = .shuffle } },
    .{ "repeat", .{ .lists = .repeat } },
    .{ "play_from_top", .{ .lists = .play_container } },
    .{ "play_later", .{ .lists = .play_later } },
    .{ "play_next", .{ .lists = .play_next } },
    .{ "station", .{ .lists = .station } },
    .{ "remove", .{ .lists = .remove } },

    .{ "favorite", .{ .lists = .favorite } },
    .{ "favorite_playing", .{ .lists = .favorite_now } },
    .{ "add_to_library", .{ .lists = .add_library } },
    .{ "add_to_playlist", .{ .lists = .add_playlist } },
    .{ "details", .{ .lists = .info } },

    .{ "artwork", .{ .lists = .image_mode } },
    .{ "reload_view", .{ .lists = .refresh } },
    .{ "redraw", .{ .lists = .redraw } },
    .{ "quit", .{ .lists = .quit } },
    .{ "quit_and_stop", .{ .lists = .quit_stop } },
    .{ "sign_in", .{ .lists = .signin } },
    .{ "help", .{ .lists = .help } },

    .{ "delete_back", .{ .typing = .delete_back } },
    .{ "clear", .{ .typing = .clear } },
    .{ "submit", .{ .typing = .submit } },
    .{ "leave", .{ .typing = .leave } },
    .{ "move_down", .{ .typing = .down } },
    .{ "move_up", .{ .typing = .up } },
    .{ "switch_scope", .{ .typing = .toggle_scope } },
};

/// The action named `name` in `context`, if exactly one is.
fn onlyNamed(context: Context, name: []const u8) ?Action {
    var found: ?Action = null;
    for (actions) |a| if (a.context() == context and std.mem.eql(u8, a.name, name)) {
        if (found != null) return null;
        found = a;
    };
    return found;
}

fn expectPinned() !void {
    for (pinned) |pin| {
        const name, const does = pin;
        const context: Context = does;
        const a = onlyNamed(context, name) orelse {
            std.debug.print("action {s}.{s}: no action or several have this name, want exactly 1\n", .{ @tagName(context), name });
            return error.TestUnexpectedResult;
        };
        if (!std.meta.eql(a.does, does)) {
            std.debug.print("action {s}.{s} runs {any}, pinned to {any}\n", .{ @tagName(context), name, a.does, does });
            return error.TestUnexpectedResult;
        }
    }
    for (actions) |a| {
        for (pinned) |pin| {
            const name, const does = pin;
            if (a.context() == @as(Context, does) and std.mem.eql(u8, a.name, name)) break;
        } else {
            std.debug.print("action {s}.{s} isn't pinned: add it to `pinned`\n", .{ @tagName(a.context()), a.name });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectBinding(context: Context, k: Key, want: ?[]const u8) !void {
    const got = Bindings.defaults.lookup(context, k);
    const got_name = if (got) |a| a.name else null;
    if (want) |w| if (got_name) |g| if (std.mem.eql(u8, w, g)) return;
    if (want == null and got_name == null) return;
    std.debug.print("{s}: {any} runs {?s}, want {?s}\n", .{ @tagName(context), k, got_name, want });
    return error.TestUnexpectedResult;
}

test "the default keys and the actions they run" {
    const B = struct { Key, []const u8 };
    // Outside text input.
    for ([_]B{
        .{ .char('j'), "move_down" },          .{ named(.down), "move_down" },          .{ .ctrlChar('n'), "move_down" },
        .{ .char('k'), "move_up" },            .{ named(.up), "move_up" },              .{ .ctrlChar('p'), "move_up" },
        .{ .char('g'), "top" },                .{ named(.home), "top" },                .{ .char('G'), "bottom" },
        .{ named(.end), "bottom" },            .{ named(.page_down), "page_down" },     .{ named(.page_up), "page_up" },
        .{ .ctrlChar('d'), "half_page_down" }, .{ .ctrlChar('u'), "half_page_up" },     .{ named(.tab), "focus_next" },
        .{ shifted(.tab), "focus_previous" },  .{ .char('h'), "focus_left" },           .{ .char('l'), "focus_right" },
        .{ named(.enter), "open" },            .{ named(.esc), "back" },                .{ named(.backspace), "back" },
        .{ .ctrlChar('f'), "filter" },         .{ .char('o'), "go_album" },             .{ .char('O'), "go_artist" },
        .{ .char('c'), "go_playing" },         .{ .char('1'), "section_home" },         .{ .char('2'), "section_recent" },
        .{ .char('3'), "section_songs" },      .{ .char('4'), "section_albums" },       .{ .char('5'), "section_artists" },
        .{ .char('6'), "section_playlists" },  .{ .char('7'), "section_favorites" },    .{ .char('8'), "section_radio" },
        .{ .char('9'), "section_charts" },     .{ .char('0'), "section_queue" },        .{ .char('/'), "search" },
        .{ .char(' '), "play_pause" },         .{ .char('n'), "next" },                 .{ .char('>'), "next" },
        .{ .char('p'), "previous" },           .{ .char('<'), "previous" },             .{ named(.left), "seek_back_5" },
        .{ named(.right), "seek_forward_5" },  .{ .char('['), "seek_back_30" },         .{ shifted(.left), "seek_back_30" },
        .{ .char(']'), "seek_forward_30" },    .{ shifted(.right), "seek_forward_30" }, .{ .char('+'), "volume_up" },
        .{ .char('='), "volume_up" },          .{ .char('-'), "volume_down" },          .{ .char('m'), "mute" },
        .{ .char('s'), "shuffle" },            .{ .char('r'), "repeat" },               .{ .char('P'), "play_from_top" },
        .{ .char('e'), "play_later" },         .{ .char('E'), "play_next" },            .{ .char('R'), "station" },
        .{ .char('d'), "remove" },             .{ named(.delete), "remove" },           .{ .char('f'), "favorite" },
        .{ .char('F'), "favorite_playing" },   .{ .char('a'), "add_to_library" },       .{ .char('A'), "add_to_playlist" },
        .{ .char('i'), "details" },            .{ .char('v'), "artwork" },              .{ .ctrlChar('r'), "reload_view" },
        .{ .ctrlChar('l'), "redraw" },         .{ .char('q'), "quit" },                 .{ .char('Q'), "quit_and_stop" },
        .{ .char('S'), "sign_in" },            .{ .char('?'), "help" },
    }) |b| try expectBinding(.lists, b[0], b[1]);
    // And in search and filter.
    for ([_]B{
        .{ named(.backspace), "delete_back" }, .{ .ctrlChar('u'), "clear" },   .{ named(.enter), "submit" },
        .{ named(.esc), "leave" },             .{ named(.down), "move_down" }, .{ named(.up), "move_up" },
        .{ named(.tab), "switch_scope" },
    }) |b| try expectBinding(.typing, b[0], b[1]);

    // Keys with no action.
    try expectBinding(.lists, .char('x'), null);
    try expectBinding(.lists, named(.{ .f = 1 }), null);
    try expectBinding(.typing, .char('q'), null);
    // ^c and ^z are fixed, not bindings.
    try expectBinding(.lists, .ctrlChar('c'), null);
    try expectBinding(.lists, .ctrlChar('z'), null);
    try expectBinding(.typing, .ctrlChar('c'), null);
    // Recently Added has no key.
    for (actions) |a| if (std.mem.eql(u8, a.name, "section_recently_added")) try testing.expectEqual(@as(usize, 0), a.defaults.len);
}

test "keys only some terminals tell apart are read as the shared key" {
    // Ctrl+i is Tab; Ctrl+m, Ctrl+j, Shift+Enter and Ctrl+Enter are Enter; Ctrl+h is Backspace;
    // Ctrl+[ is Esc. Ghostty, kitty and foot send these apart; Terminal.app and tmux don't.
    try expectBinding(.lists, .ctrlChar('i'), "focus_next");
    try expectBinding(.typing, .ctrlChar('i'), "switch_scope");
    try expectBinding(.lists, .ctrlChar('m'), "open");
    try expectBinding(.lists, .ctrlChar('j'), "open");
    try expectBinding(.lists, shifted(.enter), "open");
    try expectBinding(.lists, .{ .code = .enter, .ctrl = true }, "open");
    try expectBinding(.lists, .{ .code = .enter, .ctrl = true, .shift = true }, "open");
    try expectBinding(.typing, shifted(.enter), "submit");
    try expectBinding(.lists, .ctrlChar('h'), "back");
    try expectBinding(.typing, .ctrlChar('h'), "delete_back");
    try expectBinding(.lists, .ctrlChar('['), "back");
    try expectBinding(.typing, .ctrlChar('['), "leave");
    // Ctrl+Shift+letter is Ctrl+letter, however the terminal spells it: kitty, modifyOtherKeys,
    // WezTerm.
    try expectBinding(.lists, .{ .code = .{ .char = 'f' }, .ctrl = true, .shift = true }, "filter");
    try expectBinding(.lists, .{ .code = .{ .char = 'F' }, .ctrl = true, .shift = true }, "filter");
    try expectBinding(.lists, .ctrlChar('F'), "filter");
    try expectBinding(.lists, .{ .code = .{ .char = 'I' }, .ctrl = true, .shift = true }, "focus_next");
    // Shift+Space is Space; Shift+character is the shifted character.
    try expectBinding(.lists, .{ .code = .{ .char = ' ' }, .shift = true }, "play_pause");
    try expectBinding(.lists, .{ .code = .{ .char = 'a' }, .shift = true }, "add_to_playlist");
    try expectBinding(.lists, .{ .code = .{ .char = 'A' }, .shift = true }, "add_to_playlist");

    // A fold keeps the other modifiers, as terminals without a keyboard protocol send them.
    try testing.expect(fold(.{ .code = .{ .char = 'i' }, .ctrl = true, .alt = true }).eql(.{ .code = .tab, .alt = true }));
    try testing.expect(fold(.{ .code = .{ .char = 'a' }, .alt = true, .shift = true }).eql(.{ .code = .{ .char = 'A' }, .alt = true }));
    try testing.expect(fold(.{ .code = .enter, .alt = true, .shift = true }).eql(.{ .code = .enter, .alt = true }));
    try testing.expect(fold(.{ .code = .{ .char = 0xfc }, .shift = true }).eql(.char(0xdc))); // ü
    // Shift stays on named keys other than Enter, and Ctrl on other characters.
    try testing.expect(fold(shifted(.up)).eql(shifted(.up)));
    try testing.expect(fold(shifted(.tab)).eql(shifted(.tab)));
    try testing.expect(fold(.ctrlChar(' ')).eql(.ctrlChar(' ')));
}

test "a binding matches the whole key: Alt+j and Shift+↑ are keys of their own" {
    try expectBinding(.lists, .char('j'), "move_down");
    try expectBinding(.lists, .{ .code = .{ .char = 'j' }, .alt = true }, null);
    try expectBinding(.lists, named(.up), "move_up");
    try expectBinding(.lists, shifted(.up), null);
    try expectBinding(.lists, .{ .code = .up, .alt = true }, null);
    try expectBinding(.lists, .{ .code = .left, .alt = true }, null);
    try expectBinding(.lists, shifted(.backspace), null);
    try expectBinding(.lists, shifted(.page_down), null);
    try expectBinding(.lists, .{ .code = .{ .char = 'f' }, .ctrl = true, .alt = true }, null);
    try expectBinding(.typing, .{ .code = .backspace, .alt = true }, null);
    try expectBinding(.typing, .{ .code = .down, .ctrl = true }, null);
}

test "the defaults are folded keys, one action each, never ^c or ^z or a typing key while typing" {
    for (actions, 0..) |a, i| {
        try testing.expectEqual(a.context() == .typing, a.group == .typing);
        for (a.defaults) |k| {
            try testing.expect(fold(k).eql(k));
            try testing.expect(fixed(k) == null);
            if (a.context() == .typing) try testing.expect(typed(k) == null);
            for (actions[i + 1 ..]) |b| if (b.context() == a.context()) for (b.defaults) |other| {
                if (other.eql(k)) std.debug.print("{s} and {s} share a key\n", .{ a.name, b.name });
                try testing.expect(!other.eql(k));
            };
        }
    }
}

test "^c quits and ^z suspends, outside the bindings" {
    try testing.expectEqual(Fixed.quit, fixed(.ctrlChar('c')).?);
    try testing.expectEqual(Fixed.suspend_process, fixed(.ctrlChar('z')).?);
    try testing.expectEqual(Fixed.quit, fixed(.{ .code = .{ .char = 'c' }, .ctrl = true, .shift = true }).?);
    try testing.expect(fixed(.{ .code = .{ .char = 'c' }, .ctrl = true, .alt = true }) == null);
    try testing.expect(fixed(.char('c')) == null);
    try testing.expect(fixed(.char('q')) == null);
}

test "action names are fixed: none is renamed, removed or repointed, and every action is pinned" {
    try expectPinned();
}
