//! Linux platform text system: fontconfig (font matching and per-character fallback),
//! HarfBuzz (shaping), FreeType (rasterization: grayscale, LCD subpixel, color emoji).
//! Port of zui's `gpui_wgpu/src/cosmic_text_system.rs` onto the C libraries.
//!
//! Not thread-safe: all calls must come from one thread (the core serializes access).

const std = @import("std");
const c = @import("freetype_c");
const types = @import("types.zig");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const fallback = @import("fallback.zig");

const Allocator = std.mem.Allocator;
const FontId = types.FontId;
const Pixels = types.Pixels;
const DevicePixels = geometry.DevicePixels;

/// Create the FreeType backend (see `text.createPlatformTextSystem`).
pub fn create(gpa: Allocator) !platform.TextSystem {
    const self = try FreeTypeTextSystem.create(gpa);
    return self.textSystem();
}

pub fn destroy(ts: platform.TextSystem) void {
    FreeTypeTextSystem.fromPtr(ts.ptr).destroy();
}

/// Where a face's bytes come from.
const Source = union(enum) {
    file: struct { path: [:0]const u8, index: u32 },
    memory: struct { bytes: []const u8, index: u32 },

    fn hash(self: Source, h: *std.hash.Wyhash) void {
        switch (self) {
            .file => |f| {
                h.update(f.path);
                h.update(std.mem.asBytes(&f.index));
            },
            .memory => |m| {
                h.update(std.mem.asBytes(&@intFromPtr(m.bytes.ptr)));
                h.update(std.mem.asBytes(&m.index));
            },
        }
    }

    fn faceIndex(self: Source) u32 {
        return switch (self) {
            inline else => |s| s.index,
        };
    }
};

/// A matchable face: source plus style properties.
const Descriptor = struct {
    source: Source,
    weight: f32,
    italic: bool,
};

/// A font registered with `addFont`.
const MemoryFace = struct {
    /// Lowercased family names (name IDs 1 and 16).
    families: [][]u8,
    desc: Descriptor,
};

/// A loaded face; indexed by `FontId`.
const Face = struct {
    ft: c.FT_Face,
    hb_font: *c.hb_font_t,
    features: []c.hb_feature_t,
    /// Resolved user fallback chain (`Font.fallbacks`).
    fallback_chain: []FontId,
    is_color: bool,
    scalable: bool,
    weight: f32,
    italic: bool,
    upem: f32,
    metrics: types.FontMetrics,
    /// Last FT_Set_Char_Size value (26.6), to skip redundant calls.
    char_size: c.FT_F26Dot6 = -1,
    strike: c_int = -1,
};

