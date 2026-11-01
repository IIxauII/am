//! The terminal while the full-screen UI runs: raw input, the alternate screen, the modes the
//! UI needs, and putting all of it back however the process ends.
//!
//! - POSIX (macOS, Linux): termios raw mode; SIGWINCH sets a flag that `resized` reports.
//!   SIGTERM, SIGHUP, SIGINT, SIGQUIT, SIGABRT (and the fault signals, when std doesn't handle
//!   them) restore the terminal and then end the process as they would have; a signal that already has a handler (the app's own shutdown flag) or is
//!   ignored keeps it, and the app's normal exit restores. SIGTSTP (e.g. `suspendProcess` for
//!   Ctrl-Z) restores the terminal before stopping, and SIGCONT sets it up again.
//! - Windows 10+: console modes with VT input and output, UTF-8 code pages. The size is polled,
//!   as ReadFile filters out window events. Closing the console restores the modes first.
//!
//! The state lives in globals so that `restoreTerminal` can run from a panic handler or a
//! signal handler without a pointer to the `Terminal`. Only one `Terminal` can be active.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const posix = std.posix;
const windows = std.os.windows;
const is_windows = builtin.os.tag == .windows;

pub const Size = struct {
    cols: u16,
    rows: u16,
    /// Pixels per cell when the terminal reports them (POSIX `TIOCGWINSZ`), else 0.
    cell_w_px: u16 = 0,
    cell_h_px: u16 = 0,
};

