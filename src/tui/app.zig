//! The running TUI: one UI thread that owns all state and draws, and tasks that feed it events
//! through one queue: the terminal input reader, a 100 ms ticker, the background process's
//! `watch` stream, the sign-in, and bounded job pools for Apple Music requests, artwork
//! downloads and background-process commands. The UI thread never waits on the network or the
//! background process; results come back as events.
const std = @import("std");
const builtin = @import("builtin");
const apple = @import("../apple.zig");
const artwork = @import("artwork.zig");
const auth = @import("auth.zig");
const config = @import("../config.zig");
const daemon = @import("../daemon.zig");
const graphics = @import("graphics.zig");
const input = @import("input.zig");
const jobs = @import("jobs.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
const list_mod = @import("list.zig");
const model = @import("../music/model.zig");
const music = @import("../music/api.zig");
const platform = @import("../platform.zig");
const playback = @import("../playback.zig");
const player = @import("../daemon/player.zig");
const playstate = @import("playstate.zig");
const protocol_mod = @import("../daemon/protocol.zig");
const settings_mod = @import("../settings.zig");
const token_source = @import("../token_source.zig");
const screen_mod = @import("screen.zig");
const server_mod = @import("../daemon/server.zig");
const term = @import("term.zig");
const ui_mod = @import("ui.zig");
const views = @import("views.zig");
const Channel = @import("../daemon/channel.zig").Channel;
const deadline_mod = @import("../deadline.zig");
const Deadline = deadline_mod.Deadline;

const Allocator = std.mem.Allocator;
const Client = daemon.client.Client;
const Io = std.Io;
const Item = model.Item;
const Snapshot = playstate.Snapshot;
const Ui = ui_mod.Ui;
const View = ui_mod.View;

pub const Options = struct {
    io: Io,
    /// Thread-safe.
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    config_dir: []const u8,
    settings: *const settings_mod.Settings,
    port: u16,
};

const Event = union(enum) {
    key: input.Key,
    /// Owned (gpa).
    paste: []u8,
    kitty: struct { id: u32, ok: bool },
    device_attributes,
    cell_size: input.Event.CellSize,
    resize: input.Event.Resize,
    input_closed,
    tick,
    job: *Job,
    state: *Snapshot,
    daemon_up: bool,
    art,
    /// From the sign-in with this generation; text owned (gpa).
    signin_url: SigninText,
    signin_line: SigninText,
    signin_done: struct { gen: u32, ok: bool, message: ?[]u8 },
    /// A progress line from the background process (owned).
    note: []u8,
};

const SigninText = struct { gen: u32, text: []u8 };

/// The developer tokens renewals replaced, each mapped to the newest replacement, shared by the
/// workers: a job built from the session's first token sends the newest at once, however many
/// renewals came after it.
const Replaced = struct {
    mutex: Io.Mutex = .init,
    /// Owned. The oldest goes once `max` are kept.
    refused: [max]?[]u8 = @splat(null),
    /// Owned; set once any token was replaced.
    fresh: ?[]u8 = null,

    const max = 8;

    fn set(r: *Replaced, io: Io, gpa: Allocator, refused: []const u8, fresh: []const u8) void {
        const fresh_copy = gpa.dupe(u8, fresh) catch return;
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.fresh) |old| gpa.free(old);
        r.fresh = fresh_copy;
        // The newest replacement is never a refused one. The rest move up, oldest first.
        var count: usize = 0;
        for (r.refused) |slot| if (slot) |t| {
            if (std.mem.eql(u8, t, fresh)) {
                gpa.free(t);
            } else {
                r.refused[count] = t;
                count += 1;
            }
        };
        @memset(r.refused[count..], null);
        for (r.refused[0..count]) |t| if (std.mem.eql(u8, t.?, refused)) return;
        const copy = gpa.dupe(u8, refused) catch return;
        if (count == max) {
            gpa.free(r.refused[0].?);
            std.mem.copyForwards(?[]u8, r.refused[0 .. max - 1], r.refused[1..]);
            count = max - 1;
        }
        r.refused[count] = copy;
    }

    /// The token in place of `token`, copied into `a`.
    fn get(r: *Replaced, io: Io, a: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const fresh = r.fresh orelse return null;
        for (r.refused) |slot| if (slot) |t| if (std.mem.eql(u8, t, token)) return try a.dupe(u8, fresh);
        return null;
    }

    fn clear(r: *Replaced, io: Io, gpa: Allocator) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (&r.refused) |*slot| if (slot.*) |t| {
            gpa.free(t);
            slot.* = null;
        };
        if (r.fresh) |t| gpa.free(t);
        r.fresh = null;
    }
};

test "Replaced maps every refused token to the newest replacement" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var r: Replaced = .{};
    defer r.clear(io, testing.allocator);
    try testing.expectEqual(null, try r.get(io, a, "A"));
    r.set(io, testing.allocator, "A", "B");
    try testing.expectEqualStrings("B", (try r.get(io, a, "A")).?);
    // B refused in turn: A and B both lead to C now, and C to nothing.
    r.set(io, testing.allocator, "B", "C");
    try testing.expectEqualStrings("C", (try r.get(io, a, "A")).?);
    try testing.expectEqualStrings("C", (try r.get(io, a, "B")).?);
    try testing.expectEqual(null, try r.get(io, a, "C"));
    // Back to a token refused before (an own token signed again): it's no longer a refused one.
    r.set(io, testing.allocator, "C", "A");
    try testing.expectEqual(null, try r.get(io, a, "A"));
    try testing.expectEqualStrings("A", (try r.get(io, a, "B")).?);
}

test "Replaced drops the oldest refused token only when all its slots are taken" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var r: Replaced = .{};
    defer r.clear(io, testing.allocator);
    const names = [_][]const u8{ "T0", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", "T9" };
    // T0 → T1 → … → T7: T0 to T6 are refused, seven slots.
    for (0..7) |i| r.set(io, testing.allocator, names[i], names[i + 1]);
    // Back to T3 (an own token signed again): T3 leaves the refused ones and T7 joins, seven.
    r.set(io, testing.allocator, "T7", "T3");
    // T3 refused again fills the eighth slot; nothing is dropped yet.
    r.set(io, testing.allocator, "T3", "T8");
    // The session's first token still leads to the newest.
    try testing.expectEqualStrings("T8", (try r.get(io, a, "T0")).?);
    // One more, and the oldest goes.
    r.set(io, testing.allocator, "T8", "T9");
    try testing.expectEqual(null, try r.get(io, a, "T0"));
    try testing.expectEqualStrings("T9", (try r.get(io, a, "T1")).?);
    try testing.expectEqualStrings("T9", (try r.get(io, a, "T8")).?);
}

/// The signed-in session: what every Apple Music request needs.
const Session = struct {
    arena: std.heap.ArenaAllocator,
    storefront: []const u8,
    developer_token: []const u8,
    user_token: []const u8,
};

/// With AM_TUI_LOG=<file>, what the TUI does goes there (never tokens). For debugging.
const Log = struct {
    io: Io,
    file: ?Io.File = null,
    mutex: Io.Mutex = .init,

    fn open(io: Io, path: ?[]const u8) Log {
        const p = path orelse return .{ .io = io };
        return .{ .io = io, .file = Io.Dir.cwd().createFile(io, p, .{}) catch null };
    }

    fn print(l: *Log, comptime fmt: []const u8, args: anytype) void {
        const f = l.file orelse return;
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        f.writeStreamingAll(l.io, text) catch {};
    }

    fn close(l: *Log) void {
        if (l.file) |f| f.close(l.io);
        l.file = null;
    }
};

const toast_ms = 4000;
const error_toast_ms = 7000;
/// When a job pool is full.
const busy_text = "Busy: try again in a moment";

