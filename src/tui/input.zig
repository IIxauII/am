//! Turns the bytes a terminal sends into keys, pastes and replies to our queries.
//!
//! Escape sequences can be split across reads, so the decoder keeps what it can't finish yet.
//! A lone ESC is ambiguous (the Escape key, or the start of a sequence): the app calls
//! `flushPending` after ~30 ms without input, which decodes whatever is left as keys. A paste
//! and a reply to the startup query (kitty graphics, cell size, device attributes) are never
//! keys: they wait for their end however long it takes.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Key = struct {
    code: Code,
    ctrl: bool = false,
    alt: bool = false,
    /// Set for keys that aren't characters (Shift-Tab, Shift-Up). A shifted character
    /// arrives as the character itself ('F').
    shift: bool = false,
    /// Only in reports that carry a modifier parameter (kitty-style and xterm-style ones). A key
    /// with Super does nothing in the TUI: few terminals report it, and none the same way.
    super: bool = false,

    pub const Code = union(enum) {
        char: u21,
        enter,
        esc,
        tab,
        backspace,
        delete,
        insert,
        up,
        down,
        left,
        right,
        home,
        end,
        page_up,
        page_down,
        /// F1 is 1.
        f: u8,
    };

    pub fn char(c: u21) Key {
        return .{ .code = .{ .char = c } };
    }

    pub fn ctrlChar(c: u21) Key {
        return .{ .code = .{ .char = c }, .ctrl = true };
    }

    pub fn eql(a: Key, b: Key) bool {
        return std.meta.eql(a, b);
    }
};

pub const Event = union(enum) {
    key: KeyEvent,
    /// Bracketed paste content, verbatim.
    paste: []const u8,
    /// A kitty graphics reply `ESC _G i=<id>;OK ESC \`.
    kitty_graphics_ok: KittyReply,
    /// Any other kitty graphics reply, such as `ENOENT:…`.
    kitty_graphics_error: KittyReply,
    /// The parameters of a primary device attributes reply `ESC [ ? <params> c`.
    device_attributes: []const u8,
    /// `ESC [ 6 ; <h> ; <w> t`: the cell size in pixels.
    cell_size: CellSize,
    /// `ESC [ 48 ; <rows> ; <cols> ; <h_px> ; <w_px> t`: an in-band resize report (mode 2048).
    resize: Resize,

    pub const KeyEvent = struct {
        key: Key,
        /// Other keys came in the same read, counting what a flush would decode at its end.
        /// A terminal that sends one press as several keys does this (Konsole's Shift-F1 is
        /// Alt-O `2` `P`), and so does typing faster than the app reads.
        together: bool = false,
    };
    pub const KittyReply = struct { id: u32, message: []const u8 };
    pub const CellSize = struct { w: u16, h: u16 };
    pub const Resize = struct { rows: u16, cols: u16, h_px: u16, w_px: u16 };
};

/// Pastes longer than this are cut off; the rest is dropped.
pub const max_paste = 1 << 20;

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
/// Longest escape sequence or reply we wait for before giving up on it.
const max_sequence = 4096;

pub const Decoder = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    in_paste: bool = false,
    /// Paste content from earlier feeds, while a paste spans several reads.
    paste: std.ArrayList(u8) = .empty,
    /// The open paste began in an earlier feed, and its start is in `paste`.
    paste_open: bool = false,
    /// `paste` was returned in an event and is freed for reuse at the next feed.
    paste_emitted: bool = false,
    /// Whether the last feed's bytes hold several keys, for `KeyEvent.together`. Null until
    /// worked out, at their first key.
    feed_has_several_keys: ?bool = null,

    pub fn init(gpa: Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Decoder) void {
        d.buf.deinit(d.gpa);
        d.paste.deinit(d.gpa);
        d.* = undefined;
    }

    /// Adds bytes read from the terminal. Slices in events returned before stop being valid.
    pub fn feed(d: *Decoder, bytes: []const u8) Allocator.Error!void {
        d.feed_has_several_keys = null;
        if (d.paste_emitted) {
            d.paste.clearRetainingCapacity();
            d.paste_emitted = false;
        }
        // An open paste moves to `paste`, all but a tail that may be the start of its end marker.
        if (d.in_paste and std.mem.find(u8, d.buf.items[d.pos..], paste_end) == null) {
            const open = d.buf.items[d.pos..];
            const keep = @min(open.len, paste_end.len - 1);
            const moved = open[0 .. open.len - keep];
            const room = max_paste -| d.paste.items.len;
            try d.paste.appendSlice(d.gpa, moved[0..@min(moved.len, room)]);
            d.pos += moved.len;
            d.paste_open = true;
        }
        if (d.pos > 0) {
            const rest = d.buf.items[d.pos..];
            std.mem.copyForwards(u8, d.buf.items[0..rest.len], rest);
            d.buf.shrinkRetainingCapacity(rest.len);
            d.pos = 0;
        }
        try d.buf.appendSlice(d.gpa, bytes);
        // The end of a spanning paste is appended in `next`, which can't fail.
        if (d.in_paste) try d.paste.ensureUnusedCapacity(d.gpa, @min(d.buf.items.len, max_paste -| d.paste.items.len));
    }

    /// The next complete event, or null when the rest needs more bytes.
    pub fn next(d: *Decoder) ?Event {
        return d.decode(false);
    }

    /// Like `next`, but an unfinished sequence is decoded as keys (a lone ESC is Escape). Call
    /// it after a short silence, until it returns null.
    pub fn flushPending(d: *Decoder) ?Event {
        return d.decode(true);
    }

    /// Bytes are waiting that `flushPending` would decode. False inside a paste or a reply,
    /// which wait for their end however long it takes.
    pub fn pending(d: *const Decoder) bool {
        var ahead = d.cursor();
        return ahead.next(true) != null;
    }

    fn cursor(d: *const Decoder) Cursor {
        return .{ .bytes = d.buf.items, .pos = d.pos, .in_paste = d.in_paste };
    }

    fn decode(d: *Decoder, force: bool) ?Event {
        var at = d.cursor();
        const from = at;
        const found = at.next(force);
        d.pos = at.pos;
        d.in_paste = at.in_paste;
        var event = found orelse return null;
        switch (event) {
            .paste => |*content| content.* = d.finishPaste(content.*),
            .key => |*k| {
                const several = d.feed_has_several_keys orelse from.severalKeys();
                d.feed_has_several_keys = several;
                k.together = several;
            },
            else => {},
        }
        return event;
    }

    /// A paste's whole content, from the part of it in `buf` (`tail`) and what earlier feeds
    /// moved to `paste`.
    fn finishPaste(d: *Decoder, tail: []const u8) []const u8 {
        if (!d.paste_open) return tail[0..@min(tail.len, max_paste)];
        d.paste_open = false;
        const room = max_paste -| d.paste.items.len;
        d.paste.appendSliceAssumeCapacity(tail[0..@min(tail.len, room)]);
        d.paste_emitted = true;
        return d.paste.items;
    }
};

