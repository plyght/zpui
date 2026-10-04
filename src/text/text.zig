//! zpui text system: shaping, wrapping, layout caching and glyph painting.
//!
//! Platform backends implement `platform.TextSystem` (`freetype.zig` on Linux,
//! `coretext.zig` on macOS); everything else here is platform-independent.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/platform.zig");

pub const types = @import("types.zig");
pub const fallback = @import("fallback.zig");
pub const line_layout = @import("line_layout.zig");
pub const line_wrapper = @import("line_wrapper.zig");
pub const line = @import("line.zig");
pub const text_system = @import("text_system.zig");

// Contract types.
pub const Font = types.Font;
pub const FontId = types.FontId;
pub const FontWeight = types.FontWeight;
pub const weight = types.weight;
pub const FontStyle = types.FontStyle;
pub const FontFeature = types.FontFeature;
pub const FontMetrics = types.FontMetrics;
pub const FontRun = types.FontRun;
pub const GlyphId = types.GlyphId;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const LineLayout = types.LineLayout;
pub const RenderGlyphParams = types.RenderGlyphParams;
pub const TextRun = types.TextRun;
pub const UnderlineStyle = types.UnderlineStyle;
pub const StrikethroughStyle = types.StrikethroughStyle;
pub const subpixel_variants_x = types.subpixel_variants_x;
pub const subpixel_variants_y = types.subpixel_variants_y;

// Core.
pub const TextSystem = text_system.TextSystem;
pub const WindowTextSystem = text_system.WindowTextSystem;
pub const ShapeTextOptions = text_system.ShapeTextOptions;
pub const Truncation = text_system.Truncation;
pub const freeLines = text_system.freeLines;
pub const font = text_system.font;
pub const LineWrapper = line_wrapper.LineWrapper;
pub const LineFragment = line_wrapper.LineFragment;
pub const Boundary = line_wrapper.Boundary;
pub const TruncateFrom = line_wrapper.TruncateFrom;
pub const WrapBoundary = line_layout.WrapBoundary;
pub const SharedLineLayout = line_layout.SharedLineLayout;
pub const SharedWrappedLayout = line_layout.SharedWrappedLayout;
pub const LineLayoutCache = line_layout.LineLayoutCache;
pub const LineLayoutIndex = line_layout.LineLayoutIndex;
pub const ShapedLine = line.ShapedLine;
pub const WrappedLine = line.WrappedLine;
pub const DecorationRun = line.DecorationRun;
pub const GlyphPainter = line.GlyphPainter;
pub const TextAlign = line.TextAlign;

/// The OS text backend module (`create(gpa) !platform.TextSystem`, `destroy(ts)`).
pub const backend = switch (builtin.os.tag) {
    .linux => @import("freetype.zig"),
    else => struct {
        pub fn create(_: std.mem.Allocator) !platform.TextSystem {
            return error.Unsupported;
        }
        pub fn destroy(_: platform.TextSystem) void {}
    },
};

/// Create the platform text system: FreeType/HarfBuzz/fontconfig on Linux, CoreText on macOS.
/// Destroy with `destroyPlatformTextSystem`.
pub fn createPlatformTextSystem(gpa: std.mem.Allocator) !platform.TextSystem {
    return backend.create(gpa);
}

pub fn destroyPlatformTextSystem(ts: platform.TextSystem) void {
    backend.destroy(ts);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
