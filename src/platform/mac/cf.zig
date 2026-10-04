//! Hand-written C bindings for the slices of CoreFoundation, CoreGraphics and
//! CoreText used by the macOS backend and `text/coretext.zig`.
//!
//! Signatures follow Apple's headers (CFBase.h, CGContext.h, CTFont.h, ...):
//! `Boolean` is `u8`, C `bool` is Zig `bool`, `CFIndex` is `isize`, `size_t` is
//! `usize`, `CGGlyph` is `u16`, `UniChar` is `u16`. `Create`/`Copy` results are
//! +1 and must be `CFRelease`d; `Get` results are borrowed.

const objc = @import("objc.zig");

pub const CGFloat = objc.CGFloat;
pub const CGPoint = objc.CGPoint;
pub const CGSize = objc.CGSize;
pub const CGRect = objc.CGRect;

// ---------------------------------------------------------------------------
// CoreFoundation
// ---------------------------------------------------------------------------

pub const CFIndex = isize;
pub const CFTypeID = usize;
pub const Boolean = u8;
pub const CFTypeRef = *const anyopaque;
pub const CFAllocatorRef = ?*const anyopaque;
pub const CFStringRef = *const opaque {};
pub const CFArrayRef = *const opaque {};
pub const CFMutableArrayRef = *opaque {};
pub const CFDictionaryRef = *const opaque {};
pub const CFSetRef = *const opaque {};
pub const CFDataRef = *const opaque {};
pub const CFNumberRef = *const opaque {};
pub const CFBooleanRef = *const opaque {};
pub const CFAttributedStringRef = *const opaque {};
pub const CFMutableAttributedStringRef = *opaque {};

pub const CFRange = extern struct { location: CFIndex, length: CFIndex };

pub const kCFStringEncodingUTF8: u32 = 0x08000100;
pub const kCFNumberSInt32Type: CFIndex = 3;
pub const kCFNumberSInt64Type: CFIndex = 4;
pub const kCFNumberFloat64Type: CFIndex = 6;
pub const kCFNumberCGFloatType: CFIndex = 16;

pub extern "c" fn CFRelease(cf: CFTypeRef) void;
pub extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;
pub extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
pub extern "c" fn CFEqual(a: CFTypeRef, b: CFTypeRef) Boolean;

pub extern "c" fn CFStringCreateWithBytes(alloc: CFAllocatorRef, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, is_external: Boolean) ?CFStringRef;
pub extern "c" fn CFStringGetLength(str: CFStringRef) CFIndex;
pub extern "c" fn CFStringGetBytes(str: CFStringRef, range: CFRange, encoding: u32, loss_byte: u8, is_external: Boolean, buffer: ?[*]u8, max_buf_len: CFIndex, used_buf_len: ?*CFIndex) CFIndex;
pub extern "c" fn CFStringGetTypeID() CFTypeID;

pub extern "c" fn CFAttributedStringCreateMutable(alloc: CFAllocatorRef, max_length: CFIndex) ?CFMutableAttributedStringRef;
pub extern "c" fn CFAttributedStringReplaceString(astr: CFMutableAttributedStringRef, range: CFRange, replacement: CFStringRef) void;
pub extern "c" fn CFAttributedStringGetLength(astr: CFMutableAttributedStringRef) CFIndex;
pub extern "c" fn CFAttributedStringSetAttribute(astr: CFMutableAttributedStringRef, range: CFRange, name: CFStringRef, value: CFTypeRef) void;
pub extern "c" fn CFAttributedStringBeginEditing(astr: CFMutableAttributedStringRef) void;
pub extern "c" fn CFAttributedStringEndEditing(astr: CFMutableAttributedStringRef) void;

/// Address-only symbols (`&kCFTypeArrayCallBacks`); never read from Zig.
pub extern "c" const kCFTypeArrayCallBacks: u8;
pub extern "c" const kCFTypeDictionaryKeyCallBacks: u8;
pub extern "c" const kCFTypeDictionaryValueCallBacks: u8;
pub extern "c" const kCFTypeSetCallBacks: u8;

