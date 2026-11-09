//! Which developer token `am` uses: the user's own (signed by `am token --key-stdin` with their
//! MusicKit key, for the TEAM_ID and KEY_ID set) when it is usable, else the shared one that the
//! token service signs (token-worker/, SETUP.md section 6).
//!
//! The shared one is downloaded from `TOKEN_URL` and kept in the config dir, with the URL it
//! came from, until fewer than `refresh_days` are left on it. A download that fails (or doesn't
//! answer within `download_timeout_s`) keeps the kept one in use while it lasts, and isn't tried
//! again for `backoff_s`. When Apple refuses a shared token with 401 (the service's key changed,
//! or a long-running TUI outlived it), `Renewer` downloads a newer one once, under the same
//! backoff.
//!
//! `choose` and `renewChoice` decide from what the caller read; `get` and `renewNow` read the
//! config dir, decide, and keep what they downloaded.
const std = @import("std");
const apple = @import("apple.zig");
const config = @import("config.zig");
const deadline = @import("deadline.zig");
const developer_token = @import("developer_token.zig");
const platform = @import("platform.zig");
const settings_mod = @import("settings.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const UtcTime = developer_token.UtcTime;

/// A kept shared token with fewer days left than this is downloaded again. The service signs
/// them for 7 days, so several failed days in a row still leave a working one.
pub const refresh_days = 5;

/// After a failed download, the kept token is used without trying again for this long.
pub const backoff_s = 3600;

/// After a failed download with no usable token kept, the next try waits this long: short,
/// since nothing works meanwhile, yet a page fetching the token again and again doesn't wait
/// out the timeout every time.
pub const retry_without_token_s = 60;

/// A download that hasn't answered by then counts as failed.
pub const download_timeout_s = 10;

/// The only port a shared token works on: its origin claim names the engine page there
/// (`apple.origin`).
pub const shared_port = settings_mod.default_port;

const day = std.time.s_per_day;

pub const Source = enum { own, shared };

pub const Found = struct {
    token: []const u8,
    source: Source,
    decoded: developer_token.Decoded,
    /// The shared token's service.
    url: ?[]const u8 = null,
    /// An own token with less than `developer_token.warn_days` left. A shared one renews itself.
    expiring_soon: bool = false,
    /// A shared token: why a newer one couldn't be downloaded (the kept one still works).
    refresh_failed: ?[]const u8 = null,
    /// A shared token while TEAM_ID and KEY_ID are set: why the user's own isn't used.
    own_problem: ?[]const u8 = null,

    /// `your own, kid=… iss=… expires …` or `shared, from <url>, kid=… iss=… expires …`.
    pub fn format(f: Found, w: *Io.Writer) Io.Writer.Error!void {
        switch (f.source) {
            .own => try w.writeAll("your own"),
            .shared => try w.print("shared, from {s}", .{f.url orelse "?"}),
        }
        try w.print(", kid={s} iss={s} expires {f}", .{ f.decoded.header.kid, f.decoded.claims.iss, UtcTime{ .unix = f.decoded.claims.exp } });
    }
};

pub const Problem = struct {
    /// Why there is no token, and what to do.
    text: []const u8,
    /// Neither TEAM_ID and KEY_ID (for an own token) nor a token service is set: nothing to try.
    nothing_set: bool = false,
};

pub const Result = union(enum) {
    found: Found,
    problem: Problem,
};

/// `AM_PORT`, or why its value isn't a port.
pub const Port = settings_mod.Checked(u16);

/// `TOKEN_URL`: the token service's URL (null: there is none), or why it isn't one.
pub const Url = settings_mod.Checked(?[]const u8);

/// The kept shared token's file: the token, the service it came from, and when a download from
/// there last failed (Unix seconds), one per line.
pub const Kept = struct {
    token: ?[]const u8 = null,
    url: ?[]const u8 = null,
    failed_at: ?i64 = null,

    /// A damaged or older file (no URL line) reads as nothing kept, or as another service's.
    pub fn parse(text: ?[]const u8) Kept {
        var lines = std.mem.splitScalar(u8, text orelse return .{}, '\n');
        const token = config.storedToken(lines.next());
        const url = config.trimSpace(lines.next() orelse "");
        const failed_at = std.fmt.parseInt(i64, config.trimSpace(lines.next() orelse ""), 10) catch null;
        return .{ .token = token, .url = if (url.len == 0) null else url, .failed_at = failed_at };
    }

    pub fn serialize(k: Kept, arena: Allocator) Allocator.Error![]const u8 {
        var failed: [24]u8 = undefined;
        const at = if (k.failed_at) |t| std.fmt.bufPrint(&failed, "{d}", .{t}) catch unreachable else "";
        return arena.print("{s}\n{s}\n{s}\n", .{ k.token orelse "", k.url orelse "", at });
    }
};

pub const Input = struct {
    /// TEAM_ID and KEY_ID, when both are set.
    ids: ?developer_token.Ids,
    /// The stored own token (`config.storedToken`), if any.
    own: ?[]const u8,
    kept: Kept,
    url: Url,
    port: Port,
    /// Unix seconds.
    now: i64,
    /// The env file, for the messages.
    env_path: []const u8,
    /// How long a download may take.
    timeout: Io.Duration = .fromSeconds(download_timeout_s),
};

pub const Choice = struct {
    result: Result,
    /// What to write to the kept token's file; null leaves it as it is.
    keep: ?Kept = null,
};

pub const Error = Allocator.Error || Io.Cancelable;

/// The own token if it is usable; else the kept shared token while it has `refresh_days` left
/// (or a download failed within `backoff_s`); else a fresh one from the service (`transport`
/// GETs `url`); else the kept one while it lasts.
pub fn choose(arena: Allocator, io: Io, in: Input, transport: apple.Transport) Error!Choice {
    var own_problem: ?[]const u8 = null;
    if (in.ids) |ids| {
        const status = try developer_token.check(arena, in.own, ids, in.now);
        switch (status) {
            .usable => |u| return found(.{ .token = in.own.?, .source = .own, .decoded = u.decoded, .expiring_soon = u.expiring_soon }),
            else => own_problem = try arena.print("{f}", .{developer_token.Problem{ .status = status }}),
        }
    }
    const service = switch (in.url) {
        .ok => |url| url,
        .bad => |why| return problem(try orOwn(arena, own_problem, why), false),
    };
    const url = service orelse return problem(own_problem orelse try arena.print(
        "no developer token: put TEAM_ID=<your Apple Developer Team ID> and KEY_ID=<the ID of your MusicKit key> in {s} and run am token --key-stdin, or set TOKEN_URL=<the shared token service> there",
        .{in.env_path},
    ), own_problem == null);
    if (try wrongPort(arena, in.port)) |why| return problem(try orOwn(arena, own_problem, why), false);

    const kept = try keptToken(arena, in.kept, url, in.now);
    if (kept) |k| {
        if (k.decoded.claims.exp - in.now >= refresh_days * day) return found(withOwn(k, own_problem));
        if (recentFailure(in.kept, url, in.now, backoff_s)) |at| {
            var still = withOwn(k, own_problem);
            still.refresh_failed = try arena.print("the last download failed at {f}; the next try is after {f}", .{
                UtcTime{ .unix = at }, UtcTime{ .unix = at + backoff_s },
            });
            return found(still);
        }
    } else if (recentFailure(in.kept, url, in.now, retry_without_token_s)) |at| {
        return problem(try orOwn(arena, own_problem, try arena.print(
            "can't get the shared developer token from {s}: the last download failed at {f}; the next try is after {f}",
            .{ url, UtcTime{ .unix = at }, UtcTime{ .unix = at + retry_without_token_s } },
        )), false);
    }
    switch (try download(arena, io, url, transport, in.now, in.timeout)) {
        .token => |t| return .{
            .result = .{ .found = withOwn(.{ .token = t.token, .source = .shared, .decoded = t.decoded, .url = url }, own_problem) },
            .keep = .{ .token = t.token, .url = url },
        },
        .failed => |why| {
            if (kept) |k| {
                var still = withOwn(k, own_problem);
                still.refresh_failed = why;
                return .{ .result = .{ .found = still }, .keep = .{ .token = k.token, .url = url, .failed_at = in.now } };
            }
            var no = problem(try orOwn(arena, own_problem, try arena.print(
                "can't get the shared developer token from {s} ({s}): try again later, or sign your own token (am token --key-stdin)",
                .{ url, why },
            )), false);
            no.keep = .{ .url = url, .failed_at = in.now };
            return no;
        },
    }
}

/// What a renewal did.
pub const Outcome = union(enum) {
    /// Nothing to renew: the refused token is the user's own, or there's no usable service.
    none,
    /// The user's own token is usable again: it replaces the refused shared one.
    own,
    /// A newer token was kept already (another request renewed it).
    kept,
    downloaded,
    /// The service still hands out the refused token. Counts as a failure for the backoff: no
    /// try before this time (Unix seconds).
    same: i64,
    /// The download failed: why.
    failed: []const u8,
    /// A download failed lately: no try before this time (Unix seconds).
    backoff: i64,

    /// A line for `am token`, after Apple refused a shared token.
    pub fn format(o: Outcome, w: *Io.Writer) Io.Writer.Error!void {
        switch (o) {
            .none => try w.writeAll("no newer developer token to try"),
            .own => try w.writeAll("switched to your own developer token, which is usable again"),
            .kept => try w.writeAll("switched to the newer shared developer token already downloaded"),
            .downloaded => try w.writeAll("downloaded a newer shared developer token"),
            .same => |next| try w.print("the token service still hands out the refused token; the next try is after {f}", .{UtcTime{ .unix = next }}),
            .failed => |why| try w.print("can't download a newer shared developer token ({s})", .{why}),
            .backoff => |next| try w.print("not trying to download a newer shared developer token yet: the last try failed; the next try is after {f}", .{UtcTime{ .unix = next }}),
        }
    }
};

pub const Renewal = struct {
    /// The token to try instead; null when there is none.
    token: ?[]const u8 = null,
    keep: ?Kept = null,
    outcome: Outcome = .none,
};

/// After Apple refused `refused` with 401: the user's own token when it is usable and another
/// one; the kept shared token when it is another one (already renewed); else a fresh download,
/// unless one failed within `backoff_s` (`retry_without_token_s` when no unexpired token is
/// kept). Nothing for a refused own token: that one is theirs to sign again.
pub fn renewChoice(arena: Allocator, io: Io, in: Input, refused: []const u8, transport: apple.Transport) Error!Renewal {
    if (in.own) |own| {
        if (std.mem.eql(u8, own, refused)) return .{};
        if (in.ids) |ids| if ((try developer_token.check(arena, own, ids, in.now)) == .usable) return .{ .token = own, .outcome = .own };
    }
    const url = switch (in.url) {
        .ok => |url| url orelse return .{},
        .bad => return .{},
    };
    if (try wrongPort(arena, in.port) != null) return .{};
    const kept = try keptToken(arena, in.kept, url, in.now);
    if (kept) |k| if (!std.mem.eql(u8, k.token, refused)) return .{ .token = k.token, .outcome = .kept };
    // As in `choose`: with no unexpired token kept, nothing works meanwhile, so the wait is short.
    const wait: i64 = if (kept != null) backoff_s else retry_without_token_s;
    if (recentFailure(in.kept, url, in.now, wait)) |at| return .{ .outcome = .{ .backoff = at + wait } };
    switch (try download(arena, io, url, transport, in.now, in.timeout)) {
        .token => |t| {
            // The service still hands out the refused one: sending it again won't help, and
            // asking again soon won't either.
            if (std.mem.eql(u8, t.token, refused)) return .{
                .keep = .{ .token = t.token, .url = url, .failed_at = in.now },
                .outcome = .{ .same = in.now + backoff_s },
            };
            return .{ .token = t.token, .keep = .{ .token = t.token, .url = url }, .outcome = .downloaded };
        },
        .failed => |why| {
            const same_service = if (in.kept.url) |u| std.mem.eql(u8, u, url) else false;
            return .{
                .keep = .{ .token = if (same_service) in.kept.token else null, .url = url, .failed_at = in.now },
                .outcome = .{ .failed = why },
            };
        },
    }
}

fn found(f: Found) Choice {
    return .{ .result = .{ .found = f } };
}

fn withOwn(f: Found, own_problem: ?[]const u8) Found {
    var with = f;
    with.own_problem = own_problem;
    return with;
}

fn problem(text: []const u8, nothing_set: bool) Choice {
    return .{ .result = .{ .problem = .{ .text = text, .nothing_set = nothing_set } } };
}

/// The own token's problem first (the user set TEAM_ID and KEY_ID, so it's theirs to fix), then
/// why the shared one didn't help.
fn orOwn(arena: Allocator, own: ?[]const u8, shared: []const u8) Allocator.Error![]const u8 {
    const o = own orelse return shared;
    return arena.print("{s}; and {s}", .{ o, shared });
}

/// Why a shared token can't work on `port`, if it can't.
fn wrongPort(arena: Allocator, port: Port) Allocator.Error!?[]const u8 {
    switch (port) {
        .bad => |why| return try arena.print("{s}, and the shared developer token works only on port {d}", .{ why, shared_port }),
        .ok => |p| if (p != shared_port) return try arena.print(
            "the shared developer token works only on port {d}, and AM_PORT is {d}: unset AM_PORT, or sign your own token (am token --key-stdin)",
            .{ shared_port, p },
        ),
    }
    return null;
}

/// The kept token, if it came from `url`, reads as a token and hasn't expired.
fn keptToken(arena: Allocator, kept: Kept, url: []const u8, now: i64) Allocator.Error!?Found {
    const token = kept.token orelse return null;
    const from = kept.url orelse return null;
    if (!std.mem.eql(u8, from, url)) return null;
    const decoded = developer_token.decode(arena, token) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (decoded.claims.exp <= now) return null;
    return .{ .token = token, .source = .shared, .decoded = decoded, .url = url };
}

/// When a download from `url` failed less than `window` seconds ago.
fn recentFailure(kept: Kept, url: []const u8, now: i64, window: i64) ?i64 {
    const at = kept.failed_at orelse return null;
    const from = kept.url orelse return null;
    if (!std.mem.eql(u8, from, url)) return null;
    return if (at <= now and now - at < window) at else null;
}

const Downloaded = union(enum) {
    token: struct { token: []const u8, decoded: developer_token.Decoded },
    /// Why not.
    failed: []const u8,
};

fn download(arena: Allocator, io: Io, url: []const u8, transport: apple.Transport, now: i64, timeout: Io.Duration) Error!Downloaded {
    const answer = try deadline.withTimeout(io, timeout, fetch, .{ transport, arena, url }) orelse {
        const ms = timeout.toMilliseconds();
        return .{ .failed = if (@mod(ms, 1000) == 0)
            try arena.print("no answer within {d} s", .{@divExact(ms, 1000)})
        else
            try arena.print("no answer within {d} ms", .{ms}) };
    };
    const response = answer catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .{ .failed = try arena.print("{t}", .{e}) },
    };
    if (response.status != 200) return .{ .failed = try arena.print("HTTP {d}{s}{s}", .{
        response.status, if (said(response.body).len > 0) ": " else "", said(response.body),
    }) };
    const token = config.storedToken(response.body) orelse return .{ .failed = "it didn't answer a token" };
    const decoded = developer_token.decode(arena, token) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = "it didn't answer a token" },
    };
    if (decoded.claims.exp <= now) return .{ .failed = "it answered an expired token" };
    return .{ .token = .{ .token = token, .decoded = decoded } };
}

