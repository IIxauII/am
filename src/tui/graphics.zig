//! Album artwork on the terminal: which image protocol to use, the kitty graphics escape
//! sequences, and drawing into the screen model (kitty Unicode placeholders, or `▀` half blocks).
//!
//! Kitty spec: https://sw.kovidgoyal.net/kitty/graphics-protocol/ (docs/graphics-protocol.rst in
//! the kitty repo). Every command is `ESC _ G <keys> [; <base64>] ESC \`. Ids are 24-bit, so a
//! truecolor foreground carries them in placeholder cells.
//!
//! The drawing functions take the screen as `anytype`: anything with
//! `put(x: u16, y: u16, grapheme: []const u8, width: u2, style: Style)`, where `Style` has
//! `fg`/`bg` fields of a colour union with an `rgb: u24` case (screen.zig).
const std = @import("std");
const png = @import("png.zig");

const Environ = std.process.Environ;
const Io = std.Io;

/// How to draw artwork: the `AM_IMAGES` setting.
pub const Images = enum {
    /// Kitty graphics where the terminal answers the query, else half blocks.
    auto,
    /// Kitty graphics, with placeholders where the terminal is known to have them.
    kitty,
    placeholders,
    placements,
    blocks,
    off,
};

/// The artwork setting: settings.json's `artwork`, which `v` cycles.
pub const Artwork = enum {
    /// Kitty images where the terminal can show them, else half blocks.
    images,
    /// Half blocks, always.
    blocks,
    /// No artwork, and none downloaded.
    off,
};

pub const Protocol = enum {
    /// Kitty graphics shown through U+10EEEE placeholder text (Ghostty, kitty): the image lives
    /// in the cell grid, so redraws, scrolling and overwrites need no extra commands.
    kitty_placeholders,
    /// Kitty graphics placed at a cell (WezTerm, iTerm2, Konsole…): the app must re-place or
    /// delete the placement whenever the cover moves or is covered.
    kitty_placements,
    /// `▀` cells coloured from the decoded pixels; works in any colour terminal.
    half_blocks,
    none,
};

