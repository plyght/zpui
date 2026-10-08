//! Canonical attachment chips — port of zeron `crates/proto/src/attachment_mentions.rs`
//! (shared by the editor, transcript and harness delivery).
//!
//! A composer attachment is referenced from the prompt by a strict local
//! Markdown link carrying only its per-draft number, never a path. Images read
//! `[Image N](zeron-image:N)`; other files carry their file name
//! (`[notes.md](zeron-attachment:N)`). Providers receive the plain label,
//! which pairs with the upload of the same name. Only canonical chip links are
//! decoded — never escaped text, code spans or image alt text — using the
//! pulldown-cmark port (`cmark`) for the offset event stream, as Rust does.

const std = @import("std");
const cmark = @import("cmark/parse.zig");
const Allocator = std.mem.Allocator;

pub const image_mention_scheme = "zeron-image:";
pub const attachment_mention_scheme = "zeron-attachment:";

pub const AttachmentMention = struct {
    /// Byte range of the whole link in the source text.
    start: usize,
    end: usize,
    index: u32,
    /// `Image N` for images, the file name for other attachments (owned by
    /// the allocator passed to `attachmentMentions`).
    label: []const u8,
    is_image: bool,

    /// `names_attachment`: whether this chip names the attachment at `path`.
    /// Images match by draft number (`Image 2` <-> `ab12cd34-Image_2.png`),
    /// files by name as the engine sanitizes it.
    pub fn namesAttachment(self: AttachmentMention, path: []const u8) bool {
        if (self.is_image) return imageIndexFromName(path) == self.index;
        const name = attachmentDisplayName(basename(path));
        return sanitizedEql(self.label, name);
    }
};

fn basename(path: []const u8) []const u8 {
    const cut = std.mem.findLastAny(u8, path, "/\\") orelse return path;
    return path[cut + 1 ..];
}

/// The engine's upload-name sanitizer, applied per char (each non-ASCII
/// char becomes one `_`).
fn sanitizedEql(a: []const u8, b: []const u8) bool {
    var ia = std.unicode.Utf8View.initUnchecked(a).iterator();
    var ib = std.unicode.Utf8View.initUnchecked(b).iterator();
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null or cb == null) return ca == null and cb == null;
        if (sanitize(ca.?) != sanitize(cb.?)) return false;
    }
}

fn sanitize(c: u21) u8 {
    if (c < 0x80) {
        const b: u8 = @intCast(c);
        if (std.ascii.isAlphanumeric(b) or b == '.' or b == '-' or b == '_') return b;
    }
    return '_';
}

/// `image_label`: the user-visible name of the `index`th image of a draft.
pub fn writeImageLabel(w: *std.Io.Writer, index: u32) std.Io.Writer.Error!void {
    try w.print("Image {d}", .{index});
}

pub fn imageLabel(gpa: Allocator, index: u32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "Image {d}", .{index});
}

