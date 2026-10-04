//! `zig build icon-sheet`: rasterizes every zeron icon through zpui's image
//! module and writes zig-out/icon-sheet.png, emulating what the GPU shows.
//!
//! Rows, top to bottom (dark panel, zeron-like):
//!  1. the 117 control icons as tinted alpha masks at 16px @2x: masks are
//!     rendered at 2x the device size (gpui `SMOOTH_SVG_SCALE_FACTOR`) and box
//!     downsampled, which is exactly what bilinear sampling of the half-size
//!     sprite does;
//!  2. the same at 24px @2x;
//!  3. the 355 vscode-symbols file/folder icons as polychrome BGRA at 16px @2x
//!     with zeron's dark-appearance color swaps;
//!  4. decoded samples (examples/assets): PNG (16-bit), JPEG with EXIF
//!     orientation 6 (must read "JPEG UP" upright), WebP, the three GIF
//!     frames, then the PNG object-fit into a square: fill, contain, cover
//!     (tile cropped via `FittedImage.tile`), scale-down, none.
//! A light panel at the bottom repeats rows 1 and 3 on white.

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");
const image = zpui.image;

const output_path = "zig-out/icon-sheet.png";
const icons_dir = "apps/zeron/assets/icons";
const file_icons_dirs = [_][]const u8{ "apps/zeron/assets/file-icons/files", "apps/zeron/assets/file-icons/folders" };
const samples_dir = "examples/assets";

const dark_swaps = [_][2][]const u8{
    .{ "#64748B", "#CBD5E1" }, .{ "#71717A", "#D4D4D8" }, .{ "#2563EB", "#60A5FA" },
    .{ "#EA580C", "#FB923C" }, .{ "#16A34A", "#4ADE80" }, .{ "#8B5CF6", "#A78BFA" },
    .{ "#A855F7", "#C084FC" },
};

const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA8

    fn fill(self: *Canvas, x0: u32, y0: u32, w: u32, h: u32, rgb: [3]u8) void {
        for (y0..@min(y0 + h, self.height)) |y| for (x0..@min(x0 + w, self.width)) |x| {
            const p = self.pixels[(y * self.width + x) * 4 ..][0..4];
            p.* = .{ rgb[0], rgb[1], rgb[2], 255 };
        };
    }

    /// Composite a coverage mask tinted with `rgb`.
    fn mask(self: *Canvas, x0: i64, y0: i64, w: u32, h: u32, cov: []const u8, rgb: [3]u8) void {
        for (0..h) |y| for (0..w) |x| {
            const cx = x0 + @as(i64, @intCast(x));
            const cy = y0 + @as(i64, @intCast(y));
            if (cx < 0 or cy < 0 or cx >= self.width or cy >= self.height) continue;
            const a: u32 = cov[y * w + x];
            const p = self.pixels[(@as(usize, @intCast(cy)) * self.width + @as(usize, @intCast(cx))) * 4 ..][0..4];
            inline for (0..3) |k| p[k] = @intCast((@as(u32, p[k]) * (255 - a) + @as(u32, rgb[k]) * a + 127) / 255);
        };
    }

    /// Composite straight-alpha BGRA.
    fn bgra(self: *Canvas, x0: i64, y0: i64, w: u32, h: u32, src: []const u8) void {
        for (0..h) |y| for (0..w) |x| {
            const cx = x0 + @as(i64, @intCast(x));
            const cy = y0 + @as(i64, @intCast(y));
            if (cx < 0 or cy < 0 or cx >= self.width or cy >= self.height) continue;
            const s = src[(y * w + x) * 4 ..][0..4];
            const a: u32 = s[3];
            const p = self.pixels[(@as(usize, @intCast(cy)) * self.width + @as(usize, @intCast(cx))) * 4 ..][0..4];
            const rgb = [3]u32{ s[2], s[1], s[0] };
            inline for (0..3) |k| p[k] = @intCast((@as(u32, p[k]) * (255 - a) + rgb[k] * a + 127) / 255);
        };
    }

    /// Draw a BGRA sub-rect (`src_rect` in texels) stretched into a dest rect, bilinear — a GPU sprite.
    fn sprite(self: *Canvas, dst: [4]f32, src: []const u8, sw: u32, sh: u32, src_rect: [4]i32) void {
        const x0: i64 = @intFromFloat(@floor(dst[0]));
        const y0: i64 = @intFromFloat(@floor(dst[1]));
        const x1: i64 = @intFromFloat(@ceil(dst[0] + dst[2]));
        const y1: i64 = @intFromFloat(@ceil(dst[1] + dst[3]));
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                if (x < 0 or y < 0 or x >= self.width or y >= self.height) continue;
                const u = (@as(f32, @floatFromInt(x)) + 0.5 - dst[0]) / dst[2];
                const v = (@as(f32, @floatFromInt(y)) + 0.5 - dst[1]) / dst[3];
                if (u < 0 or v < 0 or u >= 1 or v >= 1) continue;
                const tx = @as(f32, @floatFromInt(src_rect[0])) + u * @as(f32, @floatFromInt(src_rect[2])) - 0.5;
                const ty = @as(f32, @floatFromInt(src_rect[1])) + v * @as(f32, @floatFromInt(src_rect[3])) - 0.5;
                var acc: [4]f32 = @splat(0);
                const fx = tx - @floor(tx);
                const fy = ty - @floor(ty);
                inline for (0..2) |j| inline for (0..2) |i| {
                    const sx: i64 = std.math.clamp(@as(i64, @intFromFloat(@floor(tx))) + i, 0, sw - 1);
                    const sy: i64 = std.math.clamp(@as(i64, @intFromFloat(@floor(ty))) + j, 0, sh - 1);
                    const wgt = (if (i == 0) 1 - fx else fx) * (if (j == 0) 1 - fy else fy);
                    const s = src[(@as(usize, @intCast(sy)) * sw + @as(usize, @intCast(sx))) * 4 ..][0..4];
                    const a = @as(f32, @floatFromInt(s[3])) / 255.0;
                    acc[0] += wgt * @as(f32, @floatFromInt(s[2])) * a;
                    acc[1] += wgt * @as(f32, @floatFromInt(s[1])) * a;
                    acc[2] += wgt * @as(f32, @floatFromInt(s[0])) * a;
                    acc[3] += wgt * a;
                };
                const p = self.pixels[(@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4 ..][0..4];
                inline for (0..3) |k| p[k] = @intFromFloat(@min(255, acc[k] + @as(f32, @floatFromInt(p[k])) * (1 - acc[3])));
            }
        }
    }

    fn frame(self: *Canvas, x0: u32, y0: u32, w: u32, h: u32, rgb: [3]u8) void {
        self.fill(x0, y0, w, 1, rgb);
        self.fill(x0, y0 + h - 1, w, 1, rgb);
        self.fill(x0, y0, 1, h, rgb);
        self.fill(x0 + w - 1, y0, 1, h, rgb);
    }
};

