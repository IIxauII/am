//! The background process's local HTTP server. One server carries two kinds of client:
//!
//! - the engine page, with the Node POC's routes unchanged: `/claim`, `/events` (SSE),
//!   `POST /report`, `POST /result`, `/developer-token`, `GET`/`POST /user-token` and its own
//!   static files. The token `GET`s, like `/events`, need the current launch's `?engine=` nonce;
//! - the `am` CLI, under `/cli/`, authenticated with the daemon secret.
//!
//! Every request must pass the Host check and, if it has one, the Origin check (see `guard.zig`).
//! What the CLI routes and token routes do is the daemon's business (`Backend`); this file only
//! guards, routes and speaks HTTP.
const std = @import("std");
const channel_mod = @import("channel.zig");
const guard = @import("guard.zig");
const platform = @import("../platform.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Channel = channel_mod.Channel;
const Io = std.Io;
const net = Io.net;

const index_html = @embedFile("web/index.html");
const app_js = @embedFile("web/app.js");

/// A command channel's SSE stream sends a `: ping` comment this often when idle, so a dropped
/// engine page shows up as a failed write (std.http.Server has no timeouts of its own).
pub const ping_interval: Io.Duration = .fromSeconds(15);

/// Request bodies are reports, results and tokens: a few KiB.
const max_body = 1 << 20;

pub const Response = struct {
    status: std.http.Status = .ok,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",

    pub fn json(body: []const u8) Response {
        return .{ .content_type = "application/json", .body = body };
    }

    pub fn text(status: std.http.Status, body: []const u8) Response {
        return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = body };
    }
};

/// What the daemon answers on the routes that need more than the channel.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `GET /developer-token`: the stored developer token as text, or why there is none.
        developerToken: *const fn (ptr: *anyopaque, arena: Allocator) anyerror!Response,
        /// `GET /user-token`: the stored Music User Token as text (200), or 204.
        userToken: *const fn (ptr: *anyopaque, arena: Allocator) anyerror!Response,
        /// `POST /user-token`: `{token}` from the sign-in page; checked with Apple, kept on 200.
        postUserToken: *const fn (ptr: *anyopaque, arena: Allocator, body: []const u8) anyerror!Response,
        /// Whether `/cli/<name>` exists.
        hasCli: *const fn (ptr: *anyopaque, name: []const u8) bool,
        /// Runs `/cli/<name>`, already authenticated, writing what the CLI prints to `reply`.
        cli: *const fn (ptr: *anyopaque, name: []const u8, body: []const u8, reply: *protocol.Reply) protocol.Reply.Error!void,
    };

    pub fn developerToken(b: Backend, arena: Allocator) !Response {
        return b.vtable.developerToken(b.ptr, arena);
    }

    pub fn userToken(b: Backend, arena: Allocator) !Response {
        return b.vtable.userToken(b.ptr, arena);
    }

    pub fn postUserToken(b: Backend, arena: Allocator, body: []const u8) !Response {
        return b.vtable.postUserToken(b.ptr, arena, body);
    }

    pub fn hasCli(b: Backend, name: []const u8) bool {
        return b.vtable.hasCli(b.ptr, name);
    }

    pub fn cli(b: Backend, name: []const u8, body: []const u8, reply: *protocol.Reply) protocol.Reply.Error!void {
        return b.vtable.cli(b.ptr, name, body, reply);
    }
};

pub const Route = union(enum) {
    claim: ?[]const u8,
    events: ?[]const u8,
    report,
    result,
    /// Holds the `?engine=` nonce, like `user_token_get`: only the current page gets tokens.
    developer_token: ?[]const u8,
    user_token_get: ?[]const u8,
    /// Holds the `?engine=` nonce: the sign-in page's, or the engine page's.
    user_token_post: ?[]const u8,
    cli: []const u8,
    index_html,
    app_js,
    not_found,
};

