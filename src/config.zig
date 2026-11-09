//! The files the config directory holds: their names, reading them, and the stored tokens.
//! Where the directory is comes from the platform layer; the settings (the env file and the
//! environment) come from `settings.zig`.
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

const testing = std.testing;

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
