//! New-thread background artwork, pure half (zeron
//! `new_thread_background_image.rs` + the raster side of
//! `new_thread_background_effects.rs`): the one decoding contract, the
//! source-space proxy (`DynamicImage::thumbnail(2048, 2048)`, ported exactly
//! from the image crate's integer box sampler), its Rec. 709 luma plane, and
//! the five effect rasters (None, Dither, ASCII, Halftone, Scanlines) in the
//! BGRA layout `RenderImage` consumes.
//!
//! Everything here is allocation-explicit and thread-safe, so the cache
//! (`cache.zig`) runs it on background workers.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");

const Allocator = std.mem.Allocator;
pub const Effect = model.settings.NewThreadBackgroundEffect;
pub const all_effects = [_]Effect{ .none, .dither, .ascii, .halftone, .scanlines };

/// Longest proxy side (`image.thumbnail(2048, 2048)`).
pub const proxy_side: u32 = 2048;
/// Longest proxy side of a moving background's frames (zpui-only: each
/// frame is proxied and rendered on a worker, so it stays cheap; stills keep
/// Rust's 2048).
pub const motion_proxy_side: u32 = 1024;

/// An RGBA image (straight alpha, row-major).
pub const Rgba = struct {
    width: u32,
    height: u32,
    pixels: [][4]u8,

    pub fn deinit(self: *Rgba, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

pub const DecodeError = error{ OutOfMemory, InvalidImage };

/// `new_thread_background_image::decode`: the exact bytes, format guessed
/// from content (never the extension), first frame, no EXIF rotation.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Rgba {
    var decoded = zpui.image.decode(gpa, bytes, .{
        .max_dimension = 1 << 15,
        .animate = false,
        .max_frames = 1,
        .apply_orientation = false,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidImage;
    defer decoded.deinit(gpa);
    if (decoded.frames.len == 0) return error.InvalidImage;
    const f = decoded.frames[0];
    if (f.width == 0 or f.height == 0) return error.InvalidImage;
    const out = try gpa.alloc([4]u8, @as(usize, f.width) * f.height);
    for (out, 0..) |*p, i| {
        const s = f.pixels[i * 4 ..][0..4];
        p.* = .{ s[2], s[1], s[0], s[3] };
    }
    return .{ .width = f.width, .height = f.height, .pixels = out };
}

/// `math::utils::resize_dimensions(.., fill = false)`.
pub fn fitDimensions(width: u32, height: u32, nwidth: u32, nheight: u32) [2]u32 {
    const wratio = @as(f64, @floatFromInt(nwidth)) / @as(f64, @floatFromInt(width));
    const hratio = @as(f64, @floatFromInt(nheight)) / @as(f64, @floatFromInt(height));
    const ratio = @min(wratio, hratio);
    const nw: u32 = @intFromFloat(@max(@round(@as(f64, @floatFromInt(width)) * ratio), 1));
    const nh: u32 = @intFromFloat(@max(@round(@as(f64, @floatFromInt(height)) * ratio), 1));
    return .{ nw, nh };
}

fn truncU8(x: f32) u8 {
    if (!(x > 0)) return 0;
    if (x >= 255) return 255;
    return @intFromFloat(x);
}

/// `DynamicImage::thumbnail(nw, nh)` (aspect-preserving, upscales too) with
/// the image crate's `imageops::thumbnail` sampler, channel for channel.
pub fn thumbnail(gpa: Allocator, src: Rgba, nw_bound: u32, nh_bound: u32) Allocator.Error!Rgba {
    const dims = fitDimensions(src.width, src.height, nw_bound, nh_bound);
    return thumbnailExact(gpa, src, dims[0], dims[1]);
}

pub fn thumbnailExact(gpa: Allocator, src: Rgba, new_width: u32, new_height: u32) Allocator.Error!Rgba {
    const out = try gpa.alloc([4]u8, @as(usize, new_width) * new_height);
    const width = src.width;
    const height = src.height;
    const x_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(new_width));
    const y_ratio = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(new_height));
    const px = struct {
        fn at(s: Rgba, x: u32, y: u32) [4]u8 {
            return s.pixels[@as(usize, y) * s.width + x];
        }
    }.at;
    for (0..new_height) |oy| {
        const bottomf = @as(f32, @floatFromInt(oy)) * y_ratio;
        const topf = bottomf + y_ratio;
        const bottom = std.math.clamp(@as(u32, @intFromFloat(@ceil(bottomf))), 0, height - 1);
        const top = std.math.clamp(@as(u32, @intFromFloat(@ceil(topf))), bottom, height);
        for (0..new_width) |ox| {
            const leftf = @as(f32, @floatFromInt(ox)) * x_ratio;
            const rightf = leftf + x_ratio;
            const left = std.math.clamp(@as(u32, @intFromFloat(@ceil(leftf))), 0, width - 1);
            const right = std.math.clamp(@as(u32, @intFromFloat(@ceil(rightf))), left, width);
            var avg: [4]u8 = undefined;
            if (bottom != top and left != right) {
                var sum: [4]u64 = .{ 0, 0, 0, 0 };
                var y = bottom;
                while (y < top) : (y += 1) {
                    var x = left;
                    while (x < right) : (x += 1) {
                        const k = px(src, x, y);
                        for (0..4) |c| sum[c] += k[c];
                    }
                }
                const n: u64 = @as(u64, right - left) * (top - bottom);
                const round = n / 2;
                for (0..4) |c| avg[c] = @intCast(@min((sum[c] + round) / n, 255));
            } else if (bottom != top) {
                // left == right: two source columns, `fraction_horizontal`.
                const fract = (fractOf(leftf) + fractOf(rightf)) / 2;
                const l = right - 1;
                var sl: [4]u64 = .{ 0, 0, 0, 0 };
                var sr: [4]u64 = .{ 0, 0, 0, 0 };
                var y = bottom;
                while (y < top) : (y += 1) {
                    const kl = px(src, l, y);
                    const kr = px(src, @min(l + 1, width - 1), y);
                    for (0..4) |c| {
                        sl[c] += kl[c];
                        sr[c] += kr[c];
                    }
                }
                const n: f32 = @floatFromInt(top - bottom);
                for (0..4) |c| avg[c] = truncU8((1 - fract) / n * @as(f32, @floatFromInt(sl[c])) + fract / n * @as(f32, @floatFromInt(sr[c])));
            } else if (left != right) {
                // bottom == top: two source rows, `fraction_vertical`.
                const fract = (fractOf(topf) + fractOf(bottomf)) / 2;
                const b = top - 1;
                var sb: [4]u64 = .{ 0, 0, 0, 0 };
                var st: [4]u64 = .{ 0, 0, 0, 0 };
                var x = left;
                while (x < right) : (x += 1) {
                    const kb = px(src, x, b);
                    const kt = px(src, x, @min(b + 1, height - 1));
                    for (0..4) |c| {
                        sb[c] += kb[c];
                        st[c] += kt[c];
                    }
                }
                const n: f32 = @floatFromInt(right - left);
                for (0..4) |c| avg[c] = truncU8((1 - fract) / n * @as(f32, @floatFromInt(sb[c])) + fract / n * @as(f32, @floatFromInt(st[c])));
            } else {
                // Upscaling: a bilinear mix of four neighbours.
                const frac_v = (fractOf(topf) + fractOf(bottomf)) / 2; // passed as "fraction_vertical"
                const frac_h = (fractOf(leftf) + fractOf(rightf)) / 2;
                const l = right - 1;
                const b = top - 1;
                const l1 = @min(l + 1, width - 1);
                const b1 = @min(b + 1, height - 1);
                const k_bl = px(src, l, b);
                const k_tl = px(src, l, b1);
                const k_br = px(src, l1, b);
                const k_tr = px(src, l1, b1);
                const fact_tr = frac_v * frac_h;
                const fact_tl = frac_v * (1 - frac_h);
                const fact_br = (1 - frac_v) * frac_h;
                const fact_bl = (1 - frac_v) * (1 - frac_h);
                for (0..4) |c| avg[c] = truncU8(fact_br * toF(k_br[c]) + fact_tr * toF(k_tr[c]) + fact_bl * toF(k_bl[c]) + fact_tl * toF(k_tl[c]));
            }
            out[oy * new_width + ox] = avg;
        }
    }
    return .{ .width = new_width, .height = new_height, .pixels = out };
}

fn toF(v: u8) f32 {
    return @floatFromInt(v);
}

fn fractOf(x: f32) f32 {
    return x - @trunc(x);
}

/// `to_luma8`: (2126 R + 7152 G + 722 B) / 10000, truncated.
pub fn luma(p: [4]u8) u8 {
    const l = 2126 * @as(u32, p[0]) + 7152 * @as(u32, p[1]) + 722 * @as(u32, p[2]);
    return @intCast(@min(l / 10000, 255));
}

/// `BackgroundLuminance`: the 2048px source-space proxy and its luma plane.
pub const Proxy = struct {
    width: u32,
    height: u32,
    luma: []u8,
    /// RGBA.
    colors: [][4]u8,

    pub fn deinit(self: *Proxy, gpa: Allocator) void {
        gpa.free(self.luma);
        gpa.free(self.colors);
        self.* = undefined;
    }

    /// `source_from_image`.
    pub fn fromImage(gpa: Allocator, image: Rgba) Allocator.Error!Proxy {
        return fromImageSized(gpa, image, proxy_side);
    }

    /// `fromImage` with another longest side (moving backgrounds' frames).
    pub fn fromImageSized(gpa: Allocator, image: Rgba, side: u32) Allocator.Error!Proxy {
        const thumb = try thumbnail(gpa, image, side, side);
        errdefer gpa.free(thumb.pixels);
        const l = try gpa.alloc(u8, thumb.pixels.len);
        for (l, thumb.pixels) |*o, p| o.* = luma(p);
        return .{ .width = thumb.width, .height = thumb.height, .luma = l, .colors = thumb.pixels };
    }

    /// `PreloadedArtwork::color`: the wallpaper color from ≤ 4096 strided samples.
    pub fn color(self: *const Proxy) ?zt.Color {
        const stride = @max(self.colors.len / 4096, 1);
        var buf: [4097][4]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.colors.len and n < buf.len) : (i += stride) {
            buf[n] = self.colors[i];
            n += 1;
        }
        return zt.wallpaper.extract(buf[0..n]);
    }

    /// The effect raster as BGRA bytes (`render_image`); caller owns.
    pub fn render(self: *const Proxy, gpa: Allocator, effect: Effect, light_in: bool) Allocator.Error![]u8 {
        const light = effectUsesLight(effect, light_in);
        const out = try gpa.alloc(u8, self.colors.len * 4);
        switch (effect) {
            .none => for (self.colors, 0..) |c, i| put(out, i, .{ c[2], c[1], c[0], c[3] }),
            .dither => self.dither(out),
            .halftone => self.halftone(out, light),
            .ascii => self.ascii(out, light),
            .scanlines => self.scanlines(out, light),
        }
        return out;
    }

    fn scanlines(self: *const Proxy, out: []u8, light: bool) void {
        for (0..self.height) |y| {
            const gain: f32 = if (y % 3 == 0) 0.52 else 1.0;
            for (0..self.width) |x| {
                const i = y * self.width + x;
                const c = self.colors[i];
                const ch = struct {
                    fn f(v: u8, g: f32, l: bool) u8 {
                        const vf: f32 = @floatFromInt(v);
                        return if (l) truncU8(vf + (255.0 - vf) * (1.0 - g)) else truncU8(vf * g);
                    }
                }.f;
                put(out, i, .{ ch(c[2], gain, light), ch(c[1], gain, light), ch(c[0], gain, light), c[3] });
            }
        }
    }

    const glyphs = [10][7]u8{
        .{ 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 4, 0 },
        .{ 0, 4, 0, 0, 4, 0, 0 },
        .{ 0, 0, 0, 14, 0, 0, 0 },
        .{ 0, 0, 14, 0, 14, 0, 0 },
        .{ 0, 4, 4, 31, 4, 4, 0 },
        .{ 0, 21, 14, 31, 14, 21, 0 },
        .{ 10, 10, 31, 10, 31, 10, 10 },
        .{ 17, 2, 4, 4, 8, 16, 17 },
        .{ 14, 17, 23, 21, 23, 16, 14 },
    };

    fn ascii(self: *const Proxy, out: []u8, light: bool) void {
        const w = self.width;
        const h = self.height;
        for (0..h) |yy| {
            const y: u32 = @intCast(yy);
            for (0..w) |xx| {
                const x: u32 = @intCast(xx);
                const sx = @min(x / 6 * 6 + 3, w - 1);
                const sy = @min(y / 8 * 8 + 4, h - 1);
                const sample = @as(usize, sy) * w + sx;
                const ink_density: u8 = if (light) 255 - self.luma[sample] else self.luma[sample];
                const index: usize = @intFromFloat(@sqrt(@as(f32, @floatFromInt(ink_density)) / 255.0) * 9.0);
                const row = y % 8;
                const ink = x % 6 < 5 and row < 7 and glyphs[index][row] & (@as(u8, 1) << @intCast(4 - x % 6)) != 0;
                const i = @as(usize, y) * w + x;
                const c = self.colors[i];
                const g = self.colors[sample];
                const paper: f32 = if (light) 255 else 0;
                const mix = struct {
                    fn f(base: u8, glyph: u8, inked: bool, p: f32) u8 {
                        return truncU8(@as(f32, @floatFromInt(base)) * 0.60 + (if (inked) @as(f32, @floatFromInt(glyph)) * 0.40 else p * 0.40));
                    }
                }.f;
                put(out, i, .{ mix(c[2], g[2], ink, paper), mix(c[1], g[1], ink, paper), mix(c[0], g[0], ink, paper), c[3] });
            }
        }
    }

    fn coverIndex(self: *const Proxy, bw: f32, bh: f32, x: f32, y: f32) usize {
        const width = @max(bw, 1);
        const height = @max(bh, 1);
        const sw: f32 = @floatFromInt(self.width);
        const sh: f32 = @floatFromInt(self.height);
        const scale = @max(width / sw, height / sh);
        const vw = width / scale;
        const vh = height / scale;
        const sx: u32 = @intFromFloat(std.math.clamp((sw - vw) * 0.5 + x / scale, 0, sw - 1));
        const sy: u32 = @intFromFloat(std.math.clamp((sh - vh) * 0.5 + y / scale, 0, sh - 1));
        return @as(usize, sy) * self.width + sx;
    }

    fn halftone(self: *const Proxy, out: []u8, light: bool) void {
        const w = self.width;
        const h = self.height;
        const bw: f32 = @floatFromInt(w);
        const bh: f32 = @floatFromInt(h);
        const paper: u8 = if (light) 255 else 0;
        var i: usize = 0;
        while (i < self.colors.len) : (i += 1) put(out, i, .{ paper, paper, paper, 255 });
        var y: u32 = 0;
        while (y < h) : (y += 4) {
            var x: u32 = 0;
            while (x < w) : (x += 4) {
                const l0 = self.luma[self.coverIndex(bw, bh, @floatFromInt(x), @floatFromInt(y))];
                const l: u8 = if (light) 255 - l0 else l0;
                const radius = 2.0 * (0.3 + 0.7 * @sqrt(@as(f32, @floatFromInt(l)) / 255.0));
                const dot = self.colors[self.coverIndex(bw, bh, @as(f32, @floatFromInt(x)) + 2.0, @as(f32, @floatFromInt(y)) + 2.0)];
                for (0..@min(4, h - y)) |dy| {
                    for (0..@min(4, w - x)) |dx| {
                        const fx = @as(f32, @floatFromInt(dx)) - 1.5;
                        const fy = @as(f32, @floatFromInt(dy)) - 1.5;
                        const distance = @sqrt(fx * fx + fy * fy);
                        const coverage = std.math.clamp(radius + 0.5 - distance, 0, 1) * @as(f32, @floatFromInt(dot[3])) / 255.0;
                        const idx = (@as(usize, y) + dy) * w + x + dx;
                        const s = self.colors[idx];
                        const blend = struct {
                            fn f(source: u8, d: u8, cov: f32, p: u8) u8 {
                                return truncU8(@as(f32, @floatFromInt(source)) * 0.60 + (@as(f32, @floatFromInt(d)) * cov + @as(f32, @floatFromInt(p)) * (1.0 - cov)) * 0.40);
                            }
                        }.f;
                        put(out, idx, .{ blend(s[2], dot[2], coverage, paper), blend(s[1], dot[1], coverage, paper), blend(s[0], dot[0], coverage, paper), s[3] });
                    }
                }
            }
        }
    }

    const bayer = [4][4]u8{ .{ 0, 8, 2, 10 }, .{ 12, 4, 14, 6 }, .{ 3, 11, 1, 9 }, .{ 15, 7, 13, 5 } };

    fn dither(self: *const Proxy, out: []u8) void {
        const w = self.width;
        const h = self.height;
        const bw: f32 = @floatFromInt(w);
        const bh: f32 = @floatFromInt(h);
        var y: u32 = 0;
        while (y < h) : (y += 2) {
            var x: u32 = 0;
            while (x < w) : (x += 2) {
                const index = self.coverIndex(bw, bh, @floatFromInt(x + 1), @floatFromInt(y + 1));
                const c = ditherColor(self.colors[index], bayer[y / 2 % 4][x / 2 % 4]);
                for (0..@min(2, h - y)) |dy| {
                    for (0..@min(2, w - x)) |dx| put(out, (@as(usize, y) + dy) * w + x + dx, .{ c[2], c[1], c[0], c[3] });
                }
            }
        }
    }
};

