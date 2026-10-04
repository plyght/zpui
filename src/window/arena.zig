//! Per-frame element arena (gpui `arena.rs`): a bump allocator plus a destructor list.
//!
//! Elements built during `render` live here until the window clears the arena after
//! presenting the frame. Values that own resources register a destructor (`create` does
//! this automatically for types declaring `deinit`), run in reverse order on `clear`.
//!
//! The arena of the window currently drawing is installed as the thread's *current* arena,
//! which is what lets view code write `div()` / `zpui.fmt(...)` without passing allocators.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ElementArena = struct {
    arena: std.heap.ArenaAllocator,
    destructors: std.ArrayList(Destructor) = .empty,
    gpa: Allocator,
    /// Number of `clear` calls; handy for asserting element lifetimes in tests.
    generation: u64 = 0,

    const Destructor = struct { ptr: *anyopaque, func: *const fn (*anyopaque) void };

    pub fn init(gpa: Allocator) ElementArena {
        return .{ .arena = .init(gpa), .gpa = gpa };
    }

    pub fn deinit(self: *ElementArena) void {
        self.clear();
        self.destructors.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn allocator(self: *ElementArena) Allocator {
        return self.arena.allocator();
    }

    /// Allocate a `T` initialized to `value`; registers `value.deinit()` if `T` has one.
    pub fn create(self: *ElementArena, comptime T: type, value: T) *T {
        const p = self.arena.allocator().create(T) catch @panic("OOM");
        p.* = value;
        if (comptime hasDeinit(T)) self.onClear(p, struct {
            fn run(ptr: *anyopaque) void {
                const t: *T = @ptrCast(@alignCast(ptr));
                t.deinit();
            }
        }.run);
        return p;
    }

    /// Run `func(ptr)` when the arena is cleared.
    pub fn onClear(self: *ElementArena, ptr: *anyopaque, func: *const fn (*anyopaque) void) void {
        self.destructors.append(self.gpa, .{ .ptr = ptr, .func = func }) catch @panic("OOM");
    }

    /// Run destructors (last registered first) and release all memory, keeping capacity.
    pub fn clear(self: *ElementArena) void {
        var i = self.destructors.items.len;
        while (i > 0) {
            i -= 1;
            const d = self.destructors.items[i];
            d.func(d.ptr);
        }
        self.destructors.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.generation += 1;
    }

    fn hasDeinit(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum" => @hasDecl(T, "deinit") and
                @typeInfo(@TypeOf(T.deinit)).@"fn".param_types.len == 1,
            else => false,
        };
    }
};

threadlocal var current_arena: ?*ElementArena = null;

/// The arena of the window that is currently rendering. Panics outside a draw (or test
/// scope set up with `enter`).
pub fn current() *ElementArena {
    return current_arena orelse @panic("no element arena: elements can only be built while a window draws (or inside ElementArena scope)");
}

pub fn currentOrNull() ?*ElementArena {
    return current_arena;
}

/// Install `arena` as the current arena; returns the previous one for `exit`.
pub fn enter(arena: *ElementArena) ?*ElementArena {
    const prev = current_arena;
    current_arena = arena;
    return prev;
}

pub fn exit(prev: ?*ElementArena) void {
    current_arena = prev;
}

/// Allocator of the current element arena (frame lifetime).
pub fn frameAllocator() Allocator {
    return current().allocator();
}

/// `std.fmt.allocPrint` into the current element arena: `div().child(zpui.fmt("{d} items", .{n}))`.
pub fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(frameAllocator(), format, args) catch @panic("OOM");
}

/// Copy `s` into the current element arena.
pub fn dupe(s: []const u8) []const u8 {
    return frameAllocator().dupe(u8, s) catch @panic("OOM");
}

test "arena runs destructors in reverse and resets" {
    var a = ElementArena.init(std.testing.allocator);
    defer a.deinit();
    const Log = struct {
        var buf: [4]u8 = undefined;
        var n: usize = 0;
    };
    Log.n = 0;
    const T = struct {
        c: u8,
        pub fn deinit(self: *@This()) void {
            Log.buf[Log.n] = self.c;
            Log.n += 1;
        }
    };
    _ = a.create(T, .{ .c = 'a' });
    _ = a.create(T, .{ .c = 'b' });
    _ = a.create(u32, 7);
    a.clear();
    try std.testing.expectEqualStrings("ba", Log.buf[0..Log.n]);
    try std.testing.expectEqual(@as(u64, 1), a.generation);
    const prev = enter(&a);
    defer exit(prev);
    try std.testing.expectEqualStrings("3 x", fmt("{d} x", .{3}));
}
