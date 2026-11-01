//! Where the panes go for a terminal size, how a list scrolls, and the pieces of the player
//! bar that are plain arithmetic (sub-cell progress, times). No drawing.
const std = @import("std");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn inset(r: Rect, dx: u16, dy: u16) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w -| 2 * dx, .h = r.h -| 2 * dy };
    }

    pub fn bottom(r: Rect) u16 {
        return r.y + r.h;
    }

    pub fn right(r: Rect) u16 {
        return r.x + r.w;
    }
};

/// Smaller than this, the app shows "terminal too small".
pub const min_cols = 50;
pub const min_rows = 14;
/// From this width the now-playing pane shows.
pub const wide_cols = 110;
/// From this width the sidebar shows; below it a one-line tab strip does.
pub const sidebar_cols = 76;

pub const sidebar_w = 22;
pub const now_w = 36;
/// Player bar rows: title line and progress line.
pub const bar_h = 2;

pub const Layout = struct {
    too_small: bool = false,
    sidebar: ?Rect = null,
    /// The one-line section strip when there is no sidebar.
    tabs: ?Rect = null,
    main: Rect = .{},
    now: ?Rect = null,
    bar: Rect = .{},
    status: Rect = .{},
};

pub fn compute(cols: u16, rows: u16) Layout {
    if (cols < min_cols or rows < min_rows) return .{ .too_small = true };
    const status: Rect = .{ .x = 0, .y = rows - 1, .w = cols, .h = 1 };
    const bar: Rect = .{ .x = 0, .y = rows - 1 - bar_h, .w = cols, .h = bar_h };
    // One separator row above the bar.
    const body_h = rows - 1 - bar_h - 1;
    var out: Layout = .{ .status = status, .bar = bar };
    var x: u16 = 0;
    var w: u16 = cols;
    var y: u16 = 0;
    var h: u16 = body_h;
    if (cols >= sidebar_cols) {
        out.sidebar = .{ .x = 0, .y = 0, .w = sidebar_w, .h = body_h };
        x = sidebar_w + 1;
        w -= sidebar_w + 1;
    } else {
        out.tabs = .{ .x = 0, .y = 0, .w = cols, .h = 1 };
        y = 1;
        h -= 1;
    }
    if (cols >= wide_cols) {
        out.now = .{ .x = cols - now_w, .y = 0, .w = now_w, .h = body_h };
        w -= now_w + 1;
    }
    out.main = .{ .x = x, .y = y, .w = w, .h = h };
    return out;
}

/// The first visible row so that `selected` shows with `margin` rows of context when the list
/// allows, moving as little as possible from `offset`.
pub fn scroll(selected: usize, offset: usize, height: usize, total: usize, margin: usize) usize {
    if (height == 0 or total <= height) return 0;
    const m = @min(margin, (height - 1) / 2);
    var top = offset;
    if (selected < top + m) top = selected -| m;
    if (selected + m >= top + height) top = selected + m + 1 - height;
    return @min(top, total - height);
}

/// A progress bar of `width` cells at `fraction`: `full` whole cells, then one cell holding
/// `eighths` (0 to 7) of a cell.
pub const Progress = struct {
    full: u16,
    eighths: u3,
};

pub fn progress(width: u16, fraction: f64) Progress {
    const f = if (std.math.isNan(fraction)) 0 else std.math.clamp(fraction, 0, 1);
    const total_eighths: u32 = @intFromFloat(@floor(f * @as(f64, @floatFromInt(@as(u32, width) * 8))));
    return .{ .full = @intCast(total_eighths / 8), .eighths = @intCast(total_eighths % 8) };
}

/// The partial block for 1 to 7 eighths of a cell (left-aligned).
pub fn eighthBlock(eighths: u3) []const u8 {
    return switch (eighths) {
        0 => " ",
        1 => "▏",
        2 => "▎",
        3 => "▍",
        4 => "▌",
        5 => "▋",
        6 => "▊",
        7 => "▉",
    };
}

/// `m:ss`, or `h:mm:ss` from an hour; `-:--` when unknown.
pub fn formatTime(buf: []u8, seconds: ?f64) []const u8 {
    const s = seconds orelse return "-:--";
    if (std.math.isNan(s) or s < 0) return "-:--";
    const total: u64 = @intFromFloat(@floor(@min(s, 360000)));
    const h = total / 3600;
    const m = (total / 60) % 60;
    const sec = total % 60;
    return if (h > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, sec }) catch "-:--"
    else
        std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, sec }) catch "-:--";
}

/// The artwork square in a pane: as many rows as fit `max_rows`, with columns from the cell
/// aspect (2:1 when unknown) capped at `max_cols`.
pub const Cover = struct { cols: u16, rows: u16 };

pub fn cover(max_cols: u16, max_rows: u16, cell_w: u16, cell_h: u16) Cover {
    if (max_cols == 0 or max_rows == 0) return .{ .cols = 0, .rows = 0 };
    var rows = max_rows;
    while (rows > 1 and colsFor(rows, cell_w, cell_h) > max_cols) rows -= 1;
    return .{ .cols = @min(colsFor(rows, cell_w, cell_h), max_cols), .rows = rows };
}