/// Sent once at startup, after entering the alternate screen: a kitty graphics query (1×1 RGB,
/// id 31), the cell size in pixels, and DA1. Every terminal answers DA1, so a DA1 reply with no
/// `ESC_Gi=31;OK ESC\` before it means no kitty graphics.
pub const query = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[16t\x1b[c";

/// Picks the protocol. `kitty_ok`: the terminal answered `query` with OK. `images` is the
/// `AM_IMAGES` setting; `auto` picks from the terminal.
pub fn choose(environ: *const Environ.Map, kitty_ok: bool, images: Images) Protocol {
    switch (images) {
        .off => return .none,
        .blocks => return .half_blocks,
        .placeholders => return .kitty_placeholders,
        .placements => return .kitty_placements,
        .kitty => return kittyProtocol(environ),
        .auto => {},
    }
    if (fallback(environ, kitty_ok, .auto)) |f| return f.shows;
    return kittyProtocol(environ);
}

/// The protocol for the artwork setting. `images` is what Images means: `auto`, or the kitty
/// protocol `AM_IMAGES` names (settings.zig's `Tui.images`).
pub fn protocolFor(environ: *const Environ.Map, kitty_ok: bool, artwork: Artwork, images: Images) Protocol {
    return switch (artwork) {
        .images => choose(environ, kitty_ok, images),
        .blocks => .half_blocks,
        .off => .none,
    };
}

/// What Images shows instead of kitty images, and why.
pub const Fallback = struct {
    /// Half blocks, or none.
    shows: Protocol,
    /// E.g. `inside tmux`.
    why: []const u8,
};

/// What `images` (as `choose` takes it) shows instead of kitty images in this terminal, or null
/// when it shows them. Only `auto` falls back; the other values force a protocol.
pub fn fallback(environ: *const Environ.Map, kitty_ok: bool, images: Images) ?Fallback {
    if (images != .auto) return null;
    if (eql(env(environ, "TERM"), "dumb")) return .{ .shows = .none, .why = "TERM=dumb" };
    // tmux swallows kitty APCs unless wrapped for passthrough, which this doesn't do.
    const tmux = env(environ, "TMUX") != null;
    if (kitty_ok and !tmux) return null;
    const no_color = env(environ, "NO_COLOR") != null;
    return .{
        .shows = if (no_color) .none else .half_blocks,
        .why = if (tmux)
            (if (no_color) "inside tmux, and NO_COLOR is set" else "inside tmux")
        else if (no_color) "no answer to the graphics query, and NO_COLOR is set" else "no answer to the graphics query",
    };
}

fn kittyProtocol(environ: *const Environ.Map) Protocol {
    return if (placeholdersKnown(environ)) .kitty_placeholders else .kitty_placements;
}

/// Placeholder support can't be queried; these terminals have it (kitty since 0.28).
fn placeholdersKnown(environ: *const Environ.Map) bool {
    const term = env(environ, "TERM");
    return eql(env(environ, "TERM_PROGRAM"), "ghostty") or eql(term, "xterm-ghostty") or
        eql(term, "xterm-kitty") or env(environ, "KITTY_WINDOW_ID") != null;
}

fn env(environ: *const Environ.Map, key: []const u8) ?[]const u8 {
    const value = environ.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, b) else false;
}

/// Base64 characters per chunk; the spec's maximum, and a multiple of 4.
pub const chunk_chars = 4096;
const chunk_bytes = chunk_chars / 4 * 3;

/// Sends a PNG file to the terminal as image `id` without showing it (`a=t,f=100`), in chunks
/// of 4096 base64 characters with `m=1` on all but the last. `q=2` on every chunk: no replies.
/// Write the whole stream before any other kitty command. Nothing is written for an empty file.
pub fn transmitPng(w: *Io.Writer, id: u32, file: []const u8) Io.Writer.Error!void {
    std.debug.assert(id != 0);
    var off: usize = 0;
    var b64: [chunk_chars]u8 = undefined;
    while (off < file.len) {
        const end = @min(off + chunk_bytes, file.len);
        const more: u1 = @intFromBool(end < file.len);
        if (off == 0) {
            try w.print("\x1b_Ga=t,f=100,t=d,i={d},q=2,m={d};", .{ id, more });
        } else {
            try w.print("\x1b_Gm={d},q=2;", .{more});
        }
        try w.writeAll(std.base64.standard.Encoder.encode(&b64, file[off..end]));
        try w.writeAll("\x1b\\");
        off = end;
    }
}

/// Creates (or replaces: same `p=1`) the virtual placement that placeholder cells show, scaled
/// into `cols`×`rows` cells. Re-send after a size change.
pub fn placeVirtual(w: *Io.Writer, id: u32, cols: u16, rows: u16) Io.Writer.Error!void {
    try w.print("\x1b_Ga=p,U=1,i={d},p=1,c={d},r={d},q=2\x1b\\", .{ id, cols, rows });
}

/// Shows image `id` with its top-left corner at cell (`col`, `row`), both 0-based, scaled into
/// `cols`×`rows` cells. Moves the cursor there; `C=1` keeps it from moving further. Sending it
/// again moves the placement (`p=1` is replaced, not added).
pub fn placeAt(w: *Io.Writer, id: u32, col: u16, row: u16, cols: u16, rows: u16) Io.Writer.Error!void {
    try w.print("\x1b[{d};{d}H\x1b_Ga=p,i={d},p=1,c={d},r={d},C=1,q=2\x1b\\", .{ @as(u32, row) + 1, @as(u32, col) + 1, id, cols, rows });
}

/// Removes every placement of `id`, virtual ones included; the image stays stored.
pub fn deletePlacements(w: *Io.Writer, id: u32) Io.Writer.Error!void {
    try w.print("\x1b_Ga=d,d=i,i={d},q=2\x1b\\", .{id});
}

/// Removes the placements of `id` and frees its data.
pub fn free(w: *Io.Writer, id: u32) Io.Writer.Error!void {
    try w.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id});
}

