//! Reads Apple Music API responses into `model` types. Apple mixes resource types in one list
//! (recommendations, recently played, search top results), so bodies are read as JSON trees
//! and each resource is mapped by its `type`. Unknown types and odd fields are skipped, never
//! an error: only a body that is not JSON is.
const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Item = model.Item;
const Kind = model.Kind;
const Page = model.Page;
const Group = model.Group;

pub const Error = error{BadResponse} || Allocator.Error;

/// The body as a JSON tree. Strings may point into `body`, so it must live as long as the result.
pub fn tree(arena: Allocator, body: []const u8) Error!Value {
    // Some endpoints answer 200 with an empty body.
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return .{ .object = .empty };
    return std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

/// The kind a resource `type` names, or null for types the TUI doesn't show.
pub fn kindOf(resource_type: []const u8) ?Kind {
    const map = [_]struct { []const u8, Kind }{
        .{ "songs", .song },                       .{ "library-songs", .song },
        .{ "albums", .album },                     .{ "library-albums", .album },
        .{ "artists", .artist },                   .{ "library-artists", .artist },
        .{ "playlists", .playlist },               .{ "library-playlists", .playlist },
        .{ "stations", .station },                 .{ "music-videos", .music_video },
        .{ "library-music-videos", .music_video }, .{ "curators", .curator },
        .{ "apple-curators", .curator },
    };
    for (map) |entry| if (std.mem.eql(u8, entry[0], resource_type)) return entry[1];
    return null;
}

/// One resource (`{id, type, attributes, relationships?}`), or null when it is of a type the
/// TUI doesn't show or carries no attributes.
pub fn item(arena: Allocator, resource: Value) Allocator.Error!?Item {
    const resource_type = string(field(resource, "type")) orelse return null;
    const kind = kindOf(resource_type) orelse return null;
    const id = string(field(resource, "id")) orelse return null;
    const attributes = field(resource, "attributes") orelse return null;
    if (attributes != .object) return null;
    const library = std.mem.startsWith(u8, resource_type, "library-");
    const play = field(attributes, "playParams");
    // A library resource fetched with include=catalog carries its catalog twin.
    const catalog_twin = first(field(field(field(resource, "relationships"), "catalog"), "data"));

    var it: Item = .{
        .kind = kind,
        .id = id,
        .library = library,
        .title = string(field(attributes, "name")) orelse "",
        .artist = string(field(attributes, "artistName")) orelse string(field(attributes, "curatorName")) orelse
            string(field(attributes, "stationProviderName")),
        .album = string(field(attributes, "albumName")),
        .duration_ms = integer(u32, field(attributes, "durationInMillis")),
        .track_number = integer(u16, field(attributes, "trackNumber")),
        .disc_number = integer(u16, field(attributes, "discNumber")),
        .track_count = integer(u32, field(attributes, "trackCount")),
        .release_date = string(field(attributes, "releaseDate")),
        .genre = string(first(field(attributes, "genreNames"))),
        .description = try description(arena, attributes),
        .artwork = artwork(field(attributes, "artwork")),
        .explicit = std.mem.eql(u8, string(field(attributes, "contentRating")) orelse "", "explicit"),
        .favorited = boolean(field(attributes, "inFavorites")),
        .is_live = boolean(field(attributes, "isLive")) orelse false,
        .playable = play != null,
        .tags_favorited = hasString(field(attributes, "tags"), "favorited"),
        .can_edit = boolean(field(attributes, "canEdit")) orelse false,
    };
    if (!library) {
        it.catalog_id = id;
    } else {
        it.catalog_id = string(field(play, "catalogId")) orelse string(field(play, "globalId")) orelse
            string(field(catalog_twin, "id"));
        if (catalog_twin) |twin| {
            // The catalog twin has the colors library artwork lacks, and artists have only a name.
            if (artwork(field(field(twin, "attributes"), "artwork"))) |art| it.artwork = art;
        }
    }
    return it;
}

/// The items of a `data` array, skipping what `item` skips.
pub fn items(arena: Allocator, data: ?Value) Allocator.Error![]Item {
    const list = array(data);
    var out: std.ArrayList(Item) = try .initCapacity(arena, list.len);
    for (list) |resource| if (try item(arena, resource)) |it| out.appendAssumeCapacity(it);
    return out.items;
}

/// A collection: `{data, next?, meta?: {total}}`.
pub fn page(arena: Allocator, body: []const u8) Error!Page {
    const root = try tree(arena, body);
    return pageOf(arena, root);
}

fn pageOf(arena: Allocator, collection: Value) Allocator.Error!Page {
    return .{
        .items = try items(arena, field(collection, "data")),
        .next_offset = nextOffset(string(field(collection, "next"))),
        .total = integer(u32, field(field(collection, "meta"), "total")),
    };
}

/// The `offset` in a `next` path: Apple's `next` drops limit, include and extend, so callers
/// rebuild the request from the offset instead of following it.
pub fn nextOffset(next: ?[]const u8) ?u32 {
    const path = next orelse return null;
    const query = path[(std.mem.findScalar(u8, path, '?') orelse return null) + 1 ..];
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.startsWith(u8, param, "offset="))
            return std.fmt.parseInt(u32, param["offset=".len..], 10) catch null;
    }
    return null;
}

