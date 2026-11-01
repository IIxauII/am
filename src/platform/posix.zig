//! The platform interface on Linux and macOS. See `../platform.zig` for the contract.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const platform = @import("../platform.zig");
const Deadline = @import("../deadline.zig").Deadline;

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;
const posix = std.posix;

pub fn configDir(gpa: Allocator, environ: *const Environ.Map) platform.ConfigDirError![]u8 {
    if (config.getEnv(environ, "AM_CONFIG_DIR")) |dir| return gpa.dupe(u8, dir);
    if (config.getEnv(environ, "XDG_CONFIG_HOME")) |xdg| if (Io.Dir.path.isAbsolute(xdg)) return Io.Dir.path.join(gpa, &.{ xdg, "am" });
    const home = homeDir(environ) orelse return error.NoHomeDir;
    return Io.Dir.path.join(gpa, &.{ home, ".config", "am" });
}

pub fn homeDir(environ: *const Environ.Map) ?[]const u8 {
    return config.getEnv(environ, "HOME");
}

pub fn describeConfigDirError(err: platform.ConfigDirError) []const u8 {
    return switch (err) {
        error.NoHomeDir => "HOME is not set, so there is no config directory: set AM_CONFIG_DIR",
        error.Unsupported => "not supported on this OS yet",
        error.OutOfMemory => "out of memory",
    };
}

pub fn writePrivateFile(io: Io, dir_path: []const u8, name: []const u8, data: []const u8) platform.WritePrivateFileError!void {
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .permissions = .fromMode(0o700) });
    defer dir.close(io);
    // A directory that existed already keeps its mode, so tighten one that others can enter.
    if ((try dir.stat(io)).permissions.toMode() & 0o077 != 0)
        try Io.Dir.cwd().setFilePermissions(io, dir_path, .fromMode(0o700), .{});
    // A fresh file is created 600 and renamed over the old one, so an existing file with a wider
    // mode never holds the new secret.
    var file = try dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600), .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.replace(io);
}

pub fn createPrivateDir(io: Io, path: []const u8) platform.CreatePrivateDirError!void {
    var dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700) });
    dir.close(io);
}

pub fn createPrivateFile(io: Io, path: []const u8) platform.CreatePrivateFileError!Io.File {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    // The mode applies only to a new file; an existing one may be wider.
    try file.setPermissions(io, .fromMode(0o600));
    return file;
}

// ---- The background process's server ----

/// Binds a listening TCP socket. Like `IpAddress.listen`, but with SO_REUSEADDR alone: it lets
/// a restarted daemon bind while connections of the old one linger in TIME_WAIT, yet a second
/// listener still gets `AddressInUse`. (std's `reuse_address` adds SO_REUSEPORT, which would let
/// two daemons share the port and break the bind-is-the-lock rule.)
pub fn listenLoopback(io: Io, address: Io.net.IpAddress) platform.ListenError!Io.net.Server {
    _ = io;
    const family = Io.Threaded.posixAddressFamily(&address);
    // macOS has no SOCK_CLOEXEC: set FD_CLOEXEC afterwards (no other thread spawns meanwhile).
    const cloexec_flag = if (Io.Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(family, posix.SOCK.STREAM | cloexec_flag, 0);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        else => return error.Unexpected,
    }
    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = posix.system.close(fd);
    if (cloexec_flag == 0 and posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS)
        return error.Unexpected;

    const one: c_int = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch return error.Unexpected;
    var storage: Io.Threaded.PosixAddress = undefined;
    const len = Io.Threaded.addressToPosix(&address, &storage);
    switch (posix.errno(posix.system.bind(fd, &storage.any, len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ACCES => return error.AccessDenied,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        else => return error.Unexpected,
    }
    switch (posix.errno(posix.system.listen(fd, 128))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.Unexpected,
    }
    // The bound address, with the port the kernel picked for port 0.
    var bound_len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(fd, &storage.any, &bound_len)) != .SUCCESS) return error.Unexpected;
    return .{ .socket = .{ .handle = fd, .address = Io.Threaded.addressFromPosix(&storage) }, .options = {} };
}

// ---- Engine processes ----

