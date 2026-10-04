//! Lazily rendered Mermaid diagrams for surfaces that discover their fences
//! while painting (zeron `markdown/mermaid_cache.rs` + the transcript's
//! diagram worker).
//!
//! Rows request their fences as they lay out, so only painted diagrams cost
//! anything. One requested source renders at a time on the background
//! executor (parse → layout → SVG → lunasvg raster); requests whose rows left
//! the viewport before their turn are dropped. Results are retained under a
//! byte budget, least recently painted first out; diagrams painted in the
//! latest two passes are never evicted. Main thread only (except the job's
//! `run`).

const std = @import("std");
const zpui = @import("zpui");
const media = @import("zeron_media");

const App = zpui.App;
const RenderImage = zpui.RenderImage;
const diagram = media.diagram;
const gpa = std.heap.smp_allocator;

pub const max_retained_bytes: usize = 64 * 1024 * 1024;
const max_entries: usize = 64;

pub const Size = diagram.Size;

pub const Lookup = union(enum) {
    pending,
    ready: struct { image: *RenderImage, natural: Size, key: u64 },
    failed: []const u8,
};

const State = enum { pending, ready, failed };

const Entry = struct {
    code: []u8,
    dark: bool,
    state: State = .pending,
    /// Paint pass that last requested this source.
    used: u64,
    message: []u8 = &.{},
    svg: []u8 = &.{},
    natural: Size = .{ .width = 1, .height = 1 },
    image: ?*RenderImage = null,
    raster: [2]u32 = .{ 0, 0 },
    /// A re-raster for a new view is queued or running.
    rerender: bool = false,

    fn bytes(e: *const Entry) usize {
        return e.svg.len * 2 + 1024 + @as(usize, e.raster[0]) * e.raster[1] * 8;
    }
};

var entries: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty;
var frame: u64 = 0;
var view: Size = .{ .width = 720, .height = 480 };
var view_scale: f32 = 2;
var busy: bool = false;
/// Diagram frames switched to their source, by frame key.
var source_visible: std.AutoHashMapUnmanaged(u64, void) = .empty;

pub fn keyFor(code: []const u8, dark: bool) u64 {
    return std.hash.Wyhash.hash(if (dark) 0xDA4C else 0x11E7, code);
}

/// Free a raster and its atlas tiles in every window.
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

/// Start a paint pass with the reading column and display density
/// (`begin_frame` + `set_view`).
pub fn beginFrame(column: f32, scale: f32) void {
    frame += 1;
    view = .{ .width = @max(column, 1), .height = 480 };
    view_scale = scale;
}

fn targetSize(e: *const Entry) [2]u32 {
    return diagram.rasterSize(e.natural, view, view_scale, diagram.preview_pixels);
}

/// Look up a fence painted in the current pass, queueing it if unseen.
pub fn request(app: *App, code: []const u8, dark: bool) Lookup {
    const key = keyFor(code, dark);
    const gop = entries.getOrPut(gpa, key) catch return .pending;
    if (!gop.found_existing) {
        const owned = gpa.dupe(u8, code) catch {
            _ = entries.swapRemove(key);
            return .pending;
        };
        gop.value_ptr.* = .{ .code = owned, .dark = dark, .used = frame };
    }
    const e = gop.value_ptr;
    e.used = frame;
    switch (e.state) {
        .pending => {
            pump(app);
            return .pending;
        },
        .failed => return .{ .failed = e.message },
        .ready => {
            const want = targetSize(e);
            if (!e.rerender and (want[0] != e.raster[0] or want[1] != e.raster[1])) {
                e.rerender = true;
                pump(app);
            }
            return .{ .ready = .{ .image = e.image.?, .natural = e.natural, .key = key } };
        },
    }
}

pub fn sourceVisible(frame_key: u64) bool {
    return source_visible.contains(frame_key);
}

pub fn toggleSource(frame_key: u64) void {
    if (source_visible.remove(frame_key)) return;
    source_visible.put(gpa, frame_key, {}) catch {};
}

pub fn get(key: u64) ?*Entry {
    return entries.getPtr(key);
}

pub fn retainedBytes() usize {
    var n: usize = 0;
    for (entries.values()) |*e| if (e.state == .ready) {
        n += e.bytes();
    };
    return n;
}

/// The next job: pending requests not repainted in the latest two passes
/// are forgotten; the most recently painted pending source (or stale
/// raster) goes first.
fn nextJob() ?u64 {
    var i: usize = 0;
    while (i < entries.count()) {
        const e = &entries.values()[i];
        if (e.state == .pending and frame -| e.used > 1) {
            gpa.free(e.code);
            entries.swapRemoveAt(i);
            continue;
        }
        i += 1;
    }
    var best: ?u64 = null;
    var best_used: u64 = 0;
    for (entries.keys(), entries.values()) |k, *e| {
        const wants = e.state == .pending or (e.state == .ready and e.rerender and frame -| e.used <= 1);
        if (!wants) continue;
        if (best == null or e.used > best_used) {
            best = k;
            best_used = e.used;
        }
    }
    return best;
}

