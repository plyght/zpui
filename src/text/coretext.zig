//! macOS `platform.TextSystem` on CoreText + CoreGraphics (port of zui
//! `gpui_macos/src/text_system.rs`, with font-kit's CoreText loader inlined).
//!
//! * Fonts: a family is loaded as every face CoreText matches for its family
//!   name (memory fonts from `addFont` first), each stored at size =
//!   units-per-em so metrics and advances come out in font units. Faces
//!   without an 'm' glyph are skipped like zui. Selection is CSS-style best
//!   match on (style, weight).
//! * Features / fallbacks: `kCTFontFeatureSettingsAttribute` and
//!   `kCTFontCascadeListAttribute` (+ the system cascade list) on the face.
//! * Shaping: one `CFAttributedString` per line, a `CTLine`, and its `CTRun`s'
//!   glyphs, positions and UTF-16 string indices (converted to UTF-8). CoreText
//!   substitutes fallback fonts per run; those faces are registered on the fly.
//!   Adjacent runs on the same face alternate the font size by one ULP to stop
//!   ligatures forming across run boundaries (zui nudges every other run,
//!   starting with the first). The first run, and any run whose face differs from
//!   the previous one, keeps the exact size: CoreText's system font is not
//!   continuous in size (macOS 27: 28 pt is the default instance, 28 pt + 1 ULP an
//!   interpolated one 0.57 px narrower per line), so a nudged single-run line
//!   measured differently from AppKit.
//! * Rasterization: `CTFontDrawGlyphs` into an A8 bitmap (or RGBA for color
//!   emoji, converted to BGRA with straight alpha as zui's
//!   `swap_rgba_pa_to_bgra` does, which the polychrome sprite shader expects),
//!   with subpixel-positioned origins. Font smoothing (stroke dilation) follows
//!   `RenderGlyphParams.dilation`, which the painters set from the fill color
//!   (`glyphDilationForColor`, zui).
//! * The system font (".SystemUIFont" → ".AppleSystemUIFont") needs no special
//!   casing: CoreText re-resolves the optical size (`opsz`) when a face is copied
//!   to the layout size, and `CTLine` applies the size-specific tracking, so
//!   widths and glyph positions match `NSFont.systemFont(ofSize:weight:)` exactly
//!   (tools/font-compare, macOS 15, 26 and 27).
//!
//! Thread-safe: every entry point takes an `os_unfair_lock`.

const std = @import("std");
const builtin = @import("builtin");
const cf = @import("../platform/mac/cf.zig");
const ak = @import("../platform/mac/appkit.zig");
const platform = @import("../platform/platform.zig");
const types = @import("types.zig");
const geometry = @import("../geometry.zig");

const Allocator = std.mem.Allocator;
const FontId = types.FontId;
const DevicePixels = geometry.DevicePixels;

const log = std.log.scoped(.coretext);

const FontEntry = struct {
    /// The face at size == units_per_em.
    font: cf.CTFontRef,
    units_per_em: f32,
    is_emoji: bool,
    metrics: types.FontMetrics,
};

/// CSS-ish font properties of a face, for best-match selection.
/// `width`: CoreText width trait (-1 condensed .. 0 normal .. 1 expanded).
const Props = struct { weight: f32, style: types.FontStyle, width: f32 = 0 };

/// Create the CoreText backend (see `text.createPlatformTextSystem`).
pub fn create(gpa: Allocator) !platform.TextSystem {
    return (try CoreTextSystem.create(gpa)).textSystem();
}

pub fn destroy(ts: platform.TextSystem) void {
    CoreTextSystem.cast(ts.ptr).destroy();
}

