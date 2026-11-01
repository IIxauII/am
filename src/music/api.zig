//! The Apple Music API calls the TUI makes: catalog, library, recommendations, charts,
//! stations, favorites. Results are allocated in the caller's arena and nothing is printed.
//! An `Api` is a plain value, so each job can hold its own copy; requests from all copies share
//! one rate limiter.
const std = @import("std");
const apple = @import("../apple.zig");
const model = @import("model.zig");
const parse = @import("parse.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Item = model.Item;
const Kind = model.Kind;
const Page = model.Page;
const Group = model.Group;

pub const Error = error{
    /// 401: Apple refused the developer token.
    DeveloperTokenRejected,
    /// 403: the Music User Token is missing, expired or revoked.
    SignInRequired,
    /// 429, still after the retries.
    RateLimited,
    NotFound,
    /// Any other 4xx. Only an answer from Apple is this, so the diagnostic is about it.
    BadRequest,
    /// A request that makes no sense for the item (a station's tracks, a curator as a
    /// favorite): refused here, nothing sent.
    Unsupported,
    ServerError,
    /// Apple could not be reached.
    Network,
    /// Apple's answer was not the JSON expected.
    BadResponse,
} || Allocator.Error || Io.Cancelable;

/// A sentence for the user.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.DeveloperTokenRejected => "Apple rejected the developer token; run `am token` to make a new one",
        error.SignInRequired => "Apple Music needs you to sign in again",
        error.RateLimited => "Apple Music is limiting requests; try again in a minute",
        error.NotFound => "Apple Music doesn't have that (any more)",
        error.BadRequest => "Apple Music refused the request",
        error.Unsupported => "Apple Music has no way to do that for this item",
        error.ServerError => "Apple Music had a server error; try again",
        error.Network => "can't reach Apple Music; check the network",
        error.BadResponse => "Apple Music sent an answer am can't read",
        error.OutOfMemory => "out of memory",
        error.Canceled => "canceled",
    };
}

/// What Apple said about a failed request. Strings live in that call's arena.
pub const Diagnostic = struct {
    status: u16 = 0,
    code: []const u8 = "",
    title: []const u8 = "",
    detail: []const u8 = "",
};

/// At most `per_second` requests start in any `window`. Thread-safe.
pub const Limiter = struct {
    per_second: u8 = 8,
    window: Io.Duration = .fromSeconds(1),
    mutex: Io.Mutex = .init,
    /// When each of the last `per_second` requests started (a ring).
    starts: [max]Io.Timestamp = @splat(.zero),
    next: usize = 0,

    pub const max = 16;

    /// Waits for a free slot and takes it.
    pub fn wait(l: *Limiter, io: Io) Io.Cancelable!void {
        const now: Io.Timestamp = .now(io, .awake);
        const start = start: {
            try l.mutex.lock(io);
            defer l.mutex.unlock(io);
            const n = @min(@max(l.per_second, 1), max);
            // The slot is free once the request `n` back is a window old.
            const free_at = l.starts[l.next].addDuration(l.window);
            const start = if (free_at.compare(.gt, now)) free_at else now;
            l.starts[l.next] = start;
            l.next = (l.next + 1) % n;
            break :start start;
        };
        if (start.compare(.gt, now)) try io.sleep(now.durationTo(start), .awake);
    }
};

/// The process-wide limit: Apple answers 429 after a few dozen quick requests.
pub var shared_limiter: Limiter = .{};

/// How requests are spaced and retried.
pub const Pacing = struct {
    limiter: ?*Limiter = &shared_limiter,
    /// Waits before each retry of a 429.
    retry_delays: []const Io.Duration = &.{ .fromSeconds(1), .fromSeconds(2), .fromSeconds(4) },
    /// Recommendations sometimes come back empty on the first call; the wait before the retry.
    empty_retry: Io.Duration = .fromSeconds(1),

    /// No limiter and no waits, with the same number of retries (tests).
    pub const immediate: Pacing = .{ .limiter = null, .retry_delays = &.{ .zero, .zero, .zero }, .empty_retry = .zero };
};

pub const Sort = enum {
    name,
    name_desc,
    date_added,
    date_added_desc,

    fn param(s: Sort) []const u8 {
        return switch (s) {
            .name => "name",
            .name_desc => "-name",
            .date_added => "dateAdded",
            .date_added_desc => "-dateAdded",
        };
    }
};