fn ditherColor(c: [4]u8, threshold: u8) [4]u8 {
    const peak: f32 = @floatFromInt(@max(c[0], c[1], c[2]));
    const bright = peak / 255.0 > (@as(f32, @floatFromInt(threshold)) + 0.5) / 16.0;
    const gain: f32 = if (bright) 255.0 / @max(peak, 1.0) else 0.08;
    const r = struct {
        fn f(v: u8, g: f32) u8 {
            return truncU8(@round(@as(f32, @floatFromInt(v)) * g));
        }
    }.f;
    return .{ r(c[0], gain), r(c[1], gain), r(c[2], gain), c[3] };
}

inline fn put(out: []u8, i: usize, bgra: [4]u8) void {
    out[i * 4 ..][0..4].* = bgra;
}

/// Dither and None ignore the appearance (`(effect, light && !matches!(..))`).
pub fn effectUsesLight(effect: Effect, light: bool) bool {
    return light and effect != .dither and effect != .none;
}

/// The wallpaper color of a decoded image (`thumbnail(64, 64)` + extract).
pub fn colorOf(gpa: Allocator, image: Rgba) ?zt.Color {
    var thumb = thumbnail(gpa, image, 64, 64) catch return null;
    defer thumb.deinit(gpa);
    return zt.wallpaper.extract(thumb.pixels);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn solid(gpa: Allocator, w: u32, h: u32, c: [4]u8) !Rgba {
    const p = try gpa.alloc([4]u8, @as(usize, w) * h);
    @memset(p, c);
    return .{ .width = w, .height = h, .pixels = p };
}

test "thumbnail fits within the bound, upscaling small images like the image crate" {
    try testing.expectEqual([2]u32{ 2048, 1024 }, fitDimensions(400, 200, 2048, 2048));
    try testing.expectEqual([2]u32{ 1024, 2048 }, fitDimensions(3000, 6000, 2048, 2048));
    try testing.expectEqual([2]u32{ 64, 1 }, fitDimensions(10000, 10, 64, 64));
    const gpa = testing.allocator;
    var img = try solid(gpa, 8, 4, .{ 10, 20, 30, 255 });
    defer img.deinit(gpa);
    var down = try thumbnail(gpa, img, 4, 4);
    defer down.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), down.width);
    try testing.expectEqual(@as(u32, 2), down.height);
    for (down.pixels) |p| try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, p);
    var up = try thumbnail(gpa, img, 16, 16);
    defer up.deinit(gpa);
    try testing.expectEqual(@as(u32, 16), up.width);
    for (up.pixels) |p| try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, p);
}

