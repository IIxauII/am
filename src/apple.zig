//! The Apple Music REST API (api.music.apple.com): what `am` asks it and how it reads the answers.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const base_url = "https://api.music.apple.com";

/// The engine page's origin on the default port (`settings.default_port`), sent as the Origin
/// header of every request to Apple. Apple accepts a token with an `origin` claim (the shared
/// developer token, SETUP.md section 6) only from an origin the claim lists; a token without
/// one doesn't look at the header.
pub const origin = "http://localhost:47823";

pub const Response = struct {
    status: u16,
    body: []const u8,

    /// At most the first `max` bytes of the body, for error messages.
    pub fn excerpt(r: Response, max: usize) []const u8 {
        return r.body[0..@min(r.body.len, max)];
    }
};

/// The HTTP methods `am` sends to Apple.
pub const Method = enum { GET, POST, PUT, DELETE };

/// How requests reach Apple. `HttpTransport` and `SharedHttpTransport` are the real ones; tests
/// substitute their own.
pub const Transport = struct {
    ptr: *anyopaque,
    /// `body` is JSON when given. POST and PUT without one send an empty body.
    requestFn: *const fn (ptr: *anyopaque, arena: Allocator, method: Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) anyerror!Response,

    pub fn request(t: Transport, arena: Allocator, method: Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Response {
        return t.requestFn(t.ptr, arena, method, url, headers, body);
    }

    pub fn get(t: Transport, arena: Allocator, url: []const u8, headers: []const std.http.Header) !Response {
        return t.requestFn(t.ptr, arena, .GET, url, headers, null);
    }
};

/// HTTPS through `std.http.Client`. Each request gets a fresh client: a client fixes its clock
/// and CA bundle at its first HTTPS request, and the background process (#5) runs for days.
pub const HttpTransport = struct {
    io: Io,
    gpa: Allocator,

    pub fn transport(t: *HttpTransport) Transport {
        return .{ .ptr = t, .requestFn = request };
    }

    fn request(ptr: *anyopaque, arena: Allocator, method: Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Response {
        const t: *HttpTransport = @ptrCast(@alignCast(ptr));
        var client: std.http.Client = .{ .allocator = t.gpa, .io = t.io };
        defer client.deinit();
        return fetch(&client, arena, method, url, headers, body, false);
    }
};

/// One `std.http.Client` shared by every thread that sends through it, so connections and the
/// CA bundle are reused (`fetch` is thread-safe). The client is replaced once it is older than
/// `max_age`, for the same reason `HttpTransport` makes fresh ones; requests still running on
/// the old one finish first. `gpa` must be thread-safe.
pub const SharedHttpTransport = struct {
    io: Io,
    gpa: Allocator,
    max_age: Io.Duration = .fromSeconds(60 * 60),
    /// Kept-alive connections unused for this long are closed before the next request. Apple
    /// kept idle ones open for 4 minutes when tried; sleep or a network change can end them sooner.
    max_idle: Io.Duration = .fromSeconds(60),
    mutex: Io.Mutex = .init,
    current: ?*Shared = null,
    /// When a request last started or finished (boot clock, which runs through sleep).
    last_used: ?Io.Timestamp = null,
    /// How many clients were made so far.
    generation: u32 = 0,
    /// The program is exiting: a failed request isn't repeated. A canceled read comes back
    /// from std.http as `ReadFailed`, and repeating it would wait for Apple after all.
    stopping: std.atomic.Value(bool) = .init(false),

    const Shared = struct {
        client: std.http.Client,
        born: Io.Timestamp,
        users: u32 = 0,
        retired: bool = false,
    };

    pub fn transport(t: *SharedHttpTransport) Transport {
        return .{ .ptr = t, .requestFn = request };
    }

    /// Failed requests are no longer repeated (call before canceling the requests).
    pub fn stop(t: *SharedHttpTransport) void {
        t.stopping.store(true, .release);
    }

    /// No request may be in flight.
    pub fn deinit(t: *SharedHttpTransport) void {
        if (t.current) |s| t.destroy(s);
        t.current = null;
    }

    fn request(ptr: *anyopaque, arena: Allocator, method: Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Response {
        const t: *SharedHttpTransport = @ptrCast(@alignCast(ptr));
        const shared = try t.acquire();
        defer t.release(shared);
        return fetch(&shared.client, arena, method, url, headers, body, true) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |e| return e,
            else => {
                if (t.stopping.load(.acquire)) return err;
                // The pool hands out connections the server has since closed, and those fail
                // on first use. Close the idle ones; repeat the request when that is safe.
                try closeIdle(&shared.client, t.io);
                if (method == .POST or method == .PUT) return err;
                return fetch(&shared.client, arena, method, url, headers, body, true);
            },
        };
    }

    /// What `std.http.Client` keeps by default.
    const pool_size = 32;

    fn closeIdle(client: *std.http.Client, io: Io) Io.Cancelable!void {
        try client.connection_pool.resize(io, 0);
        try client.connection_pool.resize(io, pool_size);
    }

    fn acquire(t: *SharedHttpTransport) !*Shared {
        try t.mutex.lock(t.io);
        defer t.mutex.unlock(t.io);
        const now: Io.Timestamp = .now(t.io, .real);
        if (t.current) |s| if (s.born.durationTo(now).nanoseconds >= t.max_age.nanoseconds) {
            s.retired = true;
            if (s.users == 0) t.destroy(s);
            t.current = null;
        };
        // Servers hang up on connections left idle; don't send a write down one of those.
        const boot: Io.Timestamp = .now(t.io, .boot);
        if (t.current) |s| if (t.last_used) |last| if (last.durationTo(boot).nanoseconds >= t.max_idle.nanoseconds) {
            try closeIdle(&s.client, t.io);
        };
        t.last_used = boot;
        const s = t.current orelse s: {
            const s = try t.gpa.create(Shared);
            s.* = .{ .client = .{ .allocator = t.gpa, .io = t.io }, .born = now };
            t.current = s;
            t.generation += 1;
            break :s s;
        };
        s.users += 1;
        return s;
    }

    fn release(t: *SharedHttpTransport, s: *Shared) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        s.users -= 1;
        t.last_used = .now(t.io, .boot);
        if (s.retired and s.users == 0) t.destroy(s);
    }

    fn destroy(t: *SharedHttpTransport, s: *Shared) void {
        s.client.deinit();
        t.gpa.destroy(s);
    }
};

fn fetch(client: *std.http.Client, arena: Allocator, method: Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8, keep_alive: bool) !Response {
    const has_body = switch (method) {
        .POST, .PUT => true,
        .GET, .DELETE => false,
    };
    var response_body: Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        },
        .payload = if (has_body) body orelse "" else null,
        .keep_alive = keep_alive,
        .headers = .{ .content_type = if (has_body and body != null) .{ .override = "application/json" } else .default },
        // Not `privileged_headers`: 0.17's client never writes those to the wire. Refusing
        // redirects keeps the tokens on Apple's host instead.
        .extra_headers = headers,
        .redirect_behavior = .not_allowed,
        .response_writer = &response_body.writer,
    });
    return .{ .status = @backingInt(result.status), .body = response_body.written() };
}