pub const Api = struct {
    io: Io,
    transport: apple.Transport,
    developer_token: []const u8,
    /// Empty: none is sent (catalog requests work without; `/v1/me` ones answer 403).
    user_token: []const u8,
    storefront: []const u8,
    /// `l=`: one of the storefront's supportedLanguageTags, e.g. `en-GB`.
    language: ?[]const u8 = null,
    pacing: Pacing = .{},
    /// Cleared as each request starts and filled when it fails with an HTTP status, so after a
    /// call that failed with an HTTP error it describes that answer. Give each concurrent caller
    /// its own.
    diagnostic: ?*Diagnostic = null,
    /// Asked once per request for a newer developer token when Apple answers 401; the request
    /// is then sent again with it.
    renew: ?apple.Renew = null,

    const page_size = 100;
    const search_limit = 25;

    // ---- Account ----

    /// `GET /v1/me/storefront`: the user's storefront id. `storefront` may still be empty.
    pub fn storefrontOf(api: Api, arena: Allocator) Error![]const u8 {
        return parse.storefront(arena, try api.get(arena, "/v1/me/storefront"));
    }

    // ---- Search ----

    /// Catalog search over songs, albums, artists, playlists and stations, sections in Apple's
    /// order. The first page (offset 0) also has Top Results.
    pub fn search(api: Api, arena: Allocator, term: []const u8, offset: u32) Error![]Group {
        var u = try api.catalog(arena, "/search");
        try u.param("term", term);
        try u.param("types", "songs,albums,artists,playlists,stations");
        try u.int("limit", search_limit);
        if (offset > 0) try u.int("offset", offset) else try u.param("with", "topResults");
        try u.param("extend", "inFavorites");
        return parse.searchGroups(arena, try api.get(arena, u.path()));
    }

    /// More of one search section: `key` is a group's key from `search` or `librarySearch`.
    pub fn searchMore(api: Api, arena: Allocator, term: []const u8, key: []const u8, offset: u32) Error!Page {
        if (std.mem.eql(u8, key, "topResults")) return error.Unsupported;
        const in_library = std.mem.startsWith(u8, key, "library-");
        var u = if (in_library) try Url.init(arena, "/v1/me/library/search") else try api.catalog(arena, "/search");
        try u.param("term", term);
        try u.param("types", key);
        try u.int("limit", search_limit);
        try u.int("offset", offset);
        try u.param("extend", "inFavorites");
        return parse.searchPage(arena, try api.get(arena, u.path()), key);
    }

    /// Search-as-you-type: up to ten terms.
    pub fn suggestions(api: Api, arena: Allocator, term: []const u8) Error![][]const u8 {
        var u = try api.catalog(arena, "/search/suggestions");
        try u.param("term", term);
        try u.param("kinds", "terms");
        try u.int("limit", 10);
        return parse.suggestions(arena, try api.get(arena, u.path()));
    }

    pub fn librarySearch(api: Api, arena: Allocator, term: []const u8) Error![]Group {
        var u = try Url.init(arena, "/v1/me/library/search");
        try u.param("term", term);
        try u.param("types", "library-songs,library-albums,library-artists,library-playlists");
        try u.int("limit", search_limit);
        try u.param("extend", "inFavorites");
        return parse.searchGroups(arena, try api.get(arena, u.path()));
    }

    // ---- Library ----

    /// One page (100) of library songs, albums, artists or playlists. Artists sort by name only.
    pub fn library(api: Api, arena: Allocator, kind: Kind, offset: u32, sort: Sort) Error!Page {
        const segment = switch (kind) {
            .song => "songs",
            .album => "albums",
            .artist => "artists",
            .playlist => "playlists",
            .station, .music_video, .curator => return error.Unsupported,
        };
        var u = try Url.init(arena, "/v1/me/library/");
        try u.lit(segment);
        try u.int("limit", page_size);
        try u.int("offset", offset);
        switch (kind) {
            .artist => {
                try u.param("sort", if (sort == .name_desc) "-name" else "name");
                // Library artists have only a name; the catalog twin has the picture.
                try u.param("include", "catalog");
                try u.param("extend", "inFavorites");
            },
            .playlist => {
                try u.param("sort", sort.param());
                try u.param("extend", "inFavorites,tags");
            },
            .album => {
                try u.param("sort", sort.param());
                // Library albums carry no catalog id; the twin has it, and the colors.
                try u.param("include", "catalog");
                try u.param("extend", "inFavorites");
            },
            else => {
                try u.param("sort", sort.param());
                try u.param("extend", "inFavorites");
            },
        }
        return parse.page(arena, try api.get(arena, u.path()));
    }

    /// Albums and playlists added to the library, newest first; 25 per page.
    pub fn recentlyAdded(api: Api, arena: Allocator, offset: u32) Error!Page {
        var u = try Url.init(arena, "/v1/me/library/recently-added");
        try u.int("limit", 25);
        try u.int("offset", offset);
        try u.param("include", "catalog");
        try u.param("extend", "inFavorites");
        return parse.page(arena, try api.get(arena, u.path()));
    }

    /// Recently played albums, playlists and stations; 10 per page.
    pub fn recentlyPlayed(api: Api, arena: Allocator, offset: u32) Error!Page {
        var u = try Url.init(arena, "/v1/me/recent/played");
        try u.int("limit", 10);
        try u.int("offset", offset);
        try u.param("extend", "inFavorites");
        return parse.page(arena, try api.get(arena, u.path()));
    }

    /// Recently played songs; 30 per page.
    pub fn recentlyPlayedTracks(api: Api, arena: Allocator, offset: u32) Error!Page {
        var u = try Url.init(arena, "/v1/me/recent/played/tracks");
        try u.int("limit", 30);
        try u.int("offset", offset);
        try u.param("extend", "inFavorites");
        return parse.page(arena, try api.get(arena, u.path()));
    }

    pub fn recentStations(api: Api, arena: Allocator) Error!Page {
        return parse.page(arena, try api.get(arena, "/v1/me/recent/radio-stations?limit=30"));
    }

    pub fn heavyRotation(api: Api, arena: Allocator) Error!Page {
        return parse.page(arena, try api.get(arena, "/v1/me/history/heavy-rotation?limit=10&extend=inFavorites"));
    }

    // ---- Browse ----

    /// "For You": Made for You mixes, Recently Played, Stations for You, …
    pub fn recommendations(api: Api, arena: Allocator) Error![]Group {
        const path = "/v1/me/recommendations?limit=30&extend=inFavorites";
        const groups = try parse.recommendationGroups(arena, try api.get(arena, path));
        if (groups.len > 0) return groups;
        try api.io.sleep(api.pacing.empty_retry, .awake);
        return parse.recommendationGroups(arena, try api.get(arena, path));
    }

    /// Top songs, albums and playlists of the storefront, and the daily global top 100.
    pub fn charts(api: Api, arena: Allocator) Error![]Group {
        var u = try api.catalog(arena, "/charts");
        try u.param("types", "songs,albums,playlists");
        try u.int("limit", 50);
        try u.param("with", "dailyGlobalTopCharts");
        return parse.chartGroups(arena, try api.get(arena, u.path()));
    }

    /// The personal station, live radio and recently played stations; empty ones left out.
    pub fn stations(api: Api, arena: Allocator) Error![]Group {
        var groups: std.ArrayList(Group) = .empty;
        var personal = try api.catalog(arena, "/stations");
        try personal.param("filter[identity]", "personal");
        try appendGroup(arena, &groups, "Your Station", "personal", api.getPage(arena, personal.path()));
        var live = try api.catalog(arena, "/stations");
        try live.param("filter[featured]", "apple-music-live-radio");
        try appendGroup(arena, &groups, "Live Radio", "live", api.getPage(arena, live.path()));
        try appendGroup(arena, &groups, "Recently Played Stations", "recent", api.recentStations(arena));
        return groups.items;
    }

    fn appendGroup(arena: Allocator, groups: *std.ArrayList(Group), title: []const u8, key: []const u8, result: Error!Page) Error!void {
        const p = result catch |e| switch (e) {
            error.NotFound => return,
            else => return e,
        };
        if (p.items.len == 0) return;
        try groups.append(arena, .{ .title = title, .items = p.items, .next_offset = p.next_offset, .key = key });
    }

    // ---- Containers and artists ----

    /// One page (100) of an album's or playlist's tracks, catalog or library. Albums come in
    /// disc and track order; an empty library playlist is an empty page.
    pub fn tracks(api: Api, arena: Allocator, container: Item, offset: u32) Error!Page {
        const kind = switch (container.kind) {
            .album => "albums/",
            .playlist => "playlists/",
            else => return error.Unsupported,
        };
        var u = if (container.library) try Url.init(arena, "/v1/me/library/") else try api.catalog(arena, "/");
        try u.lit(kind);
        try u.segment(container.id);
        try u.lit("/tracks");
        try u.int("limit", page_size);
        try u.int("offset", offset);
        try u.param("extend", "inFavorites");
        const p = api.getPage(arena, u.path()) catch |e| switch (e) {
            // Apple answers 404 for a playlist with no tracks.
            error.NotFound => if (container.library) return .{ .items = &.{}, .total = 0 } else return e,
            else => return e,
        };
        if (container.kind == .album) parse.sortTracks(p.items);
        return p;
    }

    /// A catalog artist's sections (latest release, top songs, albums, singles, …). A library
    /// artist gets its library albums first, then the catalog sections when Apple knows the artist.
    pub fn artist(api: Api, arena: Allocator, who: Item) Error![]Group {
        var groups: std.ArrayList(Group) = .empty;
        var catalog_id = if (who.library) who.catalog_id else who.catalog_id orelse who.id;
        if (who.library) {
            var u = try Url.init(arena, "/v1/me/library/artists/");
            try u.segment(who.id);
            try u.lit("/albums");
            try u.int("limit", page_size);
            try u.param("include", "catalog");
            try u.param("extend", "inFavorites");
            try appendGroup(arena, &groups, "In Your Library", "library-albums", api.getPage(arena, u.path()));
            if (catalog_id == null) {
                var c = try Url.init(arena, "/v1/me/library/artists/");
                try c.segment(who.id);
                try c.lit("/catalog");
                const twin = api.get(arena, c.path()) catch |e| switch (e) {
                    error.NotFound => null,
                    else => return e,
                };
                if (twin) |body| if (try parse.firstItem(arena, body)) |it| {
                    catalog_id = it.id;
                };
            }
        }
        if (catalog_id) |id| {
            var u = try api.catalog(arena, "/artists/");
            try u.segment(id);
            try u.param("views", "latest-release,top-songs,full-albums,singles,appears-on-albums,featured-playlists,similar-artists");
            try u.param("extend", "inFavorites");
            const body = api.get(arena, u.path()) catch |e| switch (e) {
                // Not in this storefront: a library artist still has its library albums.
                error.NotFound => if (who.library) return groups.items else return e,
                else => return e,
            };
            try groups.appendSlice(arena, try parse.artistViews(arena, body));
        }
        return groups.items;
    }

    /// More of one artist section: `key` is a group's key from `artist`, `artist_id` a catalog id.
    pub fn artistView(api: Api, arena: Allocator, artist_id: []const u8, key: []const u8, offset: u32) Error!Page {
        var u = try api.catalog(arena, "/artists/");
        try u.segment(artist_id);
        try u.lit("/view/");
        try u.segment(key);
        try u.int("limit", search_limit);
        try u.int("offset", offset);
        try u.param("extend", "inFavorites");
        return api.getPage(arena, u.path());
    }

    /// The station Apple builds from a song, or null when there is none.
    pub fn songStation(api: Api, arena: Allocator, song: Item) Error!?Item {
        const id = song.catalog_id orelse return null;
        var u = try api.catalog(arena, "/songs/");
        try u.segment(id);
        try u.lit("/station");
        const body = api.get(arena, u.path()) catch |e| switch (e) {
            error.NotFound => return null,
            else => return e,
        };
        return parse.firstItem(arena, body);
    }

    /// Catalog (or library) items by id, up to 100, with their favorite state: what the TUI
    /// shows about the song that is playing. Unknown ids are left out.
    pub fn lookup(api: Api, arena: Allocator, kind: Kind, in_library: bool, ids: []const []const u8) Error![]Item {
        if (ids.len == 0) return &.{};
        if (ids.len > page_size) return error.Unsupported;
        const resource = (if (in_library) libraryType(kind) else catalogType(kind)) orelse return error.Unsupported;
        var u = if (in_library) try Url.init(arena, "/v1/me/library/") else try api.catalog(arena, "/");
        try u.lit(if (in_library) resource["library-".len..] else resource);
        try u.list("ids", ids);
        try u.param("extend", "inFavorites");
        return (try api.getPage(arena, u.path())).items;
    }

    pub const Relation = enum { albums, artists };

    /// The album or artist a song (or an album's artist) belongs to: `GET …/{id}/albums` or
    /// `…/{id}/artists`. The catalog is asked when the catalog id is known; a library item it
    /// knows nothing about is then asked in the library. Null when there is none.
    pub fn related(api: Api, arena: Allocator, it: Item, relation: Relation) Error!?Item {
        const own_type = switch (it.kind) {
            .song => "songs/",
            .album => "albums/",
            .music_video => "music-videos/",
            else => return error.Unsupported,
        };
        if (it.catalog_id) |id| {
            var u = try api.catalog(arena, "/");
            if (try api.relatedAt(arena, &u, own_type, id, relation)) |found| return found;
        }
        if (!it.library) return null;
        var u = try Url.init(arena, "/v1/me/library/");
        return api.relatedAt(arena, &u, own_type, it.id, relation);
    }

    fn relatedAt(api: Api, arena: Allocator, u: *Url, own_type: []const u8, id: []const u8, relation: Relation) Error!?Item {
        try u.lit(own_type);
        try u.segment(id);
        try u.lit(if (relation == .albums) "/albums" else "/artists");
        const body = api.get(arena, u.path()) catch |e| switch (e) {
            error.NotFound => return null,
            else => return e,
        };
        return parse.firstItem(arena, body);
    }

    // ---- Favorites and library edits ----

    /// The library's Favorite Songs playlist (tagged "favorited"), or null when there is none.
    pub fn favoriteSongsPlaylist(api: Api, arena: Allocator) Error!?Item {
        var offset: ?u32 = 0;
        var pages: usize = 0;
        while (offset) |o| : (pages += 1) {
            if (pages == max_pages) break;
            var u = try Url.init(arena, "/v1/me/library/playlists");
            try u.int("limit", page_size);
            try u.int("offset", o);
            try u.param("extend[library-playlists]", "tags");
            const p = try api.getPage(arena, u.path());
            for (p.items) |it| if (it.tags_favorited) return it;
            offset = p.next_offset;
        }
        return null;
    }

    /// Favorites an item, the way music.apple.com does: `POST /v1/me/favorites?ids[<type>]=<id>`.
    pub fn addFavorite(api: Api, arena: Allocator, it: Item) Error!void {
        const target = favoriteTarget(it) orelse return error.Unsupported;
        var u = try Url.init(arena, "/v1/me/favorites");
        try u.ids(target.type, &.{target.id});
        _ = try api.call(arena, .POST, u.path(), null);
    }

    /// What Apple says after `removeFavorite`.
    pub const Unfavorited = enum {
        removed,
        /// Apple still lists it as a favorite, or there's no way to ask (an artist): only the
        /// Music app can remove it.
        still_favorite,
    };

    /// Un-favorites an item by deleting its rating, `DELETE /v1/me/ratings/<type>/<id>` (the
    /// catalog one when known, else the library one): Apple refuses `DELETE /v1/me/favorites` to
    /// other apps' tokens. Then reads `inFavorites` back. Artists have no rating to delete.
    /// A deleted rating whose read-back fails counts as removed: the delete is the last thing
    /// Apple answered.
    pub fn removeFavorite(api: Api, arena: Allocator, it: Item) Error!Unfavorited {
        const target = ratingTarget(it) orelse return .still_favorite;
        var u = try Url.init(arena, "/v1/me/ratings/");
        try u.lit(target.type);
        try u.lit("/");
        try u.segment(target.id);
        var deleted = true;
        _ = api.call(arena, .DELETE, u.path(), null) catch |e| switch (e) {
            // No rating to delete: what Apple says next decides.
            error.NotFound => deleted = false,
            else => return e,
        };
        var one = [_]Item{it};
        one[0].favorited = null;
        api.favoritedState(arena, &one) catch |e| switch (e) {
            error.Canceled => return e,
            else => if (deleted) return .removed else return e,
        };
        return if (one[0].favorited orelse false) .still_favorite else .removed;
    }

    /// Fills `favorited` for the items that lack it, 100 ids per request. Stations and curators
    /// have no favorite state and stay null.
    pub fn favoritedState(api: Api, arena: Allocator, list: []Item) Error!void {
        const kinds = [_]Kind{ .song, .album, .artist, .playlist, .music_video };
        for (kinds) |kind| for ([_]bool{ false, true }) |in_library| {
            var wanted: std.ArrayList(usize) = .empty;
            for (list, 0..) |it, i| {
                if (it.favorited != null or it.kind != kind or it.library != in_library) continue;
                if (!in_library and it.catalog_id == null) continue;
                try wanted.append(arena, i);
            }
            var start: usize = 0;
            while (start < wanted.items.len) : (start += page_size) {
                const chunk = wanted.items[start..@min(start + page_size, wanted.items.len)];
                try api.fillFavorites(arena, list, chunk, kind, in_library);
            }
        };
    }

    fn fillFavorites(api: Api, arena: Allocator, list: []Item, chunk: []const usize, kind: Kind, in_library: bool) Error!void {
        const ids = try arena.alloc([]const u8, chunk.len);
        for (chunk, ids) |i, *id| id.* = if (in_library) list[i].id else list[i].catalog_id.?;
        var u = if (in_library) try Url.init(arena, "/v1/me/library/") else try api.catalog(arena, "/");
        try u.lit(if (in_library) libraryType(kind).?["library-".len..] else catalogType(kind).?);
        try u.list("ids", ids);
        try u.param("extend", "inFavorites");
        const p = try api.getPage(arena, u.path());
        for (p.items) |found| {
            const state = found.favorited orelse continue;
            for (chunk) |i| {
                const id = if (in_library) list[i].id else list[i].catalog_id.?;
                if (std.mem.eql(u8, id, found.id)) list[i].favorited = state;
            }
        }
    }

    /// Adds a catalog song, album, playlist or music video to the library
    /// (`POST /v1/me/library?ids[<type>]=<id>`). Library items are already there.
    pub fn addToLibrary(api: Api, arena: Allocator, it: Item) Error!void {
        if (it.library) return;
        const id = it.catalog_id orelse return error.Unsupported;
        const resource_type = switch (it.kind) {
            .song, .album, .playlist, .music_video => catalogType(it.kind).?,
            .artist, .station, .curator => return error.Unsupported,
        };
        var u = try Url.init(arena, "/v1/me/library");
        try u.ids(resource_type, &.{id});
        _ = try api.call(arena, .POST, u.path(), null);
    }

    /// The library playlists tracks can be added to (canEdit), all pages, in name order.
    pub fn editablePlaylists(api: Api, arena: Allocator) Error!Page {
        var editable: std.ArrayList(Item) = .empty;
        var offset: ?u32 = 0;
        var pages: usize = 0;
        while (offset) |o| : (pages += 1) {
            if (pages == max_pages) break;
            const p = try api.library(arena, .playlist, o, .name);
            for (p.items) |it| if (it.can_edit) try editable.append(arena, it);
            offset = p.next_offset;
        }
        return .{ .items = editable.items, .total = @intCast(editable.items.len) };
    }

    /// Appends songs (catalog or library) and music videos to a library playlist
    /// (`POST /v1/me/library/playlists/{id}/tracks`), 100 per request.
    pub fn addToPlaylist(api: Api, arena: Allocator, playlist_id: []const u8, songs: []const Item) Error!void {
        // Check every item first, so a bad one doesn't leave the playlist half done.
        for (songs) |it| switch (it.kind) {
            .song, .music_video => {},
            else => return error.Unsupported,
        };
        var u = try Url.init(arena, "/v1/me/library/playlists/");
        try u.segment(playlist_id);
        try u.lit("/tracks");
        var start: usize = 0;
        while (start < songs.len) : (start += page_size) {
            const chunk = songs[start..@min(start + page_size, songs.len)];
            var body: Io.Writer.Allocating = .init(arena);
            writeTracksBody(&body.writer, chunk) catch return error.OutOfMemory;
            _ = try api.call(arena, .POST, u.path(), body.written());
        }
    }

    fn writeTracksBody(w: *Io.Writer, chunk: []const Item) Io.Writer.Error!void {
        try w.writeAll("{\"data\":[");
        for (chunk, 0..) |it, i| {
            const id, const resource_type = if (it.library)
                .{ it.id, libraryType(it.kind).? }
            else
                .{ it.catalog_id orelse it.id, catalogType(it.kind).? };
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try std.json.Stringify.encodeJsonString(id, .{}, w);
            try w.print(",\"type\":\"{s}\"}}", .{resource_type});
        }
        try w.writeAll("]}");
    }

    // ---- Requests ----

    /// The most pages a whole-collection walk reads (10 000 playlists).
    const max_pages = 100;

    fn catalog(api: Api, arena: Allocator, rest: []const u8) Allocator.Error!Url {
        var u = try Url.init(arena, "/v1/catalog/");
        try u.segment(api.storefront);
        try u.lit(rest);
        return u;
    }

    fn getPage(api: Api, arena: Allocator, path: []const u8) Error!Page {
        return parse.page(arena, try api.get(arena, path));
    }

    fn get(api: Api, arena: Allocator, path: []const u8) Error![]const u8 {
        return api.call(arena, .GET, path, null);
    }

    /// Sends one request (paced, 429s retried) and returns the body of a 2xx answer.
    fn call(api: Api, arena: Allocator, method: apple.Method, path: []const u8, body: ?[]const u8) Error![]const u8 {
        const url = if (api.language) |language| url: {
            var u: Url = .{ .arena = arena, .bytes = .empty, .has_query = std.mem.findScalar(u8, path, '?') != null };
            try u.lit(apple.base_url);
            try u.lit(path);
            try u.param("l", language);
            break :url u.path();
        } else try std.mem.concat(arena, u8, &.{ apple.base_url, path });

        var buffer: [3]std.http.Header = undefined;
        const token = try apple.Renew.current(api.renew, arena, api.developer_token);
        var headers = try apple.requestHeaders(arena, &buffer, token, api.user_token);

        // Only the last request's failure is described.
        if (api.diagnostic) |d| d.* = .{};
        var retries: usize = 0;
        var renewed = false;
        while (true) {
            if (api.pacing.limiter) |l| try l.wait(api.io);
            const response = api.transport.request(arena, method, url, headers, body) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => error.Network,
            };
            if (response.status / 100 == 2) return response.body;
            if (response.status == 429 and retries < api.pacing.retry_delays.len) {
                try api.io.sleep(api.pacing.retry_delays[retries], .awake);
                retries += 1;
                continue;
            }
            if (response.status == 401 and !renewed) if (api.renew) |r| {
                renewed = true;
                if (try r.renew(arena, token)) |fresh| {
                    headers = try apple.requestHeaders(arena, &buffer, fresh, api.user_token);
                    continue;
                }
            };
            if (api.diagnostic) |d| {
                const said = parse.apiError(arena, response.body) orelse parse.ApiError{};
                d.* = .{ .status = response.status, .code = said.code, .title = said.title, .detail = said.detail };
            }
            return statusError(response.status);
        }
    }
};

