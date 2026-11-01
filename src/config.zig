//! Settings from `<config dir>/env` and the environment, and the names of the files the config
//! directory holds. Where the directory is comes from the platform layer.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

pub const ReadFileError = Allocator.Error || Io.Dir.ReadFileAllocError;

/// A file in the config dir (`file.*`, at most 1 MiB), or null when it doesn't exist.
pub fn readFile(io: Io, arena: Allocator, config_dir: []const u8, name: []const u8) ReadFileError!?[]u8 {
    const path = try Io.Dir.path.join(arena, &.{ config_dir, name });
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => |other| other,
    };
}

/// File names inside the config directory.
pub const file = struct {
    pub const env = "env";
    /// Secret: written mode 600.
    pub const developer_token = "developer-token.jwt";
    /// The shared developer token, downloaded from `TOKEN_URL` (`token_source.zig`). Mode 600.
    pub const shared_developer_token = "shared-developer-token.jwt";
    /// Secret: written mode 600.
    pub const music_user_token = "music-user-token";
};

/// Drops spaces, tabs and line breaks around `s`.
pub fn trimSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// An environment variable; an empty one counts as unset.
pub fn getEnv(environ: *const Environ.Map, key: []const u8) ?[]const u8 {
    const value = environ.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

/// A stored token (developer token, Music User Token) from its file's contents: surrounding
/// whitespace is dropped. Empty, or holding any character a token never has (CR/LF, spaces,
/// quotes, non-ASCII), counts as no token, so a damaged file never reaches an HTTP header.
pub fn storedToken(contents: ?[]const u8) ?[]const u8 {
    const token = trimSpace(contents orelse return null);
    if (token.len == 0) return null;
    for (token) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "-._~+/=", c) != null)) return null;
    return token;
}

/// Settings lookup: a real environment variable wins over the env file.
pub const Settings = struct {
    environ: *const Environ.Map,
    file: Environ.Map,

    pub fn get(s: *const Settings, key: []const u8) ?[]const u8 {
        return getEnv(s.environ, key) orelse s.file.get(key);
    }
};

/// Parses env-file text. `home` expands a leading `~`. Allocates into `arena`.
pub fn parseEnvFile(arena: Allocator, text: []const u8, home: ?[]const u8) !Environ.Map {
    var map: Environ.Map = .init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = trimSpace(line[0..eq]);
        if (!isKey(key)) continue;
        try map.put(key, try expandHome(arena, unquote(trimSpace(line[eq + 1 ..])), home));
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

test "a real environment variable wins over the env file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: Environ.Map = .init(arena.allocator());
    try environ.put("KEY_ID", "FROMENV000");
    try environ.put("TEAM_ID", "");
    const settings: Settings = .{
        .environ = &environ,
        .file = try parseEnvFile(arena.allocator(), "KEY_ID=FROMFILE00\nTEAM_ID=TEAM123456\n", null),
    };
    try testing.expectEqualStrings("FROMENV000", settings.get("KEY_ID").?);
    // An empty variable counts as unset.
    try testing.expectEqualStrings("TEAM123456", settings.get("TEAM_ID").?);
    try testing.expectEqual(null, settings.get("ENGINE"));
}

test "a stored token is its file without surrounding whitespace" {
    try testing.expectEqualStrings("eyJh.eyJp.c2ln", storedToken("eyJh.eyJp.c2ln\n").?);
    try testing.expectEqualStrings("Am+x/Y_z-9~=", storedToken("  Am+x/Y_z-9~=\r\n").?);
}

test "a stored token that is empty or holds characters no token has counts as none" {
    try testing.expectEqual(null, storedToken(null));
    try testing.expectEqual(null, storedToken(""));
    try testing.expectEqual(null, storedToken(" \n"));
    // CR/LF inside would make an invalid HTTP header (std.http asserts on it).
    try testing.expectEqual(null, storedToken("abc\r\nX-Injected: 1"));
    try testing.expectEqual(null, storedToken("abc\ndef"));
    try testing.expectEqual(null, storedToken("abc def"));
    try testing.expectEqual(null, storedToken("abc\"def"));
    try testing.expectEqual(null, storedToken("abc\x00def"));
    try testing.expectEqual(null, storedToken("abcü"));
}
