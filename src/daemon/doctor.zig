//! The `doctor` endpoint: start the engine and report what playback needs: codecs, Widevine with
//! MusicKit's exact EME config, `browserSupportsVideoDrm`, the Music User Token, MusicKit's
//! authorization and the subscription. Each check prints ✔, ✘ or ?, as in the Node POC. The
//! engine page module (`engine_page.zig`) makes the repairs; doctor asks it to repair the page if
//! idle and reports what came back. Before all that come the warnings about the settings the
//! daemon runs with (values, env-file keys and lines am ignores), and how the env file changed
//! them since the daemon read it at start.
const std = @import("std");
const engine_page = @import("engine_page.zig");
const host_mod = @import("host.zig");
const playback = @import("../playback.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Host = host_mod.Host;
const Reply = protocol.Reply;

/// The engine and its page as `start` found them, the codecs and Widevine, the tokens, then
/// whatever the repair printed and left alone, and last the page's DRM, authorization and
/// subscription: all about the page as the repair left it.
pub fn run(host: Host, r: *Reply) Reply.Error!void {
    const a = r.arena;
    // First, so that an engine that doesn't start still shows them.
    try settingsWarnings(host, r);
    var problem: []const u8 = "";
    const started = host.page.start(a, &problem) catch |e| switch (e) {
        error.EngineFailed => return r.fail("the engine didn't start: {s}", .{problem}),
        error.Canceled => return error.Canceled,
        else => return r.fail("the engine didn't start: {t}", .{e}),
    };
    try r.print("engine: {s}{s}, pid {d}{s}\n", .{
        started.kind, if (started.headless) " (headless)" else "", started.pid, if (started.started) "" else " (already running)",
    });
    try r.print("UA: {s}  webdriver={?}\n", .{ started.report.userAgent orelse "?", started.report.webdriver });
    if (!started.ready) try r.print("note: MusicKit hasn't finished loading in the engine page yet\n", .{});

    const probe = try host.page.probe(r);
    try r.check(if (probe.h264.len > 0 and probe.aac.len > 0) true else false, "codecs: H.264 \"{s}\", AAC \"{s}\", MSE AAC {}", .{ probe.h264, probe.aac, probe.mseAac });
    try r.check(probe.widevine, "Widevine with MusicKit's exact EME config{s}{s}", .{ if (probe.widevineError != null) ": " else "", probe.widevineError orelse "" });

    switch (try host.developerToken(a)) {
        .found => |f| try r.check(true, "developer token: {s}", .{f.line}),
        .problem => |why| try r.check(false, "developer token: {s}", .{why}),
    }

    const token = try host.userTokenStatus(a);
    switch (token) {
        .missing => try r.check(false, "Music User Token missing: run `am signin`", .{}),
        .unchecked => |why| try r.check(null, "Music User Token not checked: {s}", .{why}),
        // 401 is about the developer token; 403 about the Music User Token.
        .checked => |c| if (c.status == 401)
            try r.check(false, "Apple refused the developer token (GET /v1/me/storefront → 401): check it with `am token`", .{})
        else
            try r.check(c.status == 200, "Music User Token valid (GET /v1/me/storefront → {d}){s}", .{ c.status, if (c.status == 200) "" else ": run `am signin`" }),
    }
    const user_token_ok = switch (token) {
        .checked => |c| c.status == 200,
        else => false,
    };

    // The token repairs need Apple's answer about the Music User Token first.
    const outcome = try host.page.repair(r, .{ .if_idle = .{ .user_token_ok = user_token_ok } });
    if (outcome.left_alone) |left| {
        var needs = left.needs.iterator();
        while (needs.next()) |need| try r.print("note: {f}\n", .{left.note(need)});
    }
    const report = outcome.report;
    switch (outcome.verdict) {
        // Why goes on the DRM line, the first of the page's lines: after a reload that didn't
        // come back, it is the new page load's why, not the old load's DRM support.
        .not_configured => |why| {
            try r.check(null, "MusicKit sees DRM support (browserSupportsVideoDrm): MusicKit isn't configured: {s}", .{why orelse "not loaded yet"});
            try r.check(null, "MusicKit authorized in the engine: MusicKit isn't configured", .{});
        },
        else => {
            try r.check(report.browserSupportsVideoDrm, "MusicKit {s} sees DRM support (browserSupportsVideoDrm)", .{report.musicKitVersion orelse "?"});
            try r.check(report.isAuthorized, "MusicKit authorized in the engine (storefront {s})", .{report.storefrontId orelse "?"});
        },
    }
    try r.check(report.subscriptionActive, "Apple Music subscription active{s}{s}", .{
        if (report.meError != null) ": " else if (report.subscriptionActive == null) ": unknown until MusicKit is authorized" else "", report.meError orelse "",
    });
}

/// The warnings the daemon started with, and those the env file has gained since. The daemon
/// reads it only at start, so either kind says when it changed. Its environment stays as it was.
fn settingsWarnings(host: Host, r: *Reply) Reply.Error!void {
    const now = try host.settingsWarningsNow(r.arena);
    for (host.settings_warnings) |warning| {
        const fixed = if (now) |n| !contains(n, warning) else false;
        try r.print("warning: {s}{s}\n", .{ warning, if (fixed) " (fixed in the env file since the daemon started: `am daemon stop` applies it)" else "" });
    }
    for (now orelse &.{}) |warning| if (!contains(host.settings_warnings, warning))
        try r.print("warning: {s} (new in the env file since the daemon started, which reads it only when it starts)\n", .{warning});
}

fn contains(list: []const []const u8, text: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}

const testing = std.testing;
const Fake = host_mod.Fake;

/// What the CLI would print.
fn runDoctor(f: *Fake, arena: Allocator) ![]const u8 {
    var t: protocol.TestReply = undefined;
    t.init(arena);
    const printed = try t.finish(run(f.host(), &t.reply));
    return printed.out;
}

fn parsed(arena: Allocator, json: []const u8) playback.Report {
    return playback.parseReport(arena, json) orelse @panic("not a report");
}

/// What the canned engine page's `repair` answers, in turn.
fn canned(arena: Allocator, outcomes: []const engine_page.Outcome) []const engine_page.Outcome {
    return arena.dupe(engine_page.Outcome, outcomes) catch @panic("out of memory");
}

test "without a developer token or Music User Token, doctor still reports codecs and Widevine, and hints at the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const report = parsed(a,
        \\{"configured":false,"configureError":"Error | developer token endpoint: HTTP 503 developer token missing: run am token --key-stdin",
        \\"browserSupportsVideoDrm":null,"isAuthorized":false,"subscriptionActive":null,"meError":null,
        \\"userAgent":"Mozilla/5.0 HeadlessChrome/141","webdriver":false,"load":"abc"}
    );
    var f: Fake = .{
        .arena = a,
        .page_started = .{ .kind = "chrome", .pid = 4242, .started = true, .headless = true, .ready = true, .report = report },
        .outcomes = canned(a, &.{.{ .report = report, .verdict = .{ .not_configured = report.configureError } }}),
        .token = .missing,
        .developer = .{ .problem = "developer token missing: run am token --key-stdin" },
    };
    try testing.expectEqualStrings(
        \\engine: chrome (headless), pid 4242
        \\UA: Mozilla/5.0 HeadlessChrome/141  webdriver=false
        \\✔ codecs: H.264 "probably", AAC "probably", MSE AAC true
        \\✔ Widevine with MusicKit's exact EME config
        \\✘ developer token: developer token missing: run am token --key-stdin
        \\✘ Music User Token missing: run `am signin`
        \\? MusicKit sees DRM support (browserSupportsVideoDrm): MusicKit isn't configured: Error | developer token endpoint: HTTP 503 developer token missing: run am token --key-stdin
        \\? MusicKit authorized in the engine: MusicKit isn't configured
        \\? Apple Music subscription active: unknown until MusicKit is authorized
        \\
    , try runDoctor(&f, a));
    try testing.expectEqual(false, f.idle_user_token_ok);
}

