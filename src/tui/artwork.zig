//! Artwork for the TUI: the PNG URL for an Apple Music artwork template, the download from
//! mzstatic, and a small thread-safe cache of downloaded files.
const std = @import("std");
const png = @import("png.zig");
const graphics = @import("graphics.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const UrlError = error{BadUrl} || Allocator.Error;

/// The URL of the artwork as a `w`×`h` PNG. `template` is an `artwork.url` from the API:
/// `…/<file>/{w}x{h}<crop>.jpg[?query]`, or a ready-made URL such as generated playlist art
/// (`…/gen/1200x1200AM.PDCXS11.jpg?c1=…`). Only the last path segment changes: `{w}`/`{h}` (or
/// a leading `<n>x<n>`) become the size, and its extension becomes `.png`. The query stays as
/// is: composite art carries other images' `.jpg` names there. `http://` becomes `https://`.
pub fn pngUrl(arena: Allocator, template: []const u8, w: u32, h: u32) UrlError![]const u8 {
    const https = "https://";
    const rest = if (std.ascii.startsWithIgnoreCase(template, https))
        template[https.len..]
    else if (std.ascii.startsWithIgnoreCase(template, "http://"))
        template["http://".len..]
    else
        return error.BadUrl;
    const query_at = std.mem.findScalar(u8, rest, '?') orelse rest.len;
    const path = rest[0..query_at];
    const query = rest[query_at..];
    const slash = std.mem.findScalarLast(u8, path, '/') orelse return error.BadUrl;
    if (slash == 0) return error.BadUrl;
    const dir = path[0 .. slash + 1];
    var segment = path[slash + 1 ..];
    if (segment.len == 0) return error.BadUrl;

    var size_buf: [24]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ w, h }) catch unreachable;
    var w_buf: [10]u8 = undefined;
    var h_buf: [10]u8 = undefined;
    const w_text = std.fmt.bufPrint(&w_buf, "{d}", .{w}) catch unreachable;
    const h_text = std.fmt.bufPrint(&h_buf, "{d}", .{h}) catch unreachable;

    if (std.mem.find(u8, segment, "{w}") != null or std.mem.find(u8, segment, "{h}") != null) {
        segment = try std.mem.replaceOwned(u8, arena, segment, "{w}", w_text);
        segment = try std.mem.replaceOwned(u8, arena, segment, "{h}", h_text);
    } else if (leadingSize(segment)) |len| {
        segment = try std.mem.concat(arena, u8, &.{ size, segment[len..] });
    }
    segment = try std.mem.replaceOwned(u8, arena, segment, "{f}", "png");

    if (std.mem.findScalarLast(u8, segment, '.')) |dot| {
        const ext = segment[dot + 1 ..];
        for ([_][]const u8{ "jpg", "jpeg", "webp", "heic" }) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) {
                segment = try std.mem.concat(arena, u8, &.{ segment[0 .. dot + 1], "png" });
                break;
            }
        }
    }
    return std.mem.concat(arena, u8, &.{ https, dir, segment, query });
}

/// The length of a leading `<digits>x<digits>`, if `segment` starts with one.
fn leadingSize(segment: []const u8) ?usize {
    var i: usize = 0;
    while (i < segment.len and std.ascii.isDigit(segment[i])) i += 1;
    if (i == 0 or i >= segment.len or segment[i] != 'x') return null;
    const second = i + 1;
    i = second;
    while (i < segment.len and std.ascii.isDigit(segment[i])) i += 1;
    return if (i == second) null else i;
}

/// The largest artwork file `fetch` accepts. A 600×600 PNG is about 0.8 MB.
pub const max_bytes = 2 * 1024 * 1024;

pub const FetchError = error{
    /// The URL, or a redirect, isn't https.
    NotHttps,
    /// Anything but 200.
    BadStatus,
    /// Over `max_bytes`.
    TooLarge,
    /// The body isn't a PNG (a JPEG, an error page).
    NotPng,
    /// DNS, TLS, connection or protocol failure.
    Network,
} || Allocator.Error || Io.Cancelable;