/// The headers of a request to Apple, in `buffer`: the developer token, `origin`, and the Music
/// User Token when given. Every request to api.music.apple.com is built with this.
pub fn requestHeaders(arena: Allocator, buffer: *[3]std.http.Header, developer_token: []const u8, user_token: ?[]const u8) Allocator.Error![]const std.http.Header {
    buffer[0] = .{ .name = "Authorization", .value = try std.mem.concat(arena, u8, &.{ "Bearer ", developer_token }) };
    buffer[1] = .{ .name = "Origin", .value = origin };
    const user = user_token orelse return buffer[0..2];
    if (user.len == 0) return buffer[0..2];
    buffer[2] = .{ .name = "Music-User-Token", .value = user };
    return buffer[0..3];
}

/// Replaces a developer token Apple refused with 401: the shared token renewed after the token
/// service's key changed or the old one expired (`token_source.Renewer`, the TUI's session).
/// It remembers what it replaced, so the requests after one renewal send the newer token at once.
pub const Renew = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// After Apple refused `refused` with 401: the token to try instead, or null (the
        /// refused one was the user's own, there's no service, or it failed lately).
        renew: *const fn (ptr: *anyopaque, arena: Allocator, refused: []const u8) Io.Cancelable!?[]const u8,
        /// The token an earlier renewal put in place of `token`, if any.
        replacement: *const fn (ptr: *anyopaque, arena: Allocator, token: []const u8) Allocator.Error!?[]const u8,
    };

    pub fn renew(r: Renew, arena: Allocator, refused: []const u8) Io.Cancelable!?[]const u8 {
        return r.vtable.renew(r.ptr, arena, refused);
    }

    pub fn replacement(r: Renew, arena: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
        return r.vtable.replacement(r.ptr, arena, token);
    }

    /// `token`, or what an earlier renewal put in its place.
    pub fn current(r: ?Renew, arena: Allocator, token: []const u8) Allocator.Error![]const u8 {
        const with = r orelse return token;
        return try with.replacement(arena, token) orelse token;
    }
};

