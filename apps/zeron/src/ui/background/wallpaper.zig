//! Folder-backed wallpaper rotation (zeron `settings/wallpaper.rs`): the
//! `shell::RandomWallpaper` shortcut (mod-u) and Appearance → Shuffle pick a
//! random readable image from `wallpaperFolder`, avoiding the most recent
//! ones, and make it the new-thread background.
//!
//! ```zig
//! wallpaper.preload(app);              // every shell render: keeps 3 candidates warm
//! wallpaper.randomize(app, .shortcut); // commits a warm candidate synchronously
//! ```
//!
//! Scanning, decoding, the effect raster, color extraction and the managed
//! copy all happen on background workers ahead of time (a lookahead of
//! three), so a warm switch reads no files. The queue is keyed by folder,
//! history, active background, effect, appearance and data dir; any change
//! drops the lookahead (and its prewritten copies).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const artwork = @import("artwork.zig");
const cache = @import("cache.zig");
const install = @import("install.zig");
const anim = @import("anim_decode.zig");
const store = @import("../settings/store.zig");

const App = zpui.App;
const Allocator = std.mem.Allocator;

pub const lookahead = 3;
pub const msg_no_folder = "Choose a wallpaper folder in Appearance first.";
pub const msg_unreadable_folder = "Unable to read the wallpaper folder. Choose an accessible folder in Appearance.";
pub const msg_no_images = "No readable wallpapers found in this folder. Add images such as PNG or JPEG, or choose another folder.";

pub const Origin = enum { settings, shortcut };

/// Set by the shell: open Settings → Appearance (the shortcut's error path,
/// and mod-u without a folder, which opens the folder picker there).
pub var open_appearance: ?*const fn (app: *App, choose_folder: bool) void = null;

fn supported(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    const exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff" };
    for (exts) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    // zpui-only: moving backgrounds (APNG, video).
    if (std.ascii.eqlIgnoreCase(ext[1..], "apng")) return true;
    return anim.isVideoExtension(name);
}

const Ranked = struct { recency: usize, rank: u64, path: []u8 };

fn rankedLess(_: void, a: Ranked, b: Ranked) bool {
    if (a.recency != b.recency) return a.recency < b.recency;
    return a.rank < b.rank;
}

/// The cooldown window: leave at least two random choices when the folder allows.
pub fn cooldown(candidates: usize) usize {
    return std.math.clamp(candidates -| 2, 1, install.history_limit);
}

/// Sort keys for `choose` (recency 0 = not recently shown).
pub fn recency(history: []const []const u8, cool: usize, path: []const u8) usize {
    for (history[0..@min(cool, history.len)], 0..) |h, i| if (std.mem.eql(u8, h, path)) return cool - i;
    return 0;
}

pub const Chosen = struct {
    source: []u8,
    /// Staged bytes and the still (or a moving file's poster).
    loaded: install.Loaded,

    pub fn deinit(self: *Chosen, gpa: Allocator) void {
        gpa.free(self.source);
        self.loaded.deinit(gpa);
    }
};

pub const ChooseError = error{ OutOfMemory, Unreadable, NoImages };

/// `choose`: a random readable image, recent ones last (worker-safe).
pub fn choose(gpa: Allocator, io: std.Io, folder: []const u8, history: []const []const u8) ChooseError!Chosen {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return error.Unreadable;
    defer dir.close(io);
    var list: std.ArrayList(Ranked) = .empty;
    defer {
        for (list.items) |r| gpa.free(r.path);
        list.deinit(gpa);
    }
    var it = dir.iterate();
    while (true) {
        const e = (it.next(io) catch return error.Unreadable) orelse break;
        if (!supported(e.name)) continue;
        const full = try std.fs.path.join(gpa, &.{ folder, e.name });
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch {
            gpa.free(full);
            continue;
        };
        if (st.kind != .file) {
            gpa.free(full);
            continue;
        }
        var rank: [8]u8 = undefined;
        io.random(&rank);
        list.append(gpa, .{ .recency = 0, .rank = std.mem.readInt(u64, &rank, .little), .path = full }) catch {
            gpa.free(full);
            return error.OutOfMemory;
        };
    }
    const cool = cooldown(list.items.len);
    for (list.items) |*r| r.recency = recency(history, cool, r.path);
    std.mem.sort(Ranked, list.items, {}, rankedLess);
    for (list.items) |*r| {
        const loaded = switch (try install.load(gpa, io, r.path)) {
            .ok => |l| l,
            .err => |m| {
                gpa.free(m);
                continue;
            },
        };
        const source = r.path;
        r.path = try gpa.dupe(u8, ""); // keep the deferred free balanced
        return .{ .source = source, .loaded = loaded };
    }
    return error.NoImages;
}