pub const App = struct {
    io: Io,
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    config_dir: []const u8,

    terminal: term.Terminal,
    screen: screen_mod.Screen,
    /// From the environment; kitty placeholder cells carry their own 24-bit foreground.
    color: screen_mod.ColorMode,

    events: Io.Queue(Event),
    event_buf: [1024]Event = undefined,
    group: Io.Group = .init,
    api_pool: jobs.Pool,
    api_buf: [64]*jobs.Task = undefined,
    art_pool: jobs.Pool,
    art_buf: [32]*jobs.Task = undefined,
    daemon_pool: jobs.Pool,
    daemon_buf: [32]*jobs.Task = undefined,
    /// Writes to the account (favorites, library, playlists), one at a time and in order, so
    /// f pressed twice reaches Apple as favorite-then-undo.
    write_pool: jobs.Pool,
    write_buf: [32]*jobs.Task = undefined,

    transport: apple.SharedHttpTransport,
    art_client: std.http.Client,
    cache: artwork.Cache,
    link: DaemonLink,

    machine: auth.Machine = .{},
    session: ?Session = null,
    /// The renewals: each developer token Apple refused, mapped to the newest one in its place
    /// (`renewSession`). Every request built from the session sends the newest one.
    replaced: Replaced = .{},
    ui: Ui,
    player: ?*Snapshot = null,
    daemon_up: bool = false,
    /// The playing song's details from the API, and the id they are for.
    now_item: ?Item = null,
    now_arena: ?std.heap.ArenaAllocator = null,
    now_key: [64]u8 = undefined,
    now_key_len: usize = 0,

    toast_text: auth.Text(512) = .{},
    toast_kind: @FieldType(views.Toast, "kind") = .info,
    toast_until: i64 = 0,

    /// The last thing played, for playing it again after the engine closed.
    last_queue: ?QueueMemo = null,
    /// A queue request waiting for the one in flight.
    pending_queue: ?QueueMemo = null,
    queue_inflight: u32 = 0,
    volume_touched_ms: i64 = 0,
    /// Where the music was when last seen playing.
    resume_point: ?playstate.Resume = null,
    /// Song ids added with e/E since the last queue (owned).
    inserted: std.ArrayList([]u8) = .empty,
    queue_seen: struct { position: i64 = -2, length: u32 = 0 } = .{},
    fav_ask: FavoriteAsk = .{},

    signin: ?Io.Future(void) = null,
    /// Bumped by every start and cancel: events from an older sign-in are dropped.
    signin_gen: u32 = 0,

    // Artwork.
    protocol: graphics.Protocol = .none,
    /// The terminal said yes to the kitty graphics query.
    kitty_ok: bool = false,
    probe_done: bool = false,
    probe_deadline: i64 = 0,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    slots: std.ArrayList(views.ImageSlot) = .empty,
    /// Image id → cell size of its virtual placement (placeholders) or placement (placements).
    placed: std.AutoHashMapUnmanaged(u32, Placed) = .empty,
    frame_arena: std.heap.ArenaAllocator,

    log: Log,
    /// settings.json's settings, with AM_IMAGES over its artwork: read once, at start
    /// (`loadSettings`), into `settings_arena`.
    tui: settings_mod.Tui = .{},
    settings_arena: std.heap.ArenaAllocator,
    /// The first problem with settings.json went to the status line.
    settings_told: bool = false,
    /// The watch task runs (it starts once signed in, so a setup screen starts no daemon).
    watching: bool = false,
    /// Set to leave: true to stop everything (`Q`), false to keep what still has a use.
    quit: ?bool = null,
    dirty: bool = true,
    full_repaint: bool = true,

    const Placed = struct { x: u16, y: u16, cols: u16, rows: u16, seen: bool = false };

    pub fn create(o: Options) !*App {
        const app = try o.gpa.create(App);
        errdefer o.gpa.destroy(app);
        app.* = .{
            .io = o.io,
            .gpa = o.gpa,
            .environ = o.environ,
            .config_dir = o.config_dir,
            .terminal = undefined,
            .screen = undefined,
            .color = screen_mod.colorMode(o.environ),
            .events = undefined,
            .api_pool = undefined,
            .art_pool = undefined,
            .daemon_pool = undefined,
            .write_pool = undefined,
            .transport = .{ .io = o.io, .gpa = o.gpa },
            .art_client = .{ .allocator = o.gpa, .io = o.io },
            .cache = undefined,
            .link = .{ .io = o.io, .gpa = o.gpa, .config_dir = o.config_dir, .port = o.port },
            .ui = .init(o.gpa),
            .frame_arena = .init(o.gpa),
            .log = .open(o.io, o.settings.tui_log),
            .settings_arena = .init(o.gpa),
        };
        app.events = .init(&app.event_buf);
        app.api_pool = .init(&app.api_buf);
        app.art_pool = .init(&app.art_buf);
        app.daemon_pool = .init(&app.daemon_buf);
        app.write_pool = .init(&app.write_buf);
        app.cache = .init(o.gpa, o.io, .{ .ctx = app, .start = startArt });
        var id_bytes: [8]u8 = undefined;
        o.io.random(&id_bytes);
        app.link.client_id = std.fmt.bytesToHex(id_bytes, .lower);
        app.loadSettings(o.settings.images);
        app.loadState();
        return app;
    }

    /// settings.json, once: the TUI never reads it again, and nothing watches it. A file am
    /// can't use leaves the defaults, and the first problem goes to the status line once signed
    /// in (`becomeReady`).
    fn loadSettings(app: *App, images: ?settings_mod.Images) void {
        app.tui = settings_mod.loadTui(app.io, app.settings_arena.allocator(), app.config_dir, images) catch .{};
        for (app.tui.problems) |p| app.log.print("{s}", .{p});
        app.ui.artwork = .{
            .setting = app.tui.artwork,
            .session_only = app.tui.artworkSessionOnly(),
            .fallback = graphics.fallback(app.environ, app.kitty_ok, app.tui.images),
        };
    }

    pub fn run(app: *App) !void {
        stop_signal.install();
        app.terminal = try term.Terminal.init(app.io);
        defer app.terminal.deinit();
        const size = app.terminal.size();
        app.cell_w = size.cell_w_px;
        app.cell_h = size.cell_h_px;
        app.screen = try .init(app.gpa, size.cols, size.rows);
        defer app.screen.deinit();

        // The image probe: kitty graphics, cell size, then DA1 which every terminal answers.
        const w = app.terminal.writer();
        w.writeAll(graphics.query) catch {};
        w.flush() catch {};
        app.probe_deadline = app.nowMs() + 500;

        // Before the first task: a task that started must be stopped before `destroy`.
        defer app.shutdown();
        try app.api_pool.start(app.io, &app.group, 4);
        try app.art_pool.start(app.io, &app.group, 3);
        try app.daemon_pool.start(app.io, &app.group, 3);
        try app.write_pool.start(app.io, &app.group, 1);
        try app.group.concurrent(app.io, inputTask, .{app});
        try app.group.concurrent(app.io, tickerTask, .{app});

        app.authEffect(app.machine.start());
        while (app.quit == null) {
            const first = app.events.getOne(app.io) catch break;
            app.handle(first);
            // Everything else that is already there, then one frame.
            var more: [64]Event = undefined;
            while (app.quit == null) {
                const n = app.events.get(app.io, &more, 0) catch break;
                if (n == 0) break;
                for (more[0..n]) |e| app.handle(e);
            }
            if (app.quit != null) break;
            if (app.dirty) app.render();
        }
    }

    fn shutdown(app: *App) void {
        if (app.signin) |*f| f.cancel(app.io);
        app.signin = null;
        // A job that swallows its cancelation must find its queue closed, not wait on it.
        app.transport.stop();
        for ([_]*jobs.Pool{ &app.api_pool, &app.art_pool, &app.daemon_pool, &app.write_pool }) |p| p.close(app.io);
        app.group.cancel(app.io);
        const w = app.terminal.writer();
        if (app.protocol == .kitty_placeholders or app.protocol == .kitty_placements) graphics.freeAll(w) catch {};
        w.flush() catch {};
        // Before the background process may go (`leaveDaemon`): the next session re-queues
        // from this file.
        app.saveState();
    }

    /// After `run`, with the terminal restored: `Q` stops the background process and its
    /// engine as `am daemon stop` does. Every other way out asks it to stop only if nothing
    /// else uses it (`stop-if-unused` decides: no music, no other TUI or command, no sign-in;
    /// a play of this TUI's own that hasn't made a sound yet is stopped first), and keeps it
    /// on any doubt. All of it, connecting included, takes at
    /// most about `timeout` plus 2 s. Null when there is nothing to report. Every task is gone
    /// by then, so nothing starts the background process again. Also after a session that
    /// ended without a quit (its event queue closed, `run` failed): that counts as q. A
    /// session that never reached the background process leaves it alone.
    pub fn leaveDaemon(app: *App, timeout: Io.Duration) ?Client.Stopped {
        if (!app.link.used.load(.acquire)) return null;
        const stop_all = app.quit orelse false;
        var kept: auth.Text(128) = .{};
        const bound: Io.Duration = .{ .nanoseconds = timeout.nanoseconds + 2 * std.time.ns_per_s };
        const result = deadline_mod.withTimeout(app.io, bound, leave, .{ &app.link, app.gpa, stop_all, timeout, &kept }) catch return null;
        const left = result orelse {
            app.log.print("the background process didn't answer within {d} s at exit", .{bound.toSeconds()});
            return .still_running;
        };
        if (kept.len > 0) app.log.print("kept the background process: {s}", .{kept.get()});
        return left;
    }

    fn nowMs(app: *App) i64 {
        return @intCast(@divFloor(Io.Timestamp.now(app.io, .awake).nanoseconds, std.time.ns_per_ms));
    }

    fn nowNs(app: *App) i96 {
        return Io.Timestamp.now(app.io, .awake).nanoseconds;
    }

    /// Queues `e` for the UI thread; an event that can't be queued (canceled at exit) is freed.
    fn post(app: *App, e: Event) void {
        app.events.putOne(app.io, e) catch |err| {
            app.discard(e);
            switch (err) {
                // Keep the cancelation for the caller's next blocking call.
                error.Canceled => app.io.recancel(),
                error.Closed => {},
            }
        };
    }

    fn toast(app: *App, text: []const u8, kind: @FieldType(views.Toast, "kind")) void {
        app.toast_text.set(text);
        app.toast_kind = kind;
        app.toast_until = app.nowMs() + if (kind == .err) @as(i64, error_toast_ms) else toast_ms;
        app.dirty = true;
    }

    fn toastFmt(app: *App, comptime fmt: []const u8, args: anytype, kind: @FieldType(views.Toast, "kind")) void {
        var buf: [512]u8 = undefined;
        app.toast(std.fmt.bufPrint(&buf, fmt, args) catch fmt, kind);
    }

    // ---- Events ----

    fn handle(app: *App, e: Event) void {
        switch (e) {
            .key => |k| app.onKey(k),
            .paste => |text| {
                defer app.gpa.free(text);
                if (app.machine.phase == .ready and app.ui.textMode()) {
                    app.ui.paste(text, app.nowMs());
                    app.afterUi();
                }
            },
            .kitty => |k| if (k.id == 31) {
                app.kitty_ok = k.ok;
            },
            .device_attributes => app.finishProbe(),
            .cell_size => |c| {
                app.cell_w = c.w;
                app.cell_h = c.h;
                app.dirty = true;
            },
            .resize => |r| {
                if (r.cols > 0 and r.rows > 0 and r.w_px > 0) {
                    app.cell_w = r.w_px / r.cols;
                    app.cell_h = r.h_px / r.rows;
                }
                app.onResize(false);
            },
            .input_closed => app.quit = false,
            .tick => app.onTick(),
            .job => |job| app.finishJob(job),
            .state => |s| app.onState(s),
            .daemon_up => |up| {
                app.daemon_up = up;
                if (!up) app.setPlayer(null);
                if (app.link.restarted.swap(false, .acq_rel)) app.toast("Restarted the background process: it was from another build of am", .info);
                app.dirty = true;
            },
            .art => app.dirty = true,
            .note => |text| {
                defer app.gpa.free(text);
                app.toast(text, .info);
            },
            .signin_url => |url| {
                defer app.gpa.free(url.text);
                if (url.gen != app.signin_gen) return;
                const eff = app.machine.signinUrl(url.text);
                app.authEffect(eff);
            },
            .signin_line => |line| {
                defer app.gpa.free(line.text);
                if (line.gen != app.signin_gen) return;
                app.machine.signinLine(line.text);
                app.dirty = true;
            },
            .signin_done => |d| {
                defer if (d.message) |m| app.gpa.free(m);
                // Another sign-in started since: its future isn't this one's.
                if (d.gen != app.signin_gen) return;
                if (app.signin) |*f| f.await(app.io);
                app.signin = null;
                app.authEffect(app.machine.signinDone(d.ok, d.message));
            },
        }
    }

    /// Frees what an event owns, for one never handled.
    fn discard(app: *App, e: Event) void {
        switch (e) {
            .paste, .note => |text| app.gpa.free(text),
            .job => |job| job.destroy(),
            .state => |snap| snap.destroy(),
            .signin_url, .signin_line => |t| app.gpa.free(t.text),
            .signin_done => |d| if (d.message) |m| app.gpa.free(m),
            .key, .kitty, .device_attributes, .cell_size, .resize, .input_closed, .tick, .daemon_up, .art => {},
        }
    }

    fn finishProbe(app: *App) void {
        if (app.probe_done) return;
        app.probe_done = true;
        app.ui.artwork.fallback = graphics.fallback(app.environ, app.kitty_ok, app.tui.images);
        app.setProtocol(app.artworkProtocol(app.ui.artwork.setting));
    }

    /// What the artwork setting draws with in this terminal.
    fn artworkProtocol(app: *App, setting: graphics.Artwork) graphics.Protocol {
        return graphics.protocolFor(app.environ, app.kitty_ok, setting, app.tui.images);
    }

    fn setProtocol(app: *App, p: graphics.Protocol) void {
        const w = app.terminal.writer();
        if (app.protocol == .kitty_placeholders or app.protocol == .kitty_placements) {
            if (p != app.protocol) {
                graphics.freeAll(w) catch {};
                app.cache.forgetTransmitted();
                app.placed.clearRetainingCapacity();
            }
        }
        app.protocol = p;
        app.full_repaint = true;
        app.dirty = true;
    }

    /// `v` picked `setting`. Before the graphics query's answer, the answer picks for it
    /// (`finishProbe`).
    fn setArtwork(app: *App, setting: graphics.Artwork) void {
        if (app.probe_done) app.setProtocol(app.artworkProtocol(setting));
    }

    /// Saves one change to settings.json, on top of what the file holds now. A file am can't
    /// write back stays as it is, and the status line says why.
    fn saveSetting(app: *App, change: settings_mod.Change) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const saved = settings_mod.saveChange(app.io, arena.allocator(), app.config_dir, change) catch |e| {
            app.log.print("can't save settings.json: {t}", .{e});
            return app.toastFmt("Not saved: can't write settings.json ({t})", .{e}, .err);
        };
        switch (saved) {
            .saved, .unchanged => {},
            .refused => |why| app.toastFmt("Not saved: {s}", .{why}, .err),
        }
    }

    fn onResize(app: *App, resumed: bool) void {
        const size = app.terminal.size();
        if (size.cell_w_px > 0) {
            app.cell_w = size.cell_w_px;
            app.cell_h = size.cell_h_px;
        }
        if (size.cols != app.screen.cols or size.rows != app.screen.rows) {
            app.screen.resize(size.cols, size.rows) catch {};
        }
        if (resumed) {
            app.cache.forgetTransmitted();
        }
        // Placements sit at cell positions that moved; virtual ones keep their image.
        if (app.protocol == .kitty_placements or resumed) {
            const w = app.terminal.writer();
            var it = app.placed.keyIterator();
            while (it.next()) |id| graphics.deletePlacements(w, id.*) catch {};
            app.placed.clearRetainingCapacity();
        }
        app.full_repaint = true;
        app.dirty = true;
    }

    fn onTick(app: *App) void {
        // SIGTERM or SIGHUP: leave as q does, so the state file is written.
        if (stop_signal.requested.load(.acquire)) {
            app.quit = false;
            return;
        }
        const now = app.nowMs();
        if (!app.probe_done and now >= app.probe_deadline) app.finishProbe();
        const resumed = app.terminal.resumed();
        if (app.terminal.resized() or resumed) app.onResize(resumed);
        if (app.toast_until != 0 and now >= app.toast_until) {
            app.toast_until = 0;
            app.toast_text.len = 0;
            app.dirty = true;
        }
        app.authEffect(app.machine.tick(now));
        if (app.machine.phase != .ready) {
            // Spinner and countdown.
            if (app.machine.phase == .checking or app.machine.phase == .signing_in or app.machine.phase == .retry) app.dirty = true;
            return;
        }
        app.ui.tick(now);
        app.afterUi();
        app.askFavorites(now);
        // The progress bar and spinners move.
        if (app.player) |p| if (p.isPlaying()) {
            app.dirty = true;
        };
        if (app.queue_inflight > 0 or app.busy()) app.dirty = true;
        if (app.ui.current()) |v| if (v.list.loading) {
            app.dirty = true;
        };
    }

    fn busy(app: *App) bool {
        return app.api_pool.pending() > 0 or app.daemon_pool.pending() > 0 or app.write_pool.pending() > 0;
    }

    fn onKey(app: *App, k: input.Key) void {
        app.dirty = true;
        const now = app.nowMs();
        if (keys.fixed(k) == .suspend_process) {
            app.terminal.suspendProcess();
            app.onResize(app.terminal.resumed());
            return;
        }
        if (app.machine.phase != .ready) {
            const ak: ?auth.Key = if (k.ctrl and k.code == .char and k.code.char == 'c') .quit else switch (k.code) {
                .esc => .cancel,
                .char => |c| switch (c) {
                    'q', 'Q' => .quit,
                    'o' => .reopen,
                    'r' => .retry,
                    's' => .signin,
                    'c' => .cancel,
                    else => null,
                },
                else => null,
            };
            if (ak) |key| return app.authEffect(app.machine.key(key, now));
            // The sign-in box over the session: the music keeps answering its keys.
            if (app.machine.in_session) {
                app.ui.playerKey(k, now);
                app.afterUi();
            }
            return;
        }
        app.ui.key(k, now);
        app.afterUi();
    }

    // ---- Auth ----

    fn authEffect(app: *App, e: auth.Effect) void {
        app.dirty = true;
        switch (e) {
            .none => {},
            .check => app.submitJob(&app.api_pool, .{ .check = {} }),
            .start_signin => {
                if (app.signin) |*f| f.cancel(app.io);
                app.signin_gen +%= 1;
                app.signin = app.io.concurrent(signinTask, .{ app, app.signin_gen }) catch {
                    app.machine.fatal("Can't start the sign-in (no threads left).");
                    return;
                };
            },
            .open_url => app.submitJob(&app.daemon_pool, .{ .open_url = app.machine.url.get() }),
            .cancel_signin => {
                if (app.signin) |*f| f.cancel(app.io);
                app.signin = null;
                app.signin_gen +%= 1;
            },
            .quit => app.quit = false,
        }
    }

    fn becomeReady(app: *App, r: auth.Ready) void {
        if (app.session) |*s| s.arena.deinit();
        app.session = .{ .arena = .init(app.gpa), .storefront = "", .developer_token = "", .user_token = "" };
        const s = &app.session.?;
        const a = s.arena.allocator();
        s.storefront = a.dupe(u8, r.storefront) catch "";
        s.developer_token = a.dupe(u8, r.developer_token) catch "";
        s.user_token = a.dupe(u8, r.user_token) catch "";
        // The check's token is the newest; a renewal from before it is spent.
        app.replaced.clear(app.io, app.gpa);
        if (r.expiring_soon) app.toast("The developer token expires within two weeks: run am token --key-stdin", .info);
        if (r.own_problem) |why| app.toastFmt("Your own developer token isn't used ({s}); the shared one is", .{why}, .info);
        // A bad settings.json never stops am: it says so once, at startup.
        if (!app.settings_told) {
            app.settings_told = true;
            if (app.tui.problems.len > 0) app.toast(app.tui.problems[0], .err);
        }
        app.log.print("ready, storefront {s}", .{r.storefront});
        if (!app.watching) {
            app.group.concurrent(app.io, watchTask, .{app}) catch {};
            app.watching = true;
        }
        _ = app.ui.current();
        app.afterUi();
    }

    // ---- UI effects ----

    fn afterUi(app: *App) void {
        app.dirty = true;
        // Effects may add effects (none do today); take them one by one.
        var i: usize = 0;
        while (i < app.ui.effects.items.len) : (i += 1) app.effect(app.ui.effects.items[i]);
        app.ui.effectsDone();
    }

    fn effect(app: *App, e: ui_mod.Effect) void {
        switch (e) {
            .load => |id| app.startLoad(id),
            .suggest => |s| app.submitJob(&app.api_pool, .{ .suggest = .{ .view = s.view, .term = s.term, .generation = s.generation } }),
            .play => |req| app.play(req),
            .control => |c| app.control(c.action, c.value),
            .favorite => |f| {
                const v = app.ui.findView(f.ref.view) orelse return;
                app.changeFavorite(v.list.rows.items[f.ref.row].item, f.on, f.was);
            },
            .favorite_now => app.favoriteNow(),
            .add_library => |ref| {
                const v = app.ui.findView(ref.view) orelse return;
                app.submitJob(&app.write_pool, .{ .add_library = v.list.rows.items[ref.row].item });
            },
            .pick_playlist => |ref| {
                const v = app.ui.findView(ref.view) orelse return;
                const it = v.list.rows.items[ref.row].item;
                const picker = app.ui.openPicker(it) orelse return;
                app.submitJob(&app.api_pool, .{ .playlists = picker.id });
            },
            .add_to_playlist => |a| {
                const p = app.ui.picker orelse return;
                const playlist = p.list.rows.items[a.playlist.row].item;
                app.submitJob(&app.write_pool, .{ .add_to_playlist = .{ .playlist = playlist, .song = a.song } });
                app.ui.closePicker();
            },
            .go => |g| {
                const v = app.ui.findView(g.ref.view) orelse return;
                app.submitJob(&app.api_pool, .{ .related = .{ .item = v.list.rows.items[g.ref.row].item, .artist = g.artist } });
            },
            .quit => |q| app.quit = q.stop,
            .redraw => {
                app.full_repaint = true;
                if (app.protocol == .kitty_placeholders or app.protocol == .kitty_placements) {
                    graphics.freeAll(app.terminal.writer()) catch {};
                    app.cache.forgetTransmitted();
                    app.placed.clearRetainingCapacity();
                }
            },
            .set_artwork => |a| app.setArtwork(a),
            .save_setting => |c| app.saveSetting(c),
            .toast => |t| app.toast(t, .info),
            .signin => app.authEffect(app.machine.signinAgain(app.nowMs())),
        }
    }

    fn startLoad(app: *App, id: u64) void {
        const v = app.ui.findView(id) orelse return;
        if (app.session == null) {
            v.list.loading = false;
            return;
        }
        const offset: u32 = if (v.list.loaded) v.list.next_offset orelse 0 else 0;
        var load: Load = .{ .view = id, .epoch = v.list.epoch, .kind = v.kind, .offset = offset, .subject = v.subject, .term = v.term, .key = v.key, .artist_id = v.artist_id, .favorites_playlist = v.favorites_playlist, .stub = v.stub };
        if (v.search) |s| {
            load.term = s.submitted.items;
            load.library_search = s.library;
        }
        const pool = if (v.kind == .queue) &app.daemon_pool else &app.api_pool;
        if (!app.submitJobOk(pool, .{ .load = load })) {
            v.list.loading = false;
            v.list.setFailed("Too busy to load this right now");
        }
    }

    // ---- Playback ----

    fn play(app: *App, req: player.QueueRequest) void {
        var r = req;
        r.volume = app.ui.volume;
        const memo = QueueMemo.of(app.gpa, r) orelse return;
        if (app.queue_inflight > 0) {
            if (app.pending_queue) |*p| p.arena.deinit();
            app.pending_queue = memo;
        } else if (!app.sendQueue(memo)) return;
        app.clearInserted();
    }

    /// Sends a queue request (and frees `memo`), and remembers it as the last thing played.
    /// False, with a toast, when the pool refuses it: then it is forgotten.
    fn sendQueue(app: *App, memo: QueueMemo) bool {
        var m = memo;
        defer m.arena.deinit();
        if (!app.submitJobOk(&app.daemon_pool, .{ .queue = m.json })) {
            app.toast(busy_text, .err);
            return false;
        }
        // Remembered without a start time: where the music is now is `resume_point`'s job.
        // Nor a volume: every replay sends the session's (`ui.volume`, 0 while muted).
        var remembered = m.req;
        remembered.startTime = null;
        remembered.volume = null;
        rememberQueue(app.gpa, &app.last_queue, remembered);
        app.queue_inflight += 1;
        app.toast("Starting playback…", .info);
        return true;
    }

    fn control(app: *App, action: player.Action, value: ui_mod.ControlValue) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var out: Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        w.print("{{\"action\":\"{t}\"", .{action}) catch return;
        switch (value) {
            .none => {},
            .number => |n| w.print(",\"value\":{d}", .{n}) catch return,
            .boolean => |b| w.print(",\"value\":{}", .{b}) catch return,
            .string => |s| w.print(",\"value\":{f}", .{std.json.fmt(s, .{})}) catch return,
            .index => |i| w.print(",\"value\":{d}", .{i}) catch return,
            .insert => |ins| {
                const json = std.json.Stringify.valueAlloc(a, ins, .{ .emit_null_optional_fields = false }) catch return;
                w.print(",\"value\":{s}", .{json}) catch return;
            },
        }
        w.writeAll("}") catch return;
        if (action == .volume) app.volume_touched_ms = app.nowMs();
        if (value == .insert) app.noteInserted(value.insert);
        app.submitJob(&app.daemon_pool, .{ .control = .{ .action = action, .body = out.written() } });
    }

    /// `control` answered: the engine had closed (its queue is gone) for play and toggle.
    fn controlFailed(app: *App, action: player.Action, message: []const u8) void {
        if (std.mem.eql(u8, message, player.not_running)) {
            switch (action) {
                .toggle, .play => {
                    const last = app.last_queue orelse return app.toast("Nothing to play yet: pick a song and press Enter", .info);
                    var arena: std.heap.ArenaAllocator = .init(app.gpa);
                    defer arena.deinit();
                    const req = playstate.requeue(arena.allocator(), last.req, if (app.resume_point) |*r| r else null, app.ui.volume) catch return;
                    return app.play(req);
                },
                .volume => return app.toastFmt("Volume {d}%: used when the music starts", .{@as(u32, @intFromFloat(@round(app.ui.volume * 100)))}, .info),
                else => return app.toast("Nothing is playing", .info),
            }
        }
        app.toast(message, .err);
    }

    /// Song ids put into Up Next with e/E since the last queue: they aren't part of it.
    fn noteInserted(app: *App, ins: player.InsertRequest) void {
        const ids = ins.songs orelse return;
        for (ids) |id| {
            if (app.inserted.items.len >= 64) return;
            app.inserted.append(app.gpa, app.gpa.dupe(u8, id) catch return) catch {};
        }
    }

    fn clearInserted(app: *App) void {
        for (app.inserted.items) |id| app.gpa.free(id);
        app.inserted.clearRetainingCapacity();
    }

    fn isInserted(app: *const App, id: []const u8) bool {
        for (app.inserted.items) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }

    fn favoriteNow(app: *App) void {
        const p = app.player orelse return app.toast("Nothing is playing", .info);
        const np = p.nowPlaying() orelse return app.toast("Nothing is playing", .info);
        if (np.isLive) return app.toast("Live radio can't be a favorite", .info);
        const it = if (app.now_item) |*n| n else return app.toast("Still looking up the song; try again in a moment", .info);
        app.changeFavorite(it.*, !(it.favorited orelse false), it.favorited);
    }

    /// Asks Apple to make `it` a favorite or not, and shows `on` at once on every copy on
    /// screen. `was`: what the copy the key acted on showed before, for putting it back.
    fn changeFavorite(app: *App, it: Item, on: bool, was: ?bool) void {
        app.setFavoriteCopies(it, null, on);
        if (!app.submitJobOk(&app.write_pool, .{ .favorite = .{ .item = it, .on = on, .was = was } })) {
            app.setFavoriteCopies(it, on, was);
            app.toast(busy_text, .err);
        }
    }

    /// `Ui.setFavoriteCopies`, and Now Playing too.
    fn setFavoriteCopies(app: *App, it: Item, showing: ?bool, to: ?bool) void {
        app.ui.setFavoriteCopies(it, showing, to);
        if (app.now_item) |*n| ui_mod.setFavoriteCopy(n, it, showing, to);
    }

    fn onState(app: *App, s: *Snapshot) void {
        app.daemon_up = true;
        app.setPlayer(s);
        const now = app.nowMs();
        // Follow the player's volume only while something is loaded: a new engine page has
        // nothing queued and reports full volume, which is not the user's.
        if (s.volume()) |v| if (now - app.volume_touched_ms > 2000) app.ui.playerVolume(v, s.nowPlaying() != null);
        if (playstate.Resume.of(s, app.nowNs())) |r| {
            var seen = r;
            seen.inserted = app.isInserted(seen.id()) or (seen.catalog_len > 0 and app.isInserted(seen.catalogId()));
            app.resume_point = seen;
        }
        // The now-playing song's details.
        const np = s.nowPlaying();
        const key: []const u8 = if (np) |n| n.id orelse "" else "";
        if (!std.mem.eql(u8, key, app.now_key[0..app.now_key_len])) {
            app.now_key_len = @min(key.len, app.now_key.len);
            @memcpy(app.now_key[0..app.now_key_len], key[0..app.now_key_len]);
            app.clearNowItem();
            if (np) |n| if (!n.isLive and app.session != null) {
                const id = n.catalogId orelse n.id orelse "";
                const library = n.catalogId == null and std.mem.startsWith(u8, id, "i.");
                if (id.len > 0 and (library or n.catalogId != null)) app.submitJob(&app.api_pool, .{ .lookup_now = .{ .key = key, .id = id, .library = library } });
            };
        }
        // Up Next changed: refresh the queue view if it shows.
        if (s.report) |r| if (r.queue) |q| {
            if (q.position != app.queue_seen.position or q.length != app.queue_seen.length) {
                app.queue_seen = .{ .position = q.position, .length = q.length };
                if (app.ui.section == .queue) if (app.ui.current()) |v| if (v.kind == .queue and !v.list.loading) {
                    if (v.list.selectedItem()) |sel| v.list.setWant(sel.id);
                    v.list.clear();
                    v.list.loading = true;
                    app.startLoad(v.id);
                };
            }
        };
        app.dirty = true;
    }

    fn setPlayer(app: *App, s: ?*Snapshot) void {
        if (app.player) |old| old.destroy();
        app.player = s;
        app.ui.player = s;
    }

    fn clearNowItem(app: *App) void {
        app.now_item = null;
        if (app.now_arena) |*a| a.deinit();
        app.now_arena = null;
    }

    // ---- Jobs ----

    fn submitJob(app: *App, pool: *jobs.Pool, kind: JobKind) void {
        if (!app.submitJobOk(pool, kind)) app.toast(busy_text, .err);
    }

    fn submitJobOk(app: *App, pool: *jobs.Pool, kind: JobKind) bool {
        const job = Job.create(app, kind) catch return false;
        if (!pool.submit(app.io, &job.task)) {
            job.destroy();
            return false;
        }
        return true;
    }

    fn api(app: *App, a: Allocator) ?music.Api {
        const s = app.session orelse return null;
        return .{
            .io = app.io,
            .transport = app.transport.transport(),
            .developer_token = a.dupe(u8, s.developer_token) catch return null,
            .user_token = a.dupe(u8, s.user_token) catch return null,
            .storefront = a.dupe(u8, s.storefront) catch return null,
            // Sends the renewed token in place of the session's, and renews after a 401.
            .renew = app.renewHook(),
        };
    }

    fn renewHook(app: *App) apple.Renew {
        return .{ .ptr = app, .vtable = &.{ .renew = renewSession, .replacement = sessionReplacement } };
    }

    fn finishJob(app: *App, job: *Job) void {
        defer job.destroy();
        app.dirty = true;
        if (job.err) |e| app.log.print("job {t} failed: {t}", .{ job.kind, e });
        switch (job.kind) {
            .check => {
                if (job.err) |e| {
                    if (e != error.Canceled) app.machine.fatal(job.message);
                    return;
                }
                const result = job.out.check orelse return;
                if (result == .ready) app.becomeReady(result.ready);
                app.authEffect(app.machine.checked(result, app.nowMs()));
            },
            .load => |l| app.finishLoad(job, l),
            .suggest => |s| {
                if (job.err != null) return;
                const v = app.ui.findView(s.view) orelse return;
                const search = v.search orelse return;
                if (search.generation != s.generation or !search.focused) return;
                search.clearSuggestions(app.gpa);
                app.log.print("suggestions for {s}: {d}", .{ s.term, job.out.suggestions.len });
                for (job.out.suggestions) |t| {
                    if (std.ascii.eqlIgnoreCase(t, std.mem.trim(u8, search.query.items, " "))) continue;
                    search.suggestions.append(app.gpa, app.gpa.dupe(u8, t) catch continue) catch {};
                    if (search.suggestions.items.len == 8) break;
                }
            },
            .queue => {
                app.queue_inflight -|= 1;
                if (job.err) |e| {
                    if (e != error.Canceled) app.toastFmt("Can't play that: {s}", .{describeDaemonError(e)}, .err);
                } else if (job.out.outcome) |o| {
                    if (o.code != 0) app.toast(o.message orelse "Playback failed", .err) else if (app.toast_kind == .info) {
                        app.toast_until = 0;
                        app.toast_text.len = 0;
                    }
                }
                if (app.pending_queue) |p| {
                    app.pending_queue = null;
                    _ = app.sendQueue(p);
                }
            },
            .control => |c| {
                if (job.err) |e| {
                    if (e != error.Canceled) app.toastFmt("{s}", .{describeDaemonError(e)}, .err);
                } else if (job.out.outcome) |o| if (o.code != 0) app.controlFailed(c.action, o.message orelse "failed");
            },
            .favorite => |f| {
                if (job.err) |e| {
                    app.setFavoriteCopies(f.item, f.on, f.was);
                    app.apiFailed(e, "Can't change the favorite", &job.said);
                } else if (stillFavorite(job.out)) {
                    // The heart shows what Apple says.
                    app.setFavoriteCopies(f.item, false, true);
                    app.toast(only_music_app, .info);
                } else app.toast(if (f.on) "♥ Added to your favorites" else "Removed from your favorites", .info);
            },
            .add_library => |it| {
                if (job.err) |e| app.apiFailed(e, "Can't add that to your library", &job.said) else app.toastFmt("Added “{s}” to your library", .{it.title}, .info);
            },
            .playlists => |id| {
                const p = app.ui.picker orelse return;
                if (p.id != id) return;
                if (job.err) |e| {
                    p.list.setFailed(music.describe(asApiError(e)));
                    p.list.loading = false;
                    return;
                }
                const page = job.out.page orelse return;
                app.adoptInto(&p.list, job) catch return;
                p.list.appendPage(page.items, null, page.total) catch {};
                if (page.items.len == 0) p.list.appendNote("No playlists you can add to. Make one in the Music app first.") catch {};
            },
            .add_to_playlist => |a| {
                if (job.err) |e| app.apiFailed(e, "Can't add the song", &job.said) else app.toastFmt("Added to “{s}”", .{a.playlist.title}, .info);
            },
            .lookup_now => |l| {
                if (job.err != null) return;
                if (!std.mem.eql(u8, l.key, app.now_key[0..app.now_key_len])) return;
                const found = job.out.item orelse return;
                app.clearNowItem();
                app.now_arena = job.arena;
                job.arena_moved = true;
                app.now_item = found;
            },
            .related => |r| {
                if (job.err) |e| return app.apiFailed(e, "Can't find it", &job.said);
                const found = job.out.item orelse return app.toast(if (r.artist) "No artist found" else "No album found", .info);
                app.ui.openDetail(found, if (r.artist) null else r.item.id);
                app.afterUi();
            },
            .fill_favorites => |f| {
                app.fav_ask.finished(job.err == null, app.nowMs());
                const v = app.ui.findView(f.view) orelse return;
                // Asked for again later.
                if (job.err != null) return v.list.unaskFavorites(f.rows, f.items);
                for (f.rows, f.items) |row, it| {
                    if (row >= v.list.rows.items.len) continue;
                    const target = &v.list.rows.items[row];
                    if (target.tag != .item or !std.mem.eql(u8, target.item.id, it.id)) continue;
                    if (target.item.favorited == null) target.item.favorited = it.favorited;
                }
            },
            .open_url => {
                if (job.err != null) app.toast("Can't open the browser: open the address shown", .err);
            },
        }
    }

    /// `said`: what Apple answered, when it did.
    fn apiFailed(app: *App, e: anyerror, what: []const u8, said: ?*const music.Diagnostic) void {
        const err = asApiError(e);
        if (err == error.SignInRequired) app.authEffect(app.machine.signInRequired(app.nowMs()));
        var buf: [512]u8 = undefined;
        app.toast(apiFailureText(&buf, what, err, said), .err);
    }

    /// Moves the job's memory into the list, which the new rows point into.
    fn adoptInto(app: *App, l: *list_mod.List, job: *Job) !void {
        const a = try app.gpa.create(std.heap.ArenaAllocator);
        a.* = job.arena;
        l.adopt(a) catch |e| {
            app.gpa.destroy(a);
            return e;
        };
        job.arena_moved = true;
    }

    fn finishLoad(app: *App, job: *Job, l: Load) void {
        const v = app.ui.findView(l.view) orelse return;
        // The list was cleared since (a new search, ^r): a newer load is on its way.
        if (l.epoch != v.list.epoch) return;
        if (job.err) |e| {
            v.list.loading = false;
            if (e == error.Canceled) return;
            if (v.kind == .queue) {
                v.list.setFailed(describeDaemonError(e));
                return;
            }
            const err = asApiError(e);
            v.list.setFailed(music.describe(err));
            if (err == error.SignInRequired) app.authEffect(app.machine.signInRequired(app.nowMs()));
            return;
        }
        app.adoptInto(&v.list, job) catch {
            v.list.loading = false;
            return;
        };
        switch (job.out) {
            .page => |maybe| {
                const page = maybe orelse return;
                if (job.subject) |found| {
                    v.subject = ui_mod.dupeItem(v.arena.allocator(), found) catch v.subject;
                    v.stub = false;
                }
                // A library walk for favorites: its total counts the whole library.
                const total = if (v.kind == .favorites_scan) null else page.total;
                v.list.appendPage(page.items, page.next_offset, total) catch {};
                // `c` or `o` wanted a song this album doesn't have (autoplay, e/E).
                if (v.kind == .tracks and page.next_offset == null) if (v.list.want_id) |_| {
                    v.list.setWant(null);
                    app.toast("The playing song isn't on this album or playlist", .info);
                };
            },
            .groups => |groups| {
                // Top Results first, whatever order Apple gives.
                for (groups, 0..) |g, i| if (std.mem.eql(u8, g.key, "topResults") and i > 0) {
                    std.mem.copyBackwards(model.Group, groups[1 .. i + 1], groups[0..i]);
                    groups[0] = g;
                    break;
                };
                for (groups) |g| v.list.appendGroup(.{ .title = g.title, .items = g.items, .key = g.key, .next_offset = g.next_offset, .limit = groupLimit(v.kind) }) catch {};
                v.list.loading = false;
                v.list.loaded = true;
                if (groups.len == 0) v.list.appendNote(if (v.kind == .search) "No results." else "Nothing here yet.") catch {};
            },
            .favorites => |f| {
                v.favorites_playlist = if (f.playlist) |p| ui_mod.dupeItem(v.arena.allocator(), p) catch null else null;
                for (f.groups) |g| v.list.appendGroup(.{ .title = g.title, .items = g.items, .key = g.key, .limit = 15, .more = true }) catch {};
                v.list.loading = false;
                v.list.loaded = true;
                if (f.groups.len == 0) v.list.appendNote("No favorites yet: f on a song, album or playlist adds one.") catch {};
            },
            .queue => |q| {
                const start = v.list.rows.items.len;
                // A reload keeps the selection on the same song (`want_id`) when it is still there.
                const wanted = v.list.want_id != null;
                v.list.appendPage(q.items, q.next_offset, q.length) catch {};
                for (v.list.rows.items[start..], 0..) |*row, i| {
                    row.aux = q.indices[i];
                    row.flag = q.autoplay[i];
                }
                const kept = wanted and v.list.want_id == null;
                if (q.next_offset == null) v.list.setWant(null);
                if (l.offset == 0 and q.position >= 0 and !kept) {
                    for (v.list.visible.items, 0..) |r, i| if (v.list.rows.items[r].aux == q.position) {
                        v.list.selected = i;
                    };
                }
            },
            else => {
                v.list.loading = false;
                v.list.loaded = true;
            },
        }
    }

    fn groupLimit(kind: ui_mod.Kind) usize {
        return if (kind == .search) 6 else 10;
    }

    // ---- Drawing ----

    fn render(app: *App) void {
        app.dirty = false;
        _ = app.frame_arena.reset(.retain_capacity);
        app.slots.clearRetainingCapacity();
        const now_ms = app.nowMs();
        var frame: views.Frame = .{
            .ui = &app.ui,
            .auth = &app.machine,
            .player = app.player,
            .now_item = app.now_item,
            .now_ns = app.nowNs(),
            .now_ms = now_ms,
            .color = app.color,
            .images = app.protocol != .none,
            .cell_w = app.cell_w,
            .cell_h = app.cell_h,
            .toast = if (app.toast_text.len > 0) .{ .text = app.toast_text.get(), .kind = app.toast_kind } else null,
            .storefront = if (app.session) |s| s.storefront else "",
            .daemon_up = app.daemon_up,
            .starting = app.queue_inflight > 0,
            .busy = app.busy() or app.queue_inflight > 0,
            .slots = &app.slots,
            .gpa = app.gpa,
        };
        views.draw(&app.screen, &frame);
        // Drawing may have made views (and their loads).
        app.afterUiQuiet();
        const w = app.terminal.writer();
        const overlay = app.ui.overlay != .none or (app.machine.phase != .ready and app.machine.in_session);
        app.drawImages(w, overlay);
        views.drawOverlays(&app.screen, &frame);
        app.screen.flush(w, app.color, app.full_repaint) catch {};
        app.full_repaint = false;
        if (app.protocol == .kitty_placements) app.placeImages(w, overlay);
        app.askFavorites(now_ms);
    }

    fn afterUiQuiet(app: *App) void {
        const dirty = app.dirty;
        app.afterUi();
        app.dirty = dirty;
    }

    /// Kitty transmissions and placeholder cells, or half blocks, for this frame's slots.
    fn drawImages(app: *App, w: *Io.Writer, overlay: bool) void {
        const a = app.frame_arena.allocator();
        while (app.cache.popEvicted()) |id| {
            graphics.free(w, id) catch {};
            _ = app.placed.remove(id);
        }
        var it = app.placed.valueIterator();
        while (it.next()) |p| p.seen = false;
        for (app.slots.items) |slot| {
            if (slot.cols == 0 or slot.rows == 0) continue;
            const url = slotUrl(a, slot, app.protocol, app.cell_w, app.cell_h) catch continue;
            const view = app.cache.request(url) catch continue;
            const ready = switch (view) {
                .ready => |r| r,
                .loading, .failed => {
                    views.artPlaceholderAt(&app.screen, slot.x, slot.y, slot.cols, slot.rows, app.color, view == .loading);
                    continue;
                },
            };
            switch (app.protocol) {
                .kitty_placeholders => {
                    if (!ready.transmitted) {
                        graphics.transmitPng(w, ready.id, ready.png) catch continue;
                        app.cache.markTransmitted(url);
                        _ = app.placed.remove(ready.id);
                    }
                    const known = app.placed.getPtr(ready.id);
                    if (known == null or known.?.cols != slot.cols or known.?.rows != slot.rows) {
                        graphics.placeVirtual(w, ready.id, slot.cols, slot.rows) catch continue;
                        app.placed.put(app.gpa, ready.id, .{ .x = slot.x, .y = slot.y, .cols = slot.cols, .rows = slot.rows }) catch {};
                    }
                    if (app.placed.getPtr(ready.id)) |p| p.seen = true;
                    graphics.drawPlaceholders(&app.screen, slot.x, slot.y, ready.id, slot.cols, slot.rows);
                },
                .kitty_placements => {
                    if (overlay) continue;
                    if (!ready.transmitted) {
                        graphics.transmitPng(w, ready.id, ready.png) catch continue;
                        app.cache.markTransmitted(url);
                        _ = app.placed.remove(ready.id);
                    }
                },
                .half_blocks => if (app.cache.image(url)) |img| {
                    graphics.drawHalfBlocks(&app.screen, slot.x, slot.y, slot.cols, slot.rows, img);
                } else views.artPlaceholderAt(&app.screen, slot.x, slot.y, slot.cols, slot.rows, app.color, false),
                .none => {},
            }
        }
    }

    /// Kitty placements go on top of the flushed frame; ones no longer wanted are removed.
    fn placeImages(app: *App, w: *Io.Writer, overlay: bool) void {
        const a = app.frame_arena.allocator();
        var wanted: std.AutoHashMapUnmanaged(u32, Placed) = .empty;
        if (!overlay) for (app.slots.items) |slot| {
            const url = slotUrl(a, slot, app.protocol, app.cell_w, app.cell_h) catch continue;
            const view = app.cache.get(url) orelse continue;
            if (view != .ready or !view.ready.transmitted) continue;
            wanted.put(a, view.ready.id, .{ .x = slot.x, .y = slot.y, .cols = slot.cols, .rows = slot.rows }) catch {};
        };
        var stale: std.ArrayList(u32) = .empty;
        var it = app.placed.iterator();
        while (it.next()) |e| {
            const want = wanted.get(e.key_ptr.*);
            if (want == null or want.?.x != e.value_ptr.x or want.?.y != e.value_ptr.y or want.?.cols != e.value_ptr.cols or want.?.rows != e.value_ptr.rows)
                stale.append(a, e.key_ptr.*) catch {};
        }
        var changed = false;
        for (stale.items) |id| {
            graphics.deletePlacements(w, id) catch {};
            _ = app.placed.remove(id);
            changed = true;
        }
        var wi = wanted.iterator();
        while (wi.next()) |e| {
            if (app.placed.contains(e.key_ptr.*)) continue;
            const p = e.value_ptr.*;
            graphics.placeAt(w, e.key_ptr.*, p.x, p.y, p.cols, p.rows) catch continue;
            app.placed.put(app.gpa, e.key_ptr.*, p) catch {};
            changed = true;
        }
        if (changed) {
            // placeAt moved the cursor.
            if (app.screen.cursor) |c| w.print("\x1b[{d};{d}H", .{ @as(u32, c.y) + 1, @as(u32, c.x) + 1 }) catch {};
            w.flush() catch {};
        }
    }

    /// Asks for the favorite state of the items on screen that don't have one, once the
    /// screen has settled (`FavoriteAsk`). A prefetch: never a toast.
    fn askFavorites(app: *App, now: i64) void {
        if (app.session == null or app.machine.phase != .ready) return;
        // Not `current`, which makes a view.
        const trail = app.ui.trail();
        if (trail.len == 0) return;
        const v = trail[trail.len - 1];
        if (v.kind == .queue or v.list.loading) return;
        if (!app.fav_ask.due(v.id, v.list.offset, now)) return;
        var buf: [100]u32 = undefined;
        const rows = v.list.unknownFavorites(&buf, v.list.offset, app.ui.height + 10);
        if (rows.len == 0) return;
        if (!app.submitJobOk(&app.api_pool, .{ .fill_favorites = .{ .view = v.id, .rows = rows, .list = &v.list } }))
            return app.fav_ask.finished(false, now);
        for (rows) |r| v.list.rows.items[r].fav_asked = true;
        app.fav_ask.inflight = true;
    }

    // ---- State file ----

    const state_file = "tui-state.json";

    fn loadState(app: *App) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = config.readFile(app.io, a, app.config_dir, state_file) catch return orelse return;
        const parsed = parseState(a, text) orelse return;
        if (parsed.volume) |v| app.ui.volume = std.math.clamp(v, 0, 1);
        if (parsed.resume_point) |r| app.resume_point = playstate.Resume.fromSaved(r);
        if (parsed.last_queue) |q| {
            const json = std.json.Stringify.valueAlloc(a, q, .{}) catch return;
            var memo: QueueMemo = .{ .arena = .init(app.gpa) };
            memo.json = memo.arena.allocator().dupe(u8, json) catch return memo.arena.deinit();
            memo.req = playstate.parseRequest(memo.arena.allocator(), memo.json) orelse return memo.arena.deinit();
            app.last_queue = memo;
        }
    }

    fn saveState(app: *App) void {
        // Nothing to keep before signing in.
        if (app.session == null) return;
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const text = stateJson(arena.allocator(), app.ui.muted_from orelse app.ui.volume, if (app.last_queue) |l| l.json else null, if (app.resume_point) |*r| r else null) catch return;
        platform.writePrivateFile(app.io, app.config_dir, state_file, text) catch {};
    }

    pub fn destroy(app: *App) void {
        // Tasks are gone (shutdown); what is left is memory: jobs that never ran, events never
        // handled.
        for ([_]*jobs.Pool{ &app.api_pool, &app.art_pool, &app.daemon_pool, &app.write_pool }) |p| p.drain(app.io);
        var left: [64]Event = undefined;
        while (true) {
            const n = app.events.getUncancelable(app.io, &left, 0) catch break;
            if (n == 0) break;
            for (left[0..n]) |e| app.discard(e);
        }
        app.setPlayer(null);
        app.clearNowItem();
        if (app.last_queue) |*l| l.arena.deinit();
        if (app.pending_queue) |*p| p.arena.deinit();
        app.clearInserted();
        app.inserted.deinit(app.gpa);
        if (app.session) |*s| s.arena.deinit();
        app.replaced.clear(app.io, app.gpa);
        app.ui.deinit();
        app.cache.deinit();
        app.art_client.deinit();
        app.transport.deinit();
        app.slots.deinit(app.gpa);
        app.placed.deinit(app.gpa);
        app.frame_arena.deinit();
        app.settings_arena.deinit();
        app.log.close();
        app.gpa.destroy(app);
    }
};