/// The error for a non-2xx HTTP status.
pub fn statusError(status: u16) Error {
    return switch (status) {
        401 => error.DeveloperTokenRejected,
        403 => error.SignInRequired,
        404 => error.NotFound,
        429 => error.RateLimited,
        500...599 => error.ServerError,
        else => error.BadRequest,
    };
}

fn catalogType(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .song => "songs",
        .album => "albums",
        .artist => "artists",
        .playlist => "playlists",
        .station => "stations",
        .music_video => "music-videos",
        .curator => null,
    };
}

fn libraryType(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .song => "library-songs",
        .album => "library-albums",
        .artist => "library-artists",
        .playlist => "library-playlists",
        .music_video => "library-music-videos",
        .station, .curator => null,
    };
}

/// The rating to delete to un-favorite `it`: the catalog one when known, else the library one.
/// Songs, albums, playlists and music videos have one.
fn ratingTarget(it: Item) ?struct { type: []const u8, id: []const u8 } {
    switch (it.kind) {
        .song, .album, .playlist, .music_video => {},
        .artist, .station, .curator => return null,
    }
    if (it.catalog_id) |id| return .{ .type = catalogType(it.kind).?, .id = id };
    if (it.library) return .{ .type = libraryType(it.kind).?, .id = it.id };
    return null;
}