/// Catalog or library search: `results.{type}.{data, next}`, in `meta.results.order`.
/// Types with nothing the TUI shows are left out.
pub fn searchGroups(arena: Allocator, body: []const u8) Error![]Group {
    const root = try tree(arena, body);
    const results = field(root, "results");
    var groups: std.ArrayList(Group) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (array(field(field(field(root, "meta"), "results"), "order"))) |key_value| {
        const key = string(key_value) orelse continue;
        try seen.append(arena, key);
        try appendSearchGroup(arena, &groups, results, key);
    }
    // Sections the order left out still count.
    if (results) |r| if (r == .object) for (r.object.keys()) |key| {
        if (!containsString(seen.items, key)) try appendSearchGroup(arena, &groups, results, key);
    };
    return groups.items;
}

fn appendSearchGroup(arena: Allocator, groups: *std.ArrayList(Group), results: ?Value, key: []const u8) Allocator.Error!void {
    const section = field(results, key) orelse return;
    const found = try items(arena, field(section, "data"));
    if (found.len == 0) return;
    try groups.append(arena, .{
        .title = searchTitle(key),
        .items = found,
        .next_offset = nextOffset(string(field(section, "next"))),
        .key = key,
    });
}

/// One search type's results (`results.{key}`) as a page, for paging a search section.
pub fn searchPage(arena: Allocator, body: []const u8, key: []const u8) Error!Page {
    const root = try tree(arena, body);
    const section = field(field(root, "results"), key) orelse return .{ .items = &.{} };
    return pageOf(arena, section);
}

/// The section title for a search type.
pub fn searchTitle(key: []const u8) []const u8 {
    const prefix = "library-";
    const bare = if (std.mem.startsWith(u8, key, prefix)) key[prefix.len..] else key;
    const titles = [_]struct { []const u8, []const u8 }{
        .{ "topResults", "Top Results" },    .{ "songs", "Songs" },         .{ "albums", "Albums" },
        .{ "artists", "Artists" },           .{ "playlists", "Playlists" }, .{ "stations", "Stations" },
        .{ "music-videos", "Music Videos" }, .{ "curators", "Curators" },   .{ "apple-curators", "Apple Curators" },
    };
    for (titles) |t| if (std.mem.eql(u8, t[0], bare)) return t[1];
    return key;
}

/// `/search/suggestions` with kinds=terms: the terms to search for.
pub fn suggestions(arena: Allocator, body: []const u8) Error![][]const u8 {
    const root = try tree(arena, body);
    const list = array(field(field(root, "results"), "suggestions"));
    var terms: std.ArrayList([]const u8) = try .initCapacity(arena, list.len);
    for (list) |s| {
        if (!std.mem.eql(u8, string(field(s, "kind")) orelse "", "terms")) continue;
        const term = string(field(s, "searchTerm")) orelse string(field(s, "displayTerm")) orelse continue;
        terms.appendAssumeCapacity(term);
    }
    return terms.items;
}