/// Downloads an artwork PNG with a fresh client. Caller owns the bytes (free with `gpa`).
pub fn fetch(io: Io, gpa: Allocator, url: []const u8) FetchError![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    return fetchWith(&client, gpa, url);
}

/// Like `fetch`, on a client that the caller keeps (it reuses connections and the CA bundle;
/// `std.http.Client` is thread-safe). No auth headers: mzstatic is public. Redirects are
/// followed (up to 3), but only to https.
pub fn fetchWith(client: *std.http.Client, gpa: Allocator, url: []const u8) FetchError![]u8 {
    return download(client, gpa, url, "https") catch |e| switch (e) {
        error.NotHttps, error.BadStatus, error.TooLarge, error.NotPng, error.OutOfMemory, error.Canceled => |x| x,
        else => error.Network,
    };
}

const max_redirects = 3;

/// `fetchWith` for URLs (and redirects) of `scheme` only; tests use "http" against a local server.
fn download(client: *std.http.Client, gpa: Allocator, url: []const u8, scheme: []const u8) ![]u8 {
    var uri = try std.Uri.parse(url);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, scheme)) return error.NotHttps;
    // Redirect targets alternate between the two halves: the next one resolves against the last.
    var location_bufs: [2][8 * 1024]u8 = undefined;
    var redirects: usize = 0;
    while (true) : (redirects += 1) {
        var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status.class() == .redirect) {
            if (redirects == max_redirects) return error.TooManyHttpRedirects;
            const location = response.head.location orelse return error.BadStatus;
            var aux: []u8 = &location_bufs[redirects % 2];
            if (location.len > aux.len) return error.HttpRedirectLocationOversize;
            @memcpy(aux[0..location.len], location);
            uri = try uri.resolveInPlace(location.len, &aux);
            if (!std.ascii.eqlIgnoreCase(uri.scheme, scheme)) return error.NotHttps;
            continue; // `req.deinit` skips the redirect's body
        }
        if (response.head.status != .ok) return error.BadStatus;
        return readPng(&response, gpa);
    }
}

fn readPng(response: *std.http.Client.Response, gpa: Allocator) ![]u8 {
    if (response.head.content_length) |n| if (n > max_bytes) return error.TooLarge;
    const decompress_buf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.Network,
    };
    defer gpa.free(decompress_buf);
    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const body = reader.allocRemaining(gpa, .limited(max_bytes)) catch |e| switch (e) {
        error.StreamTooLong => return error.TooLarge,
        // A bad compressed body leaves no transfer error behind (std's own `fetch` would panic).
        error.ReadFailed => return response.bodyErr() orelse error.Network,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer gpa.free(body);
    if (!std.mem.startsWith(u8, body, png.signature)) return error.NotPng;
    return body;
}

