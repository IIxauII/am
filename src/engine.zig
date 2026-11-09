//! The engine: a stock browser that opens the engine page with its own profile. This file says
//! how each browser is launched; where it lives on this OS comes from the platform layer, and
//! starting and killing the process is the platform layer's job too.
const std = @import("std");
const platform = @import("platform.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum {
    firefox,
    chrome,

    pub fn spec(kind: Kind) *const Spec {
        return specs.getPtrConst(kind);
    }
};

/// Everything that differs between the engine browsers.
pub const Spec = struct {
    /// The profile directory's name inside the config directory. It persists across launches
    /// (Widevine module, cached `musickit.js`).
    profile_name: []const u8,
    /// Where this OS keeps it, and what else it needs there.
    browser: platform.Browser,
    /// Added to the daemon's environment.
    env: []const [2][]const u8,
    /// Whether the profile gets our `user.js` prefs.
    user_js: bool,
    /// Appends the browser's own flags (between the binary and the URL).
    appendArgs: *const fn (argv: *std.ArrayList([]const u8), arena: Allocator, profile: []const u8, headless: bool) Allocator.Error!void,
};

const specs: std.EnumArray(Kind, Spec) = .init(.{
    .firefox = .{
        .profile_name = "firefox-profile",
        .browser = platform.browsers.firefox,
        .env = &.{ .{ "MOZ_CRASHREPORTER_DISABLE", "1" }, .{ "MOZ_DISABLE_AUTO_SAFE_MODE", "1" } },
        .user_js = true,
        .appendArgs = firefoxArgs,
    },
    .chrome = .{
        .profile_name = "chrome-profile",
        .browser = platform.browsers.chrome,
        .env = &.{},
        .user_js = false,
        .appendArgs = chromeArgs,
    },
});

fn firefoxArgs(argv: *std.ArrayList([]const u8), arena: Allocator, profile: []const u8, headless: bool) Allocator.Error!void {
    // Firefox's remoting is keyed by profile path, so this never reaches the user's own Firefox.
    // (--no-remote is ignored by Firefox 140; --new-instance is the working equivalent.)
    try argv.appendSlice(arena, &.{ "--new-instance", "--profile", profile });
    if (headless) try argv.append(arena, "--headless");
}

fn chromeArgs(argv: *std.ArrayList([]const u8), arena: Allocator, profile: []const u8, headless: bool) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        try std.mem.concat(arena, u8, &.{ "--user-data-dir=", profile }),
        "--no-first-run",
        "--no-default-browser-check",
        "--password-store=basic",
        // play() comes from the CLI, not a click.
        "--autoplay-policy=no-user-gesture-required",
        if (headless) "--headless" else "--new-window",
    });
}

/// Engine profile prefs, verified headless on firefox-esr 140 and Firefox 158+ on macOS (see NOTES.md).
const firefox_prefs = [_]struct { []const u8, []const u8 }{
    // Mozilla turns EME off on Linux; without it MusicKit silently falls back to 30 s previews.
    // Set on every OS. Firefox then fetches the Widevine CDM itself on the first request.
    .{ "media.eme.enabled", "true" },
    .{ "media.gmp-widevinecdm.enabled", "true" },
    .{ "media.gmp-widevinecdm.visible", "true" },
    // Headless has no user gesture, so audible autoplay must be allowed or play() never starts.
    .{ "media.autoplay.default", "0" },
    .{ "media.block-autoplay-until-in-foreground", "false" },
    // Fewer processes for a single trusted page.
    .{ "fission.autostart", "false" },
    .{ "dom.ipc.processCount", "1" },
    .{ "dom.ipc.processPrelaunch.enabled", "false" },
    // No preloaded new tab (a privilegedabout process, about 48 MiB) and no socket process
    // (networking runs in the parent, as on Android): -2 processes, measured on macOS (issue #1).
    .{ "browser.newtab.preload", "false" },
    .{ "browser.newtabpage.enabled", "false" },
    .{ "network.process.enabled", "false" },
    // No system add-ons (e.g. KDE's, which claims a fixed MPRIS name).
    .{ "extensions.enabledScopes", "5" },
    .{ "browser.shell.checkDefaultBrowser", "false" },
    .{ "browser.aboutwelcome.enabled", "false" },
    .{ "browser.startup.homepage_override.mstone", "\"ignore\"" },
    .{ "datareporting.policy.dataSubmissionEnabled", "false" },
    .{ "toolkit.telemetry.reportingpolicy.firstRun", "false" },
    .{ "browser.sessionstore.resume_from_crash", "false" },
    // Firefox counts every session shorter than ~30 s as a startup crash (we stop it with
    // SIGTERM), and after 3 of those restarts itself in safe mode without our URL. Never do that.
    .{ "toolkit.startup.max_resumed_crashes", "-1" },
};

/// The engine profile's `user.js`. `force-chromium-update` follows `FIREFOX_WIDEVINE=google`
/// (take Google's current Widevine directly) and is always written: user.js values persist in
/// prefs.js after they're removed.
pub fn firefoxUserJs(arena: Allocator, widevine_from_google: bool) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    for (firefox_prefs) |pref| try writePref(&out.writer, pref[0], pref[1]);
    try writePref(&out.writer, "media.gmp-widevinecdm.force-chromium-update", if (widevine_from_google) "true" else "false");
    return out.written();
}

fn writePref(w: *Io.Writer, name: []const u8, value: []const u8) Allocator.Error!void {
    w.print("user_pref(\"{s}\", {s});\n", .{ name, value }) catch return error.OutOfMemory;
}