pub const CoreTextSystem = struct {
    gpa: Allocator,
    lock: ak.UnfairLock = .{},
    fonts: std.ArrayList(FontEntry) = .empty,
    /// Serialized `Font` → selected face.
    selections: std.StringHashMapUnmanaged(FontId) = .empty,
    /// Serialized (family, features, fallbacks) → candidate faces.
    families: std.StringHashMapUnmanaged([]FontId) = .empty,
    /// PostScript name + traits → face (for fonts CoreText substitutes while shaping).
    by_native_key: std.StringHashMapUnmanaged(FontId) = .empty,
    /// Descriptors from `addFont`, searched before system fonts (retained).
    memory_descriptors: std.ArrayList(cf.CTFontDescriptorRef) = .empty,

    pub fn create(gpa: Allocator) !*CoreTextSystem {
        const self = try gpa.create(CoreTextSystem);
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *CoreTextSystem) void {
        const gpa = self.gpa;
        for (self.fonts.items) |f| cf.CFRelease(f.font);
        self.fonts.deinit(gpa);
        freeKeys(gpa, &self.selections);
        self.selections.deinit(gpa);
        var it = self.families.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.families.deinit(gpa);
        freeKeys(gpa, &self.by_native_key);
        self.by_native_key.deinit(gpa);
        for (self.memory_descriptors.items) |d| cf.CFRelease(d);
        self.memory_descriptors.deinit(gpa);
        gpa.destroy(self);
    }

    fn freeKeys(gpa: Allocator, map: *std.StringHashMapUnmanaged(FontId)) void {
        var it = map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
    }

    pub fn textSystem(self: *CoreTextSystem) platform.TextSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform.TextSystem.VTable = .{
        .addFont = vAddFont,
        .fontId = vFontId,
        .fontMetrics = vFontMetrics,
        .glyphForChar = vGlyphForChar,
        .advance = vAdvance,
        .glyphRasterBounds = vGlyphRasterBounds,
        .rasterizeGlyph = vRasterizeGlyph,
        .layoutLine = vLayoutLine,
        .glyphDilationForColor = glyphDilationForColor,
        .raster_transforms = true,
    };

    fn cast(ptr: *anyopaque) *CoreTextSystem {
        return @ptrCast(@alignCast(ptr));
    }

    fn entry(self: *CoreTextSystem, font_id: FontId) FontEntry {
        return self.fonts.items[@backingInt(font_id)];
    }

    // -- addFont ----------------------------------------------------------------

    fn vAddFont(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        const data = cf.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
        defer cf.CFRelease(data);
        const descriptors = cf.CTFontManagerCreateFontDescriptorsFromData(data) orelse return error.InvalidFontData;
        defer cf.CFRelease(descriptors);
        const count = cf.CFArrayGetCount(descriptors);
        if (count == 0) return error.InvalidFontData;
        try self.memory_descriptors.ensureUnusedCapacity(self.gpa, @intCast(count));
        var i: cf.CFIndex = 0;
        while (i < count) : (i += 1) {
            const d: cf.CTFontDescriptorRef = @ptrCast(cf.CFArrayGetValueAtIndex(descriptors, i).?);
            self.memory_descriptors.appendAssumeCapacity(@ptrCast(cf.CFRetain(d)));
        }
    }

    // -- font selection -----------------------------------------------------------

    fn vFontId(ptr: *anyopaque, font: types.Font) anyerror!FontId {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();

        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(self.gpa);
        try serializeFamilyKey(self.gpa, &key_buf, font);
        const family_len = key_buf.items.len;
        try key_buf.print(self.gpa, "\x00{d}\x00{d}", .{ font.weight, @backingInt(font.style) });
        if (self.selections.get(key_buf.items)) |id| return id;

        const family_key = key_buf.items[0..family_len];
        const candidates = self.families.get(family_key) orelse blk: {
            const ids = try self.loadFamily(font);
            errdefer self.gpa.free(ids);
            const owned_key = try self.gpa.dupe(u8, family_key);
            errdefer self.gpa.free(owned_key);
            try self.families.put(self.gpa, owned_key, ids);
            break :blk ids;
        };
        if (candidates.len == 0) return error.FontNotFound;

        // Large variable families (SF Pro: weights x widths x optical sizes) have many
        // named instances; keep them all so the normal-width faces are considered.
        var props_buf: [512]Props = undefined;
        const n = @min(candidates.len, props_buf.len);
        for (candidates[0..n], props_buf[0..n]) |cid, *p| p.* = faceProps(self.entry(cid).font);
        const ix = bestMatch(props_buf[0..n], .{ .weight = font.weight, .style = font.style });
        const id = candidates[ix];

        const owned = try self.gpa.dupe(u8, key_buf.items);
        errdefer self.gpa.free(owned);
        try self.selections.put(self.gpa, owned, id);
        return id;
    }

    fn serializeFamilyKey(gpa: Allocator, out: *std.ArrayList(u8), font: types.Font) !void {
        try out.appendSlice(gpa, font.family);
        for (font.features) |f| try out.print(gpa, "\x01{s}={d}", .{ &f.tag, f.value });
        for (font.fallbacks) |f| try out.print(gpa, "\x02{s}", .{f});
    }

    /// zui `load_family`: every face of the family, with features/fallbacks applied.
    fn loadFamily(self: *CoreTextSystem, font: types.Font) ![]FontId {
        const name = if (std.mem.eql(u8, font.family, ".SystemUIFont")) ".AppleSystemUIFont" else font.family;

        var descriptors: std.ArrayList(cf.CTFontDescriptorRef) = .empty;
        defer {
            for (descriptors.items) |d| cf.CFRelease(d);
            descriptors.deinit(self.gpa);
        }
        for (self.memory_descriptors.items) |d| {
            if (descriptorFamilyIs(d, name)) try descriptors.append(self.gpa, @ptrCast(cf.CFRetain(d)));
        }
        if (descriptors.items.len == 0) try appendSystemFamily(self.gpa, &descriptors, name);

        var ids: std.ArrayList(FontId) = .empty;
        errdefer ids.deinit(self.gpa);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            seen.deinit(self.gpa);
        }
        for (descriptors.items) |desc| {
            const base = cf.CTFontCreateWithFontDescriptor(desc, 0, null) orelse continue;
            defer cf.CFRelease(base);
            const upem: f32 = @floatFromInt(cf.CTFontGetUnitsPerEm(base));
            const attrs = makeFeatureAndFallbackDescriptor(base, font);
            defer if (attrs) |a| cf.CFRelease(a);
            const unit = cf.CTFontCreateCopyWithAttributes(base, upem, null, attrs) orelse continue;

            // Text measurement relies on 'm'; skip faces without it (zui).
            if (glyphForCharIn(unit, 'm') == null) {
                log.warn("font in family '{s}' has no 'm' glyph and was not loaded", .{name});
                cf.CFRelease(unit);
                continue;
            }
            var key_buf: [512]u8 = undefined;
            const key = nativeKey(unit, &key_buf);
            if (seen.contains(key)) {
                cf.CFRelease(unit);
                continue;
            }
            try seen.put(self.gpa, try self.gpa.dupe(u8, key), {});
            const id = try self.registerFont(unit, key);
            try ids.append(self.gpa, id);
        }
        return ids.toOwnedSlice(self.gpa);
    }

    /// Takes ownership of `unit` (size == upem). Points `key` at the new face.
    fn registerFont(self: *CoreTextSystem, unit: cf.CTFontRef, key: []const u8) !FontId {
        errdefer cf.CFRelease(unit);
        const id: FontId = @fromBackingInt(@intCast(self.fonts.items.len));
        var ps_buf: [256]u8 = undefined;
        const ps_name = cf.CTFontCopyPostScriptName(unit);
        defer cf.CFRelease(ps_name);
        const ps = cf.stringToUtf8(ps_name, &ps_buf);
        const upem: f32 = @floatFromInt(cf.CTFontGetUnitsPerEm(unit));
        const bbox = cf.CTFontGetBoundingBox(unit);
        try self.fonts.append(self.gpa, .{
            .font = unit,
            .units_per_em = upem,
            .is_emoji = std.mem.eql(u8, ps, "AppleColorEmoji") or std.mem.eql(u8, ps, ".AppleColorEmojiUI"),
            .metrics = .{
                .units_per_em = @intFromFloat(upem),
                .ascent = @floatCast(cf.CTFontGetAscent(unit)),
                .descent = -@as(f32, @floatCast(cf.CTFontGetDescent(unit))),
                .line_gap = @floatCast(cf.CTFontGetLeading(unit)),
                .underline_position = @floatCast(cf.CTFontGetUnderlinePosition(unit)),
                .underline_thickness = @floatCast(cf.CTFontGetUnderlineThickness(unit)),
                .cap_height = @floatCast(cf.CTFontGetCapHeight(unit)),
                .x_height = @floatCast(cf.CTFontGetXHeight(unit)),
                .bounding_box = .{
                    .origin = .{ .x = @floatCast(bbox.origin.x), .y = @floatCast(bbox.origin.y) },
                    .size = .{ .width = @floatCast(bbox.size.width), .height = @floatCast(bbox.size.height) },
                },
            },
        });
        errdefer _ = self.fonts.pop();
        const gop = try self.by_native_key.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
                self.by_native_key.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = id;
        return id;
    }

    /// zui `id_for_native_font`: a face CoreText chose while shaping (fallback or ours).
    fn idForNativeFont(self: *CoreTextSystem, font: cf.CTFontRef) !FontId {
        var key_buf: [512]u8 = undefined;
        const key = nativeKey(font, &key_buf);
        if (self.by_native_key.get(key)) |id| return id;
        const upem: cf.CGFloat = @floatFromInt(cf.CTFontGetUnitsPerEm(font));
        const unit = cf.CTFontCreateCopyWithAttributes(font, upem, null, null) orelse return error.FontCreationFailed;
        return self.registerFont(unit, key);
    }

    // -- metrics ------------------------------------------------------------------

    fn vFontMetrics(ptr: *anyopaque, font_id: FontId) types.FontMetrics {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        return self.entry(font_id).metrics;
    }

    fn vGlyphForChar(ptr: *anyopaque, font_id: FontId, ch: u21) ?types.GlyphId {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        return glyphForCharIn(self.entry(font_id).font, ch);
    }

    fn vAdvance(ptr: *anyopaque, font_id: FontId, glyph: types.GlyphId) geometry.Size(f32) {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        const g: cf.CGGlyph = @truncate(glyph);
        var adv: [1]cf.CGSize = .{.{ .width = 0, .height = 0 }};
        _ = cf.CTFontGetAdvancesForGlyphs(self.entry(font_id).font, cf.kCTFontOrientationDefault, @ptrCast(&g), &adv, 1);
        return .{ .width = @floatCast(adv[0].width), .height = @floatCast(adv[0].height) };
    }

    // -- rasterization ------------------------------------------------------------

    fn vGlyphRasterBounds(ptr: *anyopaque, params: types.RenderGlyphParams) anyerror!geometry.Bounds(DevicePixels) {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        return self.rasterBounds(params);
    }

    /// font-kit `raster_bounds` (y-down, device pixels, rounded out) dilated by 1px
    /// on every side to leave CoreGraphics room for antialiasing (zui). Under a raster
    /// transform, the bounding box of the transformed glyph box (`transformedRasterBounds`).
    fn rasterBounds(self: *CoreTextSystem, params: types.RenderGlyphParams) !geometry.Bounds(DevicePixels) {
        const sized = cf.CTFontCreateCopyWithAttributes(self.entry(params.font_id).font, params.font_size, null, null) orelse
            return error.FontCreationFailed;
        defer cf.CFRelease(sized);
        const g: cf.CGGlyph = @truncate(params.glyph_id);
        const r = cf.CTFontGetBoundingRectsForGlyphs(sized, cf.kCTFontOrientationDefault, @ptrCast(&g), null, 1);
        if (rasterTransformed(params)) return transformedRasterBounds(params, r);
        const s: f64 = params.scale_factor;
        const x0 = @floor(r.origin.x * s);
        const y0 = @floor(-(r.origin.y + r.size.height) * s);
        const x1 = @ceil((r.origin.x + r.size.width) * s);
        const y1 = @ceil(-r.origin.y * s);
        // zui widens the bitmap by one pixel per shifted axis inside `rasterize_glyph` and returns
        // the new size; our contract returns only bytes, so the extra pixel belongs in the bounds
        // (the atlas tile is sized from them).
        const extra_x: DevicePixels = if (params.subpixel_variant_x > 0) 1 else 0;
        const extra_y: DevicePixels = if (params.subpixel_variant_y > 0) 1 else 0;
        return .{
            .origin = .{ .x = @as(DevicePixels, @intFromFloat(x0)) - 1, .y = @as(DevicePixels, @intFromFloat(y0)) - 1 },
            .size = .{ .width = @as(DevicePixels, @intFromFloat(x1 - x0)) + 2 + extra_x, .height = @as(DevicePixels, @intFromFloat(y1 - y0)) + 2 + extra_y },
        };
    }

    fn vRasterizeGlyph(ptr: *anyopaque, gpa: Allocator, params: types.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels)) anyerror![]u8 {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        return self.rasterize(gpa, params, bounds, if (params.is_emoji) 0 else params.dilation);
    }

    /// zui `rasterize_glyph`. `dilation` (0..4, see `glyphDilationForColor`) enables font smoothing.
    fn rasterize(self: *CoreTextSystem, gpa: Allocator, params: types.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels), dilation: u8) ![]u8 {
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return error.EmptyGlyphBounds;
        // `bounds` already includes the extra pixel for subpixel-shifted variants (rasterBounds),
        // so the bitmap matches the atlas tile exactly.
        const w: usize = @intCast(bounds.size.width);
        const h: usize = @intCast(bounds.size.height);

        const bpp: usize = if (params.is_emoji) 4 else 1;
        const bytes = try gpa.alloc(u8, w * h * bpp);
        errdefer gpa.free(bytes);
        @memset(bytes, 0);

        const ctx = blk: {
            if (params.is_emoji) {
                const space = cf.CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpaceFailed;
                defer cf.CGColorSpaceRelease(space);
                break :blk cf.CGBitmapContextCreate(bytes.ptr, w, h, 8, w * 4, space, cf.kCGImageAlphaPremultipliedLast);
            }
            // Device gray like zui: font smoothing (dilation) keys off the gray fill color.
            const gray = cf.CGColorSpaceCreateDeviceGray() orelse return error.ColorSpaceFailed;
            defer cf.CGColorSpaceRelease(gray);
            break :blk cf.CGBitmapContextCreate(bytes.ptr, w, h, 8, w, gray, cf.kCGImageAlphaOnly);
        } orelse return error.BitmapContextFailed;
        defer cf.CGContextRelease(ctx);

        // Origin at the bitmap's bottom-left, matching the y-down raster bounds.
        cf.CGContextTranslateCTM(ctx, @floatFromInt(-bounds.origin.x), @floatFromInt(bounds.origin.y + bounds.size.height));
        const transformed = rasterTransformed(params);
        if (!transformed) cf.CGContextScaleCTM(ctx, params.scale_factor, params.scale_factor);

        cf.CGContextSetTextDrawingMode(ctx, cf.kCGTextFill);
        cf.CGContextSetAllowsAntialiasing(ctx, true);
        cf.CGContextSetShouldAntialias(ctx, true);
        cf.CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        cf.CGContextSetShouldSubpixelPositionFonts(ctx, true);
        cf.CGContextSetAllowsFontSubpixelQuantization(ctx, false);
        cf.CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
        if (dilation > 0) {
            cf.CGContextSetShouldSmoothFonts(ctx, true);
            cf.CGContextSetGrayFillColor(ctx, @as(f64, @floatFromInt(dilation)) * 0.25, 1);
        } else {
            cf.CGContextSetShouldSmoothFonts(ctx, false);
            cf.CGContextSetGrayFillColor(ctx, 0, 1);
        }

        const sized = cf.CTFontCreateCopyWithAttributes(self.entry(params.font_id).font, params.font_size, null, null) orelse
            return error.FontCreationFailed;
        defer cf.CFRelease(sized);
        // zui divides both axes by SUBPIXEL_VARIANTS_X.
        const variants: f32 = @floatFromInt(types.subpixel_variants_x);
        const shift_x = @as(f32, @floatFromInt(params.subpixel_variant_x)) / variants;
        const shift_y = @as(f32, @floatFromInt(params.subpixel_variant_y)) / variants;
        const g: cf.CGGlyph = @truncate(params.glyph_id);
        if (transformed) {
            // Bitmap origin, then the device-space subpixel shift (so the variant still moves
            // the glyph by a fraction of a device pixel), then the outline transform
            // (conjugated into CoreGraphics' y-up space), then the logical -> device scale.
            cf.CGContextTranslateCTM(ctx, shift_x, shift_y);
            cf.CGContextConcatCTM(ctx, cgTransform(params.raster_transform));
            cf.CGContextScaleCTM(ctx, params.scale_factor, params.scale_factor);
            const origin: cf.CGPoint = .{ .x = 0, .y = 0 };
            cf.CTFontDrawGlyphs(sized, @ptrCast(&g), @ptrCast(&origin), 1, ctx);
        } else {
            const pos: cf.CGPoint = .{ .x = shift_x / params.scale_factor, .y = shift_y / params.scale_factor };
            cf.CTFontDrawGlyphs(sized, @ptrCast(&g), @ptrCast(&pos), 1, ctx);
        }

        if (params.is_emoji) swapRgbaPremultipliedToBgraStraight(bytes);
        return bytes;
    }

    // -- shaping ------------------------------------------------------------------

    fn vLayoutLine(ptr: *anyopaque, arena: Allocator, str: []const u8, font_size: geometry.Pixels, runs: []const types.FontRun) anyerror!types.LineLayout {
        const self = cast(ptr);
        self.lock.lock();
        defer self.lock.unlock();
        return self.layoutLine(arena, str, font_size, runs);
    }

    /// zui `layout_line`.
    fn layoutLine(self: *CoreTextSystem, arena: Allocator, text: []const u8, font_size: geometry.Pixels, font_runs: []const types.FontRun) !types.LineLayout {
        const astr = cf.CFAttributedStringCreateMutable(null, 0) orelse return error.OutOfMemory;
        defer cf.CFRelease(astr);
        var max_ascent: f32 = 0;
        var max_descent: f32 = 0;

        cf.CFAttributedStringBeginEditing(astr);
        var rest = text;
        var prev_font: ?FontId = null;
        var prev_nudged = false;
        // The sized fonts this line set, so runs CoreText kept on them map back to their face.
        var line_fonts: std.ArrayList(struct { font: cf.CTFontRef, id: FontId }) = .empty;
        defer {
            for (line_fonts.items) |lf| cf.CFRelease(lf.font);
            line_fonts.deinit(self.gpa);
        }
        for (font_runs) |run| {
            const len = @min(run.len, rest.len);
            const run_text = rest[0..len];
            rest = rest[len..];

            const utf16_start = cf.CFAttributedStringGetLength(astr);
            if (cf.string(run_text)) |s| {
                defer cf.CFRelease(s);
                // May silently drop code points it dislikes (e.g. a leading BOM).
                cf.CFAttributedStringReplaceString(astr, .{ .location = utf16_start, .length = 0 }, s);
            }
            const utf16_end = cf.CFAttributedStringGetLength(astr);

            const e = self.entry(run.font_id);
            const scale = font_size / e.units_per_em;
            max_ascent = @max(max_ascent, e.metrics.ascent * scale);
            max_descent = @max(max_descent, -e.metrics.descent * scale);

            // Only a run following a run on the same face needs a different size to keep them
            // apart (otherwise CoreText merges them and ligatures span the boundary).
            const nudge = prev_font != null and prev_font.? == run.font_id and !prev_nudged;
            prev_font = run.font_id;
            prev_nudged = nudge;
            const size: f32 = if (nudge) std.math.nextAfter(f32, font_size, std.math.inf(f32)) else font_size;
            if (utf16_end == utf16_start) continue;
            const sized = cf.CTFontCreateCopyWithAttributes(e.font, size, null, null) orelse continue;
            line_fonts.append(self.gpa, .{ .font = sized, .id = run.font_id }) catch {
                cf.CFRelease(sized);
                continue;
            };
            cf.CFAttributedStringSetAttribute(astr, .{ .location = utf16_start, .length = utf16_end - utf16_start }, cf.kCTFontAttributeName, sized);
        }
        cf.CFAttributedStringEndEditing(astr);

        const line = cf.CTLineCreateWithAttributedString(@ptrCast(astr)) orelse return error.ShapingFailed;
        defer cf.CFRelease(line);
        const glyph_runs = cf.CTLineGetGlyphRuns(line);
        const run_count: usize = @intCast(cf.CFArrayGetCount(glyph_runs));

        var runs: std.ArrayList(types.ShapedRun) = try .initCapacity(arena, run_count);
        var glyphs_tmp: std.ArrayList(types.ShapedGlyph) = .empty;
        var current_font: ?FontId = null;
        var conv: IndexConverter = .{ .text = text };

        for (0..run_count) |ri| {
            const run: cf.CTRunRef = @ptrCast(cf.CFArrayGetValueAtIndex(glyph_runs, @intCast(ri)).?);
            const attrs = cf.CTRunGetAttributes(run);
            const run_font: cf.CTFontRef = @ptrCast(cf.CFDictionaryGetValue(attrs, cf.kCTFontAttributeName) orelse continue);
            const font_id = for (line_fonts.items) |lf| {
                if (lf.font == run_font or cf.CFEqual(lf.font, run_font) != 0) break lf.id;
            } else try self.idForNativeFont(run_font);
            const is_emoji = self.entry(font_id).is_emoji;

            if (current_font == null or current_font.? != font_id) {
                if (current_font) |fid| try runs.append(arena, .{ .font_id = fid, .glyphs = try glyphs_tmp.toOwnedSlice(arena) });
                current_font = font_id;
            }

            const count: usize = @intCast(cf.CTRunGetGlyphCount(run));
            if (count == 0) continue;
            const ids = try self.gpa.alloc(cf.CGGlyph, count);
            defer self.gpa.free(ids);
            const positions = try self.gpa.alloc(cf.CGPoint, count);
            defer self.gpa.free(positions);
            const indices = try self.gpa.alloc(cf.CFIndex, count);
            defer self.gpa.free(indices);
            const all: cf.CFRange = .{ .location = 0, .length = 0 };
            cf.CTRunGetGlyphs(run, all, ids.ptr);
            cf.CTRunGetPositions(run, all, positions.ptr);
            cf.CTRunGetStringIndices(run, all, indices.ptr);

            try glyphs_tmp.ensureUnusedCapacity(arena, count);
            for (ids, positions, indices) |gid, pos, utf16_ix_signed| {
                const utf16_ix: usize = @intCast(@max(utf16_ix_signed, 0));
                // The converter only seeks forward; restart for RTL / reordered runs.
                if (conv.utf16_ix > utf16_ix) conv = .{ .text = text };
                conv.advanceToUtf16(utf16_ix);
                glyphs_tmp.appendAssumeCapacity(.{
                    .id = gid,
                    .position = .{ .x = @floatCast(pos.x), .y = @floatCast(pos.y) },
                    .index = conv.utf8_ix,
                    .is_emoji = is_emoji,
                });
            }
        }
        if (current_font) |fid| try runs.append(arena, .{ .font_id = fid, .glyphs = try glyphs_tmp.toOwnedSlice(arena) });

        const width = cf.CTLineGetTypographicBounds(line, null, null, null);
        return .{
            .font_size = font_size,
            .width = @floatCast(width),
            .ascent = max_ascent,
            .descent = max_descent,
            .runs = try runs.toOwnedSlice(arena),
            .len = text.len,
        };
    }
};

