//! Image sources and the image cache (gpui `ImageSource`, `RetainAllImageCache`,
//! and the zui fork's `ImageSource::evict`).
//!
//! The cache is main-thread state owned by the window/app layer. Decoding is
//! the expensive part and runs elsewhere: `ImageCache.startLoad` tells the
//! caller whether to start a load; the caller runs `decode.decode` (directly
//! or through `DecodeJob` on the background executor) and hands the result to
//! `finishLoad`. Evicting an image frees its atlas tiles in every atlas the
//! caller passes (gpui `App::drop_image` walks all windows the same way).

const std = @import("std");
const Allocator = std.mem.Allocator;
const atlas_mod = @import("../atlas.zig");
const decode_mod = @import("decode.zig");
const render_image = @import("render_image.zig");
const RenderImage = render_image.RenderImage;
const DecodedImage = render_image.DecodedImage;

/// Encoded image bytes with a content id (gpui `Image`: id = hash of bytes).
pub const EncodedImage = struct {
    id: u64,
    bytes: []const u8,

    pub fn fromBytes(bytes: []const u8) EncodedImage {
        return .{ .id = std.hash.Wyhash.hash(0x494d_4721, bytes), .bytes = bytes };
    }
};

/// gpui `ImageSource` (minus `Custom`, which is a window-layer closure).
/// Slices are borrowed; the cache keys by hash and never stores them.
pub const ImageSource = union(enum) {
    /// A file path (gpui `Resource::Path`).
    path: []const u8,
    /// An asset path for the app's asset source (gpui `Resource::Embedded`).
    embedded: []const u8,
    /// A URL (gpui `Resource::Uri`); fetching is the app layer's job.
    uri: []const u8,
    /// Encoded bytes (gpui `ImageSource::Image`).
    image: EncodedImage,
    /// An already-decoded image (gpui `ImageSource::Render`); not cached.
    render: *RenderImage,

    /// gpui `From<&str>`: a URI if it has a scheme, else an embedded asset path.
    pub fn fromString(s: []const u8) ImageSource {
        if (std.mem.indexOf(u8, s, "://")) |i| {
            const scheme = s[0..i];
            var ok = scheme.len > 0 and std.ascii.isAlphabetic(scheme[0]);
            for (scheme) |ch| ok = ok and (std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.');
            if (ok) return .{ .uri = s };
        }
        return .{ .embedded = s };
    }

    /// Cache key. Distinct variants never collide on the same string.
    pub fn key(self: ImageSource) u64 {
        return switch (self) {
            .path => |p| std.hash.Wyhash.hash(1, p),
            .embedded => |p| std.hash.Wyhash.hash(2, p),
            .uri => |p| std.hash.Wyhash.hash(3, p),
            .image => |img| img.id ^ 0x9e37_79b9_7f4a_7c15,
            .render => |r| r.id,
        };
    }
};

/// Why a load failed (kept so a broken image is not retried every frame).
pub const LoadError = decode_mod.Error || error{ NotFound, Io };

/// Free every frame's atlas tile of `image` in each atlas (gpui `Window::drop_image`).
pub fn dropImage(image: *const RenderImage, atlases: []const *atlas_mod.Atlas) void {
    for (atlases) |a| a.evictImage(image.id, @intCast(image.frameCount()));
}

pub const ImageCache = struct {
    gpa: Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// Total decoded bytes of ready entries.
    total_bytes: usize = 0,
    /// Optional budget for `trim` (null: retain everything, like gpui's
    /// `RetainAllImageCache`).
    budget_bytes: ?usize = null,
    frame: u64 = 0,

    pub const Entry = struct {
        state: State,
        last_used: u64,
    };

    pub const State = union(enum) {
        loading,
        ready: *RenderImage,
        failed: LoadError,
    };

    /// What `get` reports for a source.
    pub const Lookup = union(enum) {
        /// Never requested (or evicted): call `startLoad`.
        missing,
        loading,
        ready: *RenderImage,
        failed: LoadError,
    };

    pub fn init(gpa: Allocator) ImageCache {
        return .{ .gpa = gpa };
    }

    /// Releases every image. Atlas tiles are not touched: call `clear` with the
    /// atlases first if they outlive the cache.
    pub fn deinit(self: *ImageCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| if (e.state == .ready) e.state.ready.release();
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Advance the use clock; call once per frame before painting.
    pub fn beginFrame(self: *ImageCache) void {
        self.frame += 1;
    }

    /// State of `source`, marking it used this frame. `.render` sources are
    /// always ready and never stored.
    pub fn get(self: *ImageCache, source: ImageSource) Lookup {
        if (source == .render) return .{ .ready = source.render };
        const e = self.entries.getPtr(source.key()) orelse return .missing;
        e.last_used = self.frame;
        return switch (e.state) {
            .loading => .loading,
            .ready => |r| .{ .ready = r },
            .failed => |err| .{ .failed = err },
        };
    }

    /// Mark `source` as loading. Returns true when the caller must start the
    /// load (it was missing); false if it is already loading, ready or failed.
    pub fn startLoad(self: *ImageCache, source: ImageSource) Allocator.Error!bool {
        if (source == .render) return false;
        const gop = try self.entries.getOrPut(self.gpa, source.key());
        if (gop.found_existing) return false;
        gop.value_ptr.* = .{ .state = .loading, .last_used = self.frame };
        return true;
    }

    /// Deliver a load result for `key` (`ImageSource.key`). Takes ownership of
    /// a decoded image (allocated with `self.gpa`). Results for keys that were
    /// evicted meanwhile are dropped. Returns the stored image, if any.
    pub fn finishLoad(self: *ImageCache, key: u64, result: LoadError!DecodedImage) Allocator.Error!?*RenderImage {
        var decoded = result catch |err| {
            if (self.entries.getPtr(key)) |e| if (e.state == .loading) {
                e.state = .{ .failed = err };
            };
            return null;
        };
        const e = self.entries.getPtr(key) orelse {
            decoded.deinit(self.gpa);
            return null;
        };
        if (e.state != .loading) {
            decoded.deinit(self.gpa);
            return null;
        }
        const image = RenderImage.create(self.gpa, decoded) catch |err| {
            decoded.deinit(self.gpa);
            e.state = .{ .failed = error.OutOfMemory };
            return err;
        };
        e.state = .{ .ready = image };
        self.total_bytes += image.byteSize();
        return image;
    }

    /// Store an already-decoded image under `source` (retains it).
    pub fn insert(self: *ImageCache, source: ImageSource, image: *RenderImage, atlases: []const *atlas_mod.Atlas) Allocator.Error!void {
        const gop = try self.entries.getOrPut(self.gpa, source.key());
        if (gop.found_existing) self.dropEntry(gop.value_ptr.*, atlases);
        gop.value_ptr.* = .{ .state = .{ .ready = image.retain() }, .last_used = self.frame };
        self.total_bytes += image.byteSize();
    }

    /// The zui fork's `ImageSource::evict`: forget `source` AND free its
    /// decoded image's atlas tiles. A `.render` source only drops its tiles.
    /// Evicting a source that is still loading makes `finishLoad` discard it.
    pub fn evict(self: *ImageCache, source: ImageSource, atlases: []const *atlas_mod.Atlas) void {
        if (source == .render) return dropImage(source.render, atlases);
        const kv = self.entries.fetchRemove(source.key()) orelse return;
        self.dropEntry(kv.value, atlases);
    }

    /// gpui `RetainAllImageCache::clear`.
    pub fn clear(self: *ImageCache, atlases: []const *atlas_mod.Atlas) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| self.dropEntry(e.*, atlases);
        self.entries.clearRetainingCapacity();
    }

    /// Evict least-recently-used ready images until `total_bytes <=
    /// budget_bytes`, sparing anything used in the current frame. Failed
    /// entries are forgotten too so they can be retried. No-op without a budget.
    pub fn trim(self: *ImageCache, atlases: []const *atlas_mod.Atlas) void {
        const budget = self.budget_bytes orelse return;
        while (self.total_bytes > budget) {
            var victim: ?u64 = null;
            var oldest: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.state != .ready or kv.value_ptr.last_used >= self.frame) continue;
                if (kv.value_ptr.last_used < oldest) {
                    oldest = kv.value_ptr.last_used;
                    victim = kv.key_ptr.*;
                }
            }
            const k = victim orelse return;
            const kv = self.entries.fetchRemove(k).?;
            self.dropEntry(kv.value, atlases);
        }
    }

    pub fn count(self: *const ImageCache) usize {
        return self.entries.count();
    }

    fn dropEntry(self: *ImageCache, e: Entry, atlases: []const *atlas_mod.Atlas) void {
        if (e.state != .ready) return;
        const image = e.state.ready;
        dropImage(image, atlases);
        self.total_bytes -= image.byteSize();
        image.release();
    }
};

