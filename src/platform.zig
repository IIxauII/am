//! Everything OS-specific sits behind this interface; the core (config, tokens, Apple API,
//! commands) imports only this file. Each backend exports the same functions:
//!
//! - `platform/posix.zig`: Linux and macOS.
//! - `platform/windows.zig`: Windows 10 and later.
//!
//! Slots for the later sub-issues of #2 are added here and in every backend as they land.
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux, .macos => @import("platform/posix.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("am supports Linux, macOS and Windows"),
};

/// The directory holding the env file, tokens and engine profiles. Caller owns the result.
/// POSIX: `AM_CONFIG_DIR`, else `$XDG_CONFIG_HOME/am`, else `~/.config/am`.
/// Windows: `AM_CONFIG_DIR`, else `%APPDATA%\am`.
pub const configDir: fn (std.mem.Allocator, *const std.process.Environ.Map) ConfigDirError![]u8 = impl.configDir;

pub const ConfigDirError = error{
    /// No `AM_CONFIG_DIR` and no home directory to put the default under.
    NoHomeDir,
    /// The backend for this OS isn't written yet.
    Unsupported,
    OutOfMemory,
};

/// The user's home directory, for expanding `~` in the env file (`%USERPROFILE%` on Windows).
pub const homeDir: fn (*const std.process.Environ.Map) ?[]const u8 = impl.homeDir;

/// What to tell the user when `configDir` fails, in this OS's terms.
pub const describeConfigDirError: fn (ConfigDirError) []const u8 = impl.describeConfigDirError;

/// Writes `data` to `<dir_path>/<name>` so that only the user can read it, creating the
/// directory (user-only, and tightened if it exists wider) if needed. Replaces an existing file
/// atomically. Windows sets no permissions: files inherit the directory's ACL, which under
/// `%APPDATA%` normally grants only the user, SYSTEM and Administrators.
pub const writePrivateFile: fn (std.Io, []const u8, []const u8, []const u8) WritePrivateFileError!void = impl.writePrivateFile;

pub const WritePrivateFileError = std.Io.Dir.CreateDirPathOpenError ||
    std.Io.Dir.StatError ||
    std.Io.Dir.SetFilePermissionsError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.ReplaceError ||
    error{
        /// The backend for this OS isn't written yet.
        Unsupported,
    };

/// Creates a directory (and its parents) that only the user can enter.
pub const createPrivateDir: fn (std.Io, []const u8) CreatePrivateDirError!void = impl.createPrivateDir;

pub const CreatePrivateDirError = std.Io.Dir.CreateDirPathOpenError || std.Io.Dir.CreateDirPathError;

/// Creates or truncates a file only the user can read, tightening an existing one (on Windows
/// it keeps the ACL it inherits).
pub const createPrivateFile: fn (std.Io, []const u8) CreatePrivateFileError!std.Io.File = impl.createPrivateFile;

pub const CreatePrivateFileError = std.Io.File.OpenError || std.Io.File.SetPermissionsError;

/// Binds the background process's server socket on one loopback address. Binding is the lock
/// that keeps a second `am daemon` out, so `AddressInUse` must mean another listener holds it.
pub const listenLoopback: fn (std.Io, std.Io.net.IpAddress) ListenError!std.Io.net.Server = impl.listenLoopback;

pub const ListenError = error{
    /// Another process listens on the port.
    AddressInUse,
    /// The OS refused the port: a privileged port, or on Windows one held exclusively or in a
    /// range reserved for Hyper-V, WSL or Docker (`netsh interface ipv4 show excludedportrange
    /// protocol=tcp`).
    AccessDenied,
    /// The address doesn't exist here, e.g. `::1` with IPv6 disabled.
    AddressUnavailable,
    AddressFamilyUnsupported,
    Unsupported,
    Unexpected,
};

/// A process id as this OS has it.
pub const ProcessId = impl.ProcessId;

/// This process's id.
pub const currentPid: fn () ProcessId = impl.currentPid;