/// Downloaded artwork files by URL (the `pngUrl` result, so the size is part of the key), with
/// least-recently-used eviction.
///
/// Threads: `request`, `get`, `image`, `markTransmitted`, `forgetTransmitted`, `popEvicted`
/// and `deinit` belong to the UI thread; `finish`, `fail` and `load` may run on any thread.
/// `gpa` must be thread-safe, and every fetch job must be done before `deinit`.
/// Slices in a `View` and images from `image` stay valid until the UI thread's next `request`,
/// or its next `image` for the same URL (a file that doesn't decode is dropped).
///
/// Keep the artwork on screen at once well under `capacity`: past it, every frame evicts and
/// refetches.
pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    fetcher: Fetcher,
    capacity: usize = 64,
    /// A failed URL is fetched again when requested this long after the failure.
    retry_after: Io.Duration = .fromSeconds(60),

    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    clock: u64 = 0,
    /// Kitty ids of evicted entries that were transmitted; the app frees them (`graphics.free`).
    evicted: std.ArrayList(u32) = .empty,

    /// How the cache asks the app to download a URL: `start` queues a job (it must not block)
    /// that later calls `finish` or `fail` (`load` does both). `url` is valid only during the
    /// call. `start` may call `finish` before returning.
    pub const Fetcher = struct {
        ctx: *anyopaque,
        start: *const fn (ctx: *anyopaque, url: []const u8) void,
    };

    pub const View = union(enum) {
        loading,
        failed,
        ready: Ready,
    };

    pub const Ready = struct {
        /// The PNG file, for `graphics.transmitPng`.
        png: []const u8,
        /// The kitty image id, unique among the cache's entries and the ids waiting in `evicted`.
        id: u32,
        /// Set by `markTransmitted`: the terminal holds the image under `id`.
        transmitted: bool,
    };

    const Entry = struct {
        url: []u8,
        state: enum { loading, ready, failed },
        file: []u8 = &.{},
        image: ?png.Image = null,
        id: u32,
        transmitted: bool = false,
        used: u64,
        failed_at: Io.Clock.Timestamp = undefined,

        fn view(e: *const Entry) View {
            return switch (e.state) {
                .loading => .loading,
                .failed => .failed,
                .ready => .{ .ready = .{ .png = e.file, .id = e.id, .transmitted = e.transmitted } },
            };
        }

        fn freeData(e: *Entry, gpa: Allocator) void {
            gpa.free(e.file);
            e.file = &.{};
            if (e.image) |img| img.deinit(gpa);
            e.image = null;
        }
    };

    pub fn init(gpa: Allocator, io: Io, fetcher: Fetcher) Cache {
        return .{ .gpa = gpa, .io = io, .fetcher = fetcher };
    }

    pub fn deinit(c: *Cache) void {
        for (c.entries.items) |*e| {
            e.freeData(c.gpa);
            c.gpa.free(e.url);
        }
        c.entries.deinit(c.gpa);
        c.evicted.deinit(c.gpa);
    }

    /// The artwork at `url`, starting its download when it isn't cached (or failed more than
    /// `retry_after` ago). Evicts the least recently used entry when full.
    pub fn request(c: *Cache, url: []const u8) Allocator.Error!View {
        const start, const view = blk: {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            if (c.find(url)) |e| {
                e.used = c.tick();
                if (e.state == .failed and e.failed_at.untilNow(c.io).raw.nanoseconds >= c.retry_after.nanoseconds) {
                    e.state = .loading;
                    break :blk .{ e.url, e.view() };
                }
                break :blk .{ null, e.view() };
            }
            try c.entries.ensureUnusedCapacity(c.gpa, 1);
            try c.evicted.ensureUnusedCapacity(c.gpa, 1);
            const owned = try c.gpa.dupe(u8, url);
            if (c.entries.items.len >= @max(1, c.capacity)) c.evictOldest();
            c.entries.appendAssumeCapacity(.{ .url = owned, .state = .loading, .id = c.freeId(url), .used = c.tick() });
            break :blk .{ owned, View.loading };
        };
        // Outside the lock: the fetcher may finish at once. Only this thread frees urls.
        if (start) |u| c.fetcher.start(c.fetcher.ctx, u);
        return view;
    }

    /// The artwork at `url` if cached, without starting a download.
    pub fn get(c: *Cache, url: []const u8) ?View {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const e = c.find(url) orelse return null;
        e.used = c.tick();
        return e.view();
    }

    /// Stores the downloaded file for `url`; takes ownership of `file` (allocated with the
    /// cache's `gpa`). Dropped when the entry is gone or already done.
    pub fn finish(c: *Cache, url: []const u8, file: []u8) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const e = c.find(url) orelse return c.gpa.free(file);
        if (e.state != .loading) return c.gpa.free(file);
        e.state = .ready;
        e.file = file;
    }

    pub fn fail(c: *Cache, url: []const u8) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const e = c.find(url) orelse return;
        if (e.state != .loading) return;
        e.state = .failed;
        e.failed_at = .now(c.io, .awake);
    }

    /// Downloads `url` and stores the result: the body of a fetch job.
    pub fn load(c: *Cache, client: *std.http.Client, url: []const u8) void {
        if (fetchWith(client, c.gpa, url)) |file| c.finish(url, file) else |_| c.fail(url);
    }

    /// The decoded pixels for the half-block fallback, decoded on first use. Null while
    /// loading or failed; a file that doesn't decode turns the entry into `failed`.
    pub fn image(c: *Cache, url: []const u8) ?png.Image {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const e = c.find(url) orelse return null;
        if (e.state != .ready) return null;
        if (e.image == null) {
            e.image = png.decode(c.gpa, e.file) catch {
                e.freeData(c.gpa);
                e.state = .failed;
                e.failed_at = .now(c.io, .awake);
                return null;
            };
        }
        return e.image;
    }

    /// Records that the app sent `url`'s file to the terminal under its id.
    pub fn markTransmitted(c: *Cache, url: []const u8) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.find(url)) |e| e.transmitted = true;
    }

    /// After the terminal lost its images (a protocol switch, a reset): send everything again.
    pub fn forgetTransmitted(c: *Cache) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.entries.items) |*e| e.transmitted = false;
        c.evicted.clearRetainingCapacity();
    }

    /// A kitty id to free in the terminal (`graphics.free`), from an evicted entry. Write the
    /// frees before transmitting new images.
    pub fn popEvicted(c: *Cache) ?u32 {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.evicted.pop();
    }

    fn tick(c: *Cache) u64 {
        c.clock += 1;
        return c.clock;
    }

    fn find(c: *Cache, url: []const u8) ?*Entry {
        for (c.entries.items) |*e| if (std.mem.eql(u8, e.url, url)) return e;
        return null;
    }

    /// Needs one unused slot in `evicted`.
    fn evictOldest(c: *Cache) void {
        var oldest: usize = 0;
        for (c.entries.items, 0..) |e, i| {
            if (e.used < c.entries.items[oldest].used) oldest = i;
        }
        var e = c.entries.swapRemove(oldest);
        if (e.transmitted) c.evicted.appendAssumeCapacity(e.id);
        e.freeData(c.gpa);
        c.gpa.free(e.url);
    }

    /// `graphics.imageId(url)`, moved on past ids still in use or waiting to be freed.
    fn freeId(c: *Cache, url: []const u8) u32 {
        var id = graphics.imageId(url);
        while (c.idTaken(id)) id = id % 0xFFFFFF + 1;
        return id;
    }

    fn idTaken(c: *Cache, id: u32) bool {
        for (c.entries.items) |e| if (e.id == id) return true;
        return std.mem.findScalar(u32, c.evicted.items, id) != null;
    }
};