pub extern "c" fn CFArrayCreate(alloc: CFAllocatorRef, values: [*]const ?*const anyopaque, num_values: CFIndex, callbacks: ?*const anyopaque) ?CFArrayRef;
pub extern "c" fn CFArrayCreateMutable(alloc: CFAllocatorRef, capacity: CFIndex, callbacks: ?*const anyopaque) ?CFMutableArrayRef;
pub extern "c" fn CFArrayAppendValue(array: CFMutableArrayRef, value: ?*const anyopaque) void;
pub extern "c" fn CFArrayGetCount(array: CFArrayRef) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) ?*const anyopaque;

pub extern "c" fn CFDictionaryCreate(alloc: CFAllocatorRef, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, num_values: CFIndex, key_callbacks: ?*const anyopaque, value_callbacks: ?*const anyopaque) ?CFDictionaryRef;
pub extern "c" fn CFDictionaryGetValue(dict: CFDictionaryRef, key: ?*const anyopaque) ?*const anyopaque;

pub extern "c" fn CFSetCreate(alloc: CFAllocatorRef, values: [*]const ?*const anyopaque, num_values: CFIndex, callbacks: ?*const anyopaque) ?CFSetRef;

pub extern "c" fn CFNumberCreate(alloc: CFAllocatorRef, number_type: CFIndex, value_ptr: *const anyopaque) ?CFNumberRef;
pub extern "c" fn CFNumberGetValue(number: CFNumberRef, number_type: CFIndex, value_ptr: *anyopaque) Boolean;
pub extern "c" fn CFNumberGetTypeID() CFTypeID;
pub extern "c" fn CFBooleanGetValue(boolean: CFBooleanRef) Boolean;

pub extern "c" fn CFDataCreate(alloc: CFAllocatorRef, bytes: [*]const u8, length: CFIndex) ?CFDataRef;
pub extern "c" fn CFDataGetBytePtr(data: CFDataRef) ?[*]const u8;
pub extern "c" fn CFDataGetLength(data: CFDataRef) CFIndex;

pub extern "c" const kCFPreferencesCurrentApplication: CFStringRef;
pub extern "c" fn CFPreferencesCopyAppValue(key: CFStringRef, application_id: CFStringRef) ?CFTypeRef;
pub extern "c" fn CFLocaleCopyPreferredLanguages() ?CFArrayRef;

/// A +1 `CFString` from UTF-8 (null on invalid UTF-8).
pub fn string(bytes: []const u8) ?CFStringRef {
    return CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), kCFStringEncodingUTF8, 0);
}

/// Copy a `CFString` as UTF-8 into `buf`; returns the written prefix (truncated if `buf` is short).
pub fn stringToUtf8(str: CFStringRef, buf: []u8) []u8 {
    const len = CFStringGetLength(str);
    var used: CFIndex = 0;
    _ = CFStringGetBytes(str, .{ .location = 0, .length = len }, kCFStringEncodingUTF8, 0, 0, buf.ptr, @intCast(buf.len), &used);
    return buf[0..@intCast(used)];
}

/// A +1 `CFNumber` holding a double.
pub fn number(value: f64) ?CFNumberRef {
    return CFNumberCreate(null, kCFNumberFloat64Type, &value);
}

