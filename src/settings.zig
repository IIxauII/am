//! Every am setting: its name, default, parser and the text of its problems. A setting comes
//! from the environment, else the env file (`<config dir>/env`), else its default. The TUI's
//! own settings come from the settings file (`<config dir>/settings.json`, `Tui`), which holds
//! only what differs from the defaults, and `AM_IMAGES` wins over its artwork.
const std = @import("std");
const builtin = @import("builtin");
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

/// A setting's value, or why it can't be used. Whatever needs it refuses to go on: the daemon
/// doesn't start without AM_PORT, ENGINE and ENGINE_IDLE_MINUTES (`daemonStart`), and the shared
/// developer token needs TOKEN_URL.
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

comptime {
    // It goes in unchecked, so check it here, where no build can skip it.
    @setEvalBranchQuota(10_000);
    std.debug.assert(validTokenUrl(default_token_url));
}

/// `AM_IMAGES`: how the TUI draws artwork.
pub const Images = @import("tui/graphics.zig").Images;

/// What am runs with: a field per setting, and the warnings about them. Each process reads the
/// fields it needs.
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
    /// `TOKEN_URL`: the shared developer token's service: https, or plain http to this machine
    /// (`wrangler dev`). Null when `TOKEN_URL=` (empty) in the env file turns it off; an empty
    /// environment variable counts as unset.
    token_url: Checked(?[]const u8) = .{ .ok = default_token_url },
    /// `AM_IMAGES`; null when unset. When set, it wins over settings.json's artwork for the run
    /// (`parseTui`).
    images: ?Images = null,
    /// `AM_TUI_LOG`: the file the TUI writes what it does to (never tokens), for debugging. It is
    /// truncated, so the env file must give an absolute path (or `~/…`): a relative one would
    /// name a different file in each directory am runs in.
    tui_log: ?[]const u8 = null,
    /// The values am ignores, behaving as if they were unset, and the keys and lines in the env
    /// file it doesn't understand: for `am doctor` and the daemon's log.
    warnings: []const []const u8 = &.{},

    /// TEAM_ID and KEY_ID, when both are set.
    pub fn ids(s: *const Settings) ?developer_token.Ids {
        return .{ .team_id = s.team_id orelse return null, .key_id = s.key_id orelse return null };
    }

    /// What the daemon doesn't start without, or why it doesn't start: the first of AM_PORT,
    /// ENGINE and ENGINE_IDLE_MINUTES with a bad value.
    pub fn daemonStart(s: *const Settings) Checked(Start) {
        const port = switch (s.port) {
            .ok => |p| p,
            .bad => |why| return .{ .bad = why },
        };
        const kind = switch (s.engine) {
            .ok => |k| k,
            .bad => |why| return .{ .bad = why },
        };
        const idle_minutes = switch (s.engine_idle_minutes) {
            .ok => |m| m,
            .bad => |why| return .{ .bad = why },
        };
        return .{ .ok = .{ .port = port, .engine = kind, .idle_minutes = idle_minutes } };
    }

    /// FIREFOX_PATH or CHROME_PATH.
    pub fn browserPath(s: *const Settings, kind: engine.Kind) ?[]const u8 {
        return switch (kind) {
            .firefox => s.firefox_path,
            .chrome => s.chrome_path,
        };
    }
};

/// settings.json's `artwork`.
pub const Artwork = @import("tui/graphics.zig").Artwork;

/// The TUI's own settings: the settings file's (`settings.json` in the config directory), with
/// `AM_IMAGES` over its artwork. Only the TUI reads them, once at start.
pub const Tui = struct {
    /// How artwork is drawn at start: the file's `artwork`, or what `AM_IMAGES` picks.
    artwork: Artwork = .images,
    /// What Images draws: `auto` (kitty images where the terminal can show them, else half
    /// blocks), or the kitty protocol `AM_IMAGES` names.
    images: Images = .auto,
    /// `AM_IMAGES` is set: it wins over the file's artwork for the run, so `v` changes only the
    /// session.
    images_set: bool = false,
    /// Why am never writes the file (it isn't valid JSON, or can't be read), e.g.
    /// `settings.json isn't valid JSON`; null when it can. Its settings are then the defaults.
    unwritable: ?[]const u8 = null,
    /// What is wrong with the file, in the file's order; each bad entry falls back to its
    /// default. The TUI's status line names the first at startup.
    problems: []const []const u8 = &.{},

    /// Why a change to artwork lasts only for the session, or null when it is saved.
    pub fn artworkSessionOnly(t: *const Tui) ?[]const u8 {
        return if (t.images_set) "AM_IMAGES is set" else t.unwritable;
    }
};

