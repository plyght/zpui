//! Custom sidebar sections (zeron `shell/sidebar_sections.rs` + the section
//! half of `shell/sidebar_pins.rs` and `crates/proto/src/sidebar_pins.rs`).
//!
//! Account-synced: under a synced / development workspace the sections are
//! the engine's `WatchSidebarPreferences` snapshot with the queued writes
//! projected on top (an optimistic overlay, never the authoritative state);
//! each edit is a `Mutate {op: "changeSidebarPin", change: {action:
//! "section", change}}` sent one at a time, the reply's `sidebarPreferences`
//! replacing the snapshot. A local workspace keeps its sections in
//! `ui-settings.json` (`sidebarSectionsByProfile["local"]`). Sections a local
//! profile stored for a synced profile are imported once (`Import`) after the
//! synced snapshot arrives, and dropped locally when the engine acknowledges.
//!
//! ```zig
//! const list = try sections.active(&ctl, arena, ws, auth, settings);
//! ctl.change(.{ .create = .{ .id = uuid, .name = "Review" } }, env, cx);
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");

const Allocator = std.mem.Allocator;
const json = std.json;
const protocol = engine.protocol;

pub const Section = protocol.SidebarSection;
pub const SectionChange = protocol.SidebarSectionChange;
pub const PinChange = protocol.SidebarPinChange;

/// Longest section name the dialog accepts (`name.chars().count() > 120`).
pub const max_name_chars: usize = 120;

// ---- pure projection (zeron_proto `SidebarSectionChange::project`) -------------------

/// Copy `src` into `a` (sections and their id lists become mutable slices).
pub fn cloneSections(a: Allocator, src: []const Section) Allocator.Error!std.ArrayList(Section) {
    var out: std.ArrayList(Section) = try .initCapacity(a, src.len);
    for (src) |s| out.appendAssumeCapacity(.{
        .id = s.id,
        .name = s.name,
        .session_ids = try a.dupe([]const u8, s.session_ids),
        .collapsed = s.collapsed,
    });
    return out;
}

fn without(a: Allocator, ids: []const []const u8, id: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = try .initCapacity(a, ids.len + 1);
    for (ids) |x| if (!std.mem.eql(u8, x, id)) out.appendAssumeCapacity(x);
    return out.items;
}

/// `SidebarSectionChange::project`: apply one intent to `sections` (strings
/// borrowed from `change`; new slices from `a`). `Import` is resolved by the
/// engine's registry and projects nothing.
pub fn project(a: Allocator, sections: *std.ArrayList(Section), change: SectionChange) Allocator.Error!void {
    switch (change) {
        .create => |c| {
            for (sections.items) |s| if (std.mem.eql(u8, s.id, c.id)) return;
            try sections.append(a, .{ .id = c.id, .name = c.name, .session_ids = &.{}, .collapsed = false });
        },
        .rename => |c| for (sections.items) |*s| if (std.mem.eql(u8, s.id, c.id)) {
            s.name = c.name;
            break;
        },
        .collapse => |c| for (sections.items) |*s| if (std.mem.eql(u8, s.id, c.id)) {
            s.collapsed = c.collapsed;
            break;
        },
        .delete => |c| {
            var n: usize = 0;
            for (sections.items) |s| if (!std.mem.eql(u8, s.id, c.id)) {
                sections.items[n] = s;
                n += 1;
            };
            sections.shrinkRetainingCapacity(n);
        },
        .assign => |c| for (sections.items) |*s| {
            var ids = try without(a, s.session_ids, c.sessionId);
            if (c.sectionId) |target| if (std.mem.eql(u8, target, s.id)) {
                const grown = try a.alloc([]const u8, ids.len + 1);
                @memcpy(grown[0..ids.len], ids);
                grown[ids.len] = c.sessionId;
                ids = grown;
                s.collapsed = false;
            };
            s.session_ids = ids;
        },
        .import => {},
    }
}

/// `SidebarPinChange::project_sections`: a pin leaves every section.
pub fn projectPinChange(a: Allocator, sections: *std.ArrayList(Section), change: PinChange) Allocator.Error!void {
    switch (change) {
        .pin => |p| for (sections.items) |*s| {
            s.session_ids = try without(a, s.session_ids, p.sessionId);
        },
        .section => |s| try project(a, sections, s.change),
        else => {},
    }
}

/// The section holding `chat_id`, if any.
pub fn sectionOf(sections: []const Section, chat_id: []const u8) ?usize {
    for (sections, 0..) |s, i| for (s.session_ids) |id| if (std.mem.eql(u8, id, chat_id)) return i;
    return null;
}

/// The dialog's name rule: trimmed, non-empty, at most 120 characters.
pub fn validName(raw: []const u8) ?[]const u8 {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    if (name.len == 0) return null;
    const chars = std.unicode.utf8CountCodepoints(name) catch name.len;
    if (chars > max_name_chars) return null;
    return name;
}

