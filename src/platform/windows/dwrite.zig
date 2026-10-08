//! Hand-written DirectWrite bindings for src/text/directwrite.zig (Windows 10+).
//! Vtables list every slot in SDK order (inherited first; MSVC orders overloads in
//! reverse declaration order, which only matters for slots marked `Unused` here).

const std = @import("std");
const w = @import("win32.zig");

const WINAPI = w.WINAPI;
const HRESULT = w.HRESULT;
const BOOL = w.BOOL;
const UINT32 = u32;
const GUID = w.GUID;
const Unused = w.Unused;
const IUnknownMethods = w.IUnknownMethods;

pub const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;
pub const DWRITE_FONT_WEIGHT = u32;
pub const DWRITE_FONT_STYLE_NORMAL: u32 = 0;
pub const DWRITE_FONT_STYLE_OBLIQUE: u32 = 1;
pub const DWRITE_FONT_STYLE_ITALIC: u32 = 2;
pub const DWRITE_FONT_STRETCH_NORMAL: u32 = 5;
pub const DWRITE_FONT_SIMULATIONS_NONE: u32 = 0;
pub const DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC: u32 = 5;
pub const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;
pub const DWRITE_GRID_FIT_MODE_DEFAULT: u32 = 0;
pub const DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 1;
pub const DWRITE_TEXTURE_ALIASED_1x1: u32 = 0;
pub const DWRITE_READING_DIRECTION_LEFT_TO_RIGHT: u32 = 0;
pub const DWRITE_E_NOCOLOR: HRESULT = @bitCast(@as(u32, 0x8898500C));
pub const E_NOT_SUFFICIENT_BUFFER: HRESULT = @bitCast(@as(u32, 0x8007007A));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub fn tag(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24);
}

pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const DWRITE_GLYPH_OFFSET = extern struct { advanceOffset: f32 = 0, ascenderOffset: f32 = 0 };

pub const DWRITE_SCRIPT_ANALYSIS = extern struct { script: u16, shapes: u32 };

pub const DWRITE_FONT_FEATURE = extern struct { nameTag: u32, parameter: u32 };
pub const DWRITE_TYPOGRAPHIC_FEATURES = extern struct { features: [*]const DWRITE_FONT_FEATURE, featureCount: u32 };

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: *IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32 = null,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET = null,
    isSideways: BOOL = 0,
    bidiLevel: u32 = 0,
};

pub const DWRITE_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };

pub const DWRITE_COLOR_GLYPH_RUN = extern struct {
    glyphRun: DWRITE_GLYPH_RUN,
    glyphRunDescription: ?*anyopaque,
    baselineOriginX: f32,
    baselineOriginY: f32,
    runColor: DWRITE_COLOR_F,
    paletteIndex: u16,
};

// ---- interfaces ---------------------------------------------------------------------------