fn fetch(transport: apple.Transport, arena: Allocator, url: []const u8) anyerror!apple.Response {
    return transport.get(arena, url, &.{});
}

/// The first line of the service's answer, at most 120 bytes, printable ASCII only.
fn said(body: []const u8) []const u8 {
    const line = config.trimSpace(body[0 .. std.mem.findScalar(u8, body, '\n') orelse body.len]);
    const short = line[0..@min(line.len, 120)];
    for (short) |c| if (!std.ascii.isPrint(c)) return "";
    return short;
}

pub const Env = struct {
    io: Io,
    config_dir: []const u8,
    ids: ?developer_token.Ids,
    url: Url,
    port: Port,
    transport: apple.Transport,
    now: i64,

    pub fn fromSettings(io: Io, config_dir: []const u8, settings: *const settings_mod.Settings, transport: apple.Transport, now: i64) Env {
        return .{
            .io = io,
            .config_dir = config_dir,
            .ids = settings.ids(),
            .url = settings.token_url,
            .port = settings.port,
            .transport = transport,
            .now = now,
        };
    }
};

pub const GetError = Error || config.ReadFileError;

/// Reads both token files, chooses, and keeps what was downloaded (mode 600). A token that
/// can't be kept is still used; the next run downloads again.
pub fn get(arena: Allocator, env: Env) GetError!Result {
    const choice = try choose(arena, env.io, try readInput(arena, env), env.transport);
    if (choice.keep) |k| try writeKept(arena, env, k);
    return choice.result;
}

