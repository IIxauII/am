//! The platform interface on Windows. See `../platform.zig` for the contract.
//!
//! std doesn't bind Job Objects, console control handlers, the Toolhelp process list or
//! process-thread attribute lists, so `win32` below declares them by hand. The pure parts
//! (paths, command lines, leftover matching) are tested on every host.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;
const windows = std.os.windows;
const ntdll = windows.ntdll;

const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;

/// Paths and executable names compare without regard to case, as Windows does.
const eql = windows.eqlIgnoreCaseWtf8;

/// The exit code of a process we end.
const killed_exit_code = 1;

/// Enough to read a process's image path and command line.
const query_access: windows.ACCESS_MASK = .{ .SPECIFIC = .{ .PROCESS = .{ .QUERY_LIMITED_INFORMATION = true } } };

pub fn configDir(gpa: Allocator, environ: *const Environ.Map) platform.ConfigDirError![]u8 {
    if (config.getEnv(environ, "AM_CONFIG_DIR")) |dir| return gpa.dupe(u8, dir);
    const appdata = config.getEnv(environ, "APPDATA") orelse return error.NoHomeDir;
    if (!Io.Dir.path.isAbsoluteWindows(appdata)) return error.NoHomeDir;
    return std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, appdata, "\\/"), "\\am" });
}

pub fn homeDir(environ: *const Environ.Map) ?[]const u8 {
    return config.getEnv(environ, "USERPROFILE");
}

pub fn describeConfigDirError(err: platform.ConfigDirError) []const u8 {
    return switch (err) {
        error.NoHomeDir => "APPDATA is not set, so there is no config directory: set AM_CONFIG_DIR",
        error.OutOfMemory => "out of memory",
        // `configDir` has no other errors here.
        error.Unsupported => unreachable,
    };
}

// Secrets get no mode: they rely on the ACL that the config directory inherits. Under
// %APPDATA% (the user's profile) that normally grants only the user, SYSTEM and Administrators;
// an AM_CONFIG_DIR elsewhere (say C:\am) may let every local user read them.

/// Replaces `<dir_path>/<name>` atomically (a temporary file renamed over it).
pub fn writePrivateFile(io: Io, dir_path: []const u8, name: []const u8, data: []const u8) platform.WritePrivateFileError!void {
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    var file = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.replace(io);
}

pub fn createPrivateDir(io: Io, path: []const u8) platform.CreatePrivateDirError!void {
    try Io.Dir.cwd().createDirPath(io, path);
}

pub fn createPrivateFile(io: Io, path: []const u8) platform.CreatePrivateFileError!Io.File {
    return Io.Dir.cwd().createFile(io, path, .{});
}

// ---- The background process's server ----

/// A plain listening socket. No SO_REUSEADDR: on Windows it would let a second socket bind the
/// port we hold, and the bind is the lock. (Windows allows a new listener while old connections
/// linger in TIME_WAIT without it.)
pub fn listenLoopback(io: Io, address: Io.net.IpAddress) platform.ListenError!Io.net.Server {
    return address.listen(io, .{}) catch |e| switch (e) {
        error.AddressInUse => error.AddressInUse,
        error.AddressUnavailable => error.AddressUnavailable,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        // WSAEACCES: the port is in a range Windows reserves (Hyper-V, WSL, Docker).
        error.AccessDenied => error.AccessDenied,
        else => error.Unexpected,
    };
}

// ---- Engine processes ----

pub const ProcessId = DWORD;

/// The engine and everything it starts, as one Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
/// The daemon holds the only handle to it, so the engine ends when the daemon does, even when
/// the daemon is killed outright.
pub const ProcessGroup = struct {
    /// Null once killed.
    job: ?HANDLE,
    pid: ProcessId,

    /// The first process's id.
    pub fn leader(g: *const ProcessGroup) ProcessId {
        return g.pid;
    }

    /// Whether any process of the job still runs. Firefox's launcher process starts the browser
    /// and exits, so the first process may be gone while the job lives on.
    pub fn alive(g: *ProcessGroup) bool {
        const job = g.job orelse return false;
        return activeProcesses(job) != 0;
    }

    /// Terminates every process in the job (Windows has no SIGTERM for a windowless process),
    /// waits up to 2 s for them to go, and closes the job.
    pub fn kill(g: *ProcessGroup, io: Io) void {
        const job = g.job orelse return;
        _ = win32.TerminateJobObject(job, killed_exit_code);
        var waited: u32 = 0;
        while (waited < 2000 and activeProcesses(job) != 0) : (waited += 50)
            io.sleep(.fromMilliseconds(50), .awake) catch break;
        windows.CloseHandle(job);
        g.job = null;
    }

    /// Processes in the job; when that can't be read, assumes they're still there.
    fn activeProcesses(job: HANDLE) DWORD {
        var info: win32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = undefined;
        if (!win32.QueryInformationJobObject(job, .BasicAccountingInformation, &info, @sizeOf(@TypeOf(info)), null).toBool()) return 1;
        return info.ActiveProcesses;
    }
};

pub fn currentPid() ProcessId {
    return windows.GetCurrentProcessId();
}

const chrome_in_dir = "Google\\Chrome\\Application\\chrome.exe";

/// 64-bit installs, then 32-bit ones, then Chrome's per-user install.
pub const browsers: platform.Browsers = .{
    .firefox = .{
        .candidates = &.{
            .{ .under = "ProgramFiles", .path = "Mozilla Firefox\\firefox.exe" },
            .{ .under = "ProgramFiles(x86)", .path = "Mozilla Firefox\\firefox.exe" },
        },
        .exe_names = &.{"firefox.exe"},
    },
    .chrome = .{
        .candidates = &.{
            .{ .under = "ProgramFiles", .path = chrome_in_dir },
            .{ .under = "ProgramFiles(x86)", .path = chrome_in_dir },
            .{ .under = "LOCALAPPDATA", .path = chrome_in_dir },
        },
        .exe_names = &.{"chrome.exe"},
    },
};