pub const Client = struct {
    transport: Transport,
    developer_token: []const u8,
    /// The stored Music User Token, if any.
    user_token: ?[]const u8,
    /// Gives the developer token to send in place of `developer_token` once a renewal replaced
    /// it, and is asked once for a newer one when Apple answers 401 (the request is then sent
    /// again with it). `music/api.zig` resends its own requests the same way, with the same
    /// `Renew`.
    renew: ?Renew = null,

    pub const GetOptions = struct {
        /// `am token` leaves it out, so that only the developer token is under test.
        send_user_token: bool = true,
    };

    /// `path_and_query` starts with `/v1/`. Allocates into `arena`.
    pub fn get(c: Client, arena: Allocator, path_and_query: []const u8, options: GetOptions) !Response {
        return (try c.getWith(arena, path_and_query, options)).response;
    }

    pub const Answer = struct {
        response: Response,
        /// The developer token this answer was for: after a renewal, the newer one.
        developer_token: []const u8,
    };

    /// `get`, saying which developer token the answer was for.
    pub fn getWith(c: Client, arena: Allocator, path_and_query: []const u8, options: GetOptions) !Answer {
        const url = try std.mem.concat(arena, u8, &.{ base_url, path_and_query });
        const user = if (options.send_user_token) c.user_token else null;
        var buffer: [3]std.http.Header = undefined;
        const token = try Renew.current(c.renew, arena, c.developer_token);
        const response = try c.transport.get(arena, url, try requestHeaders(arena, &buffer, token, user));
        if (response.status != 401) return .{ .response = response, .developer_token = token };
        const r = c.renew orelse return .{ .response = response, .developer_token = token };
        const fresh = try r.renew(arena, token) orelse return .{ .response = response, .developer_token = token };
        return .{ .response = try c.transport.get(arena, url, try requestHeaders(arena, &buffer, fresh, user)), .developer_token = fresh };
    }
};

/// A `Renew` for tests: hands out `token` for any refused one, and remembers the replacement
/// as a real one does.
pub const FakeRenew = struct {
    token: ?[]const u8,
    /// What was refused last.
    refused: ?[]const u8 = null,
    calls: usize = 0,
    replaced: ?[]const u8 = null,

    pub fn renew(f: *FakeRenew) Renew {
        return .{ .ptr = f, .vtable = &.{ .renew = renewFn, .replacement = replacementFn } };
    }

    fn renewFn(ptr: *anyopaque, _: Allocator, refused: []const u8) Io.Cancelable!?[]const u8 {
        const f: *FakeRenew = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        f.refused = refused;
        if (f.token != null) f.replaced = refused;
        return f.token;
    }

    fn replacementFn(ptr: *anyopaque, _: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
        const f: *FakeRenew = @ptrCast(@alignCast(ptr));
        const replaced = f.replaced orelse return null;
        return if (std.mem.eql(u8, replaced, token)) f.token else null;
    }
};

pub const Song = struct {
    id: []const u8,
    name: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_ms: ?u64,
    storefront: []const u8,
};

/// The user's storefront when a Music User Token is stored and Apple accepts it, else `us`.
pub fn storefront(c: Client, arena: Allocator) ![]const u8 {
    const fallback = "us";
    if (c.user_token == null) return fallback;
    const response = try c.get(arena, "/v1/me/storefront", .{});
    if (response.status != 200 or response.body.len == 0) return fallback;
    const parsed = std.json.parseFromSliceLeaky(struct {
        data: []const struct { id: []const u8 },
    }, arena, response.body, .{ .ignore_unknown_fields = true }) catch return fallback;
    return if (parsed.data.len > 0) parsed.data[0].id else fallback;
}