/// `renewChoice` on the config dir; keeps what it downloaded or that it failed.
pub fn renewNow(arena: Allocator, env: Env, refused: []const u8) GetError!Renewal {
    const renewal = try renewChoice(arena, env.io, try readInput(arena, env), refused, env.transport);
    if (renewal.keep) |k| try writeKept(arena, env, k);
    return renewal;
}

/// `apple.Renew` on the config dir, for one command or one daemon request (one thread): the
/// clock is read at each call, and the last replacement and outcome are remembered, the tokens
/// copied into `arena`.
pub const Renewer = struct {
    env: Env,
    arena: Allocator,
    /// The last renewal's refused token and what replaced it.
    refused: ?[]const u8 = null,
    fresh: ?[]const u8 = null,
    /// What the last renewal did, for `am token`.
    last: ?Outcome = null,

    pub fn renew(r: *Renewer) apple.Renew {
        return .{ .ptr = r, .vtable = &.{ .renew = renewFn, .replacement = replacementFn } };
    }

    fn renewFn(ptr: *anyopaque, arena: Allocator, refused: []const u8) Io.Cancelable!?[]const u8 {
        const r: *Renewer = @ptrCast(@alignCast(ptr));
        var env = r.env;
        env.now = Io.Clock.real.now(env.io).toSeconds();
        const renewal = renewNow(arena, env, refused) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {
                r.last = .{ .failed = @errorName(e) };
                return null;
            },
        };
        r.last = renewal.outcome;
        const fresh = renewal.token orelse return null;
        r.refused = r.arena.dupe(u8, refused) catch return fresh;
        r.fresh = r.arena.dupe(u8, fresh) catch {
            r.refused = null;
            return fresh;
        };
        return fresh;
    }

    fn replacementFn(ptr: *anyopaque, _: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
        const r: *Renewer = @ptrCast(@alignCast(ptr));
        const refused = r.refused orelse return null;
        return if (std.mem.eql(u8, refused, token)) r.fresh else null;
    }
};

