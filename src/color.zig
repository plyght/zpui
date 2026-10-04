//! Colors and backgrounds, ported from gpui's `color.rs` (zui fork).
//!
//! `Hsla` is the canonical color type: every GPU primitive carries colors as
//! HSLA and the shaders convert to RGBA (see docs/shaders-notes.md).
//! `Rgba` is the convenient authoring/interchange type.

const std = @import("std");

/// Convert an RGB hex color code number (0xRRGGBB) to `Rgba` with alpha 1.
pub fn rgb(value: u32) Rgba {
    return .{
        .r = byteToUnit(@truncate(value >> 16)),
        .g = byteToUnit(@truncate(value >> 8)),
        .b = byteToUnit(@truncate(value)),
        .a = 1.0,
    };
}

/// Convert an RGBA hex color code number (0xRRGGBBAA) to `Rgba`.
pub fn rgba(value: u32) Rgba {
    return .{
        .r = byteToUnit(@truncate(value >> 24)),
        .g = byteToUnit(@truncate(value >> 16)),
        .b = byteToUnit(@truncate(value >> 8)),
        .a = byteToUnit(@truncate(value)),
    };
}

/// Construct an `Hsla`, clamping every component to [0, 1].
pub fn hsla(h: f32, s: f32, l: f32, a: f32) Hsla {
    return .{ .h = clamp01(h), .s = clamp01(s), .l = clamp01(l), .a = clamp01(a) };
}

/// Parse a CSS-style hex color at compile time: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`.
/// Invalid input is a compile error.
pub fn hex(comptime s: []const u8) Rgba {
    return comptime Rgba.parse(s) catch |err| @compileError("invalid hex color '" ++ s ++ "': " ++ @errorName(err));
}

/// Swap an RGBA pixel with premultiplied alpha to straight-alpha BGRA, in place.
pub fn swapRgbaPaToBgra(color: []u8) void {
    std.mem.swap(u8, &color[0], &color[2]);
    if (color[3] > 0) {
        const a: f32 = @as(f32, @floatFromInt(color[3])) / 255.0;
        for (color[0..3]) |*c| {
            c.* = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(c.*)) / a));
        }
    }
}

fn byteToUnit(b: u8) f32 {
    return @as(f32, @floatFromInt(b)) / 255.0;
}

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0.0, 1.0);
}

/// Saturating float -> u8 conversion matching Rust's `as u8` (truncates, NaN -> 0).
fn unitToByteTrunc(v: f32) u32 {
    if (!(v > 0)) return 0;
    return @intFromFloat(@min(255.0, @trunc(v * 255.0)));
}