/// `attachment_mention_link`: the chip link for attachment `index` — an
/// image when `file_name` is null.
pub fn writeAttachmentMentionLink(w: *std.Io.Writer, index: u32, file_name: ?[]const u8) std.Io.Writer.Error!void {
    const name = file_name orelse return w.print("[Image {d}](" ++ image_mention_scheme ++ "{d})", .{ index, index });
    try w.writeByte('[');
    // `file_mentions::escape_mention_label`.
    for (name) |c| switch (c) {
        '\\', '[', ']', '`' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
    try w.print("](" ++ attachment_mention_scheme ++ "{d})", .{index});
}

pub fn attachmentMentionLink(gpa: Allocator, index: u32, file_name: ?[]const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeAttachmentMentionLink(&aw.writer, index, file_name) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `image_index_from_name`: the draft number of an upload or staged image
/// name such as `Image 2.png` / `ab12cd34-Image_2.png` (uploads sanitize
/// spaces).
pub fn imageIndexFromName(path: []const u8) ?u32 {
    const name = basename(path);
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[0..dot] else name;
    var digits_at = stem.len;
    while (digits_at > 0 and std.ascii.isDigit(stem[digits_at - 1])) digits_at -= 1;
    const head_raw = stem[0..digits_at];
    const digits = stem[digits_at..];
    if (head_raw.len == 0) return null;
    const last = head_raw[head_raw.len - 1];
    if (last != ' ' and last != '_') return null;
    const head = head_raw[0 .. head_raw.len - 1];
    if (!(std.mem.eql(u8, head, "Image") or std.mem.endsWith(u8, head, "-Image"))) return null;
    const index = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (index > 0) index else null;
}

/// `is_image_path`: whether an attachment ref names an image (the
/// extensions the desktop decodes).
pub fn isImagePath(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    const known = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff" };
    for (known) |k| if (std.ascii.eqlIgnoreCase(ext, k)) return true;
    return false;
}

/// `attachment_display_name`: uploads are stored as `{id8}-{name}`; the
/// prefix is not part of the name.
pub fn attachmentDisplayName(name: []const u8) []const u8 {
    const dash = std.mem.indexOfScalar(u8, name, '-') orelse return name;
    const id = name[0..dash];
    if (id.len != 8) return name;
    for (id) |b| if (!std.ascii.isHex(b)) return name;
    return name[dash + 1 ..];
}

/// `unescape_label`: undo `escape_mention_label`, rejecting any label that is
/// not exactly what escaping produces. Null when rejected or empty.
fn unescapeLabel(gpa: Allocator, raw: []const u8) Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            '\\' => {
                if (i + 1 >= raw.len) return reject(gpa, &out);
                const e = raw[i + 1];
                if (e != '\\' and e != '[' and e != ']' and e != '`') return reject(gpa, &out);
                try out.append(gpa, e);
                i += 2;
                continue;
            },
            '[', ']', '`' => return reject(gpa, &out),
            else => {},
        }
        // `char::is_control`: Unicode Cc — U+0000..001F, U+007F..009F.
        const len = std.unicode.utf8ByteSequenceLength(c) catch return reject(gpa, &out);
        if (i + len > raw.len) return reject(gpa, &out);
        const cp = std.unicode.utf8Decode(raw[i .. i + len]) catch return reject(gpa, &out);
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return reject(gpa, &out);
        try out.appendSlice(gpa, raw[i .. i + len]);
        i += len;
    }
    if (out.items.len == 0) return reject(gpa, &out);
    return try out.toOwnedSlice(gpa);
}

fn reject(gpa: Allocator, out: *std.ArrayList(u8)) ?[]u8 {
    out.deinit(gpa);
    return null;
}

/// `attachment_mentions`: the canonical chip links of `text`, in order.
/// Labels and the slice are allocated in `arena` (free it wholesale).
pub fn attachmentMentions(arena: Allocator, text: []const u8) Allocator.Error![]AttachmentMention {
    if (std.mem.indexOf(u8, text, image_mention_scheme) == null and std.mem.indexOf(u8, text, attachment_mention_scheme) == null) return &.{};
    var out: std.ArrayList(AttachmentMention) = .empty;
    var parser = try cmark.Parser.init(arena, text);
    var image_depth: usize = 0;
    while (try parser.nextEvent()) |ev| {
        switch (ev.event) {
            .start => |tag| if (tag == .image) {
                image_depth += 1;
            },
            .end => |kind| if (kind == .image) {
                image_depth -|= 1;
            },
            else => {},
        }
        if (image_depth > 0) continue;
        const link = switch (ev.event) {
            .start => |tag| switch (tag) {
                .link => |l| l,
                else => continue,
            },
            else => continue,
        };
        const dest = link.dest_url;
        const is_image = std.mem.startsWith(u8, dest, image_mention_scheme);
        const scheme = if (is_image) image_mention_scheme else attachment_mention_scheme;
        if (!std.mem.startsWith(u8, dest, scheme)) continue;
        const digits = dest[scheme.len..];
        if (digits.len == 0) continue;
        const all_digits = for (digits) |b| {
            if (!std.ascii.isDigit(b)) break false;
        } else true;
        if (!all_digits) continue;
        const index = std.fmt.parseInt(u32, digits, 10) catch continue;
        if (index == 0) continue;
        const source = text[ev.start..ev.end];
        const label: []const u8 = if (is_image) blk: {
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeAttachmentMentionLink(&w, index, null) catch continue;
            if (!std.mem.eql(u8, source, w.buffered())) continue;
            break :blk try imageLabel(arena, index);
        } else blk: {
            if (source.len == 0 or source[0] != '[') continue;
            var tail_buf: [48]u8 = undefined;
            const tail = std.fmt.bufPrint(&tail_buf, "](" ++ attachment_mention_scheme ++ "{d})", .{index}) catch continue;
            if (!std.mem.endsWith(u8, source, tail) or source.len < 1 + tail.len) continue;
            break :blk (try unescapeLabel(arena, source[1 .. source.len - tail.len])) orelse continue;
        };
        try out.append(arena, .{ .start = ev.start, .end = ev.end, .index = index, .label = label, .is_image = is_image });
    }
    return out.toOwnedSlice(arena);
}

