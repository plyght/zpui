//! Installed font families (gpui `TextSystem::all_font_names` + zeron's
//! `installed_families_with_latin_metrics`): every family the OS offers that
//! has a Latin `m` glyph, each flagged fixed-width when the advances of
//! `i`, `m`, `W` and `0` agree within 1% in every face (the terminal's cell
//! grid needs measured equal advances, not PANOSE metadata).
//!
//! macOS: `CTFontManagerCopyAvailableFontFamilyNames` + a CoreText face per
//! family. Linux: fontconfig's family list + FreeType per file. Other targets
//! (and the test platform) return an empty list.
//!
//! ```zig
//! const fams = try zpui.text.font_catalog.installedFamilies(gpa); // sorted, unique
//! defer zpui.text.font_catalog.freeFamilies(gpa, fams);
//! for (fams) |f| if (f.fixed_width) ...;
//! ```
//!
//! Slow (it opens every installed face): call it off the main thread.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Family = struct {
    name: []const u8,
    fixed_width: bool,
};

/// Relative spread the sampled advances may show and still count as fixed width.
pub const fixed_width_tolerance: f32 = 0.01;

/// The advances of `i m W 0` (any 0 = glyph missing) → fixed width.
pub fn advancesFixedWidth(advances: [4]f32) bool {
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = 0;
    for (advances) |a| {
        if (!(a > 0)) return false;
        lo = @min(lo, a);
        hi = @max(hi, a);
    }
    return hi - lo <= fixed_width_tolerance * lo;
}

pub fn freeFamilies(gpa: Allocator, families: []Family) void {
    for (families) |f| gpa.free(f.name);
    gpa.free(families);
}

