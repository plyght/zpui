//! New-thread background artwork cache (zeron `new_thread_background_effects.rs`
//! `CACHE` / `background_luminance` / `raster_image` / `PreloadedArtwork::install`).
//!
//! ```zig
//! const img = cache.prepare(app, path, .ascii, light); // ?*RenderImage, null while loading
//! ```
//!
//! Up to four decoded sources (keyed by path, oldest evicted) live in an App
//! global. A miss spawns one background decode (`artwork.decode` +
//! `Proxy.fromImage`); a ready source lacking the requested effect raster
//! spawns one effect job per (effect, light) key. Everything is source-space:
//! layout, resize and composer geometry never invalidate an entry. Finished
//! jobs refresh the windows. Unreadable files settle as `failed` (the hero
//! simply shows nothing; Settings reports the image as unavailable).

const std = @import("std");
const zpui = @import("zpui");
const artwork = @import("artwork.zig");
const anim = @import("anim_decode.zig");
const video = @import("video.zig");

const App = zpui.App;
const Allocator = std.mem.Allocator;
const RenderImage = zpui.image.RenderImage;
const Effect = artwork.Effect;

pub const max_sources = 4;

/// A decoded proxy shared by the cache and in-flight effect jobs.
pub const Source = struct {
    gpa: Allocator,
    proxy: artwork.Proxy,
    refs: std.atomic.Value(u32) = .init(1),
    /// Main-thread only: (effect, light) → raster (null = job pending).
    effects: std.ArrayList(Raster) = .empty,

    pub const Raster = struct { effect: Effect, light: bool, image: ?*RenderImage };

    pub fn create(gpa: Allocator, proxy: artwork.Proxy) Allocator.Error!*Source {
        const s = try gpa.create(Source);
        s.* = .{ .gpa = gpa, .proxy = proxy };
        return s;
    }

    pub fn retain(self: *Source) *Source {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    /// Drop a reference; the last one frees the proxy (rasters are released
    /// by the cache on the main thread before that).
    pub fn release(self: *Source) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.effects.deinit(self.gpa);
        self.proxy.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn find(self: *Source, effect: Effect, light: bool) ?*Raster {
        for (self.effects.items) |*r| if (r.effect == effect and r.light == light) return r;
        return null;
    }

    /// Seed a raster rendered elsewhere (wallpaper preloads).
    pub fn adopt(self: *Source, effect: Effect, light: bool, image: *RenderImage) Allocator.Error!void {
        try self.effects.append(self.gpa, .{ .effect = effect, .light = artwork.effectUsesLight(effect, light), .image = image });
    }

    fn releaseRasters(self: *Source, app: *App) void {
        for (self.effects.items) |*r| if (r.image) |img| {
            releaseImage(app, img);
            r.image = null;
        };
        self.effects.clearRetainingCapacity();
    }
};

const State = union(enum) { pending, ready: *Source, failed };

const Entry = struct {
    path: []u8,
    state: State,
};

/// The App global.
pub const ArtworkCache = struct {
    gpa: Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,
    /// Jobs started (decode + effect); tests read it to prove warm paths do no work.
    jobs_started: u64 = 0,

    pub fn deinit(self: *ArtworkCache, app: *App) void {
        for (self.entries.items) |*e| dropEntry(app, e, self.gpa);
        self.entries.deinit(self.gpa);
    }

    fn index(self: *const ArtworkCache, path: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) return i;
        return null;
    }

    fn push(self: *ArtworkCache, app: *App, path: []const u8, state: State) Allocator.Error!*Entry {
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        try self.entries.append(self.gpa, .{ .path = owned, .state = state });
        while (self.entries.items.len > max_sources) {
            var old = self.entries.orderedRemove(0);
            dropEntry(app, &old, self.gpa);
        }
        return &self.entries.items[self.entries.items.len - 1];
    }
};

fn dropEntry(app: *App, e: *Entry, gpa: Allocator) void {
    switch (e.state) {
        .ready => |s| {
            s.releaseRasters(app);
            s.release();
        },
        else => {},
    }
    gpa.free(e.path);
}

/// Release a RenderImage, evicting its atlas tiles on the last reference.
pub fn releaseImage(app: *App, r: *RenderImage) void {
    if (r.refs.load(.acquire) == 1) {
        var atlases: [16]*zpui.atlas.Atlas = undefined;
        var n: usize = 0;
        for (app.windows.items) |slot| if (slot) |w| {
            if (n < atlases.len) {
                atlases[n] = w.sprite_atlas;
                n += 1;
            }
        };
        zpui.image.dropImage(r, atlases[0..n]);
    }
    r.release();
}

/// Mutable access without a global-observer notification: the cache is
/// consulted during render, and notifying from there would loop.
fn cacheMut(app: *App) ?*ArtworkCache {
    return @constCast(app.tryGlobal(ArtworkCache) orelse return null);
}

/// Install the cache global (idempotent).
pub fn ensure(app: *App, io: std.Io) *ArtworkCache {
    if (app.tryGlobal(ArtworkCache) == null) {
        app.setGlobal(ArtworkCache{ .gpa = app.gpa, .io = io }) catch @panic("OOM");
    }
    return cacheMut(app).?;
}