pub const FreeTypeTextSystem = struct {
    gpa: Allocator,
    library: c.FT_Library,
    fc: *c.FcConfig,
    hb_buffer: *c.hb_buffer_t,
    faces: std.ArrayList(*Face) = .empty,
    memory_faces: std.ArrayList(MemoryFace) = .empty,
    /// Lowercased family name -> candidate faces.
    family_cache: std.StringHashMapUnmanaged([]Descriptor) = .empty,
    /// Hash of (source, features, fallbacks) -> loaded face.
    loaded: std.AutoHashMapUnmanaged(u64, FontId) = .empty,
    /// Per-character system fallback results.
    fallback_cache: std.AutoHashMapUnmanaged(FallbackKey, ?FontId) = .empty,
    emoji_font: ??FontId = null,
    /// Owned strings (descriptor paths) freed on destroy.
    strings: std.ArrayList([:0]const u8) = .empty,

    const FallbackKey = struct { cp: u21, weight: u16, italic: bool };

    pub fn create(gpa: Allocator) !*FreeTypeTextSystem {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(library);
        // Ignored if FreeType was built without ClearType-style filtering (Harmony LCD is used then).
        _ = c.FT_Library_SetLcdFilter(library, c.FT_LCD_FILTER_DEFAULT);
        const fc = c.FcInitLoadConfigAndFonts() orelse return error.FontconfigInitFailed;
        errdefer c.FcConfigDestroy(fc);
        const buf = c.hb_buffer_create() orelse return error.OutOfMemory;
        const self = try gpa.create(FreeTypeTextSystem);
        self.* = .{ .gpa = gpa, .library = library, .fc = fc, .hb_buffer = buf };
        return self;
    }

    pub fn destroy(self: *FreeTypeTextSystem) void {
        const gpa = self.gpa;
        for (self.faces.items) |f| {
            c.hb_font_destroy(f.hb_font);
            _ = c.FT_Done_Face(f.ft);
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
        var it = self.family_cache.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.family_cache.deinit(gpa);
        self.loaded.deinit(gpa);
        self.fallback_cache.deinit(gpa);
        for (self.strings.items) |s| gpa.free(s);
        self.strings.deinit(gpa);
        c.hb_buffer_destroy(self.hb_buffer);
        c.FcConfigDestroy(self.fc);
        _ = c.FT_Done_FreeType(self.library);
        gpa.destroy(self);
    }

    pub fn fromPtr(ptr: *anyopaque) *FreeTypeTextSystem {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn textSystem(self: *FreeTypeTextSystem) platform.TextSystem {
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
        .raster_transforms = true,
    };

    fn face(self: *FreeTypeTextSystem, id: FontId) *Face {
        return self.faces.items[@intFromEnum(id)];
    }

    // -----------------------------------------------------------------------
    // Font registration and matching
    // -----------------------------------------------------------------------

    /// Register TTF/OTF/TTC bytes (borrowed; must outlive the text system).
    pub fn addFont(self: *FreeTypeTextSystem, bytes: []const u8) !void {
        var probe: c.FT_Face = null;
        if (c.FT_New_Memory_Face(self.library, bytes.ptr, @intCast(bytes.len), -1, &probe) != 0) return error.InvalidFont;
        const num_faces: u32 = @intCast(probe.*.num_faces);
        _ = c.FT_Done_Face(probe);
        for (0..num_faces) |i| {
            var ft: c.FT_Face = null;
            if (c.FT_New_Memory_Face(self.library, bytes.ptr, @intCast(bytes.len), @intCast(i), &ft) != 0) continue;
            defer _ = c.FT_Done_Face(ft);
            const families = try self.familyNames(ft);
            errdefer {
                for (families) |n| self.gpa.free(n);
                self.gpa.free(families);
            }
            try self.memory_faces.append(self.gpa, .{
                .families = families,
                .desc = .{ .source = .{ .memory = .{ .bytes = bytes, .index = @intCast(i) } }, .weight = faceWeight(ft), .italic = faceItalic(ft) },
            });
        }
        // New faces may join families already cached.
        var it = self.family_cache.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.family_cache.clearRetainingCapacity();
    }

    fn familyNames(self: *FreeTypeTextSystem, ft: c.FT_Face) ![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        if (ft.*.family_name != null) try names.append(self.gpa, try std.ascii.allocLowerString(self.gpa, std.mem.span(ft.*.family_name)));
        const count = c.FT_Get_Sfnt_Name_Count(ft);
        var buf: [256]u8 = undefined;
        for (0..count) |i| {
            var name: c.FT_SfntName = undefined;
            if (c.FT_Get_Sfnt_Name(ft, @intCast(i), &name) != 0) continue;
            if (name.name_id != 1 and name.name_id != 16) continue;
            const raw = name.string[0..name.string_len];
            var n: usize = 0;
            if (name.platform_id == 0 or name.platform_id == 3) {
                // UTF-16BE; keep the ASCII subset.
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
            if (!dup) try names.append(self.gpa, try self.gpa.dupe(u8, buf[0..n]));
        }
        return names.toOwnedSlice(self.gpa);
    }

    /// gpui `font_name_with_fallbacks` plus CSS-style generic names.
    fn aliasFamily(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, ".SystemUIFont") or std.mem.eql(u8, name, "system-ui")) return "sans-serif";
        if (std.mem.eql(u8, name, ".ZedSans") or std.mem.eql(u8, name, "Zed Plex Sans")) return "IBM Plex Sans";
        if (std.mem.eql(u8, name, ".ZedMono") or std.mem.eql(u8, name, "Zed Plex Mono")) return "Lilex";
        return name;
    }

    fn isGenericFamily(name: []const u8) bool {
        for ([_][]const u8{ "sans-serif", "serif", "monospace", "emoji", "cursive", "fantasy", "sans", "mono" }) |g| {
            if (std.ascii.eqlIgnoreCase(name, g)) return true;
        }
        return false;
    }

    /// All faces of `family` (memory fonts first, then fontconfig). Cached.
    fn familyCandidates(self: *FreeTypeTextSystem, family_in: []const u8) ![]const Descriptor {
        const family = aliasFamily(family_in);
        var lower_buf: [256]u8 = undefined;
        if (family.len > lower_buf.len) return &.{};
        const lower = std.ascii.lowerString(&lower_buf, family);
        if (self.family_cache.get(lower)) |d| return d;

        var list: std.ArrayList(Descriptor) = .empty;
        defer list.deinit(self.gpa);
        for (self.memory_faces.items) |m| {
            for (m.families) |n| if (std.mem.eql(u8, n, lower)) {
                try list.append(self.gpa, m.desc);
                break;
            };
        }
        try self.listFontconfigFamily(&list, family);
        if (list.items.len == 0 and isGenericFamily(family)) {
            if (try self.matchFamilyName(family)) |resolved| {
                defer self.gpa.free(resolved);
                const descs = try self.familyCandidates(resolved);
                try list.appendSlice(self.gpa, descs);
            }
        }
        const key = try self.gpa.dupe(u8, lower);
        errdefer self.gpa.free(key);
        const owned = try list.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(owned);
        try self.family_cache.put(self.gpa, key, owned);
        return owned;
    }

    fn listFontconfigFamily(self: *FreeTypeTextSystem, list: *std.ArrayList(Descriptor), family: []const u8) !void {
        const name = try self.gpa.dupeSentinel(u8, family, 0);
        defer self.gpa.free(name);
        const pat = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pat);
        _ = c.FcPatternAddString(pat, c.FC_FAMILY, name.ptr);
        const os = c.FcObjectSetBuild(c.FC_FILE, c.FC_INDEX, c.FC_WEIGHT, c.FC_SLANT, c.FC_VARIABLE, @as(?*anyopaque, null));
        defer c.FcObjectSetDestroy(os);
        const set = c.FcFontList(self.fc, pat, os);
        if (set == null) return;
        defer c.FcFontSetDestroy(set);
        for (0..@intCast(set.*.nfont)) |i| {
            const p = set.*.fonts[i];
            if (try self.descriptorFromPattern(p)) |d| try list.append(self.gpa, d);
        }
    }

    fn descriptorFromPattern(self: *FreeTypeTextSystem, p: ?*c.FcPattern) !?Descriptor {
        var file: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(p, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
        var variable: c.FcBool = 0;
        if (c.FcPatternGetBool(p, c.FC_VARIABLE, 0, &variable) == c.FcResultMatch and variable != 0) return null;
        var index: c_int = 0;
        _ = c.FcPatternGetInteger(p, c.FC_INDEX, 0, &index);
        var w: f64 = 80; // FC_WEIGHT_REGULAR
        _ = c.FcPatternGetDouble(p, c.FC_WEIGHT, 0, &w);
        var slant: c_int = 0;
        _ = c.FcPatternGetInteger(p, c.FC_SLANT, 0, &slant);
        const path = try self.gpa.dupeSentinel(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file))), 0);
        errdefer self.gpa.free(path);
        try self.strings.append(self.gpa, path);
        return .{
            .source = .{ .file = .{ .path = path, .index = @intCast(index) } },
            .weight = @floatCast(c.FcWeightToOpenTypeDouble(w)),
            .italic = slant != 0,
        };
    }

    /// Resolve a generic family (e.g. "sans-serif") to the concrete family fontconfig picks.
    fn matchFamilyName(self: *FreeTypeTextSystem, family: []const u8) !?[]u8 {
        const name = try self.gpa.dupeSentinel(u8, family, 0);
        defer self.gpa.free(name);
        const pat = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pat);
        _ = c.FcPatternAddString(pat, c.FC_FAMILY, name.ptr);
        _ = c.FcConfigSubstitute(self.fc, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);
        var result: c.FcResult = undefined;
        const m = c.FcFontMatch(self.fc, pat, &result) orelse return null;
        defer c.FcPatternDestroy(m);
        var fam: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(m, c.FC_FAMILY, 0, &fam) != c.FcResultMatch) return null;
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(fam)));
        if (std.ascii.eqlIgnoreCase(s, family)) return null;
        return try self.gpa.dupe(u8, s);
    }

    /// zui's fallback `find_best_match`: style mismatch costs 1000, plus weight distance.
    fn bestMatch(candidates: []const Descriptor, w: f32, style: types.FontStyle) ?usize {
        if (candidates.len == 0) return null;
        const want_italic = style != .normal;
        var best: usize = 0;
        var best_score: f32 = std.math.floatMax(f32);
        for (candidates, 0..) |d, i| {
            const score = (if (d.italic == want_italic) @as(f32, 0) else 1000) + @abs(d.weight - w);
            if (score < best_score) {
                best_score = score;
                best = i;
            }
        }
        return best;
    }

    pub fn fontId(self: *FreeTypeTextSystem, font: types.Font) !FontId {
        const candidates = try self.familyCandidates(font.family);
        const ix = bestMatch(candidates, font.weight, font.style) orelse return error.FontNotFound;
        const desc = candidates[ix];

        var h = std.hash.Wyhash.init(0);
        desc.source.hash(&h);
        for (font.features) |f| h.update(std.mem.asBytes(&f));
        h.update("|");
        for (font.fallbacks) |f| {
            h.update(f);
            h.update("\x00");
        }
        const key = h.final();
        if (self.loaded.get(key)) |id| return id;

        // Recurse with no fallbacks so a fallback family cannot pull in another chain;
        // missing fallback families are skipped.
        var chain: std.ArrayList(FontId) = .empty;
        defer chain.deinit(self.gpa);
        for (font.fallbacks) |fb| {
            const id = self.fontId(.{ .family = fb, .weight = font.weight, .style = font.style, .features = font.features }) catch continue;
            try chain.append(self.gpa, id);
        }
        const id = try self.loadFace(desc, font.features, chain.items);
        try self.loaded.put(self.gpa, key, id);
        return id;
    }

    fn loadFace(self: *FreeTypeTextSystem, desc: Descriptor, features: []const types.FontFeature, chain: []const FontId) !FontId {
        var ft: c.FT_Face = null;
        const err = switch (desc.source) {
            .file => |f| c.FT_New_Face(self.library, f.path.ptr, @intCast(f.index), &ft),
            .memory => |m| c.FT_New_Memory_Face(self.library, m.bytes.ptr, @intCast(m.bytes.len), @intCast(m.index), &ft),
        };
        if (err != 0) return error.InvalidFont;
        errdefer _ = c.FT_Done_Face(ft);

        const blob = switch (desc.source) {
            .file => |f| c.hb_blob_create_from_file(f.path.ptr),
            .memory => |m| c.hb_blob_create(m.bytes.ptr, @intCast(m.bytes.len), c.HB_MEMORY_MODE_READONLY, null, null),
        };
        defer c.hb_blob_destroy(blob);
        const index = desc.source.faceIndex();
        const hb_face = c.hb_face_create(blob, index & 0xFFFF);
        defer c.hb_face_destroy(hb_face);
        const hb_font = c.hb_font_create(hb_face) orelse return error.OutOfMemory;
        errdefer c.hb_font_destroy(hb_font);
        if (index >> 16 != 0) c.hb_font_set_var_named_instance(hb_font, (index >> 16) - 1);

        const hb_features = try self.gpa.alloc(c.hb_feature_t, features.len);
        errdefer self.gpa.free(hb_features);
        for (features, hb_features) |f, *out| out.* = .{
            .tag = (@as(u32, f.tag[0]) << 24) | (@as(u32, f.tag[1]) << 16) | (@as(u32, f.tag[2]) << 8) | f.tag[3],
            .value = f.value,
            .start = 0,
            .end = std.math.maxInt(c_uint),
        };
        const fallback_chain = try self.gpa.dupe(FontId, chain);
        errdefer self.gpa.free(fallback_chain);

        const f = try self.gpa.create(Face);
        errdefer self.gpa.destroy(f);
        // FreeType reports 0 units/em for bitmap-only faces (CBDT emoji); HarfBuzz reads `head`.
        const upem_units: u32 = @max(c.hb_face_get_upem(hb_face), 1);
        const upem: f32 = @floatFromInt(upem_units);
        f.* = .{
            .ft = ft,
            .hb_font = hb_font,
            .features = hb_features,
            .fallback_chain = fallback_chain,
            .is_color = (ft.*.face_flags & c.FT_FACE_FLAG_COLOR) != 0,
            .scalable = (ft.*.face_flags & c.FT_FACE_FLAG_SCALABLE) != 0,
            .weight = faceWeight(ft),
            .italic = faceItalic(ft),
            .upem = upem,
            .metrics = computeMetrics(ft, hb_font, upem_units),
        };
        try self.faces.append(self.gpa, f);
        return @enumFromInt(self.faces.items.len - 1);
    }

    /// Load a system face for fallback use (no features, no chain), deduplicated by source.
    fn loadFallbackFace(self: *FreeTypeTextSystem, desc: Descriptor) !FontId {
        var h = std.hash.Wyhash.init(0);
        desc.source.hash(&h);
        h.update("|");
        const key = h.final();
        if (self.loaded.get(key)) |id| return id;
        const id = try self.loadFace(desc, &.{}, &.{});
        try self.loaded.put(self.gpa, key, id);
        return id;
    }

    fn covers(self: *FreeTypeTextSystem, id: FontId, cp: u21) bool {
        return c.FT_Get_Char_Index(self.face(id).ft, cp) != 0;
    }

    const CoverCtx = struct {
        ts: *FreeTypeTextSystem,
        pub fn covers(self: CoverCtx, id: FontId, cp: u21) bool {
            return self.ts.covers(id, cp);
        }
    };

    /// The system color emoji font (fontconfig "emoji" family with color), if any.
    fn emojiFont(self: *FreeTypeTextSystem) ?FontId {
        if (self.emoji_font) |cached| return cached;
        self.emoji_font = self.findEmojiFont() catch null;
        return self.emoji_font.?;
    }

    fn findEmojiFont(self: *FreeTypeTextSystem) !?FontId {
        const pat = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pat);
        _ = c.FcPatternAddString(pat, c.FC_FAMILY, "emoji");
        _ = c.FcPatternAddBool(pat, c.FC_COLOR, c.FcTrue);
        _ = c.FcConfigSubstitute(self.fc, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);
        var result: c.FcResult = undefined;
        const m = c.FcFontMatch(self.fc, pat, &result) orelse return null;
        defer c.FcPatternDestroy(m);
        const desc = (try self.descriptorFromPattern(m)) orelse return null;
        const id = try self.loadFallbackFace(desc);
        return if (self.face(id).is_color) id else null;
    }

    /// Fontconfig per-character fallback: the best font covering `cp` near the primary's style.
    fn systemFallback(self: *FreeTypeTextSystem, cp: u21, weight_: f32, italic: bool) ?FontId {
        const key: FallbackKey = .{ .cp = cp, .weight = @intFromFloat(@round(weight_)), .italic = italic };
        if (self.fallback_cache.get(key)) |cached| return cached;
        const result = self.findSystemFallback(cp, weight_, italic) catch null;
        self.fallback_cache.put(self.gpa, key, result) catch {};
        return result;
    }

    fn findSystemFallback(self: *FreeTypeTextSystem, cp: u21, weight_: f32, italic: bool) !?FontId {
        const pat = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pat);
        const cs = c.FcCharSetCreate() orelse return error.OutOfMemory;
        defer c.FcCharSetDestroy(cs);
        _ = c.FcCharSetAddChar(cs, cp);
        _ = c.FcPatternAddCharSet(pat, c.FC_CHARSET, cs);
        _ = c.FcPatternAddDouble(pat, c.FC_WEIGHT, c.FcWeightFromOpenTypeDouble(weight_));
        _ = c.FcPatternAddInteger(pat, c.FC_SLANT, if (italic) 100 else 0);
        _ = c.FcConfigSubstitute(self.fc, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);
        var result: c.FcResult = undefined;
        const set = c.FcFontSort(self.fc, pat, c.FcTrue, null, &result);
        if (set == null) return null;
        defer c.FcFontSetDestroy(set);
        for (0..@intCast(set.*.nfont)) |i| {
            const p = set.*.fonts[i];
            var charset: ?*c.FcCharSet = null;
            if (c.FcPatternGetCharSet(p, c.FC_CHARSET, 0, &charset) != c.FcResultMatch) continue;
            if (c.FcCharSetHasChar(charset, cp) == 0) continue;
            const desc = (try self.descriptorFromPattern(p)) orelse continue;
            const id = self.loadFallbackFace(desc) catch continue;
            if (self.covers(id, cp)) return id;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Shaping
    // -----------------------------------------------------------------------

    const Segment = struct { start: usize, end: usize, font_id: FontId };

    /// Pick the font for one grapheme: emoji presentation prefers color fonts; otherwise
    /// the span font, the current fallback, then fontconfig's per-character fallback.
    fn pickFont(self: *FreeTypeTextSystem, cp: u21, want_emoji: bool, primary: FontId, current: FontId) FontId {
        if (want_emoji) {
            if (self.face(primary).is_color and self.covers(primary, cp)) return primary;
            if (self.face(current).is_color and self.covers(current, cp)) return current;
            if (self.emojiFont()) |e| if (self.covers(e, cp)) return e;
        }
        if (cp < 0x80 or self.covers(primary, cp)) return primary;
        if (self.covers(current, cp)) return current;
        if (fallback.isExtend(cp) or cp < 0x20) return current;
        const p = self.face(primary);
        return self.systemFallback(cp, p.weight, p.italic) orelse primary;
    }

    fn appendSegments(self: *FreeTypeTextSystem, out: *std.ArrayList(Segment), text: []const u8, span: fallback.RunSpan) !void {
        var seg_start = span.start;
        var seg_font = span.font_id;
        var current = span.font_id;
        var i = span.start;
        while (i < span.end) {
            const g_end = @min(fallback.graphemeEnd(text, i), span.end);
            const cp = fallback.decodeAt(text, i).cp;
            const f = self.pickFont(cp, fallback.graphemeWantsEmoji(text[i..g_end]), span.font_id, current);
            if (f != seg_font) {
                if (i > seg_start) try pushSegment(self.gpa, out, .{ .start = seg_start, .end = i, .font_id = seg_font });
                seg_start = i;
                seg_font = f;
            }
            current = f;
            i = g_end;
        }
        if (span.end > seg_start) try pushSegment(self.gpa, out, .{ .start = seg_start, .end = span.end, .font_id = seg_font });
    }

    fn pushSegment(gpa: Allocator, out: *std.ArrayList(Segment), seg: Segment) !void {
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.font_id == seg.font_id and last.end == seg.start) {
                last.end = seg.end;
                return;
            }
        }
        try out.append(gpa, seg);
    }

    /// Shape one line with per-run fonts, falling back per grapheme. Result lives in `arena`.
    pub fn layoutLine(self: *FreeTypeTextSystem, arena: Allocator, text: []const u8, font_size: Pixels, runs: []const types.FontRun) !types.LineLayout {
        var spans: std.ArrayList(fallback.RunSpan) = .empty;
        defer spans.deinit(self.gpa);
        var segments: std.ArrayList(Segment) = .empty;
        defer segments.deinit(self.gpa);

        var offset: usize = 0;
        for (runs) |run| {
            const len = @min(run.len, text.len -| offset);
            spans.clearRetainingCapacity();
            try fallback.computeRunSpans(self.gpa, &spans, text, offset, len, run.font_id, self.face(run.font_id).fallback_chain, CoverCtx{ .ts = self });
            for (spans.items) |span| try self.appendSegments(&segments, text, span);
            offset += len;
        }

        var out_runs: std.ArrayList(types.ShapedRun) = .empty;
        var glyphs: std.ArrayList(types.ShapedGlyph) = .empty;
        var run_font: ?FontId = null;
        var pen: f32 = 0;
        var ascent: f32 = 0;
        var descent: f32 = 0;

        for (segments.items) |seg| {
            const f = self.face(seg.font_id);
            const scale = font_size / f.upem;
            ascent = @max(ascent, f.metrics.ascent * scale);
            descent = @max(descent, -f.metrics.descent * scale);

            const buf = self.hb_buffer;
            c.hb_buffer_clear_contents(buf);
            var flags: c_uint = c.HB_BUFFER_FLAG_REMOVE_DEFAULT_IGNORABLES;
            if (seg.start == 0) flags |= c.HB_BUFFER_FLAG_BOT;
            if (seg.end == text.len) flags |= c.HB_BUFFER_FLAG_EOT;
            c.hb_buffer_set_flags(buf, flags);
            c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), @intCast(seg.start), @intCast(seg.end - seg.start));
            c.hb_buffer_guess_segment_properties(buf);
            c.hb_shape(f.hb_font, buf, f.features.ptr, @intCast(f.features.len));

            var n: c_uint = 0;
            const infos = c.hb_buffer_get_glyph_infos(buf, &n);
            const positions = c.hb_buffer_get_glyph_positions(buf, &n);

            if (run_font != seg.font_id) {
                if (run_font) |rf| if (glyphs.items.len > 0) {
                    try out_runs.append(arena, .{ .font_id = rf, .glyphs = try glyphs.toOwnedSlice(arena) });
                };
                glyphs = .empty;
                run_font = seg.font_id;
            }
            for (0..n) |i| {
                const pos = positions[i];
                try glyphs.append(arena, .{
                    .id = infos[i].codepoint,
                    .position = .{
                        .x = pen + @as(f32, @floatFromInt(pos.x_offset)) * scale,
                        .y = -@as(f32, @floatFromInt(pos.y_offset)) * scale,
                    },
                    .index = infos[i].cluster,
                    .is_emoji = f.is_color,
                });
                pen += @as(f32, @floatFromInt(pos.x_advance)) * scale;
            }
        }
        if (run_font) |rf| if (glyphs.items.len > 0) {
            try out_runs.append(arena, .{ .font_id = rf, .glyphs = try glyphs.toOwnedSlice(arena) });
        };
        if (segments.items.len == 0 and runs.len > 0) {
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

    // -----------------------------------------------------------------------
    // Rasterization
    // -----------------------------------------------------------------------

    const Image = struct {
        left: i32,
        top: i32,
        width: u32,
        height: u32,
        /// 1 (mono) or 4 (BGRA) bytes per pixel. Owned by gpa.
        data: []u8,
    };

    /// Render a glyph per `params` (gray, LCD → BGRA coverage, or color BGRA straight alpha).
    fn renderGlyph(self: *FreeTypeTextSystem, gpa: Allocator, params: types.RenderGlyphParams) !Image {
        const f = self.face(params.font_id);
        const ft = f.ft;
        const ppem = params.font_size * params.scale_factor;
        var bitmap_scale: f32 = 1;

        if (f.scalable) {
            const size: c.FT_F26Dot6 = @intFromFloat(@round(ppem * 64));
            if (f.char_size != size) {
                if (c.FT_Set_Char_Size(ft, 0, size, 72, 72) != 0) return error.SetSizeFailed;
                f.char_size = size;
            }
        } else if (ft.*.num_fixed_sizes > 0) {
            const strike = pickStrike(ft, ppem);
            if (f.strike != strike) {
                if (c.FT_Select_Size(ft, strike) != 0) return error.SetSizeFailed;
                f.strike = strike;
            }
            const strike_ppem = @as(f32, @floatFromInt(ft.*.available_sizes[@intCast(strike)].y_ppem)) / 64;
            bitmap_scale = ppem / strike_ppem;
        }

        var delta: c.FT_Vector = .{
            .x = @divTrunc(@as(c.FT_Pos, params.subpixel_variant_x) * 64, types.subpixel_variants_x),
            .y = 0,
        };
        // Raster transform (outline glyphs only; FreeType leaves bitmap strikes untouched).
        // Identity keeps the exact untransformed call below.
        const transformed = !params.is_emoji and !params.raster_transform.isIdentity();
        var matrix: c.FT_Matrix = if (transformed) ftMatrix(params.raster_transform) else undefined;
        c.FT_Set_Transform(ft, if (transformed) &matrix else null, &delta);
        defer c.FT_Set_Transform(ft, null, null);

        // FreeType hints in the untransformed grid and ignores most of it under a transform,
        // so transformed outlines load unhinted (and stay consistent across matrices).
        const load_flags: i32 = if (params.is_emoji) c.FT_LOAD_COLOR else if (transformed) c.FT_LOAD_NO_HINTING else c.FT_LOAD_TARGET_LIGHT;
        if (c.FT_Load_Glyph(ft, params.glyph_id, load_flags) != 0) return error.GlyphLoadFailed;
        const slot = ft.*.glyph;
        const mode: c_uint = if (params.subpixel_rendering and !params.is_emoji) c.FT_RENDER_MODE_LCD else c.FT_RENDER_MODE_NORMAL;
        if (slot.*.format != c.FT_GLYPH_FORMAT_BITMAP or (mode == c.FT_RENDER_MODE_LCD and slot.*.bitmap.pixel_mode != c.FT_PIXEL_MODE_LCD)) {
            if (c.FT_Render_Glyph(slot, mode) != 0) return error.GlyphRenderFailed;
        }
        const bm = slot.*.bitmap;
        const want_bgra = params.is_emoji or params.subpixel_rendering;
        var img = try convertBitmap(gpa, bm, want_bgra, params.is_emoji);
        img.left = slot.*.bitmap_left;
        img.top = slot.*.bitmap_top;
        if (bitmap_scale != 1 and img.width > 0 and img.height > 0) {
            // Resample while premultiplied (FreeType's BGRA is premultiplied), then unpremultiply.
            const scaled = try scaleImage(gpa, img, bitmap_scale, if (want_bgra) 4 else 1);
            gpa.free(img.data);
            img = scaled;
        }
        if (params.is_emoji) unpremultiply(img.data);
        return img;
    }

    /// `RasterTransform` (y down) as FreeType's 16.16 `FT_Matrix` (y up): conjugating by the
    /// y flip negates the off-diagonal terms.
    fn ftMatrix(t: types.RasterTransform) c.FT_Matrix {
        const fixed = struct {
            fn f(v: f32) c.FT_Fixed {
                return @intFromFloat(@round(@as(f64, v) * 65536.0));
            }
        }.f;
        return .{ .xx = fixed(t.a), .xy = fixed(-t.c), .yx = fixed(-t.b), .yy = fixed(t.d) };
    }

    fn pickStrike(ft: c.FT_Face, ppem: f32) c_int {
        var best: c_int = 0;
        var best_ppem: f32 = 0;
        for (0..@intCast(ft.*.num_fixed_sizes)) |i| {
            const p = @as(f32, @floatFromInt(ft.*.available_sizes[i].y_ppem)) / 64;
            const better = if (best_ppem < ppem) p > best_ppem else (p >= ppem and p < best_ppem);
            if (i == 0 or better) {
                best = @intCast(i);
                best_ppem = p;
            }
        }
        return best;
    }

    pub fn glyphRasterBounds(self: *FreeTypeTextSystem, params: types.RenderGlyphParams) !geometry.Bounds(DevicePixels) {
        const img = try self.renderGlyph(self.gpa, params);
        defer self.gpa.free(img.data);
        return .{
            .origin = .{ .x = img.left, .y = -img.top },
            .size = .{ .width = @intCast(img.width), .height = @intCast(img.height) },
        };
    }

    pub fn rasterizeGlyph(self: *FreeTypeTextSystem, gpa: Allocator, params: types.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels)) ![]u8 {
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return error.EmptyGlyph;
        const img = try self.renderGlyph(gpa, params);
        if (img.width == bounds.size.width and img.height == bounds.size.height) return img.data;
        // Bounds came from a different render (should not happen); copy into the expected size.
        defer gpa.free(img.data);
        const bpp: usize = if (params.is_emoji or params.subpixel_rendering) 4 else 1;
        const w: usize = @intCast(bounds.size.width);
        const h: usize = @intCast(bounds.size.height);
        const out = try gpa.alloc(u8, w * h * bpp);
        @memset(out, 0);
        for (0..@min(h, img.height)) |y| {
            const n = @min(w, img.width) * bpp;
            @memcpy(out[y * w * bpp ..][0..n], img.data[y * img.width * bpp ..][0..n]);
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
        const g = c.FT_Get_Char_Index(fromPtr(ptr).face(id).ft, ch);
        return if (g == 0) null else g;
    }
    fn vtAdvance(ptr: *anyopaque, id: FontId, glyph: types.GlyphId) geometry.Size(f32) {
        const f = fromPtr(ptr).face(id);
        return .{
            .width = @floatFromInt(c.hb_font_get_glyph_h_advance(f.hb_font, glyph)),
            .height = @floatFromInt(c.hb_font_get_glyph_v_advance(f.hb_font, glyph)),
        };
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

fn os2(ft: c.FT_Face) ?*const c.TT_OS2 {
    const p = c.FT_Get_Sfnt_Table(ft, c.FT_SFNT_OS2) orelse return null;
    const t: *const c.TT_OS2 = @ptrCast(@alignCast(p));
    return if (t.version == 0xFFFF) null else t;
}

fn faceWeight(ft: c.FT_Face) f32 {
    if (os2(ft)) |t| if (t.usWeightClass != 0) return @floatFromInt(t.usWeightClass);
    return if ((ft.*.style_flags & c.FT_STYLE_FLAG_BOLD) != 0) 700 else 400;
}

fn faceItalic(ft: c.FT_Face) bool {
    return (ft.*.style_flags & c.FT_STYLE_FLAG_ITALIC) != 0;
}

/// Font-unit metrics like swash's: hhea ascent/descent unless OS/2 USE_TYPO_METRICS is set.
/// Bitmap-only faces (where FreeType reports no metrics) use HarfBuzz's extents.
fn computeMetrics(ft: c.FT_Face, hb_font: *c.hb_font_t, upem: u32) types.FontMetrics {
    var ascent: f32 = @floatFromInt(ft.*.ascender);
    var descent: f32 = @floatFromInt(ft.*.descender);
    var line_gap: f32 = @floatFromInt(ft.*.height - ft.*.ascender + ft.*.descender);
    var max_advance: f32 = @floatFromInt(ft.*.max_advance_width);
    var cap_height: f32 = 0;
    var x_height: f32 = 0;
    if (os2(ft)) |t| {
        if ((t.fsSelection & (1 << 7)) != 0) {
            ascent = @floatFromInt(t.sTypoAscender);
            descent = @floatFromInt(t.sTypoDescender);
            line_gap = @floatFromInt(t.sTypoLineGap);
        }
        if (t.version >= 2) {
            cap_height = @floatFromInt(t.sCapHeight);
            x_height = @floatFromInt(t.sxHeight);
        }
    }
    if (ft.*.units_per_EM == 0) {
        var e: c.hb_font_extents_t = undefined;
        if (c.hb_font_get_h_extents(hb_font, &e) != 0) {
            ascent = @floatFromInt(e.ascender);
            descent = @floatFromInt(e.descender);
            line_gap = @floatFromInt(e.line_gap);
        }
        if (max_advance == 0) max_advance = @floatFromInt(upem);
    }
    return .{
        .units_per_em = upem,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .underline_position = @floatFromInt(ft.*.underline_position),
        .underline_thickness = @floatFromInt(ft.*.underline_thickness),
        .cap_height = cap_height,
        .x_height = x_height,
        // As cosmic-text: (0, 0, max advance, ascent + |descent|).
        .bounding_box = .{ .origin = .zero, .size = .{ .width = max_advance, .height = ascent - descent } },
    };
}

/// Convert an FT bitmap to tightly packed A8 or BGRA.
fn convertBitmap(gpa: Allocator, bm: c.FT_Bitmap, want_bgra: bool, is_emoji: bool) !FreeTypeTextSystem.Image {
    const mode: c_int = bm.pixel_mode;
    const w: usize = if (mode == c.FT_PIXEL_MODE_LCD) bm.width / 3 else bm.width;
    const h: usize = bm.rows;
    const bpp: usize = if (want_bgra) 4 else 1;
    const out = try gpa.alloc(u8, w * h * bpp);
    errdefer gpa.free(out);
    const pitch: isize = bm.pitch;
    for (0..h) |y| {
        const row: [*]const u8 = @ptrCast(if (pitch >= 0) bm.buffer + y * @as(usize, @intCast(pitch)) else bm.buffer + (h - 1 - y) * @as(usize, @intCast(-pitch)));
        for (0..w) |x| {
            const dst = out[(y * w + x) * bpp ..][0..bpp];
            switch (mode) {
                c.FT_PIXEL_MODE_BGRA => {
                    if (want_bgra) @memcpy(dst, row[x * 4 ..][0..4]) else dst[0] = row[x * 4 + 3];
                },
                c.FT_PIXEL_MODE_LCD => {
                    const r = row[x * 3];
                    const g = row[x * 3 + 1];
                    const b = row[x * 3 + 2];
                    if (want_bgra) {
                        dst[0] = b;
                        dst[1] = g;
                        dst[2] = r;
                        dst[3] = @max(r, g, b);
                    } else dst[0] = @intCast((@as(u16, r) + g + b) / 3);
                },
                else => {
                    const a: u8 = if (mode == c.FT_PIXEL_MODE_MONO)
                        (if ((row[x / 8] >> @intCast(7 - x % 8)) & 1 != 0) 255 else 0)
                    else
                        row[x];
                    if (want_bgra) {
                        // Emoji from a non-color glyph: black; subpixel: equal coverage.
                        const v: u8 = if (is_emoji) 0 else a;
                        dst[0] = v;
                        dst[1] = v;
                        dst[2] = v;
                        dst[3] = a;
                    } else dst[0] = a;
                },
            }
        }
    }
    return .{ .left = 0, .top = 0, .width = @intCast(w), .height = @intCast(h), .data = out };
}

/// BGRA premultiplied -> straight alpha, in place.
fn unpremultiply(bgra: []u8) void {
    var i: usize = 0;
    while (i + 4 <= bgra.len) : (i += 4) {
        const a: u32 = bgra[i + 3];
        if (a == 0 or a == 255) continue;
        for (0..3) |k| bgra[i + k] = @intCast(@min(255, (@as(u32, bgra[i + k]) * 255 + a / 2) / a));
    }
}

/// Area-averaging resample (for scaling fixed-size bitmap strikes such as CBDT emoji).
fn scaleImage(gpa: Allocator, src: FreeTypeTextSystem.Image, scale: f32, bpp: usize) !FreeTypeTextSystem.Image {
    const fl: f32 = @floatFromInt(src.left);
    const ft_: f32 = @floatFromInt(src.top);
    const sw: f32 = @floatFromInt(src.width);
    const sh: f32 = @floatFromInt(src.height);
    // Destination pixel grid aligned so the origin stays at integer coordinates.
    const left: i32 = @intFromFloat(@floor(fl * scale));
    const top: i32 = @intFromFloat(@ceil(ft_ * scale));
    const right: i32 = @intFromFloat(@ceil((fl + sw) * scale));
    const bottom_y: i32 = @intFromFloat(@floor((ft_ - sh) * scale));
    const dw: usize = @intCast(@max(right - left, 1));
    const dh: usize = @intCast(@max(top - bottom_y, 1));
    const out = try gpa.alloc(u8, dw * dh * bpp);
    errdefer gpa.free(out);
    const inv = 1 / scale;
    for (0..dh) |dy| {
        // Source y range (in source pixel rows, top-down) covered by this destination row.
        const y0 = (ft_ - (@as(f32, @floatFromInt(top)) - @as(f32, @floatFromInt(dy))) * inv);
        const y1 = y0 + inv;
        for (0..dw) |dx| {
            const x0 = (@as(f32, @floatFromInt(left)) + @as(f32, @floatFromInt(dx))) * inv - fl;
            const x1 = x0 + inv;
            var acc: [4]f32 = @splat(0);
            var total: f32 = 0;
            var sy: i32 = @intFromFloat(@floor(y0));
            while (@as(f32, @floatFromInt(sy)) < y1) : (sy += 1) {
                const wy = @min(y1, @as(f32, @floatFromInt(sy + 1))) - @max(y0, @as(f32, @floatFromInt(sy)));
                if (wy <= 0) continue;
                var sx: i32 = @intFromFloat(@floor(x0));
                while (@as(f32, @floatFromInt(sx)) < x1) : (sx += 1) {
                    const wx = @min(x1, @as(f32, @floatFromInt(sx + 1))) - @max(x0, @as(f32, @floatFromInt(sx)));
                    if (wx <= 0) continue;
                    const wgt = wx * wy;
                    total += wgt;
                    if (sx < 0 or sy < 0 or sx >= src.width or sy >= src.height) continue;
                    const p = src.data[(@as(usize, @intCast(sy)) * src.width + @as(usize, @intCast(sx))) * bpp ..][0..bpp];
                    for (0..bpp) |k| acc[k] += @as(f32, @floatFromInt(p[k])) * wgt;
                }
            }
            const dst = out[(dy * dw + dx) * bpp ..][0..bpp];
            for (0..bpp) |k| dst[k] = if (total > 0) @intFromFloat(@min(255, @round(acc[k] / total))) else 0;
        }
    }
    return .{ .left = left, .top = top, .width = @intCast(dw), .height = @intCast(dh), .data = out };
}

test "freetype raster transforms: sheared 'A' covers its transformed outline; identity is byte-identical" {
    const gpa = std.testing.allocator;
    const fts = try FreeTypeTextSystem.create(gpa);
    defer fts.destroy();
    const ts = fts.textSystem();
    try std.testing.expect(ts.vtable.raster_transforms);
    const id = fts.fontId(.{ .family = "Inter" }) catch fts.fontId(.{ .family = "DejaVu Sans" }) catch return error.SkipZigTest;
    const glyph = c.FT_Get_Char_Index(fts.face(id).ft, 'A');
    if (glyph == 0) return error.SkipZigTest;
    const plain: types.RenderGlyphParams = .{ .font_id = id, .glyph_id = glyph, .font_size = 24, .subpixel_variant_x = 0, .subpixel_variant_y = 0, .is_emoji = false, .subpixel_rendering = false, .scale_factor = 2 };

    const ref_bounds = try fts.glyphRasterBounds(plain);
    const ref = try fts.rasterizeGlyph(gpa, plain, ref_bounds);
    defer gpa.free(ref);

    // Identity (explicit, with signed zeros) is the untransformed path, byte for byte.
    var ident = plain;
    ident.raster_transform = .{ .a = 1, .b = -0.0, .c = -0.0, .d = 1 };
    for ([_]u8{ 0, 2 }) |variant| {
        var p0 = plain;
        p0.subpixel_variant_x = variant;
        var p1 = ident;
        p1.subpixel_variant_x = variant;
        const b0 = try fts.glyphRasterBounds(p0);
        try std.testing.expectEqual(b0, try fts.glyphRasterBounds(p1));
        const bm0 = try fts.rasterizeGlyph(gpa, p0, b0);
        defer gpa.free(bm0);
        const bm1 = try fts.rasterizeGlyph(gpa, p1, b0);
        defer gpa.free(bm1);
        try std.testing.expectEqualSlices(u8, bm0, bm1);
    }

    // The upright outline at the same size (unhinted, no transform), in y-down device px.
    _ = try fts.glyphRasterBounds(plain); // sets the char size
    const ft = fts.face(id).ft;
    if (c.FT_Load_Glyph(ft, glyph, c.FT_LOAD_NO_HINTING | c.FT_LOAD_NO_BITMAP) != 0) return error.GlyphLoadFailed;
    const outline = ft.*.glyph.*.outline;
    try std.testing.expect(outline.n_points > 0);
    // Copy: the glyph slot is reused by the renders below.
    const points = try gpa.dupe(c.FT_Vector, outline.points[0..@intCast(outline.n_points)]);
    defer gpa.free(points);

    const cases = [_]types.RasterTransform{
        // Up leans right by 0.5 per unit.
        types.RasterTransform.fromBasis(.{ 1, 0 }, .{ 0.5, -1 }),
        // A keyboard plane in 3/4 view: rows slope down to the right, keys foreshortened.
        types.RasterTransform.fromBasis(.{ 0.95, 0.18 }, .{ 0.42, -0.62 }),
        // Rotated 90 degrees clockwise.
        .{ .a = 0, .b = 1, .c = -1, .d = 0 },
    };
    for (cases) |t| {
        var p = plain;
        p.raster_transform = t;
        const b = try fts.glyphRasterBounds(p);
        const bm = try fts.rasterizeGlyph(gpa, p, b);
        defer gpa.free(bm);
        const w: usize = @intCast(b.size.width);
        const h: usize = @intCast(b.size.height);
        try std.testing.expectEqual(w * h, bm.len);
        // Ink bbox, device px relative to the glyph origin.
        var ink: [4]i32 = .{ std.math.maxInt(i32), std.math.maxInt(i32), std.math.minInt(i32), std.math.minInt(i32) };
        for (0..h) |y| for (0..w) |x| if (bm[y * w + x] > 0) {
            const dx = b.origin.x + @as(i32, @intCast(x));
            const dy = b.origin.y + @as(i32, @intCast(y));
            ink = .{ @min(ink[0], dx), @min(ink[1], dy), @max(ink[2], dx + 1), @max(ink[3], dy + 1) };
        };
        // Transformed outline bbox ('A' is straight segments: the points' box is the outline's).
        var ob: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (points) |pt| {
            const q = t.apply(.{ .x = @as(f32, @floatFromInt(pt.x)) / 64, .y = -@as(f32, @floatFromInt(pt.y)) / 64 });
            ob = .{ @min(ob[0], q.x), @min(ob[1], q.y), @max(ob[2], q.x), @max(ob[3], q.y) };
        }
        const expect: [4]i32 = .{ @intFromFloat(@floor(ob[0])), @intFromFloat(@floor(ob[1])), @intFromFloat(@ceil(ob[2])), @intFromFloat(@ceil(ob[3])) };
        for (ink, expect) |got, want| {
            if (@abs(got - want) > 1) {
                std.debug.print("transform {any}: ink bbox {any}, outline bbox {any}\n", .{ t, ink, expect });
                return error.TestUnexpectedResult;
            }
        }
        // The bounds the atlas allocates hold all the ink.
        try std.testing.expect(ink[0] >= b.origin.x and ink[1] >= b.origin.y and ink[2] <= b.origin.x + b.size.width and ink[3] <= b.origin.y + b.size.height);
    }
    // The transform is restored: a plain render after transformed ones matches the first.
    try std.testing.expectEqual(ref_bounds, try fts.glyphRasterBounds(plain));
    const again = try fts.rasterizeGlyph(gpa, plain, ref_bounds);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, ref, again);
}