fn readInput(arena: Allocator, env: Env) config.ReadFileError!Input {
    return .{
        .ids = env.ids,
        .own = config.storedToken(try config.readFile(env.io, arena, env.config_dir, config.file.developer_token)),
        .kept = .parse(try config.readFile(env.io, arena, env.config_dir, config.file.shared_developer_token)),
        .url = env.url,
        .port = env.port,
        .now = env.now,
        .env_path = try Io.Dir.path.join(arena, &.{ env.config_dir, config.file.env }),
    };
}

fn writeKept(arena: Allocator, env: Env, k: Kept) Allocator.Error!void {
    platform.writePrivateFile(env.io, env.config_dir, config.file.shared_developer_token, try k.serialize(arena)) catch {};
}

const testing = std.testing;

/// A developer token `developer_token.decode` reads: header and claims only, no real signature.
pub fn fakeToken(arena: Allocator, kid: []const u8, iss: []const u8, exp: i64) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = try std.fmt.allocPrint(arena, "{{\"alg\":\"ES256\",\"kid\":\"{s}\"}}", .{kid});
    const claims = try std.fmt.allocPrint(arena, "{{\"iss\":\"{s}\",\"iat\":0,\"exp\":{d}}}", .{ iss, exp });
    const h = try arena.alloc(u8, enc.calcSize(header.len));
    const c = try arena.alloc(u8, enc.calcSize(claims.len));
    return std.fmt.allocPrint(arena, "{s}.{s}.c2ln", .{ enc.encode(h, header), enc.encode(c, claims) });
}

/// Answers every GET with `response` (or fails with `fail`, or never answers with `hang`), and
/// counts them.
const FakeService = struct {
    response: apple.Response = .{ .status = 200, .body = "" },
    fail: ?anyerror = null,
    hang: bool = false,
    requests: usize = 0,
    last_url: []const u8 = "",
    last_headers: usize = 0,

    fn transport(f: *FakeService) apple.Transport {
        return .{ .ptr = f, .requestFn = request };
    }

    fn request(ptr: *anyopaque, _: Allocator, method: apple.Method, url: []const u8, headers: []const std.http.Header, _: ?[]const u8) anyerror!apple.Response {
        const f: *FakeService = @ptrCast(@alignCast(ptr));
        try testing.expectEqual(apple.Method.GET, method);
        f.requests += 1;
        f.last_url = url;
        f.last_headers = headers.len;
        if (f.hang) try testing.io.sleep(.fromSeconds(600), .awake);
        if (f.fail) |e| return e;
        return f.response;
    }
};

const t0: i64 = 1_800_000_000;
const test_url = "https://am-token.example.workers.dev/token";

fn baseInput() Input {
    return .{ .ids = null, .own = null, .kept = .{}, .url = .{ .ok = test_url }, .port = .{ .ok = 47823 }, .now = t0, .env_path = "/home/u/.config/am/env" };
}

fn keptFrom(token: []const u8) Kept {
    return .{ .token = token, .url = test_url };
}

test "a usable own token wins: the service isn't asked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{};
    var in = baseInput();
    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    in.own = try fakeToken(a, "KEY", "TEAM", t0 + 100 * day);
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 6 * day));
    const choice = try choose(a, testing.io, in, service.transport());
    try testing.expectEqual(Source.own, choice.result.found.source);
    try testing.expectEqualStrings(in.own.?, choice.result.found.token);
    try testing.expect(!choice.result.found.expiring_soon);
    try testing.expectEqual(null, choice.result.found.own_problem);
    try testing.expectEqual(null, choice.keep);
    try testing.expectEqual(@as(usize, 0), service.requests);
    try testing.expect(std.mem.startsWith(u8, try std.fmt.allocPrint(a, "{f}", .{choice.result.found}), "your own, kid=KEY iss=TEAM expires "));

    // Close to its end, it says so; it's still the one used.
    in.own = try fakeToken(a, "KEY", "TEAM", t0 + 3 * day);
    try testing.expect((try choose(a, testing.io, in, service.transport())).result.found.expiring_soon);
}