/// Starts `argv` suspended, puts it in a new kill-on-close Job Object, then lets it run, so every
/// process it starts is in the job too.
pub fn spawnGroup(io: Io, options: platform.SpawnGroupOptions) platform.SpawnError!ProcessGroup {
    _ = io;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job = win32.CreateJobObjectW(null, null) orelse return windows.unexpectedError(windows.GetLastError());
    errdefer windows.CloseHandle(job);
    var limits = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!win32.SetInformationJobObject(job, .ExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))).toBool())
        return windows.unexpectedError(windows.GetLastError());

    // The child gets its own handle to the log, on the same open file, so stdout and stderr
    // share one position.
    const output: ?HANDLE = if (options.output) |file| blk: {
        var dup: HANDLE = undefined;
        if (!win32.DuplicateHandle(windows.GetCurrentProcess(), file.handle, windows.GetCurrentProcess(), &dup, 0, .TRUE, windows.DUPLICATE_SAME_ACCESS).toBool())
            return windows.unexpectedError(windows.GetLastError());
        break :blk dup;
    } else null;
    defer if (output) |h| windows.CloseHandle(h);

    const info = try createProcess(arena, options.argv, options.environ_map, .{ .create_suspended = true, .create_unicode_environment = true }, output);
    defer windows.CloseHandle(info.hThread);
    defer windows.CloseHandle(info.hProcess);
    if (!win32.AssignProcessToJobObject(job, info.hProcess).toBool()) {
        const err = windows.GetLastError();
        _ = ntdll.NtTerminateProcess(info.hProcess, @fromBackingInt(killed_exit_code));
        return windows.unexpectedError(err);
    }
    switch (ntdll.NtResumeThread(info.hThread, null)) {
        .SUCCESS => {},
        else => |status| {
            _ = win32.TerminateJobObject(job, killed_exit_code);
            return windows.unexpectedStatus(status);
        },
    }
    return .{ .job = job, .pid = info.dwProcessId };
}

/// Engines from earlier runs that outlived their job (it should take them down with the
/// daemon, so these are rare). Caller frees.
pub fn findLeftovers(gpa: Allocator, io: Io, identity: platform.EngineIdentity) platform.FindLeftoversError![]KillTarget {
    // Without the binary there can't be an engine running it.
    _ = Io.Dir.cwd().statFile(io, identity.binary, .{}) catch return &.{};

    const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return error.CantListProcesses;
    defer windows.CloseHandle(snapshot);
    var entry: win32.PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(win32.PROCESSENTRY32W);
    if (!win32.Process32FirstW(snapshot, &entry).toBool()) return error.CantListProcesses;

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(gpa);
    const own = windows.GetCurrentProcessId();
    while (true) {
        // The snapshot names each executable: only those that may be an engine are opened.
        const pid = entry.th32ProcessID;
        const exe_name = try std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.sliceTo(&entry.szExeFile, 0));
        defer gpa.free(exe_name);
        if (pid != 0 and pid != own and isEngineExe(exe_name, identity) and try runsEngine(gpa, pid, identity))
            try matches.append(gpa, .{ .pid = pid, .parent = entry.th32ParentProcessID });
        if (!win32.Process32NextW(snapshot, &entry).toBool()) break;
    }
    const roots = try leftoversFrom(gpa, matches.items);
    defer gpa.free(roots);
    const targets = try gpa.alloc(KillTarget, roots.len);
    for (targets, roots) |*t, pid| t.* = .{ .pid = pid };
    return targets;
}

/// Whether process `pid` is an engine; false when it can't be inspected (another user's).
fn runsEngine(gpa: Allocator, pid: ProcessId, identity: platform.EngineIdentity) Allocator.Error!bool {
    const process = win32.OpenProcess(query_access, .FALSE, pid) orelse return false;
    defer windows.CloseHandle(process);

    var exe_w: [4096]u16 = undefined;
    var exe_len: DWORD = exe_w.len;
    if (!win32.QueryFullProcessImageNameW(process, 0, &exe_w, &exe_len).toBool()) return false;
    const exe = try std.unicode.wtf16LeToWtf8Alloc(gpa, exe_w[0..exe_len]);
    defer gpa.free(exe);

    // ProcessCommandLineInformation: a UNICODE_STRING followed by the characters it points to.
    var needed: windows.ULONG = 0;
    var probe: windows.UNICODE_STRING = undefined;
    switch (ntdll.NtQueryInformationProcess(process, .CommandLineInformation, &probe, @sizeOf(windows.UNICODE_STRING), &needed)) {
        .SUCCESS => return false, // An empty command line.
        .INFO_LENGTH_MISMATCH, .BUFFER_TOO_SMALL, .BUFFER_OVERFLOW => {},
        else => return false,
    }
    const buffer = try gpa.alignedAlloc(u8, .of(windows.UNICODE_STRING), needed);
    defer gpa.free(buffer);
    if (ntdll.NtQueryInformationProcess(process, .CommandLineInformation, @ptrCast(buffer.ptr), needed, null) != .SUCCESS) return false;
    const cmd_line: *const windows.UNICODE_STRING = @ptrCast(buffer.ptr);
    const chars = cmd_line.Buffer orelse return false;
    return isLeftoverEngine(gpa, exe, chars[0 .. cmd_line.Length / 2], identity);
}

const Match = struct { pid: ProcessId, parent: ProcessId };

/// The ids of the matches to kill: each one whose parent isn't a match too, since the engine's other
/// processes exit with the one that started them. The process list's parent ids can be stale
/// (the parent exited and its id was reused), so a chain of parents that loops instead of
/// ending at a match without a matching parent doesn't count: those matches are all killed.
fn leftoversFrom(gpa: Allocator, matches: []const Match) Allocator.Error![]ProcessId {
    var roots: std.ArrayList(ProcessId) = .empty;
    errdefer roots.deinit(gpa);
    for (matches) |m| {
        if (hasRootAncestor(matches, m)) continue;
        try roots.append(gpa, m.pid);
    }
    return roots.toOwnedSlice(gpa);
}

/// Whether `m`'s parent is a match, and so on up to a match whose parent isn't one, without
/// coming round in a loop.
fn hasRootAncestor(matches: []const Match, m: Match) bool {
    var current = m;
    for (0..matches.len) |_| {
        const parent = for (matches) |other| {
            if (other.pid == current.parent) break other;
        } else return current.pid != m.pid;
        if (parent.pid == m.pid) return false;
        current = parent;
    }
    return false;
}

/// A leftover engine process whose parent isn't a match too (there are no process groups).
pub const KillTarget = struct {
    pid: ProcessId,

    pub fn format(t: KillTarget, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("process {d}", .{t.pid});
    }
};

/// Ends a leftover engine found by `findLeftovers` and waits up to 2 s for it to go.
pub fn killLeftover(io: Io, target: KillTarget) void {
    _ = io;
    const process = win32.OpenProcess(.{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .PROCESS = .{ .TERMINATE = true } },
    }, .FALSE, target.pid) orelse return;
    defer windows.CloseHandle(process);
    _ = ntdll.NtTerminateProcess(process, @fromBackingInt(killed_exit_code));
    const two_seconds: windows.LARGE_INTEGER = -2 * std.time.ns_per_s / 100; // Relative, in 100 ns.
    _ = ntdll.NtWaitForSingleObject(process, .FALSE, &two_seconds);
}