/// The catalog resource when known, else the library one.
fn favoriteTarget(it: Item) ?struct { type: []const u8, id: []const u8 } {
    if (it.catalog_id) |id| if (catalogType(it.kind)) |t| return .{ .type = t, .id = id };
    if (it.library) if (libraryType(it.kind)) |t| return .{ .type = t, .id = it.id };
    return null;
}

/// A path and query, built with every value percent-encoded.
const Url = struct {
    arena: Allocator,
    bytes: std.ArrayList(u8),
    has_query: bool = false,

    fn init(arena: Allocator, start: []const u8) Allocator.Error!Url {
        var u: Url = .{ .arena = arena, .bytes = .empty };
        try u.lit(start);
        return u;
    }

    fn path(u: *const Url) []const u8 {
        return u.bytes.items;
    }

    fn lit(u: *Url, s: []const u8) Allocator.Error!void {
        try u.bytes.appendSlice(u.arena, s);
    }

    /// One path segment (a storefront, an id).
    fn segment(u: *Url, s: []const u8) Allocator.Error!void {
        try u.encode(s, false);
    }

    fn param(u: *Url, key: []const u8, value: []const u8) Allocator.Error!void {
        try u.startParam(key);
        try u.encode(value, true);
    }

    fn int(u: *Url, key_text: []const u8, value: u32) Allocator.Error!void {
        try u.startParam(key_text);
        try u.bytes.print(u.arena, "{d}", .{value});
    }

    /// `key=a,b,c`.
    fn list(u: *Url, key_text: []const u8, values: []const []const u8) Allocator.Error!void {
        try u.startParam(key_text);
        for (values, 0..) |v, i| {
            if (i > 0) try u.bytes.append(u.arena, ',');
            try u.encode(v, false);
        }
    }

    /// `ids[<type>]=a,b`.
    fn ids(u: *Url, resource_type: []const u8, values: []const []const u8) Allocator.Error!void {
        try u.list(try std.mem.concat(u.arena, u8, &.{ "ids[", resource_type, "]" }), values);
    }

    fn startParam(u: *Url, k: []const u8) Allocator.Error!void {
        try u.bytes.append(u.arena, if (u.has_query) '&' else '?');
        u.has_query = true;
        try u.encode(k, false);
        try u.bytes.append(u.arena, '=');
    }

    /// RFC 3986 unreserved characters stay; so do commas in values (Apple's list separator).
    fn encode(u: *Url, s: []const u8, allow_comma: bool) Allocator.Error!void {
        for (s) |c| {
            const keep = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or (allow_comma and c == ',');
            if (keep) try u.bytes.append(u.arena, c) else try u.bytes.print(u.arena, "%{X:0>2}", .{c});
        }
    }
};

const testing = std.testing;

fn fixture(comptime name: []const u8) []const u8 {
    return @embedFile("testdata/" ++ name);
}

/// Answers each request with the next scripted reply, after checking its method and path, and
/// records what was sent.
const Fake = struct {
    script: []const Reply,
    sent: std.ArrayList(Sent) = .empty,
    arena: Allocator,

    const Reply = struct {
        method: apple.Method = .GET,
        /// The path and query the request must have, exactly.
        path: []const u8,
        status: u16 = 200,
        body: []const u8 = "",
        fail: ?anyerror = null,
    };
    const Sent = struct { method: apple.Method, url: []const u8, body: ?[]const u8, headers: []const std.http.Header };

    fn init(arena: Allocator, script: []const Reply) Fake {
        return .{ .script = script, .arena = arena };
    }

    fn api(f: *Fake) Api {
        return .{
            .io = testing.io,
            .transport = .{ .ptr = f, .requestFn = request },
            .developer_token = "DEV",
            .user_token = "MUT",
            .storefront = "gb",
            .pacing = .immediate,
        };
    }

    fn request(ptr: *anyopaque, _: Allocator, method: apple.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) anyerror!Response {
        const f: *Fake = @ptrCast(@alignCast(ptr));
        const n = f.sent.items.len;
        try f.sent.append(f.arena, .{
            .method = method,
            .url = try f.arena.dupe(u8, url),
            .body = if (body) |b| try f.arena.dupe(u8, b) else null,
            .headers = try f.arena.dupe(std.http.Header, headers),
        });
        if (n >= f.script.len) {
            std.debug.print("unexpected request {t} {s}\n", .{ method, url });
            return error.TestUnexpectedRequest;
        }
        const reply = f.script[n];
        try testing.expectEqual(reply.method, method);
        try testing.expectEqualStrings(reply.path, url[apple.base_url.len..]);
        if (reply.fail) |e| return e;
        return .{ .status = reply.status, .body = reply.body };
    }

    fn done(f: *const Fake) !void {
        try testing.expectEqual(f.script.len, f.sent.items.len);
    }
};

const Response = apple.Response;

const FakeRenew = apple.FakeRenew;

