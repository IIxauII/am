//! The TUI's state and what keys do to it: sections with their back stacks of views, focus,
//! overlays, search and filter input, and the selection. Anything that needs the network, the
//! background process or the terminal comes out as an `Effect` for the app to carry out; the
//! app drains `effects` right after every call, while the slices in them are still valid.
const std = @import("std");
const input = @import("input.zig");
const keys = @import("keys.zig");
const list_mod = @import("list.zig");
const model = @import("../music/model.zig");
const player = @import("../daemon/player.zig");
const playstate = @import("playstate.zig");

const Allocator = std.mem.Allocator;
const Item = model.Item;
const Key = input.Key;
const List = list_mod.List;
const Section = keys.Section;
const QueueRequest = player.QueueRequest;

pub const Source = enum {
    /// Everything is in the list already.
    static,
    search,
    artist_view,
    recent_containers,
    recent_tracks,
};

pub const Kind = union(enum) {
    home,
    recent,
    library: model.Kind,
    recently_added,
    favorites,
    radio,
    charts,
    search,
    queue,
    /// An album's or playlist's tracks; `View.subject` is the container.
    tracks,
    /// An artist's sections; `View.subject` is the artist.
    artist,
    /// A group's "see all".
    group: Source,
    /// Library items of one kind that are favorites.
    favorites_scan: model.Kind,
};

pub const View = struct {
    id: u64,
    kind: Kind,
    title: []const u8,
    /// The container or artist of a detail view, copied into `arena`.
    subject: ?Item = null,
    /// Paging a group: the search term, the artist's catalog id, the group key.
    term: []const u8 = "",
    artist_id: []const u8 = "",
    key: []const u8 = "",
    /// The Favorite Songs playlist (favorites view), once known.
    favorites_playlist: ?Item = null,
    /// `subject` holds only what the player knew (`c`); the load looks the container up.
    stub: bool = false,
    arena: std.heap.ArenaAllocator,
    list: List,
    search: ?*Search = null,

    pub fn destroy(v: *View, gpa: Allocator) void {
        v.list.deinit();
        if (v.search) |s| s.deinit(gpa);
        v.arena.deinit();
        gpa.destroy(v);
    }

    /// The container a play-in-context in this view queues, if it is an album or playlist.
    pub fn container(v: *const View) ?player.Container {
        if (v.kind != .tracks) return null;
        return containerOf(v.subject orelse return null);
    }
};

pub const Search = struct {
    query: std.ArrayList(u8) = .empty,
    /// The input has the focus.
    focused: bool = true,
    library: bool = false,
    /// The term the results are for; owned.
    submitted: std.ArrayList(u8) = .empty,
    suggestions: std.ArrayList([]u8) = .empty,
    /// Highlighted suggestion while the input has the focus.
    pick: ?usize = null,
    /// When to ask for suggestions, ms.
    suggest_at: ?i64 = null,
    /// Bumped on every change, so late answers are dropped.
    generation: u32 = 0,

    pub fn deinit(s: *Search, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.submitted.deinit(gpa);
        s.clearSuggestions(gpa);
        s.suggestions.deinit(gpa);
        gpa.destroy(s);
    }

    pub fn clearSuggestions(s: *Search, gpa: Allocator) void {
        for (s.suggestions.items) |t| gpa.free(t);
        s.suggestions.clearRetainingCapacity();
        s.pick = null;
    }
};

pub const Focus = enum { sidebar, main };
pub const Overlay = enum { none, help, info, picker };

pub const ControlValue = union(enum) {
    none,
    number: f64,
    boolean: bool,
    string: []const u8,
    index: u32,
    insert: player.InsertRequest,
};

pub const Ref = struct { view: u64, row: u32 };

pub const Effect = union(enum) {
    /// Load the first or next page of a view.
    load: u64,
    suggest: struct { view: u64, term: []const u8, generation: u32 },
    play: QueueRequest,
    control: struct { action: player.Action, value: ControlValue = .none },
    /// Set the favorite state of a row's item to `on`. Every open copy shows it already; `was`
    /// is what the row showed before.
    favorite: struct { ref: Ref, on: bool, was: ?bool },
    favorite_now,
    add_library: Ref,
    /// Load the playlists a song can be added to, then open the picker.
    pick_playlist: Ref,
    add_to_playlist: struct { playlist: Ref, song: Item },
    /// Find the album or artist of an item, then open it.
    go: struct { ref: Ref, artist: bool },
    quit: struct { stop: bool },
    redraw,
    image_mode,
    toast: []const u8,
    /// Sign in to Apple Music again.
    signin,
};

pub const section_count = std.meta.fieldNames(Section).len;