test "a signed-in, working setup is all ✔" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const report = parsed(a,
        \\{"configured":true,"musicKitVersion":"3.2526.0","browserSupportsVideoDrm":true,"isAuthorized":true,
        \\"storefrontId":"gb","subscriptionActive":true,"userAgent":"Firefox/140","webdriver":false}
    );
    var f: Fake = .{
        .arena = a,
        .page_started = .{ .kind = "firefox", .pid = 7, .started = false, .headless = true, .ready = true, .report = report },
        .page_probe = .{ .h264 = "probably", .aac = "maybe", .mseAac = true, .widevine = true },
        .outcomes = canned(a, &.{.{ .report = report, .verdict = .ready }}),
        .token = .{ .checked = .{ .status = 200, .storefront = "gb" } },
        .developer = .{ .found = .{ .line = "shared, from https://am-token.xauyxau.workers.dev/token, kid=KEY iss=TEAM expires 2026-11-02 00:00 UTC" } },
    };
    try testing.expectEqualStrings(
        \\engine: firefox (headless), pid 7 (already running)
        \\UA: Firefox/140  webdriver=false
        \\✔ codecs: H.264 "probably", AAC "maybe", MSE AAC true
        \\✔ Widevine with MusicKit's exact EME config
        \\✔ developer token: shared, from https://am-token.xauyxau.workers.dev/token, kid=KEY iss=TEAM expires 2026-11-02 00:00 UTC
        \\✔ Music User Token valid (GET /v1/me/storefront → 200)
        \\✔ MusicKit 3.2526.0 sees DRM support (browserSupportsVideoDrm)
        \\✔ MusicKit authorized in the engine (storefront gb)
        \\✔ Apple Music subscription active
        \\
    , try runDoctor(&f, a));
    try testing.expectEqual(true, f.idle_user_token_ok);
}