/// A non-identity `raster_transform` on a monochrome glyph (emoji always draw upright).
fn rasterTransformed(params: types.RenderGlyphParams) bool {
    return !params.is_emoji and !params.raster_transform.isIdentity();
}

/// `RasterTransform` (y down) as a CoreGraphics CTM (y up): conjugating by the y flip
/// negates the off-diagonal terms.
fn cgTransform(t: types.RasterTransform) cf.CGAffineTransform {
    return .{ .a = t.a, .b = -t.b, .c = -t.c, .d = t.d, .tx = 0, .ty = 0 };
}

/// Raster bounds of a transformed glyph whose CoreText bounding rect (y up, logical px) is
/// `r`: the device-pixel bounding box of the transformed rect, rounded out, plus the same
/// 1px antialiasing margin and subpixel-shift pixel as the untransformed path. A rect's
/// image under a linear map is a parallelogram, so this always covers the drawn outline.
fn transformedRasterBounds(params: types.RenderGlyphParams, r: cf.CGRect) geometry.Bounds(DevicePixels) {
    const s: f64 = params.scale_factor;
    const box = params.raster_transform.mapRect(
        r.origin.x * s,
        -(r.origin.y + r.size.height) * s,
        (r.origin.x + r.size.width) * s,
        -r.origin.y * s,
    );
    const x0 = @floor(box[0]);
    const y0 = @floor(box[1]);
    const x1 = @ceil(box[2]);
    const y1 = @ceil(box[3]);
    const extra_x: DevicePixels = if (params.subpixel_variant_x > 0) 1 else 0;
    const extra_y: DevicePixels = if (params.subpixel_variant_y > 0) 1 else 0;
    return .{
        .origin = .{ .x = @as(DevicePixels, @intFromFloat(x0)) - 1, .y = @as(DevicePixels, @intFromFloat(y0)) - 1 },
        .size = .{ .width = @as(DevicePixels, @intFromFloat(x1 - x0)) + 2 + extra_x, .height = @as(DevicePixels, @intFromFloat(y1 - y0)) + 2 + extra_y },
    };
}