/// Where decoding stands in some bytes: the position, and whether it is inside a paste.
/// `Decoder.decode` moves one through the buffer; a copy looks ahead without moving it.
const Cursor = struct {
    bytes: []const u8,
    pos: usize,
    in_paste: bool,

    /// The next event, or null when the rest needs more bytes. `force` decodes an unfinished
    /// sequence as keys, as a flush does. A paste comes with only the part of it in `bytes`.
    fn next(c: *Cursor, force: bool) ?Event {
        while (true) {
            const rest = c.bytes[c.pos..];
            if (c.in_paste) {
                const end = std.mem.find(u8, rest, paste_end) orelse return null;
                c.in_paste = false;
                c.pos += end + paste_end.len;
                return .{ .paste = rest[0..end] };
            }
            if (rest.len == 0) return null;
            switch (parse(rest, force)) {
                .incomplete => return null,
                .skip => |n| c.pos += n,
                .paste_start => |n| {
                    c.pos += n;
                    c.in_paste = true;
                },
                .event => |e| {
                    c.pos += e.len;
                    return e.event;
                },
            }
        }
    }

    /// Whether more than one key is left, counting what a flush would decode at the end.
    fn severalKeys(from: Cursor) bool {
        var ahead = from;
        var keys: usize = 0;
        while (ahead.next(true)) |e| {
            if (e == .key) keys += 1;
            if (keys > 1) return true;
        }
        return false;
    }
};

const Parsed = union(enum) {
    incomplete,
    /// Bytes that mean nothing to us.
    skip: usize,
    paste_start: usize,
    event: struct { len: usize, event: Event },

    fn key(len: usize, k: Key) Parsed {
        return .{ .event = .{ .len = len, .event = .{ .key = .{ .key = k } } } };
    }

    fn code(len: usize, c: Key.Code) Parsed {
        return key(len, .{ .code = c });
    }
};

fn parse(bytes: []const u8, force: bool) Parsed {
    if (bytes[0] != 0x1b) return parsePlain(bytes, force);
    if (bytes.len == 1) return if (force) .code(1, .esc) else .incomplete;
    return switch (bytes[1]) {
        '[' => parseCsi(bytes, force),
        'O' => parseSs3(bytes, force),
        '_' => parseApc(bytes, force),
        else => withAlt(bytes, force),
    };
}

/// ESC then a key: that key with Alt.
fn withAlt(bytes: []const u8, force: bool) Parsed {
    const inner = parse(bytes[1..], force);
    return switch (inner) {
        .incomplete => .incomplete,
        .event => |e| switch (e.event) {
            .key => |k| blk: {
                var alt = k.key;
                alt.alt = true;
                break :blk .key(e.len + 1, alt);
            },
            else => .code(1, .esc),
        },
        else => .code(1, .esc),
    };
}

/// ESC followed by `bytes[1]` as an Alt-modified character, when what follows is not a
/// sequence after all.
fn altChar(bytes: []const u8) Parsed {
    return .key(2, .{ .code = .{ .char = bytes[1] }, .alt = true });
}

fn parsePlain(bytes: []const u8, force: bool) Parsed {
    const b = bytes[0];
    switch (b) {
        '\r', '\n' => return .code(1, .enter),
        '\t' => return .code(1, .tab),
        0x7f, 0x08 => return .code(1, .backspace),
        0x00 => return .key(1, .ctrlChar(' ')),
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => return .key(1, .ctrlChar('a' + @as(u21, b) - 1)),
        0x1c...0x1f => return .key(1, .ctrlChar("\\]^_"[b - 0x1c])),
        0x1b => unreachable,
        0x20...0x7e => return .key(1, .char(b)),
        else => {},
    }
    const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .skip = 1 };
    if (len > bytes.len) {
        // Wait for the rest unless a byte that can't continue it is already here.
        for (bytes[1..]) |c| if (c & 0xc0 != 0x80) return .{ .skip = 1 };
        return if (force) .{ .skip = 1 } else .incomplete;
    }
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .skip = 1 };
    return .key(len, .char(cp));
}

