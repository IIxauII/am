//! Getting signed in at startup, before the TUI shows any music:
//!
//! 1. A developer token to use (`token_source.zig`: your own, else the shared one)? With neither
//!    TEAM_ID and KEY_ID nor a token service set, a setup screen saying where to put them; with
//!    another problem, the problem and the exact `am token --key-stdin` instructions.
//! 2. Apple accepts that token (`/v1/test`)? Else a setup screen saying so.
//! 3. A Music User Token stored and accepted (`/v1/me/storefront` answers 200)? A missing or
//!    rejected (403) one starts the sign-in automatically: the background process's sign-in
//!    page opens in the browser and the TUI waits for it.
//! 4. 429, 5xx or no network: a retry screen that keeps the tokens and tries again.
//!
//! `check` does steps 1-3 from what the caller read from the config dir; `Machine` holds the
//! screen state and says what the app has to do next. Neither prints or touches the terminal.
const std = @import("std");
const builtin = @import("builtin");
const apple = @import("../apple.zig");
const developer_token = @import("../developer_token.zig");
const token_source = @import("../token_source.zig");

const Allocator = std.mem.Allocator;

pub const CheckInput = struct {
    config_dir: []const u8,
    /// For the setup screens.
    team_id: ?[]const u8,
    key_id: ?[]const u8,
    /// The developer token to use, or why there is none (`token_source.get`).
    developer: token_source.Result,
    user_token: ?[]const u8,
    /// Unix seconds.
    now: i64,
    os: std.Target.Os.Tag = builtin.os.tag,
    /// Asked once for a newer shared token when Apple refuses the shared one with 401.
    renew: ?apple.Renew = null,
};

pub const Ready = struct {
    storefront: []const u8,
    developer_token: []const u8,
    user_token: []const u8,
    /// Less than two weeks left on the developer token.
    expiring_soon: bool,
    /// The shared token is used although TEAM_ID and KEY_ID are set: why the own one isn't.
    own_problem: ?[]const u8 = null,
};

pub const CheckResult = union(enum) {
    ready: Ready,
    /// Something only the user can fix; the text says how.
    setup: []const u8,
    /// Sign in again; the text says why.
    signin: []const u8,
    /// Apple couldn't answer now (429, 5xx, network); try again later.
    transient: []const u8,
};

/// Steps 1-3. Requests go through `transport`; texts are allocated in `arena`.
pub fn check(arena: Allocator, in: CheckInput, transport: apple.Transport) (Allocator.Error || std.Io.Cancelable)!CheckResult {
    const env_path = try std.fs.path.join(arena, &.{ in.config_dir, "env" });
    const key_id = in.key_id orelse "<KEY_ID>";
    const found: token_source.Found = switch (in.developer) {
        .found => |f| f,
        .problem => |p| if (p.nothing_set) {
            const which = if (in.team_id == null and in.key_id == null) "TEAM_ID and KEY_ID are" else if (in.team_id == null) "TEAM_ID is" else "KEY_ID is";
            return .{ .setup = try std.fmt.allocPrint(arena,
                \\{s} missing, and no shared token service is set. Put these two lines in {s}
                \\(or set them in the environment):
                \\
                \\    TEAM_ID=<your Apple Developer Team ID>
                \\    KEY_ID=<the ID of your MusicKit key>
                \\
                \\Both are on developer.apple.com (Membership, and Certificates, IDs & Profiles → Keys).
                \\Then sign the developer token as below and press r. Or put TOKEN_URL=<the shared
                \\token service> there to use a shared developer token.
                \\
                \\{s}
            , .{ which, env_path, try tokenInstructions(arena, "<KEY_ID>", in.os) }) };
        } else return .{ .setup = try std.fmt.allocPrint(arena, "{s}.\n\n{s}", .{ p.text, try tokenInstructions(arena, key_id, in.os) }) },
    };
    const expiring_soon = found.expiring_soon;

    // A shared token Apple refuses (its service's key changed) is renewed once by the client;
    // the token that answered is the session's.
    const test_client: apple.Client = .{ .transport = transport, .developer_token = found.token, .user_token = null, .renew = in.renew };
    const answer = test_client.getWith(arena, "/v1/test", .{ .send_user_token = false }) catch |e| return transient(arena, e);
    const dev = answer.developer_token;
    const tested = answer.response.status;
    switch (tested) {
        200...299 => {},
        401, 403 => return .{ .setup = try rejected(arena, found, tested, key_id, in.os) },
        else => return transientStatus(arena, tested),
    }

    const user = in.user_token orelse return .{ .signin = "You're not signed in to Apple Music yet." };
    var body: []const u8 = "";
    const status_code = getBody(arena, transport, dev, user, "/v1/me/storefront", &body) catch |e| return transient(arena, e);
    switch (status_code) {
        200 => {
            const parsed = std.json.parseFromSliceLeaky(struct { data: []const struct { id: []const u8 } }, arena, body, .{
                .ignore_unknown_fields = true,
            }) catch return .{ .transient = "Apple Music sent an answer am can't read." };
            if (parsed.data.len == 0) return .{ .transient = "Apple Music didn't say which storefront you use." };
            return .{ .ready = .{
                .storefront = parsed.data[0].id,
                .developer_token = dev,
                .user_token = user,
                .expiring_soon = expiring_soon,
                .own_problem = found.own_problem,
            } };
        },
        403 => return .{ .signin = "Apple Music no longer accepts the stored sign-in (it lasts about six months)." },
        401 => return .{ .setup = try rejected(arena, found, 401, key_id, in.os) },
        else => return transientStatus(arena, status_code),
    }
}

