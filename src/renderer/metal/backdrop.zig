//! GPU-independent pieces of the backdrop-blur pass, ported from zui's
//! `MetalRenderer::draw_primitives_to_texture` / `ensure_backdrop_scratch` /
//! `ensure_gaussian_kernel` (gpui_macos/src/metal_renderer.rs): the padded
//! snapshot region, the copy-window placement, and the bounded LRU caches for
//! scratch texture pairs and gaussian kernels. Generic over the GPU handles
//! so the policy is unit-tested on every platform.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scene = @import("../../scene.zig");

/// Rendered frames without a backdrop blur (resp. without paths) before the
/// scratch textures backing that feature are released.
pub const scratch_release_after_frames: u32 = 30;

/// Device-pixel rect `[x0, x1) x [y0, y1)` of the drawable to snapshot.
pub const Region = struct {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,

    pub fn width(r: Region) u64 {
        return @intCast(r.x1 - r.x0);
    }

    pub fn height(r: Region) u64 {
        return @intCast(r.y1 - r.y0);
    }
};

/// Gaussian sigma in device pixels (`max(blur_radius, 1)`).
pub fn sigma(blur: scene.BackdropBlur) f32 {
    return @max(blur.blur_radius, 1.0);
}

/// The blur only samples its visible (clipped) bounds and the gaussian only
/// reaches ~3 sigma beyond, so snapshot just that padded region. Null when
/// fully clipped or off-screen.
pub fn snapshotRegion(blur: scene.BackdropBlur, drawable_width: i64, drawable_height: i64) ?Region {
    const padding = @ceil(sigma(blur) * 3.0) + 2.0;
    const visible = blur.bounds.intersect(blur.content_mask.bounds);
    const r: Region = .{
        .x0 = @max(floatToI64(@floor(visible.origin.x - padding)), 0),
        .y0 = @max(floatToI64(@floor(visible.origin.y - padding)), 0),
        .x1 = @min(floatToI64(@ceil(visible.right() + padding)), drawable_width),
        .y1 = @min(floatToI64(@ceil(visible.bottom() + padding)), drawable_height),
    };
    if (r.x1 <= r.x0 or r.y1 <= r.y0) return null;
    return r;
}

/// Rust `f32 as i64`: saturating, NaN -> 0.
fn floatToI64(v: f32) i64 {
    if (std.math.isNan(v)) return 0;
    const lo: f32 = @floatFromInt(std.math.minInt(i64));
    const hi: f32 = @floatFromInt(std.math.maxInt(i64));
    if (v <= lo) return std.math.minInt(i64);
    if (v >= hi) return std.math.maxInt(i64);
    return @intFromFloat(v);
}

/// Scratch extent for a needed region: quantized up to 64 px, capped at the drawable.
pub fn scratchExtent(needed: u64, drawable: u64) u64 {
    const quantum = 64;
    return @min((std.math.divCeil(u64, needed, quantum) catch unreachable) * quantum, drawable);
}

/// Where to place the scratch-sized copy window so it covers the region and
/// stays inside the drawable; the copy fills the ENTIRE scratch texture so its
/// edges hold real framebuffer content (clamp-to-edge then matches a
/// drawable-sized blur).
pub fn copyOrigin(region_start: i64, drawable: u64, scratch: u64) u64 {
    const limit: i64 = @as(i64, @intCast(drawable)) - @as(i64, @intCast(scratch));
    return @intCast(@max(@min(region_start, limit), 0));
}

