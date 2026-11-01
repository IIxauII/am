//! A grid of styled cells that the app draws into, then `flush` sends only what changed
//! since the last frame, wrapped in synchronized output so the terminal shows whole frames.
//!
//! It never clears with `ESC[2J`: Ghostty frees kitty images on it. A full repaint overwrites
//! every cell instead.
const std = @import("std");
const width = @import("width.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Color = union(enum) {
    default,
    /// The terminal's palette: 0-15 are the themed ANSI colors, 16-255 the xterm cube and grays.
    index: u8,
    /// 0xRRGGBB.
    rgb: u24,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    /// Hidden text (SGR 8). Kitty image placeholders use it, in case a terminal draws their
    /// text; Ghostty 1.3.1 never does, and shows the image either way.
    conceal: bool = false,
    /// The foreground is data, not a look: a kitty placeholder's image id. Written as 24-bit
    /// whatever the color mode, NO_COLOR included.
    exact_fg: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
};

/// One grapheme. Width 2 takes this cell and the next, which is a continuation (width 0, no
/// bytes) holding the same style.
pub const Cell = struct {
    bytes: [max_bytes]u8 = space,
    len: u8 = 1,
    width: u2 = 1,
    style: Style = .{},

    pub const max_bytes = 24;

    const space: [max_bytes]u8 = blk: {
        var b: [max_bytes]u8 = @splat(0);
        b[0] = ' ';
        break :blk b;
    };

    pub fn blank(style: Style) Cell {
        return .{ .style = style };
    }

    fn continuation(style: Style) Cell {
        return .{ .bytes = @splat(0), .len = 0, .width = 0, .style = style };
    }

    pub fn text(c: *const Cell) []const u8 {
        return c.bytes[0..c.len];
    }

    pub fn eql(a: *const Cell, b: *const Cell) bool {
        return a.len == b.len and a.width == b.width and a.style.eql(b.style) and std.mem.eql(u8, a.text(), b.text());
    }
};

/// `none`: no colors at all (NO_COLOR); bold, dim, underline and reverse still show.
pub const ColorMode = enum { truecolor, ansi256, ansi16, none };

/// Picks how colors are written, from the environment. COLORTERM=truecolor/24bit, a terminal
/// known for 24-bit color (TERM_PROGRAM ghostty, iTerm.app, WezTerm, vscode), or TERM
/// `*-direct`, `*kitty*` or `xterm-ghostty` mean truecolor; else TERM with 256color means 256
/// colors; else 16. A non-empty NO_COLOR (no-color.org) means none, before all of these.
pub fn colorMode(environ: *const std.process.Environ.Map) ColorMode {
    if (environ.get("NO_COLOR")) |v| if (v.len > 0) return .none;
    if (environ.get("COLORTERM")) |v| {
        if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit")) return .truecolor;
    }
    if (environ.get("TERM_PROGRAM")) |v| {
        for ([_][]const u8{ "ghostty", "iTerm.app", "WezTerm", "vscode" }) |name| {
            if (std.mem.eql(u8, v, name)) return .truecolor;
        }
    }
    const term = environ.get("TERM") orelse return .ansi16;
    if (std.mem.endsWith(u8, term, "-direct") or std.mem.find(u8, term, "kitty") != null or std.mem.eql(u8, term, "xterm-ghostty"))
        return .truecolor;
    if (std.mem.find(u8, term, "256color") != null) return .ansi256;
    return .ansi16;
}

pub const Position = struct { x: u16, y: u16 };