/// The TUI's settings from settings.json's text (null: there is none) and `AM_IMAGES` (null:
/// unset). Allocates into `arena`.
pub fn parseTui(arena: Allocator, images: ?Images, text: ?[]const u8) Allocator.Error!Tui {
    var t: Tui = .{};
    var problems: std.ArrayList([]const u8) = .empty;
    const object: std.json.ObjectMap = switch (try parseObject(arena, text orelse "")) {
        .object => |o| o,
        .bad => |bad| o: {
            t.unwritable = bad.why;
            try problems.append(arena, try arena.print("{s}{s}: using the defaults and leaving the file alone", .{ bad.why, bad.where }));
            break :o .empty;
        },
    };
    if (object.get("artwork")) |v| {
        t.artwork = parseArtwork(v) orelse a: {
            try problems.append(arena, try arena.print("artwork in settings.json must be \"images\", \"blocks\" or \"off\", not {f}: showing images", .{std.json.fmt(v, .{})}));
            break :a .images;
        };
    }
    if (images) |i| {
        t.images_set = true;
        t.artwork = switch (i) {
            .blocks => .blocks,
            .off => .off,
            .auto, .kitty, .placeholders, .placements => .images,
        };
        if (t.artwork == .images) t.images = i;
    }
    t.problems = problems.items;
    return t;
}

/// The TUI's settings from settings.json in `config_dir` and `AM_IMAGES` (`Settings.images`).
/// A file that can't be read counts as one that isn't valid JSON: the defaults, a problem, and
/// never written.
pub fn loadTui(io: Io, arena: Allocator, config_dir: []const u8, images: ?Images) Allocator.Error!Tui {
    const text = config.readFile(io, arena, config_dir, config.file.settings) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const why = "can't read settings.json";
            var t = try parseTui(arena, images, null);
            t.unwritable = why;
            t.problems = try arena.dupe([]const u8, &.{try arena.print(why ++ " ({t}): using the defaults and leaving the file alone", .{e})});
            return t;
        },
    };
    return parseTui(arena, images, text);
}

pub const Saved = union(enum) {
    saved,
    /// The file says so already.
    unchanged,
    /// Why the file is never written (`Applied.refused`).
    refused: []const u8,
};

/// Saves one change: reads settings.json in `config_dir` again, applies `change` on top
/// (`applyChange`), and replaces the file atomically, with a temporary file and a rename. So a
/// hand edit since the TUI started, or another TUI's save, survives.
pub fn saveChange(io: Io, arena: Allocator, config_dir: []const u8, change: Change) !Saved {
    const text = try config.readFile(io, arena, config_dir, config.file.settings);
    switch (try applyChange(arena, text, change)) {
        .unchanged => return .unchanged,
        .refused => |why| return .{ .refused = why },
        .text => |new| {
            try writeTuiFile(io, arena, config_dir, new);
            return .saved;
        },
    }
}

/// Replaces settings.json, as the TUI's state file is replaced (`platform.writePrivateFile`). A
/// settings.json that links elsewhere (dotfiles) stays a link: the file it points to is replaced
/// instead, and its directory, which isn't am's, keeps its permissions.
fn writeTuiFile(io: Io, arena: Allocator, config_dir: []const u8, text: []const u8) !void {
    const path = try Io.Dir.path.join(arena, &.{ config_dir, config.file.settings });
    const linked = if (Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |s| s.kind == .sym_link else |_| false;
    // A dangling link, or one that can't be followed, is replaced by am's own file.
    const target = if (linked) Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    } else null;
    const t = target orelse return platform.writePrivateFile(io, config_dir, config.file.settings, text);
    var dir = try Io.Dir.cwd().openDir(io, Io.Dir.path.dirname(t) orelse return error.FileNotFound, .{});
    defer dir.close(io);
    var file = try dir.createFileAtomic(io, Io.Dir.path.basename(t), .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, text);
    try file.replace(io);
}

/// One change to the settings file.
pub const Change = union(enum) {
    artwork: Artwork,
};

/// What a change does to the settings file's text.
pub const Applied = union(enum) {
    /// The file's new text.
    text: []const u8,
    /// The file says so already: nothing to write.
    unchanged,
    /// The text isn't one am can write back (`Tui.unwritable`, e.g. `settings.json isn't valid
    /// JSON`): the file is never overwritten.
    refused: []const u8,
};

/// Applies one change on top of the settings file's text as it is now (null: there is none),
/// keeping every other entry, the ones am doesn't know included, in their order. A change back
/// to an entry's default removes the entry. Allocates into `arena`.
pub fn applyChange(arena: Allocator, text: ?[]const u8, change: Change) Allocator.Error!Applied {
    var object = switch (try parseObject(arena, text orelse "")) {
        .object => |o| o,
        .bad => |bad| return .{ .refused = bad.why },
    };
    const changed = switch (change) {
        .artwork => |a| try setEntry(arena, &object, "artwork", if (a == .images) null else .{ .string = @tagName(a) }),
    };
    if (!changed) return .unchanged;
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(std.json.Value{ .object = object }, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return .{ .text = out.written() };
}

/// Sets entry `name` to `value` where it is, else last; null removes it (the default). False
/// when the object has that already.
fn setEntry(arena: Allocator, object: *std.json.ObjectMap, name: []const u8, value: ?std.json.Value) Allocator.Error!bool {
    const new = value orelse return object.orderedRemove(name);
    if (object.getPtr(name)) |old| {
        if (old.* == .string and new == .string and std.mem.eql(u8, old.string, new.string)) return false;
        old.* = new;
        return true;
    }
    try object.put(arena, name, new);
    return true;
}

/// settings.json's text as a JSON object, or why am can't use it.
const Object = union(enum) {
    object: std.json.ObjectMap,
    bad: struct {
        /// E.g. `settings.json isn't valid JSON`.
        why: []const u8,
        /// Where in the file, e.g. ` (line 3, column 1)`, or empty.
        where: []const u8 = "",
    },
};

/// How deep `{}` and `[]` may nest. A save writes the file back with `std.json.Stringify`, which
/// stops at 256 levels.
const max_nesting = 128;

/// The text's object. An empty file (blanks only) holds nothing to lose: it is an empty object.
fn parseObject(arena: Allocator, text: []const u8) Allocator.Error!Object {
    if (config.trimSpace(text).len == 0) return .{ .object = .empty };
    var scanner: std.json.Scanner = .initCompleteInput(arena, text);
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    const value = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, json_options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .bad = .{
            .why = "settings.json isn't valid JSON",
            .where = try arena.print(" (line {d}, column {d})", .{ diagnostics.getLine(), diagnostics.getColumn() }),
        } },
    };
    if (value != .object) return .{ .bad = .{ .why = "settings.json isn't a JSON object", .where = " ({ … })" } };
    if (try nesting(arena, text) > max_nesting) return .{ .bad = .{ .why = std.fmt.comptimePrint("settings.json nests more than {d} levels deep", .{max_nesting}) } };
    return .{ .object = value.object };
}

