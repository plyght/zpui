//! Mermaid diagram media (zeron `image_media.rs` for `image/svg+xml`): the
//! SVG from `zeron_mermaid` rasterized by zpui's lunasvg backend with the
//! bundled Geist faces, sized like `MediaImage::for_view`.
//!
//! Everything except `registerFonts` is pure and safe on worker threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const assets = @import("zeron_assets");
const mermaid = @import("zeron_mermaid");

const svg = zpui.image.svg;

/// Pixels of one transcript preview raster (`PREVIEW_PIXELS`).
pub const preview_pixels: usize = 1024 * 1024;
pub const max_raster_side: f64 = 4096.0;

var fonts_registered = std.atomic.Value(bool).init(false);

/// Register Geist / Geist Mono with lunasvg (usvg's fontdb in zeron:
/// bundled faces, `sans-serif` → Geist). Weight 600 selects SemiBold, the
/// only bold weight the engine emits. Idempotent.
pub fn registerFonts() void {
    if (fonts_registered.swap(true, .acq_rel)) return;
    for (std.enums.values(assets.Font)) |f| {
        const i = f.info();
        const bold = i.weight == 600;
        if (i.weight != 400 and !bold) continue;
        const family: [:0]const u8 = if (std.mem.eql(u8, i.family, "Geist")) "Geist" else if (std.mem.eql(u8, i.family, "Geist Mono")) "Geist Mono" else continue;
        _ = svg.addFontFace(family, bold, i.italic, i.data);
    }
}

pub const Size = struct { width: f32, height: f32 };

fn attrNumber(tag: []const u8, name: []const u8) ?f32 {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, " {s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const rest = tag[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return std.fmt.parseFloat(f32, rest[0..end]) catch null;
}

/// The diagram's natural size: the root `width`/`height`, else the viewBox
/// (pie charts declare `width="100%"`).
pub fn naturalSize(doc: []const u8) ?Size {
    const start = std.mem.indexOf(u8, doc, "<svg") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, doc, start, '>') orelse return null;
    const tag = doc[start..end];
    var vb: [4]f32 = .{ 0, 0, 0, 0 };
    if (std.mem.indexOf(u8, tag, " viewBox=\"")) |v| {
        const rest = tag[v + 10 ..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        var it = std.mem.tokenizeAny(u8, rest[0..close], " ,");
        for (&vb) |*x| x.* = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
    }
    const w = attrNumber(tag, "width") orelse vb[2];
    const h = attrNumber(tag, "height") orelse vb[3];
    if (!(w > 0 and h > 0)) return null;
    return .{ .width = w, .height = h };
}

/// `raster_size`: device pixels for a view of `viewport` at `dpi`, bounded
/// by `pixels` and the 4096px side cap.
pub fn rasterSize(natural: Size, viewport: Size, dpi_in: f32, pixels_in: usize) [2]u32 {
    const w: f64 = natural.width;
    const h: f64 = natural.height;
    const dpi: f64 = std.math.clamp(dpi_in, 1.0, 4.0);
    const pixels: usize = @max(pixels_in, 1);
    const fit = @min(@min(@as(f64, @max(viewport.width, 1.0)) / w, @as(f64, @max(viewport.height, 1.0)) / h), 1.0);
    const scale = @min(@min(@min(fit * dpi, max_raster_side / w), max_raster_side / h), @sqrt(@as(f64, @floatFromInt(pixels)) / (w * h)));
    var size: [2]u32 = .{ @intFromFloat(@max(@floor(w * scale), 1.0)), @intFromFloat(@max(@floor(h * scale), 1.0)) };
    if (@as(usize, size[0]) * size[1] > pixels) {
        if (size[0] > size[1]) {
            size[0] = @intCast(@max(pixels / size[1], 1));
        } else {
            size[1] = @intCast(@max(pixels / size[0], 1));
        }
    }
    return size;
}