const Params = struct {
    values: [8]u32 = @splat(0),
    len: usize = 0,

    /// `n`-th parameter, 0 when missing or empty. Sub-parameters after ':' are ignored.
    fn get(p: Params, n: usize) u32 {
        return if (n < p.len) p.values[n] else 0;
    }

    fn parse(text: []const u8) Params {
        var p: Params = .{};
        var sub = false;
        p.len = 1;
        for (text) |c| switch (c) {
            '0'...'9' => if (!sub and p.len <= p.values.len) {
                const v = &p.values[p.len - 1];
                v.* = v.* *| 10 +| (c - '0');
            },
            ':' => sub = true,
            ';' => {
                sub = false;
                p.len += 1;
            },
            else => {},
        };
        p.len = @min(p.len, p.values.len);
        return p;
    }
};

/// The modifier parameter: 1 + bits (shift 1, alt 2, ctrl 4, super 8). Bit 8 is Super in kitty's
/// encoding, which Ghostty, kitty, Alacritty and foot use even without the protocol; it is xterm's
/// Meta, which is rare. Higher bits (hyper, meta, the locks) are dropped.
fn applyModifiers(k: Key, param: u32) Key {
    var out = k;
    if (param < 2) return out;
    const bits = param - 1;
    if (bits & 1 != 0) out.shift = true;
    if (bits & 2 != 0) out.alt = true;
    if (bits & 4 != 0) out.ctrl = true;
    if (bits & 8 != 0) out.super = true;
    return out;
}

fn parseCsi(bytes: []const u8, force: bool) Parsed {
    var i: usize = 2;
    var marker: u8 = 0;
    if (i < bytes.len and switch (bytes[i]) {
        '<', '=', '>', '?' => true,
        else => false,
    }) {
        marker = bytes[i];
        i += 1;
    }
    const params_start = i;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) i += 1;
    const params_end = i;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) i += 1;
    if (i >= bytes.len) {
        if (bytes.len > max_sequence) return altChar(bytes);
        // A reply split across reads waits for its end, through a flush too: its bytes are
        // never keys.
        if (force and !canStillBeReply(marker, bytes[params_start..])) return altChar(bytes);
        return .incomplete;
    }
    const final = bytes[i];
    if (final < 0x40 or final > 0x7e) return altChar(bytes);
    const len = i + 1;
    const raw = bytes[params_start..params_end];
    const p: Params = .parse(raw);

    if (marker == '?') {
        if (final == 'c') return .{ .event = .{ .len = len, .event = .{ .device_attributes = raw } } };
        return .{ .skip = len };
    }
    if (marker != 0 or params_end != i) return .{ .skip = len };

    const plain: ?Key.Code = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        'S' => .{ .f = 4 },
        // CSI R without "1;" is a cursor position report.
        'R' => if (p.get(0) <= 1) .{ .f = 3 } else null,
        else => null,
    };
    if (plain) |c| return .key(len, applyModifiers(.{ .code = c }, p.get(1)));

    switch (final) {
        'Z' => return .key(len, .{ .code = .tab, .shift = true }),
        '~' => {
            const n = p.get(0);
            if (n == 200) return .{ .paste_start = len };
            if (n == 27) {
                // xterm modifyOtherKeys: CSI 27 ; mod ; code ~
                const k = codepointKey(p.get(2)) orelse return .{ .skip = len };
                return .key(len, applyModifiers(k, p.get(1)));
            }
            const c = tildeKey(n) orelse return .{ .skip = len };
            return .key(len, applyModifiers(.{ .code = c }, p.get(1)));
        },
        'u' => {
            // kitty keyboard protocol: CSI code ; mod u
            const k = codepointKey(p.get(0)) orelse return .{ .skip = len };
            return .key(len, applyModifiers(k, p.get(1)));
        },
        't' => switch (p.get(0)) {
            6 => return .{ .event = .{ .len = len, .event = .{ .cell_size = .{ .h = clamp16(p.get(1)), .w = clamp16(p.get(2)) } } } },
            48 => return .{ .event = .{ .len = len, .event = .{ .resize = .{
                .rows = clamp16(p.get(1)),
                .cols = clamp16(p.get(2)),
                .h_px = clamp16(p.get(3)),
                .w_px = clamp16(p.get(4)),
            } } } },
            else => return .{ .skip = len },
        },
        else => return .{ .skip = len },
    }
}

/// Whether an unfinished CSI, `rest` after its marker, can still be one of the replies to the
/// startup query (`graphics.query`) that are CSIs: DA1, or any other with `?`, which no key
/// has, and the cell size `6 ; <h> ; <w> t`. `ESC [` alone is Alt-[, not one.
fn canStillBeReply(marker: u8, rest: []const u8) bool {
    if (marker == '?') return true;
    if (marker != 0 or rest.len == 0 or rest[0] != '6') return false;
    if (rest.len > 1 and rest[1] != ';') return false;
    var params: usize = 1;
    for (rest[1..]) |c| switch (c) {
        '0'...'9' => {},
        ';' => params += 1,
        else => return false,
    };
    return params <= 3;
}

fn clamp16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn tildeKey(n: u32) ?Key.Code {
    return switch (n) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11...15 => .{ .f = @intCast(n - 10) },
        17...21 => .{ .f = @intCast(n - 11) },
        23...26 => .{ .f = @intCast(n - 12) },
        28, 29 => .{ .f = @intCast(n - 13) },
        31...34 => .{ .f = @intCast(n - 14) },
        else => null,
    };
}

/// The key for a code point in CSI u / modifyOtherKeys reports.
fn codepointKey(cp: u32) ?Key {
    return switch (cp) {
        13 => .{ .code = .enter },
        9 => .{ .code = .tab },
        27 => .{ .code = .esc },
        127, 8 => .{ .code = .backspace },
        0x20...0x7e, 0x80...0xd7ff, 0xe000...0x10ffff => .char(@intCast(cp)),
        else => null,
    };
}