pub const Ui = struct {
    gpa: Allocator,
    next_id: u64 = 1,
    section: Section = .home,
    stacks: [section_count]std.ArrayList(*View) = @splat(.empty),
    focus: Focus = .main,
    sidebar_pick: usize = 0,
    overlay: Overlay = .none,
    /// The help overlay's first line, when it is taller than the screen (the drawing clamps it).
    help_scroll: usize = 0,
    /// The filter input of the current list has the focus.
    filtering: bool = false,
    /// The add-to-playlist picker: the editable playlists, and the song to add.
    picker: ?*View = null,
    picker_song: ?Item = null,
    picker_arena: ?std.heap.ArenaAllocator = null,
    /// The item the info overlay shows (copied).
    info: ?Item = null,
    info_arena: ?std.heap.ArenaAllocator = null,
    /// List rows on screen, set by the drawing code; paging and page keys use it.
    height: usize = 20,
    /// The sidebar is drawn (wide enough).
    has_sidebar: bool = true,
    /// Which keys run which action.
    bindings: keys.Bindings = .defaults,
    effects: std.ArrayList(Effect) = .empty,
    /// What effects point to that no view keeps (a queue's song ids); reset by `effectsDone`.
    scratch: std.heap.ArenaAllocator,

    /// The latest player state, owned by the app.
    player: ?*const playstate.Snapshot = null,
    /// The volume the next queue starts at; follows the player.
    volume: f64 = 0.5,
    muted_from: ?f64 = null,

    pub fn init(gpa: Allocator) Ui {
        return .{ .gpa = gpa, .scratch = .init(gpa) };
    }

    /// The app carried out every effect: they and what they point to in `scratch` go.
    pub fn effectsDone(u: *Ui) void {
        u.effects.clearRetainingCapacity();
        _ = u.scratch.reset(.{ .retain_with_limit = 64 * 1024 });
    }

    pub fn deinit(u: *Ui) void {
        for (&u.stacks) |*views| {
            for (views.items) |v| v.destroy(u.gpa);
            views.deinit(u.gpa);
        }
        u.closePicker();
        u.closeInfo();
        u.effects.deinit(u.gpa);
        u.scratch.deinit();
    }

    fn emit(u: *Ui, e: Effect) void {
        u.effects.append(u.gpa, e) catch {};
    }

    fn toast(u: *Ui, message: []const u8) void {
        u.emit(.{ .toast = message });
    }

    // ---- Views ----

    fn newView(u: *Ui, kind: Kind, title: []const u8) Allocator.Error!*View {
        const v = try u.gpa.create(View);
        v.* = .{ .id = u.next_id, .kind = kind, .title = "", .arena = .init(u.gpa), .list = .init(u.gpa) };
        u.next_id += 1;
        errdefer v.destroy(u.gpa);
        v.title = try v.arena.allocator().dupe(u8, title);
        if (kind == .search) {
            v.search = try u.gpa.create(Search);
            v.search.?.* = .{};
        }
        return v;
    }

    fn rootKind(s: Section) Kind {
        return switch (s) {
            .home => .home,
            .recent => .recent,
            .songs => .{ .library = .song },
            .albums => .{ .library = .album },
            .artists => .{ .library = .artist },
            .playlists => .{ .library = .playlist },
            .recently_added => .recently_added,
            .favorites => .favorites,
            .radio => .radio,
            .charts => .charts,
            .search => .search,
            .queue => .queue,
        };
    }

    fn stack(u: *Ui) *std.ArrayList(*View) {
        return &u.stacks[@backingInt(u.section)];
    }

    /// The view on top of the current section's stack, made (and its load started) the first time.
    pub fn current(u: *Ui) ?*View {
        const s = u.stack();
        if (s.items.len == 0) {
            const v = u.newView(rootKind(u.section), u.section.title()) catch return null;
            s.append(u.gpa, v) catch {
                v.destroy(u.gpa);
                return null;
            };
            if (v.kind != .search) u.startLoad(v);
        }
        return s.items[s.items.len - 1];
    }

    /// The views of the current section, bottom first (the breadcrumb).
    pub fn trail(u: *Ui) []const *View {
        return u.stack().items;
    }

    pub fn findView(u: *Ui, id: u64) ?*View {
        for (&u.stacks) |*s| for (s.items) |v| if (v.id == id) return v;
        if (u.picker) |p| if (p.id == id) return p;
        return null;
    }

    fn startLoad(u: *Ui, v: *View) void {
        v.list.loading = true;
        u.emit(.{ .load = v.id });
    }

    fn push(u: *Ui, v: *View) void {
        u.stack().append(u.gpa, v) catch {
            v.destroy(u.gpa);
            return;
        };
        u.focus = .main;
        u.filtering = false;
        u.startLoad(v);
    }

    /// Opens a detail view for `it` (album, playlist, artist).
    pub fn openDetail(u: *Ui, it: Item, want: ?[]const u8) void {
        u.openDetailAs(it, want, false);
    }

    fn openDetailAs(u: *Ui, it: Item, want: ?[]const u8, stub: bool) void {
        const kind: Kind = switch (it.kind) {
            .album, .playlist => .tracks,
            .artist => .artist,
            else => return,
        };
        const v = u.newView(kind, it.title) catch return;
        v.stub = stub;
        v.subject = dupeItem(v.arena.allocator(), it) catch {
            v.destroy(u.gpa);
            return;
        };
        v.list.setWant(want);
        u.push(v);
    }

    pub fn goSection(u: *Ui, s: Section) void {
        u.section = s;
        u.overlay = .none;
        u.filtering = false;
        for (keys.sidebar, 0..) |x, i| if (x == s) {
            u.sidebar_pick = i;
        };
        const v = u.current() orelse return;
        u.focus = .main;
        if (v.search) |search| search.focused = true;
    }

    fn back(u: *Ui) void {
        if (u.overlay != .none) {
            if (u.overlay == .picker) u.closePicker();
            if (u.overlay == .info) u.closeInfo();
            u.overlay = .none;
            return;
        }
        const s = u.stack();
        if (s.items.len > 1) {
            const v = s.pop().?;
            v.destroy(u.gpa);
            return;
        }
        if (u.has_sidebar) u.focus = .sidebar;
    }

    pub fn closePicker(u: *Ui) void {
        if (u.picker) |p| p.destroy(u.gpa);
        u.picker = null;
        u.picker_song = null;
        if (u.picker_arena) |*a| a.deinit();
        u.picker_arena = null;
    }

    fn closeInfo(u: *Ui) void {
        u.info = null;
        if (u.info_arena) |*a| a.deinit();
        u.info_arena = null;
    }

    /// The picker for adding `song` to a playlist; the app fills it from `editablePlaylists`.
    pub fn openPicker(u: *Ui, track: Item) ?*View {
        u.closePicker();
        u.closeInfo();
        const v = u.newView(.{ .library = .playlist }, "Add to playlist") catch return null;
        u.picker_arena = .init(u.gpa);
        u.picker_song = dupeItem(u.picker_arena.?.allocator(), track) catch null;
        v.list.loading = true;
        u.picker = v;
        u.overlay = .picker;
        return v;
    }

    pub fn showInfo(u: *Ui, it: Item) void {
        u.closeInfo();
        u.closePicker();
        u.info_arena = .init(u.gpa);
        u.info = dupeItem(u.info_arena.?.allocator(), it) catch null;
        u.overlay = .info;
    }

    // ---- Keys ----

    /// Whether keys go to a text field now.
    pub fn textMode(u: *Ui) bool {
        if (u.overlay != .none) return false;
        if (u.filtering) return true;
        if (u.focus != .main) return false;
        const v = u.current() orelse return false;
        const s = v.search orelse return false;
        return s.focused;
    }

    /// A key from the main UI. `^c` quits from anywhere; in a text field a character types
    /// itself; any other key runs the action it's bound to in the current context, if any.
    pub fn key(u: *Ui, k: Key, now_ms: i64) void {
        if (keys.fixed(k) == .quit) return u.emit(.{ .quit = .{ .stop = false } });
        if (u.textMode()) {
            if (keys.typed(k)) |c| return u.text(.{ .insert = c }, now_ms);
            const a = u.bindings.lookup(.typing, k) orelse return;
            return u.text(a.does.typing, now_ms);
        }
        const a = u.bindings.lookup(.lists, k) orelse return;
        u.command(a.does.lists, now_ms);
    }

    /// A key while the sign-in box covers the session: only the player's keys answer.
    pub fn playerKey(u: *Ui, k: Key, now_ms: i64) void {
        const a = u.bindings.lookup(.lists, k) orelse return;
        switch (a.does.lists) {
            .toggle, .next, .previous, .seek, .volume, .mute => u.command(a.does.lists, now_ms),
            else => {},
        }
    }

    fn command(u: *Ui, cmd: keys.Command, now_ms: i64) void {
        if (u.overlay == .help) {
            switch (cmd) {
                .move => |n| u.scrollHelp(n),
                .page, .half => |n| u.scrollHelp(n * @as(i32, @intCast(@max(1, u.height / 2)))),
                .top => u.help_scroll = 0,
                .bottom => u.help_scroll = std.math.maxInt(u16),
                .quit => u.emit(.{ .quit = .{ .stop = false } }),
                else => u.back(),
            }
            return;
        }
        if (u.overlay == .info) {
            switch (cmd) {
                .quit => u.emit(.{ .quit = .{ .stop = false } }),
                else => u.back(),
            }
            return;
        }
        if (u.overlay == .picker) return u.pickerCommand(cmd);
        switch (cmd) {
            .move => |n| u.moveBy(n),
            .top => u.moveTo(.top),
            .bottom => u.moveTo(.bottom),
            .page => |n| u.moveBy(n * @as(i32, @intCast(@max(1, u.height -| 1)))),
            .half => |n| u.moveBy(n * @as(i32, @intCast(@max(1, u.height / 2)))),
            // Two panes take focus: Tab goes back and forth, h and l pick one. In search results
            // Tab switches catalog / library, as it does while typing; without a sidebar it goes
            // through the sections.
            .focus_next, .focus_prev => {
                if (u.focus == .main) if (u.current()) |v| if (v.search) |s| if (s.submitted.items.len > 0) {
                    // The same term in the other scope, even if the field was edited since.
                    s.query.clearRetainingCapacity();
                    s.query.appendSlice(u.gpa, s.submitted.items) catch return;
                    s.library = !s.library;
                    return u.runSearch(v, s);
                };
                if (!u.has_sidebar) return u.cycleSection(if (cmd == .focus_next) 1 else -1);
                if (u.focus == .sidebar) u.focus = .main else u.focus = .sidebar;
            },
            .focus_right => u.focusMain(),
            .focus_left => {
                if (u.has_sidebar) u.focus = .sidebar;
            },
            .open => u.open(),
            .back => u.back(),
            .section => |s| u.goSection(s),
            .search => {
                u.goSection(.search);
            },
            .filter => {
                if (u.focus == .main) u.filtering = true;
            },
            .toggle => u.emit(.{ .control = .{ .action = .toggle } }),
            .next => u.emit(.{ .control = .{ .action = .next } }),
            .previous => u.emit(.{ .control = .{ .action = .previous } }),
            .seek => |s| u.emit(.{ .control = .{ .action = .seek_by, .value = .{ .number = @floatFromInt(s) } } }),
            .volume => |d| u.changeVolume(@as(f64, @floatFromInt(d)) / 100),
            .mute => u.toggleMute(),
            .shuffle => {
                const on = if (u.player) |p| p.shuffleOn() else false;
                u.emit(.{ .control = .{ .action = .shuffle, .value = .{ .boolean = !on } } });
            },
            .repeat => {
                const mode = if (u.player) |p| p.repeatMode() else .none;
                u.emit(.{ .control = .{ .action = .repeat, .value = .{ .string = @tagName(playstate.repeatNext(mode)) } } });
            },
            .favorite => u.favoriteSelection(),
            .favorite_now => u.emit(.favorite_now),
            .add_library => if (u.selectionRef()) |r| u.emit(.{ .add_library = r }),
            .add_playlist => u.addToPlaylist(),
            .play_later, .play_next => u.insert(cmd == .play_next),
            .play_container => u.playContainer(),
            .station => u.station(),
            .go_album, .go_artist => u.go(cmd == .go_artist),
            .jump_now => u.jumpNow(),
            .remove => u.remove(),
            .info => {
                if (u.selectedItem()) |it| u.showInfo(it.*) else u.toast("Nothing selected");
            },
            .image_mode => u.emit(.image_mode),
            .help => {
                u.overlay = .help;
                u.help_scroll = 0;
            },
            .quit => u.emit(.{ .quit = .{ .stop = false } }),
            .quit_stop => u.emit(.{ .quit = .{ .stop = true } }),
            .refresh => if (u.current()) |v| u.refresh(v),
            .redraw => u.emit(.redraw),
            .signin => u.emit(.signin),
        }
        _ = now_ms;
    }

    fn scrollHelp(u: *Ui, n: i32) void {
        const next = @as(i64, @intCast(u.help_scroll)) + n;
        u.help_scroll = @intCast(std.math.clamp(next, 0, std.math.maxInt(u16)));
    }

    /// The next or previous section in sidebar order, for the tab strip.
    fn cycleSection(u: *Ui, dir: i32) void {
        var i: usize = 0;
        for (keys.sidebar, 0..) |x, j| if (x == u.section) {
            i = j;
        };
        const n: i32 = keys.sidebar.len;
        const next: usize = @intCast(@mod(@as(i32, @intCast(i)) + dir, n));
        u.goSection(keys.sidebar[next]);
    }

    fn refresh(u: *Ui, v: *View) void {
        if (v.kind == .search and v.search.?.submitted.items.len == 0) return;
        // A "see all" of rows the parent already had: nothing to load them from again.
        if (v.kind == .group and v.kind.group == .static) return u.toast("This page reloads with the one it came from: Esc, ^r there");
        v.list.clear();
        u.startLoad(v);
    }

    fn focusMain(u: *Ui) void {
        if (u.focus == .sidebar) return u.openSidebarPick();
        u.focus = .main;
    }

    fn openSidebarPick(u: *Ui) void {
        const s = keys.sidebar[u.sidebar_pick];
        u.goSection(s);
    }

    fn moveBy(u: *Ui, n: i32) void {
        if (u.focus == .sidebar) {
            const next = std.math.clamp(@as(i64, @intCast(u.sidebar_pick)) + n, 0, keys.sidebar.len - 1);
            u.sidebar_pick = @intCast(next);
            return;
        }
        const v = u.current() orelse return;
        if (v.search) |s| if (s.focused) {
            if (n > 0) s.focused = false else return;
        };
        if (v.search) |s| if (n < 0 and v.list.selected == firstSelectable(&v.list)) {
            s.focused = true;
            return;
        };
        v.list.move(n);
        u.maybeMore(v);
    }

    fn firstSelectable(l: *const List) usize {
        var i: usize = 0;
        while (i < l.len()) : (i += 1) if (l.rowAt(i).selectable()) return i;
        return 0;
    }

    fn moveTo(u: *Ui, where: enum { top, bottom }) void {
        if (u.focus == .sidebar) {
            u.sidebar_pick = if (where == .top) 0 else keys.sidebar.len - 1;
            return;
        }
        const v = u.current() orelse return;
        if (where == .top) v.list.top() else v.list.bottom();
        u.maybeMore(v);
    }

    fn maybeMore(u: *Ui, v: *View) void {
        if (v.list.wantsMore(u.height)) u.startLoad(v);
    }

    pub fn selectedRow(u: *Ui) ?*list_mod.Row {
        if (u.focus != .main) return null;
        const v = u.current() orelse return null;
        return v.list.selectedRow();
    }

    pub fn selectedItem(u: *Ui) ?*Item {
        if (u.focus != .main) return null;
        const v = u.current() orelse return null;
        if (v.search) |s| if (s.focused) return null;
        return v.list.selectedItem();
    }

    fn selectionRef(u: *Ui) ?Ref {
        const v = u.current() orelse return null;
        _ = u.selectedItem() orelse {
            u.toast("Nothing selected");
            return null;
        };
        return .{ .view = v.id, .row = v.list.visible.items[v.list.selected] };
    }

    fn open(u: *Ui) void {
        if (u.focus == .sidebar) return u.openSidebarPick();
        const v = u.current() orelse return;
        const row = v.list.selectedRow() orelse return;
        switch (row.tag) {
            .more => u.openGroup(v, row.group),
            .item => u.activate(v, row),
            .header, .note => {},
        }
    }

    /// Enter on an item: open a container or artist, play a song in its context, tune a station.
    fn activate(u: *Ui, v: *View, row: *list_mod.Row) void {
        const it = row.item;
        if (v.kind == .queue) return u.emit(.{ .control = .{ .action = .jump, .value = .{ .index = row.aux } } });
        switch (it.kind) {
            .album, .playlist, .artist => u.openDetail(it, null),
            .station => u.emit(.{ .play = .{ .station = it.id } }),
            .song => {
                if (!it.playable) return u.toast("Apple Music can't play that one here");
                if (v.container()) |c| return u.emit(.{ .play = .{ .container = c, .startId = it.id } });
                const ids = v.list.songIds(u.scratch.allocator(), player.max_songs) catch return;
                if (ids.len == 0) return;
                u.emit(.{ .play = .{ .songs = ids, .startId = it.id } });
            },
            .music_video => u.toast("Music videos don't play in am"),
            .curator => u.toast("Curators can't be opened here"),
        }
    }

    fn openGroup(u: *Ui, parent: *View, index: u16) void {
        const g = parent.list.groups.items[index];
        // Favorites: Favorite Songs is a playlist; the others walk the library.
        if (parent.kind == .favorites) {
            if (std.mem.eql(u8, g.key, "favorite-songs")) {
                if (parent.favorites_playlist) |p| u.openDetail(p, null);
                return;
            }
            const kind: model.Kind = if (std.mem.eql(u8, g.key, "fav-albums")) .album else if (std.mem.eql(u8, g.key, "fav-artists")) .artist else .playlist;
            const v = u.newView(.{ .favorites_scan = kind }, g.title) catch return;
            v.list.only_favorites = true;
            return u.push(v);
        }
        const source: Source = switch (parent.kind) {
            .search => if (std.mem.eql(u8, g.key, "topResults") or g.key.len == 0) .static else .search,
            .artist => if (std.mem.eql(u8, g.key, "library-albums") or g.key.len == 0) .static else .artist_view,
            .recent => if (std.mem.eql(u8, g.key, "recent-tracks")) .recent_tracks else .recent_containers,
            else => .static,
        };
        const v = u.newView(.{ .group = source }, g.title) catch return;
        const a = v.arena.allocator();
        v.key = a.dupe(u8, g.key) catch "";
        if (parent.search) |s| v.term = a.dupe(u8, s.submitted.items) catch "";
        if (parent.subject) |subject| v.artist_id = a.dupe(u8, if (subject.library) subject.catalog_id orelse "" else subject.catalog_id orelse subject.id) catch "";
        if (source == .artist_view and v.artist_id.len == 0) {
            v.kind = .{ .group = .static };
        }
        // Start with what the parent has; paging goes on from its next offset.
        const items = dupeItems(a, g.items) catch return v.destroy(u.gpa);
        v.list.appendPage(items, if (v.kind.group == .static) null else g.next_offset, null) catch {};
        u.stack().append(u.gpa, v) catch return v.destroy(u.gpa);
        u.focus = .main;
        u.maybeMore(v);
    }

    fn favoriteSelection(u: *Ui) void {
        const ref = u.selectionRef() orelse return;
        const v = u.findView(ref.view).?;
        const it = &v.list.rows.items[ref.row].item;
        switch (it.kind) {
            .station, .curator => return u.toast("Stations can't be favorites"),
            else => {},
        }
        const was = it.favorited;
        const on = !(was orelse false);
        u.setFavoriteCopies(it.*, null, on);
        u.emit(.{ .favorite = .{ .ref = ref, .on = on, .was = was } });
    }

    /// Sets the favorite state of every copy of `it` the UI holds: rows in every open view, a
    /// detail view's album, playlist or artist, and the info overlay's item. With `showing`,
    /// only the copies that show it change, so one flipped again in the meantime is left alone.
    pub fn setFavoriteCopies(u: *Ui, it: Item, showing: ?bool, to: ?bool) void {
        for (&u.stacks) |*s| for (s.items) |v| {
            if (v.subject) |*subject| setFavoriteCopy(subject, it, showing, to);
            for (v.list.rows.items) |*r| if (r.tag == .item) setFavoriteCopy(&r.item, it, showing, to);
        };
        if (u.info) |*info| setFavoriteCopy(info, it, showing, to);
    }

    fn addToPlaylist(u: *Ui) void {
        const ref = u.selectionRef() orelse return;
        const it = u.findView(ref.view).?.list.rows.items[ref.row].item;
        if (it.kind != .song) return u.toast("Select a song to add to a playlist");
        u.emit(.{ .pick_playlist = ref });
    }

    fn pickerCommand(u: *Ui, cmd: keys.Command) void {
        const p = u.picker orelse return;
        switch (cmd) {
            .move => |n| p.list.move(n),
            .top => p.list.top(),
            .bottom => p.list.bottom(),
            .page => |n| p.list.move(n * 10),
            .open => {
                const row = p.list.selectedRow() orelse return;
                const track = u.picker_song orelse return;
                u.emit(.{ .add_to_playlist = .{ .playlist = .{ .view = p.id, .row = p.list.visible.items[p.list.selected] }, .song = track } });
                _ = row;
                u.overlay = .none;
            },
            .quit => u.emit(.{ .quit = .{ .stop = false } }),
            else => u.back(),
        }
    }

    fn insert(u: *Ui, next: bool) void {
        const it = (u.selectedItem() orelse return u.toast("Nothing selected")).*;
        const action: player.Action = if (next) .play_next else .play_later;
        const req: player.InsertRequest = switch (it.kind) {
            .song => .{ .songs = u.scratch.allocator().dupe([]const u8, &.{it.id}) catch return },
            .album, .playlist => .{ .container = containerOf(it).? },
            else => return u.toast("Only songs, albums and playlists go into Up Next"),
        };
        u.emit(.{ .control = .{ .action = action, .value = .{ .insert = req } } });
    }

    fn playContainer(u: *Ui) void {
        const v = u.current() orelse return;
        if (u.selectedItem()) |it| switch (it.kind) {
            .album, .playlist => return u.emit(.{ .play = .{ .container = containerOf(it.*).? } }),
            .station => return u.emit(.{ .play = .{ .station = it.id } }),
            else => {},
        };
        if (v.container()) |c| return u.emit(.{ .play = .{ .container = c } });
        u.toast("Select an album or playlist");
    }

    fn station(u: *Ui) void {
        const it = (u.selectedItem() orelse return u.toast("Nothing selected")).*;
        switch (it.kind) {
            .station => u.emit(.{ .play = .{ .station = it.id } }),
            .song => u.emit(.{ .play = .{ .stationFor = .{ .song = it.catalog_id orelse return u.toast("No station for songs that aren't in Apple Music's catalog") } } }),
            .artist => u.emit(.{ .play = .{ .stationFor = .{ .artist = if (it.library) it.catalog_id orelse return u.toast("Apple Music doesn't know this artist") else it.catalog_id orelse it.id } } }),
            else => u.toast("Stations start from a song or an artist"),
        }
    }

    fn go(u: *Ui, artist: bool) void {
        const ref = u.selectionRef() orelse return;
        const it = u.findView(ref.view).?.list.rows.items[ref.row].item;
        if (artist and it.kind == .artist) return u.openDetail(it, null);
        if (!artist and it.kind == .album) return u.openDetail(it, null);
        switch (it.kind) {
            .song, .album, .music_video => u.emit(.{ .go = .{ .ref = ref, .artist = artist } }),
            else => u.toast(if (artist) "No artist to go to" else "No album to go to"),
        }
    }

    fn jumpNow(u: *Ui) void {
        const p = u.player orelse return u.toast("Nothing is playing");
        const np = p.nowPlaying() orelse return u.toast("Nothing is playing");
        const id = np.id orelse return;
        if (u.current()) |v| {
            if (v.list.selectId(id) or (if (np.catalogId) |c| v.list.selectId(c) else false)) {
                u.focus = .main;
                return;
            }
        }
        const c = np.container orelse return u.toast("Not playing from an album or playlist");
        const ctype = c.type orelse return;
        const cid = c.id orelse return;
        const kind: model.Kind = if (std.mem.endsWith(u8, ctype, "albums")) .album else if (std.mem.endsWith(u8, ctype, "playlists")) .playlist else return u.toast("Not playing from an album or playlist");
        // What the player knows; the album's own details come with its tracks.
        var stub: Item = .{ .kind = kind, .id = cid, .library = std.mem.startsWith(u8, ctype, "library-"), .title = c.name orelse np.album orelse "Now playing" };
        if (kind == .album) {
            stub.artist = np.artist;
            if (np.artworkUrl) |url| stub.artwork = .{ .url = url };
        }
        u.openDetailAs(stub, id, true);
    }

    fn remove(u: *Ui) void {
        const v = u.current() orelse return;
        if (v.kind != .queue) return u.toast("d removes from Up Next (press 0)");
        const row = v.list.selectedRow() orelse return;
        if (row.tag != .item) return;
        u.emit(.{ .control = .{ .action = .remove, .value = .{ .index = row.aux } } });
    }

    fn changeVolume(u: *Ui, delta: f64) void {
        const base = if (u.muted_from) |m| m else u.volume;
        u.muted_from = null;
        u.volume = std.math.clamp(@round((base + delta) * 100) / 100, 0, 1);
        u.emit(.{ .control = .{ .action = .volume, .value = .{ .number = u.volume } } });
    }

    fn toggleMute(u: *Ui) void {
        if (u.muted_from) |m| {
            u.volume = m;
            u.muted_from = null;
        } else {
            u.muted_from = u.volume;
            u.volume = 0;
        }
        u.emit(.{ .control = .{ .action = .volume, .value = .{ .number = u.volume } } });
    }

    /// The player reported a volume: follow it, unless muted from here. `loaded`: the engine
    /// has something queued. A fresh engine page has nothing and reports full volume, which
    /// says nothing about what the user wants; following it would start the next queue loud.
    pub fn playerVolume(u: *Ui, v: f64, loaded: bool) void {
        if (!loaded) return;
        if (u.muted_from != null and v == 0) return;
        if (u.muted_from != null) u.muted_from = null;
        u.volume = v;
    }

    // ---- Text fields ----

    fn text(u: *Ui, cmd: keys.TextCommand, now_ms: i64) void {
        const v = u.current() orelse return;
        if (u.filtering) return u.filterText(v, cmd);
        const s = v.search orelse return;
        switch (cmd) {
            .insert => |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return;
                s.query.appendSlice(u.gpa, buf[0..n]) catch return;
                u.queryChanged(s, now_ms);
            },
            .delete_back => {
                deleteLastChar(&s.query);
                u.queryChanged(s, now_ms);
            },
            .clear => {
                s.query.clearRetainingCapacity();
                u.queryChanged(s, now_ms);
            },
            .down => {
                if (s.suggestions.items.len > 0) {
                    s.pick = if (s.pick) |p| @min(p + 1, s.suggestions.items.len - 1) else 0;
                } else if (v.list.len() > 0) s.focused = false;
            },
            .up => {
                if (s.pick) |p| s.pick = if (p == 0) null else p - 1;
            },
            .submit => {
                if (s.pick) |p| {
                    const t = s.suggestions.items[p];
                    s.query.clearRetainingCapacity();
                    s.query.appendSlice(u.gpa, t) catch {};
                }
                u.runSearch(v, s);
            },
            .leave => {
                if (s.pick != null) {
                    s.pick = null;
                    s.clearSuggestions(u.gpa);
                } else if (v.list.len() > 0 or !u.has_sidebar) {
                    // Without results or a sidebar the keys work again from here (/ types again).
                    s.focused = false;
                } else {
                    s.focused = false;
                    u.focus = .sidebar;
                }
            },
            .toggle_scope => {
                s.library = !s.library;
                if (s.submitted.items.len > 0) u.runSearch(v, s);
            },
        }
    }

    /// Pasted text into the field with the focus: the printable characters of one line. The
    /// bytes come from the terminal as they are, so invalid UTF-8 (or a sequence cut at the
    /// paste limit) is skipped rather than trusted.
    pub fn paste(u: *Ui, bytes: []const u8, now_ms: i64) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > bytes.len) break;
            const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch {
                i += 1;
                continue;
            };
            i += n;
            if (cp < 0x20 or cp == 0x7f) continue;
            if (!u.textMode()) return;
            u.text(.{ .insert = cp }, now_ms);
        }
    }

    fn queryChanged(u: *Ui, s: *Search, now_ms: i64) void {
        s.generation +%= 1;
        s.pick = null;
        s.clearSuggestions(u.gpa);
        s.suggest_at = if (std.mem.trim(u8, s.query.items, " ").len >= 2 and !s.library) now_ms + 300 else null;
    }

    fn runSearch(u: *Ui, v: *View, s: *Search) void {
        const term = std.mem.trim(u8, s.query.items, " ");
        if (term.len == 0) return;
        s.submitted.clearRetainingCapacity();
        s.submitted.appendSlice(u.gpa, term) catch return;
        s.clearSuggestions(u.gpa);
        s.suggest_at = null;
        s.generation +%= 1;
        s.focused = false;
        v.list.clear();
        u.startLoad(v);
    }

    fn filterText(u: *Ui, v: *View, cmd: keys.TextCommand) void {
        var f: std.ArrayList(u8) = .empty;
        defer f.deinit(u.gpa);
        f.appendSlice(u.gpa, v.list.filter.items) catch return;
        switch (cmd) {
            .insert => |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return;
                f.appendSlice(u.gpa, buf[0..n]) catch return;
            },
            .delete_back => deleteLastChar(&f),
            .clear => f.clearRetainingCapacity(),
            .submit, .down => {
                u.filtering = false;
                return;
            },
            .leave => {
                u.filtering = false;
                f.clearRetainingCapacity();
            },
            .up, .toggle_scope => return,
        }
        v.list.setFilter(f.items) catch {};
        u.maybeMore(v);
    }

    /// Debounced work, every tick: suggestions, and pages for a list that isn't full.
    pub fn tick(u: *Ui, now_ms: i64) void {
        const v = u.current() orelse return;
        if (v.search) |s| if (s.suggest_at) |at| if (now_ms >= at) {
            s.suggest_at = null;
            if (s.focused) u.emit(.{ .suggest = .{ .view = v.id, .term = std.mem.trim(u8, s.query.items, " "), .generation = s.generation } });
        };
        u.maybeMore(v);
    }
};