/// Executor job (src/app/executor.zig protocol) that decodes on a worker.
/// Embed it in a window-layer job whose `finish` calls
/// `cache.finishLoad(key, result)`:
///
/// ```zig
/// const Load = struct {
///     inner: image.DecodeJob,
///     cache: *image.ImageCache,
///     key: u64,
///     pub fn run(self: *Load) image.LoadError!image.DecodedImage { return self.inner.run(); }
///     pub fn finish(self: *Load, r: image.LoadError!image.DecodedImage) void {
///         _ = self.cache.finishLoad(self.key, r) catch {};
///     }
///     pub fn discard(self: *Load, r: image.LoadError!image.DecodedImage) void { self.inner.discard(r); }
///     pub fn deinit(self: *Load) void { self.inner.deinit(); }
/// };
/// ```
pub const DecodeJob = struct {
    /// Thread-safe allocator; also used for the result.
    gpa: Allocator,
    bytes: []const u8,
    /// Free `bytes` with `gpa` in `deinit`.
    owns_bytes: bool = false,
    options: decode_mod.Options = .{},

    pub fn run(self: *DecodeJob) LoadError!DecodedImage {
        return decode_mod.decode(self.gpa, self.bytes, self.options);
    }

    pub fn discard(self: *DecodeJob, result: LoadError!DecodedImage) void {
        var d = result catch return;
        d.deinit(self.gpa);
    }

    pub fn deinit(self: *DecodeJob) void {
        if (self.owns_bytes) self.gpa.free(self.bytes);
    }
};