test "a 401 asks once for a newer developer token; the request goes again with it, and the next starts with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .init(a, &.{
        .{ .path = "/v1/me/storefront", .status = 401 },
        .{ .path = "/v1/me/storefront", .body = fixture("storefront.json") },
        .{ .path = "/v1/me/storefront", .body = fixture("storefront.json") },
    });
    var renewer: FakeRenew = .{ .token = "NEW" };
    var api = fake.api();
    api.renew = renewer.renew();
    try testing.expectEqualStrings("gb", try api.storefrontOf(a));
    try testing.expectEqualStrings("DEV", renewer.refused.?);
    try testing.expectEqualStrings("Bearer NEW", fake.sent.items[1].headers[0].value);
    try testing.expectEqualStrings("http://localhost:47823", fake.sent.items[1].headers[1].value);
    try testing.expectEqualStrings("MUT", fake.sent.items[1].headers[2].value);
    // The same Api (a TUI job's) sends the newer token straight away next time.
    try testing.expectEqualStrings("gb", try api.storefrontOf(a));
    try fake.done();
    try testing.expectEqualStrings("Bearer NEW", fake.sent.items[2].headers[0].value);
    try testing.expectEqual(@as(usize, 1), renewer.calls);

    // A second 401 with the new token, or no newer token at all: rejected, asked only once.
    var twice: Fake = .init(a, &.{
        .{ .path = "/v1/me/storefront", .status = 401 },
        .{ .path = "/v1/me/storefront", .status = 401 },
    });
    var again = twice.api();
    renewer = .{ .token = "NEW" };
    again.renew = renewer.renew();
    try testing.expectError(error.DeveloperTokenRejected, again.storefrontOf(a));
    try twice.done();
    try testing.expectEqual(@as(usize, 1), renewer.calls);
    var nothing: FakeRenew = .{ .token = null };
    var once: Fake = .init(a, &.{.{ .path = "/v1/me/storefront", .status = 401 }});
    var stuck = once.api();
    stuck.renew = nothing.renew();
    try testing.expectError(error.DeveloperTokenRejected, stuck.storefrontOf(a));
    try once.done();
}

test "lookup and related: the playing song's details, a song's album and artist" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const album =
        \\{"data":[{"id":"1564530719","type":"albums","attributes":{"name":"Scaled and Icy","artistName":"twenty one pilots","playParams":{"id":"1564530719","kind":"album"}}}]}
    ;
    var fake: Fake = .init(a, &.{
        .{ .path = "/v1/catalog/gb/songs?ids=1561837008,42&extend=inFavorites", .body = album },
        .{ .path = "/v1/me/library/songs?ids=i.abc&extend=inFavorites", .body = "{\"data\":[]}" },
        .{ .path = "/v1/catalog/gb/songs/1561837008/albums", .body = album },
        .{ .path = "/v1/me/library/songs/i.abc/artists", .status = 404 },
        // A library song the catalog has no artist for: the library is asked next.
        .{ .path = "/v1/catalog/gb/songs/77/artists", .body = "{\"data\":[]}" },
        .{ .path = "/v1/me/library/songs/i.def/artists", .body = "{\"data\":[{\"id\":\"r.1\",\"type\":\"library-artists\",\"attributes\":{\"name\":\"TWENTYTHREE\"}}]}" },
    });
    const api = fake.api();
    const found = try api.lookup(a, .song, false, &.{ "1561837008", "42" });
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 0), (try api.lookup(a, .song, true, &.{"i.abc"})).len);
    const it: Item = .{ .kind = .song, .id = "1561837008", .catalog_id = "1561837008", .title = "Shy Away" };
    try testing.expectEqualStrings("Scaled and Icy", (try api.related(a, it, .albums)).?.title);
    const upload: Item = .{ .kind = .song, .id = "i.abc", .library = true, .title = "demo" };
    try testing.expect(try api.related(a, upload, .artists) == null);
    try testing.expectError(error.Unsupported, api.related(a, .{ .kind = .station, .id = "ra.1", .title = "x" }, .albums));
    // Neither in the catalog nor in the library: nothing to ask.
    try testing.expect(try api.related(a, .{ .kind = .song, .id = "x", .title = "x" }, .albums) == null);
    const twin: Item = .{ .kind = .song, .id = "i.def", .catalog_id = "77", .library = true, .title = "A Change of Weather" };
    try testing.expectEqualStrings("TWENTYTHREE", (try api.related(a, twin, .artists)).?.title);
    try fake.done();
}

test "requests carry both tokens, and the language when one is set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/me/storefront", .body = fixture("storefront.json") },
        .{ .path = "/v1/me/recent/radio-stations?limit=30&l=en-GB", .body = fixture("recent-stations.json") },
    });
    var api = fake.api();
    try testing.expectEqualStrings("gb", try api.storefrontOf(arena.allocator()));
    api.language = "en-GB";
    api.user_token = "";
    const p = try api.recentStations(arena.allocator());
    try fake.done();
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqual(@as(?u32, 30), p.next_offset);
    const first = fake.sent.items[0].headers;
    try testing.expectEqual(@as(usize, 3), first.len);
    try testing.expectEqualStrings("Bearer DEV", first[0].value);
    try testing.expectEqualStrings("Origin", first[1].name);
    try testing.expectEqualStrings("http://localhost:47823", first[1].value);
    try testing.expectEqualStrings("Music-User-Token", first[2].name);
    try testing.expectEqualStrings("MUT", first[2].value);
    try testing.expectEqual(@as(usize, 2), fake.sent.items[1].headers.len);
    try testing.expectEqualStrings("Origin", fake.sent.items[1].headers[1].name);
}

test "search: all five types with top results first, then a section's next page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/catalog/gb/search?term=twenty%20one%20pilots%20%26%20co&types=songs,albums,artists,playlists,stations&limit=25&with=topResults&extend=inFavorites", .body = fixture("search.json") },
        .{ .path = "/v1/catalog/gb/search?term=twenty&types=songs&limit=25&offset=25&extend=inFavorites", .body = fixture("search.json") },
        .{ .path = "/v1/me/library/search?term=shy&types=library-songs&limit=25&offset=25&extend=inFavorites", .body = fixture("library-search.json") },
        .{ .path = "/v1/me/library/search?term=shy&types=library-songs,library-albums,library-artists,library-playlists&limit=25&extend=inFavorites", .body = fixture("library-search.json") },
        .{ .path = "/v1/catalog/gb/search/suggestions?term=twenty%20on&kinds=terms&limit=10", .body = fixture("suggestions.json") },
    });
    const api = fake.api();
    const a = arena.allocator();
    const groups = try api.search(a, "twenty one pilots & co", 0);
    try testing.expectEqualStrings("topResults", groups[0].key);
    const more = try api.searchMore(a, "twenty", "songs", 25);
    try testing.expectEqual(@as(usize, 2), more.items.len);
    const lib_more = try api.searchMore(a, "shy", "library-songs", 25);
    try testing.expectEqualStrings("Shy", lib_more.items[0].title);
    try testing.expectEqual(@as(usize, 2), (try api.librarySearch(a, "shy")).len);
    try testing.expectEqual(@as(usize, 3), (try api.suggestions(a, "twenty on")).len);
    try testing.expectError(error.Unsupported, api.searchMore(a, "x", "topResults", 25));
    try fake.done();
}

test "library pages: 100 at a time with sort and favorites; artists bring their catalog twin" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/me/library/songs?limit=100&offset=0&sort=-dateAdded&extend=inFavorites", .body = fixture("library-songs.json") },
        .{ .path = "/v1/me/library/albums?limit=100&offset=200&sort=name&include=catalog&extend=inFavorites", .body = fixture("library-artist-albums.json") },
        .{ .path = "/v1/me/library/artists?limit=100&offset=0&sort=-name&include=catalog&extend=inFavorites", .body = fixture("library-artists.json") },
        .{ .path = "/v1/me/library/artists?limit=100&offset=0&sort=name&include=catalog&extend=inFavorites", .body = fixture("library-artists.json") },
        .{ .path = "/v1/me/library/playlists?limit=100&offset=100&sort=dateAdded&extend=inFavorites,tags", .body = fixture("library-playlists.json") },
    });
    const api = fake.api();
    const a = arena.allocator();
    const songs = try api.library(a, .song, 0, .date_added_desc);
    try testing.expectEqual(@as(?u32, 100), songs.next_offset);
    try testing.expectEqual(@as(?u32, 250), songs.total);
    _ = try api.library(a, .album, 200, .name);
    _ = try api.library(a, .artist, 0, .name_desc);
    const artists = try api.library(a, .artist, 0, .date_added);
    try testing.expect(artists.items[0].artwork != null);
    const playlists = try api.library(a, .playlist, 100, .date_added);
    try testing.expect(playlists.items[1].tags_favorited);
    try testing.expectError(error.Unsupported, api.library(a, .station, 0, .name));
    try fake.done();
}

test "recently added, played, played tracks and heavy rotation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/me/library/recently-added?limit=25&offset=25&include=catalog&extend=inFavorites", .body = fixture("recent-played.json") },
        .{ .path = "/v1/me/recent/played?limit=10&offset=0&extend=inFavorites", .body = fixture("recent-played.json") },
        .{ .path = "/v1/me/recent/played/tracks?limit=30&offset=30&extend=inFavorites", .body = fixture("catalog-album-tracks.json") },
        .{ .path = "/v1/me/history/heavy-rotation?limit=10&extend=inFavorites", .body = fixture("recent-played.json") },
    });
    const api = fake.api();
    const a = arena.allocator();
    _ = try api.recentlyAdded(a, 25);
    try testing.expectEqual(@as(usize, 3), (try api.recentlyPlayed(a, 0)).items.len);
    try testing.expectEqual(Kind.song, (try api.recentlyPlayedTracks(a, 30)).items[0].kind);
    _ = try api.heavyRotation(a);
    try fake.done();
}