/// When to ask Apple for the favorite state of the rows on screen: once the screen has shown
/// the same rows for `settle_ms` (holding j asks nothing until it stops), one request at a time,
/// and after a failure or a full pool not before `retry_ms`.
const FavoriteAsk = struct {
    view: u64 = 0,
    offset: usize = 0,
    since_ms: i64 = 0,
    inflight: bool = false,
    not_before_ms: i64 = 0,

    const settle_ms = 300;
    const retry_ms = 5000;

    /// Whether to ask now, for the rows of `view` from `offset`.
    fn due(f: *FavoriteAsk, view: u64, offset: usize, now: i64) bool {
        if (view != f.view or offset != f.offset) {
            f.view = view;
            f.offset = offset;
            f.since_ms = now;
        }
        return !f.inflight and now >= f.not_before_ms and now - f.since_ms >= settle_ms;
    }

    fn finished(f: *FavoriteAsk, ok: bool, now: i64) void {
        f.inflight = false;
        if (!ok) f.not_before_ms = now + retry_ms;
    }
};

const QueueMemo = struct {
    arena: std.heap.ArenaAllocator,
    json: []const u8 = "",
    /// Points into `arena`.
    req: player.QueueRequest = .{},

    /// A copy of `req` in its own arena, as JSON and parsed back.
    fn of(gpa: Allocator, req: player.QueueRequest) ?QueueMemo {
        var memo: QueueMemo = .{ .arena = .init(gpa) };
        const a = memo.arena.allocator();
        memo.json = playstate.requestJson(a, req) catch {
            memo.arena.deinit();
            return null;
        };
        memo.req = playstate.parseRequest(a, memo.json) orelse {
            memo.arena.deinit();
            return null;
        };
        return memo;
    }
};