fn deleteLastChar(buf: *std.ArrayList(u8)) void {
    var n = buf.items.len;
    if (n == 0) return;
    n -= 1;
    while (n > 0 and (buf.items[n] & 0xC0) == 0x80) n -= 1;
    buf.shrinkRetainingCapacity(n);
}

/// What `queue` plays for an album or playlist.
pub fn containerOf(it: Item) ?player.Container {
    const t: player.ContainerType = switch (it.kind) {
        .album => if (it.library) .@"library-albums" else .albums,
        .playlist => if (it.library) .@"library-playlists" else .playlists,
        else => return null,
    };
    return .{ .type = t, .id = it.id, .name = it.title };
}

/// Whether two items are the same song, album, playlist…: a library item and its catalog item
/// have different ids, but the catalog id of one is the id or catalog id of the other. Songs
/// and music videos count as one kind, since queue rows are all songs.
pub fn sameItem(a: Item, b: Item) bool {
    const track_a = a.kind == .song or a.kind == .music_video;
    const track_b = b.kind == .song or b.kind == .music_video;
    if (a.kind != b.kind and !(track_a and track_b)) return false;
    const ids_a = [2]?[]const u8{ a.id, a.catalog_id };
    const ids_b = [2]?[]const u8{ b.id, b.catalog_id };
    for (ids_a) |x| for (ids_b) |y| {
        const p = x orelse continue;
        const q = y orelse continue;
        if (p.len > 0 and std.mem.eql(u8, p, q)) return true;
    };
    return false;
}