/// Alternate screen (saves the cursor), hidden cursor, no autowrap (so the bottom-right cell
/// can't scroll), bracketed paste, in-band resize reports.
const enter_sequence = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?2004h\x1b[?2048h\x1b[0m\x1b[H";
/// Ends an unfinished synchronized frame, resets the style, turns every mode back off and
/// leaves the alternate screen, which restores the cursor and the shell's screen.
const leave_sequence = "\x1b[?2026l\x1b[0m\x1b[?2048l\x1b[?2004l\x1b[?7h\x1b[?25h\x1b[?1049l";

const State = enum(u8) { off, on, suspended };
var state: std.atomic.Value(State) = .init(.off);
var winch: std.atomic.Value(bool) = .init(false);
var resumed_flag: std.atomic.Value(bool) = .init(false);

pub const InitError = error{
    /// stdin or stdout is not a terminal.
    NotATerminal,
    /// Another `Terminal` is active.
    AlreadyActive,
    Unexpected,
} || Io.Cancelable;

pub const Terminal = struct {
    io: Io,
    last_size: Size,
    /// The size `resized` last saw (Windows).
    polled_size: Size,
    out: Io.File.Writer = undefined,
    out_ready: bool = false,
    out_buffer: [32 * 1024]u8 = undefined,

    /// Takes over the terminal: raw mode, alternate screen, hidden cursor, no autowrap,
    /// bracketed paste (?2004h) and in-band resize reports (?2048h), then installs the restore
    /// for signals (POSIX) or console close (Windows). `deinit` undoes it.
    pub fn init(io: Io) InitError!Terminal {
        if (state.load(.acquire) != .off) return error.AlreadyActive;
        if (!try isTtyCancelable(io)) return error.NotATerminal;
        backend.installHandlers();
        try backend.enter();
        state.store(.on, .release);
        writeRaw(enter_sequence);
        winch.store(false, .release);
        resumed_flag.store(false, .release);
        const initial = backend.size(io) orelse Size{ .cols = 80, .rows = 24 };
        return .{ .io = io, .last_size = initial, .polled_size = initial };
    }

    /// Sends what is buffered, then restores the terminal exactly as it was. Safe to call
    /// more than once, and after `restoreTerminal`.
    pub fn deinit(t: *Terminal) void {
        if (t.out_ready) t.out.interface.flush() catch {};
        restoreTerminal();
    }

    /// The window size; the last known one if the query fails.
    pub fn size(t: *Terminal) Size {
        if (backend.size(t.io)) |s| t.last_size = s;
        return t.last_size;
    }

    /// Whether the window changed size (or the process was resumed) since the last call.
    /// POSIX consumes the SIGWINCH flag; Windows compares the size with the last one seen.
    pub fn resized(t: *Terminal) bool {
        if (is_windows) {
            const before = t.polled_size;
            t.polled_size = t.size();
            return t.polled_size.cols != before.cols or t.polled_size.rows != before.rows;
        }
        return winch.swap(false, .acq_rel);
    }

    /// Whether the process was stopped and resumed since the last call (POSIX). The terminal
    /// was set up again and the alternate screen is new, so kitty images sent before are gone.
    /// `resized` reports true as well.
    pub fn resumed(t: *Terminal) bool {
        _ = t;
        return resumed_flag.swap(false, .acq_rel);
    }

    /// Blocks until input arrives and returns how many bytes were read into `buf` (0 is
    /// possible on Windows: read again). Canceling the task (e.g. `Io.Group.cancel`) ends the
    /// wait with `error.Canceled`; a hangup gives `error.EndOfStream`.
    pub fn read(t: *Terminal, buf: []u8) Io.File.ReadStreamingError!usize {
        return Io.File.stdin().readStreaming(t.io, &.{buf});
    }

    /// A buffered writer to the terminal. Nothing reaches it until `flush`. The `Terminal`
    /// must not move after the first call.
    pub fn writer(t: *Terminal) *Io.Writer {
        if (!t.out_ready) {
            t.out = Io.File.stdout().writerStreaming(t.io, &t.out_buffer);
            t.out_ready = true;
        }
        return &t.out.interface;
    }

    /// Suspends the process as Ctrl-Z would in a shell (which raw mode turns into a key):
    /// the terminal is restored, the process stops, and when the shell resumes it the
    /// terminal is set up again and `resized` reports true so the app repaints everything.
    /// Does nothing on Windows, or when SIGTSTP was ignored at start (a shell without job
    /// control could never resume the process).
    pub fn suspendProcess(t: *Terminal) void {
        if (is_windows or !unix.job_control) return;
        if (t.out_ready) t.out.interface.flush() catch {};
        posix.raise(.TSTP) catch {};
        // The process ran again. The kernel discards the stop when the process group is
        // orphaned (e.g. `kitty am`, where am leads its own session) and no SIGCONT comes.
        unix.resumeIfSuspended();
    }
};

/// Puts the terminal back: leaves the alternate screen, shows the cursor, turns the modes
/// off and restores the termios / console modes. Does nothing unless a `Terminal` is active,
/// so it can be called any number of times, from a panic handler or a signal handler (it
/// only calls write and tcsetattr / SetConsoleMode).
pub fn restoreTerminal() void {
    switch (state.swap(.off, .acq_rel)) {
        .on => {
            writeRaw(leave_sequence);
            backend.leave();
        },
        // Already restored when the process stopped.
        .suspended, .off => {},
    }
}

/// For `std.debug.FullPanic` in the root file, so a panic prints on the normal screen:
/// `pub const panic = std.debug.FullPanic(term.panicHandler);`
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreTerminal();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// For `root.debug.handleSegfault`: a segfault, bus error, illegal instruction or stack
/// overflow (on any thread) prints its trace on the normal screen too.
pub fn segfaultHandler(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
    restoreTerminal();
    std.debug.defaultHandleSegfault(addr, name, ctx);
}

/// stdin and stdout are both terminals.
pub fn isTty(io: Io) bool {
    return isTtyCancelable(io) catch false;
}

fn isTtyCancelable(io: Io) Io.Cancelable!bool {
    return try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io);
}

/// Writes to stdout with plain system calls, so it is safe in a signal handler.
fn writeRaw(bytes: []const u8) void {
    backend.write(bytes);
}

const backend = if (is_windows) win else unix;

const unix = struct {
    var saved: posix.termios = undefined;
    var raw: posix.termios = undefined;
    var handlers_installed = false;
    /// SIGTSTP had its default action, so stopping and resuming works.
    var job_control = false;
    /// ABRT: std.process.abort after a crash. The faults only take this path when std's own
    /// segfault handler is off (ReleaseFast); with it on, the root's `debug.handleSegfault`
    /// restores the terminal.
    const end_signals = [_]posix.SIG{ .TERM, .HUP, .INT, .QUIT, .ABRT, .SEGV, .BUS, .ILL, .FPE };

    fn enter() InitError!void {
        saved = posix.tcgetattr(posix.STDIN_FILENO) catch |e| return switch (e) {
            error.NotATerminal => error.NotATerminal,
            else => error.Unexpected,
        };
        raw = makeRaw(saved);
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch |e| return switch (e) {
            error.NotATerminal => error.NotATerminal,
            else => error.Unexpected,
        };
    }

    /// Byte-at-a-time input with no echo, no signals from keys (Ctrl-C, Ctrl-Z arrive as
    /// bytes), no flow control and no output processing.
    fn makeRaw(orig: posix.termios) posix.termios {
        var t = orig;
        t.iflag.ICRNL = false;
        t.iflag.IXON = false;
        t.iflag.BRKINT = false;
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        t.oflag.OPOST = false;
        t.cflag.CSIZE = .CS8;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.cc[@backingInt(posix.V.MIN)] = 1;
        t.cc[@backingInt(posix.V.TIME)] = 0;
        return t;
    }

    fn leave() void {
        // The raw call, not posix.tcsetattr: no error handling that could print or assert.
        // FLUSH drops input not read yet, such as late replies to terminal queries.
        _ = posix.system.tcsetattr(posix.STDIN_FILENO, .FLUSH, &saved);
    }

    fn write(bytes: []const u8) void {
        var rest = bytes;
        var tries: u8 = 0;
        while (rest.len > 0 and tries < 64) : (tries += 1) {
            const rc = posix.system.write(posix.STDOUT_FILENO, rest.ptr, rest.len);
            switch (posix.errno(rc)) {
                .SUCCESS => rest = rest[@intCast(rc)..],
                .INTR, .AGAIN => {},
                else => return,
            }
        }
    }

    fn size(io: Io) ?Size {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const result = io.operate(.{ .device_io_control = .{
            .file = Io.File.stdout(),
            .code = posix.T.IOCGWINSZ,
            .arg = &ws,
        } }) catch return null;
        if (result.device_io_control < 0 or ws.col == 0 or ws.row == 0) return null;
        return .{
            .cols = ws.col,
            .rows = ws.row,
            .cell_w_px = if (ws.xpixel != 0) ws.xpixel / ws.col else 0,
            .cell_h_px = if (ws.ypixel != 0) ws.ypixel / ws.row else 0,
        };
    }

    fn action(handler: *const fn (posix.SIG) callconv(.c) void, flags: @FieldType(posix.Sigaction, "flags")) posix.Sigaction {
        return .{ .handler = .{ .handler = handler }, .mask = posix.sigemptyset(), .flags = flags };
    }

    fn installHandlers() void {
        if (handlers_installed) return;
        handlers_installed = true;
        // SA_RESTART: a resize must not fail the input task's blocking read.
        posix.sigaction(.WINCH, &action(onWinch, posix.SA.RESTART), null);
        // SA_RESETHAND: the second delivery takes the default action.
        const end = action(onEnd, posix.SA.RESETHAND);
        for (end_signals) |sig| if (hasDefaultAction(sig)) posix.sigaction(sig, &end, null);
        job_control = hasDefaultAction(.TSTP);
        if (job_control) {
            posix.sigaction(.TSTP, &action(onStop, posix.SA.RESTART), null);
            posix.sigaction(.CONT, &action(onCont, posix.SA.RESTART), null);
        }
    }

    /// Neither ignored nor handled already.
    fn hasDefaultAction(sig: posix.SIG) bool {
        var old: posix.Sigaction = undefined;
        posix.sigaction(sig, null, &old);
        return old.handler.handler == null;
    }

    fn onWinch(sig: posix.SIG) callconv(.c) void {
        _ = sig;
        winch.store(true, .release);
    }

    /// Restores the terminal, then lets the signal end the process: it is blocked while
    /// this handler runs, and the handler is already reset to the default.
    fn onEnd(sig: posix.SIG) callconv(.c) void {
        restoreTerminal();
        posix.raise(sig) catch {};
    }

    fn onStop(sig: posix.SIG) callconv(.c) void {
        _ = sig;
        if (state.cmpxchgStrong(.on, .suspended, .acq_rel, .acquire) == null) {
            write(leave_sequence);
            leave();
        }
        // Stop for real: the default action, delivered once this handler returns.
        const default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.TSTP, &default, null);
        posix.raise(.TSTP) catch {};
    }

    /// Also after SIGSTOP, which can't be caught: the shell may have reset the modes.
    fn onCont(sig: posix.SIG) callconv(.c) void {
        _ = sig;
        posix.sigaction(.TSTP, &action(onStop, posix.SA.RESTART), null);
        _ = state.cmpxchgStrong(.suspended, .on, .acq_rel, .acquire);
        if (state.load(.acquire) == .on) reenter();
    }

    /// After a stop that never happened: set the terminal up again, as SIGCONT would.
    fn resumeIfSuspended() void {
        if (state.cmpxchgStrong(.suspended, .on, .acq_rel, .acquire) != null) return;
        posix.sigaction(.TSTP, &action(onStop, posix.SA.RESTART), null);
        reenter();
    }

    fn reenter() void {
        _ = posix.system.tcsetattr(posix.STDIN_FILENO, .FLUSH, &raw);
        write(enter_sequence);
        resumed_flag.store(true, .release);
        winch.store(true, .release);
    }
};

const win = struct {
    var saved: Saved = undefined;
    var handlers_installed = false;

    const Saved = struct { in_mode: DWORD, out_mode: DWORD, in_cp: UINT, out_cp: UINT };

    const DWORD = windows.DWORD;
    const UINT = windows.UINT;
    const BOOL = windows.BOOL;
    const HANDLE = windows.HANDLE;

    fn stdinHandle() HANDLE {
        return Io.File.stdin().handle;
    }

    fn stdoutHandle() HANDLE {
        return Io.File.stdout().handle;
    }

    fn enter() InitError!void {
        var in_mode: DWORD = 0;
        var out_mode: DWORD = 0;
        if (!win32.GetConsoleMode(stdinHandle(), &in_mode).toBool()) return error.NotATerminal;
        if (!win32.GetConsoleMode(stdoutHandle(), &out_mode).toBool()) return error.NotATerminal;
        saved = .{ .in_mode = in_mode, .out_mode = out_mode, .in_cp = win32.GetConsoleCP(), .out_cp = win32.GetConsoleOutputCP() };
        // Quick-edit can only be turned off together with ENABLE_EXTENDED_FLAGS.
        const raw_in = (in_mode & ~(win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT | win32.ENABLE_PROCESSED_INPUT |
            win32.ENABLE_QUICK_EDIT_MODE | win32.ENABLE_MOUSE_INPUT | win32.ENABLE_WINDOW_INPUT)) |
            win32.ENABLE_VIRTUAL_TERMINAL_INPUT | win32.ENABLE_EXTENDED_FLAGS;
        if (!win32.SetConsoleMode(stdinHandle(), raw_in).toBool()) return error.Unexpected;
        const raw_out = out_mode | win32.ENABLE_PROCESSED_OUTPUT | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
            win32.DISABLE_NEWLINE_AUTO_RETURN;
        if (!win32.SetConsoleMode(stdoutHandle(), raw_out).toBool()) {
            _ = win32.SetConsoleMode(stdinHandle(), in_mode);
            return error.Unexpected;
        }
        _ = win32.SetConsoleCP(win32.CP_UTF8);
        _ = win32.SetConsoleOutputCP(win32.CP_UTF8);
    }

    fn leave() void {
        _ = win32.SetConsoleMode(stdinHandle(), saved.in_mode);
        _ = win32.SetConsoleMode(stdoutHandle(), saved.out_mode);
        _ = win32.SetConsoleCP(saved.in_cp);
        _ = win32.SetConsoleOutputCP(saved.out_cp);
    }

    fn write(bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            var written: DWORD = 0;
            const n: DWORD = @intCast(@min(rest.len, std.math.maxInt(DWORD)));
            if (!win32.WriteFile(stdoutHandle(), rest.ptr, n, &written, null).toBool() or written == 0) return;
            rest = rest[written..];
        }
    }

    fn size(io: Io) ?Size {
        _ = io;
        var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!win32.GetConsoleScreenBufferInfo(stdoutHandle(), &info).toBool()) return null;
        // The visible window, not the scrollback buffer.
        const cols = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const rows = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return null;
        return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
    }

    fn installHandlers() void {
        if (handlers_installed) return;
        handlers_installed = true;
        _ = win32.SetConsoleCtrlHandler(onConsoleEvent, .TRUE);
    }

    /// Ctrl-Break, closing the window, logoff, shutdown: restore, then let the next handler
    /// (or the default, which ends the process) run.
    fn onConsoleEvent(event: DWORD) callconv(.winapi) BOOL {
        _ = event;
        restoreTerminal();
        return .FALSE;
    }

    /// What std.os.windows doesn't declare, from the Windows SDK headers named.
    const win32 = struct {
        // consoleapi.h, consoleapi2.h, wincon.h
        extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
        extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
        extern "kernel32" fn GetConsoleCP() callconv(.winapi) UINT;
        extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
        extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
        extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
        extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
        extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?*const fn (DWORD) callconv(.winapi) BOOL, Add: BOOL) callconv(.winapi) BOOL;
        // fileapi.h
        extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;

        const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
        const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
            dwSize: windows.COORD,
            dwCursorPosition: windows.COORD,
            wAttributes: windows.WORD,
            srWindow: SMALL_RECT,
            dwMaximumWindowSize: windows.COORD,
        };

        const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
        const ENABLE_LINE_INPUT: DWORD = 0x0002;
        const ENABLE_ECHO_INPUT: DWORD = 0x0004;
        const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
        const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
        const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
        const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
        const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
        const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
        const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;
        const CP_UTF8: UINT = 65001;
    };
};

