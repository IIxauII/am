//! Every am setting: its name, default, parser and the text of its problems. A setting comes
//! from the environment, else the env file (`<config dir>/env`), else its default.
const std = @import("std");
const apple = @import("apple.zig");
const config = @import("config.zig");
const developer_token = @import("developer_token.zig");
const engine = @import("engine.zig");
const platform = @import("platform.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

/// The names of the settings, as they are set.
pub const Name = enum {
    AM_PORT,
    ENGINE,
    ENGINE_IDLE_MINUTES,
    ENGINE_HEADLESS,
    FIREFOX_WIDEVINE,
    FIREFOX_PATH,
    CHROME_PATH,
    TEAM_ID,
    KEY_ID,
    TOKEN_URL,
    AM_IMAGES,
    AM_TUI_LOG,
};

/// `AM_PORT, ENGINE, … and AM_TUI_LOG`.
const all_names = names: {
    const names = std.meta.fieldNames(Name);
    var text: []const u8 = names[0];
    for (names[1 .. names.len - 1]) |n| text = text ++ ", " ++ n;
    break :names text ++ " and " ++ names[names.len - 1];
};

/// A setting whose bad value the daemon refuses to start with: the value, or why it can't be
/// used.
pub fn Checked(comptime T: type) type {
    return union(enum) {
        ok: T,
        /// The whole message, e.g. `AM_PORT must be a port number (1-65535), not abc`.
        bad: []const u8,
    };
}

/// `AM_PORT`'s default. The port is fixed on purpose: MusicKit keeps the Music User Token in
/// localStorage, which is scoped to the origin `http://localhost:<port>`.
pub const default_port = 47823;
pub const default_idle_minutes = 5;

comptime {
    // The shared developer token's origin claim and the Origin header name this port.
    std.debug.assert(std.mem.eql(u8, apple.origin, std.fmt.comptimePrint("http://localhost:{d}", .{default_port})));
}

/// Where the shared developer token comes from when `TOKEN_URL` is unset: the token service's
/// Worker (`am-token`, token-worker/wrangler.toml) on the owner's workers.dev subdomain.
pub const default_token_url = "https://am-token.xauyxau.workers.dev/token";

/// `AM_IMAGES`: how the TUI draws artwork.
pub const Images = enum {
    /// Kitty graphics where the terminal answers the query, else half blocks.
    auto,
    /// Kitty graphics, with placeholders where the terminal is known to have them.
    kitty,
    placeholders,
    placements,
    blocks,
    off,
};

/// What am runs with, one field per setting. Each process reads the fields it needs.
pub const Settings = struct {
    /// `AM_PORT`: the background process's port.
    port: Checked(u16) = .{ .ok = default_port },
    /// `ENGINE`: the browser the engine runs in.
    engine: Checked(engine.Kind) = .{ .ok = .firefox },
    /// `ENGINE_IDLE_MINUTES`: the engine closes once nothing has played for this long.
    engine_idle_minutes: Checked(u32) = .{ .ok = default_idle_minutes },
    /// `ENGINE_HEADLESS`: `0` shows the engine's window.
    engine_headless: bool = true,
    /// `FIREFOX_WIDEVINE=google`: Firefox takes Google's current Widevine instead of the one
    /// Mozilla serves.
    widevine_from_google: bool = false,
    /// `FIREFOX_PATH`: the Firefox binary, instead of looking in the usual places.
    firefox_path: ?[]const u8 = null,
    /// `CHROME_PATH`: the Chrome binary, instead of looking in the usual places.
    chrome_path: ?[]const u8 = null,
    /// `TEAM_ID`: the Apple Developer Team ID, for the user's own developer token.
    team_id: ?[]const u8 = null,
    /// `KEY_ID`: the ID of the user's MusicKit key.
    key_id: ?[]const u8 = null,
    /// `TOKEN_URL`: the shared developer token's service. Null when `TOKEN_URL=` (empty) in the
    /// env file turns it off; an empty environment variable counts as unset.
    token_url: ?[]const u8 = default_token_url,
    /// `AM_IMAGES`.
    images: Images = .auto,
    /// `AM_TUI_LOG`: the file the TUI writes what it does to (never tokens), for debugging.
    tui_log: ?[]const u8 = null,
    /// The values am ignores, behaving as if they were unset, and the keys in the env file it
    /// doesn't know: for `am doctor` and the daemon's log.
    warnings: []const []const u8 = &.{},

    /// TEAM_ID and KEY_ID, when both are set.
    pub fn ids(s: *const Settings) ?developer_token.Ids {
        return .{ .team_id = s.team_id orelse return null, .key_id = s.key_id orelse return null };
    }

    /// Why the daemon doesn't start with these settings: the first of AM_PORT, ENGINE and
    /// ENGINE_IDLE_MINUTES with a bad value. When null, all three are `ok`.
    pub fn refusal(s: *const Settings) ?[]const u8 {
        inline for (.{ s.port, s.engine, s.engine_idle_minutes }) |setting| switch (setting) {
            .ok => {},
            .bad => |why| return why,
        };
        return null;
    }

    /// FIREFOX_PATH or CHROME_PATH.
    pub fn browserPath(s: *const Settings, kind: engine.Kind) ?[]const u8 {
        return switch (kind) {
            .firefox => s.firefox_path,
            .chrome => s.chrome_path,
        };
    }
};

/// The setting that says where the `kind` browser is.
pub fn browserPathName(kind: engine.Kind) Name {
    return switch (kind) {
        .firefox => .FIREFOX_PATH,
        .chrome => .CHROME_PATH,
    };
}

/// The settings from `environ` and the env file in `config_dir`. Reloading them is calling
/// this again.
pub fn load(io: Io, arena: Allocator, config_dir: []const u8, environ: *const Environ.Map) config.ReadFileError!Settings {
    return parse(arena, environ, try config.readFile(io, arena, config_dir, config.file.env));
}

/// The settings from `environ` and the env file's text (null: there is none). Allocates into
/// `arena`.
pub fn parse(arena: Allocator, environ: *const Environ.Map, env_file: ?[]const u8) Allocator.Error!Settings {
    const source: Source = .{ .environ = environ, .file = try parseEnvFile(arena, env_file orelse "", platform.homeDir(environ)) };
    var warnings: std.ArrayList([]const u8) = .empty;
    var s: Settings = .{};
    if (source.get(.AM_PORT)) |v| s.port = if (port(v)) |p| .{ .ok = p } else .{ .bad = try arena.print("AM_PORT must be a port number (1-65535), not {s}", .{v}) };
    if (source.get(.ENGINE)) |v| s.engine = if (std.meta.stringToEnum(engine.Kind, v)) |k| .{ .ok = k } else .{ .bad = try arena.print("ENGINE must be firefox or chrome, not {s}", .{v}) };
    if (source.get(.ENGINE_IDLE_MINUTES)) |v| s.engine_idle_minutes = if (minutes(v)) |m| .{ .ok = m } else .{ .bad = try arena.print("ENGINE_IDLE_MINUTES must be a whole number of minutes (1 or more), not {s}", .{v}) };
    if (source.get(.ENGINE_HEADLESS)) |v| {
        if (std.mem.eql(u8, v, "0")) {
            s.engine_headless = false;
        } else if (!std.mem.eql(u8, v, "1")) {
            try warnings.append(arena, try arena.print("ENGINE_HEADLESS must be 0 (show the engine) or 1 (headless), not \"{s}\": ignored, the engine runs headless", .{v}));
        }
    }
    if (source.get(.FIREFOX_WIDEVINE)) |v| {
        if (std.mem.eql(u8, v, "google")) {
            s.widevine_from_google = true;
        } else {
            try warnings.append(arena, try arena.print("FIREFOX_WIDEVINE must be google (Google's current Widevine) or unset, not \"{s}\": ignored, Firefox keeps Mozilla's Widevine", .{v}));
        }
    }
    s.firefox_path = source.get(.FIREFOX_PATH);
    s.chrome_path = source.get(.CHROME_PATH);
    s.team_id = source.get(.TEAM_ID);
    s.key_id = source.get(.KEY_ID);
    if (source.get(.TOKEN_URL)) |v| {
        const url = config.trimSpace(v);
        s.token_url = if (url.len == 0) null else url;
    }
    if (source.get(.AM_IMAGES)) |v| s.images = images(v);
    s.tui_log = source.get(.AM_TUI_LOG);
    // Only the env file's keys: the environment holds unrelated variables, and the env file's
    // lines never reach the engine's environment.
    for (source.file.keys()) |key| if (std.meta.stringToEnum(Name, key) == null)
        try warnings.append(arena, try arena.print("{s} in the env file isn't a setting: ignored. The settings are " ++ all_names, .{key}));
    s.warnings = warnings.items;
    return s;
}

/// Where a setting's value comes from: the environment (an empty variable counts as unset),
/// else the env file.
const Source = struct {
    environ: *const Environ.Map,
    file: Environ.Map,

    fn get(s: *const Source, name: Name) ?[]const u8 {
        return config.getEnv(s.environ, @tagName(name)) orelse s.file.get(@tagName(name));
    }
};

fn port(value: []const u8) ?u16 {
    const p = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (p == 0) null else p;
}

/// Any letter case; `none` is `off`, and anything else is `auto`.
fn images(value: []const u8) Images {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .off;
    for (std.enums.values(Images)) |i| if (std.ascii.eqlIgnoreCase(value, @tagName(i))) return i;
    return .auto;
}

fn minutes(value: []const u8) ?u32 {
    const m = std.fmt.parseInt(u32, value, 10) catch return null;
    return if (m == 0) null else m;
}

/// Parses env-file text. `home` expands a leading `~`. Allocates into `arena`.
fn parseEnvFile(arena: Allocator, text: []const u8, home: ?[]const u8) !Environ.Map {
    var map: Environ.Map = .init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = config.trimSpace(line[0..eq]);
        if (!isKey(key)) continue;
        try map.put(key, try expandHome(arena, unquote(config.trimSpace(line[eq + 1 ..])), home));
    }
    return map;
}