fn parseSs3(bytes: []const u8, force: bool) Parsed {
    if (bytes.len < 3) return if (force) altChar(bytes) else .incomplete;
    const c: Key.Code = switch (bytes[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        'R' => .{ .f = 3 },
        'S' => .{ .f = 4 },
        'M' => .enter,
        else => return altChar(bytes),
    };
    return .code(3, c);
}

fn parseApc(bytes: []const u8, force: bool) Parsed {
    if (bytes.len < 3) return if (force) altChar(bytes) else .incomplete;
    if (bytes[2] != 'G') return altChar(bytes);
    const st = switch (kittyReplyEnd(bytes[3..])) {
        .st => |i| i,
        // A reply split across reads waits for its end, through a flush too: its bytes are
        // never keys. Only one longer than any reply gives up.
        .open => return if (bytes.len > max_sequence) altChar(bytes) else .incomplete,
        .bad => return altChar(bytes),
    };
    const body = bytes[3..][0..st];
    const len = 3 + st + 2;
    const semi = std.mem.findScalar(u8, body, ';') orelse body.len;
    const message = if (semi < body.len) body[semi + 1 ..] else "";
    var id: u32 = 0;
    var keys = std.mem.splitScalar(u8, body[0..semi], ',');
    while (keys.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "i=")) id = std.fmt.parseInt(u32, kv[2..], 10) catch 0;
    }
    const reply: Event.KittyReply = .{ .id = id, .message = message };
    const event: Event = if (std.mem.eql(u8, message, "OK")) .{ .kitty_graphics_ok = reply } else .{ .kitty_graphics_error = reply };
    return .{ .event = .{ .len = len, .event = event } };
}

const ReplyEnd = union(enum) {
    /// Where the closing `ESC \` starts.
    st: usize,
    /// All of it can be the start of a reply.
    open,
    /// It can't be a reply.
    bad,
};

/// How a kitty graphics reply goes on after `ESC _ G`: control data such as `i=31,p=1`, then
/// `;` and a message, then `ESC \`, with no other ESC. Once its `ESC \` is here it is a reply,
/// whatever its control data. Until then it must look like one, so that keys someone types
/// after Alt-_ G are only held while they could still be a reply.
fn kittyReplyEnd(body: []const u8) ReplyEnd {
    const esc = std.mem.findScalar(u8, body, 0x1b) orelse body.len;
    if (esc + 1 < body.len) return if (body[esc + 1] == '\\') .{ .st = esc } else .bad;
    return if (canStartKittyReply(body[0..esc])) .open else .bad;
}

/// Whether `text` can be how a kitty graphics reply's control data and message begin.
fn canStartKittyReply(text: []const u8) bool {
    // Control data is `name=value` pairs, each name one letter; the message after `;` is free.
    var at: enum { name, equals, value } = .name;
    for (text) |c| {
        at = switch (at) {
            .name => switch (c) {
                'a'...'z', 'A'...'Z' => .equals,
                ';' => return true,
                else => return false,
            },
            .equals => if (c == '=') .value else return false,
            .value => switch (c) {
                '0'...'9', 'a'...'z', 'A'...'Z', '-' => .value,
                ',' => .name,
                ';' => return true,
                else => return false,
            },
        };
    }
    return true;
}

// ---- Tests ----

const testing = std.testing;

/// Feeds `bytes` and collects every event, then (if `flush`) the forced ones.
fn decodeAll(d: *Decoder, bytes: []const u8, flush: bool, out: *std.ArrayList(Event)) !void {
    try d.feed(bytes);
    while (d.next()) |e| try out.append(testing.allocator, e);
    if (flush) while (d.flushPending()) |e| try out.append(testing.allocator, e);
}

fn expectKeys(bytes: []const u8, expected: []const Key) !void {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(testing.allocator);
    try decodeAll(&d, bytes, true, &events);
    if (events.items.len != expected.len) {
        std.debug.print("bytes {x}: got {d} events, want {d}\n", .{ bytes, events.items.len, expected.len });
        for (events.items) |e| std.debug.print("  {any}\n", .{e});
        return error.TestUnexpectedResult;
    }
    for (expected, events.items) |want, got| {
        try testing.expect(got == .key);
        if (!want.eql(got.key.key)) {
            std.debug.print("bytes {x}: want {any}, got {any}\n", .{ bytes, want, got.key.key });
            return error.TestUnexpectedResult;
        }
    }
}

fn plainKey(c: Key.Code) Key {
    return .{ .code = c };
}

test "plain characters, UTF-8 and control keys" {
    try expectKeys("aZ ~", &.{ .char('a'), .char('Z'), .char(' '), .char('~') });
    try expectKeys("é中🎵", &.{ .char(0xe9), .char(0x4e2d), .char(0x1f3b5) });
    try expectKeys("\r\n\t\x7f\x08", &.{ plainKey(.enter), plainKey(.enter), plainKey(.tab), plainKey(.backspace), plainKey(.backspace) });
    try expectKeys("\x01\x03\x04\x15\x1a", &.{ .ctrlChar('a'), .ctrlChar('c'), .ctrlChar('d'), .ctrlChar('u'), .ctrlChar('z') });
    try expectKeys("\x00\x1c\x1d\x1e\x1f", &.{ .ctrlChar(' '), .ctrlChar('\\'), .ctrlChar(']'), .ctrlChar('^'), .ctrlChar('_') });
    try expectKeys("\x0b\x0c\x0e", &.{ .ctrlChar('k'), .ctrlChar('l'), .ctrlChar('n') });
}

test "invalid UTF-8 is dropped" {
    try expectKeys("\xffa\x80b", &.{ .char('a'), .char('b') });
    // A lead byte cut off by a non-continuation byte.
    try expectKeys("\xe4a", &.{.char('a')});
    // A truncated sequence at the end is dropped on flush.
    try expectKeys("x\xe4\xb8", &.{.char('x')});
}