pub const IDWriteFactory = extern struct {
    vtbl: *const VTable,
    pub const iid = GUID.parse("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
    pub const iid2 = GUID.parse("0439fc60-ca44-4994-8dee-3a9af7b732ec");
    pub const iid5 = GUID.parse("958db99a-be2a-4f09-af7d-65189803d1d3");
    const Self = IDWriteFactory;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetSystemFontCollection: *const fn (*Self, *?*IDWriteFontCollection, BOOL) callconv(WINAPI) HRESULT,
        CreateCustomFontCollection: Unused,
        RegisterFontCollectionLoader: Unused,
        UnregisterFontCollectionLoader: Unused,
        CreateFontFileReference: Unused,
        CreateCustomFontFileReference: Unused,
        CreateFontFace: *const fn (*Self, u32, u32, [*]const *IDWriteFontFile, u32, u32, *?*IDWriteFontFace) callconv(WINAPI) HRESULT,
        CreateRenderingParams: Unused,
        CreateMonitorRenderingParams: Unused,
        CreateCustomRenderingParams: Unused,
        RegisterFontFileLoader: *const fn (*Self, *anyopaque) callconv(WINAPI) HRESULT,
        UnregisterFontFileLoader: *const fn (*Self, *anyopaque) callconv(WINAPI) HRESULT,
        CreateTextFormat: Unused,
        CreateTypography: Unused,
        GetGdiInterop: Unused,
        CreateTextLayout: Unused,
        CreateGdiCompatibleTextLayout: Unused,
        CreateEllipsisTrimmingSign: Unused,
        CreateTextAnalyzer: *const fn (*Self, *?*IDWriteTextAnalyzer) callconv(WINAPI) HRESULT,
        CreateNumberSubstitution: Unused,
        CreateGlyphRunAnalysis: Unused,
        // IDWriteFactory1
        GetEudcFontCollection: Unused,
        CreateCustomRenderingParams1: Unused,
        // IDWriteFactory2
        GetSystemFontFallback: *const fn (*Self, *?*IDWriteFontFallback) callconv(WINAPI) HRESULT,
        CreateFontFallbackBuilder: Unused,
        TranslateColorGlyphRun: *const fn (*Self, f32, f32, *const DWRITE_GLYPH_RUN, ?*const anyopaque, u32, ?*const anyopaque, u32, *?*IDWriteColorGlyphRunEnumerator) callconv(WINAPI) HRESULT,
        CreateCustomRenderingParams2: Unused,
        CreateGlyphRunAnalysis2: *const fn (*Self, *const DWRITE_GLYPH_RUN, ?*const anyopaque, u32, u32, u32, u32, f32, f32, *?*IDWriteGlyphRunAnalysis) callconv(WINAPI) HRESULT,
        // IDWriteFactory3
        _f3: [9]Unused,
        // IDWriteFactory4
        _f4: [3]Unused,
        // IDWriteFactory5 (only through a pointer queried with `iid5`)
        CreateFontSetBuilder5: Unused,
        CreateInMemoryFontFileLoader: *const fn (*Self, *?*IDWriteInMemoryFontFileLoader) callconv(WINAPI) HRESULT,
    };
};

pub const IDWriteInMemoryFontFileLoader = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteInMemoryFontFileLoader;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        CreateStreamFromKey: Unused,
        CreateInMemoryFontFileReference: *const fn (*Self, *IDWriteFactory, *const anyopaque, u32, ?*w.IUnknown, *?*IDWriteFontFile) callconv(WINAPI) HRESULT,
        GetFileCount: Unused,
    };
};

pub const IDWriteFontFile = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteFontFile;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetReferenceKey: *const fn (*Self, *?*const anyopaque, *u32) callconv(WINAPI) HRESULT,
        GetLoader: Unused,
        /// (isSupportedFontType, fontFileType, fontFaceType, numberOfFaces)
        Analyze: *const fn (*Self, *BOOL, *u32, *u32, *u32) callconv(WINAPI) HRESULT,
    };
};

pub const IDWriteFontCollection = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteFontCollection;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetFontFamilyCount: *const fn (*Self) callconv(WINAPI) u32,
        GetFontFamily: *const fn (*Self, u32, *?*IDWriteFontFamily) callconv(WINAPI) HRESULT,
        FindFamilyName: *const fn (*Self, w.LPCWSTR, *u32, *BOOL) callconv(WINAPI) HRESULT,
        GetFontFromFontFace: Unused,
    };
};

pub const IDWriteFontFamily = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteFontFamily;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        // IDWriteFontList
        GetFontCollection: Unused,
        GetFontCount: *const fn (*Self) callconv(WINAPI) u32,
        GetFont: *const fn (*Self, u32, *?*IDWriteFont) callconv(WINAPI) HRESULT,
        // IDWriteFontFamily
        GetFamilyNames: *const fn (*Self, *?*IDWriteLocalizedStrings) callconv(WINAPI) HRESULT,
        GetFirstMatchingFont: *const fn (*Self, u32, u32, u32, *?*IDWriteFont) callconv(WINAPI) HRESULT,
        GetMatchingFonts: Unused,
    };
};

pub const IDWriteLocalizedStrings = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteLocalizedStrings;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetCount: *const fn (*Self) callconv(WINAPI) u32,
        FindLocaleName: *const fn (*Self, w.LPCWSTR, *u32, *BOOL) callconv(WINAPI) HRESULT,
        GetLocaleNameLength: Unused,
        GetLocaleName: Unused,
        GetStringLength: *const fn (*Self, u32, *u32) callconv(WINAPI) HRESULT,
        GetString: *const fn (*Self, u32, [*]u16, u32) callconv(WINAPI) HRESULT,
    };
};