/// A process and everything it started, as one process group led by the first process.
pub const ProcessGroup = struct {
    pgid: posix.pid_t,
    leader_reaped: bool = false,

    /// The first process's id.
    pub fn leader(g: *const ProcessGroup) posix.pid_t {
        return g.pgid;
    }

    /// Whether any process of the group is still running. Firefox can fork and exit, so the
    /// leader may be gone while the group lives on.
    pub fn alive(g: *ProcessGroup) bool {
        g.reapLeader();
        return groupAlive(g.pgid);
    }

    /// SIGTERM to the whole group, up to 5 s to exit, then SIGKILL and up to 2 s more.
    pub fn kill(g: *ProcessGroup, io: Io) void {
        g.reapLeader();
        terminate(io, -g.pgid, g);
    }

    /// A dead leader stays a zombie member of its group until reaped, and would keep the group
    /// "alive" for `kill(-pgid, 0)`.
    fn reapLeader(g: *ProcessGroup) void {
        if (g.leader_reaped) return;
        var status: if (builtin.link_libc) c_int else i32 = 0;
        const rc = posix.system.waitpid(g.pgid, &status, posix.W.NOHANG);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc != 0) {
                g.leader_reaped = true;
            },
            .CHILD => g.leader_reaped = true,
            else => {},
        }
    }
};

pub const ProcessId = posix.pid_t;

pub fn currentPid() ProcessId {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

pub const browsers: platform.Browsers = switch (builtin.os.tag) {
    .macos => .{
        .firefox = .{ .candidates = &.{.{ .path = "/Applications/Firefox.app/Contents/MacOS/firefox" }}, .exe_names = &.{"firefox"} },
        .chrome = .{
            .candidates = &.{.{ .path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }},
            .exe_names = &.{"Google Chrome"},
            // Keeps Chrome from asking the user's login keychain for its "Safe Storage" key.
            .extra_args = &.{"--use-mock-keychain"},
        },
    },
    else => .{
        // `firefox` on PATH is often a wrapper script for /usr/lib*/firefox*/firefox.
        .firefox = .{ .candidates = &.{ .{ .path = "firefox-esr" }, .{ .path = "firefox" } }, .exe_names = &.{ "firefox-esr", "firefox", "firefox-bin" } },
        // The real binary, not the /usr/bin/google-chrome wrapper script.
        .chrome = .{ .candidates = &.{.{ .path = "/opt/google/chrome/chrome" }}, .exe_names = &.{"chrome"} },
    },
};

/// Starts `argv` as the leader of a new process group.
pub fn spawnGroup(io: Io, options: platform.SpawnGroupOptions) platform.SpawnError!ProcessGroup {
    const out: std.process.SpawnOptions.StdIo = if (options.output) |file| .{ .file = file } else .ignore;
    const child = try std.process.spawn(io, .{
        .argv = options.argv,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = out,
        .stderr = out,
        .pgid = 0,
    });
    return .{ .pgid = child.id.? };
}

/// Ends a leftover engine from an earlier run, the same way `ProcessGroup.kill` does.
pub fn killLeftover(io: Io, leftover: KillTarget) void {
    switch (leftover) {
        .group => |pgid| terminate(io, -pgid, null),
        .process => |pid| terminate(io, pid, null),
    }
}

/// SIGTERM, up to 5 s to exit, then SIGKILL and up to 2 s more. `target` is a pid, or minus a
/// process group id for the whole group.
fn terminate(io: Io, target: posix.pid_t, own: ?*ProcessGroup) void {
    // Cancellation (the daemon shutting down) must not skip the SIGKILL.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const steps = [_]struct { posix.SIG, i64 }{ .{ .TERM, 5000 }, .{ .KILL, 2000 } };
    for (steps) |step| {
        if (!mayStillSignal(target, own)) return;
        posix.kill(target, step[0]) catch {};
        const deadline: Deadline = .after(io, .fromMilliseconds(step[1]));
        while (deadline.sleep(.fromMilliseconds(50)) catch unreachable) {
            if (!mayStillSignal(target, own)) return;
        }
    }
}

/// Never signal a group that has emptied out once its leader is reaped (or a process that is
/// gone): its id is free again and may by now belong to something we didn't start.
fn mayStillSignal(target: posix.pid_t, own: ?*ProcessGroup) bool {
    if (own) |g| g.reapLeader();
    return exists(target);
}

/// `kill(target, 0)` succeeds while the process (or any process of the group) exists; EPERM
/// means it exists but isn't ours.
fn exists(target: posix.pid_t) bool {
    posix.kill(target, @fromBackingInt(@intCast(0))) catch |e| return e == error.PermissionDenied;
    return true;
}

fn groupAlive(pgid: posix.pid_t) bool {
    return exists(-pgid);
}

const procs = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("darwin.zig"),
    else => @compileError("the POSIX backend covers Linux and macOS"),
};

