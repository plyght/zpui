//! SVG rendering (gpui `svg_renderer.rs`) on top of the vendored lunasvg.
//!
//! Two output shapes, as in gpui:
//! - **alpha masks** (`renderAlphaMask`, gpui `render_alpha_mask`) for tinted
//!   monochrome icons: one coverage byte per pixel, uploaded to the
//!   monochrome atlas under an `AtlasKey.svg` (`RenderSvgParams.atlasKey`) and
//!   drawn as a `MonochromeSprite` in the element's text color. The size is in
//!   device pixels and already includes `SMOOTH_SVG_SCALE_FACTOR` (gpui's
//!   `paint_svg` asks for `ceil(device_size * 2)` and draws it at half size).
//! - **straight-alpha BGRA images** (`renderSingleFrame`, gpui
//!   `render_single_frame`; `renderPolychrome` at an exact device size) for
//!   multicolor SVGs such as zeron's vscode-symbols file icons, which zeron
//!   shows through `img()`; they go to the polychrome atlas as `AtlasKey.image`.
//!
//! `SvgRenderer` parses each path once and caches the document; it is meant
//! for the main thread. The free functions (`rasterizeAlphaMask`,
//! `rasterizeImage`) parse and render from bytes with no shared state, so
//! they can run on executor workers. A `Document` may move between threads but
//! must not be rendered by two threads at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const geometry = @import("../geometry.zig");
const atlas_mod = @import("../atlas.zig");
const render_image = @import("render_image.zig");

const DevicePixels = geometry.DevicePixels;
const DeviceSize = geometry.Size(DevicePixels);

/// gpui `SMOOTH_SVG_SCALE_FACTOR`: SVGs are rasterized at twice the drawn size.
pub const SMOOTH_SVG_SCALE_FACTOR: f32 = 2.0;
/// gpui caps pixmaps at 8192 px per side (zed issue #56466).
pub const MAX_SIZE: f32 = 8192.0;

pub const Error = error{ OutOfMemory, InvalidSvg, ZeroSize, RenderFailed };

/// gpui `SvgSize`: an absolute device size (only the width sets the scale; the
/// height follows the document's aspect ratio) or a factor on the intrinsic size.
pub const SvgSize = union(enum) {
    size: DeviceSize,
    scale_factor: f32,
};

/// Pixel buffer produced by a render. `bytes` is `width * height * bpp`.
pub const Pixmap = struct {
    width: u32,
    height: u32,
    bytes: []u8,

    pub fn deinit(self: *Pixmap, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }

    pub fn deviceSize(self: Pixmap) DeviceSize {
        return .{ .width = @intCast(self.width), .height = @intCast(self.height) };
    }
};

/// One coverage byte per pixel (monochrome atlas format).
pub const AlphaMask = Pixmap;

