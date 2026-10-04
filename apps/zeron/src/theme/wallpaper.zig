//! Wallpaper-derived accents and subtle surface tints (port of zeron
//! `crates/ui/src/settings/wallpaper_colors.rs`). User theme choices stay intact.

const std = @import("std");
const model = @import("model.zig");

const Color = model.Color;

/// Quantized dominant color of RGBA pixels, favouring chromatic regions;
/// pixels with alpha < 128 are ignored. Sampling is bounded by the caller.
pub fn extract(pixels: []const [4]u8) ?Color {
    const Bin = struct { f64, [3]f64 };
    var bins: [4096]Bin = @splat(.{ 0, .{ 0, 0, 0 } });
    for (pixels) |px| {
        const r, const g, const b, const a = px;
        if (a < 128) continue;
        const high: f64 = @floatFromInt(@max(r, g, b));
        const low: f64 = @floatFromInt(@min(r, g, b));
        const saturation = (high - low) / @max(high, 1.0);
        const weight = (0.2 + saturation * saturation) * @as(f64, @floatFromInt(a)) / 255.0;
        const index = (@as(usize, r >> 4) << 8) | (@as(usize, g >> 4) << 4) | @as(usize, b >> 4);
        bins[index][0] += weight;
        for (&bins[index][1], [3]u8{ r, g, b }) |*sum, ch| sum.* += @as(f64, @floatFromInt(ch)) * weight;
    }
    // Rust's `max_by` keeps the last maximum.
    var best: usize = 0;
    for (bins, 0..) |bin, i| {
        if (bin[0] >= bins[best][0]) best = i;
    }
    const count, const ch = bins[best];
    if (!(count > 0)) return null;
    return .rgb(round(ch[0] / count), round(ch[1] / count), round(ch[2] / count));
}

fn round(x: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(x), 0, 255));
}

/// Tint every surface 40% toward the wallpaper color and re-derive the
/// interactive roles from it. Text is hardened afterwards by `Theme.fromVariant`.
pub fn tintVariant(variant: *model.ThemeVariant, color: Color) void {
    const dark = variant.appearance.isDark();
    const tint = color.mix(if (dark) Color.black else Color.white, if (dark) 0.88 else 0.94);
    const colors = &variant.colors;
    for ([_]*Color{ &colors.background, &colors.shell, &colors.raised, &colors.card, &colors.dialog, &colors.overlay, &colors.input }) |surface| {
        surface.* = surface.mix(tint, 0.4);
    }
    variant.accent = .derive(color, variant.appearance, colors.background);
    colors.hover = variant.accent.primary.withAlpha(0.09);
    colors.active = variant.accent.primary.withAlpha(0.15);
    colors.border = variant.accent.primary.withAlpha(0.14);
    colors.border_strong = variant.accent.primary.withAlpha(0.3);
    variant.terminal.background = variant.terminal.background.mix(tint, 0.4);
    variant.terminal.selection = variant.accent.selection;
}

const testing = std.testing;

test "extraction ignores transparency and favours prominent colour" {
    var pixels: [120][4]u8 = undefined;
    for (pixels[0..80]) |*p| p.* = .{ 240, 240, 240, 255 };
    for (pixels[80..110]) |*p| p.* = .{ 20, 120, 220, 255 };
    for (pixels[110..]) |*p| p.* = .{ 255, 0, 0, 0 };
    const c = extract(&pixels).?;
    try testing.expect(c.b > c.r and c.b > c.g);
    try testing.expect(extract(&.{.{ 1, 2, 3, 0 }}) == null);
}

test "overlays preserve semantic colours" {
    const registry = @import("registry.zig");
    var v = registry.builtin.variant("zeron-dark").?.*;
    const before = v.colors;
    tintVariant(&v, .rgb(20, 60, 140));
    try testing.expect(v.colors.danger.eql(before.danger));
    try testing.expect(!v.colors.background.eql(before.background));
    try testing.expect(v.accent.primary.contrast(v.colors.background) >= 3.0);
}
