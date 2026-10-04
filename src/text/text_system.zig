//! Platform-independent text system core (gpui `text_system.rs`): font resolution,
//! metrics and raster-bounds caches, line-wrapper pool, and the per-window
//! `WindowTextSystem` that shapes lines through the two-frame layout cache.
//!
//! Not thread-safe: use from the main thread (gpui guards these with locks).

const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const atlas_mod = @import("../atlas.zig");
const line_layout = @import("line_layout.zig");
const line_wrapper = @import("line_wrapper.zig");
const line_mod = @import("line.zig");
const fallback = @import("fallback.zig");

const Allocator = std.mem.Allocator;
const Pixels = types.Pixels;
const DevicePixels = geometry.DevicePixels;
const Font = types.Font;
const FontId = types.FontId;
const FontRun = types.FontRun;
const FontMetrics = types.FontMetrics;
const TextRun = types.TextRun;
const RenderGlyphParams = types.RenderGlyphParams;
const LineWrapper = line_wrapper.LineWrapper;
const ShapedLine = line_mod.ShapedLine;
const WrappedLine = line_mod.WrappedLine;
const DecorationRun = line_mod.DecorationRun;

/// Convenience constructor (gpui `font(family)`).
pub fn font(family: []const u8) Font {
    return .{ .family = family };
}

/// gpui's default fallback font stack, tried in order when a font fails to resolve.
pub const default_fallback_stack = [_]Font{
    font(".ZedMono"),     font(".ZedSans"),  font("Helvetica"),   font("Segoe UI"),
    font("Ubuntu"),       font("Adwaita Sans"), font("Cantarell"), font("Noto Sans"),
    font("DejaVu Sans"),  font("Arial"),     font("sans-serif"),
};

// Font metric helpers (gpui `FontMetrics::ascent(font_size)` etc.).
pub fn scaleMetric(m: FontMetrics, value: f32, font_size: Pixels) Pixels {
    return value / @as(f32, @floatFromInt(m.units_per_em)) * font_size;
}

pub const RasterizedGlyph = struct {
    bounds: geometry.Bounds(DevicePixels),
    /// 1 byte/px (mono) or 4 bytes/px (emoji BGRA straight alpha, subpixel BGRA coverage). Caller frees.
    bytes: []u8,
};

