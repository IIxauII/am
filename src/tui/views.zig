//! Drawing the TUI into a `Screen`: the startup and sign-in screens, the sidebar, the list pane
//! with its breadcrumb, the now-playing pane, the player bar, the status line and the overlays.
//! Artwork is not drawn here: the places for it are collected as `ImageSlot`s, which the app
//! fills with kitty images or half blocks.
const std = @import("std");
const auth = @import("auth.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
const list_mod = @import("list.zig");
const model = @import("../music/model.zig");
const playback = @import("../playback.zig");
const playstate = @import("playstate.zig");
const screen_mod = @import("screen.zig");
const ui_mod = @import("ui.zig");
const width = @import("width.zig");

const Color = screen_mod.Color;
const ColorMode = screen_mod.ColorMode;
const Item = model.Item;
const Rect = layout.Rect;
const Screen = screen_mod.Screen;
const Style = screen_mod.Style;
const Ui = ui_mod.Ui;
const View = ui_mod.View;

pub const ImageSlot = struct {
    /// The artwork template (or plain URL).
    url: []const u8,
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
};

pub const Toast = struct {
    text: []const u8,
    kind: enum { info, err } = .info,
};

pub const Frame = struct {
    ui: *Ui,
    auth: *const auth.Machine,
    player: ?*const playstate.Snapshot,
    /// The details of the playing song from the API (favorite, colors), when known.
    now_item: ?Item = null,
    now_ns: i96,
    now_ms: i64,
    color: ColorMode,
    /// Artwork can be shown (a protocol other than `none`).
    images: bool,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    toast: ?Toast = null,
    storefront: []const u8 = "",
    /// The background process answers.
    daemon_up: bool = false,
    /// A `queue` request is on its way (the engine may be starting).
    starting: bool = false,
    busy: bool = false,
    slots: *std.ArrayList(ImageSlot),
    gpa: std.mem.Allocator,
};

// ---- Colors ----

pub const Theme = struct {
    mode: ColorMode,
    accent: Color,
    sel_bg: Color,
    track: Color,
    rule: Color,
    good: Color,
    bad: Color,
    warn: Color,
    muted: Color,

    fn dim(t: Theme) Style {
        if (t.mode == .none) return .{ .dim = true };
        return .{ .fg = t.muted };
    }

    fn strong(t: Theme) Style {
        _ = t;
        return .{ .bold = true };
    }

    fn accented(t: Theme) Style {
        return .{ .fg = t.accent, .bold = true };
    }

    fn selected(t: Theme, focused: bool) Style {
        if (t.mode == .ansi16 or t.mode == .none) return .{ .reverse = focused, .bold = !focused };
        return .{ .bg = if (focused) t.sel_bg else t.track, .bold = focused };
    }
};

const default_accent: u24 = 0xFA586A;

pub fn theme(mode: ColorMode, art: ?model.Artwork) Theme {
    return switch (mode) {
        .truecolor => .{
            .mode = mode,
            .accent = .{ .rgb = accentFrom(art) orelse default_accent },
            .sel_bg = .{ .rgb = 0x3A3F55 },
            .track = .{ .rgb = 0x2E3040 },
            .rule = .{ .rgb = 0x45475A },
            .good = .{ .rgb = 0x7CCF8A },
            .bad = .{ .rgb = 0xF07178 },
            .warn = .{ .rgb = 0xF2C46D },
            .muted = .{ .rgb = 0x8A8FA8 },
        },
        .ansi256 => .{ .mode = mode, .accent = .{ .index = 204 }, .sel_bg = .{ .index = 238 }, .track = .{ .index = 236 }, .rule = .{ .index = 240 }, .good = .{ .index = 114 }, .bad = .{ .index = 203 }, .warn = .{ .index = 221 }, .muted = .{ .index = 245 } },
        .ansi16, .none => .{ .mode = mode, .accent = .{ .index = 5 }, .sel_bg = .{ .index = 8 }, .track = .{ .index = 8 }, .rule = .{ .index = 8 }, .good = .{ .index = 2 }, .bad = .{ .index = 1 }, .warn = .{ .index = 3 }, .muted = .{ .index = 8 } },
    };
}

/// The more colorful of the artwork's background and text color, if either is colorful enough
/// to read on a dark terminal.
pub fn accentFrom(art: ?model.Artwork) ?u24 {
    const a = art orelse return null;
    var best: ?u24 = null;
    var best_score: f32 = 0.18;
    for ([_]?u24{ a.bg, a.text1 }) |maybe| {
        const c = maybe orelse continue;
        const r: f32 = @floatFromInt(c >> 16);
        const g: f32 = @floatFromInt((c >> 8) & 0xFF);
        const b: f32 = @floatFromInt(c & 0xFF);
        const max = @max(r, @max(g, b)) / 255;
        const min = @min(r, @min(g, b)) / 255;
        if (max < 0.45) continue;
        const score = (max - min) * max;
        if (score > best_score) {
            best_score = score;
            best = c;
        }
    }
    return best;
}

// ---- Glyphs (single-width text characters that common monospace fonts carry) ----

pub const glyph = struct {
    pub const playing = "▶";
    pub const paused = "‖";
    pub const stopped = "■";
    pub const shuffle = "⇄";
    pub const repeat = "↻";
    pub const heart = "♥";
    pub const live = "●";
    pub const now = "▶";
    pub const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
};

fn spin(now_ms: i64) []const u8 {
    return glyph.spinner[@intCast(@mod(@divFloor(now_ms, 80), glyph.spinner.len))];
}

// ---- Entry ----

pub fn draw(s: *Screen, f: *Frame) void {
    const l = layout.compute(s.cols, s.rows);
    s.clear(.{});
    s.hideCursor();
    if (l.too_small) {
        const msg = "terminal too small";
        const sub = std.fmt.allocPrint(f.gpa, "{d}×{d}, need {d}×{d}", .{ s.cols, s.rows, layout.min_cols, layout.min_rows }) catch "";
        defer if (sub.len > 0) f.gpa.free(sub);
        center(s, 0, s.rows / 2 -| 1, s.cols, msg, .{ .bold = true });
        center(s, 0, s.rows / 2, s.cols, sub, .{ .dim = true });
        return;
    }
    const art = if (f.now_item) |n| n.artwork else null;
    const t = theme(f.color, art);
    if (f.auth.phase != .ready and !f.auth.in_session) return drawAuth(s, f, t, .{ .x = 0, .y = 0, .w = s.cols, .h = s.rows });

    f.ui.has_sidebar = l.sidebar != null;
    if (!f.ui.has_sidebar and f.ui.focus == .sidebar) f.ui.focus = .main;
    if (l.sidebar) |r| drawSidebar(s, f, t, r);
    if (l.tabs) |r| drawTabs(s, f, t, r);
    drawMain(s, f, t, l.main);
    if (l.now) |r| drawNowPane(s, f, t, r);
    // Separators.
    if (l.sidebar) |r| vline(s, r.right(), 0, r.h, t);
    if (l.now) |r| vline(s, r.x -| 1, 0, r.h, t);
    hline(s, 0, l.bar.y -| 1, s.cols, t);
    drawBar(s, l.bar, barInfo(f), t, f.now_ms);
    drawStatus(s, f, t, l.status);
}

/// What goes on top of the frame, after the artwork: help, details, the playlist picker, and
/// the sign-in box when Apple asks to sign in again during the session.
pub fn drawOverlays(s: *Screen, f: *Frame) void {
    const l = layout.compute(s.cols, s.rows);
    if (l.too_small) return;
    if (f.auth.phase != .ready and !f.auth.in_session) return;
    const t = theme(f.color, if (f.now_item) |n| n.artwork else null);
    switch (f.ui.overlay) {
        .none => {},
        .help => drawHelp(s, t, &f.ui.help_scroll),
        .info => drawInfo(s, f, t),
        .picker => drawPicker(s, f, t),
    }
    if (f.auth.phase != .ready) {
        const w = @min(s.cols -| 4, 76);
        const h = @min(s.rows -| 4, 18);
        const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows - h) / 2, .w = w, .h = h };
        box(s, r, t, "Sign in");
        drawAuth(s, f, t, r.inset(2, 1));
    }
}