/// Frees every image: `d=A` for the placed ones, and the id range 1…0xFFFFFF (`d=R`, kitty
/// 0.33+, Ghostty) because `d=A` never touches virtual placements.
pub fn freeAll(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("\x1b_Ga=d,d=A,q=2\x1b\\\x1b_Ga=d,d=R,x=1,y=16777215,q=2\x1b\\");
}

/// The placeholder character.
pub const placeholder: u21 = 0x10EEEE;

/// Row, column (and id top byte) diacritics: entry n stands for the number n. Parsed at compile
/// time from kitty's gen/rowcolumn-diacritics.txt, kept verbatim next to this file.
pub const diacritics = parseDiacritics(@embedFile("rowcolumn-diacritics.txt"));

fn parseDiacritics(comptime text: []const u8) [countDiacritics(text)]u21 {
    @setEvalBranchQuota(1_000_000);
    var out: [countDiacritics(text)]u21 = undefined;
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const hex = line[0 .. std.mem.findScalar(u8, line, ';') orelse line.len];
        out[n] = std.fmt.parseInt(u21, hex, 16) catch unreachable;
        n += 1;
    }
    return out;
}

fn countDiacritics(comptime text: []const u8) usize {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line[0] != '#') n += 1;
    }
    return n;
}

/// One placeholder cell's text: U+10EEEE, the row and column diacritics, and the id's top byte
/// when it has one. At most 16 bytes.
pub fn placeholderCell(buf: *[16]u8, id: u32, row: u16, col: u16) []const u8 {
    var n: usize = std.unicode.utf8Encode(placeholder, buf) catch unreachable;
    n += std.unicode.utf8Encode(diacritics[row], buf[n..]) catch unreachable;
    n += std.unicode.utf8Encode(diacritics[col], buf[n..]) catch unreachable;
    const top: u8 = @intCast(id >> 24);
    if (top != 0) n += std.unicode.utf8Encode(diacritics[top], buf[n..]) catch unreachable;
    return buf[0..n];
}

/// Fills `cols`×`rows` cells at (`x`, `y`) with placeholders for image `id`, which needs a
/// virtual placement of the same size (`placeVirtual`). Every cell carries both diacritics, so a
/// diff renderer may rewrite any single cell. The foreground is the id's low 24 bits, marked
/// `exact_fg` so the screen writes it in 24-bit whatever its color mode. The cells are concealed
/// in case a terminal draws placeholder text (Ghostty 1.3.1 doesn't; kitty and Ghostty read only
/// the colors, so the image is unaffected). Sizes are capped at the diacritics table (297).
pub fn drawPlaceholders(screen: anytype, x: u16, y: u16, id: u32, cols: u16, rows: u16) void {
    const fg: u24 = @truncate(id);
    var buf: [16]u8 = undefined;
    for (0..@min(rows, diacritics.len)) |r| {
        for (0..@min(cols, diacritics.len)) |c| {
            const text = placeholderCell(&buf, id, @intCast(r), @intCast(c));
            screen.put(x + @as(u16, @intCast(c)), y + @as(u16, @intCast(r)), text, 1, .{ .fg = .{ .rgb = fg }, .exact_fg = true, .conceal = true });
        }
    }
}

/// The upper half block: the foreground paints the top pixel, the background the bottom one.
pub const upper_half = "\u{2580}";

/// Draws `img` into `cols`×`rows` cells at (`x`, `y`) as `▀` cells, each two pixels tall:
/// the image is box-filtered (averaged) to `cols`×`2·rows` pixels, stretching it to fill.
pub fn drawHalfBlocks(screen: anytype, x: u16, y: u16, cols: u16, rows: u16, img: png.Image) void {
    if (img.width == 0 or img.height == 0) return;
    const out_h: u32 = @as(u32, rows) * 2;
    for (0..rows) |r| {
        for (0..cols) |c| {
            const top = average(img, @intCast(c), cols, @intCast(r * 2), out_h);
            const bottom = average(img, @intCast(c), cols, @intCast(r * 2 + 1), out_h);
            screen.put(x + @as(u16, @intCast(c)), y + @as(u16, @intCast(r)), upper_half, 1, .{
                .fg = .{ .rgb = top },
                .bg = .{ .rgb = bottom },
            });
        }
    }
}