/// The lock is the open file itself: opened for writing and shared for reading only, so a
/// second daemon's open fails with a sharing violation while a reader can still see who holds
/// it. Windows closes it when the process dies, however it dies. The file keeps the ACL it
/// inherits.
pub fn lockFile(io: Io, path: []const u8, contents: []const u8) platform.LockFileError!Io.File {
    const path_w = win32Path(std.heap.page_allocator, path) catch |e| return switch (e) {
        error.OutOfMemory => error.SystemResources,
        error.InvalidWtf8 => error.BadPathName,
    };
    defer std.heap.page_allocator.free(path_w);
    // CREATE_ALWAYS truncates, but only once the open got past the sharing check.
    const handle = win32.CreateFileW(path_w, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{ .READ = true, .WRITE = true },
    }, .{ .READ = true }, null, .CREATE_ALWAYS, .{ .NORMAL = true }, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (windows.GetLastError()) {
        .SHARING_VIOLATION => error.Locked,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        else => |err| windows.unexpectedError(err),
    };
    const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    errdefer file.close(io);
    try file.writePositionalAll(io, contents, 0);
    return file;
}

/// The daemon holds the file shared for reading only, so asking for write access fails while it
/// runs. Opens an existing file only, and changes nothing.
pub fn lockHeld(io: Io, path: []const u8) bool {
    _ = io;
    const path_w = win32Path(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(path_w);
    const handle = win32.CreateFileW(path_w, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{ .WRITE = true },
    }, .{ .READ = true, .WRITE = true }, null, .OPEN_EXISTING, .{ .NORMAL = true }, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return windows.GetLastError() == .SHARING_VIOLATION;
    windows.CloseHandle(handle);
    return false;
}

// ---- Shutdown and detaching ----

/// A console control event, by its `CTRL_*_EVENT` value (wincon.h), or none yet.
const ConsoleEvent = enum(u8) {
    ctrl_c = 0,
    ctrl_break = 1,
    close = 2,
    logoff = 5,
    shutdown = 6,
    none = 0xff,
    _,

    fn name(e: ConsoleEvent) ?[]const u8 {
        return switch (e) {
            .ctrl_c => "Ctrl-C",
            .ctrl_break => "Ctrl-Break",
            .close => "console closed",
            .logoff => "logoff",
            .shutdown => "shutdown",
            .none => null,
            _ => "console event",
        };
    }
};

var shutdown_event: std.atomic.Value(ConsoleEvent) = .init(.none);

fn onConsoleEvent(ctrl_type: DWORD) callconv(.winapi) BOOL {
    const event: ConsoleEvent = switch (ctrl_type) {
        0, 1, 2, 5, 6 => @fromBackingInt(@intCast(ctrl_type)),
        else => return .FALSE,
    };
    shutdown_event.store(event, .release);
    // After close, logoff and shutdown, Windows ends the process as soon as this handler
    // returns. Hold it (this is its own thread) while the daemon closes the engine and exits;
    // Windows gives up waiting after about 5 s anyway (HandlerRoutine's "Timeouts",
    // https://learn.microsoft.com/en-us/windows/console/handlerroutine).
    switch (event) {
        .close, .logoff, .shutdown => {
            const ten_seconds: windows.LARGE_INTEGER = -10 * std.time.ns_per_s / 100;
            _ = ntdll.NtDelayExecution(.FALSE, &ten_seconds);
        },
        else => {},
    }
    return .TRUE;
}

/// Console control events (Ctrl-C, Ctrl-Break, the console closing, logoff, shutdown) set a
/// flag that `shutdownRequested` reports, like SIGTERM on POSIX; the daemon polls it.
pub fn installShutdownHandlers() void {
    _ = win32.SetConsoleCtrlHandler(onConsoleEvent, .TRUE);
}

pub fn shutdownRequested() ?[]const u8 {
    return shutdown_event.load(.acquire).name();
}

/// Nothing to do: `spawnDetached` already gives the daemon a console of its own.
pub fn detachFromTerminal() void {}

/// Starts `argv` in the background with its own hidden console (CREATE_NO_WINDOW): no window,
/// no Ctrl-C from the user's terminal, and closing that terminal doesn't end it. It also leaves
/// the caller's Job Object where that's allowed, since some terminals and SSH sessions kill
/// their job when they close. stdout and stderr are appended to `log_path`.
pub fn spawnDetached(io: Io, argv: []const []const u8, log_path: []const u8) platform.SpawnDetachedError!void {
    _ = io;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const log_path_w = win32Path(arena, log_path) catch return error.CantOpenLog;
    var inheritable: windows.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
    // Append-only access: every write lands at the end, whoever else writes the file.
    const log = win32.CreateFileW(log_path_w, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .SPECIFIC = .{ .FILE = .{ .APPEND_DATA = true } },
    }, .VALID_FLAGS, &inheritable, .OPEN_ALWAYS, .{ .NORMAL = true }, null);
    if (log == windows.INVALID_HANDLE_VALUE) return error.CantOpenLog;
    defer windows.CloseHandle(log);

    var flags: windows.CreateProcessFlags = .{ .create_no_window = true, .create_breakaway_from_job = true };
    const info = createProcess(arena, argv, null, flags, log) catch |e| switch (e) {
        // The caller's job doesn't allow breaking away: stay in it.
        error.AccessDenied => retry: {
            flags.create_breakaway_from_job = false;
            break :retry try createProcess(arena, argv, null, flags, log);
        },
        else => return e,
    };
    windows.CloseHandle(info.hThread);
    windows.CloseHandle(info.hProcess);
}

/// `CreateProcessW` for an absolute `argv[0]`, with stdin closed and stdout/stderr on `output`
/// (inheritable), which is the only handle the child inherits. (`std.process.spawn` lets the
/// child inherit every inheritable handle, such as a pipe the CLI's own output goes to, which a
/// long-lived daemon would then hold open.) `environ_map` null inherits ours.
fn createProcess(arena: Allocator, argv: []const []const u8, environ_map: ?*const Environ.Map, flags: windows.CreateProcessFlags, output: ?HANDLE) platform.SpawnError!windows.PROCESS.INFORMATION {
    const app = try std.unicode.wtf8ToWtf16LeAllocZ(arena, argv[0]);
    const cmd_line = try std.unicode.wtf8ToWtf16LeAllocZ(arena, commandLine(arena, argv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArg0 => return error.FileNotFound,
    });
    const env_block: ?Environ.WindowsBlock = if (environ_map) |map| try map.createWindowsBlock(arena, .{}) else null;

    var startup: win32.STARTUPINFOEXW = .{ .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW), .lpAttributeList = null };
    startup.StartupInfo.cb = @sizeOf(windows.STARTUPINFOW);
    startup.StartupInfo.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdOutput = output;
    startup.StartupInfo.hStdError = output;
    var with_flags = flags;
    var handle_list: [1]HANDLE = undefined;
    if (output) |h| {
        handle_list[0] = h;
        var size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &size);
        const list: *anyopaque = @ptrCast((try arena.alignedAlloc(u8, .of(usize), size)).ptr);
        if (!win32.InitializeProcThreadAttributeList(list, 1, 0, &size).toBool()) return windows.unexpectedError(windows.GetLastError());
        startup.lpAttributeList = list;
        if (!win32.UpdateProcThreadAttribute(list, 0, win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handle_list, @sizeOf(@TypeOf(handle_list)), null, null).toBool()) {
            win32.DeleteProcThreadAttributeList(list);
            return windows.unexpectedError(windows.GetLastError());
        }
        with_flags.extended_startupinfo_present = true;
        startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
    }
    defer if (startup.lpAttributeList) |list| win32.DeleteProcThreadAttributeList(list);

    var info: windows.PROCESS.INFORMATION = undefined;
    if (!windows.kernel32.CreateProcessW(
        app,
        cmd_line,
        null,
        null,
        .fromBool(output != null),
        with_flags,
        if (env_block) |block| block.slice.ptr else null,
        null,
        &startup.StartupInfo,
        &info,
    ).toBool()) return switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .DIRECTORY => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH => error.InvalidExe,
        .NOT_ENOUGH_MEMORY, .COMMITMENT_LIMIT => error.SystemResources,
        else => |err| windows.unexpectedError(err),
    };
    return info;
}