test "box sampling averages with rounding" {
    const gpa = testing.allocator;
    const px = try gpa.alloc([4]u8, 2);
    px[0] = .{ 0, 0, 0, 255 };
    px[1] = .{ 255, 101, 1, 255 };
    var img: Rgba = .{ .width = 2, .height = 1, .pixels = px };
    defer img.deinit(gpa);
    var t = try thumbnailExact(gpa, img, 1, 1);
    defer t.deinit(gpa);
    try testing.expectEqual([4]u8{ 128, 51, 1, 255 }, t.pixels[0]);
}

test "luma uses the image crate's sRGB weights" {
    try testing.expectEqual(@as(u8, 255), luma(.{ 255, 255, 255, 255 }));
    try testing.expectEqual(@as(u8, 54), luma(.{ 255, 0, 0, 255 }));
    try testing.expectEqual(@as(u8, 182), luma(.{ 0, 255, 0, 255 }));
}

test "effects: none swaps to BGRA, scanlines darken every third row, light mode lightens" {
    const gpa = testing.allocator;
    var img = try solid(gpa, 6, 6, .{ 200, 100, 50, 255 });
    defer img.deinit(gpa);
    var proxy = try Proxy.fromImage(gpa, img);
    defer proxy.deinit(gpa);
    try testing.expectEqual(@as(u32, 2048), proxy.width);
    const none = try proxy.render(gpa, .none, true);
    defer gpa.free(none);
    try testing.expectEqualSlices(u8, &.{ 50, 100, 200, 255 }, none[0..4]);
    const dark = try proxy.render(gpa, .scanlines, false);
    defer gpa.free(dark);
    try testing.expectEqualSlices(u8, &.{ 26, 52, 104, 255 }, dark[0..4]);
    const row1 = @as(usize, proxy.width) * 4;
    try testing.expectEqualSlices(u8, &.{ 50, 100, 200, 255 }, dark[row1..][0..4]);
    const light = try proxy.render(gpa, .scanlines, true);
    defer gpa.free(light);
    try testing.expect(light[0] > 50 and light[2] > 200);
}