/// `/v1/me/recommendations`: one group per recommendation, empty ones left out.
pub fn recommendationGroups(arena: Allocator, body: []const u8) Error![]Group {
    const root = try tree(arena, body);
    var groups: std.ArrayList(Group) = .empty;
    for (array(field(root, "data"))) |rec| {
        const attributes = field(rec, "attributes");
        const contents = field(field(rec, "relationships"), "contents");
        const found = try items(arena, field(contents, "data"));
        if (found.len == 0) continue;
        try groups.append(arena, .{
            .title = string(field(field(attributes, "title"), "stringForDisplay")) orelse "",
            .items = found,
            .next_offset = nextOffset(string(field(contents, "next"))),
            .key = string(field(rec, "id")) orelse "",
        });
    }
    return groups.items;
}

/// `/charts`: `results.{type}` is a list of charts; groups follow `meta.results.order`
/// (orderIds), then any chart it left out.
pub fn chartGroups(arena: Allocator, body: []const u8) Error![]Group {
    const root = try tree(arena, body);
    const results = field(root, "results");
    var charts: std.ArrayList(Value) = .empty;
    if (results) |r| if (r == .object) for (r.object.values()) |list| {
        for (array(list)) |chart| try charts.append(arena, chart);
    };
    const used = try arena.alloc(bool, charts.items.len);
    @memset(used, false);
    var groups: std.ArrayList(Group) = .empty;
    for (array(field(field(field(root, "meta"), "results"), "order"))) |order_value| {
        const order = string(order_value) orelse continue;
        for (charts.items, used) |chart, *u| {
            if (u.* or !std.mem.eql(u8, string(field(chart, "orderId")) orelse "", order)) continue;
            u.* = true;
            try appendChart(arena, &groups, chart);
        }
    }
    for (charts.items, used) |chart, u| if (!u) try appendChart(arena, &groups, chart);
    return groups.items;
}

fn appendChart(arena: Allocator, groups: *std.ArrayList(Group), chart: Value) Allocator.Error!void {
    const found = try items(arena, field(chart, "data"));
    if (found.len == 0) return;
    try groups.append(arena, .{
        .title = string(field(chart, "name")) orelse "",
        .items = found,
        .next_offset = nextOffset(string(field(chart, "next"))),
        .key = string(field(chart, "orderId")) orelse "",
    });
}

/// A catalog artist with `views=…`: one group per non-empty view, in `meta.views.order`.
pub fn artistViews(arena: Allocator, body: []const u8) Error![]Group {
    const root = try tree(arena, body);
    const artist = first(field(root, "data"));
    const views = field(artist, "views");
    var groups: std.ArrayList(Group) = .empty;
    var order: std.ArrayList([]const u8) = .empty;
    for (array(field(field(field(artist, "meta"), "views"), "order"))) |v| if (string(v)) |name| try order.append(arena, name);
    if (views) |v| if (v == .object) for (v.object.keys()) |name| {
        if (!containsString(order.items, name)) try order.append(arena, name);
    };
    for (order.items) |name| {
        const view = field(views, name) orelse continue;
        const found = try items(arena, field(view, "data"));
        if (found.len == 0) continue;
        try groups.append(arena, .{
            .title = string(field(field(view, "attributes"), "title")) orelse name,
            .items = found,
            .next_offset = nextOffset(string(field(view, "next"))),
            .key = name,
        });
    }
    return groups.items;
}

/// `/v1/me/storefront`: the storefront id.
pub fn storefront(arena: Allocator, body: []const u8) Error![]const u8 {
    const root = try tree(arena, body);
    return string(field(first(field(root, "data")), "id")) orelse error.BadResponse;
}

/// The first resource of a `data` array, as an item.
pub fn firstItem(arena: Allocator, body: []const u8) Error!?Item {
    const root = try tree(arena, body);
    for (array(field(root, "data"))) |resource| if (try item(arena, resource)) |it| return it;
    return null;
}

/// Album order: disc, then track. Stable, so tracks without numbers keep their place.
pub fn sortTracks(tracks: []Item) void {
    std.mem.sort(Item, tracks, {}, struct {
        fn lessThan(_: void, a: Item, b: Item) bool {
            const ad = a.disc_number orelse 1;
            const bd = b.disc_number orelse 1;
            if (ad != bd) return ad < bd;
            return (a.track_number orelse 0) < (b.track_number orelse 0);
        }
    }.lessThan);
}

/// Apple's error body (`errors[0]`, or a bare error object), when there is one.
pub const ApiError = struct { code: []const u8 = "", title: []const u8 = "", detail: []const u8 = "" };