// ---- Playback (#6): sign-in in the user's browser, footprint, free memory ----

/// Opens `url` in the user's default browser through the shell (ShellExecuteW), which never
/// passes it through cmd.exe, so `&`, `^` and `%` in it need no quoting. Only http(s) URLs:
/// the shell would run or open anything else.
///
/// shell32 and ole32 are loaded here, not linked: they load user32, and "if a console
/// application loads the gdi32.dll or user32.dll library, the HandlerRoutine function [...] does
/// not get called for the CTRL_LOGOFF_EVENT and CTRL_SHUTDOWN_EVENT events"
/// (https://learn.microsoft.com/en-us/windows/console/setconsolectrlhandler). Linked, they would
/// load into every `am` process, the daemon included; the CLI is the one that opens URLs.
/// (HandlerRoutine's own page says those two events reach only services anyway:
/// https://learn.microsoft.com/en-us/windows/console/handlerroutine.)
pub fn openUrl(io: Io, url: []const u8) platform.OpenUrlError!void {
    _ = io;
    // Refused like a file we may not run.
    if (!isWebUrl(url)) return error.AccessDenied;
    const gpa = std.heap.page_allocator;
    const url_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, url);
    defer gpa.free(url_w);
    const shellExecute = loadProc(win32.ShellExecuteW, "shell32.dll", "ShellExecuteW") orelse return error.FileNotFound;
    // The shell may hand the URL to a COM handler. S_OK and S_FALSE (COM was already set up on
    // this thread) are balanced by CoUninitialize; RPC_E_CHANGED_MODE (negative) is not.
    const initialized = if (loadProc(win32.CoInitializeEx, "ole32.dll", "CoInitializeEx")) |coInitializeEx|
        coInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE) >= 0
    else
        false;
    defer if (initialized) if (loadProc(win32.CoUninitialize, "ole32.dll", "CoUninitialize")) |coUninitialize| coUninitialize();
    const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
    // Above 32 is success; below, an SE_ERR_* code (shellapi.h).
    return switch (@intFromPtr(shellExecute(null, open, url_w, null, null, win32.SW_SHOWNORMAL))) {
        33...std.math.maxInt(usize) => {},
        0, 8 => error.SystemResources, // Out of memory or resources.
        // File or path not found, no or an incomplete association, a DLL not found.
        2, 3, 27, 31, 32 => error.FileNotFound,
        5 => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// `name` from the DLL `dll` (loaded if it isn't yet, and kept), as a `T` function pointer.
fn loadProc(comptime T: type, comptime dll: []const u8, name: []const u8) ?T {
    var module: windows.PVOID = undefined;
    const dll_w = std.unicode.utf8ToUtf16LeStringLiteral(dll);
    if (ntdll.LdrLoadDll(null, null, &.init(dll_w), &module) != .SUCCESS) return null;
    var proc: windows.PVOID = undefined;
    if (ntdll.LdrGetProcedureAddress(module, &.init(name), 0, &proc) != .SUCCESS) return null;
    return @ptrCast(@alignCast(proc));
}

/// Starts with `http://` or `https://` and has something after it.
fn isWebUrl(url: []const u8) bool {
    for ([_][]const u8{ "http://", "https://" }) |scheme| {
        if (url.len > scheme.len and std.ascii.startsWithIgnoreCase(url, scheme)) return true;
    }
    return false;
}

/// Every process in the engine's job, which holds everything the engine started. Empty once
/// the job is closed. Caller frees.
pub fn processTree(gpa: Allocator, io: Io, group: *const ProcessGroup) platform.ProcessTreeError![]ProcessId {
    _ = io;
    const job = group.job orelse return gpa.alloc(ProcessId, 0);
    // Room for the engine's processes (a dozen or two); grown when the job has more.
    var capacity: usize = 64;
    while (true) {
        const buffer = try allocProcessIdList(gpa, capacity);
        defer gpa.free(buffer);
        const size = buffer.len;
        const list: *win32.JOBOBJECT_BASIC_PROCESS_ID_LIST = @ptrCast(buffer.ptr);
        if (win32.QueryInformationJobObject(job, .BasicProcessIdList, buffer.ptr, @intCast(size), null).toBool()) {
            const pids = try gpa.alloc(ProcessId, list.NumberOfProcessIdsInList);
            for (pids, list.ids()[0..pids.len]) |*pid, id| pid.* = @intCast(id);
            return pids;
        }
        if (windows.GetLastError() != .MORE_DATA) return error.CantListProcesses;
        capacity = @max(capacity * 2, list.NumberOfAssignedProcesses + 16);
    }
}

/// Room for a JOBOBJECT_BASIC_PROCESS_ID_LIST with `capacity` ids, aligned for the ids (the
/// header alone only needs 4 bytes).
fn allocProcessIdList(gpa: Allocator, capacity: usize) Allocator.Error![]align(@alignOf(usize)) u8 {
    return gpa.alignedAlloc(u8, .of(usize), @sizeOf(win32.JOBOBJECT_BASIC_PROCESS_ID_LIST) + capacity * @sizeOf(usize));
}

/// The private working set (memory only this process uses, in RAM: Task Manager's "Memory"),
/// or the whole working set (`.rss`) on Windows versions that don't report it, and CPU time
/// from `GetProcessTimes`.
pub fn processUsage(io: Io, pid: ProcessId) platform.ProcessUsageError!platform.ProcessUsage {
    _ = io;
    const process = win32.OpenProcess(query_access, .FALSE, pid) orelse return error.CantReadProcess;
    defer windows.CloseHandle(process);

    var counters = std.mem.zeroes(win32.PROCESS_MEMORY_COUNTERS_EX2);
    counters.cb = @sizeOf(win32.PROCESS_MEMORY_COUNTERS_EX2);
    if (!win32.K32GetProcessMemoryInfo(process, &counters, counters.cb).toBool()) {
        // Before PROCESS_MEMORY_COUNTERS_EX2: the struct it extends, without the private part.
        counters = std.mem.zeroes(win32.PROCESS_MEMORY_COUNTERS_EX2);
        counters.cb = @offsetOf(win32.PROCESS_MEMORY_COUNTERS_EX2, "PrivateUsage");
        if (!win32.K32GetProcessMemoryInfo(process, &counters, counters.cb).toBool()) return error.CantReadProcess;
    }
    const private = counters.PrivateWorkingSetSize != 0;

    var created: windows.FILETIME = undefined;
    var exited: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (!win32.GetProcessTimes(process, &created, &exited, &kernel, &user).toBool()) return error.CantReadProcess;
    return .{
        .memory_bytes = if (private) counters.PrivateWorkingSetSize else counters.WorkingSetSize,
        .memory = if (private) .private_working_set else .rss,
        .cpu_ns = (fileTimeTicks(kernel) + fileTimeTicks(user)) * 100,
    };
}

/// A FILETIME duration in 100 ns ticks.
fn fileTimeTicks(t: windows.FILETIME) u64 {
    return @as(u64, t.dwHighDateTime) << 32 | t.dwLowDateTime;
}

/// Physical memory available without paging (`GlobalMemoryStatusEx`'s `ullAvailPhys`).
pub fn availableMemory(io: Io) platform.AvailableMemoryError!u64 {
    _ = io;
    var status: win32.MEMORYSTATUSEX = undefined;
    status.dwLength = @sizeOf(win32.MEMORYSTATUSEX);
    if (!win32.GlobalMemoryStatusEx(&status).toBool()) return error.CantReadMemory;
    return status.ullAvailPhys;
}

/// No check on Windows (the PipeWire check is Linux only).
pub fn engineAudio(arena: Allocator, io: Io, pids: []const ProcessId) Allocator.Error!platform.EngineAudio {
    _ = arena;
    _ = io;
    _ = pids;
    return .{ .unsupported = "not checked on Windows" };
}

/// What std.os.windows doesn't declare, from the Windows SDK headers named.
const win32 = struct {
    // jobapi2.h, winnt.h
    extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES, lpName: ?windows.LPCWSTR) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: JOBOBJECTINFOCLASS, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryInformationJobObject(hJob: ?HANDLE, JobObjectInformationClass: JOBOBJECTINFOCLASS, lpJobObjectInformation: *anyopaque, cbJobObjectInformationLength: DWORD, lpReturnLength: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: windows.UINT) callconv(.winapi) BOOL;

    const JOBOBJECTINFOCLASS = enum(c_int) {
        BasicAccountingInformation = 1,
        BasicProcessIdList = 3,
        ExtendedLimitInformation = 9,
        _,
    };
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x2000;

    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: windows.LARGE_INTEGER,
        PerJobUserTimeLimit: windows.LARGE_INTEGER,
        LimitFlags: DWORD,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: DWORD,
        Affinity: usize,
        PriorityClass: DWORD,
        SchedulingClass: DWORD,
    };
    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };
    const JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = extern struct {
        TotalUserTime: windows.LARGE_INTEGER,
        TotalKernelTime: windows.LARGE_INTEGER,
        ThisPeriodTotalUserTime: windows.LARGE_INTEGER,
        ThisPeriodTotalKernelTime: windows.LARGE_INTEGER,
        TotalPageFaultCount: DWORD,
        TotalProcesses: DWORD,
        ActiveProcesses: DWORD,
        TotalTerminatedProcesses: DWORD,
    };

    // consoleapi.h, wincon.h
    extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?*const fn (DWORD) callconv(.winapi) BOOL, Add: BOOL) callconv(.winapi) BOOL;

    // tlhelp32.h
    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    const TH32CS_SNAPPROCESS: DWORD = 0x2;
    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD,
        cntUsage: DWORD,
        th32ProcessID: DWORD,
        th32DefaultHeapID: usize,
        th32ModuleID: DWORD,
        cntThreads: DWORD,
        th32ParentProcessID: DWORD,
        pcPriClassBase: windows.LONG,
        dwFlags: DWORD,
        szExeFile: [windows.MAX_PATH]u16,
    };

    // processthreadsapi.h, winbase.h, handleapi.h, fileapi.h
    extern "kernel32" fn OpenProcess(dwDesiredAccess: windows.ACCESS_MASK, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn DuplicateHandle(hSourceProcessHandle: HANDLE, hSourceHandle: HANDLE, hTargetProcessHandle: HANDLE, lpTargetHandle: *HANDLE, dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwOptions: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(lpFileName: windows.LPCWSTR, dwDesiredAccess: windows.ACCESS_MASK, dwShareMode: windows.FILE.SHARE, lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES, dwCreationDisposition: CreationDisposition, dwFlagsAndAttributes: windows.FILE.ATTRIBUTE, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
    /// Win32's values, not the NT ones of `windows.FILE.CREATE_DISPOSITION`.
    const CreationDisposition = enum(DWORD) {
        CREATE_ALWAYS = 2,
        OPEN_EXISTING = 3,
        OPEN_ALWAYS = 4,
        _,
    };

    extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, Attribute: usize, lpValue: *const anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
    const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x20002;
    const STARTUPINFOEXW = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };

    /// Followed by `ProcessIdList`, as many ULONG_PTRs as fit the buffer.
    const JOBOBJECT_BASIC_PROCESS_ID_LIST = extern struct {
        NumberOfAssignedProcesses: DWORD,
        NumberOfProcessIdsInList: DWORD,

        fn ids(list: *JOBOBJECT_BASIC_PROCESS_ID_LIST) [*]usize {
            return @ptrCast(@alignCast(@as([*]u8, @ptrCast(list)) + @sizeOf(JOBOBJECT_BASIC_PROCESS_ID_LIST)));
        }
    };

    // psapi.h (exported by kernel32 as K32*), sysinfoapi.h
    extern "kernel32" fn K32GetProcessMemoryInfo(Process: HANDLE, ppsmemCounters: *PROCESS_MEMORY_COUNTERS_EX2, cb: DWORD) callconv(.winapi) BOOL;
    /// Windows 10/11 22H2 with the September 2023 update and later know it
    /// (https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex2).
    const PROCESS_MEMORY_COUNTERS_EX2 = extern struct {
        cb: DWORD,
        PageFaultCount: DWORD,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
        PrivateUsage: usize,
        PrivateWorkingSetSize: usize,
        SharedCommitUsage: u64,
    };
    extern "kernel32" fn GetProcessTimes(hProcess: HANDLE, lpCreationTime: *windows.FILETIME, lpExitTime: *windows.FILETIME, lpKernelTime: *windows.FILETIME, lpUserTime: *windows.FILETIME) callconv(.winapi) BOOL;
    extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
    const MEMORYSTATUSEX = extern struct {
        dwLength: DWORD,
        dwMemoryLoad: DWORD,
        ullTotalPhys: u64,
        ullAvailPhys: u64,
        ullTotalPageFile: u64,
        ullAvailPageFile: u64,
        ullTotalVirtual: u64,
        ullAvailVirtual: u64,
        ullAvailExtendedVirtual: u64,
    };

    // shellapi.h, combaseapi.h, objbase.h, winuser.h: loaded at run time (see `openUrl`).
    const ShellExecuteW = *const fn (hwnd: ?windows.HWND, lpOperation: ?windows.LPCWSTR, lpFile: windows.LPCWSTR, lpParameters: ?windows.LPCWSTR, lpDirectory: ?windows.LPCWSTR, nShowCmd: c_int) callconv(.winapi) ?windows.HINSTANCE;
    const SW_SHOWNORMAL: c_int = 1;
    /// Returns an HRESULT.
    const CoInitializeEx = *const fn (pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) windows.LONG;
    const CoUninitialize = *const fn () callconv(.winapi) void;
    const COINIT_APARTMENTTHREADED: DWORD = 0x2;
    const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;

    comptime {
        // Sizes the SDK documents for 64-bit Windows.
        if (@sizeOf(usize) == 8) {
            std.debug.assert(@sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144);
            std.debug.assert(@sizeOf(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION) == 48);
            std.debug.assert(@sizeOf(PROCESSENTRY32W) == 568);
            std.debug.assert(@sizeOf(PROCESS_MEMORY_COUNTERS_EX2) == 96);
            std.debug.assert(@sizeOf(MEMORYSTATUSEX) == 64);
        }
    }
};

// ---- Paths ----

/// `path` as the NUL-terminated WTF-16 that Win32 file functions take. A drive-absolute path
/// gets the `\\?\` prefix, which lifts the 260-character MAX_PATH limit; that prefix also turns
/// off Windows' own clean-up of the path, so it is resolved here first (`/` to `\`, `.` and `..`
/// components). Caller frees.
pub fn win32Path(gpa: Allocator, path: []const u8) (Allocator.Error || error{InvalidWtf8})![:0]u16 {
    const resolved = try Io.Dir.path.resolveAllocWindows(gpa, &.{path});
    defer gpa.free(resolved);
    const drive_absolute = resolved.len >= 3 and std.ascii.isAlphabetic(resolved[0]) and resolved[1] == ':' and resolved[2] == '\\';
    const prefixed = if (drive_absolute) try std.mem.concat(gpa, u8, &.{ "\\\\?\\", resolved }) else try gpa.dupe(u8, resolved);
    defer gpa.free(prefixed);
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, prefixed);
}