test "CSI and SS3 cursor keys, home and end" {
    try expectKeys("\x1b[A\x1b[B\x1b[C\x1b[D", &.{ plainKey(.up), plainKey(.down), plainKey(.right), plainKey(.left) });
    try expectKeys("\x1bOA\x1bOB\x1bOC\x1bOD", &.{ plainKey(.up), plainKey(.down), plainKey(.right), plainKey(.left) });
    try expectKeys("\x1b[H\x1b[F\x1bOH\x1bOF", &.{ plainKey(.home), plainKey(.end), plainKey(.home), plainKey(.end) });
    try expectKeys("\x1bOM", &.{plainKey(.enter)});
}

test "modifiers on cursor keys" {
    try expectKeys("\x1b[1;2A", &.{.{ .code = .up, .shift = true }});
    try expectKeys("\x1b[1;3B", &.{.{ .code = .down, .alt = true }});
    try expectKeys("\x1b[1;4C", &.{.{ .code = .right, .shift = true, .alt = true }});
    try expectKeys("\x1b[1;5D", &.{.{ .code = .left, .ctrl = true }});
    try expectKeys("\x1b[1;6H", &.{.{ .code = .home, .ctrl = true, .shift = true }});
    try expectKeys("\x1b[1;7F", &.{.{ .code = .end, .ctrl = true, .alt = true }});
    try expectKeys("\x1b[1;8A", &.{.{ .code = .up, .ctrl = true, .alt = true, .shift = true }});
    try expectKeys("\x1b[1;1A", &.{plainKey(.up)});
}

test "modifier bit 8 is Super, not Alt" {
    // kitty's protocol, and Ghostty, kitty, Alacritty and foot without it: Super-Up is `CSI 1;9A`.
    try expectKeys("\x1b[1;9A", &.{.{ .code = .up, .super = true }});
    try expectKeys("\x1b[97;9u", &.{.{ .code = .{ .char = 'a' }, .super = true }});
    // Ghostty's Super-Enter, in the modifyOtherKeys form.
    try expectKeys("\x1b[27;9;13~", &.{.{ .code = .enter, .super = true }});
    // Super with the others: Alt (2), Ctrl (4), Shift (1).
    try expectKeys("\x1b[97;11u", &.{.{ .code = .{ .char = 'a' }, .alt = true, .super = true }});
    try expectKeys("\x1b[3;13~", &.{.{ .code = .delete, .ctrl = true, .super = true }});
    try expectKeys("\x1b[1;10C", &.{.{ .code = .right, .shift = true, .super = true }});
}

test "tilde keys" {
    try expectKeys("\x1b[1~\x1b[7~\x1b[4~\x1b[8~", &.{ plainKey(.home), plainKey(.home), plainKey(.end), plainKey(.end) });
    try expectKeys("\x1b[2~\x1b[3~\x1b[5~\x1b[6~", &.{ plainKey(.insert), plainKey(.delete), plainKey(.page_up), plainKey(.page_down) });
    try expectKeys("\x1b[3;5~", &.{.{ .code = .delete, .ctrl = true }});
    try expectKeys("\x1b[5;2~", &.{.{ .code = .page_up, .shift = true }});
    try expectKeys("\x1b[11~\x1b[12~\x1b[13~\x1b[14~\x1b[15~", &.{ plainKey(.{ .f = 1 }), plainKey(.{ .f = 2 }), plainKey(.{ .f = 3 }), plainKey(.{ .f = 4 }), plainKey(.{ .f = 5 }) });
    try expectKeys("\x1b[17~\x1b[18~\x1b[19~\x1b[20~\x1b[21~", &.{ plainKey(.{ .f = 6 }), plainKey(.{ .f = 7 }), plainKey(.{ .f = 8 }), plainKey(.{ .f = 9 }), plainKey(.{ .f = 10 }) });
    try expectKeys("\x1b[23~\x1b[24~\x1b[24;5~", &.{ plainKey(.{ .f = 11 }), plainKey(.{ .f = 12 }), .{ .code = .{ .f = 12 }, .ctrl = true } });
    try expectKeys("\x1b[99~x", &.{.char('x')});
}

test "function keys F1-F4" {
    try expectKeys("\x1bOP\x1bOQ\x1bOR\x1bOS", &.{ plainKey(.{ .f = 1 }), plainKey(.{ .f = 2 }), plainKey(.{ .f = 3 }), plainKey(.{ .f = 4 }) });
    try expectKeys("\x1b[1;5P\x1b[1;2R", &.{ .{ .code = .{ .f = 1 }, .ctrl = true }, .{ .code = .{ .f = 3 }, .shift = true } });
    // A cursor position report is not F3.
    try expectKeys("\x1b[12;40Rx", &.{.char('x')});
}

test "shift-tab, CSI u and modifyOtherKeys" {
    try expectKeys("\x1b[Z", &.{.{ .code = .tab, .shift = true }});
    try expectKeys("\x1b[97;5u", &.{.ctrlChar('a')});
    try expectKeys("\x1b[13u\x1b[27u\x1b[127;3u", &.{ plainKey(.enter), plainKey(.esc), .{ .code = .backspace, .alt = true } });
    try expectKeys("\x1b[27;5;13~", &.{.{ .code = .enter, .ctrl = true }});
    try expectKeys("\x1b[97:65;2u", &.{.{ .code = .{ .char = 'a' }, .shift = true }});
}

