//! What the `am` commands share: the context they run in and how they report failure.
const std = @import("std");
const apple = @import("apple.zig");
const config = @import("config.zig");
const daemon_client = @import("daemon/client.zig");
const developer_token = @import("developer_token.zig");
const platform = @import("platform.zig");
const settings_mod = @import("settings.zig");
const token_source = @import("token_source.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

pub const token = @import("commands/token.zig");
pub const search = @import("commands/search.zig");
pub const remote = @import("commands/remote.zig");
pub const daemon_command = @import("commands/daemon.zig");
pub const playback = @import("commands/playback.zig");
pub const tui = @import("commands/tui.zig");

/// A command printed why it failed; exit 1.
pub const Failed = error{Reported};

pub const Context = struct {
    io: Io,
    /// Lives as long as the command; nothing is freed before exit.
    arena: Allocator,
    out: *Io.Writer,
    err: *Io.Writer,
    environ: *const Environ.Map,
    config_dir: []const u8,
    /// Read once per command.
    settings: settings_mod.Settings,
    apple_transport: apple.Transport,

    pub const InitError = Failed || Allocator.Error || Io.Dir.ReadFileAllocError;

    pub fn init(io: Io, arena: Allocator, environ: *const Environ.Map, out: *Io.Writer, err: *Io.Writer, apple_transport: apple.Transport) InitError!Context {
        var ctx: Context = .{
            .io = io,
            .arena = arena,
            .out = out,
            .err = err,
            .environ = environ,
            .config_dir = undefined,
            .settings = undefined,
            .apple_transport = apple_transport,
        };
        ctx.config_dir = platform.configDir(arena, environ) catch |e| return switch (e) {
            error.NoHomeDir, error.Unsupported => ctx.fail("{s}", .{platform.describeConfigDirError(e)}),
            error.OutOfMemory => error.OutOfMemory,
        };
        ctx.settings = try settings_mod.load(io, arena, ctx.config_dir, environ);
        return ctx;
    }

    /// Prints `error: <message>` and returns the error that makes `am` exit 1.
    pub fn fail(ctx: *const Context, comptime fmt: []const u8, args: anytype) Failed {
        ctx.err.print("error: " ++ fmt ++ "\n", args) catch {};
        return error.Reported;
    }

    pub fn now(ctx: *const Context) i64 {
        return Io.Clock.real.now(ctx.io).toSeconds();
    }

    pub fn configPath(ctx: *const Context, name: []const u8) Allocator.Error![]const u8 {
        return Io.Dir.path.join(ctx.arena, &.{ ctx.config_dir, name });
    }

    /// The file's contents, or null when it doesn't exist.
    pub fn readConfigFile(ctx: *const Context, name: []const u8) config.ReadFileError!?[]u8 {
        return config.readFile(ctx.io, ctx.arena, ctx.config_dir, name);
    }

    /// TEAM_ID and KEY_ID, from the environment or the env file.
    pub fn ids(ctx: *const Context) (Failed || Allocator.Error)!developer_token.Ids {
        const team_id = ctx.settings.team_id;
        const key_id = ctx.settings.key_id;
        if (team_id == null or key_id == null) {
            const team_line = "TEAM_ID=<your Apple Developer Team ID>";
            const key_line = "KEY_ID=<the ID of your MusicKit key>";
            const which, const lines, const pronoun = if (team_id == null and key_id == null)
                .{ "TEAM_ID and KEY_ID", team_line ++ " and " ++ key_line, "them" }
            else if (team_id == null) .{ "TEAM_ID", team_line, "it" } else .{ "KEY_ID", key_line, "it" };
            return ctx.fail("{s} missing: put {s} in {s}, or set {s} in the environment", .{
                which, lines, try ctx.configPath(config.file.env), pronoun,
            });
        }
        return .{ .team_id = team_id.?, .key_id = key_id.? };
    }

    pub const TokenError = Failed || token_source.GetError;

    fn tokenEnv(ctx: *const Context) token_source.Env {
        return .fromSettings(ctx.io, ctx.config_dir, &ctx.settings, ctx.apple_transport, ctx.now());
    }

    /// The developer token to use: the user's own, else the shared one (`token_source.zig`),
    /// downloaded through `apple_transport` when it is due.
    pub fn developerTokenSource(ctx: *const Context) TokenError!token_source.Result {
        return token_source.get(ctx.arena, ctx.tokenEnv());
    }

    /// For `apple.Client.renew`: a newer shared token after Apple refused one.
    pub fn tokenRenewer(ctx: *const Context) token_source.Renewer {
        return .{ .env = ctx.tokenEnv(), .arena = ctx.arena };
    }

    /// The developer token to use, or a failure saying why there is none.
    pub fn developerToken(ctx: *const Context) TokenError![]const u8 {
        return switch (try ctx.developerTokenSource()) {
            .found => |f| f.token,
            .problem => |p| ctx.fail("{s}", .{p.text}),
        };
    }

    pub const ConnectOptions = struct {
        /// Start `am daemon` when nothing answers.
        start: bool = true,
    };

    /// The background process's port: `AM_PORT`, else 47823.
    pub fn daemonPort(ctx: *const Context) Failed!u16 {
        return switch (ctx.settings.port) {
            .ok => |port| port,
            .bad => |why| ctx.fail("{s}", .{why}),
        };
    }

    /// The stored Music User Token, if there is a usable one.
    pub fn userToken(ctx: *const Context) (Allocator.Error || Io.Dir.ReadFileAllocError)!?[]const u8 {
        return config.storedToken(try ctx.readConfigFile(config.file.music_user_token));
    }
};

/// A client for the background process, started if needed. `error.NotRunning` only when
/// `start` is false.
pub fn connectDaemon(ctx: *const Context, gpa: Allocator, options: Context.ConnectOptions) (Failed || error{NotRunning} || Allocator.Error || Io.Cancelable)!daemon_client.Client {
    return daemon_client.connect(.{
        .io = ctx.io,
        .gpa = gpa,
        .arena = ctx.arena,
        .config_dir = ctx.config_dir,
        .port = try ctx.daemonPort(),
        .start = options.start,
        .err = ctx.err,
    }) catch |e| switch (e) {
        error.Reported => error.Reported,
        error.NotRunning => error.NotRunning,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
    };
}

test {
    _ = token;
    _ = search;
    _ = playback;
}
