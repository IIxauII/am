//! The TUI's keymap: which key does what, outside text input, and the help overlay generated
//! from the same table. One meaning per key across views: lower case acts on the selection,
//! upper case on what is playing (or is the stronger variant).
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

    /// The key that jumps to it, if any.
    pub fn hotkey(s: Section) ?u8 {
        return switch (s) {
            .home => '1',
            .recent => '2',
            .songs => '3',
            .albums => '4',
            .artists => '5',
            .playlists => '6',
            .favorites => '7',
            .radio => '8',
            .charts => '9',
            .recently_added => null,
            .search => '/',
            .queue => '0',
        };
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
    suspend_process,
    refresh,
    redraw,
    /// Sign in to Apple Music again (after closing the sign-in during the session).
    signin,
};

/// The command for a key outside text input, or null when the key does nothing.
pub fn command(key: Key) ?Command {
    if (key.ctrl) return switch (key.code) {
        .char => |c| switch (c) {
            'c' => .quit,
            'z' => .suspend_process,
            'u' => .{ .half = -1 },
            'd' => .{ .half = 1 },
            'f' => .filter,
            'r' => .refresh,
            'l' => .redraw,
            'n' => .{ .move = 1 },
            'p' => .{ .move = -1 },
            else => null,
        },
        else => null,
    };
    return switch (key.code) {
        .up => .{ .move = -1 },
        .down => .{ .move = 1 },
        .left => if (key.shift) .{ .seek = -30 } else .{ .seek = -5 },
        .right => if (key.shift) .{ .seek = 30 } else .{ .seek = 5 },
        .home => .top,
        .end => .bottom,
        .page_up => .{ .page = -1 },
        .page_down => .{ .page = 1 },
        .tab => if (key.shift) .focus_prev else .focus_next,
        .enter => .open,
        .esc, .backspace => .back,
        .delete => .remove,
        .char => |c| charCommand(c),
        else => null,
    };
}

fn charCommand(c: u21) ?Command {
    return switch (c) {
        'j' => .{ .move = 1 },
        'k' => .{ .move = -1 },
        'g' => .top,
        'G' => .bottom,
        'h' => .focus_left,
        'l' => .focus_right,
        '1'...'9' => .{ .section = sectionForDigit(@intCast(c)).? },
        '0' => .{ .section = .queue },
        '/' => .search,
        ' ' => .toggle,
        'n', '>' => .next,
        'p', '<' => .previous,
        '[' => .{ .seek = -30 },
        ']' => .{ .seek = 30 },
        '+', '=' => .{ .volume = 5 },
        '-' => .{ .volume = -5 },
        'm' => .mute,
        's' => .shuffle,
        'r' => .repeat,
        'f' => .favorite,
        'F' => .favorite_now,
        'a' => .add_library,
        'A' => .add_playlist,
        'e' => .play_later,
        'E' => .play_next,
        'P' => .play_container,
        'R' => .station,
        'o' => .go_album,
        'O' => .go_artist,
        'c' => .jump_now,
        'd' => .remove,
        'i' => .info,
        'v' => .image_mode,
        '?' => .help,
        'q' => .quit,
        'Q' => .quit_stop,
        'S' => .signin,
        else => null,
    };
}

fn sectionForDigit(d: u8) ?Section {
    for (sidebar) |s| if (s.hotkey() == d) return s;
    return null;
}

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
    quit,
};

pub fn textCommand(key: Key) ?TextCommand {
    if (key.ctrl) return switch (key.code) {
        .char => |c| switch (c) {
            'c' => .quit,
            'u' => .clear,
            'h' => .delete_back,
            else => null,
        },
        else => null,
    };
    return switch (key.code) {
        .char => |c| if (c >= 0x20) .{ .insert = c } else null,
        .backspace => .delete_back,
        .enter => .submit,
        .esc => .leave,
        .down => .down,
        .up => .up,
        .tab => .toggle_scope,
        else => null,
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

test "keys outside text input" {
    try testing.expectEqual(Command{ .move = 1 }, command(.char('j')).?);
    try testing.expectEqual(Command{ .move = -1 }, command(.{ .code = .up }).?);
    try testing.expectEqual(Command{ .seek = -5 }, command(.{ .code = .left }).?);
    try testing.expectEqual(Command{ .seek = 30 }, command(.{ .code = .right, .shift = true }).?);
    try testing.expectEqual(Command{ .seek = 30 }, command(.char(']')).?);
    try testing.expectEqual(Command{ .section = .albums }, command(.char('4')).?);
    try testing.expectEqual(Command{ .section = .charts }, command(.char('9')).?);
    try testing.expectEqual(Command{ .section = .queue }, command(.char('0')).?);
    try testing.expectEqual(Command.focus_prev, command(.{ .code = .tab, .shift = true }).?);
    try testing.expectEqual(Command.quit, command(.ctrlChar('c')).?);
    try testing.expectEqual(Command.suspend_process, command(.ctrlChar('z')).?);
    try testing.expectEqual(Command.filter, command(.ctrlChar('f')).?);
    try testing.expectEqual(Command.favorite_now, command(.char('F')).?);
    try testing.expectEqual(Command.quit_stop, command(.char('Q')).?);
    try testing.expectEqual(Command{ .volume = 5 }, command(.char('=')).?);
    try testing.expect(command(.char('x')) == null);
    try testing.expect(command(.{ .code = .{ .f = 1 } }) == null);
}

test "every section key goes to its section; text input swallows printable keys" {
    for (sidebar) |s| {
        const k = s.hotkey() orelse continue;
        const cmd = command(.char(k)).?;
        switch (cmd) {
            .section => |got| try testing.expectEqual(s, got),
            .search => try testing.expectEqual(Section.search, s),
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(TextCommand{ .insert = 'q' }, textCommand(.char('q')).?);
    try testing.expectEqual(TextCommand{ .insert = ' ' }, textCommand(.char(' ')).?);
    try testing.expectEqual(TextCommand{ .insert = '4' }, textCommand(.char('4')).?);
    try testing.expectEqual(TextCommand.quit, textCommand(.ctrlChar('c')).?);
    try testing.expectEqual(TextCommand.clear, textCommand(.ctrlChar('u')).?);
    try testing.expectEqual(TextCommand.leave, textCommand(.{ .code = .esc }).?);
    try testing.expectEqual(TextCommand.submit, textCommand(.{ .code = .enter }).?);
}

test "every help key names a binding" {
    // A spot check that the help table and the keymap agree on the main keys.
    for ([_]u21{ 'f', 'F', 'a', 'A', 'e', 'E', 'P', 'R', 'o', 'O', 'c', 'd', 'i', 'v', '?', 'q', 'Q', 's', 'r', 'm', 'n', 'p', 'S' }) |c|
        try testing.expect(command(.char(c)) != null);
}