/// Replaces `slot` with a copy of `req`. `req` may point into the memo being replaced, so the
/// copy is made first and the old memory freed after.
fn rememberQueue(gpa: Allocator, slot: *?QueueMemo, req: player.QueueRequest) void {
    const next = QueueMemo.of(gpa, req) orelse return;
    if (slot.*) |*old| old.arena.deinit();
    slot.* = next;
}

const SavedState = struct {
    volume: ?f64 = null,
    last_queue: ?std.json.Value = null,
    resume_point: ?playstate.Resume.Saved = null,
};

fn parseState(a: Allocator, text: []const u8) ?SavedState {
    return std.json.parseFromSliceLeaky(SavedState, a, text, .{ .ignore_unknown_fields = true }) catch null;
}

fn stateJson(a: Allocator, volume: f64, last_queue: ?[]const u8, resume_point: ?*const playstate.Resume) Allocator.Error![]const u8 {
    const point: []const u8 = if (resume_point) |r| try std.json.Stringify.valueAlloc(a, r.saved(), .{ .emit_null_optional_fields = false }) else "null";
    return std.fmt.allocPrint(a, "{{\"volume\":{d},\"last_queue\":{s},\"resume_point\":{s}}}\n", .{ volume, last_queue orelse "null", point });
}

/// The cache key and download for a slot's artwork. With kitty images, each cell size gets its
/// own key (a `#<cols>x<rows>` fragment, which never reaches the server) and so its own image id:
/// a header cover and the now-playing cover of one album would otherwise share an id, and its
/// single placement would flip between their sizes every frame.
fn slotUrl(a: Allocator, slot: views.ImageSlot, protocol: graphics.Protocol, cell_w: u16, cell_h: u16) ![]const u8 {
    const px = layout.artworkPixels(slot.cols, slot.rows, cell_w, cell_h);
    const size: u32 = if (protocol == .half_blocks) @min(px, 200) else px;
    const url = try artwork.pngUrl(a, slot.url, size, size);
    return switch (protocol) {
        .kitty_placeholders, .kitty_placements => std.fmt.allocPrint(a, "{s}#{d}x{d}", .{ url, slot.cols, slot.rows }),
        .half_blocks, .none => url,
    };
}