/// The mean colour of the source pixels under output pixel (`tx`, `ty`) of a `out_w`×`out_h`
/// grid. Every output pixel covers at least one source pixel.
fn average(img: png.Image, tx: u32, out_w: u32, ty: u32, out_h: u32) u24 {
    const x0: u32 = @intCast(@as(u64, tx) * img.width / out_w);
    const x1: u32 = @max(x0 + 1, @as(u32, @intCast(@as(u64, tx + 1) * img.width / out_w)));
    const y0: u32 = @intCast(@as(u64, ty) * img.height / out_h);
    const y1: u32 = @max(y0 + 1, @as(u32, @intCast(@as(u64, ty + 1) * img.height / out_h)));
    var sum: [3]u64 = .{ 0, 0, 0 };
    for (y0..y1) |sy| {
        for (x0..x1) |sx| {
            const p = img.pixel(@intCast(sx), @intCast(sy));
            for (0..3) |i| sum[i] += p[i];
        }
    }
    const n: u64 = @as(u64, x1 - x0) * (y1 - y0);
    var rgb: u24 = 0;
    for (sum) |s| rgb = (rgb << 8) | @as(u8, @intCast((s + n / 2) / n));
    return rgb;
}

/// A kitty image id for an artwork URL: 24-bit (fits a truecolor foreground) and never 0.
pub fn imageId(url: []const u8) u32 {
    return 1 + @as(u32, @intCast(std.hash.Wyhash.hash(0, url) % 0xFFFFFE));
}

/// How many columns make `rows` rows look square, given the cell size in pixels (0 when
/// unknown: cells are then taken to be twice as tall as wide). The sizes come from the
/// terminal's reply, so an absurd one saturates instead of overflowing.
pub fn squareCols(rows: u16, cell_w: u16, cell_h: u16) u16 {
    if (cell_w == 0 or cell_h == 0) return rows *| 2;
    const cols = (@as(u32, rows) * cell_h + cell_w / 2) / cell_w;
    return @intCast(@min(cols, std.math.maxInt(u16)));
}

const testing = std.testing;

/// Stands in for screen.zig's Screen: records what `put` gets.
const FakeScreen = struct {
    const Color = union(enum) { default, index: u8, rgb: u24 };
    const Style = struct {
        fg: Color = .default,
        bg: Color = .default,
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        underline: bool = false,
        reverse: bool = false,
        conceal: bool = false,
        exact_fg: bool = false,
    };
    const Cell = struct { bytes: [24]u8 = undefined, len: u8 = 0, width: u2 = 1, style: Style = .{} };
    const cols = 20;
    const rows = 10;

    cells: [rows][cols]Cell = @splat(@splat(.{})),
    puts: usize = 0,

    pub fn put(s: *FakeScreen, x: u16, y: u16, grapheme: []const u8, width: u2, style: Style) void {
        if (x >= cols or y >= rows) return;
        const cell = &s.cells[y][x];
        @memcpy(cell.bytes[0..grapheme.len], grapheme);
        cell.len = @intCast(grapheme.len);
        cell.width = width;
        cell.style = style;
        s.puts += 1;
    }

    fn text(s: *const FakeScreen, x: u16, y: u16) []const u8 {
        const cell = &s.cells[y][x];
        return cell.bytes[0..cell.len];
    }
};