pub const Status = enum { loading, ready, failed };

/// Where the source at `path` stands (starts no work).
pub fn status(app: *App, path: []const u8) ?Status {
    const c = app.tryGlobal(ArtworkCache) orelse return null;
    const i = c.index(path) orelse return null;
    return switch (c.entries.items[i].state) {
        .pending => .loading,
        .ready => .ready,
        .failed => .failed,
    };
}

/// The effect raster for `path`, or null while decoding / rendering (work is
/// started on the first miss). `light` matters only for the light-aware effects.
pub fn prepare(app: *App, io: std.Io, path: []const u8, effect: Effect, light_in: bool) ?*RenderImage {
    const c = ensure(app, io);
    const light = artwork.effectUsesLight(effect, light_in);
    const i = c.index(path) orelse {
        _ = c.push(app, path, .pending) catch return null;
        startDecode(app, c, path);
        return null;
    };
    const src = switch (c.entries.items[i].state) {
        .ready => |s| s,
        else => return null,
    };
    if (src.find(effect, light)) |r| return r.image;
    src.effects.append(src.gpa, .{ .effect = effect, .light = light, .image = null }) catch return null;
    startEffect(app, c, src, effect, light);
    return null;
}

/// `PreloadedArtwork::install`: seed `path` with an already decoded source.
pub fn install(app: *App, io: std.Io, path: []const u8, source: *Source) void {
    const c = ensure(app, io);
    if (c.index(path)) |i| {
        var old = c.entries.orderedRemove(i);
        dropEntry(app, &old, c.gpa);
    }
    _ = c.push(app, path, .{ .ready = source }) catch {
        source.releaseRasters(app);
        source.release();
    };
}

/// Forget `path` (a removed or replaced managed file).
pub fn forget(app: *App, path: []const u8) void {
    const c = cacheMut(app) orelse return;
    if (c.index(path)) |i| {
        var old = c.entries.orderedRemove(i);
        dropEntry(app, &old, c.gpa);
    }
}

pub fn jobsStarted(app: *App) u64 {
    return if (app.tryGlobal(ArtworkCache)) |c| c.jobs_started else 0;
}

// ---- jobs -------------------------------------------------------------------

fn startDecode(app: *App, c: *ArtworkCache, path: []const u8) void {
    const owned = c.gpa.dupe(u8, path) catch return markFailed(app, path);
    const job: DecodeJob = .{ .app = app, .gpa = c.gpa, .io = c.io, .path = owned };
    var task = app.backgroundExecutor().spawn(job) catch {
        c.gpa.free(owned);
        return markFailed(app, path);
    };
    c.jobs_started += 1;
    task.detach();
}

fn markFailed(app: *App, path: []const u8) void {
    const c = cacheMut(app) orelse return;
    if (c.index(path)) |i| c.entries.items[i].state = .failed;
}

/// The still of `path` (worker-safe): Rust's decode, else (zpui-only) the
/// first frame of an animated WebP or a video, so a moving file referenced
/// directly still shows its poster.
pub fn decodeStill(gpa: Allocator, io: std.Io, path: []const u8) ?artwork.Rgba {
    if (anim.isVideoExtension(path)) return video.firstFrame(gpa, path) catch null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch return null;
    defer gpa.free(bytes);
    if (artwork.decode(gpa, bytes)) |image| return image else |_| {}
    const kind = anim.classify(bytes);
    return switch (kind) {
        .gif, .apng, .webp => anim.firstFrame(gpa, bytes, kind) catch null,
        .video => video.firstFrame(gpa, path) catch null,
        .still => null,
    };
}

/// Read + decode + proxy, off the main thread.
pub fn loadSource(gpa: Allocator, io: std.Io, path: []const u8) ?*Source {
    var image = decodeStill(gpa, io, path) orelse return null;
    defer image.deinit(gpa);
    const proxy = artwork.Proxy.fromImage(gpa, image) catch return null;
    return Source.create(gpa, proxy) catch {
        var p = proxy;
        p.deinit(gpa);
        return null;
    };
}

const DecodeJob = struct {
    app: *App,
    gpa: Allocator,
    io: std.Io,
    path: []u8,

    pub fn run(self: *DecodeJob) ?*Source {
        return loadSource(self.gpa, self.io, self.path);
    }

    pub fn finish(self: *DecodeJob, result: ?*Source) void {
        defer self.gpa.free(self.path);
        const app = self.app;
        defer app.refreshWindows();
        const c = cacheMut(app) orelse {
            if (result) |s| s.release();
            return;
        };
        const i = c.index(self.path) orelse {
            if (result) |s| s.release();
            return;
        };
        const e = &c.entries.items[i];
        if (e.state != .pending) {
            if (result) |s| s.release();
            return;
        }
        e.state = if (result) |s| .{ .ready = s } else .failed;
    }
};

fn startEffect(app: *App, c: *ArtworkCache, src: *Source, effect: Effect, light: bool) void {
    const job: EffectJob = .{ .app = app, .source = src.retain(), .effect = effect, .light = light };
    var task = app.backgroundExecutor().spawn(job) catch {
        src.release();
        return;
    };
    c.jobs_started += 1;
    task.detach();
}