test "recommendations are asked for again once when Apple answers none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/me/recommendations?limit=30&extend=inFavorites", .body = "{\"data\":[]}" },
        .{ .path = "/v1/me/recommendations?limit=30&extend=inFavorites", .body = fixture("recommendations.json") },
        .{ .path = "/v1/me/recommendations?limit=30&extend=inFavorites", .body = "{\"data\":[]}" },
        .{ .path = "/v1/me/recommendations?limit=30&extend=inFavorites", .body = "{\"data\":[]}" },
    });
    const api = fake.api();
    try testing.expectEqual(@as(usize, 2), (try api.recommendations(arena.allocator())).len);
    try testing.expectEqual(@as(usize, 0), (try api.recommendations(arena.allocator())).len);
    try fake.done();
}

test "charts and stations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/catalog/gb/charts?types=songs,albums,playlists&limit=50&with=dailyGlobalTopCharts", .body = fixture("charts.json") },
        .{ .path = "/v1/catalog/gb/stations?filter%5Bidentity%5D=personal", .status = 404, .body = fixture("error-403.json") },
        .{ .path = "/v1/catalog/gb/stations?filter%5Bfeatured%5D=apple-music-live-radio", .body = fixture("stations-live.json") },
        .{ .path = "/v1/me/recent/radio-stations?limit=30", .body = fixture("recent-stations.json") },
    });
    const api = fake.api();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 4), (try api.charts(a)).len);
    const groups = try api.stations(a);
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("Live Radio", groups[0].title);
    try testing.expectEqualStrings("Recently Played Stations", groups[1].title);
    try fake.done();
}

test "tracks: catalog and library albums and playlists; albums in disc order; empty library playlists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/me/library/albums/l.AAAA0001/tracks?limit=100&offset=0&extend=inFavorites", .body = fixture("library-album-tracks.json") },
        .{ .path = "/v1/catalog/gb/albums/1560650222/tracks?limit=100&offset=0&extend=inFavorites", .body = fixture("catalog-album-tracks.json") },
        .{ .path = "/v1/catalog/gb/playlists/pl.pm-AAAA0001/tracks?limit=100&offset=100&extend=inFavorites", .body = fixture("catalog-album-tracks.json") },
        .{ .path = "/v1/me/library/playlists/p.AAAA0002/tracks?limit=100&offset=0&extend=inFavorites", .body = fixture("library-playlist-tracks.json") },
        .{ .path = "/v1/me/library/playlists/p.EMPTY/tracks?limit=100&offset=0&extend=inFavorites", .status = 404 },
        .{ .path = "/v1/catalog/gb/playlists/pl.gone/tracks?limit=100&offset=0&extend=inFavorites", .status = 404 },
    });
    const api = fake.api();
    const a = arena.allocator();
    const album = try api.tracks(a, .{ .kind = .album, .id = "l.AAAA0001", .library = true, .title = "" }, 0);
    try testing.expectEqualStrings("Opener", album.items[0].title);
    try testing.expectEqualStrings("Bonus", album.items[2].title);
    _ = try api.tracks(a, .{ .kind = .album, .id = "1560650222", .title = "" }, 0);
    _ = try api.tracks(a, .{ .kind = .playlist, .id = "pl.pm-AAAA0001", .title = "" }, 100);
    // Playlists keep their own order.
    const favorites = try api.tracks(a, .{ .kind = .playlist, .id = "p.AAAA0002", .library = true, .title = "" }, 0);
    try testing.expectEqualStrings("Zebra", favorites.items[0].title);
    try testing.expectEqual(@as(?u32, 100), favorites.next_offset);
    try testing.expectEqual(@as(?u32, 414), favorites.total);
    const empty = try api.tracks(a, .{ .kind = .playlist, .id = "p.EMPTY", .library = true, .title = "" }, 0);
    try testing.expectEqual(@as(usize, 0), empty.items.len);
    try testing.expectError(error.NotFound, api.tracks(a, .{ .kind = .playlist, .id = "pl.gone", .title = "" }, 0));
    try testing.expectError(error.Unsupported, api.tracks(a, .{ .kind = .station, .id = "ra.1", .title = "" }, 0));
    try fake.done();
}

test "artists: catalog views; a library artist adds its library albums and finds its catalog twin" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const views_path = "/v1/catalog/gb/artists/349736311?views=latest-release,top-songs,full-albums,singles,appears-on-albums,featured-playlists,similar-artists&extend=inFavorites";
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = views_path, .body = fixture("artist-views.json") },
        .{ .path = "/v1/me/library/artists/r.AAAA0002/albums?limit=100&include=catalog&extend=inFavorites", .body = fixture("library-artist-albums.json") },
        .{ .path = "/v1/me/library/artists/r.AAAA0002/catalog", .body = "{\"data\":[{\"id\":\"349736311\",\"type\":\"artists\",\"attributes\":{\"name\":\"x\"}}]}" },
        .{ .path = views_path, .body = fixture("artist-views.json") },
        .{ .path = "/v1/me/library/artists/r.AAAA0003/albums?limit=100&include=catalog&extend=inFavorites", .body = fixture("library-artist-albums.json") },
        .{ .path = "/v1/me/library/artists/r.AAAA0003/catalog", .status = 404 },
        .{ .path = "/v1/me/library/artists/r.AAAA0004/albums?limit=100&include=catalog&extend=inFavorites", .body = fixture("library-artist-albums.json") },
        .{ .path = "/v1/catalog/gb/artists/1?views=latest-release,top-songs,full-albums,singles,appears-on-albums,featured-playlists,similar-artists&extend=inFavorites", .status = 404 },
        .{ .path = "/v1/catalog/gb/artists/1?views=latest-release,top-songs,full-albums,singles,appears-on-albums,featured-playlists,similar-artists&extend=inFavorites", .status = 404 },
        .{ .path = "/v1/catalog/gb/artists/349736311/view/top-songs?limit=25&offset=10&extend=inFavorites", .body = fixture("catalog-album-tracks.json") },
    });
    const api = fake.api();
    const a = arena.allocator();
    const catalog = try api.artist(a, .{ .kind = .artist, .id = "349736311", .catalog_id = "349736311", .title = "" });
    try testing.expectEqual(@as(usize, 6), catalog.len);
    const mine = try api.artist(a, .{ .kind = .artist, .id = "r.AAAA0002", .library = true, .title = "" });
    try testing.expectEqual(@as(usize, 7), mine.len);
    try testing.expectEqualStrings("In Your Library", mine[0].title);
    try testing.expectEqualStrings("Album One", mine[0].items[0].title);
    const unmatched = try api.artist(a, .{ .kind = .artist, .id = "r.AAAA0003", .library = true, .title = "" });
    try testing.expectEqual(@as(usize, 1), unmatched.len);
    // A catalog id Apple doesn't know in this storefront: the library albums still show.
    const elsewhere = try api.artist(a, .{ .kind = .artist, .id = "r.AAAA0004", .catalog_id = "1", .library = true, .title = "" });
    try testing.expectEqual(@as(usize, 1), elsewhere.len);
    try testing.expectError(error.NotFound, api.artist(a, .{ .kind = .artist, .id = "1", .catalog_id = "1", .title = "" }));
    _ = try api.artistView(a, "349736311", "top-songs", 10);
    try fake.done();
}

test "a 429 is retried after each wait, then becomes RateLimited" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path = "/v1/me/history/heavy-rotation?limit=10&extend=inFavorites";
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = path, .status = 429 },
        .{ .path = path, .status = 429 },
        .{ .path = path, .body = fixture("recent-played.json") },
        .{ .path = path, .status = 429 },
        .{ .path = path, .status = 429 },
        .{ .path = path, .status = 429 },
        .{ .path = path, .status = 429 },
    });
    const api = fake.api();
    try testing.expectEqual(@as(usize, 3), (try api.heavyRotation(arena.allocator())).items.len);
    try testing.expectError(error.RateLimited, api.heavyRotation(arena.allocator()));
    try fake.done();
}

