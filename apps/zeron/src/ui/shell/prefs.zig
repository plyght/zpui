//! Shell/sidebar UI preferences as an app global (`Prefs`): the subset of
//! zeron's `UiSettings` the shell and sidebar render from, plus fixture-mode
//! extras (pinned rows, PR numbers, a frozen clock).
//!
//! Seeded from `ui-settings.json` (SettingsStore) when present, overridden by
//! a fixture's `meta.json`. Views read it with `prefs.get(cx)` and mutate via
//! `prefs.update(app, f)` which redraws every window.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");

pub const Organization = enum { in_one_list, by_project, by_device };
pub const Sort = enum { last_updated, created };

pub const Prefs = struct {
    gpa: std.mem.Allocator,
    sidebar_width: f32 = zt.layout.sidebar_default,
    sidebar_collapsed: bool = false,
    sidebar_compact: bool = true,
    show_project_label: bool = true,
    show_project_icon: bool = true,
    show_harness: bool = true,
    show_branch: bool = true,
    show_pull_request: bool = true,
    organization: Organization = .in_one_list,
    sort: Sort = .last_updated,
    right_pane_width: f32 = zt.layout.right_pane_default,
    right_pane_open: bool = false,
    terminal_open: bool = false,
    transcript_width: f32 = zt.layout.transcript_width_default,
    /// Sidebar project filter (space id), owned.
    space_filter: ?[]u8 = null,
    /// Pinned chat ids (owned).
    pins: std.ArrayList([]u8) = .empty,
    /// Fixture-provided open PR numbers per chat id (owned keys).
    pull_requests: std.StringHashMapUnmanaged(u64) = .empty,
    /// Fixture override for the update strip label (e.g. "Update ready — restart to apply").
    update_label: ?[]const u8 = null,
    /// Frozen clock for reproducible screenshots.
    now_override: ?model.time.Timestamp = null,
    /// [lifecycle] A write-back to the settings store is queued (`mut`).
    persist_pending: bool = false,

    pub fn deinit(self: *Prefs) void {
        if (self.space_filter) |s| self.gpa.free(s);
        for (self.pins.items) |p| self.gpa.free(p);
        self.pins.deinit(self.gpa);
        var it = self.pull_requests.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.pull_requests.deinit(self.gpa);
    }

    pub fn isPinned(self: *const Prefs, chat_id: []const u8) bool {
        for (self.pins.items) |p| if (std.mem.eql(u8, p, chat_id)) return true;
        return false;
    }

    pub fn pinIndex(self: *const Prefs, chat_id: []const u8) ?usize {
        for (self.pins.items, 0..) |p, i| if (std.mem.eql(u8, p, chat_id)) return i;
        return null;
    }

    pub fn setPinned(self: *Prefs, chat_id: []const u8, pinned: bool) void {
        if (self.pinIndex(chat_id)) |i| {
            if (!pinned) self.gpa.free(self.pins.orderedRemove(i));
        } else if (pinned) {
            const copy = self.gpa.dupe(u8, chat_id) catch return;
            self.pins.append(self.gpa, copy) catch self.gpa.free(copy);
        }
    }

    pub fn setFilter(self: *Prefs, space: ?[]const u8) void {
        if (self.space_filter) |s| self.gpa.free(s);
        self.space_filter = if (space) |s| self.gpa.dupe(u8, s) catch null else null;
    }

    pub fn pullRequest(self: *const Prefs, chat_id: []const u8) ?u64 {
        return self.pull_requests.get(chat_id);
    }

    pub fn now(self: *const Prefs, io: std.Io) model.time.Timestamp {
        return self.now_override orelse model.time.Timestamp.now(io);
    }

    /// Copy the relevant fields from persisted settings.
    pub fn applySettings(self: *Prefs, s: *const model.UiSettings) void {
        self.sidebar_width = s.sidebarWidth;
        self.sidebar_collapsed = s.sidebarCollapsed;
        self.sidebar_compact = s.sidebarCompact;
        self.show_project_label = s.sidebarShowProjectLabel;
        self.show_project_icon = s.sidebarShowProjectIcon;
        self.show_harness = s.sidebarShowHarness;
        self.show_branch = s.sidebarShowBranch;
        self.show_pull_request = s.sidebarShowPullRequest;
        self.right_pane_width = s.rightPaneWidth;
        self.transcript_width = s.transcriptWidthOr();
        // [lifecycle] the sidebar view-menu choices (Rust `sidebar_organization` / `sidebar_sort`).
        self.organization = switch (s.sidebarOrganization) {
            .inOneList => .in_one_list,
            .byProject => .by_project,
            .byDevice => .by_device,
        };
        self.sort = switch (s.sidebarSort) {
            .lastUpdated => .last_updated,
            .created => .created,
        };
    }

    /// [lifecycle] The inverse of `applySettings` for what Rust writes back from the shell
    /// (pane sizes, collapse flag, sidebar view-menu choices); `transcriptWidth` is owned
    /// by the settings page.
    pub fn writeSettings(self: *const Prefs, s: *model.UiSettings) void {
        s.sidebarWidth = self.sidebar_width;
        s.sidebarCollapsed = self.sidebar_collapsed;
        s.sidebarCompact = self.sidebar_compact;
        s.sidebarShowProjectLabel = self.show_project_label;
        s.sidebarShowProjectIcon = self.show_project_icon;
        s.sidebarShowHarness = self.show_harness;
        s.sidebarShowBranch = self.show_branch;
        s.sidebarShowPullRequest = self.show_pull_request;
        s.rightPaneWidth = self.right_pane_width;
        s.sidebarOrganization = switch (self.organization) {
            .in_one_list => .inOneList,
            .by_project => .byProject,
            .by_device => .byDevice,
        };
        s.sidebarSort = switch (self.sort) {
            .last_updated => .lastUpdated,
            .created => .created,
        };
    }
};

fn appOf(cx: anytype) *zpui.App {
    if (@TypeOf(cx) == *zpui.App) return cx;
    return cx.app;
}

pub fn install(app: *zpui.App, prefs: Prefs) !void {
    try app.setGlobal(prefs);
}

pub fn get(cx: anytype) *const Prefs {
    return appOf(cx).global(Prefs);
}

/// Mutate in place and redraw. [lifecycle] The change is written back to
/// `ui-settings.json` (debounced) once the current update finishes, like Rust's
/// `settings::update(SavePolicy::Debounced, ...)` calls in the shell.
pub fn mut(cx: anytype) *Prefs {
    const app = appOf(cx);
    app.refreshWindows();
    const p = app.globalMut(Prefs);
    if (!p.persist_pending) {
        p.persist_pending = true;
        app.deferFn(app, persist);
    }
    return p;
}

fn persist(app: *zpui.App, _: *zpui.App) void {
    const p = @constCast(app.tryGlobal(Prefs) orelse return);
    p.persist_pending = false;
    const Write = struct {
        fn f(prefs: *const Prefs, s: *model.UiSettings, _: std.mem.Allocator) void {
            prefs.writeSettings(s);
        }
    };
    _ = model.settings_store.update(app, .debounced, p, Write.f);
}
