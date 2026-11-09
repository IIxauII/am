//! `am`: play Apple Music from the terminal. This file only wires arguments to commands.
const std = @import("std");
const apple = @import("apple.zig");
/// From `build.zig`: `version` is `build.zig.zon`'s.
const build_options = @import("build_options");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const term = @import("tui/term.zig");

const Io = std.Io;

/// A panic while the TUI runs puts the terminal back before printing.
pub const panic = std.debug.FullPanic(term.panicHandler);

/// So does a segfault (std calls `root.debug.handleSegfault`).
pub const debug = struct {
    pub const handleSegfault = term.segfaultHandler;
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buffer);
    var err_buffer: [1024]u8 = undefined;
    var err = Io.File.stderr().writerStreaming(io, &err_buffer);

    const code = run(init, &out.interface, &err.interface);
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    std.process.exit(code);
}

fn run(init: std.process.Init, out: *Io.Writer, err: *Io.Writer) u8 {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return 1;
    const command = cli.parse(arena, argv[1..]) catch return 1;
    switch (command) {
        .help => {
            out.writeAll(cli.usage) catch {};
            return 0;
        },
        .version => {
            out.writeAll("am " ++ build_options.version ++ "\n") catch {};
            return 0;
        },
        .tui => |t| {
            if (!t.explicit and !term.isTty(init.io)) {
                out.writeAll(cli.usage) catch {};
                return 0;
            }
            return runCommand(init, out, err, commands.tui.run, .{init.gpa});
        },
        .usage_error => |message| {
            err.print("error: {s}\n\n{s}", .{ message, cli.usage }) catch {};
            return 2;
        },
        .token => |t| return runCommand(init, out, err, commands.token.run, .{t.key_stdin}),
        .search => |s| return runCommand(init, out, err, commands.search.run, .{s.term}),
        .signin => |s| return runCommand(init, out, err, commands.playback.signin, .{ init.gpa, s.engine, s.open }),
        .play => |p| return runCommand(init, out, err, commands.playback.play, .{ init.gpa, p.target, p.mode }),
        .pause => return runCommand(init, out, err, commands.playback.control, .{ init.gpa, .pause }),
        .@"resume" => return runCommand(init, out, err, commands.playback.control, .{ init.gpa, .@"resume" }),
        .stop => return runCommand(init, out, err, commands.playback.control, .{ init.gpa, .stop }),
        .status => return runCommand(init, out, err, commands.playback.status, .{init.gpa}),
        .doctor => return runCommand(init, out, err, commands.remote.run, .{ init.gpa, "doctor", "{}" }),
        .daemon => |d| return runCommand(init, out, err, commands.daemon_command.run, .{ init.gpa, d.detach }),
        .daemon_stop => return runCommand(init, out, err, commands.daemon_command.stop, .{init.gpa}),
    }
}

/// Runs `command(&ctx, args...)` and turns its result into the exit code.
fn runCommand(init: std.process.Init, out: *Io.Writer, err: *Io.Writer, command: anytype, args: anytype) u8 {
    var http: apple.HttpTransport = .{ .io = init.io, .gpa = init.gpa };
    const result = result: {
        const ctx = commands.Context.init(init.io, init.arena.allocator(), init.environ_map, out, err, http.transport()) catch |e| break :result e;
        break :result @call(.auto, command, .{&ctx} ++ args);
    };
    result catch |e| {
        if (e != error.Reported) err.print("error: {t}\n", .{e}) catch {};
        return 1;
    };
    return 0;
}

test {
    _ = @import("pkcs8.zig");
    _ = @import("developer_token.zig");
    _ = @import("token_source.zig");
    _ = @import("config.zig");
    _ = @import("settings.zig");
    _ = @import("platform.zig");
    _ = @import("apple.zig");
    _ = @import("cli.zig");
    _ = commands;
    _ = @import("daemon/guard.zig");
    _ = @import("daemon/channel.zig");
    _ = @import("engine.zig");
    _ = @import("daemon/server.zig");
    _ = @import("daemon.zig");
    _ = @import("deadline.zig");
    _ = @import("playback.zig");
    _ = @import("footprint.zig");
    _ = @import("music/parse.zig");
    _ = @import("music/api.zig");
    _ = @import("tui/width.zig");
    _ = @import("tui/input.zig");
    _ = @import("tui/screen.zig");
    _ = @import("tui/term.zig");
    _ = @import("tui/png.zig");
    _ = @import("tui/graphics.zig");
    _ = @import("tui/artwork.zig");
    _ = @import("tui/keys.zig");
    _ = @import("tui/layout.zig");
    _ = @import("tui/list.zig");
    _ = @import("tui/playstate.zig");
    _ = @import("tui/auth.zig");
    _ = @import("tui/jobs.zig");
    _ = @import("tui/ui.zig");
    _ = @import("tui/views.zig");
    _ = @import("tui/app.zig");
}