/// A parsed SVG document.
pub const Document = struct {
    handle: *c.Svg,
    /// Intrinsic size in user units (width/height attributes, else viewBox).
    width: f32,
    height: f32,

    pub fn parse(bytes: []const u8) Error!Document {
        if (bytes.len == 0) return error.InvalidSvg;
        const handle = c.zpui_svg_parse(bytes.ptr, bytes.len) orelse return error.InvalidSvg;
        var w: f32 = 0;
        var h: f32 = 0;
        c.zpui_svg_size(handle, &w, &h);
        if (!(w > 0 and h > 0)) {
            c.zpui_svg_destroy(handle);
            return error.InvalidSvg;
        }
        return .{ .handle = handle, .width = w, .height = h };
    }

    pub fn deinit(self: *Document) void {
        c.zpui_svg_destroy(self.handle);
        self.* = undefined;
    }

    /// Output size and scale for `size` (gpui `render_pixmap`, incl. the MAX_SIZE clamp).
    pub fn pixmapGeometry(self: Document, size: SvgSize) struct { width: u32, height: u32, scale: f32 } {
        var scale = switch (size) {
            .size => |s| @as(f32, @floatFromInt(s.width)) / self.width,
            .scale_factor => |f| f,
        };
        if (self.width * scale > MAX_SIZE) scale *= MAX_SIZE / (self.width * scale);
        if (self.height * scale > MAX_SIZE) scale *= MAX_SIZE / (self.height * scale);
        // gpui truncates; the epsilon keeps 24 * (32 / 24) from becoming 31.
        return .{
            .width = @intFromFloat(@max(self.width * scale + 1e-3, 0)),
            .height = @intFromFloat(@max(self.height * scale + 1e-3, 0)),
            .scale = scale,
        };
    }

    /// Render to premultiplied BGRA (plutovg's native ARGB32 on little-endian).
    /// `current_color` is 0xAARRGGBB.
    pub fn renderPremultiplied(self: *Document, gpa: Allocator, size: SvgSize, current_color: u32) Error!Pixmap {
        const g = self.pixmapGeometry(size);
        if (g.width == 0 or g.height == 0) return error.ZeroSize;
        const bytes = try gpa.alloc(u8, @as(usize, g.width) * g.height * 4);
        errdefer gpa.free(bytes);
        @memset(bytes, 0);
        const matrix = [6]f32{ g.scale, 0, 0, g.scale, 0, 0 };
        if (c.zpui_svg_render(self.handle, bytes.ptr, @intCast(g.width), @intCast(g.height), @intCast(g.width * 4), &matrix, current_color) != 0)
            return error.RenderFailed;
        return .{ .width = g.width, .height = g.height, .bytes = bytes };
    }

    /// gpui `render_alpha_mask`: coverage of the whole document at `size`
    /// (device pixels, width-driven).
    pub fn renderAlphaMask(self: *Document, gpa: Allocator, size: DeviceSize) Error!AlphaMask {
        if (size.width <= 0 or size.height <= 0) return error.ZeroSize;
        var pm = try self.renderPremultiplied(gpa, .{ .size = size }, 0xFF000000);
        defer pm.deinit(gpa);
        const n = @as(usize, pm.width) * pm.height;
        const mask = try gpa.alloc(u8, n);
        for (mask, 0..) |*a, i| a.* = pm.bytes[i * 4 + 3];
        return .{ .width = pm.width, .height = pm.height, .bytes = mask };
    }

    /// Straight-alpha BGRA (the polychrome atlas format).
    pub fn renderBgra(self: *Document, gpa: Allocator, size: SvgSize, current_color: u32) Error!Pixmap {
        const pm = try self.renderPremultiplied(gpa, size, current_color);
        unpremultiplyBgra(pm.bytes);
        return pm;
    }
};

/// gpui `swap_rgba_pa_to_bgra` minus the swap: premultiplied BGRA -> straight BGRA in place.
pub fn unpremultiplyBgra(bytes: []u8) void {
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const a: u32 = bytes[i + 3];
        if (a == 0 or a == 255) continue;
        inline for (0..3) |k| bytes[i + k] = @intCast(@min(255, (@as(u32, bytes[i + k]) * 255 + a / 2) / a));
    }
}

// ---------------------------------------------------------------------------
// Pure entry points (safe on worker threads)
// ---------------------------------------------------------------------------

/// Parse `bytes` and render an alpha mask at `size` (device pixels).
pub fn rasterizeAlphaMask(gpa: Allocator, bytes: []const u8, size: DeviceSize) Error!AlphaMask {
    var doc = try Document.parse(bytes);
    defer doc.deinit();
    return doc.renderAlphaMask(gpa, size);
}

/// Parse `bytes` and render straight-alpha BGRA at `size`.
pub fn rasterizeBgra(gpa: Allocator, bytes: []const u8, size: SvgSize, current_color: u32) Error!Pixmap {
    var doc = try Document.parse(bytes);
    defer doc.deinit();
    return doc.renderBgra(gpa, size, current_color);
}

/// gpui `render_single_frame`: a one-frame image at `scale_factor *
/// SMOOTH_SVG_SCALE_FACTOR` times the intrinsic size, tagged with
/// `scale_factor = SMOOTH_SVG_SCALE_FACTOR` so it lays out at intrinsic size.
pub fn rasterizeImage(gpa: Allocator, bytes: []const u8, scale_factor: f32) Error!render_image.DecodedImage {
    var pm = try rasterizeBgra(gpa, bytes, .{ .scale_factor = scale_factor * SMOOTH_SVG_SCALE_FACTOR }, 0xFF000000);
    errdefer pm.deinit(gpa);
    const frames = try gpa.alloc(render_image.Frame, 1);
    frames[0] = .{ .width = pm.width, .height = pm.height, .pixels = pm.bytes };
    return .{ .frames = frames, .scale_factor = SMOOTH_SVG_SCALE_FACTOR };
}

// ---------------------------------------------------------------------------
// Atlas keys
// ---------------------------------------------------------------------------

pub fn hashPath(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5356_4721, path);
}

