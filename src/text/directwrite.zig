//! Windows platform text system on DirectWrite: font matching (system collection +
//! fonts registered with `addFont`, loaded through the in-memory font file loader),
//! shaping (IDWriteTextAnalyzer script itemization, GetGlyphs / GetGlyphPlacements with
//! OpenType features), per-character fallback (IDWriteFontFallback, the system's own
//! fallback chain), and rasterization through IDWriteGlyphRunAnalysis (grayscale
//! natural-symmetric antialiasing, 4 horizontal subpixel variants). Color fonts (Segoe
//! UI Emoji's COLR layers) rasterize by compositing each color layer into straight-alpha
//! BGRA. Mirrors the FreeType backend's structure (src/text/freetype.zig).
//!
//! Not thread-safe: the core serializes access. Scratch buffers are reused across calls,
//! so steady-state shaping allocates only the result in the caller's arena.

const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const fallback = @import("fallback.zig");
const w = @import("../platform/windows/win32.zig");
const dw = @import("../platform/windows/dwrite.zig");

const Allocator = std.mem.Allocator;
const FontId = types.FontId;
const Pixels = types.Pixels;
const DevicePixels = geometry.DevicePixels;
const log = std.log.scoped(.directwrite);

/// Create the DirectWrite backend (see `text.createPlatformTextSystem`).
pub fn create(gpa: Allocator) !platform.TextSystem {
    const self = try DirectWriteTextSystem.create(gpa);
    return self.textSystem();
}

pub fn destroy(ts: platform.TextSystem) void {
    DirectWriteTextSystem.fromPtr(ts.ptr).destroy();
}

/// A font registered with `addFont` (bytes borrowed for the text system's lifetime).
const MemoryFace = struct {
    /// Lowercased family names (name IDs 1 and 16).
    families: [][]u8,
    bytes: []const u8,
    index: u32,
    weight: f32,
    italic: bool,
};

const Face = struct {
    face: *dw.IDWriteFontFace,
    /// UTF-16 family name for IDWriteFontFallback (system faces); empty for memory faces.
    family_w: [:0]u16,
    features: []dw.DWRITE_FONT_FEATURE,
    fallback_chain: []FontId,
    is_color: bool,
    weight: f32,
    italic: bool,
    upem: f32,
    metrics: types.FontMetrics,
};