/// A +1 dictionary with CF-type callbacks (keys and values are retained).
pub fn dictionary(keys: []const ?*const anyopaque, values: []const ?*const anyopaque) ?CFDictionaryRef {
    return CFDictionaryCreate(null, keys.ptr, values.ptr, @intCast(keys.len), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

/// Read a numeric CF value (CFNumber) as f64; null for other types.
pub fn numberValue(value: ?*const anyopaque) ?f64 {
    const v = value orelse return null;
    if (CFGetTypeID(v) != CFNumberGetTypeID()) return null;
    var out: f64 = 0;
    if (CFNumberGetValue(@ptrCast(v), kCFNumberFloat64Type, &out) == 0) return null;
    return out;
}

// ---------------------------------------------------------------------------
// CoreGraphics
// ---------------------------------------------------------------------------

pub const CGContextRef = *opaque {};
pub const CGColorSpaceRef = *opaque {};
pub const CGImageRef = *opaque {};
pub const CGColorRef = *opaque {};
pub const CGGlyph = u16;
pub const CGDirectDisplayID = u32;
pub const CGWindowID = u32;

pub const kCGImageAlphaPremultipliedLast: u32 = 1;
pub const kCGImageAlphaPremultipliedFirst: u32 = 2;
pub const kCGImageAlphaOnly: u32 = 7;
pub const kCGBitmapByteOrder32Big: u32 = 4 << 12;
pub const kCGTextFill: i32 = 0;

pub const kCGWindowListOptionOnScreenOnly: u32 = 1 << 0;
pub const kCGWindowListOptionIncludingWindow: u32 = 1 << 3;
pub const kCGNullWindowID: CGWindowID = 0;
pub const kCGWindowImageDefault: u32 = 0;
pub const kCGWindowImageBoundsIgnoreFraming: u32 = 1 << 0;
pub const kCGWindowImageBestResolution: u32 = 1 << 3;

pub extern "c" const CGRectNull: CGRect;
pub extern "c" const CGRectInfinite: CGRect;

pub extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceCreateDeviceGray() ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ?CGColorSpaceRef, bitmap_info: u32) ?CGContextRef;
pub extern "c" fn CGContextRelease(c: CGContextRef) void;
pub extern "c" fn CGContextTranslateCTM(c: CGContextRef, tx: CGFloat, ty: CGFloat) void;
pub extern "c" fn CGContextScaleCTM(c: CGContextRef, sx: CGFloat, sy: CGFloat) void;
pub extern "c" fn CGContextSetTextDrawingMode(c: CGContextRef, mode: i32) void;
pub extern "c" fn CGContextSetAllowsAntialiasing(c: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldAntialias(c: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelPositioning(c: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelPositionFonts(c: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelQuantization(c: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(c: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(c: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetGrayFillColor(c: CGContextRef, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextDrawImage(c: CGContextRef, rect: CGRect, image: CGImageRef) void;
pub extern "c" fn CGImageGetWidth(image: CGImageRef) usize;
pub extern "c" fn CGImageGetHeight(image: CGImageRef) usize;
pub extern "c" fn CGImageRelease(image: CGImageRef) void;
/// `CGWindowListCreateImage` (obsoleted in the macOS 15 SDK in favor of
/// ScreenCaptureKit, still present at runtime). Resolved with `dlsym` so the
/// link never depends on the SDK stubs; null if unavailable. Smoke test only.
pub const CGWindowListCreateImageFn = *const fn (screen_bounds: CGRect, list_option: u32, window_id: CGWindowID, image_option: u32) callconv(.c) ?CGImageRef;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
pub fn cgWindowListCreateImage() ?CGWindowListCreateImageFn {
    const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    return @ptrCast(@alignCast(dlsym(rtld_default, "CGWindowListCreateImage")));
}

// ---------------------------------------------------------------------------
// CoreText
// ---------------------------------------------------------------------------

pub const CTFontRef = *const opaque {};
pub const CTFontDescriptorRef = *const opaque {};
pub const CTLineRef = *const opaque {};
pub const CTRunRef = *const opaque {};

pub const kCTFontUIFontSystem: u32 = 2;
pub const kCTFontOrientationDefault: u32 = 0;
pub const kCTFontItalicTrait: u32 = 1 << 0;

pub extern "c" const kCTFontAttributeName: CFStringRef;
pub extern "c" const kCTFontFamilyNameAttribute: CFStringRef;
pub extern "c" const kCTFontTraitsAttribute: CFStringRef;
pub extern "c" const kCTFontWeightTrait: CFStringRef;
pub extern "c" const kCTFontSlantTrait: CFStringRef;
pub extern "c" const kCTFontSymbolicTrait: CFStringRef;
pub extern "c" const kCTFontFeatureSettingsAttribute: CFStringRef;
pub extern "c" const kCTFontCascadeListAttribute: CFStringRef;
pub extern "c" const kCTFontOpenTypeFeatureTag: CFStringRef;
pub extern "c" const kCTFontOpenTypeFeatureValue: CFStringRef;

pub extern "c" fn CTFontDescriptorCreateWithAttributes(attributes: CFDictionaryRef) ?CTFontDescriptorRef;
pub extern "c" fn CTFontDescriptorCreateMatchingFontDescriptors(descriptor: CTFontDescriptorRef, mandatory_attributes: ?CFSetRef) ?CFArrayRef;
pub extern "c" fn CTFontDescriptorCopyAttribute(descriptor: CTFontDescriptorRef, attribute: CFStringRef) ?CFTypeRef;

pub extern "c" fn CTFontCreateWithFontDescriptor(descriptor: CTFontDescriptorRef, size: CGFloat, matrix: ?*const anyopaque) ?CTFontRef;
pub extern "c" fn CTFontCreateCopyWithAttributes(font: CTFontRef, size: CGFloat, matrix: ?*const anyopaque, attributes: ?CTFontDescriptorRef) ?CTFontRef;
pub extern "c" fn CTFontCreateUIFontForLanguage(ui_type: u32, size: CGFloat, language: ?CFStringRef) ?CTFontRef;
pub extern "c" fn CTFontCopyFontDescriptor(font: CTFontRef) CTFontDescriptorRef;
pub extern "c" fn CTFontCopyPostScriptName(font: CTFontRef) CFStringRef;
pub extern "c" fn CTFontCopyTraits(font: CTFontRef) CFDictionaryRef;
pub extern "c" fn CTFontGetSymbolicTraits(font: CTFontRef) u32;
pub extern "c" fn CTFontGetUnitsPerEm(font: CTFontRef) c_uint;
pub extern "c" fn CTFontGetSize(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetAscent(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetDescent(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetLeading(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetUnderlinePosition(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetUnderlineThickness(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetCapHeight(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetXHeight(font: CTFontRef) CGFloat;
pub extern "c" fn CTFontGetBoundingBox(font: CTFontRef) CGRect;
pub extern "c" fn CTFontGetGlyphsForCharacters(font: CTFontRef, characters: [*]const u16, glyphs: [*]CGGlyph, count: CFIndex) bool;
pub extern "c" fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: u32, glyphs: [*]const CGGlyph, advances: ?[*]CGSize, count: CFIndex) f64;
pub extern "c" fn CTFontGetBoundingRectsForGlyphs(font: CTFontRef, orientation: u32, glyphs: [*]const CGGlyph, bounding_rects: ?[*]CGRect, count: CFIndex) CGRect;
pub extern "c" fn CTFontDrawGlyphs(font: CTFontRef, glyphs: [*]const CGGlyph, positions: [*]const CGPoint, count: usize, context: CGContextRef) void;
pub extern "c" fn CTFontCopyDefaultCascadeListForLanguages(font: CTFontRef, language_pref_list: ?CFArrayRef) ?CFArrayRef;

pub extern "c" fn CTFontManagerCreateFontDescriptorsFromData(data: CFDataRef) ?CFArrayRef;

pub extern "c" fn CTLineCreateWithAttributedString(string: CFAttributedStringRef) ?CTLineRef;
pub extern "c" fn CTLineGetGlyphRuns(line: CTLineRef) CFArrayRef;
pub extern "c" fn CTLineGetTypographicBounds(line: CTLineRef, ascent: ?*CGFloat, descent: ?*CGFloat, leading: ?*CGFloat) f64;

pub extern "c" fn CTRunGetGlyphCount(run: CTRunRef) CFIndex;
pub extern "c" fn CTRunGetAttributes(run: CTRunRef) CFDictionaryRef;
pub extern "c" fn CTRunGetGlyphs(run: CTRunRef, range: CFRange, buffer: [*]CGGlyph) void;
pub extern "c" fn CTRunGetPositions(run: CTRunRef, range: CFRange, buffer: [*]CGPoint) void;
pub extern "c" fn CTRunGetStringIndices(run: CTRunRef, range: CFRange, buffer: [*]CFIndex) void;