pub const SearchResult = union(enum) {
    songs: []const Song,
    /// Apple answered something other than 200.
    failed: Response,
};

pub fn searchSongs(c: Client, arena: Allocator, store: []const u8, term: []const u8, limit: u8) !SearchResult {
    var path: Io.Writer.Allocating = .init(arena);
    try path.writer.writeAll("/v1/catalog/");
    try std.Uri.Component.percentEncode(&path.writer, store, isUnreserved);
    try path.writer.writeAll("/search?term=");
    try std.Uri.Component.percentEncode(&path.writer, term, isUnreserved);
    try path.writer.print("&types=songs&limit={d}", .{limit});

    const response = try c.get(arena, path.written(), .{});
    if (response.status != 200) return .{ .failed = response };
    // Some endpoints answer 200 with a JSON content type and an empty body.
    if (response.body.len == 0) return .{ .songs = &.{} };

    const parsed = try std.json.parseFromSliceLeaky(struct {
        results: struct {
            songs: ?struct { data: []const SongJson } = null,
        } = .{},
    }, arena, response.body, .{ .ignore_unknown_fields = true });
    const hits = if (parsed.results.songs) |songs| songs.data else &.{};
    const songs = try arena.alloc(Song, hits.len);
    for (hits, songs) |hit, *song| song.* = .{
        .id = hit.id,
        .name = hit.attributes.name,
        .artist = hit.attributes.artistName,
        .album = hit.attributes.albumName,
        .duration_ms = hit.attributes.durationInMillis,
        .storefront = store,
    };
    return .{ .songs = songs };
}

const SongJson = struct {
    id: []const u8,
    attributes: struct {
        name: []const u8 = "",
        artistName: []const u8 = "",
        albumName: []const u8 = "",
        durationInMillis: ?u64 = null,
    } = .{},
};

/// RFC 3986 unreserved characters; everything else in a query value is percent-encoded.
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// `id  m:ss  name — artist (album) [storefront]`, as the Node POC prints it.
pub fn writeSongLine(w: *Io.Writer, song: Song) Io.Writer.Error!void {
    try w.print("{s:<11} ", .{song.id});
    if (song.duration_ms) |ms| {
        const seconds = ms / 1000;
        try w.print("{d}:{d:0>2}", .{ seconds / 60, seconds % 60 });
    } else try w.writeAll("–:––");
    try w.print("  {s} — {s} ({s}) [{s}]\n", .{ song.name, song.artist, song.album, song.storefront });
}

const testing = std.testing;

