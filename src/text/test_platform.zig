//! Deterministic fake `platform.TextSystem` for unit tests: one glyph per code point,
//! 10px advance for narrow characters and 20px for wide ones (CJK, emoji) at 16px,
//! scaled linearly with font size. Fonts named "Missing" fail to resolve.

const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const fallback = @import("fallback.zig");

const Self = @This();

families: std.ArrayList([]const u8) = .empty,
gpa: std.mem.Allocator,
layout_calls: usize = 0,

pub const units_per_em: u32 = 1600;

pub fn init(gpa: std.mem.Allocator) Self {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Self) void {
    for (self.families.items) |f| self.gpa.free(f);
    self.families.deinit(self.gpa);
}

pub fn textSystem(self: *Self) platform.TextSystem {
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn isWide(cp: u21) bool {
    return cp >= 0x1100 and (cp <= 0x115F or (cp >= 0x2E80 and cp <= 0xA4CF) or (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFF60) or cp >= 0x1F300);
}

/// "Lilex" mimics gpui's test font (.ZedMono, 600/1000 em → 9.6px at 16px); others use 10px.
fn advanceUnits(self: *const Self, font_id: types.FontId, cp: u21) f32 {
    const ix = @intFromEnum(font_id);
    const lilex = ix < self.families.items.len and std.mem.eql(u8, self.families.items[ix], "Lilex");
    const base: f32 = if (lilex) 960 else 1000;
    return if (isWide(cp)) base * 2 else base;
}

const vtable: platform.TextSystem.VTable = .{
    .addFont = addFont,
    .fontId = fontId,
    .fontMetrics = fontMetrics,
    .glyphForChar = glyphForChar,
    .advance = advance,
    .glyphRasterBounds = glyphRasterBounds,
    .rasterizeGlyph = rasterizeGlyph,
    .layoutLine = layoutLine,
    .raster_transforms = true,
};

fn cast(ptr: *anyopaque) *Self {
    return @ptrCast(@alignCast(ptr));
}

fn addFont(_: *anyopaque, _: []const u8) anyerror!void {}

fn fontId(ptr: *anyopaque, font: types.Font) anyerror!types.FontId {
    const self = cast(ptr);
    if (std.mem.eql(u8, font.family, "Missing")) return error.FontNotFound;
    for (self.families.items, 0..) |f, i| if (std.mem.eql(u8, f, font.family)) return @enumFromInt(i);
    try self.families.append(self.gpa, try self.gpa.dupe(u8, font.family));
    return @enumFromInt(self.families.items.len - 1);
}

fn fontMetrics(_: *anyopaque, _: types.FontId) types.FontMetrics {
    return .{
        .units_per_em = units_per_em,
        .ascent = 1200,
        .descent = 400,
        .line_gap = 0,
        .underline_position = -100,
        .underline_thickness = 50,
        .cap_height = 1100,
        .x_height = 800,
        .bounding_box = .{ .origin = .zero, .size = .{ .width = 1000, .height = 1600 } },
    };
}

fn glyphForChar(_: *anyopaque, _: types.FontId, ch: u21) ?types.GlyphId {
    return ch;
}

fn advance(ptr: *anyopaque, id: types.FontId, glyph: types.GlyphId) geometry.Size(f32) {
    return .{ .width = cast(ptr).advanceUnits(id, @intCast(glyph)), .height = 0 };
}

/// Every glyph is an 8x10 device-px box on the baseline; a raster transform maps the box.
fn glyphRasterBounds(_: *anyopaque, p: types.RenderGlyphParams) anyerror!geometry.Bounds(geometry.DevicePixels) {
    if (p.glyph_id == ' ') return .{ .origin = .zero, .size = .zero };
    if (p.is_emoji or p.raster_transform.isIdentity()) return .{ .origin = .{ .x = 0, .y = -10 }, .size = .{ .width = 8, .height = 10 } };
    const r = p.raster_transform.mapRect(0, -10, 8, 0);
    const x0: i32 = @intFromFloat(@floor(r[0]));
    const y0: i32 = @intFromFloat(@floor(r[1]));
    return .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = @as(i32, @intFromFloat(@ceil(r[2]))) - x0, .height = @as(i32, @intFromFloat(@ceil(r[3]))) - y0 } };
}

fn rasterizeGlyph(_: *anyopaque, gpa: std.mem.Allocator, p: types.RenderGlyphParams, b: geometry.Bounds(geometry.DevicePixels)) anyerror![]u8 {
    const bpp: usize = if (p.is_emoji or p.subpixel_rendering) 4 else 1;
    const out = try gpa.alloc(u8, @as(usize, @intCast(b.size.width * b.size.height)) * bpp);
    @memset(out, 0xFF);
    return out;
}

fn layoutLine(ptr: *anyopaque, arena: std.mem.Allocator, str: []const u8, font_size: types.Pixels, runs: []const types.FontRun) anyerror!types.LineLayout {
    const self = cast(ptr);
    self.layout_calls += 1;
    const scale = font_size / @as(f32, units_per_em);
    var out_runs: std.ArrayList(types.ShapedRun) = .empty;
    var x: f32 = 0;
    var offset: usize = 0;
    for (runs) |run| {
        var glyphs: std.ArrayList(types.ShapedGlyph) = .empty;
        var i = offset;
        const end = @min(offset + run.len, str.len);
        while (i < end) {
            const d = fallback.decodeAt(str, i);
            try glyphs.append(arena, .{
                .id = d.cp,
                .position = .{ .x = x, .y = 0 },
                .index = i,
                .is_emoji = d.cp >= 0x1F300,
            });
            x += self.advanceUnits(run.font_id, d.cp) * scale;
            i += d.len;
        }
        offset = end;
        if (glyphs.items.len > 0) try out_runs.append(arena, .{ .font_id = run.font_id, .glyphs = glyphs.items });
    }
    return .{
        .font_size = font_size,
        .width = x,
        .ascent = 1200 * scale,
        .descent = 400 * scale,
        .runs = out_runs.items,
        .len = str.len,
    };
}
