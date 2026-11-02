//! Turns `am`'s arguments into a command.
const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");
const playback = @import("playback.zig");

const Allocator = std.mem.Allocator;

pub const usage =
    \\usage: am [command]
    \\  (none), tui         the full-screen player: browse, search, play, favorites (needs a
    \\                      terminal; signs in to Apple Music when needed)
    \\  token --key-stdin   sign the developer token from the .p8 on stdin, store it, test it
    \\  token               report the developer token in use (yours, else the shared one) and
    \\                      test it against Apple
    \\  search <term>       catalog search over the REST API
    \\  signin [--engine E] [--no-open]
    \\                      one-time Apple ID sign-in in your normal browser (--engine E: in a
    \\                      window of the firefox or chrome engine profile; --no-open: print the
    \\                      address instead of opening it)
    \\  play [id|term] [--seconds N | --full]
    \\                      play a song (default 1561837008) and return once it plays; with
    \\                      --seconds N or --full, watch it and verify it's the full track
    \\  pause, resume       pause or continue what the engine is playing
    \\  stop                stop playback (the engine stays warm until its idle timeout, then
    \\                      the background process exits too unless a TUI is open)
    \\  status              what's playing, the engine, and what both processes cost
    \\  doctor              start the engine, report DRM, MusicKit and sign-in status
    \\  daemon              run the background process in the foreground (the CLI starts it as needed)
    \\  daemon stop         stop the background process and its engine
    \\  version, --version  print am's version
    \\
;

pub const Command = union(enum) {
    help,
    version,
    /// The full-screen player. Not `explicit` (no arguments): only on a terminal, else the usage.
    tui: struct { explicit: bool },
    token: struct { key_stdin: bool },
    search: struct { term: []const u8 },
    signin: struct {
        /// Sign in through a window of this engine's profile instead of the normal browser.
        engine: ?engine.Kind,
        /// Open the address in the normal browser (else just print it).
        open: bool,
    },
    play: struct {
        /// A catalog song id, or a search term (its first hit plays).
        target: []const u8,
        mode: playback.Mode,
    },
    pause,
    @"resume",
    stop,
    status,
    doctor,
    /// `--detach`: leave the terminal's session (what the CLI's auto-start passes).
    daemon: struct { detach: bool },
    daemon_stop,
    /// Holds what is wrong; print it with the usage and exit 2.
    usage_error: []const u8,
};