/// Where artwork goes while it loads, failed, or images are off.
pub fn artPlaceholderAt(s: *Screen, x: u16, y: u16, cols: u16, rows: u16, mode: ColorMode, loading: bool) void {
    const t = theme(mode, null);
    s.fill(x, y, cols, rows, .{ .bg = t.track });
    if (cols >= 1 and rows >= 1) _ = s.print(x + cols / 2, y + rows / 2, 1, if (loading) "·" else "♪", .{ .bg = t.track, .fg = t.muted });
}

// ---- Startup and sign-in ----

fn drawAuth(s: *Screen, f: *Frame, t: Theme, area: Rect) void {
    const m = f.auth;
    const w = @min(area.w -| 4, 112);
    const x = area.x + (area.w - w) / 2;
    var y = area.y + @as(u16, if (area.h > 30) area.h / 6 else 1);
    if (area.w == s.cols) {
        _ = s.print(x, y, w, "am", t.accented());
        _ = s.print(x + 3, y, w - 3, "· Apple Music in the terminal", t.dim());
        y += 2;
    }
    var buf: [256]u8 = undefined;
    switch (m.phase) {
        .checking => {
            _ = s.print(x, y, w, spin(f.now_ms), .{ .fg = t.accent });
            _ = s.print(x + 2, y, w - 2, "Checking your Apple Music sign-in…", .{});
        },
        .setup => {
            _ = s.print(x, y, w, "Set up am first", .{ .bold = true, .fg = t.warn });
            const bottom = area.bottom() -| 2;
            const full = m.text.get();
            // Too short for all of it: less prose, step by step, keeping the commands.
            const room = bottom -| (y + 2);
            var text = full;
            var level: u8 = 1;
            while (wrapHeight(w, text) > room and level <= 3) : (level += 1) {
                if (text.ptr != full.ptr) f.gpa.free(text);
                text = condensed(f.gpa, full, level) catch full;
            }
            defer if (text.ptr != full.ptr) f.gpa.free(text);
            y = wrap(s, x, y + 2, w, bottom, text, .{});
            _ = s.print(x, @min(y + 1, area.bottom() -| 1), w, "r check again · q quit", t.dim());
        },
        .signing_in => {
            _ = s.print(x, y, w, spin(f.now_ms), .{ .fg = t.accent });
            _ = s.print(x + 2, y, w - 2, "Signing in to Apple Music", .{ .bold = true });
            y = wrap(s, x, y + 2, w, area.bottom(), m.text.get(), t.dim());
            y += 1;
            if (m.url.len > 0) {
                y = wrap(s, x, y, w, area.bottom(), "Your browser opened the sign-in page. Click \"Sign in to Apple Music\" and finish Apple's sign-in there. If no page opened, open this address:", .{});
                _ = s.print(x + 2, y, w -| 2, m.url.get(), .{ .fg = t.accent, .underline = true });
                y += 2;
            } else {
                _ = s.print(x, y, w, "Starting the background process…", .{});
                y += 2;
            }
            var lines: [3][]const u8 = undefined;
            for (m.signinLines(&lines)) |line| {
                _ = s.print(x, y, w, line, .{ .fg = t.bad });
                y += 1;
            }
            const left = m.signinLeft(f.now_ms);
            const wait = std.fmt.bufPrint(&buf, "waiting {d}:{d:0>2} more", .{ @divFloor(left, 60), @mod(left, 60) }) catch "";
            _ = s.print(x, @min(y + 1, area.bottom() -| 2), w, wait, t.dim());
            _ = s.print(x, @min(y + 2, area.bottom() -| 1), w, if (m.in_session) "o open the page again · Esc back to the music · q quit" else "o open the page again · Esc cancel · q quit", t.dim());
        },
        .signed_out => {
            _ = s.print(x, y, w, "Not signed in", .{ .bold = true, .fg = t.warn });
            y = wrap(s, x, y + 2, w, area.bottom(), m.text.get(), .{});
            _ = s.print(x, y + 1, w, if (m.in_session) "s sign in · Esc back to the music · q quit" else "s sign in · q quit", t.dim());
        },
        .retry => {
            _ = s.print(x, y, w, "Can't check the sign-in right now", .{ .bold = true, .fg = t.warn });
            y = wrap(s, x, y + 2, w, area.bottom(), m.text.get(), .{});
            const again = std.fmt.bufPrint(&buf, "Trying again in {d} s · r now · q quit", .{m.retryIn(f.now_ms)}) catch "";
            _ = s.print(x, y + 1, w, again, t.dim());
        },
        .fatal => {
            _ = s.print(x, y, w, "am can't start", .{ .bold = true, .fg = t.bad });
            y = wrap(s, x, y + 2, w, area.bottom(), m.text.get(), .{});
            _ = s.print(x, y + 1, w, "q quit", t.dim());
        },
        .ready => {},
    }
}

// ---- Sidebar ----

fn drawSidebar(s: *Screen, f: *Frame, t: Theme, r: Rect) void {
    const u = f.ui;
    var y = r.y;
    _ = s.print(r.x + 1, y, r.w - 1, "am", t.accented());
    y += 2;
    var library_heading = false;
    for (keys.sidebar, 0..) |sec, i| {
        if (y >= r.bottom()) break;
        if (sec.inLibrary() and !library_heading) {
            library_heading = true;
            _ = s.print(r.x + 1, y, r.w - 1, "Library", t.dim());
            y += 1;
        }
        const active = sec == u.section;
        const picked = u.focus == .sidebar and i == u.sidebar_pick;
        const style: Style = if (picked) t.selected(true) else if (active) .{ .fg = t.accent, .bold = true } else .{};
        if (picked) s.fill(r.x, y, r.w, 1, style);
        const indent: u16 = if (sec.inLibrary()) 3 else 1;
        var label_buf: [48]u8 = undefined;
        const label = if (sec.defaultKey()) |k|
            std.fmt.bufPrint(&label_buf, "{c} {s}", .{ k, sec.title() }) catch sec.title()
        else
            std.fmt.bufPrint(&label_buf, "  {s}", .{sec.title()}) catch sec.title();
        _ = s.print(r.x + indent, y, r.w -| indent, label, style);
        if (active and !picked) _ = s.print(r.x, y, 1, "▌", .{ .fg = t.accent });
        y += 1;
    }
}

fn drawTabs(s: *Screen, f: *Frame, t: Theme, r: Rect) void {
    const current = f.ui.section;
    var bufs: [keys.sidebar.len][32]u8 = undefined;
    var full: [keys.sidebar.len][]const u8 = undefined;
    var total: usize = 0;
    for (keys.sidebar, 0..) |sec, i| {
        full[i] = tabLabel(&bufs[i], sec, false);
        total += width.textWidth(full[i]) + 2;
    }
    // Every tab spelled out when they fit; else just their keys, the current one spelled out.
    const compact = total > r.w;
    var x = r.x;
    for (keys.sidebar, 0..) |sec, i| {
        var short_buf: [32]u8 = undefined;
        const label = if (!compact or sec == current) full[i] else tabLabel(&short_buf, sec, true);
        if (label.len == 0) continue;
        const w: u16 = @intCast(width.textWidth(label));
        if (x + w > r.right()) break;
        const style: Style = if (sec == current) .{ .fg = t.accent, .bold = true, .underline = true } else t.dim();
        _ = s.print(x, r.y, w, label, style);
        x += w + if (compact) @as(u16, 1) else 2;
    }
}

/// "1 Home"; `short`: "1" (nothing for a section without a key; Tab still reaches it).
fn tabLabel(buf: []u8, sec: keys.Section, short: bool) []const u8 {
    const name = switch (sec) {
        .recent => "Recent",
        .recently_added => "Added",
        .queue => "Queue",
        else => sec.title(),
    };
    const k = sec.defaultKey() orelse return if (short) "" else name;
    if (short) return std.fmt.bufPrint(buf, "{c}", .{k}) catch "";
    return std.fmt.bufPrint(buf, "{c} {s}", .{ k, name }) catch name;
}

// ---- Main pane ----