/// `Ui.setFavoriteCopies` for one item: `copy` gets `to` when it is a copy of `it` (and shows
/// `showing`, when given).
pub fn setFavoriteCopy(copy: *Item, it: Item, showing: ?bool, to: ?bool) void {
    if (!sameItem(copy.*, it)) return;
    if (showing) |s| if (copy.favorited != s) return;
    copy.favorited = to;
}

pub fn dupeItem(a: Allocator, it: Item) Allocator.Error!Item {
    var out = it;
    out.id = try a.dupe(u8, it.id);
    out.title = try a.dupe(u8, it.title);
    inline for (.{ "catalog_id", "artist", "album", "release_date", "genre", "description" }) |name| {
        if (@field(it, name)) |s| @field(out, name) = try a.dupe(u8, s);
    }
    if (it.artwork) |art| {
        out.artwork = art;
        out.artwork.?.url = try a.dupe(u8, art.url);
    }
    return out;
}

pub fn dupeItems(a: Allocator, items: []const Item) Allocator.Error![]Item {
    const out = try a.alloc(Item, items.len);
    for (items, out) |it, *o| o.* = try dupeItem(a, it);
    return out;
}

const testing = std.testing;

fn song(id: []const u8, title: []const u8) Item {
    return .{ .kind = .song, .id = id, .catalog_id = id, .title = title, .artist = "Band" };
}