const tiny_svg = "<svg width=\"4\" height=\"4\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\" height=\"4\" fill=\"#00ff00\"/></svg>";

test "ImageSource keys and parsing" {
    try std.testing.expect(ImageSource.fromString("https://example.com/a.png") == .uri);
    try std.testing.expect(ImageSource.fromString("icons/a.svg") == .embedded);
    try std.testing.expect(ImageSource.fromString("://x") == .embedded);
    const a: ImageSource = .{ .path = "x" };
    const b: ImageSource = .{ .embedded = "x" };
    try std.testing.expect(a.key() != b.key());
    try std.testing.expectEqual(EncodedImage.fromBytes("abc").id, EncodedImage.fromBytes("abc").id);
}

test "cache load lifecycle and evict frees atlas tiles" {
    const gpa = std.testing.allocator;
    var cache = ImageCache.init(gpa);
    defer cache.deinit();
    var atlas = atlas_mod.Atlas.init(gpa, .{});
    defer atlas.deinit();
    const atlases = [_]*atlas_mod.Atlas{&atlas};

    const src: ImageSource = .{ .image = EncodedImage.fromBytes(tiny_svg) };
    try std.testing.expect(cache.get(src) == .missing);
    try std.testing.expect(try cache.startLoad(src));
    try std.testing.expect(!try cache.startLoad(src));
    try std.testing.expect(cache.get(src) == .loading);

    var job: DecodeJob = .{ .gpa = gpa, .bytes = tiny_svg };
    defer job.deinit();
    const image = (try cache.finishLoad(src.key(), job.run())).?;
    try std.testing.expect(cache.get(src) == .ready);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), cache.total_bytes);

    _ = (try atlas.getOrInsertWith(image.atlasKey(0), image.tileBuilder(0))).?;
    try std.testing.expect(atlas.get(image.atlasKey(0)) != null);
    const key = image.atlasKey(0);
    cache.evict(src, &atlases);
    try std.testing.expect(atlas.get(key) == null);
    try std.testing.expect(cache.get(src) == .missing);
    try std.testing.expectEqual(@as(usize, 0), cache.total_bytes);

    // A result arriving after eviction is discarded.
    try std.testing.expect(try cache.startLoad(src));
    cache.evict(src, &atlases);
    try std.testing.expectEqual(@as(?*RenderImage, null), try cache.finishLoad(src.key(), job.run()));

    // Failures are remembered.
    const bad: ImageSource = .{ .path = "broken.png" };
    _ = try cache.startLoad(bad);
    _ = try cache.finishLoad(bad.key(), error.InvalidImage);
    try std.testing.expectEqual(LoadError.InvalidImage, cache.get(bad).failed);
}

test "trim evicts least recently used images over budget" {
    const gpa = std.testing.allocator;
    var cache = ImageCache.init(gpa);
    defer cache.deinit();
    cache.budget_bytes = 300;
    const sources = [_]ImageSource{ .{ .path = "a" }, .{ .path = "b" }, .{ .path = "c" } };
    for (sources) |s| {
        cache.beginFrame();
        _ = try cache.startLoad(s);
        _ = try cache.finishLoad(s.key(), decode_mod.decode(gpa, tiny_svg, .{}));
    }
    try std.testing.expectEqual(@as(usize, 3 * 256), cache.total_bytes);
    cache.beginFrame();
    _ = cache.get(sources[0]); // a used this frame
    cache.trim(&.{});
    try std.testing.expect(cache.get(sources[0]) == .ready);
    try std.testing.expect(cache.get(sources[1]) == .missing);
    try std.testing.expect(cache.get(sources[2]) == .missing);
}

test "insert and render sources" {
    const gpa = std.testing.allocator;
    var cache = ImageCache.init(gpa);
    defer cache.deinit();
    var atlas = atlas_mod.Atlas.init(gpa, .{});
    defer atlas.deinit();
    const image = try RenderImage.create(gpa, try decode_mod.decode(gpa, tiny_svg, .{}));
    defer image.release();
    const src: ImageSource = .{ .render = image };
    try std.testing.expectEqual(image, cache.get(src).ready);
    try std.testing.expect(!try cache.startLoad(src));
    _ = (try atlas.getOrInsertWith(image.atlasKey(0), image.tileBuilder(0))).?;
    cache.evict(src, &.{&atlas});
    try std.testing.expect(atlas.get(image.atlasKey(0)) == null);

    try cache.insert(.{ .embedded = "x" }, image, &.{});
    try std.testing.expect(cache.get(.{ .embedded = "x" }) == .ready);
}