test "alt is an ESC prefix" {
    try expectKeys("\x1bx", &.{.{ .code = .{ .char = 'x' }, .alt = true }});
    try expectKeys("\x1bé", &.{.{ .code = .{ .char = 0xe9 }, .alt = true }});
    try expectKeys("\x1b\x7f", &.{.{ .code = .backspace, .alt = true }});
    try expectKeys("\x1b\r", &.{.{ .code = .enter, .alt = true }});
    try expectKeys("\x1b\x01", &.{.{ .code = .{ .char = 'a' }, .ctrl = true, .alt = true }});
    try expectKeys("\x1b\x1b[A", &.{.{ .code = .up, .alt = true }});
    try expectKeys("\x1bP\x1b]", &.{ .{ .code = .{ .char = 'P' }, .alt = true }, .{ .code = .{ .char = ']' }, .alt = true } });
    try expectKeys("\x1bOz", &.{ .{ .code = .{ .char = 'O' }, .alt = true }, .char('z') });
    try expectKeys("\x1b_x", &.{ .{ .code = .{ .char = '_' }, .alt = true }, .char('x') });
}

test "each key says whether other keys came with it in one read" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    // Konsole sends Shift-F1 as Alt-O, `2`, `P`: one press, three keys in one read.
    try d.feed("\x1bO2P");
    for ([_]Key{ .{ .code = .{ .char = 'O' }, .alt = true }, .char('2'), .char('P') }) |want| {
        const k = d.next().?.key;
        try testing.expect(k.key.eql(want));
        try testing.expect(k.together);
    }
    try testing.expectEqual(null, d.next());
    // Two keys typed faster than the app reads.
    try d.feed("jk");
    try testing.expect(d.next().?.key.together);
    try testing.expect(d.next().?.key.together);

    // One key in a read is alone, a sequence split across reads too.
    try d.feed("j");
    try testing.expect(!d.next().?.key.together);
    try d.feed("\x1b[1;5");
    try testing.expectEqual(null, d.next());
    try d.feed("A");
    const up = d.next().?.key;
    try testing.expect(up.key.eql(.{ .code = .up, .ctrl = true }));
    try testing.expect(!up.together);

    // A paste or a reply in the same read isn't a key.
    try d.feed("\x1b[200~xy\x1b[201~k\x1b_Gi=31;OK\x1b\\");
    try testing.expectEqualStrings("xy", d.next().?.paste);
    try testing.expect(!d.next().?.key.together);
    try testing.expectEqual(31, d.next().?.kitty_graphics_ok.id);

    // A lone ESC is alone after the wait; one that came after a key came with it.
    try d.feed("\x1b");
    try testing.expectEqual(null, d.next());
    const esc = d.flushPending().?.key;
    try testing.expect(esc.key.eql(plainKey(.esc)));
    try testing.expect(!esc.together);
    try d.feed("x\x1b");
    try testing.expect(d.next().?.key.together);
    try testing.expectEqual(null, d.next());
    try testing.expect(d.flushPending().?.key.together);
}

test "a lone ESC waits for the flush" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b");
    try testing.expectEqual(null, d.next());
    try testing.expect(d.pending());
    const e = d.flushPending().?;
    try testing.expect(e.key.key.eql(plainKey(.esc)));
    try testing.expectEqual(null, d.flushPending());
    try testing.expect(!d.pending());

    // Two ESCs: Alt-Escape after the flush.
    try d.feed("\x1b\x1b");
    try testing.expectEqual(null, d.next());
    try testing.expect(d.flushPending().?.key.key.eql(.{ .code = .esc, .alt = true }));
}

test "unfinished sequences flush as keys" {
    try expectKeys("\x1b[", &.{.{ .code = .{ .char = '[' }, .alt = true }});
    try expectKeys("\x1b[1;", &.{ .{ .code = .{ .char = '[' }, .alt = true }, .char('1'), .char(';') });
    try expectKeys("\x1bO", &.{.{ .code = .{ .char = 'O' }, .alt = true }});
    // Past what a cell-size report can be.
    try expectKeys("\x1b[61", &.{ .{ .code = .{ .char = '[' }, .alt = true }, .char('6'), .char('1') });
    try expectKeys("\x1b[6;1;2;", &.{ .{ .code = .{ .char = '[' }, .alt = true }, .char('6'), .char(';'), .char('1'), .char(';'), .char('2'), .char(';') });
    // A malformed CSI (a control before the final byte) is Alt-[ and the rest.
    try expectKeys("\x1b[\r", &.{ .{ .code = .{ .char = '[' }, .alt = true }, plainKey(.enter) });
}

test "sequences split across feeds" {
    const all = "a\x1b[1;5A\x1bOP\x1b[200~hi\x1b[201~é\x1b_Gi=31;OK\x1b\\\x1b[?62;22c\x1b[6;20;10t\x1b[48;40;120;800;1200t";
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    try testing.expectEqual(9, try describeRead(all, &want));
    // Every split point gives the same events.
    for (1..all.len) |cut| try expectSplitGives(all, cut, false, want.items);
}

test "every byte fed alone" {
    const all = "x\x1b[3;5~\x1b[200~p\x1b[2xq\x1b[201~\x1b_Gi=31;ENOENT:gone\x1b\\y";
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    var texts: std.ArrayList(u8) = .empty;
    defer texts.deinit(testing.allocator);
    for (all) |b| {
        try d.feed(&.{b});
        while (d.next()) |e| switch (e) {
            .paste => |p| try texts.print(testing.allocator, "paste:{s}|", .{p}),
            .kitty_graphics_error => |r| try texts.print(testing.allocator, "kerr:{d}:{s}|", .{ r.id, r.message }),
            .key => |k| try texts.print(testing.allocator, "key:{any}|", .{k.key.code}),
            else => try texts.appendSlice(testing.allocator, "other|"),
        };
    }
    try testing.expectEqualStrings(
        "key:.{ .char = 120 }|key:.{ .delete = void }|paste:p\x1b[2xq|kerr:31:ENOENT:gone|key:.{ .char = 121 }|",
        texts.items,
    );
}