test "transformed CoreText raster bounds cover the sheared glyph box" {
    const r: cf.CGRect = .{ .origin = .{ .x = 0.5, .y = -2 }, .size = .{ .width = 8, .height = 12 } }; // y up
    var p: types.RenderGlyphParams = .{ .font_id = @enumFromInt(0), .glyph_id = 1, .font_size = 16, .subpixel_variant_x = 0, .subpixel_variant_y = 0, .is_emoji = false, .subpixel_rendering = false, .scale_factor = 2 };
    try std.testing.expect(!rasterTransformed(p));
    // Up leans right by half its height (glyph top at y = -20 device px moves +10 in x).
    p.raster_transform = types.RasterTransform.fromBasis(.{ 1, 0 }, .{ 0.5, -1 });
    try std.testing.expect(rasterTransformed(p));
    const b = transformedRasterBounds(p, r);
    // Device box (y down): x [1, 17], y [-20, 4]. x' = x - 0.5 * y -> [1 - 2, 17 + 10] = [-1, 27].
    try std.testing.expectEqual(@as(DevicePixels, -2), b.origin.x);
    try std.testing.expectEqual(@as(DevicePixels, 28 + 2), b.size.width);
    try std.testing.expectEqual(@as(DevicePixels, -21), b.origin.y);
    try std.testing.expectEqual(@as(DevicePixels, 24 + 2), b.size.height);
    // The subpixel-shifted variant keeps its extra column.
    p.subpixel_variant_x = 2;
    try std.testing.expectEqual(b.size.width + 1, transformedRasterBounds(p, r).size.width);
    // Emoji never transform.
    p.is_emoji = true;
    try std.testing.expect(!rasterTransformed(p));
    // y-up conjugation: glyph up (0, 1 in CG) leans right.
    const m = cgTransform(types.RasterTransform.fromBasis(.{ 1, 0 }, .{ 0.5, -1 }));
    try std.testing.expectEqual(@as(f64, 0.5), m.c);
    try std.testing.expectEqual(@as(f64, 1), m.d);
}