fn takeEffects(u: *Ui) []Effect {
    const out = u.effects.items;
    u.effects.items.len = 0;
    return out;
}

test "sections start their view and its load; Enter opens an album, Esc goes back" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    const home = u.current().?;
    try testing.expectEqual(Kind.home, home.kind);
    try testing.expectEqual(@as(u64, home.id), takeEffects(&u)[0].load);

    u.key(.char('4'), 0);
    const albums = u.current().?;
    try testing.expectEqual(Kind{ .library = .album }, albums.kind);
    try testing.expectEqual(albums.id, takeEffects(&u)[0].load);
    var album: Item = .{ .kind = .album, .id = "l.abc", .library = true, .title = "Trench", .artist = "twenty one pilots" };
    try albums.list.appendPage(&.{album}, null, 1);

    u.key(.{ .code = .enter }, 0);
    const detail = u.current().?;
    try testing.expectEqual(Kind.tracks, detail.kind);
    try testing.expectEqualStrings("Trench", detail.subject.?.title);
    try testing.expectEqual(detail.id, takeEffects(&u)[0].load);
    try testing.expectEqual(@as(usize, 2), u.trail().len);
    // The subject is a copy: the album list's memory can go.
    album.title = "changed";
    try testing.expectEqualStrings("Trench", detail.subject.?.title);

    // Enter on a track plays the album from that track.
    try detail.list.appendPage(&.{ song("i.1", "Jumpsuit"), song("i.2", "Levitate") }, null, 2);
    u.key(.char('j'), 0);
    u.key(.{ .code = .enter }, 0);
    const play = takeEffects(&u)[0].play;
    try testing.expectEqual(player.ContainerType.@"library-albums", play.container.?.type);
    try testing.expectEqualStrings("l.abc", play.container.?.id);
    try testing.expectEqualStrings("i.2", play.startId.?);

    u.key(.{ .code = .esc }, 0);
    try testing.expectEqual(albums, u.current().?);
    // Esc at the root moves the focus to the sidebar.
    u.key(.{ .code = .esc }, 0);
    try testing.expectEqual(Focus.sidebar, u.focus);
    // The sidebar's pick follows the section (Albums); one down is Artists.
    u.key(.char('j'), 0);
    try testing.expectEqual(@as(usize, 4), u.sidebar_pick);
    u.key(.{ .code = .enter }, 0);
    try testing.expectEqual(Section.artists, u.section);
    try testing.expectEqual(Focus.main, u.focus);
}

