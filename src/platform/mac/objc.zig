//! Minimal, dependency-free Objective-C runtime bindings for macOS.
//!
//! Messages are sent through `objc_msgSend`, cast to a concrete C function
//! type built at comptime from the argument tuple (`msgSend`). On arm64 the
//! one entry point covers every signature; on x86_64 it also covers every
//! signature zpui uses (no struct returns larger than 16 bytes, which would
//! need `objc_msgSend_stret`).
//!
//! Only meaningful on Darwin targets; nothing here is analyzed elsewhere.

const std = @import("std");
const builtin = @import("builtin");

/// Any Objective-C object (`id`). Never dereferenced from Zig.
pub const Object = opaque {
    /// Send `selector` to this object. See `msgSend`.
    pub inline fn msg(self: *Object, comptime Ret: type, comptime selector: [:0]const u8, args: anytype) Ret {
        return msgSend(Ret, self, cachedSel(selector), args);
    }

    pub fn retain(self: *Object) *Object {
        return objc_retain(self);
    }

    pub fn release(self: *Object) void {
        objc_release(self);
    }

    pub fn autorelease(self: *Object) *Object {
        return objc_autorelease(self);
    }
};
pub const id = *Object;

/// An Objective-C class object.
pub const Class = opaque {
    pub inline fn msg(self: *Class, comptime Ret: type, comptime selector: [:0]const u8, args: anytype) Ret {
        return msgSend(Ret, self, cachedSel(selector), args);
    }

    /// `[[Class alloc] init]`; returns a +1 reference.
    pub fn new(self: *Class) ?id {
        return self.msg(?id, "new", .{});
    }
};

pub const SEL = *opaque {};
pub const IMP = *const anyopaque;

/// `BOOL` is C `bool` on arm64 and `signed char` on x86_64.
pub const BOOL = if (builtin.cpu.arch == .aarch64) bool else i8;
pub const YES: BOOL = if (BOOL == bool) true else 1;
pub const NO: BOOL = if (BOOL == bool) false else 0;

pub inline fn toBOOL(b: bool) BOOL {
    return if (BOOL == bool) b else @intFromBool(b);
}

pub inline fn fromBOOL(b: BOOL) bool {
    return if (BOOL == bool) b else b != 0;
}

pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const CGFloat = f64;

pub const NSRange = extern struct { location: NSUInteger, length: NSUInteger };
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

// ---------------------------------------------------------------------------
// Runtime externs (libobjc)
// ---------------------------------------------------------------------------

extern "c" fn objc_getClass(name: [*:0]const u8) ?*Class;
extern "c" fn sel_registerName(name: [*:0]const u8) ?SEL;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_msgSendSuper() void;
extern "c" fn objc_retain(obj: id) id;
extern "c" fn objc_release(obj: id) void;
extern "c" fn objc_autorelease(obj: id) id;
extern "c" fn objc_autoreleasePoolPush() *anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: *anyopaque) void;
extern "c" fn objc_allocateClassPair(superclass: ?*Class, name: [*:0]const u8, extra_bytes: usize) ?*Class;
extern "c" fn objc_registerClassPair(class: *Class) void;
extern "c" fn class_addMethod(class: *Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
extern "c" fn class_addIvar(class: *Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
extern "c" fn object_getClass(obj: id) ?*Class;
extern "c" fn object_getInstanceVariable(obj: id, name: [*:0]const u8, out_value: *?*anyopaque) ?*anyopaque;
extern "c" fn object_setInstanceVariable(obj: id, name: [*:0]const u8, value: ?*anyopaque) ?*anyopaque;

/// Look up a class by name; null if it is not loaded (e.g. framework not linked).
pub fn getClass(name: [:0]const u8) ?*Class {
    return objc_getClass(name.ptr);
}

/// Register (or look up) a selector. Never fails for valid C strings.
pub fn sel(name: [:0]const u8) SEL {
    return sel_registerName(name.ptr).?;
}

/// `sel` for a comptime-known name, registered once per selector. Concurrent
/// first calls race benignly (the runtime returns the same SEL).
pub fn cachedSel(comptime name: [:0]const u8) SEL {
    const Cache = struct {
        var value: ?SEL = null;
    };
    if (@atomicLoad(?SEL, &Cache.value, .monotonic)) |v| return v;
    const v = sel(name);
    @atomicStore(?SEL, &Cache.value, v, .monotonic);
    return v;
}

/// The concrete C function type `fn (Target, SEL, args...) callconv(.c) Ret`.
fn MsgSendFn(comptime Ret: type, comptime Target: type, comptime Args: type) type {
    const arg_types = @typeInfo(Args).@"struct".field_types;
    const params: [arg_types.len + 2]type = .{ Target, SEL } ++ arg_types[0..arg_types.len].*;
    const attrs: [params.len]std.lang.Type.Fn.ParamAttributes = @splat(.{});
    return @Fn(&params, &attrs, Ret, .{ .@"callconv" = .c });
}

/// Send a message. `target` is an object or class pointer, `args` a tuple whose
/// element types must match the method's C signature exactly (use `f32`,
/// `NSUInteger`, `BOOL`, extern structs, ...).
pub inline fn msgSend(comptime Ret: type, target: anytype, selector: SEL, args: anytype) Ret {
    const Fn = MsgSendFn(Ret, @TypeOf(target), @TypeOf(args));
    const f: *const Fn = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, selector } ++ args);
}

/// `struct objc_super` for `msgSendSuper`.
pub const Super = extern struct { receiver: id, super_class: *Class };