/// 2x2 box downsample (what bilinear sampling of a 2x sprite drawn at half size yields).
fn half(gpa: std.mem.Allocator, src: []const u8, w: u32, h: u32, bpp: u32) ![]u8 {
    const ow = w / 2;
    const oh = h / 2;
    const out = try gpa.alloc(u8, ow * oh * bpp);
    for (0..oh) |y| for (0..ow) |x| {
        if (bpp == 1) {
            var s: u32 = 0;
            inline for (0..2) |j| inline for (0..2) |i| {
                s += src[(2 * y + j) * w + 2 * x + i];
            };
            out[y * ow + x] = @intCast((s + 2) / 4);
        } else {
            // Premultiplied average, then unpremultiply.
            var acc: [4]u32 = @splat(0);
            inline for (0..2) |j| inline for (0..2) |i| {
                const p = src[((2 * y + j) * w + 2 * x + i) * 4 ..][0..4];
                inline for (0..3) |k| acc[k] += @as(u32, p[k]) * p[3];
                acc[3] += p[3];
            };
            const o = out[(y * ow + x) * 4 ..][0..4];
            o[3] = @intCast((acc[3] + 2) / 4);
            inline for (0..3) |k| o[k] = if (acc[3] == 0) 0 else @intCast(@min(255, (acc[k] + acc[3] / 2) / acc[3]));
        }
    };
    return out;
}

fn listSvgs(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer names.deinit(gpa);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".svg")) continue;
        try names.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, e.name }));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    try out.appendSlice(gpa, names.items);
}

const Stats = struct { ok: usize = 0, failed: usize = 0 };