pub const IDWriteFont = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteFont;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetFontFamily: *const fn (*Self, *?*IDWriteFontFamily) callconv(WINAPI) HRESULT,
        GetWeight: *const fn (*Self) callconv(WINAPI) u32,
        GetStretch: Unused,
        GetStyle: *const fn (*Self) callconv(WINAPI) u32,
        IsSymbolFont: Unused,
        GetFaceNames: Unused,
        GetInformationalStrings: Unused,
        GetSimulations: *const fn (*Self) callconv(WINAPI) u32,
        GetMetrics: Unused,
        HasCharacter: *const fn (*Self, u32, *BOOL) callconv(WINAPI) HRESULT,
        CreateFontFace: *const fn (*Self, *?*IDWriteFontFace) callconv(WINAPI) HRESULT,
    };
};

pub const IDWriteFontFace = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteFontFace;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetType: *const fn (*Self) callconv(WINAPI) u32,
        GetFiles: *const fn (*Self, *u32, ?[*]?*IDWriteFontFile) callconv(WINAPI) HRESULT,
        GetIndex: *const fn (*Self) callconv(WINAPI) u32,
        GetSimulations: *const fn (*Self) callconv(WINAPI) u32,
        IsSymbolFont: Unused,
        GetMetrics: *const fn (*Self, *DWRITE_FONT_METRICS) callconv(WINAPI) void,
        GetGlyphCount: *const fn (*Self) callconv(WINAPI) u16,
        GetDesignGlyphMetrics: *const fn (*Self, [*]const u16, u32, [*]DWRITE_GLYPH_METRICS, BOOL) callconv(WINAPI) HRESULT,
        GetGlyphIndices: *const fn (*Self, [*]const u32, u32, [*]u16) callconv(WINAPI) HRESULT,
        TryGetFontTable: *const fn (*Self, u32, *?*const anyopaque, *u32, *?*anyopaque, *BOOL) callconv(WINAPI) HRESULT,
        ReleaseFontTable: *const fn (*Self, ?*anyopaque) callconv(WINAPI) void,
    };
};

pub const IDWriteTextAnalyzer = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteTextAnalyzer;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        AnalyzeScript: *const fn (*Self, *TextAnalysisSource, u32, u32, *TextAnalysisSink) callconv(WINAPI) HRESULT,
        AnalyzeBidi: Unused,
        AnalyzeNumberSubstitution: Unused,
        AnalyzeLineBreakpoints: Unused,
        GetGlyphs: *const fn (
            *Self,
            [*]const u16,
            u32,
            *IDWriteFontFace,
            BOOL,
            BOOL,
            *const DWRITE_SCRIPT_ANALYSIS,
            ?w.LPCWSTR,
            ?*anyopaque,
            ?[*]const *const DWRITE_TYPOGRAPHIC_FEATURES,
            ?[*]const u32,
            u32,
            u32,
            [*]u16,
            [*]u16,
            [*]u16,
            [*]u16,
            *u32,
        ) callconv(WINAPI) HRESULT,
        GetGlyphPlacements: *const fn (
            *Self,
            [*]const u16,
            [*]const u16,
            [*]u16,
            u32,
            [*]const u16,
            [*]const u16,
            u32,
            *IDWriteFontFace,
            f32,
            BOOL,
            BOOL,
            *const DWRITE_SCRIPT_ANALYSIS,
            ?w.LPCWSTR,
            ?[*]const *const DWRITE_TYPOGRAPHIC_FEATURES,
            ?[*]const u32,
            u32,
            [*]f32,
            [*]DWRITE_GLYPH_OFFSET,
        ) callconv(WINAPI) HRESULT,
    };
};

pub const IDWriteFontFallback = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteFontFallback;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        MapCharacters: *const fn (*Self, *TextAnalysisSource, u32, u32, ?*IDWriteFontCollection, ?w.LPCWSTR, u32, u32, u32, *u32, *?*IDWriteFont, *f32) callconv(WINAPI) HRESULT,
    };
};

pub const IDWriteGlyphRunAnalysis = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteGlyphRunAnalysis;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        GetAlphaTextureBounds: *const fn (*Self, u32, *w.RECT) callconv(WINAPI) HRESULT,
        CreateAlphaTexture: *const fn (*Self, u32, *const w.RECT, [*]u8, u32) callconv(WINAPI) HRESULT,
        GetAlphaBlendParams: Unused,
    };
};

