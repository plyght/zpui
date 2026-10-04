//! Rust-`format!`-compatible string building for the SVG emitter: `{}` prints
//! f32 like Rust `Display` (shortest round-trip), `{:.N}` with exact
//! half-to-even decimal expansion, strings verbatim, integers in decimal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

pub const Out = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(a: Allocator) Out {
        return .{ .a = a };
    }

    pub fn str(self: *Out, s: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(self.a, s);
    }

    pub fn put(self: *Out, comptime tpl: []const u8, args: anytype) Allocator.Error!void {
        try write(self.a, &self.buf, tpl, args);
    }

    pub fn items(self: *const Out) []const u8 {
        return self.buf.items;
    }
};

pub fn print(a: Allocator, comptime tpl: []const u8, args: anytype) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try write(a, &list, tpl, args);
    return list.items;
}

pub fn write(a: Allocator, list: *std.ArrayList(u8), comptime tpl: []const u8, args: anytype) Allocator.Error!void {
    comptime var i: usize = 0;
    comptime var lit_start: usize = 0;
    comptime var arg: usize = 0;
    inline while (i < tpl.len) {
        if (tpl[i] == '{' and i + 1 < tpl.len and tpl[i + 1] == '{') {
            try list.appendSlice(a, tpl[lit_start .. i + 1]);
            i += 2;
            lit_start = i;
        } else if (tpl[i] == '}' and i + 1 < tpl.len and tpl[i + 1] == '}') {
            try list.appendSlice(a, tpl[lit_start .. i + 1]);
            i += 2;
            lit_start = i;
        } else if (tpl[i] == '{') {
            try list.appendSlice(a, tpl[lit_start..i]);
            const close = comptime std.mem.indexOfScalarPos(u8, tpl, i, '}').?;
            const spec = tpl[i + 1 .. close];
            try writeArg(a, list, spec, args[arg]);
            arg += 1;
            i = close + 1;
            lit_start = i;
        } else i += 1;
    }
    try list.appendSlice(a, tpl[lit_start..]);
    if (arg != args.len) @compileError("argument count mismatch for: " ++ tpl);
}

fn writeArg(a: Allocator, list: *std.ArrayList(u8), comptime spec: []const u8, v: anytype) Allocator.Error!void {
    const T = @TypeOf(v);
    var buf: [512]u8 = undefined;
    if (comptime spec.len > 0) {
        comptime std.debug.assert(spec[0] == ':' and spec[1] == '.');
        const prec = comptime std.fmt.parseInt(usize, spec[2..], 10) catch unreachable;
        const f: f32 = switch (@typeInfo(T)) {
            .float, .comptime_float => @floatCast(v),
            .int, .comptime_int => @floatFromInt(v),
            else => @compileError("precision on non-float"),
        };
        return list.appendSlice(a, util.writeFixed(&buf, f, prec));
    }
    switch (@typeInfo(T)) {
        .float, .comptime_float => try list.appendSlice(a, util.writeF32(&buf, @floatCast(v))),
        .int, .comptime_int => try list.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable),
        .pointer => try list.appendSlice(a, v),
        .optional => if (v) |x| try writeArg(a, list, spec, x),
        else => @compileError("unsupported format argument " ++ @typeName(T)),
    }
}

test "rust formatting" {
    const a = std.testing.allocator;
    const s = try print(a, "<rect x=\"{:.2}\" w=\"{}\" id=\"{}\" n=\"{}\"/>{{}}", .{ @as(f32, 1.005), @as(f32, 0.1), "a", @as(usize, 3) });
    defer a.free(s);
    try std.testing.expectEqualStrings("<rect x=\"1.00\" w=\"0.1\" id=\"a\" n=\"3\"/>{}", s);
}