/// Where this OS keeps a browser that can serve as the engine, and what it needs there.
pub const Browser = struct {
    /// Where to look when its path setting is unset, in order.
    candidates: []const Candidate,
    /// File names of the executable a running engine shows. A wrapper script found on `PATH`
    /// starts the real binary from elsewhere, so leftover engines are matched by these too.
    exe_names: []const []const u8,
    /// Flags this OS needs on top of the browser's own.
    extra_args: []const []const u8 = &.{},
};

pub const Browsers = struct { firefox: Browser, chrome: Browser };

/// One place a browser may be: `path` inside the directory that the environment variable
/// `under` names (Windows' `ProgramFiles`), else an absolute path, else a name looked up on
/// `PATH`.
pub const Candidate = struct {
    under: ?[]const u8 = null,
    path: []const u8,
};

pub const browsers: Browsers = impl.browsers;

/// What marks a process as our engine: it runs `binary` (or a file named like one of
/// `exe_names`) and names `profile` on its command line, which the user's own browser never does.
pub const EngineIdentity = struct {
    binary: []const u8,
    profile: []const u8,
    exe_names: []const []const u8,
};

/// The engine's whole process tree: a process group on POSIX, a kill-on-close Job Object on
/// Windows. `leader()` is the first process's id, `alive()` whether any process of the tree
/// still runs, and `kill(io)` ends them all (POSIX: SIGTERM, up to 5 s, then SIGKILL, up to
/// 2 s; Windows: terminated at once, up to 2 s to go).
pub const ProcessGroup = impl.ProcessGroup;

pub const SpawnGroupOptions = struct {
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    /// Receives stdout and stderr; null discards them.
    output: ?std.Io.File = null,
};

/// Starts a process as the root of a new `ProcessGroup`.
pub const spawnGroup: fn (std.Io, SpawnGroupOptions) SpawnError!ProcessGroup = impl.spawnGroup;

pub const SpawnError = std.process.SpawnError || error{
    /// The backend for this OS isn't written yet.
    Unsupported,
};

/// Engines left over from earlier runs (see `EngineIdentity`), as kill targets. Caller frees
/// the slice.
pub const findLeftovers: fn (std.mem.Allocator, std.Io, EngineIdentity) FindLeftoversError![]KillTarget = impl.findLeftovers;

/// What `killLeftover` ends; each backend decides. POSIX: a whole process group when its leader
/// is itself an engine (ours always are), else just the matching process. Windows: a process whose parent isn't a match
/// too (there are no process groups). Prints with `{f}`.
pub const KillTarget = impl.KillTarget;

pub const FindLeftoversError = std.mem.Allocator.Error || error{
    /// The process list itself couldn't be read (single processes that can't be read are skipped).
    CantListProcesses,
    /// The backend for this OS isn't written yet.
    Unsupported,
};

/// Ends a leftover found by `findLeftovers`.
pub const killLeftover: fn (std.Io, KillTarget) void = impl.killLeftover;

/// Takes an exclusive lock on the file at `path` (created user-only), held until the file is
/// closed, and writes `contents` to it. A second `am daemon` on the same config dir gets
/// `error.Locked`: one config dir, one daemon, whatever the port. On Windows the lock is the
/// open file itself, shared for reading only.
pub const lockFile: fn (std.Io, []const u8, []const u8) LockFileError!std.Io.File = impl.lockFile;

/// Whether another process holds the lock `lockFile` takes on `path`. Changes nothing: only a
/// shared lock (POSIX) or a write-access open (Windows), released at once.
pub const lockHeld: fn (std.Io, []const u8) bool = impl.lockHeld;

pub const LockFileError = std.Io.File.OpenError || std.Io.File.SetPermissionsError || std.Io.File.SetLengthError || std.Io.File.WritePositionalError || error{
    /// Another process holds the lock.
    Locked,
};

/// Routes the OS's shutdown requests (SIGTERM, SIGHUP, SIGINT; console control events on
/// Windows) to `shutdownRequested`, which the daemon polls.
pub const installShutdownHandlers: fn () void = impl.installShutdownHandlers;