pub const IDWriteColorGlyphRunEnumerator = extern struct {
    vtbl: *const VTable,
    const Self = IDWriteColorGlyphRunEnumerator;
    pub const VTable = extern struct {
        base: IUnknownMethods(Self),
        MoveNext: *const fn (*Self, *BOOL) callconv(WINAPI) HRESULT,
        GetCurrentRun: *const fn (*Self, *?*const DWRITE_COLOR_GLYPH_RUN) callconv(WINAPI) HRESULT,
    };
};

// ---- client-implemented interfaces (text analysis source / sink) --------------------------

pub const IID_IDWriteTextAnalysisSource = GUID.parse("688e1a58-5094-47c8-adc8-fbcea60ae92b");
pub const IID_IDWriteTextAnalysisSink = GUID.parse("5810cd44-0ca0-4701-b3fa-bec5182ae4f6");

/// IDWriteTextAnalysisSource over one UTF-16 string (stack-owned: refcounting is a no-op).
pub const TextAnalysisSource = extern struct {
    vtbl: *const VTable = &vtable,
    text: [*]const u16,
    len: u32,

    const Self = TextAnalysisSource;
    pub const VTable = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*Self) callconv(WINAPI) u32,
        Release: *const fn (*Self) callconv(WINAPI) u32,
        GetTextAtPosition: *const fn (*Self, u32, *?[*]const u16, *u32) callconv(WINAPI) HRESULT,
        GetTextBeforePosition: *const fn (*Self, u32, *?[*]const u16, *u32) callconv(WINAPI) HRESULT,
        GetParagraphReadingDirection: *const fn (*Self) callconv(WINAPI) u32,
        GetLocaleName: *const fn (*Self, u32, *u32, *?[*:0]const u16) callconv(WINAPI) HRESULT,
        GetNumberSubstitution: *const fn (*Self, u32, *u32, *?*anyopaque) callconv(WINAPI) HRESULT,
    };
    const vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = refNoop,
        .Release = refNoop,
        .GetTextAtPosition = getTextAtPosition,
        .GetTextBeforePosition = getTextBeforePosition,
        .GetParagraphReadingDirection = readingDirection,
        .GetLocaleName = getLocaleName,
        .GetNumberSubstitution = getNumberSubstitution,
    };
    const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

    fn queryInterface(self: *Self, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (std.meta.eql(iid.*, IID_IDWriteTextAnalysisSource) or std.meta.eql(iid.*, w.IID_IUnknown)) {
            out.* = self;
            return w.S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }
    fn refNoop(_: *Self) callconv(WINAPI) u32 {
        return 1;
    }
    fn getTextAtPosition(self: *Self, pos: u32, text: *?[*]const u16, len: *u32) callconv(WINAPI) HRESULT {
        if (pos >= self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text + pos;
            len.* = self.len - pos;
        }
        return w.S_OK;
    }
    fn getTextBeforePosition(self: *Self, pos: u32, text: *?[*]const u16, len: *u32) callconv(WINAPI) HRESULT {
        if (pos == 0 or pos > self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text;
            len.* = pos;
        }
        return w.S_OK;
    }
    fn readingDirection(_: *Self) callconv(WINAPI) u32 {
        return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
    }
    fn getLocaleName(self: *Self, pos: u32, len: *u32, name: *?[*:0]const u16) callconv(WINAPI) HRESULT {
        len.* = self.len -| pos;
        name.* = locale;
        return w.S_OK;
    }
    fn getNumberSubstitution(self: *Self, pos: u32, len: *u32, subst: *?*anyopaque) callconv(WINAPI) HRESULT {
        len.* = self.len -| pos;
        subst.* = null;
        return w.S_OK;
    }
};

pub const ScriptRun = struct { start: u32, len: u32, analysis: DWRITE_SCRIPT_ANALYSIS };

