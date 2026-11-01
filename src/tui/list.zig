//! A list in the main pane: rows of items (with group headings and "see all" rows), the
//! selection and scroll position, a filter, and the paging state for loading more as the
//! selection nears the end. Only the visible rows are ever drawn; the rows themselves are
//! plain values whose strings live in arenas the list owns.
const std = @import("std");
const model = @import("../music/model.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;
const Item = model.Item;

pub const Row = struct {
    tag: Tag,
    /// Header and note text.
    text: []const u8 = "",
    /// Valid when `tag` is `.item`.
    item: Item = undefined,
    /// The group the row belongs to (headers, items and "see all" rows of grouped views).
    group: u16 = 0,
    /// The queue index, in the queue view.
    aux: u32 = 0,
    /// Added by autoplay (queue view); for other rows unused.
    flag: bool = false,
    /// Its favorite state was asked for already.
    fav_asked: bool = false,

    pub const Tag = enum { header, item, more, note };

    pub fn selectable(r: Row) bool {
        return r.tag == .item or r.tag == .more;
    }
};

/// A titled section of a grouped view, for its "see all" row.
pub const Group = struct {
    title: []const u8,
    key: []const u8,
    next_offset: ?u32,
    /// All of the group's items, also those past its "see all" row.
    items: []const Item,
};

pub const List = struct {
    gpa: Allocator,
    rows: std.ArrayList(Row) = .empty,
    groups: std.ArrayList(Group) = .empty,
    /// Indices into `rows` that pass the filter, in order.
    visible: std.ArrayList(u32) = .empty,
    filter: std.ArrayList(u8) = .empty,
    /// An index into `visible`.
    selected: usize = 0,
    /// The first visible row on screen.
    offset: usize = 0,
    /// Memory the rows point into.
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,

    // Paging.
    next_offset: ?u32 = null,
    total: ?u32 = null,
    loading: bool = false,
    loaded: bool = false,
    /// Why the last load failed; owned.
    failed: ?[]u8 = null,
    /// Keep only items Apple says are favorites (a library walk for the Favorites section).
    only_favorites: bool = false,
    /// Select this item id once it arrives (go to now playing).
    want_id: ?[]u8 = null,
    /// Bumped by `clear`: a load started before carries the old value, and its page is dropped.
    epoch: u32 = 0,

    pub fn init(gpa: Allocator) List {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *List) void {
        l.clear();
        l.rows.deinit(l.gpa);
        l.groups.deinit(l.gpa);
        l.visible.deinit(l.gpa);
        l.filter.deinit(l.gpa);
        l.arenas.deinit(l.gpa);
        if (l.want_id) |w| l.gpa.free(w);
    }

    /// Forgets every row and the paging state, keeping the filter. Loads already on their way
    /// no longer match `epoch`.
    pub fn clear(l: *List) void {
        l.epoch +%= 1;
        for (l.arenas.items) |a| {
            a.deinit();
            l.gpa.destroy(a);
        }
        l.arenas.clearRetainingCapacity();
        l.rows.clearRetainingCapacity();
        l.groups.clearRetainingCapacity();
        l.visible.clearRetainingCapacity();
        l.selected = 0;
        l.offset = 0;
        l.next_offset = null;
        l.total = null;
        l.loading = false;
        l.loaded = false;
        l.setFailed(null);
    }

    pub fn setFailed(l: *List, message: ?[]const u8) void {
        if (l.failed) |f| l.gpa.free(f);
        l.failed = if (message) |m| l.gpa.dupe(u8, m) catch null else null;
    }

    pub fn setWant(l: *List, id: ?[]const u8) void {
        if (l.want_id) |w| l.gpa.free(w);
        l.want_id = if (id) |i| l.gpa.dupe(u8, i) catch null else null;
    }

    /// Takes ownership of `arena`, which the rows added next point into.
    pub fn adopt(l: *List, arena: *std.heap.ArenaAllocator) Allocator.Error!void {
        try l.arenas.append(l.gpa, arena);
    }

    /// Appends a page of items. `next_offset` and `total` become the page's.
    pub fn appendPage(l: *List, items: []const Item, next_offset: ?u32, total: ?u32) Allocator.Error!void {
        for (items) |it| {
            if (l.only_favorites and it.favorited != true) continue;
            try l.appendRow(.{ .tag = .item, .item = it });
        }
        l.next_offset = next_offset;
        if (total) |t| l.total = t;
        l.loading = false;
        l.loaded = true;
        l.setFailed(null);
        l.selectWanted();
    }

    pub const GroupIn = struct {
        title: []const u8,
        items: []const Item,
        key: []const u8 = "",
        next_offset: ?u32 = null,
        /// Rows shown before "see all".
        limit: usize = 12,
        /// The "see all" row even without more pages (the rest of `items`).
        more: bool = false,
    };

    /// Appends a group: its heading, up to `limit` items and a "see all" row when there is more.
    pub fn appendGroup(l: *List, g: GroupIn) Allocator.Error!void {
        if (g.items.len == 0) return;
        const index: u16 = @intCast(l.groups.items.len);
        try l.groups.append(l.gpa, .{ .title = g.title, .key = g.key, .next_offset = g.next_offset, .items = g.items });
        try l.appendRow(.{ .tag = .header, .text = g.title, .group = index });
        for (g.items[0..@min(g.items.len, g.limit)]) |it| try l.appendRow(.{ .tag = .item, .item = it, .group = index });
        if (g.more or g.items.len > g.limit or g.next_offset != null)
            try l.appendRow(.{ .tag = .more, .text = "See all", .group = index });
        l.loading = false;
        l.loaded = true;
    }

    pub fn appendNote(l: *List, text: []const u8) Allocator.Error!void {
        try l.appendRow(.{ .tag = .note, .text = text });
    }

    fn appendRow(l: *List, row: Row) Allocator.Error!void {
        try l.rows.append(l.gpa, row);
        const i: u32 = @intCast(l.rows.items.len - 1);
        if (l.passes(l.rows.items[i])) try l.visible.append(l.gpa, i);
        // The first selectable row is where the selection starts.
        if (l.visible.items.len > 0 and !l.rowAt(l.selected).selectable()) l.selected = l.nextSelectable(l.selected, 1) orelse l.selected;
    }

    fn passes(l: *const List, row: Row) bool {
        if (l.filter.items.len == 0) return true;
        if (row.tag != .item) return false;
        const it = row.item;
        return contains(it.title, l.filter.items) or
            (if (it.artist) |a| contains(a, l.filter.items) else false) or
            (if (it.album) |a| contains(a, l.filter.items) else false);
    }

    fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.ascii.findIgnoreCase(haystack, needle) != null;
    }

    /// Changes the filter and rebuilds the visible rows, keeping the selected row if it stays.
    pub fn setFilter(l: *List, text: []const u8) Allocator.Error!void {
        const keep: ?u32 = if (l.selected < l.visible.items.len) l.visible.items[l.selected] else null;
        l.filter.clearRetainingCapacity();
        try l.filter.appendSlice(l.gpa, text);
        l.visible.clearRetainingCapacity();
        for (l.rows.items, 0..) |row, i| if (l.passes(row)) try l.visible.append(l.gpa, @intCast(i));
        l.selected = 0;
        l.offset = 0;
        if (keep) |k| for (l.visible.items, 0..) |v, i| if (v == k) {
            l.selected = i;
        };
        if (l.visible.items.len > 0 and !l.rowAt(l.selected).selectable()) l.selected = l.nextSelectable(0, 1) orelse 0;
    }

    pub fn len(l: *const List) usize {
        return l.visible.items.len;
    }

    /// The `i`th visible row.
    pub fn rowAt(l: *const List, i: usize) *Row {
        return &l.rows.items[l.visible.items[i]];
    }

    pub fn selectedRow(l: *const List) ?*Row {
        if (l.selected >= l.visible.items.len) return null;
        const r = l.rowAt(l.selected);
        return if (r.selectable()) r else null;
    }

    pub fn selectedItem(l: *const List) ?*Item {
        const r = l.selectedRow() orelse return null;
        return if (r.tag == .item) &r.item else null;
    }

    fn nextSelectable(l: *const List, from: usize, dir: i2) ?usize {
        var i: isize = @intCast(from);
        const n: isize = @intCast(l.visible.items.len);
        while (i >= 0 and i < n) : (i += dir) {
            if (l.rowAt(@intCast(i)).selectable()) return @intCast(i);
        }
        return null;
    }

    /// Moves the selection by `delta` selectable rows' worth, landing on a selectable row and
    /// stopping at the ends.
    pub fn move(l: *List, delta: isize) void {
        const n = l.visible.items.len;
        if (n == 0) return;
        const target: isize = std.math.clamp(@as(isize, @intCast(l.selected)) + delta, 0, @as(isize, @intCast(n - 1)));
        const t: usize = @intCast(target);
        const dir: i2 = if (delta < 0) -1 else 1;
        l.selected = l.nextSelectable(t, dir) orelse l.nextSelectable(t, -dir) orelse l.selected;
    }

    pub fn top(l: *List) void {
        l.selected = l.nextSelectable(0, 1) orelse 0;
    }

    pub fn bottom(l: *List) void {
        if (l.visible.items.len == 0) return;
        l.selected = l.nextSelectable(l.visible.items.len - 1, -1) orelse 0;
    }

    /// Selects the item with this id, if a row has it.
    pub fn selectId(l: *List, id: []const u8) bool {
        for (l.visible.items, 0..) |v, i| {
            const r = l.rows.items[v];
            if (r.tag == .item and (std.mem.eql(u8, r.item.id, id) or (if (r.item.catalog_id) |c| std.mem.eql(u8, c, id) else false))) {
                l.selected = i;
                return true;
            }
        }
        return false;
    }

    fn selectWanted(l: *List) void {
        const want = l.want_id orelse return;
        if (l.selectId(want)) l.setWant(null);
    }

    /// Updates the scroll position for a pane `height` rows tall.
    pub fn scrollTo(l: *List, height: usize) void {
        l.offset = layout.scroll(l.selected, l.offset, height, l.visible.items.len, 2);
    }

    /// Whether to load the next page now: more exists, nothing is loading, and the selection
    /// is within two screens of the end (or the screen isn't full).
    pub fn wantsMore(l: *const List, height: usize) bool {
        if (l.loading or l.failed != null or l.next_offset == null) return false;
        const n = l.visible.items.len;
        return n < height or n - @min(n, l.selected) <= 2 * height;
    }

    /// Items between `from` and `from + count` (visible rows) whose favorite state isn't known
    /// or asked for yet, as row indices.
    pub fn unknownFavorites(l: *const List, out: []u32, from: usize, count: usize) []u32 {
        var n: usize = 0;
        const end = @min(l.visible.items.len, from + count);
        var i = from;
        while (i < end and n < out.len) : (i += 1) {
            const v = l.visible.items[i];
            const r = l.rows.items[v];
            if (r.tag != .item or r.fav_asked or r.item.favorited != null) continue;
            switch (r.item.kind) {
                .song, .album, .artist, .playlist, .music_video => {},
                .station, .curator => continue,
            }
            if (!r.item.library and r.item.catalog_id == null) continue;
            out[n] = v;
            n += 1;
        }
        return out[0..n];
    }

    /// Rows whose favorite request failed: asked for again, if they still hold the same items.
    pub fn unaskFavorites(l: *List, rows: []const u32, items: []const Item) void {
        for (rows, items) |row, it| {
            if (row >= l.rows.items.len) continue;
            const r = &l.rows.items[row];
            if (r.tag == .item and std.mem.eql(u8, r.item.id, it.id)) r.fav_asked = false;
        }
    }

    /// Song ids of the visible rows around the selection (at most `max`), the selected one
    /// included, for a queue of "this list from here".
    pub fn songIds(l: *const List, arena: Allocator, max: usize) Allocator.Error![]const []const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        // Up to a sixth before the selection, so `previous` has somewhere to go.
        var songs_before: usize = 0;
        var i = l.selected;
        while (i > 0 and songs_before < max / 6) {
            i -= 1;
            const r = l.rowAt(i);
            if (r.tag == .item and r.item.kind == .song and r.item.playable) songs_before += 1;
        }
        var group: ?u16 = null;
        if (l.selectedRow()) |sel| if (l.groups.items.len > 0) {
            group = sel.group;
        };
        while (i < l.visible.items.len and ids.items.len < max) : (i += 1) {
            const r = l.rowAt(i);
            if (r.tag != .item or r.item.kind != .song or !r.item.playable) continue;
            // In a grouped view, only the selection's own group.
            if (group) |g| if (r.group != g) continue;
            try ids.append(arena, r.item.id);
        }
        return ids.items;
    }
};