fn isKey(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

fn expandHome(arena: Allocator, value: []const u8, home: ?[]const u8) ![]const u8 {
    const h = home orelse return value;
    if (std.mem.eql(u8, value, "~")) return h;
    if (std.mem.startsWith(u8, value, "~/")) return std.mem.concat(arena, u8, &.{ h, value[1..] });
    return value;
}

const testing = std.testing;

const Case = struct {
    /// Environment variables.
    environ: []const [2][]const u8 = &.{},
    /// The env file's text.
    file: ?[]const u8 = null,
    want: Settings,
};

test "parse: every setting's default, a junk value, the environment over the env file, and unknown keys" {
    const cases = [_]Case{
        // Nothing set: every default.
        .{ .want = .{
            .port = .{ .ok = 47823 },
            .engine = .{ .ok = .firefox },
            .engine_idle_minutes = .{ .ok = 5 },
            .engine_headless = true,
            .widevine_from_google = false,
            .firefox_path = null,
            .chrome_path = null,
            .team_id = null,
            .key_id = null,
            .token_url = "https://am-token.xauyxau.workers.dev/token",
            .images = .auto,
            .tui_log = null,
            .warnings = &.{},
        } },
        .{ .file = "AM_PORT=50000\n", .want = .{ .port = .{ .ok = 50000 } } },
        .{ .file = "AM_PORT=0\n", .want = .{ .port = .{ .bad = "AM_PORT must be a port number (1-65535), not 0" } } },
        .{ .file = "AM_PORT=70000\n", .want = .{ .port = .{ .bad = "AM_PORT must be a port number (1-65535), not 70000" } } },
        .{ .file = "AM_PORT=http\n", .want = .{ .port = .{ .bad = "AM_PORT must be a port number (1-65535), not http" } } },
        .{ .file = "ENGINE=chrome\n", .want = .{ .engine = .{ .ok = .chrome } } },
        .{ .file = "ENGINE=firefox\n", .want = .{ .engine = .{ .ok = .firefox } } },
        .{ .file = "ENGINE=safari\n", .want = .{ .engine = .{ .bad = "ENGINE must be firefox or chrome, not safari" } } },
        .{ .file = "ENGINE_IDLE_MINUTES=1\n", .want = .{ .engine_idle_minutes = .{ .ok = 1 } } },
        .{ .file = "ENGINE_IDLE_MINUTES=0\n", .want = .{ .engine_idle_minutes = .{ .bad = "ENGINE_IDLE_MINUTES must be a whole number of minutes (1 or more), not 0" } } },
        .{ .file = "ENGINE_IDLE_MINUTES=-1\n", .want = .{ .engine_idle_minutes = .{ .bad = "ENGINE_IDLE_MINUTES must be a whole number of minutes (1 or more), not -1" } } },
        .{ .file = "ENGINE_IDLE_MINUTES=1.5\n", .want = .{ .engine_idle_minutes = .{ .bad = "ENGINE_IDLE_MINUTES must be a whole number of minutes (1 or more), not 1.5" } } },
        .{ .file = "ENGINE_HEADLESS=0\n", .want = .{ .engine_headless = false } },
        .{ .file = "ENGINE_HEADLESS=1\n", .want = .{ .engine_headless = true } },
        // Ignored as before, now with a warning.
        .{ .file = "ENGINE_HEADLESS=false\n", .want = .{ .engine_headless = true, .warnings = &.{
            "ENGINE_HEADLESS must be 0 (show the engine) or 1 (headless), not \"false\": ignored, the engine runs headless",
        } } },
        .{ .file = "FIREFOX_WIDEVINE=google\n", .want = .{ .widevine_from_google = true } },
        .{ .file = "FIREFOX_WIDEVINE=Google\n", .want = .{ .widevine_from_google = false, .warnings = &.{
            "FIREFOX_WIDEVINE must be google (Google's current Widevine) or unset, not \"Google\": ignored, Firefox keeps Mozilla's Widevine",
        } } },
        // `~` is HOME in the env file.
        .{ .environ = &.{.{ "HOME", "/home/u" }}, .file = "FIREFOX_PATH=~/bin/firefox\nCHROME_PATH=/opt/chrome\n", .want = .{ .firefox_path = "/home/u/bin/firefox", .chrome_path = "/opt/chrome" } },
        .{ .file = "TEAM_ID=TEAM123456\n", .want = .{ .team_id = "TEAM123456" } },
        .{ .file = "KEY_ID=KEY1234567\n", .want = .{ .key_id = "KEY1234567" } },
        .{ .file = "TOKEN_URL= https://x.example/token \n", .want = .{ .token_url = "https://x.example/token" } },
        // Empty turns the shared token off.
        .{ .file = "TOKEN_URL=\n", .want = .{ .token_url = null } },
        .{ .file = "AM_IMAGES=kitty\n", .want = .{ .images = .kitty } },
        .{ .file = "AM_IMAGES=Placeholders\n", .want = .{ .images = .placeholders } },
        .{ .file = "AM_IMAGES=placements\n", .want = .{ .images = .placements } },
        .{ .file = "AM_IMAGES=blocks\n", .want = .{ .images = .blocks } },
        .{ .file = "AM_IMAGES=off\n", .want = .{ .images = .off } },
        .{ .file = "AM_IMAGES=none\n", .want = .{ .images = .off } },
        // Anything else is automatic, as before.
        .{ .file = "AM_IMAGES=nonsense\n", .want = .{ .images = .auto } },
        .{ .environ = &.{.{ "HOME", "/home/u" }}, .file = "AM_TUI_LOG=~/am-tui.log\n", .want = .{ .tui_log = "/home/u/am-tui.log" } },
        // The environment wins over the env file, for every setting.
        .{
            .environ = &.{
                .{ "AM_PORT", "48000" },                       .{ "ENGINE", "chrome" },           .{ "ENGINE_IDLE_MINUTES", "9" },
                .{ "ENGINE_HEADLESS", "0" },                   .{ "FIREFOX_WIDEVINE", "google" }, .{ "FIREFOX_PATH", "/env/firefox" },
                .{ "CHROME_PATH", "/env/chrome" },             .{ "TEAM_ID", "ENVTEAM" },         .{ "KEY_ID", "ENVKEY" },
                .{ "TOKEN_URL", "https://env.example/token" }, .{ "AM_IMAGES", "blocks" },        .{ "AM_TUI_LOG", "/env/tui.log" },
            },
            .file =
            \\AM_PORT=50000
            \\ENGINE=safari
            \\ENGINE_IDLE_MINUTES=0
            \\ENGINE_HEADLESS=false
            \\FIREFOX_WIDEVINE=Google
            \\FIREFOX_PATH=/file/firefox
            \\CHROME_PATH=/file/chrome
            \\TEAM_ID=FILETEAM
            \\KEY_ID=FILEKEY
            \\TOKEN_URL=
            \\AM_IMAGES=off
            \\AM_TUI_LOG=/file/tui.log
            \\
            ,
            .want = .{
                .port = .{ .ok = 48000 },
                .engine = .{ .ok = .chrome },
                .engine_idle_minutes = .{ .ok = 9 },
                .engine_headless = false,
                .widevine_from_google = true,
                .firefox_path = "/env/firefox",
                .chrome_path = "/env/chrome",
                .team_id = "ENVTEAM",
                .key_id = "ENVKEY",
                .token_url = "https://env.example/token",
                .images = .blocks,
                .tui_log = "/env/tui.log",
            },
        },
        // An empty environment variable counts as unset.
        .{ .environ = &.{ .{ "KEY_ID", "" }, .{ "TOKEN_URL", "" } }, .file = "KEY_ID=FILEKEY\n", .want = .{ .key_id = "FILEKEY" } },
        // An unknown key in the env file is ignored, with a warning that names am's settings. In
        // the environment, which holds unrelated variables, it isn't.
        .{ .environ = &.{.{ "SOMETHING_ELSE", "1" }}, .file = "ENGINE_IDEL_MINUTES=10\nAM_PORT=48000\n", .want = .{ .port = .{ .ok = 48000 }, .warnings = &.{
            "ENGINE_IDEL_MINUTES in the env file isn't a setting: ignored. The settings are AM_PORT, ENGINE, ENGINE_IDLE_MINUTES, ENGINE_HEADLESS, FIREFOX_WIDEVINE, FIREFOX_PATH, CHROME_PATH, TEAM_ID, KEY_ID, TOKEN_URL, AM_IMAGES and AM_TUI_LOG",
        } } },
    };
    for (cases, 0..) |case, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var environ: Environ.Map = .init(a);
        for (case.environ) |kv| try environ.put(kv[0], kv[1]);
        try testing.expectEqualDeep(case.want, try parse(a, &environ, case.file));
    }
}

