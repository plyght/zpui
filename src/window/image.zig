//! Window-layer glue for `src/image/` (decoders, SVG renderer, image cache): the App owns
//! one `ImageServices` (created on first use) and the `img` / `svg` elements go through it.
//!
//! Encoded images decode on a background worker; until then `img` paints nothing (its
//! layout box is sized by the style). When a decode finishes, every window refreshes.
//! Register where `embedded` paths and `svg().path(...)` load from with `setAssetSource`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("../image/image.zig");
const App = @import("../app/app.zig").App;

pub const RenderImage = image.RenderImage;
pub const ImageSource = image.ImageSource;
pub const AssetSource = image.AssetSource;

pub const ImageServices = struct {
    gpa: Allocator,
    cache: image.ImageCache,
    svg: image.SvgRenderer,

    pub fn deinit(self: *ImageServices) void {
        self.cache.deinit();
        self.svg.deinit();
    }
};

/// The App's image services, created on first use.
pub fn services(app: *App) *ImageServices {
    if (app.image_services) |s| return s;
    const s = app.gpa.create(ImageServices) catch @panic("OOM");
    s.* = .{ .gpa = app.gpa, .cache = .init(app.gpa), .svg = .init(app.gpa, null) };
    app.image_services = s;
    return s;
}

pub fn destroyServices(app: *App) void {
    const s = app.image_services orelse return;
    s.deinit();
    app.gpa.destroy(s);
    app.image_services = null;
}

/// Where `ImageSource.embedded` paths and `svg().path(...)` are loaded from.
pub fn setAssetSource(app: *App, source: AssetSource) void {
    services(app).svg.assets = source;
}

const LoadJob = struct {
    inner: image.DecodeJob,
    app: *App,
    key: u64,

    pub fn run(self: *LoadJob) image.LoadError!image.DecodedImage {
        return self.inner.run();
    }
    pub fn finish(self: *LoadJob, r: image.LoadError!image.DecodedImage) void {
        const s = self.app.image_services orelse {
            self.inner.discard(r);
            return;
        };
        _ = s.cache.finishLoad(self.key, r) catch {};
        self.app.refreshWindows();
    }
    pub fn discard(self: *LoadJob, r: image.LoadError!image.DecodedImage) void {
        self.inner.discard(r);
    }
    pub fn deinit(self: *LoadJob) void {
        self.inner.deinit();
    }
};

/// The decoded image for `source`, starting a background decode on first use.
pub fn loadImage(app: *App, source: ImageSource) ?*RenderImage {
    const s = services(app);
    switch (s.cache.get(source)) {
        .ready => |r| return r,
        .loading, .failed => return null,
        .missing => {},
    }
    if (!(s.cache.startLoad(source) catch return null)) return null;
    const bytes: ?[]const u8 = switch (source) {
        .image => |e| e.bytes,
        .embedded, .path => |p| if (s.svg.assets) |a| a.load(p) else null,
        .uri, .render => null,
    };
    const b = bytes orelse {
        _ = s.cache.finishLoad(source.key(), error.NotFound) catch {};
        return null;
    };
    var task = app.backgroundExecutor().spawn(LoadJob{ .inner = .{ .gpa = app.gpa, .bytes = b }, .app = app, .key = source.key() }) catch return null;
    task.detach();
    return null;
}

/// Free the decoded image of `source` and its atlas tiles in every window (zui fork
/// `ImageSource::evict`).
pub fn evict(app: *App, source: ImageSource) void {
    const s = app.image_services orelse return;
    var atlases: [16]*@import("../atlas.zig").Atlas = undefined;
    var n: usize = 0;
    for (app.windows.items) |slot| if (slot) |w| {
        if (n < atlases.len) {
            atlases[n] = w.sprite_atlas;
            n += 1;
        }
    };
    s.cache.evict(source, atlases[0..n]);
}