test "no own token: a kept shared one with 5 days or more left is used as it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{};
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 5 * day));
    const choice = try choose(a, testing.io, in, service.transport());
    const f = choice.result.found;
    try testing.expectEqual(Source.shared, f.source);
    try testing.expectEqualStrings(in.kept.token.?, f.token);
    try testing.expectEqual(null, f.refresh_failed);
    try testing.expectEqual(null, f.own_problem);
    try testing.expectEqual(null, choice.keep);
    try testing.expectEqual(@as(usize, 0), service.requests);
    try testing.expect(std.mem.startsWith(u8, try std.fmt.allocPrint(a, "{f}", .{f}), "shared, from " ++ test_url ++ ", kid=SHARED iss=TEAM expires "));
}

test "an own token that doesn't work falls back to the shared one, and its problem is reported with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{};
    var in = baseInput();
    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    in.own = try fakeToken(a, "KEY", "TEAM", t0 - 1);
    in.kept = keptFrom(try fakeToken(a, "OTHERKEY", "OTHERTEAM", t0 + 6 * day));
    const f = (try choose(a, testing.io, in, service.transport())).result.found;
    try testing.expectEqual(Source.shared, f.source);
    try testing.expect(std.mem.startsWith(u8, f.own_problem.?, "developer token expired ("));

    in.own = try fakeToken(a, "OTHER", "TEAM", t0 + 100 * day);
    const mismatch = (try choose(a, testing.io, in, service.transport())).result.found;
    try testing.expect(std.mem.find(u8, mismatch.own_problem.?, "another KEY_ID or TEAM_ID") != null);
}

test "under 5 days left: a fresh token is downloaded, with no tokens or Origin sent, and kept with its URL" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fresh = try fakeToken(a, "SHARED", "TEAM", t0 + 7 * day);
    var service: FakeService = .{ .response = .{ .status = 200, .body = try std.mem.concat(a, u8, &.{ fresh, "\n" }) } };
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 5 * day - 1));
    const choice = try choose(a, testing.io, in, service.transport());
    try testing.expectEqualStrings(fresh, choice.result.found.token);
    try testing.expectEqualStrings(fresh, choice.keep.?.token.?);
    try testing.expectEqualStrings(test_url, choice.keep.?.url.?);
    try testing.expectEqual(null, choice.keep.?.failed_at);
    try testing.expectEqual(@as(usize, 1), service.requests);
    try testing.expectEqualStrings(test_url, service.last_url);
    try testing.expectEqual(@as(usize, 0), service.last_headers);

    // Nothing kept, a damaged file, or an expired token: the same.
    for ([_]Kept{ .{}, .parse("garbage\n" ++ test_url), keptFrom(try fakeToken(a, "SHARED", "TEAM", t0)) }) |kept| {
        in.kept = kept;
        try testing.expectEqualStrings(fresh, (try choose(a, testing.io, in, service.transport())).keep.?.token.?);
    }
}

test "a kept token from another service isn't used: after TOKEN_URL changes, the new one is asked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fresh = try fakeToken(a, "NEW", "TEAM", t0 + 7 * day);
    var service: FakeService = .{ .response = .{ .status = 200, .body = fresh } };
    var in = baseInput();
    in.kept = .{ .token = try fakeToken(a, "OLD", "TEAM", t0 + 6 * day), .url = "https://old.example/token" };
    const choice = try choose(a, testing.io, in, service.transport());
    try testing.expectEqualStrings(fresh, choice.result.found.token);
    try testing.expectEqualStrings(test_url, choice.result.found.url.?);
    try testing.expectEqual(@as(usize, 1), service.requests);
    // An older file without the URL line is another service's too.
    in.kept = .parse(try fakeToken(a, "OLD", "TEAM", t0 + 6 * day));
    try testing.expectEqual(null, in.kept.url);
    try testing.expectEqualStrings(fresh, (try choose(a, testing.io, in, service.transport())).result.found.token);
    // A failure noted for the old service doesn't hold back the new one.
    in.kept = .{ .token = null, .url = "https://old.example/token", .failed_at = t0 - 1 };
    try testing.expectEqualStrings(fresh, (try choose(a, testing.io, in, service.transport())).result.found.token);
}

test "a failed download keeps the kept token while it lasts, says why, and notes when" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 2 * day));
    const Case = struct { service: FakeService, why: []const u8 };
    const cases = [_]Case{
        .{ .service = .{ .fail = error.ConnectionRefused }, .why = "ConnectionRefused" },
        .{ .service = .{ .response = .{ .status = 503, .body = "the shared developer token is switched off\n" } }, .why = "HTTP 503: the shared developer token is switched off" },
        .{ .service = .{ .response = .{ .status = 500, .body = "" } }, .why = "HTTP 500" },
        .{ .service = .{ .response = .{ .status = 200, .body = "<html>hi</html>" } }, .why = "it didn't answer a token" },
        .{ .service = .{ .response = .{ .status = 200, .body = "a.b" } }, .why = "it didn't answer a token" },
        .{ .service = .{ .response = .{ .status = 200, .body = try fakeToken(a, "S", "T", t0) } }, .why = "it answered an expired token" },
    };
    for (cases) |case| {
        var service = case.service;
        const choice = try choose(a, testing.io, in, service.transport());
        try testing.expectEqualStrings(in.kept.token.?, choice.result.found.token);
        try testing.expectEqualStrings(case.why, choice.result.found.refresh_failed.?);
        try testing.expectEqualDeep(Kept{ .token = in.kept.token, .url = test_url, .failed_at = t0 }, choice.keep.?);
    }
}