// ---- Command lines ----

pub const CommandLineError = Allocator.Error || error{
    /// Double quotes can't be in a program path (Windows forbids them in file names).
    InvalidArg0,
};

/// Joins `argv` into the command line `CreateProcessW` takes, quoted so that the C runtime's
/// parser (which Firefox, Chrome and `am` itself use) splits it back into the same arguments.
/// The same rules as std's own (private) serializer for `std.process.spawn`. WTF-8 in and out.
pub fn commandLine(gpa: Allocator, argv: []const []const u8) CommandLineError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(gpa, ' ');
        const needs_quotes = arg.len == 0 or for (arg) |c| {
            if (c <= ' ' or c == '"') break true;
        } else false;
        if (i == 0) {
            // The program name ends at the next space or quote; backslashes mean nothing in it.
            if (std.mem.findScalar(u8, arg, '"') != null) return error.InvalidArg0;
            if (needs_quotes) try out.append(gpa, '"');
            try out.appendSlice(gpa, arg);
            if (needs_quotes) try out.append(gpa, '"');
            continue;
        }
        if (!needs_quotes) {
            try out.appendSlice(gpa, arg);
            continue;
        }
        // Inside quotes, backslashes are literal unless they precede a quote: double those, and
        // escape the quote itself. Trailing ones precede the closing quote.
        try out.append(gpa, '"');
        var backslashes: usize = 0;
        for (arg) |c| switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                try out.appendNTimes(gpa, '\\', backslashes * 2 + 1);
                try out.append(gpa, '"');
                backslashes = 0;
            },
            else => {
                try out.appendNTimes(gpa, '\\', backslashes);
                try out.append(gpa, c);
                backslashes = 0;
            },
        };
        try out.appendNTimes(gpa, '\\', backslashes * 2);
        try out.append(gpa, '"');
    }
    return out.toOwnedSlice(gpa);
}