pub const TextSystem = struct {
    gpa: Allocator,
    platform: platform.TextSystem,
    font_ids_by_font: std.HashMapUnmanaged(Font, ?FontId, FontContext, std.hash_map.default_max_load_percentage) = .empty,
    font_metrics: std.AutoHashMapUnmanaged(FontId, FontMetrics) = .empty,
    raster_bounds: std.HashMapUnmanaged(RenderGlyphParams, geometry.Bounds(DevicePixels), ParamsContext, std.hash_map.default_max_load_percentage) = .empty,
    wrapper_pool: std.AutoHashMapUnmanaged(WrapperKey, std.ArrayList(*LineWrapper)) = .empty,
    fallback_font_stack: []const Font = &default_fallback_stack,

    const WrapperKey = struct { font_id: FontId, font_size_bits: u32 };

    pub fn init(gpa: Allocator, platform_text_system: platform.TextSystem) TextSystem {
        return .{ .gpa = gpa, .platform = platform_text_system };
    }

    pub fn deinit(self: *TextSystem) void {
        var it = self.font_ids_by_font.keyIterator();
        while (it.next()) |k| freeFont(self.gpa, k.*);
        self.font_ids_by_font.deinit(self.gpa);
        self.font_metrics.deinit(self.gpa);
        self.raster_bounds.deinit(self.gpa);
        var wit = self.wrapper_pool.valueIterator();
        while (wit.next()) |list| {
            for (list.items) |w| {
                w.deinit();
                self.gpa.destroy(w);
            }
            list.deinit(self.gpa);
        }
        self.wrapper_pool.deinit(self.gpa);
    }

    /// Register font bytes (must outlive the text system).
    pub fn addFont(self: *TextSystem, bytes: []const u8) !void {
        try self.platform.vtable.addFont(self.platform.ptr, bytes);
    }

    /// Resolve `f` exactly (cached, including failures).
    pub fn fontId(self: *TextSystem, f: Font) !FontId {
        if (self.font_ids_by_font.get(f)) |cached| return cached orelse error.FontNotFound;
        const result: ?FontId = self.platform.vtable.fontId(self.platform.ptr, f) catch null;
        const owned = try dupeFont(self.gpa, f);
        self.font_ids_by_font.put(self.gpa, owned, result) catch |err| {
            freeFont(self.gpa, owned);
            return err;
        };
        return result orelse error.FontNotFound;
    }

    /// Reverse lookup of a resolved font.
    pub fn fontForId(self: *TextSystem, id: FontId) ?Font {
        var it = self.font_ids_by_font.iterator();
        while (it.next()) |e| if (e.value_ptr.* == id) return e.key_ptr.*;
        return null;
    }

    /// gpui `resolve_font`: `f`, else the first resolvable font in the fallback stack.
    pub fn resolveFont(self: *TextSystem, f: Font) !FontId {
        if (self.fontId(f)) |id| return id else |_| {}
        for (self.fallback_font_stack) |fb| {
            if (self.fontId(fb)) |id| return id else |_| {}
        }
        return error.FontNotFound;
    }

    pub fn fontMetrics(self: *TextSystem, id: FontId) FontMetrics {
        if (self.font_metrics.get(id)) |m| return m;
        const m = self.platform.vtable.fontMetrics(self.platform.ptr, id);
        self.font_metrics.put(self.gpa, id, m) catch {};
        return m;
    }

    pub fn unitsPerEm(self: *TextSystem, id: FontId) u32 {
        return self.fontMetrics(id).units_per_em;
    }
    pub fn ascent(self: *TextSystem, id: FontId, font_size: Pixels) Pixels {
        const m = self.fontMetrics(id);
        return scaleMetric(m, m.ascent, font_size);
    }
    /// Font descent scaled to `font_size`; negative (below the baseline), as in gpui.
    pub fn descent(self: *TextSystem, id: FontId, font_size: Pixels) Pixels {
        const m = self.fontMetrics(id);
        return scaleMetric(m, m.descent, font_size);
    }
    pub fn capHeight(self: *TextSystem, id: FontId, font_size: Pixels) Pixels {
        const m = self.fontMetrics(id);
        return scaleMetric(m, m.cap_height, font_size);
    }
    pub fn xHeight(self: *TextSystem, id: FontId, font_size: Pixels) Pixels {
        const m = self.fontMetrics(id);
        return scaleMetric(m, m.x_height, font_size);
    }
    pub fn boundingBox(self: *TextSystem, id: FontId, font_size: Pixels) geometry.Bounds(Pixels) {
        const m = self.fontMetrics(id);
        const s = font_size / @as(f32, @floatFromInt(m.units_per_em));
        return m.bounding_box.scale(s);
    }

    /// gpui `baseline_offset`: y of the baseline within a line box of `line_height`.
    pub fn baselineOffset(self: *TextSystem, id: FontId, font_size: Pixels, line_height: Pixels) Pixels {
        const a = self.ascent(id, font_size);
        const d = self.descent(id, font_size);
        return (line_height - a - d) / 2 + a;
    }

    /// Advance of `ch` from the font's horizontal metrics (unshaped).
    pub fn advance(self: *TextSystem, id: FontId, font_size: Pixels, ch: u21) !geometry.Size(Pixels) {
        const glyph = self.platform.vtable.glyphForChar(self.platform.ptr, id, ch) orelse return error.GlyphNotFound;
        const adv = self.platform.vtable.advance(self.platform.ptr, id, glyph);
        const s = font_size / @as(f32, @floatFromInt(self.unitsPerEm(id)));
        return .{ .width = adv.width * s, .height = adv.height * s };
    }

    /// Advance width of 'm' (gpui `em_advance`; also `em_width`, which on Linux is the same).
    pub fn emAdvance(self: *TextSystem, id: FontId, font_size: Pixels) !Pixels {
        return (try self.advance(id, font_size, 'm')).width;
    }
    pub fn emWidth(self: *TextSystem, id: FontId, font_size: Pixels) !Pixels {
        return self.emAdvance(id, font_size);
    }
    pub fn chAdvance(self: *TextSystem, id: FontId, font_size: Pixels) !Pixels {
        return (try self.advance(id, font_size, '0')).width;
    }

    /// Shaped width of a single character (uncached; used by `LineWrapper`).
    pub fn layoutWidth(self: *TextSystem, id: FontId, font_size: Pixels, ch: u21) Pixels {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &buf) catch return 0;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const run = [_]FontRun{.{ .len = n, .font_id = id }};
        const layout = self.platform.vtable.layoutLine(self.platform.ptr, arena.allocator(), buf[0..n], font_size, &run) catch return 0;
        return layout.width;
    }

    /// Borrow a pooled line wrapper; give it back with `releaseLineWrapper`.
    pub fn lineWrapper(self: *TextSystem, f: Font, font_size: Pixels) !*LineWrapper {
        const id = try self.resolveFont(f);
        const gop = try self.wrapper_pool.getOrPut(self.gpa, .{ .font_id = id, .font_size_bits = @bitCast(font_size) });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (gop.value_ptr.pop()) |w| return w;
        const w = try self.gpa.create(LineWrapper);
        w.* = .init(self, id, font_size);
        return w;
    }

    pub fn releaseLineWrapper(self: *TextSystem, w: *LineWrapper) void {
        const list = self.wrapper_pool.getPtr(.{ .font_id = w.font_id, .font_size_bits = @bitCast(w.font_size) }).?;
        list.append(self.gpa, w) catch {
            w.deinit();
            self.gpa.destroy(w);
        };
    }

    /// Rasterized bounds of a glyph relative to its integer device origin (cached).
    pub fn rasterBounds(self: *TextSystem, params: RenderGlyphParams) !geometry.Bounds(DevicePixels) {
        if (self.raster_bounds.get(params)) |b| return b;
        const b = try self.platform.vtable.glyphRasterBounds(self.platform.ptr, params);
        try self.raster_bounds.put(self.gpa, params, b);
        return b;
    }

    pub fn rasterizeGlyph(self: *TextSystem, gpa: Allocator, params: RenderGlyphParams) !RasterizedGlyph {
        const bounds = try self.rasterBounds(params);
        const bytes = try self.platform.vtable.rasterizeGlyph(self.platform.ptr, gpa, params, bounds);
        return .{ .bounds = bounds, .bytes = bytes };
    }

    /// Glyph tile plus sprite bounds, for a Window's `GlyphPainter` implementation.
    pub const GlyphSprite = struct {
        tile: atlas_mod.AtlasTile,
        /// Device-pixel sprite bounds (`origin + raster bounds origin`, tile size).
        bounds: geometry.Bounds(geometry.ScaledPixels),
    };

    /// Look up (or rasterize and insert) the atlas tile for `params`; null for empty glyphs.
    /// `origin` is the integer device origin passed to `GlyphPainter.paintGlyph/paintEmoji`.
    pub fn rasterizeToAtlas(self: *TextSystem, atlas: *atlas_mod.Atlas, params: RenderGlyphParams, origin: geometry.Point(geometry.ScaledPixels)) !?GlyphSprite {
        const rb = try self.rasterBounds(params);
        if (rb.size.width <= 0 or rb.size.height <= 0) return null;
        const Builder = struct {
            ts: *TextSystem,
            params: RenderGlyphParams,
            bytes: ?[]u8 = null,
            pub fn build(b: *@This()) !?atlas_mod.BuiltTile {
                const r = try b.ts.rasterizeGlyph(b.ts.gpa, b.params);
                b.bytes = r.bytes;
                // A backend whose bitmap disagrees with its raster bounds would upload a sheared
                // tile; drop the glyph loudly instead (this hid a CoreText subpixel-variant bug).
                const bpp: usize = if (b.params.is_emoji or b.params.subpixel_rendering) 4 else 1;
                const want = @as(usize, @intCast(r.bounds.size.width)) * @as(usize, @intCast(r.bounds.size.height)) * bpp;
                if (r.bytes.len != want) {
                    std.log.scoped(.text).err("glyph {d} bitmap is {d} bytes, raster bounds need {d}; skipping", .{ b.params.glyph_id, r.bytes.len, want });
                    return null;
                }
                return .{ .size = r.bounds.size, .bytes = r.bytes };
            }
        };
        var builder: Builder = .{ .ts = self, .params = params };
        defer if (builder.bytes) |b| self.gpa.free(b);
        const tile = (try atlas.getOrInsertWith(atlasKey(params), &builder)) orelse return null;
        return .{
            .tile = tile,
            .bounds = .{
                .origin = .{ .x = origin.x + @as(f32, @floatFromInt(rb.origin.x)), .y = origin.y + @as(f32, @floatFromInt(rb.origin.y)) },
                .size = .{ .width = @floatFromInt(tile.bounds.size.width), .height = @floatFromInt(tile.bounds.size.height) },
            },
        };
    }
};