test "bracketed paste" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("a\x1b[200~hello\r\nwörld\x1b[201~b");
    try testing.expect(d.next().?.key.key.eql(.char('a')));
    try testing.expectEqualStrings("hello\r\nwörld", d.next().?.paste);
    try testing.expect(d.next().?.key.key.eql(.char('b')));
    try testing.expectEqual(null, d.next());

    // Keys inside a paste are text; a paste waits for its end even through a flush.
    try d.feed("\x1b[200~\x1b[A\x03");
    try testing.expectEqual(null, d.next());
    try testing.expectEqual(null, d.flushPending());
    try testing.expect(!d.pending());
    try d.feed("more\x1b[20");
    try testing.expectEqual(null, d.next());
    try d.feed("1~");
    try testing.expectEqualStrings("\x1b[A\x03more", d.next().?.paste);

    // Empty paste; a stray end marker is ignored.
    try d.feed("\x1b[200~\x1b[201~\x1b[201~z");
    try testing.expectEqualStrings("", d.next().?.paste);
    try testing.expect(d.next().?.key.key.eql(.char('z')));
}

test "two pastes in one feed keep their slices" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[200~one");
    try testing.expectEqual(null, d.next());
    try d.feed("\x1b[201~\x1b[200~two\x1b[201~\x1b[200~thr");
    const first = d.next().?.paste;
    const second = d.next().?.paste;
    try testing.expectEqual(null, d.next());
    try testing.expectEqualStrings("one", first);
    try testing.expectEqualStrings("two", second);
    try d.feed("ee\x1b[201~");
    try testing.expectEqualStrings("three", d.next().?.paste);
}

test "a long paste over many feeds" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed(paste_start);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    for (0..500) |i| {
        var line: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&line, "line {d}\n", .{i});
        try expected.appendSlice(testing.allocator, s);
        try d.feed(s);
        try testing.expectEqual(null, d.next());
    }
    try d.feed(paste_end);
    try testing.expectEqualStrings(expected.items, d.next().?.paste);
    // The buffer did not keep the whole paste.
    try testing.expect(d.buf.items.len < 64);
}

test "kitty graphics replies" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b_Gi=31;OK\x1b\\\x1b_Gi=7,p=1;ENOENT:image not found\x1b\\\x1b_G;OK\x1b\\");
    const ok = d.next().?.kitty_graphics_ok;
    try testing.expectEqual(31, ok.id);
    const err = d.next().?.kitty_graphics_error;
    try testing.expectEqual(7, err.id);
    try testing.expectEqualStrings("ENOENT:image not found", err.message);
    try testing.expectEqual(0, d.next().?.kitty_graphics_ok.id);
    try testing.expectEqual(null, d.next());

    // Whole, it is a reply whatever its control data: only an unfinished one must look like one.
    try d.feed("\x1b_Gi=31,x.y z;OK\x1b\\");
    try testing.expectEqual(31, d.next().?.kitty_graphics_ok.id);
    try testing.expectEqual(null, d.next());
}

test "the answer to the startup query split across reads stays together through the wait" {
    // What a terminal answers to `graphics.query`: the kitty graphics reply (OK or an error),
    // the cell size, then DA1.
    const answers = [_][]const []const u8{
        &.{ "\x1b_Gi=31;OK\x1b\\", "\x1b[6;20;10t", "\x1b[?62;22c" },
        &.{ "\x1b_Gi=31,p=1;ENOENT:image not found\x1b\\", "\x1b[6;20;10t", "\x1b[?62;22c" },
    };
    for (answers) |replies| {
        const all = try std.mem.concat(testing.allocator, u8, replies);
        defer testing.allocator.free(all);
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(testing.allocator);
        try testing.expectEqual(3, try describeRead(all, &want));
        // From the third byte of each reply on (`ESC _ G`, `ESC [ 6`, `ESC [ ?`), its bytes
        // are a reply's: the rest may come long after the 30 ms the app waits, and they still
        // give the same replies and no keys.
        var start: usize = 0;
        for (replies) |reply| {
            for (3..reply.len) |at| try expectSplitGives(all, start + at, true, want.items);
            start += reply.len;
        }
    }
    // `ESC`, `ESC _` and `ESC [` alone are keys someone can press (Esc, Alt-_, Alt-[): they
    // still wait only the 30 ms, as "a lone ESC waits for the flush" and "unfinished sequences
    // flush as keys" show.
    try expectKeys("\x1b_", &.{.{ .code = .{ .char = '_' }, .alt = true }});
}

test "after ESC _ G, what can't be a graphics reply is keys" {
    // Decoded at once, not waited for: a byte no reply has...
    for ([_][]const u8{ "\x1b_Gi=1\r", "\x1b_Gab" }) |bytes| {
        var d: Decoder = .init(testing.allocator);
        defer d.deinit();
        try d.feed(bytes);
        try testing.expect(d.next().?.key.key.eql(.{ .code = .{ .char = '_' }, .alt = true }));
    }
    try expectKeys("\x1b_Gi=1\x1bx", &.{ .{ .code = .{ .char = '_' }, .alt = true }, .char('G'), .char('i'), .char('='), .char('1'), .{ .code = .{ .char = 'x' }, .alt = true } });

    // A reply right after such keys is still a reply: it doesn't end theirs.
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b_Gab\x1b_Gi=31;OK\x1b\\");
    for ([_]Key{ .{ .code = .{ .char = '_' }, .alt = true }, .char('G'), .char('a'), .char('b') }) |want| {
        try testing.expect(d.next().?.key.key.eql(want));
    }
    try testing.expectEqual(31, d.next().?.kitty_graphics_ok.id);
    try testing.expectEqual(null, d.next());

    // ...or one past the longest reply we wait for.
    var long: Decoder = .init(testing.allocator);
    defer long.deinit();
    try long.feed("\x1b_Gi=");
    const digits: [max_sequence]u8 = @splat('1');
    try long.feed(&digits);
    try testing.expect(long.next().?.key.key.eql(.{ .code = .{ .char = '_' }, .alt = true }));
}