/// Engines from earlier runs that were killed without cleanup (terminal closed, OOM, kill -9).
/// Our own group is never in the list. Caller frees.
pub fn findLeftovers(gpa: Allocator, io: Io, identity: platform.EngineIdentity) platform.FindLeftoversError![]KillTarget {
    // Without the binary there can't be an engine running it.
    const real_binary = Io.Dir.realPathFileAbsoluteAlloc(io, identity.binary, gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    defer gpa.free(real_binary);

    const Finder = struct {
        gpa: Allocator,
        identity: platform.EngineIdentity,
        own_group: ?posix.pid_t,
        matches: std.ArrayList(Match) = .empty,

        fn visit(f: *@This(), pid: posix.pid_t, exe: []const u8, args: []const []const u8) !void {
            if (!isLeftoverEngine(exe, args, f.identity)) return;
            const pgid = procs.processGroupOf(pid) orelse return;
            if (pgid <= 1 or pgid == f.own_group) return;
            try f.matches.append(f.gpa, .{ .pid = pid, .pgid = pgid });
        }
    };
    var finder: Finder = .{
        .gpa = gpa,
        .identity = .{ .binary = real_binary, .profile = identity.profile, .exe_names = identity.exe_names },
        .own_group = procs.processGroupOf(0),
    };
    defer finder.matches.deinit(gpa);
    procs.forEachProcess(gpa, io, &finder, Finder.visit) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CantListProcesses,
    };
    return leftoversFrom(gpa, finder.matches.items);
}

pub const Match = struct { pid: posix.pid_t, pgid: posix.pid_t };

pub const KillTarget = union(enum) {
    group: posix.pid_t,
    process: posix.pid_t,

    pub fn format(t: KillTarget, w: *Io.Writer) Io.Writer.Error!void {
        switch (t) {
            .group => |pgid| try w.print("process group {d}", .{pgid}),
            .process => |pid| try w.print("process {d}", .{pid}),
        }
    }
};

/// A whole group is ours to kill only when its leader is itself a matching engine (our engines
/// always lead their group). Otherwise, as when Firefox forked and its first process exited,
/// only the matching processes are.
pub fn leftoversFrom(gpa: Allocator, matches: []const Match) Allocator.Error![]KillTarget {
    var leftovers: std.ArrayList(KillTarget) = .empty;
    errdefer leftovers.deinit(gpa);
    for (matches) |m| {
        const leader_matches = for (matches) |other| {
            if (other.pid == m.pgid) break true;
        } else false;
        const leftover: KillTarget = if (leader_matches) .{ .group = m.pgid } else .{ .process = m.pid };
        const seen = for (leftovers.items) |l| {
            if (std.meta.eql(l, leftover)) break true;
        } else false;
        if (!seen) try leftovers.append(gpa, leftover);
    }
    return leftovers.toOwnedSlice(gpa);
}

/// An engine names our profile on its command line, either as its own argument (Firefox's
/// `--profile <dir>`) or after `=` (Chrome's `--user-data-dir=<dir>`), and runs our engine
/// binary or a file named like it: a wrapper script (`/usr/bin/firefox` on some distributions)
/// starts the real binary from elsewhere (`/usr/lib64/firefox/firefox`).
pub fn isLeftoverEngine(exe: []const u8, args: []const []const u8, identity: platform.EngineIdentity) bool {
    const exe_name = Io.Dir.path.basename(exe);
    const runs_engine = std.mem.eql(u8, exe, identity.binary) or for (identity.exe_names) |name| {
        if (std.mem.eql(u8, exe_name, name)) break true;
    } else false;
    if (!runs_engine) return false;
    const profile = identity.profile;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, profile)) return true;
        if (std.mem.endsWith(u8, arg, profile) and arg.len > profile.len and arg[arg.len - profile.len - 1] == '=') return true;
    }
    return false;
}

/// Holds `path` (created user-only) with an exclusive lock until the file is closed, then
/// writes `contents` to it. `error.Locked` when another process holds it.
pub fn lockFile(io: Io, path: []const u8, contents: []const u8) platform.LockFileError!Io.File {
    const file = Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(0o600),
    }) catch |e| return switch (e) {
        error.WouldBlock => error.Locked,
        else => |other| other,
    };
    errdefer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    try file.setLength(io, 0);
    try file.writePositionalAll(io, contents, 0);
    return file;
}

pub fn lockHeld(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{ .lock = .shared, .lock_nonblocking = true }) catch |e| return e == error.WouldBlock;
    file.close(io);
    return false;
}

/// Splits NUL-terminated strings (`/proc/<pid>/cmdline`). Caller frees the slice, which points
/// into `bytes`.
pub fn splitNul(gpa: Allocator, bytes: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\x00"), 0);
    while (it.next()) |arg| try list.append(gpa, arg);
    return list.toOwnedSlice(gpa);
}

// ---- Shutdown and detaching ----

var shutdown_signal: std.atomic.Value(u8) = .init(0);

fn onShutdownSignal(sig: posix.SIG) callconv(.c) void {
    shutdown_signal.store(@intCast(@backingInt(sig)), .release);
}