fn mapOf(pairs: []const [2][]const u8) !Environ.Map {
    var m: Environ.Map = .init(testing.allocator);
    errdefer m.deinit();
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

test "choose: placeholders on Ghostty and kitty, placements elsewhere, half blocks without kitty" {
    var ghostty = try mapOf(&.{ .{ "TERM_PROGRAM", "ghostty" }, .{ "TERM", "xterm-256color" } });
    defer ghostty.deinit();
    try testing.expectEqual(Protocol.kitty_placeholders, choose(&ghostty, true, .auto));
    try testing.expectEqual(Protocol.half_blocks, choose(&ghostty, false, .auto));

    var kitty = try mapOf(&.{.{ "KITTY_WINDOW_ID", "1" }});
    defer kitty.deinit();
    try testing.expectEqual(Protocol.kitty_placeholders, choose(&kitty, true, .auto));

    var wezterm = try mapOf(&.{.{ "TERM_PROGRAM", "WezTerm" }});
    defer wezterm.deinit();
    try testing.expectEqual(Protocol.kitty_placements, choose(&wezterm, true, .auto));
    try testing.expectEqual(Protocol.half_blocks, choose(&wezterm, false, .auto));

    var tmux = try mapOf(&.{ .{ "TERM_PROGRAM", "ghostty" }, .{ "TMUX", "/tmp/tmux-501/default,1,0" } });
    defer tmux.deinit();
    try testing.expectEqual(Protocol.half_blocks, choose(&tmux, true, .auto));

    var dumb = try mapOf(&.{.{ "TERM", "dumb" }});
    defer dumb.deinit();
    try testing.expectEqual(Protocol.none, choose(&dumb, false, .auto));

    var no_color = try mapOf(&.{.{ "NO_COLOR", "1" }});
    defer no_color.deinit();
    try testing.expectEqual(Protocol.none, choose(&no_color, false, .auto));
}

test "choose: AM_IMAGES overrides detection" {
    var ghostty = try mapOf(&.{.{ "TERM_PROGRAM", "ghostty" }});
    defer ghostty.deinit();
    var plain = try mapOf(&.{});
    defer plain.deinit();
    try testing.expectEqual(Protocol.none, choose(&ghostty, true, .off));
    try testing.expectEqual(Protocol.half_blocks, choose(&ghostty, true, .blocks));
    try testing.expectEqual(Protocol.kitty_placeholders, choose(&ghostty, false, .kitty));
    try testing.expectEqual(Protocol.kitty_placements, choose(&plain, false, .kitty));
    try testing.expectEqual(Protocol.kitty_placements, choose(&ghostty, true, .placements));
    try testing.expectEqual(Protocol.kitty_placeholders, choose(&plain, false, .placeholders));
}

test "fallback: what Images shows instead of kitty images in this terminal, and why" {
    var ghostty = try mapOf(&.{.{ "TERM_PROGRAM", "ghostty" }});
    defer ghostty.deinit();
    try testing.expectEqual(@as(?Fallback, null), fallback(&ghostty, true, .auto));
    try testing.expectEqualDeep(@as(?Fallback, .{ .shows = .half_blocks, .why = "no answer to the graphics query" }), fallback(&ghostty, false, .auto));

    var tmux = try mapOf(&.{ .{ "TERM_PROGRAM", "ghostty" }, .{ "TMUX", "/tmp/tmux-501/default,1,0" } });
    defer tmux.deinit();
    try testing.expectEqualDeep(@as(?Fallback, .{ .shows = .half_blocks, .why = "inside tmux" }), fallback(&tmux, true, .auto));
    try testing.expectEqualDeep(@as(?Fallback, .{ .shows = .half_blocks, .why = "inside tmux" }), fallback(&tmux, false, .auto));

    var dumb = try mapOf(&.{.{ "TERM", "dumb" }});
    defer dumb.deinit();
    try testing.expectEqualDeep(@as(?Fallback, .{ .shows = .none, .why = "TERM=dumb" }), fallback(&dumb, true, .auto));

    var no_color = try mapOf(&.{.{ "NO_COLOR", "1" }});
    defer no_color.deinit();
    try testing.expectEqual(@as(?Fallback, null), fallback(&no_color, true, .auto));
    try testing.expectEqualDeep(@as(?Fallback, .{ .shows = .none, .why = "no answer to the graphics query, and NO_COLOR is set" }), fallback(&no_color, false, .auto));

    // AM_IMAGES naming a kitty protocol forces it: nothing to fall back to.
    try testing.expectEqual(@as(?Fallback, null), fallback(&tmux, false, .kitty));
    try testing.expectEqual(@as(?Fallback, null), fallback(&dumb, false, .placements));
}

test "protocolFor: Blocks and Off whatever the terminal, Images as AM_IMAGES says (#12)" {
    var ghostty = try mapOf(&.{.{ "TERM_PROGRAM", "ghostty" }});
    defer ghostty.deinit();
    var dumb = try mapOf(&.{ .{ "TERM", "dumb" }, .{ "NO_COLOR", "1" } });
    defer dumb.deinit();
    try testing.expectEqual(Protocol.kitty_placeholders, protocolFor(&ghostty, true, .images, .auto));
    try testing.expectEqual(Protocol.half_blocks, protocolFor(&ghostty, false, .images, .auto));
    // With AM_IMAGES=placements, Images is placements, not Ghostty's placeholders.
    try testing.expectEqual(Protocol.kitty_placements, protocolFor(&ghostty, true, .images, .placements));
    try testing.expectEqual(Protocol.half_blocks, protocolFor(&ghostty, true, .blocks, .placements));
    try testing.expectEqual(Protocol.half_blocks, protocolFor(&dumb, false, .blocks, .auto));
    try testing.expectEqual(Protocol.none, protocolFor(&ghostty, true, .off, .auto));
}

test "the startup query is the spec's 1x1 query, CSI 16 t and DA1" {
    try testing.expectEqualStrings("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[16t\x1b[c", query);
    var b64: [4]u8 = undefined;
    try testing.expectEqualStrings("AAAA", std.base64.standard.Encoder.encode(&b64, &.{ 0, 0, 0 }));
}

test "transmitPng: one chunk with m=0" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try transmitPng(&w, 41394, "\x89PNG");
    try testing.expectEqualStrings("\x1b_Ga=t,f=100,t=d,i=41394,q=2,m=0;iVBORw==\x1b\\", w.buffered());
}