fn drawMain(s: *Screen, f: *Frame, t: Theme, r: Rect) void {
    const u = f.ui;
    const v = u.current() orelse return;
    var y = r.y;
    drawBreadcrumb(s, f, t, .{ .x = r.x, .y = y, .w = r.w, .h = 1 }, v);
    y += 1;
    hline(s, r.x, y, r.w, t);
    y += 1;

    if (v.search) |search| {
        drawSearchInput(s, f, t, .{ .x = r.x, .y = y, .w = r.w, .h = 1 }, search);
        y += 2;
        if (search.focused and search.suggestions.items.len > 0) {
            _ = s.print(r.x + 1, y, r.w -| 1, "Suggestions", t.dim());
            y += 1;
            for (search.suggestions.items, 0..) |sug, i| {
                if (y >= r.bottom()) break;
                const picked = search.pick == i;
                if (picked) s.fill(r.x, y, r.w, 1, t.selected(true));
                _ = s.print(r.x + 3, y, r.w -| 3, sug, if (picked) t.selected(true) else .{});
                y += 1;
            }
            u.height = r.bottom() -| y;
            return;
        }
        if (search.submitted.items.len == 0) {
            const hint = if (search.library) "Type to search your library, Enter to search." else "Type to search Apple Music, Enter to search. Tab switches to your library.";
            _ = wrap(s, r.x + 1, y, r.w -| 2, r.bottom(), hint, t.dim());
            u.height = r.bottom() -| y;
            return;
        }
    }

    // A header with the cover for albums, playlists and artists.
    if (v.subject) |subject| if (r.h >= 18) {
        y = drawDetailHeader(s, f, t, .{ .x = r.x, .y = y, .w = r.w, .h = r.bottom() - y }, v, subject);
    };

    var bottom = r.bottom();
    if (u.filtering or v.list.filter.items.len > 0) {
        bottom -= 1;
        const style: Style = if (u.filtering) .{ .fg = t.accent } else t.dim();
        const label = "Filter: ";
        const label_w: u16 = label.len;
        _ = s.print(r.x + 1, bottom, r.w -| 1, label, style);
        const used = s.print(r.x + 1 + label_w, bottom, r.w -| (label_w + 1), v.list.filter.items, .{});
        if (u.filtering) s.showCursor(r.x + 1 + label_w + used, bottom);
    }
    const h = bottom -| y;
    u.height = @max(1, h);
    drawList(s, f, t, .{ .x = r.x, .y = y, .w = r.w, .h = h }, v, u.focus == .main and !u.textMode());
}

fn drawBreadcrumb(s: *Screen, f: *Frame, t: Theme, r: Rect, v: *View) void {
    const u = f.ui;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (u.section.inLibrary()) w.writeAll("Library › ") catch {};
    for (u.trail(), 0..) |view, i| {
        if (i > 0) w.writeAll(" › ") catch {};
        w.writeAll(view.title) catch {};
    }
    var count_buf: [48]u8 = undefined;
    const count: []const u8 = if (v.list.loading and v.list.len() == 0)
        spin(f.now_ms)
    else if (v.list.total) |total|
        thousands(&count_buf, total)
    else if (v.list.loaded and v.kind != .home and v.kind != .search and v.list.groups.items.len == 0)
        thousands(&count_buf, v.list.len())
    else
        "";
    const cw: u16 = @intCast(width.textWidth(count));
    _ = s.print(r.x + 1, r.y, r.w -| (cw + 3), w.buffered(), .{ .bold = true });
    if (cw > 0) _ = s.print(r.right() -| (cw + 1), r.y, cw, count, if (v.list.loading) .{ .fg = t.accent } else t.dim());
}

fn thousands(buf: []u8, n: usize) []const u8 {
    var tmp: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return "";
    var out: usize = 0;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            // A thin no-break space.
            const sep = "\u{202F}";
            @memcpy(buf[out .. out + sep.len], sep);
            out += sep.len;
        }
        buf[out] = c;
        out += 1;
    }
    return buf[0..out];
}

fn drawSearchInput(s: *Screen, f: *Frame, t: Theme, r: Rect, search: *ui_mod.Search) void {
    const focused = search.focused and f.ui.focus == .main and f.ui.overlay == .none;
    const scope = if (search.library) "Library" else "Apple Music";
    var buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Search {s}: ", .{scope}) catch "Search: ";
    const lw: u16 = @intCast(width.textWidth(label));
    _ = s.print(r.x + 1, r.y, lw, label, if (focused) .{ .fg = t.accent, .bold = true } else t.dim());
    const used = s.print(r.x + 1 + lw, r.y, r.w -| (lw + 2), search.query.items, .{ .bold = true });
    if (focused) s.showCursor(r.x + 1 + lw + used, r.y);
    const hint = "Tab: catalog/library";
    const hw: u16 = @intCast(width.textWidth(hint));
    if (r.w > lw + used + hw + 6) _ = s.print(r.right() - hw - 1, r.y, hw, hint, t.dim());
}

fn drawDetailHeader(s: *Screen, f: *Frame, t: Theme, r: Rect, v: *View, it: Item) u16 {
    const rows: u16 = if (r.h >= 30) 8 else 6;
    const c = layout.cover(16, rows, f.cell_w, f.cell_h);
    var x = r.x + 1;
    if (f.images and it.artwork != null) {
        f.slots.append(f.gpa, .{ .url = it.artwork.?.url, .x = x, .y = r.y, .cols = c.cols, .rows = c.rows }) catch {};
        x += c.cols + 2;
    } else {
        artPlaceholder(s, x, r.y, c.cols, c.rows, t, it.artwork);
        x += c.cols + 2;
    }
    const w = r.right() -| (x + 1);
    var y = r.y;
    const kind = switch (it.kind) {
        .album => if (it.library) "ALBUM · IN YOUR LIBRARY" else "ALBUM",
        .playlist => if (it.library) "PLAYLIST · IN YOUR LIBRARY" else "PLAYLIST",
        .artist => "ARTIST",
        else => "",
    };
    _ = s.print(x, y, w, kind, t.dim());
    y += 1;
    const tw = s.print(x, y, w, it.title, .{ .bold = true, .fg = t.accent });
    if (it.favorited == true) _ = s.print(x + tw + 1, y, 2, glyph.heart, .{ .fg = t.accent });
    y += 1;
    if (it.artist) |a| {
        _ = s.print(x, y, w, a, .{});
        y += 1;
    }
    var meta_buf: [160]u8 = undefined;
    var mw: std.Io.Writer = .fixed(&meta_buf);
    if (it.release_date) |d| mw.writeAll(d[0..@min(4, d.len)]) catch {};
    if (it.genre) |g| {
        if (mw.end > 0) mw.writeAll(" · ") catch {};
        mw.writeAll(g) catch {};
    }
    if (v.list.total) |n| {
        if (mw.end > 0) mw.writeAll(" · ") catch {};
        mw.print("{d} {s}", .{ n, if (n == 1) "track" else "tracks" }) catch {};
    }
    if (mw.end > 0) {
        _ = s.print(x, y, w, mw.buffered(), t.dim());
        y += 1;
    }
    if (it.description) |d| if (y + 1 < r.y + c.rows) {
        _ = wrap(s, x, y + 1, w, r.y + c.rows, d, t.dim());
    };
    const hint = if (it.kind == .artist) "Enter open · R station" else "Enter play from track · P play all · e/E queue · f ♥";
    _ = s.print(x, r.y + c.rows -| 1, w, hint, t.dim());
    return r.y + c.rows + 1;
}

fn artPlaceholder(s: *Screen, x: u16, y: u16, cols: u16, rows: u16, t: Theme, art: ?model.Artwork) void {
    const bg: Color = if (t.mode != .ansi16 and t.mode != .none) (if (art) |a| if (a.bg) |c| Color{ .rgb = c } else t.track else t.track) else t.track;
    s.fill(x, y, cols, rows, .{ .bg = bg });
    if (cols >= 1 and rows >= 1) _ = s.print(x + cols / 2, y + rows / 2, 1, "♪", .{ .bg = bg, .fg = t.muted });
}

