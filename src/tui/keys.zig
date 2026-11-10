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
    pub fn hotkey(s: Section) ?u8 {
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
    /// Today's keys, folded (`fold`). Empty: no key by default.
    defaults: []const Key,
    /// What it does, in a few words.
    help: []const u8,

    pub fn context(a: Action) Context {
        return a.does;
    }
};

fn ch(c: u21) Key {
    return .char(c);
}

fn ctl(c: u21) Key {
    return .ctrlChar(c);
}

fn named(c: Key.Code) Key {
    return .{ .code = c };
}

fn shifted(c: Key.Code) Key {
    return .{ .code = c, .shift = true };
}

fn list(name: []const u8, group: Group, cmd: Command, defaults: []const Key, help_text: []const u8) Action {
    return .{ .name = name, .group = group, .does = .{ .lists = cmd }, .defaults = defaults, .help = help_text };
}

fn typing(name: []const u8, cmd: TextCommand, defaults: []const Key, help_text: []const u8) Action {
    return .{ .name = name, .group = .typing, .does = .{ .typing = cmd }, .defaults = defaults, .help = help_text };
}

/// Every action, in Settings page order. `^c` and `^z` are fixed (`fixed`), so they're not here.
pub const actions = [_]Action{
    list("move_down", .move, .{ .move = 1 }, &.{ ch('j'), named(.down), ctl('n') }, "Move down"),
    list("move_up", .move, .{ .move = -1 }, &.{ ch('k'), named(.up), ctl('p') }, "Move up"),
    list("top", .move, .top, &.{ ch('g'), named(.home) }, "Top"),
    list("bottom", .move, .bottom, &.{ ch('G'), named(.end) }, "Bottom"),
    list("page_down", .move, .{ .page = 1 }, &.{named(.page_down)}, "Page down"),
    list("page_up", .move, .{ .page = -1 }, &.{named(.page_up)}, "Page up"),
    list("half_page_down", .move, .{ .half = 1 }, &.{ctl('d')}, "Half page down"),
    list("half_page_up", .move, .{ .half = -1 }, &.{ctl('u')}, "Half page up"),
    list("focus_next", .move, .focus_next, &.{named(.tab)}, "Other pane"),
    list("focus_previous", .move, .focus_prev, &.{shifted(.tab)}, "Other pane, backwards"),
    list("focus_left", .move, .focus_left, &.{ch('h')}, "To the sidebar"),
    list("focus_right", .move, .focus_right, &.{ch('l')}, "To the list"),
    list("open", .move, .open, &.{named(.enter)}, "Open, or play from here"),
    list("back", .move, .back, &.{ named(.esc), named(.backspace) }, "Back"),
    list("filter", .move, .filter, &.{ctl('f')}, "Filter this list"),
    list("go_album", .move, .go_album, &.{ch('o')}, "Go to album"),
    list("go_artist", .move, .go_artist, &.{ch('O')}, "Go to artist"),
    list("go_playing", .move, .jump_now, &.{ch('c')}, "Go to what's playing"),

    list("section_home", .sections, .{ .section = .home }, &.{ch('1')}, "Home"),
    list("section_recent", .sections, .{ .section = .recent }, &.{ch('2')}, "Recently Played"),
    list("section_songs", .sections, .{ .section = .songs }, &.{ch('3')}, "Songs"),
    list("section_albums", .sections, .{ .section = .albums }, &.{ch('4')}, "Albums"),
    list("section_artists", .sections, .{ .section = .artists }, &.{ch('5')}, "Artists"),
    list("section_playlists", .sections, .{ .section = .playlists }, &.{ch('6')}, "Playlists"),
    list("section_favorites", .sections, .{ .section = .favorites }, &.{ch('7')}, "Favorites"),
    list("section_radio", .sections, .{ .section = .radio }, &.{ch('8')}, "Radio"),
    list("section_charts", .sections, .{ .section = .charts }, &.{ch('9')}, "Charts"),
    list("section_recently_added", .sections, .{ .section = .recently_added }, &.{}, "Recently Added"),
    list("section_queue", .sections, .{ .section = .queue }, &.{ch('0')}, "Up Next"),
    list("search", .sections, .search, &.{ch('/')}, "Search"),

    list("play_pause", .play, .toggle, &.{ch(' ')}, "Play / pause"),
    list("next", .play, .next, &.{ ch('n'), ch('>') }, "Next"),
    list("previous", .play, .previous, &.{ ch('p'), ch('<') }, "Previous"),
    list("seek_back_5", .play, .{ .seek = -5 }, &.{named(.left)}, "Seek back 5 s"),
    list("seek_forward_5", .play, .{ .seek = 5 }, &.{named(.right)}, "Seek forward 5 s"),
    list("seek_back_30", .play, .{ .seek = -30 }, &.{ ch('['), shifted(.left) }, "Seek back 30 s"),
    list("seek_forward_30", .play, .{ .seek = 30 }, &.{ ch(']'), shifted(.right) }, "Seek forward 30 s"),
    list("volume_up", .play, .{ .volume = 5 }, &.{ ch('+'), ch('=') }, "Volume up"),
    list("volume_down", .play, .{ .volume = -5 }, &.{ch('-')}, "Volume down"),
    list("mute", .play, .mute, &.{ch('m')}, "Mute"),
    list("shuffle", .play, .shuffle, &.{ch('s')}, "Shuffle"),
    list("repeat", .play, .repeat, &.{ch('r')}, "Repeat: off, all, one"),
    list("play_from_top", .play, .play_container, &.{ch('P')}, "Play album or playlist from the top"),
    list("play_later", .play, .play_later, &.{ch('e')}, "Play later"),
    list("play_next", .play, .play_next, &.{ch('E')}, "Play next"),
    list("station", .play, .station, &.{ch('R')}, "Station from the selection"),
    list("remove", .play, .remove, &.{ ch('d'), named(.delete) }, "Remove from Up Next"),

    list("favorite", .library, .favorite, &.{ch('f')}, "Favorite the selection"),
    list("favorite_playing", .library, .favorite_now, &.{ch('F')}, "Favorite what's playing"),
    list("add_to_library", .library, .add_library, &.{ch('a')}, "Add to library"),
    list("add_to_playlist", .library, .add_playlist, &.{ch('A')}, "Add to a playlist"),
    list("details", .library, .info, &.{ch('i')}, "Details"),

    list("artwork", .app, .image_mode, &.{ch('v')}, "Artwork: images, blocks, off"),
    list("reload_view", .app, .refresh, &.{ctl('r')}, "Reload view"),
    list("redraw", .app, .redraw, &.{ctl('l')}, "Redraw"),
    list("quit", .app, .quit, &.{ch('q')}, "Quit (the music goes on)"),
    list("quit_and_stop", .app, .quit_stop, &.{ch('Q')}, "Quit and stop the music"),
    list("sign_in", .app, .signin, &.{ch('S')}, "Sign in to Apple Music again"),
    list("help", .app, .help, &.{ch('?')}, "Help"),

    typing("delete_back", .delete_back, &.{named(.backspace)}, "Delete back"),
    typing("clear", .clear, &.{ctl('u')}, "Clear the field"),
    typing("submit", .submit, &.{named(.enter)}, "Search, or submit"),
    typing("leave", .leave, &.{named(.esc)}, "Leave the field"),
    typing("move_down", .down, &.{named(.down)}, "Down to the list"),
    typing("move_up", .up, &.{named(.up)}, "Up"),
    typing("switch_scope", .toggle_scope, &.{named(.tab)}, "Catalog or library search"),
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
        .{ .keys = "v", .what = "artwork: image → blocks → off" },
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
    try testing.expectEqual(@as(?u8, '1'), Section.home.hotkey());
    try testing.expectEqual(@as(?u8, '9'), Section.charts.hotkey());
    try testing.expectEqual(@as(?u8, '0'), Section.queue.hotkey());
    try testing.expectEqual(@as(?u8, '/'), Section.search.hotkey());
    try testing.expectEqual(@as(?u8, null), Section.recently_added.hotkey());
}