/// zui `glyph_dilation_for_color`: CoreGraphics' smoothing thickens strokes by
/// an amount picked from the fill luminance; 0 when the user disabled smoothing.
pub fn glyphDilationForColor(rgba: [3]f32) u8 {
    if (!fontSmoothingAllowedByUser()) return 0;
    const luminance = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2];
    const level: i32 = @intFromFloat(@floor(4.0 * luminance + 0.5));
    return @intCast(std.math.clamp(level, 0, 4));
}

var smoothing_cache = std.atomic.Value(u8).init(0); // 0 = unknown, 1 = no, 2 = yes

/// `AppleFontSmoothing` preference: only an explicit 0 disables smoothing.
pub fn fontSmoothingAllowedByUser() bool {
    switch (smoothing_cache.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const allowed = blk: {
        const key = cf.string("AppleFontSmoothing") orelse break :blk true;
        defer cf.CFRelease(key);
        const value = cf.CFPreferencesCopyAppValue(key, cf.kCFPreferencesCurrentApplication) orelse break :blk true;
        defer cf.CFRelease(value);
        const n = cf.numberValue(value) orelse break :blk true;
        break :blk n != 0;
    };
    smoothing_cache.store(if (allowed) 2 else 1, .monotonic);
    return allowed;
}

/// zui `StringIndexConverter`: UTF-16 offsets → UTF-8 offsets, seeking forward.
const IndexConverter = struct {
    text: []const u8,
    utf8_ix: usize = 0,
    utf16_ix: usize = 0,

    fn advanceToUtf16(self: *IndexConverter, target: usize) void {
        var i = self.utf8_ix;
        while (i < self.text.len) {
            if (self.utf16_ix >= target) {
                self.utf8_ix = i;
                return;
            }
            const n = std.unicode.utf8ByteSequenceLength(self.text[i]) catch 1;
            const cp_len = @min(n, self.text.len - i);
            self.utf16_ix += if (cp_len == 4) 2 else 1;
            i += cp_len;
        }
        self.utf8_ix = self.text.len;
    }
};

fn glyphForCharIn(font: cf.CTFontRef, ch: u21) ?types.GlyphId {
    var units: [2]u16 = undefined;
    var n: cf.CFIndex = 1;
    if (ch >= 0x10000) {
        const v = ch - 0x10000;
        units = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) };
        n = 2;
    } else {
        units[0] = @intCast(ch);
    }
    var glyphs: [2]cf.CGGlyph = .{ 0, 0 };
    if (!cf.CTFontGetGlyphsForCharacters(font, &units, &glyphs, n)) return null;
    return if (glyphs[0] == 0) null else glyphs[0];
}

/// Convert premultiplied RGBA to BGRA with straight alpha (gpui `swap_rgba_pa_to_bgra`).
pub fn swapRgbaPremultipliedToBgraStraight(bytes: []u8) void {
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const px = bytes[i..][0..4];
        std.mem.swap(u8, &px[0], &px[2]);
        if (px[3] > 0) {
            const a = @as(f32, @floatFromInt(px[3])) / 255.0;
            for (px[0..3]) |*c| c.* = @intFromFloat(@min(@as(f32, @floatFromInt(c.*)) / a, 255));
        }
    }
}

/// Key identifying a face across CoreText copies: PostScript name plus weight
/// and symbolic traits (variable fonts expose instances under one name).
fn nativeKey(font: cf.CTFontRef, buf: []u8) []const u8 {
    var ps_buf: [256]u8 = undefined;
    const ps_name = cf.CTFontCopyPostScriptName(font);
    defer cf.CFRelease(ps_name);
    const ps = cf.stringToUtf8(ps_name, &ps_buf);
    const p = faceProps(font);
    return std.fmt.bufPrint(buf, "{s}|{d:.0}|{d}|{d:.2}", .{ ps, p.weight, @backingInt(p.style), p.width }) catch ps;
}

/// Weight (CSS) and style of a face from its CoreText traits.
fn faceProps(font: cf.CTFontRef) Props {
    const traits = cf.CTFontCopyTraits(font);
    defer cf.CFRelease(traits);
    const ct_weight = cf.numberValue(cf.CFDictionaryGetValue(traits, cf.kCTFontWeightTrait)) orelse 0;
    const slant = cf.numberValue(cf.CFDictionaryGetValue(traits, cf.kCTFontSlantTrait)) orelse 0;
    const width = cf.numberValue(cf.CFDictionaryGetValue(traits, cf.kCTFontWidthTrait)) orelse 0;
    const symbolic = cf.CTFontGetSymbolicTraits(font);
    const style: types.FontStyle = if (symbolic & cf.kCTFontItalicTrait != 0) .italic else if (@abs(slant) > 0.01) .oblique else .normal;
    return .{ .weight = coreTextWeightToCss(@floatCast(ct_weight)), .style = style, .width = @floatCast(width) };
}

/// Piecewise-linear map between CoreText weight traits (-1..1) and CSS weights (0..1000),
/// at Apple's `NSFont.Weight` / `kCTFontWeight*` stops (ultraLight -0.8 ... medium 0.23,
/// semibold 0.3, bold 0.4, heavy 0.56, black 0.62), which is what CoreText reports for
/// usWeightClass 100..900. font-kit's table (zui) puts 500 at 0.2, so a Medium face (0.23)
/// read as CSS 530 and a 500 request fell back to Regular (SF Pro Medium never rendered).
const ct_weights = [_]f32{ -1.0, -0.8, -0.6, -0.4, 0.0, 0.23, 0.3, 0.4, 0.56, 0.62, 1.0 };

fn coreTextWeightToCss(w: f32) f32 {
    if (w <= ct_weights[0]) return 0;
    for (ct_weights[0 .. ct_weights.len - 1], ct_weights[1..], 0..) |lo, hi, i| {
        if (w <= hi) return (@as(f32, @floatFromInt(i)) + (w - lo) / (hi - lo)) * 100;
    }
    return 1000;
}

fn cssWeightToCoreText(css: f32) f32 {
    const x = std.math.clamp(css / 100, 0, 10);
    const i: usize = @intFromFloat(@min(@floor(x), 9));
    return ct_weights[i] + (ct_weights[i + 1] - ct_weights[i]) * (x - @as(f32, @floatFromInt(i)));
}

/// CSS Fonts 3 §5.2 matching (font-kit `find_best_match`): narrow by stretch (width),
/// then by style preference, then pick the weight by the CSS rules. Without the width
/// step a variable family like SF Pro could resolve to an Expanded/Condensed instance.
fn bestMatch(cands: []const Props, want: Props) usize {
    const width = closestWidth(cands, want.width);
    var narrowed_buf: [512]Props = undefined;
    var index_buf: [512]usize = undefined;
    var n: usize = 0;
    for (cands, 0..) |c, i| if (@abs(c.width - width) < 0.001) {
        narrowed_buf[n] = c;
        index_buf[n] = i;
        n += 1;
    };
    return index_buf[bestMatchSameWidth(narrowed_buf[0..n], want)];
}