fn drawList(s: *Screen, f: *Frame, t: Theme, r: Rect, v: *View, focused: bool) void {
    const l = &v.list;
    if (r.h == 0) return;
    if (l.len() == 0) {
        const y = r.y + 1;
        if (l.failed) |msg| {
            _ = s.print(r.x + 2, y, r.w -| 3, msg, .{ .fg = t.bad });
            _ = s.print(r.x + 2, y + 1, r.w -| 3, "^r to try again", t.dim());
        } else if (l.loading or !l.loaded) {
            _ = s.print(r.x + 2, y, 2, spin(f.now_ms), .{ .fg = t.accent });
            _ = s.print(r.x + 4, y, r.w -| 5, "Loading…", t.dim());
        } else if (l.filter.items.len > 0) {
            _ = s.print(r.x + 2, y, r.w -| 3, "Nothing matches the filter.", t.dim());
        } else {
            _ = s.print(r.x + 2, y, r.w -| 3, emptyText(v), t.dim());
        }
        return;
    }
    l.scrollTo(r.h);
    const np = if (f.player) |p| p.nowPlaying() else null;
    // Up Next marks the playing position, not every row with the playing song.
    const queue_pos: ?i64 = if (v.kind != .queue) null else if (f.player) |p| if (p.report) |rep| if (rep.queue) |q| q.position else null else null else null;
    const tracks = v.kind == .tracks and v.subject != null and v.subject.?.kind == .album;
    // One kind of item only: no kind labels.
    const uniform = l.groups.items.len == 0 and switch (v.kind) {
        .library, .favorites_scan, .recently_added => true,
        else => false,
    };
    // One right column for the rows on screen, so titles and artists line up across kinds.
    var tail_w: u16 = 0;
    {
        var j = l.offset;
        var rows: usize = 0;
        while (rows < r.h and j < l.len()) : ({
            j += 1;
            rows += 1;
        }) {
            const row = l.rowAt(j);
            if (row.tag != .item) continue;
            var dur_buf: [16]u8 = undefined;
            tail_w = @max(tail_w, @as(u16, @intCast(width.textWidth(tailText(&dur_buf, row.item, uniform)))));
        }
    }
    var i = l.offset;
    var y = r.y;
    while (y < r.bottom() and i < l.len()) : ({
        i += 1;
        y += 1;
    }) {
        const row = l.rowAt(i);
        const sel = i == l.selected and row.selectable();
        const playing = if (v.kind == .queue) (if (queue_pos) |pos| row.tag == .item and pos == row.aux else false) else row.tag == .item and isNowPlaying(row.item, np);
        drawRow(s, t, .{ .x = r.x, .y = y, .w = r.w, .h = 1 }, row, sel, focused, playing, tracks, v.kind == .queue, uniform, tail_w);
    }
    if (l.loading and y < r.bottom()) {
        _ = s.print(r.x + 2, y, 2, spin(f.now_ms), .{ .fg = t.accent });
        _ = s.print(r.x + 4, y, r.w -| 5, "Loading more…", t.dim());
    } else if (l.failed) |msg| if (y < r.bottom()) {
        _ = s.print(r.x + 2, y, r.w -| 3, msg, .{ .fg = t.bad });
    };
    // A scroll indicator.
    if (l.len() > r.h) {
        const frac = @as(f64, @floatFromInt(l.offset)) / @as(f64, @floatFromInt(l.len() - r.h));
        const pos: u16 = @intFromFloat(@round(frac * @as(f64, @floatFromInt(r.h - 1))));
        _ = s.print(r.right() -| 1, r.y + pos, 1, "┃", .{ .fg = t.rule });
    }
}

fn emptyText(v: *const View) []const u8 {
    return switch (v.kind) {
        .queue => "Up Next is empty. Enter on a song plays it with its album or list.",
        .favorites_scan => "No favorites found here yet.",
        .favorites => "No favorites yet: f on a song, album or playlist adds one.",
        .search => "No results.",
        else => "Nothing here.",
    };
}

fn isNowPlaying(it: Item, np: ?playback.NowPlaying) bool {
    const n = np orelse return false;
    if (n.id) |id| {
        if (std.mem.eql(u8, id, it.id)) return true;
        if (it.catalog_id) |c| if (std.mem.eql(u8, c, id)) return true;
    }
    if (n.catalogId) |c| {
        if (std.mem.eql(u8, c, it.id)) return true;
        if (it.catalog_id) |ic| if (std.mem.eql(u8, c, ic)) return true;
    }
    return false;
}

/// The right-hand label of a row: a duration, a year, or what kind of item it is.
fn tailText(buf: []u8, it: Item, uniform: bool) []const u8 {
    return switch (it.kind) {
        .song, .music_video => if (it.duration_ms) |ms| layout.formatTime(buf, @as(f64, @floatFromInt(ms)) / 1000) else "",
        .album => if (uniform) (if (it.release_date) |d| d[0..@min(4, d.len)] else "") else "album",
        .playlist => if (uniform) "" else "playlist",
        .artist => if (uniform) "" else "artist",
        .station => if (it.is_live) "live" else "station",
        .curator => "curator",
    };
}

fn drawRow(s: *Screen, t: Theme, r: Rect, row: *const list_mod.Row, sel: bool, focused: bool, playing: bool, tracks: bool, queue: bool, uniform: bool, tail_col: u16) void {
    const base: Style = if (sel) t.selected(focused) else .{};
    if (sel) {
        s.fill(r.x, r.y, r.w, 1, base);
        var mark = base;
        mark.fg = t.accent;
        _ = s.print(r.x, r.y, 1, if (focused) "▌" else "▏", mark);
    }
    switch (row.tag) {
        .header => {
            const w = s.print(r.x + 1, r.y, r.w -| 2, row.text, .{ .fg = t.accent, .bold = true });
            if (r.w > w + 4) hlineStyle(s, r.x + w + 2, r.y, r.w - w - 3, .{ .fg = t.rule });
            return;
        },
        .more => {
            var st = base;
            st.fg = t.muted;
            _ = s.print(r.x + 3, r.y, r.w -| 4, "See all ›", st);
            return;
        },
        .note => {
            _ = s.print(r.x + 3, r.y, r.w -| 4, row.text, t.dim());
            return;
        },
        .item => {},
    }
    const it = row.item;
    var st = base;
    if (!it.playable and it.kind == .song) st.fg = t.muted;
    if (playing) {
        st.fg = t.accent;
        st.bold = true;
    }
    // Lead: now-playing mark, track number, or kind.
    var lead_buf: [8]u8 = undefined;
    const lead: []const u8 = if (playing)
        glyph.now
    else if (tracks and it.track_number != null)
        std.fmt.bufPrint(&lead_buf, "{d}", .{it.track_number.?}) catch ""
    else if (queue)
        std.fmt.bufPrint(&lead_buf, "{d}", .{row.aux + 1}) catch ""
    else
        "";
    const lead_w: u16 = 4;
    if (lead.len > 0) {
        const lw: u16 = @intCast(width.textWidth(lead));
        var ls = st;
        if (!playing) ls.fg = t.muted;
        _ = s.print(r.x + lead_w -| (lw + 1), r.y, lw, lead, ls);
    }
    var x = r.x + lead_w;
    const right_end = r.right() -| 1;
    // Right: heart, duration or kind label.
    const heart_w: u16 = 2;
    var right_x = right_end -| heart_w;
    if (it.favorited == true) _ = s.print(right_x + 1, r.y, 1, glyph.heart, blend(st, t.accent));
    var dur_buf: [16]u8 = undefined;
    const tail = tailText(&dur_buf, it, uniform);
    const tail_w: u16 = @intCast(width.textWidth(tail));
    // The column is as wide as the widest tail on screen; each tail sits at its right end.
    if (tail_col > 0 and right_x > x + tail_col + 10) {
        right_x -= tail_col + 1;
        if (tail_w > 0) _ = s.print(right_x + tail_col - tail_w, r.y, tail_w, tail, blend(st, t.muted));
    }
    const avail = right_x -| (x + 1);
    // Title, then artist (and album when wide).
    const show_album = !tracks and avail >= 70 and it.kind == .song and it.album != null;
    const title_w: u16 = if (it.artist == null) avail else if (show_album) avail * 2 / 5 else avail * 3 / 5;
    _ = s.print(x, r.y, title_w -| 1, it.title, if (playing) st else blend(st, null));
    x += title_w;
    if (it.artist) |a| {
        const aw: u16 = if (show_album) (avail - title_w) / 2 else avail - title_w;
        _ = s.print(x, r.y, aw -| 1, a, blend(st, t.muted));
        x += aw;
        if (show_album) _ = s.print(x, r.y, (avail - title_w - aw) -| 1, it.album.?, blend(st, t.muted));
    }
    if (queue and row.flag) _ = s.print(right_end -| 1, r.y, 1, "∞", blend(st, t.muted));
}