/// SIGTERM, SIGHUP and SIGINT set a flag that `shutdownRequested` reports; the daemon polls it.
pub fn installShutdownHandlers() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]posix.SIG{ .TERM, .HUP, .INT }) |sig| posix.sigaction(sig, &action, null);
}

/// The name of the shutdown signal received, if any.
pub fn shutdownRequested() ?[]const u8 {
    const sig: posix.SIG = @fromBackingInt(@intCast(shutdown_signal.load(.acquire)));
    return switch (sig) {
        .TERM => "SIGTERM",
        .HUP => "SIGHUP",
        .INT => "SIGINT",
        else => null,
    };
}

/// Leaves the terminal's session, so closing the terminal (SIGHUP) or Ctrl-C there doesn't
/// reach the background process. Fails harmlessly when already a group leader.
pub fn detachFromTerminal() void {
    _ = posix.system.setsid();
}

/// Starts `argv` in the background with stdin closed and stdout/stderr appended to `log_path`
/// (created mode 600). It isn't waited for: it outlives us.
pub fn spawnDetached(io: Io, argv: []const []const u8, log_path: []const u8) platform.SpawnDetachedError!void {
    const fd = posix.openat(posix.AT.FDCWD, log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch
        return error.CantOpenLog;
    const log: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer log.close(io);
    // The mode applies only to a new file; an existing one may be wider.
    log.setPermissions(io, .fromMode(0o600)) catch return error.CantOpenLog;
    _ = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .{ .file = log }, .stderr = .{ .file = log } });
}

// ---- Playback: the browser, footprint, free memory ----

pub fn openUrl(io: Io, url: []const u8) platform.OpenUrlError!void {
    _ = try std.process.spawn(io, .{
        .argv = &openUrlArgv(builtin.os.tag, url),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // xdg-open may run the browser itself and wait for it: Ctrl-C on `am` must not reach it.
        .pgid = 0,
    });
}

pub fn openUrlArgv(os: std.Target.Os.Tag, url: []const u8) [2][]const u8 {
    return .{ if (os == .macos) "/usr/bin/open" else "xdg-open", url };
}

pub fn processTree(gpa: Allocator, io: Io, group: *const ProcessGroup) platform.ProcessTreeError![]posix.pid_t {
    return procs.processTree(gpa, io, group.pgid);
}

pub fn processUsage(io: Io, pid: posix.pid_t) platform.ProcessUsageError!platform.ProcessUsage {
    return procs.processUsage(io, pid);
}

pub fn availableMemory(io: Io) platform.AvailableMemoryError!u64 {
    return procs.availableMemory(io);
}

pub fn engineAudio(arena: Allocator, io: Io, pids: []const posix.pid_t) Allocator.Error!platform.EngineAudio {
    return switch (builtin.os.tag) {
        .linux => pipewire.engineStreams(arena, io, pids),
        else => .{ .unsupported = "not checked on macOS (the PipeWire check is Linux only)" },
    };
}

const pipewire = @import("pipewire.zig");

test {
    // Its parser is pure; test it here too, not only on Linux.
    _ = pipewire;
}

pub const TreeEntry = struct { pid: posix.pid_t, ppid: posix.pid_t, pgid: posix.pid_t };

/// The members of process group `pgid` and, transitively, their children. Caller frees.
pub fn treeOf(gpa: Allocator, entries: []const TreeEntry, pgid: posix.pid_t) Allocator.Error![]posix.pid_t {
    var tree: std.ArrayList(posix.pid_t) = .empty;
    errdefer tree.deinit(gpa);
    for (entries) |e| if (e.pgid == pgid) try tree.append(gpa, e.pid);
    var next: usize = 0;
    while (next < tree.items.len) : (next += 1) {
        const parent = tree.items[next];
        for (entries) |e| if (e.ppid == parent and std.mem.findScalar(posix.pid_t, tree.items, e.pid) == null) try tree.append(gpa, e.pid);
    }
    return tree.toOwnedSlice(gpa);
}

/// The fields of `/proc/<pid>/stat` we read.
pub const Stat = struct {
    ppid: posix.pid_t,
    pgrp: posix.pid_t,
    /// utime + stime, in clock ticks.
    cpu_ticks: u64,
};

/// `/proc/<pid>/stat`. The command name may hold spaces and parentheses, so fields are counted
/// from the last `)`.
pub fn parseStat(text: []const u8) ?Stat {
    const paren = std.mem.findScalarLast(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[paren + 1 ..], ' ');
    var values: [13][]const u8 = undefined;
    for (&values) |*v| v.* = fields.next() orelse return null;
    // values[0] is the state; ppid, pgrp, then utime and stime are fields 14 and 15 of the file.
    const ppid = std.fmt.parseInt(posix.pid_t, values[1], 10) catch return null;
    const pgrp = std.fmt.parseInt(posix.pid_t, values[2], 10) catch return null;
    const utime = std.fmt.parseInt(u64, values[11], 10) catch return null;
    const stime = std.fmt.parseInt(u64, values[12], 10) catch return null;
    return .{ .ppid = ppid, .pgrp = pgrp, .cpu_ticks = utime + stime };
}

