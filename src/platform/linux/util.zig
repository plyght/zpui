//! Small helpers shared by the Linux backends: cursor names, pipe reads with timeout.

const std = @import("std");
const linux = std.os.linux;
const platform = @import("../platform.zig");

/// Xcursor theme names for a style, most preferred first (gpui `cursor_style_to_icon_names`,
/// based on Chromium's list). Empty for `.none` (hidden cursor).
pub fn cursorNames(style: platform.CursorStyle) []const [*:0]const u8 {
    return switch (style) {
        .arrow => &.{"left_ptr"},
        .ibeam => &.{ "text", "xterm" },
        .crosshair => &.{ "crosshair", "cross" },
        .closed_hand => &.{ "closedhand", "grabbing", "hand2" },
        .open_hand => &.{ "openhand", "grab", "hand1" },
        .pointing_hand => &.{ "pointer", "hand", "hand2" },
        .resize_left => &.{ "w-resize", "left_side" },
        .resize_right => &.{ "e-resize", "right_side" },
        .resize_left_right => &.{ "ew-resize", "sb_h_double_arrow" },
        .resize_up => &.{ "n-resize", "top_side" },
        .resize_down => &.{ "s-resize", "bottom_side" },
        .resize_up_down => &.{ "sb_v_double_arrow", "ns-resize" },
        .resize_column => &.{ "col-resize", "sb_h_double_arrow" },
        .resize_row => &.{ "row-resize", "sb_v_double_arrow" },
        .operation_not_allowed => &.{ "not-allowed", "crossed_circle" },
        .drag_link => &.{"alias"},
        .drag_copy => &.{"copy"},
        .context_menu => &.{"context-menu"},
        .none => &.{},
    };
}

/// X11 core cursor-font glyph used when no Xcursor theme provides a style.
pub fn cursorFontGlyph(style: platform.CursorStyle) u16 {
    // Values from <X11/cursorfont.h>.
    return switch (style) {
        .arrow, .context_menu, .drag_link, .drag_copy, .none => 68, // XC_left_ptr
        .ibeam => 152, // XC_xterm
        .crosshair => 34, // XC_crosshair
        .closed_hand, .open_hand => 52, // XC_fleur
        .pointing_hand => 60, // XC_hand2
        .resize_left => 70, // XC_left_side
        .resize_right => 96, // XC_right_side
        .resize_left_right, .resize_column => 108, // XC_sb_h_double_arrow
        .resize_up => 138, // XC_top_side
        .resize_down => 16, // XC_bottom_side
        .resize_up_down, .resize_row => 116, // XC_sb_v_double_arrow
        .operation_not_allowed => 0, // XC_X_cursor
    };
}

pub const read_timeout_ms: i32 = 4000;

/// Reads `fd` to EOF, giving up when no data arrives for `timeout_ms` (gpui
/// `read_fd_with_timeout`; the deadline re-arms after every chunk). Closes `fd`.
pub fn readFdWithTimeout(gpa: std.mem.Allocator, fd: linux.fd_t, timeout_ms: i32) ![]u8 {
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [8192]u8 = undefined;
    while (true) {
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&pfd, 1, timeout_ms);
        switch (linux.errno(ready)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        if (ready == 0) return error.Timeout;
        const n = linux.read(fd, &chunk, chunk.len);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return out.toOwnedSlice(gpa);
                try out.appendSlice(gpa, chunk[0..n]);
            },
            .INTR, .AGAIN => {},
            else => return error.ReadFailed,
        }
    }
}

/// Writes all of `data` to `fd` (switched to blocking), then closes it.
pub fn writeAllAndClose(fd: linux.fd_t, data: []const u8) void {
    defer _ = linux.close(fd);
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) == .SUCCESS) _ = linux.fcntl(fd, linux.F.SETFL, flags & ~@as(usize, 0o4000)); // ~O_NONBLOCK
    var rest = data;
    while (rest.len > 0) {
        const n = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(n)) {
            .SUCCESS => rest = rest[n..],
            .INTR => {},
            else => return,
        }
    }
}

const testing = std.testing;

test "readFdWithTimeout reads to EOF and times out on a stalled writer" {
    var fds: [2]linux.fd_t = undefined;
    _ = linux.pipe2(&fds, .{ .CLOEXEC = true });
    _ = linux.write(fds[1], "hello clipboard", 15);
    _ = linux.close(fds[1]);
    const bytes = try readFdWithTimeout(testing.allocator, fds[0], 1000);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello clipboard", bytes);

    _ = linux.pipe2(&fds, .{ .CLOEXEC = true });
    defer _ = linux.close(fds[1]);
    try testing.expectError(error.Timeout, readFdWithTimeout(testing.allocator, fds[0], 30));
}

test "cursorNames" {
    try testing.expectEqualStrings("left_ptr", std.mem.span(cursorNames(.arrow)[0]));
    try testing.expectEqual(@as(usize, 0), cursorNames(.none).len);
}