const testing = std.testing;

test "pngUrl: album and song templates (bb)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/24/f2/15/24f215e3-52cc-078b-d799-d58d606feddd/075679786210.jpg/300x300bb.png",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/24/f2/15/24f215e3-52cc-078b-d799-d58d606feddd/075679786210.jpg/{w}x{h}bb.jpg", 300, 300),
    );
    // A `.png` directory segment (artist images) is left alone; only the last segment changes.
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/AMCArtistImages211/v4/16/64/8d/16648d1f-472a-b326-87aa-0ec4478b8ac1/file_cropped.png/64x64bb.png",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/AMCArtistImages211/v4/16/64/8d/16648d1f-472a-b326-87aa-0ec4478b8ac1/file_cropped.png/{w}x{h}bb.jpg", 64, 64),
    );
}

test "pngUrl: cc, sr, ac and mv crops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/08/c4/32/08c432de-d171-0322-0e6c-a90d0437411e/80aa11c4-8eb3-44fe-a42d-d23b0c72765e.png/120x120cc.png",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/08/c4/32/08c432de-d171-0322-0e6c-a90d0437411e/80aa11c4-8eb3-44fe-a42d-d23b0c72765e.png/{w}x{h}cc.jpg", 120, 120),
    );
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/94/9c/a1/x.png/300x300sr.png",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/94/9c/a1/x.png/{w}x{h}sr.jpg", 300, 300),
    );
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/300x200ac.png",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/{w}x{h}ac.jpg", 300, 200),
    );
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/300x300mv.png",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/{w}x{h}mv.jpg", 300, 300),
    );
}