test "dither quantizes to bright or near-black per Bayer cell; ascii and halftone keep a colored base" {
    const gpa = testing.allocator;
    try testing.expectEqual([4]u8{ 255, 128, 0, 9 }, ditherColor(.{ 200, 100, 0, 9 }, 0));
    try testing.expectEqual([4]u8{ 16, 8, 0, 9 }, ditherColor(.{ 200, 100, 0, 9 }, 15));
    var img = try solid(gpa, 32, 32, .{ 240, 240, 240, 255 });
    defer img.deinit(gpa);
    var proxy = try Proxy.fromImage(gpa, img);
    defer proxy.deinit(gpa);
    for ([_]Effect{ .ascii, .halftone, .dither }) |e| {
        const out = try proxy.render(gpa, e, false);
        defer gpa.free(out);
        try testing.expectEqual(proxy.colors.len * 4, out.len);
        try testing.expect(out[3] == 255);
    }
    try testing.expect(effectUsesLight(.ascii, true) and !effectUsesLight(.dither, true) and !effectUsesLight(.none, true));
}

test "proxy color favours the chromatic region" {
    const gpa = testing.allocator;
    var img = try solid(gpa, 8, 8, .{ 20, 60, 200, 255 });
    defer img.deinit(gpa);
    const c = colorOf(gpa, img).?;
    try testing.expect(c.b > c.r);
    var proxy = try Proxy.fromImage(gpa, img);
    defer proxy.deinit(gpa);
    try testing.expect(proxy.color().?.eql(c));
}