test "after a failed download, the kept token is used for an hour without asking the service again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{ .response = .{ .status = 200, .body = try fakeToken(a, "NEW", "TEAM", t0 + 7 * day) } };
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 2 * day));
    in.kept.failed_at = t0 - backoff_s + 1;
    const held = try choose(a, testing.io, in, service.transport());
    try testing.expectEqualStrings(in.kept.token.?, held.result.found.token);
    try testing.expect(std.mem.startsWith(u8, held.result.found.refresh_failed.?, "the last download failed at "));
    try testing.expectEqual(null, held.keep);
    try testing.expectEqual(@as(usize, 0), service.requests);

    // An hour on, it's asked again.
    in.kept.failed_at = t0 - backoff_s;
    const fresh = try choose(a, testing.io, in, service.transport());
    try testing.expectEqualStrings("NEW", fresh.result.found.decoded.header.kid);
    try testing.expectEqual(@as(usize, 1), service.requests);

    // With nothing usable kept, a failure holds the next try back for a minute only.
    in.kept = .{ .url = test_url, .failed_at = t0 - retry_without_token_s + 1 };
    const waiting = try choose(a, testing.io, in, service.transport());
    try testing.expect(std.mem.startsWith(u8, waiting.result.problem.text, "can't get the shared developer token from " ++ test_url ++ ": the last download failed at "));
    try testing.expect(std.mem.find(u8, waiting.result.problem.text, "; the next try is after ") != null);
    try testing.expectEqual(null, waiting.keep);
    try testing.expectEqual(@as(usize, 1), service.requests);
    in.kept.failed_at = t0 - retry_without_token_s;
    try testing.expectEqualStrings("NEW", (try choose(a, testing.io, in, service.transport())).result.found.decoded.header.kid);
    try testing.expectEqual(@as(usize, 2), service.requests);
}

test "a service that doesn't answer counts as failed after the timeout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{ .hang = true };
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 2 * day));
    in.timeout = .fromMilliseconds(100);
    const start: Io.Clock.Timestamp = .now(testing.io, .awake);
    const choice = try choose(a, testing.io, in, service.transport());
    try testing.expectEqualStrings("no answer within 100 ms", choice.result.found.refresh_failed.?);
    try testing.expectEqual(t0, choice.keep.?.failed_at.?);
    try testing.expect(start.untilNow(testing.io).raw.toSeconds() < 30);
    // The default is 10 s.
    try testing.expectEqual(@as(i64, 10_000), baseInput().timeout.toMilliseconds());
}

test "a failed download with nothing usable kept: the problem names the service and why" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{ .fail = error.ConnectionRefused };
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 - day));
    const choice = try choose(a, testing.io, in, service.transport());
    const p = choice.result.problem;
    try testing.expectEqualStrings("can't get the shared developer token from " ++ test_url ++ " (ConnectionRefused): try again later, or sign your own token (am token --key-stdin)", p.text);
    try testing.expect(!p.nothing_set);
    // The failure is noted, so the next calls (the engine page's fetch) don't wait out the timeout.
    try testing.expectEqualDeep(Kept{ .url = test_url, .failed_at = t0 }, choice.keep.?);

    // With TEAM_ID and KEY_ID set, the own token's problem comes first.
    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    const both = (try choose(a, testing.io, in, service.transport())).result.problem.text;
    try testing.expect(std.mem.startsWith(u8, both, "developer token missing: run am token --key-stdin; and can't get the shared developer token from "));
}

test "no TOKEN_URL: the own token's problem, or what to set when neither is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{};
    var in = baseInput();
    in.url = .{ .ok = null };
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 6 * day));
    const nothing = (try choose(a, testing.io, in, service.transport())).result.problem;
    try testing.expect(nothing.nothing_set);
    try testing.expect(std.mem.startsWith(u8, nothing.text, "no developer token: put TEAM_ID="));
    try testing.expect(std.mem.find(u8, nothing.text, "/home/u/.config/am/env") != null);
    try testing.expect(std.mem.find(u8, nothing.text, "TOKEN_URL=") != null);

    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    const own = (try choose(a, testing.io, in, service.transport())).result.problem;
    try testing.expect(!own.nothing_set);
    try testing.expectEqualStrings("developer token missing: run am token --key-stdin", own.text);
    try testing.expectEqual(@as(usize, 0), service.requests);
}

test "AM_PORT matters only for the shared token: another port or a bad value stops it, an own token doesn't mind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{};
    var in = baseInput();
    in.kept = keptFrom(try fakeToken(a, "SHARED", "TEAM", t0 + 6 * day));
    in.port = .{ .ok = 48000 };
    try testing.expectEqualStrings(
        "the shared developer token works only on port 47823, and AM_PORT is 48000: unset AM_PORT, or sign your own token (am token --key-stdin)",
        (try choose(a, testing.io, in, service.transport())).result.problem.text,
    );
    in.port = .{ .bad = "AM_PORT must be a port number (1-65535), not abc" };
    try testing.expectEqualStrings(
        "AM_PORT must be a port number (1-65535), not abc, and the shared developer token works only on port 47823",
        (try choose(a, testing.io, in, service.transport())).result.problem.text,
    );
    try testing.expectEqual(@as(usize, 0), service.requests);

    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    in.own = try fakeToken(a, "KEY", "TEAM", t0 + 100 * day);
    for ([_]Port{ .{ .ok = 48000 }, .{ .bad = "AM_PORT must be a port number (1-65535), not abc" } }) |port| {
        in.port = port;
        try testing.expectEqual(Source.own, (try choose(a, testing.io, in, service.transport())).result.found.source);
    }
}