/// Rasterize `doc` (natural size `natural`) to exactly `size` device pixels:
/// the wrapper `<svg>` of `MediaImage::for_view`, rendered once. The image
/// lays out at its natural size (`scale_factor = size / natural`).
pub fn rasterize(gpa: Allocator, doc: []const u8, natural: Size, size: [2]u32) (svg.Error || Allocator.Error)!zpui.image.DecodedImage {
    registerFonts();
    const body = if (std.mem.startsWith(u8, doc, "<?xml")) doc[(std.mem.indexOf(u8, doc, "?>") orelse 0) + 2 ..] else doc;
    const wrapper = try std.fmt.allocPrint(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">{s}</svg>", .{ size[0], size[1], natural.width, natural.height, body });
    defer gpa.free(wrapper);
    var d = try svg.Document.parse(wrapper);
    defer d.deinit();
    var pm = try d.renderBgra(gpa, .{ .size = .{ .width = @intCast(size[0]), .height = @intCast(size[1]) } }, 0xFF000000);
    errdefer pm.deinit(gpa);
    const frames = try gpa.alloc(zpui.image.Frame, 1);
    frames[0] = .{ .width = pm.width, .height = pm.height, .pixels = pm.bytes };
    return .{ .frames = frames, .scale_factor = @as(f32, @floatFromInt(pm.width)) / natural.width };
}

/// A rendered diagram: the restyled SVG (gpa-owned) and its natural size.
pub const Prepared = struct {
    svg: []u8,
    natural: Size,

    pub fn deinit(self: *Prepared, gpa: Allocator) void {
        gpa.free(self.svg);
    }
};

pub const Outcome = union(enum) {
    ok: Prepared,
    /// Static or gpa-owned message (see `owned`).
    failed: struct { message: []const u8, owned: bool },
};

/// `mermaid::render` + the `decode_image` checks, on a worker thread.
pub fn prepare(gpa: Allocator, source: []const u8, dark: bool) Outcome {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = mermaid.zeron.render(arena.allocator(), source, mermaid.zeron.Palette.forDark(dark)) catch
        return .{ .failed = .{ .message = "Diagram could not be rendered", .owned = false } };
    switch (r) {
        .err => |m| {
            const msg = gpa.dupe(u8, m) catch return .{ .failed = .{ .message = "Diagram could not be rendered", .owned = false } };
            return .{ .failed = .{ .message = msg, .owned = true } };
        },
        .svg => |s| {
            const natural = naturalSize(s) orelse return .{ .failed = .{ .message = "Diagram could not be rendered", .owned = false } };
            const owned = gpa.dupe(u8, s) catch return .{ .failed = .{ .message = "Diagram could not be rendered", .owned = false } };
            return .{ .ok = .{ .svg = owned, .natural = natural } };
        },
    }
}

test "raster size follows image_media" {
    // A 600×300 diagram in a 720px column at 2x: full natural size at 2x,
    // capped by the 1M-pixel preview budget.
    const s = rasterSize(.{ .width = 600, .height = 300 }, .{ .width = 720, .height = 480 }, 2, preview_pixels);
    try std.testing.expectEqual(@as(u32, 1200), s[0]);
    try std.testing.expectEqual(@as(u32, 600), s[1]);
    const big = rasterSize(.{ .width = 2000, .height = 1000 }, .{ .width = 720, .height = 480 }, 2, preview_pixels);
    try std.testing.expect(@as(usize, big[0]) * big[1] <= preview_pixels);
    try std.testing.expectEqual(@as(u32, 1440), big[0]);
}

test "natural size of pie output uses the viewBox" {
    const n = naturalSize("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100%\" viewBox=\"0 0 412.5 300\" style=\"max-width: 412.500px;\">").?;
    try std.testing.expectEqual(@as(f32, 412.5), n.width);
    try std.testing.expectEqual(@as(f32, 300), n.height);
}