pub const Screen = struct {
    gpa: Allocator,
    cols: u16,
    rows: u16,
    /// The frame being drawn.
    cells: []Cell,
    /// What the terminal shows, as of the last flush.
    shown: []Cell,
    shown_valid: bool = false,
    cursor: ?Position = null,
    shown_cursor: ?Position = null,

    pub fn init(gpa: Allocator, cols: u16, rows: u16) Allocator.Error!Screen {
        const n = @as(usize, cols) * rows;
        const cells = try gpa.alloc(Cell, n);
        errdefer gpa.free(cells);
        const shown = try gpa.alloc(Cell, n);
        @memset(cells, .{});
        @memset(shown, .{});
        return .{ .gpa = gpa, .cols = cols, .rows = rows, .cells = cells, .shown = shown };
    }

    pub fn deinit(s: *Screen) void {
        s.gpa.free(s.cells);
        s.gpa.free(s.shown);
        s.* = undefined;
    }

    /// Changes the size and blanks the frame; the next flush repaints everything.
    pub fn resize(s: *Screen, cols: u16, rows: u16) Allocator.Error!void {
        const n = @as(usize, cols) * rows;
        const cells = try s.gpa.alloc(Cell, n);
        errdefer s.gpa.free(cells);
        const shown = try s.gpa.alloc(Cell, n);
        s.gpa.free(s.cells);
        s.gpa.free(s.shown);
        s.cells = cells;
        s.shown = shown;
        s.cols = cols;
        s.rows = rows;
        @memset(s.cells, .{});
        @memset(s.shown, .{});
        s.shown_valid = false;
        if (s.cursor) |c| if (c.x >= cols or c.y >= rows) {
            s.cursor = null;
        };
    }

    /// The next flush repaints every cell, e.g. after something else wrote to the terminal.
    pub fn invalidate(s: *Screen) void {
        s.shown_valid = false;
    }

    pub fn cell(s: *const Screen, x: u16, y: u16) *const Cell {
        return &s.cells[@as(usize, y) * s.cols + x];
    }

    /// Blanks the whole frame.
    pub fn clear(s: *Screen, style: Style) void {
        @memset(s.cells, .blank(style));
    }

    /// Blanks a rectangle, clipped to the screen.
    pub fn fill(s: *Screen, x: u16, y: u16, w: u16, h: u16, style: Style) void {
        if (x >= s.cols or y >= s.rows) return;
        const x_end = @min(@as(u32, x) + w, s.cols);
        const y_end = @min(@as(u32, y) + h, s.rows);
        var row: u32 = y;
        while (row < y_end) : (row += 1) {
            var col: u32 = x;
            while (col < x_end) : (col += 1) s.set(@intCast(col), @intCast(row), .blank(style));
        }
    }

    /// Writes text from (x, y), at most `max_w` columns and never past the right edge.
    /// Combining marks, ZWJ sequences and variation selectors stay with their base. Text that
    /// doesn't fit ends in "…". Controls are dropped and invalid UTF-8 shows as U+FFFD.
    /// Returns the columns used.
    pub fn print(s: *Screen, x: u16, y: u16, max_w: u16, text: []const u8, style: Style) u16 {
        if (x >= s.cols or y >= s.rows) return 0;
        const limit: u16 = @min(max_w, s.cols - x);
        if (limit == 0) return 0;
        const truncate = width.textWidth(text) > limit;
        const avail = if (truncate) limit - 1 else limit;
        var used: u16 = 0;
        var it: width.Iterator = .init(text);
        while (it.next()) |cluster| {
            if (cluster.kind == .control or cluster.width == 0) continue;
            if (used + cluster.width > avail) break;
            const bytes = if (cluster.kind == .invalid) "\u{FFFD}" else cluster.bytes;
            s.put(x + used, y, bytes, cluster.width, style);
            used += cluster.width;
        }
        if (truncate) {
            s.put(x + used, y, "\u{2026}", 1, style);
            used += 1;
        }
        return used;
    }

    pub fn textWidth(text: []const u8) usize {
        return width.textWidth(text);
    }

    /// Writes one raw cell: `grapheme_bytes` is sent as is (e.g. U+10EEEE and the kitty
    /// placeholder diacritics). Width 2 also takes the next cell; a wide cell that would cross
    /// the right edge becomes a blank. Width 0 is taken as 1. Bytes past `Cell.max_bytes` are
    /// cut at a code point.
    pub fn put(s: *Screen, x: u16, y: u16, grapheme_bytes: []const u8, cell_width: u2, style: Style) void {
        if (x >= s.cols or y >= s.rows) return;
        const w: u2 = if (cell_width == 0) 1 else @min(cell_width, 2);
        if (w == 2 and x + 1 >= s.cols) return s.set(x, y, .blank(style));
        var c: Cell = .{ .width = w, .style = style };
        const bytes = fitBytes(grapheme_bytes);
        @memcpy(c.bytes[0..bytes.len], bytes);
        c.len = @intCast(bytes.len);
        if (c.len == 0) c = .blank(style);
        s.set(x, y, c);
    }

    /// Shows the cursor at (x, y) after the next flush, e.g. in a text field.
    pub fn showCursor(s: *Screen, x: u16, y: u16) void {
        s.cursor = if (x < s.cols and y < s.rows) .{ .x = x, .y = y } else null;
    }

    pub fn hideCursor(s: *Screen) void {
        s.cursor = null;
    }

    /// Stores a cell, keeping wide cells whole: overwriting either half of a wide cell blanks
    /// the other half.
    fn set(s: *Screen, x: u16, y: u16, c: Cell) void {
        const row = @as(usize, y) * s.cols;
        const i = row + x;
        s.breakWide(x, y);
        if (c.width == 2) {
            s.breakWide(x + 1, y);
            s.cells[i + 1] = .continuation(c.style);
        }
        s.cells[i] = c;
    }

    fn breakWide(s: *Screen, x: u16, y: u16) void {
        const i = @as(usize, y) * s.cols + x;
        const old = &s.cells[i];
        if (old.width == 0 and x > 0) {
            s.cells[i - 1] = .blank(s.cells[i - 1].style);
            old.* = .blank(old.style);
        } else if (old.width == 2 and x + 1 < s.cols) {
            s.cells[i + 1] = .blank(old.style);
        }
    }

    /// Sends the frame: only the cells that differ from the last flush, or all of them when
    /// `full` is set or after `resize`/`invalidate`. Writes nothing when nothing changed.
    /// Flushes `w`.
    pub fn flush(s: *Screen, w: *Io.Writer, mode: ColorMode, full: bool) Io.Writer.Error!void {
        const repaint = full or !s.shown_valid;
        if (!repaint and std.meta.eql(s.cursor, s.shown_cursor) and s.unchanged()) return;

        try w.writeAll("\x1b[?2026h");
        var style: ?Style = null;
        var at: ?Position = null;
        for (0..s.rows) |yi| {
            const y: u16 = @intCast(yi);
            const row = yi * s.cols;
            var x: u16 = 0;
            while (x < s.cols) {
                const c = &s.cells[row + x];
                if (c.width == 0 or (!repaint and c.eql(&s.shown[row + x]))) {
                    x += 1;
                    continue;
                }
                // Ghostty (grapheme clustering on, its default) with autowrap off joins a mark
                // that arrives with the cursor in the last column to that column's cell if it
                // holds text, not to the cell just written. A cell with marks ending one column
                // before the edge goes out with autowrap on, so Ghostty goes by its pending-wrap
                // state. Nothing can wrap: the cursor move puts the base where it fits even if
                // drawn wide, and only zero-width code points follow. A cell in the last column
                // joins its marks correctly with autowrap off.
                const marks_at_edge = x + c.width == s.cols - 1 and hasMarksOnly(c);
                if (marks_at_edge or at == null or at.?.x != x or at.?.y != y) try moveTo(w, x, y);
                if (style == null or !style.?.eql(c.style)) {
                    try writeStyle(w, c.style, mode);
                    style = c.style;
                }
                if (marks_at_edge) try w.writeAll("\x1b[?7h");
                try w.writeAll(c.text());
                if (marks_at_edge) try w.writeAll("\x1b[?7l");
                x += c.width;
                // At the right edge, or after an emoji whose width the terminal may count
                // differently, the terminal's cursor position is uncertain.
                at = if (x < s.cols and widthIsCertain(c)) .{ .x = x, .y = y } else null;
            }
        }
        if (style != null) try w.writeAll("\x1b[0m");
        if (s.cursor) |c| {
            try moveTo(w, c.x, c.y);
            if (repaint or s.shown_cursor == null) try w.writeAll("\x1b[?25h");
        } else if (repaint or s.shown_cursor != null) {
            try w.writeAll("\x1b[?25l");
        }
        try w.writeAll("\x1b[?2026l");
        try w.flush();

        @memcpy(s.shown, s.cells);
        s.shown_valid = true;
        s.shown_cursor = s.cursor;
    }

    fn unchanged(s: *const Screen) bool {
        for (s.cells, s.shown) |*a, *b| if (!a.eql(b)) return false;
        return true;
    }
};