/// How deep `{}` and `[]` nest in `text`, which is valid JSON.
fn nesting(arena: Allocator, text: []const u8) Allocator.Error!usize {
    var scanner: std.json.Scanner = .initCompleteInput(arena, text);
    var deepest: usize = 0;
    while (true) switch (scanner.next() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Not reached for valid JSON; too deep to write is the safe answer.
        else => return max_nesting + 1,
    }) {
        .object_begin, .array_begin => deepest = @max(deepest, scanner.stackHeight()),
        .end_of_document => return deepest,
        else => {},
    };
}

/// Numbers stay as they are written, so a save writes back the ones am doesn't know unchanged.
const json_options: std.json.ParseOptions = .{ .parse_numbers = false, .duplicate_field_behavior = .use_last };

/// Any letter case, as `AM_IMAGES`.
fn parseArtwork(v: std.json.Value) ?Artwork {
    const s = switch (v) {
        .string => |s| s,
        else => return null,
    };
    for (std.enums.values(Artwork)) |a| if (std.ascii.eqlIgnoreCase(s, @tagName(a))) return a;
    return null;
}

/// AM_PORT, ENGINE and ENGINE_IDLE_MINUTES, all good: what the daemon starts with.
pub const Start = struct {
    port: u16,
    engine: engine.Kind,
    idle_minutes: u32,
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
    const file = try parseEnvFile(arena, env_file orelse "", platform.homeDir(environ));
    const source: Source = .{ .environ = environ, .file = file.map };
    var warnings: std.ArrayList([]const u8) = .empty;
    var s: Settings = .{};
    if (source.get(.AM_PORT)) |v| s.port = if (parsePositive(u16, v)) |p| .{ .ok = p } else .{ .bad = try arena.print("AM_PORT must be a port number (1-65535), not {s}", .{v}) };
    if (source.get(.ENGINE)) |v| s.engine = if (std.meta.stringToEnum(engine.Kind, v)) |k| .{ .ok = k } else .{ .bad = try arena.print("ENGINE must be firefox or chrome, not {s}", .{v}) };
    if (source.get(.ENGINE_IDLE_MINUTES)) |v| s.engine_idle_minutes = if (parsePositive(u32, v)) |m| .{ .ok = m } else .{ .bad = try arena.print("ENGINE_IDLE_MINUTES must be a whole number of minutes (1 or more), not {s}", .{v}) };
    if (source.lookup(.ENGINE_HEADLESS)) |v| {
        if (std.mem.eql(u8, v.text, "0")) {
            s.engine_headless = false;
        } else if (!std.mem.eql(u8, v.text, "1")) {
            try warnings.append(arena, try arena.print("ENGINE_HEADLESS {s} must be 0 (show the engine) or 1 (headless), not \"{s}\": ignored, the engine runs headless", .{ v.where(), v.text }));
        }
    }
    if (source.lookup(.FIREFOX_WIDEVINE)) |v| {
        if (std.mem.eql(u8, v.text, "google")) {
            s.widevine_from_google = true;
        } else {
            try warnings.append(arena, try arena.print("FIREFOX_WIDEVINE {s} must be google (Google's current Widevine) or unset, not \"{s}\": ignored, Firefox keeps Mozilla's Widevine", .{ v.where(), v.text }));
        }
    }
    s.firefox_path = source.get(.FIREFOX_PATH);
    s.chrome_path = source.get(.CHROME_PATH);
    s.team_id = source.get(.TEAM_ID);
    s.key_id = source.get(.KEY_ID);
    if (source.get(.TOKEN_URL)) |v| {
        const url = config.trimSpace(v);
        s.token_url = if (url.len == 0)
            .{ .ok = null }
        else if (validTokenUrl(url))
            .{ .ok = url }
        else
            .{ .bad = try arena.print("TOKEN_URL must be an https:// URL (or http://localhost:<port> or http://127.0.0.1:<port>), not {s}", .{url}) };
    }
    if (source.get(.AM_IMAGES)) |v| s.images = parseImages(v);
    if (source.lookup(.AM_TUI_LOG)) |v| {
        if (v.from == .env_file and !Io.Dir.path.isAbsolute(v.text)) {
            try warnings.append(arena, try arena.print("AM_TUI_LOG in the env file must be an absolute path or start with ~/, not \"{s}\": ignored, the TUI doesn't log", .{v.text}));
        } else {
            s.tui_log = v.text;
        }
    }
    // Only the env file's keys: the environment holds unrelated variables, and the env file's
    // lines never reach the engine's environment.
    for (source.file.keys()) |key| if (std.meta.stringToEnum(Name, key) == null)
        try warnings.append(arena, try arena.print("{s} in the env file isn't a setting: ignored. The settings are " ++ all_names, .{key}));
    for (file.bad_lines) |line|
        try warnings.append(arena, try arena.print("\"{s}\" in the env file isn't NAME=value with NAME in capital letters: ignored", .{line}));
    s.warnings = warnings.items;
    return s;
}