/// The setup screen for a developer token Apple refused with `status`, saying whose it was.
fn rejected(arena: Allocator, found: token_source.Found, status: u16, key_id: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const u8 {
    return switch (found.source) {
        .own => try std.fmt.allocPrint(arena,
            \\Apple rejects the developer token (HTTP {d}): the key may be revoked, or TEAM_ID / KEY_ID
            \\don't match it.
            \\
            \\{s}
        , .{ status, try tokenInstructions(arena, key_id, os) }),
        .shared => try std.fmt.allocPrint(arena,
            \\Apple rejects the shared developer token from {s} (HTTP {d}): its key may be
            \\revoked. Sign your own instead:
            \\
            \\{s}
        , .{ found.url orelse "?", status, try tokenInstructions(arena, key_id, os) }),
    };
}

fn tokenInstructions(arena: Allocator, key_id: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const u8 {
    const keychain = if (os == .macos)
        \\
        \\With the key in the macOS Keychain (item am-musickit-p8, as SETUP.md section 1e sets up):
        \\
        \\    security find-generic-password -a am -s am-musickit-p8 -w | base64 -D | am token --key-stdin
        \\
    else
        "";
    return std.fmt.allocPrint(arena,
        \\Sign a developer token from your MusicKit key (the .p8 file from developer.apple.com),
        \\in another terminal:
        \\
        \\    am token --key-stdin < AuthKey_{s}.p8
        \\{s}
        \\am keeps only the signed token, never the key. Then press r here.
    , .{ key_id, keychain });
}

fn getBody(arena: Allocator, transport: apple.Transport, dev: []const u8, user: ?[]const u8, path: []const u8, body: *[]const u8) !u16 {
    const client: apple.Client = .{ .transport = transport, .developer_token = dev, .user_token = user };
    const response = try client.get(arena, path, .{ .send_user_token = user != null });
    body.* = response.body;
    return response.status;
}

fn transient(arena: Allocator, e: anyerror) (Allocator.Error || std.Io.Cancelable)!CheckResult {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    if (e == error.Canceled) return error.Canceled;
    return .{ .transient = try std.fmt.allocPrint(arena, "Can't reach Apple Music ({t}). Check the network.", .{e}) };
}

fn transientStatus(arena: Allocator, status: u16) Allocator.Error!CheckResult {
    return .{ .transient = if (status == 429)
        "Apple Music is limiting requests right now (HTTP 429)."
    else
        try std.fmt.allocPrint(arena, "Apple Music answered HTTP {d}.", .{status}) };
}

/// Text in a fixed buffer, so the machine needs no allocator.
pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(t: *@This(), s: []const u8) void {
            t.len = @min(s.len, n);
            @memcpy(t.buf[0..t.len], s[0..t.len]);
            // Never end inside a UTF-8 sequence.
            while (t.len > 0 and t.len < s.len and (s[t.len] & 0xC0) == 0x80) t.len -= 1;
        }

        pub fn get(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
    };
}

pub const Phase = enum { checking, setup, signing_in, signed_out, retry, ready, fatal };

/// What the app must do after a transition.
pub const Effect = enum {
    none,
    /// Run `check` (in a job) and pass the result to `checked`.
    check,
    /// Get a sign-in page from the background process (`signin-page`), pass its address to
    /// `signinUrl`, then run `signin` and pass its lines and result on.
    start_signin,
    /// Open `url` in the browser.
    open_url,
    cancel_signin,
    quit,
};

pub const Key = enum { reopen, cancel, quit, retry, signin };

/// How long the background process waits for a sign-in.
pub const signin_timeout_s = 10 * 60;

pub const Machine = struct {
    phase: Phase = .checking,
    /// The setup instructions, the reason for signing in, or the error shown.
    text: Text(4096) = .{},
    url: Text(512) = .{},
    /// The latest lines from the sign-in ("✘ Apple rejected that token…").
    lines: [3]Text(256) = @splat(.{}),
    line_count: usize = 0,
    /// When the sign-in started, ms.
    since_ms: i64 = 0,
    retry_at_ms: i64 = 0,
    attempts: u8 = 0,
    /// The main UI was up before: this is a sign-in during the session.
    in_session: bool = false,
    signin_running: bool = false,
    /// The user closed the sign-in during the session (Esc): Apple still wants one, but the
    /// box doesn't open by itself again; `S` (`signinAgain`) does.
    needs_signin: bool = false,

    pub fn start(m: *Machine) Effect {
        m.phase = .checking;
        return .check;
    }

    pub fn checked(m: *Machine, result: CheckResult, now_ms: i64) Effect {
        switch (result) {
            .ready => {
                m.phase = .ready;
                m.attempts = 0;
                m.in_session = true;
                m.needs_signin = false;
                return .none;
            },
            .setup => |text| {
                m.phase = .setup;
                m.text.set(text);
                return .none;
            },
            .signin => |why| return m.beginSignin(why, now_ms),
            .transient => |why| {
                m.phase = .retry;
                m.text.set(why);
                m.attempts +|= 1;
                m.retry_at_ms = now_ms + backoffMs(m.attempts);
                return .none;
            },
        }
    }

    fn beginSignin(m: *Machine, why: []const u8, now_ms: i64) Effect {
        m.phase = .signing_in;
        m.text.set(why);
        m.url.len = 0;
        m.line_count = 0;
        m.since_ms = now_ms;
        m.signin_running = true;
        return .start_signin;
    }

    /// The sign-in page's address arrived.
    pub fn signinUrl(m: *Machine, url: []const u8) Effect {
        if (m.phase != .signing_in) return .none;
        m.url.set(url);
        return .open_url;
    }

    /// A line the sign-in printed; empty ones are its keep-alives.
    pub fn signinLine(m: *Machine, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "Click ")) return;
        if (m.line_count == m.lines.len) {
            for (0..m.lines.len - 1) |i| m.lines[i] = m.lines[i + 1];
            m.line_count -= 1;
        }
        m.lines[m.line_count].set(trimmed);
        m.line_count += 1;
    }

    pub fn signinLines(m: *const Machine, out: *[3][]const u8) []const []const u8 {
        for (0..m.line_count) |i| out[i] = m.lines[i].get();
        return out[0..m.line_count];
    }

    /// The sign-in ended: `ok` when the background process saved a token Apple accepts.
    pub fn signinDone(m: *Machine, ok: bool, message: ?[]const u8) Effect {
        m.signin_running = false;
        if (m.phase != .signing_in) return .none;
        if (ok) {
            m.phase = .checking;
            return .check;
        }
        m.phase = .signed_out;
        m.text.set(message orelse "The sign-in didn't finish.");
        return .none;
    }

    pub fn key(m: *Machine, k: Key, now_ms: i64) Effect {
        if (k == .quit) return .quit;
        switch (m.phase) {
            .signing_in => switch (k) {
                .reopen => return if (m.url.len > 0) .open_url else .none,
                .cancel => {
                    const running = m.signin_running;
                    // During the session, Esc goes back to the music.
                    if (m.in_session) m.dismiss() else {
                        m.phase = .signed_out;
                        m.text.set("Sign-in canceled.");
                    }
                    return if (running) .cancel_signin else .none;
                },
                else => return .none,
            },
            .signed_out => switch (k) {
                .signin, .retry => return m.beginSignin("Signing in to Apple Music.", now_ms),
                .cancel => {
                    if (m.in_session) m.dismiss();
                    return .none;
                },
                else => return .none,
            },
            .setup, .retry => switch (k) {
                .retry => {
                    m.phase = .checking;
                    return .check;
                },
                else => return .none,
            },
            .checking, .ready, .fatal => return .none,
        }
    }

    pub fn tick(m: *Machine, now_ms: i64) Effect {
        if (m.phase == .retry and now_ms >= m.retry_at_ms) {
            m.phase = .checking;
            return .check;
        }
        return .none;
    }

    /// Apple refused the Music User Token during the session (a 403 from any call). After the
    /// user closed the box, it stays closed until they ask (`signinAgain`).
    pub fn signInRequired(m: *Machine, now_ms: i64) Effect {
        if (m.phase != .ready) return .none;
        if (m.needs_signin) return .none;
        return m.beginSignin("Apple Music needs you to sign in again.", now_ms);
    }

    /// `S` in the main UI: sign in again now.
    pub fn signinAgain(m: *Machine, now_ms: i64) Effect {
        if (m.phase != .ready) return .none;
        return m.beginSignin("Signing in to Apple Music again.", now_ms);
    }

    /// Back to the main UI without a sign-in (the in-session box closed).
    fn dismiss(m: *Machine) void {
        m.phase = .ready;
        m.needs_signin = true;
        m.signin_running = false;
    }

    pub fn fatal(m: *Machine, text: []const u8) void {
        m.phase = .fatal;
        m.text.set(text);
    }

    /// Seconds left before the background process gives up on the sign-in.
    pub fn signinLeft(m: *const Machine, now_ms: i64) i64 {
        return @max(0, signin_timeout_s - @divFloor(now_ms - m.since_ms, 1000));
    }

    /// Seconds until the next automatic check.
    pub fn retryIn(m: *const Machine, now_ms: i64) i64 {
        return @max(0, @divFloor(m.retry_at_ms - now_ms + 999, 1000));
    }
};