pub fn apiError(arena: Allocator, body: []const u8) ?ApiError {
    const root = tree(arena, body) catch return null;
    const e = first(field(root, "errors")) orelse root;
    const said: ApiError = .{
        .code = string(field(e, "code")) orelse "",
        .title = string(field(e, "title")) orelse "",
        .detail = string(field(e, "detail")) orelse "",
    };
    if (said.code.len == 0 and said.title.len == 0 and said.detail.len == 0) return null;
    return said;
}

// ---- Fields ----

fn description(arena: Allocator, attributes: Value) Allocator.Error!?[]const u8 {
    for ([_][]const u8{ "editorialNotes", "description" }) |name| {
        const notes = field(attributes, name) orelse continue;
        const text = string(field(notes, "short")) orelse string(field(notes, "standard")) orelse continue;
        const plain = try plainText(arena, text);
        if (plain.len > 0) return plain;
    }
    return null;
}

/// Editorial notes carry a little HTML: tags dropped, the common entities decoded, runs of
/// whitespace folded to one space.
pub fn plainText(arena: Allocator, html: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, html.len);
    var i: usize = 0;
    var space = false;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const end = std.mem.findScalarPos(u8, html, i, '>') orelse html.len;
            const tag = html[i..@min(end + 1, html.len)];
            if (std.ascii.startsWithIgnoreCase(tag, "<br") or std.ascii.startsWithIgnoreCase(tag, "<p")) space = true;
            i = end + 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            i += 1;
            continue;
        }
        if (space and out.items.len > 0) out.appendAssumeCapacity(' ');
        space = false;
        if (c == '&') {
            if (entity(html[i..])) |e| {
                try out.appendSlice(arena, e.text);
                i += e.len;
                continue;
            }
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.items;
}

fn entity(s: []const u8) ?struct { text: []const u8, len: usize } {
    const entities = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" },  .{ "&lt;", "<" },   .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" },
        .{ "&apos;", "'" }, .{ "&nbsp;", " " },
    };
    for (entities) |e| if (std.mem.startsWith(u8, s, e[0])) return .{ .text = e[1], .len = e[0].len };
    return null;
}

fn artwork(v: ?Value) ?model.Artwork {
    const url = string(field(v, "url")) orelse return null;
    if (url.len == 0) return null;
    return .{
        .url = url,
        .width = integer(u32, field(v, "width")),
        .height = integer(u32, field(v, "height")),
        .bg = color(string(field(v, "bgColor"))),
        .text1 = color(string(field(v, "textColor1"))),
    };
}

fn color(hex: ?[]const u8) ?u24 {
    const h = hex orelse return null;
    if (h.len != 6) return null;
    return std.fmt.parseInt(u24, h, 16) catch null;
}

// ---- JSON tree access: a missing or mistyped field is null ----

fn field(v: ?Value, name: []const u8) ?Value {
    const object = v orelse return null;
    if (object != .object) return null;
    return object.object.get(name);
}

fn string(v: ?Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

fn integer(comptime T: type, v: ?Value) ?T {
    const n = v orelse return null;
    return switch (n) {
        .integer => |i| std.math.cast(T, i),
        else => null,
    };
}

fn boolean(v: ?Value) ?bool {
    const b = v orelse return null;
    return if (b == .bool) b.bool else null;
}

fn array(v: ?Value) []const Value {
    const a = v orelse return &.{};
    return if (a == .array) a.array.items else &.{};
}

fn first(v: ?Value) ?Value {
    const list = array(v);
    return if (list.len > 0) list[0] else null;
}

fn hasString(v: ?Value, wanted: []const u8) bool {
    for (array(v)) |s| if (std.mem.eql(u8, string(s) orelse continue, wanted)) return true;
    return false;
}

fn containsString(list: []const []const u8, wanted: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, wanted)) return true;
    return false;
}

const testing = std.testing;

fn fixture(comptime name: []const u8) []const u8 {
    return @embedFile("testdata/" ++ name);
}