/// `st` with a foreground, keeping a selection's background.
fn blend(st: Style, fg: ?Color) Style {
    var out = st;
    if (fg) |c| if (!st.reverse) {
        out.fg = c;
    };
    return out;
}

// ---- Now playing ----

fn drawNowPane(s: *Screen, f: *Frame, t: Theme, r: Rect) void {
    const x = r.x + 1;
    const w = r.w -| 2;
    var y = r.y;
    _ = s.print(x, y, w, "Now Playing", t.dim());
    y += 2;
    const p = f.player;
    const np = if (p) |snap| snap.nowPlaying() else null;
    // The cover takes about half the pane.
    const max_rows: u16 = @min(r.h / 2, w / 2 + 1);
    const c = layout.cover(w, max_rows, f.cell_w, f.cell_h);
    const cx = x + (w - c.cols) / 2;
    if (np) |n| {
        if (f.images and n.artworkUrl != null) {
            f.slots.append(f.gpa, .{ .url = n.artworkUrl.?, .x = cx, .y = y, .cols = c.cols, .rows = c.rows }) catch {};
        } else artPlaceholder(s, cx, y, c.cols, c.rows, t, if (f.now_item) |it| it.artwork else null);
    } else artPlaceholder(s, cx, y, c.cols, c.rows, t, null);
    y += c.rows + 1;
    const n = np orelse {
        _ = s.print(x, y, w, "Nothing playing", .{ .bold = true });
        _ = wrap(s, x, y + 2, w, r.bottom(), "Pick a song and press Enter: it plays with the rest of its album or list.", t.dim());
        return;
    };
    const live = if (p.?.report) |rep| rep.liveInfo else null;
    const title = n.title orelse "";
    const tw = s.print(x, y, w -| 2, title, .{ .bold = true });
    const fav = if (f.now_item) |it| it.favorited orelse false else false;
    if (fav) _ = s.print(x + tw + 1, y, 1, glyph.heart, .{ .fg = t.accent });
    y += 1;
    if (n.artist) |a| {
        _ = s.print(x, y, w, a, .{ .fg = t.accent });
        y += 1;
    }
    if (n.album) |a| {
        var buf: [160]u8 = undefined;
        const year = if (f.now_item) |it| if (it.release_date) |d| d[0..@min(4, d.len)] else "" else "";
        const text = if (year.len > 0) std.fmt.bufPrint(&buf, "{s} · {s}", .{ a, year }) catch a else a;
        _ = s.print(x, y, w, text, t.dim());
        y += 1;
    }
    if (live) |info| {
        y += 1;
        _ = s.print(x, y, w, glyph.live ++ " LIVE", .{ .fg = t.bad, .bold = true });
        y += 1;
        if (info.title) |lt| {
            _ = s.print(x, y, w, lt, .{});
            y += 1;
        }
        if (info.artist) |la| {
            _ = s.print(x, y, w, la, t.dim());
            y += 1;
        }
    }
    y += 1;
    switch (playstate.verdict(n)) {
        .full => {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "✓ full track ({s})", .{n.playbackType.?}) catch "✓ full track";
            _ = s.print(x, y, w, text, .{ .fg = t.good });
        },
        .preview => _ = s.print(x, y, w, "▲ 30 s PREVIEW only", .{ .fg = t.bad, .bold = true }),
        .unknown => if (n.playbackType) |pt| {
            _ = s.print(x, y, w, pt, t.dim());
        },
    }
    y += 1;
    if (n.container) |cont| if (cont.name) |name| {
        var buf: [160]u8 = undefined;
        _ = s.print(x, y, w, std.fmt.bufPrint(&buf, "from {s}", .{name}) catch name, t.dim());
        y += 1;
    };
    // Up next.
    const q = if (p.?.report) |rep| rep.queue else null;
    if (q) |queue| if (queue.upcoming.len > 0 and y + 3 < r.bottom()) {
        y += 1;
        var buf: [48]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "Up Next  {d}/{d}", .{ @max(queue.position + 1, 0), queue.length }) catch "Up Next";
        _ = s.print(x, y, w, head, t.dim());
        y += 1;
        for (queue.upcoming) |qi| {
            if (y >= r.bottom()) break;
            const tt = qi.title orelse "";
            const used = s.print(x, y, w, tt, .{});
            if (qi.artist) |a| if (used + 4 < w) {
                _ = s.print(x + used + 2, y, w - used - 2, a, t.dim());
            };
            y += 1;
        }
    };
}

// ---- Player bar ----

pub const BarInfo = struct {
    state: enum { playing, paused, stopped, loading, idle } = .idle,
    title: []const u8 = "",
    artist: []const u8 = "",
    position: ?f64 = null,
    duration: ?f64 = null,
    live: bool = false,
    shuffle: bool = false,
    repeat: @import("../daemon/player.zig").Repeat = .none,
    volume: f64 = 0.5,
    muted: bool = false,
    verdict: playstate.Verdict = .unknown,
    /// Shown instead of a title when nothing plays.
    note: []const u8 = "",
};

fn barInfo(f: *const Frame) BarInfo {
    var b: BarInfo = .{ .volume = f.ui.volume, .muted = f.ui.muted_from != null };
    const p = f.player orelse {
        b.note = if (f.daemon_up) "Nothing playing" else "Connecting to the background process…";
        return b;
    };
    b.shuffle = p.shuffleOn();
    b.repeat = p.repeatMode();
    if (p.engine == null and !f.starting) b.note = "Nothing playing · the engine starts when you play something";
    const r = p.report orelse {
        if (f.starting) {
            b.state = .loading;
            b.note = "Starting the engine…";
        } else if (b.note.len == 0) b.note = "Starting the engine…";
        return b;
    };
    if (r.nowPlaying) |n| {
        b.title = n.title orelse "";
        b.artist = n.artist orelse "";
        b.live = n.isLive;
        b.verdict = playstate.verdict(n);
        if (r.liveInfo) |li| if (li.title) |lt| {
            b.title = lt;
            b.artist = li.artist orelse b.artist;
        };
    } else b.note = if (f.starting) "Starting…" else "Nothing playing";
    b.state = switch (r.state) {
        .playing => .playing,
        .paused => .paused,
        .loading, .waiting, .stalled, .seeking => .loading,
        .stopped, .ended, .completed, .none => .stopped,
        .unknown => if (p.isPlaying()) .playing else .stopped,
    };
    if (f.starting and b.state != .playing) b.state = .loading;
    if (r.nowPlaying == null) return b;
    b.position = p.position(f.now_ns);
    b.duration = p.duration();
    return b;
}