/// 2 s, 4 s, 8 s, 16 s, then every 30 s.
pub fn backoffMs(attempt: u8) i64 {
    if (attempt == 0) return 0;
    const shift: u6 = @intCast(@min(attempt, 5));
    return @min(@as(i64, 1000) << shift, 30_000);
}

const testing = std.testing;

/// Answers each path with a status, in the order given.
const FakeApple = struct {
    answers: []const Answer,
    next: usize = 0,
    seen_user_token: bool = false,

    const Answer = struct { path: []const u8, status: u16, body: []const u8 = "", fail: bool = false };

    fn transport(f: *FakeApple) apple.Transport {
        return .{ .ptr = f, .requestFn = request };
    }

    fn request(ptr: *anyopaque, _: Allocator, method: apple.Method, url: []const u8, headers: []const std.http.Header, _: ?[]const u8) anyerror!apple.Response {
        const f: *FakeApple = @ptrCast(@alignCast(ptr));
        try testing.expectEqual(apple.Method.GET, method);
        const a = f.answers[f.next];
        f.next += 1;
        try testing.expect(std.mem.endsWith(u8, url, a.path));
        for (headers) |h| if (std.mem.eql(u8, h.name, "Music-User-Token")) {
            f.seen_user_token = true;
        };
        if (a.fail) return error.ConnectionRefused;
        return .{ .status = a.status, .body = a.body };
    }
};