/// CSS stretch search: the desired width if present; for normal or narrower requests
/// the closest narrower width, then the closest wider one (the reverse for wider).
fn closestWidth(cands: []const Props, desired: f32) f32 {
    var exact = false;
    var narrower: ?f32 = null;
    var wider: ?f32 = null;
    for (cands) |c| {
        const w = c.width;
        if (@abs(w - desired) < 0.001) exact = true else if (w < desired) {
            if (narrower == null or w > narrower.?) narrower = w;
        } else if (wider == null or w < wider.?) wider = w;
    }
    if (exact) return desired;
    if (desired <= 0) return narrower orelse wider orelse cands[0].width;
    return wider orelse narrower orelse cands[0].width;
}

fn bestMatchSameWidth(cands: []const Props, want: Props) usize {
    const order: [3]types.FontStyle = switch (want.style) {
        .italic => .{ .italic, .oblique, .normal },
        .oblique => .{ .oblique, .italic, .normal },
        .normal => .{ .normal, .oblique, .italic },
    };
    const style = outer: for (order) |s| {
        for (cands) |c| if (c.style == s) break :outer s;
    } else cands[0].style;

    var best: usize = 0;
    var best_score: f32 = std.math.inf(f32);
    for (cands, 0..) |c, i| {
        if (c.style != style) continue;
        const score = weightScore(c.weight, want.weight);
        if (score < best_score) {
            best_score = score;
            best = i;
        }
    }
    return best;
}

/// Lower is better. Tiers encode the CSS search direction for the desired weight.
fn weightScore(w: f32, desired: f32) f32 {
    const d = @abs(w - desired);
    if (desired >= 400 and desired <= 500) {
        if (w >= desired and w <= 500) return d;
        if (w < desired) return 1000 + d;
        return 2000 + d;
    }
    if (desired < 400) return if (w <= desired) d else 1000 + d;
    return if (w >= desired) d else 1000 + d;
}

fn descriptorFamilyIs(desc: cf.CTFontDescriptorRef, name: []const u8) bool {
    const v = cf.CTFontDescriptorCopyAttribute(desc, cf.kCTFontFamilyNameAttribute) orelse return false;
    defer cf.CFRelease(v);
    if (cf.CFGetTypeID(v) != cf.CFStringGetTypeID()) return false;
    var buf: [256]u8 = undefined;
    return std.ascii.eqlIgnoreCase(cf.stringToUtf8(@ptrCast(v), &buf), name);
}

/// All faces of the installed family `name` (font-kit `select_family_by_name`).
fn appendSystemFamily(gpa: Allocator, out: *std.ArrayList(cf.CTFontDescriptorRef), name: []const u8) !void {
    const family = cf.string(name) orelse return;
    defer cf.CFRelease(family);
    const attrs = cf.dictionary(&.{cf.kCTFontFamilyNameAttribute}, &.{family}) orelse return;
    defer cf.CFRelease(attrs);
    const desc = cf.CTFontDescriptorCreateWithAttributes(attrs) orelse return;
    defer cf.CFRelease(desc);
    const mandatory_values = [_]?*const anyopaque{cf.kCTFontFamilyNameAttribute};
    const mandatory = cf.CFSetCreate(null, &mandatory_values, 1, &cf.kCFTypeSetCallBacks) orelse return;
    defer cf.CFRelease(mandatory);

    if (cf.CTFontDescriptorCreateMatchingFontDescriptors(desc, mandatory)) |matches| {
        defer cf.CFRelease(matches);
        const count = cf.CFArrayGetCount(matches);
        try out.ensureUnusedCapacity(gpa, @intCast(count));
        var i: cf.CFIndex = 0;
        while (i < count) : (i += 1) {
            const d: cf.CTFontDescriptorRef = @ptrCast(cf.CFArrayGetValueAtIndex(matches, i).?);
            out.appendAssumeCapacity(@ptrCast(cf.CFRetain(d)));
        }
    }
    if (out.items.len > 0) return;

    // Hidden system families (".AppleSystemUIFont") may not match by family name.
    if (name.len > 0 and name[0] == '.') {
        const ui = cf.CTFontCreateUIFontForLanguage(cf.kCTFontUIFontSystem, 0, null) orelse return;
        defer cf.CFRelease(ui);
        try out.append(gpa, cf.CTFontCopyFontDescriptor(ui));
    }
}

/// zui `apply_features_and_fallbacks`: a descriptor carrying the feature
/// settings and (when fallbacks are given) the cascade list. Null if neither.
fn makeFeatureAndFallbackDescriptor(base: cf.CTFontRef, font: types.Font) ?cf.CTFontDescriptorRef {
    if (font.features.len == 0 and font.fallbacks.len == 0) return null;
    var keys: [2]?*const anyopaque = undefined;
    var values: [2]?*const anyopaque = undefined;
    var n: usize = 0;
    defer for (values[0..n]) |v| cf.CFRelease(v.?);

    if (font.features.len > 0) if (featureArray(font.features)) |arr| {
        keys[n] = cf.kCTFontFeatureSettingsAttribute;
        values[n] = arr;
        n += 1;
    };
    if (font.fallbacks.len > 0) if (fallbackArray(base, font.fallbacks)) |arr| {
        keys[n] = cf.kCTFontCascadeListAttribute;
        values[n] = arr;
        n += 1;
    };
    if (n == 0) return null;
    const attrs = cf.dictionary(keys[0..n], values[0..n]) orelse return null;
    defer cf.CFRelease(attrs);
    return cf.CTFontDescriptorCreateWithAttributes(attrs);
}

fn featureArray(features: []const types.FontFeature) ?cf.CFArrayRef {
    const arr = cf.CFArrayCreateMutable(null, 0, &cf.kCFTypeArrayCallBacks) orelse return null;
    for (features) |f| {
        const tag = cf.string(&f.tag) orelse continue;
        defer cf.CFRelease(tag);
        const value: i32 = @intCast(@min(f.value, std.math.maxInt(i32)));
        const num = cf.CFNumberCreate(null, cf.kCFNumberSInt32Type, &value) orelse continue;
        defer cf.CFRelease(num);
        const dict = cf.dictionary(&.{ cf.kCTFontOpenTypeFeatureTag, cf.kCTFontOpenTypeFeatureValue }, &.{ tag, num }) orelse continue;
        defer cf.CFRelease(dict);
        cf.CFArrayAppendValue(arr, dict);
    }
    return @ptrCast(arr);
}

/// User fallbacks (matching the face's weight and slant), then the system cascade list.
fn fallbackArray(base: cf.CTFontRef, fallbacks: []const []const u8) ?cf.CFArrayRef {
    const arr = cf.CFArrayCreateMutable(null, 0, &cf.kCFTypeArrayCallBacks) orelse return null;
    const props = faceProps(base);
    const weight = cf.number(cssWeightToCoreText(props.weight)) orelse return @ptrCast(arr);
    defer cf.CFRelease(weight);
    const slant = cf.number(if (props.style == .italic) 1.0 else 0.0) orelse return @ptrCast(arr);
    defer cf.CFRelease(slant);
    const traits = cf.dictionary(&.{ cf.kCTFontWeightTrait, cf.kCTFontSlantTrait }, &.{ weight, slant }) orelse return @ptrCast(arr);
    defer cf.CFRelease(traits);
    for (fallbacks) |name| {
        const family = cf.string(name) orelse continue;
        defer cf.CFRelease(family);
        const attrs = cf.dictionary(&.{ cf.kCTFontFamilyNameAttribute, cf.kCTFontTraitsAttribute }, &.{ family, traits }) orelse continue;
        defer cf.CFRelease(attrs);
        const desc = cf.CTFontDescriptorCreateWithAttributes(attrs) orelse continue;
        defer cf.CFRelease(desc);
        cf.CFArrayAppendValue(arr, desc);
    }
    const langs = cf.CFLocaleCopyPreferredLanguages();
    defer if (langs) |l| cf.CFRelease(l);
    if (cf.CTFontCopyDefaultCascadeListForLanguages(base, langs)) |defaults| {
        defer cf.CFRelease(defaults);
        const count = cf.CFArrayGetCount(defaults);
        var i: cf.CFIndex = 0;
        while (i < count) : (i += 1) cf.CFArrayAppendValue(arr, cf.CFArrayGetValueAtIndex(defaults, i));
    }
    return @ptrCast(arr);
}