/// Answers each request with the response queued for its path, and records what was sent.
const FakeApple = struct {
    routes: []const Route,
    urls: std.ArrayList([]const u8) = .empty,
    headers: std.ArrayList([]const std.http.Header) = .empty,

    const Route = struct { path_prefix: []const u8, response: Response };

    fn transport(f: *FakeApple) Transport {
        return .{ .ptr = f, .requestFn = request };
    }

    fn request(ptr: *anyopaque, arena: Allocator, method: Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Response {
        const f: *FakeApple = @ptrCast(@alignCast(ptr));
        try testing.expectEqual(Method.GET, method);
        try testing.expectEqual(null, body);
        try f.urls.append(arena, try arena.dupe(u8, url));
        try f.headers.append(arena, try arena.dupe(std.http.Header, headers));
        const path = if (std.mem.startsWith(u8, url, base_url)) url[base_url.len..] else url;
        for (f.routes) |r| if (std.mem.startsWith(u8, path, r.path_prefix)) return r.response;
        return .{ .status = 404, .body = "" };
    }

    fn header(f: *const FakeApple, index: usize, name: []const u8) ?[]const u8 {
        for (f.headers.items[index]) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

const storefront_gb =
    \\{"data":[{"id":"gb","type":"storefronts","attributes":{"name":"United Kingdom","defaultLanguageTag":"en-GB"}}]}
;

const search_hits =
    \\{"results":{"songs":{"href":"/v1/catalog/gb/search?limit=5&term=shy+away&types=songs","data":[
    \\  {"id":"1561837008","type":"songs","attributes":{"name":"Shy Away","artistName":"Twenty One Pilots",
    \\   "albumName":"Scaled and Icy","durationInMillis":175000,"isrc":"USAT22100180"}},
    \\  {"id":"42","type":"songs","attributes":{"name":"Short","artistName":"A","albumName":"B","durationInMillis":9999}}
    \\]}},"meta":{"results":{"order":["songs"]}}}
;

test "every request carries the developer token, plus the Music User Token when one is stored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeApple = .{ .routes = &.{.{ .path_prefix = "/v1/test", .response = .{ .status = 200, .body = "" } }} };
    const signed_in: Client = .{ .transport = fake.transport(), .developer_token = "DEV", .user_token = "MUT" };
    const anonymous: Client = .{ .transport = fake.transport(), .developer_token = "DEV", .user_token = null };

    _ = try signed_in.get(arena.allocator(), "/v1/test", .{});
    _ = try anonymous.get(arena.allocator(), "/v1/test", .{});
    _ = try signed_in.get(arena.allocator(), "/v1/test", .{ .send_user_token = false });

    try testing.expectEqualStrings("https://api.music.apple.com/v1/test", fake.urls.items[0]);
    try testing.expectEqualStrings("Bearer DEV", fake.header(0, "Authorization").?);
    try testing.expectEqualStrings("MUT", fake.header(0, "Music-User-Token").?);
    try testing.expectEqualStrings("Bearer DEV", fake.header(1, "Authorization").?);
    try testing.expectEqual(null, fake.header(1, "Music-User-Token"));
    try testing.expectEqual(null, fake.header(2, "Music-User-Token"));
    // The engine page's origin, which a shared token's origin claim lists.
    for (0..3) |i| try testing.expectEqualStrings("http://localhost:47823", fake.header(i, "Origin").?);
}

/// Accepts only `Bearer NEW`; 401 for anything else. Counts the requests.
const OnlyNew = struct {
    requests: usize = 0,

    fn transport(f: *OnlyNew) Transport {
        return .{ .ptr = f, .requestFn = request };
    }

    fn request(ptr: *anyopaque, _: Allocator, _: Method, _: []const u8, headers: []const std.http.Header, _: ?[]const u8) anyerror!Response {
        const f: *OnlyNew = @ptrCast(@alignCast(ptr));
        f.requests += 1;
        return .{ .status = if (std.mem.eql(u8, headers[0].value, "Bearer NEW")) 200 else 401, .body = "" };
    }
};

test "a 401 asks once for a newer developer token and sends the request again with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var apple: OnlyNew = .{};
    var renewer: FakeRenew = .{ .token = "NEW" };
    const client: Client = .{ .transport = apple.transport(), .developer_token = "OLD", .user_token = null, .renew = renewer.renew() };
    const answer = try client.getWith(arena.allocator(), "/v1/test", .{});
    try testing.expectEqual(@as(u16, 200), answer.response.status);
    try testing.expectEqualStrings("NEW", answer.developer_token);
    try testing.expectEqualStrings("OLD", renewer.refused.?);
    try testing.expectEqual(@as(usize, 2), apple.requests);

    // The next request on the same client sends the newer token at once: one request, no renewal.
    apple.requests = 0;
    const next = try client.getWith(arena.allocator(), "/v1/test", .{});
    try testing.expectEqualStrings("NEW", next.developer_token);
    try testing.expectEqual(@as(usize, 1), apple.requests);
    try testing.expectEqual(@as(usize, 1), renewer.calls);
    apple.requests = 0;

    // Nothing newer: Apple's 401 stands, and the request isn't repeated.
    var none: FakeRenew = .{ .token = null };
    apple.requests = 0;
    const stuck: Client = .{ .transport = apple.transport(), .developer_token = "OLD", .user_token = null, .renew = none.renew() };
    try testing.expectEqual(@as(u16, 401), (try stuck.get(arena.allocator(), "/v1/test", .{})).status);
    try testing.expectEqual(@as(usize, 1), apple.requests);
    // Without a renewer, the same; with a 200, no renewer is asked.
    const plain: Client = .{ .transport = apple.transport(), .developer_token = "OLD", .user_token = null };
    try testing.expectEqual(@as(u16, 401), (try plain.get(arena.allocator(), "/v1/test", .{})).status);
    const good: Client = .{ .transport = apple.transport(), .developer_token = "NEW", .user_token = null, .renew = none.renew() };
    try testing.expectEqual(@as(u16, 200), (try good.get(arena.allocator(), "/v1/test", .{})).status);
    try testing.expectEqual(@as(usize, 1), none.calls);
}

/// Accepts one connection, answers 200 and returns the request head and body it read.
fn serveOnce(listener: *std.Io.net.Server, out: *[4096]u8) ![]const u8 {
    const io = testing.io;
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var r = stream.reader(io, &read_buffer);
    var len: usize = 0;
    while (!std.mem.endsWith(u8, out[0..len], "\r\n\r\n")) {
        const n = try r.interface.readSliceShort(out[len .. len + 1]);
        if (n == 0) return error.EndOfStream;
        len += n;
    }
    if (std.ascii.findIgnoreCase(out[0..len], "\r\ncontent-length: ")) |at| {
        const start = at + "\r\ncontent-length: ".len;
        const end = std.mem.findScalarPos(u8, out[0..len], start, '\r').?;
        const body_len = try std.fmt.parseInt(usize, out[start..end], 10);
        try r.interface.readSliceAll(out[len .. len + body_len]);
        len += body_len;
    }
    var write_buffer: [256]u8 = undefined;
    var w = stream.writer(io, &write_buffer);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    try w.interface.flush();
    return out[0..len];
}

/// Serves `count` connections one after another.
fn serveMany(listener: *std.Io.net.Server, count: usize) !void {
    var out: [4096]u8 = undefined;
    for (0..count) |_| _ = try serveOnce(listener, &out);
}

fn localListener() !std.Io.net.Server {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    return address.listen(testing.io, .{});
}

fn localUrl(arena: Allocator, listener: *const std.Io.net.Server, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ listener.socket.address.getPort(), path });
}