test "the daemon refuses to start over a bad AM_PORT, ENGINE or ENGINE_IDLE_MINUTES, the first of them" {
    try testing.expectEqual(null, (Settings{ .warnings = &.{"a warning"} }).refusal());
    try testing.expectEqualStrings("ENGINE is bad", (Settings{ .engine = .{ .bad = "ENGINE is bad" } }).refusal().?);
    try testing.expectEqualStrings("idle is bad", (Settings{ .engine_idle_minutes = .{ .bad = "idle is bad" } }).refusal().?);
    try testing.expectEqualStrings("AM_PORT is bad", (Settings{ .port = .{ .bad = "AM_PORT is bad" }, .engine = .{ .bad = "ENGINE is bad" } }).refusal().?);
}

test "the developer token's ids: TEAM_ID and KEY_ID, both or none" {
    try testing.expectEqual(null, (Settings{ .team_id = "T" }).ids());
    try testing.expectEqual(null, (Settings{ .key_id = "K" }).ids());
    const both = (Settings{ .team_id = "T", .key_id = "K" }).ids().?;
    try testing.expectEqualStrings("T", both.team_id);
    try testing.expectEqualStrings("K", both.key_id);
}

test "the env file is KEY=VALUE lines, with optional quotes and ~ expanded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\# comment
        \\TEAM_ID=TEAM123456
        \\  KEY_ID = "KEY1234567"
        \\FIREFOX_PATH='~/bin/firefox'
        \\CHROME_PATH=~
        \\NOT_HOME=a~b
        \\lowercase=ignored
        \\garbage line
        \\EMPTY=
        \\MISMATCHED="quote'
        \\
    ;
    const map = try parseEnvFile(arena.allocator(), text, "/home/u");
    try testing.expectEqualStrings("TEAM123456", map.get("TEAM_ID").?);
    try testing.expectEqualStrings("KEY1234567", map.get("KEY_ID").?);
    try testing.expectEqualStrings("/home/u/bin/firefox", map.get("FIREFOX_PATH").?);
    try testing.expectEqualStrings("/home/u", map.get("CHROME_PATH").?);
    try testing.expectEqualStrings("a~b", map.get("NOT_HOME").?);
    try testing.expectEqualStrings("", map.get("EMPTY").?);
    try testing.expectEqualStrings("\"quote'", map.get("MISMATCHED").?);
    try testing.expectEqual(null, map.get("lowercase"));
    try testing.expectEqual(@as(usize, 7), map.count());
}
