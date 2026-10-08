//! System symbol images (macOS SF Symbols) as tinted monochrome icons.
//!
//! A symbol is looked up by name (`"folder"`, `"gearshape"`), configured with
//! `Options` (point size, weight, scale; AppKit `NSImageSymbolConfiguration`)
//! and rendered by the platform (`Platform.renderSystemSymbol`) into a
//! straight alpha `Mask` at device scale. The mask goes to the monochrome
//! sprite atlas under `AtlasKey.symbol` and is drawn as a `MonochromeSprite`
//! in the element's text color, exactly like an SVG icon.
//!
//! Backends: macOS 11+ (AppKit). Linux and older macOS have none: the
//! platform returns null and callers fall back to their SVG.

const std = @import("std");
const Allocator = std.mem.Allocator;
const atlas_mod = @import("../atlas.zig");

/// `NSFontWeight` steps.
pub const Weight = enum(u8) {
    ultralight,
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    heavy,
    black,

    /// AppKit's `NSFontWeight*` constant.
    pub fn nsFontWeight(self: Weight) f64 {
        return switch (self) {
            .ultralight => -0.8,
            .thin => -0.6,
            .light => -0.4,
            .regular => 0,
            .medium => 0.23,
            .semibold => 0.3,
            .bold => 0.4,
            .heavy => 0.56,
            .black => 0.62,
        };
    }
};

/// `NSImageSymbolScale` (the glyph's size relative to its point size).
pub const Scale = enum(u8) {
    small = 1,
    medium = 2,
    large = 3,
};

pub const Options = struct {
    /// `NSImageSymbolConfiguration` point size (logical points).
    point_size: f32 = 13,
    weight: Weight = .regular,
    scale: Scale = .medium,
    /// Box (logical points) the rendered symbol is scaled down to fit, keeping
    /// its aspect ratio; 0 = no limit. Never scales up.
    fit: f32 = 0,
};

/// What `Platform.renderSystemSymbol` renders: `name` at `options`, with
/// `scale_factor` device pixels per point.
pub const Request = struct {
    name: []const u8,
    options: Options = .{},
    scale_factor: f32 = 1,
};

/// One-byte-per-pixel coverage (`width * height`, rows top to bottom),
/// allocated with the allocator passed to the renderer.
pub const Mask = struct {
    width: u32,
    height: u32,
    bytes: []u8,

    pub fn deinit(self: *Mask, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

pub fn hashName(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5f53796d626f6c, name);
}

/// Monochrome-atlas key: symbol, size, weight, scale (and fit, device scale).
pub fn atlasKey(r: Request) atlas_mod.AtlasKey {
    return .{ .symbol = .{
        .name_hash = hashName(r.name),
        .point_size_bits = @bitCast(r.options.point_size),
        .fit_bits = @bitCast(r.options.fit),
        .scale_factor_bits = @bitCast(r.scale_factor),
        .weight = @intFromEnum(r.options.weight),
        .scale = @intFromEnum(r.options.scale),
    } };
}

/// Device-pixel size a symbol of logical size `w`×`h` renders at, after `fit`.
pub fn deviceSize(w: f64, h: f64, options: Options, scale_factor: f32) struct { u32, u32, f64 } {
    var k: f64 = 1;
    if (options.fit > 0 and w > 0 and h > 0) {
        const f: f64 = options.fit;
        k = @min(1, @min(f / w, f / h));
    }
    const s: f64 = scale_factor;
    const pw: u32 = @intFromFloat(@max(1, @ceil(w * k * s - 0.001)));
    const ph: u32 = @intFromFloat(@max(1, @ceil(h * k * s - 0.001)));
    return .{ pw, ph, k };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "symbol keys differ by symbol, size, weight, scale and device scale" {
    const base: Request = .{ .name = "folder", .options = .{ .point_size = 13 }, .scale_factor = 2 };
    const k = atlasKey(base);
    try testing.expectEqual(atlas_mod.AtlasTextureKind.monochrome, k.textureKind());
    try testing.expect(std.meta.eql(k, atlasKey(base)));
    var r = base;
    r.name = "folder.fill";
    try testing.expect(!std.meta.eql(k, atlasKey(r)));
    r = base;
    r.options.point_size = 14;
    try testing.expect(!std.meta.eql(k, atlasKey(r)));
    r = base;
    r.options.weight = .semibold;
    try testing.expect(!std.meta.eql(k, atlasKey(r)));
    r = base;
    r.options.scale = .large;
    try testing.expect(!std.meta.eql(k, atlasKey(r)));
    r = base;
    r.scale_factor = 1;
    try testing.expect(!std.meta.eql(k, atlasKey(r)));
}

test "deviceSize fits the box without scaling up" {
    const a = deviceSize(20, 10, .{ .fit = 16 }, 2);
    try testing.expectEqual(@as(u32, 32), a[0]);
    try testing.expectEqual(@as(u32, 16), a[1]);
    const b = deviceSize(12, 10, .{ .fit = 16 }, 2);
    try testing.expectEqual(@as(u32, 24), b[0]);
    try testing.expectEqual(@as(f64, 1), b[2]);
    const c = deviceSize(12.2, 10, .{}, 1);
    try testing.expectEqual(@as(u32, 13), c[0]);
}