/// Maps a request line to a route. `?engine=<nonce>` rides along on `/claim` and `/events`.
pub fn route(method: std.http.Method, target: []const u8) Route {
    const query_start = std.mem.findScalar(u8, target, '?');
    const path = target[0 .. query_start orelse target.len];
    const query = if (query_start) |q| target[q + 1 ..] else "";
    if (std.mem.startsWith(u8, path, "/cli/")) return .{ .cli = path["/cli/".len..] };
    if (eql(path, "/claim")) return .{ .claim = queryParam(query, "engine") };
    if (eql(path, "/events")) return .{ .events = queryParam(query, "engine") };
    if (eql(path, "/report") and method == .POST) return .report;
    if (eql(path, "/result") and method == .POST) return .result;
    if (eql(path, "/developer-token")) return .{ .developer_token = queryParam(query, "engine") };
    if (eql(path, "/user-token")) return if (method == .POST) .{ .user_token_post = queryParam(query, "engine") } else .{ .user_token_get = queryParam(query, "engine") };
    if (eql(path, "/") or eql(path, "/index.html")) return .index_html;
    if (eql(path, "/app.js")) return .app_js;
    return .not_found;
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (eql(pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const Server = struct {
    io: Io,
    gpa: Allocator,
    channel: *Channel,
    backend: Backend,
    /// The contents of `daemon-secret`, which CLI requests must carry.
    secret: []const u8,
    port: u16 = 0,
    listeners: [2]?net.Server = .{ null, null },
    tasks: Io.Group = .init,

    pub const BindError = error{
        /// Another process (most likely another `am daemon`) holds the port.
        PortBusy,
    } || platform.ListenError;

    /// Binds `127.0.0.1:port` and, unless IPv6 is unavailable, `[::1]:port` (Chrome may resolve
    /// `localhost` to either). Never a public interface. Port 0 (tests) binds IPv4 only.
    pub fn bind(s: *Server, port: u16) BindError!void {
        var v4 = platform.listenLoopback(s.io, .{ .ip4 = .loopback(port) }) catch |e| return switch (e) {
            error.AddressInUse => error.PortBusy,
            else => e,
        };
        errdefer v4.deinit(s.io);
        s.port = v4.socket.address.getPort();
        s.listeners[0] = v4;
        if (port == 0) return;
        s.listeners[1] = platform.listenLoopback(s.io, .{ .ip6 = .loopback(port) }) catch |e| switch (e) {
            error.AddressUnavailable, error.AddressFamilyUnsupported => null,
            error.AddressInUse => return error.PortBusy,
            else => return e,
        };
    }

    /// Accepts connections in the background until `close`.
    pub fn start(s: *Server) Io.ConcurrentError!void {
        for (&s.listeners) |*l| if (l.*) |*listener| try s.tasks.concurrent(s.io, acceptLoop, .{ s, listener });
    }

    /// Stops accepting, ends every connection (SSE streams included) and closes the sockets.
    pub fn close(s: *Server) void {
        s.tasks.cancel(s.io);
        for (&s.listeners) |*l| if (l.*) |*listener| {
            listener.deinit(s.io);
            l.* = null;
        };
    }

    fn acceptLoop(s: *Server, listener: *net.Server) Io.Cancelable!void {
        while (true) {
            const stream = listener.accept(s.io) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => {
                    // Out of file descriptors and the like: back off instead of spinning.
                    try s.io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            };
            s.tasks.concurrent(s.io, handleConnection, .{ s, stream }) catch stream.close(s.io);
        }
    }

    fn handleConnection(s: *Server, stream: net.Stream) Io.Cancelable!void {
        defer stream.close(s.io);
        var recv_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var reader = stream.reader(s.io, &recv_buffer);
        var writer = stream.writer(s.io, &send_buffer);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        while (true) {
            _ = arena.reset(.retain_capacity);
            var request = http.receiveHead() catch return;
            // Reading a body also leaves the reader `.ready`, even after `Connection: close`.
            const keep_alive = request.head.keep_alive;
            s.handleRequest(arena.allocator(), &request, &reader) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            if (!keep_alive or http.reader.state != .ready) return;
        }
    }

    /// `conn`: the connection's own reader, for noticing a CLI that hangs up.
    fn handleRequest(s: *Server, arena: Allocator, request: *std.http.Server.Request, conn: *net.Stream.Reader) !void {
        var host: ?[]const u8 = null;
        var origin: ?[]const u8 = null;
        var secret: ?[]const u8 = null;
        var client: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, guard.secret_header)) secret = h.value;
            // An empty one names no client: two of them aren't the same one.
            if (std.ascii.eqlIgnoreCase(h.name, guard.client_header)) client = if (h.value.len > 0) h.value else null;
        }
        if (!guard.hostAllowed(host, s.port) or !guard.originAllowed(origin, s.port))
            return respond(request, .text(.forbidden, "forbidden\n"));

        const method = request.head.method;
        switch (route(method, request.head.target)) {
            .claim => |nonce| return respond(request, .{ .status = if (s.channel.claim(nonce)) .no_content else .conflict }),
            .events => |nonce| return s.streamEvents(arena, request, nonce),
            .report => {
                const body = try readBody(arena, request);
                return respond(request, switch (try s.channel.postReport(body)) {
                    .accepted => .{ .status = .no_content },
                    .stale => .{ .status = .conflict },
                    .invalid => .text(.bad_request, "bad report\n"),
                });
            },
            .result => {
                const body = try readBody(arena, request);
                return respond(request, switch (try s.channel.postResult(body)) {
                    .settled, .unknown => .{ .status = .no_content },
                    .invalid => .text(.bad_request, "bad result\n"),
                });
            },
            // Tokens only for the current engine page (and the developer token for the current
            // sign-in page): no other local process gets them by sending the right Host header.
            .developer_token => |nonce| {
                if (!s.channel.claimSignin(nonce)) return respond(request, .text(.forbidden, "forbidden\n"));
                return respond(request, try s.backend.developerToken(arena));
            },
            .user_token_get => |nonce| {
                if (!s.channel.claim(nonce)) return respond(request, .text(.forbidden, "forbidden\n"));
                return respond(request, try s.backend.userToken(arena));
            },
            // Nor can one plant a Music User Token of its own.
            .user_token_post => |nonce| {
                if (!s.channel.claimSignin(nonce)) return respond(request, .text(.forbidden, "forbidden\n"));
                const body = try readBody(arena, request);
                return respond(request, try s.backend.postUserToken(arena, body));
            },
            .cli => |name| {
                if (!guard.secretMatches(s.secret, secret)) return respond(request, .text(.forbidden, "forbidden\n"));
                if (!s.backend.hasCli(name)) return respond(request, .text(.not_found, "unknown command\n"));
                if (method != .POST) return respond(request, .text(.method_not_allowed, "POST only\n"));
                return s.runCli(arena, request, conn, if (client) |id| try arena.dupe(u8, id) else null, name, try readBody(arena, request));
            },
            .index_html => return respond(request, .{ .content_type = "text/html; charset=utf-8", .body = index_html }),
            .app_js => return respond(request, .{ .content_type = "text/javascript; charset=utf-8", .body = app_js }),
            .not_found => return respond(request, .text(.not_found, "not found\n")),
        }
    }

    /// Streams what the endpoint prints to the CLI as it happens, then its result. Meanwhile
    /// `conn` is watched for the CLI closing its end (`Reply.client_gone`).
    fn runCli(s: *Server, arena: Allocator, request: *std.http.Server.Request, conn: *net.Stream.Reader, client: ?[]const u8, name: []const u8, body: []const u8) !void {
        var gone: std.atomic.Value(bool) = .init(false);
        // No thread to spare: the endpoint can't tell, and treats the CLI as still there.
        var watcher = s.io.concurrent(watchHangUp, .{ conn, &gone }) catch null;
        defer if (watcher) |*w| w.cancel(s.io) catch {};
        var buffer: [4096]u8 = undefined;
        var response = try request.respondStreaming(&buffer, .{ .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = protocol.content_type },
                .{ .name = "cache-control", .value = "no-store" },
            },
        } });
        var reply: protocol.Reply = .{
            .arena = arena,
            .out = &response.writer,
            .flushFn = flushReply,
            .flush_ctx = &response,
            .client_gone = if (watcher != null) &gone else null,
            .client_id = client,
        };
        try reply.finish(s.backend.cli(name, body, &reply));
        try response.end();
    }

    fn streamEvents(s: *Server, arena: Allocator, request: *std.http.Server.Request, nonce: ?[]const u8) !void {
        var stream = s.channel.openStream(nonce) orelse return respond(request, .{ .status = .conflict });
        defer s.channel.closeStream(stream);
        var buffer: [4096]u8 = undefined;
        var body = try request.respondStreaming(&buffer, .{ .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        } });
        try body.writer.writeAll(": connected\n\n");
        try flushEvent(&body);
        while (true) {
            switch (try s.channel.nextEvent(arena, &stream, ping_interval)) {
                .command => |json| try body.writer.print("data: {s}\n\n", .{json}),
                .ping => try body.writer.writeAll(": ping\n\n"),
                .closed => return body.end(),
            }
            try flushEvent(&body);
        }
    }
};