/// A developer token that `developer_token.check` reads as usable: header and claims only;
/// nothing checks the signature.
const fakeToken = token_source.fakeToken;
const test_service = "https://am-token.example.workers.dev/token";

/// What `token_source.choose` makes of these, with no token service set unless `kept` is given.
fn developer(arena: Allocator, team: ?[]const u8, key: ?[]const u8, own: ?[]const u8, kept: ?[]const u8) !token_source.Result {
    var unused: FakeApple = .{ .answers = &.{} };
    const ids: ?developer_token.Ids = if (team != null and key != null) .{ .team_id = team.?, .key_id = key.? } else null;
    return (try token_source.choose(arena, testing.io, .{
        .ids = ids,
        .own = own,
        .kept = .{ .token = kept, .url = if (kept != null) test_service else null },
        .url = if (kept != null) test_service else null,
        .port = .{ .ok = 47823 },
        .now = 1_800_000_000,
        .env_path = "/home/u/.config/am/env",
    }, unused.transport())).result;
}

fn input(arena: Allocator, user: ?[]const u8) !CheckInput {
    return .{
        .config_dir = "/home/u/.config/am",
        .team_id = "TEAM",
        .key_id = "KEY",
        .developer = try developer(arena, "TEAM", "KEY", try fakeToken(arena, "KEY", "TEAM", 2_000_000_000), null),
        .user_token = user,
        .now = 1_800_000_000,
        .os = .linux,
    };
}