/// Where a setting's value comes from: the environment, else the env file. An empty value
/// counts as unset, except `TOKEN_URL=` in the env file, which turns the shared token off.
const Source = struct {
    environ: *const Environ.Map,
    file: Environ.Map,

    const Value = struct {
        text: []const u8,
        from: enum { environment, env_file },

        /// For a warning: `in the environment` or `in the env file`.
        fn where(v: Value) []const u8 {
            return switch (v.from) {
                .environment => "in the environment",
                .env_file => "in the env file",
            };
        }
    };

    fn lookup(s: *const Source, name: Name) ?Value {
        if (config.getEnv(s.environ, @tagName(name))) |text| return .{ .text = text, .from = .environment };
        const text = s.file.get(@tagName(name)) orelse return null;
        if (text.len == 0 and name != .TOKEN_URL) return null;
        return .{ .text = text, .from = .env_file };
    }

    fn get(s: *const Source, name: Name) ?[]const u8 {
        return if (s.lookup(name)) |v| v.text else null;
    }
};

/// A whole number, 1 or more.
fn parsePositive(comptime T: type, value: []const u8) ?T {
    const n = std.fmt.parseInt(T, value, 10) catch return null;
    return if (n == 0) null else n;
}

/// Any letter case; `none` is `off`, and anything else is `auto`.
fn parseImages(value: []const u8) Images {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .off;
    for (std.enums.values(Images)) |i| if (std.ascii.eqlIgnoreCase(value, @tagName(i))) return i;
    return .auto;
}

/// https to any host, or plain http to this machine (`wrangler dev`). Parsed the way std.http
/// parses it, so the host checked is the one it connects to; user info is refused.
fn validTokenUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null) return false;
    const host = switch (uri.host orelse return false) {
        .raw, .percent_encoded => |h| h,
    };
    if (host.len == 0 or std.mem.findScalar(u8, host, '%') != null) return false;
    if (std.mem.eql(u8, uri.scheme, "https")) return true;
    if (!std.mem.eql(u8, uri.scheme, "http")) return false;
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
}

const EnvFile = struct {
    map: Environ.Map,
    /// The lines that are neither blank, a `#` comment nor NAME=value, trimmed: ignored.
    bad_lines: []const []const u8,
};

/// Parses env-file text: NAME=value lines, `export NAME=value` as a shell writes them. `home`
/// expands a leading `~`. Allocates into `arena`.
fn parseEnvFile(arena: Allocator, text: []const u8, home: ?[]const u8) Allocator.Error!EnvFile {
    var map: Environ.Map = .init(arena);
    var bad_lines: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = config.trimSpace(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const assignment = withoutExport(line);
        const eq = std.mem.findScalar(u8, assignment, '=');
        const key = config.trimSpace(assignment[0 .. eq orelse 0]);
        if (eq == null or !isKey(key)) {
            try bad_lines.append(arena, line);
            continue;
        }
        try map.put(key, try expandHome(arena, unquote(config.trimSpace(assignment[eq.? + 1 ..])), home));
    }
    return .{ .map = map, .bad_lines = bad_lines.items };
}