test "a bad TOKEN_URL is why there is no shared token, after the own token's problem, and nothing is downloaded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: FakeService = .{};
    var in = baseInput();
    in.url = .{ .bad = "TOKEN_URL must be an https:// URL (or http://localhost:<port> or http://127.0.0.1:<port>), not ftp://x" };
    try testing.expectEqualStrings(
        "TOKEN_URL must be an https:// URL (or http://localhost:<port> or http://127.0.0.1:<port>), not ftp://x",
        (try choose(a, testing.io, in, service.transport())).result.problem.text,
    );
    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    const problem_text = (try choose(a, testing.io, in, service.transport())).result.problem.text;
    try testing.expect(std.mem.startsWith(u8, problem_text, "developer token missing"));
    try testing.expect(std.mem.endsWith(u8, problem_text, "; and TOKEN_URL must be an https:// URL (or http://localhost:<port> or http://127.0.0.1:<port>), not ftp://x"));
    const renewal = try renewChoice(a, testing.io, in, "refused", service.transport());
    try testing.expectEqual(null, renewal.token);
    try testing.expectEqual(@as(usize, 0), service.requests);
}

test "renewing after Apple refused a shared token: a fresh download once, kept with its URL" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = try fakeToken(a, "OLDKEY", "TEAM", t0 + 6 * day);
    const fresh = try fakeToken(a, "NEWKEY", "TEAM", t0 + 7 * day);
    var service: FakeService = .{ .response = .{ .status = 200, .body = fresh } };
    var in = baseInput();
    in.kept = keptFrom(refused);
    const renewal = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqualStrings(fresh, renewal.token.?);
    try testing.expectEqualDeep(Kept{ .token = fresh, .url = test_url }, renewal.keep.?);
    try testing.expectEqual(Outcome.downloaded, renewal.outcome);
    try testing.expectEqual(@as(usize, 1), service.requests);

    // Already renewed (by another request): the kept one, no download.
    in.kept = keptFrom(fresh);
    const kept = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqualStrings(fresh, kept.token.?);
    try testing.expectEqual(Outcome.kept, kept.outcome);
    try testing.expectEqual(@as(usize, 1), service.requests);

    // The service still hands out the refused token: nothing to try, and that counts as a
    // failure, so the next 401 doesn't download again within the backoff.
    in.kept = keptFrom(refused);
    service.response = .{ .status = 200, .body = refused };
    const same = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqual(null, same.token);
    try testing.expectEqualDeep(Kept{ .token = refused, .url = test_url, .failed_at = t0 }, same.keep.?);
    try testing.expectEqual(t0 + backoff_s, same.outcome.same);
    in.kept = same.keep.?;
    const after = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqual(null, after.token);
    try testing.expectEqual(t0 + backoff_s, after.outcome.backoff);
    try testing.expectEqual(@as(usize, 2), service.requests);
}

test "renewing prefers the user's own token when it is usable again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = try fakeToken(a, "SHARED", "TEAM", t0 + 6 * day);
    var service: FakeService = .{ .response = .{ .status = 200, .body = try fakeToken(a, "NEWSHARED", "TEAM", t0 + 7 * day) } };
    var in = baseInput();
    in.ids = .{ .team_id = "TEAM", .key_id = "KEY" };
    in.own = try fakeToken(a, "KEY", "TEAM", t0 + 100 * day);
    in.kept = keptFrom(refused);
    const renewal = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqualStrings(in.own.?, renewal.token.?);
    try testing.expectEqual(Outcome.own, renewal.outcome);
    try testing.expectEqual(null, renewal.keep);
    try testing.expectEqual(@as(usize, 0), service.requests);

    // An own token that isn't usable (expired) leaves it to the shared one.
    in.own = try fakeToken(a, "KEY", "TEAM", t0 - 1);
    try testing.expectEqual(Outcome.downloaded, (try renewChoice(a, testing.io, in, refused, service.transport())).outcome);
}

test "renewing respects the backoff, notes a failure, and leaves the user's own token alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = try fakeToken(a, "OLDKEY", "TEAM", t0 + 6 * day);
    var service: FakeService = .{ .fail = error.ConnectionRefused };
    var in = baseInput();
    in.kept = keptFrom(refused);
    const failed = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqual(null, failed.token);
    try testing.expectEqualDeep(Kept{ .token = refused, .url = test_url, .failed_at = t0 }, failed.keep.?);
    try testing.expectEqualStrings("ConnectionRefused", failed.outcome.failed);

    in.kept.failed_at = t0 - 60;
    const held = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqual(null, held.token);
    try testing.expectEqual(null, held.keep);
    try testing.expectEqual(t0 - 60 + backoff_s, held.outcome.backoff);
    try testing.expect(std.mem.startsWith(u8, try std.fmt.allocPrint(a, "{f}", .{held.outcome}), "not trying to download a newer shared developer token yet: the last try failed; the next try is after "));
    try testing.expectEqual(@as(usize, 1), service.requests);

    // The user's own token, no service, or a port the shared token can't use: nothing.
    in = baseInput();
    in.own = refused;
    try testing.expectEqual(null, (try renewChoice(a, testing.io, in, refused, service.transport())).token);
    in = baseInput();
    in.url = .{ .ok = null };
    try testing.expectEqual(null, (try renewChoice(a, testing.io, in, refused, service.transport())).token);
    in = baseInput();
    in.port = .{ .ok = 48000 };
    try testing.expectEqual(null, (try renewChoice(a, testing.io, in, refused, service.transport())).token);
    try testing.expectEqual(@as(usize, 1), service.requests);
}