/// Terminals agree on the width of narrow cells and of single East Asian wide characters.
/// Wide emoji (ZWJ sequences, VS16, flags, newer emoji) vary with the terminal's tables.
fn widthIsCertain(c: *const Cell) bool {
    if (c.width != 2) return true;
    const text = c.text();
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    if (len != text.len) return false;
    const cp = std.unicode.utf8Decode(text) catch return false;
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x20000 and cp <= 0x3FFFD);
}

/// A base and at least one code point after it, all of which take no column: combining marks,
/// variation selectors, ZWJ (e.g. a kitty placeholder's diacritics, or a decomposed "é").
fn hasMarksOnly(c: *const Cell) bool {
    const text = c.text();
    var i: usize = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    if (i >= text.len) return false;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return false;
        if (i + len > text.len) return false;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return false;
        if (width.codepointWidth(cp) != 0) return false;
        i += len;
    }
    return true;
}

/// The longest prefix of whole code points that fits in a cell, without a trailing ZWJ.
fn fitBytes(bytes: []const u8) []const u8 {
    if (bytes.len <= Cell.max_bytes) return bytes;
    var end: usize = Cell.max_bytes;
    while (end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
    var out = bytes[0..end];
    while (std.mem.endsWith(u8, out, "\u{200D}")) out = out[0 .. out.len - 3];
    return out;
}

fn moveTo(w: *Io.Writer, x: u16, y: u16) Io.Writer.Error!void {
    try w.print("\x1b[{d};{d}H", .{ @as(u32, y) + 1, @as(u32, x) + 1 });
}

/// One SGR that resets and then sets the whole style.
fn writeStyle(w: *Io.Writer, style: Style, mode: ColorMode) Io.Writer.Error!void {
    try w.writeAll("\x1b[0");
    if (style.bold) try w.writeAll(";1");
    if (style.dim) try w.writeAll(";2");
    if (style.italic) try w.writeAll(";3");
    if (style.underline) try w.writeAll(";4");
    if (style.reverse) try w.writeAll(";7");
    if (style.conceal) try w.writeAll(";8");
    try writeColor(w, style.fg, if (style.exact_fg) .truecolor else mode, false);
    try writeColor(w, style.bg, mode, true);
    try w.writeAll("m");
}

fn writeColor(w: *Io.Writer, color: Color, mode: ColorMode, bg: bool) Io.Writer.Error!void {
    if (mode == .none) return;
    const index: u8 = switch (color) {
        .default => return,
        .index => |i| if (mode == .ansi16 and i >= 16) nearest16(indexRgb(i)) else i,
        .rgb => |rgb| switch (mode) {
            .truecolor => return w.print(";{d};2;{d};{d};{d}", .{
                @as(u8, if (bg) 48 else 38),
                @as(u8, @truncate(rgb >> 16)),
                @as(u8, @truncate(rgb >> 8)),
                @as(u8, @truncate(rgb)),
            }),
            .ansi256 => nearest256(rgb),
            .ansi16 => nearest16(rgb),
            .none => unreachable,
        },
    };
    const base: u8 = if (bg) 40 else 30;
    if (index < 8) return w.print(";{d}", .{base + index});
    if (index < 16) return w.print(";{d}", .{base + 60 + index - 8});
    try w.print(";{d};5;{d}", .{ base + 8, index });
}

/// xterm's default colors for the 16 ANSI entries; themes change these, so they only guide
/// the nearest-color choice.
const ansi16_rgb = [16]u24{
    0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
    0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
};

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

fn indexRgb(i: u8) u24 {
    if (i < 16) return ansi16_rgb[i];
    if (i >= 232) {
        const v: u24 = 8 + 10 * @as(u24, i - 232);
        return v << 16 | v << 8 | v;
    }
    const n = i - 16;
    return @as(u24, cube_levels[n / 36]) << 16 | @as(u24, cube_levels[n / 6 % 6]) << 8 | cube_levels[n % 6];
}

fn channels(rgb: u24) [3]i32 {
    return .{ @intCast(rgb >> 16), @intCast(rgb >> 8 & 0xff), @intCast(rgb & 0xff) };
}

fn distance(a: u24, b: u24) i32 {
    const x = channels(a);
    const y = channels(b);
    var d: i32 = 0;
    for (x, y) |p, q| d += (p - q) * (p - q);
    return d;
}

fn cubeStep(v: i32) u8 {
    if (v < 48) return 0;
    if (v < 115) return 1;
    return @intCast(@divTrunc(v - 35, 40));
}

/// The closest of the xterm cube and gray ramp (16-255); 0-15 are skipped as themes redefine them.
fn nearest256(rgb: u24) u8 {
    const c = channels(rgb);
    const cube: u8 = 16 + 36 * cubeStep(c[0]) + 6 * cubeStep(c[1]) + cubeStep(c[2]);
    const avg = @divTrunc(c[0] + c[1] + c[2], 3);
    const k: u8 = @intCast(std.math.clamp(@divTrunc(avg - 3, 10), 0, 23));
    const gray: u8 = 232 + k;
    return if (distance(indexRgb(gray), rgb) < distance(indexRgb(cube), rgb)) gray else cube;
}

fn nearest16(rgb: u24) u8 {
    var best: u8 = 0;
    var best_d: i32 = std.math.maxInt(i32);
    for (ansi16_rgb, 0..) |c, i| {
        const d = distance(c, rgb);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

// ---- Tests ----

const testing = std.testing;

/// The frame's text, one line per row, continuation cells left out.
fn rowsText(s: *const Screen, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    for (0..s.rows) |y| {
        for (0..s.cols) |x| w.writeAll(s.cell(@intCast(x), @intCast(y)).text()) catch unreachable;
        w.writeAll("\n") catch unreachable;
    }
    return w.buffered();
}

fn expectRows(s: *const Screen, expected: []const u8) !void {
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, rowsText(s, &buf));
}

test "print: plain text, clipping at max_w and the right edge" {
    var s: Screen = try .init(testing.allocator, 10, 2);
    defer s.deinit();
    try testing.expectEqual(5, s.print(0, 0, 10, "hello", .{}));
    try testing.expectEqual(4, s.print(6, 0, 10, "abcd", .{}));
    try expectRows(&s, "hello abcd\n          \n");
    // Too long for the edge: cut with an ellipsis in the last column.
    try testing.expectEqual(4, s.print(6, 1, 10, "abcdef", .{}));
    try expectRows(&s, "hello abcd\n      abc…\n");
    try testing.expectEqual(3, s.print(0, 1, 3, "xyzw", .{}));
    try expectRows(&s, "hello abcd\nxy…   abc…\n");
    try testing.expectEqual(1, s.print(0, 1, 1, "xyzw", .{}));
    try testing.expectEqual(0, s.print(0, 1, 0, "xyzw", .{}));
    try testing.expectEqual(0, s.print(10, 0, 5, "x", .{}));
    try testing.expectEqual(0, s.print(0, 2, 5, "x", .{}));
    // Exactly fitting text has no ellipsis.
    try testing.expectEqual(3, s.print(0, 1, 3, "pqr", .{}));
    try expectRows(&s, "hello abcd\npqr   abc…\n");
}

test "print: wide characters, combining marks, emoji" {
    var s: Screen = try .init(testing.allocator, 8, 3);
    defer s.deinit();
    try testing.expectEqual(4, s.print(0, 0, 8, "中文", .{}));
    try testing.expectEqual(0, s.cell(1, 0).width);
    try testing.expectEqual(2, s.cell(0, 0).width);
    try testing.expectEqual(5, s.print(0, 1, 8, "Beyonce\u{301}"[2..], .{}));
    try testing.expectEqualStrings("e\u{301}", s.cell(4, 1).text());
    // A wide char that would cross max_w is not split: "a中" then "…" in 4 columns.
    try testing.expectEqual(4, s.print(0, 2, 4, "a中文", .{}));
    try expectRows(&s, "中文    \nyonce\u{301}   \na中…    \n");
    // Ellipsis after a gap left by a wide char: "中" doesn't fit in 1 column.
    try testing.expectEqual(1, s.print(0, 2, 2, "中中", .{}));
    try testing.expectEqualStrings("\u{2026}", s.cell(0, 2).text());
    // ZWJ family and flag stay in one cell.
    try testing.expectEqual(4, s.print(0, 0, 8, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{1F1E9}\u{1F1EA}", .{}));
    try testing.expectEqualStrings("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", s.cell(0, 0).text());
    try testing.expectEqualStrings("\u{1F1E9}\u{1F1EA}", s.cell(2, 0).text());
}

test "print: controls dropped, invalid UTF-8 replaced, overlong clusters cut" {
    var s: Screen = try .init(testing.allocator, 8, 1);
    defer s.deinit();
    try testing.expectEqual(6, s.print(0, 0, 8, "a\x1b[31mb", .{}));
    try expectRows(&s, "a[31mb  \n");
    try testing.expectEqual(3, s.print(0, 0, 8, "x\xffy", .{}));
    try testing.expectEqualStrings("\u{FFFD}", s.cell(1, 0).text());
    // 25 bytes: man ZWJ woman ZWJ girl ZWJ boy. It keeps whole code points and no trailing ZWJ.
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    try testing.expectEqual(25, family.len);
    try testing.expectEqual(2, s.print(0, 0, 8, family, .{}));
    try testing.expectEqualStrings("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", s.cell(0, 0).text());
}

test "overwriting half of a wide cell blanks the other half" {
    var s: Screen = try .init(testing.allocator, 6, 1);
    defer s.deinit();
    _ = s.print(0, 0, 6, "中文字", .{});
    _ = s.print(1, 0, 1, "x", .{});
    try expectRows(&s, " x文字\n");
    _ = s.print(2, 0, 1, "y", .{});
    try expectRows(&s, " xy 字\n");
    // A wide char over a wide char's continuation.
    _ = s.print(0, 0, 6, "中文字", .{});
    _ = s.print(1, 0, 2, "国", .{});
    try expectRows(&s, " 国 字\n");
    try testing.expectEqual(0, s.cell(2, 0).width);
    try testing.expectEqual(1, s.cell(3, 0).width);
    // A wide char in the last column becomes a blank.
    s.put(5, 0, "国", 2, .{});
    try testing.expectEqual(1, s.cell(5, 0).width);
    try testing.expectEqualStrings(" ", s.cell(5, 0).text());
    try testing.expectEqual(1, s.cell(4, 0).width);
    // fill over half a wide char.
    _ = s.print(0, 0, 6, "中文字", .{});
    s.fill(3, 0, 1, 1, .{});
    try expectRows(&s, "中  字\n");
}

test "put: raw cells for kitty placeholders" {
    var s: Screen = try .init(testing.allocator, 4, 1);
    defer s.deinit();
    const style: Style = .{ .fg = .{ .rgb = 0x00a1b2 } };
    s.put(0, 0, "\u{10EEEE}\u{305}\u{305}", 1, style);
    s.put(1, 0, "\u{10EEEE}", 1, style);
    try testing.expectEqualStrings("\u{10EEEE}\u{305}\u{305}", s.cell(0, 0).text());
    try testing.expect(s.cell(1, 0).style.eql(style));
    s.put(9, 0, "x", 1, style);
    s.put(0, 3, "x", 1, style);
    s.put(2, 0, "", 1, style);
    try testing.expectEqualStrings(" ", s.cell(2, 0).text());
}

test "fill and clear" {
    var s: Screen = try .init(testing.allocator, 4, 3);
    defer s.deinit();
    _ = s.print(0, 0, 4, "abcd", .{});
    _ = s.print(0, 1, 4, "efgh", .{});
    const red: Style = .{ .bg = .{ .index = 1 } };
    s.fill(1, 0, 10, 2, red);
    try expectRows(&s, "a   \ne   \n    \n");
    try testing.expect(s.cell(3, 1).style.eql(red));
    try testing.expect(s.cell(0, 1).style.eql(.{}));
    try testing.expect(s.cell(1, 2).style.eql(.{}));
    s.fill(9, 9, 2, 2, red);
    s.clear(red);
    try testing.expect(s.cell(0, 2).style.eql(red));
}

fn flushed(s: *Screen, mode: ColorMode, full: bool, buf: []u8) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try s.flush(&w, mode, full);
    return w.buffered();
}

test "flush: first frame repaints every cell, in synchronized output" {
    var s: Screen = try .init(testing.allocator, 3, 2);
    defer s.deinit();
    _ = s.print(0, 0, 3, "ab", .{});
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0mab \x1b[2;1H   \x1b[0m\x1b[?25l\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
    // Nothing changed: nothing is written.
    try testing.expectEqualStrings("", try flushed(&s, .truecolor, false, &buf));
    // full repaints anyway.
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0mab \x1b[2;1H   \x1b[0m\x1b[?25l\x1b[?2026l",
        try flushed(&s, .truecolor, true, &buf),
    );
}

test "flush: only changed cells, cursor moves only across gaps" {
    var s: Screen = try .init(testing.allocator, 6, 2);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    _ = s.print(1, 0, 2, "xy", .{});
    _ = s.print(4, 0, 1, "z", .{});
    _ = s.print(0, 1, 1, "w", .{ .bold = true });
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;2H\x1b[0mxy\x1b[1;5Hz\x1b[2;1H\x1b[0;1mw\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
    // Writing the same text again changes nothing.
    _ = s.print(1, 0, 2, "xy", .{});
    try testing.expectEqualStrings("", try flushed(&s, .truecolor, false, &buf));
    // Same text, new style.
    _ = s.print(1, 0, 2, "xy", .{ .underline = true });
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;2H\x1b[0;4mxy\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: wide cells are written once and replaced cleanly" {
    var s: Screen = try .init(testing.allocator, 4, 1);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    _ = s.print(0, 0, 4, "中a", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0m中a\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
    // Narrow text over the wide cell rewrites both columns.
    _ = s.print(0, 0, 2, "bc", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0mbc\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
    // A wide cell starting in the second column.
    _ = s.print(1, 0, 2, "文", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;2H\x1b[0m文\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
    // Overwriting its right half blanks the left half too.
    _ = s.print(2, 0, 1, "d", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;2H\x1b[0m d\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: a wide emoji is followed by a cursor move, CJK is not" {
    var s: Screen = try .init(testing.allocator, 12, 1);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    _ = s.print(0, 0, 12, "中a\u{2764}\u{FE0F}b\u{1F3B5}c", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0m中a\u{2764}\u{FE0F}\x1b[1;6Hb\u{1F3B5}\x1b[1;9Hc\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: the last column leaves the cursor position unknown" {
    var s: Screen = try .init(testing.allocator, 3, 2);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    _ = s.print(2, 0, 1, "x", .{});
    _ = s.print(0, 1, 1, "y", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;3H\x1b[0mx\x1b[2;1Hy\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: a cell with marks that leaves the cursor in the last column is written with autowrap on" {
    var s: Screen = try .init(testing.allocator, 4, 1);
    defer s.deinit();
    var buf: [256]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    s.put(2, 0, "e\u{301}", 1, .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;3H\x1b[0m\x1b[?7he\u{301}\x1b[?7l\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: autowrap stays off for plain cells, cells clear of the edge and cells in the last column" {
    var s: Screen = try .init(testing.allocator, 4, 4);
    defer s.deinit();
    var buf: [512]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    s.put(2, 0, "b", 1, .{});
    s.put(1, 1, "a\u{301}", 1, .{});
    s.put(3, 2, "e\u{301}", 1, .{});
    // ZWJ joins a code point that takes columns in a terminal that doesn't cluster; with
    // autowrap on, it could wrap there.
    s.put(2, 3, "\u{2764}\u{200D}\u{1F525}", 1, .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;3H\x1b[0mb\x1b[2;2Ha\u{301}\x1b[3;4He\u{301}\x1b[4;3H\u{2764}\u{200D}\u{1F525}\x1b[0m\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: a cell with marks before the last column gets its own cursor move" {
    var s: Screen = try .init(testing.allocator, 5, 2);
    defer s.deinit();
    _ = s.print(0, 0, 5, "abce\u{301}", .{});
    _ = s.print(2, 1, 2, "中\u{301}", .{});
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0mabc\x1b[1;4H\x1b[?7he\u{301}\x1b[?7l \x1b[2;1H  \x1b[2;3H\x1b[?7h中\u{301}\x1b[?7l\x1b[2;5H \x1b[0m\x1b[?25l\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
}

test "flush: a placeholder box ending one column before the edge wraps only each row's last cell" {
    const graphics = @import("graphics.zig");
    var s: Screen = try .init(testing.allocator, 6, 2);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    graphics.drawPlaceholders(&s, 1, 0, 0x0a0b0c, 4, 2);

    var want_buf: [1024]u8 = undefined;
    var want: Io.Writer = .fixed(&want_buf);
    var cell_buf: [16]u8 = undefined;
    try want.writeAll("\x1b[?2026h");
    for (0..2) |r| {
        try want.print("\x1b[{d};2H", .{r + 1});
        if (r == 0) try want.writeAll("\x1b[0;8;38;2;10;11;12m");
        for (0..3) |c| try want.writeAll(graphics.placeholderCell(&cell_buf, 0x0a0b0c, @intCast(r), @intCast(c)));
        try want.print("\x1b[{d};5H\x1b[?7h", .{r + 1});
        try want.writeAll(graphics.placeholderCell(&cell_buf, 0x0a0b0c, @intCast(r), 3));
        try want.writeAll("\x1b[?7l");
    }
    try want.writeAll("\x1b[0m\x1b[?2026l");
    try testing.expectEqualStrings(want.buffered(), try flushed(&s, .truecolor, false, &buf));
}

test "flush: colors in each mode" {
    var s: Screen = try .init(testing.allocator, 1, 1);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    const cases = [_]struct { Style, ColorMode, []const u8 }{
        .{ .{ .fg = .{ .rgb = 0x102030 } }, .truecolor, "\x1b[0;38;2;16;32;48m" },
        .{ .{ .bg = .{ .rgb = 0xff8000 } }, .truecolor, "\x1b[0;48;2;255;128;0m" },
        .{ .{ .fg = .{ .index = 3 }, .bg = .{ .index = 12 } }, .truecolor, "\x1b[0;33;104m" },
        .{ .{ .fg = .{ .index = 200 } }, .ansi256, "\x1b[0;38;5;200m" },
        .{ .{ .fg = .{ .rgb = 0xff0000 } }, .ansi256, "\x1b[0;38;5;196m" },
        .{ .{ .bg = .{ .rgb = 0x808080 } }, .ansi256, "\x1b[0;48;5;244m" },
        .{ .{ .fg = .{ .rgb = 0x5f87af } }, .ansi256, "\x1b[0;38;5;67m" },
        .{ .{ .fg = .{ .rgb = 0xff0000 } }, .ansi16, "\x1b[0;91m" },
        .{ .{ .fg = .{ .rgb = 0x101010 } }, .ansi16, "\x1b[0;30m" },
        .{ .{ .fg = .{ .index = 196 } }, .ansi16, "\x1b[0;91m" },
        .{ .{ .bg = .{ .index = 4 } }, .ansi16, "\x1b[0;44m" },
        .{ .{ .bold = true, .dim = true, .italic = true, .underline = true, .reverse = true }, .ansi16, "\x1b[0;1;2;3;4;7m" },
        .{ .{ .conceal = true, .fg = .{ .rgb = 0x00a1b2 } }, .truecolor, "\x1b[0;8;38;2;0;161;178m" },
        // A placeholder's image id stays exact in every mode; the rest of the cell follows it.
        .{ .{ .conceal = true, .exact_fg = true, .fg = .{ .rgb = 0x00a1b2 }, .bg = .{ .rgb = 0xff0000 } }, .none, "\x1b[0;8;38;2;0;161;178m" },
        .{ .{ .exact_fg = true, .fg = .{ .rgb = 0x00a1b2 }, .bg = .{ .rgb = 0xff0000 } }, .ansi16, "\x1b[0;38;2;0;161;178;101m" },
        .{ .{ .fg = .{ .rgb = 0x00a1b2 } }, .none, "\x1b[0m" },
    };
    for (cases) |case| {
        _ = s.print(0, 0, 1, "x", case[0]);
        const out = try flushed(&s, case[1], true, &buf);
        const want = try std.fmt.allocPrint(testing.allocator, "\x1b[?2026h\x1b[1;1H{s}x\x1b[0m\x1b[?25l\x1b[?2026l", .{case[2]});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, out);
    }
}

test "nearest256 picks the cube or the gray ramp" {
    try testing.expectEqual(16, nearest256(0x000000));
    try testing.expectEqual(231, nearest256(0xffffff));
    try testing.expectEqual(232, nearest256(0x080808));
    try testing.expectEqual(255, nearest256(0xeeeeee));
    try testing.expectEqual(196, nearest256(0xff0000));
    // Every cube and gray entry maps to itself.
    for (16..256) |i| {
        const idx: u8 = @intCast(i);
        try testing.expectEqual(indexRgb(idx), indexRgb(nearest256(indexRgb(idx))));
    }
}

test "flush: text cursor" {
    var s: Screen = try .init(testing.allocator, 4, 2);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = try flushed(&s, .truecolor, false, &buf);
    s.showCursor(2, 1);
    try testing.expectEqualStrings("\x1b[?2026h\x1b[2;3H\x1b[?25h\x1b[?2026l", try flushed(&s, .truecolor, false, &buf));
    try testing.expectEqualStrings("", try flushed(&s, .truecolor, false, &buf));
    // While shown it is put back after every frame that writes.
    _ = s.print(0, 0, 1, "a", .{});
    try testing.expectEqualStrings("\x1b[?2026h\x1b[1;1H\x1b[0ma\x1b[0m\x1b[2;3H\x1b[?2026l", try flushed(&s, .truecolor, false, &buf));
    s.hideCursor();
    try testing.expectEqualStrings("\x1b[?2026h\x1b[?25l\x1b[?2026l", try flushed(&s, .truecolor, false, &buf));
    s.showCursor(9, 9);
    try testing.expectEqual(null, s.cursor);
}

test "resize blanks the frame and repaints in full" {
    var s: Screen = try .init(testing.allocator, 3, 1);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    _ = s.print(0, 0, 3, "abc", .{});
    s.showCursor(2, 0);
    _ = try flushed(&s, .truecolor, false, &buf);
    try s.resize(2, 2);
    try testing.expectEqual(null, s.cursor);
    _ = s.print(0, 1, 2, "z", .{});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H\x1b[0m  \x1b[2;1Hz \x1b[0m\x1b[?25l\x1b[?2026l",
        try flushed(&s, .truecolor, false, &buf),
    );
    s.invalidate();
    try testing.expect((try flushed(&s, .truecolor, false, &buf)).len > 0);
}

test "a frame bigger than the writer's buffer still comes out whole" {
    var s: Screen = try .init(testing.allocator, 80, 24);
    defer s.deinit();
    for (0..24) |y| _ = s.print(0, @intCast(y), 80, "the quick brown fox jumps over the lazy dog 中文 🎵 é", .{ .fg = .{ .rgb = @intCast(y * 1000) } });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.flush(&out.writer, .truecolor, false);
    try testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[?2026h"));
    try testing.expect(std.mem.endsWith(u8, out.written(), "\x1b[?2026l"));
    try testing.expectEqual(24, std.mem.count(u8, out.written(), "🎵"));
}

test colorMode {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(.ansi16, colorMode(&env));
    try env.put("TERM", "xterm");
    try testing.expectEqual(.ansi16, colorMode(&env));
    try env.put("TERM", "xterm-256color");
    try testing.expectEqual(.ansi256, colorMode(&env));
    try env.put("TERM_PROGRAM", "Apple_Terminal");
    try testing.expectEqual(.ansi256, colorMode(&env));
    try env.put("TERM_PROGRAM", "ghostty");
    try testing.expectEqual(.truecolor, colorMode(&env));
    _ = env.swapRemove("TERM_PROGRAM");
    try env.put("COLORTERM", "24bit");
    try testing.expectEqual(.truecolor, colorMode(&env));
    try env.put("COLORTERM", "yes");
    try testing.expectEqual(.ansi256, colorMode(&env));
    try env.put("TERM", "xterm-kitty");
    try testing.expectEqual(.truecolor, colorMode(&env));
    try env.put("TERM", "foot-direct");
    try testing.expectEqual(.truecolor, colorMode(&env));
    try env.put("NO_COLOR", "");
    try testing.expectEqual(.truecolor, colorMode(&env));
    try env.put("NO_COLOR", "1");
    try testing.expectEqual(.none, colorMode(&env));
}

test "no colors: attributes only" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStyle(&out.writer, .{ .fg = .{ .rgb = 0xff0000 }, .bg = .{ .index = 238 }, .bold = true, .reverse = true }, .none);
    try testing.expectEqualStrings("\x1b[0;1;7m", out.written());
}