test "HTTP statuses and transport failures map to errors, with Apple's words in the diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path = "/v1/me/storefront";
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = path, .status = 401 },
        .{ .path = path, .status = 403, .body = fixture("error-403.json") },
        .{ .path = path, .status = 404 },
        .{ .path = path, .status = 400, .body = fixture("error-400.json") },
        .{ .path = path, .status = 503 },
        .{ .path = path, .fail = error.ConnectionRefused },
        .{ .path = path, .fail = error.OutOfMemory },
        .{ .path = path, .body = "not json" },
    });
    var diagnostic: Diagnostic = .{};
    var api = fake.api();
    api.diagnostic = &diagnostic;
    const a = arena.allocator();
    try testing.expectError(error.DeveloperTokenRejected, api.storefrontOf(a));
    try testing.expectEqual(@as(u16, 401), diagnostic.status);
    try testing.expectError(error.SignInRequired, api.storefrontOf(a));
    try testing.expectEqualStrings("40300", diagnostic.code);
    try testing.expectError(error.NotFound, api.storefrontOf(a));
    try testing.expectError(error.BadRequest, api.storefrontOf(a));
    try testing.expectEqualStrings("Invalid Parameter Value", diagnostic.title);
    try testing.expectError(error.ServerError, api.storefrontOf(a));
    try testing.expectError(error.Network, api.storefrontOf(a));
    try testing.expectError(error.OutOfMemory, api.storefrontOf(a));
    try testing.expectError(error.BadResponse, api.storefrontOf(a));
    try fake.done();
    try testing.expect(describe(error.SignInRequired).len > 0);
}

test "the diagnostic describes only the last request: a later one clears it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const path = "/v1/me/storefront";
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = path, .status = 400, .body = fixture("error-400.json") },
        .{ .path = path, .body = fixture("storefront.json") },
        .{ .path = path, .status = 404, .body = fixture("error-403.json") },
        .{ .path = path, .fail = error.ConnectionRefused },
    });
    var diagnostic: Diagnostic = .{};
    var api = fake.api();
    api.diagnostic = &diagnostic;
    const a = arena.allocator();
    try testing.expectError(error.BadRequest, api.storefrontOf(a));
    try testing.expectEqual(@as(u16, 400), diagnostic.status);
    _ = try api.storefrontOf(a);
    try testing.expectEqual(@as(u16, 0), diagnostic.status);
    try testing.expectEqualStrings("", diagnostic.title);
    try testing.expectError(error.NotFound, api.storefrontOf(a));
    try testing.expectEqual(error.NotFound, statusError(diagnostic.status));
    try testing.expectError(error.Network, api.storefrontOf(a));
    try testing.expectEqual(@as(u16, 0), diagnostic.status);
    try fake.done();
}

test "am's own refusals are Unsupported and send nothing; BadRequest is only Apple's answer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .POST, .path = "/v1/me/favorites?ids%5Bsongs%5D=1", .status = 400, .body = fixture("error-400.json") },
    });
    var diagnostic: Diagnostic = .{};
    var api = fake.api();
    api.diagnostic = &diagnostic;
    const a = arena.allocator();
    // A job that lets Apple's 400 pass, then refuses something itself.
    try testing.expectError(error.BadRequest, api.addFavorite(a, .{ .kind = .song, .id = "1", .catalog_id = "1", .title = "" }));
    try testing.expectEqualStrings("Invalid Parameter Value", diagnostic.title);
    try testing.expectError(error.Unsupported, api.addFavorite(a, .{ .kind = .curator, .id = "2", .catalog_id = "2", .title = "" }));
    try testing.expectError(error.Unsupported, api.lookup(a, .curator, false, &.{"3"}));
    try testing.expectError(error.Unsupported, api.addToPlaylist(a, "p.1", &.{.{ .kind = .album, .id = "4", .title = "" }}));
    try fake.done();
}

test "favorite: POST /v1/me/favorites with the catalog id, else the library one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .POST, .path = "/v1/me/favorites?ids%5Bsongs%5D=1000000001", .status = 202 },
        .{ .method = .POST, .path = "/v1/me/favorites?ids%5Blibrary-playlists%5D=p.AAAA0001", .status = 202 },
        .{ .method = .POST, .path = "/v1/me/favorites?ids%5Bplaylists%5D=pl.u-AAAA0004", .status = 202 },
    });
    const api = fake.api();
    const a = arena.allocator();
    try api.addFavorite(a, .{ .kind = .song, .id = "i.AAAA0001", .catalog_id = "1000000001", .library = true, .title = "" });
    try api.addFavorite(a, .{ .kind = .playlist, .id = "p.AAAA0001", .library = true, .title = "" });
    try api.addFavorite(a, .{ .kind = .playlist, .id = "p.AAAA0004", .catalog_id = "pl.u-AAAA0004", .library = true, .title = "" });
    try testing.expectError(error.Unsupported, api.addFavorite(a, .{ .kind = .curator, .id = "1", .catalog_id = "1", .title = "" }));
    try fake.done();
    for (fake.sent.items) |s| try testing.expectEqual(@as(?[]const u8, null), s.body);
}

test "un-favorite: DELETE the rating (catalog, else library), then Apple's inFavorites decides" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .DELETE, .path = "/v1/me/ratings/songs/1561837008", .status = 204 },
        // A library song is read back as the library item, as its row is.
        .{ .path = "/v1/me/library/songs?ids=i.AAAA0001&extend=inFavorites", .body = "{\"data\":[{\"id\":\"i.AAAA0001\",\"type\":\"library-songs\",\"attributes\":{\"name\":\"x\",\"inFavorites\":false}}]}" },
        // Still a favorite after the delete.
        .{ .method = .DELETE, .path = "/v1/me/ratings/songs/1117028240", .status = 204 },
        .{ .path = "/v1/catalog/gb/songs?ids=1117028240&extend=inFavorites", .body = fixture("favorites-lookup.json") },
        // A library-only playlist with no rating left to delete.
        .{ .method = .DELETE, .path = "/v1/me/ratings/library-playlists/p.AAAA0001", .status = 404 },
        .{ .path = "/v1/me/library/playlists?ids=p.AAAA0001&extend=inFavorites", .body = "{\"data\":[{\"id\":\"p.AAAA0001\",\"type\":\"library-playlists\",\"attributes\":{\"name\":\"Mine\",\"inFavorites\":false}}]}" },
        .{ .method = .DELETE, .path = "/v1/me/ratings/albums/1560650222", .status = 400 },
    });
    const api = fake.api();
    const a = arena.allocator();
    try testing.expectEqual(Api.Unfavorited.removed, try api.removeFavorite(a, .{ .kind = .song, .id = "i.AAAA0001", .catalog_id = "1561837008", .library = true, .title = "", .favorited = true }));
    try testing.expectEqual(Api.Unfavorited.still_favorite, try api.removeFavorite(a, .{ .kind = .song, .id = "1117028240", .catalog_id = "1117028240", .title = "" }));
    try testing.expectEqual(Api.Unfavorited.removed, try api.removeFavorite(a, .{ .kind = .playlist, .id = "p.AAAA0001", .library = true, .title = "" }));
    try testing.expectError(error.BadRequest, api.removeFavorite(a, .{ .kind = .album, .id = "1560650222", .catalog_id = "1560650222", .title = "" }));
    // Artists have no rating: nothing is sent, only the Music app can remove them.
    try testing.expectEqual(Api.Unfavorited.still_favorite, try api.removeFavorite(a, .{ .kind = .artist, .id = "1", .catalog_id = "1", .title = "" }));
    try fake.done();
    for (fake.sent.items) |s| try testing.expect(!std.mem.startsWith(u8, s.url, "https://api.music.apple.com/v1/me/favorites"));
}

test "un-favorite: each type's rating route, library ones only without a catalog id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const none = "{\"data\":[]}";
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .DELETE, .path = "/v1/me/ratings/albums/1560650222", .status = 204 },
        .{ .path = "/v1/me/library/albums?ids=l.AAAA0001&extend=inFavorites", .body = none },
        .{ .method = .DELETE, .path = "/v1/me/ratings/library-albums/l.AAAA0002", .status = 204 },
        .{ .path = "/v1/me/library/albums?ids=l.AAAA0002&extend=inFavorites", .body = none },
        // A shared library playlist: its globalId is the catalog id.
        .{ .method = .DELETE, .path = "/v1/me/ratings/playlists/pl.u-AAAA0004", .status = 204 },
        .{ .path = "/v1/me/library/playlists?ids=p.AAAA0004&extend=inFavorites", .body = none },
        .{ .method = .DELETE, .path = "/v1/me/ratings/music-videos/1500000001", .status = 204 },
        .{ .path = "/v1/catalog/gb/music-videos?ids=1500000001&extend=inFavorites", .body = none },
        .{ .method = .DELETE, .path = "/v1/me/ratings/library-songs/i.UPLOAD", .status = 204 },
        .{ .path = "/v1/me/library/songs?ids=i.UPLOAD&extend=inFavorites", .body = none },
    });
    const api = fake.api();
    const a = arena.allocator();
    const removed = Api.Unfavorited.removed;
    try testing.expectEqual(removed, try api.removeFavorite(a, .{ .kind = .album, .id = "l.AAAA0001", .catalog_id = "1560650222", .library = true, .title = "" }));
    try testing.expectEqual(removed, try api.removeFavorite(a, .{ .kind = .album, .id = "l.AAAA0002", .library = true, .title = "" }));
    try testing.expectEqual(removed, try api.removeFavorite(a, .{ .kind = .playlist, .id = "p.AAAA0004", .catalog_id = "pl.u-AAAA0004", .library = true, .title = "" }));
    try testing.expectEqual(removed, try api.removeFavorite(a, .{ .kind = .music_video, .id = "1500000001", .catalog_id = "1500000001", .title = "" }));
    try testing.expectEqual(removed, try api.removeFavorite(a, .{ .kind = .song, .id = "i.UPLOAD", .library = true, .title = "" }));
    try fake.done();
    for (fake.sent.items) |s| try testing.expectEqual(@as(?[]const u8, null), s.body);
}