const testing = std.testing;

fn song(id: []const u8, title: []const u8) Item {
    return .{ .kind = .song, .id = id, .catalog_id = id, .title = title, .artist = "Band" };
}

test "paging: append pages, ask for more near the end, stop on the last" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    try testing.expect(!l.wantsMore(10)); // nothing known yet: the first load is the view's job
    l.loading = true;
    var items: [30]Item = undefined;
    var names: [30][4]u8 = undefined;
    for (&items, &names, 0..) |*it, *n, i| {
        _ = std.fmt.bufPrint(n, "s{d:0>3}", .{i}) catch unreachable;
        it.* = song(n, n);
    }
    try l.appendPage(items[0..20], 20, 30);
    try testing.expectEqual(@as(usize, 20), l.len());
    try testing.expectEqual(@as(?u32, 30), l.total);
    // Selection at the top of 20 rows, 10 per screen: within two screens of the end.
    try testing.expect(l.wantsMore(10));
    try testing.expect(!l.wantsMore(5)); // 20 rows left > 2×5
    l.loading = true;
    try testing.expect(!l.wantsMore(10)); // already loading
    try l.appendPage(items[20..30], null, 30);
    try testing.expect(!l.wantsMore(10)); // last page
    l.bottom();
    try testing.expectEqualStrings("s029", l.selectedItem().?.id);
}