test "a rejected Music User Token, or one that couldn't be checked, says so, and the page gets no token repair" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { host_mod.TokenStatus, []const u8 }{
        .{ .{ .checked = .{ .status = 403, .storefront = null } }, "✘ Music User Token valid (GET /v1/me/storefront → 403): run `am signin`\n" },
        // 401 is about the developer token, not the sign-in.
        .{ .{ .checked = .{ .status = 401, .storefront = null } }, "✘ Apple refused the developer token (GET /v1/me/storefront → 401): check it with `am token`\n" },
        .{ .{ .unchecked = "developer token missing: run am token --key-stdin" }, "? Music User Token not checked: developer token missing: run am token --key-stdin\n" },
    };
    for (cases) |case| {
        var f: Fake = .{ .arena = a, .token = case[0] };
        try testing.expect(std.mem.find(u8, try runDoctor(&f, a), case[1]) != null);
        // Token repairs only with a Music User Token Apple accepts.
        try testing.expectEqual(false, f.idle_user_token_ok);
    }
}

test "doctor starts with the warnings about the daemon's settings, then checks as always" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .settings_warnings = &.{
        "ENGINE_HEADLESS in the env file must be 0 (show the engine) or 1 (headless), not \"false\": ignored, the engine runs headless",
        "ENGINE_IDEL_MINUTES in the env file isn't a setting: ignored. The settings are AM_PORT, …",
    } };
    try testing.expect(std.mem.startsWith(u8, try runDoctor(&f, a),
        \\warning: ENGINE_HEADLESS in the env file must be 0 (show the engine) or 1 (headless), not "false": ignored, the engine runs headless
        \\warning: ENGINE_IDEL_MINUTES in the env file isn't a setting: ignored. The settings are AM_PORT, …
        \\engine: chrome (headless), pid 4242 (already running)
        \\
    ));
}

test "doctor says which warnings the env file fixed or gained since the daemon started" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{
        .arena = a,
        .settings_warnings = &.{ "ENGINE_HEADLESS in the env file must be 0 …", "FIREFOX_WIDEVINE in the environment must be google …" },
        .settings_warnings_now = &.{ "FIREFOX_WIDEVINE in the environment must be google …", "ENGINE_IDEL_MINUTES in the env file isn't a setting …" },
    };
    try testing.expect(std.mem.startsWith(u8, try runDoctor(&f, a),
        \\warning: ENGINE_HEADLESS in the env file must be 0 … (fixed in the env file since the daemon started: `am daemon stop` applies it)
        \\warning: FIREFOX_WIDEVINE in the environment must be google …
        \\warning: ENGINE_IDEL_MINUTES in the env file isn't a setting … (new in the env file since the daemon started, which reads it only when it starts)
        \\engine: chrome (headless), pid 4242 (already running)
        \\
    ));
}

/// The page MusicKit signed out, as the engine start found it.
const signed_out_report =
    \\{"configured":true,"musicKitVersion":"3.2526.0","browserSupportsVideoDrm":true,"isAuthorized":false,"storefrontId":"us","meError":"AUTHORIZATION_ERROR | Unauthorized","load":"1"}
;