test "the real transport puts the tokens on the wire" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var listener = try localListener();
    defer listener.deinit(testing.io);
    const url = try localUrl(arena.allocator(), &listener, "/v1/test");

    var out: [4096]u8 = undefined;
    var server = try testing.io.concurrent(serveOnce, .{ &listener, &out });
    var transport: HttpTransport = .{ .io = testing.io, .gpa = testing.allocator };
    const response = try transport.transport().get(arena.allocator(), url, &.{
        .{ .name = "Authorization", .value = "Bearer DEV" },
        .{ .name = "Music-User-Token", .value = "MUT" },
    });
    const head = try server.await(testing.io);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("ok", response.body);
    try testing.expect(std.mem.startsWith(u8, head, "GET /v1/test HTTP/1.1\r\n"));
    try testing.expect(std.mem.find(u8, head, "\r\nAuthorization: Bearer DEV\r\n") != null);
    try testing.expect(std.mem.find(u8, head, "\r\nMusic-User-Token: MUT\r\n") != null);
}

test "a POST sends its JSON body; a POST without one and a DELETE send none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var listener = try localListener();
    defer listener.deinit(testing.io);
    const url = try localUrl(arena.allocator(), &listener, "/v1/me/x?ids%5Bsongs%5D=1");
    var transport: HttpTransport = .{ .io = testing.io, .gpa = testing.allocator };

    var out: [4096]u8 = undefined;
    var server = try testing.io.concurrent(serveOnce, .{ &listener, &out });
    _ = try transport.transport().request(arena.allocator(), .POST, url, &.{}, "{\"data\":[]}");
    var sent = try server.await(testing.io);
    try testing.expect(std.mem.startsWith(u8, sent, "POST /v1/me/x?ids%5Bsongs%5D=1 HTTP/1.1\r\n"));
    try testing.expect(std.ascii.findIgnoreCase(sent, "\r\ncontent-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, sent, "\r\n\r\n{\"data\":[]}"));

    server = try testing.io.concurrent(serveOnce, .{ &listener, &out });
    _ = try transport.transport().request(arena.allocator(), .POST, url, &.{}, null);
    sent = try server.await(testing.io);
    try testing.expect(std.ascii.findIgnoreCase(sent, "\r\ncontent-length: 0\r\n") != null);
    try testing.expect(std.ascii.findIgnoreCase(sent, "content-type") == null);

    server = try testing.io.concurrent(serveOnce, .{ &listener, &out });
    _ = try transport.transport().request(arena.allocator(), .DELETE, url, &.{}, null);
    sent = try server.await(testing.io);
    try testing.expect(std.mem.startsWith(u8, sent, "DELETE /v1/me/x?ids%5Bsongs%5D=1 HTTP/1.1\r\n"));
    try testing.expect(std.mem.endsWith(u8, sent, "\r\n\r\n"));
}