// ---- queue -------------------------------------------------------------------

const Key = struct {
    folder: ?[]const u8,
    history: []const []const u8,
    background: ?[]const u8,
    effect: artwork.Effect,
    light: bool,
    data_dir: ?[]const u8,

    fn eql(a: Key, b: Key) bool {
        if (!optEql(a.folder, b.folder) or !optEql(a.background, b.background) or !optEql(a.data_dir, b.data_dir)) return false;
        if (a.effect != b.effect or a.light != b.light or a.history.len != b.history.len) return false;
        for (a.history, b.history) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    /// `QueueKey::current` into `a`.
    fn current(app: *App, a: Allocator) Allocator.Error!Key {
        const s = store.current(app);
        var history = s.wallpaperHistory;
        if (s.wallpaperSource) |src| history = try install.remember(a, history, src);
        return .{
            .folder = s.wallpaperFolder,
            .history = history,
            .background = if (s.newThreadComposerBackground) |b| b.path else null,
            .effect = s.newThreadBackgroundEffect,
            .light = ui.theme.get(app).appearance == .light,
            .data_dir = install.dataDir(app),
        };
    }

    fn clone(self: Key, a: Allocator) Allocator.Error!Key {
        const hist = try a.alloc([]const u8, self.history.len);
        for (hist, self.history) |*o, h| o.* = try a.dupe(u8, h);
        return .{
            .folder = if (self.folder) |f| try a.dupe(u8, f) else null,
            .history = hist,
            .background = if (self.background) |b| try a.dupe(u8, b) else null,
            .effect = self.effect,
            .light = self.light,
            .data_dir = if (self.data_dir) |d| try a.dupe(u8, d) else null,
        };
    }
};

const Candidate = struct {
    source: []u8,
    color: ?zt.Color,
    prepared: install.Prepared,
    artwork: *cache.Source,

    fn discard(self: *Candidate, app: *App, io: std.Io) void {
        self.prepared.discard(app.gpa, io);
        app.gpa.free(self.source);
        dropSource(app, self.artwork);
    }
};

fn dropSource(app: *App, s: *cache.Source) void {
    for (s.effects.items) |*r| if (r.image) |img| {
        cache.releaseImage(app, img);
        r.image = null;
    };
    s.release();
}

pub const Queue = struct {
    gpa: Allocator,
    key_arena: std.heap.ArenaAllocator,
    key: ?Key = null,
    ready: std.ArrayList(Candidate) = .empty,
    generation: u64 = 0,
    loading: bool = false,
    err: ?[]u8 = null,
    /// A randomize request waiting for the first candidate.
    waiting: ?Origin = null,
    waiting_generation: u64 = 0,
    app: *App,
    /// Captured at creation: the settings store may be gone by `deinit`.
    io: std.Io,

    pub fn deinit(self: *Queue, app: *App) void {
        for (self.ready.items) |*c| c.discard(app, self.io);
        self.ready.deinit(self.gpa);
        if (self.err) |e| self.gpa.free(e);
        self.key_arena.deinit();
    }

    fn setErr(self: *Queue, msg: ?[]const u8) void {
        if (self.err) |e| self.gpa.free(e);
        self.err = if (msg) |m| (self.gpa.dupe(u8, m) catch null) else null;
    }
};

fn queueMut(app: *App) ?*Queue {
    return @constCast(app.tryGlobal(Queue) orelse return null);
}

/// Retire managed copies left by earlier sessions' unused preloads.
fn removeOrphanedPreloads(app: *App, key: Key) void {
    const dir_path = key.data_dir orelse return;
    const io = install.ioOf(app);
    const folder = std.fs.path.join(app.gpa, &.{ dir_path, install.backgrounds_dir }) catch return;
    defer app.gpa.free(folder);
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const active: ?[]const u8 = if (key.background) |b| std.fs.path.basename(b) else null;
    const active_motion: ?[]const u8 = if (store.current(app).newThreadComposerBackground) |b| (if (b.motionPath) |m| std.fs.path.basename(m) else null) else null;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| app.gpa.free(n);
        names.deinit(app.gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, install.managed_prefix)) continue;
        if (active) |a| if (std.mem.eql(u8, a, e.name)) continue;
        if (active_motion) |a| if (std.mem.eql(u8, a, e.name)) continue;
        names.append(app.gpa, app.gpa.dupe(u8, e.name) catch continue) catch {};
    }
    for (names.items) |n| dir.deleteFile(io, n) catch {};
}