/// Draw a grid of tinted monochrome icons; returns the height used.
fn drawMonoRow(gpa: std.mem.Allocator, canvas: *Canvas, renderer: *image.SvgRenderer, paths: []const []u8, sources: []const []u8, y0: u32, logical: f32, scale: f32, tint: [3]u8, stats: *Stats) !u32 {
    const device: u32 = @intFromFloat(logical * scale);
    const cell = device + 12;
    const per_row = (canvas.width - 24) / cell;
    for (paths, sources, 0..) |path, bytes, i| {
        const cx: u32 = 12 + @as(u32, @intCast(i % per_row)) * cell + 6;
        const cy: u32 = y0 + @as(u32, @intCast(i / per_row)) * cell + 6;
        const params = image.RenderSvgParams.forDeviceBounds(path, .{ .width = @floatFromInt(device), .height = @floatFromInt(device) });
        var mask = (renderer.renderAlphaMask(gpa, params, bytes) catch {
            stats.failed += 1;
            canvas.fill(cx, cy, device, device, .{ 200, 40, 40 });
            continue;
        }) orelse continue;
        defer mask.deinit(gpa);
        stats.ok += 1;
        const m = try half(gpa, mask.bytes, mask.width, mask.height, 1);
        defer gpa.free(m);
        // gpui centers the tile in the bounds.
        const ox = @as(i64, cx) + @divFloor(@as(i64, device) - mask.width / 2, 2);
        const oy = @as(i64, cy) + @divFloor(@as(i64, device) - mask.height / 2, 2);
        canvas.mask(ox, oy, mask.width / 2, mask.height / 2, m, tint);
    }
    return @as(u32, @intCast((paths.len + per_row - 1) / per_row)) * cell + 8;
}