/// The `<name>:   <n> kB` line of `/proc` files like `smaps_rollup`, `status` and `meminfo`,
/// in bytes.
pub fn parseKbField(text: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name) or line.len <= name.len or line[name.len] != ':') continue;
        var words = std.mem.tokenizeAny(u8, line[name.len + 1 ..], " \t");
        const kb = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
        return kb * 1024;
    }
    return null;
}

const testing = std.testing;

fn expectConfigDir(expected: []const u8, vars: []const [2][]const u8) !void {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for (vars) |v| try environ.put(v[0], v[1]);
    const dir = try configDir(testing.allocator, &environ);
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings(expected, dir);
}

test "the config dir is AM_CONFIG_DIR, else $XDG_CONFIG_HOME/am, else ~/.config/am" {
    try expectConfigDir("/custom/am", &.{ .{ "AM_CONFIG_DIR", "/custom/am" }, .{ "XDG_CONFIG_HOME", "/xdg" }, .{ "HOME", "/home/u" } });
    try expectConfigDir("/xdg/am", &.{ .{ "XDG_CONFIG_HOME", "/xdg" }, .{ "HOME", "/home/u" } });
    try expectConfigDir("/home/u/.config/am", &.{.{ "HOME", "/home/u" }});
    // Empty means unset, and the XDG spec says to ignore a relative XDG_CONFIG_HOME.
    try expectConfigDir("/home/u/.config/am", &.{ .{ "AM_CONFIG_DIR", "" }, .{ "XDG_CONFIG_HOME", "" }, .{ "HOME", "/home/u" } });
    try expectConfigDir("/home/u/.config/am", &.{ .{ "XDG_CONFIG_HOME", "relative" }, .{ "HOME", "/home/u" } });
}

test "without HOME there is no default config dir" {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectError(error.NoHomeDir, configDir(testing.allocator, &environ));
}

fn modeOf(io: Io, path: []const u8) !std.posix.mode_t {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return st.permissions.toMode() & 0o777;
}

test "a private file is mode 600 in a directory created mode 700, and replaces what was there" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const dir = try Io.Dir.path.join(testing.allocator, &.{ root, "a", "am" });
    defer testing.allocator.free(dir);
    const path = try Io.Dir.path.join(testing.allocator, &.{ dir, "secret" });
    defer testing.allocator.free(path);

    try writePrivateFile(io, dir, "secret", "one");
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), try modeOf(io, dir));
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try modeOf(io, path));

    // A file someone left world-readable is replaced, not rewritten in place.
    try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o644), .{});
    try writePrivateFile(io, dir, "secret", "two");
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try modeOf(io, path));
    var content: [16]u8 = undefined;
    try testing.expectEqualStrings("two", try Io.Dir.cwd().readFile(io, path, &content));
}

test "an existing config dir that others can read is tightened to 700" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const dir = try Io.Dir.path.join(testing.allocator, &.{ root, "am" });
    defer testing.allocator.free(dir);

    try Io.Dir.cwd().createDir(io, dir, .fromMode(0o755));
    try Io.Dir.cwd().setFilePermissions(io, dir, .fromMode(0o755), .{});
    try writePrivateFile(io, dir, "secret", "one");
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), try modeOf(io, dir));
}

test "a private file created over an existing wider one ends up 600, and so does an appended log" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try Io.Dir.path.join(testing.allocator, &.{ root, "engine.log" });
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "engine.log", .data = "old" });
    try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o644), .{});
    const file = try createPrivateFile(io, path);
    file.close(io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try modeOf(io, path));

    const log = try Io.Dir.path.join(testing.allocator, &.{ root, "daemon.log" });
    defer testing.allocator.free(log);
    try tmp.dir.writeFile(io, .{ .sub_path = "daemon.log", .data = "old\n" });
    try Io.Dir.cwd().setFilePermissions(io, log, .fromMode(0o644), .{});
    try spawnDetached(io, &.{ "/bin/echo", "new" }, log);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try modeOf(io, log));
    var tries: usize = 0;
    var content: [16]u8 = undefined;
    while (tries < 100 and !std.mem.eql(u8, try Io.Dir.cwd().readFile(io, log, &content), "old\nnew\n")) : (tries += 1) try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectEqualStrings("old\nnew\n", try Io.Dir.cwd().readFile(io, log, &content));
}

