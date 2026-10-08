//! Image previews inside expanded tool chips — the pure half of zeron
//! `crates/ui/src/tool_images.rs`: which image files a tool call read, wrote
//! or printed (`image_paths`), and where they live on the owning host
//! (`resolve_path`). UNC, device and drive-relative paths are never
//! previewed (opening one can reach another host). Pixels come through the
//! transcript's attachment cache (`TranscriptView.imageState`).
//!
//! Not ported: the bounded BGRA thumbnail decode, the 600 ms release grace
//! and the 64 MiB offscreen budget (`ToolImages`); the shared attachment
//! cache decodes and keeps the full image instead.

const std = @import("std");
const protocol = @import("zeron_engine").protocol;
const ToolCall = protocol.ToolCall;
const Allocator = std.mem.Allocator;

/// `MAX_IMAGES_PER_TOOL`: previews per chip; further paths stay in the text.
pub const max_images_per_tool: usize = 4;
/// `TOOL_IMAGE_HEIGHT` / `TOOL_IMAGE_MAX_WIDTH` / `TOOL_IMAGE_PAD`.
pub const image_height: f32 = 220;
pub const image_max_width: f32 = 560;
pub const image_pad: f32 = 8;

const image_extensions = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tif", "tiff" };

/// `is_image_path`: a file name with a non-empty stem and an image extension.
pub fn isImagePath(path: []const u8) bool {
    const cut = std.mem.findLastAny(u8, path, "/\\");
    const name = if (cut) |c| path[c + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    const ext = name[dot + 1 ..];
    for (image_extensions) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn isSep(b: ?u8) bool {
    const c = b orelse return false;
    return c == '/' or c == '\\';
}

/// `is_remote_or_device_path`: UNC (`\\host\share`, `//host/share`), device
/// and verbatim (`\\.\`, `\\?\`, `\??\`) and drive-relative (`C:x.png`).
pub fn isRemoteOrDevicePath(path: []const u8) bool {
    const at = struct {
        fn f(p: []const u8, i: usize) ?u8 {
            return if (i < p.len) p[i] else null;
        }
    }.f;
    if (isSep(at(path, 0)) and isSep(at(path, 1))) return true;
    if (std.mem.startsWith(u8, path, "\\??\\")) return true;
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and !isSep(at(path, 2));
}

const Paths = struct {
    gpa: Allocator,
    list: std.ArrayList([]const u8) = .empty,

    fn full(self: *const Paths) bool {
        return self.list.items.len >= max_images_per_tool;
    }

    /// `push_path`.
    fn push(self: *Paths, path: []const u8) Allocator.Error!void {
        if (self.full() or !isImagePath(path) or isRemoteOrDevicePath(path)) return;
        for (self.list.items) |known| if (std.mem.eql(u8, known, path)) return;
        try self.list.append(self.gpa, try self.gpa.dupe(u8, path));
    }

    /// `push_text_paths`: image-looking local paths in free text. URLs and
    /// glob patterns are skipped; trailing sentence punctuation is dropped.
    fn pushText(self: *Paths, text: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i <= text.len) {
            if (self.full()) return;
            const start = i;
            while (i < text.len) {
                const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + len, text.len);
                if (isSeparator(text[i..end])) break;
                i = end;
            }
            var token = text[start..i];
            // The separator itself (one char).
            if (i < text.len) i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1 else i += 1;
            token = std.mem.trimEnd(u8, token, ".:!?");
            if (std.mem.startsWith(u8, token, "file://")) token = token["file://".len..];
            if (std.mem.indexOf(u8, token, "://") != null or std.mem.startsWith(u8, token, "data:") or
                std.mem.indexOfAny(u8, token, "*?") != null) continue;
            try self.push(token);
        }
    }

    /// `push_json_paths`.
    fn pushJson(self: *Paths, value: std.json.Value) Allocator.Error!void {
        switch (value) {
            .string => |s| try self.pushText(s),
            .array => |arr| for (arr.items) |v| try self.pushJson(v),
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |kv| try self.pushJson(kv.value_ptr.*);
            },
            else => {},
        }
    }
};

/// `char::is_whitespace` or one of `"'` `` ` `` `<>()[]{},;|=`.
fn isSeparator(ch: []const u8) bool {
    if (ch.len == 1) {
        return switch (ch[0]) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c, '"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}', ',', ';', '|', '=' => true,
            else => false,
        };
    }
    const cp = std.unicode.utf8Decode(ch) catch return false;
    return switch (cp) {
        0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `image_paths`: the image files a tool call touched, as reported (maybe
/// relative to the chat's cwd). Strings are allocated in `a`.
pub fn imagePaths(a: Allocator, call: ToolCall, output: ?[]const u8) Allocator.Error![]const []const u8 {
    var p: Paths = .{ .gpa = a };
    switch (call) {
        .readFile => |c| try p.push(c.path),
        .writeFile => |c| try p.push(c.path),
        .editFile => |c| try p.push(c.path),
        .applyPatch => |c| if (c.path) |path| try p.push(path),
        .exec => |c| try p.pushText(c.command),
        .mcp => |c| if (c.input) |in| try p.pushJson(in),
        .unknown => |c| if (c.input) |in| try p.pushJson(in),
        else => {},
    }
    if (output) |o| try p.pushText(o);
    return p.list.toOwnedSlice(a);
}

/// `resolve_path`: absolute path on the owning host. Relative paths join the
/// chat's cwd in that host's separator style (the UI may run on another OS).
pub fn resolvePath(a: Allocator, path: []const u8, cwd: ?[]const u8) Allocator.Error![]const u8 {
    const absolute = (path.len > 0 and (path[0] == '/' or path[0] == '\\')) or
        (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\'));
    const dir = (if (absolute) null else cwd) orelse return a.dupe(u8, path);
    var rel = path;
    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    if (std.mem.indexOfScalar(u8, dir, '\\') != null) {
        const tail = try a.dupe(u8, rel);
        std.mem.replaceScalar(u8, tail, '/', '\\');
        return std.fmt.allocPrint(a, "{s}\\{s}", .{ std.mem.trimEnd(u8, dir, "/\\"), tail });
    }
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), rel });
}