fn getStatus(t: Transport, url: []const u8) anyerror!u16 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return (try t.get(arena.allocator(), url, &.{})).status;
}

test "the shared transport keeps one client until it is too old" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var listener = try localListener();
    defer listener.deinit(testing.io);
    const url = try localUrl(arena.allocator(), &listener, "/v1/test");
    var shared: SharedHttpTransport = .{ .io = testing.io, .gpa = testing.allocator };
    defer shared.deinit();

    var server = try testing.io.concurrent(serveMany, .{ &listener, 3 });
    try testing.expectEqual(@as(u16, 200), try getStatus(shared.transport(), url));
    try testing.expectEqual(@as(u16, 200), try getStatus(shared.transport(), url));
    try testing.expectEqual(@as(u32, 1), shared.generation);
    shared.max_age = .zero;
    try testing.expectEqual(@as(u16, 200), try getStatus(shared.transport(), url));
    try testing.expectEqual(@as(u32, 2), shared.generation);
    try server.await(testing.io);
}

/// Answers one request on a kept-alive connection, then hangs up, as a server does with a
/// connection left idle.
fn serveKeepAliveThenClose(listener: *std.Io.net.Server) !void {
    const io = testing.io;
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var r = stream.reader(io, &read_buffer);
    var head: [4096]u8 = undefined;
    var len: usize = 0;
    while (!std.mem.endsWith(u8, head[0..len], "\r\n\r\n")) {
        const n = try r.interface.readSliceShort(head[len .. len + 1]);
        if (n == 0) return error.EndOfStream;
        len += n;
    }
    var write_buffer: [256]u8 = undefined;
    var w = stream.writer(io, &write_buffer);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    try w.interface.flush();
}

test "the shared transport recovers when the server closed an idle connection" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var listener = try localListener();
    defer listener.deinit(testing.io);
    const url = try localUrl(arena.allocator(), &listener, "/v1/test");
    var shared: SharedHttpTransport = .{ .io = testing.io, .gpa = testing.allocator };
    defer shared.deinit();

    var first = try testing.io.concurrent(serveKeepAliveThenClose, .{&listener});
    try testing.expectEqual(@as(u16, 200), try getStatus(shared.transport(), url));
    try first.await(testing.io);

    // The pooled connection is dead now; GET and DELETE are sent again on a new one.
    var out: [4096]u8 = undefined;
    var second = try testing.io.concurrent(serveOnce, .{ &listener, &out });
    try testing.expectEqual(@as(u16, 200), try getStatus(shared.transport(), url));
    _ = try second.await(testing.io);
    try testing.expectEqual(@as(u32, 1), shared.generation);

    // A POST is never sent twice; connections idle past max_idle are closed before it goes.
    shared.max_idle = .zero;
    var third = try testing.io.concurrent(serveKeepAliveThenClose, .{&listener});
    try testing.expectEqual(@as(u16, 200), try getStatus(shared.transport(), url));
    try third.await(testing.io);
    var fourth = try testing.io.concurrent(serveOnce, .{ &listener, &out });
    const posted = try shared.transport().request(arena.allocator(), .POST, url, &.{}, "{}");
    try testing.expectEqual(@as(u16, 200), posted.status);
    _ = try fourth.await(testing.io);
}

test "the shared transport serves requests from several threads at once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var listener = try localListener();
    defer listener.deinit(testing.io);
    const url = try localUrl(arena.allocator(), &listener, "/v1/test");
    var shared: SharedHttpTransport = .{ .io = testing.io, .gpa = testing.allocator, .max_age = .zero };
    defer shared.deinit();

    var server = try testing.io.concurrent(serveMany, .{ &listener, 4 });
    var requests: [4]Io.Future(anyerror!u16) = undefined;
    for (&requests) |*r| r.* = try testing.io.concurrent(getStatus, .{ shared.transport(), url });
    for (&requests) |*r| try testing.expectEqual(@as(u16, 200), try r.await(testing.io));
    try server.await(testing.io);
    try testing.expectEqual(@as(u32, 4), shared.generation);
}