test "every help key names a binding" {
    // A spot check that the help table and the bindings agree on the main keys.
    for ([_]u21{ 'f', 'F', 'a', 'A', 'e', 'E', 'P', 'R', 'o', 'O', 'c', 'd', 'i', 'v', '?', 'q', 'Q', 's', 'r', 'm', 'n', 'p', 'S' }) |c|
        try testing.expect(Bindings.defaults.lookup(.lists, .char(c)) != null);
}

/// The names `settings.json` gives the actions, per context. They are a public format: a
/// user's file names them. Add a new action's name here; never rename or remove one.
const pinned_names = struct {
    const lists = [_][]const u8{
        // Move
        "move_down",         "move_up",        "top",             "bottom",
        "page_down",         "page_up",        "half_page_down",  "half_page_up",
        "focus_next",        "focus_previous", "focus_left",      "focus_right",
        "open",              "back",           "filter",          "go_album",
        "go_artist",         "go_playing",
        // Sections
            "section_home",    "section_recent",
        "section_songs",     "section_albums", "section_artists", "section_playlists",
        "section_favorites", "section_radio",  "section_charts",  "section_recently_added",
        "section_queue",     "search",
        // Play
                "play_pause",      "next",
        "previous",          "seek_back_5",    "seek_forward_5",  "seek_back_30",
        "seek_forward_30",   "volume_up",      "volume_down",     "mute",
        "shuffle",           "repeat",         "play_from_top",   "play_later",
        "play_next",         "station",        "remove",
        // Library
                 "favorite",
        "favorite_playing",  "add_to_library", "add_to_playlist", "details",
        // App
        "artwork",           "reload_view",    "redraw",          "quit",
        "quit_and_stop",     "sign_in",        "help",
    };
    const typing = [_][]const u8{ "delete_back", "clear", "submit", "leave", "move_down", "move_up", "switch_scope" };
};