test "an engine runs our binary, or one named like it, with our profile as an argument or after =" {
    const chrome: platform.EngineIdentity = .{ .binary = "/opt/google/chrome/chrome", .profile = "/home/u/.config/am/chrome-profile", .exe_names = &.{"chrome"} };
    const firefox: platform.EngineIdentity = .{ .binary = "/usr/bin/firefox", .profile = "/home/u/.config/am/firefox-profile", .exe_names = &.{ "firefox-esr", "firefox", "firefox-bin" } };
    try testing.expect(isLeftoverEngine(chrome.binary, &.{ chrome.binary, "--user-data-dir=/home/u/.config/am/chrome-profile", "--headless" }, chrome));
    try testing.expect(isLeftoverEngine("/usr/bin/firefox", &.{ "firefox", "--profile", firefox.profile }, firefox));
    // /usr/bin/firefox is a wrapper script: the running exe is the real binary elsewhere.
    try testing.expect(isLeftoverEngine("/usr/lib64/firefox/firefox", &.{ "/usr/lib64/firefox/firefox", "--new-instance", "--profile", firefox.profile }, firefox));
    try testing.expect(isLeftoverEngine("/usr/lib/firefox/firefox-bin", &.{ "firefox-bin", "--profile", firefox.profile }, firefox));

    // The user's own browser: same binary, another profile (or one that merely shares a prefix).
    try testing.expect(!isLeftoverEngine(chrome.binary, &.{ chrome.binary, "--user-data-dir=/home/u/.config/google-chrome" }, chrome));
    try testing.expect(!isLeftoverEngine(chrome.binary, &.{ chrome.binary, "--user-data-dir=/home/u/.config/am/chrome-profile2" }, chrome));
    try testing.expect(!isLeftoverEngine(chrome.binary, &.{ chrome.binary, "--x=/tmp/home/u/.config/am/chrome-profile" }, chrome));
    try testing.expect(!isLeftoverEngine(chrome.binary, &.{chrome.binary}, chrome));
    try testing.expect(!isLeftoverEngine("/usr/lib64/firefox/firefox", &.{ "firefox", "--profile", "/home/u/.mozilla/firefox/abc.default" }, firefox));
    // Another program that happens to name our profile, like `ls` on it.
    try testing.expect(!isLeftoverEngine("/bin/ls", &.{ "ls", chrome.profile }, chrome));
    try testing.expect(!isLeftoverEngine("/usr/bin/vim", &.{ "vim", firefox.profile }, firefox));
}

test "a whole group is killed only when its leader is a matching engine, else the matching processes" {
    const matches = [_]Match{
        // Chrome: the leader and its helpers.
        .{ .pid = 100, .pgid = 100 },
        .{ .pid = 101, .pgid = 100 },
        // Firefox forked and its first process (200) exited: its group isn't ours to kill.
        .{ .pid = 201, .pgid = 200 },
        // A match inside someone else's group (e.g. started from a shell by hand).
        .{ .pid = 301, .pgid = 300 },
    };
    const leftovers = try leftoversFrom(testing.allocator, &matches);
    defer testing.allocator.free(leftovers);
    try testing.expectEqualSlices(KillTarget, &.{ .{ .group = 100 }, .{ .process = 201 }, .{ .process = 301 } }, leftovers);
}

test "the config dir lock admits one holder at a time" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try Io.Dir.path.join(testing.allocator, &.{ root, "daemon.lock" });
    defer testing.allocator.free(path);

    const held = try lockFile(io, path, "pid 1 port 47823\n");
    try testing.expectError(error.Locked, lockFile(io, path, "pid 2 port 47824\n"));
    var content: [64]u8 = undefined;
    try testing.expectEqualStrings("pid 1 port 47823\n", try Io.Dir.cwd().readFile(io, path, &content));
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try modeOf(io, path));
    held.close(io);
    const again = try lockFile(io, path, "pid 3\n");
    again.close(io);
    try testing.expectEqualStrings("pid 3\n", try Io.Dir.cwd().readFile(io, path, &content));
}

test "a /proc cmdline splits at its NULs" {
    const args = try splitNul(testing.allocator, "firefox\x00--profile\x00/p\x00");
    defer testing.allocator.free(args);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "firefox", "--profile", "/p" }), args);
}

fn testEnviron() Environ.Map {
    return .init(testing.allocator);
}