test "a song outside an album plays the list from there; a station tunes in; P plays the container" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('9'), 0);
    const charts = u.current().?;
    _ = takeEffects(&u);
    try charts.list.appendGroup(.{ .title = "Top Songs", .items = &.{ song("1", "a"), song("2", "b"), song("3", "c") } });
    try charts.list.appendGroup(.{ .title = "Top Albums", .items = &.{.{ .kind = .album, .id = "9", .catalog_id = "9", .title = "x" }} });
    u.key(.char('j'), 0);
    u.key(.{ .code = .enter }, 0);
    const play = takeEffects(&u)[0].play;
    try testing.expectEqual(@as(usize, 3), play.songs.?.len);
    try testing.expectEqualStrings("2", play.startId.?);

    // P on the album plays it from the top.
    u.key(.char('G'), 0);
    u.key(.char('P'), 0);
    try testing.expectEqualStrings("9", takeEffects(&u)[0].play.container.?.id);

    u.key(.char('8'), 0);
    const radio = u.current().?;
    _ = takeEffects(&u);
    try radio.list.appendPage(&.{.{ .kind = .station, .id = "ra.978194965", .title = "Apple Music 1", .is_live = true }}, null, null);
    u.key(.{ .code = .enter }, 0);
    try testing.expectEqualStrings("ra.978194965", takeEffects(&u)[0].play.station.?);
    u.key(.char('R'), 0);
    try testing.expectEqualStrings("ra.978194965", takeEffects(&u)[0].play.station.?);
}

test "favorite flips the row at once and is put back when Apple refuses" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('3'), 0);
    const songs = u.current().?;
    _ = takeEffects(&u);
    var s = song("i.1", "a");
    s.library = true;
    s.favorited = false;
    try songs.list.appendPage(&.{s}, null, 1);
    u.key(.char('f'), 0);
    const e = takeEffects(&u)[0].favorite;
    try testing.expect(e.on);
    try testing.expectEqual(@as(?bool, true), songs.list.rows.items[e.ref.row].item.favorited);
    u.setFavoriteCopies(s, true, e.was);
    try testing.expectEqual(@as(?bool, false), songs.list.rows.items[e.ref.row].item.favorited);
    // A failure for an item no longer there changes nothing.
    u.setFavoriteCopies(song("2", "b"), true, false);
}

test "favorite: every open copy of the song shows the same heart, also after a failure" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    // The song from the catalog, in a view on another section's stack.
    u.key(.char('1'), 0);
    const home = u.current().?;
    _ = takeEffects(&u);
    try home.list.appendPage(&.{
        song("100", "a"),
        song("200", "other"),
        .{ .kind = .album, .id = "100", .catalog_id = "100", .title = "an album, same number" },
    }, null, 3);
    // The same song from the library: its own id, the catalog id beside it.
    u.key(.char('3'), 0);
    const songs = u.current().?;
    _ = takeEffects(&u);
    var lib = song("i.1", "a");
    lib.catalog_id = "100";
    lib.library = true;
    lib.favorited = false;
    try songs.list.appendPage(&.{lib}, null, 1);

    u.key(.char('f'), 0);
    const e = takeEffects(&u)[0].favorite;
    try testing.expect(e.on);
    try testing.expectEqual(@as(?bool, true), home.list.rows.items[0].item.favorited);
    try testing.expectEqual(@as(?bool, null), home.list.rows.items[1].item.favorited);
    try testing.expectEqual(@as(?bool, null), home.list.rows.items[2].item.favorited);

    u.setFavoriteCopies(lib, true, e.was);
    try testing.expectEqual(@as(?bool, false), songs.list.rows.items[0].item.favorited);
    try testing.expectEqual(@as(?bool, false), home.list.rows.items[0].item.favorited);
    try testing.expectEqual(@as(?bool, null), home.list.rows.items[1].item.favorited);
}

test "favorite: an open album's header and the info overlay show the new heart too" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    var album: Item = .{ .kind = .album, .id = "9", .catalog_id = "9", .title = "x", .favorited = false };
    u.key(.char('1'), 0);
    _ = takeEffects(&u);
    u.openDetail(album, null);
    const detail = u.current().?;
    _ = takeEffects(&u);
    u.key(.char('4'), 0);
    const albums = u.current().?;
    _ = takeEffects(&u);
    album.id = "l.9";
    album.library = true;
    try albums.list.appendPage(&.{album}, null, 1);

    u.key(.char('f'), 0);
    const e = takeEffects(&u)[0].favorite;
    try testing.expectEqual(@as(?bool, true), detail.subject.?.favorited);
    u.key(.char('i'), 0);
    try testing.expectEqual(@as(?bool, true), u.info.?.favorited);

    u.setFavoriteCopies(album, true, e.was);
    try testing.expectEqual(@as(?bool, false), detail.subject.?.favorited);
    try testing.expectEqual(@as(?bool, false), u.info.?.favorited);
}