/// An sRGB color with straight (non-premultiplied) alpha. Components are in [0, 1].
pub const Rgba = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const ParseError = error{ MissingHash, InvalidLength, InvalidDigit };

    /// Parse `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` (surrounding whitespace allowed).
    /// Usable at comptime and runtime.
    pub fn parse(input: []const u8) ParseError!Rgba {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '#') return error.MissingHash;
        const digits = trimmed[1..];
        var bytes: [4]u8 = .{ 0, 0, 0, 0xff };
        switch (digits.len) {
            3, 4 => for (digits, 0..) |c, i| {
                const v = try hexDigit(c);
                bytes[i] = (v << 4) | v;
            },
            6, 8 => for (0..digits.len / 2) |i| {
                bytes[i] = (try hexDigit(digits[2 * i]) << 4) | try hexDigit(digits[2 * i + 1]);
            },
            else => return error.InvalidLength,
        }
        return .{
            .r = byteToUnit(bytes[0]),
            .g = byteToUnit(bytes[1]),
            .b = byteToUnit(bytes[2]),
            .a = byteToUnit(bytes[3]),
        };
    }

    fn hexDigit(c: u8) ParseError!u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidDigit,
        };
    }

    /// Pack as 0xRRGGBBAA (components truncated, like gpui's `From<Rgba> for u32`).
    pub fn toU32(self: Rgba) u32 {
        return (unitToByteTrunc(self.r) << 24) | (unitToByteTrunc(self.g) << 16) |
            (unitToByteTrunc(self.b) << 8) | unitToByteTrunc(self.a);
    }

    /// Format as `#rrggbbaa` with rounded components (gpui's serde format).
    pub fn toHexString(self: Rgba) [9]u8 {
        var out: [9]u8 = undefined;
        out[0] = '#';
        const chars = "0123456789abcdef";
        for ([_]f32{ self.r, self.g, self.b, self.a }, 0..) |c, i| {
            const v: u8 = @intFromFloat(@round(clamp01(c) * 255.0));
            out[1 + 2 * i] = chars[v >> 4];
            out[2 + 2 * i] = chars[v & 0xf];
        }
        return out;
    }

    /// Composite `other` over `self` by `other.a`, keeping `self.a`.
    pub fn blend(self: Rgba, other: Rgba) Rgba {
        if (other.a >= 1.0) return other;
        if (other.a <= 0.0) return self;
        const k = 1.0 - other.a;
        return .{
            .r = self.r * k + other.r * other.a,
            .g = self.g * k + other.g * other.a,
            .b = self.b * k + other.b * other.a,
            .a = self.a,
        };
    }

    /// Same color with alpha replaced (clamped to [0, 1]).
    pub fn alpha(self: Rgba, a: f32) Rgba {
        var c = self;
        c.a = clamp01(a);
        return c;
    }

    /// Same color with alpha multiplied by `factor` (clamped to [0, 1]).
    pub fn opacity(self: Rgba, factor: f32) Rgba {
        var c = self;
        c.a = self.a * clamp01(factor);
        return c;
    }

    pub fn toHsla(self: Rgba) Hsla {
        const r = self.r;
        const g = self.g;
        const b = self.b;
        const max = @max(r, @max(g, b));
        const min = @min(r, @min(g, b));
        const delta = max - min;

        const l = (max + min) / 2.0;
        const s: f32 = if (l == 0.0 or l == 1.0)
            0.0
        else if (l < 0.5)
            delta / (2.0 * l)
        else
            delta / (2.0 - 2.0 * l);

        const h: f32 = if (delta == 0.0)
            0.0
        else if (max == r)
            // `@mod` on floats is floored, matching Rust's `rem_euclid` for a positive divisor.
            @mod((g - b) / delta, 6.0) / 6.0
        else if (max == g)
            ((b - r) / delta + 2.0) / 6.0
        else
            ((r - g) / delta + 4.0) / 6.0;

        return .{ .h = h, .s = s, .l = l, .a = self.a };
    }

    pub fn eql(a: Rgba, b: Rgba) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