test "check: signed in → ready with the storefront" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakeApple = .{ .answers = &.{
        .{ .path = "/v1/test", .status = 200 },
        .{ .path = "/v1/me/storefront", .status = 200, .body = "{\"data\":[{\"id\":\"gb\",\"type\":\"storefronts\"}]}" },
    } };
    const result = try check(a, try input(a, "mut"), fake.transport());
    try testing.expectEqualStrings("gb", result.ready.storefront);
    try testing.expect(!result.ready.expiring_soon);
    try testing.expect(fake.seen_user_token);
}

test "check: no IDs or no usable developer token → setup with the instructions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakeApple = .{ .answers = &.{} };
    var in = try input(a, "mut");
    in.key_id = null;
    in.developer = try developer(a, "TEAM", null, null, null);
    const no_ids = try check(a, in, fake.transport());
    try testing.expect(std.mem.find(u8, no_ids.setup, "KEY_ID is missing, and no shared token service is set") != null);
    try testing.expect(std.mem.find(u8, no_ids.setup, "/home/u/.config/am/env") != null);
    try testing.expect(std.mem.find(u8, no_ids.setup, "TOKEN_URL=") != null);

    in = try input(a, "mut");
    in.developer = try developer(a, "TEAM", "KEY", null, null);
    const missing = try check(a, in, fake.transport());
    try testing.expect(std.mem.startsWith(u8, missing.setup, "developer token missing: run am token --key-stdin."));
    try testing.expect(std.mem.find(u8, missing.setup, "am token --key-stdin < AuthKey_KEY.p8") != null);
    // The Keychain line is for macOS only.
    try testing.expect(std.mem.find(u8, missing.setup, "security find-generic-password") == null);
    in.os = .macos;
    const mac = try check(a, in, fake.transport());
    try testing.expect(std.mem.find(u8, mac.setup, "security find-generic-password -a am -s am-musickit-p8 -w | base64 -D | am token --key-stdin") != null);

    in = try input(a, "mut");
    in.developer = try developer(a, "TEAM", "KEY", try fakeToken(a, "KEY", "TEAM", 1_700_000_000), null);
    try testing.expect(std.mem.startsWith(u8, (try check(a, in, fake.transport())).setup, "developer token expired"));
    try testing.expectEqual(@as(usize, 0), fake.next);
}