/// Sets `gone` once the CLI closes its end of the connection, which ends the read. The CLI sends
/// nothing after its request (`Connection: close`), so stray bytes are dropped. Runs until
/// canceled.
fn watchHangUp(conn: *net.Stream.Reader, gone: *std.atomic.Value(bool)) Io.Cancelable!void {
    while (true) {
        _ = conn.interface.peekByte() catch |e| {
            if (e == error.ReadFailed) if (conn.err) |cause| if (cause == error.Canceled) return error.Canceled;
            gone.store(true, .release);
            return;
        };
        conn.interface.tossBuffered();
    }
}

fn flushReply(ctx: *anyopaque) Io.Writer.Error!void {
    return flushEvent(@ptrCast(@alignCast(ctx)));
}

/// `BodyWriter.flush` only flushes the connection: the event must first leave the body's own
/// buffer as a chunk.
fn flushEvent(body: *std.http.BodyWriter) std.http.BodyWriter.Error!void {
    try body.writer.flush();
    try body.flush();
}

fn readBody(arena: Allocator, request: *std.http.Server.Request) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    return reader.allocRemaining(arena, .limited(max_body));
}

/// Never with CORS headers: a page in the user's normal browser must not read any response.
fn respond(request: *std.http.Server.Request, response: Response) !void {
    var headers: [2]std.http.Header = undefined;
    headers[0] = .{ .name = "cache-control", .value = "no-store" };
    var n: usize = 1;
    if (response.content_type) |t| {
        headers[1] = .{ .name = "content-type", .value = t };
        n = 2;
    }
    try request.respond(response.body, .{ .status = response.status, .extra_headers = headers[0..n] });
}