/// Bounded LRU of scratch texture pairs (snapshot + blurred), most recent last.
/// `Backend` provides `create(*Backend, width, height, format: Format) !Pair`
/// and `destroy(*Backend, Pair) void`.
pub fn ScratchCache(comptime Pair: type, comptime Format: type, comptime Backend: type) type {
    return struct {
        const Self = @This();

        entries: std.ArrayList(Entry) = .empty,

        pub const Entry = struct {
            width: u64,
            height: u64,
            format: Format,
            used_this_frame: bool,
            pair: Pair,

            /// Two BGRA8 textures.
            fn bytes(e: Entry) u64 {
                return e.width * e.height * 8;
            }
        };

        pub fn deinit(self: *Self, gpa: Allocator, backend: *Backend) void {
            self.clear(backend);
            self.entries.deinit(gpa);
            self.* = undefined;
        }

        pub fn clear(self: *Self, backend: *Backend) void {
            for (self.entries.items) |e| backend.destroy(e.pair);
            self.entries.clearRetainingCapacity();
        }

        pub fn beginFrame(self: *Self) void {
            for (self.entries.items) |*e| e.used_this_frame = false;
        }

        /// Drop extents not used by the last frame (zui `trim_idle_resources`).
        /// Returns true if the cache is now empty.
        pub fn trimUnused(self: *Self, backend: *Backend) bool {
            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (!self.entries.items[i].used_this_frame) {
                    backend.destroy(self.entries.orderedRemove(i).pair);
                } else i += 1;
            }
            return self.entries.items.len == 0;
        }

        fn totalBytes(self: *const Self) u64 {
            var sum: u64 = 0;
            for (self.entries.items) |e| sum += e.bytes();
            return sum;
        }

        fn evictOldest(self: *Self, backend: *Backend) void {
            backend.destroy(self.entries.orderedRemove(0).pair);
        }

        /// A pair holding at least `needed_*` (quantized) that fits the drawable.
        /// Cached by exact quantized extent, at most four pairs and 32 MiB (or
        /// one oversized pair).
        pub fn ensure(
            self: *Self,
            gpa: Allocator,
            backend: *Backend,
            needed_width: u64,
            needed_height: u64,
            drawable_width: u64,
            drawable_height: u64,
            format: Format,
        ) !*Entry {
            const width = scratchExtent(needed_width, drawable_width);
            const height = scratchExtent(needed_height, drawable_height);
            // Discard obsolete extents after a window shrink, including on a hit.
            var i: usize = 0;
            while (i < self.entries.items.len) {
                const e = self.entries.items[i];
                if (e.width > drawable_width or e.height > drawable_height or e.format != format) {
                    backend.destroy(self.entries.orderedRemove(i).pair);
                } else i += 1;
            }
            const hit: ?usize = for (self.entries.items, 0..) |e, idx| {
                if (e.format == format and e.width == width and e.height == height) break idx;
            } else null;
            if (hit) |idx| {
                var e = self.entries.orderedRemove(idx);
                e.used_this_frame = true;
                self.entries.appendAssumeCapacity(e);
            } else {
                const needed = width * height * 8;
                const budget = @max(@min(drawable_width * drawable_height * 16, 32 * 1024 * 1024), needed);
                while (self.entries.items.len > 0 and
                    (self.entries.items.len >= 4 or self.totalBytes() + needed > budget)) self.evictOldest(backend);
                try self.entries.ensureUnusedCapacity(gpa, 1);
                const pair = try backend.create(width, height, format);
                self.entries.appendAssumeCapacity(.{ .width = width, .height = height, .format = format, .used_this_frame = true, .pair = pair });
            }
            // A smaller drawable can hit an existing extent while lowering the
            // aggregate budget; enforce the bound on hits too.
            const budget = @max(@min(drawable_width * drawable_height * 16, 32 * 1024 * 1024), width * height * 8);
            while (self.entries.items.len > 1 and self.totalBytes() > budget) self.evictOldest(backend);
            return &self.entries.items[self.entries.items.len - 1];
        }
    };
}

/// Small LRU of gaussian kernels keyed by sigma (+-0.01): a composer and a
/// floating menu use different sigmas in the same frame.
pub fn KernelCache(comptime Kernel: type, comptime Backend: type) type {
    return struct {
        const Self = @This();
        const capacity = 4;

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        const Entry = struct { sigma: f32, kernel: Kernel };

        pub fn clear(self: *Self, backend: *Backend) void {
            for (self.entries[0..self.len]) |e| backend.destroyKernel(e.kernel);
            self.len = 0;
        }

        /// Cached kernel for `sigma_value`, creating (and evicting the LRU) on a miss.
        pub fn ensure(self: *Self, backend: *Backend, sigma_value: f32) !Kernel {
            for (self.entries[0..self.len], 0..) |e, i| {
                if (@abs(e.sigma - sigma_value) < 0.01) {
                    std.mem.copyForwards(Entry, self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
                    self.entries[self.len - 1] = e;
                    return e.kernel;
                }
            }
            const kernel = try backend.createKernel(sigma_value);
            if (self.len == capacity) {
                backend.destroyKernel(self.entries[0].kernel);
                std.mem.copyForwards(Entry, self.entries[0 .. capacity - 1], self.entries[1..capacity]);
                self.len -= 1;
            }
            self.entries[self.len] = .{ .sigma = sigma_value, .kernel = kernel };
            self.len += 1;
            return kernel;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testBlur(x: f32, y: f32, w: f32, h: f32, radius: f32) scene.BackdropBlur {
    const b: scene.ContentMask = .{ .bounds = .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } } };
    return .{ .blur_radius = radius, .bounds = b.bounds, .content_mask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 10000, .height = 10000 } } } };
}