test "un-favorite: a read-back that fails after a deleted rating is removed; after a 404 it's the error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .DELETE, .path = "/v1/me/ratings/songs/1561837008", .status = 204 },
        .{ .path = "/v1/catalog/gb/songs?ids=1561837008&extend=inFavorites", .status = 503 },
        .{ .method = .DELETE, .path = "/v1/me/ratings/songs/1561837008", .status = 404 },
        .{ .path = "/v1/catalog/gb/songs?ids=1561837008&extend=inFavorites", .status = 503 },
        .{ .method = .DELETE, .path = "/v1/me/ratings/songs/1561837008", .status = 204 },
        .{ .path = "/v1/catalog/gb/songs?ids=1561837008&extend=inFavorites", .fail = error.Canceled },
    });
    const api = fake.api();
    const a = arena.allocator();
    const song: Item = .{ .kind = .song, .id = "1561837008", .catalog_id = "1561837008", .title = "" };
    try testing.expectEqual(Api.Unfavorited.removed, try api.removeFavorite(a, song));
    try testing.expectError(error.ServerError, api.removeFavorite(a, song));
    try testing.expectError(error.Canceled, api.removeFavorite(a, song));
    try fake.done();
}

test "favorite state is looked up for the items that lack it, catalog and library apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/catalog/gb/songs?ids=1561837008,1117028240&extend=inFavorites", .body = fixture("favorites-lookup.json") },
        .{ .path = "/v1/me/library/songs?ids=i.AAAA0001&extend=inFavorites", .body = fixture("library-songs.json") },
    });
    const api = fake.api();
    var list = [_]Item{
        .{ .kind = .song, .id = "1561837008", .catalog_id = "1561837008", .title = "" },
        .{ .kind = .song, .id = "1117028240", .catalog_id = "1117028240", .title = "" },
        .{ .kind = .song, .id = "i.AAAA0001", .catalog_id = "1000000001", .library = true, .title = "" },
        .{ .kind = .song, .id = "42", .catalog_id = "42", .title = "", .favorited = false },
        .{ .kind = .station, .id = "ra.1", .catalog_id = "ra.1", .title = "" },
    };
    try api.favoritedState(arena.allocator(), &list);
    try fake.done();
    try testing.expectEqual(@as(?bool, false), list[0].favorited);
    try testing.expectEqual(@as(?bool, true), list[1].favorited);
    try testing.expectEqual(@as(?bool, true), list[2].favorited);
    try testing.expectEqual(@as(?bool, null), list[4].favorited);
}

test "add to library: POST /v1/me/library with the catalog id; library items and artists send nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .POST, .path = "/v1/me/library?ids%5Balbums%5D=1560650222", .status = 202 },
    });
    const api = fake.api();
    const a = arena.allocator();
    try api.addToLibrary(a, .{ .kind = .album, .id = "1560650222", .catalog_id = "1560650222", .title = "" });
    try api.addToLibrary(a, .{ .kind = .album, .id = "l.AAAA0001", .library = true, .title = "" });
    try testing.expectError(error.Unsupported, api.addToLibrary(a, .{ .kind = .artist, .id = "1", .catalog_id = "1", .title = "" }));
    try fake.done();
}

test "add to playlist: POST the tracks as JSON, library songs as library-songs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .method = .POST, .path = "/v1/me/library/playlists/p.AAAA0001/tracks", .status = 204 },
    });
    const api = fake.api();
    const a = arena.allocator();
    try api.addToPlaylist(a, "p.AAAA0001", &.{
        .{ .kind = .song, .id = "1561837008", .catalog_id = "1561837008", .title = "" },
        .{ .kind = .song, .id = "i.AAAA0002", .library = true, .title = "" },
    });
    try testing.expectEqualStrings(
        \\{"data":[{"id":"1561837008","type":"songs"},{"id":"i.AAAA0002","type":"library-songs"}]}
    , fake.sent.items[0].body.?);
    try testing.expectError(error.Unsupported, api.addToPlaylist(a, "p.AAAA0001", &.{.{ .kind = .album, .id = "1", .title = "" }}));
    // Nothing is sent when any item can't go in, even past the first 100.
    var many: [150]Item = @splat(.{ .kind = .song, .id = "1561837008", .catalog_id = "1561837008", .title = "" });
    many[120].kind = .album;
    try testing.expectError(error.Unsupported, api.addToPlaylist(a, "p.AAAA0001", &many));
    try api.addToPlaylist(a, "p.AAAA0001", &.{});
    try fake.done();
}

test "the Favorite Songs playlist and the editable playlists come from walking the library playlists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const last_page = "{\"data\":[]}";
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/me/library/playlists?limit=100&offset=0&extend%5Blibrary-playlists%5D=tags", .body = fixture("library-playlists.json") },
        .{ .path = "/v1/me/library/playlists?limit=100&offset=0&extend%5Blibrary-playlists%5D=tags", .body = "{\"data\":[],\"next\":\"/v1/me/library/playlists?offset=100\"}" },
        .{ .path = "/v1/me/library/playlists?limit=100&offset=100&extend%5Blibrary-playlists%5D=tags", .body = last_page },
        .{ .path = "/v1/me/library/playlists?limit=100&offset=0&sort=name&extend=inFavorites,tags", .body = fixture("library-playlists.json") },
        .{ .path = "/v1/me/library/playlists?limit=100&offset=100&sort=name&extend=inFavorites,tags", .body = last_page },
    });
    const api = fake.api();
    const a = arena.allocator();
    try testing.expectEqualStrings("p.AAAA0002", (try api.favoriteSongsPlaylist(a)).?.id);
    try testing.expectEqual(@as(?Item, null), try api.favoriteSongsPlaylist(a));
    const editable = try api.editablePlaylists(a);
    try testing.expectEqual(@as(usize, 2), editable.items.len);
    try testing.expectEqualStrings("Road Trip", editable.items[0].title);
    try testing.expectEqualStrings("Shared Mix", editable.items[1].title);
    try fake.done();
}

test "a song's station, or none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: Fake = .init(arena.allocator(), &.{
        .{ .path = "/v1/catalog/gb/songs/1561837008/station", .body = fixture("song-station.json") },
        .{ .path = "/v1/catalog/gb/songs/1/station", .status = 404 },
    });
    const api = fake.api();
    const a = arena.allocator();
    const station = (try api.songStation(a, .{ .kind = .song, .id = "i.x", .catalog_id = "1561837008", .library = true, .title = "" })).?;
    try testing.expectEqualStrings("ra.1561837008", station.id);
    try testing.expectEqual(Kind.station, station.kind);
    try testing.expectEqual(@as(?Item, null), try api.songStation(a, .{ .kind = .song, .id = "1", .catalog_id = "1", .title = "" }));
    try testing.expectEqual(@as(?Item, null), try api.songStation(a, .{ .kind = .song, .id = "i.upload", .library = true, .title = "" }));
    try fake.done();
}

test "the limiter lets per_second requests through per window, then spaces them" {
    var limiter: Limiter = .{ .per_second = 2, .window = .fromMilliseconds(80) };
    const io = testing.io;
    const start: Io.Timestamp = .now(io, .awake);
    for (0..5) |_| try limiter.wait(io);
    const took = start.durationTo(.now(io, .awake));
    // Two at once, two after one window, the fifth after two.
    try testing.expect(took.nanoseconds >= 2 * 80 * std.time.ns_per_ms);
    try testing.expect(took.nanoseconds < 2 * 1000 * std.time.ns_per_ms);
}

test "concurrent callers share the limiter safely" {
    var limiter: Limiter = .{ .per_second = 4, .window = .fromMilliseconds(20) };
    const io = testing.io;
    var group: Io.Group = .init;
    for (0..8) |_| try group.concurrent(io, Limiter.wait, .{ &limiter, io });
    try group.await(io);
}