test "a failed load stops paging until retried" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    try l.appendPage(&.{song("1", "a")}, 1, null);
    l.setFailed("can't reach Apple Music");
    try testing.expect(!l.wantsMore(10));
    l.setFailed(null);
    try testing.expect(l.wantsMore(10));
}

test "groups: headings are skipped by the selection, see-all rows are selectable" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    const a = [_]Item{ song("1", "one"), song("2", "two"), song("3", "three") };
    try l.appendGroup(.{ .title = "Top", .items = &a, .limit = 2 });
    try l.appendGroup(.{ .title = "Songs", .items = a[0..1], .key = "songs", .next_offset = 25 });
    // Rows: H(Top) 1 2 More H(Songs) 1 More
    try testing.expectEqual(@as(usize, 7), l.len());
    try testing.expectEqual(@as(usize, 1), l.selected);
    l.move(-1);
    try testing.expectEqual(@as(usize, 1), l.selected); // the heading above can't be selected
    l.move(2);
    try testing.expectEqual(Row.Tag.more, l.selectedRow().?.tag);
    l.move(1); // over the heading
    try testing.expectEqual(@as(usize, 5), l.selected);
    try testing.expectEqual(@as(u16, 1), l.selectedRow().?.group);
    l.bottom();
    try testing.expectEqual(Row.Tag.more, l.selectedRow().?.tag);
    try testing.expectEqualStrings("songs", l.groups.items[l.selectedRow().?.group].key);
}