fn synchronize(app: *App) *Queue {
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const key = Key.current(app, scratch.allocator()) catch @panic("OOM");
    if (app.tryGlobal(Queue) == null) {
        removeOrphanedPreloads(app, key);
        app.setGlobal(Queue{ .gpa = app.gpa, .key_arena = .init(app.gpa), .app = app, .io = install.ioOf(app) }) catch @panic("OOM");
    }
    const q = queueMut(app).?;
    if (q.key == null or !q.key.?.eql(key)) {
        for (q.ready.items) |*c| c.discard(app, q.io);
        q.ready.clearRetainingCapacity();
        q.generation +%= 1;
        q.loading = false;
        q.setErr(null);
        _ = q.key_arena.reset(.retain_capacity);
        q.key = key.clone(q.key_arena.allocator()) catch null;
    }
    return q;
}

/// Warm the lookahead (called on render and after each switch).
pub fn preload(app: *App) void {
    const q = synchronize(app);
    const key = q.key orelse return;
    if (key.folder == null or q.loading or q.err != null or q.ready.items.len >= lookahead) return;
    var job: LoadJob = .{ .app = app, .gpa = app.gpa, .io = install.ioOf(app), .generation = q.generation, .arena = .init(app.gpa) };
    const a = job.arena.allocator();
    job.key = key.clone(a) catch {
        job.arena.deinit();
        return;
    };
    var history = job.key.history;
    for (q.ready.items) |c| history = install.remember(a, history, c.source) catch history;
    job.history = history;
    q.loading = true;
    var task = app.backgroundExecutor().spawn(job) catch {
        q.loading = false;
        var j = job;
        j.arena.deinit();
        return;
    };
    task.detach();
}

const LoadResult = union(enum) { ok: Candidate, err: []const u8 };

const LoadJob = struct {
    app: *App,
    gpa: Allocator,
    io: std.Io,
    generation: u64,
    arena: std.heap.ArenaAllocator,
    key: Key = undefined,
    history: []const []const u8 = &.{},

    pub fn run(self: *LoadJob) LoadResult {
        return loadCandidate(self.gpa, self.io, self.key, self.history);
    }

    pub fn finish(self: *LoadJob, result: LoadResult) void {
        const app = self.app;
        defer self.arena.deinit();
        const q = synchronize(app);
        if (q.generation != self.generation) {
            switch (result) {
                .ok => |c| {
                    var cc = c;
                    cc.discard(app, install.ioOf(app));
                },
                .err => {},
            }
            return;
        }
        q.loading = false;
        switch (result) {
            .ok => |c| q.ready.append(q.gpa, c) catch {
                var cc = c;
                cc.discard(app, install.ioOf(app));
            },
            .err => |m| q.setErr(m),
        }
        settleWaiter(app);
        preload(app);
    }
};

/// `Candidate::load` (worker-safe).
fn loadCandidate(gpa: Allocator, io: std.Io, key: Key, history: []const []const u8) LoadResult {
    const folder = key.folder orelse return .{ .err = msg_no_folder };
    var chosen = choose(gpa, io, folder, history) catch |err| return .{ .err = switch (err) {
        error.Unreadable => msg_unreadable_folder,
        else => msg_no_images,
    } };
    defer chosen.loaded.deinit(gpa);
    const proxy = artwork.Proxy.fromImage(gpa, chosen.loaded.image) catch {
        gpa.free(chosen.source);
        return .{ .err = msg_no_images };
    };
    const src = cache.Source.create(gpa, proxy) catch {
        var p = proxy;
        p.deinit(gpa);
        gpa.free(chosen.source);
        return .{ .err = msg_no_images };
    };
    if (cache.renderRaster(gpa, &src.proxy, key.effect, key.light)) |img| {
        src.adopt(key.effect, key.light, img) catch img.release();
    }
    const color = src.proxy.color();
    const prepared = install.prepareLoaded(gpa, io, key.data_dir, chosen.source, &chosen.loaded) catch {
        src.release();
        gpa.free(chosen.source);
        return .{ .err = install.msg_permissions };
    };
    return .{ .ok = .{ .source = chosen.source, .color = color, .prepared = prepared, .artwork = src } };
}