test "pngUrl: editorial crops with a dot and a query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/65/02/0a/65020a06-097f-1df8-79d3-994f9c6c0632/5fad68e7-3e43-4c7a-aedb-d4bbbe9a8386.png/300x300SC.DN01.png?l=en-US",
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/65/02/0a/65020a06-097f-1df8-79d3-994f9c6c0632/5fad68e7-3e43-4c7a-aedb-d4bbbe9a8386.png/{w}x{h}SC.DN01.jpg?l=en-US", 300, 300),
    );
}

test "pngUrl: composite art keeps the .jpg names in its query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = "?imgLeftAlbum=Music124%2Fv4%2F52%2Faf%2F44%2F52af4464-589d-8c12-5e43-0c06317eb814%2F074644622522.jpg&imgRight=Features125%2Fv4%2Fd0%2Fb7%2Fa8%2Fd0b7a85e-7058-f758-086d-fa98a6994630%2Fmzl.rztcefvm.jpg";
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/Features115/v4/ff/5b/49/ff5b49b7-5d59-8fb3-a901-001d20f29f6e/mzl.bzbetibz.jpg/300x300AM.RSMA03.png" ++ query,
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/Features115/v4/ff/5b/49/ff5b49b7-5d59-8fb3-a901-001d20f29f6e/mzl.bzbetibz.jpg/{w}x{h}AM.RSMA03.jpg" ++ query, 300, 300),
    );
}

test "pngUrl: generated playlist art has a size instead of {w}x{h}" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = "?c1=EEEEEE&c2=BBBBBB&c3=464646&c4=111111&signature=0a1b&t=QWNpZCBUZWNobm8%3D&tc=000000&vkey=1";
    try testing.expectEqualStrings(
        "https://is1-ssl.mzstatic.com/image/thumb/gen/300x300AM.PDCXS11.png" ++ query,
        try pngUrl(a, "https://is1-ssl.mzstatic.com/image/thumb/gen/1200x1200AM.PDCXS11.jpg" ++ query, 300, 300),
    );
}

test "pngUrl: plain URLs, {f}, http, and what isn't a URL" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No size to rewrite: only the extension changes.
    try testing.expectEqualStrings("https://example.com/art/cover.png", try pngUrl(a, "https://example.com/art/cover.jpg", 64, 64));
    try testing.expectEqualStrings("https://example.com/art/cover.png", try pngUrl(a, "https://example.com/art/cover.png", 64, 64));
    try testing.expectEqualStrings("https://example.com/a/x200", try pngUrl(a, "https://example.com/a/x200", 64, 64));
    try testing.expectEqualStrings("https://example.com/a/b.jpg/64x64bb.png", try pngUrl(a, "https://example.com/a/b.jpg/{w}x{h}bb.{f}", 64, 64));
    try testing.expectEqualStrings("https://example.com/a/b.jpg/64x32bb.png", try pngUrl(a, "http://example.com/a/b.jpg/{w}x{h}bb.jpg", 64, 32));
    try testing.expectError(error.BadUrl, pngUrl(a, "ftp://example.com/a.jpg", 64, 64));
    try testing.expectError(error.BadUrl, pngUrl(a, "https://example.com", 64, 64));
    try testing.expectError(error.BadUrl, pngUrl(a, "https://example.com/", 64, 64));
    try testing.expectError(error.BadUrl, pngUrl(a, "", 64, 64));
}

test "fetch refuses anything but https before touching the network" {
    try testing.expectError(error.NotHttps, fetch(testing.io, testing.allocator, "http://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/64x64bb.png"));
    try testing.expectError(error.NotHttps, fetch(testing.io, testing.allocator, "file:///etc/passwd"));
}