test "renewing with no unexpired token kept waits a minute after a failure, as choose does, not an hour" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A TUI open past its token's life: the kept one has expired, and the last download failed.
    const refused = try fakeToken(a, "KEY", "TEAM", t0 - day);
    var service: FakeService = .{ .response = .{ .status = 200, .body = try fakeToken(a, "KEY", "TEAM", t0 + 7 * day) } };
    var in = baseInput();
    in.kept = .{ .token = refused, .url = test_url, .failed_at = t0 - 30 };
    const held = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqual(t0 - 30 + retry_without_token_s, held.outcome.backoff);
    try testing.expectEqual(@as(usize, 0), service.requests);
    in.kept.failed_at = t0 - retry_without_token_s - 1;
    const renewed = try renewChoice(a, testing.io, in, refused, service.transport());
    try testing.expectEqual(Outcome.downloaded, renewed.outcome);
    try testing.expectEqual(@as(usize, 1), service.requests);
}

test "the kept file: token, URL and failure time, one per line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k: Kept = .{ .token = "a.b.c", .url = test_url, .failed_at = t0 };
    const text = try k.serialize(a);
    try testing.expectEqualStrings("a.b.c\n" ++ test_url ++ "\n1800000000\n", text);
    try testing.expectEqualDeep(k, Kept.parse(text));
    try testing.expectEqualDeep(Kept{ .token = "a.b.c", .url = test_url }, Kept.parse(try (Kept{ .token = "a.b.c", .url = test_url }).serialize(a)));
    try testing.expectEqualDeep(Kept{}, Kept.parse(null));
    try testing.expectEqualDeep(Kept{}, Kept.parse(""));
}

test "get keeps a downloaded token with its URL in a private file, and reads it back next time" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    const fresh = try fakeToken(a, "SHARED", "TEAM", t0 + 7 * day);
    var service: FakeService = .{ .response = .{ .status = 200, .body = fresh } };
    const env: Env = .{ .io = io, .config_dir = dir, .ids = null, .url = .{ .ok = test_url }, .port = .{ .ok = 47823 }, .transport = service.transport(), .now = t0 };
    try testing.expectEqualStrings(fresh, (try get(a, env)).found.token);
    const kept = try tmp.dir.readFileAlloc(io, config.file.shared_developer_token, a, .limited(4096));
    try testing.expectEqualDeep(Kept{ .token = fresh, .url = test_url }, Kept.parse(kept));
    // The own token's file is left alone.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, config.file.developer_token, .{}));

    service.fail = error.ConnectionRefused;
    try testing.expectEqualStrings(fresh, (try get(a, env)).found.token);
    try testing.expectEqual(@as(usize, 1), service.requests);

    // Apple refused it: renewNow downloads, fails, and notes the failure for the backoff.
    try testing.expectEqual(null, (try renewNow(a, env, fresh)).token);
    try testing.expectEqual(@as(usize, 2), service.requests);
    const noted = Kept.parse(try tmp.dir.readFileAlloc(io, config.file.shared_developer_token, a, .limited(4096)));
    try testing.expectEqual(t0, noted.failed_at.?);
    try testing.expectEqual(null, (try renewNow(a, env, fresh)).token);
    try testing.expectEqual(@as(usize, 2), service.requests);
}

test "a refused own token is never renewed or replaced: no download, no replacement" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const own = try fakeToken(a, "KEY", "TEAM", 4_000_000_000);
    try tmp.dir.writeFile(io, .{ .sub_path = config.file.developer_token, .data = own });
    var service: FakeService = .{ .response = .{ .status = 200, .body = try fakeToken(a, "SHARED", "TEAM", 4_000_000_000) } };
    var renewer: Renewer = .{
        .env = .{ .io = io, .config_dir = dir, .ids = .{ .team_id = "TEAM", .key_id = "KEY" }, .url = .{ .ok = test_url }, .port = .{ .ok = 47823 }, .transport = service.transport(), .now = 0 },
        .arena = a,
    };
    const r = renewer.renew();
    try testing.expectEqual(null, try r.renew(a, own));
    try testing.expectEqual(null, try r.replacement(a, own));
    try testing.expectEqual(Outcome.none, renewer.last.?);
    try testing.expectEqual(@as(usize, 0), service.requests);
}

test "a Renewer remembers what it replaced, so later requests send the newer token at once, and says what it did" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    // Far in the future, so the Renewer's own clock reads them as valid.
    const old = try fakeToken(a, "OLDKEY", "TEAM", 4_000_000_000);
    const new = try fakeToken(a, "NEWKEY", "TEAM", 4_000_000_000);
    var service: FakeService = .{ .response = .{ .status = 200, .body = new } };
    var renewer: Renewer = .{
        .env = .{ .io = io, .config_dir = dir, .ids = null, .url = .{ .ok = test_url }, .port = .{ .ok = 47823 }, .transport = service.transport(), .now = 0 },
        .arena = a,
    };
    const r = renewer.renew();
    try testing.expectEqual(null, try r.replacement(a, old));
    {
        // The arena the request passed in goes away; the Renewer keeps its own copies.
        var request: std.heap.ArenaAllocator = .init(testing.allocator);
        defer request.deinit();
        try testing.expectEqualStrings(new, (try r.renew(request.allocator(), old)).?);
    }
    try testing.expectEqualStrings(new, (try r.replacement(a, old)).?);
    try testing.expectEqualStrings(new, try apple.Renew.current(r, a, old));
    try testing.expectEqual(null, try r.replacement(a, new));
    try testing.expectEqual(Outcome.downloaded, renewer.last.?);
    try testing.expectEqual(@as(usize, 1), service.requests);
}