fn pump(app: *App) void {
    if (busy) return;
    const key = nextJob() orelse return;
    const e = entries.getPtr(key).?;
    var job: Job = .{ .app = app, .key = key, .dark = e.dark, .view = view, .scale = view_scale };
    if (e.state == .ready) {
        job.svg = gpa.dupe(u8, e.svg) catch return;
        job.natural = e.natural;
    } else {
        job.code = gpa.dupe(u8, e.code) catch return;
    }
    var task = app.backgroundExecutor().spawn(job) catch {
        var j = job;
        j.deinit();
        return;
    };
    task.detach();
    busy = true;
}

const Result = union(enum) {
    ok: struct { svg: []u8, natural: Size, decoded: zpui.image.DecodedImage, size: [2]u32 },
    failed: struct { message: []const u8, owned: bool },
};

const Job = struct {
    app: *App,
    key: u64,
    dark: bool,
    view: Size,
    scale: f32,
    /// Source to render (first render) …
    code: ?[]u8 = null,
    /// … or the prepared SVG to re-rasterize for a new view.
    svg: ?[]u8 = null,
    natural: Size = .{ .width = 1, .height = 1 },

    pub fn run(self: *Job) Result {
        var svg_doc: []u8 = undefined;
        var natural: Size = undefined;
        if (self.svg) |s| {
            svg_doc = s;
            natural = self.natural;
            self.svg = null;
        } else switch (diagram.prepare(gpa, self.code.?, self.dark)) {
            .ok => |p| {
                svg_doc = p.svg;
                natural = p.natural;
            },
            .failed => |f| return .{ .failed = .{ .message = f.message, .owned = f.owned } },
        }
        const size = diagram.rasterSize(natural, self.view, self.scale, diagram.preview_pixels);
        const decoded = diagram.rasterize(gpa, svg_doc, natural, size) catch {
            gpa.free(svg_doc);
            return .{ .failed = .{ .message = "Diagram could not be rendered", .owned = false } };
        };
        return .{ .ok = .{ .svg = svg_doc, .natural = natural, .decoded = decoded, .size = size } };
    }

    pub fn finish(self: *Job, result: Result) void {
        busy = false;
        const app = self.app;
        defer {
            pump(app);
            app.refreshWindows();
        }
        const e = entries.getPtr(self.key) orelse return self.discard(result);
        switch (result) {
            .ok => |v| {
                const img = RenderImage.create(gpa, v.decoded) catch {
                    var d = v.decoded;
                    d.deinit(gpa);
                    gpa.free(v.svg);
                    return;
                };
                if (e.image) |old| releaseImage(app, old);
                if (e.svg.len > 0) gpa.free(e.svg);
                e.* = .{ .code = e.code, .dark = e.dark, .used = e.used, .state = .ready, .svg = v.svg, .natural = v.natural, .image = img, .raster = v.size };
            },
            .failed => |f| {
                if (e.state == .ready) {
                    // A failed re-raster keeps the current one.
                    e.rerender = false;
                    if (f.owned) gpa.free(f.message);
                    return;
                }
                e.state = .failed;
                e.message = if (f.owned) @constCast(f.message) else (gpa.dupe(u8, f.message) catch @constCast(""));
            },
        }
        evict(app);
    }

    pub fn discard(_: *Job, result: Result) void {
        switch (result) {
            .ok => |v| {
                var d = v.decoded;
                d.deinit(gpa);
                gpa.free(v.svg);
            },
            .failed => |f| if (f.owned) gpa.free(f.message),
        }
    }

    pub fn deinit(self: *Job) void {
        if (self.code) |c| gpa.free(c);
        if (self.svg) |s| gpa.free(s);
    }
};

/// Release settled diagrams least recently painted first until the retained
/// memory and entry count fit their limits.
fn evict(app: *App) void {
    while (retainedBytes() > max_retained_bytes or entries.count() > max_entries) {
        var victim: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (entries.values(), 0..) |*e, i| {
            if (e.state == .pending or frame -| e.used <= 1) continue;
            if (e.used < oldest) {
                oldest = e.used;
                victim = i;
            }
        }
        const i = victim orelse break;
        var e = entries.values()[i];
        entries.swapRemoveAt(i);
        if (e.image) |img| releaseImage(app, img);
        freeEntry(&e);
    }
}

fn freeEntry(e: *Entry) void {
    gpa.free(e.code);
    if (e.message.len > 0) gpa.free(e.message);
    if (e.svg.len > 0) gpa.free(e.svg);
}

/// An enlarged raster for the lightbox (`MediaImage::enlarged`): the
/// viewport at `dpi`, within what the retained budget leaves (at most 2M
/// pixels). Caller owns the image.
pub fn enlarged(key: u64, viewport: Size, dpi: f32) ?*RenderImage {
    const e = entries.getPtr(key) orelse return null;
    if (e.state != .ready) return null;
    const available = max_retained_bytes -| retainedBytes();
    const budget = (available -| (e.svg.len * 2 + 1024)) / 8;
    const current = @as(usize, e.raster[0]) * e.raster[1];
    if (budget < current) return e.image.?.retain();
    const size = diagram.rasterSize(e.natural, viewport, dpi, @min(budget, 2 * diagram.preview_pixels));
    if (size[0] == e.raster[0] and size[1] == e.raster[1]) return e.image.?.retain();
    const decoded = diagram.rasterize(gpa, e.svg, e.natural, size) catch return e.image.?.retain();
    return RenderImage.create(gpa, decoded) catch {
        var d = decoded;
        d.deinit(gpa);
        return e.image.?.retain();
    };
}