/// `attachment_mention_indices`: the attachment numbers a draft mentions,
/// in order of appearance, without repeats.
pub fn attachmentMentionIndices(arena: Allocator, text: []const u8) Allocator.Error![]u32 {
    var seen: std.ArrayList(u32) = .empty;
    for (try attachmentMentions(arena, text)) |m| {
        if (std.mem.indexOfScalar(u32, seen.items, m.index) == null) try seen.append(arena, m.index);
    }
    return seen.toOwnedSlice(arena);
}

/// `attachment_mention_prompt`: chips replaced by their plain label.
pub fn attachmentMentionPrompt(arena: Allocator, text: []const u8) Allocator.Error![]u8 {
    return replaceMentions(arena, text, &.{}, true);
}

/// `demote_unattached_mentions`: chips whose attachment is not attached
/// become plain text, so a dangling reference never leaves the composer as a
/// link.
pub fn demoteUnattachedMentions(arena: Allocator, text: []const u8, attached: []const u32) Allocator.Error![]u8 {
    return replaceMentions(arena, text, attached, false);
}

fn replaceMentions(arena: Allocator, text: []const u8, attached: []const u32, all: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (try attachmentMentions(arena, text)) |m| {
        if (!all and std.mem.indexOfScalar(u32, attached, m.index) != null) continue;
        try out.appendSlice(arena, text[at..m.start]);
        try out.appendSlice(arena, m.label);
        at = m.end;
    }
    try out.appendSlice(arena, text[at..]);
    return out.toOwnedSlice(arena);
}

// ---- tests (attachment_mentions.rs `mod tests`) ----

const testing = std.testing;

test "links round trip and become plain labels" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("[Image 2](zeron-image:2)", try attachmentMentionLink(a, 2, null));
    const notes = try attachmentMentionLink(a, 3, "my [notes].md");
    try testing.expectEqualStrings("[my \\[notes\\].md](zeron-attachment:3)", notes);
    const text = try std.fmt.allocPrint(a, "compare {s} with {s} and {s}", .{ try attachmentMentionLink(a, 2, null), notes, try attachmentMentionLink(a, 10, null) });
    const mentions = try attachmentMentions(a, text);
    try testing.expectEqual(@as(usize, 3), mentions.len);
    const want = [_]struct { u32, []const u8, bool }{ .{ 2, "Image 2", true }, .{ 3, "my [notes].md", false }, .{ 10, "Image 10", true } };
    for (mentions, want) |m, w| {
        try testing.expectEqual(w[0], m.index);
        try testing.expectEqualStrings(w[1], m.label);
        try testing.expectEqual(w[2], m.is_image);
    }
    try testing.expectEqualStrings(notes, text[mentions[1].start..mentions[1].end]);
    try testing.expectEqualStrings("compare Image 2 with my [notes].md and Image 10", try attachmentMentionPrompt(a, text));
    const twice = try std.fmt.allocPrint(a, "{s}{s}", .{ try attachmentMentionLink(a, 2, null), try attachmentMentionLink(a, 2, null) });
    try testing.expectEqualSlices(u32, &.{2}, try attachmentMentionIndices(a, twice));
}