test "css weight mapping round trips" {
    try std.testing.expectApproxEqAbs(@as(f32, 400), coreTextWeightToCss(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 700), coreTextWeightToCss(0.4), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), cssWeightToCoreText(700), 0.001);
    // Apple's stops: SF Pro Medium / Semibold report 0.23 / 0.3 (NSFont.Weight.medium/.semibold).
    try std.testing.expectApproxEqAbs(@as(f32, 500), coreTextWeightToCss(0.23), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 600), coreTextWeightToCss(0.3), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), coreTextWeightToCss(-0.4), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 900), coreTextWeightToCss(0.62), 0.01);
    for ([_]f32{ 100, 250, 400, 500, 550, 600, 800, 900 }) |w| try std.testing.expectApproxEqAbs(w, coreTextWeightToCss(cssWeightToCoreText(w)), 0.01);
}

test "a 500 request picks the Medium face (CoreText trait 0.23), not Regular" {
    const cands = [_]Props{
        .{ .weight = coreTextWeightToCss(0), .style = .normal },
        .{ .weight = coreTextWeightToCss(0.23), .style = .normal },
        .{ .weight = coreTextWeightToCss(0.3), .style = .normal },
        .{ .weight = coreTextWeightToCss(0.4), .style = .normal },
    };
    try std.testing.expectEqual(@as(usize, 1), bestMatch(&cands, .{ .weight = 500, .style = .normal }));
    try std.testing.expectEqual(@as(usize, 2), bestMatch(&cands, .{ .weight = 600, .style = .normal }));
    try std.testing.expectEqual(@as(usize, 0), bestMatch(&cands, .{ .weight = 400, .style = .normal }));
}

test "best match prefers style then CSS weight order" {
    const cands = [_]Props{
        .{ .weight = 400, .style = .normal },
        .{ .weight = 700, .style = .normal },
        .{ .weight = 400, .style = .italic },
        .{ .weight = 300, .style = .normal },
    };
    try std.testing.expectEqual(@as(usize, 1), bestMatch(&cands, .{ .weight = 700, .style = .normal }));
    try std.testing.expectEqual(@as(usize, 2), bestMatch(&cands, .{ .weight = 700, .style = .italic }));
    try std.testing.expectEqual(@as(usize, 0), bestMatch(&cands, .{ .weight = 500, .style = .normal }));
}

test "best match prefers the normal width of a variable family (SF Pro Expanded/Condensed)" {
    const cands = [_]Props{
        .{ .weight = 400, .style = .normal, .width = 0.4 }, // Expanded Regular
        .{ .weight = 400, .style = .normal, .width = -0.2 }, // Condensed Regular
        .{ .weight = 700, .style = .normal, .width = 0 }, // Bold
        .{ .weight = 400, .style = .normal, .width = 0 }, // Regular
    };
    try std.testing.expectEqual(@as(usize, 3), bestMatch(&cands, .{ .weight = 400, .style = .normal }));
    try std.testing.expectEqual(@as(usize, 2), bestMatch(&cands, .{ .weight = 700, .style = .normal }));
    // No normal width: the closest narrower width wins over a wider one.
    try std.testing.expectEqual(@as(usize, 1), bestMatch(cands[0..2], .{ .weight = 400, .style = .normal }));
    try std.testing.expectEqual(@as(usize, 3), bestMatch(&cands, .{ .weight = 200, .style = .normal }));
}

test "utf16 to utf8 index conversion" {
    var c: IndexConverter = .{ .text = "a😀b" };
    c.advanceToUtf16(1);
    try std.testing.expectEqual(@as(usize, 1), c.utf8_ix);
    c.advanceToUtf16(3);
    try std.testing.expectEqual(@as(usize, 5), c.utf8_ix);
}