/// A random (v4) UUID, lowercase hyphenated (`uuid::Uuid::new_v4`).
pub fn newId(buf: *[36]u8, io: std.Io) []const u8 {
    model.attachments.uuidV4(io, buf);
    return buf[0..36];
}

/// Attached to an engine (headless tests: calls go to `EngineState.test_sink`).
fn attached(es: *const model.EngineState) bool {
    return es.conn != null or model.engine_state.test_sink != null;
}

// ---- owned values ---------------------------------------------------------------------

fn cloneValue(comptime T: type, gpa: Allocator, v: T) ?json.Parsed(T) {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    s.write(v) catch return null;
    return json.parseFromSlice(T, gpa, aw.written(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// Messages the sidebar shows inline (Rust `sidebar_notice`).
pub const notice_syncing = "Sidebar is still syncing. Try again shortly.";
pub const notice_no_engine = "Engine not connected. Sidebar was not changed.";
pub const notice_waiting = "Waiting for the engine to confirm the previous sidebar change.";

// ---- controller (the Shell's `sidebar_pin_write` for section intents) ------------------

/// What the controller needs from the app for one call.
pub const Env = struct {
    gpa: Allocator,
    app: *zpui.App,
    workspace: zpui.Entity(model.WorkspaceStore),
    engine: zpui.Entity(model.EngineState),
    auth: ?*const protocol.AuthState,
};

pub const Pending = struct {
    id: u64,
    profile_key: []u8,
    /// `EngineState.generation` the queue was started on (`same_connection`).
    generation: u64,
    queue: std.ArrayList(json.Parsed(SectionChange)) = .empty,

    fn deinit(self: *Pending, gpa: Allocator) void {
        for (self.queue.items) |*p| p.deinit();
        self.queue.deinit(gpa);
        gpa.free(self.profile_key);
    }
};

pub const Controller = struct {
    pending: ?Pending = null,
    generation: u64 = 0,
    /// `sidebar_section_migration`: (profile key, connection generation).
    migrated: ?struct { key: []u8, generation: u64 } = null,

    pub fn deinit(self: *Controller, gpa: Allocator) void {
        if (self.pending) |*p| p.deinit(gpa);
        self.pending = null;
        if (self.migrated) |m| gpa.free(m.key);
        self.migrated = null;
    }

    /// `active_sidebar_pin_profile_key` (allocated in `a`).
    pub fn profileKey(a: Allocator, scope: ?protocol.WorkspaceScope, auth: ?*const protocol.AuthState) ?[]u8 {
        return model.settings.sidebarPinProfileKey(a, scope, auth, null) catch null;
    }

    fn isCurrent(self: *const Controller, p: *const Pending, env: Env, a: Allocator) bool {
        _ = self;
        const scope = env.workspace.read(env.app).workspace_scope;
        const key = profileKey(a, scope, env.auth) orelse return false;
        const es = env.engine.read(env.app);
        return std.mem.eql(u8, key, p.profile_key) and attached(es) and es.generation == p.generation;
    }

    fn discardStale(self: *Controller, env: Env) void {
        const p = if (self.pending) |*x| x else return;
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        if (!self.isCurrent(p, env, fba.allocator())) {
            p.deinit(env.gpa);
            self.pending = null;
        }
    }

    /// `active_sidebar_sections`: local settings, or the synced snapshot with
    /// the queued intents projected on top. Allocated in `a`.
    pub fn active(self: *Controller, a: Allocator, env: Env) Allocator.Error![]Section {
        const ws = env.workspace.read(env.app);
        const local = ws.workspace_scope == .local;
        if (local) {
            const key = profileKey(a, ws.workspace_scope, env.auth) orelse return &.{};
            const s = model.settings_store.current(env.app) orelse return &.{};
            const stored = s.sidebarSectionsByProfile.map.get(key) orelse return &.{};
            return (try cloneSections(a, stored)).items;
        }
        var list = try cloneSections(a, ws.sidebarPreferences().sections);
        if (self.pending) |*p| {
            var buf: [512]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            if (self.isCurrent(p, env, fba.allocator())) for (p.queue.items) |c| try project(a, &list, c.value);
        }
        return list.items;
    }

    /// `change_sidebar_section`: apply locally, or queue the synced write.
    /// Returns the inline notice to show when the change was refused.
    pub fn change(self: *Controller, ch: SectionChange, env: Env) Result {
        var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const ws = env.workspace.read(env.app);
        const key = profileKey(a, ws.workspace_scope, env.auth) orelse return .refused;
        if (ws.workspace_scope == .local) {
            const current = self.active(a, env) catch return .refused;
            var list: std.ArrayList(Section) = .fromOwnedSlice(current);
            if (ch == .assign) if (ch.assign.sectionId) |target| {
                var known = false;
                for (list.items) |s| if (std.mem.eql(u8, s.id, target)) {
                    known = true;
                };
                if (!known) return .refused;
            };
            project(a, &list, ch) catch return .refused;
            writeLocal(env.app, key, list.items);
            return .applied;
        }
        if (!ws.sidebarPreferences().canEdit()) return .{ .notice = notice_syncing };
        return self.queue(key, ch, env);
    }

    /// `send`: a new write started, the caller sends `head()`.
    pub const Result = union(enum) { applied, send, refused, notice: []const u8 };

    /// `queue_sidebar_pin_write` (section intents only).
    fn queue(self: *Controller, key: []const u8, ch: SectionChange, env: Env) Result {
        self.discardStale(env);
        const es = env.engine.read(env.app);
        if (!attached(es)) return .{ .notice = notice_no_engine };
        const owned = cloneValue(SectionChange, env.gpa, ch) orelse return .refused;
        if (self.pending) |*p| {
            p.queue.append(env.gpa, owned) catch {
                var o = owned;
                o.deinit();
                return .refused;
            };
            return .applied;
        }
        self.generation += 1;
        var p: Pending = .{
            .id = self.generation,
            .profile_key = env.gpa.dupe(u8, key) catch {
                var o = owned;
                o.deinit();
                return .refused;
            },
            .generation = es.generation,
        };
        p.queue.append(env.gpa, owned) catch {
            var o = owned;
            o.deinit();
            p.deinit(env.gpa);
            return .refused;
        };
        self.pending = p;
        return .{ .send = {} };
    }

    /// The change at the head of the queue (to send).
    pub fn head(self: *const Controller) ?SectionChange {
        const p = self.pending orelse return null;
        if (p.queue.items.len == 0) return null;
        return p.queue.items[0].value;
    }

    pub fn pendingId(self: *const Controller) ?u64 {
        return if (self.pending) |p| p.id else null;
    }

    /// `finish_sidebar_pin_write`: adopt the acknowledged snapshot (or report
    /// the failure), drop the head, and say whether another write follows.
    /// An acknowledged `Import` clears the local copy it came from.
    pub fn finish(self: *Controller, id: u64, result: model.engine_state.CallResult, env: Env) Finish {
        self.discardStale(env);
        const p = if (self.pending) |*x| x else return .{};
        if (p.id != id) return .{};
        var out: Finish = .{};
        const was_import = p.queue.items.len > 0 and p.queue.items[0].value == .import;
        switch (result) {
            .ok => |v| {
                const prefs = if (v == .object) v.object.get("sidebarPreferences") else null;
                if (prefs) |pv| {
                    if (json.parseFromValue(protocol.SidebarPreferencesState, env.gpa, pv, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed| {
                        env.workspace.update(env.app, model.WorkspaceStore.applySidebarPreferences, .{parsed});
                        out.clear_notice = true;
                        if (was_import) clearLocal(env.app, p.profile_key);
                    } else |_| out.notice = "Couldn't save sidebar changes: The engine did not confirm the sidebar changes";
                } else out.notice = "Couldn't save sidebar changes: The engine did not confirm the sidebar changes";
            },
            .err => |e| out.notice_error = e.message,
        }
        if (p.queue.items.len > 0) {
            var first = p.queue.orderedRemove(0);
            first.deinit();
        }
        if (p.queue.items.len == 0) {
            p.deinit(env.gpa);
            self.pending = null;
        } else out.send_next = true;
        return out;
    }

    pub const Finish = struct {
        send_next: bool = false,
        clear_notice: bool = false,
        notice: ?[]const u8 = null,
        /// "Couldn't save sidebar changes: {error}" (borrowed from the result).
        notice_error: ?[]const u8 = null,
    };

    /// `migrate_sidebar_sections`: once the synced snapshot is authoritative,
    /// hand any sections this device stored for the profile to the engine.
    pub fn migrate(self: *Controller, env: Env) Result {
        var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const ws = env.workspace.read(env.app);
        if (ws.workspace_scope == .local or ws.workspace_scope == null or !ws.sidebarPreferences().synced) return .refused;
        const es = env.engine.read(env.app);
        if (!attached(es)) return .refused;
        const key = profileKey(a, ws.workspace_scope, env.auth) orelse return .refused;
        if (self.migrated) |m| if (std.mem.eql(u8, m.key, key) and m.generation == es.generation) return .refused;
        const s = model.settings_store.current(env.app) orelse return .refused;
        const stored = s.sidebarSectionsByProfile.map.get(key) orelse return .refused;
        if (stored.len == 0) return .refused;
        const r = self.queue(key, .{ .import = .{ .sections = stored } }, env);
        if (r == .send or r == .applied) {
            if (self.migrated) |m| env.gpa.free(m.key);
            self.migrated = .{ .key = env.gpa.dupe(u8, key) catch return r, .generation = es.generation };
        }
        return r;
    }
};

/// Store `sections` as the profile's local sections (`schedule_save`).
pub fn writeLocal(app: *zpui.App, key: []const u8, sections: []const Section) void {
    const Ctx = struct { key: []const u8, sections: []const Section };
    const W = struct {
        fn f(c: Ctx, s: *model.UiSettings, a: Allocator) void {
            var map: std.StringArrayHashMapUnmanaged([]const Section) = .empty;
            var it = s.sidebarSectionsByProfile.map.iterator();
            while (it.next()) |e| map.put(a, e.key_ptr.*, e.value_ptr.*) catch return;
            const k = a.dupe(u8, c.key) catch return;
            const list = a.alloc(Section, c.sections.len) catch return;
            for (c.sections, 0..) |sec, i| {
                const ids = a.alloc([]const u8, sec.session_ids.len) catch return;
                for (sec.session_ids, 0..) |id, j| ids[j] = a.dupe(u8, id) catch return;
                list[i] = .{ .id = a.dupe(u8, sec.id) catch return, .name = a.dupe(u8, sec.name) catch return, .session_ids = ids, .collapsed = sec.collapsed };
            }
            map.put(a, k, list) catch return;
            s.sidebarSectionsByProfile = .{ .map = map };
        }
    };
    _ = model.settings_store.update(app, .debounced, Ctx{ .key = key, .sections = sections }, W.f);
}

/// Drop the profile's local sections (after the engine imported them).
pub fn clearLocal(app: *zpui.App, key: []const u8) void {
    const W = struct {
        fn f(k: []const u8, s: *model.UiSettings, a: Allocator) void {
            var map: std.StringArrayHashMapUnmanaged([]const Section) = .empty;
            var it = s.sidebarSectionsByProfile.map.iterator();
            while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, k)) map.put(a, e.key_ptr.*, e.value_ptr.*) catch return;
            s.sidebarSectionsByProfile = .{ .map = map };
        }
    };
    _ = model.settings_store.update(app, .debounced, key, W.f);
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn idsOf(list: []const Section, ix: usize) []const []const u8 {
    return list[ix].session_ids;
}

test "section projection: create, rename, collapse, assign, delete" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Section) = .empty;
    try project(a, &list, .{ .create = .{ .id = "a", .name = "Focus" } });
    try project(a, &list, .{ .create = .{ .id = "b", .name = "Later" } });
    try project(a, &list, .{ .create = .{ .id = "a", .name = "Dup" } });
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("Focus", list.items[0].name);
    try project(a, &list, .{ .collapse = .{ .id = "b", .collapsed = true } });
    try project(a, &list, .{ .assign = .{ .sessionId = "x", .sectionId = "a" } });
    try project(a, &list, .{ .assign = .{ .sessionId = "y", .sectionId = "b" } });
    try testing.expect(!list.items[1].collapsed); // assigning reveals the target
    try project(a, &list, .{ .assign = .{ .sessionId = "x", .sectionId = "b" } });
    try testing.expectEqual(@as(usize, 0), idsOf(list.items, 0).len);
    try testing.expectEqualStrings("y", idsOf(list.items, 1)[0]);
    try testing.expectEqualStrings("x", idsOf(list.items, 1)[1]);
    try project(a, &list, .{ .assign = .{ .sessionId = "y", .sectionId = null } });
    try testing.expectEqual(@as(usize, 1), idsOf(list.items, 1).len);
    try project(a, &list, .{ .rename = .{ .id = "b", .name = "Today" } });
    try testing.expectEqualStrings("Today", list.items[1].name);
    try projectPinChange(a, &list, .{ .pin = .{ .sessionId = "x" } });
    try testing.expectEqual(@as(?usize, null), sectionOf(list.items, "x"));
    try project(a, &list, .{ .delete = .{ .id = "a" } });
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("b", list.items[0].id);
}

test "section names and ids" {
    try testing.expectEqualStrings("Review", validName("  Review  ").?);
    try testing.expect(validName("   ") == null);
    const x121: [121]u8 = @splat('x');
    try testing.expect(validName(&x121) == null);
    try testing.expect(validName(x121[0..120]) != null);
    var accents: [240]u8 = undefined;
    for (0..120) |i| @memcpy(accents[i * 2 ..][0..2], "é");
    try testing.expect(validName(&accents) != null);
    var buf: [36]u8 = undefined;
    const id = newId(&buf, testing.io);
    try testing.expectEqual(@as(usize, 36), id.len);
    try testing.expectEqual(@as(u8, '4'), id[14]);
    try testing.expectEqual(@as(u8, '-'), id[8]);
}