/// gpui `RenderSvgParams`: `size` is the rasterized device size (already
/// multiplied by SMOOTH_SVG_SCALE_FACTOR by the caller, as in `paint_svg`).
pub const RenderSvgParams = struct {
    path: []const u8,
    size: DeviceSize,

    /// Size for an icon drawn in `bounds_device` device pixels (gpui `paint_svg`).
    pub fn forDeviceBounds(path: []const u8, bounds_device: geometry.Size(f32)) RenderSvgParams {
        return .{ .path = path, .size = .{
            .width = @intFromFloat(@ceil(bounds_device.width * SMOOTH_SVG_SCALE_FACTOR)),
            .height = @intFromFloat(@ceil(bounds_device.height * SMOOTH_SVG_SCALE_FACTOR)),
        } };
    }

    /// Monochrome-atlas key for the alpha mask.
    pub fn atlasKey(self: RenderSvgParams) atlas_mod.AtlasKey {
        return .{ .svg = .{ .path_hash = hashPath(self.path), .size = .{ self.size.width, self.size.height } } };
    }

    /// Polychrome-atlas key for a multicolor render at exactly this size
    /// (`SvgRenderer.renderPolychrome`). Ids have the top bit set, which
    /// `RenderImage` ids (a counter) never reach.
    pub fn polychromeAtlasKey(self: RenderSvgParams) atlas_mod.AtlasKey {
        var h = std.hash.Wyhash.init(0x5356_4750);
        h.update(self.path);
        h.update(std.mem.asBytes(&self.size.width));
        h.update(std.mem.asBytes(&self.size.height));
        return .{ .image = .{ .image_id = h.final() | (@as(u64, 1) << 63) } };
    }
};

/// Where `SvgRenderer` loads path bytes from when the caller passes none
/// (gpui `AssetSource`). Returned bytes are borrowed and must outlive the call.
pub const AssetSource = struct {
    ctx: ?*anyopaque = null,
    loadFn: *const fn (ctx: ?*anyopaque, path: []const u8) ?[]const u8,

    pub fn load(self: AssetSource, path: []const u8) ?[]const u8 {
        return self.loadFn(self.ctx, path);
    }
};