test "favorite: a heart that wasn't known goes back to unknown after a failure, not to no" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('3'), 0);
    const songs = u.current().?;
    _ = takeEffects(&u);
    try songs.list.appendPage(&.{song("1", "a")}, null, 1);
    u.key(.char('f'), 0);
    const e = takeEffects(&u)[0].favorite;
    try testing.expect(e.on);
    try testing.expectEqual(@as(?bool, null), e.was);
    u.setFavoriteCopies(song("1", "a"), true, e.was);
    try testing.expectEqual(@as(?bool, null), songs.list.rows.items[0].item.favorited);
}

test "search: typing debounces suggestions, Enter searches, see-all pages the section" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    _ = takeEffects(&u);
    u.key(.char('/'), 0);
    const v = u.current().?;
    try testing.expect(u.textMode());
    try testing.expectEqual(@as(usize, 0), takeEffects(&u).len); // nothing to load before a term
    for ("shy") |c| u.key(.char(c), 1000);
    u.tick(1200);
    try testing.expectEqual(@as(usize, 0), takeEffects(&u).len);
    u.tick(1300);
    const sug = takeEffects(&u)[0].suggest;
    try testing.expectEqualStrings("shy", sug.term);
    // Digits and space are text here.
    u.key(.char(' '), 1400);
    u.key(.char('1'), 1400);
    u.key(.{ .code = .backspace }, 1400);
    u.key(.{ .code = .enter }, 1500);
    try testing.expectEqual(v.id, takeEffects(&u)[0].load);
    try testing.expectEqualStrings("shy", v.search.?.submitted.items);
    try testing.expect(!u.textMode());

    try v.list.appendGroup(.{ .title = "Songs", .key = "songs", .items = &.{ song("1", "Shy Away"), song("2", "x") }, .next_offset = 25, .limit = 1 });
    u.key(.char('j'), 0); // to "See all"
    u.key(.{ .code = .enter }, 0);
    const all = u.current().?;
    try testing.expectEqual(Kind{ .group = .search }, all.kind);
    try testing.expectEqualStrings("shy", all.term);
    try testing.expectEqualStrings("songs", all.key);
    try testing.expectEqual(@as(usize, 2), all.list.len());
    try testing.expectEqual(@as(?u32, 25), all.list.next_offset);
    // Two rows on a 20-row screen: the next page is asked for at once.
    try testing.expectEqual(all.id, takeEffects(&u)[0].load);
}

test "a paste with invalid UTF-8 or a cut-off sequence types only what decodes" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('/'), 0);
    const v = u.current().?;
    u.paste("ab\xffc\xc3\xa9\n\x80d\xe2\x82", 0);
    try testing.expectEqualStrings("abc\u{e9}d", v.search.?.query.items);
}

test "^r reloads a view (a fresh epoch drops loads already on their way), not a static see-all" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('9'), 0);
    const charts = u.current().?;
    _ = takeEffects(&u);
    try charts.list.appendGroup(.{ .title = "Top Songs", .items = &.{ song("1", "a"), song("2", "b") }, .limit = 1 });
    const before = charts.list.epoch;
    u.key(.ctrlChar('r'), 0);
    try testing.expect(charts.list.epoch != before);
    try testing.expectEqual(charts.id, takeEffects(&u)[0].load);
    try charts.list.appendGroup(.{ .title = "Top Songs", .items = &.{ song("1", "a"), song("2", "b") }, .limit = 1 });
    u.key(.char('j'), 0);
    u.key(.{ .code = .enter }, 0);
    const all = u.current().?;
    try testing.expectEqual(Kind{ .group = .static }, all.kind);
    _ = takeEffects(&u);
    u.key(.ctrlChar('r'), 0);
    try testing.expectEqual(@as(usize, 2), all.list.len());
    try testing.expectEqual(std.meta.Tag(Effect).toast, std.meta.activeTag(takeEffects(&u)[0]));
}

test "filter narrows the current list and Esc clears it" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('3'), 0);
    const v = u.current().?;
    _ = takeEffects(&u);
    try v.list.appendPage(&.{ song("1", "Shy Away"), song("2", "Heathens") }, null, 2);
    u.key(.ctrlChar('f'), 0);
    try testing.expect(u.textMode());
    for ("hea") |c| u.key(.char(c), 0);
    try testing.expectEqual(@as(usize, 1), v.list.len());
    u.key(.{ .code = .esc }, 0);
    try testing.expect(!u.textMode());
    try testing.expectEqual(@as(usize, 2), v.list.len());
}

test "player keys become control effects; volume and mute are remembered" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    _ = takeEffects(&u);
    u.volume = 0.2;
    u.key(.char(' '), 0);
    try testing.expectEqual(player.Action.toggle, takeEffects(&u)[0].control.action);
    u.key(.char('['), 0);
    try testing.expectEqual(@as(f64, -30), takeEffects(&u)[0].control.value.number);
    u.key(.char('-'), 0);
    try testing.expectApproxEqAbs(@as(f64, 0.15), u.volume, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.15), takeEffects(&u)[0].control.value.number, 1e-9);
    u.key(.char('m'), 0);
    try testing.expectEqual(@as(f64, 0), takeEffects(&u)[0].control.value.number);
    u.playerVolume(0, true); // the player confirms the mute
    try testing.expectApproxEqAbs(@as(f64, 0.15), u.muted_from.?, 1e-9);
    u.key(.char('m'), 0);
    try testing.expectApproxEqAbs(@as(f64, 0.15), takeEffects(&u)[0].control.value.number, 1e-9);
    u.key(.char('r'), 0);
    try testing.expectEqualStrings("all", takeEffects(&u)[0].control.value.string);
    u.key(.char('s'), 0);
    try testing.expect(takeEffects(&u)[0].control.value.boolean);
    // Volume stops at full.
    u.volume = 0.98;
    u.key(.char('+'), 0);
    try testing.expectEqual(@as(f64, 1), u.volume);
    u.volume = 0.1;
    // A new engine page with nothing queued says 1: not followed.
    u.playerVolume(1, false);
    try testing.expectEqual(@as(f64, 0.1), u.volume);
    u.playerVolume(0.3, true);
    try testing.expectEqual(@as(f64, 0.3), u.volume);
}

test "queue view: Enter jumps, d removes; d elsewhere explains" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('0'), 0);
    const q = u.current().?;
    _ = takeEffects(&u);
    try q.list.appendPage(&.{ song("a", "a"), song("b", "b") }, null, null);
    q.list.rows.items[1].aux = 7;
    u.key(.char('j'), 0);
    u.key(.{ .code = .enter }, 0);
    try testing.expectEqual(@as(u32, 7), takeEffects(&u)[0].control.value.index);
    u.key(.char('d'), 0);
    const rm = takeEffects(&u)[0].control;
    try testing.expectEqual(player.Action.remove, rm.action);
    try testing.expectEqual(@as(u32, 7), rm.value.index);
    u.key(.char('1'), 0);
    _ = takeEffects(&u);
    u.key(.char('d'), 0);
    try testing.expectEqual(std.meta.Tag(Effect).toast, std.meta.activeTag(takeEffects(&u)[0]));
}