test "device attributes, cell size and resize reports" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[?62;22;52c\x1b[6;20;10t\x1b[48;40;120;800;1200t\x1b[4;800;1200t\x1b[?1;2$y\x1b[Ix");
    try testing.expectEqualStrings("62;22;52", d.next().?.device_attributes);
    const cell = d.next().?.cell_size;
    try testing.expectEqual(10, cell.w);
    try testing.expectEqual(20, cell.h);
    const r = d.next().?.resize;
    try testing.expectEqual(40, r.rows);
    try testing.expectEqual(120, r.cols);
    try testing.expectEqual(800, r.h_px);
    try testing.expectEqual(1200, r.w_px);
    // Other replies (text area size, DECRPM, focus) are skipped.
    try testing.expect(d.next().?.key.key.eql(.char('x')));
    try testing.expectEqual(null, d.next());
}

test "mouse reports and unknown sequences are skipped" {
    try expectKeys("\x1b[<0;10;5M\x1b[<0;10;5m\x1b[>1;2mq", &.{.char('q')});
    try expectKeys("\x1b[2 qr", &.{.char('r')});
}

test "huge parameters saturate" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[48;99999999999;5;6;7;8;9;10;11;12t");
    const r = d.next().?.resize;
    try testing.expectEqual(65535, r.rows);
    try testing.expectEqual(5, r.cols);
}

test "an endless sequence gives up" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[");
    const digits: [max_sequence]u8 = @splat('1');
    try d.feed(&digits);
    // Alt-[ first, then the digits as keys.
    try testing.expect(d.next().?.key.key.eql(.{ .code = .{ .char = '[' }, .alt = true }));
    try testing.expect(d.next().?.key.key.eql(.char('1')));

    // A reply that waits through the flush gives up too.
    var reply: Decoder = .init(testing.allocator);
    defer reply.deinit();
    try reply.feed("\x1b[?");
    try reply.feed(&digits);
    try testing.expect(reply.next().?.key.key.eql(.{ .code = .{ .char = '[' }, .alt = true }));
    try testing.expect(reply.next().?.key.key.eql(.char('?')));
}

test "a paste after one that spanned feeds starts empty" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[200~first part");
    try testing.expectEqual(null, d.next());
    try d.feed("!\x1b[201~\x1b[200~two\x1b[201~");
    const first = d.next().?.paste;
    const second = d.next().?.paste;
    try testing.expectEqualStrings("first part!", first);
    try testing.expectEqualStrings("two", second);
    try testing.expectEqual(null, d.next());
}

/// Writes the events one read of `bytes` gives, as `describe` does, and returns how many.
fn describeRead(bytes: []const u8, out: *std.ArrayList(u8)) !usize {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed(bytes);
    var n: usize = 0;
    while (d.next()) |e| : (n += 1) try describe(out, e);
    return n;
}

/// Feeds `bytes` as two reads cut at `cut` and checks they give `want` (as `describe` writes
/// it), with nothing left waiting. With `wait`, the app's 30 ms wait runs out between the two
/// reads, and must find nothing to flush.
fn expectSplitGives(bytes: []const u8, cut: usize, wait: bool, want: []const u8) !void {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    // Compare as text: slices from the first feed may not outlive the second.
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try d.feed(bytes[0..cut]);
    while (d.next()) |e| try describe(&got, e);
    if (wait) {
        try testing.expect(!d.pending());
        while (d.flushPending()) |e| try describe(&got, e);
    }
    try d.feed(bytes[cut..]);
    while (d.next()) |e| try describe(&got, e);
    if (!std.mem.eql(u8, want, got.items)) std.debug.print("split at {d} of {x}\n", .{ cut, bytes });
    try testing.expectEqualStrings(want, got.items);
    try testing.expect(!d.pending());
}

/// An event as text that outlives the decoder's buffers.
fn describe(out: *std.ArrayList(u8), e: Event) !void {
    switch (e) {
        .paste => |p| try out.print(testing.allocator, "paste:{s}|", .{p}),
        .device_attributes => |p| try out.print(testing.allocator, "da:{s}|", .{p}),
        .kitty_graphics_ok, .kitty_graphics_error => |r| try out.print(testing.allocator, "kitty:{t}:{d}:{s}|", .{ e, r.id, r.message }),
        // Without the together mark, which depends on how the bytes were split into reads.
        .key => |k| try out.print(testing.allocator, "key:{any}|", .{k.key}),
        else => try out.print(testing.allocator, "{any}|", .{e}),
    }
}

test "any chunk size gives the same events" {
    const all = "k\x1b[200~first paste text\x1b[201~\x1b[200~second one here\x1b[201~\x1b[A\x1b[200~x\x1b[201~é\x1b_Gi=5;OK\x1b\\z";
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    {
        var d: Decoder = .init(testing.allocator);
        defer d.deinit();
        try d.feed(all);
        while (d.next()) |e| try describe(&want, e);
    }
    try testing.expect(std.mem.find(u8, want.items, "second one here") != null);
    for (1..all.len) |chunk| {
        var d: Decoder = .init(testing.allocator);
        defer d.deinit();
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        var i: usize = 0;
        while (i < all.len) : (i += chunk) {
            try d.feed(all[i..@min(i + chunk, all.len)]);
            while (d.next()) |e| try describe(&got, e);
        }
        try testing.expectEqualStrings(want.items, got.items);
    }
}