/// An HSLA color — gpui's canonical color type. All components are in [0, 1]
/// (hue is a fraction of a full turn).
pub const Hsla = extern struct {
    h: f32 = 0,
    s: f32 = 0,
    l: f32 = 0,
    a: f32 = 0,

    pub fn toRgba(self: Hsla) Rgba {
        const h = self.h;
        const s = self.s;
        const l = self.l;

        const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
        // Rust `%` is a truncated remainder.
        const x = c * (1.0 - @abs(@rem(h * 6.0, 2.0) - 1.0));
        const m = l - c / 2.0;
        const cm = c + m;
        const xm = x + m;

        const sector: i32 = @intFromFloat(std.math.clamp(@floor(h * 6.0), -1.0, 7.0));
        const r: f32, const g: f32, const b: f32 = switch (sector) {
            0, 6 => .{ cm, xm, m },
            1 => .{ xm, cm, m },
            2 => .{ m, cm, xm },
            3 => .{ m, xm, cm },
            4 => .{ xm, m, cm },
            else => .{ cm, m, xm },
        };
        return .{ .r = clamp01(r), .g = clamp01(g), .b = clamp01(b), .a = self.a };
    }

    pub fn isTransparent(self: Hsla) bool {
        return self.a == 0.0;
    }

    pub fn isOpaque(self: Hsla) bool {
        return self.a == 1.0;
    }

    /// Blend `other` on top of `self` (through RGB) based on `other.a`.
    /// Returns `other` if it is opaque and `self` if it is fully transparent.
    pub fn blend(self: Hsla, other: Hsla) Hsla {
        if (other.a >= 1.0) return other;
        if (other.a <= 0.0) return self;
        return self.toRgba().blend(other.toRgba()).toHsla();
    }

    /// Same hue and lightness with zero saturation.
    pub fn grayscale(self: Hsla) Hsla {
        return .{ .h = self.h, .s = 0, .l = self.l, .a = self.a };
    }

    /// Fade out in place: 0.0 leaves the color unchanged, 1.0 makes it fully transparent.
    pub fn fadeOut(self: *Hsla, factor: f32) void {
        self.a *= 1.0 - clamp01(factor);
    }

    /// Same color with alpha multiplied by `factor` (clamped to [0, 1]).
    pub fn opacity(self: Hsla, factor: f32) Hsla {
        var c = self;
        c.a = self.a * clamp01(factor);
        return c;
    }

    /// Same color with alpha replaced (clamped to [0, 1]).
    pub fn alpha(self: Hsla, a: f32) Hsla {
        var c = self;
        c.a = clamp01(a);
        return c;
    }

    /// Total ordering over (h, s, l, a) using IEEE total order, like gpui's `Ord for Hsla`.
    pub fn order(a: Hsla, b: Hsla) std.math.Order {
        inline for (.{ "h", "s", "l", "a" }) |f| {
            const o = totalOrder(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        return .eq;
    }

    /// Bitwise-total equality (NaN == NaN, -0 != +0), matching gpui's `PartialEq for Hsla`.
    pub fn eql(a: Hsla, b: Hsla) bool {
        return order(a, b) == .eq;
    }

    pub fn fromRgba(c: Rgba) Hsla {
        return c.toHsla();
    }

    pub fn fromHex(value: u32) Hsla {
        return rgb(value).toHsla();
    }
};

fn totalOrder(a: f32, b: f32) std.math.Order {
    // Map IEEE bits to a monotonically ordered signed integer (Rust's f32::total_cmp).
    const key = struct {
        fn f(x: f32) i32 {
            const bits: i32 = @bitCast(x);
            return bits ^ @as(i32, @bitCast(@as(u32, @bitCast(bits >> 31)) >> 1));
        }
    }.f;
    return std.math.order(key(a), key(b));
}

// ---- Named colors (gpui's free functions) ----

pub const black: Hsla = .{ .h = 0, .s = 0, .l = 0, .a = 1 };
pub const white: Hsla = .{ .h = 0, .s = 0, .l = 1, .a = 1 };
pub const transparent_black: Hsla = .{ .h = 0, .s = 0, .l = 0, .a = 0 };
pub const transparent_white: Hsla = .{ .h = 0, .s = 0, .l = 1, .a = 0 };
pub const red: Hsla = .{ .h = 0, .s = 1, .l = 0.5, .a = 1 };
pub const blue: Hsla = .{ .h = 0.6666666667, .s = 1, .l = 0.5, .a = 1 };
pub const green: Hsla = .{ .h = 0.3333333333, .s = 1, .l = 0.25, .a = 1 };
pub const yellow: Hsla = .{ .h = 0.1666666667, .s = 1, .l = 0.5, .a = 1 };

/// Opaque-hue grey with the given lightness and opacity (both clamped).
pub fn opaqueGrey(lightness: f32, opacity: f32) Hsla {
    return .{ .h = 0, .s = 0, .l = clamp01(lightness), .a = clamp01(opacity) };
}

// ---- Backgrounds ----

/// Discriminant of `Background`; values are read by the shaders as `u32`.
pub const BackgroundTag = enum(u32) {
    solid = 0,
    linear_gradient = 1,
    pattern_slash = 2,
    checkerboard = 3,
};

/// Color space used to interpolate gradients
/// (<https://developer.mozilla.org/en-US/docs/Web/CSS/color-interpolation-method>).
pub const ColorSpace = enum(u32) {
    srgb = 0,
    oklab = 1,
};

/// A color stop in a linear gradient. `percentage` is in [0, 1].
pub const LinearColorStop = extern struct {
    color: Hsla = .{},
    percentage: f32 = 0,

    /// Same stop with its color's alpha multiplied by `factor`.
    pub fn opacity(self: LinearColorStop, factor: f32) LinearColorStop {
        return .{ .color = self.color.opacity(factor), .percentage = self.percentage };
    }
};

pub fn linearColorStop(color: Hsla, percentage: f32) LinearColorStop {
    return .{ .color = color, .percentage = percentage };
}

/// A fill: solid color, two-stop linear gradient, diagonal-stripe pattern or
/// checkerboard. GPU layout (72 bytes, 4-byte aligned) is shared verbatim with
/// the Metal `Background` and WGSL `Background` structs.
pub const Background = extern struct {
    tag: BackgroundTag = .solid,
    color_space: ColorSpace = .srgb,
    solid: Hsla = .{},
    /// Gradient angle in degrees (0 = towards top, clockwise), pattern-slash packed
    /// `width*255*0xFFFF + interval*255`, or checkerboard cell size.
    gradient_angle_or_pattern_height: f32 = 0,
    colors: [2]LinearColorStop = .{ .{}, .{} },
    /// Explicit tail padding so the struct contains no implicit padding bytes.
    pad: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Background) == 72);
    }

    /// The solid color, if this is a solid background.
    pub fn asSolid(self: Background) ?Hsla {
        return if (self.tag == .solid) self.solid else null;
    }

    /// Use `space` for gradient color interpolation.
    pub fn colorSpace(self: Background, space: ColorSpace) Background {
        var b = self;
        b.color_space = space;
        return b;
    }

    /// Multiply the alpha of every color in the background by `factor`.
    pub fn opacity(self: Background, factor: f32) Background {
        var b = self;
        b.solid = self.solid.opacity(factor);
        b.colors = .{ self.colors[0].opacity(factor), self.colors[1].opacity(factor) };
        return b;
    }

    pub fn isTransparent(self: Background) bool {
        return switch (self.tag) {
            .solid, .pattern_slash, .checkerboard => self.solid.isTransparent(),
            .linear_gradient => self.colors[0].color.isTransparent() and self.colors[1].color.isTransparent(),
        };
    }

    pub fn fromHsla(color: Hsla) Background {
        return .{ .solid = color };
    }

    pub fn fromRgba(color: Rgba) Background {
        return .{ .solid = color.toHsla() };
    }

    pub fn eql(a: Background, b: Background) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }
};