pub const DirectWriteTextSystem = struct {
    gpa: Allocator,
    factory: *dw.IDWriteFactory,
    /// IDWriteFactory5 (Windows 10 1703+): in-memory font files. Null on older systems.
    factory5: ?*dw.IDWriteFactory = null,
    memory_loader: ?*dw.IDWriteInMemoryFontFileLoader = null,
    system: *dw.IDWriteFontCollection,
    analyzer: *dw.IDWriteTextAnalyzer,
    font_fallback: ?*dw.IDWriteFontFallback = null,
    faces: std.ArrayList(*Face) = .empty,
    memory_faces: std.ArrayList(MemoryFace) = .empty,
    /// Hash of (source, features, fallbacks) -> loaded face.
    loaded: std.AutoHashMapUnmanaged(u64, FontId) = .empty,
    fallback_cache: std.AutoHashMapUnmanaged(FallbackKey, ?FontId) = .empty,
    emoji_font: ??FontId = null,
    // Scratch (reused across calls).
    utf16: std.ArrayList(u16) = .empty,
    utf8_index: std.ArrayList(u32) = .empty,
    script_runs: std.ArrayList(dw.ScriptRun) = .empty,
    cluster_map: std.ArrayList(u16) = .empty,
    text_props: std.ArrayList(u16) = .empty,
    glyph_ids: std.ArrayList(u16) = .empty,
    glyph_props: std.ArrayList(u16) = .empty,
    advances: std.ArrayList(f32) = .empty,
    offsets: std.ArrayList(dw.DWRITE_GLYPH_OFFSET) = .empty,
    spans: std.ArrayList(fallback.RunSpan) = .empty,
    segments: std.ArrayList(Segment) = .empty,

    const FallbackKey = struct { cp: u21, weight: u16, italic: bool };

    pub fn create(gpa: Allocator) !*DirectWriteTextSystem {
        var raw: ?*anyopaque = null;
        try w.check(dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IDWriteFactory.iid2, &raw));
        const factory: *dw.IDWriteFactory = @ptrCast(@alignCast(raw.?));
        errdefer w.release(factory);
        var system: ?*dw.IDWriteFontCollection = null;
        try w.check(factory.vtbl.GetSystemFontCollection(factory, &system, 0));
        errdefer w.release(system);
        var analyzer: ?*dw.IDWriteTextAnalyzer = null;
        try w.check(factory.vtbl.CreateTextAnalyzer(factory, &analyzer));
        errdefer w.release(analyzer);
        const self = try gpa.create(DirectWriteTextSystem);
        self.* = .{ .gpa = gpa, .factory = factory, .system = system.?, .analyzer = analyzer.? };
        var fb: ?*dw.IDWriteFontFallback = null;
        if (factory.vtbl.GetSystemFontFallback(factory, &fb) >= 0) self.font_fallback = fb;
        if (w.queryInterfaceIid(factory, &dw.IDWriteFactory.iid5, dw.IDWriteFactory)) |f5| {
            self.factory5 = f5;
            var loader: ?*dw.IDWriteInMemoryFontFileLoader = null;
            if (f5.vtbl.CreateInMemoryFontFileLoader(f5, &loader) >= 0) {
                if (factory.vtbl.RegisterFontFileLoader(factory, @ptrCast(loader.?)) >= 0) {
                    self.memory_loader = loader;
                } else w.release(loader);
            }
        }
        return self;
    }

    pub fn destroy(self: *DirectWriteTextSystem) void {
        const gpa = self.gpa;
        for (self.faces.items) |f| {
            w.release(f.face);
            gpa.free(f.family_w);
            gpa.free(f.features);
            gpa.free(f.fallback_chain);
            gpa.destroy(f);
        }
        self.faces.deinit(gpa);
        for (self.memory_faces.items) |m| {
            for (m.families) |n| gpa.free(n);
            gpa.free(m.families);
        }
        self.memory_faces.deinit(gpa);
        self.loaded.deinit(gpa);
        self.fallback_cache.deinit(gpa);
        inline for (.{ "utf16", "utf8_index", "script_runs", "cluster_map", "text_props", "glyph_ids", "glyph_props", "advances", "offsets", "spans", "segments" }) |name| @field(self, name).deinit(gpa);
        if (self.memory_loader) |l| {
            _ = self.factory.vtbl.UnregisterFontFileLoader(self.factory, @ptrCast(l));
            w.release(l);
        }
        w.release(self.factory5);
        w.release(self.font_fallback);
        w.release(self.analyzer);
        w.release(self.system);
        w.release(self.factory);
        gpa.destroy(self);
    }

    pub fn fromPtr(ptr: *anyopaque) *DirectWriteTextSystem {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn textSystem(self: *DirectWriteTextSystem) platform.TextSystem {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform.TextSystem.VTable = .{
        .addFont = vtAddFont,
        .fontId = vtFontId,
        .fontMetrics = vtFontMetrics,
        .glyphForChar = vtGlyphForChar,
        .advance = vtAdvance,
        .glyphRasterBounds = vtGlyphRasterBounds,
        .rasterizeGlyph = vtRasterizeGlyph,
        .layoutLine = vtLayoutLine,
    };

    fn face(self: *DirectWriteTextSystem, id: FontId) *Face {
        return self.faces.items[@backingInt(id)];
    }

    // -----------------------------------------------------------------------
    // Font registration and matching
    // -----------------------------------------------------------------------

    /// Register TTF/OTF/TTC bytes (borrowed; must outlive the text system).
    pub fn addFont(self: *DirectWriteTextSystem, bytes: []const u8) !void {
        const count = sfnt.faceCount(bytes) orelse return error.InvalidFont;
        for (0..count) |i| {
            const info = sfnt.parse(self.gpa, bytes, @intCast(i)) catch continue;
            try self.memory_faces.append(self.gpa, .{
                .families = info.families,
                .bytes = bytes,
                .index = @intCast(i),
                .weight = info.weight,
                .italic = info.italic,
            });
        }
    }

    /// gpui `font_name_with_fallbacks` plus CSS-style generic names, mapped to Windows faces.
    fn aliasFamily(name: []const u8) []const u8 {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, ".SystemUIFont") or eq(name, "system-ui") or eq(name, "sans-serif") or eq(name, "sans")) return "Segoe UI";
        if (eq(name, "monospace") or eq(name, "mono")) return "Consolas";
        if (eq(name, "serif")) return "Times New Roman";
        if (eq(name, "emoji")) return "Segoe UI Emoji";
        if (eq(name, ".ZedSans") or eq(name, "Zed Plex Sans")) return "IBM Plex Sans";
        if (eq(name, ".ZedMono") or eq(name, "Zed Plex Mono")) return "Lilex";
        return name;
    }

    fn isGeneric(name: []const u8) bool {
        for ([_][]const u8{ ".SystemUIFont", "system-ui", "sans-serif", "sans", "monospace", "mono", "serif" }) |g| {
            if (std.ascii.eqlIgnoreCase(name, g)) return true;
        }
        return false;
    }

    pub fn fontId(self: *DirectWriteTextSystem, font: types.Font) !FontId {
        const family = aliasFamily(font.family);
        var h = std.hash.Wyhash.init(0);
        var lower_buf: [256]u8 = undefined;
        if (family.len > lower_buf.len) return error.FontNotFound;
        const lower = std.ascii.lowerString(&lower_buf, family);
        h.update(lower);
        h.update(std.mem.asBytes(&font.weight));
        h.update(std.mem.asBytes(&font.style));
        for (font.features) |f| h.update(std.mem.asBytes(&f));
        h.update("|");
        for (font.fallbacks) |f| {
            h.update(f);
            h.update("\x00");
        }
        const key = h.final();
        if (self.loaded.get(key)) |id| return id;

        var chain: std.ArrayList(FontId) = .empty;
        defer chain.deinit(self.gpa);
        for (font.fallbacks) |fb| {
            const id = self.fontId(.{ .family = fb, .weight = font.weight, .style = font.style, .features = font.features }) catch continue;
            try chain.append(self.gpa, id);
        }

        const dface = (try self.memoryFace(lower, font)) orelse (try self.systemFace(family, font)) orelse blk: {
            // Generic families fall back through common Windows faces.
            if (!isGeneric(font.family)) return error.FontNotFound;
            const chain_names: []const []const u8 = if (std.mem.eql(u8, family, "Consolas"))
                &.{ "Cascadia Mono", "Courier New", "Lucida Console" }
            else if (std.mem.eql(u8, family, "Times New Roman"))
                &.{ "Georgia", "Cambria" }
            else
                &.{ "Segoe UI Variable Text", "Tahoma", "Arial", "Verdana" };
            for (chain_names) |name| if (try self.systemFace(name, font)) |found| break :blk found;
            // Last resort: whatever the system font fallback picks for Latin text.
            break :blk (self.defaultFace(font) catch null) orelse return error.FontNotFound;
        };
        errdefer w.release(dface.face);
        const id = try self.register(dface.face, family, font.features, chain.items, dface.weight, dface.italic);
        try self.loaded.put(self.gpa, key, id);
        return id;
    }

    const Found = struct { face: *dw.IDWriteFontFace, weight: f32, italic: bool };

    fn memoryFace(self: *DirectWriteTextSystem, lower: []const u8, font: types.Font) !?Found {
        var best: ?usize = null;
        var best_score: f32 = std.math.floatMax(f32);
        const want_italic = font.style != .normal;
        for (self.memory_faces.items, 0..) |m, i| {
            var match = false;
            for (m.families) |n| match = match or std.mem.eql(u8, n, lower);
            if (!match) continue;
            const score = (if (m.italic == want_italic) @as(f32, 0) else 1000) + @abs(m.weight - font.weight);
            if (score < best_score) {
                best_score = score;
                best = i;
            }
        }
        const m = self.memory_faces.items[best orelse return null];
        const f = try self.createMemoryFace(m.bytes, m.index);
        return .{ .face = f, .weight = m.weight, .italic = m.italic };
    }

    fn createMemoryFace(self: *DirectWriteTextSystem, bytes: []const u8, index: u32) !*dw.IDWriteFontFace {
        const loader = self.memory_loader orelse return error.InMemoryFontsUnsupported;
        var file: ?*dw.IDWriteFontFile = null;
        try w.check(loader.vtbl.CreateInMemoryFontFileReference(loader, self.factory, bytes.ptr, @intCast(bytes.len), null, &file));
        defer w.release(file);
        var supported: w.BOOL = 0;
        var file_type: u32 = 0;
        var face_type: u32 = 0;
        var faces: u32 = 0;
        try w.check(file.?.vtbl.Analyze(file.?, &supported, &file_type, &face_type, &faces));
        if (supported == 0) return error.InvalidFont;
        var out: ?*dw.IDWriteFontFace = null;
        const files = [_]*dw.IDWriteFontFile{file.?};
        try w.check(self.factory.vtbl.CreateFontFace(self.factory, face_type, 1, &files, index, dw.DWRITE_FONT_SIMULATIONS_NONE, &out));
        return out.?;
    }

    fn systemFace(self: *DirectWriteTextSystem, family: []const u8, font: types.Font) !?Found {
        var name_buf: [256]u16 = undefined;
        const name = w.wideBuf(&name_buf, family);
        var index: u32 = 0;
        var exists: w.BOOL = 0;
        if (self.system.vtbl.FindFamilyName(self.system, name.ptr, &index, &exists) < 0 or exists == 0) return null;
        var fam: ?*dw.IDWriteFontFamily = null;
        try w.check(self.system.vtbl.GetFontFamily(self.system, index, &fam));
        defer w.release(fam);
        const weight: u32 = @intFromFloat(std.math.clamp(@round(font.weight), 1, 999));
        const style: u32 = switch (font.style) {
            .normal => dw.DWRITE_FONT_STYLE_NORMAL,
            .italic => dw.DWRITE_FONT_STYLE_ITALIC,
            .oblique => dw.DWRITE_FONT_STYLE_OBLIQUE,
        };
        var dfont: ?*dw.IDWriteFont = null;
        try w.check(fam.?.vtbl.GetFirstMatchingFont(fam.?, weight, dw.DWRITE_FONT_STRETCH_NORMAL, style, &dfont));
        defer w.release(dfont);
        return try fontToFound(dfont.?);
    }

    /// The system fallback's choice for "a" in the requested weight/style.
    fn defaultFace(self: *DirectWriteTextSystem, font: types.Font) !?Found {
        const fb = self.font_fallback orelse return null;
        var text = [_]u16{'a'};
        var source: dw.TextAnalysisSource = .{ .text = &text, .len = 1 };
        var mapped_len: u32 = 0;
        var mapped: ?*dw.IDWriteFont = null;
        var scale: f32 = 1;
        const style = if (font.style == .normal) dw.DWRITE_FONT_STYLE_NORMAL else dw.DWRITE_FONT_STYLE_ITALIC;
        try w.check(fb.vtbl.MapCharacters(fb, &source, 0, 1, self.system, null, @intFromFloat(std.math.clamp(@round(font.weight), 1, 999)), style, dw.DWRITE_FONT_STRETCH_NORMAL, &mapped_len, &mapped, &scale));
        const f = mapped orelse return null;
        defer w.release(f);
        return try fontToFound(f);
    }

    fn fontToFound(dfont: *dw.IDWriteFont) !Found {
        var out: ?*dw.IDWriteFontFace = null;
        try w.check(dfont.vtbl.CreateFontFace(dfont, &out));
        return .{
            .face = out.?,
            .weight = @floatFromInt(dfont.vtbl.GetWeight(dfont)),
            .italic = dfont.vtbl.GetStyle(dfont) != dw.DWRITE_FONT_STYLE_NORMAL,
        };
    }

    /// Take ownership of `f` (one reference) as a new FontId.
    fn register(self: *DirectWriteTextSystem, f: *dw.IDWriteFontFace, family: []const u8, features: []const types.FontFeature, chain: []const FontId, weight: f32, italic: bool) !FontId {
        const gpa = self.gpa;
        const family_w = try w.utf8ToWide(gpa, family);
        errdefer gpa.free(family_w);
        const feats = try gpa.alloc(dw.DWRITE_FONT_FEATURE, features.len);
        errdefer gpa.free(feats);
        for (features, feats) |src, *dst| dst.* = .{
            .nameTag = @as(u32, src.tag[0]) | (@as(u32, src.tag[1]) << 8) | (@as(u32, src.tag[2]) << 16) | (@as(u32, src.tag[3]) << 24),
            .parameter = src.value,
        };
        const fallback_chain = try gpa.dupe(FontId, chain);
        errdefer gpa.free(fallback_chain);
        var m: dw.DWRITE_FONT_METRICS = undefined;
        f.vtbl.GetMetrics(f, &m);
        const upem: u32 = @max(m.designUnitsPerEm, 1);
        const ascent: f32 = @floatFromInt(m.ascent);
        const descent: f32 = -@as(f32, @floatFromInt(m.descent));
        const entry = try gpa.create(Face);
        errdefer gpa.destroy(entry);
        entry.* = .{
            .face = f,
            .family_w = family_w,
            .features = feats,
            .fallback_chain = fallback_chain,
            .is_color = hasTable(f, "COLR") or hasTable(f, "CBDT") or hasTable(f, "sbix"),
            .weight = weight,
            .italic = italic,
            .upem = @floatFromInt(upem),
            .metrics = .{
                .units_per_em = upem,
                .ascent = ascent,
                .descent = descent,
                .line_gap = @floatFromInt(m.lineGap),
                .underline_position = @floatFromInt(m.underlinePosition),
                .underline_thickness = @floatFromInt(m.underlineThickness),
                .cap_height = @floatFromInt(m.capHeight),
                .x_height = @floatFromInt(m.xHeight),
                .bounding_box = .{ .origin = .zero, .size = .{ .width = @floatFromInt(upem), .height = ascent - descent } },
            },
        };
        try self.faces.append(gpa, entry);
        return @fromBackingInt(@intCast(self.faces.items.len - 1));
    }

    fn hasTable(f: *dw.IDWriteFontFace, comptime name: *const [4]u8) bool {
        var data: ?*const anyopaque = null;
        var size: u32 = 0;
        var ctx: ?*anyopaque = null;
        var exists: w.BOOL = 0;
        if (f.vtbl.TryGetFontTable(f, dw.tag(name), &data, &size, &ctx, &exists) < 0) return false;
        if (exists != 0) f.vtbl.ReleaseFontTable(f, ctx);
        return exists != 0;
    }

    fn glyphIndex(f: *dw.IDWriteFontFace, cp: u21) u16 {
        const cps = [_]u32{cp};
        var idx = [_]u16{0};
        if (f.vtbl.GetGlyphIndices(f, &cps, 1, &idx) < 0) return 0;
        return idx[0];
    }

    fn covers(self: *DirectWriteTextSystem, id: FontId, cp: u21) bool {
        return glyphIndex(self.face(id).face, cp) != 0;
    }

    const CoverCtx = struct {
        ts: *DirectWriteTextSystem,
        pub fn covers(self: CoverCtx, id: FontId, cp: u21) bool {
            return self.ts.covers(id, cp);
        }
    };

    /// Identity of a font face (file reference key + face index + simulations), for
    /// deduplicating faces returned by the system fallback.
    fn faceKey(f: *dw.IDWriteFontFace) u64 {
        var h = std.hash.Wyhash.init(0x5eed);
        var n: u32 = 1;
        var files: [1]?*dw.IDWriteFontFile = .{null};
        if (f.vtbl.GetFiles(f, &n, &files) >= 0 and files[0] != null) {
            defer w.release(files[0]);
            var key: ?*const anyopaque = null;
            var size: u32 = 0;
            if (files[0].?.vtbl.GetReferenceKey(files[0].?, &key, &size) >= 0 and key != null) {
                const p: [*]const u8 = @ptrCast(key.?);
                h.update(p[0..size]);
            }
        } else h.update(std.mem.asBytes(&@intFromPtr(f)));
        h.update(std.mem.asBytes(&f.vtbl.GetIndex(f)));
        h.update(std.mem.asBytes(&f.vtbl.GetSimulations(f)));
        h.update("fallback");
        return h.final();
    }

    fn registerFallback(self: *DirectWriteTextSystem, found: Found) !FontId {
        const key = faceKey(found.face);
        if (self.loaded.get(key)) |id| {
            w.release(found.face);
            return id;
        }
        const id = self.register(found.face, "", &.{}, &.{}, found.weight, found.italic) catch |e| {
            w.release(found.face);
            return e;
        };
        try self.loaded.put(self.gpa, key, id);
        return id;
    }

    fn emojiFont(self: *DirectWriteTextSystem) ?FontId {
        if (self.emoji_font) |cached| return cached;
        const id: ?FontId = blk: {
            const found = (self.systemFace("Segoe UI Emoji", .{ .family = "Segoe UI Emoji" }) catch null) orelse break :blk null;
            break :blk self.registerFallback(found) catch null;
        };
        self.emoji_font = id;
        return id;
    }

    /// The system fallback (IDWriteFontFallback::MapCharacters) for one code point.
    fn systemFallback(self: *DirectWriteTextSystem, cp: u21, primary: FontId) ?FontId {
        const p = self.face(primary);
        const key: FallbackKey = .{ .cp = cp, .weight = @intFromFloat(@round(p.weight)), .italic = p.italic };
        if (self.fallback_cache.get(key)) |cached| return cached;
        const result = self.findSystemFallback(cp, p) catch null;
        self.fallback_cache.put(self.gpa, key, result) catch {};
        return result;
    }

    fn findSystemFallback(self: *DirectWriteTextSystem, cp: u21, p: *Face) !?FontId {
        const fb = self.font_fallback orelse return null;
        var buf: [2]u16 = undefined;
        var len: u32 = 1;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            buf[0] = @intCast(0xD800 + (v >> 10));
            buf[1] = @intCast(0xDC00 + (v & 0x3FF));
            len = 2;
        } else buf[0] = @intCast(cp);
        var source: dw.TextAnalysisSource = .{ .text = &buf, .len = len };
        var mapped_len: u32 = 0;
        var mapped: ?*dw.IDWriteFont = null;
        var scale: f32 = 1;
        const base: ?w.LPCWSTR = if (p.family_w.len > 0) p.family_w.ptr else null;
        const style = if (p.italic) dw.DWRITE_FONT_STYLE_ITALIC else dw.DWRITE_FONT_STYLE_NORMAL;
        try w.check(fb.vtbl.MapCharacters(fb, &source, 0, len, self.system, base, @intFromFloat(std.math.clamp(@round(p.weight), 1, 999)), style, dw.DWRITE_FONT_STRETCH_NORMAL, &mapped_len, &mapped, &scale));
        const font = mapped orelse return null;
        defer w.release(font);
        const id = try self.registerFallback(try fontToFound(font));
        return if (self.covers(id, cp)) id else null;
    }

    // -----------------------------------------------------------------------
    // Shaping
    // -----------------------------------------------------------------------

    const Segment = struct { start: usize, end: usize, font_id: FontId };

    fn pickFont(self: *DirectWriteTextSystem, cp: u21, want_emoji: bool, primary: FontId, current: FontId) FontId {
        if (want_emoji) {
            if (self.face(primary).is_color and self.covers(primary, cp)) return primary;
            if (self.face(current).is_color and self.covers(current, cp)) return current;
            if (self.emojiFont()) |e| if (self.covers(e, cp)) return e;
        }
        if (cp < 0x80 or self.covers(primary, cp)) return primary;
        if (self.covers(current, cp)) return current;
        if (fallback.isExtend(cp) or cp < 0x20) return current;
        return self.systemFallback(cp, primary) orelse primary;
    }

    fn appendSegments(self: *DirectWriteTextSystem, text: []const u8, span: fallback.RunSpan) !void {
        var seg_start = span.start;
        var seg_font = span.font_id;
        var current = span.font_id;
        var i = span.start;
        while (i < span.end) {
            const g_end = @min(fallback.graphemeEnd(text, i), span.end);
            const cp = fallback.decodeAt(text, i).cp;
            const f = self.pickFont(cp, fallback.graphemeWantsEmoji(text[i..g_end]), span.font_id, current);
            if (f != seg_font) {
                if (i > seg_start) try self.pushSegment(.{ .start = seg_start, .end = i, .font_id = seg_font });
                seg_start = i;
                seg_font = f;
            }
            current = f;
            i = g_end;
        }
        if (span.end > seg_start) try self.pushSegment(.{ .start = seg_start, .end = span.end, .font_id = seg_font });
    }

    fn pushSegment(self: *DirectWriteTextSystem, seg: Segment) !void {
        if (self.segments.items.len > 0) {
            const last = &self.segments.items[self.segments.items.len - 1];
            if (last.font_id == seg.font_id and last.end == seg.start) {
                last.end = seg.end;
                return;
            }
        }
        try self.segments.append(self.gpa, seg);
    }

    /// UTF-8 `text` -> UTF-16 in `self.utf16`, with `self.utf8_index[k]` = byte offset of
    /// code unit k (plus one past-the-end entry).
    fn toUtf16(self: *DirectWriteTextSystem, text: []const u8, base: usize) !void {
        const gpa = self.gpa;
        self.utf16.clearRetainingCapacity();
        self.utf8_index.clearRetainingCapacity();
        var i: usize = 0;
        while (i < text.len) {
            const d = fallback.decodeAt(text, i);
            const n: usize = @max(d.len, 1);
            const cp = d.cp;
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                try self.utf16.append(gpa, @intCast(0xD800 + (v >> 10)));
                try self.utf16.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
                try self.utf8_index.appendNTimes(gpa, @intCast(base + i), 2);
            } else {
                try self.utf16.append(gpa, @intCast(cp));
                try self.utf8_index.append(gpa, @intCast(base + i));
            }
            i += n;
        }
        try self.utf8_index.append(gpa, @intCast(base + text.len));
    }

    /// Shape one line with per-run fonts, falling back per grapheme. Result lives in `arena`.
    pub fn layoutLine(self: *DirectWriteTextSystem, arena: Allocator, text: []const u8, font_size: Pixels, runs: []const types.FontRun) !types.LineLayout {
        self.segments.clearRetainingCapacity();
        var offset: usize = 0;
        for (runs) |run| {
            const len = @min(run.len, text.len -| offset);
            self.spans.clearRetainingCapacity();
            try fallback.computeRunSpans(self.gpa, &self.spans, text, offset, len, run.font_id, self.face(run.font_id).fallback_chain, CoverCtx{ .ts = self });
            for (self.spans.items) |span| try self.appendSegments(text, span);
            offset += len;
        }

        var out_runs: std.ArrayList(types.ShapedRun) = .empty;
        var glyphs: std.ArrayList(types.ShapedGlyph) = .empty;
        var run_font: ?FontId = null;
        var pen: f32 = 0;
        var ascent: f32 = 0;
        var descent: f32 = 0;

        for (self.segments.items) |seg| {
            const f = self.face(seg.font_id);
            const scale = font_size / f.upem;
            ascent = @max(ascent, f.metrics.ascent * scale);
            descent = @max(descent, -f.metrics.descent * scale);
            if (run_font != seg.font_id) {
                if (run_font) |rf| if (glyphs.items.len > 0) {
                    try out_runs.append(arena, .{ .font_id = rf, .glyphs = try glyphs.toOwnedSlice(arena) });
                };
                glyphs = .empty;
                run_font = seg.font_id;
            }
            try self.shapeSegment(arena, &glyphs, &pen, text[seg.start..seg.end], seg.start, f, font_size);
        }
        if (run_font) |rf| if (glyphs.items.len > 0) {
            try out_runs.append(arena, .{ .font_id = rf, .glyphs = try glyphs.toOwnedSlice(arena) });
        };
        if (self.segments.items.len == 0 and runs.len > 0) {
            const f = self.face(runs[0].font_id);
            ascent = f.metrics.ascent * font_size / f.upem;
            descent = -f.metrics.descent * font_size / f.upem;
        }
        return .{
            .font_size = font_size,
            .width = pen,
            .ascent = ascent,
            .descent = descent,
            .runs = try out_runs.toOwnedSlice(arena),
            .len = text.len,
        };
    }

    fn shapeSegment(self: *DirectWriteTextSystem, arena: Allocator, glyphs: *std.ArrayList(types.ShapedGlyph), pen: *f32, text: []const u8, base: usize, f: *Face, font_size: f32) !void {
        const gpa = self.gpa;
        try self.toUtf16(text, base);
        const units = self.utf16.items;
        if (units.len == 0) return;

        // Script itemization.
        self.script_runs.clearRetainingCapacity();
        var source: dw.TextAnalysisSource = .{ .text = units.ptr, .len = @intCast(units.len) };
        var sink: dw.TextAnalysisSink = .{ .runs = &self.script_runs, .gpa = &self.gpa };
        if (self.analyzer.vtbl.AnalyzeScript(self.analyzer, &source, 0, @intCast(units.len), &sink) < 0 or sink.failed or self.script_runs.items.len == 0) {
            self.script_runs.clearRetainingCapacity();
            try self.script_runs.append(gpa, .{ .start = 0, .len = @intCast(units.len), .analysis = .{ .script = 0, .shapes = 0 } });
        }
        std.mem.sort(dw.ScriptRun, self.script_runs.items, {}, struct {
            fn lt(_: void, a: dw.ScriptRun, b: dw.ScriptRun) bool {
                return a.start < b.start;
            }
        }.lt);

        const feature_set: dw.DWRITE_TYPOGRAPHIC_FEATURES = .{ .features = f.features.ptr, .featureCount = @intCast(f.features.len) };
        const feature_ptrs = [_]*const dw.DWRITE_TYPOGRAPHIC_FEATURES{&feature_set};

        for (self.script_runs.items) |sr| {
            const run_units = units[sr.start..][0..sr.len];
            const n: u32 = sr.len;
            const feature_lens = [_]u32{n};
            const has_features = f.features.len > 0;
            try self.cluster_map.resize(gpa, n);
            try self.text_props.resize(gpa, n);
            var max_glyphs: u32 = n * 3 / 2 + 16;
            var glyph_count: u32 = 0;
            while (true) {
                try self.glyph_ids.resize(gpa, max_glyphs);
                try self.glyph_props.resize(gpa, max_glyphs);
                const hr = self.analyzer.vtbl.GetGlyphs(
                    self.analyzer,
                    run_units.ptr,
                    n,
                    f.face,
                    0,
                    0,
                    &sr.analysis,
                    null,
                    null,
                    if (has_features) &feature_ptrs else null,
                    if (has_features) &feature_lens else null,
                    if (has_features) 1 else 0,
                    max_glyphs,
                    self.cluster_map.items.ptr,
                    self.text_props.items.ptr,
                    self.glyph_ids.items.ptr,
                    self.glyph_props.items.ptr,
                    &glyph_count,
                );
                if (hr == dw.E_NOT_SUFFICIENT_BUFFER and max_glyphs < 1 << 20) {
                    max_glyphs *= 2;
                    continue;
                }
                try w.check(hr);
                break;
            }
            try self.advances.resize(gpa, glyph_count);
            try self.offsets.resize(gpa, glyph_count);
            try w.check(self.analyzer.vtbl.GetGlyphPlacements(
                self.analyzer,
                run_units.ptr,
                self.cluster_map.items.ptr,
                self.text_props.items.ptr,
                n,
                self.glyph_ids.items.ptr,
                self.glyph_props.items.ptr,
                glyph_count,
                f.face,
                font_size,
                0,
                0,
                &sr.analysis,
                null,
                if (has_features) &feature_ptrs else null,
                if (has_features) &feature_lens else null,
                if (has_features) 1 else 0,
                self.advances.items.ptr,
                self.offsets.items.ptr,
            ));

            // Glyph -> cluster start (text position) via the cluster map (LTR).
            const first_glyph = glyphs.items.len;
            try glyphs.ensureUnusedCapacity(arena, glyph_count);
            var g: u32 = 0;
            var i: u32 = 0;
            while (i < n) {
                const start_glyph = self.cluster_map.items[i];
                var j = i + 1;
                while (j < n and self.cluster_map.items[j] == start_glyph) j += 1;
                const end_glyph: u32 = if (j < n) self.cluster_map.items[j] else glyph_count;
                const byte_index = self.utf8_index.items[sr.start + i];
                g = start_glyph;
                while (g < end_glyph and g < glyph_count) : (g += 1) {
                    const off = self.offsets.items[g];
                    glyphs.appendAssumeCapacity(.{
                        .id = self.glyph_ids.items[g],
                        .position = .{ .x = pen.* + off.advanceOffset, .y = -off.ascenderOffset },
                        .index = byte_index,
                        .is_emoji = f.is_color,
                    });
                    pen.* += self.advances.items[g];
                }
                i = j;
            }
            _ = first_glyph;
        }
    }

    // -----------------------------------------------------------------------
    // Rasterization
    // -----------------------------------------------------------------------

    fn analysis(self: *DirectWriteTextSystem, f: *dw.IDWriteFontFace, glyph: u16, em: f32, x: f32, y: f32) !*dw.IDWriteGlyphRunAnalysis {
        const ids = [_]u16{glyph};
        const adv = [_]f32{0};
        const run: dw.DWRITE_GLYPH_RUN = .{ .fontFace = f, .fontEmSize = em, .glyphCount = 1, .glyphIndices = &ids, .glyphAdvances = &adv };
        var out: ?*dw.IDWriteGlyphRunAnalysis = null;
        try w.check(self.factory.vtbl.CreateGlyphRunAnalysis2(
            self.factory,
            &run,
            null,
            dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
            dw.DWRITE_MEASURING_MODE_NATURAL,
            dw.DWRITE_GRID_FIT_MODE_DEFAULT,
            dw.DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
            x,
            y,
            &out,
        ));
        return out.?;
    }

    fn analysisFromRun(self: *DirectWriteTextSystem, run: *const dw.DWRITE_GLYPH_RUN, x: f32, y: f32) !*dw.IDWriteGlyphRunAnalysis {
        var out: ?*dw.IDWriteGlyphRunAnalysis = null;
        try w.check(self.factory.vtbl.CreateGlyphRunAnalysis2(self.factory, run, null, dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, dw.DWRITE_MEASURING_MODE_NATURAL, dw.DWRITE_GRID_FIT_MODE_DEFAULT, dw.DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, x, y, &out));
        return out.?;
    }

    fn textureBounds(a: *dw.IDWriteGlyphRunAnalysis) w.RECT {
        var r: w.RECT = .{};
        if (a.vtbl.GetAlphaTextureBounds(a, dw.DWRITE_TEXTURE_ALIASED_1x1, &r) < 0) return .{};
        return r;
    }

    const Raster = struct { rect: w.RECT, data: ?[]u8 };

    /// Color layers of an emoji glyph (null when the glyph has none).
    fn colorLayers(self: *DirectWriteTextSystem, params: types.RenderGlyphParams, x: f32) ?*dw.IDWriteColorGlyphRunEnumerator {
        const f = self.face(params.font_id).face;
        const ids = [_]u16{@intCast(params.glyph_id)};
        const adv = [_]f32{0};
        const run: dw.DWRITE_GLYPH_RUN = .{ .fontFace = f, .fontEmSize = params.font_size * params.scale_factor, .glyphCount = 1, .glyphIndices = &ids, .glyphAdvances = &adv };
        var e: ?*dw.IDWriteColorGlyphRunEnumerator = null;
        if (self.factory.vtbl.TranslateColorGlyphRun(self.factory, x, 0, &run, null, dw.DWRITE_MEASURING_MODE_NATURAL, null, 0, &e) < 0) return null;
        return e;
    }

    /// Rasterize per `params`: 1 byte/px grayscale, or straight-alpha BGRA for emoji
    /// (color layers composited) and for subpixel requests (equal coverage per channel).
    fn render(self: *DirectWriteTextSystem, gpa: Allocator, params: types.RenderGlyphParams, want_data: bool) !Raster {
        const f = self.face(params.font_id).face;
        const em = params.font_size * params.scale_factor;
        const x: f32 = @as(f32, @floatFromInt(params.subpixel_variant_x)) / @as(f32, @floatFromInt(types.subpixel_variants_x));
        if (em <= 0) return .{ .rect = .{}, .data = null };

        if (params.is_emoji) if (self.colorLayers(params, x)) |layers| {
            defer w.release(layers);
            return self.renderColor(gpa, layers, want_data);
        };

        const a = try self.analysis(f, @intCast(params.glyph_id), em, x, 0);
        defer w.release(a);
        const rect = textureBounds(a);
        if (!want_data or rect.width() <= 0 or rect.height() <= 0) return .{ .rect = rect, .data = null };
        const n: usize = @intCast(rect.width() * rect.height());
        const alpha = try gpa.alloc(u8, n);
        errdefer gpa.free(alpha);
        try w.check(a.vtbl.CreateAlphaTexture(a, dw.DWRITE_TEXTURE_ALIASED_1x1, &rect, alpha.ptr, @intCast(n)));
        if (!params.is_emoji and !params.subpixel_rendering) return .{ .rect = rect, .data = alpha };
        defer gpa.free(alpha);
        const bgra = try gpa.alloc(u8, n * 4);
        for (alpha, 0..) |v, i| {
            // Emoji from a monochrome glyph: black; subpixel: equal coverage.
            const c: u8 = if (params.is_emoji) 0 else v;
            bgra[i * 4 ..][0..4].* = .{ c, c, c, v };
        }
        return .{ .rect = rect, .data = bgra };
    }

    fn renderColor(self: *DirectWriteTextSystem, gpa: Allocator, layers: *dw.IDWriteColorGlyphRunEnumerator, want_data: bool) !Raster {
        // Pass 1: union of the layer bounds. Pass 2 needs the enumerator again, so the
        // layer runs are copied (a handful per emoji).
        var runs: [32]dw.DWRITE_COLOR_GLYPH_RUN = undefined;
        var count: usize = 0;
        var union_rect: ?w.RECT = null;
        while (count < runs.len) {
            var more: w.BOOL = 0;
            if (layers.vtbl.MoveNext(layers, &more) < 0 or more == 0) break;
            var cur: ?*const dw.DWRITE_COLOR_GLYPH_RUN = null;
            if (layers.vtbl.GetCurrentRun(layers, &cur) < 0 or cur == null) break;
            runs[count] = cur.?.*;
            const a = self.analysisFromRun(&runs[count].glyphRun, runs[count].baselineOriginX, runs[count].baselineOriginY) catch continue;
            defer w.release(a);
            const r = textureBounds(a);
            count += 1;
            if (r.width() <= 0 or r.height() <= 0) continue;
            union_rect = if (union_rect) |u| .{ .left = @min(u.left, r.left), .top = @min(u.top, r.top), .right = @max(u.right, r.right), .bottom = @max(u.bottom, r.bottom) } else r;
        }
        const rect = union_rect orelse return .{ .rect = .{}, .data = null };
        if (!want_data) return .{ .rect = rect, .data = null };
        const rw: usize = @intCast(rect.width());
        const rh: usize = @intCast(rect.height());
        // Premultiplied accumulation, then straight alpha (the polychrome atlas format).
        const acc = try gpa.alloc(f32, rw * rh * 4);
        defer gpa.free(acc);
        @memset(acc, 0);
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(gpa);
        for (runs[0..count]) |*run| {
            const a = self.analysisFromRun(&run.glyphRun, run.baselineOriginX, run.baselineOriginY) catch continue;
            defer w.release(a);
            const r = textureBounds(a);
            if (r.width() <= 0 or r.height() <= 0) continue;
            const lw: usize = @intCast(r.width());
            const lh: usize = @intCast(r.height());
            try scratch.resize(gpa, lw * lh);
            if (a.vtbl.CreateAlphaTexture(a, dw.DWRITE_TEXTURE_ALIASED_1x1, &r, scratch.items.ptr, @intCast(lw * lh)) < 0) continue;
            // paletteIndex 0xFFFF = "use the text color": black for emoji.
            const c = if (run.paletteIndex == 0xFFFF) dw.DWRITE_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 1 } else run.runColor;
            for (0..lh) |y| for (0..lw) |xx| {
                const cov = @as(f32, @floatFromInt(scratch.items[y * lw + xx])) / 255.0 * c.a;
                if (cov == 0) continue;
                const dx: usize = @intCast(r.left - rect.left + @as(i32, @intCast(xx)));
                const dy: usize = @intCast(r.top - rect.top + @as(i32, @intCast(y)));
                const p = acc[(dy * rw + dx) * 4 ..][0..4];
                p[0] = c.b * cov + p[0] * (1 - cov);
                p[1] = c.g * cov + p[1] * (1 - cov);
                p[2] = c.r * cov + p[2] * (1 - cov);
                p[3] = cov + p[3] * (1 - cov);
            };
        }
        const out = try gpa.alloc(u8, rw * rh * 4);
        for (0..rw * rh) |i| {
            const p = acc[i * 4 ..][0..4];
            const a = p[3];
            const o = out[i * 4 ..][0..4];
            if (a <= 0) {
                o.* = .{ 0, 0, 0, 0 };
                continue;
            }
            for (0..3) |k| o[k] = @intFromFloat(@round(std.math.clamp(p[k] / a, 0, 1) * 255));
            o[3] = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
        }
        return .{ .rect = rect, .data = out };
    }

    pub fn glyphRasterBounds(self: *DirectWriteTextSystem, params: types.RenderGlyphParams) !geometry.Bounds(DevicePixels) {
        const r = try self.render(self.gpa, params, false);
        if (r.rect.width() <= 0 or r.rect.height() <= 0) return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        return .{
            .origin = .{ .x = r.rect.left, .y = r.rect.top },
            .size = .{ .width = r.rect.width(), .height = r.rect.height() },
        };
    }

    pub fn rasterizeGlyph(self: *DirectWriteTextSystem, gpa: Allocator, params: types.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels)) ![]u8 {
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return error.EmptyGlyph;
        const r = try self.render(gpa, params, true);
        const data = r.data orelse return error.EmptyGlyph;
        const iw: usize = @intCast(r.rect.width());
        const ih: usize = @intCast(r.rect.height());
        if (iw == bounds.size.width and ih == bounds.size.height) return data;
        defer gpa.free(data);
        const bpp: usize = if (params.is_emoji or params.subpixel_rendering) 4 else 1;
        const bw: usize = @intCast(bounds.size.width);
        const bh: usize = @intCast(bounds.size.height);
        const out = try gpa.alloc(u8, bw * bh * bpp);
        @memset(out, 0);
        for (0..@min(bh, ih)) |y| {
            const n = @min(bw, iw) * bpp;
            @memcpy(out[y * bw * bpp ..][0..n], data[y * iw * bpp ..][0..n]);
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Vtable shims
    // -----------------------------------------------------------------------

    fn vtAddFont(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        return fromPtr(ptr).addFont(bytes);
    }
    fn vtFontId(ptr: *anyopaque, font: types.Font) anyerror!FontId {
        return fromPtr(ptr).fontId(font);
    }
    fn vtFontMetrics(ptr: *anyopaque, id: FontId) types.FontMetrics {
        return fromPtr(ptr).face(id).metrics;
    }
    fn vtGlyphForChar(ptr: *anyopaque, id: FontId, ch: u21) ?types.GlyphId {
        const g = glyphIndex(fromPtr(ptr).face(id).face, ch);
        return if (g == 0) null else g;
    }
    fn vtAdvance(ptr: *anyopaque, id: FontId, glyph: types.GlyphId) geometry.Size(f32) {
        const f = fromPtr(ptr).face(id).face;
        const ids = [_]u16{@intCast(glyph)};
        var m: [1]dw.DWRITE_GLYPH_METRICS = undefined;
        if (f.vtbl.GetDesignGlyphMetrics(f, &ids, 1, &m, 0) < 0) return .{ .width = 0, .height = 0 };
        return .{ .width = @floatFromInt(m[0].advanceWidth), .height = @floatFromInt(m[0].advanceHeight) };
    }
    fn vtGlyphRasterBounds(ptr: *anyopaque, params: types.RenderGlyphParams) anyerror!geometry.Bounds(DevicePixels) {
        return fromPtr(ptr).glyphRasterBounds(params);
    }
    fn vtRasterizeGlyph(ptr: *anyopaque, gpa: Allocator, params: types.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels)) anyerror![]u8 {
        return fromPtr(ptr).rasterizeGlyph(gpa, params, bounds);
    }
    fn vtLayoutLine(ptr: *anyopaque, arena: Allocator, str: []const u8, font_size: Pixels, runs: []const types.FontRun) anyerror!types.LineLayout {
        return fromPtr(ptr).layoutLine(arena, str, font_size, runs);
    }
};