fn describeDaemonError(e: anyerror) []const u8 {
    return switch (e) {
        error.NotRunning, error.DaemonUnavailable => "the background process isn't running (see daemon.log in the config dir)",
        error.Refused => "the background process refused the request",
        error.Canceled => "canceled",
        error.OutOfMemory => "out of memory",
        else => "lost the connection to the background process",
    };
}

const only_music_app = "Remove it in the Music app: Apple doesn't let other apps remove favorites";

fn stillFavorite(out: JobOut) bool {
    return switch (out) {
        .unfavorited => |u| u == .still_favorite,
        else => false,
    };
}

/// Apple's reason in a toast is cut to this many bytes.
const max_reason = 100;

/// The toast for a failed Apple Music request: Apple's own reason when it refused the request
/// and said why (kept short), else the error's sentence. `said` is the job's diagnostic: a
/// BadRequest is only ever Apple's answer to the request that ended the job, which wrote it
/// (what am refuses itself is Unsupported, with nothing sent).
fn apiFailureText(buf: []u8, what: []const u8, err: music.Error, said: ?*const music.Diagnostic) []const u8 {
    if (err == error.BadRequest) if (said) |d| {
        const reason = if (d.detail.len > 0) d.detail else d.title;
        if (reason.len > 0) {
            var short: auth.Text(max_reason) = .{};
            short.set(reason);
            const more = if (short.len < reason.len) "…" else "";
            return std.fmt.bufPrint(buf, "{s}: Apple Music said “{s}{s}”", .{ what, short.get(), more }) catch what;
        }
    };
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ what, music.describe(err) }) catch what;
}

fn asApiError(e: anyerror) music.Error {
    return switch (e) {
        error.DeveloperTokenRejected => error.DeveloperTokenRejected,
        error.SignInRequired => error.SignInRequired,
        error.RateLimited => error.RateLimited,
        error.NotFound => error.NotFound,
        error.BadRequest => error.BadRequest,
        error.Unsupported => error.Unsupported,
        error.ServerError => error.ServerError,
        error.BadResponse => error.BadResponse,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Network,
    };
}

// ---- The background process ----

/// The connection details for the background process, shared by every task: started on first
/// use, restarted when it is from another build of am, reconnected after it restarts.
const DaemonLink = struct {
    io: Io,
    gpa: Allocator,
    config_dir: []const u8,
    port: u16,
    /// This binary's build id, computed on first use (it reads the whole executable); points
    /// into `own_build_buf`.
    own_build: []const u8 = "",
    own_build_buf: [64]u8 = undefined,
    mutex: Io.Mutex = .init,
    secret: [256]u8 = undefined,
    secret_len: usize = 0,
    build_checked: bool = false,
    build_matched: bool = false,
    restarted: std.atomic.Value(bool) = .init(false),
    /// This session reached the background process (started it, or used one already running).
    used: std.atomic.Value(bool) = .init(false),
    /// Sent with every request (`Client.client_id`) when set: as this TUI quits,
    /// `stop-if-unused` knows its other connections are closing, however soon the daemon
    /// notices. `App.create` sets one per session; without one the header isn't sent.
    client_id: ?[16]u8 = null,

    /// A client (its secret copied into `arena`), starting the background process if needed.
    fn client(l: *DaemonLink, arena: Allocator) !Client {
        try l.mutex.lock(l.io);
        defer l.mutex.unlock(l.io);
        if (l.secret_len > 0) {
            var discard: Io.Writer.Discarding = .init(&.{});
            return l.options(arena, false, &discard.writer).client(try arena.dupe(u8, l.secret[0..l.secret_len]));
        }
        var c = try l.connect(arena, true);
        // Reached, whatever the build check below says: leaving must see to it.
        l.used.store(true, .release);
        if (!l.build_checked) {
            l.build_checked = true;
            var scratch: std.heap.ArenaAllocator = .init(l.gpa);
            defer scratch.deinit();
            const id = daemon.buildId(l.io, scratch.allocator()) catch "";
            if (id.len <= l.own_build_buf.len) {
                @memcpy(l.own_build_buf[0..id.len], id);
                l.own_build = l.own_build_buf[0..id.len];
            }
        }
        if (l.own_build.len > 0 and !l.build_matched) {
            const theirs = c.build(arena);
            if (theirs) |_| {} else |e| if (e == error.Canceled) return error.Canceled;
            // The ping failed: the client isn't kept, so the next call asks again.
            const stale = staleDaemon(l.own_build, theirs) orelse return c;
            l.build_matched = true;
            if (stale) {
                var discard: Io.Writer.Discarding = .init(&.{});
                _ = c.stopAndWait(arena, &discard.writer, &discard.writer, daemon.client.stop_timeout) catch {};
                c = try l.connect(arena, true);
                l.restarted.store(true, .release);
            }
        }
        if (c.secret.len <= l.secret.len) {
            @memcpy(l.secret[0..c.secret.len], c.secret);
            l.secret_len = c.secret.len;
        }
        return c;
    }

    /// A client only if the background process already runs (for `Q` at exit).
    fn clientIfRunning(l: *DaemonLink, arena: Allocator) ?Client {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        return l.connect(arena, false) catch null;
    }

    fn connect(l: *DaemonLink, arena: Allocator, start: bool) !Client {
        // What it reports isn't shown: the TUI says the background process is unavailable.
        var discard: Io.Writer.Discarding = .init(&.{});
        return daemon.client.connect(l.options(arena, start, &discard.writer)) catch |e| switch (e) {
            error.Reported => error.DaemonUnavailable,
            else => |other| other,
        };
    }

    /// What every client of this link is made from, the session's `client_id` included.
    fn options(l: *const DaemonLink, arena: Allocator, start: bool, err: *Io.Writer) daemon.client.Options {
        return .{
            .io = l.io,
            .gpa = l.gpa,
            .arena = arena,
            .config_dir = l.config_dir,
            .port = l.port,
            .start = start,
            .err = err,
            .client_id = if (l.client_id) |*id| id else "",
        };
    }

    /// Forget the client after a refusal (the secret changes with every daemon start).
    fn invalidate(l: *DaemonLink) void {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        l.secret_len = 0;
    }
};

/// Whether the daemon that answered `ping` with `theirs` is from another build of am (or from
/// before build ids); null when the ping failed or answered with an error, which says nothing.
fn staleDaemon(own: []const u8, theirs: Client.BuildError!?[]const u8) ?bool {
    const id = (theirs catch return null) orelse return true;
    return !std.mem.eql(u8, id, own);
}

/// `leaveDaemon`'s work, on its own thread.
fn leave(link: *DaemonLink, gpa: Allocator, stop_all: bool, timeout: Io.Duration, kept: *auth.Text(128)) ?Client.Stopped {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = link.clientIfRunning(a) orelse return null;
    if (stop_all) return stopAll(&c, a, timeout);
    const outcome = c.stopIfUnused(a, timeout) catch |e| {
        // Says nothing about the daemon: keep it, and the music it may be playing.
        kept.set(@errorName(e));
        return null;
    };
    return switch (outcome) {
        .kept => |why| {
            kept.set(why);
            return null;
        },
        .stopping => |stopped| stopped,
    };
}

/// `Q`: stop as `am daemon stop` does; one that refuses at least stops the music.
fn stopAll(c: *const Client, a: Allocator, timeout: Io.Duration) Client.Stopped {
    var discard: Io.Writer.Discarding = .init(&.{});
    const stopped = c.stopAndWait(a, &discard.writer, &discard.writer, timeout) catch .refused;
    if (stopped == .refused) _ = c.call(a, "control", "{\"action\":\"stop\"}", null) catch {};
    return stopped;
}

/// One call to the background process, reconnecting once when it was restarted meanwhile.
fn daemonCall(app: *App, arena: Allocator, name: []const u8, body: []const u8, sink: ?daemon.client.Sink) !daemon.client.Outcome {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const c = try app.link.client(arena);
        return c.call(arena, name, body, sink) catch |e| switch (e) {
            error.NotRunning, error.Refused => {
                app.link.invalidate();
                if (tries >= 1) return e;
                continue;
            },
            else => return e,
        };
    }
}

/// Posts every `State` line of a reply to the UI; text lines become notes.
const StateSink = struct {
    app: *App,
    /// Text lines go to the sign-in screen.
    notes: bool = false,
    /// Text lines become toasts ("starting the engine…").
    toasts: bool = false,
    /// The sign-in's generation, with `notes`.
    gen: u32 = 0,

    fn sink(s: *StateSink) daemon.client.Sink {
        return .{ .ctx = s, .onLine = onLine };
    }

    fn onLine(ctx: *anyopaque, line: daemon.client.Line) void {
        const s: *StateSink = @ptrCast(@alignCast(ctx));
        const app = s.app;
        switch (line) {
            .data => |json| {
                const snap = playstate.parse(app.gpa, json, app.nowNs()) catch return;
                app.post(.{ .state = snap });
            },
            .out => |text| if (s.notes or s.toasts) {
                const t = std.mem.trim(u8, text, " \r\n");
                if (t.len == 0) return;
                const owned = app.gpa.dupe(u8, t) catch return;
                app.post(if (s.notes) .{ .signin_line = .{ .gen = s.gen, .text = owned } } else .{ .note = owned });
            },
        }
    }
};

/// SIGTERM or SIGHUP (closing the window, `kill`): quit the way q does, so the state file is
/// written and kitty images are freed. A second one ends the process at once, with the terminal
/// restored. Signals that were ignored at start (nohup) stay ignored. POSIX only.
const stop_signal = struct {
    var requested: std.atomic.Value(bool) = .init(false);

    fn install() void {
        if (builtin.os.tag == .windows) return;
        posix_impl.install();
    }

    const posix_impl = if (builtin.os.tag == .windows) struct {
        fn install() void {}
    } else struct {
        const posix = std.posix;

        fn install() void {
            const act: posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = posix.sigemptyset(), .flags = 0 };
            for ([_]posix.SIG{ .TERM, .HUP }) |sig| {
                var old: posix.Sigaction = undefined;
                posix.sigaction(sig, null, &old);
                if (old.handler.handler == null) posix.sigaction(sig, &act, null);
            }
        }

        fn handler(sig: posix.SIG) callconv(.c) void {
            if (!requested.swap(true, .acq_rel)) return;
            term.restoreTerminal();
            const default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
            posix.sigaction(sig, &default, null);
            posix.raise(sig) catch {};
        }
    };
};

// ---- Tasks ----

fn inputTask(app: *App) Io.Cancelable!void {
    var dec: input.Decoder = .init(app.gpa);
    defer dec.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = app.terminal.read(&buf) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {
                app.post(.input_closed);
                return;
            },
        };
        if (n == 0) continue;
        dec.feed(buf[0..n]) catch {};
        try drainInput(app, &dec, false);
        // A lone ESC (or half a sequence): wait 30 ms for the rest, else take it as keys.
        while (dec.pending()) {
            const result = app.io.operateTimeout(.{ .file_read_streaming = .{ .file = Io.File.stdin(), .data = &.{&buf} } }, .{
                .duration = .{ .raw = .fromMilliseconds(30), .clock = .awake },
            }) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => {
                    try drainInput(app, &dec, true);
                    break;
                },
            };
            const m = result.file_read_streaming catch {
                try drainInput(app, &dec, true);
                break;
            };
            dec.feed(buf[0..m]) catch {};
            try drainInput(app, &dec, false);
        }
    }
}

fn drainInput(app: *App, dec: *input.Decoder, flush: bool) Io.Cancelable!void {
    while (true) {
        const ev = (if (flush) dec.flushPending() else dec.next()) orelse return;
        const out: ?Event = switch (ev) {
            .key => |k| .{ .key = k },
            .paste => |p| if (app.gpa.dupe(u8, p)) |owned| Event{ .paste = owned } else |_| null,
            .kitty_graphics_ok => |r| .{ .kitty = .{ .id = r.id, .ok = true } },
            .kitty_graphics_error => |r| .{ .kitty = .{ .id = r.id, .ok = false } },
            .device_attributes => .device_attributes,
            .cell_size => |c| .{ .cell_size = c },
            .resize => |r| .{ .resize = r },
        };
        if (out) |e| app.events.putOne(app.io, e) catch |err| {
            app.discard(e);
            switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            }
        };
    }
}

fn tickerTask(app: *App) Io.Cancelable!void {
    while (true) {
        try app.io.sleep(.fromMilliseconds(100), .awake);
        // Skipped when the queue is full: the UI is behind anyway.
        _ = app.events.put(app.io, &.{.tick}, 0) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
    }
}

/// Follows the background process's `watch` stream for as long as the TUI runs, reconnecting
/// (and starting it again) after it went away.
fn watchTask(app: *App) Io.Cancelable!void {
    var backoff_ms: i64 = 500;
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var sink: StateSink = .{ .app = app };
        if (app.link.client(a)) |c| {
            app.post(.{ .daemon_up = true });
            backoff_ms = 500;
            _ = c.call(a, "watch", "{}", sink.sink()) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => app.link.invalidate(),
            };
        } else |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {},
        }
        app.post(.{ .daemon_up = false });
        try app.io.sleep(.fromMilliseconds(backoff_ms), .awake);
        backoff_ms = @min(backoff_ms * 2, 8000);
    }
}

/// The sign-in: a page from the background process, opened in the browser, then the long
/// `signin` request until Apple accepts a token (or it gives up, or this is canceled).
fn signinTask(app: *App, gen: u32) void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Capture = struct {
        text: std.ArrayList(u8) = .empty,
        arena: Allocator,
        fn onLine(ctx: *anyopaque, line: daemon.client.Line) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            switch (line) {
                .out => |t| c.text.appendSlice(c.arena, t) catch {},
                .data => {},
            }
        }
    };
    var cap: Capture = .{ .arena = a };
    const page = daemonCall(app, a, "signin-page", "{}", .{ .ctx = &cap, .onLine = Capture.onLine }) catch |e| {
        if (e == error.Canceled) return;
        return signinFinished(app, gen, false, describeDaemonError(e));
    };
    if (page.code != 0) return signinFinished(app, gen, false, page.message orelse "the background process can't make a sign-in page");
    const url = std.mem.trim(u8, cap.text.items, " \r\n");
    app.post(.{ .signin_url = .{ .gen = gen, .text = app.gpa.dupe(u8, url) catch return } });

    var lines: StateSink = .{ .app = app, .notes = true, .gen = gen };
    const outcome = daemonCall(app, a, "signin", "{\"engine\":null}", lines.sink()) catch |e| {
        if (e == error.Canceled) return;
        return signinFinished(app, gen, false, describeDaemonError(e));
    };
    signinFinished(app, gen, outcome.code == 0, outcome.message);
}

fn signinFinished(app: *App, gen: u32, ok: bool, message: ?[]const u8) void {
    const owned = if (message) |m| app.gpa.dupe(u8, m) catch null else null;
    app.post(.{ .signin_done = .{ .gen = gen, .ok = ok, .message = owned } });
}