test "killing a process group takes down every process in it, even after the leader exited" {
    const io = testing.io;
    var environ = testEnviron();
    defer environ.deinit();

    // Like Firefox: the first process starts helpers and exits.
    var forked = try spawnGroup(io, .{ .argv = &.{ "/bin/sh", "-c", "/bin/sleep 30 & /bin/sleep 30 & exit 0" }, .environ_map = &environ });
    try io.sleep(.fromMilliseconds(200), .awake);
    try testing.expect(forked.alive());
    forked.kill(io);
    try testing.expect(!forked.alive());

    var waiting = try spawnGroup(io, .{ .argv = &.{ "/bin/sh", "-c", "/bin/sleep 30 & wait" }, .environ_map = &environ });
    try testing.expect(waiting.alive());
    waiting.kill(io);
    try testing.expect(!waiting.alive());
}

test "killing a group that already ended sends nothing and returns at once" {
    const io = testing.io;
    var environ = testEnviron();
    defer environ.deinit();
    var group = try spawnGroup(io, .{ .argv = &.{"/usr/bin/true"}, .environ_map = &environ });
    while (group.alive()) try io.sleep(.fromMilliseconds(10), .awake);
    const start: Io.Clock.Timestamp = .now(io, .awake);
    group.kill(io);
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 50);
}

fn killInTask(group: *ProcessGroup, io: Io) void {
    group.kill(io);
}

test "cancelling a kill doesn't skip the SIGKILL for a group that ignores SIGTERM" {
    const io = testing.io;
    var environ = testEnviron();
    defer environ.deinit();
    var group = try spawnGroup(io, .{ .argv = &.{ "/bin/sh", "-c", "trap '' TERM; /bin/sleep 30 & wait" }, .environ_map = &environ });
    try io.sleep(.fromMilliseconds(200), .awake);
    var killing = try io.concurrent(killInTask, .{ &group, io });
    try io.sleep(.fromMilliseconds(100), .awake);
    killing.cancel(io);
    try testing.expect(!group.alive());
}

test "a process that exits on its own leaves no live group" {
    const io = testing.io;
    var environ = testEnviron();
    defer environ.deinit();
    var group = try spawnGroup(io, .{ .argv = &.{"/usr/bin/true"}, .environ_map = &environ });
    var tries: usize = 0;
    while (group.alive() and tries < 100) : (tries += 1) try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expect(!group.alive());
}

test "leftovers are found by binary and profile path, and killed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const profile = try Io.Dir.path.join(testing.allocator, &.{ root, "chrome-profile" });
    defer testing.allocator.free(profile);
    const other = try Io.Dir.path.join(testing.allocator, &.{ root, "other-profile" });
    defer testing.allocator.free(other);

    var environ = testEnviron();
    defer environ.deinit();
    // `tail -F` on a missing file runs until killed, with the path on its command line.
    var engine = try spawnGroup(io, .{ .argv = &.{ "/usr/bin/tail", "-F", profile }, .environ_map = &environ });
    defer engine.kill(io);
    var bystander = try spawnGroup(io, .{ .argv = &.{ "/usr/bin/tail", "-F", other }, .environ_map = &environ });
    defer bystander.kill(io);
    try io.sleep(.fromMilliseconds(200), .awake);

    const tail: platform.EngineIdentity = .{ .binary = "/usr/bin/tail", .profile = profile, .exe_names = &.{} };
    const found = try findLeftovers(testing.allocator, io, tail);
    defer testing.allocator.free(found);
    try testing.expectEqualSlices(KillTarget, &.{.{ .group = engine.pgid }}, found);

    killLeftover(io, found[0]);
    try testing.expect(!engine.alive());
    try testing.expect(bystander.alive());

    const none = try findLeftovers(testing.allocator, io, tail);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    const missing_binary = try findLeftovers(testing.allocator, io, .{ .binary = "/nonexistent/browser", .profile = profile, .exe_names = &.{} });
    try testing.expectEqual(@as(usize, 0), missing_binary.len);
}

test "a leftover whose group leader is gone is killed alone, not its group" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const profile = try Io.Dir.path.join(testing.allocator, &.{ root, "firefox-profile" });
    defer testing.allocator.free(profile);
    const script = try std.mem.concat(testing.allocator, u8, &.{ "/usr/bin/tail -F ", profile, " & /bin/sleep 30 & exit 0" });
    defer testing.allocator.free(script);

    var environ = testEnviron();
    defer environ.deinit();
    // Like Firefox forking: the leader exits, the engine and a bystander stay in its group.
    var group = try spawnGroup(io, .{ .argv = &.{ "/bin/sh", "-c", script }, .environ_map = &environ });
    defer group.kill(io);
    try io.sleep(.fromMilliseconds(200), .awake);

    const found = try findLeftovers(testing.allocator, io, .{ .binary = "/usr/bin/tail", .profile = profile, .exe_names = &.{} });
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expect(found[0] == .process);
    killLeftover(io, found[0]);
    // The bystander in the same group survives.
    try testing.expect(group.alive());
}