test "Tab in search results switches catalog / library; Esc leaves an empty search without a sidebar" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    _ = takeEffects(&u);
    u.key(.char('/'), 0);
    const v = u.current().?;
    for ("queen") |c| u.key(.char(c), 0);
    u.key(.{ .code = .enter }, 0);
    _ = takeEffects(&u);
    // Typed on after submitting, then back to the results.
    u.key(.char('k'), 0);
    u.key(.char('x'), 0);
    u.key(.{ .code = .down }, 0);
    v.search.?.focused = false;
    u.key(.{ .code = .tab }, 0);
    try testing.expect(v.search.?.library);
    try testing.expectEqualStrings("queen", v.search.?.submitted.items);
    try testing.expectEqual(v.id, takeEffects(&u)[0].load);
    try testing.expectEqual(Focus.main, u.focus);

    // Narrow: no sidebar, no results. Esc gives the keys back, Tab goes through the sections.
    u.has_sidebar = false;
    u.key(.char('/'), 0);
    v.search.?.submitted.clearRetainingCapacity();
    v.search.?.query.clearRetainingCapacity();
    v.list.clear();
    try testing.expect(u.textMode());
    u.key(.{ .code = .esc }, 0);
    try testing.expect(!u.textMode());
    u.key(.char('9'), 0);
    try testing.expectEqual(Section.charts, u.section);
    u.key(.{ .code = .tab }, 0);
    try testing.expectEqual(Section.search, u.section);
    // Search gives its field the keys; Esc gives them back.
    try testing.expect(u.textMode());
    u.key(.{ .code = .tab, .shift = true }, 0);
    try testing.expectEqual(Section.search, u.section);
    u.key(.{ .code = .esc }, 0);
    u.key(.{ .code = .tab, .shift = true }, 0);
    u.key(.{ .code = .tab, .shift = true }, 0);
    try testing.expectEqual(Section.radio, u.section);
}

test "c opens the playing album with what the player knows of it" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    _ = takeEffects(&u);
    const snap = try playstate.parse(testing.allocator,
        \\{"report":{"playbackState":"playing","nowPlaying":{"id":"i.9","title":"Run","artist":"Band","album":"Dark",
        \\ "artworkUrl":"https://x/{w}x{h}bb.jpg","container":{"type":"library-albums","id":"l.7","name":"Dark"}}}}
    , 0);
    defer snap.destroy();
    u.player = snap;
    u.key(.char('c'), 0);
    const v = u.current().?;
    try testing.expectEqual(Kind.tracks, v.kind);
    try testing.expectEqualStrings("Band", v.subject.?.artist.?);
    try testing.expectEqualStrings("https://x/{w}x{h}bb.jpg", v.subject.?.artwork.?.url);
    try testing.expectEqualStrings("i.9", v.list.want_id.?);
    try testing.expect(v.stub);
}

test "help closes on any key but scrolling; quit from anywhere" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    _ = takeEffects(&u);
    u.key(.char('?'), 0);
    try testing.expectEqual(Overlay.help, u.overlay);
    // j / k scroll it; anything else closes it.
    u.key(.char('j'), 0);
    try testing.expectEqual(Overlay.help, u.overlay);
    try testing.expectEqual(@as(usize, 1), u.help_scroll);
    u.key(.{ .code = .enter }, 0);
    try testing.expectEqual(Overlay.none, u.overlay);
    u.key(.char('Q'), 0);
    try testing.expect(takeEffects(&u)[0].quit.stop);
}

test "a key matches whole: Alt+j and Shift+↓ do nothing while j moves; Shift+Enter still opens" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('3'), 0);
    const v = u.current().?;
    _ = takeEffects(&u);
    try v.list.appendPage(&.{ song("1", "a"), song("2", "b"), song("3", "c") }, null, 3);

    u.key(.{ .code = .{ .char = 'j' }, .alt = true }, 0);
    u.key(.{ .code = .down, .shift = true }, 0);
    try testing.expectEqual(@as(usize, 0), takeEffects(&u).len);
    u.key(.{ .code = .enter, .shift = true }, 0);
    try testing.expectEqualStrings("1", takeEffects(&u)[0].play.startId.?);

    u.key(.char('j'), 0);
    // Ctrl+m is Enter wherever the terminal sends it apart.
    u.key(.ctrlChar('m'), 0);
    try testing.expectEqualStrings("2", takeEffects(&u)[0].play.startId.?);
}

test "keys only some terminals tell apart work as the shared key, in a list and in a text field" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    u.key(.char('3'), 0);
    const v = u.current().?;
    _ = takeEffects(&u);
    try v.list.appendPage(&.{ song("1", "a"), song("2", "b"), song("3", "c") }, null, 3);

    // Shift+g is G (bottom); Ctrl+j is Enter.
    u.key(.{ .code = .{ .char = 'g' }, .shift = true }, 0);
    u.key(.ctrlChar('j'), 0);
    try testing.expectEqualStrings("3", takeEffects(&u)[0].play.startId.?);
    // Ctrl+Shift+u is ^u (half page up); Ctrl+Enter is Enter.
    u.key(.{ .code = .{ .char = 'u' }, .ctrl = true, .shift = true }, 0);
    u.key(.{ .code = .enter, .ctrl = true }, 0);
    try testing.expectEqualStrings("1", takeEffects(&u)[0].play.startId.?);
    // Ctrl+i is Tab; Ctrl+Alt+i is Alt+Tab, a key of its own that does nothing.
    u.key(.{ .code = .{ .char = 'i' }, .ctrl = true, .alt = true }, 0);
    try testing.expectEqual(Focus.main, u.focus);
    u.key(.ctrlChar('i'), 0);
    try testing.expectEqual(Focus.sidebar, u.focus);
    u.key(.ctrlChar('i'), 0);
    try testing.expectEqual(Focus.main, u.focus);
    // Ctrl+[ is Esc: at a section's root it moves the focus to the sidebar.
    u.key(.ctrlChar('['), 0);
    try testing.expectEqual(Focus.sidebar, u.focus);

    // In a text field: Ctrl+i switches catalog / library, Ctrl+[ leaves, Ctrl+j searches.
    u.key(.char('/'), 0);
    _ = takeEffects(&u);
    const s = u.current().?.search.?;
    for ("queen") |c| u.key(.char(c), 0);
    u.key(.ctrlChar('i'), 0);
    try testing.expect(s.library);
    u.key(.ctrlChar('['), 0);
    try testing.expect(!u.textMode());
    try testing.expectEqual(Focus.sidebar, u.focus);
    u.key(.char('/'), 0);
    u.key(.ctrlChar('j'), 0);
    try testing.expectEqualStrings("queen", s.submitted.items);
}

test "^c quits from a list, a text field and the help; q types in a field" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    _ = takeEffects(&u);
    u.key(.ctrlChar('c'), 0);
    try testing.expect(!takeEffects(&u)[0].quit.stop);

    u.key(.char('/'), 0);
    _ = takeEffects(&u);
    try testing.expect(u.textMode());
    u.key(.char('q'), 0);
    try testing.expectEqual(@as(usize, 0), takeEffects(&u).len);
    // Ctrl+Shift+c, as Ghostty sends it, is ^c.
    u.key(.{ .code = .{ .char = 'c' }, .ctrl = true, .shift = true }, 0);
    try testing.expect(!takeEffects(&u)[0].quit.stop);

    u.key(.{ .code = .esc }, 0);
    u.key(.char('?'), 0);
    try testing.expectEqual(Overlay.help, u.overlay);
    u.key(.ctrlChar('c'), 0);
    try testing.expect(!takeEffects(&u)[0].quit.stop);
}

test "in a text field every character types itself, shifted ones too; Alt+x types nothing" {
    var u: Ui = .init(testing.allocator);
    defer u.deinit();
    _ = u.current();
    u.key(.char('/'), 0);
    const s = u.current().?.search.?;
    for ([_]Key{
        .char('q'),
        .char('4'),
        .{ .code = .{ .char = ' ' }, .shift = true },
        .{ .code = .{ .char = 'a' }, .shift = true },
        .{ .code = .{ .char = 'x' }, .alt = true },
        .char(0xe9),
    }) |k| u.key(k, 0);
    try testing.expectEqualStrings("q4 A\u{e9}", s.query.items);
    // Ctrl+h is Backspace; ^u clears.
    u.key(.ctrlChar('h'), 0);
    try testing.expectEqualStrings("q4 A", s.query.items);
    u.key(.ctrlChar('u'), 0);
    try testing.expectEqualStrings("", s.query.items);
}