/// gpui `SvgRenderer`, plus a parsed-document cache keyed by path.
pub const SvgRenderer = struct {
    gpa: Allocator,
    assets: ?AssetSource,
    documents: std.StringHashMapUnmanaged(?Document) = .empty,

    pub fn init(gpa: Allocator, assets: ?AssetSource) SvgRenderer {
        return .{ .gpa = gpa, .assets = assets };
    }

    pub fn deinit(self: *SvgRenderer) void {
        var it = self.documents.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |*d| d.deinit();
        }
        self.documents.deinit(self.gpa);
        self.* = undefined;
    }

    /// The cached document for `path`, parsing `bytes` (or the asset source's
    /// bytes) on first use. Null when there are no bytes for the path; a parse
    /// failure is cached too, so a broken icon is parsed only once.
    pub fn document(self: *SvgRenderer, path: []const u8, bytes: ?[]const u8) Error!?*Document {
        const gop = try self.documents.getOrPut(self.gpa, path);
        if (!gop.found_existing) {
            const data = bytes orelse (if (self.assets) |a| a.load(path) else null) orelse {
                self.documents.removeByPtr(gop.key_ptr);
                return null;
            };
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch |err| {
                self.documents.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = Document.parse(data) catch |err| switch (err) {
                error.InvalidSvg => null,
                else => {
                    self.gpa.free(gop.key_ptr.*);
                    self.documents.removeByPtr(gop.key_ptr);
                    return err;
                },
            };
        }
        if (gop.value_ptr.*) |*d| return d;
        return error.InvalidSvg;
    }

    /// Drop the cached document for `path` (atlas tiles are the caller's: remove
    /// `RenderSvgParams.atlasKey` entries separately).
    pub fn evict(self: *SvgRenderer, path: []const u8) void {
        const kv = self.documents.fetchRemove(path) orelse return;
        self.gpa.free(kv.key);
        var v = kv.value;
        if (v) |*d| d.deinit();
    }

    /// gpui `render_alpha_mask`; null when the path has no bytes. `out_gpa` owns the mask.
    pub fn renderAlphaMask(self: *SvgRenderer, out_gpa: Allocator, params: RenderSvgParams, bytes: ?[]const u8) Error!?AlphaMask {
        if (params.size.width <= 0 or params.size.height <= 0) return error.ZeroSize;
        const doc = (try self.document(params.path, bytes)) orelse return null;
        return try doc.renderAlphaMask(out_gpa, params.size);
    }

    /// Multicolor render at exactly `params.size` (width-driven, like the mask),
    /// straight-alpha BGRA for the polychrome atlas under `params.polychromeAtlasKey()`.
    pub fn renderPolychrome(self: *SvgRenderer, out_gpa: Allocator, params: RenderSvgParams, bytes: ?[]const u8, current_color: u32) Error!?Pixmap {
        if (params.size.width <= 0 or params.size.height <= 0) return error.ZeroSize;
        const doc = (try self.document(params.path, bytes)) orelse return null;
        return try doc.renderBgra(out_gpa, .{ .size = params.size }, current_color);
    }

    /// gpui `render_single_frame` (uncached: `bytes` has no path).
    pub fn renderSingleFrame(self: *SvgRenderer, bytes: []const u8, scale_factor: f32) Error!render_image.DecodedImage {
        return rasterizeImage(self.gpa, bytes, scale_factor);
    }

    /// `atlas.getOrInsertWith(params.atlasKey(), renderer.maskBuilder(params, bytes))`
    /// — the body of gpui's `paint_svg` closure. Returns null (nothing to draw)
    /// when the path has no bytes or the SVG is invalid.
    pub fn maskBuilder(self: *SvgRenderer, params: RenderSvgParams, bytes: ?[]const u8) MaskBuilder {
        return .{ .renderer = self, .params = params, .bytes = bytes };
    }

    pub const MaskBuilder = struct {
        renderer: *SvgRenderer,
        params: RenderSvgParams,
        bytes: ?[]const u8,
        scratch: ?AlphaMask = null,

        /// The atlas copies the bytes; call `deinit` after `getOrInsertWith`.
        pub fn build(self: *MaskBuilder) Error!?atlas_mod.BuiltTile {
            const mask = self.renderer.renderAlphaMask(self.renderer.gpa, self.params, self.bytes) catch |err| switch (err) {
                error.InvalidSvg => return null,
                else => return err,
            } orelse return null;
            self.scratch = mask;
            return .{ .size = mask.deviceSize(), .bytes = mask.bytes };
        }

        pub fn deinit(self: *MaskBuilder) void {
            if (self.scratch) |*m| m.deinit(self.renderer.gpa);
            self.scratch = null;
        }
    };
};

/// Case-insensitively replace hex colors in SVG source (zeron's dark-appearance
/// file-icon swaps, `zeron_assets.file_icon_dark_swaps`). Caller owns the result.
pub fn applyColorSwaps(gpa: Allocator, bytes: []const u8, swaps: []const [2][]const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, bytes.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    outer: while (i < bytes.len) {
        if (bytes[i] == '#') {
            for (swaps) |s| {
                const from = s[0];
                if (i + from.len <= bytes.len and std.ascii.eqlIgnoreCase(bytes[i..][0..from.len], from) and
                    (i + from.len == bytes.len or !std.ascii.isHex(bytes[i + from.len])))
                {
                    try out.appendSlice(gpa, s[1]);
                    i += from.len;
                    continue :outer;
                }
            }
        }
        try out.append(gpa, bytes[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "alpha mask of a stroked icon" {
    const gpa = std.testing.allocator;
    const src =
        \\<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
        \\<path d="M4 12H20" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
    ;
    var mask = try rasterizeAlphaMask(gpa, src, .{ .width = 48, .height = 48 });
    defer mask.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 48), mask.width);
    try std.testing.expectEqual(@as(u32, 48), mask.height);
    // Line covers y in [22, 26) at 2x, x in [6, 42) incl. round caps.
    try std.testing.expectEqual(@as(u8, 255), mask.bytes[24 * 48 + 24]);
    try std.testing.expectEqual(@as(u8, 0), mask.bytes[10 * 48 + 24]);
    try std.testing.expectEqual(@as(u8, 0), mask.bytes[24 * 48 + 2]);
    // Anti-aliased round cap: partial coverage near the tip.
    var partial = false;
    for (0..48) |y| {
        const a = mask.bytes[y * 48 + 6];
        if (a > 0 and a < 255) partial = true;
    }
    try std.testing.expect(partial);
}

test "polychrome render is straight-alpha BGRA" {
    const gpa = std.testing.allocator;
    const src =
        \\<svg width="4" height="4" xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4" fill="#3366CC" fill-opacity="0.5"/></svg>
    ;
    var pm = try rasterizeBgra(gpa, src, .{ .scale_factor = 1 }, 0xFF000000);
    defer pm.deinit(gpa);
    const px = pm.bytes[0..4];
    try std.testing.expect(@abs(@as(i32, px[0]) - 0xCC) <= 2);
    try std.testing.expect(@abs(@as(i32, px[1]) - 0x66) <= 2);
    try std.testing.expect(@abs(@as(i32, px[2]) - 0x33) <= 2);
    try std.testing.expect(@abs(@as(i32, px[3]) - 128) <= 1);
}

test "currentColor follows the requested color" {
    const gpa = std.testing.allocator;
    const src =
        \\<svg width="2" height="2" xmlns="http://www.w3.org/2000/svg"><rect width="2" height="2" fill="currentColor"/></svg>
    ;
    var doc = try Document.parse(src);
    defer doc.deinit();
    var a = try doc.renderBgra(gpa, .{ .scale_factor = 1 }, 0xFFFF0000);
    defer a.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, a.bytes[0..4]);
    var b = try doc.renderBgra(gpa, .{ .scale_factor = 1 }, 0xFF00FF00);
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, b.bytes[0..4]);
}