/// `NAME=value` from `export NAME=value`.
fn withoutExport(line: []const u8) []const u8 {
    const prefix = "export";
    if (line.len > prefix.len and std.mem.startsWith(u8, line, prefix) and (line[prefix.len] == ' ' or line[prefix.len] == '\t'))
        return config.trimSpace(line[prefix.len..]);
    return line;
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

/// The home directory, as `platform.homeDir` reads it: HOME, or USERPROFILE on Windows.
const home_environ = [_][2][]const u8{ .{ "HOME", "/home/u" }, .{ "USERPROFILE", "/home/u" } };

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
            .token_url = .{ .ok = "https://am-token.xauyxau.workers.dev/token" },
            // Unset: settings.json's artwork applies.
            .images = null,
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
        // Ignored as before, now with a warning that says where the value is.
        .{ .file = "ENGINE_HEADLESS=false\n", .want = .{ .engine_headless = true, .warnings = &.{
            "ENGINE_HEADLESS in the env file must be 0 (show the engine) or 1 (headless), not \"false\": ignored, the engine runs headless",
        } } },
        .{ .environ = &.{.{ "ENGINE_HEADLESS", "false" }}, .want = .{ .engine_headless = true, .warnings = &.{
            "ENGINE_HEADLESS in the environment must be 0 (show the engine) or 1 (headless), not \"false\": ignored, the engine runs headless",
        } } },
        .{ .file = "FIREFOX_WIDEVINE=google\n", .want = .{ .widevine_from_google = true } },
        .{ .file = "FIREFOX_WIDEVINE=Google\n", .want = .{ .widevine_from_google = false, .warnings = &.{
            "FIREFOX_WIDEVINE in the env file must be google (Google's current Widevine) or unset, not \"Google\": ignored, Firefox keeps Mozilla's Widevine",
        } } },
        // `~` is the home directory in the env file.
        .{ .environ = &home_environ, .file = "FIREFOX_PATH=~/bin/firefox\nCHROME_PATH=/opt/chrome\n", .want = .{ .firefox_path = "/home/u/bin/firefox", .chrome_path = "/opt/chrome" } },
        .{ .file = "TEAM_ID=TEAM123456\n", .want = .{ .team_id = "TEAM123456" } },
        .{ .file = "KEY_ID=KEY1234567\n", .want = .{ .key_id = "KEY1234567" } },
        .{ .file = "TOKEN_URL= https://x.example/token \n", .want = .{ .token_url = .{ .ok = "https://x.example/token" } } },
        // Empty turns the shared token off.
        .{ .file = "TOKEN_URL=\n", .want = .{ .token_url = .{ .ok = null } } },
        .{ .file = "TOKEN_URL=ftp://x\n", .want = .{ .token_url = .{ .bad = "TOKEN_URL must be an https:// URL (or http://localhost:<port> or http://127.0.0.1:<port>), not ftp://x" } } },
        .{ .file = "AM_IMAGES=kitty\n", .want = .{ .images = .kitty } },
        .{ .file = "AM_IMAGES=Placeholders\n", .want = .{ .images = .placeholders } },
        .{ .file = "AM_IMAGES=placements\n", .want = .{ .images = .placements } },
        .{ .file = "AM_IMAGES=blocks\n", .want = .{ .images = .blocks } },
        .{ .file = "AM_IMAGES=off\n", .want = .{ .images = .off } },
        .{ .file = "AM_IMAGES=none\n", .want = .{ .images = .off } },
        // Set to auto, or anything else, is automatic, as before, and still wins over
        // settings.json.
        .{ .file = "AM_IMAGES=auto\n", .want = .{ .images = .auto } },
        .{ .file = "AM_IMAGES=nonsense\n", .want = .{ .images = .auto } },
        .{ .environ = &home_environ, .file = "AM_TUI_LOG=~/am-tui.log\n", .want = .{ .tui_log = "/home/u/am-tui.log" } },
        // A relative AM_TUI_LOG in the env file would truncate a file wherever am runs; in the
        // environment, it is the shell's own directory.
        .{ .file = "AM_TUI_LOG=notes.txt\n", .want = .{ .tui_log = null, .warnings = &.{
            "AM_TUI_LOG in the env file must be an absolute path or start with ~/, not \"notes.txt\": ignored, the TUI doesn't log",
        } } },
        .{ .environ = &.{.{ "AM_TUI_LOG", "notes.txt" }}, .want = .{ .tui_log = "notes.txt" } },
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
                .token_url = .{ .ok = "https://env.example/token" },
                .images = .blocks,
                .tui_log = "/env/tui.log",
            },
        },
        // An empty environment variable counts as unset.
        .{ .environ = &.{ .{ "KEY_ID", "" }, .{ "TOKEN_URL", "" } }, .file = "KEY_ID=FILEKEY\n", .want = .{ .key_id = "FILEKEY" } },
        // So does an empty value in the env file, but for TOKEN_URL (above).
        .{
            .file = "AM_PORT=\nENGINE=\nENGINE_IDLE_MINUTES=\nENGINE_HEADLESS=\nFIREFOX_WIDEVINE=\nFIREFOX_PATH=\nCHROME_PATH=\"\"\nTEAM_ID=\nKEY_ID=\nAM_IMAGES=\nAM_TUI_LOG=\n",
            .want = .{},
        },
        // `export NAME=value` is a setting; any other line that isn't NAME=value is ignored with
        // a warning.
        .{ .file = "# comment\nexport ENGINE=chrome\nengine=firefox\nENGINE firefox\n\n", .want = .{ .engine = .{ .ok = .chrome }, .warnings = &.{
            "\"engine=firefox\" in the env file isn't NAME=value with NAME in capital letters: ignored",
            "\"ENGINE firefox\" in the env file isn't NAME=value with NAME in capital letters: ignored",
        } } },
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

const TuiCase = struct {
    /// `AM_IMAGES`, as `parse` reads it; null: unset.
    images: ?Images = null,
    /// settings.json's text; null: there is none.
    file: ?[]const u8 = null,
    want: Tui,
};