fn expectNamesPinned(context: Context, pinned: []const []const u8) !void {
    for (pinned) |name| {
        var found: usize = 0;
        for (actions) |a| found += @intFromBool(a.context() == context and std.mem.eql(u8, a.name, name));
        testing.expectEqual(@as(usize, 1), found) catch |err| {
            std.debug.print("action {s}.{s}: {d} actions have this name, want exactly 1\n", .{ @tagName(context), name, found });
            return err;
        };
    }
    for (actions) |a| {
        if (a.context() != context) continue;
        for (pinned) |name| {
            if (std.mem.eql(u8, a.name, name)) break;
        } else {
            std.debug.print("action {s}.{s} isn't pinned: add its name to `pinned_names`\n", .{ @tagName(context), a.name });
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

test "default keys are today's" {
    const B = struct { Key, []const u8 };
    // Every key the keymap knew before bindings, outside text input.
    for ([_]B{
        .{ ch('j'), "move_down" },            .{ named(.down), "move_down" },          .{ ctl('n'), "move_down" },
        .{ ch('k'), "move_up" },              .{ named(.up), "move_up" },              .{ ctl('p'), "move_up" },
        .{ ch('g'), "top" },                  .{ named(.home), "top" },                .{ ch('G'), "bottom" },
        .{ named(.end), "bottom" },           .{ named(.page_down), "page_down" },     .{ named(.page_up), "page_up" },
        .{ ctl('d'), "half_page_down" },      .{ ctl('u'), "half_page_up" },           .{ named(.tab), "focus_next" },
        .{ shifted(.tab), "focus_previous" }, .{ ch('h'), "focus_left" },              .{ ch('l'), "focus_right" },
        .{ named(.enter), "open" },           .{ named(.esc), "back" },                .{ named(.backspace), "back" },
        .{ ctl('f'), "filter" },              .{ ch('o'), "go_album" },                .{ ch('O'), "go_artist" },
        .{ ch('c'), "go_playing" },           .{ ch('1'), "section_home" },            .{ ch('2'), "section_recent" },
        .{ ch('3'), "section_songs" },        .{ ch('4'), "section_albums" },          .{ ch('5'), "section_artists" },
        .{ ch('6'), "section_playlists" },    .{ ch('7'), "section_favorites" },       .{ ch('8'), "section_radio" },
        .{ ch('9'), "section_charts" },       .{ ch('0'), "section_queue" },           .{ ch('/'), "search" },
        .{ ch(' '), "play_pause" },           .{ ch('n'), "next" },                    .{ ch('>'), "next" },
        .{ ch('p'), "previous" },             .{ ch('<'), "previous" },                .{ named(.left), "seek_back_5" },
        .{ named(.right), "seek_forward_5" }, .{ ch('['), "seek_back_30" },            .{ shifted(.left), "seek_back_30" },
        .{ ch(']'), "seek_forward_30" },      .{ shifted(.right), "seek_forward_30" }, .{ ch('+'), "volume_up" },
        .{ ch('='), "volume_up" },            .{ ch('-'), "volume_down" },             .{ ch('m'), "mute" },
        .{ ch('s'), "shuffle" },              .{ ch('r'), "repeat" },                  .{ ch('P'), "play_from_top" },
        .{ ch('e'), "play_later" },           .{ ch('E'), "play_next" },               .{ ch('R'), "station" },
        .{ ch('d'), "remove" },               .{ named(.delete), "remove" },           .{ ch('f'), "favorite" },
        .{ ch('F'), "favorite_playing" },     .{ ch('a'), "add_to_library" },          .{ ch('A'), "add_to_playlist" },
        .{ ch('i'), "details" },              .{ ch('v'), "artwork" },                 .{ ctl('r'), "reload_view" },
        .{ ctl('l'), "redraw" },              .{ ch('q'), "quit" },                    .{ ch('Q'), "quit_and_stop" },
        .{ ch('S'), "sign_in" },              .{ ch('?'), "help" },
    }) |b| try expectBinding(.lists, b[0], b[1]);
    // And in search and filter.
    for ([_]B{
        .{ named(.backspace), "delete_back" }, .{ ctl('u'), "clear" },         .{ named(.enter), "submit" },
        .{ named(.esc), "leave" },             .{ named(.down), "move_down" }, .{ named(.up), "move_up" },
        .{ named(.tab), "switch_scope" },
    }) |b| try expectBinding(.typing, b[0], b[1]);

    // Keys that did nothing still do nothing.
    try expectBinding(.lists, ch('x'), null);
    try expectBinding(.lists, named(.{ .f = 1 }), null);
    try expectBinding(.typing, ch('q'), null);
    // ^c and ^z are fixed, not bindings.
    try expectBinding(.lists, ctl('c'), null);
    try expectBinding(.lists, ctl('z'), null);
    try expectBinding(.typing, ctl('c'), null);
    // Recently Added has no key, as before.
    for (actions) |a| if (std.mem.eql(u8, a.name, "section_recently_added")) try testing.expectEqual(@as(usize, 0), a.defaults.len);
}

test "keys only some terminals tell apart are read as the shared key" {
    // Ctrl+i is Tab; Ctrl+m, Ctrl+j, Shift+Enter and Ctrl+Enter are Enter; Ctrl+h is Backspace;
    // Ctrl+[ is Esc. Ghostty, kitty and foot send these apart; Terminal.app and tmux don't.
    try expectBinding(.lists, ctl('i'), "focus_next");
    try expectBinding(.typing, ctl('i'), "switch_scope");
    try expectBinding(.lists, ctl('m'), "open");
    try expectBinding(.lists, ctl('j'), "open");
    try expectBinding(.lists, shifted(.enter), "open");
    try expectBinding(.lists, .{ .code = .enter, .ctrl = true }, "open");
    try expectBinding(.lists, .{ .code = .enter, .ctrl = true, .shift = true }, "open");
    try expectBinding(.typing, shifted(.enter), "submit");
    try expectBinding(.lists, ctl('h'), "back");
    try expectBinding(.typing, ctl('h'), "delete_back");
    try expectBinding(.lists, ctl('['), "back");
    try expectBinding(.typing, ctl('['), "leave");
    // Ctrl+Shift+letter is Ctrl+letter, however the terminal spells it: kitty, modifyOtherKeys,
    // WezTerm.
    try expectBinding(.lists, .{ .code = .{ .char = 'f' }, .ctrl = true, .shift = true }, "filter");
    try expectBinding(.lists, .{ .code = .{ .char = 'F' }, .ctrl = true, .shift = true }, "filter");
    try expectBinding(.lists, ctl('F'), "filter");
    try expectBinding(.lists, .{ .code = .{ .char = 'I' }, .ctrl = true, .shift = true }, "focus_next");
    // Shift+Space is Space; Shift+character is the shifted character.
    try expectBinding(.lists, .{ .code = .{ .char = ' ' }, .shift = true }, "play_pause");
    try expectBinding(.lists, .{ .code = .{ .char = 'a' }, .shift = true }, "add_to_playlist");
    try expectBinding(.lists, .{ .code = .{ .char = 'A' }, .shift = true }, "add_to_playlist");

    // A fold keeps the other modifiers, as the old encoding sends them.
    try testing.expect(fold(.{ .code = .{ .char = 'i' }, .ctrl = true, .alt = true }).eql(.{ .code = .tab, .alt = true }));
    try testing.expect(fold(.{ .code = .{ .char = 'a' }, .alt = true, .shift = true }).eql(.{ .code = .{ .char = 'A' }, .alt = true }));
    try testing.expect(fold(.{ .code = .enter, .alt = true, .shift = true }).eql(.{ .code = .enter, .alt = true }));
    try testing.expect(fold(.{ .code = .{ .char = 0xfc }, .shift = true }).eql(ch(0xdc))); // ü
    // Shift stays on named keys other than Enter, and Ctrl on other characters.
    try testing.expect(fold(shifted(.up)).eql(shifted(.up)));
    try testing.expect(fold(shifted(.tab)).eql(shifted(.tab)));
    try testing.expect(fold(ctl(' ')).eql(ctl(' ')));
}

test "a binding matches the whole key: Alt+j and Shift+↑ are keys of their own" {
    try expectBinding(.lists, ch('j'), "move_down");
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
    try testing.expectEqual(Fixed.quit, fixed(ctl('c')).?);
    try testing.expectEqual(Fixed.suspend_process, fixed(ctl('z')).?);
    try testing.expectEqual(Fixed.quit, fixed(.{ .code = .{ .char = 'c' }, .ctrl = true, .shift = true }).?);
    try testing.expect(fixed(.{ .code = .{ .char = 'c' }, .ctrl = true, .alt = true }) == null);
    try testing.expect(fixed(ch('c')) == null);
    try testing.expect(fixed(ch('q')) == null);
}

test "action names are fixed: none is renamed or removed, and every action is pinned" {
    try expectNamesPinned(.lists, &pinned_names.lists);
    try expectNamesPinned(.typing, &pinned_names.typing);
}