/// `take_ready`: commit the next warm candidate. Null when none is ready.
fn takeReady(app: *App) ??[]const u8 {
    const q = queueMut(app) orelse return null;
    if (q.ready.items.len == 0) return null;
    var c = q.ready.orderedRemove(0);
    defer app.gpa.free(c.source);
    const err = install.commit(app, c.source, &c.prepared, c.color, c.artwork);
    const q2 = queueMut(app).?;
    if (err == null) {
        _ = q2.key_arena.reset(.retain_capacity);
        var scratch = std.heap.ArenaAllocator.init(app.gpa);
        defer scratch.deinit();
        q2.key = if (Key.current(app, scratch.allocator())) |k| (k.clone(q2.key_arena.allocator()) catch null) else |_| null;
        preload(app);
    } else q2.key = null;
    return err;
}

fn report(app: *App, origin: Origin, err: ?[]const u8) void {
    install.setError(app, err);
    if (err != null and origin == .shortcut) if (open_appearance) |open| open(app, false);
}

fn settleWaiter(app: *App) void {
    const q = queueMut(app) orelse return;
    const origin = q.waiting orelse return;
    if (q.generation != q.waiting_generation) {
        q.waiting = null;
        return;
    }
    if (takeReady(app)) |result| {
        queueMut(app).?.waiting = null;
        return report(app, origin, result);
    }
    if (queueMut(app).?.err) |e| {
        queueMut(app).?.waiting = null;
        const copy = app.gpa.dupe(u8, e) catch return;
        defer app.gpa.free(copy);
        report(app, origin, copy);
    }
}

/// `randomize`: switch to a random wallpaper now when one is warm, else as
/// soon as the lookahead produces one. Errors reach `install.lastError`
/// (and, from the shortcut, open Settings → Appearance).
pub fn randomize(app: *App, origin: Origin) void {
    install.setError(app, null);
    if (store.current(app).wallpaperFolder == null) {
        if (origin == .shortcut) {
            if (open_appearance) |open| open(app, true);
        } else install.setError(app, msg_no_folder);
        return;
    }
    const q = synchronize(app);
    // A user request retries a failed speculative preload.
    q.setErr(null);
    preload(app);
    if (takeReady(app)) |result| return report(app, origin, result);
    const q2 = queueMut(app).?;
    q2.waiting = origin;
    q2.waiting_generation = q2.generation;
    settleWaiter(app);
}

/// Set the folder and shuffle once (`choose_wallpaper_folder`).
pub fn setFolder(app: *App, folder: []const u8) void {
    const Set = struct {
        fn f(p: []const u8, s: *model.UiSettings, a: Allocator) void {
            s.wallpaperFolder = a.dupe(u8, p) catch return;
        }
    };
    store.update(app, .immediate, folder, Set.f);
    randomize(app, .settings);
}

pub fn readyCount(app: *App) usize {
    return if (app.tryGlobal(Queue)) |q| q.ready.items.len else 0;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "cooldown and recency push recent wallpapers last" {
    try testing.expectEqual(@as(usize, 1), cooldown(0));
    try testing.expectEqual(@as(usize, 1), cooldown(3));
    try testing.expectEqual(@as(usize, 8), cooldown(12));
    const history = [_][]const u8{ "/w/a", "/w/b", "/w/c" };
    try testing.expectEqual(@as(usize, 3), recency(&history, 3, "/w/a"));
    try testing.expectEqual(@as(usize, 1), recency(&history, 3, "/w/c"));
    try testing.expectEqual(@as(usize, 0), recency(&history, 2, "/w/c"));
    try testing.expectEqual(@as(usize, 0), recency(&history, 3, "/w/z"));
    try testing.expect(supported("x.JPG") and supported("y.webp") and !supported("z.txt") and !supported("png"));
}

test "choose skips unreadable files and recent picks" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.png", .data = "nope" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "x" });
    try cache.test_support.png(tmp.dir, "a.png", 4, 4, .{ 10, 20, 30, 255 });
    try cache.test_support.png(tmp.dir, "b.png", 4, 4, .{ 40, 50, 60, 255 });
    const folder = try cache.test_support.path(tmp.dir, "");
    defer gpa.free(folder);
    const a_path = try std.fs.path.join(gpa, &.{ folder, "a.png" });
    defer gpa.free(a_path);
    // With "a" most recent and a cooldown of 1, "b" always wins.
    for (0..4) |_| {
        var c = try choose(gpa, testing.io, folder, &.{a_path});
        defer c.deinit(gpa);
        try testing.expectEqualStrings("b.png", std.fs.path.basename(c.source));
    }
    try testing.expectError(error.Unreadable, choose(gpa, testing.io, "/nonexistent/zeron-wallpapers", &.{}));
}