const testing = std.testing;

test "requests map to the POC's routes, with the nonce from the query" {
    try testing.expectEqualDeep(Route{ .claim = "abc" }, route(.GET, "/claim?engine=abc"));
    try testing.expectEqualDeep(Route{ .claim = null }, route(.GET, "/claim"));
    try testing.expectEqualDeep(Route{ .events = "abc" }, route(.GET, "/events?x=1&engine=abc"));
    try testing.expectEqual(Route.report, route(.POST, "/report"));
    try testing.expectEqual(Route.not_found, route(.GET, "/report"));
    try testing.expectEqual(Route.result, route(.POST, "/result"));
    try testing.expectEqualDeep(Route{ .developer_token = "abc" }, route(.GET, "/developer-token?engine=abc"));
    try testing.expectEqualDeep(Route{ .developer_token = null }, route(.GET, "/developer-token"));
    try testing.expectEqualDeep(Route{ .user_token_get = "abc" }, route(.GET, "/user-token?engine=abc"));
    try testing.expectEqualDeep(Route{ .user_token_post = "abc" }, route(.POST, "/user-token?engine=abc"));
    try testing.expectEqual(Route.index_html, route(.GET, "/?signin"));
    try testing.expectEqual(Route.index_html, route(.GET, "/index.html?engine=abc"));
    try testing.expectEqual(Route.app_js, route(.GET, "/app.js"));
    try testing.expectEqualDeep(Route{ .cli = "ping" }, route(.GET, "/cli/ping"));
    try testing.expectEqual(Route.not_found, route(.GET, "/../secret"));
}