test "parseTui: settings.json's defaults, a bad artwork value, unknown entries, AM_IMAGES winning, and a file that isn't valid JSON" {
    const cases = [_]TuiCase{
        // No file: every default.
        .{ .want = .{ .artwork = .images, .images = .auto, .images_set = false, .unwritable = null, .problems = &.{} } },
        .{ .file = "{}", .want = .{} },
        .{ .file = "{\"artwork\": \"blocks\"}\n", .want = .{ .artwork = .blocks } },
        .{ .file = "{\"artwork\": \"off\"}\n", .want = .{ .artwork = .off } },
        .{ .file = "{\"artwork\": \"images\"}\n", .want = .{ .artwork = .images } },
        // Any letter case, as AM_IMAGES.
        .{ .file = "{\"artwork\": \"Blocks\"}\n", .want = .{ .artwork = .blocks } },
        // A bad value falls back to images, with a problem that names it.
        .{ .file = "{\"artwork\": \"kitty\"}\n", .want = .{ .artwork = .images, .problems = &.{
            "artwork in settings.json must be \"images\", \"blocks\" or \"off\", not \"kitty\": showing images",
        } } },
        .{ .file = "{\"artwork\": false}\n", .want = .{ .artwork = .images, .problems = &.{
            "artwork in settings.json must be \"images\", \"blocks\" or \"off\", not false: showing images",
        } } },
        // Entries am doesn't know (a later am's) are no problem.
        .{ .file = "{\"keepEngine\": true, \"keys\": {\"lists\": {\"help\": [\"x\"]}}, \"artwork\": \"off\", \"later\": 1.50}", .want = .{ .artwork = .off } },
        // AM_IMAGES wins over the file for the run, with every value it has.
        .{ .images = .blocks, .file = "{\"artwork\": \"off\"}", .want = .{ .artwork = .blocks, .images_set = true } },
        .{ .images = .off, .file = "{\"artwork\": \"blocks\"}", .want = .{ .artwork = .off, .images_set = true } },
        .{ .images = .auto, .file = "{\"artwork\": \"off\"}", .want = .{ .artwork = .images, .images = .auto, .images_set = true } },
        .{ .images = .kitty, .want = .{ .artwork = .images, .images = .kitty, .images_set = true } },
        .{ .images = .placeholders, .want = .{ .artwork = .images, .images = .placeholders, .images_set = true } },
        // Images then means the protocol AM_IMAGES names, also after v went to blocks (#12).
        .{ .images = .placements, .file = "{\"artwork\": \"blocks\"}", .want = .{ .artwork = .images, .images = .placements, .images_set = true } },
        // The file's bad entry is still named.
        .{ .images = .blocks, .file = "{\"artwork\": \"big\"}", .want = .{ .artwork = .blocks, .images_set = true, .problems = &.{
            "artwork in settings.json must be \"images\", \"blocks\" or \"off\", not \"big\": showing images",
        } } },
        // A file that isn't valid JSON: the defaults, and am never writes it.
        .{ .file = "{\n  \"artwork\": \"off\",\n}\n", .want = .{ .artwork = .images, .unwritable = "settings.json isn't valid JSON", .problems = &.{
            "settings.json isn't valid JSON (line 3, column 1): using the defaults and leaving the file alone",
        } } },
        .{ .file = "{\"artwork\": \"off\"", .want = .{ .unwritable = "settings.json isn't valid JSON", .problems = &.{
            "settings.json isn't valid JSON (line 1, column 18): using the defaults and leaving the file alone",
        } } },
        .{ .file = "[\"off\"]", .want = .{ .unwritable = "settings.json isn't a JSON object", .problems = &.{
            "settings.json isn't a JSON object ({ … }): using the defaults and leaving the file alone",
        } } },
        // AM_IMAGES still applies.
        .{ .images = .blocks, .file = "artwork=off\n", .want = .{ .artwork = .blocks, .images_set = true, .unwritable = "settings.json isn't valid JSON", .problems = &.{
            "settings.json isn't valid JSON (line 1, column 1): using the defaults and leaving the file alone",
        } } },
        // Nested deeper than a save could write back.
        .{ .file = "{\"x\": " ++ @as([200]u8, @splat('[')) ++ @as([200]u8, @splat(']')) ++ "}", .want = .{ .unwritable = "settings.json nests more than 128 levels deep", .problems = &.{
            "settings.json nests more than 128 levels deep: using the defaults and leaving the file alone",
        } } },
        // An empty file holds nothing to lose: it counts as `{}`.
        .{ .file = "", .want = .{} },
        .{ .file = " \n", .want = .{} },
    };
    for (cases, 0..) |case, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqualDeep(case.want, try parseTui(arena.allocator(), case.images, case.file));
    }
}

test "an artwork change lasts only for the session while AM_IMAGES is set or the file is never written" {
    try testing.expectEqual(@as(?[]const u8, null), (Tui{}).artworkSessionOnly());
    try testing.expectEqualStrings("settings.json isn't valid JSON", (Tui{ .unwritable = "settings.json isn't valid JSON" }).artworkSessionOnly().?);
    try testing.expectEqualStrings("AM_IMAGES is set", (Tui{ .images_set = true, .unwritable = "settings.json isn't valid JSON" }).artworkSessionOnly().?);
}

test "applyChange: a fresh install's first change writes only that entry, and back to its default removes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = (try applyChange(a, null, .{ .artwork = .blocks })).text;
    try testing.expectEqualStrings(
        \\{
        \\  "artwork": "blocks"
        \\}
        \\
    , blocks);
    try testing.expectEqualStrings("{}\n", (try applyChange(a, blocks, .{ .artwork = .images })).text);
    // No file, and the default: nothing to write.
    try testing.expectEqual(Applied.unchanged, try applyChange(a, null, .{ .artwork = .images }));
}