/// The two-line player bar: what plays and the modes, then the progress.
pub fn drawBar(s: *Screen, r: Rect, b: BarInfo, t: Theme, now_ms: i64) void {
    const y0 = r.y;
    const y1 = r.y + 1;
    const icon: []const u8 = switch (b.state) {
        .playing => glyph.playing,
        .paused => glyph.paused,
        .stopped => glyph.stopped,
        .loading => spin(now_ms),
        .idle => glyph.stopped,
    };
    _ = s.print(r.x + 1, y0, 1, icon, .{ .fg = t.accent, .bold = true });
    // Right side: modes and volume.
    var right_buf: [64]u8 = undefined;
    const vol_pct: u32 = @intFromFloat(@round(b.volume * 100));
    const vol = if (b.muted) "muted" else std.fmt.bufPrint(&right_buf, "vol {d}%", .{vol_pct}) catch "";
    var x_right = r.right() -| 1;
    const vw: u16 = @intCast(width.textWidth(vol));
    x_right -= vw;
    _ = s.print(x_right, y0, vw, vol, if (b.muted) .{ .fg = t.warn } else t.dim());
    x_right -= 4;
    const rep = switch (b.repeat) {
        .none => glyph.repeat ++ " ",
        .all => glyph.repeat ++ " ",
        .one => glyph.repeat ++ "1",
    };
    _ = s.print(x_right, y0, 2, rep, if (b.repeat == .none) t.dim() else .{ .fg = t.accent, .bold = true });
    x_right -= 2;
    _ = s.print(x_right, y0, 1, glyph.shuffle, if (b.shuffle) .{ .fg = t.accent, .bold = true } else t.dim());
    x_right -= 2;
    if (b.verdict == .preview) {
        x_right -= 8;
        _ = s.print(x_right, y0, 7, "PREVIEW", .{ .fg = t.bad, .bold = true });
        x_right -= 1;
    }
    const text_x = r.x + 3;
    const text_w = x_right -| text_x;
    if (b.title.len > 0) {
        const used = s.print(text_x, y0, text_w, b.title, .{ .bold = true });
        if (b.artist.len > 0 and used + 4 < text_w) {
            _ = s.print(text_x + used, y0, 3, " — ", t.dim());
            _ = s.print(text_x + used + 3, y0, text_w - used - 3, b.artist, .{ .fg = t.accent });
        }
    } else _ = s.print(text_x, y0, text_w, b.note, t.dim());

    // Progress.
    var tb1: [16]u8 = undefined;
    var tb2: [16]u8 = undefined;
    if (b.live) {
        _ = s.print(r.x + 1, y1, 6, glyph.live ++ " LIVE", .{ .fg = t.bad, .bold = true });
        hlineStyle(s, r.x + 8, y1, r.w -| 9, .{ .fg = t.rule });
        return;
    }
    const left = layout.formatTime(&tb1, b.position);
    const right = layout.formatTime(&tb2, b.duration);
    const lw: u16 = @intCast(left.len);
    const rw: u16 = @intCast(right.len);
    _ = s.print(r.x + 1, y1, lw, left, t.dim());
    _ = s.print(r.right() -| (rw + 1), y1, rw, right, t.dim());
    const bar_x = r.x + 2 + lw;
    const bar_w = r.w -| (lw + rw + 4);
    const frac: f64 = if (b.position != null and b.duration != null and b.duration.? > 0) b.position.? / b.duration.? else 0;
    const pr = layout.progress(bar_w, frac);
    var i: u16 = 0;
    while (i < bar_w) : (i += 1) {
        const cx = bar_x + i;
        if (i < pr.full) {
            s.put(cx, y1, "█", 1, .{ .fg = t.accent, .bg = t.track });
        } else if (i == pr.full and pr.eighths > 0) {
            s.put(cx, y1, layout.eighthBlock(pr.eighths), 1, .{ .fg = t.accent, .bg = t.track });
        } else {
            s.put(cx, y1, " ", 1, .{ .bg = t.track });
        }
    }
}

// ---- Status line ----

fn drawStatus(s: *Screen, f: *Frame, t: Theme, r: Rect) void {
    var x = r.x + 1;
    const signed = f.auth.phase == .ready and !f.auth.needs_signin;
    _ = s.print(x, r.y, 1, "●", .{ .fg = if (signed) t.good else t.warn });
    x += 2;
    var buf: [128]u8 = undefined;
    const who = if (signed) std.fmt.bufPrint(&buf, "{s}", .{f.storefront}) catch "" else if (f.auth.needs_signin) "not signed in: S" else "signing in";
    x += s.print(x, r.y, 16, who, if (f.auth.needs_signin) .{ .fg = t.warn } else t.dim()) + 2;
    const engine: []const u8 = if (!f.daemon_up) "no background process" else if (f.player) |p| if (p.engine) |e| std.fmt.bufPrint(buf[64..], "{s} engine", .{e.kind}) catch "engine" else "engine idle" else "connecting";
    x += s.print(x, r.y, 24, engine, t.dim()) + 2;
    if (f.busy) {
        _ = s.print(x, r.y, 1, spin(f.now_ms), .{ .fg = t.accent });
    }
    x += 2;
    const hint = "? help · / search · q quit";
    const hw: u16 = @intCast(width.textWidth(hint));
    if (f.toast) |toast| {
        const style: Style = if (toast.kind == .err) .{ .fg = t.bad, .bold = true } else .{ .fg = t.accent };
        _ = s.print(x, r.y, r.right() -| (x + 1), toast.text, style);
    } else if (r.right() > x + hw + 1) {
        _ = s.print(r.right() - hw - 1, r.y, hw, hint, t.dim());
    }
}

// ---- Overlays ----

/// The keys, from `keys.help`: two columns when they fit side by side, else one. Columns are
/// as wide as their longest entry; when the box is shorter than the list, j / k scroll it.
fn drawHelp(s: *Screen, t: Theme, scroll: *usize) void {
    var key_w: u16 = 0;
    var what_w: u16 = 0;
    for (keys.help) |sec| {
        what_w = @max(what_w, @as(u16, @intCast(width.textWidth(sec.title))));
        for (sec.lines) |line| {
            key_w = @max(key_w, @as(u16, @intCast(width.textWidth(line.keys))));
            what_w = @max(what_w, @as(u16, @intCast(width.textWidth(line.what))));
        }
    }
    key_w += 2;
    const col_w = key_w + what_w;
    const two = s.cols >= col_w * 2 + 10;
    const split: usize = if (two) 2 else keys.help.len;
    var left: usize = 0;
    var right: usize = 0;
    for (keys.help, 0..) |sec, i| {
        const n = sec.lines.len + 1 + @intFromBool(i + 1 != split and i + 1 != keys.help.len);
        if (i < split) left += n else right += n;
    }
    const lines = @max(left, right);
    const w: u16 = @min(s.cols -| 4, if (two) col_w * 2 + 8 else col_w + 4);
    const h: u16 = @intCast(@min(s.rows -| 2, lines + 2));
    const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows - h) / 2, .w = w, .h = h };
    box(s, r, t, "Keys");
    // Rows for lines: between the borders (the hint sits on the bottom one).
    const room: usize = h -| 2;
    scroll.* = @min(scroll.*, lines -| room);
    const inner_right = r.right() -| 2;
    for (0..2) |column| {
        if (column == 1 and !two) break;
        const x: u16 = if (column == 0) r.x + 2 else r.x + 6 + col_w;
        var line_no: usize = 0;
        const from: usize = if (column == 0) 0 else split;
        const to: usize = if (column == 0) split else keys.help.len;
        for (keys.help[from..to], from..) |sec, i| {
            const entries = sec.lines.len + 1;
            for (0..entries) |e| {
                defer line_no += 1;
                if (line_no < scroll.* or line_no - scroll.* >= room) continue;
                const y: u16 = r.y + 1 + @as(u16, @intCast(line_no - scroll.*));
                if (e == 0) {
                    _ = s.print(x, y, inner_right -| x, sec.title, .{ .fg = t.accent, .bold = true });
                    continue;
                }
                const line = sec.lines[e - 1];
                _ = s.print(x, y, @min(key_w -| 1, inner_right -| x), line.keys, .{ .bold = true });
                _ = s.print(x + key_w, y, inner_right -| (x + key_w), line.what, .{});
            }
            if (i + 1 != to) line_no += 1;
        }
    }
    const more = lines > room;
    const hint = if (!more) "any key closes" else if (scroll.* + room < lines) "j k ↓ more · any other key closes" else "j k ↑ more · any other key closes";
    _ = s.print(r.x + 2, r.bottom() -| 1, w -| 4, hint, t.dim());
}