/// `args` excludes the program name. Allocates into `arena`.
pub fn parse(arena: Allocator, args: []const []const u8) Allocator.Error!Command {
    if (args.len == 0) return .{ .tui = .{ .explicit = false } };
    const name = args[0];
    const rest = args[1..];
    if (eql(name, "help") or eql(name, "-h") or eql(name, "--help")) return .help;
    if (eql(name, "tui")) {
        if (rest.len > 0) return .{ .usage_error = try arena.print("tui: unknown argument {s}", .{rest[0]}) };
        return .{ .tui = .{ .explicit = true } };
    }

    if (eql(name, "token")) {
        var key_stdin = false;
        for (rest) |arg| {
            if (!eql(arg, "--key-stdin")) return .{ .usage_error = try arena.print("token: unknown argument {s}", .{arg}) };
            key_stdin = true;
        }
        return .{ .token = .{ .key_stdin = key_stdin } };
    }

    if (eql(name, "search")) {
        const term = config.trimSpace(try std.mem.join(arena, " ", rest));
        if (term.len == 0) return .{ .usage_error = "search needs a term" };
        return .{ .search = .{ .term = term } };
    }

    if (eql(name, "signin")) {
        var kind: ?engine.Kind = null;
        var open = true;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const arg = rest[i];
            if (eql(arg, "--no-open")) {
                open = false;
            } else if (eql(arg, "--engine")) {
                i += 1;
                if (i == rest.len) return .{ .usage_error = "signin: --engine needs firefox or chrome" };
                kind = std.meta.stringToEnum(engine.Kind, rest[i]) orelse
                    return .{ .usage_error = try arena.print("signin: --engine must be firefox or chrome, not {s}", .{rest[i]}) };
            } else return .{ .usage_error = try arena.print("signin: unknown argument {s}", .{arg}) };
        }
        if (kind != null and !open) return .{ .usage_error = "signin: --no-open is for the normal browser, not --engine" };
        return .{ .signin = .{ .engine = kind, .open = open } };
    }

    if (eql(name, "play")) {
        var mode: playback.Mode = .until_playing;
        var words: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const arg = rest[i];
            if (eql(arg, "--full") or eql(arg, "--seconds")) {
                if (mode != .until_playing) return .{ .usage_error = "play: give --seconds N or --full, not both" };
                if (eql(arg, "--full")) {
                    mode = .full;
                    continue;
                }
                i += 1;
                const n = if (i < rest.len) std.fmt.parseInt(u32, rest[i], 10) catch 0 else 0;
                if (n == 0) return .{ .usage_error = "play: --seconds needs a whole number of seconds (1 or more)" };
                mode = .{ .seconds = n };
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return .{ .usage_error = try arena.print("play: unknown argument {s}", .{arg}) };
            } else try words.append(arena, arg);
        }
        const target = config.trimSpace(try std.mem.join(arena, " ", words.items));
        return .{ .play = .{ .target = if (target.len == 0) default_song else target, .mode = mode } };
    }

    inline for (.{ "pause", "resume", "stop", "status" }) |simple| if (eql(name, simple)) {
        if (rest.len > 0) return .{ .usage_error = try arena.print(simple ++ ": unknown argument {s}", .{rest[0]}) };
        return @field(Command, simple);
    };

    if (eql(name, "version") or eql(name, "--version")) {
        if (rest.len > 0) return .{ .usage_error = try arena.print("version: unknown argument {s}", .{rest[0]}) };
        return .version;
    }

    if (eql(name, "doctor")) {
        if (rest.len > 0) return .{ .usage_error = try arena.print("doctor: unknown argument {s}", .{rest[0]}) };
        return .doctor;
    }

    if (eql(name, "daemon")) {
        if (rest.len == 0) return .{ .daemon = .{ .detach = false } };
        if (rest.len == 1 and eql(rest[0], "stop")) return .daemon_stop;
        if (rest.len == 1 and eql(rest[0], "--detach")) return .{ .daemon = .{ .detach = true } };
        return .{ .usage_error = try arena.print("daemon: unknown argument {s}", .{rest[0]}) };
    }

    return .{ .usage_error = try arena.print("unknown command: {s}", .{name}) };
}

/// Shy Away (2:55), in the US catalog: long enough to tell a full track from a preview.
pub const default_song = "1561837008";

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

fn expectParse(expected: Command, args: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualDeep(expected, try parse(arena.allocator(), args));
}

test "help, -h and --help ask for the usage; no command or tui opens the player" {
    try expectParse(.{ .tui = .{ .explicit = false } }, &.{});
    try expectParse(.{ .tui = .{ .explicit = true } }, &.{"tui"});
    try expectParse(.{ .usage_error = "tui: unknown argument --x" }, &.{ "tui", "--x" });
    try expectParse(.help, &.{"help"});
    try expectParse(.help, &.{"-h"});
    try expectParse(.help, &.{"--help"});
}

test "--version and version ask for the version, and take no arguments" {
    try expectParse(.version, &.{"--version"});
    try expectParse(.version, &.{"version"});
    try expectParse(.{ .usage_error = "version: unknown argument --json" }, &.{ "version", "--json" });
}

test "token takes --key-stdin and nothing else" {
    try expectParse(.{ .token = .{ .key_stdin = false } }, &.{"token"});
    try expectParse(.{ .token = .{ .key_stdin = true } }, &.{ "token", "--key-stdin" });
    try expectParse(.{ .usage_error = "token: unknown argument --key" }, &.{ "token", "--key" });
}