/// Atlas key for a glyph raster.
pub fn atlasKey(p: RenderGlyphParams) atlas_mod.AtlasKey {
    var k = atlas_mod.GlyphKey.init(@intFromEnum(p.font_id), p.glyph_id, p.font_size, p.scale_factor);
    k.subpixel_variant = .{ p.subpixel_variant_x, p.subpixel_variant_y };
    k.is_emoji = p.is_emoji;
    k.subpixel_rendering = p.subpixel_rendering;
    return .{ .glyph = k };
}

const ParamsContext = struct {
    pub fn hash(_: ParamsContext, p: RenderGlyphParams) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&p));
    }
    pub fn eql(_: ParamsContext, a: RenderGlyphParams, b: RenderGlyphParams) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }
};

pub const FontContext = struct {
    pub fn hash(_: FontContext, f: Font) u64 {
        var h = std.hash.Wyhash.init(0);
        f.hash(&h);
        return h.final();
    }
    pub fn eql(_: FontContext, a: Font, b: Font) bool {
        return fontEql(a, b);
    }
};

pub fn fontEql(a: Font, b: Font) bool {
    if (!std.mem.eql(u8, a.family, b.family) or a.weight != b.weight or a.style != b.style) return false;
    if (a.features.len != b.features.len or a.fallbacks.len != b.fallbacks.len) return false;
    for (a.features, b.features) |x, y| if (!std.mem.eql(u8, &x.tag, &y.tag) or x.value != y.value) return false;
    for (a.fallbacks, b.fallbacks) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub fn dupeFont(gpa: Allocator, f: Font) !Font {
    const family = try gpa.dupe(u8, f.family);
    errdefer gpa.free(family);
    const features = try gpa.dupe(types.FontFeature, f.features);
    errdefer gpa.free(features);
    const fallbacks = try gpa.alloc([]const u8, f.fallbacks.len);
    var n: usize = 0;
    errdefer {
        for (fallbacks[0..n]) |s| gpa.free(s);
        gpa.free(fallbacks);
    }
    for (f.fallbacks) |s| {
        fallbacks[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return .{ .family = family, .weight = f.weight, .style = f.style, .features = features, .fallbacks = fallbacks };
}

pub fn freeFont(gpa: Allocator, f: Font) void {
    gpa.free(f.family);
    gpa.free(f.features);
    for (f.fallbacks) |s| gpa.free(s);
    gpa.free(f.fallbacks);
}

// ---------------------------------------------------------------------------
// WindowTextSystem
// ---------------------------------------------------------------------------

/// Truncation request for `WindowTextSystem.shapeText` (gpui `TextOverflow`).
pub const Truncation = struct {
    /// Maximum width of the truncated text (with `line_clamp`, usually wrap_width * lines).
    width: Pixels,
    affix: []const u8 = "…",
    from: line_wrapper.TruncateFrom = .end,
    /// Line height used to check whether the untruncated text already fits.
    line_height: Pixels = 0,
};

pub const ShapeTextOptions = struct {
    wrap_width: ?Pixels = null,
    line_clamp: ?usize = null,
    truncate: ?Truncation = null,
};

/// gpui `WindowTextSystem`: the per-window front end with the line layout cache.
pub const WindowTextSystem = struct {
    text_system: *TextSystem,
    cache: line_layout.LineLayoutCache,

    pub fn init(text_system: *TextSystem) WindowTextSystem {
        return .{ .text_system = text_system, .cache = .init(text_system.gpa, text_system.platform) };
    }

    pub fn deinit(self: *WindowTextSystem) void {
        self.cache.deinit();
    }

    fn gpa(self: *WindowTextSystem) Allocator {
        return self.text_system.gpa;
    }

    pub fn finishFrame(self: *WindowTextSystem) void {
        self.cache.finishFrame();
    }
    pub fn layoutIndex(self: *WindowTextSystem) line_layout.LineLayoutIndex {
        return self.cache.layoutIndex();
    }
    pub fn reuseLayouts(self: *WindowTextSystem, start: line_layout.LineLayoutIndex, end: line_layout.LineLayoutIndex) !void {
        try self.cache.reuseLayouts(start, end);
    }
    pub fn truncateLayouts(self: *WindowTextSystem, index: line_layout.LineLayoutIndex) void {
        self.cache.truncateLayouts(index);
    }

    /// gpui `shape_line`: shape a single line (no '\n') for painting. Caller `deinit`s the result.
    pub fn shapeLine(self: *WindowTextSystem, text: []const u8, font_size: Pixels, runs: []const TextRun, force_width: ?Pixels) !ShapedLine {
        std.debug.assert(std.mem.indexOfScalar(u8, text, '\n') == null);
        const decorations = try decorationRuns(self.gpa(), runs);
        errdefer self.gpa().free(decorations);
        const owned_text = try self.gpa().dupe(u8, text);
        errdefer self.gpa().free(owned_text);
        const layout = try self.layoutLine(text, font_size, runs, force_width);
        return .{ .layout = layout, .text = owned_text, .decoration_runs = decorations };
    }

    /// gpui `shape_line_by_hash`: like `shapeLine` keyed by a caller content hash; `materialize.text()`
    /// supplies the text only on a cache miss. The result's `text` is empty.
    pub fn shapeLineByHash(self: *WindowTextSystem, text_hash: u64, text_len: usize, font_size: Pixels, runs: []const TextRun, force_width: ?Pixels, materialize: anytype) !ShapedLine {
        const decorations = try decorationRuns(self.gpa(), runs);
        errdefer self.gpa().free(decorations);
        const font_runs = try self.fontRuns(runs);
        defer self.gpa().free(font_runs);
        const layout = try self.cache.layoutLineByHash(text_hash, text_len, font_size, font_runs, force_width, materialize);
        return .{ .layout = layout, .text = try self.gpa().alloc(u8, 0), .decoration_runs = decorations };
    }

    /// gpui `layout_line`: shaped (cached) unwrapped layout. Caller releases the reference.
    pub fn layoutLine(self: *WindowTextSystem, text: []const u8, font_size: Pixels, runs: []const TextRun, force_width: ?Pixels) !*line_layout.SharedLineLayout {
        const font_runs = try self.fontRuns(runs);
        defer self.gpa().free(font_runs);
        return self.cache.layoutLine(text, font_size, font_runs, force_width);
    }

    /// Font runs from text runs; adjacent runs merge unless font or (non-background) decoration changes.
    fn fontRuns(self: *WindowTextSystem, runs: []const TextRun) ![]FontRun {
        var out: std.ArrayList(FontRun) = .empty;
        errdefer out.deinit(self.gpa());
        var last: ?TextRun = null;
        for (runs) |run| {
            const decoration_changed = if (last) |l|
                !(l.color.eql(run.color) and std.meta.eql(l.underline, run.underline) and std.meta.eql(l.strikethrough, run.strikethrough))
            else
                true;
            if (decoration_changed) last = run;
            const id = try self.text_system.resolveFont(run.font);
            if (out.items.len > 0 and out.items[out.items.len - 1].font_id == id and !decoration_changed) {
                out.items[out.items.len - 1].len += run.len;
            } else try out.append(self.gpa(), .{ .len = run.len, .font_id = id });
        }
        return out.toOwnedSlice(self.gpa());
    }

    /// gpui `shape_text` (plus the text element's truncation step): split on '\n', soft-wrap
    /// each paragraph at `wrap_width`, clamp to `line_clamp` lines and optionally truncate
    /// with an ellipsis. Free the result with `freeLines`.
    pub fn shapeText(self: *WindowTextSystem, text: []const u8, font_size: Pixels, runs: []const TextRun, options: ShapeTextOptions) ![]WrappedLine {
        if (options.truncate) |t| if (runs.len > 0) {
            if (try self.truncateText(text, font_size, runs, options, t)) |tr| {
                defer tr.deinit(self.gpa());
                return self.shapeTextImpl(tr.text, font_size, tr.runs, options.wrap_width, options.line_clamp);
            }
        };
        return self.shapeTextImpl(text, font_size, runs, options.wrap_width, options.line_clamp);
    }

    fn truncateText(self: *WindowTextSystem, text: []const u8, font_size: Pixels, runs: []const TextRun, options: ShapeTextOptions, t: Truncation) !?LineWrapper.Truncated {
        const wrapper = try self.text_system.lineWrapper(runs[0].font, font_size);
        defer self.text_system.releaseLineWrapper(wrapper);
        if (options.line_clamp) |max_lines| if (options.wrap_width) |ww| {
            return wrapper.truncateWrappedLine(self.gpa(), text, ww, max_lines, t.affix, runs, t.from);
        };
        // Skip truncation when the honestly shaped text already fits (per-char sums overestimate).
        const unclipped = try self.shapeTextImpl(text, font_size, runs, null, null);
        defer freeLines(self.gpa(), unclipped);
        var fits = true;
        for (unclipped) |l| fits = fits and l.size(t.line_height).width <= t.width;
        if (fits) return null;
        return wrapper.truncateLine(self.gpa(), text, t.width, t.affix, runs, t.from);
    }

    fn shapeTextImpl(self: *WindowTextSystem, text: []const u8, font_size: Pixels, runs_in: []const TextRun, wrap_width: ?Pixels, line_clamp: ?usize) ![]WrappedLine {
        const alloc = self.gpa();
        // Mutable copy of non-empty runs; lengths are consumed as lines are processed.
        var runs: std.ArrayList(TextRun) = .empty;
        defer runs.deinit(alloc);
        for (runs_in) |r| if (r.len > 0) try runs.append(alloc, r);
        var run_ix: usize = 0;

        var lines: std.ArrayList(WrappedLine) = .empty;
        errdefer {
            for (lines.items) |l| l.deinit(alloc);
            lines.deinit(alloc);
        }
        var font_runs: std.ArrayList(FontRun) = .empty;
        defer font_runs.deinit(alloc);
        var decorations: std.ArrayList(DecorationRun) = .empty;
        defer decorations.deinit(alloc);
        var wrapped_lines: usize = 0;

        var line_start: usize = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
            const line_end = nl orelse text.len;
            font_runs.clearRetainingCapacity();
            decorations.clearRetainingCapacity();

            var run_start = line_start;
            while (run_start < line_end) {
                if (run_ix >= runs.items.len) {
                    std.log.warn("TextRuns do not cover the entire text to be shaped", .{});
                    break;
                }
                const run = &runs.items[run_ix];
                const len_in_line = @min(line_end - run_start, run.len);
                var decoration_changed = true;
                if (decorations.items.len > 0) {
                    const last = &decorations.items[decorations.items.len - 1];
                    if (last.sameStyle(run.*)) {
                        last.len += @intCast(len_in_line);
                        decoration_changed = false;
                    }
                }
                if (decoration_changed) try decorations.append(alloc, .{
                    .len = @intCast(len_in_line),
                    .color = run.color,
                    .background_color = run.background_color,
                    .underline = run.underline,
                    .strikethrough = run.strikethrough,
                });
                const id = try self.text_system.resolveFont(run.font);
                if (font_runs.items.len > 0 and font_runs.items[font_runs.items.len - 1].font_id == id and !decoration_changed) {
                    font_runs.items[font_runs.items.len - 1].len += len_in_line;
                } else try font_runs.append(alloc, .{ .len = len_in_line, .font_id = id });
                run.len -= len_in_line;
                if (run.len == 0) run_ix += 1;
                run_start += len_in_line;
            }

            const line_text = text[line_start..line_end];
            const max_lines: ?usize = if (line_clamp) |m| m -| wrapped_lines else null;
            const layout = try self.cache.layoutWrappedLine(line_text, font_size, font_runs.items, wrap_width, max_lines);
            errdefer layout.release();
            wrapped_lines += layout.wrap_boundaries.len;
            const owned_text = try alloc.dupe(u8, line_text);
            errdefer alloc.free(owned_text);
            const owned_decorations = try alloc.dupe(DecorationRun, decorations.items);
            errdefer alloc.free(owned_decorations);
            try lines.append(alloc, .{ .layout = layout, .text = owned_text, .decoration_runs = owned_decorations });

            // Skip the '\n'.
            if (run_ix < runs.items.len and nl != null) {
                runs.items[run_ix].len -= 1;
                if (runs.items[run_ix].len == 0) run_ix += 1;
            }
            if (nl) |i| line_start = i + 1 else break;
        }
        return lines.toOwnedSlice(alloc);
    }
};

pub fn freeLines(gpa: Allocator, lines: []const WrappedLine) void {
    for (lines) |l| l.deinit(gpa);
    gpa.free(lines);
}

fn decorationRuns(gpa: Allocator, runs: []const TextRun) ![]DecorationRun {
    var out: std.ArrayList(DecorationRun) = .empty;
    errdefer out.deinit(gpa);
    for (runs) |run| {
        if (out.items.len > 0 and out.items[out.items.len - 1].sameStyle(run)) {
            out.items[out.items.len - 1].len += @intCast(run.len);
            continue;
        }
        try out.append(gpa, .{
            .len = @intCast(run.len),
            .color = run.color,
            .background_color = run.background_color,
            .underline = run.underline,
            .strikethrough = run.strikethrough,
        });
    }
    return out.toOwnedSlice(gpa);
}