test "check: without TEAM_ID and KEY_ID, a shared token is used; Apple refusing it says it was the shared one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try input(a, "mut");
    in.team_id = null;
    in.key_id = null;
    in.developer = try developer(a, null, null, null, try fakeToken(a, "SHARED", "TEAM", 1_800_000_000 + 6 * 86400));
    var ok: FakeApple = .{ .answers = &.{
        .{ .path = "/v1/test", .status = 200 },
        .{ .path = "/v1/me/storefront", .status = 200, .body = "{\"data\":[{\"id\":\"gb\",\"type\":\"storefronts\"}]}" },
    } };
    const ready = (try check(a, in, ok.transport())).ready;
    try testing.expectEqualStrings("gb", ready.storefront);
    try testing.expect(!ready.expiring_soon);

    var refused: FakeApple = .{ .answers = &.{.{ .path = "/v1/test", .status = 403 }} };
    const setup = (try check(a, in, refused.transport())).setup;
    try testing.expect(std.mem.startsWith(u8, setup, "Apple rejects the shared developer token from https://am-token.example.workers.dev/token (HTTP 403)"));
    try testing.expect(std.mem.find(u8, setup, "am token --key-stdin < AuthKey_<KEY_ID>.p8") != null);

    // A 401 from the storefront check says it was the shared token too.
    var late: FakeApple = .{ .answers = &.{
        .{ .path = "/v1/test", .status = 200 },
        .{ .path = "/v1/me/storefront", .status = 401 },
    } };
    try testing.expect(std.mem.startsWith(u8, (try check(a, in, late.transport())).setup, "Apple rejects the shared developer token from https://am-token.example.workers.dev/token (HTTP 401)"));
}

const FakeRenew = apple.FakeRenew;

test "check: a shared token Apple refuses with 401 is renewed once and tested again; the new one is the session's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try input(a, "mut");
    in.team_id = null;
    in.key_id = null;
    const old = try fakeToken(a, "OLDKEY", "TEAM", 1_800_000_000 + 6 * 86400);
    in.developer = try developer(a, null, null, null, old);
    var renewer: FakeRenew = .{ .token = "NEW" };
    in.renew = renewer.renew();
    var fake: FakeApple = .{ .answers = &.{
        .{ .path = "/v1/test", .status = 401 },
        .{ .path = "/v1/test", .status = 200 },
        .{ .path = "/v1/me/storefront", .status = 200, .body = "{\"data\":[{\"id\":\"gb\",\"type\":\"storefronts\"}]}" },
    } };
    const ready = (try check(a, in, fake.transport())).ready;
    try testing.expectEqualStrings("NEW", ready.developer_token);
    try testing.expectEqualStrings(old, renewer.refused.?);

    // Nothing newer, or the newer one refused too: the shared-token screen.
    var none: FakeRenew = .{ .token = null };
    in.renew = none.renew();
    var once: FakeApple = .{ .answers = &.{.{ .path = "/v1/test", .status = 401 }} };
    try testing.expect(std.mem.startsWith(u8, (try check(a, in, once.transport())).setup, "Apple rejects the shared developer token"));
    in.renew = renewer.renew();
    var twice: FakeApple = .{ .answers = &.{ .{ .path = "/v1/test", .status = 401 }, .{ .path = "/v1/test", .status = 401 } } };
    try testing.expect(std.mem.startsWith(u8, (try check(a, in, twice.transport())).setup, "Apple rejects the shared developer token"));

    // An own token Apple refuses: the renewer has nothing for it (`token_source.renewChoice`),
    // and the screen says it was the user's own.
    var own_in = try input(a, "mut");
    var nothing: FakeRenew = .{ .token = null };
    own_in.renew = nothing.renew();
    var own_refused: FakeApple = .{ .answers = &.{.{ .path = "/v1/test", .status = 401 }} };
    try testing.expect(std.mem.startsWith(u8, (try check(a, own_in, own_refused.transport())).setup, "Apple rejects the developer token (HTTP 401)"));
    // Asked once, with the own token, and nothing replaced it.
    try testing.expectEqual(@as(usize, 1), nothing.calls);
    try testing.expectEqualStrings(own_in.developer.found.token, nothing.refused.?);
    try testing.expectEqual(null, nothing.replaced);
    try testing.expectEqual(@as(usize, 1), own_refused.next);
}