test "filter keeps matching items and the selection when it still matches" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    try l.appendPage(&.{ song("1", "Shy Away"), song("2", "Heathens"), song("3", "Away from home") }, null, null);
    l.move(1);
    try testing.expectEqualStrings("2", l.selectedItem().?.id);
    try l.setFilter("away");
    try testing.expectEqual(@as(usize, 2), l.len());
    try testing.expectEqualStrings("1", l.selectedItem().?.id);
    l.move(1);
    try testing.expectEqualStrings("3", l.selectedItem().?.id);
    try l.setFilter("");
    try testing.expectEqual(@as(usize, 3), l.len());
    try testing.expectEqualStrings("3", l.selectedItem().?.id);
    try l.setFilter("zzz");
    try testing.expect(l.selectedItem() == null);
}

test "virtual scrolling follows the selection" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    var items: [100]Item = undefined;
    for (&items) |*it| it.* = song("x", "x");
    try l.appendPage(&items, null, null);
    l.move(50);
    l.scrollTo(10);
    try testing.expect(l.offset <= 50 and 50 < l.offset + 10);
    l.bottom();
    l.scrollTo(10);
    try testing.expectEqual(@as(usize, 90), l.offset);
}

test "only favorites keeps favorited items; unknown favorites are listed once" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    l.only_favorites = true;
    var a = song("1", "a");
    a.favorited = true;
    var b = song("2", "b");
    b.favorited = false;
    try l.appendPage(&.{ a, b, song("3", "c") }, 3, null);
    try testing.expectEqual(@as(usize, 1), l.len());

    var m: List = .init(testing.allocator);
    defer m.deinit();
    var station: Item = .{ .kind = .station, .id = "ra.1", .title = "radio" };
    station.catalog_id = "ra.1";
    try m.appendPage(&.{ a, song("3", "c"), station, song("4", "d") }, null, null);
    var buf: [8]u32 = undefined;
    const unknown = m.unknownFavorites(&buf, 0, 10);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, unknown);
}