fn drawInfo(s: *Screen, f: *Frame, t: Theme) void {
    const it = f.ui.info orelse return;
    const w: u16 = @min(s.cols -| 4, 72);
    const h: u16 = @min(s.rows -| 2, 18);
    const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows - h) / 2, .w = w, .h = h };
    box(s, r, t, "Details");
    var y = r.y + 1;
    const x = r.x + 2;
    const vw = w -| 18;
    const Field = struct { []const u8, ?[]const u8 };
    var num_buf: [3][32]u8 = undefined;
    const fields = [_]Field{
        .{ "Title", it.title },
        .{ "Artist", it.artist },
        .{ "Album", it.album },
        .{ "Kind", @tagName(it.kind) },
        .{ "Released", it.release_date },
        .{ "Genre", it.genre },
        .{ "Duration", if (it.duration_ms) |ms| layout.formatTime(&num_buf[0], @as(f64, @floatFromInt(ms)) / 1000) else null },
        .{ "Track", if (it.track_number) |n| std.fmt.bufPrint(&num_buf[1], "{d}", .{n}) catch null else null },
        .{ "In library", if (it.library) "yes" else "no" },
        .{ "Favorite", if (it.favorited) |fv| (if (fv) "yes" else "no") else "unknown" },
        .{ "Playable", if (it.playable) "yes" else "no" },
        .{ "Id", it.id },
        .{ "Catalog id", it.catalog_id },
    };
    for (fields) |field| {
        const value = field[1] orelse continue;
        if (y >= r.bottom() -| 2) break;
        _ = s.print(x, y, 14, field[0], t.dim());
        _ = s.print(x + 15, y, vw, value, .{});
        y += 1;
    }
    if (it.description) |d| if (y + 1 < r.bottom() -| 1) {
        _ = wrap(s, x, y + 1, w -| 4, r.bottom() -| 1, d, t.dim());
    };
}

fn drawPicker(s: *Screen, f: *Frame, t: Theme) void {
    const p = f.ui.picker orelse return;
    const w: u16 = @min(s.cols -| 4, 60);
    const h: u16 = @min(s.rows -| 2, 20);
    const r: Rect = .{ .x = (s.cols - w) / 2, .y = (s.rows - h) / 2, .w = w, .h = h };
    box(s, r, t, "Add to playlist");
    if (f.ui.picker_song) |song| {
        var buf: [160]u8 = undefined;
        _ = s.print(r.x + 2, r.y + 1, w -| 4, std.fmt.bufPrint(&buf, "Add “{s}” to:", .{song.title}) catch song.title, .{ .bold = true });
    }
    const inner: Rect = .{ .x = r.x + 1, .y = r.y + 3, .w = w -| 2, .h = h -| 5 };
    drawList(s, f, t, inner, p, true);
    _ = s.print(r.x + 2, r.bottom() -| 1, w -| 4, "Enter add · Esc cancel", t.dim());
}

// ---- Helpers ----

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
    if (title.len > 0) {
        _ = s.print(r.x + 2, r.y, 1, " ", .{});
        const tw = s.print(r.x + 3, r.y, r.w -| 6, title, .{ .fg = t.accent, .bold = true });
        _ = s.print(r.x + 3 + tw, r.y, 1, " ", .{});
    }
}

fn hline(s: *Screen, x: u16, y: u16, w: u16, t: Theme) void {
    hlineStyle(s, x, y, w, .{ .fg = t.rule });
}

fn hlineStyle(s: *Screen, x: u16, y: u16, w: u16, st: Style) void {
    var i: u16 = 0;
    while (i < w) : (i += 1) s.put(x + i, y, "─", 1, st);
}

fn vline(s: *Screen, x: u16, y: u16, h: u16, t: Theme) void {
    var i: u16 = 0;
    while (i < h) : (i += 1) s.put(x, y + i, "│", 1, .{ .fg = t.rule });
}

fn center(s: *Screen, x: u16, y: u16, w: u16, text: []const u8, st: Style) void {
    const tw: u16 = @intCast(@min(width.textWidth(text), w));
    _ = s.print(x + (w - tw) / 2, y, w, text, st);
}

/// The setup text with less prose: 1, its first line and its indented lines (the env lines and
/// commands) and a note that the rest needs a bigger window; 2, without the note and the
/// Keychain alternative; 3, only the first sentence of the first line.
fn condensed(gpa: std.mem.Allocator, text: []const u8, level: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        defer first = false;
        if (first) {
            const end = if (level >= 3) if (std.mem.find(u8, line, ". ")) |dot| dot + 1 else line.len else line.len;
            try out.appendSlice(gpa, line[0..end]);
            try out.append(gpa, '\n');
            continue;
        }
        if (!std.mem.startsWith(u8, line, "    ")) continue;
        if (level >= 2 and std.mem.find(u8, line, "security ") != null) continue;
        try out.appendSlice(gpa, std.mem.trimStart(u8, line, " "));
        try out.append(gpa, '\n');
    }
    if (level == 1) try out.appendSlice(gpa, "(a taller window shows the full instructions)");
    return out.toOwnedSlice(gpa);
}

/// How many rows `wrap` takes for `text` at width `w`.
fn wrapHeight(w: u16, text: []const u8) u16 {
    return wrapInto(null, 0, 0, w, std.math.maxInt(u16), text, .{});
}

/// Word-wraps `text` (keeping its line breaks and the indentation of each line) from row `y`,
/// stopping before `bottom`. Returns the row after the last one written.
pub fn wrap(s: *Screen, x: u16, y_start: u16, w: u16, bottom: u16, text: []const u8, st: Style) u16 {
    return wrapInto(s, x, y_start, w, bottom, text, st);
}

fn wrapInto(screen: ?*Screen, x: u16, y_start: u16, w: u16, bottom: u16, text: []const u8, st: Style) u16 {
    var y = y_start;
    if (w == 0) return y;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        if (y >= bottom) return y;
        const line = std.mem.trimEnd(u8, line_raw, " \r");
        if (line.len == 0) {
            y += 1;
            continue;
        }
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        var rest = line[indent..];
        const ind: u16 = @intCast(@min(indent, w / 2));
        while (rest.len > 0 and y < bottom) {
            const avail = w - ind;
            if (width.textWidth(rest) <= avail) {
                if (screen) |s| _ = s.print(x + ind, y, avail, rest, st);
                y += 1;
                break;
            }
            // The longest prefix up to a space that fits; else a hard break.
            var cut: usize = 0;
            var last_space: ?usize = null;
            var cols: usize = 0;
            var it: width.Iterator = .init(rest);
            while (it.next()) |cl| {
                if (cols + cl.width > avail) break;
                cols += cl.width;
                cut = it.i;
                if (cl.bytes.len == 1 and cl.bytes[0] == ' ') last_space = it.i - 1;
            }
            const end = last_space orelse cut;
            if (screen) |s| _ = s.print(x + ind, y, avail, rest[0..end], st);
            y += 1;
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
    }
    return y;
}

const testing = std.testing;

fn rowText(s: *const Screen, y: u16, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..s.cols) |x| {
        const c = s.cell(@intCast(x), y);
        if (c.width == 0) continue;
        try out.appendSlice(gpa, c.text());
    }
    return out.toOwnedSlice(gpa);
}

test "the player bar: state, title, modes, volume and a progress bar with eighths" {
    var s: Screen = try .init(testing.allocator, 60, 2);
    defer s.deinit();
    const t = theme(.truecolor, null);
    drawBar(&s, .{ .x = 0, .y = 0, .w = 60, .h = 2 }, .{
        .state = .playing,
        .title = "Shy Away",
        .artist = "twenty one pilots",
        .position = 72,
        .duration = 175,
        .shuffle = true,
        .repeat = .one,
        .volume = 0.15,
        .verdict = .full,
    }, t, 0);
    const top = try rowText(&s, 0, testing.allocator);
    defer testing.allocator.free(top);
    try testing.expect(std.mem.startsWith(u8, top, " ▶ Shy Away — twenty one pilots"));
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, top, " "), "⇄ ↻1  vol 15%"));
    const bottom = try rowText(&s, 1, testing.allocator);
    defer testing.allocator.free(bottom);
    try testing.expect(std.mem.startsWith(u8, bottom, " 1:12 █"));
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, bottom, " "), "2:55"));
    // 72/175 of the 48-cell bar is 19.75 cells: 19 full, then a 5/8 block.
    var full: usize = 0;
    var partial: ?[]const u8 = null;
    for (0..60) |x| {
        const c = s.cell(@intCast(x), 1);
        if (std.mem.eql(u8, c.text(), "█")) full += 1 else if (full > 0 and partial == null and !std.mem.eql(u8, c.text(), " ")) partial = c.text();
    }
    try testing.expectEqual(@as(usize, 19), full);
    try testing.expectEqualStrings("▋", partial.?);
    // The bar's cells carry the accent and the track color.
    try testing.expectEqual(Color{ .rgb = default_accent }, s.cell(7, 1).style.fg);
}