/// A local HTTP server for `download`: answers each connection by its path, then closes it.
/// Runs until canceled.
fn serveArt(listener: *std.Io.net.Server) !void {
    const io = testing.io;
    while (true) {
        const stream = try listener.accept(io);
        defer stream.close(io);
        var read_buf: [1024]u8 = undefined;
        var r = stream.reader(io, &read_buf);
        var head: [4096]u8 = undefined;
        var len: usize = 0;
        while (!std.mem.endsWith(u8, head[0..len], "\r\n\r\n")) {
            if (len == head.len) return error.HeadTooLong;
            const n = try r.interface.readSliceShort(head[len .. len + 1]);
            if (n == 0) break;
            len += n;
        }
        var it = std.mem.tokenizeScalar(u8, head[0..len], ' ');
        _ = it.next();
        const path = it.next() orelse "";
        var write_buf: [256]u8 = undefined;
        var w = stream.writer(io, &write_buf);
        const out = &w.interface;
        const close = "Connection: close\r\n";
        const routes = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "/ok", "200 OK", "" },
            .{ "/redirect", "302 Found", "Location: ok\r\n" },
            .{ "/to-https", "302 Found", "Location: https://127.0.0.1:1/ok\r\n" },
            .{ "/loop", "301 Moved Permanently", "Location: /loop\r\n" },
            .{ "/gzip", "200 OK", "Content-Encoding: gzip\r\n" },
            .{ "/jpeg", "200 OK", "" },
            .{ "/missing", "404 Not Found", "" },
        };
        const body: []const u8 = if (std.mem.eql(u8, path, "/ok"))
            small_png
        else if (std.mem.eql(u8, path, "/jpeg"))
            "\xff\xd8\xff\xe0 a JPEG"
        else if (std.mem.eql(u8, path, "/gzip"))
            "not gzip at all"
        else
            "";
        if (std.mem.eql(u8, path, "/huge")) {
            try out.writeAll("HTTP/1.1 200 OK\r\n" ++ close ++ "Content-Length: 3000000\r\n\r\n");
        } else for (routes) |route| {
            if (!std.mem.eql(u8, path, route[0])) continue;
            try out.print("HTTP/1.1 {s}\r\n{s}" ++ close ++ "Content-Length: {d}\r\n\r\n{s}", .{ route[1], route[2], body.len, body });
            break;
        } else try out.writeAll("HTTP/1.1 500 Internal Server Error\r\n" ++ close ++ "Content-Length: 0\r\n\r\n");
        try out.flush();
    }
}

test "download: redirects, statuses, size cap, bad bodies" {
    const io = testing.io;
    const gpa = testing.allocator;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var server = try io.concurrent(serveArt, .{&listener});
    defer server.cancel(io) catch {};

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const port = listener.socket.address.getPort();
    const url = struct {
        fn at(buf: *[64]u8, p: u16, path: []const u8) []const u8 {
            return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ p, path }) catch unreachable;
        }
    }.at;

    const file = try download(&client, gpa, url(&url_buf, port, "/ok"), "http");
    defer gpa.free(file);
    try testing.expectEqualSlices(u8, small_png, file);
    const redirected = try download(&client, gpa, url(&url_buf, port, "/redirect"), "http");
    defer gpa.free(redirected);
    try testing.expectEqualSlices(u8, small_png, redirected);

    try testing.expectError(error.NotHttps, download(&client, gpa, url(&url_buf, port, "/to-https"), "http"));
    try testing.expectError(error.TooManyHttpRedirects, download(&client, gpa, url(&url_buf, port, "/loop"), "http"));
    try testing.expectError(error.BadStatus, download(&client, gpa, url(&url_buf, port, "/missing"), "http"));
    try testing.expectError(error.TooLarge, download(&client, gpa, url(&url_buf, port, "/huge"), "http"));
    try testing.expectError(error.NotPng, download(&client, gpa, url(&url_buf, port, "/jpeg"), "http"));
    // A broken compressed body is an error, not a panic.
    try testing.expectError(error.Network, download(&client, gpa, url(&url_buf, port, "/gzip"), "http"));
}