test "doctor's DRM, authorization and subscription lines come last, about the page after the repair, below what the repair printed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // MusicKit configured before Widevine was there, and signed the page out since.
    var f: Fake = .{
        .arena = a,
        .page_started = .{ .kind = "firefox", .pid = 7, .started = false, .headless = true, .ready = true, .report = parsed(a,
            \\{"configured":true,"musicKitVersion":"3.2526.0","browserSupportsVideoDrm":false,"isAuthorized":false,"userAgent":"Firefox/140","webdriver":false,"load":"1"}
        ) },
        .says =
        \\Widevine is available; reloading the engine page so MusicKit sees it.
        \\MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens
        \\
        ,
        .outcomes = canned(a, &.{.{
            .report = parsed(a, "{\"configured\":true,\"musicKitVersion\":\"3.2526.0\",\"browserSupportsVideoDrm\":true,\"isAuthorized\":true,\"storefrontId\":\"gb\",\"subscriptionActive\":true,\"load\":\"3\"}"),
            .verdict = .ready,
        }}),
    };
    try testing.expectEqualStrings(
        \\engine: firefox (headless), pid 7 (already running)
        \\UA: Firefox/140  webdriver=false
        \\✔ codecs: H.264 "probably", AAC "probably", MSE AAC true
        \\✔ Widevine with MusicKit's exact EME config
        \\✔ developer token: your own, kid=KEY iss=TEAM expires 2027-04-01 00:00 UTC
        \\✔ Music User Token valid (GET /v1/me/storefront → 200)
        \\Widevine is available; reloading the engine page so MusicKit sees it.
        \\MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens
        \\✔ MusicKit 3.2526.0 sees DRM support (browserSupportsVideoDrm)
        \\✔ MusicKit authorized in the engine (storefront gb)
        \\✔ Apple Music subscription active
        \\
    , try runDoctor(&f, a));
    try testing.expectEqual(true, f.idle_user_token_ok);
}

test "doctor says which repairs the page was left alone for, one note each, and why a reload that didn't come back left it unconfigured" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = parsed(a, signed_out_report);
    // The page holds music: the repair it needs is left for the next play.
    var left: Fake = .{
        .arena = a,
        .page_started = .{ .kind = "firefox", .pid = 7, .started = false, .headless = true, .ready = true, .report = before },
        .outcomes = canned(a, &.{.{ .report = before, .verdict = .signed_out, .left_alone = .{ .needs = .initOne(.signed_out), .because = .{ .holds = .paused } } }}),
    };
    try testing.expect(std.mem.endsWith(u8, try runDoctor(&left, a),
        \\✔ Music User Token valid (GET /v1/me/storefront → 200)
        \\note: MusicKit signed the engine page out, though Apple accepts the Music User Token; the page holds music, so it's left alone: the next play reloads it
        \\✔ MusicKit 3.2526.0 sees DRM support (browserSupportsVideoDrm)
        \\✘ MusicKit authorized in the engine (storefront us)
        \\? Apple Music subscription active: AUTHORIZATION_ERROR | Unauthorized
        \\
    ));

    // Every need it found, in the order of the repairs, each with why it was left alone.
    var every: Fake = .{
        .arena = a,
        .page_started = .{ .kind = "firefox", .pid = 7, .started = false, .headless = true, .ready = true, .report = before },
        .outcomes = canned(a, &.{.{ .report = before, .verdict = .signed_out, .left_alone = .{ .needs = .full, .because = .play_on_its_way } }}),
    };
    try testing.expect(std.mem.endsWith(u8, try runDoctor(&every, a),
        \\✔ Music User Token valid (GET /v1/me/storefront → 200)
        \\note: Widevine is available, but MusicKit configured without it; a play is on its way, so it's left alone: the next play reloads it
        \\note: MusicKit signed the engine page out, though Apple accepts the Music User Token; a play is on its way, so it's left alone: the next play reloads it
        \\note: the engine page loaded before the last sign-in; a play is on its way, so it's left alone: the next play reloads it
        \\note: Apple refuses the engine page's developer token; a play is on its way, so it's left alone: the next play reloads it
        \\✔ MusicKit 3.2526.0 sees DRM support (browserSupportsVideoDrm)
        \\✘ MusicKit authorized in the engine (storefront us)
        \\? Apple Music subscription active: AUTHORIZATION_ERROR | Unauthorized
        \\
    ));

    // Its reload didn't come back: the DRM line says why, about the page as it is now.
    var gone: Fake = .{
        .arena = a,
        .page_started = .{ .kind = "firefox", .pid = 7, .started = false, .headless = true, .ready = true, .report = before },
        .says = "MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens\n",
        .outcomes = canned(a, &.{.{ .report = .{}, .verdict = .{ .not_configured = "the reloaded engine page didn't configure MusicKit within 60 s" } }}),
    };
    try testing.expect(std.mem.endsWith(u8, try runDoctor(&gone, a),
        \\✔ Music User Token valid (GET /v1/me/storefront → 200)
        \\MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens
        \\? MusicKit sees DRM support (browserSupportsVideoDrm): MusicKit isn't configured: the reloaded engine page didn't configure MusicKit within 60 s
        \\? MusicKit authorized in the engine: MusicKit isn't configured
        \\? Apple Music subscription active: unknown until MusicKit is authorized
        \\
    ));
}