/// A solid background.
pub fn solidBackground(color: Hsla) Background {
    return .{ .solid = color };
}

/// A linear gradient. `angle` is in degrees: 0 points to the top, increasing clockwise
/// (<https://developer.mozilla.org/en-US/docs/Web/CSS/gradient/linear-gradient>).
pub fn linearGradient(angle: f32, from: LinearColorStop, to: LinearColorStop) Background {
    return .{ .tag = .linear_gradient, .gradient_angle_or_pattern_height = angle, .colors = .{ from, to } };
}

/// Diagonal (45 degree) stripes of `width` separated by `interval` (logical px, up to 255
/// with 1/255 precision; both are packed into one f32 exactly as gpui does).
pub fn patternSlash(color: Hsla, width: f32, interval: f32) Background {
    const width_scaled: u32 = @intFromFloat(@max(0.0, width * 255.0));
    const interval_scaled: u32 = @intFromFloat(@max(0.0, interval * 255.0));
    const height: f32 = @floatFromInt(width_scaled *% 0xFFFF +% interval_scaled);
    return .{ .tag = .pattern_slash, .solid = color, .gradient_angle_or_pattern_height = height };
}

/// A checkerboard of `size`-px cells (alternate cells are transparent).
pub fn checkerboard(color: Hsla, size: f32) Background {
    return .{ .tag = .checkerboard, .solid = color, .gradient_angle_or_pattern_height = size };
}

// ---- Tests ----

const testing = std.testing;

test "hex parsing variants" {
    const want = rgba(0xff0099ff);
    try testing.expect(want.eql(try Rgba.parse("#f09")));
    try testing.expect(want.eql(try Rgba.parse("#f09f")));
    try testing.expect(want.eql(try Rgba.parse("#ff0099")));
    try testing.expect(want.eql(try Rgba.parse("#ff0099ff")));
    try testing.expect(rgba(0xf5f5f5ff).eql(try Rgba.parse(" #f5f5f5ff   ")));
    try testing.expect(rgba(0xdeadbeef).eql(try Rgba.parse("#DeAdbEeF")));
    try testing.expectError(error.MissingHash, Rgba.parse("ff0099"));
    try testing.expectError(error.InvalidLength, Rgba.parse("#ff00"[0..3]));
    try testing.expectError(error.InvalidDigit, Rgba.parse("#gg0000"));
    const c = comptime hex("#336699");
    comptime std.debug.assert(c.a == 1.0);
    try testing.expect(c.eql(rgb(0x336699)));
}

test "rgb/rgba helpers and packing" {
    const c = rgb(0x336699);
    try testing.expectEqual(@as(f32, 0x33) / 255.0, c.r);
    try testing.expectEqual(@as(f32, 1), c.a);
    try testing.expectEqual(@as(u32, 0xdeadbeef), rgba(0xdeadbeef).toU32());
    try testing.expectEqualStrings("#deadbeef", &rgba(0xdeadbeef).toHexString());
}

test "rgba alpha and opacity" {
    const c: Rgba = .{ .r = 0.2, .g = 0.6, .b = 1.0, .a = 0.8 };
    try testing.expectEqual(@as(f32, 0.25), c.alpha(0.25).a);
    try testing.expectEqual(@as(f32, 1.0), c.alpha(1.5).a);
    try testing.expectApproxEqAbs(@as(f32, 0.4), c.opacity(0.5).a, 1e-6);
    try testing.expectEqual(@as(f32, 0.8), c.opacity(2.0).a);
}