test "restoreTerminal does nothing when no terminal is active" {
    restoreTerminal();
    restoreTerminal();
    try std.testing.expectEqual(.off, state.load(.acquire));
}

test "init refuses a second terminal" {
    state.store(.on, .release);
    defer state.store(.off, .release);
    try std.testing.expectError(error.AlreadyActive, Terminal.init(std.testing.io));
}

test "the leave sequence turns off every mode the enter sequence sets" {
    var it = std.mem.splitSequence(u8, enter_sequence, "\x1b[?");
    _ = it.next();
    while (it.next()) |part| {
        const end = std.mem.findScalar(u8, part, 'h') orelse continue;
        const off = try std.fmt.allocPrint(std.testing.allocator, "\x1b[?{s}l", .{part[0..end]});
        defer std.testing.allocator.free(off);
        // Except autowrap, which goes back on.
        if (std.mem.eql(u8, part[0..end], "7")) continue;
        try std.testing.expect(std.mem.find(u8, leave_sequence, off) != null);
    }
    try std.testing.expect(std.mem.find(u8, leave_sequence, "\x1b[?7h") != null);
    try std.testing.expect(std.mem.find(u8, leave_sequence, "\x1b[?25h") != null);
}

test "raw mode clears the line discipline flags" {
    if (is_windows) return error.SkipZigTest;
    var t: posix.termios = std.mem.zeroes(posix.termios);
    t.lflag.ECHO = true;
    t.lflag.ICANON = true;
    t.lflag.ISIG = true;
    t.iflag.ICRNL = true;
    t.iflag.IXON = true;
    t.oflag.OPOST = true;
    const r = unix.makeRaw(t);
    try std.testing.expect(!r.lflag.ECHO and !r.lflag.ICANON and !r.lflag.ISIG and !r.lflag.IEXTEN);
    try std.testing.expect(!r.iflag.ICRNL and !r.iflag.IXON);
    try std.testing.expect(!r.oflag.OPOST);
    try std.testing.expectEqual(1, r.cc[@backingInt(posix.V.MIN)]);
    try std.testing.expectEqual(0, r.cc[@backingInt(posix.V.TIME)]);
}

test "every function compiles for this target" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Terminal);
}