test "transmitPng: 4096-character chunks, m=1 until the last, keys only on the first" {
    const file = try testing.allocator.alloc(u8, 3072 * 2 + 1);
    defer testing.allocator.free(file);
    for (file, 0..) |*b, i| b.* = @truncate(i * 7);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try transmitPng(&out.writer, 7, file);
    const got = out.written();

    var b64: [4096]u8 = undefined;
    var want: Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    try want.writer.print("\x1b_Ga=t,f=100,t=d,i=7,q=2,m=1;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, file[0..3072])});
    try want.writer.print("\x1b_Gm=1,q=2;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, file[3072..6144])});
    try want.writer.print("\x1b_Gm=0,q=2;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, file[6144..])});
    try testing.expectEqualStrings(want.written(), got);

    // Each payload: 4096 characters (a multiple of 4) except the last.
    var it = std.mem.splitSequence(u8, got, "\x1b\\");
    var lens: [3]usize = undefined;
    for (&lens) |*len| {
        const cmd = it.next().?;
        len.* = cmd.len - (std.mem.findScalar(u8, cmd, ';').? + 1);
    }
    try testing.expectEqual([3]usize{ 4096, 4096, 4 }, lens);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "transmitPng: exactly one chunk's worth is a single m=0 command" {
    const file: [3072]u8 = @splat(0xab);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try transmitPng(&out.writer, 1, &file);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\x1b_G"));
    try testing.expect(std.mem.startsWith(u8, out.written(), "\x1b_Ga=t,f=100,t=d,i=1,q=2,m=0;"));
    try testing.expectEqual(@as(usize, "\x1b_Ga=t,f=100,t=d,i=1,q=2,m=0;".len + 4096 + 2), out.written().len);

    var empty: Io.Writer.Allocating = .init(testing.allocator);
    defer empty.deinit();
    try transmitPng(&empty.writer, 1, "");
    try testing.expectEqualStrings("", empty.written());
}

test "placement and delete commands" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try placeVirtual(&w, 41394, 6, 3);
    try testing.expectEqualStrings("\x1b_Ga=p,U=1,i=41394,p=1,c=6,r=3,q=2\x1b\\", w.buffered());

    w = .fixed(&buf);
    try placeAt(&w, 9, 0, 4, 12, 6);
    try testing.expectEqualStrings("\x1b[5;1H\x1b_Ga=p,i=9,p=1,c=12,r=6,C=1,q=2\x1b\\", w.buffered());

    w = .fixed(&buf);
    try deletePlacements(&w, 9);
    try free(&w, 9);
    try freeAll(&w);
    try testing.expectEqualStrings("\x1b_Ga=d,d=i,i=9,q=2\x1b\\" ++
        "\x1b_Ga=d,d=I,i=9,q=2\x1b\\" ++
        "\x1b_Ga=d,d=A,q=2\x1b\\\x1b_Ga=d,d=R,x=1,y=16777215,q=2\x1b\\", w.buffered());
}

test "the diacritics table is kitty's: 297 entries" {
    try testing.expectEqual(@as(usize, 297), diacritics.len);
    // The first 16, as listed in the research notes and Ghostty's copy of the table.
    try testing.expectEqualSlices(u21, &.{
        0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
        0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
    }, diacritics[0..16]);
    try testing.expectEqual(@as(u21, 0x1D244), diacritics[296]);
    // Sorted, without duplicates.
    for (diacritics[1..], diacritics[0 .. diacritics.len - 1]) |b, a| try testing.expect(b > a);
}

test "placeholder cells: U+10EEEE, row diacritic, column diacritic" {
    var buf: [16]u8 = undefined;
    // Spec example: (0,0) = \U10EEEE\U0305\U0305, (1,0) = \U10EEEE\U030D\U0305.
    try testing.expectEqualStrings("\xf4\x8e\xbb\xae\xcc\x85\xcc\x85", placeholderCell(&buf, 42, 0, 0));
    try testing.expectEqualStrings("\u{10EEEE}\u{030D}\u{0305}", placeholderCell(&buf, 42, 1, 0));
    try testing.expectEqualStrings("\u{10EEEE}\u{0305}\u{030D}", placeholderCell(&buf, 42, 0, 1));
    // Spec example for id 33554474 = 42 + (2 << 24): a third diacritic U+030E.
    try testing.expectEqualStrings("\u{10EEEE}\u{0305}\u{030D}\u{030E}", placeholderCell(&buf, 33554474, 0, 1));
    // The longest: 4-byte placeholder and diacritics (entry 255, the top byte's maximum, is 3 bytes).
    try testing.expectEqual(@as(usize, 15), placeholderCell(&buf, 0xff00_0001, 296, 296).len);
}

test "drawPlaceholders fills the rectangle, fg = id" {
    var s: FakeScreen = .{};
    drawPlaceholders(&s, 2, 1, 0x00A1B2, 6, 3);
    try testing.expectEqual(@as(usize, 18), s.puts);
    try testing.expectEqualStrings("\u{10EEEE}\u{0305}\u{0305}", s.text(2, 1));
    try testing.expectEqualStrings("\u{10EEEE}\u{030E}\u{0312}", s.text(2 + 4, 1 + 2));
    const cell = s.cells[3][7];
    try testing.expectEqual(@as(u2, 1), cell.width);
    try testing.expectEqual(FakeScreen.Color{ .rgb = 0x00A1B2 }, cell.style.fg);
    try testing.expectEqual(FakeScreen.Color.default, cell.style.bg);
    try testing.expect(cell.style.conceal);
    try testing.expect(cell.style.exact_fg);
    try testing.expectEqual(@as(u8, 0), s.cells[1][8].len); // right of the rectangle
    try testing.expectEqual(@as(u8, 0), s.cells[4][2].len); // below it
}

fn testImage(comptime w: u32, comptime h: u32, pixels: *const [w * h]u24) !png.Image {
    const rgb = try testing.allocator.alloc(u8, w * h * 3);
    for (pixels, 0..) |p, i| rgb[i * 3 ..][0..3].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) };
    return .{ .width = w, .height = h, .rgb = rgb };
}

test "drawHalfBlocks: one pixel per half cell at 1:1" {
    const img = try testImage(2, 4, &.{
        0xff0000, 0x00ff00,
        0x0000ff, 0xffffff,
        0x101010, 0x202020,
        0x303030, 0x404040,
    });
    defer img.deinit(testing.allocator);
    var s: FakeScreen = .{};
    drawHalfBlocks(&s, 1, 1, 2, 2, img);
    try testing.expectEqual(@as(usize, 4), s.puts);
    try testing.expectEqualStrings("▀", s.text(1, 1));
    try testing.expectEqual(FakeScreen.Style{ .fg = .{ .rgb = 0xff0000 }, .bg = .{ .rgb = 0x0000ff } }, s.cells[1][1].style);
    try testing.expectEqual(FakeScreen.Style{ .fg = .{ .rgb = 0x00ff00 }, .bg = .{ .rgb = 0xffffff } }, s.cells[1][2].style);
    try testing.expectEqual(FakeScreen.Style{ .fg = .{ .rgb = 0x101010 }, .bg = .{ .rgb = 0x303030 } }, s.cells[2][1].style);
    try testing.expectEqual(FakeScreen.Style{ .fg = .{ .rgb = 0x202020 }, .bg = .{ .rgb = 0x404040 } }, s.cells[2][2].style);
}

test "drawHalfBlocks: box filter averages each block" {
    // 4x4 into 1 cell (1x2 pixels): top = mean of the top 4x2, bottom = mean of the bottom 4x2.
    const img = try testImage(4, 4, &.{
        0x000000, 0x0a0a0a, 0x141414, 0x1e1e1e,
        0x000000, 0x0a0a0a, 0x141414, 0x1e1e1e,
        0xff0000, 0xff0000, 0x00ff00, 0x00ff00,
        0xff0000, 0xff0000, 0x00ff00, 0x00ff00,
    });
    defer img.deinit(testing.allocator);
    var s: FakeScreen = .{};
    drawHalfBlocks(&s, 0, 0, 1, 1, img);
    try testing.expectEqual(FakeScreen.Color{ .rgb = 0x0f0f0f }, s.cells[0][0].style.fg);
    try testing.expectEqual(FakeScreen.Color{ .rgb = 0x808000 }, s.cells[0][0].style.bg);
}

test "drawHalfBlocks: a small image stretches to fill" {
    const img = try testImage(1, 1, &.{0x123456});
    defer img.deinit(testing.allocator);
    var s: FakeScreen = .{};
    drawHalfBlocks(&s, 0, 0, 3, 2, img);
    try testing.expectEqual(@as(usize, 6), s.puts);
    for (0..2) |y| for (0..3) |x| {
        try testing.expectEqual(FakeScreen.Style{ .fg = .{ .rgb = 0x123456 }, .bg = .{ .rgb = 0x123456 } }, s.cells[y][x].style);
    };
}

test "drawHalfBlocks on 300x300 artwork: corners match the source" {
    const img = try png.decode(testing.allocator, @embedFile("testdata/artwork/station-300-rgb.png"));
    defer img.deinit(testing.allocator);
    var s: FakeScreen = .{};
    drawHalfBlocks(&s, 0, 0, 12, 6, img);
    try testing.expectEqual(@as(usize, 72), s.puts);
    // A 25x25 block average stays near the corner pixel on smooth artwork.
    const corner = img.pixel(0, 0);
    const got = s.cells[0][0].style.fg.rgb;
    const channels = [3]u8{ @truncate(got >> 16), @truncate(got >> 8), @truncate(got) };
    for (channels, corner) |g, c| try testing.expect(@abs(@as(i16, g) - c) < 48);
}

test "imageId: 24-bit, nonzero, stable" {
    const a = imageId("https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/300x300bb.png");
    try testing.expect(a != 0 and a <= 0xFFFFFF);
    try testing.expectEqual(a, imageId("https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/300x300bb.png"));
    try testing.expect(a != imageId("https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/64x64bb.png"));
    try testing.expect(imageId("") != 0);
}

test "squareCols" {
    try testing.expectEqual(@as(u16, 12), squareCols(6, 0, 0));
    try testing.expectEqual(@as(u16, 13), squareCols(6, 9, 20)); // 13.3
    try testing.expectEqual(@as(u16, 12), squareCols(6, 10, 20));
    try testing.expectEqual(@as(u16, 0), squareCols(0, 10, 20));
    try testing.expectEqual(@as(u16, 65535), squareCols(100, 1, 65535));
    try testing.expectEqual(@as(u16, 65535), squareCols(40000, 0, 0));
}
