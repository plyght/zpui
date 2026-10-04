//! Object-fit geometry (gpui `ObjectFit::get_bounds`) and the cover crop the
//! zui fork's `paint_image_fitted` performs: paint only `visible = bounds ∩
//! fitted` and crop the atlas tile's UVs to match (scene.cropTileForFit), so
//! corner radii round the element's real corners.

const std = @import("std");
const geometry = @import("../geometry.zig");
const scene = @import("../scene.zig");
const atlas_mod = @import("../atlas.zig");

const Pixels = geometry.Pixels;
const PxBounds = geometry.Bounds(Pixels);

pub const ObjectFit = enum {
    /// Stretch to the element's bounds.
    fill,
    /// Scale to fit inside, keeping aspect (gpui's default for `img`).
    contain,
    /// Scale to cover, keeping aspect; the overflow is cropped.
    cover,
    /// `contain` if the image is larger than the bounds, else natural size, centered.
    scale_down,
    /// Natural size at the bounds' origin.
    none,

    /// gpui `ObjectFit::get_bounds`. Like gpui, the image's device size is used
    /// as its natural size in logical pixels for `scale_down` and `none`.
    pub fn getBounds(self: ObjectFit, bounds: PxBounds, image_size: geometry.Size(geometry.DevicePixels)) PxBounds {
        const iw: f32 = @floatFromInt(image_size.width);
        const ih: f32 = @floatFromInt(image_size.height);
        const bw = bounds.size.width;
        const bh = bounds.size.height;
        const image_ratio = iw / ih;
        const bounds_ratio = bw / bh;
        return switch (self) {
            .fill => bounds,
            .contain => centered(bounds, if (bounds_ratio > image_ratio) .{ .width = iw * (bh / ih), .height = bh } else .{ .width = bw, .height = ih * (bw / iw) }),
            .scale_down => if (iw > bw or ih > bh)
                ObjectFit.contain.getBounds(bounds, image_size)
            else
                centered(bounds, .{ .width = iw, .height = ih }),
            .cover => centered(bounds, if (bounds_ratio > image_ratio) .{ .width = bw, .height = ih * (bw / iw) } else .{ .width = iw * (bh / ih), .height = bh }),
            .none => .{ .origin = bounds.origin, .size = .{ .width = iw, .height = ih } },
        };
    }
};

fn centered(bounds: PxBounds, size: geometry.Size(Pixels)) PxBounds {
    return .{
        .origin = .{
            .x = bounds.origin.x + (bounds.size.width - size.width) / 2.0,
            .y = bounds.origin.y + (bounds.size.height - size.height) / 2.0,
        },
        .size = size,
    };
}

/// What `img()` paints for one frame: `fitted` is the object-fit box, `visible`
/// its part inside the element (the sprite bounds). Empty `visible` means
/// nothing to draw.
pub const FittedImage = struct {
    fitted: PxBounds,
    visible: PxBounds,

    pub fn isCropped(self: FittedImage) bool {
        return !std.meta.eql(self.visible, self.fitted);
    }

    /// The tile to put in the `PolychromeSprite`: cropped to `visible` when
    /// the fitted box overflows the element (gpui fork `paint_image_fitted`).
    pub fn tile(self: FittedImage, full: atlas_mod.AtlasTile) atlas_mod.AtlasTile {
        return if (self.isCropped()) scene.cropTileForFit(full, self.visible, self.fitted) else full;
    }
};

/// gpui `Img::paint`: `fitted = object_fit.get_bounds(bounds, size)`, `visible = bounds ∩ fitted`.
pub fn fitImage(object_fit: ObjectFit, bounds: PxBounds, image_size: geometry.Size(geometry.DevicePixels)) FittedImage {
    const fitted = object_fit.getBounds(bounds, image_size);
    return .{ .fitted = fitted, .visible = bounds.intersect(fitted) };
}

fn rect(x: f32, y: f32, w: f32, h: f32) PxBounds {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "object fit geometry matches gpui" {
    const b = rect(0, 0, 200, 100);
    const img: geometry.Size(geometry.DevicePixels) = .{ .width = 100, .height = 100 };
    try std.testing.expectEqual(rect(0, 0, 200, 100), ObjectFit.fill.getBounds(b, img));
    try std.testing.expectEqual(rect(50, 0, 100, 100), ObjectFit.contain.getBounds(b, img));
    try std.testing.expectEqual(rect(0, -50, 200, 200), ObjectFit.cover.getBounds(b, img));
    try std.testing.expectEqual(rect(50, 0, 100, 100), ObjectFit.scale_down.getBounds(b, img));
    try std.testing.expectEqual(rect(75, 25, 50, 50), ObjectFit.scale_down.getBounds(b, .{ .width = 50, .height = 50 }));
    try std.testing.expectEqual(rect(0, 0, 400, 50), ObjectFit.none.getBounds(b, .{ .width = 400, .height = 50 }));
    try std.testing.expectEqual(rect(0, 25, 200, 50), ObjectFit.contain.getBounds(b, .{ .width = 400, .height = 100 }));
}

test "cover crops the tile to the visible part" {
    const b = rect(10, 10, 100, 50);
    const f = fitImage(.cover, b, .{ .width = 200, .height = 200 });
    try std.testing.expectEqual(rect(10, -15, 100, 100), f.fitted);
    try std.testing.expectEqual(b, f.visible);
    try std.testing.expect(f.isCropped());
    const full: atlas_mod.AtlasTile = .{
        .texture_id = .{ .index = 0, .kind = .polychrome },
        .tile_id = 1,
        .padding = 0,
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 200, .height = 200 } },
    };
    const t = f.tile(full);
    try std.testing.expectEqual(@as(i32, 50), t.bounds.origin.y);
    try std.testing.expectEqual(@as(i32, 200), t.bounds.size.width);
    try std.testing.expectEqual(@as(i32, 100), t.bounds.size.height);
    const contained = fitImage(.contain, b, .{ .width = 200, .height = 200 });
    try std.testing.expect(!contained.isCropped());
    try std.testing.expectEqual(full, contained.tile(full));
}