test "snapshot region pads by 3 sigma + 2 and clamps to the drawable" {
    // sigma 10 -> padding 32.
    const r = snapshotRegion(testBlur(100, 50, 200, 100, 10), 1000, 800).?;
    try testing.expectEqual(Region{ .x0 = 68, .y0 = 18, .x1 = 332, .y1 = 182 }, r);
    // Clamped at the origin and the far edge.
    const c = snapshotRegion(testBlur(10, 10, 980, 780, 10), 1000, 800).?;
    try testing.expectEqual(Region{ .x0 = 0, .y0 = 0, .x1 = 1000, .y1 = 800 }, c);
    // Off-screen.
    try testing.expect(snapshotRegion(testBlur(2000, 0, 10, 10, 1), 1000, 800) == null);
    // Radius below 1 is clamped to sigma 1 (padding 5).
    try testing.expectEqual(@as(i64, 95), snapshotRegion(testBlur(100, 100, 10, 10, 0), 1000, 800).?.x0);
}

test "scratch extent quantizes and copy origin stays inside the drawable" {
    try testing.expectEqual(@as(u64, 320), scratchExtent(264, 1000));
    try testing.expectEqual(@as(u64, 1000), scratchExtent(990, 1000));
    try testing.expectEqual(@as(u64, 64), scratchExtent(1, 1000));
    try testing.expectEqual(@as(u64, 68), copyOrigin(68, 1000, 320));
    try testing.expectEqual(@as(u64, 680), copyOrigin(900, 1000, 320));
    try testing.expectEqual(@as(u64, 0), copyOrigin(5, 1000, 1000));
}

const FakeGpu = struct {
    live: usize = 0,
    next: u32 = 0,

    fn create(self: *FakeGpu, w: u64, h: u64, f: u8) !u32 {
        _ = .{ w, h, f };
        self.live += 1;
        self.next += 1;
        return self.next;
    }
    fn destroy(self: *FakeGpu, _: u32) void {
        self.live -= 1;
    }
    fn createKernel(self: *FakeGpu, _: f32) !u32 {
        self.live += 1;
        self.next += 1;
        return self.next;
    }
    fn destroyKernel(self: *FakeGpu, _: u32) void {
        self.live -= 1;
    }
};

test "scratch cache reuses exact extents and stays bounded" {
    const gpa = testing.allocator;
    var gpu: FakeGpu = .{};
    var cache: ScratchCache(u32, u8, FakeGpu) = .{};
    defer cache.deinit(gpa, &gpu);

    const a = (try cache.ensure(gpa, &gpu, 100, 100, 2000, 2000, 0)).pair;
    const b = (try cache.ensure(gpa, &gpu, 120, 70, 2000, 2000, 0)).pair; // same 128x128 bucket
    try testing.expectEqual(a, b);
    _ = try cache.ensure(gpa, &gpu, 600, 100, 2000, 2000, 0);
    _ = try cache.ensure(gpa, &gpu, 100, 600, 2000, 2000, 0);
    _ = try cache.ensure(gpa, &gpu, 300, 300, 2000, 2000, 0);
    try testing.expectEqual(@as(usize, 4), cache.entries.items.len);
    _ = try cache.ensure(gpa, &gpu, 900, 900, 2000, 2000, 0);
    try testing.expect(cache.entries.items.len <= 4);
    try testing.expectEqual(cache.entries.items.len, gpu.live);
    // Window shrink drops extents larger than the drawable.
    _ = try cache.ensure(gpa, &gpu, 50, 50, 200, 200, 0);
    for (cache.entries.items) |e| try testing.expect(e.width <= 200 and e.height <= 200);

    cache.beginFrame();
    try testing.expect(cache.trimUnused(&gpu));
    try testing.expectEqual(@as(usize, 0), gpu.live);
}

test "kernel cache is an LRU of four keyed by sigma" {
    var gpu: FakeGpu = .{};
    var cache: KernelCache(u32, FakeGpu) = .{};
    defer cache.clear(&gpu);
    const k1 = try cache.ensure(&gpu, 4.0);
    try testing.expectEqual(k1, try cache.ensure(&gpu, 4.005));
    _ = try cache.ensure(&gpu, 8);
    _ = try cache.ensure(&gpu, 12);
    _ = try cache.ensure(&gpu, 16);
    try testing.expectEqual(k1, try cache.ensure(&gpu, 4)); // refresh 4 -> 8 is now LRU
    _ = try cache.ensure(&gpu, 20); // evicts 8
    try testing.expectEqual(@as(usize, 4), gpu.live);
    for (cache.entries[0..cache.len]) |e| try testing.expect(e.sigma != 8);
}