test "the player bar: a preview is flagged, live radio has no progress, nothing playing says so" {
    var s: Screen = try .init(testing.allocator, 70, 2);
    defer s.deinit();
    const t = theme(.ansi256, null);
    drawBar(&s, .{ .x = 0, .y = 0, .w = 70, .h = 2 }, .{ .state = .playing, .title = "Song", .verdict = .preview, .position = 3, .duration = 30 }, t, 0);
    const top = try rowText(&s, 0, testing.allocator);
    defer testing.allocator.free(top);
    try testing.expect(std.mem.find(u8, top, "PREVIEW") != null);

    s.clear(.{});
    drawBar(&s, .{ .x = 0, .y = 0, .w = 70, .h = 2 }, .{ .state = .playing, .title = "Apple Music 1", .live = true, .muted = true }, t, 0);
    const live = try rowText(&s, 1, testing.allocator);
    defer testing.allocator.free(live);
    try testing.expect(std.mem.startsWith(u8, live, " ● LIVE ─"));
    const muted = try rowText(&s, 0, testing.allocator);
    defer testing.allocator.free(muted);
    try testing.expect(std.mem.find(u8, muted, "muted") != null);

    s.clear(.{});
    drawBar(&s, .{ .x = 0, .y = 0, .w = 70, .h = 2 }, .{ .note = "Nothing playing" }, t, 0);
    const idle = try rowText(&s, 0, testing.allocator);
    defer testing.allocator.free(idle);
    try testing.expect(std.mem.startsWith(u8, idle, " ■ Nothing playing"));
    const times = try rowText(&s, 1, testing.allocator);
    defer testing.allocator.free(times);
    try testing.expect(std.mem.startsWith(u8, times, " -:-- "));
}

test "the glyphs are one cell wide and not emoji-presentation characters" {
    inline for (.{ glyph.playing, glyph.paused, glyph.stopped, glyph.shuffle, glyph.repeat, glyph.heart, glyph.live, "█", "▏", "▉", "♪", "⠋", "✓", "▲", "┃", "›" }) |g| {
        try testing.expectEqual(@as(usize, 1), width.textWidth(g));
        var it: width.Iterator = .init(g);
        const cl = it.next().?;
        const cp = std.unicode.utf8Decode(cl.bytes) catch unreachable;
        try testing.expectEqual(@as(u2, 1), width.codepointWidth(cp));
    }
}

test "the help overlay stays inside its box and scrolls when the screen is short" {
    for ([_][2]u16{ .{ 50, 14 }, .{ 80, 24 }, .{ 101, 30 }, .{ 140, 40 } }) |size| {
        var s: Screen = try .init(testing.allocator, size[0], size[1]);
        defer s.deinit();
        var scroll: usize = 0;
        const t = theme(.ansi256, null);
        drawHelp(&s, t, &scroll);
        // Each row of the box: only the border at its edges, nothing drawn past them.
        var top: u16 = 0;
        while (!std.mem.eql(u8, s.cell(@intCast((size[0] - 1) / 2), top).text(), "─")) top += 1;
        var left: u16 = 0;
        while (!std.mem.eql(u8, s.cell(left, top).text(), "╭")) left += 1;
        var right = left + 1;
        while (!std.mem.eql(u8, s.cell(right, top).text(), "╮")) right += 1;
        var y = top + 1;
        while (!std.mem.eql(u8, s.cell(left, y).text(), "╰")) : (y += 1) {
            try testing.expectEqualStrings("│", s.cell(left, y).text());
            try testing.expectEqualStrings("│", s.cell(right, y).text());
            if (right + 1 < size[0]) try testing.expectEqualStrings(" ", s.cell(right + 1, y).text());
        }
        // Every description fits: no ellipsis anywhere.
        for (0..size[1]) |row| {
            const text = try rowText(&s, @intCast(row), testing.allocator);
            defer testing.allocator.free(text);
            try testing.expect(std.mem.find(u8, text, "…") == null or size[0] < 60);
        }
        // Short screens scroll down to the last entry.
        if (size[1] < 40) {
            scroll = 1000;
            s.clear(.{});
            drawHelp(&s, t, &scroll);
            try testing.expect(scroll > 0);
            var found = false;
            for (0..size[1]) |row| {
                const text = try rowText(&s, @intCast(row), testing.allocator);
                defer testing.allocator.free(text);
                if (std.mem.find(u8, text, "this help") != null) found = true;
            }
            try testing.expect(found);
        }
    }
}

test "wrap keeps line breaks and indentation, and breaks at spaces" {
    var s: Screen = try .init(testing.allocator, 20, 8);
    defer s.deinit();
    const end = wrap(&s, 0, 0, 20, 8, "one two three four five six\n\n    am token --key-stdin", .{});
    try testing.expectEqual(@as(u16, 5), end);
    const a = try rowText(&s, 0, testing.allocator);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("one two three four", std.mem.trimEnd(u8, a, " "));
    const d = try rowText(&s, 3, testing.allocator);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("    am token", std.mem.trimEnd(u8, d, " "));
}

test "a short setup screen keeps the env lines and the token command" {
    var m: auth.Machine = .{};
    _ = m.checked(.{ .setup = "TEAM_ID and KEY_ID are missing. Put these two lines in /private/tmp/a-rather-long-config-directory/for-this-test/env\n(or set them in the environment):\n\n    TEAM_ID=<your Apple Developer Team ID>\n    KEY_ID=<the ID of your MusicKit key>\n\nBoth are on developer.apple.com (Membership, and Certificates, IDs & Profiles → Keys).\nThen sign the developer token as below and press r.\n\nSign a developer token from your MusicKit key (the .p8 file from developer.apple.com),\nin another terminal:\n\n    am token --key-stdin < AuthKey_<KEY_ID>.p8\n\nWith the key in the macOS Keychain:\n\n    security find-generic-password -a am -s am-musickit-p8 -w | base64 -D | am token --key-stdin\n\nam keeps only the signed token, never the key. Then press r here." }, 0);
    var s: Screen = try .init(testing.allocator, 50, 14);
    defer s.deinit();
    var slots: std.ArrayList(ImageSlot) = .empty;
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    var f: Frame = .{ .ui = &u, .auth = &m, .player = null, .now_ns = 0, .now_ms = 0, .color = .ansi256, .images = false, .slots = &slots, .gpa = testing.allocator };
    draw(&s, &f);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    for (0..14) |y| {
        const row = try rowText(&s, @intCast(y), testing.allocator);
        defer testing.allocator.free(row);
        try all.appendSlice(testing.allocator, row);
    }
    for ([_][]const u8{ "TEAM_ID=", "KEY_ID=", "am token --key-stdin", "r check again" }) |want|
        try testing.expect(std.mem.find(u8, all.items, want) != null);
}

test "accent colors come from the artwork when they are colorful" {
    try testing.expectEqual(@as(?u24, 0xE0302A), accentFrom(.{ .url = "", .bg = 0x101010, .text1 = 0xE0302A }));
    try testing.expectEqual(@as(?u24, null), accentFrom(.{ .url = "", .bg = 0x000000, .text1 = 0xFFFFFF }));
    try testing.expectEqual(@as(?u24, null), accentFrom(null));
}

test "numbers get thin spaces between thousands" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("4\u{202F}595", thousands(&buf, 4595));
    try testing.expectEqualStrings("188", thousands(&buf, 188));
    try testing.expectEqualStrings("1\u{202F}000\u{202F}000", thousands(&buf, 1_000_000));
}