test "the server socket is the lock: a second listener on the same port fails" {
    const io = testing.io;
    var first = try listenLoopback(io, .{ .ip4 = .loopback(0) });
    defer first.deinit(io);
    const port = first.socket.address.getPort();
    try testing.expect(port != 0);
    try testing.expectError(error.AddressInUse, listenLoopback(io, .{ .ip4 = .loopback(port) }));
}

test "/proc/<pid>/stat gives ppid, process group and CPU ticks, even with odd command names" {
    const stat = "4242 (Web Content) (x) S 4200 4100 4100 0 -1 4194560 1 2 3 4 150 25 0 0 20 0 1 0 100 1000 50";
    try testing.expectEqual(Stat{ .ppid = 4200, .pgrp = 4100, .cpu_ticks = 175 }, parseStat(stat).?);
    try testing.expectEqual(null, parseStat("4242 (short) S 1 2"));
    try testing.expectEqual(null, parseStat("garbage"));
}

test "kB fields of smaps_rollup, status and meminfo come back in bytes" {
    const rollup = "55d0c-7ffd [rollup]\nRss:              120000 kB\nPss:               45000 kB\nPss_Anon:          30000 kB\n";
    try testing.expectEqual(@as(?u64, 45000 * 1024), parseKbField(rollup, "Pss"));
    try testing.expectEqual(@as(?u64, 120000 * 1024), parseKbField(rollup, "Rss"));
    try testing.expectEqual(@as(?u64, null), parseKbField(rollup, "Pss_File"));
    const meminfo = "MemTotal:        3900000 kB\nMemFree:          200000 kB\nMemAvailable:     650000 kB\n";
    try testing.expectEqual(@as(?u64, 650000 * 1024), parseKbField(meminfo, "MemAvailable"));
    try testing.expectEqual(@as(?u64, null), parseKbField("VmRSS:\n", "VmRSS"));
}

test "a process tree is the group plus everything its members started, even outside the group" {
    const entries = [_]TreeEntry{
        .{ .pid = 1, .ppid = 0, .pgid = 1 },
        .{ .pid = 100, .ppid = 1, .pgid = 100 }, // engine leader
        .{ .pid = 101, .ppid = 100, .pgid = 100 },
        .{ .pid = 102, .ppid = 101, .pgid = 102 }, // left the group
        .{ .pid = 103, .ppid = 102, .pgid = 102 },
        .{ .pid = 104, .ppid = 1, .pgid = 100 }, // orphaned member, reparented to init
        .{ .pid = 200, .ppid = 1, .pgid = 200 }, // someone else
    };
    const tree = try treeOf(testing.allocator, &entries, 100);
    defer testing.allocator.free(tree);
    try testing.expectEqualSlices(posix.pid_t, &.{ 100, 101, 104, 102, 103 }, tree);
}

test "the browser opens with open on macOS and xdg-open elsewhere" {
    try testing.expectEqualDeep([2][]const u8{ "/usr/bin/open", "http://localhost:47823/?signin" }, openUrlArgv(.macos, "http://localhost:47823/?signin"));
    try testing.expectEqualDeep([2][]const u8{ "xdg-open", "http://localhost:47823/?signin" }, openUrlArgv(.linux, "http://localhost:47823/?signin"));
}

test "an engine's tree and footprint: every process, non-zero memory, CPU time that grows" {
    const io = testing.io;
    var environ = testEnviron();
    defer environ.deinit();
    // A leader that keeps a busy child and a sleeping one.
    var group = try spawnGroup(io, .{ .argv = &.{ "/bin/sh", "-c", "(while :; do :; done) & /bin/sleep 30 & wait" }, .environ_map = &environ });
    defer group.kill(io);
    try io.sleep(.fromMilliseconds(300), .awake);

    const tree = try processTree(testing.allocator, io, &group);
    defer testing.allocator.free(tree);
    try testing.expectEqual(@as(usize, 3), tree.len);
    try testing.expect(std.mem.findScalar(posix.pid_t, tree, group.pgid) != null);

    var busy_ns: u64 = 0;
    for (tree) |pid| {
        const usage = try processUsage(io, pid);
        try testing.expect(usage.memory_bytes > 0);
        busy_ns = @max(busy_ns, usage.cpu_ns);
    }
    try testing.expect(busy_ns > 50 * std.time.ns_per_ms);
    try testing.expectError(error.CantReadProcess, processUsage(io, 999_999_999));
}

test "available memory is a plausible amount" {
    const bytes = try availableMemory(testing.io);
    try testing.expect(bytes > 16 * 1024 * 1024);
    try testing.expect(bytes < try std.process.totalSystemMemory());
}
