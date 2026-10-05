//! "New project" — the add-space palette (zeron `shell/spaces.rs`
//! `AddSpaceFlow` + `render_add_space_overlay`): Cmd+K's glass card walking
//! devices → locations (Home + mounted drives, `ListDrives`) → folders
//! (`ListFolders`), with a breadcrumb trail (deep paths fold into `…`),
//! ranked filtering, ⇥ completion ghost, typed path jumps (`/mnt/x/`,
//! `~/code/`), `/` descend, ← / ⌫ up a level and ⌘⏎ to add the open folder
//! (`Mutate createSpace`; an existing (device, path) pair just lands there).
//!
//! Fixture mode (no engine) browses the local filesystem directly.
//!
//! ```zig
//! const p = try cx.newWith(AddProject, AddProject.init, .{ app_state, fixtures, window });
//! // events: AddProject.Close, AddProject.Created{ .space_id }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const menu = @import("menu.zig");
const paths = @import("paths.zig");
const fixtures_mod = @import("../shell/fixtures.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const Icon = ui.icon.Icon;
const es = model.engine_state;
const Device = engine.protocol.Device;

pub const Close = struct {};
pub const Created = struct { space_id: []const u8 };

pub const Step = enum { devices, locations, folders };

pub const FolderEntry = struct { name: []const u8, isDir: bool = false, isRepo: bool = false };
pub const FolderListing = struct { path: []const u8, entries: []FolderEntry = &.{}, truncated: bool = false };
pub const DriveEntry = struct { name: []const u8, path: []const u8 };
const DriveListing = struct { drives: []DriveEntry = &.{} };

const Load = enum { idle, loading, ready, failed };

/// Folder crumbs shown before the middle folds into `…`, and the deepest
/// kept once it does.
const crumb_folders_max: usize = 3;
const crumb_folders_tail: usize = 2;

fn mod() []const u8 {
    return if (builtin.os.tag == .macos) "⌘" else "Ctrl+";
}

pub const AddProject = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    fixtures: ?*fixtures_mod.Fixtures,
    search: Entity(input.TextInput),
    focus: zpui.FocusHandle,
    list_scroll: zpui.ScrollHandle,
    crumb_scroll: zpui.ScrollHandle,
    subs: zpui.Subscriptions = .{},

    step: Step = .devices,
    device_id: ?[]u8 = null,
    /// (name, path) — a null path is the device's home.
    location_name: ?[]u8 = null,
    location_path: ?[]u8 = null,
    listing_state: Load = .idle,
    listing: ?FolderListing = null,
    listing_arena: std.heap.ArenaAllocator,
    listing_error: ?[]u8 = null,
    drives_state: Load = .idle,
    drives: []DriveEntry = &.{},
    drives_arena: std.heap.ArenaAllocator,
    browser_path: ?[]u8 = null,
    home: ?[]u8 = null,
    browser_repo: bool = false,
    active: usize = 0,
    busy: bool = false,
    err: ?[]u8 = null,
    crumb_menu_open: bool = false,
    crumb_key: u64 = 0,
    scratch: std.heap.ArenaAllocator,
    /// The create in flight (for the reply).
    pending_space: ?[36]u8 = null,

    pub const Events = .{ Close, Created };

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, window: *Window, cx: *Context(AddProject)) !AddProject {
        const theme = ui.theme.get(cx).forPopup();
        const search = try cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Search devices…",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 14,
            .line_height = 20,
            .edge_fade = false,
            .colors = .{ .text = theme.text, .placeholder = theme.text_muted, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }});
        var self: AddProject = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .fixtures = fixtures,
            .search = search,
            .focus = cx.focusHandle(),
            .list_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .crumb_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .listing_arena = std.heap.ArenaAllocator.init(cx.gpa()),
            .drives_arena = std.heap.ArenaAllocator.init(cx.gpa()),
            .scratch = std.heap.ArenaAllocator.init(cx.gpa()),
        };
        try self.subs.add(cx.gpa(), try cx.subscribe(search, onSearch));
        window.focus(search.read(cx).focusHandle());
        return self;
    }

    pub fn deinit(self: *AddProject, app: *App) void {
        self.subs.deinit(self.gpa);
        inline for (.{ "device_id", "location_name", "location_path", "listing_error", "browser_path", "home", "err" }) |f| freeOpt(self.gpa, &@field(self, f));
        self.listing_arena.deinit();
        self.drives_arena.deinit();
        self.scratch.deinit();
        self.list_scroll.release();
        self.crumb_scroll.release();
        self.focus.release(app);
        self.search.release(app);
        self.state.release(app);
    }

    fn tmp(self: *AddProject) std.mem.Allocator {
        return self.scratch.allocator();
    }

    fn ws(self: *const AddProject, cx: anytype) *const model.WorkspaceStore {
        return self.state.read(cx).workspace.read(cx);
    }

    fn isLocal(self: *const AddProject, cx: anytype) bool {
        const id = self.device_id orelse return true;
        const local = self.ws(cx).local_device_id orelse return true;
        return std.mem.eql(u8, id, local);
    }

    fn query(self: *const AddProject, cx: anytype) []const u8 {
        return self.search.read(cx).text();
    }

    fn setQuery(self: *AddProject, text: []const u8, placeholder: ?[]const u8, cx: *Context(AddProject)) void {
        if (placeholder) |p| self.search.update(cx, input.TextInput.setPlaceholder, .{p});
        self.search.update(cx, input.TextInput.setText, .{text});
    }

    // ---- rows -------------------------------------------------------------------------

    fn devices(self: *AddProject, cx: anytype) []const *const Device {
        const all = self.ws(cx).devices();
        const a = self.tmp();
        const names = a.alloc([]const u8, all.len) catch return &.{};
        for (all, 0..) |d, i| names[i] = d.name;
        const buf = a.alloc(usize, all.len) catch return &.{};
        const ix = menu.filterIndices(self.query(cx), names, buf);
        const out = a.alloc(*const Device, ix.len) catch return &.{};
        for (ix, 0..) |i, j| out[j] = &all[i];
        return out;
    }

    const Location = struct { name: []const u8, path: ?[]const u8 };

    fn locations(self: *AddProject, cx: anytype) []const Location {
        const a = self.tmp();
        var all: std.ArrayList(Location) = .empty;
        all.append(a, .{ .name = "Home", .path = null }) catch return &.{};
        for (self.drives) |d| all.append(a, .{ .name = d.name, .path = d.path }) catch {};
        const names = a.alloc([]const u8, all.items.len) catch return &.{};
        for (all.items, 0..) |l, i| names[i] = l.name;
        const buf = a.alloc(usize, all.items.len) catch return &.{};
        const ix = menu.filterIndices(self.query(cx), names, buf);
        const out = a.alloc(Location, ix.len) catch return &.{};
        for (ix, 0..) |i, j| out[j] = all.items[i];
        return out;
    }

    /// Directory rows of the listing matching the query.
    fn folders(self: *AddProject, cx: anytype) []const FolderEntry {
        if (self.step != .folders or self.listing_state != .ready) return &.{};
        const listing = self.listing orelse return &.{};
        const a = self.tmp();
        var dirs: std.ArrayList(FolderEntry) = .empty;
        for (listing.entries) |e| if (e.isDir) dirs.append(a, e) catch {};
        const names = a.alloc([]const u8, dirs.items.len) catch return &.{};
        for (dirs.items, 0..) |d, i| names[i] = d.name;
        const buf = a.alloc(usize, dirs.items.len) catch return &.{};
        const ix = menu.filterIndices(self.query(cx), names, buf);
        const out = a.alloc(FolderEntry, ix.len) catch return &.{};
        for (ix, 0..) |i, j| out[j] = dirs.items[i];
        return out;
    }

    fn rowCount(self: *AddProject, cx: anytype) usize {
        return switch (self.step) {
            .devices => self.devices(cx).len,
            .locations => self.locations(cx).len,
            .folders => self.folders(cx).len,
        };
    }

    // ---- steps ------------------------------------------------------------------------

    fn pickDevice(self: *AddProject, id: []const u8, cx: *Context(AddProject)) void {
        const copy = self.gpa.dupe(u8, id) catch return;
        freeOpt(self.gpa, &self.device_id);
        self.device_id = copy;
        self.step = .locations;
        self.clearLocation();
        freeOpt(self.gpa, &self.home);
        self.resetCommon();
        self.setQuery("", "Search locations…", cx);
        self.loadDrives(cx);
        cx.notify();
    }

    fn clearLocation(self: *AddProject) void {
        freeOpt(self.gpa, &self.location_name);
        freeOpt(self.gpa, &self.location_path);
        freeOpt(self.gpa, &self.browser_path);
        self.listing_state = .idle;
        self.listing = null;
        _ = self.listing_arena.reset(.retain_capacity);
    }

    fn resetCommon(self: *AddProject) void {
        self.browser_repo = false;
        self.active = 0;
        freeOpt(self.gpa, &self.err);
        self.crumb_menu_open = false;
        self.list_scroll.setOffset(.{ .x = 0, .y = 0 });
    }

    fn gotoLocation(self: *AddProject, name: []const u8, path: ?[]const u8, cx: *Context(AddProject)) void {
        const n = self.gpa.dupe(u8, name) catch return;
        const p: ?[]u8 = if (path) |x| self.gpa.dupe(u8, x) catch null else null;
        self.clearLocation();
        self.location_name = n;
        self.location_path = p;
        self.step = .folders;
        self.browser_repo = false;
        self.setQuery("", "Search folders…", cx);
        self.loadFolders(p, cx);
    }

    fn backTo(self: *AddProject, step: Step, cx: *Context(AddProject)) void {
        self.step = step;
        self.clearLocation();
        self.resetCommon();
        if (step == .devices) {
            freeOpt(self.gpa, &self.device_id);
            freeOpt(self.gpa, &self.home);
            self.drives = &.{};
            self.drives_state = .idle;
        }
        self.setQuery("", if (step == .devices) "Search devices…" else "Search locations…", cx);
        cx.notify();
    }

    fn descend(self: *AddProject, full: []const u8, is_repo: bool, cx: *Context(AddProject)) void {
        self.browser_repo = is_repo;
        const copy = self.gpa.dupe(u8, full) catch return;
        defer self.gpa.free(copy);
        self.setQuery("", null, cx);
        self.loadFolders(copy, cx);
    }

    fn openActive(self: *AddProject, cx: *Context(AddProject)) void {
        switch (self.step) {
            .devices => {
                const rows = self.devices(cx);
                if (self.active < rows.len) self.pickDevice(rows[self.active].id, cx);
            },
            .locations => {
                const rows = self.locations(cx);
                if (self.active < rows.len) self.gotoLocation(rows[self.active].name, rows[self.active].path, cx);
            },
            .folders => {
                const rows = self.folders(cx);
                if (rows.len == 0) {
                    // A path-shaped query with no matching rows browses the typed path.
                    if (paths.typedPathTarget(self.tmp(), self.query(cx), self.home)) |t| self.descend(t, false, cx);
                    return;
                }
                const listing = self.listing orelse return;
                if (self.active >= rows.len) return;
                const e = rows[self.active];
                self.descend(paths.childPath(self.tmp(), listing.path, e.name), e.isRepo, cx);
            },
        }
    }

    /// Back traverses folders, then locations, then devices.
    fn goUp(self: *AddProject, cx: *Context(AddProject)) void {
        switch (self.step) {
            .devices => {},
            .locations => self.backTo(.devices, cx),
            .folders => {
                const root = self.location_path orelse self.home;
                const listing = self.listing;
                const at_root = if (listing) |l| (root != null and std.mem.eql(u8, l.path, root.?)) else true;
                const parent = if (!at_root) paths.parentPath(self.tmp(), listing.?.path) else null;
                if (parent) |p| self.descend(p, false, cx) else self.backTo(.locations, cx);
            },
        }
    }

    /// The ⇥ completion: (full name, remaining suffix).
    fn completion(self: *AddProject, cx: anytype) ?struct { []const u8, []const u8 } {
        const q = self.query(cx);
        if (q.len == 0) return null;
        const rows = self.folders(cx);
        var pick: ?FolderEntry = null;
        if (self.active < rows.len and paths.completionPrefixLen(rows[self.active].name, q) != null) pick = rows[self.active];
        if (pick == null) for (rows) |r| if (paths.completionPrefixLen(r.name, q) != null) {
            pick = r;
            break;
        };
        const e = pick orelse return null;
        const n = paths.completionPrefixLen(e.name, q) orelse return null;
        if (n >= e.name.len) return null;
        return .{ e.name, e.name[n..] };
    }

    /// `/` after a folder-naming (or path-shaped) query descends.
    fn slashDescend(self: *AddProject, cx: *Context(AddProject)) bool {
        if (self.step != .folders) return false;
        const q = self.query(cx);
        if (q.len == 0 or !(q[q.len - 1] == '/' or q[q.len - 1] == '\\')) return false;
        if (paths.isTypedPath(q)) {
            const t = paths.typedPathTarget(self.tmp(), q, self.home) orelse return false;
            self.descend(t, false, cx);
            return true;
        }
        const seg = q[0 .. q.len - 1];
        if (seg.len == 0 or std.mem.indexOfScalar(u8, seg, '/') != null) return false;
        const listing = self.listing orelse return false;
        var names: std.ArrayList([]const u8) = .empty;
        var entries: std.ArrayList(FolderEntry) = .empty;
        for (listing.entries) |e| if (e.isDir) {
            names.append(self.tmp(), e.name) catch return false;
            entries.append(self.tmp(), e) catch return false;
        };
        const ix = paths.segmentTarget(names.items, seg) orelse return false;
        self.descend(paths.childPath(self.tmp(), listing.path, entries.items[ix].name), entries.items[ix].isRepo, cx);
        return true;
    }

    // ---- loads ------------------------------------------------------------------------

    const FoldersParams = struct { path: ?[]const u8 = null, targetDeviceId: ?[]const u8 = null };
    const DrivesParams = struct { targetDeviceId: ?[]const u8 = null };
    const CreateSpace = struct { op: []const u8 = "createSpace", spaceId: []const u8, deviceId: []const u8, path: []const u8, gitDetected: bool };

    fn loadFolders(self: *AddProject, path: ?[]const u8, cx: *Context(AddProject)) void {
        const went_home = path == null;
        freeOpt(self.gpa, &self.browser_path);
        self.browser_path = if (path) |p| self.gpa.dupe(u8, p) catch null else null;
        self.listing_state = .loading;
        self.active = 0;
        self.list_scroll.setOffset(.{ .x = 0, .y = 0 });
        freeOpt(self.gpa, &self.listing_error);
        if (self.fixtures != null) {
            self.listLocal(self.browser_path, went_home, cx);
            return cx.notify();
        }
        const st = self.state.read(cx);
        if (st.engine.read(cx).conn == null) {
            self.listing_state = .failed;
            self.listing_error = self.gpa.dupe(u8, "Device is not connected") catch null;
            return cx.notify();
        }
        const target: ?[]const u8 = if (self.isLocal(cx)) null else self.device_id;
        const params: FoldersParams = .{ .path = self.browser_path, .targetDeviceId = target };
        const sent = if (went_home)
            es.EngineState.request(st.engine, cx, AddProject, cx.entityId(), .ListFolders, params, onHomeFolders)
        else
            es.EngineState.request(st.engine, cx, AddProject, cx.entityId(), .ListFolders, params, onFolders);
        sent catch {
            self.listing_state = .failed;
            self.listing_error = self.gpa.dupe(u8, "Device is not connected") catch null;
        };
        cx.notify();
    }

    fn onFolders(self: *AddProject, r: es.CallResult, cx: *Context(AddProject)) void {
        self.applyFolders(r, false, cx);
    }

    fn onHomeFolders(self: *AddProject, r: es.CallResult, cx: *Context(AddProject)) void {
        self.applyFolders(r, true, cx);
    }

    fn applyFolders(self: *AddProject, r: es.CallResult, went_home: bool, cx: *Context(AddProject)) void {
        switch (r) {
            .ok => |v| {
                _ = self.listing_arena.reset(.retain_capacity);
                const listing = std.json.parseFromValueLeaky(FolderListing, self.listing_arena.allocator(), v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| {
                    self.listing_state = .failed;
                    self.listing_error = std.fmt.allocPrint(self.gpa, "{t}", .{e}) catch null;
                    return cx.notify();
                };
                self.setListing(listing, went_home);
            },
            .err => |e| {
                self.listing_state = .failed;
                self.listing_error = self.gpa.dupe(u8, e.message) catch null;
            },
        }
        cx.notify();
    }

    fn setListing(self: *AddProject, listing: FolderListing, went_home: bool) void {
        if (went_home) {
            freeOpt(self.gpa, &self.home);
            self.home = self.gpa.dupe(u8, listing.path) catch null;
        }
        self.listing = listing;
        self.listing_state = .ready;
    }

    /// Fixture mode: list a local directory (dirs sorted by name; `.git` marks repos).
    fn listLocal(self: *AddProject, path: ?[]const u8, went_home: bool, cx: *Context(AddProject)) void {
        _ = self.listing_arena.reset(.retain_capacity);
        const a = self.listing_arena.allocator();
        const io = self.ws(cx).io;
        const dir_path = path orelse blk: {
            const h = std.c.getenv("HOME") orelse break :blk "/";
            break :blk std.mem.span(h);
        };
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
            self.listing_state = .failed;
            self.listing_error = std.fmt.allocPrint(self.gpa, "{t}", .{e}) catch null;
            return;
        };
        defer dir.close(io);
        var entries: std.ArrayList(FolderEntry) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.name.len > 0 and e.name[0] == '.') continue;
            if (e.kind != .directory) continue;
            const name = a.dupe(u8, e.name) catch continue;
            const git = std.fs.path.join(a, &.{ dir_path, name, ".git" }) catch continue;
            const is_repo = if (std.Io.Dir.cwd().access(io, git, .{})) |_| true else |_| false;
            entries.append(a, .{ .name = name, .isDir = true, .isRepo = is_repo }) catch {};
            if (entries.items.len >= 500) break;
        }
        std.mem.sort(FolderEntry, entries.items, {}, struct {
            fn lt(_: void, l: FolderEntry, r: FolderEntry) bool {
                return std.ascii.orderIgnoreCase(l.name, r.name) == .lt;
            }
        }.lt);
        self.setListing(.{ .path = a.dupe(u8, dir_path) catch dir_path, .entries = entries.items }, went_home);
    }

    fn loadDrives(self: *AddProject, cx: *Context(AddProject)) void {
        _ = self.drives_arena.reset(.retain_capacity);
        self.drives = &.{};
        if (self.fixtures != null) {
            self.drives_state = .ready;
            const a = self.drives_arena.allocator();
            const list = a.alloc(DriveEntry, 1) catch return;
            list[0] = .{ .name = "System", .path = "/" };
            self.drives = list;
            return;
        }
        const st = self.state.read(cx);
        if (st.engine.read(cx).conn == null) return;
        self.drives_state = .loading;
        const target: ?[]const u8 = if (self.isLocal(cx)) null else self.device_id;
        es.EngineState.request(st.engine, cx, AddProject, cx.entityId(), .ListDrives, DrivesParams{ .targetDeviceId = target }, onDrives) catch {
            self.drives_state = .failed;
        };
    }

    fn onDrives(self: *AddProject, r: es.CallResult, cx: *Context(AddProject)) void {
        switch (r) {
            .ok => |v| {
                const listing = std.json.parseFromValueLeaky(DriveListing, self.drives_arena.allocator(), v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
                    self.drives_state = .failed;
                    return cx.notify();
                };
                self.drives = listing.drives;
                self.drives_state = .ready;
            },
            // Best-effort: the section just shows Home.
            .err => self.drives_state = .failed,
        }
        cx.notify();
    }

    /// ⌘⏎: create the space for the folder OPEN in the breadcrumbs.
    fn submit(self: *AddProject, cx: *Context(AddProject)) void {
        if (self.busy or self.step != .folders) return;
        const device_id = self.device_id orelse return;
        const listing = self.listing orelse return;
        const w = self.ws(cx);
        for (w.spaces()) |s| if (std.mem.eql(u8, s.deviceId, device_id) and std.mem.eql(u8, s.path, listing.path)) {
            return cx.emit(Created{ .space_id = s.id });
        };
        var id: [36]u8 = undefined;
        _ = @import("zeron_composer").run_config.uuidV4(w.io, &id);
        self.busy = true;
        freeOpt(self.gpa, &self.err);
        self.pending_space = id;
        const st = self.state.read(cx);
        es.EngineState.request(st.engine, cx, AddProject, cx.entityId(), .Mutate, engine.protocol.Mutate{ .createSpace = .{
            .spaceId = &id,
            .deviceId = device_id,
            .path = listing.path,
            .gitDetected = self.browser_repo,
        } }, onCreated) catch {
            self.busy = false;
            self.err = self.gpa.dupe(u8, "Engine not connected") catch null;
        };
        cx.notify();
    }

    fn onCreated(self: *AddProject, r: es.CallResult, cx: *Context(AddProject)) void {
        self.busy = false;
        switch (r) {
            .ok => if (self.pending_space) |id| {
                self.pending_space = null;
                const copy = self.tmp().dupe(u8, &id) catch return;
                cx.emit(Created{ .space_id = copy });
            },
            .err => |e| self.err = self.gpa.dupe(u8, e.message) catch null,
        }
        cx.notify();
    }

    // ---- input ------------------------------------------------------------------------

    fn onSearch(self: *AddProject, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(AddProject)) void {
        _ = self.scratch.reset(.retain_capacity);
        switch (ev.*) {
            .edited => {
                if (self.slashDescend(cx)) return;
                self.active = 0;
                self.list_scroll.setOffset(.{ .x = 0, .y = 0 });
                cx.notify();
            },
            .escape => cx.emit(Close{}),
            .submitted => self.openActive(cx),
            .modified_submitted => self.submit(cx),
            .tab => self.acceptCompletion(cx),
            else => {},
        }
    }

    fn acceptCompletion(self: *AddProject, cx: *Context(AddProject)) void {
        const c = self.completion(cx) orelse return;
        const name = self.gpa.dupe(u8, c[0]) catch return;
        defer self.gpa.free(name);
        self.setQuery(name, null, cx);
    }

    /// ↑↓ (ctrl-n/p) navigate, →/⏎ open, ← up, ⇥ complete, ⌘⏎ add the open
    /// folder, ⌫ on an empty query goes up, esc closes.
    fn onKey(self: *AddProject, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(AddProject)) void {
        _ = self.scratch.reset(.retain_capacity);
        const k = ev.keystroke;
        const eql = std.mem.eql;
        if (eql(u8, k.key, "right")) {
            self.openActive(cx);
        } else if (eql(u8, k.key, "left")) {
            self.goUp(cx);
        } else if (eql(u8, k.key, "tab")) {
            self.acceptCompletion(cx);
        } else switch (menu.classifyKey(k.key, k.modifiers.platform, k.modifiers.control)) {
            .escape => cx.emit(Close{}),
            .up, .down => |d| {
                self.active = menu.menuStep(self.active, self.rowCount(cx), if (d == .up) -1 else 1) orelse 0;
                self.list_scroll.scrollToItem(self.active);
                cx.notify();
            },
            .enter => self.openActive(cx),
            .mod_enter => self.submit(cx),
            .backspace => {
                if (self.search.read(cx).isEmpty()) self.goUp(cx) else return;
            },
            .other => return,
        }
        cx.stopPropagation();
    }

    fn onOutside(self: *AddProject, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(AddProject)) void {
        if (self.crumb_menu_open) return;
        cx.emit(Close{});
    }

    fn onRowHover(self: *AddProject, ix: usize, _: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(AddProject)) void {
        if (self.active == ix) return;
        self.active = ix;
        cx.notify();
    }

    fn onRow(self: *AddProject, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AddProject)) void {
        _ = self.scratch.reset(.retain_capacity);
        self.active = ix;
        self.openActive(cx);
    }

    fn onBack(self: *AddProject, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AddProject)) void {
        _ = self.scratch.reset(.retain_capacity);
        if (self.step == .devices) cx.emit(Close{}) else self.goUp(cx);
    }

    fn onCrumb(self: *AddProject, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AddProject)) void {
        _ = self.scratch.reset(.retain_capacity);
        const cr = self.crumbs(cx);
        if (ix >= cr.specs.len) return;
        switch (cr.specs[ix].target) {
            .devices => self.backTo(.devices, cx),
            .locations => self.backTo(.locations, cx),
            .location => if (self.location_name) |n| {
                const name = self.gpa.dupe(u8, n) catch return;
                defer self.gpa.free(name);
                const p: ?[]u8 = if (self.location_path) |x| self.gpa.dupe(u8, x) catch null else null;
                defer if (p) |x| self.gpa.free(x);
                self.gotoLocation(name, p, cx);
            },
            .folder => |full| self.descend(full, false, cx),
            .more => {
                self.crumb_menu_open = !self.crumb_menu_open;
                cx.notify();
            },
        }
    }

    fn onHiddenCrumb(self: *AddProject, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AddProject)) void {
        _ = self.scratch.reset(.retain_capacity);
        const cr = self.crumbs(cx);
        self.crumb_menu_open = false;
        if (ix < cr.hidden.len) self.descend(cr.hidden[ix].full, false, cx);
    }

    fn onCrumbMenuOut(self: *AddProject, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(AddProject)) void {
        self.crumb_menu_open = false;
        cx.notify();
    }

    fn onAdd(self: *AddProject, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AddProject)) void {
        self.submit(cx);
    }

    fn onRetry(self: *AddProject, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AddProject)) void {
        const p: ?[]u8 = if (self.browser_path) |x| self.gpa.dupe(u8, x) catch null else null;
        defer if (p) |x| self.gpa.free(x);
        self.loadFolders(p, cx);
    }

    // ---- render -----------------------------------------------------------------------

    const Target = union(enum) { devices, locations, location, folder: []const u8, more };
    const CrumbSpec = struct { name: []const u8, glyph: ?Icon, current: bool, target: Target };
    const Crumbs = struct { specs: []CrumbSpec, hidden: []paths.Crumb, key: u64 };

    fn deviceGlyph(platform: ?[]const u8) Icon {
        const p = platform orelse return .monitor;
        if (std.mem.eql(u8, p, "macos") or std.mem.eql(u8, p, "darwin")) return .laptop;
        if (std.mem.eql(u8, p, "web")) return .global;
        if (std.mem.eql(u8, p, "ios") or std.mem.eql(u8, p, "android")) return .smartphone;
        return .monitor;
    }

    fn device(self: *const AddProject, cx: anytype) ?*const Device {
        const id = self.device_id orelse return null;
        for (self.ws(cx).devices()) |*d| if (std.mem.eql(u8, d.id, id)) return d;
        return null;
    }

    fn crumbs(self: *AddProject, cx: anytype) Crumbs {
        const a = self.tmp();
        var specs: std.ArrayList(CrumbSpec) = .empty;
        var key = std.hash.Wyhash.init(7);
        specs.append(a, .{ .name = "New project", .glyph = null, .current = self.step == .devices, .target = .devices }) catch {};
        if (self.device(cx)) |d| {
            key.update(d.id);
            specs.append(a, .{ .name = d.name, .glyph = deviceGlyph(d.platform), .current = self.step == .locations, .target = .locations }) catch {};
        }
        var hidden: []paths.Crumb = &.{};
        if (self.location_name) |name| {
            const root = self.location_path orelse self.home;
            const open_path: ?[]const u8 = if (self.listing) |l| l.path else self.browser_path orelse root;
            const at_root = open_path == null or (root != null and std.mem.eql(u8, open_path.?, root.?));
            key.update(name);
            specs.append(a, .{ .name = name, .glyph = if (self.location_path == null) .home else .hard_drive, .current = at_root, .target = .location }) catch {};
            if (open_path) |op| {
                key.update(op);
                var folders_list: std.ArrayList(paths.Crumb) = .empty;
                for (paths.breadcrumbs(a, op)) |c| {
                    if (root) |r| if (paths.pathUnder(r, c.full)) continue;
                    folders_list.append(a, c) catch {};
                }
                var shown = folders_list.items;
                if (shown.len > crumb_folders_max) {
                    hidden = shown[0 .. shown.len - crumb_folders_tail];
                    shown = shown[shown.len - crumb_folders_tail ..];
                    specs.append(a, .{ .name = "…", .glyph = null, .current = false, .target = .more }) catch {};
                }
                for (shown) |c| specs.append(a, .{ .name = c.label, .glyph = null, .current = std.mem.eql(u8, c.full, op), .target = .{ .folder = c.full } }) catch {};
            }
        }
        return .{ .specs = specs.items, .hidden = hidden, .key = key.final() };
    }

    fn keyHint(theme: *const Theme, keys: []const u8, text: []const u8) zpui.Div {
        return div().flex().itemsCenter().gap(px(5))
            .child(ui.popover.kbdHint(theme, keys))
            .child(div().textSize(ui.rems(10)).textColor(theme.text_muted).child(text));
    }

    fn row(self: *AddProject, ix: usize, theme: *const Theme, cx: *Context(AddProject)) zpui.StatefulDiv {
        return ui.popover.menuRow(theme, ix == self.active).id(.{ "project-result", ix }).role(.menu_item)
            .rounded(px(ui.popover.palette_item_radius)).minH(px(30)).py(px(4))
            .onMouseMove(cx.listenerWith(ix, onRowHover))
            .onClick(cx.listenerWith(ix, onRow));
    }

    fn label(text: []const u8, q: []const u8, theme: *const Theme) zpui.Div {
        const body: zpui.AnyElement = blk: {
            const t = std.mem.trim(u8, q, " ");
            if (t.len == 0) break :blk zpui.intoAnyElement(text);
            const at = std.ascii.findIgnoreCase(text, t) orelse break :blk zpui.intoAnyElement(text);
            const hl = zpui.window.arena_mod.frameAllocator().alloc(zpui.Highlight, 1) catch break :blk zpui.intoAnyElement(text);
            hl[0] = .{ .start = at, .end = at + t.len, .style = .{ .color = theme.code_text, .background_color = theme.code_wash } };
            break :blk zpui.intoAnyElement(zpui.styledText(text).withHighlights(hl));
        };
        return div().flex1().minW0().truncate().whitespaceNowrap().child(body);
    }

    pub fn render(self: *AddProject, window: *Window, cx: *Context(AddProject)) zpui.AnyElement {
        _ = self.scratch.reset(.retain_capacity);
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).forPopup());
        const vp = window.viewportSize();
        const q = zpui.fmt("{s}", .{self.query(cx)});
        const ghost: ?[]const u8 = if (self.completion(cx)) |c| zpui.fmt("{s}", .{c[1]}) else null;
        self.search.update(cx, input.TextInput.setGhost, .{ghost});

        var rows: std.ArrayList(zpui.StatefulDiv) = .empty;
        const fa = zpui.window.arena_mod.frameAllocator();
        switch (self.step) {
            .devices => {
                const w = self.ws(cx);
                const now = model.time.Timestamp.now(w.io);
                for (self.devices(cx), 0..) |d, ix| {
                    const online = w.deviceOnline(d.id, now) or self.fixtures != null;
                    rows.append(fa, self.row(ix, theme, cx)
                        .child(ui.icon.of(deviceGlyph(d.platform), 16, theme.text_muted))
                        .child(label(d.name, q, theme))
                        .child(div().size(px(5)).flexNone().roundedFull().bg(if (online) theme.success else theme.text_faint))) catch {};
                }
            },
            .locations => for (self.locations(cx), 0..) |l, ix| {
                rows.append(fa, self.row(ix, theme, cx)
                    .child(ui.icon.of(if (l.path == null) .home else .hard_drive, 16, theme.text_muted))
                    .child(label(l.name, q, theme))) catch {};
            },
            .folders => if (self.listing_state == .ready) for (self.folders(cx), 0..) |e, ix| {
                var r = self.row(ix, theme, cx)
                    .child(ui.icon.of(.folder, 16, theme.text_muted))
                    .child(label(e.name, q, theme));
                if (e.isRepo) r = r.child(ui.icon.of(.git_branch, 14, theme.text_muted));
                rows.append(fa, r) catch {};
            },
        }
        const count = rows.items.len;
        if (count > 0) self.active = @min(self.active, count - 1);
        var results = div().id("project-results").minH0().maxH(px(std.math.clamp(vp.height - 220, 100, 360)))
            .overflowYScroll().trackScroll(self.list_scroll).flex().flexCol().gap(px(2));
        for (rows.items, 0..) |r, ix| {
            var wrap = div().flexNone().px(px(8));
            if (ix == 0) wrap = wrap.pt(px(8));
            if (ix + 1 == count) wrap = wrap.pb(px(8));
            results = results.child(wrap.child(r));
        }
        if (self.step == .folders and (self.listing_state == .loading or self.listing_state == .idle)) {
            results = results.child(div().p(px(8)).flex().flexCol().gap(px(6)).py(px(12))
                .child(div().h(px(28)).rounded(px(6)).bg(theme.ink(0.04)))
                .child(div().h(px(28)).rounded(px(6)).bg(theme.ink(0.04)).opacity(0.7))
                .child(div().h(px(28)).rounded(px(6)).bg(theme.ink(0.04)).opacity(0.5)));
        } else if (self.step == .folders and self.listing_state == .failed) {
            results = results.child(div().p(px(16)).flex().flexCol().gap(px(6)).textSize(ui.rems(12)).textColor(theme.danger)
                .child(self.listing_error orelse "Couldn't list this folder")
                .child(ui.button.ghost("project-retry", "Retry", theme).onClick(cx.listener(onRetry))));
        } else if (count == 0 and !(self.step == .locations and self.drives_state == .loading)) {
            const title: []const u8, const hint: []const u8 = switch (self.step) {
                .devices => .{ "No devices found", "Try another device name." },
                .locations => .{ "No locations found", "Try Home or a drive name." },
                .folders => if (q.len == 0) .{ "No folders here", zpui.fmt("Add this folder with {s}Enter, or go back with ←.", .{mod()}) } else .{ "No folders match", "Type a path like ~/code or /mnt to jump there." },
            };
            results = results.child(div().wFull().py(px(24)).px(px(16)).flex().flexCol().itemsCenter().gap(px(6))
                .textSize(ui.rems(13)).child(title).child(div().textColor(theme.text_muted).child(hint)));
        }
        if (self.step == .locations and self.drives_state == .loading) {
            results = results.child(div().px(px(16)).pb(px(8)).textColor(theme.text_muted).textSize(ui.rems(11)).child("Loading locations…"));
        }

        // Breadcrumbs: one sideways-scrolling line under edge fades.
        const cr = self.crumbs(cx);
        if (cr.key != self.crumb_key) {
            self.crumb_key = cr.key;
            self.crumb_scroll.scrollToItem((cr.specs.len * 2) -| 2);
        }
        var trail = div().id("project-crumbs").flex1().minW0().hFull().flex().itemsCenter().gap(px(2))
            .overflowXScroll().trackScroll(self.crumb_scroll);
        for (cr.specs, 0..) |spec, ix| {
            if (ix > 0) trail = trail.child(ui.icon.of(.alt_arrow_right, 12, theme.text_faint));
            const more = spec.target == .more;
            const color = if (spec.current or (more and self.crumb_menu_open)) theme.text else theme.text_muted;
            var el = div().id(.{ "project-crumb", ix }).relative().flexNone().h(px(24)).px(px(6)).rounded(px(6))
                .flex().itemsCenter().gap(px(5)).textColor(color);
            if (more) el = el.minW(px(24)).justifyCenter();
            if (more and self.crumb_menu_open) el = el.bg(theme.element_hover);
            if (spec.glyph) |g| el = el.child(ui.icon.of(g, 14, color));
            el = el.child(div().maxW(px(180)).truncate().whitespaceNowrap().child(spec.name));
            if (!spec.current) el = el.role(.button).ariaLabel(if (more) "Show hidden folders" else spec.name).cursorPointer().hover(sb.bg(theme.element_hover).textColor(theme.text)).onClick(cx.listenerWith(ix, onCrumb));
            if (more and self.crumb_menu_open) {
                var card = ui.popover.card(theme).minW(px(180)).maxW(px(280)).onMouseDownOut(cx.listener(onCrumbMenuOut));
                for (cr.hidden, 0..) |h, hi| card = card.child(ui.popover.menuRow(theme, false).id(.{ "project-crumb-menu", hi }).role(.menu_item)
                    .onClick(cx.listenerWith(hi, onHiddenCrumb))
                    .child(ui.icon.of(.folder, 16, theme.text_muted))
                    .child(div().minW0().truncate().whitespaceNowrap().child(h.label)));
                el = el.child(div().absolute().top(zpui.relative(1)).left(px(0)).child(zpui.deferred(
                    zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
                        .child(div().occlude().pt(px(6)).child(ui.popover.frostedCard(card))),
                ).withPriority(3)));
            }
            trail = trail.child(el);
        }
        const back_label: []const u8 = if (self.step == .devices) "Back to commands" else "Back";
        const crumb_row = div().h(px(36)).flexNone().px(px(12)).flex().itemsCenter().gap(px(6))
            .borderB1().borderColor(theme.hairline(0.06)).textSize(ui.rems(12))
            .child(div().id("project-crumb-back").role(.button).ariaLabel(back_label).group("project-crumb-back").size(px(24)).flexNone().flex().itemsCenter().justifyCenter()
                .rounded(px(6)).cursorPointer().hover(sb.bg(theme.element_hover))
                .tooltipWith(back_label, ui.tooltip.build)
                .onClick(cx.listener(onBack))
                .child(ui.icon.of(.arrow_left, 16, theme.text_muted)))
            .child(ui.effects.edgeFaded(trail, .{ .band = 18, .left = true, .right = true, .scroll = self.crumb_scroll }));

        const can_add = !self.busy and self.listing != null;
        var footer = div().flexNone().px(px(16)).py(px(7)).borderT1().borderColor(theme.hairline(0.06))
            .flex().flexWrap().itemsCenter().gap(px(12))
            .child(keyHint(theme, "↑ ↓", "Navigate"))
            .child(keyHint(theme, "↵", if (self.step == .folders) "Open" else "Select"));
        if (self.step != .devices) footer = footer.child(keyHint(theme, "←", "Back"));
        footer = footer.child(keyHint(theme, "Esc", "Close"));
        if (self.step == .folders) {
            var add = div().id("project-add").role(.button).ariaLabel("Add project").flex().itemsCenter().gap(px(6)).pl(px(3)).pr(px(8)).py(px(3)).my(px(-3)).mr(px(-8)).rounded(px(8))
                .child(ui.popover.kbdHint(theme, zpui.fmt("{s}Enter", .{mod()})))
                .child(div().textSize(ui.rems(10)).fontWeight(500).textColor(theme.text).child(if (self.busy) "Adding…" else "Add project"));
            add = if (can_add) add.cursorPointer().hover(sb.bg(ui.theme.cardSelectedBg(theme))).onClick(cx.listener(onAdd)) else add.opacity(0.5);
            footer = footer.child(div().flex1()).child(add);
        }

        var card = div().id("add-space-palette").trackFocus(self.focus).keyContext("CommandPalette")
            .captureKeyDown(cx.listener(onKey))
            .onMouseDownOut(cx.listener(onOutside))
            .w(px(@min(560, vp.width - 32))).flex().flexCol().rounded(px(16))
            .border1().borderColor(theme.border).bg(ui.popover.surfaceBg(theme)).textColor(theme.text)
            .fontFamily(theme.font_sans).textSize(ui.rems(13))
            .child(div().minH(px(44)).flexNone().px(px(16)).py(px(8)).flex().itemsCenter().gap(px(10))
                .borderB1().borderColor(theme.hairline(0.06))
                .child(ui.icon.of(.palette_search, 16, theme.text_muted))
                .child(div().flex1().minW0().textSize(ui.rems(14)).child(self.search))
                .child(ui.popover.kbdHint(theme, zpui.fmt("{s}Shift+N", .{mod()}))))
            .child(crumb_row)
            .child(ui.effects.edgeFaded(results, .{ .band = 18, .top = true, .bottom = true, .scroll = self.list_scroll }));
        if (self.err) |e| card = card.child(div().px(px(16)).pb(px(8)).textSize(ui.rems(12)).textColor(theme.danger).child(e));
        card = card.child(footer);
        const card_el = if (!theme.isFrost()) card.shadowLg() else card;
        return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 })
            .child(div().occlude().w(px(vp.width)).h(px(vp.height))
            .bg(zt.theme.scrimFor(theme.appearance, 0.35))
            .flex().itemsCenter().justifyCenter()
            // `palette_overlay`: no entrance motion (Rust mounts the card as is).
            .child(ui.effects.frosted(16, zt.layout.menu_blur, card_el)))).withPriority(2));
    }
};

fn freeOpt(gpa: std.mem.Allocator, slot: *?[]u8) void {
    if (slot.*) |s| gpa.free(s);
    slot.* = null;
}