test "renderer caches documents and feeds the atlas" {
    const gpa = std.testing.allocator;
    const Assets = struct {
        fn load(_: ?*anyopaque, path: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, path, "icons/dot.svg"))
                return "<svg width=\"8\" height=\"8\" xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"4\" cy=\"4\" r=\"3\"/></svg>";
            if (std.mem.eql(u8, path, "icons/bad.svg")) return "<svg";
            return null;
        }
    };
    var r = SvgRenderer.init(gpa, .{ .loadFn = Assets.load });
    defer r.deinit();
    var atlas = atlas_mod.Atlas.init(gpa, .{});
    defer atlas.deinit();

    const params: RenderSvgParams = .{ .path = "icons/dot.svg", .size = .{ .width = 16, .height = 16 } };
    var builder = r.maskBuilder(params, null);
    defer builder.deinit();
    const tile = (try atlas.getOrInsertWith(params.atlasKey(), &builder)).?;
    try std.testing.expectEqual(@as(i32, 16), tile.bounds.size.width);
    try std.testing.expectEqual(atlas_mod.AtlasTextureKind.monochrome, tile.texture_id.kind);
    const d1 = (try r.document("icons/dot.svg", null)).?;
    const d2 = (try r.document("icons/dot.svg", null)).?;
    try std.testing.expectEqual(d1, d2);

    try std.testing.expectEqual(@as(?AlphaMask, null), try r.renderAlphaMask(gpa, .{ .path = "missing.svg", .size = .{ .width = 4, .height = 4 } }, null));
    try std.testing.expectError(error.InvalidSvg, r.renderAlphaMask(gpa, .{ .path = "icons/bad.svg", .size = .{ .width = 4, .height = 4 } }, null));
    var bad_builder = r.maskBuilder(.{ .path = "icons/bad.svg", .size = .{ .width = 4, .height = 4 } }, null);
    defer bad_builder.deinit();
    try std.testing.expectEqual(@as(?atlas_mod.AtlasTile, null), try atlas.getOrInsertWith((RenderSvgParams{ .path = "icons/bad.svg", .size = .{ .width = 4, .height = 4 } }).atlasKey(), &bad_builder));
    r.evict("icons/dot.svg");
}

test "pixmap geometry follows gpui (width-driven, clamped)" {
    var doc = try Document.parse("<svg width=\"24\" height=\"12\" xmlns=\"http://www.w3.org/2000/svg\"/>");
    defer doc.deinit();
    const g = doc.pixmapGeometry(.{ .size = .{ .width = 32, .height = 32 } });
    try std.testing.expectEqual(@as(u32, 32), g.width);
    try std.testing.expectEqual(@as(u32, 16), g.height);
    const big = doc.pixmapGeometry(.{ .scale_factor = 1000 });
    try std.testing.expectEqual(@as(u32, 8192), big.width);
}

test "color swaps" {
    const gpa = std.testing.allocator;
    const out = try applyColorSwaps(gpa, "fill=\"#64748b\" stroke=\"#2563EB\" x=\"#64748BAA\"", &.{ .{ "#64748B", "#CBD5E1" }, .{ "#2563EB", "#60A5FA" } });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("fill=\"#CBD5E1\" stroke=\"#60A5FA\" x=\"#64748BAA\"", out);
}
