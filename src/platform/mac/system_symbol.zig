//! SF Symbols for `Platform.renderSystemSymbol` (macOS 11+):
//! `+[NSImage imageWithSystemSymbolName:accessibilityDescription:]` configured with
//! `+[NSImageSymbolConfiguration configurationWithPointSize:weight:scale:]`, drawn into a
//! premultiplied RGBA CGBitmapContext at device scale; the alpha channel is the mask.
//! Template symbols draw in black, so only coverage matters. Null when the OS lacks the
//! symbol (or the API, before macOS 11).

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const cf = @import("cf.zig");
const pf = @import("../platform.zig");

const id = objc.id;
const log = std.log.scoped(.mac_system_symbol);

var logged_first: bool = false;

pub fn render(gpa: std.mem.Allocator, r: pf.SystemSymbolRequest) ?pf.SystemSymbolMask {
    if (r.name.len == 0 or r.name.len > 200) return null;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const ns_image = objc.getClass("NSImage") orelse return null;
    const cfg_class = objc.getClass("NSImageSymbolConfiguration") orelse return null; // macOS 11+
    const base = ns_image.msg(?id, "imageWithSystemSymbolName:accessibilityDescription:", .{ ak.nsString(r.name), @as(?id, null) }) orelse return null;
    const cfg = cfg_class.msg(?id, "configurationWithPointSize:weight:scale:", .{
        @as(objc.CGFloat, r.options.point_size),
        @as(objc.CGFloat, r.options.weight.nsFontWeight()),
        @as(objc.NSInteger, @intFromEnum(r.options.scale)),
    }) orelse return null;
    const img = base.msg(?id, "imageWithSymbolConfiguration:", .{cfg}) orelse return null;
    const size = ak.msgStruct(ak.NSSize, img, "size", .{});
    if (!(size.width > 0 and size.height > 0) or size.width > 1024 or size.height > 1024) return null;

    const pw, const ph, const k = pf.system_symbol.deviceSize(size.width, size.height, r.options, r.scale_factor);
    const w: usize = pw;
    const h: usize = ph;
    const rgba = gpa.alloc(u8, w * h * 4) catch return null;
    defer gpa.free(rgba);
    @memset(rgba, 0);
    const space = cf.CGColorSpaceCreateDeviceRGB() orelse return null;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(rgba.ptr, w, h, 8, w * 4, space, cf.kCGImageAlphaPremultipliedLast) orelse return null;
    defer cf.CGContextRelease(ctx);
    // Points → device pixels, scaled down to the fit box; centered on the bitmap.
    const s: f64 = r.scale_factor;
    const dw = size.width * k * s;
    const dh = size.height * k * s;
    cf.CGContextTranslateCTM(ctx, (@as(f64, @floatFromInt(w)) - dw) / 2, (@as(f64, @floatFromInt(h)) - dh) / 2);
    cf.CGContextScaleCTM(ctx, k * s, k * s);

    const gc_class = objc.getClass("NSGraphicsContext") orelse return null;
    const gc = gc_class.msg(?id, "graphicsContextWithCGContext:flipped:", .{ @as(*anyopaque, @ptrCast(ctx)), objc.NO }) orelse return null;
    gc_class.msg(void, "saveGraphicsState", .{});
    gc_class.msg(void, "setCurrentContext:", .{gc});
    const rect: ak.NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = size };
    const zero: ak.NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    // NSCompositingOperationSourceOver = 2.
    img.msg(void, "drawInRect:fromRect:operation:fraction:", .{ rect, zero, @as(objc.NSUInteger, 2), @as(objc.CGFloat, 1) });
    gc.msg(void, "flushGraphics", .{});
    gc_class.msg(void, "restoreGraphicsState", .{});

    const mask = gpa.alloc(u8, w * h) catch return null;
    var any: u8 = 0;
    for (mask, 0..) |*m, i| {
        m.* = rgba[i * 4 + 3];
        any |= m.*;
    }
    if (any == 0) {
        gpa.free(mask);
        return null;
    }
    if (!logged_first) {
        logged_first = true;
        log.info("SF Symbols: rendered \"{s}\" at {d}pt as {d}x{d} px", .{ r.name, r.options.point_size, pw, ph });
    }
    return .{ .width = pw, .height = ph, .bytes = mask };
}
