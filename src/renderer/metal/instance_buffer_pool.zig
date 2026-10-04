//! Instance buffer pool, ported from zui's `InstanceBufferPool`
//! (gpui_macos/src/metal_renderer.rs).
//!
//! Every frame writes its instance data into one buffer of `buffer_size`
//! bytes. A frame that overflows doubles `buffer_size` (dropping pooled
//! buffers of the old size) and is re-encoded; after a sustained run of
//! frames that fit in half the current size, the pool halves back toward the
//! default so a single complex frame does not pin GPU memory for the process
//! lifetime (the zui fork's bounded-memory change).
//!
//! Generic over the buffer handle so the policy is testable without a GPU:
//! `Backend` must provide `create(*Backend, size: usize) !Buffer` and
//! `destroy(*Backend, Buffer) void`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Initial size of each instance buffer.
pub const default_buffer_size: usize = 2 * 1024 * 1024;
/// Consecutive low-usage frames before `buffer_size` halves.
pub const shrink_after_frames: u32 = 120;
/// Overflow retries stop here (zui: 256 MiB).
pub const max_buffer_size: usize = 256 * 1024 * 1024;

pub fn InstanceBufferPool(comptime Buffer: type, comptime Backend: type) type {
    return struct {
        const Self = @This();

        buffer_size: usize = default_buffer_size,
        /// Idle buffers of exactly `buffer_size` bytes.
        free: std.ArrayList(Buffer) = .empty,
        low_usage_frames: u32 = 0,

        /// A buffer checked out for one frame. `size` remembers the pool size at
        /// acquisition so stale-sized buffers are destroyed on `release`.
        pub const Acquired = struct { buffer: Buffer, size: usize };

        pub fn deinit(self: *Self, gpa: Allocator, backend: *Backend) void {
            for (self.free.items) |b| backend.destroy(b);
            self.free.deinit(gpa);
            self.* = undefined;
        }

        /// Change the buffer size and drop every pooled buffer.
        pub fn reset(self: *Self, backend: *Backend, buffer_size: usize) void {
            self.buffer_size = buffer_size;
            for (self.free.items) |b| backend.destroy(b);
            self.free.clearRetainingCapacity();
            self.low_usage_frames = 0;
        }

        /// Record how many bytes a successfully encoded frame used; shrinks
        /// `buffer_size` once usage stayed at or below half of it for
        /// `shrink_after_frames` frames. In-flight buffers of the old size are
        /// destroyed by `release` when their frame completes.
        pub fn noteUsage(self: *Self, backend: *Backend, used_bytes: usize) void {
            if (self.buffer_size > default_buffer_size and used_bytes <= self.buffer_size / 2) {
                self.low_usage_frames += 1;
                if (self.low_usage_frames >= shrink_after_frames) {
                    self.reset(backend, @max(self.buffer_size / 2, default_buffer_size));
                }
            } else {
                self.low_usage_frames = 0;
            }
        }

        /// Double the buffer size after an overflow. Errors once the cap is hit.
        pub fn grow(self: *Self, backend: *Backend) error{InstanceBufferTooLarge}!void {
            if (self.buffer_size >= max_buffer_size) return error.InstanceBufferTooLarge;
            self.reset(backend, self.buffer_size * 2);
        }

        pub fn acquire(self: *Self, backend: *Backend) !Acquired {
            const buffer = self.free.pop() orelse try backend.create(self.buffer_size);
            return .{ .buffer = buffer, .size = self.buffer_size };
        }

        /// Return a buffer after its frame completed (or was abandoned).
        pub fn release(self: *Self, gpa: Allocator, backend: *Backend, acquired: Acquired) void {
            if (acquired.size == self.buffer_size) {
                self.free.append(gpa, acquired.buffer) catch backend.destroy(acquired.buffer);
            } else {
                backend.destroy(acquired.buffer);
            }
        }
    };
}

const TestBackend = struct {
    live: usize = 0,
    created_sizes: std.ArrayList(usize) = .empty,

    fn create(self: *TestBackend, size: usize) !usize {
        self.live += 1;
        try self.created_sizes.append(std.testing.allocator, size);
        return size;
    }

    fn destroy(self: *TestBackend, _: usize) void {
        self.live -= 1;
    }
};

test "pool grows on overflow, shrinks after sustained low usage, drops stale buffers" {
    const gpa = std.testing.allocator;
    var backend: TestBackend = .{};
    defer backend.created_sizes.deinit(gpa);
    var pool: InstanceBufferPool(usize, TestBackend) = .{};
    defer pool.deinit(gpa, &backend);

    const a = try pool.acquire(&backend);
    try std.testing.expectEqual(default_buffer_size, a.size);
    // Overflow: grow, the abandoned buffer is stale and gets destroyed.
    try pool.grow(&backend);
    pool.release(gpa, &backend, a);
    try std.testing.expectEqual(@as(usize, 0), backend.live);

    const b = try pool.acquire(&backend);
    try std.testing.expectEqual(2 * default_buffer_size, b.size);
    pool.release(gpa, &backend, b);
    try std.testing.expectEqual(@as(usize, 1), pool.free.items.len);

    // High usage resets the low-usage streak.
    pool.noteUsage(&backend, 2 * default_buffer_size);
    try std.testing.expectEqual(@as(u32, 0), pool.low_usage_frames);
    for (0..shrink_after_frames - 1) |_| pool.noteUsage(&backend, 10);
    try std.testing.expectEqual(2 * default_buffer_size, pool.buffer_size);
    const in_flight = try pool.acquire(&backend);
    pool.noteUsage(&backend, 10);
    try std.testing.expectEqual(default_buffer_size, pool.buffer_size);
    // The in-flight buffer of the old size is destroyed when it completes.
    pool.release(gpa, &backend, in_flight);
    try std.testing.expectEqual(@as(usize, 0), backend.live);

    // Never shrinks below the default.
    for (0..2 * shrink_after_frames) |_| pool.noteUsage(&backend, 0);
    try std.testing.expectEqual(default_buffer_size, pool.buffer_size);

    pool.buffer_size = max_buffer_size;
    try std.testing.expectError(error.InstanceBufferTooLarge, pool.grow(&backend));
}