/// Records the URLs the cache asks for, and can answer at once.
const FakeFetcher = struct {
    started: std.ArrayList([]u8) = .empty,
    cache: ?*Cache = null,
    answer: ?[]const u8 = null,

    fn fetcher(f: *FakeFetcher) Cache.Fetcher {
        return .{ .ctx = f, .start = start };
    }

    fn start(ctx: *anyopaque, url: []const u8) void {
        const f: *FakeFetcher = @ptrCast(@alignCast(ctx));
        f.started.append(testing.allocator, testing.allocator.dupe(u8, url) catch @panic("oom")) catch @panic("oom");
        if (f.answer) |bytes| f.cache.?.finish(url, testing.allocator.dupe(u8, bytes) catch @panic("oom"));
    }

    fn deinit(f: *FakeFetcher) void {
        for (f.started.items) |u| testing.allocator.free(u);
        f.started.deinit(testing.allocator);
    }
};

const small_png = @embedFile("testdata/png/rgb8-1x1.png");

fn dupe(bytes: []const u8) []u8 {
    return testing.allocator.dupe(u8, bytes) catch @panic("oom");
}

test "Cache: request starts one fetch, finish makes it ready" {
    var f: FakeFetcher = .{};
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();

    try testing.expectEqual(@as(?Cache.View, null), c.get("https://a/1.png"));
    try testing.expectEqual(Cache.View.loading, try c.request("https://a/1.png"));
    try testing.expectEqual(Cache.View.loading, try c.request("https://a/1.png"));
    try testing.expectEqual(@as(usize, 1), f.started.items.len);
    try testing.expectEqualStrings("https://a/1.png", f.started.items[0]);

    c.finish("https://a/1.png", dupe(small_png));
    const ready = (try c.request("https://a/1.png")).ready;
    try testing.expectEqualSlices(u8, small_png, ready.png);
    try testing.expectEqual(graphics.imageId("https://a/1.png"), ready.id);
    try testing.expect(!ready.transmitted);
    c.markTransmitted("https://a/1.png");
    try testing.expect(c.get("https://a/1.png").?.ready.transmitted);

    // A second answer for the same URL, or one for an unknown URL, is dropped (and freed).
    c.finish("https://a/1.png", dupe("late"));
    c.finish("https://a/unknown.png", dupe("stray"));
    try testing.expectEqualSlices(u8, small_png, c.get("https://a/1.png").?.ready.png);
}

test "Cache: a fetcher may answer before request returns" {
    var f: FakeFetcher = .{ .answer = small_png };
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();
    f.cache = &c;
    try testing.expectEqual(Cache.View.loading, try c.request("https://a/1.png"));
    try testing.expect(c.get("https://a/1.png").? == .ready);
}

test "Cache: image decodes lazily; a bad file fails the entry" {
    var f: FakeFetcher = .{};
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();
    _ = try c.request("https://a/1.png");
    try testing.expectEqual(@as(?png.Image, null), c.image("https://a/1.png"));
    c.finish("https://a/1.png", dupe(small_png));
    const img = c.image("https://a/1.png").?;
    try testing.expectEqual([3]u8{ 200, 100, 50 }, img.pixel(0, 0));
    try testing.expectEqual(img.rgb.ptr, c.image("https://a/1.png").?.rgb.ptr);

    _ = try c.request("https://a/2.png");
    c.finish("https://a/2.png", dupe("\x89PNG\r\n\x1a\nbroken"));
    try testing.expectEqual(@as(?png.Image, null), c.image("https://a/2.png"));
    try testing.expectEqual(Cache.View.failed, c.get("https://a/2.png").?);
}