test "song ids for a queue: from a little before the selection, songs only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var l: List = .init(testing.allocator);
    defer l.deinit();
    var items: [20]Item = undefined;
    var names: [20][3]u8 = undefined;
    for (&items, &names, 0..) |*it, *n, i| {
        _ = std.fmt.bufPrint(n, "{d:0>3}", .{i}) catch unreachable;
        it.* = song(n, n);
    }
    items[5].kind = .album;
    try l.appendPage(&items, null, null);
    l.move(10);
    const ids = try l.songIds(arena.allocator(), 12);
    // max/6 = 2 songs before the selection (8, 9), then 10…
    try testing.expectEqualStrings("008", ids[0]);
    try testing.expectEqualStrings("010", ids[2]);
    try testing.expectEqual(@as(usize, 12), ids.len);
}

test "want id selects the row when its page arrives" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    l.setWant("7");
    try l.appendPage(&.{ song("5", "a"), song("6", "b") }, 2, null);
    try testing.expectEqual(@as(usize, 0), l.selected);
    try l.appendPage(&.{ song("7", "c"), song("8", "d") }, null, null);
    try testing.expectEqualStrings("7", l.selectedItem().?.id);
    try testing.expect(l.want_id == null);
}

test "a failed favorite request makes its rows askable again, unless they changed" {
    var l: List = .init(testing.allocator);
    defer l.deinit();
    try l.appendPage(&.{ song("1", "a"), song("2", "b") }, null, null);
    var buf: [8]u32 = undefined;
    const asked = l.unknownFavorites(&buf, 0, 10);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, asked);
    for (asked) |r| l.rows.items[r].fav_asked = true;
    try testing.expectEqual(@as(usize, 0), l.unknownFavorites(&buf, 0, 10).len);
    l.unaskFavorites(&.{ 0, 1, 9 }, &.{ song("1", "a"), song("other", "x"), song("3", "c") });
    var again: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{0}, l.unknownFavorites(&again, 0, 10));
}
