//! `zig build mermaid-visual -- <ref_png_dir> <out_dir>`: visual parity of
//! zeron's Mermaid diagrams. For each `<stem>.<light|dark>.png` reference
//! (resvg rasters of the Rust pipeline's SVG at zeron's preview size: a 720px
//! column at 2x, see the mermaid notes) it renders `<stem>.mmd` through the
//! Zig port + lunasvg at the same pixel size, composites both on the fence
//! plate and reports the pixel difference. Writes `<stem>.<mode>.zig.png`
//! and a side-by-side `<stem>.<mode>.cmp.png` (reference | zig | diff).

const std = @import("std");
const zpui = @import("zpui");
const media = @import("zeron_media");
const mermaid = @import("zeron_mermaid");

const diagram = media.diagram;
const testdata = "apps/zeron/src/mermaid/testdata";

fn plate(dark: bool) [3]u8 {
    const p = mermaid.zeron.Palette.forDark(dark).plateRgb();
    return .{ @intCast(p >> 16), @intCast((p >> 8) & 0xff), @intCast(p & 0xff) };
}

/// Straight-alpha BGRA (`swap` = RGBA input) over `bg` → RGB.
fn flatten(gpa: std.mem.Allocator, px: []const u8, rgba: bool, bg: [3]u8) ![]u8 {
    const n = px.len / 4;
    const out = try gpa.alloc(u8, n * 3);
    for (0..n) |i| {
        const s = px[i * 4 ..][0..4];
        const rgb = if (rgba) [3]u32{ s[0], s[1], s[2] } else [3]u32{ s[2], s[1], s[0] };
        const a: u32 = s[3];
        inline for (0..3) |k| out[i * 3 + k] = @intCast((rgb[k] * a + @as(u32, bg[k]) * (255 - a) + 127) / 255);
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: mermaid-visual <ref_png_dir> <out_dir>\n", .{});
        return;
    }
    const ref_dir_path = args[1];
    const out_dir_path = args[2];
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir_path) catch {};
    var ref_dir = try cwd.openDir(io, ref_dir_path, .{ .iterate = true });
    defer ref_dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = ref_dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".png") and !std.mem.endsWith(u8, e.name, ".zig.png") and !std.mem.endsWith(u8, e.name, ".cmp.png"))
            try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    var worst: f64 = 0;
    for (names.items) |name| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const base = name[0 .. name.len - 4]; // stem.mode
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse continue;
        const stem = base[0..dot];
        const dark = std.mem.eql(u8, base[dot + 1 ..], "dark");
        const src = cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.mmd", .{ testdata, stem }), a, .limited(1 << 20)) catch continue;
        const ref_bytes = try ref_dir.readFileAlloc(io, name, a, .limited(64 << 20));
        var ref = try zpui.image.decode(a, ref_bytes, .{});
        const rf = ref.frames[0];
        var prep = switch (diagram.prepare(gpa, src, dark)) {
            .ok => |p| p,
            .failed => |f| {
                std.debug.print("{s}: render failed: {s}\n", .{ base, f.message });
                continue;
            },
        };
        defer prep.deinit(gpa);
        const size = diagram.rasterSize(prep.natural, .{ .width = 720, .height = 480 }, 2, diagram.preview_pixels);
        var img = try diagram.rasterize(a, prep.svg, prep.natural, size);
        const zf = img.frames[0];
        _ = &ref;
        _ = &img;
        const bg = plate(dark);
        // zpui decodes PNGs to straight BGRA, like the rasterizer.
        const ref_rgb = try flatten(a, rf.pixels, false, bg);
        const zig_rgb = try flatten(a, zf.pixels, false, bg);
        const same = rf.width == zf.width and rf.height == zf.height;
        var mean: f64 = 0;
        var over: usize = 0;
        const w = @max(rf.width, zf.width);
        const h = @max(rf.height, zf.height);
        // Side-by-side: reference | zig | diff (×4).
        const cw = w * 3 + 8;
        const cmp = try a.alloc(u8, @as(usize, cw) * h * 4);
        @memset(cmp, 255);
        for (0..h) |y| for (0..w) |x| {
            const in_r = x < rf.width and y < rf.height;
            const in_z = x < zf.width and y < zf.height;
            var d: u32 = 0;
            for (0..3) |k| {
                const rv: u32 = if (in_r) ref_rgb[(y * rf.width + x) * 3 + k] else bg[k];
                const zv: u32 = if (in_z) zig_rgb[(y * zf.width + x) * 3 + k] else bg[k];
                const dd = if (rv > zv) rv - zv else zv - rv;
                d = @max(d, dd);
                cmp[(y * cw + x) * 4 + k] = @intCast(rv);
                cmp[(y * cw + w + 4 + x) * 4 + k] = @intCast(zv);
                cmp[(y * cw + 2 * w + 8 + x) * 4 + k] = @intCast(@min(255, d * 4));
            }
            mean += @floatFromInt(d);
            if (d > 48) over += 1;
        };
        const total: f64 = @floatFromInt(@as(usize, w) * h);
        mean /= total;
        const pct_over = @as(f64, @floatFromInt(over)) * 100.0 / total;
        worst = @max(worst, pct_over);
        std.debug.print("{s}: {d}x{d} vs ref {d}x{d} {s} mean|d|={d:.2} pixels>48: {d:.2}%\n", .{ base, zf.width, zf.height, rf.width, rf.height, if (same) "same-size" else "SIZE-DIFF", mean, pct_over });
        const zig_png = try zpui.image.encodePng(a, zf.pixels, zf.width, zf.height, .bgra);
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.zig.png", .{ out_dir_path, base }), .data = zig_png });
        const cmp_png = try zpui.image.encodePng(a, cmp, cw, h, .rgba);
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.cmp.png", .{ out_dir_path, base }), .data = cmp_png });
    }
    std.debug.print("worst share of pixels differing by >48: {d:.2}%\n", .{worst});
}