/// IDWriteTextAnalysisSink collecting script runs into a caller-owned list.
pub const TextAnalysisSink = extern struct {
    vtbl: *const VTable = &vtable,
    runs: *std.ArrayList(ScriptRun),
    gpa: *const std.mem.Allocator,
    failed: bool = false,

    const Self = TextAnalysisSink;
    pub const VTable = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*Self) callconv(WINAPI) u32,
        Release: *const fn (*Self) callconv(WINAPI) u32,
        SetScriptAnalysis: *const fn (*Self, u32, u32, *const DWRITE_SCRIPT_ANALYSIS) callconv(WINAPI) HRESULT,
        SetLineBreakpoints: *const fn (*Self, u32, u32, ?*const anyopaque) callconv(WINAPI) HRESULT,
        SetBidiLevel: *const fn (*Self, u32, u32, u8, u8) callconv(WINAPI) HRESULT,
        SetNumberSubstitution: *const fn (*Self, u32, u32, ?*anyopaque) callconv(WINAPI) HRESULT,
    };
    const vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = refNoop,
        .Release = refNoop,
        .SetScriptAnalysis = setScriptAnalysis,
        .SetLineBreakpoints = ignore3,
        .SetBidiLevel = ignoreBidi,
        .SetNumberSubstitution = ignoreSubst,
    };

    fn queryInterface(self: *Self, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (std.meta.eql(iid.*, IID_IDWriteTextAnalysisSink) or std.meta.eql(iid.*, w.IID_IUnknown)) {
            out.* = self;
            return w.S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }
    fn refNoop(_: *Self) callconv(WINAPI) u32 {
        return 1;
    }
    fn setScriptAnalysis(self: *Self, pos: u32, len: u32, a: *const DWRITE_SCRIPT_ANALYSIS) callconv(WINAPI) HRESULT {
        self.runs.append(self.gpa.*, .{ .start = pos, .len = len, .analysis = a.* }) catch {
            self.failed = true;
        };
        return w.S_OK;
    }
    fn ignore3(_: *Self, _: u32, _: u32, _: ?*const anyopaque) callconv(WINAPI) HRESULT {
        return w.S_OK;
    }
    fn ignoreBidi(_: *Self, _: u32, _: u32, _: u8, _: u8) callconv(WINAPI) HRESULT {
        return w.S_OK;
    }
    fn ignoreSubst(_: *Self, _: u32, _: u32, _: ?*anyopaque) callconv(WINAPI) HRESULT {
        return w.S_OK;
    }
};

pub extern "dwrite" fn DWriteCreateFactory(factory_type: u32, iid: *const GUID, factory: *?*anyopaque) callconv(WINAPI) HRESULT;

comptime {
    const slot = struct {
        fn of(comptime T: type, comptime name: []const u8) usize {
            return @offsetOf(T, name) / @sizeOf(usize);
        }
    }.of;
    std.debug.assert(slot(IDWriteFactory.VTable, "CreateFontFace") == 9);
    std.debug.assert(slot(IDWriteFactory.VTable, "RegisterFontFileLoader") == 13);
    std.debug.assert(slot(IDWriteFactory.VTable, "CreateTextAnalyzer") == 21);
    std.debug.assert(slot(IDWriteFactory.VTable, "GetSystemFontFallback") == 26);
    std.debug.assert(slot(IDWriteFactory.VTable, "TranslateColorGlyphRun") == 28);
    std.debug.assert(slot(IDWriteFactory.VTable, "CreateGlyphRunAnalysis2") == 30);
    std.debug.assert(slot(IDWriteFactory.VTable, "CreateInMemoryFontFileLoader") == 44);
    std.debug.assert(slot(IDWriteFontFace.VTable, "GetMetrics") == 8);
    std.debug.assert(slot(IDWriteFontFace.VTable, "GetGlyphIndices") == 11);
    std.debug.assert(slot(IDWriteFontFace.VTable, "TryGetFontTable") == 12);
    std.debug.assert(slot(IDWriteFont.VTable, "HasCharacter") == 12);
    std.debug.assert(slot(IDWriteFont.VTable, "CreateFontFace") == 13);
    std.debug.assert(slot(IDWriteFontFamily.VTable, "GetFirstMatchingFont") == 7);
    std.debug.assert(slot(IDWriteTextAnalyzer.VTable, "GetGlyphs") == 7);
    std.debug.assert(slot(IDWriteTextAnalyzer.VTable, "GetGlyphPlacements") == 8);
    std.debug.assert(@sizeOf(DWRITE_GLYPH_RUN) == 48);
}