test "library songs: library and catalog ids, favorites, explicit, total and next offset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(), fixture("library-songs.json"));
    try testing.expectEqual(@as(?u32, 100), p.next_offset);
    try testing.expectEqual(@as(?u32, 250), p.total);
    try testing.expectEqual(@as(usize, 2), p.items.len);
    const song = p.items[0];
    try testing.expectEqual(Kind.song, song.kind);
    try testing.expectEqualStrings("i.AAAA0001", song.id);
    try testing.expectEqualStrings("1000000001", song.catalog_id.?);
    try testing.expect(song.library);
    try testing.expectEqualStrings("First Song", song.title);
    try testing.expectEqualStrings("Artist One", song.artist.?);
    try testing.expectEqualStrings("Album One", song.album.?);
    try testing.expectEqual(@as(?u32, 181000), song.duration_ms);
    try testing.expectEqual(@as(?u16, 3), song.track_number);
    try testing.expectEqual(@as(?bool, true), song.favorited);
    try testing.expect(song.explicit);
    try testing.expect(song.playable);
    try testing.expect(std.mem.endsWith(u8, song.artwork.?.url, "/{w}x{h}bb.jpg"));
    try testing.expectEqual(@as(?u24, null), song.artwork.?.bg);
    // An upload has no catalog twin.
    try testing.expectEqual(@as(?[]const u8, null), p.items[1].catalog_id);
    try testing.expectEqual(@as(?bool, false), p.items[1].favorited);
    try testing.expect(!p.items[1].explicit);
}

test "library playlists: the favorited tag, canEdit, globalId as the catalog id, plain-text descriptions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(), fixture("library-playlists.json"));
    try testing.expectEqual(@as(usize, 4), p.items.len);
    const road_trip, const favorites, const purchased, const shared = p.items[0..4].*;
    try testing.expect(road_trip.can_edit and !road_trip.tags_favorited);
    try testing.expectEqual(@as(?[]const u8, null), road_trip.description);
    try testing.expectEqual(@as(?[]const u8, null), road_trip.catalog_id);
    // Generated art has no {w}x{h} placeholders.
    try testing.expect(std.mem.find(u8, road_trip.artwork.?.url, "{w}") == null);
    try testing.expect(favorites.tags_favorited and !favorites.can_edit);
    try testing.expectEqual(@as(?model.Artwork, null), purchased.artwork);
    try testing.expectEqualStrings("pl.u-AAAA0004", shared.catalog_id.?);
    try testing.expectEqualStrings("Songs for the weekend & after.", shared.description.?);
    try testing.expectEqual(@as(?bool, true), shared.favorited);
}

test "library artists take artwork and catalog id from their included catalog twin" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(), fixture("library-artists.json"));
    try testing.expectEqual(Kind.artist, p.items[0].kind);
    try testing.expectEqualStrings("1000000101", p.items[0].catalog_id.?);
    try testing.expect(p.items[0].artwork != null);
    try testing.expectEqual(@as(?[]const u8, null), p.items[1].catalog_id);
    try testing.expectEqual(@as(?model.Artwork, null), p.items[1].artwork);
}

test "library albums take their catalog id and colors from the included twin" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(),
        \\{"data":[{"id":"l.AAAA0001","type":"library-albums","attributes":{"name":"Album One",
        \\ "playParams":{"id":"l.AAAA0001","isLibrary":true,"kind":"album"},"artwork":{"url":"a/{w}x{h}bb.jpg"}},
        \\ "relationships":{"catalog":{"data":[{"id":"1000000401","type":"albums",
        \\ "attributes":{"artwork":{"url":"c/{w}x{h}bb.jpg","bgColor":"112233"}}}]}}}]}
    );
    const album = p.items[0];
    try testing.expectEqualStrings("l.AAAA0001", album.id);
    try testing.expectEqualStrings("1000000401", album.catalog_id.?);
    try testing.expectEqual(@as(?u24, 0x112233), album.artwork.?.bg);
}