test "the storefront is the user's when Apple accepts their token, else us" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var accepted: FakeApple = .{ .routes = &.{.{ .path_prefix = "/v1/me/storefront", .response = .{ .status = 200, .body = storefront_gb } }} };
    try testing.expectEqualStrings("gb", try storefront(.{ .transport = accepted.transport(), .developer_token = "DEV", .user_token = "MUT" }, arena.allocator()));
    try testing.expectEqualStrings("https://api.music.apple.com/v1/me/storefront", accepted.urls.items[0]);

    var rejected: FakeApple = .{ .routes = &.{.{ .path_prefix = "/v1/me/storefront", .response = .{ .status = 403, .body = "{\"errors\":[]}" } }} };
    try testing.expectEqualStrings("us", try storefront(.{ .transport = rejected.transport(), .developer_token = "DEV", .user_token = "MUT" }, arena.allocator()));

    var unasked: FakeApple = .{ .routes = &.{} };
    try testing.expectEqualStrings("us", try storefront(.{ .transport = unasked.transport(), .developer_token = "DEV", .user_token = null }, arena.allocator()));
    try testing.expectEqual(@as(usize, 0), unasked.urls.items.len);
}

test "search asks the catalog for five songs and reads the hits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeApple = .{ .routes = &.{.{ .path_prefix = "/v1/catalog/gb/search", .response = .{ .status = 200, .body = search_hits } }} };
    const client: Client = .{ .transport = fake.transport(), .developer_token = "DEV", .user_token = null };

    const result = try searchSongs(client, arena.allocator(), "gb", "shy away & co/ü", 5);
    try testing.expectEqualStrings("https://api.music.apple.com/v1/catalog/gb/search?term=shy%20away%20%26%20co%2F%C3%BC&types=songs&limit=5", fake.urls.items[0]);
    const songs = result.songs;
    try testing.expectEqual(@as(usize, 2), songs.len);
    try testing.expectEqualDeep(Song{
        .id = "1561837008",
        .name = "Shy Away",
        .artist = "Twenty One Pilots",
        .album = "Scaled and Icy",
        .duration_ms = 175000,
        .storefront = "gb",
    }, songs[0]);
}

test "a search with no hits, or a 200 with an empty body, is an empty result" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "{\"results\":{},\"meta\":{\"results\":{\"order\":[]}}}" }) |body| {
        var fake: FakeApple = .{ .routes = &.{.{ .path_prefix = "/v1/catalog/gb/search", .response = .{ .status = 200, .body = body } }} };
        const client: Client = .{ .transport = fake.transport(), .developer_token = "DEV", .user_token = null };
        try testing.expectEqual(@as(usize, 0), (try searchSongs(client, arena.allocator(), "gb", "zzzz", 5)).songs.len);
    }
}

test "a search Apple refuses comes back as the failed response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeApple = .{ .routes = &.{.{ .path_prefix = "/v1/catalog/gb/search", .response = .{ .status = 401, .body = "{\"errors\":[{\"status\":\"401\"}]}" } }} };
    const client: Client = .{ .transport = fake.transport(), .developer_token = "DEV", .user_token = null };
    const result = try searchSongs(client, arena.allocator(), "gb", "x", 5);
    try testing.expectEqual(@as(u16, 401), result.failed.status);
}

test "a song line is id, m:ss, name — artist (album) [storefront]" {
    var buf: [200]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeSongLine(&w, .{ .id = "1561837008", .name = "Shy Away", .artist = "Twenty One Pilots", .album = "Scaled and Icy", .duration_ms = 175999, .storefront = "gb" });
    try writeSongLine(&w, .{ .id = "42", .name = "N", .artist = "A", .album = "B", .duration_ms = null, .storefront = "us" });
    try testing.expectEqualStrings(
        "1561837008  2:55  Shy Away — Twenty One Pilots (Scaled and Icy) [gb]\n" ++
            "42          –:––  N — A (B) [us]\n",
        w.buffered(),
    );
}