/// `OUTPUT_LINE_MAX_CHARS`: chars kept per output line (lines clip rather
/// than wrap, but each is shaped whole for selection).
pub const output_line_max_chars: usize = 8 * 1024;

/// `output_line`: one verbatim output line, cut with an ellipsis.
pub fn outputLine(a: Allocator, line: []const u8) Allocator.Error![]const u8 {
    if (line.len <= output_line_max_chars) return line; // byte count bounds the char count
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    var n: usize = 0;
    while (n < output_line_max_chars) : (n += 1) if (it.nextCodepointSlice() == null) return line;
    if (it.i >= line.len) return line;
    return std.fmt.allocPrint(a, "{s}\u{2026}", .{line[0..it.i]});
}

// ---- tests (tool_images.rs `mod tests`) ----

const testing = std.testing;

fn expectPaths(call: ToolCall, output: ?[]const u8, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try imagePaths(arena.allocator(), call, output);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "finds images in paths, commands, output and json" {
    try expectPaths(.{ .readFile = .{ .path = "shots/A.PNG" } }, null, &.{"shots/A.PNG"});
    try expectPaths(.{ .readFile = .{ .path = "src/main.rs" } }, null, &.{});
    try expectPaths(.{ .exec = .{ .command = "python plot.py --out=chart.png" } }, "Saved to /tmp/x/chart.png.\nsee https://a.b/c.png and **/*.jpg", &.{ "chart.png", "/tmp/x/chart.png" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"opts": {"file": "C:\\shots\\home.webp"}}
    , .{});
    try expectPaths(.{ .mcp = .{ .server = "browser", .tool = "screenshot", .input = input } }, null, &.{"C:\\shots\\home.webp"});
    var many: std.ArrayList(u8) = .empty;
    for (0..9) |i| try many.print(arena.allocator(), "{d}.jpg ", .{i});
    const got = try imagePaths(arena.allocator(), .{ .exec = .{ .command = many.items } }, null);
    try testing.expectEqual(max_images_per_tool, got.len);
}

test "relative paths join the owning host's cwd" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/w/a/b.png", try resolvePath(a, "a/b.png", "/w"));
    try testing.expectEqualStrings("/w/b.png", try resolvePath(a, "./b.png", "/w/"));
    try testing.expectEqualStrings("C:\\w\\a\\b.png", try resolvePath(a, "a/b.png", "C:\\w"));
    try testing.expectEqualStrings("D:\\x.png", try resolvePath(a, "D:\\x.png", "C:\\w"));
    try testing.expectEqualStrings("/x.png", try resolvePath(a, "/x.png", "/w"));
    try testing.expectEqualStrings("x.png", try resolvePath(a, "x.png", null));
    try testing.expectEqualStrings("/w/C:x.png", try resolvePath(a, "C:x.png", "/w"));
}

test "network, device and drive-relative paths are never previewed" {
    const output =
        \\\\attacker\share\a.png
        \\//attacker/share/b.png
        \\\/attacker\share\c.png
        \\file:////attacker/share/d.png
        \\\\?\UNC\attacker\share\e.png
        \\\\?\C:\shots\f.png
        \\\\.\pipe\g.png
        \\\??\UNC\attacker\share\h.png
        \\C:i.png
    ;
    try expectPaths(.{ .exec = .{ .command = "open ok.png" } }, output, &.{"ok.png"});
    try expectPaths(.{ .readFile = .{ .path = "\\\\attacker\\share\\a.png" } }, null, &.{});
    // Ordinary absolute paths in both styles still preview.
    try expectPaths(.{ .exec = .{ .command = "cp /tmp/a.png C:\\shots\\b.png D:/c.png" } }, null, &.{ "/tmp/a.png", "C:\\shots\\b.png", "D:/c.png" });
}

test "output lines are cut at the char cap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("short", try outputLine(a, "short"));
    const long = try a.alloc(u8, output_line_max_chars + 5);
    @memset(long, 'x');
    const cut = try outputLine(a, long);
    try testing.expect(std.mem.endsWith(u8, cut, "\u{2026}"));
    try testing.expectEqual(output_line_max_chars + "\u{2026}".len, cut.len);
}