/// Answers the backend routes with fixed responses and records CLI calls.
const FakeBackend = struct {
    cli_calls: usize = 0,
    /// The last CLI call's `Reply.client_id` (copied), or null when it named none.
    client_buf: [32]u8 = undefined,
    client: ?[]const u8 = null,
    /// Posted tokens that reached the daemon's check with Apple.
    token_posts: usize = 0,

    fn backend(f: *FakeBackend) Backend {
        return .{ .ptr = f, .vtable = &.{
            .developerToken = developerToken,
            .userToken = userToken,
            .postUserToken = postUserToken,
            .hasCli = hasCli,
            .cli = cli,
        } };
    }
    fn developerToken(_: *anyopaque, _: Allocator) !Response {
        return .text(.ok, "DEV");
    }
    fn userToken(_: *anyopaque, _: Allocator) !Response {
        return .{ .status = .no_content };
    }
    fn postUserToken(ptr: *anyopaque, _: Allocator, _: []const u8) !Response {
        const f: *FakeBackend = @ptrCast(@alignCast(ptr));
        f.token_posts += 1;
        return .json("{\"ok\":true}");
    }
    fn hasCli(_: *anyopaque, name: []const u8) bool {
        return eql(name, "ping");
    }
    fn cli(ptr: *anyopaque, _: []const u8, _: []const u8, reply: *protocol.Reply) protocol.Reply.Error!void {
        const f: *FakeBackend = @ptrCast(@alignCast(ptr));
        f.cli_calls += 1;
        f.client = null;
        if (reply.client_id) |id| if (id.len <= f.client_buf.len) {
            @memcpy(f.client_buf[0..id.len], id);
            f.client = f.client_buf[0..id.len];
        };
        try reply.print("pong\n", .{});
    }
};

const test_secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";

const TestServer = struct {
    channel: Channel,
    fake: FakeBackend = .{},
    server: Server,

    fn start(t: *TestServer) !void {
        t.channel = .init(testing.io, testing.allocator);
        t.fake = .{};
        t.server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &t.channel, .backend = t.fake.backend(), .secret = test_secret };
        try t.server.bind(0);
        try t.server.start();
    }

    fn stop(t: *TestServer) void {
        t.server.close();
        t.channel.deinit();
    }

    /// Sends one request (`PORT` in it becomes the server's port) and returns the whole
    /// response. Allocated with the testing allocator.
    fn send(t: *TestServer, request: []const u8) ![]u8 {
        const io = testing.io;
        var port_text: [5]u8 = undefined;
        const port = try std.mem.print(&port_text, "{d}", .{t.server.port});
        const bytes = try std.mem.replaceOwned(u8, testing.allocator, request, "PORT", port);
        defer testing.allocator.free(bytes);
        const address: net.IpAddress = .{ .ip4 = .loopback(t.server.port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buffer: [1024]u8 = undefined;
        var w = stream.writer(io, &write_buffer);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
        var read_buffer: [4096]u8 = undefined;
        var r = stream.reader(io, &read_buffer);
        return r.interface.allocRemaining(testing.allocator, .limited(1 << 20));
    }

    fn status(t: *TestServer, request: []const u8) !u16 {
        const response = try t.send(request);
        defer testing.allocator.free(response);
        try testing.expect(std.ascii.findIgnoreCase(response, "access-control-allow") == null);
        return std.fmt.parseInt(u16, response["HTTP/1.1 ".len..][0..3], 10);
    }
};

test "a request whose Host isn't ours gets 403" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    try testing.expectEqual(@as(u16, 403), try t.status("GET / HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET / HTTP/1.1\r\nHost: evil.example:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET / HTTP/1.1\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 200), try t.status("GET / HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 200), try t.status("GET /app.js HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nConnection: close\r\n\r\n"));
}

