//! Turns the bytes a terminal sends into keys, pastes and replies to our queries.
//!
//! Escape sequences can be split across reads, so the decoder keeps what it can't finish yet.
//! A lone ESC is ambiguous (the Escape key, or the start of a sequence): the app calls
//! `flushPending` after ~30 ms without input, which decodes whatever is left as keys.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Key = struct {
    code: Code,
    ctrl: bool = false,
    alt: bool = false,
    /// Set for keys that aren't characters (Shift-Tab, Shift-Up). A shifted character
    /// arrives as the character itself ('F').
    shift: bool = false,

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
    key: Key,
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

    /// Bytes are waiting that `flushPending` would decode. False inside a paste, which waits
    /// for its end marker however long it takes.
    pub fn pending(d: *const Decoder) bool {
        return !d.in_paste and d.pos < d.buf.items.len;
    }

    fn decode(d: *Decoder, force: bool) ?Event {
        while (true) {
            const rest = d.buf.items[d.pos..];
            if (d.in_paste) {
                const end = std.mem.find(u8, rest, paste_end) orelse return null;
                d.in_paste = false;
                d.pos += end + paste_end.len;
                if (!d.paste_open) return .{ .paste = rest[0..@min(end, max_paste)] };
                d.paste_open = false;
                const room = max_paste -| d.paste.items.len;
                d.paste.appendSliceAssumeCapacity(rest[0..@min(end, room)]);
                d.paste_emitted = true;
                return .{ .paste = d.paste.items };
            }
            if (rest.len == 0) return null;
            switch (parse(rest, force)) {
                .incomplete => return null,
                .skip => |n| d.pos += n,
                .paste_start => |n| {
                    d.pos += n;
                    d.in_paste = true;
                },
                .event => |e| {
                    d.pos += e.len;
                    return e.event;
                },
            }
        }
    }
};

const Parsed = union(enum) {
    incomplete,
    /// Bytes that mean nothing to us.
    skip: usize,
    paste_start: usize,
    event: struct { len: usize, event: Event },

    fn key(len: usize, k: Key) Parsed {
        return .{ .event = .{ .len = len, .event = .{ .key = k } } };
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
                var alt = k;
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

/// xterm modifier parameter: 1 + bits (shift 1, alt 2, ctrl 4, meta 8 counted as alt).
fn applyModifiers(k: Key, param: u32) Key {
    var out = k;
    if (param < 2) return out;
    const bits = param - 1;
    if (bits & 1 != 0) out.shift = true;
    if (bits & (2 | 8) != 0) out.alt = true;
    if (bits & 4 != 0) out.ctrl = true;
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
        if (force or bytes.len > max_sequence) return altChar(bytes);
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
    const st = std.mem.find(u8, bytes[3..], "\x1b\\") orelse {
        if (force or bytes.len > max_sequence) return altChar(bytes);
        return .incomplete;
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
        if (!want.eql(got.key)) {
            std.debug.print("bytes {x}: want {any}, got {any}\n", .{ bytes, want, got.key });
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
    try expectKeys("\x1b[1;9A", &.{.{ .code = .up, .alt = true }});
    try expectKeys("\x1b[1;1A", &.{plainKey(.up)});
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

test "a lone ESC waits for the flush" {
    var d: Decoder = .init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b");
    try testing.expectEqual(null, d.next());
    try testing.expect(d.pending());
    const e = d.flushPending().?;
    try testing.expect(e.key.eql(plainKey(.esc)));
    try testing.expectEqual(null, d.flushPending());
    try testing.expect(!d.pending());

    // Two ESCs: Alt-Escape after the flush.
    try d.feed("\x1b\x1b");
    try testing.expectEqual(null, d.next());
    try testing.expect(d.flushPending().?.key.eql(.{ .code = .esc, .alt = true }));
}

test "unfinished sequences flush as keys" {
    try expectKeys("\x1b[", &.{.{ .code = .{ .char = '[' }, .alt = true }});
    try expectKeys("\x1b[1;", &.{ .{ .code = .{ .char = '[' }, .alt = true }, .char('1'), .char(';') });
    try expectKeys("\x1bO", &.{.{ .code = .{ .char = 'O' }, .alt = true }});
    try expectKeys("\x1b_Gi=1", &.{ .{ .code = .{ .char = '_' }, .alt = true }, .char('G'), .char('i'), .char('='), .char('1') });
    // A malformed CSI (a control before the final byte) is Alt-[ and the rest.
    try expectKeys("\x1b[\r", &.{ .{ .code = .{ .char = '[' }, .alt = true }, plainKey(.enter) });
}

test "sequences split across feeds" {
    const all = "a\x1b[1;5A\x1bOP\x1b[200~hi\x1b[201~é\x1b_Gi=31;OK\x1b\\\x1b[?62;22c\x1b[6;20;10t\x1b[48;40;120;800;1200t";
    // Every split point gives the same events.
    var reference: std.ArrayList(Event) = .empty;
    defer reference.deinit(testing.allocator);
    var whole: Decoder = .init(testing.allocator);
    defer whole.deinit();
    try decodeAll(&whole, all, false, &reference);
    try testing.expectEqual(9, reference.items.len);

    for (1..all.len) |cut| {
        var d: Decoder = .init(testing.allocator);
        defer d.deinit();
        var got: std.ArrayList(Event) = .empty;
        defer got.deinit(testing.allocator);
        // Compare as text: slices from the first feed may not outlive the second.
        var texts: std.ArrayList(u8) = .empty;
        defer texts.deinit(testing.allocator);
        try d.feed(all[0..cut]);
        while (d.next()) |e| try texts.print(testing.allocator, "{any}|", .{e});
        try d.feed(all[cut..]);
        while (d.next()) |e| try texts.print(testing.allocator, "{any}|", .{e});
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(testing.allocator);
        for (reference.items) |e| try want.print(testing.allocator, "{any}|", .{e});
        try testing.expectEqualStrings(want.items, texts.items);
        try testing.expect(!d.pending());
    }
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
            .key => |key| try texts.print(testing.allocator, "key:{any}|", .{key.code}),
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
    try testing.expect(d.next().?.key.eql(.char('a')));
    try testing.expectEqualStrings("hello\r\nwörld", d.next().?.paste);
    try testing.expect(d.next().?.key.eql(.char('b')));
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
    try testing.expect(d.next().?.key.eql(.char('z')));
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
    try testing.expect(d.next().?.key.eql(.char('x')));
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
    try testing.expect(d.next().?.key.eql(.{ .code = .{ .char = '[' }, .alt = true }));
    try testing.expect(d.next().?.key.eql(.char('1')));
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

/// An event as text that outlives the decoder's buffers.
fn describe(out: *std.ArrayList(u8), e: Event) !void {
    switch (e) {
        .paste => |p| try out.print(testing.allocator, "paste:{s}|", .{p}),
        .device_attributes => |p| try out.print(testing.allocator, "da:{s}|", .{p}),
        .kitty_graphics_ok, .kitty_graphics_error => |r| try out.print(testing.allocator, "kitty:{t}:{d}:{s}|", .{ e, r.id, r.message }),
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
