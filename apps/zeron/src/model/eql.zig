//! Structural equality over decoded wire/settings values: slices by content,
//! `std.json.ArrayHashMap` and `json.ObjectMap` by entries, `json.Value`
//! structurally. Used for change detection on re-sent snapshot lists (the
//! engine's watch streams resend whole state) and settings revisions.

const std = @import("std");
const json = std.json;

pub fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (T == json.Value) return valueEql(a, b);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime isJsonArrayHashMap(T)) return mapEql(a.map, b.map);
            inline for (s.field_names) |n| if (!deepEql(@field(a, n), @field(b, n))) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |va, tag| return deepEql(va, @field(b, @tagName(tag))),
            }
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!deepEql(x, y)) return false;
                return true;
            }
            if (p.size == .one) return a == b or deepEql(a.*, b.*);
            return a == b;
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        .array => {
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        .float => return a == b or (std.math.isNan(a) and std.math.isNan(b)),
        else => return a == b,
    }
}

fn isJsonArrayHashMap(comptime T: type) bool {
    return @hasField(T, "map") and @hasDecl(T, "jsonParseFromValue") and @hasDecl(T, "jsonStringify");
}

fn mapEql(a: anytype, b: @TypeOf(a)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!deepEql(e.value_ptr.*, other)) return false;
    }
    return true;
}

pub fn valueEql(a: json.Value, b: json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        // 1 vs 1.0 are distinct serde values too; only identical shapes match.
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!valueEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| mapEql(x, b.object),
    };
}

test deepEql {
    const T = struct { a: []const u8, b: ?u32 = null, v: json.Value = .null };
    try std.testing.expect(deepEql(T{ .a = "x" }, T{ .a = "x" }));
    try std.testing.expect(!deepEql(T{ .a = "x", .b = 1 }, T{ .a = "x" }));
    try std.testing.expect(!deepEql(T{ .a = "x", .v = .{ .integer = 1 } }, T{ .a = "x", .v = .{ .integer = 2 } }));
}