test "CLI requests without the secret, or with a wrong one, get 403 and never reach the daemon" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    try testing.expectEqual(@as(u16, 403), try t.status("GET /cli/ping HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET /cli/ping HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nX-AM-Secret: wrong\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("POST /cli/stop HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nX-AM-Secret: \r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(usize, 0), t.fake.cli_calls);

    const secret_header = "X-AM-Secret: " ++ test_secret ++ "\r\n";
    // Known endpoints only, POST only.
    try testing.expectEqual(@as(u16, 404), try t.status("POST /cli/call HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\n" ++ secret_header ++ "Content-Length: 2\r\nConnection: close\r\n\r\n{}"));
    try testing.expectEqual(@as(u16, 405), try t.status("GET /cli/ping HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\n" ++ secret_header ++ "Connection: close\r\n\r\n"));
    try testing.expectEqual(@as(usize, 0), t.fake.cli_calls);

    const ok = try t.send("POST /cli/ping HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\n" ++ secret_header ++ "Content-Length: 2\r\nConnection: close\r\n\r\n{}");
    defer testing.allocator.free(ok);
    try testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.ascii.findIgnoreCase(ok, "content-type: application/x-ndjson\r\n") != null);
    // The endpoint's output, then its result, as JSON lines (chunked).
    try testing.expect(std.mem.find(u8, ok, "{\"out\":\"pong\\n\"}\n") != null);
    try testing.expect(std.mem.find(u8, ok, "{\"exit\":0}\n") != null);
    try testing.expectEqual(@as(usize, 1), t.fake.cli_calls);
}

test "a CLI request names its client with X-AM-Client; an empty one names none" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    const head = "POST /cli/ping HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nX-AM-Secret: " ++ test_secret ++ "\r\n";
    const tail = "Content-Length: 2\r\nConnection: close\r\n\r\n{}";
    try testing.expectEqual(@as(u16, 200), try t.status(head ++ "X-AM-Client: 0123456789abcdef\r\n" ++ tail));
    try testing.expectEqualStrings("0123456789abcdef", t.fake.client.?);
    try testing.expectEqual(@as(u16, 200), try t.status(head ++ "X-AM-Client: \r\n" ++ tail));
    try testing.expectEqual(null, t.fake.client);
    try testing.expectEqual(@as(u16, 200), try t.status(head ++ tail));
    try testing.expectEqual(null, t.fake.client);
}

test "a foreign Origin gets 403 on the token, report and result routes; the page's own works" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    const nonce = "cccccccccccccccccccccccccccccccc";
    t.channel.setNonce(nonce.*);
    const report = "{\"engine\":\"" ++ nonce ++ "\"}";

    try testing.expectEqual(@as(u16, 403), try t.status("POST /user-token HTTP/1.1\r\nHost: localhost:PORT\r\nOrigin: https://evil.example\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"token\":\"x\"}"));
    try testing.expectEqual(@as(u16, 403), try t.status("POST /report HTTP/1.1\r\nHost: localhost:PORT\r\nOrigin: https://evil.example\r\nContent-Length: 45\r\nConnection: close\r\n\r\n" ++ report));
    try testing.expectEqual(@as(u16, 403), try t.status("POST /result HTTP/1.1\r\nHost: localhost:PORT\r\nOrigin: https://evil.example\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"));
    try testing.expectEqual(null, try t.channel.lastReport(testing.allocator));

    try testing.expectEqual(@as(u16, 200), try t.status("POST /user-token?engine=" ++ nonce ++ " HTTP/1.1\r\nHost: localhost:PORT\r\nOrigin: http://localhost:PORT\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"token\":\"x\"}"));
    try testing.expectEqual(@as(u16, 204), try t.status("POST /report HTTP/1.1\r\nHost: localhost:PORT\r\nOrigin: http://localhost:PORT\r\nContent-Length: 45\r\nConnection: close\r\n\r\n" ++ report));
    const last = (try t.channel.lastReport(testing.allocator)).?;
    testing.allocator.free(last.json);
}

