//! Canonical file references in the composer draft — ports of zeron
//! `crates/proto/src/file_mentions.rs` (`local_file_link`,
//! `local_path_is_safe`) and `composer.rs` (`reference_suffix`,
//! `dropped_file_mention`). An `@` mention or an explorer "Add to chat"
//! inserts `[basename](zeron-file:percent/encoded/path)`, the strict local
//! Markdown transport the harness delivery boundary decodes.
//!
//! Not ported: the input's chip projection (Rust draws the link as an
//! atomic chip); the Zig input shows the Markdown link text itself.

const std = @import("std");

pub const file_mention_scheme = "zeron-file:";

/// `local_path_is_safe`: a workspace-relative path with no empty, `.` or
/// `..` components, no backslashes and no control characters.
pub fn localPathIsSafe(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    for (path) |c| if (c < 0x20 or c == 0x7f) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn writeLabel(w: *std.Io.Writer, label: []const u8) !void {
    for (label) |c| switch (c) {
        '\\', '[', ']', '`' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
}

fn writeEncodedPath(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '.' or b == '_' or b == '~' or b == '/') {
            try w.writeByte(b);
        } else try w.print("%{X:0>2}", .{b});
    }
}

/// `local_file_link`: `[basename](zeron-file:path[/])`.
pub fn writeLocalFileLink(w: *std.Io.Writer, path_in: []const u8, is_dir: bool) !void {
    const path = std.mem.trimEnd(u8, path_in, "/");
    const basename = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse break :blk path;
        const tail = path[slash + 1 ..];
        break :blk if (tail.len > 0) tail else path;
    };
    try w.writeByte('[');
    try writeLabel(w, basename);
    try w.writeAll("](" ++ file_mention_scheme);
    try writeEncodedPath(w, path);
    if (is_dir) try w.writeByte('/');
    try w.writeByte(')');
}

pub fn localFileLink(gpa: std.mem.Allocator, path: []const u8, is_dir: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeLocalFileLink(&aw.writer, path, is_dir);
    return aw.toOwnedSlice();
}

pub const Suffix = struct { trailing: []const u8, advance: usize };

/// `reference_suffix`: a reference must not introduce whitespace before
/// closing Markdown syntax; existing horizontal whitespace is reused.
pub fn referenceSuffix(next: ?u8) Suffix {
    const c = next orelse return .{ .trailing = " ", .advance = 0 };
    return switch (c) {
        '\n', '\r' => .{ .trailing = "", .advance = 0 },
        ' ', '\t' => .{ .trailing = "", .advance = 1 },
        ')', ']', '}', '*', '_', '~', ',', '.', ';', ':', '!', '?' => .{ .trailing = "", .advance = 0 },
        else => .{ .trailing = " ", .advance = 0 },
    };
}

pub const Insertion = struct {
    /// Owned text to put in place of the selection.
    text: []u8,
    /// Caret offset from the selection start after the insert.
    cursor_advance: usize,
};

/// `dropped_file_mention`: the text inserted for a workspace item placed at
/// an arbitrary selection `[start, end)` of `content` — it supplies its own
/// leading separator when the previous character would glue onto the link.
pub fn droppedFileMention(gpa: std.mem.Allocator, content: []const u8, start: usize, end: usize, path: []const u8, is_dir: bool) !?Insertion {
    if (start > end or end > content.len or !localPathIsSafe(std.mem.trimEnd(u8, path, "/"))) return null;
    const prefix: []const u8 = if (start > 0) blk: {
        const prev = content[start - 1];
        const glue = !std.ascii.isWhitespace(prev) and switch (prev) {
            '(', '[', '{', '*', '_', '~' => false,
            else => true,
        };
        break :blk if (glue) " " else "";
    } else "";
    const suffix = referenceSuffix(if (end < content.len) content[end] else null);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll(prefix);
    try writeLocalFileLink(&aw.writer, path, is_dir);
    try aw.writer.writeAll(suffix.trailing);
    const text = try aw.toOwnedSlice();
    return .{ .text = text, .cursor_advance = text.len + suffix.advance };
}

const testing = std.testing;

test "local file links match file_mentions.rs" {
    const a = testing.allocator;
    const l1 = try localFileLink(a, "src/main.rs", false);
    defer a.free(l1);
    try testing.expectEqualStrings("[main.rs](zeron-file:src/main.rs)", l1);
    const l2 = try localFileLink(a, "my dir/", true);
    defer a.free(l2);
    try testing.expectEqualStrings("[my dir](zeron-file:my%20dir/)", l2);
    const l3 = try localFileLink(a, "a/[x]`y`.md", false);
    defer a.free(l3);
    try testing.expectEqualStrings("[\\[x\\]\\`y\\`.md](zeron-file:a/%5Bx%5D%60y%60.md)", l3);
}

test "safe paths" {
    try testing.expect(localPathIsSafe("src/a.rs"));
    try testing.expect(!localPathIsSafe("/abs"));
    try testing.expect(!localPathIsSafe("a/../b"));
    try testing.expect(!localPathIsSafe("a//b"));
    try testing.expect(!localPathIsSafe("a\\b"));
    try testing.expect(!localPathIsSafe(""));
}

test "dropped mention separators" {
    const a = testing.allocator;
    const r1 = (try droppedFileMention(a, "see", 3, 3, "x.md", false)).?;
    defer a.free(r1.text);
    try testing.expectEqualStrings(" [x.md](zeron-file:x.md) ", r1.text);
    const r2 = (try droppedFileMention(a, "(", 1, 1, "x.md", false)).?;
    defer a.free(r2.text);
    try testing.expectEqualStrings("[x.md](zeron-file:x.md) ", r2.text);
    const r3 = (try droppedFileMention(a, "a  b", 2, 2, "x", false)).?;
    defer a.free(r3.text);
    try testing.expectEqualStrings("[x](zeron-file:x)", r3.text);
    try testing.expectEqual(r3.text.len + 1, r3.cursor_advance);
    try testing.expect((try droppedFileMention(a, "", 0, 0, "../x", false)) == null);
}