test "check: with TEAM_ID and KEY_ID set but the own token unusable, the shared one is used and the reason travels with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try input(a, "mut");
    in.developer = try developer(a, "TEAM", "KEY", null, try fakeToken(a, "SHARED", "TEAM", 1_800_000_000 + 6 * 86400));
    var fake: FakeApple = .{ .answers = &.{
        .{ .path = "/v1/test", .status = 200 },
        .{ .path = "/v1/me/storefront", .status = 200, .body = "{\"data\":[{\"id\":\"gb\",\"type\":\"storefronts\"}]}" },
    } };
    const ready = (try check(a, in, fake.transport())).ready;
    try testing.expectEqualStrings("developer token missing: run am token --key-stdin", ready.own_problem.?);
}

test "check: Apple's answers decide between setup, sign-in and retry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { answers: []const FakeApple.Answer, user: ?[]const u8, tag: std.meta.Tag(CheckResult) };
    const cases = [_]Case{
        .{ .answers = &.{.{ .path = "/v1/test", .status = 401 }}, .user = "mut", .tag = .setup },
        .{ .answers = &.{.{ .path = "/v1/test", .status = 429 }}, .user = "mut", .tag = .transient },
        .{ .answers = &.{.{ .path = "/v1/test", .status = 0, .fail = true }}, .user = "mut", .tag = .transient },
        .{ .answers = &.{.{ .path = "/v1/test", .status = 200 }}, .user = null, .tag = .signin },
        .{ .answers = &.{ .{ .path = "/v1/test", .status = 200 }, .{ .path = "/v1/me/storefront", .status = 403 } }, .user = "mut", .tag = .signin },
        .{ .answers = &.{ .{ .path = "/v1/test", .status = 200 }, .{ .path = "/v1/me/storefront", .status = 503 } }, .user = "mut", .tag = .transient },
        .{ .answers = &.{ .{ .path = "/v1/test", .status = 200 }, .{ .path = "/v1/me/storefront", .status = 401 } }, .user = "mut", .tag = .setup },
        .{ .answers = &.{ .{ .path = "/v1/test", .status = 200 }, .{ .path = "/v1/me/storefront", .status = 0, .fail = true } }, .user = "mut", .tag = .transient },
    };
    for (cases) |c| {
        var fake: FakeApple = .{ .answers = c.answers };
        const result = try check(a, try input(a, c.user), fake.transport());
        try testing.expectEqual(c.tag, std.meta.activeTag(result));
        try testing.expectEqual(c.answers.len, fake.next);
    }
}

test "machine: a missing sign-in starts one, the URL opens, success checks again" {
    var m: Machine = .{};
    try testing.expectEqual(Effect.check, m.start());
    try testing.expectEqual(Effect.start_signin, m.checked(.{ .signin = "You're not signed in" }, 1000));
    try testing.expectEqual(Phase.signing_in, m.phase);
    try testing.expectEqual(Effect.none, m.key(.reopen, 1000)); // no URL yet
    try testing.expectEqual(Effect.open_url, m.signinUrl("http://localhost:47823/?signin&engine=abc"));
    try testing.expectEqual(Effect.open_url, m.key(.reopen, 2000));
    m.signinLine("");
    m.signinLine("Click \"Sign in to Apple Music\" and finish…\n");
    m.signinLine("✘ Apple rejected that token (HTTP 403); click the button again\n");
    var lines: [3][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), m.signinLines(&lines).len);
    try testing.expectEqual(@as(i64, 600 - 59), m.signinLeft(60_000));
    try testing.expectEqual(Effect.check, m.signinDone(true, null));
    try testing.expectEqual(Phase.checking, m.phase);
    try testing.expectEqual(Effect.none, m.checked(.{ .ready = .{ .storefront = "gb", .developer_token = "d", .user_token = "u", .expiring_soon = false } }, 5000));
    try testing.expectEqual(Phase.ready, m.phase);
    // A 403 later in the session signs in again.
    try testing.expectEqual(Effect.start_signin, m.signInRequired(9000));
    try testing.expect(m.in_session);
}