fn colsFor(rows: u16, cell_w: u16, cell_h: u16) u16 {
    if (cell_w == 0 or cell_h == 0) return rows *| 2;
    return @intCast(@min((@as(u32, rows) * cell_h + cell_w / 2) / cell_w, std.math.maxInt(u16)));
}

/// The artwork's pixel size to ask Apple for: enough for `cols`×`rows` cells, in steps of 100,
/// between 100 and 600.
pub fn artworkPixels(cols: u16, rows: u16, cell_w: u16, cell_h: u16) u32 {
    const w: u32 = @as(u32, cols) * (if (cell_w == 0) 10 else cell_w);
    const h: u32 = @as(u32, rows) * (if (cell_h == 0) 20 else cell_h);
    const want = @max(w, h);
    return std.math.clamp((want + 99) / 100 * 100, 100, 600);
}

const testing = std.testing;

test "wide: sidebar, list, now playing; narrower drops the pane, then the sidebar" {
    const wide = compute(140, 40);
    try testing.expect(!wide.too_small);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = sidebar_w, .h = 36 }, wide.sidebar.?);
    try testing.expectEqual(Rect{ .x = 140 - now_w, .y = 0, .w = now_w, .h = 36 }, wide.now.?);
    try testing.expectEqual(@as(u16, sidebar_w + 1), wide.main.x);
    try testing.expectEqual(@as(u16, 140 - sidebar_w - 1 - now_w - 1), wide.main.w);
    try testing.expectEqual(Rect{ .x = 0, .y = 37, .w = 140, .h = 2 }, wide.bar);
    try testing.expectEqual(Rect{ .x = 0, .y = 39, .w = 140, .h = 1 }, wide.status);

    const mid = compute(100, 30);
    try testing.expect(mid.now == null);
    try testing.expect(mid.sidebar != null);
    try testing.expectEqual(@as(u16, 100 - sidebar_w - 1), mid.main.w);

    const narrow = compute(60, 20);
    try testing.expect(narrow.sidebar == null and narrow.now == null);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 60, .h = 1 }, narrow.tabs.?);
    try testing.expectEqual(Rect{ .x = 0, .y = 1, .w = 60, .h = 15 }, narrow.main);

    try testing.expect(compute(49, 40).too_small);
    try testing.expect(compute(120, 13).too_small);
}

test "scroll keeps the selection in view with a margin and moves as little as possible" {
    // Fits: never scrolls.
    try testing.expectEqual(@as(usize, 0), scroll(5, 0, 10, 8, 2));
    // Moving down past the bottom margin scrolls by one.
    try testing.expectEqual(@as(usize, 0), scroll(7, 0, 10, 100, 2));
    try testing.expectEqual(@as(usize, 1), scroll(8, 0, 10, 100, 2));
    // Up into the top margin.
    try testing.expectEqual(@as(usize, 48), scroll(50, 49, 10, 100, 2));
    // Jumps.
    try testing.expectEqual(@as(usize, 90), scroll(99, 0, 10, 100, 2));
    try testing.expectEqual(@as(usize, 0), scroll(0, 90, 10, 100, 2));
    // Never past the end.
    try testing.expectEqual(@as(usize, 90), scroll(95, 95, 10, 100, 2));
}

test "progress has eighth-cell precision" {
    try testing.expectEqual(Progress{ .full = 0, .eighths = 0 }, progress(10, 0));
    try testing.expectEqual(Progress{ .full = 5, .eighths = 0 }, progress(10, 0.5));
    try testing.expectEqual(Progress{ .full = 2, .eighths = 4 }, progress(10, 0.25));
    try testing.expectEqual(Progress{ .full = 0, .eighths = 1 }, progress(10, 0.0125));
    try testing.expectEqual(Progress{ .full = 10, .eighths = 0 }, progress(10, 1.5));
    try testing.expectEqual(Progress{ .full = 0, .eighths = 0 }, progress(10, -1));
    try testing.expectEqual(Progress{ .full = 0, .eighths = 0 }, progress(10, std.math.nan(f64)));
    try testing.expectEqualStrings("▌", eighthBlock(4));
}

test "times" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0:00", formatTime(&buf, 0));
    try testing.expectEqualStrings("2:55", formatTime(&buf, 175.9));
    try testing.expectEqualStrings("1:02:03", formatTime(&buf, 3723));
    try testing.expectEqualStrings("-:--", formatTime(&buf, null));
    try testing.expectEqualStrings("-:--", formatTime(&buf, -3));
}

test "cover sizes follow the cell aspect" {
    try testing.expectEqual(Cover{ .cols = 32, .rows = 16 }, cover(32, 20, 0, 0));
    try testing.expectEqual(Cover{ .cols = 20, .rows = 10 }, cover(34, 10, 10, 20));
    // Cells 8×16 px: 16 rows need 32 columns; 9×20: 16 rows → 36 columns, too wide → 15 rows.
    try testing.expectEqual(Cover{ .cols = 32, .rows = 16 }, cover(32, 16, 8, 16));
    try testing.expectEqual(Cover{ .cols = 31, .rows = 14 }, cover(32, 16, 9, 20));
    try testing.expectEqual(@as(u32, 400), artworkPixels(32, 16, 10, 20));
    try testing.expectEqual(@as(u32, 100), artworkPixels(2, 1, 10, 20));
    try testing.expectEqual(@as(u32, 600), artworkPixels(80, 40, 20, 40));
}