fn drawPolyRow(gpa: std.mem.Allocator, canvas: *Canvas, renderer: *image.SvgRenderer, paths: []const []u8, sources: []const []u8, y0: u32, device: u32, stats: *Stats) !u32 {
    const cell = device + 12;
    const per_row = (canvas.width - 24) / cell;
    for (paths, sources, 0..) |path, bytes, i| {
        const cx: u32 = 12 + @as(u32, @intCast(i % per_row)) * cell + 6;
        const cy: u32 = y0 + @as(u32, @intCast(i / per_row)) * cell + 6;
        const params = image.RenderSvgParams.forDeviceBounds(path, .{ .width = @floatFromInt(device), .height = @floatFromInt(device) });
        var pm = (renderer.renderPolychrome(gpa, params, bytes, 0xFFFFFFFF) catch {
            stats.failed += 1;
            canvas.fill(cx, cy, device, device, .{ 200, 40, 40 });
            continue;
        }) orelse continue;
        defer pm.deinit(gpa);
        stats.ok += 1;
        const p = try half(gpa, pm.bytes, pm.width, pm.height, 4);
        defer gpa.free(p);
        const ox = @as(i64, cx) + @divFloor(@as(i64, device) - pm.width / 2, 2);
        const oy = @as(i64, cy) + @divFloor(@as(i64, device) - pm.height / 2, 2);
        canvas.bgra(ox, oy, pm.width / 2, pm.height / 2, p);
    }
    return @as(u32, @intCast((paths.len + per_row - 1) / per_row)) * cell + 8;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var icon_paths: std.ArrayList([]u8) = .empty;
    var file_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (icon_paths.items) |p| gpa.free(p);
        for (file_paths.items) |p| gpa.free(p);
        icon_paths.deinit(gpa);
        file_paths.deinit(gpa);
    }
    try listSvgs(gpa, io, icons_dir, &icon_paths);
    for (file_icons_dirs) |d| try listSvgs(gpa, io, d, &file_paths);

    var all_bytes: std.ArrayList([]u8) = .empty;
    defer {
        for (all_bytes.items) |b| gpa.free(b);
        all_bytes.deinit(gpa);
    }
    var icon_src: std.ArrayList([]u8) = .empty;
    defer icon_src.deinit(gpa);
    for (icon_paths.items) |p| {
        const b = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 20));
        try all_bytes.append(gpa, b);
        try icon_src.append(gpa, b);
    }
    var file_src: std.ArrayList([]u8) = .empty; // light appearance
    defer file_src.deinit(gpa);
    var file_src_dark: std.ArrayList([]u8) = .empty;
    defer file_src_dark.deinit(gpa);
    for (file_paths.items) |p| {
        const b = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 20));
        try all_bytes.append(gpa, b);
        try file_src.append(gpa, b);
        const swapped = try image.svg.applyColorSwaps(gpa, b, &dark_swaps);
        try all_bytes.append(gpa, swapped);
        try file_src_dark.append(gpa, swapped);
    }
    // Dark/light variants share a path; key the dark ones separately.
    var dark_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (dark_paths.items) |p| gpa.free(p);
        dark_paths.deinit(gpa);
    }
    for (file_paths.items) |p| try dark_paths.append(gpa, try std.fmt.allocPrint(gpa, "{s}#dark", .{p}));

    var renderer = image.SvgRenderer.init(gpa, null);
    defer renderer.deinit();

    var canvas: Canvas = .{ .width = 1400, .height = 2400, .pixels = undefined };
    canvas.pixels = try gpa.alloc(u8, canvas.width * canvas.height * 4);
    defer gpa.free(canvas.pixels);
    const dark_bg = [3]u8{ 0x18, 0x18, 0x1b };
    const light_bg = [3]u8{ 0xfa, 0xfa, 0xfa };
    canvas.fill(0, 0, canvas.width, canvas.height, dark_bg);

    var stats: Stats = .{};
    var y: u32 = 8;
    y += try drawMonoRow(gpa, &canvas, &renderer, icon_paths.items, icon_src.items, y, 16, 2, .{ 0xe4, 0xe4, 0xe7 }, &stats);
    y += try drawMonoRow(gpa, &canvas, &renderer, icon_paths.items, icon_src.items, y, 24, 2, .{ 0xa1, 0xa1, 0xaa }, &stats);
    y += try drawPolyRow(gpa, &canvas, &renderer, dark_paths.items, file_src_dark.items, y, 32, &stats);

    // Decoded samples.
    const sample_names = [_][]const u8{ "sample.png", "sample-exif6.jpg", "sample.webp", "sample.gif" };
    var x: u32 = 18;
    var row_h: u32 = 0;
    var png_img: ?image.DecodedImage = null;
    defer if (png_img) |*p| p.deinit(gpa);
    for (sample_names) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ samples_dir, name });
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20));
        defer gpa.free(bytes);
        var job: image.DecodeJob = .{ .gpa = gpa, .bytes = bytes };
        var decoded = job.run() catch |err| {
            std.debug.print("decode {s}: {s}\n", .{ name, @errorName(err) });
            stats.failed += 1;
            continue;
        };
        var keep = false;
        defer if (!keep) decoded.deinit(gpa);
        stats.ok += 1;
        for (decoded.frames) |f| {
            canvas.bgra(x, y + 6, f.width, f.height, f.pixels);
            x += f.width + 12;
            row_h = @max(row_h, f.height);
        }
        if (std.mem.eql(u8, name, "sample.png")) {
            png_img = decoded;
            keep = true;
        }
    }
    // Object-fit demo: the PNG into a 90x90 box, each mode.
    if (png_img) |p| {
        const f = p.frames[0];
        const size: zpui.Size(zpui.DevicePixels) = .{ .width = @intCast(f.width), .height = @intCast(f.height) };
        const tile: zpui.atlas.AtlasTile = .{
            .texture_id = .{ .index = 0, .kind = .polychrome },
            .tile_id = 0,
            .padding = 0,
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = size },
        };
        for ([_]image.ObjectFit{ .fill, .contain, .cover, .scale_down, .none }) |mode| {
            const box: zpui.Bounds(f32) = .{ .origin = .{ .x = @floatFromInt(x), .y = @floatFromInt(y + 6) }, .size = .{ .width = 90, .height = 90 } };
            canvas.frame(x - 1, y + 5, 92, 92, .{ 0x52, 0x52, 0x5b });
            const fitted = image.fitImage(mode, box, size);
            const t = fitted.tile(tile);
            const v = fitted.visible;
            if (!v.isEmpty()) canvas.sprite(.{ v.origin.x, v.origin.y, v.size.width, v.size.height }, f.pixels, f.width, f.height, .{ t.bounds.origin.x, t.bounds.origin.y, t.bounds.size.width, t.bounds.size.height });
            x += 104;
        }
        row_h = @max(row_h, 92);
    }
    y += row_h + 20;

    // Light panel.
    canvas.fill(0, y, canvas.width, canvas.height - y, light_bg);
    y += 8;
    y += try drawMonoRow(gpa, &canvas, &renderer, icon_paths.items, icon_src.items, y, 16, 2, .{ 0x27, 0x27, 0x2a }, &stats);
    y += try drawPolyRow(gpa, &canvas, &renderer, file_paths.items, file_src.items, y, 32, &stats);

    const used_h = @min(canvas.height, y + 8);
    const rgba = canvas.pixels[0 .. canvas.width * used_h * 4];
    const encoded = try png.encode(gpa, canvas.width, used_h, rgba);
    defer gpa.free(encoded);
    std.Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = encoded });
    std.debug.print("icon-sheet: {d} icons + {d} file icons, {d} renders ok, {d} failed -> {s} ({d}x{d})\n", .{ icon_paths.items.len, file_paths.items.len, stats.ok, stats.failed, output_path, canvas.width, used_h });
}