/// An engine names our profile on its command line, either as its own argument (Firefox's
/// `--profile <dir>`) or after `=` (Chrome's `--user-data-dir=<dir>`), and runs our engine
/// binary or a file named like it. Paths and names compare without regard to case, as Windows
/// does. `exe` is WTF-8, `cmd_line` the process's WTF-16 command line.
pub fn isLeftoverEngine(gpa: Allocator, exe: []const u8, cmd_line: []const u16, identity: platform.EngineIdentity) Allocator.Error!bool {
    if (!eql(exe, identity.binary) and !isEngineExe(Io.Dir.path.basenameWindows(exe), identity)) return false;
    var args: std.process.Args.Iterator.Windows = try .init(gpa, cmd_line);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (eql(arg, identity.profile)) return true;
        const eq = std.mem.findScalar(u8, arg, '=') orelse continue;
        if (eql(arg[eq + 1 ..], identity.profile)) return true;
    }
    return false;
}

/// Whether an executable's file name is our binary's or one of the browser's.
fn isEngineExe(exe_name: []const u8, identity: platform.EngineIdentity) bool {
    if (eql(exe_name, Io.Dir.path.basenameWindows(identity.binary))) return true;
    for (identity.exe_names) |name| if (eql(exe_name, name)) return true;
    return false;
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

test "the config dir is AM_CONFIG_DIR, else %APPDATA%\\am" {
    try expectConfigDir("D:\\am", &.{ .{ "AM_CONFIG_DIR", "D:\\am" }, .{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming" } });
    try expectConfigDir("C:\\Users\\u\\AppData\\Roaming\\am", &.{.{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming" }});
    try expectConfigDir("C:\\Users\\u\\AppData\\Roaming\\am", &.{.{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming\\" }});
    // Empty means unset.
    try expectConfigDir("C:\\Users\\u\\AppData\\Roaming\\am", &.{ .{ "AM_CONFIG_DIR", "" }, .{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming" } });
}

test "without APPDATA there is no default config dir" {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectError(error.NoHomeDir, configDir(testing.allocator, &environ));
    try environ.put("APPDATA", "relative\\dir");
    try testing.expectError(error.NoHomeDir, configDir(testing.allocator, &environ));
}

test "the home directory is %USERPROFILE%" {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(null, homeDir(&environ));
    try environ.put("USERPROFILE", "C:\\Users\\u");
    try testing.expectEqualStrings("C:\\Users\\u", homeDir(&environ).?);
}

/// Parses a command line the way the C runtime does, with std's parser (an independent
/// implementation of the rules `commandLine` follows).
fn parseCommandLineForTest(arena: Allocator, cmd_line: []const u8) ![]const []const u8 {
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, cmd_line);
    var it: std.process.Args.Iterator.Windows = try .init(arena, wide);
    var args: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| try args.append(arena, try arena.dupe(u8, arg));
    return args.items;
}

test "argv becomes a command line the C runtime splits back into the same arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "\"C:\\Program Files\\Mozilla Firefox\\firefox.exe\" --profile \"C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile\" http://localhost:47823/?engine=ab&c=1",
        try commandLine(a, &.{ "C:\\Program Files\\Mozilla Firefox\\firefox.exe", "--profile", "C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile", "http://localhost:47823/?engine=ab&c=1" }),
    );
    // Quotes are escaped, backslashes doubled only before a quote, and an empty argument kept.
    try testing.expectEqualStrings("C:\\am.exe \"a \\\"b\\\"\" \"\" \"my dir\\\\\" dir\\ x\\y", try commandLine(a, &.{ "C:\\am.exe", "a \"b\"", "", "my dir\\", "dir\\", "x\\y" }));

    const cases = [_][]const []const u8{
        &.{ "C:\\am.exe", "daemon", "--detach" },
        &.{ "C:\\Program Files\\am\\am.exe", "tab\there", "back\\\\\"slash", "trailing\\\\", "\\\"", "ü ✓" },
        &.{ "C:\\x.exe", "--user-data-dir=C:\\Users\\Jo Doe\\am\\chrome-profile", "\"\"", "a\\\\b c" },
    };
    for (cases) |argv| try testing.expectEqualDeep(argv, try parseCommandLineForTest(a, try commandLine(a, argv)));

    try testing.expectError(error.InvalidArg0, commandLine(a, &.{"C:\\a\"b.exe"}));
}

fn expectLeftover(expected: bool, exe: []const u8, cmd_line: []const u8, binary: []const u8, profile: []const u8) !void {
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(testing.allocator, cmd_line);
    defer testing.allocator.free(wide);
    const identity: platform.EngineIdentity = .{ .binary = binary, .profile = profile, .exe_names = &.{ "firefox.exe", "chrome.exe" } };
    try testing.expectEqual(expected, try isLeftoverEngine(testing.allocator, exe, wide, identity));
}

test "an engine is our binary with our profile as an argument or after =, in any letter case" {
    const firefox = "C:\\Program Files\\Mozilla Firefox\\firefox.exe";
    const firefox_profile = "C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile";
    try expectLeftover(true, firefox, "\"C:\\Program Files\\Mozilla Firefox\\firefox.exe\" --new-instance --profile \"C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile\" --headless http://localhost:47823/?engine=abc", firefox, firefox_profile);
    // Windows paths ignore case: the process list may spell them differently than we did.
    try expectLeftover(true, "C:\\PROGRAM FILES\\Mozilla Firefox\\FIREFOX.EXE", "firefox.exe --profile \"c:\\users\\jo doe\\appdata\\roaming\\am\\firefox-profile\"", firefox, firefox_profile);

    const chrome = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
    const chrome_profile = "C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\chrome-profile";
    try expectLeftover(true, chrome, "\"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe\" \"--user-data-dir=C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\chrome-profile\" --headless", chrome, chrome_profile);

    // The user's own browser: same binary, another profile (or one that merely shares a prefix).
    try expectLeftover(false, chrome, "chrome.exe --user-data-dir=C:\\Users\\Jo\\AppData\\Local\\Google\\Chrome\\User Data", chrome, chrome_profile);
    try expectLeftover(false, chrome, "chrome.exe \"--user-data-dir=C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\chrome-profile2\"", chrome, chrome_profile);
    try expectLeftover(false, chrome, "chrome.exe \"--x=D:\\C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\chrome-profile\"", chrome, chrome_profile);
    try expectLeftover(false, firefox, "firefox.exe -contentproc 1234 tab", firefox, firefox_profile);
    // The program name itself never counts as the profile argument.
    try expectLeftover(false, firefox, "\"C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile\"", firefox, firefox_profile);
    // The browser from another install (an update moved it, FIREFOX_PATH changed).
    try expectLeftover(true, "D:\\Apps\\Firefox\\firefox.exe", "firefox.exe --profile \"C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile\"", firefox, firefox_profile);
    // Another program that happens to name our profile, like `dir` on it.
    try expectLeftover(false, "C:\\Windows\\System32\\cmd.exe", "cmd.exe /c dir \"C:\\Users\\Jo Doe\\AppData\\Roaming\\am\\firefox-profile\"", firefox, firefox_profile);
}

test "a Win32 path is resolved, and a drive-absolute one gets the \\\\?\\ prefix that lifts MAX_PATH" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "C:\\Users\\u\\AppData\\Roaming\\am\\daemon.lock", "\\\\?\\C:\\Users\\u\\AppData\\Roaming\\am\\daemon.lock" },
        // The prefix turns off Windows' own clean-up, so `/`, `.` and `..` are resolved first.
        .{ "C:/am/./x/../daemon.log", "\\\\?\\C:\\am\\daemon.log" },
        // UNC and relative paths are left to Windows.
        .{ "\\\\server\\share\\am\\daemon.log", "\\\\server\\share\\am\\daemon.log" },
        .{ "am\\daemon.log", "am\\daemon.log" },
    };
    for (cases) |case| {
        const got = try win32Path(gpa, case[0]);
        defer gpa.free(got);
        const want = try std.unicode.wtf8ToWtf16LeAlloc(gpa, case[1]);
        defer gpa.free(want);
        try testing.expectEqualSlices(u16, want, got);
    }
    // Longer than MAX_PATH: the prefix is what makes it usable.
    const dir: [300]u8 = @splat('a');
    const long = try std.mem.concat(gpa, u8, &.{ "C:\\", &dir, "\\daemon.lock" });
    defer gpa.free(long);
    const long_w = try win32Path(gpa, long);
    defer gpa.free(long_w);
    try testing.expect(std.mem.startsWith(u16, long_w, std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\")));
}

test "a process id list's ids are aligned even when the allocator hands out memory at 4 mod 8" {
    // A fixed buffer that starts 4 bytes past an 8-byte boundary: an allocation that only asks
    // for 4-byte alignment lands there.
    var backing: [256]u8 align(8) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(backing[4..]);
    const buffer = try allocProcessIdList(fba.allocator(), 4);
    const list: *win32.JOBOBJECT_BASIC_PROCESS_ID_LIST = @ptrCast(buffer.ptr);
    list.ids()[0] = 42;
    try testing.expectEqual(@as(usize, 42), list.ids()[0]);
}

test "only http and https URLs are handed to the shell" {
    try testing.expect(isWebUrl("http://localhost:47823/signin"));
    try testing.expect(isWebUrl("HTTPS://example.com/?a=1&b=%PATH%"));
    // ShellExecute would run a program or open a file for these.
    try testing.expect(!isWebUrl("C:\\Windows\\System32\\calc.exe"));
    try testing.expect(!isWebUrl("file:///C:/x.bat"));
    try testing.expect(!isWebUrl("http:"));
    try testing.expect(!isWebUrl("ms-settings:"));
}

test "a leftover is killed unless its parent is a leftover too, and a loop of stale parent ids kills them all" {
    const gpa = testing.allocator;
    // Chrome: the browser (started by a long-gone daemon, 4) and two helpers it started.
    const chrome = try leftoversFrom(gpa, &.{ .{ .pid = 10, .parent = 4 }, .{ .pid = 11, .parent = 10 }, .{ .pid = 12, .parent = 11 } });
    defer gpa.free(chrome);
    try testing.expectEqualSlices(ProcessId, &.{10}, chrome);

    // Two engines from separate runs: both are roots.
    const two = try leftoversFrom(gpa, &.{ .{ .pid = 20, .parent = 1 }, .{ .pid = 30, .parent = 2 }, .{ .pid = 31, .parent = 30 } });
    defer gpa.free(two);
    try testing.expectEqualSlices(ProcessId, &.{ 20, 30 }, two);

    // Reused ids: 40's parent is 41 and 41's is 40. Neither leads to a root, so both go.
    const loop = try leftoversFrom(gpa, &.{ .{ .pid = 40, .parent = 41 }, .{ .pid = 41, .parent = 40 }, .{ .pid = 50, .parent = 50 } });
    defer gpa.free(loop);
    try testing.expectEqualSlices(ProcessId, &.{ 40, 41, 50 }, loop);
}

test "Windows looks for the browsers under %ProgramFiles%, then the 32-bit and per-user installs" {
    try testing.expectEqualDeep(@as([]const platform.Candidate, &.{
        .{ .under = "ProgramFiles", .path = "Mozilla Firefox\\firefox.exe" },
        .{ .under = "ProgramFiles(x86)", .path = "Mozilla Firefox\\firefox.exe" },
    }), browsers.firefox.candidates);
    try testing.expectEqualDeep(@as([]const platform.Candidate, &.{
        .{ .under = "ProgramFiles", .path = "Google\\Chrome\\Application\\chrome.exe" },
        .{ .under = "ProgramFiles(x86)", .path = "Google\\Chrome\\Application\\chrome.exe" },
        .{ .under = "LOCALAPPDATA", .path = "Google\\Chrome\\Application\\chrome.exe" },
    }), browsers.chrome.candidates);
}

// ---- On Windows only: the real processes ----

/// This process's environment: Winsock needs `SystemRoot` in a child's.
fn testEnviron() !Environ.Map {
    return testing.environ.createMap(testing.allocator);
}

/// `<System32>\<name>`. Caller frees.
fn systemProgram(gpa: Allocator, name: []const u8) ![]u8 {
    const dir = try std.unicode.wtf16LeToWtf8Alloc(gpa, windows.getSystemDirectoryWtf16Le());
    defer gpa.free(dir);
    return std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, dir, "\\"), "\\", name });
}

test "killing a job takes down every process in it, even after the first one exited" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    const cmd = try systemProgram(testing.allocator, "cmd.exe");
    defer testing.allocator.free(cmd);

    // Like Firefox's launcher: the first process starts another and exits.
    var forked = try spawnGroup(io, .{ .argv = &.{ cmd, "/d", "/c", "start /b ping -n 30 127.0.0.1 >nul" }, .environ_map = &environ });
    try io.sleep(.fromMilliseconds(500), .awake);
    try testing.expect(forked.alive());
    forked.kill(io);
    try testing.expect(!forked.alive());
}

test "a process that exits on its own leaves no live job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    const cmd = try systemProgram(testing.allocator, "cmd.exe");
    defer testing.allocator.free(cmd);
    var group = try spawnGroup(io, .{ .argv = &.{ cmd, "/d", "/c", "exit 0" }, .environ_map = &environ });
    defer group.kill(io);
    var tries: usize = 0;
    while (group.alive() and tries < 100) : (tries += 1) try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expect(!group.alive());
}

test "leftovers are found by binary and command-line argument, and killed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    const ping = try systemProgram(testing.allocator, "PING.EXE");
    defer testing.allocator.free(ping);

    // ping runs for 30 s with its target as its own argument, standing in for the profile path.
    var engine = try spawnGroup(io, .{ .argv = &.{ ping, "-n", "30", "127.0.0.3" }, .environ_map = &environ });
    defer engine.kill(io);
    var bystander = try spawnGroup(io, .{ .argv = &.{ ping, "-n", "30", "127.0.0.4" }, .environ_map = &environ });
    defer bystander.kill(io);
    try io.sleep(.fromMilliseconds(300), .awake);

    const identity: platform.EngineIdentity = .{ .binary = ping, .profile = "127.0.0.3", .exe_names = &.{"PING.EXE"} };
    const found = try findLeftovers(testing.allocator, io, identity);
    defer testing.allocator.free(found);
    try testing.expectEqualDeep(@as([]const KillTarget, &.{.{ .pid = engine.pid }}), found);

    killLeftover(io, found[0]);
    try testing.expect(!engine.alive());
    try testing.expect(bystander.alive());
    const missing_binary = try findLeftovers(testing.allocator, io, .{ .binary = "C:\\nonexistent\\firefox.exe", .profile = "127.0.0.3", .exe_names = &.{} });
    try testing.expectEqual(@as(usize, 0), missing_binary.len);
}

test "the server socket is the lock: a second listener on the same port fails" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    var first = try listenLoopback(io, .{ .ip4 = .loopback(0) });
    defer first.deinit(io);
    const port = first.socket.address.getPort();
    try testing.expect(port != 0);
    try testing.expectError(error.AddressInUse, listenLoopback(io, .{ .ip4 = .loopback(port) }));
}

test "the engine's job lists its processes, which report memory and CPU; free memory too" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    var environ = try testEnviron();
    defer environ.deinit();
    const ping = try systemProgram(testing.allocator, "PING.EXE");
    defer testing.allocator.free(ping);
    var group = try spawnGroup(io, .{ .argv = &.{ ping, "-n", "30", "127.0.0.1" }, .environ_map = &environ });
    try io.sleep(.fromMilliseconds(300), .awake);
    const tree = try processTree(testing.allocator, io, &group);
    defer testing.allocator.free(tree);
    // Without a console of its own, ping may bring a conhost.exe into the job too.
    try testing.expect(std.mem.findScalar(ProcessId, tree, group.pid) != null);
    try testing.expect((try processUsage(io, group.pid)).memory_bytes > 0);
    group.kill(io);
    const gone = try processTree(testing.allocator, io, &group);
    defer testing.allocator.free(gone);
    try testing.expectEqual(@as(usize, 0), gone.len);

    try testing.expect((try processUsage(io, currentPid())).memory_bytes > 0);
    try testing.expect(try availableMemory(io) > 0);
    // Opening a real URL would start the user's browser; a file never reaches the shell.
    try testing.expectError(error.AccessDenied, openUrl(io, "C:\\Windows\\System32\\calc.exe"));
}