test "hsla <-> rgba round trip" {
    const samples = [_]u32{ 0xff0000, 0x00ff00, 0x0000ff, 0xff0099, 0x123456, 0xffffff, 0x000000, 0x808080, 0xfedcba };
    for (samples) |s| {
        const c = rgb(s);
        const back = c.toHsla().toRgba();
        try testing.expectApproxEqAbs(c.r, back.r, 1e-5);
        try testing.expectApproxEqAbs(c.g, back.g, 1e-5);
        try testing.expectApproxEqAbs(c.b, back.b, 1e-5);
    }
    const r = red.toRgba();
    try testing.expectEqual(@as(f32, 1), r.r);
    try testing.expectEqual(@as(f32, 0), r.g);
    try testing.expectApproxEqAbs(@as(f32, 0), blue.toRgba().r, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), blue.toRgba().b, 1e-5);
}

test "hsla helpers" {
    try testing.expectEqual(@as(f32, 1), hsla(2, -1, 0.5, 1).h);
    try testing.expectEqual(@as(f32, 0), hsla(2, -1, 0.5, 1).s);
    try testing.expectEqual(@as(f32, 0.5), red.opacity(0.5).a);
    try testing.expectApproxEqAbs(@as(f32, 0.112), hsla(0.7, 1, 0.5, 0.7).opacity(0.16).a, 1e-6);
    try testing.expectEqual(@as(f32, 0.25), red.alpha(0.25).a);
    var c = red;
    c.fadeOut(0.25);
    try testing.expectEqual(@as(f32, 0.75), c.a);
    try testing.expectEqual(@as(f32, 0), red.grayscale().s);
    try testing.expect(white.blend(red).eql(red));
    try testing.expect(white.blend(transparent_black).eql(white));
    const mixed = black.blend(white.opacity(0.5)).toRgba();
    try testing.expectApproxEqAbs(@as(f32, 0.5), mixed.r, 1e-5);
    try testing.expect(Hsla.order(black, white) == .lt);
    try testing.expect(!Hsla.eql(.{ .a = 0.0 }, .{ .a = -0.0 }));
}

test "background solid" {
    const color = rgba(0xff0099ff).toHsla();
    var bg = Background.fromHsla(color);
    try testing.expectEqual(BackgroundTag.solid, bg.tag);
    try testing.expect(bg.asSolid().?.eql(color));
    try testing.expect(bg.opacity(0.5).solid.eql(color.opacity(0.5)));
    try testing.expect(!bg.isTransparent());
    bg.solid = hsla(0, 0, 0, 0);
    try testing.expect(bg.isTransparent());
}

test "background linear gradient" {
    const from = linearColorStop(rgba(0xff0099ff).toHsla(), 0.0);
    const to = linearColorStop(rgba(0x00ff99ff).toHsla(), 1.0);
    const bg = linearGradient(90.0, from, to).colorSpace(.oklab);
    try testing.expectEqual(BackgroundTag.linear_gradient, bg.tag);
    try testing.expectEqual(ColorSpace.oklab, bg.color_space);
    try testing.expect(bg.asSolid() == null);
    try testing.expect(bg.opacity(0.5).colors[0].color.eql(from.color.opacity(0.5)));
    try testing.expect(!bg.isTransparent());
    try testing.expect(bg.opacity(0.0).isTransparent());
}

test "background patterns and layout" {
    const p = patternSlash(red, 1.0, 2.0);
    try testing.expectEqual(BackgroundTag.pattern_slash, p.tag);
    try testing.expectEqual(@as(f32, 255 * 0xFFFF + 510), p.gradient_angle_or_pattern_height);
    try testing.expectEqual(BackgroundTag.checkerboard, checkerboard(red, 8).tag);
    try testing.expectEqual(@as(usize, 16), @sizeOf(Hsla));
    try testing.expectEqual(@as(usize, 20), @sizeOf(LinearColorStop));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Background, "solid"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Background, "gradient_angle_or_pattern_height"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(Background, "colors"));
    try testing.expectEqual(@as(usize, 68), @offsetOf(Background, "pad"));
}

test "swap premultiplied rgba to bgra" {
    var px = [_]u8{ 100, 50, 25, 128 };
    swapRgbaPaToBgra(&px);
    try testing.expectEqual(@as(u8, 49), px[0]);
    try testing.expectEqual(@as(u8, 199), px[2]);
}