test "applyChange keeps a hand edit and the entries am doesn't know, in their order, numbers as written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // As a later am, or a hand editor, left it while this TUI was open.
    const now =
        \\{"keepEngine": true, "artwork": "off",
        \\ "keys": {"lists": {"help": ["x", "f1"], "quit": []}},
        \\ "volumeStep": 1.50, "big": 123456789012345678901234567890, "name": "Zoë"}
    ;
    try testing.expectEqualStrings(
        \\{
        \\  "keepEngine": true,
        \\  "artwork": "blocks",
        \\  "keys": {
        \\    "lists": {
        \\      "help": [
        \\        "x",
        \\        "f1"
        \\      ],
        \\      "quit": []
        \\    }
        \\  },
        \\  "volumeStep": 1.50,
        \\  "big": 123456789012345678901234567890,
        \\  "name": "Zoë"
        \\}
        \\
    , (try applyChange(a, now, .{ .artwork = .blocks })).text);
    // Back to the default: only that entry goes.
    try testing.expectEqualStrings(
        \\{
        \\  "keepEngine": true
        \\}
        \\
    , (try applyChange(a, "{\"keepEngine\": true, \"artwork\": \"off\"}", .{ .artwork = .images })).text);
    // What the file says already: nothing to write, so its own layout stays.
    try testing.expectEqual(Applied.unchanged, try applyChange(a, "{ \"artwork\" : \"off\" }", .{ .artwork = .off }));
    try testing.expectEqual(Applied.unchanged, try applyChange(a, "{\"keepEngine\": true}", .{ .artwork = .images }));
}

test "applyChange refuses a file that isn't valid JSON, or that it couldn't write back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("settings.json isn't valid JSON", (try applyChange(a, "{\"artwork\": \"off\",}", .{ .artwork = .blocks })).refused);
    try testing.expectEqualStrings("settings.json isn't valid JSON", (try applyChange(a, "artwork=off", .{ .artwork = .images })).refused);
    try testing.expectEqualStrings("settings.json isn't a JSON object", (try applyChange(a, "[]", .{ .artwork = .blocks })).refused);
    const deep = "{\"x\": " ++ @as([129]u8, @splat('[')) ++ @as([129]u8, @splat(']')) ++ "}";
    try testing.expectEqualStrings("settings.json nests more than 128 levels deep", (try applyChange(a, deep, .{ .artwork = .blocks })).refused);
    // 128 levels, the object's own included, still write back.
    const ok = "{\"x\": " ++ @as([127]u8, @splat('[')) ++ @as([127]u8, @splat(']')) ++ "}";
    try testing.expect(try applyChange(a, ok, .{ .artwork = .blocks }) == .text);
    // An empty file holds nothing to lose.
    try testing.expectEqualStrings("{\n  \"artwork\": \"off\"\n}\n", (try applyChange(a, "\n", .{ .artwork = .off })).text);
}

test "saveChange reads settings.json again and writes it whole: a hand edit since start survives, a file that isn't valid JSON is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try testing.expectEqual(Artwork.images, (try loadTui(io, a, dir, null)).artwork);
    try testing.expectEqual(Saved.saved, try saveChange(io, a, dir, .{ .artwork = .blocks }));
    try testing.expectEqualStrings("{\n  \"artwork\": \"blocks\"\n}\n", try tmp.dir.readFileAlloc(io, "settings.json", a, .limited(4096)));
    try testing.expectEqual(Artwork.blocks, (try loadTui(io, a, dir, null)).artwork);

    // Edited by hand while the TUI is open: the next save keeps the edit.
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"keepEngine\": true, \"artwork\": \"blocks\"}" });
    try testing.expectEqual(Saved.saved, try saveChange(io, a, dir, .{ .artwork = .off }));
    try testing.expectEqualStrings("{\n  \"keepEngine\": true,\n  \"artwork\": \"off\"\n}\n", try tmp.dir.readFileAlloc(io, "settings.json", a, .limited(4096)));
    try testing.expectEqual(Saved.unchanged, try saveChange(io, a, dir, .{ .artwork = .off }));

    // Broken by hand: never written over.
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"artwork\": \"off\"," });
    const tui = try loadTui(io, a, dir, null);
    try testing.expectEqualStrings("settings.json isn't valid JSON", tui.unwritable.?);
    try testing.expectEqualStrings("settings.json isn't valid JSON", (try saveChange(io, a, dir, .{ .artwork = .blocks })).refused);
    try testing.expectEqualStrings("{\"artwork\": \"off\",", try tmp.dir.readFileAlloc(io, "settings.json", a, .limited(4096)));
}

test "saveChange on a settings.json that links elsewhere (dotfiles) writes the file it points to, and the link stays" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "dotfiles");
    try tmp.dir.createDirPath(io, "am");
    try tmp.dir.writeFile(io, .{ .sub_path = "dotfiles/am.json", .data = "{\"artwork\": \"off\"}\n" });
    try tmp.dir.symLink(io, "../dotfiles/am.json", "am/settings.json", .{});

    const dir = try Io.Dir.path.join(a, &.{ root, "am" });
    try testing.expectEqual(Artwork.off, (try loadTui(io, a, dir, null)).artwork);
    try testing.expectEqual(Saved.saved, try saveChange(io, a, dir, .{ .artwork = .blocks }));
    try testing.expectEqual(Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "am/settings.json", .{ .follow_symlinks = false })).kind);
    try testing.expectEqualStrings("{\n  \"artwork\": \"blocks\"\n}\n", try tmp.dir.readFileAlloc(io, "dotfiles/am.json", a, .limited(4096)));
}