const EffectJob = struct {
    app: *App,
    source: *Source,
    effect: Effect,
    light: bool,

    pub fn run(self: *EffectJob) ?*RenderImage {
        return renderRaster(self.source.gpa, &self.source.proxy, self.effect, self.light);
    }

    pub fn finish(self: *EffectJob, result: ?*RenderImage) void {
        const app = self.app;
        defer {
            self.source.release();
            app.refreshWindows();
        }
        // Only a source the cache still holds adopts the raster.
        var held = false;
        if (app.tryGlobal(ArtworkCache)) |c| for (c.entries.items) |e| switch (e.state) {
            .ready => |s| if (s == self.source) {
                held = true;
            },
            else => {},
        };
        const slot = if (held) self.source.find(self.effect, self.light) else null;
        if (slot) |r| if (r.image == null) {
            r.image = result;
            return;
        };
        if (result) |img| img.release();
    }
};

/// One effect raster as a RenderImage (worker-safe).
pub fn renderRaster(gpa: Allocator, proxy: *const artwork.Proxy, effect: Effect, light: bool) ?*RenderImage {
    const bgra = proxy.render(gpa, effect, light) catch return null;
    const frames = gpa.alloc(zpui.image.Frame, 1) catch {
        gpa.free(bgra);
        return null;
    };
    frames[0] = .{ .width = proxy.width, .height = proxy.height, .pixels = bgra };
    return RenderImage.create(gpa, .{ .frames = frames }) catch {
        gpa.free(bgra);
        gpa.free(frames);
        return null;
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn writePng(dir: std.Io.Dir, name: []const u8, w: u32, h: u32, rgba: [4]u8) !void {
    const gpa = testing.allocator;
    const bgra = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(bgra);
    var i: usize = 0;
    while (i < bgra.len) : (i += 4) bgra[i..][0..4].* = .{ rgba[2], rgba[1], rgba[0], rgba[3] };
    const png = try zpui.image.encodePng(gpa, bgra, w, h, .bgra);
    defer gpa.free(png);
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = png });
}

fn tmpPath(dir: std.Io.Dir, name: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try dir.realPath(testing.io, &buf);
    return std.fs.path.join(testing.allocator, &.{ buf[0..n], name });
}

pub const test_support = struct {
    pub const png = writePng;
    pub const path = tmpPath;
};

test "prepare decodes once in the background, then renders each effect once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePng(tmp.dir, "a.png", 8, 4, .{ 30, 90, 200, 255 });
    const path = try tmpPath(tmp.dir, "a.png");
    defer testing.allocator.free(path);

    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try testing.expect(prepare(app, testing.io, path, .none, false) == null);
    try testing.expectEqual(Status.loading, status(app, path).?);
    app.runUntilParked();
    try testing.expectEqual(Status.ready, status(app, path).?);
    try testing.expect(prepare(app, testing.io, path, .none, false) == null); // raster job
    app.runUntilParked();
    const img = prepare(app, testing.io, path, .none, false).?;
    try testing.expectEqual(@as(u32, 2048), img.frames[0].width);
    try testing.expectEqual(@as(u32, 1024), img.frames[0].height);
    const jobs = jobsStarted(app);
    // Warm: no new work, the same raster; light is ignored for None.
    try testing.expect(prepare(app, testing.io, path, .none, true).? == img);
    try testing.expectEqual(jobs, jobsStarted(app));
    // Scanlines distinguish light and dark.
    _ = prepare(app, testing.io, path, .scanlines, true);
    _ = prepare(app, testing.io, path, .scanlines, false);
    app.runUntilParked();
    try testing.expect(prepare(app, testing.io, path, .scanlines, true).? != prepare(app, testing.io, path, .scanlines, false).?);
}

test "a missing or damaged file settles as failed without retrying" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.png", .data = "not an image" });
    const bad = try tmpPath(tmp.dir, "bad.png");
    defer testing.allocator.free(bad);
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    _ = prepare(app, testing.io, bad, .none, false);
    _ = prepare(app, testing.io, "/nonexistent/zeron-background.png", .none, false);
    app.runUntilParked();
    try testing.expectEqual(Status.failed, status(app, bad).?);
    try testing.expectEqual(Status.failed, status(app, "/nonexistent/zeron-background.png").?);
    const jobs = jobsStarted(app);
    try testing.expect(prepare(app, testing.io, bad, .none, false) == null);
    try testing.expectEqual(jobs, jobsStarted(app));
}

test "the cache keeps at most four sources" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var buf: [32]u8 = undefined;
    for (0..6) |i| _ = prepare(app, testing.io, try std.fmt.bufPrint(&buf, "/nope/{d}.png", .{i}), .none, false);
    app.runUntilParked();
    try testing.expect(status(app, "/nope/0.png") == null);
    try testing.expect(status(app, "/nope/5.png") != null);
    try testing.expectEqual(@as(usize, max_sources), app.tryGlobal(ArtworkCache).?.entries.items.len);
}
