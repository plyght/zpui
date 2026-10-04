//! Comptime port of gpui's `Refineable` derive.
//!
//! `Refinement(T)` is a struct with the same field names as `T` where every field is optional and
//! defaults to `null`. Fields `T` already declares as optional stay `?X` (not `??X`), as in gpui.
//! Fields named in `T.refinable` (gpui's `#[refineable]`) become nested `Refinement(Field)` values
//! instead, so refining `inset.top` leaves `inset.left` alone.
//!
//! A struct whose fields are all optional and which declares no `refinable` list is its own
//! refinement, so `Refinement(Refinement(T)) == Refinement(T)` for flat types.

const std = @import("std");

/// The refinement type of `T`. Memoized per `T` by the compiler.
pub fn Refinement(comptime T: type) type {
    @setEvalBranchQuota(20_000);
    const info = @typeInfo(T).@"struct";
    const nested = nestedFields(T);
    if (nested.len == 0 and allOptional(T)) return T;

    var names: [info.field_names.len][]const u8 = undefined;
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (info.field_names, info.field_types, 0..) |name, F, i| {
        names[i] = name;
        if (isNested(nested, name)) {
            const R = Refinement(F);
            const default: R = .{};
            types[i] = R;
            attrs[i] = .{ .default_value_ptr = &default };
        } else {
            const O = if (@typeInfo(F) == .optional) F else ?F;
            const default: O = null;
            types[i] = O;
            attrs[i] = .{ .default_value_ptr = &default };
        }
    }
    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

fn nestedFields(comptime T: type) []const []const u8 {
    if (!@hasDecl(T, "refinable")) return &.{};
    const list = T.refinable;
    var out: [list.len][]const u8 = undefined;
    inline for (list, 0..) |name, i| {
        if (!@hasField(T, name)) @compileError(@typeName(T) ++ ".refinable names unknown field " ++ name);
        out[i] = name;
    }
    const final = out;
    return &final;
}

fn isNested(nested: []const []const u8, name: []const u8) bool {
    for (nested) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn allOptional(comptime T: type) bool {
    for (@typeInfo(T).@"struct".field_types) |F| if (@typeInfo(F) != .optional) return false;
    return true;
}

/// Overwrites every field of `dst` that is set in `src` (gpui `refine`). `dst` may be a base
/// value (`*T`) or another refinement (`*Refinement(T)`, i.e. a merge).
pub fn refine(dst: anytype, src: anytype) void {
    const S = @TypeOf(src);
    const info = @typeInfo(S).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const value = @field(src, name);
        if (@typeInfo(F) == .optional) {
            if (value) |v| @field(dst, name) = v;
        } else {
            // Non-optional fields of a refinement are nested refinements.
            refine(&@field(dst, name), value);
        }
    }
}

/// Returns `base` refined by `src` (gpui `refined`).
pub fn refined(comptime T: type, base: T, src: Refinement(T)) T {
    var out = base;
    refine(&out, src);
    return out;
}

/// Layers `b` over `a`: fields set in `b` win (gpui `Refinement::refine`).
pub fn merge(comptime T: type, a: *Refinement(T), b: Refinement(T)) void {
    refine(a, b);
}

/// Returns `a` with `b` layered on top.
pub fn merged(comptime T: type, a: Refinement(T), b: Refinement(T)) Refinement(T) {
    var out = a;
    refine(&out, b);
    return out;
}

/// True if no field (recursively) is set.
pub fn isEmpty(r: anytype) bool {
    const info = @typeInfo(@TypeOf(r)).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (@typeInfo(F) == .optional) {
            if (@field(r, name) != null) return false;
        } else if (!isEmpty(@field(r, name))) return false;
    }
    return true;
}

/// Builds a `T` from `T`'s defaults refined by `r` (gpui `From<Refinement> for T`).
pub fn fromRefinement(comptime T: type, r: Refinement(T)) T {
    return refined(T, .{}, r);
}

const testing = std.testing;

const Inner = struct {
    a: i32 = 1,
    b: i32 = 2,
};
const Outer = struct {
    pub const refinable = .{"inner"};
    inner: Inner = .{},
    flag: bool = false,
    maybe: ?u8 = null,
};

test "refinement shape" {
    const R = Refinement(Outer);
    const r: R = .{};
    try testing.expect(@TypeOf(r.inner) == Refinement(Inner));
    try testing.expect(@TypeOf(r.flag) == ?bool);
    try testing.expect(@TypeOf(r.maybe) == ?u8);
    try testing.expect(isEmpty(r));
    // A flat all-optional struct is its own refinement.
    try testing.expect(Refinement(Refinement(Inner)) == Refinement(Inner));
}

test "refine overwrites only set fields, nested per-field" {
    var base: Outer = .{ .maybe = 3 };
    refine(&base, Refinement(Outer){ .inner = .{ .b = 20 }, .flag = true });
    try testing.expectEqual(@as(i32, 1), base.inner.a);
    try testing.expectEqual(@as(i32, 20), base.inner.b);
    try testing.expect(base.flag);
    try testing.expectEqual(@as(?u8, 3), base.maybe);
}

test "merge layers refinements" {
    var a: Refinement(Outer) = .{ .inner = .{ .a = 5 }, .maybe = 1 };
    merge(Outer, &a, .{ .inner = .{ .b = 6 }, .maybe = 2 });
    try testing.expectEqual(@as(?i32, 5), a.inner.a);
    try testing.expectEqual(@as(?i32, 6), a.inner.b);
    try testing.expectEqual(@as(?u8, 2), a.maybe);
    try testing.expect(!isEmpty(a));
    const o = fromRefinement(Outer, a);
    try testing.expectEqual(@as(i32, 5), o.inner.a);
    try testing.expect(!o.flag);
}