test "the daemon starts with AM_PORT, ENGINE and ENGINE_IDLE_MINUTES, or refuses over the first bad one" {
    try testing.expectEqualDeep(Checked(Start){ .ok = .{ .port = 48000, .engine = .chrome, .idle_minutes = 9 } }, (Settings{
        .port = .{ .ok = 48000 },
        .engine = .{ .ok = .chrome },
        .engine_idle_minutes = .{ .ok = 9 },
        // Neither a warning nor a bad TOKEN_URL stops it.
        .token_url = .{ .bad = "TOKEN_URL is bad" },
        .warnings = &.{"a warning"},
    }).daemonStart());
    try testing.expectEqualStrings("ENGINE is bad", (Settings{ .engine = .{ .bad = "ENGINE is bad" } }).daemonStart().bad);
    try testing.expectEqualStrings("idle is bad", (Settings{ .engine_idle_minutes = .{ .bad = "idle is bad" } }).daemonStart().bad);
    try testing.expectEqualStrings("AM_PORT is bad", (Settings{ .port = .{ .bad = "AM_PORT is bad" }, .engine = .{ .bad = "ENGINE is bad" } }).daemonStart().bad);
}

test "TOKEN_URL must be https (or http to this machine), checked on the parsed host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: Environ.Map = .init(a);
    const bad = [_][]const u8{
        "http://am-token.example.workers.dev/token",
        "ftp://x",
        "https://",
        "am-token.example.workers.dev",
        // User info before a remote host: the prefix looks local, the host isn't.
        "http://localhost:@evil.example/token",
        "http://127.0.0.1:8787@evil.example/token",
        "https://user:pass@am-token.example.workers.dev/token",
        "http://localhost.evil.example/token",
        "http://%6cocalhost/token",
    };
    for (bad) |url| {
        errdefer std.debug.print("{s}\n", .{url});
        const s = try parse(a, &environ, try a.print("TOKEN_URL={s}\n", .{url}));
        try testing.expectEqualStrings(try a.print("TOKEN_URL must be an https:// URL (or http://localhost:<port> or http://127.0.0.1:<port>), not {s}", .{url}), s.token_url.bad);
    }
    for ([_][]const u8{ "http://localhost:8787/token", "http://127.0.0.1:8787/token", "https://am-token.example.workers.dev/token" }) |url| {
        try testing.expectEqualStrings(url, (try parse(a, &environ, try a.print("TOKEN_URL={s}\n", .{url}))).token_url.ok.?);
    }
}

test "the developer token's ids: TEAM_ID and KEY_ID, both or none" {
    try testing.expectEqual(null, (Settings{ .team_id = "T" }).ids());
    try testing.expectEqual(null, (Settings{ .key_id = "K" }).ids());
    const both = (Settings{ .team_id = "T", .key_id = "K" }).ids().?;
    try testing.expectEqualStrings("T", both.team_id);
    try testing.expectEqualStrings("K", both.key_id);
}

test "the env file is NAME=value lines, with optional quotes and export, and ~ expanded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\# comment
        \\TEAM_ID=TEAM123456
        \\  KEY_ID = "KEY1234567"
        \\FIREFOX_PATH='~/bin/firefox'
        \\CHROME_PATH=~
        \\NOT_HOME=a~b
        \\export ENGINE=chrome
        \\EXPORTED=1
        \\lowercase=ignored
        \\garbage line
        \\export
        \\=no name
        \\EMPTY=
        \\MISMATCHED="quote'
        \\
    ++ "export\tAM_IMAGES=off\n" ++ "WINDOWS=crlf\r\n";
    const file = try parseEnvFile(arena.allocator(), text, "/home/u");
    const map = file.map;
    try testing.expectEqualStrings("TEAM123456", map.get("TEAM_ID").?);
    try testing.expectEqualStrings("KEY1234567", map.get("KEY_ID").?);
    try testing.expectEqualStrings("/home/u/bin/firefox", map.get("FIREFOX_PATH").?);
    try testing.expectEqualStrings("/home/u", map.get("CHROME_PATH").?);
    try testing.expectEqualStrings("a~b", map.get("NOT_HOME").?);
    try testing.expectEqualStrings("chrome", map.get("ENGINE").?);
    try testing.expectEqualStrings("off", map.get("AM_IMAGES").?);
    try testing.expectEqualStrings("1", map.get("EXPORTED").?);
    try testing.expectEqualStrings("", map.get("EMPTY").?);
    try testing.expectEqualStrings("\"quote'", map.get("MISMATCHED").?);
    try testing.expectEqualStrings("crlf", map.get("WINDOWS").?);
    try testing.expectEqual(null, map.get("lowercase"));
    try testing.expectEqual(@as(usize, 11), map.count());
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "lowercase=ignored", "garbage line", "export", "=no name" }), file.bad_lines);
}