test "the token routes answer only the current engine page" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    // No launch yet: nobody.
    try testing.expectEqual(@as(u16, 403), try t.status("GET /developer-token HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    t.channel.setNonce("ffffffffffffffffffffffffffffffff".*);
    try testing.expectEqual(@as(u16, 403), try t.status("GET /developer-token HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET /developer-token?engine=stale HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET /user-token HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET /user-token?engine=null HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 200), try t.status("GET /developer-token?engine=ffffffffffffffffffffffffffffffff HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 204), try t.status("GET /user-token?engine=ffffffffffffffffffffffffffffffff HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    // The Host check still comes first.
    try testing.expectEqual(@as(u16, 403), try t.status("GET /developer-token?engine=ffffffffffffffffffffffffffffffff HTTP/1.1\r\nHost: evil.example:PORT\r\nConnection: close\r\n\r\n"));
}

test "the sign-in page's nonce gets the developer token and may post a token, but never reads one" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    const signin = "99999999999999999999999999999999";
    t.channel.setSigninNonce(signin.*);
    const post = "POST /user-token?engine={s} HTTP/1.1\r\nHost: localhost:PORT\r\nOrigin: http://localhost:PORT\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{{\"token\":\"x\"}}";
    var buf: [512]u8 = undefined;

    try testing.expectEqual(@as(u16, 200), try t.status("GET /developer-token?engine=" ++ signin ++ " HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 403), try t.status("GET /user-token?engine=" ++ signin ++ " HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 200), try t.status(try std.fmt.bufPrint(&buf, post, .{signin})));
    try testing.expectEqual(@as(usize, 1), t.fake.token_posts);
    // Without the nonce, or with an old one, a local process can't plant a token.
    try testing.expectEqual(@as(u16, 403), try t.status(try std.fmt.bufPrint(&buf, post, .{"stale"})));
    try testing.expectEqual(@as(u16, 403), try t.status("POST /user-token HTTP/1.1\r\nHost: localhost:PORT\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"token\":\"x\"}"));
    t.channel.setSigninNonce(null);
    try testing.expectEqual(@as(u16, 403), try t.status(try std.fmt.bufPrint(&buf, post, .{signin})));
    // None of the refused posts reached the check.
    try testing.expectEqual(@as(usize, 1), t.fake.token_posts);
    try testing.expectEqual(@as(u16, 403), try t.status("GET /developer-token?engine=" ++ signin ++ " HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
}

test "claim and events answer 409 to a stale nonce" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    t.channel.setNonce("dddddddddddddddddddddddddddddddd".*);
    try testing.expectEqual(@as(u16, 409), try t.status("GET /claim?engine=stale HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 409), try t.status("GET /events?engine=stale HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
    try testing.expectEqual(@as(u16, 409), try t.status("POST /report HTTP/1.1\r\nHost: localhost:PORT\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"engine\":\"stale\"}"));
    try testing.expectEqual(@as(u16, 204), try t.status("GET /claim?engine=dddddddddddddddddddddddddddddddd HTTP/1.1\r\nHost: localhost:PORT\r\nConnection: close\r\n\r\n"));
}

fn readEvents(t: *TestServer, out: *[2048]u8) !usize {
    const io = testing.io;
    const address: net.IpAddress = .{ .ip4 = .loopback(t.server.port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [512]u8 = undefined;
    var w = stream.writer(io, &write_buffer);
    try w.interface.print("GET /events?engine=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee HTTP/1.1\r\nHost: localhost:{d}\r\n\r\n", .{t.server.port});
    try w.interface.flush();
    var read_buffer: [2048]u8 = undefined;
    var r = stream.reader(io, &read_buffer);
    // Until the command shows up: the head, ": connected", then the command's data line.
    var len: usize = 0;
    while (std.mem.find(u8, out[0..len], "data: ") == null or !std.mem.endsWith(u8, out[0..len], "\n\n\r\n")) {
        const n = try r.interface.readSliceShort(out[len .. len + 1]);
        if (n == 0) return error.EndOfStream;
        len += n;
    }
    return len;
}

test "the event stream carries commands to the page as SSE data lines" {
    var t: TestServer = undefined;
    try t.start();
    defer t.stop();
    t.channel.setNonce("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee".*);

    var out: [2048]u8 = undefined;
    var reader = try testing.io.concurrent(readEvents, .{ &t, &out });
    var tries: usize = 0;
    while (!t.channel.connected() and tries < 200) : (tries += 1) try testing.io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Timeout, t.channel.call(testing.allocator, "snapshot", "[]", .fromMilliseconds(200)));
    const len = try reader.await(testing.io);
    const response = out[0..len];
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.ascii.findIgnoreCase(response, "content-type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.find(u8, response, ": connected\n\n") != null);
    try testing.expect(std.mem.find(u8, response, "data: {\"id\":1,\"method\":\"snapshot\",\"args\":[]}\n\n") != null);
}