pub const Launch = struct {
    kind: Kind,
    /// Which processes are this engine, for finding leftovers.
    identity: platform.EngineIdentity,
    argv: []const []const u8,
    /// Added to the daemon's environment.
    env: []const [2][]const u8,
    /// Written to `<profile>/user.js` before the launch (Firefox).
    user_js: ?[]const u8,
};

pub const Options = struct {
    kind: Kind,
    binary: []const u8,
    config_dir: []const u8,
    /// The engine page, e.g. `http://localhost:47823/?engine=<nonce>`.
    url: []const u8,
    headless: bool,
    widevine_from_google: bool,
    /// The OS's extra flags and executable names; `kind.spec().browser` outside tests.
    browser: ?platform.Browser = null,
};

/// The command line and files of one engine launch. Allocates into `arena`.
pub fn plan(arena: Allocator, o: Options) Allocator.Error!Launch {
    const spec = o.kind.spec();
    const browser = o.browser orelse spec.browser;
    const profile = try Io.Dir.path.join(arena, &.{ o.config_dir, spec.profile_name });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, o.binary);
    try spec.appendArgs(&argv, arena, profile, o.headless);
    try argv.appendSlice(arena, browser.extra_args);
    try argv.append(arena, o.url);
    return .{
        .kind = o.kind,
        .identity = .{ .binary = o.binary, .profile = profile, .exe_names = browser.exe_names },
        .argv = argv.items,
        .env = spec.env,
        .user_js = if (spec.user_js) try firefoxUserJs(arena, o.widevine_from_google) else null,
    };
}

const testing = std.testing;

test "Chrome gets the POC's flags, its own profile, and the engine page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const launch = try plan(arena.allocator(), .{
        .kind = .chrome,
        .binary = "/opt/google/chrome/chrome",
        .config_dir = "/home/u/.config/am",
        .url = "http://localhost:47823/?engine=abc",
        .headless = true,
        .widevine_from_google = false,
        .browser = .{ .candidates = &.{}, .exe_names = &.{"chrome"} },
    });
    try testing.expectEqualStrings("/home/u/.config/am/chrome-profile", launch.identity.profile);
    try testing.expectEqualStrings("/opt/google/chrome/chrome", launch.identity.binary);
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "/opt/google/chrome/chrome",
        "--user-data-dir=/home/u/.config/am/chrome-profile",
        "--no-first-run",
        "--no-default-browser-check",
        "--password-store=basic",
        "--autoplay-policy=no-user-gesture-required",
        "--headless",
        "http://localhost:47823/?engine=abc",
    }), launch.argv);
    try testing.expectEqual(null, launch.user_js);

    // An OS's extra flags go after the browser's own; visible, Chrome opens a new window.
    const mac = try plan(arena.allocator(), .{
        .kind = .chrome,
        .binary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        .config_dir = "/Users/u/.config/am",
        .url = "http://localhost:47823/?engine=abc",
        .headless = false,
        .widevine_from_google = false,
        .browser = .{ .candidates = &.{}, .exe_names = &.{"Google Chrome"}, .extra_args = &.{"--use-mock-keychain"} },
    });
    try testing.expectEqualStrings("--new-window", mac.argv[6]);
    try testing.expectEqualStrings("--use-mock-keychain", mac.argv[7]);
    try testing.expectEqualStrings("http://localhost:47823/?engine=abc", mac.argv[8]);
}

test "Firefox gets a new instance on its own profile, the safe-mode guard, and user.js prefs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const launch = try plan(arena.allocator(), .{
        .kind = .firefox,
        .binary = "/usr/bin/firefox-esr",
        .config_dir = "/home/u/.config/am",
        .url = "http://localhost:47823/?engine=abc",
        .headless = true,
        .widevine_from_google = false,
        .browser = .{ .candidates = &.{}, .exe_names = &.{"firefox-esr"} },
    });
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "/usr/bin/firefox-esr", "--new-instance", "--profile", "/home/u/.config/am/firefox-profile", "--headless", "http://localhost:47823/?engine=abc",
    }), launch.argv);
    try testing.expectEqualDeep(@as([]const [2][]const u8, &.{ .{ "MOZ_CRASHREPORTER_DISABLE", "1" }, .{ "MOZ_DISABLE_AUTO_SAFE_MODE", "1" } }), launch.env);

    const user_js = launch.user_js.?;
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"media.eme.enabled\", true);\n") != null);
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"media.autoplay.default\", 0);\n") != null);
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"toolkit.startup.max_resumed_crashes\", -1);\n") != null);
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"browser.startup.homepage_override.mstone\", \"ignore\");\n") != null);
    // Issue #1: no preloaded new tab (privilegedabout) and no socket process.
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"browser.newtab.preload\", false);\n") != null);
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"browser.newtabpage.enabled\", false);\n") != null);
    try testing.expect(std.mem.find(u8, user_js, "user_pref(\"network.process.enabled\", false);\n") != null);
    try testing.expect(std.mem.endsWith(u8, user_js, "user_pref(\"media.gmp-widevinecdm.force-chromium-update\", false);\n"));
}

test "FIREFOX_WIDEVINE=google turns on force-chromium-update" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const user_js = try firefoxUserJs(arena.allocator(), true);
    try testing.expect(std.mem.endsWith(u8, user_js, "user_pref(\"media.gmp-widevinecdm.force-chromium-update\", true);\n"));
}