/// Minimal SFNT reader for fonts registered from memory: face count (TTC), family names
/// (name IDs 1 and 16, Windows/Unicode platforms), OS/2 weight and the italic bit.
pub const sfnt = struct {
    fn be16(b: []const u8, at: usize) ?u16 {
        if (at + 2 > b.len) return null;
        return std.mem.readInt(u16, b[at..][0..2], .big);
    }
    fn be32(b: []const u8, at: usize) ?u32 {
        if (at + 4 > b.len) return null;
        return std.mem.readInt(u32, b[at..][0..4], .big);
    }

    pub fn faceCount(b: []const u8) ?u32 {
        const magic = be32(b, 0) orelse return null;
        if (magic == 0x74746366) return be32(b, 8); // 'ttcf'
        if (magic == 0x00010000 or magic == 0x4F54544F or magic == 0x74727565) return 1; // 1.0, 'OTTO', 'true'
        return null;
    }

    fn faceOffset(b: []const u8, index: u32) ?usize {
        if (be32(b, 0) == 0x74746366) return if (be32(b, 12 + 4 * @as(usize, index))) |o| o else null;
        return if (index == 0) 0 else null;
    }

    fn table(b: []const u8, face_off: usize, name: *const [4]u8) ?[]const u8 {
        const n = be16(b, face_off + 4) orelse return null;
        for (0..n) |i| {
            const rec = face_off + 12 + i * 16;
            if (rec + 16 > b.len) return null;
            if (!std.mem.eql(u8, b[rec..][0..4], name)) continue;
            const off = be32(b, rec + 8) orelse return null;
            const len = be32(b, rec + 12) orelse return null;
            if (@as(usize, off) + len > b.len) return null;
            return b[off..][0..len];
        }
        return null;
    }

    pub const Info = struct { families: [][]u8, weight: f32, italic: bool };

    pub fn parse(gpa: Allocator, b: []const u8, index: u32) !Info {
        const off = faceOffset(b, index) orelse return error.InvalidFont;
        var weight: f32 = 400;
        var italic = false;
        if (table(b, off, "OS/2")) |os2| {
            if (be16(os2, 4)) |wc| if (wc != 0) {
                weight = @floatFromInt(wc);
            };
            if (be16(os2, 62)) |sel| italic = sel & 1 != 0 or sel & (1 << 9) != 0;
        }
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        const nt = table(b, off, "name") orelse return error.InvalidFont;
        const count = be16(nt, 2) orelse 0;
        const storage = be16(nt, 4) orelse 0;
        var buf: [256]u8 = undefined;
        for (0..count) |i| {
            const rec = 6 + i * 12;
            const platform_id = be16(nt, rec) orelse break;
            const name_id = be16(nt, rec + 6) orelse break;
            const len = be16(nt, rec + 8) orelse break;
            const str_off = be16(nt, rec + 10) orelse break;
            if (name_id != 1 and name_id != 16) continue;
            const start = @as(usize, storage) + str_off;
            if (start + len > nt.len) continue;
            const raw = nt[start..][0..len];
            var n: usize = 0;
            if (platform_id == 0 or platform_id == 3) {
                var j: usize = 0;
                while (j + 1 < raw.len and n < buf.len) : (j += 2) {
                    if (raw[j] == 0 and raw[j + 1] < 0x80) {
                        buf[n] = std.ascii.toLower(raw[j + 1]);
                        n += 1;
                    }
                }
            } else {
                for (raw) |ch| if (n < buf.len) {
                    buf[n] = std.ascii.toLower(ch);
                    n += 1;
                };
            }
            if (n == 0) continue;
            var dup = false;
            for (names.items) |e| dup = dup or std.mem.eql(u8, e, buf[0..n]);
            if (!dup) try names.append(gpa, try gpa.dupe(u8, buf[0..n]));
        }
        if (names.items.len == 0) return error.InvalidFont;
        return .{ .families = try names.toOwnedSlice(gpa), .weight = weight, .italic = italic };
    }
};