test "catalog items: catalog id, artwork colors, genre, editorial notes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try chartGroups(arena.allocator(), fixture("charts.json"));
    const albums = for (groups) |g| {
        if (std.mem.eql(u8, g.key, "most-played:albums")) break g;
    } else return error.TestExpectedAlbums;
    const album = albums.items[0];
    try testing.expectEqual(Kind.album, album.kind);
    try testing.expect(!album.library);
    try testing.expectEqualStrings(album.id, album.catalog_id.?);
    try testing.expectEqual(@as(?u24, 0x114a21), album.artwork.?.bg);
    try testing.expectEqual(@as(?u24, 0xb4f4c3), album.artwork.?.text1);
    try testing.expectEqual(@as(?u32, 3000), album.artwork.?.width);
    try testing.expectEqualStrings("Hip-Hop/Rap", album.genre.?);
    try testing.expectEqual(@as(?u32, 16), album.track_count);
    try testing.expect(album.description != null);
    try testing.expectEqual(@as(?bool, null), album.favorited);
}

test "charts follow meta order and keep each chart's name and next offset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try chartGroups(arena.allocator(), fixture("charts.json"));
    try testing.expectEqual(@as(usize, 4), groups.len);
    try testing.expectEqualStrings("most-played:songs", groups[0].key);
    try testing.expectEqualStrings("Top Songs", groups[0].title);
    try testing.expectEqualStrings("daily-global-top:dailyGlobalTopCharts", groups[1].key);
    try testing.expectEqualStrings("most-played:playlists", groups[2].key);
    try testing.expectEqualStrings("most-played:albums", groups[3].key);
    try testing.expectEqual(@as(?u32, 50), groups[0].next_offset);
    try testing.expectEqual(Kind.song, groups[0].items[0].kind);
    try testing.expectEqual(Kind.playlist, groups[1].items[0].kind);
}

test "search groups follow meta order, drop types the TUI doesn't show, and keep next offsets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try searchGroups(arena.allocator(), fixture("search.json"));
    const want = [_][]const u8{ "topResults", "artists", "songs", "albums", "stations" };
    try testing.expectEqual(want.len, groups.len);
    for (want, groups) |key, g| try testing.expectEqualStrings(key, g.key);
    try testing.expectEqualStrings("Top Results", groups[0].title);
    try testing.expectEqual(Kind.artist, groups[0].items[0].kind);
    try testing.expectEqual(Kind.song, groups[0].items[1].kind);
    try testing.expectEqual(@as(?u32, 25), groups[2].next_offset);
    try testing.expectEqual(@as(?u32, null), groups[1].next_offset);
    try testing.expectEqualStrings("Stressed Out", groups[2].items[0].title);
}

test "a search section reads as a page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try searchPage(arena.allocator(), fixture("search.json"), "songs");
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqual(@as(?u32, 25), p.next_offset);
    try testing.expectEqual(@as(usize, 0), (try searchPage(arena.allocator(), fixture("search.json"), "music-videos")).items.len);
}

test "library search titles drop the library- prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try searchGroups(arena.allocator(), fixture("library-search.json"));
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("Artists", groups[0].title);
    try testing.expectEqualStrings("library-artists", groups[0].key);
    try testing.expectEqualStrings("Songs", groups[1].title);
    try testing.expect(groups[1].items[0].library);
}

test "suggestions are the search terms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const terms = try suggestions(arena.allocator(), fixture("suggestions.json"));
    try testing.expectEqual(@as(usize, 3), terms.len);
    try testing.expectEqualStrings("twenty one pilots", terms[0]);
}

test "recommendations: one group per recommendation, empty ones dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try recommendationGroups(arena.allocator(), fixture("recommendations.json"));
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("Playlists Made for You", groups[0].title);
    try testing.expectEqual(@as(usize, 2), groups[0].items.len);
    try testing.expectEqualStrings("Apple Music", groups[0].items[0].artist.?);
    try testing.expectEqualStrings("Stations for You", groups[1].title);
    try testing.expect(groups[1].items[0].is_live);
}

test "artist views follow meta order, keep their titles, and drop empty views" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const groups = try artistViews(arena.allocator(), fixture("artist-views.json"));
    const want = [_][]const u8{ "latest-release", "top-songs", "full-albums", "featured-playlists", "singles", "similar-artists" };
    try testing.expectEqual(want.len, groups.len);
    for (want, groups) |key, g| try testing.expectEqualStrings(key, g.key);
    try testing.expectEqualStrings("Top Songs", groups[1].title);
    try testing.expectEqual(@as(?u32, 10), groups[1].next_offset);
    try testing.expectEqual(Kind.artist, groups[5].items[0].kind);
}