test "Cache: failures are retried after retry_after" {
    var f: FakeFetcher = .{};
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();
    _ = try c.request("https://a/1.png");
    c.fail("https://a/1.png");
    try testing.expectEqual(Cache.View.failed, try c.request("https://a/1.png"));
    try testing.expectEqual(@as(usize, 1), f.started.items.len);
    c.retry_after = .zero;
    try testing.expectEqual(Cache.View.loading, try c.request("https://a/1.png"));
    try testing.expectEqual(@as(usize, 2), f.started.items.len);
}

test "Cache: evicts the least recently used; transmitted ids come back to free" {
    var f: FakeFetcher = .{};
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();
    c.capacity = 2;
    _ = try c.request("https://a/1.png");
    _ = try c.request("https://a/2.png");
    c.finish("https://a/1.png", dupe(small_png));
    c.finish("https://a/2.png", dupe(small_png));
    c.markTransmitted("https://a/1.png");
    c.markTransmitted("https://a/2.png");
    const id1 = c.get("https://a/1.png").?.ready.id; // also makes 1 the most recent
    const id2 = c.get("https://a/2.png").?.ready.id;
    _ = c.get("https://a/1.png");

    _ = try c.request("https://a/3.png"); // evicts 2
    try testing.expectEqual(@as(?Cache.View, null), c.get("https://a/2.png"));
    try testing.expectEqual(@as(?u32, id2), c.popEvicted());
    try testing.expectEqual(@as(?u32, null), c.popEvicted());
    try testing.expect(c.get("https://a/1.png") != null); // 1 is now newer than 3

    _ = try c.request("https://a/4.png"); // evicts 3, never transmitted: nothing to free
    try testing.expectEqual(@as(?u32, null), c.popEvicted());
    try testing.expectEqual(@as(?Cache.View, null), c.get("https://a/3.png"));
    _ = try c.request("https://a/5.png"); // evicts 1
    try testing.expectEqual(@as(?u32, id1), c.popEvicted());
}

test "Cache: ids stay unique among entries and pending frees" {
    var f: FakeFetcher = .{};
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();
    c.capacity = 1;
    _ = try c.request("https://a/1.png");
    c.finish("https://a/1.png", dupe(small_png));
    c.markTransmitted("https://a/1.png");
    const first = c.get("https://a/1.png").?.ready.id;
    // Re-requesting the same URL after its eviction must not reuse the id still to be freed.
    _ = try c.request("https://a/2.png");
    _ = try c.request("https://a/1.png");
    c.finish("https://a/1.png", dupe(small_png));
    try testing.expectEqual(@as(?u32, first), c.evicted.items[0]);
    try testing.expectEqual(first % 0xFFFFFF + 1, c.get("https://a/1.png").?.ready.id);

    c.forgetTransmitted();
    try testing.expectEqual(@as(?u32, null), c.popEvicted());
}

test "Cache: finish and request from several threads" {
    var f: FakeFetcher = .{};
    defer f.deinit();
    var c: Cache = .init(testing.allocator, testing.io, f.fetcher());
    defer c.deinit();
    var urls: [16][32]u8 = undefined;
    var names: [16][]const u8 = undefined;
    for (&names, &urls, 0..) |*n, *buf, i| n.* = try std.fmt.bufPrint(buf, "https://a/{d}.png", .{i});
    for (names) |n| _ = try c.request(n);

    const Worker = struct {
        fn run(cache: *Cache, list: []const []const u8) void {
            for (list) |n| cache.finish(n, dupe(small_png));
        }
    };
    var group: Io.Group = .init;
    group.concurrent(testing.io, Worker.run, .{ &c, names[0..8] }) catch Worker.run(&c, names[0..8]);
    group.concurrent(testing.io, Worker.run, .{ &c, names[8..] }) catch Worker.run(&c, names[8..]);
    for (0..200) |_| for (names) |n| {
        _ = c.get(n);
    };
    try group.await(testing.io);
    for (names) |n| try testing.expect(c.get(n).? == .ready);
}