test "search joins its arguments into one term" {
    try expectParse(.{ .search = .{ .term = "shy away" } }, &.{ "search", "shy", "away" });
    try expectParse(.{ .search = .{ .term = "-shy" } }, &.{ "search", "-shy" });
    try expectParse(.{ .usage_error = "search needs a term" }, &.{"search"});
    try expectParse(.{ .usage_error = "search needs a term" }, &.{ "search", " " });
}

test "doctor takes no arguments" {
    try expectParse(.doctor, &.{"doctor"});
    try expectParse(.{ .usage_error = "doctor: unknown argument -v" }, &.{ "doctor", "-v" });
}

test "daemon runs the background process; daemon stop stops it" {
    try expectParse(.{ .daemon = .{ .detach = false } }, &.{"daemon"});
    try expectParse(.{ .daemon = .{ .detach = true } }, &.{ "daemon", "--detach" });
    try expectParse(.daemon_stop, &.{ "daemon", "stop" });
    try expectParse(.{ .usage_error = "daemon: unknown argument start" }, &.{ "daemon", "start" });
    try expectParse(.{ .usage_error = "daemon: unknown argument stop" }, &.{ "daemon", "stop", "now" });
}

test "signin opens the normal browser, or a window of an engine profile" {
    try expectParse(.{ .signin = .{ .engine = null, .open = true } }, &.{"signin"});
    try expectParse(.{ .signin = .{ .engine = null, .open = false } }, &.{ "signin", "--no-open" });
    try expectParse(.{ .signin = .{ .engine = .chrome, .open = true } }, &.{ "signin", "--engine", "chrome" });
    try expectParse(.{ .usage_error = "signin: --engine must be firefox or chrome, not safari" }, &.{ "signin", "--engine", "safari" });
    try expectParse(.{ .usage_error = "signin: --engine needs firefox or chrome" }, &.{ "signin", "--engine" });
    try expectParse(.{ .usage_error = "signin: --no-open is for the normal browser, not --engine" }, &.{ "signin", "--engine", "firefox", "--no-open" });
    try expectParse(.{ .usage_error = "signin: unknown argument now" }, &.{ "signin", "now" });
}

test "play takes an id or a search term, and --seconds N or --full" {
    try expectParse(.{ .play = .{ .target = "1561837008", .mode = .until_playing } }, &.{"play"});
    try expectParse(.{ .play = .{ .target = "42", .mode = .until_playing } }, &.{ "play", "42" });
    try expectParse(.{ .play = .{ .target = "shy away", .mode = .{ .seconds = 20 } } }, &.{ "play", "shy", "--seconds", "20", "away" });
    try expectParse(.{ .play = .{ .target = "1561837008", .mode = .full } }, &.{ "play", "--full" });
    try expectParse(.{ .usage_error = "play: give --seconds N or --full, not both" }, &.{ "play", "--full", "--seconds", "5" });
    try expectParse(.{ .usage_error = "play: --seconds needs a whole number of seconds (1 or more)" }, &.{ "play", "--seconds" });
    try expectParse(.{ .usage_error = "play: --seconds needs a whole number of seconds (1 or more)" }, &.{ "play", "--seconds", "0" });
    try expectParse(.{ .usage_error = "play: --seconds needs a whole number of seconds (1 or more)" }, &.{ "play", "--seconds", "1.5" });
    try expectParse(.{ .usage_error = "play: unknown argument --loud" }, &.{ "play", "--loud" });
}

test "pause, resume, stop and status take no arguments" {
    try expectParse(.pause, &.{"pause"});
    try expectParse(.@"resume", &.{"resume"});
    try expectParse(.stop, &.{"stop"});
    try expectParse(.status, &.{"status"});
    try expectParse(.{ .usage_error = "stop: unknown argument now" }, &.{ "stop", "now" });
}

test "an unknown command is a usage error" {
    try expectParse(.{ .usage_error = "unknown command: shuffle" }, &.{"shuffle"});
}