/// Accumulates faces per family: a family is fixed width only when every face is.
const Collector = struct {
    gpa: Allocator,
    map: std.StringArrayHashMapUnmanaged(bool) = .empty,

    fn add(self: *Collector, name: []const u8, fixed: bool) !void {
        if (name.len == 0 or name[0] == '.') return; // hidden system families
        const gop = try self.map.getOrPut(self.gpa, name);
        if (gop.found_existing) {
            gop.value_ptr.* = gop.value_ptr.* and fixed;
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
            gop.value_ptr.* = fixed;
        }
    }

    fn finish(self: *Collector) ![]Family {
        defer self.map.deinit(self.gpa);
        const out = try self.gpa.alloc(Family, self.map.count());
        for (self.map.keys(), self.map.values(), out) |k, v, *o| o.* = .{ .name = k, .fixed_width = v };
        std.mem.sort(Family, out, {}, struct {
            fn lt(_: void, a: Family, b: Family) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        return out;
    }

    fn deinit(self: *Collector) void {
        for (self.map.keys()) |k| self.gpa.free(k);
        self.map.deinit(self.gpa);
    }
};

/// Every installed family with Latin metrics (sorted by name; owned).
pub fn installedFamilies(gpa: Allocator) ![]Family {
    var col: Collector = .{ .gpa = gpa };
    errdefer col.deinit();
    switch (builtin.os.tag) {
        .macos => try mac.collect(&col),
        .linux => try linux.collect(&col),
        else => {},
    }
    return col.finish();
}

// ---- macOS ----------------------------------------------------------------------------

const mac = if (builtin.os.tag == .macos) struct {
    const cf = @import("../platform/mac/cf.zig");
    extern "c" fn CTFontManagerCopyAvailableFontFamilyNames() ?cf.CFArrayRef;
    extern "c" fn CTFontCreateWithName(name: cf.CFStringRef, size: cf.CGFloat, matrix: ?*const anyopaque) ?cf.CTFontRef;

    fn collect(col: *Collector) !void {
        const names = CTFontManagerCopyAvailableFontFamilyNames() orelse return;
        defer cf.CFRelease(names);
        const n = cf.CFArrayGetCount(names);
        var buf: [512]u8 = undefined;
        var i: cf.CFIndex = 0;
        while (i < n) : (i += 1) {
            const s: cf.CFStringRef = @ptrCast(cf.CFArrayGetValueAtIndex(names, i) orelse continue);
            const name = cf.stringToUtf8(s, &buf);
            if (name.len == 0 or name[0] == '.') continue;
            const fixed = familyFixed(name) orelse continue;
            try col.add(name, fixed);
        }
    }

    /// null when the family's regular face has no `m`.
    fn familyFixed(name: []const u8) ?bool {
        const s = cf.string(name) orelse return null;
        defer cf.CFRelease(s);
        const font = CTFontCreateWithName(s, 64, null) orelse return null;
        defer cf.CFRelease(font);
        const chars = [_]u16{ 'i', 'm', 'W', '0' };
        var glyphs: [4]cf.CGGlyph = .{ 0, 0, 0, 0 };
        _ = cf.CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 4);
        if (glyphs[1] == 0) return null;
        var adv: [4]cf.CGSize = undefined;
        _ = cf.CTFontGetAdvancesForGlyphs(font, cf.kCTFontOrientationDefault, &glyphs, &adv, 4);
        var a: [4]f32 = undefined;
        for (&a, adv, glyphs) |*o, v, g| o.* = if (g == 0) 0 else @floatCast(v.width);
        return advancesFixedWidth(a);
    }
} else struct {};

// ---- Linux ----------------------------------------------------------------------------

const linux = if (builtin.os.tag == .linux) struct {
    const c = @import("freetype_c");

    fn collect(col: *Collector) !void {
        const fc = c.FcInitLoadConfigAndFonts() orelse return;
        defer c.FcConfigDestroy(fc);
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return;
        defer _ = c.FT_Done_FreeType(lib);
        const pat = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pat);
        const os = c.FcObjectSetBuild(c.FC_FAMILY, c.FC_FILE, c.FC_INDEX, @as(?*anyopaque, null));
        defer c.FcObjectSetDestroy(os);
        const set = c.FcFontList(fc, pat, os) orelse return;
        defer c.FcFontSetDestroy(set);
        // One measurement per file+index (fontconfig lists a face once per family name).
        var i: usize = 0;
        while (i < @as(usize, @intCast(set.*.nfont))) : (i += 1) {
            const p = set.*.fonts[i];
            var file: [*c]c.FcChar8 = null;
            if (c.FcPatternGetString(p, c.FC_FILE, 0, &file) != c.FcResultMatch) continue;
            var index: c_int = 0;
            _ = c.FcPatternGetInteger(p, c.FC_INDEX, 0, &index);
            const fixed = faceFixed(lib, file, index) orelse continue;
            var k: c_int = 0;
            while (true) : (k += 1) {
                var fam: [*c]c.FcChar8 = null;
                if (c.FcPatternGetString(p, c.FC_FAMILY, k, &fam) != c.FcResultMatch) break;
                try col.add(std.mem.span(@as([*:0]const u8, @ptrCast(fam))), fixed);
            }
        }
    }

    /// null when the face can't load or has no `m`.
    fn faceFixed(lib: c.FT_Library, file: [*c]const c.FcChar8, index: c_int) ?bool {
        var face: c.FT_Face = null;
        if (c.FT_New_Face(lib, @ptrCast(file), index, &face) != 0) return null;
        defer _ = c.FT_Done_Face(face);
        var a: [4]f32 = undefined;
        for ("imW0", &a, 0..) |ch, *o, k| {
            const g = c.FT_Get_Char_Index(face, ch);
            if (g == 0) {
                if (k == 1) return null; // no Latin `m`
                o.* = 0;
                continue;
            }
            if (c.FT_Load_Glyph(face, g, c.FT_LOAD_NO_SCALE | c.FT_LOAD_NO_HINTING) != 0) {
                o.* = 0;
                continue;
            }
            o.* = @floatFromInt(face.*.glyph.*.advance.x);
        }
        return advancesFixedWidth(a);
    }
} else struct {};

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "fixed width needs every sampled advance within 1%" {
    try testing.expect(advancesFixedWidth(.{ 600, 600, 600, 600 }));
    try testing.expect(advancesFixedWidth(.{ 600, 603, 600, 601 }));
    try testing.expect(!advancesFixedWidth(.{ 278, 833, 944, 556 }));
    try testing.expect(!advancesFixedWidth(.{ 600, 0, 600, 600 }));
}

test "installed families are sorted, unique and visible" {
    const fams = try installedFamilies(testing.allocator);
    defer freeFamilies(testing.allocator, fams);
    for (fams, 0..) |f, i| {
        try testing.expect(f.name.len > 0 and f.name[0] != '.');
        if (i > 0) try testing.expect(std.mem.lessThan(u8, fams[i - 1].name, f.name));
    }
}