fn startArt(ctx: *anyopaque, url: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const job = ArtJob.create(app, url) catch return app.cache.fail(url);
    if (!app.art_pool.submit(app.io, &job.task)) {
        job.destroy();
        app.cache.fail(url);
    }
}

const ArtJob = struct {
    task: jobs.Task = .{ .run = run, .drop = drop },
    app: *App,
    url: []u8,

    fn create(app: *App, url: []const u8) !*ArtJob {
        const j = try app.gpa.create(ArtJob);
        j.* = .{ .app = app, .url = app.gpa.dupe(u8, url) catch |e| {
            app.gpa.destroy(j);
            return e;
        } };
        return j;
    }

    fn destroy(j: *ArtJob) void {
        j.app.gpa.free(j.url);
        j.app.gpa.destroy(j);
    }

    fn drop(t: *jobs.Task) void {
        const j: *ArtJob = @alignCast(@fieldParentPtr("task", t));
        j.destroy();
    }

    fn run(t: *jobs.Task, io: Io) void {
        _ = io;
        const j: *ArtJob = @alignCast(@fieldParentPtr("task", t));
        defer j.destroy();
        j.app.cache.load(&j.app.art_client, j.url);
        j.app.post(.art);
    }
};

// ---- Jobs ----

const Load = struct {
    view: u64,
    /// The list's `epoch` when the load started.
    epoch: u32,
    kind: ui_mod.Kind,
    offset: u32,
    subject: ?Item = null,
    term: []const u8 = "",
    key: []const u8 = "",
    artist_id: []const u8 = "",
    library_search: bool = false,
    favorites_playlist: ?Item = null,
    /// The subject is only what the player knew (`c`).
    stub: bool = false,
};

const JobKind = union(enum) {
    check,
    load: Load,
    suggest: struct { view: u64, term: []const u8, generation: u32 },
    queue: []const u8,
    control: struct { action: player.Action, body: []const u8 },
    /// `was`: what the heart showed before, put back if this fails.
    favorite: struct { item: Item, on: bool, was: ?bool },
    add_library: Item,
    /// The picker view's id.
    playlists: u64,
    add_to_playlist: struct { playlist: Item, song: Item },
    lookup_now: struct { key: []const u8, id: []const u8, library: bool },
    related: struct { item: Item, artist: bool },
    fill_favorites: struct { view: u64, rows: []const u32, items: []Item = &.{}, list: ?*const list_mod.List = null },
    open_url: []const u8,
};

const QueueWindow = struct {
    position: i64,
    length: u32,
    items: []Item,
    indices: []u32,
    autoplay: []bool,
    next_offset: ?u32,
};

const JobOut = union(enum) {
    none,
    check: ?auth.CheckResult,
    page: ?model.Page,
    groups: []model.Group,
    favorites: struct { playlist: ?Item, groups: []model.Group },
    suggestions: [][]const u8,
    outcome: ?daemon.client.Outcome,
    item: ?Item,
    queue: QueueWindow,
    unfavorited: music.Api.Unfavorited,
};

const Job = struct {
    task: jobs.Task = .{ .run = run, .drop = drop },
    app: *App,
    arena: std.heap.ArenaAllocator,
    arena_moved: bool = false,
    kind: JobKind,
    api: ?music.Api = null,
    /// What Apple answered to a failed request, for the toast.
    said: music.Diagnostic = .{},
    err: ?anyerror = null,
    message: []const u8 = "",
    out: JobOut = .none,
    /// A detail view's container, looked up because its subject was only a stub (`c`).
    subject: ?Item = null,

    /// On the UI thread: copies what the job needs, since the UI may change it meanwhile.
    fn create(app: *App, kind: JobKind) !*Job {
        const job = try app.gpa.create(Job);
        job.* = .{ .app = app, .arena = .init(app.gpa), .kind = kind };
        errdefer job.destroy();
        const a = job.arena.allocator();
        job.api = app.api(a);
        if (job.api) |*api_| api_.diagnostic = &job.said;
        switch (job.kind) {
            .check => {},
            .load => |*l| {
                if (l.subject) |s| l.subject = try ui_mod.dupeItem(a, s);
                if (l.favorites_playlist) |s| l.favorites_playlist = try ui_mod.dupeItem(a, s);
                l.term = try a.dupe(u8, l.term);
                l.key = try a.dupe(u8, l.key);
                l.artist_id = try a.dupe(u8, l.artist_id);
            },
            .suggest => |*s| s.term = try a.dupe(u8, s.term),
            .queue => |*q| q.* = try a.dupe(u8, q.*),
            .control => |*c| c.body = try a.dupe(u8, c.body),
            .favorite => |*f| f.item = try ui_mod.dupeItem(a, f.item),
            .add_library => |*it| it.* = try ui_mod.dupeItem(a, it.*),
            .playlists => {},
            .add_to_playlist => |*p| {
                p.playlist = try ui_mod.dupeItem(a, p.playlist);
                p.song = try ui_mod.dupeItem(a, p.song);
            },
            .lookup_now => |*l| {
                l.key = try a.dupe(u8, l.key);
                l.id = try a.dupe(u8, l.id);
            },
            .related => |*r| r.item = try ui_mod.dupeItem(a, r.item),
            .fill_favorites => |*f| {
                const l = f.list.?;
                f.rows = try a.dupe(u32, f.rows);
                const items = try a.alloc(Item, f.rows.len);
                for (f.rows, items) |r, *it| it.* = try ui_mod.dupeItem(a, l.rows.items[r].item);
                f.items = items;
                f.list = null;
            },
            .open_url => |*u| u.* = try a.dupe(u8, u.*),
        }
        return job;
    }

    fn destroy(job: *Job) void {
        if (!job.arena_moved) job.arena.deinit();
        job.app.gpa.destroy(job);
    }

    fn drop(t: *jobs.Task) void {
        const job: *Job = @alignCast(@fieldParentPtr("task", t));
        job.destroy();
    }

    fn run(t: *jobs.Task, io: Io) void {
        const job: *Job = @alignCast(@fieldParentPtr("task", t));
        job.execute(io) catch |e| {
            job.err = e;
            job.message = @errorName(e);
        };
        if (job.err) |e| if (e == error.Canceled) {
            // Shutting down: nobody reads the result.
            io.recancel();
        };
        job.app.post(.{ .job = job });
    }

    fn execute(job: *Job, io: Io) !void {
        const app = job.app;
        const a = job.arena.allocator();
        switch (job.kind) {
            .check => job.out = .{ .check = try check(app, io, a) },
            .load => |l| try job.load(l),
            .suggest => |s| job.out = .{ .suggestions = try (job.api orelse return error.SignInRequired).suggestions(a, s.term) },
            .queue => |body| {
                var sink: StateSink = .{ .app = app, .toasts = true };
                job.out = .{ .outcome = try daemonCall(app, a, "queue", body, sink.sink()) };
            },
            .control => |c| {
                var sink: StateSink = .{ .app = app };
                job.out = .{ .outcome = try daemonCall(app, a, "control", c.body, sink.sink()) };
            },
            .favorite => |f| try job.setFavorite(a, f.item, f.on),
            .add_library => |it| try (job.api orelse return error.SignInRequired).addToLibrary(a, it),
            .playlists => job.out = .{ .page = try (job.api orelse return error.SignInRequired).editablePlaylists(a) },
            .add_to_playlist => |p| try (job.api orelse return error.SignInRequired).addToPlaylist(a, p.playlist.id, &.{p.song}),
            .lookup_now => |l| {
                const found = try (job.api orelse return error.SignInRequired).lookup(a, .song, l.library, &.{l.id});
                job.out = .{ .item = if (found.len > 0) found[0] else null };
            },
            .related => |r| job.out = .{ .item = try (job.api orelse return error.SignInRequired).related(a, r.item, if (r.artist) .artists else .albums) },
            .fill_favorites => |f| try (job.api orelse return error.SignInRequired).favoritedState(a, f.items),
            .open_url => |url| try platform.openUrl(io, url),
        }
    }

    /// Un-favoriting leaves what Apple says in `out.unfavorited`.
    fn setFavorite(job: *Job, a: Allocator, it: Item, on: bool) !void {
        const api_ = job.api orelse return error.SignInRequired;
        if (on) return api_.addFavorite(a, it);
        job.out = .{ .unfavorited = try api_.removeFavorite(a, it) };
    }

    fn load(job: *Job, l: Load) !void {
        const a = job.arena.allocator();
        if (l.kind == .queue) return job.loadQueue(l.offset);
        const api_ = job.api orelse return error.SignInRequired;
        switch (l.kind) {
            .home => job.out = .{ .groups = try api_.recommendations(a) },
            .recent => {
                var groups: std.ArrayList(model.Group) = .empty;
                const played = try api_.recentlyPlayed(a, 0);
                if (played.items.len > 0) try groups.append(a, .{ .title = "Recently Played", .items = played.items, .next_offset = played.next_offset, .key = "recent-containers" });
                const songs = try api_.recentlyPlayedTracks(a, 0);
                if (songs.items.len > 0) try groups.append(a, .{ .title = "Recently Played Songs", .items = songs.items, .next_offset = songs.next_offset, .key = "recent-tracks" });
                job.out = .{ .groups = groups.items };
            },
            .library => |kind| job.out = .{ .page = try api_.library(a, kind, l.offset, .name) },
            .recently_added => job.out = .{ .page = try api_.recentlyAdded(a, l.offset) },
            .favorites => {
                var groups: std.ArrayList(model.Group) = .empty;
                const playlist = try api_.favoriteSongsPlaylist(a);
                if (playlist) |p| {
                    const songs = try api_.tracks(a, p, 0);
                    if (songs.items.len > 0) try groups.append(a, .{ .title = "Favorite Songs", .items = songs.items, .key = "favorite-songs" });
                }
                const scans = [_]struct { model.Kind, []const u8, []const u8, music.Sort }{
                    .{ .album, "Favorite Albums", "fav-albums", .date_added_desc },
                    .{ .playlist, "Favorite Playlists", "fav-playlists", .date_added_desc },
                    .{ .artist, "Favorite Artists", "fav-artists", .name },
                };
                for (scans) |s| {
                    const page = try api_.library(a, s[0], 0, s[3]);
                    var favs: std.ArrayList(Item) = .empty;
                    for (page.items) |it| if (it.favorited == true and !it.tags_favorited) try favs.append(a, it);
                    if (favs.items.len > 0) try groups.append(a, .{ .title = s[1], .items = favs.items, .key = s[2] });
                }
                job.out = .{ .favorites = .{ .playlist = playlist, .groups = groups.items } };
            },
            .radio => job.out = .{ .groups = try api_.stations(a) },
            .charts => job.out = .{ .groups = try api_.charts(a) },
            .search => job.out = .{ .groups = if (l.library_search) try api_.librarySearch(a, l.term) else try api_.search(a, l.term, 0) },
            .tracks => {
                const subject = l.subject.?;
                // Opened from what the player knows (`c`): the album's or playlist's own details.
                if (l.offset == 0 and l.stub) {
                    const found = api_.lookup(a, subject.kind, subject.library, &.{subject.id}) catch &.{};
                    if (found.len > 0) job.subject = found[0];
                }
                job.out = .{ .page = try api_.tracks(a, subject, l.offset) };
            },
            .artist => job.out = .{ .groups = try api_.artist(a, l.subject.?) },
            .group => |source| job.out = .{ .page = switch (source) {
                .static => model.Page{ .items = &.{} },
                .search => try api_.searchMore(a, l.term, l.key, l.offset),
                .artist_view => try api_.artistView(a, l.artist_id, l.key, l.offset),
                .recent_containers => try api_.recentlyPlayed(a, l.offset),
                .recent_tracks => try api_.recentlyPlayedTracks(a, l.offset),
            } },
            .favorites_scan => |kind| job.out = .{ .page = try api_.library(a, kind, l.offset, if (kind == .artist) .name else .date_added_desc) },
            .queue => unreachable,
        }
    }

    fn loadQueue(job: *Job, offset: u32) !void {
        const a = job.arena.allocator();
        const Capture = struct {
            arena: Allocator,
            json: ?[]const u8 = null,
            fn onLine(ctx: *anyopaque, line: daemon.client.Line) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                switch (line) {
                    .data => |j| c.json = c.arena.dupe(u8, j) catch null,
                    .out => {},
                }
            }
        };
        var cap: Capture = .{ .arena = a };
        const body = try std.fmt.allocPrint(a, "{{\"offset\":{d},\"limit\":200}}", .{offset});
        const outcome = try daemonCall(job.app, a, "queue-items", body, .{ .ctx = &cap, .onLine = Capture.onLine });
        if (outcome.code != 0) {
            // No engine: an empty queue.
            if (outcome.message) |m| if (std.mem.eql(u8, m, player.not_running)) {
                job.out = .{ .queue = .{ .position = -1, .length = 0, .items = &.{}, .indices = &.{}, .autoplay = &.{}, .next_offset = null } };
                return;
            };
            return error.Refused;
        }
        const window = std.json.parseFromSliceLeaky(struct {
            position: i64 = -1,
            length: u32 = 0,
            items: []const playback.QueueItem = &.{},
        }, a, cap.json orelse "{}", .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
        const items = try a.alloc(Item, window.items.len);
        const indices = try a.alloc(u32, window.items.len);
        const autoplay = try a.alloc(bool, window.items.len);
        for (window.items, items, indices, autoplay) |q, *it, *idx, *ap| {
            it.* = queueRow(q);
            idx.* = q.index;
            ap.* = q.autoplay;
        }
        const end = offset + @as(u32, @intCast(window.items.len));
        job.out = .{ .queue = .{
            .position = window.position,
            .length = window.length,
            .items = items,
            .indices = indices,
            .autoplay = autoplay,
            .next_offset = if (end < window.length and window.items.len > 0) end else null,
        } };
    }
};

/// A queue view row's item. Its slices are `q`'s.
fn queueRow(q: playback.QueueItem) Item {
    const id = q.id orelse "";
    return .{
        .kind = .song,
        .id = id,
        // An older background process sends no catalog id: a catalog item's id is its own.
        .catalog_id = q.catalogId orelse if (id.len == 0 or std.mem.startsWith(u8, id, "i.")) null else id,
        .title = q.title orelse "",
        .artist = q.artist,
        .album = q.album,
        .duration_ms = if (q.durationSec) |d| @intFromFloat(@max(0, d * 1000)) else null,
    };
}

/// The settings read again (the user may have just added TEAM_ID and KEY_ID). An env file
/// that can't be read counts as none.
fn readSettings(app: *App, io: Io, a: Allocator) Allocator.Error!settings_mod.Settings {
    return settings_mod.load(io, a, app.config_dir, app.environ) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => settings_mod.parse(a, app.environ, null),
    };
}

/// The startup check, on a worker: what the config dir holds, then Apple's verdict.
fn check(app: *App, io: Io, a: Allocator) !?auth.CheckResult {
    const settings = try readSettings(app, io, a);
    const now = Io.Clock.real.now(io).toSeconds();
    // Your own developer token, else the shared one, downloaded when it is due.
    const developer = token_source.get(a, .fromSettings(io, app.config_dir, &settings, app.transport.transport(), now)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => token_source.Result{ .problem = .{ .text = try std.fmt.allocPrint(a, "can't read the developer token ({t})", .{e}) } },
    };
    const input_: auth.CheckInput = .{
        .config_dir = app.config_dir,
        .team_id = settings.team_id,
        .key_id = settings.key_id,
        .developer = developer,
        .user_token = config.storedToken(config.readFile(io, a, app.config_dir, config.file.music_user_token) catch null),
        .now = now,
        .renew = app.renewHook(),
    };
    return try auth.check(a, input_, app.transport.transport());
}

