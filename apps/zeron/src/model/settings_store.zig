//! `SettingsStore` — the zpui global that is the sole in-process owner and
//! writer of `ui-settings.json` (zeron `settings.rs` `SettingsStore` +
//! `update` / `replace` / `flush`).
//!
//! Mutations land in `current` immediately (clamped); `Debounced` saves
//! coalesce for `save_debounce_ms` (400ms), `Immediate` cancel any pending
//! timer and write synchronously. Global observers (`observeGlobal`) are
//! notified on every effective change. Strings written into the settings by
//! a mutator must be allocated from the `Allocator` passed to it (the
//! store's arena).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const settings = @import("settings.zig");

const App = zpui.App;
const Task = zpui.Task;
const log = std.log.scoped(.zeron_settings);

pub const SavePolicy = enum { debounced, immediate };

pub const SettingsStore = struct {
    gpa: Allocator,
    io: std.Io,
    loaded: settings.Loaded,
    data_dir: []u8,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    /// Advances only when `codeFencesFitContent` flips.
    code_fences_generation: u64 = 0,
    save_task: Task(void) = .none,
    /// False for an in-memory store (fixture mode): mutations apply and
    /// notify as usual but nothing is written to disk.
    persist: bool = true,

    pub fn current(self: *const SettingsStore) *const settings.UiSettings {
        return &self.loaded.value;
    }

    pub fn deinit(self: *SettingsStore, _: *App) void {
        self.save_task.cancel();
        self.loaded.deinit();
        self.gpa.free(self.data_dir);
    }

    /// Write the current revision if it isn't on disk yet.
    pub fn writeLatest(store: *SettingsStore) void {
        if (store.saved_revision == store.revision) return;
        if (!store.persist) {
            store.saved_revision = store.revision;
            return;
        }
        settings.save(&store.loaded.value, store.gpa, store.io, store.data_dir) catch |err| {
            log.warn("failed to persist ui settings (revision {d}): {t}", .{ store.revision, err });
            return;
        };
        store.saved_revision = store.revision;
    }

    fn updateCurrent(self: *SettingsStore, ctx: anytype, comptime mutate: anytype) bool {
        const before = self.loaded.value;
        const a = self.loaded.arena.allocator();
        mutate(ctx, &self.loaded.value, a);
        self.loaded.value = self.loaded.value.clamped(a) catch self.loaded.value;
        if (self.loaded.value.eql(&before)) return false;
        if (self.loaded.value.codeFencesFitContent != before.codeFencesFitContent) self.code_fences_generation +%= 1;
        self.revision +%= 1;
        return true;
    }
};

/// Load `{data_dir}/ui-settings.json` and install the global.
pub fn init(app: *App, io: std.Io, data_dir: []const u8) !void {
    const loaded = try settings.load(app.gpa, io, data_dir);
    errdefer loaded.deinit();
    const dir = try app.gpa.dupe(u8, data_dir);
    errdefer app.gpa.free(dir);
    try app.setGlobal(SettingsStore{ .gpa = app.gpa, .io = io, .loaded = loaded, .data_dir = dir });
}

/// Install an in-memory store seeded with defaults (fixture mode / no data
/// dir): settings pages stay live but never touch `ui-settings.json`.
pub fn initMemory(app: *App, io: std.Io) !void {
    const loaded = try settings.defaults(app.gpa);
    errdefer loaded.deinit();
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(SettingsStore{ .gpa = app.gpa, .io = io, .loaded = loaded, .data_dir = dir, .persist = false });
}

/// An in-memory store seeded from `{data_dir}/ui-settings.json` (fixture
/// runs that want a real settings file, e.g. a background image, without
/// ever writing it back).
pub fn initMemoryFrom(app: *App, io: std.Io, data_dir: []const u8) !void {
    const loaded = try settings.load(app.gpa, io, data_dir);
    errdefer loaded.deinit();
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(SettingsStore{ .gpa = app.gpa, .io = io, .loaded = loaded, .data_dir = dir, .persist = false });
}

/// Latest settings (including mutations still inside the debounce window).
pub fn current(app: *App) ?*const settings.UiSettings {
    const store = app.tryGlobal(SettingsStore) orelse return null;
    return store.current();
}

/// Mutate with `mutate(ctx, *UiSettings, arena)`; returns whether anything
/// changed (then schedules a save per `policy` and notifies observers).
pub fn update(app: *App, policy: SavePolicy, ctx: anytype, comptime mutate: anytype) bool {
    if (!app.hasGlobal(SettingsStore)) return false;
    const Ctx = @TypeOf(ctx);
    const C = struct { Ctx, SavePolicy };
    const Wrap = struct {
        fn run(c: C, store: *SettingsStore, a: *App) bool {
            if (!store.updateCurrent(c[0], mutate)) return false;
            schedule(store, a, c[1]);
            return true;
        }
    };
    return app.updateGlobal(SettingsStore, C{ ctx, policy }, Wrap.run);
}

/// Replace the whole settings value (strings must live in the store arena
/// or be static).
pub fn replace(app: *App, value: settings.UiSettings, policy: SavePolicy) bool {
    const Set = struct {
        fn set(v: settings.UiSettings, s: *settings.UiSettings, _: Allocator) void {
            s.* = v;
        }
    };
    return update(app, policy, value, Set.set);
}

const SaveJob = struct {
    app: *App,
    pub fn finish(j: *SaveJob) void {
        flushLatest(j.app);
    }
};

fn schedule(store: *SettingsStore, app: *App, policy: SavePolicy) void {
    store.save_task.cancel();
    switch (policy) {
        .immediate => store.writeLatest(),
        .debounced => store.save_task = app.foregroundExecutor().timer(settings.save_debounce_ms * std.time.ns_per_ms, SaveJob{ .app = app }) catch {
            store.writeLatest();
            return;
        },
    }
}

/// Persist the latest revision now (also at shutdown).
pub fn flush(app: *App) void {
    flushLatest(app);
}

fn flushLatest(app: *App) void {
    if (!app.hasGlobal(SettingsStore)) return;
    const Run = struct {
        fn run(_: void, store: *SettingsStore, _: *App) void {
            store.save_task.detach();
            store.writeLatest();
        }
    };
    app.updateGlobal(SettingsStore, {}, Run.run);
}

pub fn codeFencesGeneration(app: *App) u64 {
    return if (app.tryGlobal(SettingsStore)) |s| s.code_fences_generation else 0;
}