test "CoreText end to end (macOS only)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const ts = try create(gpa);
    defer destroy(ts);
    const v = ts.vtable;

    const regular = try v.fontId(ts.ptr, .{ .family = ".SystemUIFont" });
    const bold = try v.fontId(ts.ptr, .{ .family = ".SystemUIFont", .weight = types.weight.bold });
    const helvetica = try v.fontId(ts.ptr, .{ .family = "Helvetica" });
    try std.testing.expectEqual(regular, try v.fontId(ts.ptr, .{ .family = ".SystemUIFont" }));
    _ = bold;

    const m = v.fontMetrics(ts.ptr, helvetica);
    try std.testing.expect(m.units_per_em > 0 and m.ascent > 0 and m.descent < 0);
    const glyph = v.glyphForChar(ts.ptr, helvetica, 'm') orelse return error.NoGlyph;
    try std.testing.expect(v.advance(ts.ptr, helvetica, glyph).width > 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const text = "Hi \u{1F600}!";
    const layout = try v.layoutLine(ts.ptr, arena_state.allocator(), text, 16, &.{.{ .len = text.len, .font_id = helvetica }});
    try std.testing.expect(layout.width > 0 and layout.runs.len >= 2); // emoji falls back to Apple Color Emoji
    var saw_emoji = false;
    var last_index: usize = 0;
    for (layout.runs) |run| for (run.glyphs) |g| {
        saw_emoji = saw_emoji or g.is_emoji;
        try std.testing.expect(g.index <= text.len);
        last_index = @max(last_index, g.index);
    };
    try std.testing.expect(saw_emoji);
    try std.testing.expectEqual(@as(usize, text.len - 1), last_index); // '!' after the 4-byte emoji

    const params: types.RenderGlyphParams = .{
        .font_id = helvetica,
        .glyph_id = glyph,
        .font_size = 16,
        .subpixel_variant_x = 1,
        .subpixel_variant_y = 0,
        .is_emoji = false,
        .subpixel_rendering = false,
        .scale_factor = 2,
    };
    const bounds = try v.glyphRasterBounds(ts.ptr, params);
    try std.testing.expect(bounds.size.width > 2 and bounds.size.height > 2);
    const bitmap = try v.rasterizeGlyph(ts.ptr, gpa, params, bounds);
    defer gpa.free(bitmap);
    // The bitmap must match the raster bounds exactly: the atlas tile is sized from them.
    try std.testing.expectEqual(@as(usize, @intCast(bounds.size.width * bounds.size.height)), bitmap.len);
    // A shifted variant is one pixel wider than the unshifted glyph.
    var p0 = params;
    p0.subpixel_variant_x = 0;
    const b0 = try v.glyphRasterBounds(ts.ptr, p0);
    try std.testing.expectEqual(b0.size.width + 1, bounds.size.width);
    var coverage: u64 = 0;
    for (bitmap) |b| coverage += b;
    try std.testing.expect(coverage > 0);

    // Color emoji rasterizes to BGRA.
    for (layout.runs) |run| for (run.glyphs) |g| if (g.is_emoji) {
        const ep: types.RenderGlyphParams = .{
            .font_id = run.font_id,
            .glyph_id = g.id,
            .font_size = 16,
            .subpixel_variant_x = 0,
            .subpixel_variant_y = 0,
            .is_emoji = true,
            .subpixel_rendering = false,
            .scale_factor = 2,
        };
        const eb = try v.glyphRasterBounds(ts.ptr, ep);
        const ebytes = try v.rasterizeGlyph(ts.ptr, gpa, ep, eb);
        defer gpa.free(ebytes);
        try std.testing.expectEqual(@as(usize, @intCast(eb.size.width * eb.size.height * 4)), ebytes.len);
        var alpha: u64 = 0;
        var i: usize = 3;
        while (i < ebytes.len) : (i += 4) alpha += ebytes[i];
        try std.testing.expect(alpha > 0);
    };
}
test "CoreText raster transforms: identity unchanged, shear widens and stays in bounds (macOS only)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const ts = try create(gpa);
    defer destroy(ts);
    const v = ts.vtable;
    try std.testing.expect(v.raster_transforms);
    const helvetica = try v.fontId(ts.ptr, .{ .family = "Helvetica" });
    const glyph = v.glyphForChar(ts.ptr, helvetica, 'H') orelse return error.NoGlyph;
    for ([_]u8{ 0, 1, 3 }) |variant| {
        const plain: types.RenderGlyphParams = .{ .font_id = helvetica, .glyph_id = glyph, .font_size = 24, .subpixel_variant_x = variant, .subpixel_variant_y = 0, .is_emoji = false, .subpixel_rendering = false, .scale_factor = 2 };
        // An explicit identity is the untransformed path, byte for byte.
        var ident = plain;
        ident.raster_transform = .{ .a = 1, .b = -0.0, .c = -0.0, .d = 1 };
        const b0 = try v.glyphRasterBounds(ts.ptr, plain);
        try std.testing.expectEqual(b0, try v.glyphRasterBounds(ts.ptr, ident));
        const bm0 = try v.rasterizeGlyph(ts.ptr, gpa, plain, b0);
        defer gpa.free(bm0);
        const bm1 = try v.rasterizeGlyph(ts.ptr, gpa, ident, b0);
        defer gpa.free(bm1);
        try std.testing.expectEqualSlices(u8, bm0, bm1);

        // Shear: up leans right by 0.6 per unit; the bitmap fits its bounds with ink inside.
        var sheared = plain;
        sheared.raster_transform = types.RasterTransform.fromBasis(.{ 1, 0 }, .{ 0.6, -1 });
        const bs = try v.glyphRasterBounds(ts.ptr, sheared);
        try std.testing.expect(bs.size.width > b0.size.width);
        const bms = try v.rasterizeGlyph(ts.ptr, gpa, sheared, bs);
        defer gpa.free(bms);
        try std.testing.expectEqual(@as(usize, @intCast(bs.size.width * bs.size.height)), bms.len);
        const w: usize = @intCast(bs.size.width);
        const h: usize = @intCast(bs.size.height);
        var ink: u64 = 0;
        for (0..h) |y| for (0..w) |x| {
            ink += bms[y * w + x];
            // The 1px margin stays clear (nothing clipped at the tile edge).
            if (x == 0 or y == 0 or x == w - 1 or y == h - 1) try std.testing.expect(bms[y * w + x] < 32);
        };
        try std.testing.expect(ink > 0);
        // Top rows lean right of the bottom rows.
        try std.testing.expect(inkCenterX(bms[0 .. w * (h / 3)], w) > inkCenterX(bms[w * (2 * h / 3) ..], w) + 2);
    }
}

fn inkCenterX(rows: []const u8, w: usize) f64 {
    var sum: f64 = 0;
    var total: f64 = 0;
    for (rows, 0..) |c, i| {
        sum += @as(f64, @floatFromInt(c)) * @as(f64, @floatFromInt(i % w));
        total += @floatFromInt(c);
    }
    return if (total == 0) 0 else sum / total;
}

/// CTLine width of `text` in `font` (test helper).
fn testLineWidth(font: cf.CTFontRef, text: []const u8) !f32 {
    const astr = cf.CFAttributedStringCreateMutable(null, 0) orelse return error.OutOfMemory;
    defer cf.CFRelease(astr);
    const s = cf.string(text) orelse return error.OutOfMemory;
    defer cf.CFRelease(s);
    cf.CFAttributedStringReplaceString(astr, .{ .location = 0, .length = 0 }, s);
    cf.CFAttributedStringSetAttribute(astr, .{ .location = 0, .length = cf.CFAttributedStringGetLength(astr) }, cf.kCTFontAttributeName, font);
    const line = cf.CTLineCreateWithAttributedString(@ptrCast(astr)) orelse return error.ShapingFailed;
    defer cf.CFRelease(line);
    return @floatCast(cf.CTLineGetTypographicBounds(line, null, null, null));
}

test "the system font lays out like AppKit's at every size and weight (optical size + tracking; macOS only)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const ts = try create(gpa);
    defer destroy(ts);
    const v = ts.vtable;
    const sample = "Hamburgefonstiv quick brown fox 0123456789";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // AppKit's `NSFont.systemFont(ofSize:weight:)` descriptors.
    const weights = [_]struct { css: f32, usage: []const u8 }{
        .{ .css = 400, .usage = "CTFontRegularUsage" },
        .{ .css = 500, .usage = "CTFontMediumUsage" },
        .{ .css = 600, .usage = "CTFontDemiUsage" },
        .{ .css = 700, .usage = "CTFontBoldUsage" },
    };
    const key = cf.string("NSCTFontUIUsageAttribute") orelse return error.OutOfMemory;
    defer cf.CFRelease(key);
    for (weights) |wt| {
        const id = try v.fontId(ts.ptr, .{ .family = ".SystemUIFont", .weight = wt.css });
        const value = cf.string(wt.usage) orelse return error.OutOfMemory;
        defer cf.CFRelease(value);
        const dict = cf.dictionary(&.{key}, &.{value}) orelse return error.OutOfMemory;
        defer cf.CFRelease(dict);
        const desc = cf.CTFontDescriptorCreateWithAttributes(dict) orelse return error.NoSystemFont;
        defer cf.CFRelease(desc);
        for ([_]f32{ 11, 13, 20, 28 }) |size| {
            const layout = try v.layoutLine(ts.ptr, arena_state.allocator(), sample, size, &.{.{ .len = sample.len, .font_id = id }});
            const native = cf.CTFontCreateWithFontDescriptor(desc, size, null) orelse return error.NoSystemFont;
            defer cf.CFRelease(native);
            try std.testing.expectApproxEqAbs(try testLineWidth(native, sample), layout.width, 0.5);
            // Shaped glyphs stay on the system face (not a re-registered copy).
            try std.testing.expectEqual(id, layout.runs[0].font_id);
        }
    }
}

test "adjacent runs on the same face still don't ligate across the boundary (macOS only)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const ts = try create(gpa);
    defer destroy(ts);
    const v = ts.vtable;
    const font = try v.fontId(ts.ptr, .{ .family = "Helvetica" });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // "fi" ligates in one run; split between "f" and "i" it must shape as two glyphs.
    const whole = try v.layoutLine(ts.ptr, arena_state.allocator(), "fi", 20, &.{.{ .len = 2, .font_id = font }});
    const split = try v.layoutLine(ts.ptr, arena_state.allocator(), "fi", 20, &.{ .{ .len = 1, .font_id = font }, .{ .len = 1, .font_id = font } });
    var n_whole: usize = 0;
    for (whole.runs) |r| n_whole += r.glyphs.len;
    var n_split: usize = 0;
    for (split.runs) |r| n_split += r.glyphs.len;
    // 1 where the face has an fi ligature, else 2; split, it is always two glyphs.
    try std.testing.expect(n_whole == 1 or n_whole == 2);
    try std.testing.expectEqual(@as(usize, 2), n_split);
}