/// After Apple refused the session's developer token with 401: the token to use instead
/// (`token_source.renewNow`), remembered for the requests after (`App.replaced`). On a worker.
fn renewSession(ptr: *anyopaque, a: Allocator, refused: []const u8) Io.Cancelable!?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ptr));
    const settings = readSettings(app, app.io, a) catch return null;
    const env: token_source.Env = .fromSettings(app.io, app.config_dir, &settings, app.transport.transport(), Io.Clock.real.now(app.io).toSeconds());
    const renewal = token_source.renewNow(a, env, refused) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    app.log.print("Apple refused the developer token: {f}", .{renewal.outcome});
    const fresh = renewal.token orelse return null;
    app.replaced.set(app.io, app.gpa, refused, fresh);
    return fresh;
}

fn sessionReplacement(ptr: *anyopaque, a: Allocator, token: []const u8) Allocator.Error!?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.replaced.get(app.io, a, token);
}

const testing = std.testing;

/// testing.allocator, but freed memory is overwritten first, so a use after free shows.
const Poison = struct {
    fn allocator() Allocator {
        return .{ .ptr = undefined, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, m: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        return testing.allocator.rawResize(m, alignment, n, ra);
    }
    fn remap(_: *anyopaque, m: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        return testing.allocator.rawRemap(m, alignment, n, ra);
    }
    fn free(_: *anyopaque, m: []u8, alignment: std.mem.Alignment, ra: usize) void {
        @memset(m, 0x55);
        testing.allocator.rawFree(m, alignment, ra);
    }
};

test "the TUI logs to the file AM_TUI_LOG names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var environ: std.process.Environ.Map = .init(a);
    const settings: settings_mod.Settings = .{ .tui_log = try Io.Dir.path.join(a, &.{ dir, "tui.log" }) };
    const app = try App.create(.{ .io = testing.io, .gpa = testing.allocator, .environ = &environ, .config_dir = dir, .settings = &settings, .port = 1 });
    defer app.destroy();
    app.log.print("ready, storefront {s}", .{"gb"});
    app.log.close();
    try testing.expectEqualStrings("ready, storefront gb\n", try tmp.dir.readFileAlloc(testing.io, "tui.log", a, .limited(4096)));
}

test "playing the remembered queue again copies it before freeing it" {
    const gpa = Poison.allocator();
    var slot: ?QueueMemo = null;
    defer if (slot) |*m| m.arena.deinit();
    rememberQueue(gpa, &slot, .{ .songs = &.{ "i.1", "i.2" }, .container = null, .startId = "i.2" });
    rememberQueue(gpa, &slot, .{ .container = .{ .type = .@"library-albums", .id = "l.abc", .name = "Trench" }, .startId = "i.7" });
    // As controlFailed does: the request borrows the remembered one's memory.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var seen = playstate.Resume.fromSaved(.{ .id = "i.9", .containerId = "l.abc", .time = 20 }).?;
    const req = try playstate.requeue(arena.allocator(), slot.?.req, &seen, 0.1);
    try testing.expectEqualStrings("Trench", req.container.?.name.?);
    rememberQueue(gpa, &slot, req);
    try testing.expectEqualStrings(
        \\{"container":{"type":"library-albums","id":"l.abc","name":"Trench"},"startId":"i.9","startTime":20,"shuffle":false,"repeat":"none","volume":0.1}
    , slot.?.json);
    try testing.expectEqualStrings("l.abc", slot.?.req.container.?.id);
    // And with what the request points to freed under it: the slot keeps its own copy.
    seen.inserted = true;
    const own = try playstate.requeue(arena.allocator(), slot.?.req, &seen, 0.1);
    rememberQueue(gpa, &slot, own);
    try testing.expectEqualStrings("i.9", slot.?.req.songs.?[0]);
}

test "two slots of one picture at different sizes get different kitty images" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const art = "https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.jpg";
    const header: views.ImageSlot = .{ .url = art, .x = 1, .y = 3, .cols = 12, .rows = 6 };
    const pane: views.ImageSlot = .{ .url = art, .x = 100, .y = 2, .cols = 18, .rows = 9 };
    const h = try slotUrl(a, header, .kitty_placeholders, 10, 20);
    const p = try slotUrl(a, pane, .kitty_placeholders, 10, 20);
    try testing.expect(!std.mem.eql(u8, h, p));
    try testing.expect(std.mem.endsWith(u8, h, ".png#12x6"));
    // The fragment isn't sent: the request is for the same file.
    try testing.expectEqualStrings((try std.Uri.parse(h)).path.percent_encoded, (try std.Uri.parse(p)).path.percent_encoded);
    // Half blocks scale the decoded pixels: one download serves both.
    try testing.expectEqualStrings(try slotUrl(a, header, .half_blocks, 10, 20), try slotUrl(a, pane, .half_blocks, 10, 20));
}

test "the state file keeps the volume, the last queue and where the music was" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seen = playstate.Resume.fromSaved(.{ .id = "i.9", .catalogId = "123", .containerId = "l.abc", .time = 81.5, .shuffle = true, .repeat = .all }).?;
    const text = try stateJson(a, 0.1, "{\"songs\":[\"1\"]}", &seen);
    const back = parseState(a, text).?;
    try testing.expectEqual(@as(?f64, 0.1), back.volume);
    try testing.expectEqualStrings("1", back.last_queue.?.object.get("songs").?.array.items[0].string);
    const r = playstate.Resume.fromSaved(back.resume_point.?).?;
    try testing.expectEqualStrings("i.9", r.id());
    try testing.expectEqual(@as(?f64, 81.5), r.time);
    try testing.expect(r.shuffle);
    // An older file without a resume point, and nothing at all.
    try testing.expect(parseState(a, "{\"volume\":0.2,\"last_queue\":null}").?.resume_point == null);
    try testing.expectEqualStrings("{\"volume\":0.5,\"last_queue\":null,\"resume_point\":null}\n", try stateJson(a, 0.5, null, null));
}

/// An App that never touches a terminal: its pools have no workers, so a submitted job stays
/// queued (and `destroy` drops it).
const TestApp = struct {
    environ: std.process.Environ.Map,
    settings: settings_mod.Settings,
    app: *App,

    fn init(t: *TestApp) !void {
        t.environ = .init(testing.allocator);
        t.settings = .{};
        t.app = try App.create(.{
            .io = testing.io,
            .gpa = testing.allocator,
            .environ = &t.environ,
            .config_dir = "/nonexistent/am-tui-test",
            .settings = &t.settings,
            .port = 1,
        });
    }

    fn deinit(t: *TestApp) void {
        t.app.destroy();
        t.environ.deinit();
    }

    fn signIn(t: *TestApp) void {
        t.app.session = .{ .arena = .init(testing.allocator), .storefront = "gb", .developer_token = "d", .user_token = "u" };
        t.app.machine.phase = .ready;
    }

    /// A songs view with these library songs, nothing loading.
    fn songs(t: *TestApp, items: []const Item) !*View {
        t.app.ui.key(.char('3'), 0);
        t.app.ui.effectsDone();
        const v = t.app.ui.current().?;
        v.list.loading = false;
        try v.list.appendPage(items, null, @intCast(items.len));
        return v;
    }
};

/// Takes a pool's every free slot.
const Filler = struct {
    task: jobs.Task = .{ .run = run },
    fn run(_: *jobs.Task, _: Io) void {}

    fn fill(pool: *jobs.Pool, fillers: []Filler) void {
        for (fillers) |*f| _ = pool.submit(testing.io, &f.task);
    }
};

fn librarySong(id: []const u8) Item {
    return .{ .kind = .song, .id = id, .title = id, .library = true };
}

test "a full pool: a load stops its spinner, f puts the heart back, Enter remembers nothing" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    var api_fill: [64]Filler = @splat(.{});
    var write_fill: [32]Filler = @splat(.{});
    var daemon_fill: [32]Filler = @splat(.{});
    Filler.fill(&app.api_pool, &api_fill);
    Filler.fill(&app.write_pool, &write_fill);
    Filler.fill(&app.daemon_pool, &daemon_fill);

    app.onKey(.char('3'));
    const v = app.ui.current().?;
    try testing.expect(!v.list.loading);
    try testing.expect(v.list.failed != null);

    var s = librarySong("i.1");
    s.favorited = false;
    try v.list.appendPage(&.{s}, null, 1);
    app.onKey(.char('f'));
    try testing.expectEqual(@as(?bool, false), v.list.rows.items[0].item.favorited);
    try testing.expectEqualStrings(busy_text, app.toast_text.get());

    app.toast_text.len = 0;
    app.play(.{ .songs = &.{"1440818839"} });
    try testing.expect(app.last_queue == null);
    try testing.expectEqual(@as(u32, 0), app.queue_inflight);
    try testing.expectEqualStrings(busy_text, app.toast_text.get());
    try testing.expectEqual(.err, app.toast_kind);
}

test "Enter with room in the pool: the queue goes out and is remembered; destroy frees what never ran" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    app.play(.{ .songs = &.{"1440818839"} });
    try testing.expectEqualStrings("1440818839", app.last_queue.?.req.songs.?[0]);
    try testing.expectEqual(@as(u32, 1), app.queue_inflight);
    try testing.expectEqualStrings("Starting playback…", app.toast_text.get());
    try testing.expectEqual(@as(u32, 1), app.daemon_pool.pending());
    // Events nobody handled, as at exit: freed by destroy (testing.allocator checks).
    app.post(.{ .paste = try testing.allocator.dupe(u8, "pasted") });
    app.post(.{ .note = try testing.allocator.dupe(u8, "starting the engine…") });
    app.post(.{ .state = try playstate.parse(testing.allocator, "{\"report\":null}", 0) });
    app.post(.{ .signin_done = .{ .gen = 0, .ok = false, .message = try testing.allocator.dupe(u8, "no") } });
}

test "a queue waiting for the one in flight is remembered once it goes out, not when a full pool refuses it" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    app.queue_inflight = 1;
    app.play(.{ .songs = &.{"1440818839"} });
    try testing.expect(app.last_queue == null and app.pending_queue != null);
    var fill: [32]Filler = @splat(.{});
    Filler.fill(&app.daemon_pool, &fill);
    const waiting = app.pending_queue.?;
    app.pending_queue = null;
    try testing.expect(!app.sendQueue(waiting));
    try testing.expect(app.last_queue == null);
}

test "a queue that goes out later is remembered then" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    app.queue_inflight = 1;
    app.play(.{ .songs = &.{"1440818839"}, .startTime = 30 });
    const waiting = app.pending_queue.?;
    app.pending_queue = null;
    try testing.expect(app.sendQueue(waiting));
    try testing.expectEqualStrings("1440818839", app.last_queue.?.req.songs.?[0]);
    try testing.expectEqual(@as(?f64, null), app.last_queue.?.req.startTime);
    try testing.expectEqual(@as(?f64, null), app.last_queue.?.req.volume);
    try testing.expect(std.mem.indexOf(u8, app.last_queue.?.json, "volume") == null);
}

test "a refused request's toast says Apple's reason, cut short; other failures keep their sentence" {
    var buf: [512]u8 = undefined;
    const said: music.Diagnostic = .{ .status = 400, .code = "40012", .title = "Insufficient Permissions", .detail = "'Favorites:DELETE:IdsQuery' entities require permissions that are not in the request" };
    try testing.expectEqualStrings(
        "Can't change the favorite: Apple Music said “'Favorites:DELETE:IdsQuery' entities require permissions that are not in the request”",
        apiFailureText(&buf, "Can't change the favorite", error.BadRequest, &said),
    );
    const title_only: music.Diagnostic = .{ .status = 400, .title = "Invalid Parameter Value" };
    try testing.expectEqualStrings("x: Apple Music said “Invalid Parameter Value”", apiFailureText(&buf, "x", error.BadRequest, &title_only));
    const many_a: [300]u8 = @splat('a');
    const long: music.Diagnostic = .{ .status = 400, .detail = &many_a };
    try testing.expect(std.mem.endsWith(u8, apiFailureText(&buf, "x", error.BadRequest, &long), "a…”"));
    try testing.expectEqualStrings("x: Apple Music refused the request", apiFailureText(&buf, "x", error.BadRequest, &.{}));
    try testing.expectEqualStrings("x: can't reach Apple Music; check the network", apiFailureText(&buf, "x", error.Network, &said));
    // An answer the job let pass, then am's own refusal (nothing sent): never Apple's words.
    for ([_]u16{ 400, 404 }) |status| {
        const tolerated: music.Diagnostic = .{ .status = status, .title = "Earlier", .detail = "an earlier request's words" };
        try testing.expectEqualStrings("x: Apple Music has no way to do that for this item", apiFailureText(&buf, "x", error.Unsupported, &tolerated));
    }
}

test "un-favorite: the heart shows what Apple says, and a favorite Apple keeps says where to remove it" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    var s = librarySong("i.1");
    s.favorited = false;
    const v = try t.songs(&.{s});
    const job = try Job.create(app, .{ .favorite = .{ .item = s, .on = false, .was = true } });
    job.out = .{ .unfavorited = .still_favorite };
    app.finishJob(job);
    try testing.expectEqual(@as(?bool, true), v.list.rows.items[0].item.favorited);
    try testing.expectEqualStrings(only_music_app, app.toast_text.get());

    v.list.rows.items[0].item.favorited = false;
    const gone = try Job.create(app, .{ .favorite = .{ .item = s, .on = false, .was = true } });
    gone.out = .{ .unfavorited = .removed };
    app.finishJob(gone);
    try testing.expectEqual(@as(?bool, false), v.list.rows.items[0].item.favorited);
    try testing.expectEqualStrings("Removed from your favorites", app.toast_text.get());
}

test "un-favorite the playing song (F): the heart shows what Apple says" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    var s = librarySong("i.1");
    // F flipped it already.
    s.favorited = false;
    app.now_item = s;
    const job = try Job.create(app, .{ .favorite = .{ .item = s, .on = false, .was = true } });
    job.out = .{ .unfavorited = .still_favorite };
    app.finishJob(job);
    try testing.expectEqual(@as(?bool, true), app.now_item.?.favorited);
    try testing.expectEqualStrings(only_music_app, app.toast_text.get());

    app.now_item.?.favorited = false;
    const gone = try Job.create(app, .{ .favorite = .{ .item = s, .on = false, .was = true } });
    gone.out = .{ .unfavorited = .removed };
    app.finishJob(gone);
    try testing.expectEqual(@as(?bool, false), app.now_item.?.favorited);
    try testing.expectEqualStrings("Removed from your favorites", app.toast_text.get());
}

/// The playing song as `lookup_now` finds it: by its catalog id.
fn catalogSong(id: []const u8) Item {
    return .{ .kind = .song, .id = id, .catalog_id = id, .title = id };
}

/// A library song with a catalog match.
fn matchedLibrarySong(id: []const u8, catalog_id: []const u8) Item {
    var s = librarySong(id);
    s.catalog_id = catalog_id;
    return s;
}

/// The next job waiting in `pool`, taken as a worker would.
fn takeJob(pool: *jobs.Pool) !*Job {
    const task = try pool.queue.getOne(testing.io);
    _ = pool.busy.fetchSub(1, .monotonic);
    return @alignCast(@fieldParentPtr("task", task));
}