/// The name of the shutdown request received (e.g. "SIGTERM"), if any.
pub const shutdownRequested: fn () ?[]const u8 = impl.shutdownRequested;

/// Leaves the terminal's session, so closing the terminal doesn't stop the background process.
/// A no-op on Windows, where `spawnDetached` already gives the daemon its own hidden console.
pub const detachFromTerminal: fn () void = impl.detachFromTerminal;

/// Starts `argv` in the background, not waited for, with stdout and stderr appended to the file
/// at `log_path` (created user-only).
pub const spawnDetached: fn (std.Io, []const []const u8, []const u8) SpawnDetachedError!void = impl.spawnDetached;

pub const SpawnDetachedError = SpawnError || error{
    /// The log file couldn't be opened.
    CantOpenLog,
};

// ---- Playback (#6): sign-in in the user's browser, footprint, free memory ----

/// Opens `url` in the user's default browser (macOS `open`, Linux `xdg-open`) and returns
/// without waiting for the browser.
pub const openUrl: fn (std.Io, []const u8) OpenUrlError!void = impl.openUrl;

pub const OpenUrlError = SpawnError;

/// The processes of an engine: the group's members and everything they started, even ones that
/// left the group. Caller frees.
pub const processTree: fn (std.mem.Allocator, std.Io, *const ProcessGroup) ProcessTreeError![]ProcessId = impl.processTree;

pub const ProcessTreeError = std.mem.Allocator.Error || error{
    /// The process list itself couldn't be read.
    CantListProcesses,
    /// The backend for this OS isn't written yet.
    Unsupported,
};

/// How a process's memory was measured.
pub const MemoryMeasure = enum {
    /// Linux proportional set size: shared pages are split between the processes sharing them.
    pss,
    /// Resident set size: shared pages count in full in every process, so a sum over-counts.
    rss,
    /// macOS `phys_footprint` (Activity Monitor's "Memory").
    phys_footprint,
    /// Windows private working set (Task Manager's "Memory").
    private_working_set,
};

pub const ProcessUsage = struct {
    memory_bytes: u64,
    memory: MemoryMeasure,
    /// User plus system CPU time since the process started.
    cpu_ns: u64,
};

/// One process's memory now and CPU time so far. Linux: PSS from `/proc/<pid>/smaps_rollup`,
/// else RSS. macOS: `proc_pid_rusage`. Windows: the private working set, else the working set
/// (as RSS).
pub const processUsage: fn (std.Io, ProcessId) ProcessUsageError!ProcessUsage = impl.processUsage;

pub const ProcessUsageError = error{
    /// It exited, or isn't ours to inspect.
    CantReadProcess,
    /// The backend for this OS isn't written yet.
    Unsupported,
};

/// Memory that new processes can get without swapping, in bytes. Linux: `MemAvailable` from
/// `/proc/meminfo`. macOS: free plus inactive pages from `host_statistics64`.
pub const availableMemory: fn (std.Io) AvailableMemoryError!u64 = impl.availableMemory;

pub const AvailableMemoryError = error{
    /// The OS didn't say.
    CantReadMemory,
    /// The backend for this OS isn't written yet.
    Unsupported,
};

/// The audio streams the engine's processes (`pids`, from `processTree`) play into the OS's
/// sound server: metadata only, never the audio. Linux: PipeWire's sink inputs. Allocates into
/// `arena`.
pub const engineAudio: fn (std.mem.Allocator, std.Io, []const ProcessId) std.mem.Allocator.Error!EngineAudio = impl.engineAudio;

pub const EngineAudio = union(enum) {
    /// Why this OS has no check, e.g. "not checked on macOS (…)".
    unsupported: []const u8,
    /// Why the streams couldn't be listed.
    failed: []const u8,
    streams: []const AudioStream,
};

pub const AudioStream = struct {
    index: u64,
    app: []const u8,
    media: []const u8,
    corked: bool,
    mute: bool,
    sink: u64,
};

test {
    _ = impl;
    // The Windows backend's pure parts (paths, command lines) run on every host.
    if (builtin.os.tag != .windows) _ = @import("platform/windows.zig");
}