test "machine: cancel, a failed sign-in, and signing in again" {
    var m: Machine = .{};
    _ = m.checked(.{ .signin = "x" }, 0);
    try testing.expectEqual(Effect.cancel_signin, m.key(.cancel, 1));
    try testing.expectEqual(Phase.signed_out, m.phase);
    try testing.expectEqualStrings("Sign-in canceled.", m.text.get());
    // The canceled sign-in reporting back changes nothing.
    try testing.expectEqual(Effect.none, m.signinDone(false, "the background process shut down"));
    try testing.expectEqual(Effect.start_signin, m.key(.signin, 2));
    try testing.expectEqual(Effect.none, m.signinDone(false, "no successful sign-in within 10 minutes"));
    try testing.expectEqualStrings("no successful sign-in within 10 minutes", m.text.get());
    try testing.expectEqual(Effect.quit, m.key(.quit, 3));
}

test "machine: during the session Esc closes the sign-in, which then waits for S" {
    var m: Machine = .{};
    _ = m.checked(.{ .ready = .{ .storefront = "gb", .developer_token = "d", .user_token = "u", .expiring_soon = false } }, 0);
    try testing.expectEqual(Effect.start_signin, m.signInRequired(10));
    try testing.expectEqual(Effect.cancel_signin, m.key(.cancel, 20));
    try testing.expectEqual(Phase.ready, m.phase);
    try testing.expect(m.needs_signin);
    // The next refusal doesn't open it again by itself.
    try testing.expectEqual(Effect.none, m.signInRequired(30));
    try testing.expectEqual(Effect.start_signin, m.signinAgain(40));
    try testing.expectEqual(Phase.signing_in, m.phase);
    // A failed sign-in, then Esc on "Not signed in": back to the music too.
    _ = m.signinDone(false, "no successful sign-in within 10 minutes");
    try testing.expectEqual(Phase.signed_out, m.phase);
    try testing.expectEqual(Effect.none, m.key(.cancel, 50));
    try testing.expectEqual(Phase.ready, m.phase);
    // Before the session there is nothing to go back to.
    var first: Machine = .{};
    _ = first.checked(.{ .signin = "x" }, 0);
    _ = first.key(.cancel, 1);
    try testing.expectEqual(Phase.signed_out, first.phase);
    _ = first.key(.cancel, 2);
    try testing.expectEqual(Phase.signed_out, first.phase);
}

test "machine: setup waits for r; transient errors retry with backoff" {
    var m: Machine = .{};
    _ = m.checked(.{ .setup = "put TEAM_ID…" }, 0);
    try testing.expectEqual(Phase.setup, m.phase);
    try testing.expectEqual(Effect.none, m.tick(1_000_000));
    try testing.expectEqual(Effect.check, m.key(.retry, 0));

    try testing.expectEqual(Effect.none, m.checked(.{ .transient = "429" }, 10_000));
    try testing.expectEqual(Phase.retry, m.phase);
    try testing.expectEqual(@as(i64, 2), m.retryIn(10_000));
    try testing.expectEqual(Effect.none, m.tick(11_999));
    try testing.expectEqual(Effect.check, m.tick(12_000));
    _ = m.checked(.{ .transient = "429" }, 20_000);
    try testing.expectEqual(@as(i64, 24_000), m.retry_at_ms);
    try testing.expectEqual(@as(i64, 30_000), backoffMs(9));
    // r retries at once.
    try testing.expectEqual(Effect.check, m.key(.retry, 20_001));
}

test "text keeps whole UTF-8 sequences" {
    var t: Text(4) = .{};
    t.set("ab✘");
    try testing.expectEqualStrings("ab", t.get());
    t.set("abc");
    try testing.expectEqualStrings("abc", t.get());
}