test "hostile and literal links stay ordinary text" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const link = try attachmentMentionLink(a, 1, null);
    const file = try attachmentMentionLink(a, 1, "a.md");
    const literals = [_][]const u8{
        try std.fmt.allocPrint(a, "`{s}`", .{link}),
        try std.fmt.allocPrint(a, "```\n{s}\n```", .{link}),
        try std.fmt.allocPrint(a, "\\{s}", .{link}),
        try std.fmt.allocPrint(a, "![example {s}](example.png)", .{link}),
        try std.fmt.allocPrint(a, "`{s}`", .{file}),
        try std.fmt.allocPrint(a, "\\{s}", .{file}),
        "[Image 1](zeron-image:0)",
        "[Image 1](zeron-image:)",
        "[Image 1](zeron-image:1x)",
        "[Image 1](zeron-image:-1)",
        "[Image 1](zeron-image:../x)",
        "[Image 2](zeron-image:1)",
        "[Other](zeron-image:1)",
        "[Image 1](zeron-image:99999999999)",
        "[Image 01](zeron-image:01)",
        "[](zeron-attachment:1)",
        "[a.md](zeron-attachment:0)",
        "[a.md](zeron-attachment:1 \"title\")",
        "[a\nb.md](zeron-attachment:1)",
        "[a`b.md](zeron-attachment:1)",
        "[a\\xb.md](zeron-attachment:1)",
    };
    for (literals) |literal| {
        testing.expectEqual(@as(usize, 0), (try attachmentMentions(a, literal)).len) catch |e| {
            std.debug.print("literal: {s}\n", .{literal});
            return e;
        };
        try testing.expectEqualStrings(literal, try attachmentMentionPrompt(a, literal));
    }
}

test "unattached mentions demote to labels only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = try attachmentMentionLink(a, 2, "a.md");
    const text = try std.fmt.allocPrint(a, "{s} and {s}", .{ try attachmentMentionLink(a, 1, null), file });
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "Image 1 and {s}", .{file}), try demoteUnattachedMentions(a, text, &.{2}));
}

test "image names recover their number" {
    const cases = [_]struct { []const u8, ?u32 }{
        .{ "Image 3.png", 3 },
        .{ "ab12cd34-Image_12.png", 12 },
        .{ "/uploads/ab-Image_2.webp", 2 },
        .{ "Image 0.png", null },
        .{ "image.png", null },
        .{ "Imaged 2.png", null },
        .{ "cat.png", null },
    };
    for (cases) |c| try testing.expectEqual(c[1], imageIndexFromName(c[0]));
}

test "attachment refs split images from files" {
    try testing.expect(isImagePath("/uploads/ab12cd34-shot.PNG"));
    try testing.expect(isImagePath("pending://u1/Image_1.jpeg"));
    try testing.expect(!isImagePath("/uploads/ab12cd34-notes.zip"));
    try testing.expect(!isImagePath("/uploads/png"));
    try testing.expectEqualStrings("notes.zip", attachmentDisplayName("ab12cd34-notes.zip"));
    try testing.expectEqualStrings("my-notes.zip", attachmentDisplayName("my-notes.zip"));
}

test "chips name their attachment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try std.fmt.allocPrint(a, "{s} {s}", .{ try attachmentMentionLink(a, 2, null), try attachmentMentionLink(a, 3, "my notes.md") });
    const m = try attachmentMentions(a, text);
    try testing.expect(m[0].namesAttachment("/uploads/ab12cd34-Image_2.png"));
    try testing.expect(!m[0].namesAttachment("/uploads/ab12cd34-Image_3.png"));
    try testing.expect(m[1].namesAttachment("/uploads/ab12cd34-my_notes.md"));
    try testing.expect(!m[1].namesAttachment("/uploads/ab12cd34-other.md"));
}