test "the sign-in box over the session: the player's keys still answer, the others wait" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    _ = try t.songs(&.{librarySong("i.1")});
    app.machine.phase = .signing_in;
    app.machine.in_session = true;

    app.onKey(.char('1'));
    app.onKey(.char('f'));
    try testing.expectEqual(keys.Section.songs, app.ui.section);
    try testing.expectEqual(@as(usize, 0), app.write_pool.pending());
    try testing.expectEqual(@as(usize, 0), app.daemon_pool.pending());

    app.onKey(.char(' '));
    const job = try takeJob(&app.daemon_pool);
    defer job.destroy();
    try testing.expectEqual(player.Action.toggle, job.kind.control.action);
}

test "f on the playing song: Now Playing's heart flips too, and a failure puts both back" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    var row = matchedLibrarySong("i.1", "100");
    row.favorited = false;
    const v = try t.songs(&.{row});
    var now = catalogSong("100");
    now.favorited = false;
    app.now_item = now;

    app.onKey(.char('f'));
    try testing.expectEqual(@as(?bool, true), v.list.rows.items[0].item.favorited);
    try testing.expectEqual(@as(?bool, true), app.now_item.?.favorited);

    const job = try takeJob(&app.write_pool);
    job.err = error.Network;
    app.finishJob(job);
    try testing.expectEqual(@as(?bool, false), v.list.rows.items[0].item.favorited);
    try testing.expectEqual(@as(?bool, false), app.now_item.?.favorited);
}

test "F: the playing song's row in the list flips too, and a favorite Apple keeps puts both back" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    var row = matchedLibrarySong("i.1", "100");
    row.favorited = true;
    var other = matchedLibrarySong("i.2", "200");
    other.favorited = true;
    const v = try t.songs(&.{ row, other });
    app.setPlayer(try playstate.parse(testing.allocator,
        \\{"report":{"nowPlaying":{"id":"i.1","catalogId":"100","title":"i.1"}}}
    , 0));
    var now = catalogSong("100");
    now.favorited = true;
    app.now_item = now;

    app.onKey(.char('F'));
    try testing.expectEqual(@as(?bool, false), app.now_item.?.favorited);
    try testing.expectEqual(@as(?bool, false), v.list.rows.items[0].item.favorited);
    try testing.expectEqual(@as(?bool, true), v.list.rows.items[1].item.favorited);

    const job = try takeJob(&app.write_pool);
    job.out = .{ .unfavorited = .still_favorite };
    app.finishJob(job);
    try testing.expectEqual(@as(?bool, true), app.now_item.?.favorited);
    try testing.expectEqual(@as(?bool, true), v.list.rows.items[0].item.favorited);
    try testing.expectEqualStrings(only_music_app, app.toast_text.get());
}

test "queue rows: a library song keeps its catalog match, so its heart follows the catalog copies" {
    const matched = queueRow(.{ .id = "i.1", .catalogId = "100", .title = "a" });
    try testing.expectEqualStrings("i.1", matched.id);
    try testing.expectEqualStrings("100", matched.catalog_id.?);
    try testing.expect(ui_mod.sameItem(matched, catalogSong("100")));
    // A background process from before catalog ids in the queue: a catalog id is its own.
    try testing.expectEqualStrings("200", queueRow(.{ .id = "200" }).catalog_id.?);
    try testing.expectEqual(@as(?[]const u8, null), queueRow(.{ .id = "i.2" }).catalog_id);
}

test "an event that can't be queued is freed, not leaked" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    const app = t.app;
    app.events.close(testing.io);
    app.post(.{ .paste = try testing.allocator.dupe(u8, "pasted") });
    app.post(.{ .note = try testing.allocator.dupe(u8, "starting the engine…") });
    app.post(.{ .job = try Job.create(app, .{ .open_url = "https://music.apple.com" }) });
}

test "favorite prefetch: waits for the screen to settle, one request at a time, no toasts, failures asked again later" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    t.signIn();
    const app = t.app;
    const v = try t.songs(&.{ librarySong("i.1"), librarySong("i.2"), librarySong("i.3") });
    const settle = FavoriteAsk.settle_ms;

    app.askFavorites(1000);
    try testing.expectEqual(@as(u32, 0), app.api_pool.pending());
    app.askFavorites(1000 + settle);
    try testing.expectEqual(@as(u32, 1), app.api_pool.pending());
    for (v.list.rows.items) |r| try testing.expect(r.fav_asked);
    // One in flight: nothing more, even for rows that turn up meanwhile.
    try v.list.appendPage(&.{librarySong("i.4")}, null, 4);
    app.askFavorites(1000 + 2 * settle);
    try testing.expectEqual(@as(u32, 1), app.api_pool.pending());

    // It fails: no toast; its rows are asked again, but not at once.
    const job = try takeJob(&app.api_pool);
    job.err = error.Network;
    app.finishJob(job);
    try testing.expectEqual(@as(usize, 0), app.toast_text.len);
    try testing.expect(!v.list.rows.items[0].fav_asked);
    const failed_at = app.nowMs();
    app.askFavorites(failed_at + 100);
    try testing.expectEqual(@as(u32, 0), app.api_pool.pending());
    app.askFavorites(failed_at + FavoriteAsk.retry_ms);
    try testing.expectEqual(@as(u32, 1), app.api_pool.pending());
    try testing.expect(v.list.rows.items[0].fav_asked and v.list.rows.items[3].fav_asked);

    // A full pool refuses quietly and leaves the rows askable.
    const job2 = try takeJob(&app.api_pool);
    job2.err = error.Network;
    app.finishJob(job2);
    var fill: [64]Filler = @splat(.{});
    Filler.fill(&app.api_pool, &fill);
    app.askFavorites(app.nowMs() + FavoriteAsk.retry_ms);
    try testing.expectEqual(@as(usize, 0), app.toast_text.len);
    try testing.expect(!v.list.rows.items[0].fav_asked);
}

test "favorite prefetch: holding j asks nothing until the rows stop moving" {
    var f: FavoriteAsk = .{};
    var now: i64 = 0;
    for (0..40) |i| {
        try testing.expect(!f.due(7, i, now));
        now += 50;
    }
    try testing.expect(!f.due(7, 39, now + FavoriteAsk.settle_ms - 60));
    try testing.expect(f.due(7, 39, now + FavoriteAsk.settle_ms));
    // Another view starts over.
    try testing.expect(!f.due(8, 39, now + FavoriteAsk.settle_ms));
}

test "only a ping that names another build, or none, means a stale daemon" {
    try testing.expectEqual(@as(?bool, false), staleDaemon("00aa", @as(?[]const u8, "00aa")));
    try testing.expectEqual(@as(?bool, true), staleDaemon("00aa", @as(?[]const u8, "00bb")));
    try testing.expectEqual(@as(?bool, true), staleDaemon("00aa", @as(?[]const u8, null)));
    try testing.expectEqual(@as(?bool, null), staleDaemon("00aa", error.ReadFailed));
    try testing.expectEqual(@as(?bool, null), staleDaemon("00aa", error.Refused));
    try testing.expectEqual(@as(?bool, null), staleDaemon("00aa", error.PingFailed));
}

/// A background process for `leave`: answers `ping`, counts `stop` and `control`, answers
/// `stop-if-unused` with `unused`, and keeps running after either (`stop` fails with `refuse`).
const FakeDaemon = struct {
    refuse: bool = false,
    /// `stop-if-unused`: why it is kept, or null to stop; `unused_fails` answers with an error.
    unused: ?[]const u8 = null,
    unused_fails: bool = false,
    stops: std.atomic.Value(u32) = .init(0),
    controls: std.atomic.Value(u32) = .init(0),
    /// Requests that named `client` (`X-AM-Client`), and those that named none.
    client: []const u8 = "",
    named: std.atomic.Value(u32) = .init(0),
    unnamed: std.atomic.Value(u32) = .init(0),

    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";

    fn backend(f: *FakeDaemon) server_mod.Backend {
        return .{ .ptr = f, .vtable = &.{
            .developerToken = noContent,
            .userToken = noContent,
            .postUserToken = noPost,
            .hasCli = hasCli,
            .cli = cli,
        } };
    }
    fn noContent(_: *anyopaque, _: Allocator) !server_mod.Response {
        return .{ .status = .no_content };
    }
    fn noPost(_: *anyopaque, _: Allocator, _: []const u8) !server_mod.Response {
        return .{ .status = .no_content };
    }
    fn hasCli(_: *anyopaque, name: []const u8) bool {
        for ([_][]const u8{ "ping", "stop", "control", "stop-if-unused" }) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }
    fn cli(ptr: *anyopaque, name: []const u8, _: []const u8, r: *protocol_mod.Reply) protocol_mod.Reply.Error!void {
        const f: *FakeDaemon = @ptrCast(@alignCast(ptr));
        if (r.client_id) |id| {
            if (std.mem.eql(u8, id, f.client)) _ = f.named.fetchAdd(1, .acq_rel);
        } else _ = f.unnamed.fetchAdd(1, .acq_rel);
        if (std.mem.eql(u8, name, "stop")) {
            _ = f.stops.fetchAdd(1, .acq_rel);
            if (f.refuse) return r.fail("not now", .{});
        } else if (std.mem.eql(u8, name, "control")) {
            _ = f.controls.fetchAdd(1, .acq_rel);
        } else if (std.mem.eql(u8, name, "stop-if-unused")) {
            if (f.unused_fails) return r.fail("boom", .{});
            const why = f.unused orelse return r.data("{\"kept\":null}");
            return r.data(try r.arena.print("{{\"kept\":{f}}}", .{std.json.fmt(why, .{})}));
        }
    }
};

/// A link to `fake` on a fresh server, with its secret on disk in `tmp`.
const FakeSetup = struct {
    tmp: testing.TmpDir,
    dir_buf: [Io.Dir.max_path_bytes]u8 = undefined,
    channel: Channel,
    server: server_mod.Server,
    link: DaemonLink,

    fn init(t: *FakeSetup, fake: *FakeDaemon) !void {
        const io = testing.io;
        t.tmp = testing.tmpDir(.{});
        const dir = t.dir_buf[0..try t.tmp.dir.realPath(io, &t.dir_buf)];
        t.channel = .init(io, testing.allocator);
        t.server = .{ .io = io, .gpa = testing.allocator, .channel = &t.channel, .backend = fake.backend(), .secret = FakeDaemon.secret };
        try t.server.bind(0);
        try t.server.start();
        try t.tmp.dir.writeFile(io, .{ .sub_path = daemon.secret_file, .data = FakeDaemon.secret });
        t.link = .{ .io = io, .gpa = testing.allocator, .config_dir = dir, .port = t.server.port };
    }

    fn deinit(t: *FakeSetup) void {
        t.server.close();
        t.channel.deinit();
        t.tmp.cleanup();
    }

    fn leaveWith(t: *FakeSetup, stop_all: bool, timeout: Io.Duration, kept: *auth.Text(128)) ?Client.Stopped {
        return leave(&t.link, testing.allocator, stop_all, timeout, kept);
    }
};

test "Q stops the background process as am daemon stop does; one that refuses still stops the music" {
    const io = testing.io;
    const short: Io.Duration = .fromMilliseconds(250);
    var kept: auth.Text(128) = .{};
    // No secret on disk: none runs, and none is started.
    var none: DaemonLink = .{ .io = io, .gpa = testing.allocator, .config_dir = "/nonexistent/am-tui-test", .port = 1 };
    try testing.expectEqual(null, leave(&none, testing.allocator, true, short, &kept));

    var fake: FakeDaemon = .{};
    var t: FakeSetup = undefined;
    try t.init(&fake);
    defer t.deinit();

    // It takes the request but keeps answering.
    try testing.expectEqual(Client.Stopped.still_running, t.leaveWith(true, short, &kept).?);
    try testing.expectEqual(@as(u32, 1), fake.stops.load(.acquire));
    try testing.expectEqual(@as(u32, 0), fake.controls.load(.acquire));

    // It refuses: the music is stopped instead.
    fake.refuse = true;
    try testing.expectEqual(Client.Stopped.refused, t.leaveWith(true, short, &kept).?);
    try testing.expectEqual(@as(u32, 1), fake.controls.load(.acquire));

    // It goes away once asked.
    fake.refuse = false;
    var future = try io.concurrent(FakeSetup.leaveWith, .{ &t, true, Io.Duration.fromSeconds(10), &kept });
    const deadline: Deadline = .after(io, .fromSeconds(10));
    while (fake.stops.load(.acquire) < 3) {
        if (!try deadline.sleep(.fromMilliseconds(10))) break;
    }
    t.server.close();
    try testing.expectEqual(Client.Stopped.stopped, future.await(io).?);
    try testing.expectEqual(@as(u32, 1), fake.controls.load(.acquire));
}

test "q leaves it to the background process; kept, or a failed answer, keeps it" {
    const io = testing.io;
    const short: Io.Duration = .fromMilliseconds(250);
    var fake: FakeDaemon = .{ .unused = "music is playing" };
    var t: FakeSetup = undefined;
    try t.init(&fake);
    defer t.deinit();

    var kept: auth.Text(128) = .{};
    try testing.expectEqual(null, t.leaveWith(false, short, &kept));
    try testing.expectEqualStrings("music is playing", kept.get());
    fake.unused_fails = true;
    try testing.expectEqual(null, t.leaveWith(false, short, &kept));
    try testing.expectEqualStrings("boom", kept.get());
    try testing.expectEqual(@as(u32, 0), fake.stops.load(.acquire) + fake.controls.load(.acquire));

    // Nothing else uses it: it stops (this fake doesn't, so it is still running after the wait).
    fake.unused_fails = false;
    fake.unused = null;
    try testing.expectEqual(Client.Stopped.still_running, t.leaveWith(false, short, &kept).?);
    var future = try io.concurrent(FakeSetup.leaveWith, .{ &t, false, Io.Duration.fromSeconds(10), &kept });
    try io.sleep(.fromMilliseconds(250), .awake);
    t.server.close();
    try testing.expectEqual(Client.Stopped.stopped, future.await(io).?);
}

test "every request of a session names it, the connect's ping and a cached client's included" {
    const short: Io.Duration = .fromMilliseconds(250);
    var fake: FakeDaemon = .{ .unused = "music is playing", .client = "0123456789abcdef" };
    var t: FakeSetup = undefined;
    try t.init(&fake);
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Without an id, none is sent.
    var kept: auth.Text(128) = .{};
    try testing.expectEqual(null, t.leaveWith(false, short, &kept));
    try testing.expectEqual(@as(u32, 2), fake.unnamed.load(.acquire));
    try testing.expectEqual(@as(u32, 0), fake.named.load(.acquire));

    t.link.client_id = "0123456789abcdef".*;
    // Connecting pings, then it asks.
    try testing.expectEqual(null, t.leaveWith(false, short, &kept));
    try testing.expectEqual(@as(u32, 2), fake.named.load(.acquire));
    // A client from the secret it keeps.
    @memcpy(t.link.secret[0..FakeDaemon.secret.len], FakeDaemon.secret);
    t.link.secret_len = FakeDaemon.secret.len;
    const c = try t.link.client(arena.allocator());
    try testing.expect(c.ping(arena.allocator()));
    try testing.expectEqual(@as(u32, 3), fake.named.load(.acquire));
    try testing.expectEqual(@as(u32, 2), fake.unnamed.load(.acquire));
}

test "leaving: nothing to do before a quit, or without a background process" {
    var t: TestApp = undefined;
    try t.init();
    defer t.deinit();
    const short: Io.Duration = .fromMilliseconds(250);
    try testing.expectEqual(null, t.app.leaveDaemon(short));
    t.app.quit = false;
    try testing.expectEqual(null, t.app.leaveDaemon(short));
    t.app.quit = true;
    try testing.expectEqual(null, t.app.leaveDaemon(short));
}