/// Send a message to the superclass implementation (for subclass overrides).
pub inline fn msgSendSuper(comptime Ret: type, super: *const Super, selector: SEL, args: anytype) Ret {
    const Fn = MsgSendFn(Ret, *const Super, @TypeOf(args));
    const f: *const Fn = @ptrCast(&objc_msgSendSuper);
    return @call(.auto, f, .{ super, selector } ++ args);
}

// ---------------------------------------------------------------------------
// Autorelease pools
// ---------------------------------------------------------------------------

/// An `@autoreleasepool` scope: `const pool = AutoreleasePool.push(); defer pool.pop();`.
pub const AutoreleasePool = struct {
    handle: *anyopaque,

    pub fn push() AutoreleasePool {
        return .{ .handle = objc_autoreleasePoolPush() };
    }

    pub fn pop(self: AutoreleasePool) void {
        objc_autoreleasePoolPop(self.handle);
    }
};

// ---------------------------------------------------------------------------
// Foundation helpers
// ---------------------------------------------------------------------------

/// An autoreleased `NSString` copied from `str` (UTF-8).
pub fn nsString(str: [:0]const u8) id {
    const NSString = getClass("NSString").?;
    return NSString.msg(?id, "stringWithUTF8String:", .{str.ptr}).?;
}

/// Borrowed UTF-8 view of an `NSString`, valid while the string (and the
/// current autorelease pool) lives.
pub fn utf8(string: id) [:0]const u8 {
    const ptr = string.msg(?[*:0]const u8, "UTF8String", .{}) orelse return "";
    return std.mem.span(ptr);
}

/// `-[NSError localizedDescription]` as UTF-8, or a placeholder.
pub fn errorDescription(err: ?id) [:0]const u8 {
    const e = err orelse return "(no NSError)";
    const desc = e.msg(?id, "localizedDescription", .{}) orelse return "(no description)";
    return utf8(desc);
}

// ---------------------------------------------------------------------------
// Class creation (delegates, NSView subclasses)
// ---------------------------------------------------------------------------

/// Builder for a runtime-defined subclass. Call `addMethod`/`addIvar`, then `register`.
pub const ClassBuilder = struct {
    class: *Class,

    /// Returns null if `name` already exists (look it up with `getClass` instead).
    pub fn init(superclass_name: [:0]const u8, name: [:0]const u8) ?ClassBuilder {
        const superclass = getClass(superclass_name) orelse return null;
        const class = objc_allocateClassPair(superclass, name.ptr, 0) orelse return null;
        return .{ .class = class };
    }

    /// `imp` must be a `callconv(.c)` function taking `(id, SEL, ...)`.
    /// `types` is the Objective-C type encoding, e.g. "v@:@" for `- (void)x:(id)arg`.
    pub fn addMethod(self: ClassBuilder, selector: [:0]const u8, imp: anytype, types: [:0]const u8) bool {
        return fromBOOL(class_addMethod(self.class, sel(selector), @ptrCast(imp), types.ptr));
    }

    /// Adds a pointer-sized ivar (encoding "^v").
    pub fn addPointerIvar(self: ClassBuilder, name: [:0]const u8) bool {
        return fromBOOL(class_addIvar(self.class, name.ptr, @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v"));
    }

    pub fn register(self: ClassBuilder) *Class {
        objc_registerClassPair(self.class);
        return self.class;
    }
};

pub fn setIvar(obj: id, name: [:0]const u8, value: ?*anyopaque) void {
    _ = object_setInstanceVariable(obj, name.ptr, value);
}

pub fn getIvar(obj: id, name: [:0]const u8) ?*anyopaque {
    var out: ?*anyopaque = null;
    _ = object_getInstanceVariable(obj, name.ptr, &out);
    return out;
}

test "msgSend function type construction" {
    const F = MsgSendFn(void, id, @TypeOf(.{ @as(f32, 1), @as(NSUInteger, 2) }));
    const info = @typeInfo(F).@"fn";
    try std.testing.expectEqual(@as(usize, 4), info.param_types.len);
    try std.testing.expect(info.param_types[1].? == SEL);
    try std.testing.expect(info.param_types[2].? == f32);
}

// ---------------------------------------------------------------------------
// Additions for the AppKit platform backend (src/platform/mac/window.zig etc.)
// ---------------------------------------------------------------------------

extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern "c" fn class_addProtocol(class: *Class, protocol: *anyopaque) BOOL;
extern "c" fn objc_msgSend_stret() void;

/// Declare that a runtime-built class adopts `protocol_name` (e.g. "NSTextInputClient",
/// which `-[NSView inputContext]` requires). Returns false if the protocol is unknown.
pub fn addProtocol(builder: ClassBuilder, protocol_name: [:0]const u8) bool {
    const proto = objc_getProtocol(protocol_name.ptr) orelse return false;
    return fromBOOL(class_addProtocol(builder.class, proto));
}

/// Like `msgSend`, but routes struct returns larger than 16 bytes (NSRect, ...)
/// through `objc_msgSend_stret` on x86_64. arm64 has a single entry point.
pub inline fn msgSendStret(comptime Ret: type, target: anytype, selector: SEL, args: anytype) Ret {
    if (builtin.cpu.arch == .x86_64 and @sizeOf(Ret) > 16) {
        const Fn = MsgSendFn(Ret, @TypeOf(target), @TypeOf(args));
        const f: *const Fn = @ptrCast(&objc_msgSend_stret);
        return @call(.auto, f, .{ target, selector } ++ args);
    }
    return msgSend(Ret, target, selector, args);
}

/// `[obj isKindOfClass:class]`.
pub fn isKindOf(obj: id, class: *Class) bool {
    return obj.msg(BOOL, "isKindOfClass:", .{class}) == YES;
}
