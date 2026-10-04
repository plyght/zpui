//! Decoded image data (gpui `RenderImage` / `image::Frame`).
//!
//! `DecodedImage` is the plain output of the decoders (no id, no sharing) so
//! it can be produced on a worker thread; `RenderImage.create` turns it into
//! the shared, refcounted handle the window layer paints and the image cache
//! stores. Pixels are straight-alpha BGRA, which is what the polychrome atlas
//! (`AtlasTextureKind.polychrome`) expects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const atlas_mod = @import("../atlas.zig");

pub const ImageId = u64;

/// gpui's default frame delay when none is known (`Delay::from_numer_denom_ms(100, 1)`).
pub const default_delay_ms: u32 = 100;

pub const Frame = struct {
    width: u32,
    height: u32,
    /// Display time of this frame (animated GIFs); 100 ms otherwise.
    delay_ms: u32 = default_delay_ms,
    /// `width * height * 4` bytes, straight-alpha BGRA, top row first.
    pixels: []u8,
};

/// Output of a decode. Owns `frames` and their pixels (allocated with the
/// allocator passed to the decoder, which must then be used for `deinit`).
pub const DecodedImage = struct {
    frames: []Frame,
    /// Device pixels per logical pixel of the image (2 for gpui's SVG renders).
    scale_factor: f32 = 1.0,

    pub fn deinit(self: *DecodedImage, gpa: Allocator) void {
        for (self.frames) |f| gpa.free(f.pixels);
        gpa.free(self.frames);
        self.* = undefined;
    }

    pub fn byteSize(self: DecodedImage) usize {
        var n: usize = 0;
        for (self.frames) |f| n += f.pixels.len;
        return n;
    }
};

/// Process-wide id source, like gpui's `static NEXT_ID: AtomicUsize`. Ids
/// key the atlas (`AtlasKey.image`), so they must be unique across windows.
var next_id: std.atomic.Value(u64) = .init(1);

/// gpui `RenderImage`: a shared, refcounted decoded image. Create with
/// `create`, share with `retain`, drop with `release`. Before the last
/// release, callers that drew it must free its atlas tiles
/// (`ImageCache.dropImage` / `Atlas.evictImage(id, frameCount())`).
pub const RenderImage = struct {
    id: ImageId,
    scale_factor: f32,
    frames: []Frame,
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),

    /// Take ownership of `decoded` (which must have been allocated with `gpa`).
    pub fn create(gpa: Allocator, decoded: DecodedImage) Allocator.Error!*RenderImage {
        const self = try gpa.create(RenderImage);
        self.* = .{
            .id = next_id.fetchAdd(1, .monotonic),
            .scale_factor = decoded.scale_factor,
            .frames = decoded.frames,
            .gpa = gpa,
        };
        return self;
    }

    pub fn retain(self: *RenderImage) *RenderImage {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *RenderImage) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = self.gpa;
        var decoded: DecodedImage = .{ .frames = self.frames };
        decoded.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn frameCount(self: *const RenderImage) usize {
        return self.frames.len;
    }

    /// BGRA bytes of `frame_index`, or null if out of range.
    pub fn asBytes(self: *const RenderImage, frame_index: usize) ?[]const u8 {
        if (frame_index >= self.frames.len) return null;
        return self.frames[frame_index].pixels;
    }

    /// Size in device pixels (zero for an invalid frame).
    pub fn size(self: *const RenderImage, frame_index: usize) geometry.Size(geometry.DevicePixels) {
        if (frame_index >= self.frames.len) return .zero;
        const f = self.frames[frame_index];
        return .{ .width = @intCast(f.width), .height = @intCast(f.height) };
    }

    /// Size for layout, adjusted for `scale_factor` (gpui `render_size`).
    pub fn renderSize(self: *const RenderImage, frame_index: usize) geometry.Size(geometry.Pixels) {
        const s = self.size(frame_index);
        return .{
            .width = @as(f32, @floatFromInt(s.width)) / self.scale_factor,
            .height = @as(f32, @floatFromInt(s.height)) / self.scale_factor,
        };
    }

    /// Delay of `frame_index` in milliseconds (gpui `delay`).
    pub fn delayMs(self: *const RenderImage, frame_index: usize) u32 {
        if (frame_index >= self.frames.len) return default_delay_ms;
        return self.frames[frame_index].delay_ms;
    }

    pub fn byteSize(self: *const RenderImage) usize {
        var n: usize = 0;
        for (self.frames) |f| n += f.pixels.len;
        return n;
    }

    /// gpui `RenderImageParams` as an atlas key.
    pub fn atlasKey(self: *const RenderImage, frame_index: usize) atlas_mod.AtlasKey {
        return .{ .image = .{ .image_id = self.id, .frame_index = @intCast(frame_index) } };
    }

    /// `atlas.getOrInsertWith(image.atlasKey(i), image.tileBuilder(i))` — the
    /// body of gpui's `paint_image` closure. Out-of-range frames build nothing.
    pub fn tileBuilder(self: *const RenderImage, frame_index: usize) TileBuilder {
        return .{ .image = self, .frame_index = frame_index };
    }

    pub const TileBuilder = struct {
        image: *const RenderImage,
        frame_index: usize,

        pub fn build(self: TileBuilder) error{}!?atlas_mod.BuiltTile {
            const bytes = self.image.asBytes(self.frame_index) orelse return null;
            return .{ .size = self.image.size(self.frame_index), .bytes = bytes };
        }
    };
};

test "RenderImage accessors and refcount" {
    const gpa = std.testing.allocator;
    const frames = try gpa.alloc(Frame, 2);
    frames[0] = .{ .width = 2, .height = 1, .pixels = try gpa.dupe(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }) };
    frames[1] = .{ .width = 1, .height = 1, .delay_ms = 40, .pixels = try gpa.dupe(u8, &.{ 9, 9, 9, 9 }) };
    const img = try RenderImage.create(gpa, .{ .frames = frames, .scale_factor = 2 });
    const other = try RenderImage.create(gpa, .{ .frames = try gpa.alloc(Frame, 0) });
    defer other.release();
    try std.testing.expect(img.id != other.id);
    try std.testing.expectEqual(@as(usize, 2), img.frameCount());
    try std.testing.expectEqual(@as(f32, 1), img.renderSize(0).width);
    try std.testing.expectEqual(@as(u32, 40), img.delayMs(1));
    try std.testing.expectEqual(@as(u32, 100), img.delayMs(7));
    try std.testing.expectEqual(@as(?[]const u8, null), img.asBytes(2));
    try std.testing.expectEqual(@as(i32, 0), other.size(0).width);

    var atlas = atlas_mod.Atlas.init(gpa, .{});
    defer atlas.deinit();
    const tile = (try atlas.getOrInsertWith(img.atlasKey(0), img.tileBuilder(0))).?;
    try std.testing.expectEqual(atlas_mod.AtlasTextureKind.polychrome, tile.texture_id.kind);
    try std.testing.expectEqual(@as(?atlas_mod.AtlasTile, null), try atlas.getOrInsertWith(img.atlasKey(5), img.tileBuilder(5)));

    _ = img.retain();
    img.release();
    img.release();
}