test "stations: live radio, provider as the artist, editorial notes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(), fixture("stations-live.json"));
    const station = p.items[0];
    try testing.expectEqual(Kind.station, station.kind);
    try testing.expectEqualStrings("ra.978194965", station.id);
    try testing.expect(station.is_live);
    try testing.expectEqualStrings("Apple Music", station.artist.?);
    try testing.expectEqualStrings("Live now", station.description.?);
    const mine = (try firstItem(arena.allocator(), fixture("stations-personal.json"))).?;
    try testing.expect(!mine.is_live);
    try testing.expectEqualStrings("My Station", mine.title);
}

test "mixed lists keep the kinds they know and skip the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(), fixture("recent-played.json"));
    try testing.expectEqual(@as(usize, 3), p.items.len);
    try testing.expectEqual(Kind.station, p.items[0].kind);
    try testing.expectEqual(Kind.album, p.items[1].kind);
    try testing.expectEqual(Kind.playlist, p.items[2].kind);
    try testing.expect(p.items[2].library);
    try testing.expectEqual(@as(?u32, 10), p.next_offset);
}

test "album tracks sort by disc, then track" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(), fixture("library-album-tracks.json"));
    sortTracks(p.items);
    try testing.expectEqualStrings("Opener", p.items[0].title);
    try testing.expectEqualStrings("Second", p.items[1].title);
    try testing.expectEqualStrings("Bonus", p.items[2].title);
    try testing.expectEqual(@as(?u32, 3), p.total);
}

test "the storefront id, and Apple's error bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("gb", try storefront(a, fixture("storefront.json")));
    try testing.expectError(error.BadResponse, storefront(a, "{\"data\":[]}"));
    const e = apiError(a, fixture("error-400.json")).?;
    try testing.expectEqualStrings("40005", e.code);
    try testing.expect(std.mem.startsWith(u8, e.detail, "Value must be"));
    try testing.expectEqual(@as(?ApiError, null), apiError(a, ""));
    try testing.expectEqual(@as(?ApiError, null), apiError(a, "{\"data\":[]}"));
    const bare = apiError(a, "{\"title\":\"Insufficient Permissions\",\"detail\":\"needs more\",\"code\":\"40012\"}").?;
    try testing.expectEqualStrings("40012", bare.code);
    try testing.expectEqualStrings("needs more", bare.detail);
}

test "not JSON is a bad response; an empty body is an empty page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadResponse, page(arena.allocator(), "<html>"));
    try testing.expectEqual(@as(usize, 0), (try page(arena.allocator(), "")).items.len);
}

test "odd field types are skipped, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try page(arena.allocator(),
        \\{"data":[{"id":"1","type":"songs","attributes":{"name":7,"durationInMillis":"x","trackNumber":-1,
        \\ "artwork":{"url":"u","bgColor":"zz"},"genreNames":"Rock","inFavorites":"yes"}},
        \\ {"id":"2","type":"songs"},{"type":"songs","attributes":{}}],"next":"/v1/x?offset=abc"}
    );
    try testing.expectEqual(@as(usize, 1), p.items.len);
    const it = p.items[0];
    try testing.expectEqualStrings("", it.title);
    try testing.expectEqual(@as(?u32, null), it.duration_ms);
    try testing.expectEqual(@as(?u16, null), it.track_number);
    try testing.expectEqual(@as(?u24, null), it.artwork.?.bg);
    try testing.expectEqual(@as(?[]const u8, null), it.genre);
    try testing.expectEqual(@as(?bool, null), it.favorited);
    try testing.expect(!it.playable);
    try testing.expectEqual(@as(?u32, null), p.next_offset);
}

test "next offsets come from the query, wherever offset sits" {
    try testing.expectEqual(@as(?u32, 100), nextOffset("/v1/me/library/songs?offset=100"));
    try testing.expectEqual(@as(?u32, 3), nextOffset("/v1/me/library/songs?l=en-GB&offset=3&sort=name"));
    try testing.expectEqual(@as(?u32, null), nextOffset("/v1/me/library/songs"));
    try testing.expectEqual(@as(?u32, null), nextOffset(null));
}

test "plain text drops tags and decodes entities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("A <b> & C. D", try plainText(arena.allocator(), "  <i>A</i> &lt;b&gt; &amp;\n C.<br/>D "));
}
