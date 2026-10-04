//! Native, virtualized preview of a file's current Markdown buffer — port of
//! zeron `files/markdown_preview.rs` + `files/markdown_media.rs`.
//!
//! The editor's buffer parses into a `BlockTree` whose top-level blocks are
//! the rows of a top-aligned `list` (one 900px-max column, 24px gutters,
//! 16px breathing room above and below). Rows render through the transcript
//! renderer with checkboxes for tasks, code fences with copy + fit, Mermaid
//! diagrams, and images resolved against the document (local workspaces
//! load them; web images are never fetched and stay `alt — url` links).
//! Links route like zeron's preview: `#anchor` scrolls to its heading,
//! relative documents open in the editor (`OpenPath`), web links take the
//! app's link handler, anything else is rejected. A document outside the
//! workspace (absolute path) drops its local links.
//!
//! ```zig
//! const v = try cx.newWith(MarkdownPreview, MarkdownPreview.init, .{ files, "README.md" });
//! v.update(cx, MarkdownPreview.setSource, .{ text, truncated });
//! div().child(v)    // fills its parent; events: OpenPath{ .path }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const mdm = @import("zeron_markdown");
const md = @import("zeron_ui_markdown");
const ui = @import("../components/root.zig");
const client = @import("client.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const Theme = zt.Theme;
const Block = mdm.Block;
const BlockTree = mdm.BlockTree;
const InlineRun = mdm.InlineRun;

pub const max_markdown_bytes: usize = 2 * 1024 * 1024;
pub const max_preview_content_width: f32 = 900;
pub const preview_vertical_padding: f32 = 16;
pub const preview_gutter: f32 = 24;

/// Open another workspace document (relative link).
pub const OpenPath = struct { path: []const u8 };

/// `is_markdown`.
pub fn isMarkdown(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(ext, "md") or std.ascii.eqlIgnoreCase(ext, "markdown");
}

/// A document outside the workspace (`path_is_outside`: absolute paths).
pub fn pathIsOutside(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

pub const Target = struct { path: []const u8, anchor: ?[]const u8 };

fn percentDecode(a: Allocator, s: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return null;
            out.append(a, hi * 16 + lo) catch return null;
            i += 2;
        } else out.append(a, s[i]) catch return null;
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return null;
    return out.items;
}

/// `relative_target`: a link resolved against the document's folder (URL
/// path rules, independent of the host filesystem). Null for absolute,
/// schemed, escaping or malformed targets.
pub fn relativeTarget(a: Allocator, document: []const u8, target: []const u8) ?Target {
    if (std.mem.startsWith(u8, target, "zeron-file:")) return relativeTarget(a, "", target["zeron-file:".len..]);
    if (std.mem.startsWith(u8, target, "/") or std.mem.indexOfScalar(u8, target, ':') != null or std.mem.indexOfScalar(u8, target, '\\') != null) return null;
    const hash = std.mem.indexOfScalar(u8, target, '#');
    const raw_path = if (hash) |h| target[0..h] else target;
    const anchor: ?[]const u8 = if (hash) |h| percentDecode(a, target[h + 1 ..]) else null;
    const path = percentDecode(a, raw_path) orelse return null;
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null or std.mem.startsWith(u8, path, "/")) return null;
    if (path.len == 0) return .{ .path = document, .anchor = anchor };
    var parts: std.ArrayList([]const u8) = .empty;
    var dit = std.mem.splitScalar(u8, document, '/');
    while (dit.next()) |p| parts.append(a, p) catch return null;
    _ = parts.pop();
    var pit = std.mem.splitScalar(u8, path, '/');
    while (pit.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.pop() == null) return null;
            continue;
        }
        parts.append(a, p) catch return null;
    }
    if (parts.items.len == 0) return null;
    return .{ .path = std.mem.join(a, "/", parts.items) catch return null, .anchor = anchor };
}

/// `block_source_lines`: each top block's first 1-based source line.
pub fn blockSourceLines(a: Allocator, source: []const u8, tree: BlockTree) Allocator.Error![]u32 {
    var starts: std.ArrayList(usize) = .empty;
    try starts.append(a, 0);
    for (source, 0..) |c, i| if (c == '\n') try starts.append(a, i + 1);
    const out = try a.alloc(u32, tree.blocks.len);
    for (tree.blocks, out) |top, *o| {
        var n: u32 = 0;
        for (starts.items) |s| {
            if (s <= top.range.start) n += 1 else break;
        }
        o.* = n;
    }
    return out;
}

/// The heading anchor slug (`set_source`): lowercase, alphanumerics, space,
/// `-` and `_` kept, spaces become dashes.
pub fn headingSlug(a: Allocator, runs: []const InlineRun) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (runs) |r| {
        var it = std.unicode.Utf8View.initUnchecked(r.text).iterator();
        while (it.nextCodepoint()) |cp| {
            const lower: u21 = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
            const keep = (lower < 128 and (std.ascii.isAlphanumeric(@intCast(lower)) or lower == ' ' or lower == '-' or lower == '_')) or
                (lower >= 128 and isAlphanumericUnicode(lower));
            if (!keep) continue;
            if (lower == ' ') {
                try out.append(a, '-');
                continue;
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(lower, &buf) catch continue;
            try out.appendSlice(a, buf[0..n]);
        }
    }
    return out.items;
}

/// Non-ASCII letters/digits (approximation of `char::is_alphanumeric`):
/// everything outside the common punctuation, symbol and space blocks.
fn isAlphanumericUnicode(cp: u21) bool {
    return !((cp >= 0x2000 and cp <= 0x2BFF) or (cp >= 0x3000 and cp <= 0x303F) or (cp >= 0x1F000 and cp <= 0x1FAFF) or
        cp == 0xA0 or (cp >= 0xA1 and cp <= 0xBF and cp != 0xAA and cp != 0xB2 and cp != 0xB3 and cp != 0xB5 and cp != 0xB9 and cp != 0xBA) or
        cp == 0xD7 or cp == 0xF7 or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFF00 and cp <= 0xFF0F));
}

/// `image_sources` (markdown_media.rs): distinct image sources, nested and
/// repeated media included once, in document order.
pub fn imageSources(a: Allocator, tree: BlockTree) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (tree.blocks) |top| try collectImages(a, top.block, &out);
    return out.items;
}

fn collectRuns(a: Allocator, runs: []const InlineRun, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    for (runs) |r| if (r.style.image) |img| {
        for (out.items) |s| {
            if (std.mem.eql(u8, s, img.source)) break;
        } else try out.append(a, img.source);
    };
}

fn collectImages(a: Allocator, b: Block, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    switch (b) {
        .paragraph => |r| try collectRuns(a, r, out),
        .heading => |h| try collectRuns(a, h.runs, out),
        .block_quote => |c| for (c) |child| try collectImages(a, child, out),
        .list => |l| for (l.items) |item| for (item) |child| try collectImages(a, child, out),
        .table => |t| {
            for (t.header) |cell| try collectRuns(a, cell, out);
            for (t.rows) |row| for (row) |cell| try collectRuns(a, cell, out);
        },
        else => {},
    }
}

/// `diagram_sources`: distinct Mermaid fences (top level, quotes, lists).
pub fn diagramSources(a: Allocator, tree: BlockTree) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (tree.blocks) |top| try collectDiagrams(a, top.block, &out);
    return out.items;
}

fn collectDiagrams(a: Allocator, b: Block, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    switch (b) {
        .code_block => |c| if (c.language) |l| if (std.ascii.eqlIgnoreCase(l, "mermaid")) {
            for (out.items) |s| {
                if (std.mem.eql(u8, s, c.code)) break;
            } else try out.append(a, c.code);
        },
        .block_quote => |c| for (c) |child| try collectDiagrams(a, child, out),
        .list => |l| for (l.items) |item| for (item) |child| try collectDiagrams(a, child, out),
        else => {},
    }
}

/// `web_target`: links a preview still treats as links (web and mail).
pub fn webTarget(target: []const u8) bool {
    if (md.link_presentation.isWebTarget(target)) return true;
    for (target) |c| if (c < 0x20 or c == 0x7f) return false;
    return std.ascii.startsWithIgnoreCase(target, "mailto:") and target.len > "mailto:".len;
}

pub const MarkdownPreview = struct {
    gpa: Allocator,
    files: Entity(client.WorkspaceFiles),
    path: []u8,
    tree: BlockTree = .{},
    /// Hash of the parsed source (+ truncation), so unchanged buffers never reparse.
    source_key: ?u64 = null,
    truncated: bool = false,
    anchors: std.StringHashMapUnmanaged(usize) = .empty,
    anchor_arena: std.heap.ArenaAllocator,
    list: zpui.elements.ListState,
    focus: zpui.FocusHandle,
    /// `OpenPath` payload (events are delivered after the emitting call).
    open_buf: std.ArrayList(u8) = .empty,
    scope: u64,

    pub const Events = .{OpenPath};

    pub fn init(files: Entity(client.WorkspaceFiles), path: []const u8, cx: *Context(MarkdownPreview)) !MarkdownPreview {
        const gpa = cx.gpa();
        return .{
            .gpa = gpa,
            .files = files.retain(cx),
            .path = try gpa.dupe(u8, path),
            .anchor_arena = .init(gpa),
            .list = zpui.elements.ListState.init(gpa, 0, .top, 400),
            .focus = cx.focusHandle(),
            .scope = std.hash.Wyhash.hash(0x3d9e, std.mem.asBytes(&cx.entityId())),
        };
    }

    pub fn deinit(self: *MarkdownPreview, app: *App) void {
        self.files.release(app);
        self.focus.release(app);
        self.list.release();
        self.tree.deinit(self.gpa);
        self.anchors.deinit(self.gpa);
        self.anchor_arena.deinit();
        self.open_buf.deinit(self.gpa);
        self.gpa.free(self.path);
    }

    pub fn setPath(self: *MarkdownPreview, path: []const u8, cx: *Context(MarkdownPreview)) void {
        if (std.mem.eql(u8, path, self.path)) return;
        self.gpa.free(self.path);
        self.path = self.gpa.dupe(u8, path) catch @panic("OOM");
        self.source_key = null;
        cx.notify();
    }

    /// Show `source` (the editor's current buffer). Clipped at 2 MB.
    pub fn setSource(self: *MarkdownPreview, source_in: []const u8, truncated_in: bool, cx: *Context(MarkdownPreview)) void {
        var source = source_in;
        const clipped = source.len > max_markdown_bytes;
        if (clipped) {
            var end = max_markdown_bytes;
            while (end > 0 and source[end] & 0xC0 == 0x80) end -= 1;
            source = source[0..end];
        }
        const truncated = truncated_in or clipped;
        var h = std.hash.Wyhash.init(@intFromBool(truncated));
        h.update(self.path);
        h.update(source);
        const key = h.final();
        if (self.source_key == key) return;
        self.source_key = key;
        self.truncated = truncated;
        const tree = mdm.parseFull(self.gpa, source) catch return;
        // Keep the reading position across reparses.
        const top = self.list.logicalScrollTop();
        self.tree.deinit(self.gpa);
        self.tree = tree;
        self.list.reset(tree.blocks.len);
        if (tree.blocks.len > 0) self.list.scrollTo(.{ .item_ix = @min(top.item_ix, tree.blocks.len - 1), .offset_in_item = top.offset_in_item });
        // Heading anchors (`#slug`, de-duplicated with `-n`).
        self.anchors.clearRetainingCapacity();
        _ = self.anchor_arena.reset(.retain_capacity);
        const a = self.anchor_arena.allocator();
        for (tree.blocks, 0..) |t, ix| switch (t.block) {
            .heading => |hd| {
                const slug = headingSlug(a, hd.runs) catch continue;
                var unique: []const u8 = slug;
                var n: usize = 1;
                while (self.anchors.contains(unique)) : (n += 1) unique = std.fmt.allocPrint(a, "{s}-{d}", .{ slug, n }) catch break;
                self.anchors.put(self.gpa, unique, ix) catch {};
            },
            else => {},
        };
        cx.notify();
    }

    pub fn focusPreview(self: *MarkdownPreview, window: *Window) void {
        window.focus(self.focus);
    }

    // ---- links / media --------------------------------------------------------------------

    /// `link_ui`'s handler: anchors scroll, relative documents open, web and
    /// mail links take the app's handler, anything else is rejected.
    fn onLink(owner: u64, url: []const u8, _: *Window, app: *App) bool {
        if (webTarget(url)) return false;
        const weak: zpui.WeakEntity(MarkdownPreview) = .{ .id = @enumFromInt(owner) };
        const ent = weak.upgrade(app) orelse return true;
        defer ent.release(app);
        var l = ent.lease(app);
        defer l.end();
        const self = l.value;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (pathIsOutside(self.path)) return true;
        const t = relativeTarget(arena.allocator(), self.path, url) orelse return true;
        if (std.mem.eql(u8, t.path, self.path)) {
            if (t.anchor) |anc| if (self.anchors.get(anc)) |ix| {
                self.list.scrollTo(.{ .item_ix = ix, .offset_in_item = 0 });
                l.cx.notify();
            };
            return true;
        }
        self.open_buf.clearRetainingCapacity();
        self.open_buf.appendSlice(self.gpa, t.path) catch return true;
        l.cx.emit(OpenPath{ .path = self.open_buf.items });
        return true;
    }

    const ImageCtx = struct { root: ?[]const u8, document: []const u8 };

    /// Local workspaces load relative images from disk; nothing is fetched.
    fn resolveImage(ctx_ptr: *const anyopaque, source: []const u8, a: Allocator) ?[]const u8 {
        const ctx: *const ImageCtx = @ptrCast(@alignCast(ctx_ptr));
        const root = ctx.root orelse return null;
        if (pathIsOutside(ctx.document)) return null;
        const t = relativeTarget(a, ctx.document, source) orelse return null;
        return std.fs.path.join(a, &.{ root, t.path }) catch null;
    }

    // ---- input ------------------------------------------------------------------------------

    fn onMouseDownCapture(self: *MarkdownPreview, _: *const zpui.input.MouseDownEvent, window: *Window, _: *Context(MarkdownPreview)) void {
        if (md.registry.sel_key != 0) {
            md.registry.clearSelection();
            window.refresh();
        }
        window.focus(self.focus);
    }

    fn onKey(_: *MarkdownPreview, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(MarkdownPreview)) void {
        const k = ev.keystroke;
        if ((k.modifiers.control or k.modifiers.platform) and std.mem.eql(u8, k.key, "c")) {
            if (md.registry.selectedText()) |t| {
                md.copyToClipboard(cx.app, t);
                cx.app.propagate_event = false;
            }
        }
    }

    // ---- render -----------------------------------------------------------------------------

    fn renderRow(self: *MarkdownPreview, ix: usize, window: *Window, cx: *Context(MarkdownPreview)) zpui.AnyElement {
        if (ix >= self.tree.blocks.len) return zpui.empty();
        const theme = ui.theme.get(cx);
        const a = zpui.window.arena_mod.current().allocator();
        const img_ctx = a.create(ImageCtx) catch @panic("OOM");
        img_ctx.* = .{ .root = self.files.read(cx).localRoot(), .document = a.dupe(u8, self.path) catch "" };
        var key = std.hash.Wyhash.init(self.scope);
        key.update(std.mem.asBytes(&ix));
        const block = md.renderTopBlock(self.tree, ix, .{
            .theme = theme,
            .key = key.final(),
            .copy = true,
            .fit_toggle = true,
            .tasks = .checkbox,
            .images = true,
            .image_resolver = .{ .ctx = img_ctx, .f = resolveImage },
            .diagrams = true,
            .link_owner = .{ .owner = @intFromEnum(cx.entityId()), .f = onLink },
        }, window);
        return zpui.intoAnyElement(div().wFull().flex().flexCol().pb(px(md.block_gap))
            .child(div().wFull().flex().justifyCenter().px(px(preview_gutter))
                .child(div().wFull().maxW(px(max_preview_content_width)).minW0().relative().child(block))));
    }

    pub fn render(self: *MarkdownPreview, window: *Window, cx: *Context(MarkdownPreview)) zpui.AnyElement {
        const theme = ui.theme.get(cx);
        md.setClock(cx.app);
        {
            const w = self.list.viewportBounds().size.width;
            const column = if (w > 0) @min(w - 2 * preview_gutter, max_preview_content_width) else max_preview_content_width;
            md.diagrams.beginFrame(column, window.scaleFactor());
        }
        var root = div().id("markdown-file-preview").sizeFull().minW0().minH0().flex().flexCol()
            .fontFamily(theme.font_sans).textColor(theme.text).trackFocus(self.focus)
            .captureAnyMouseDown(cx.listener(onMouseDownCapture))
            .onKeyDown(cx.listener(onKey));
        if (self.truncated) root = root.child(div().px(px(preview_gutter)).textColor(theme.warning_muted)
            .child("Large file preview is truncated and read-only."));
        root = root.child(zpui.elements.list(self.list, cx, renderRow).flex1().minH0().py(px(preview_vertical_padding)));
        return zpui.intoAnyElement(root);
    }
};

// ---------------------------------------------------------------------------
// Tests (markdown_preview.rs / markdown_media.rs)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "markdown paths and links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(isMarkdown("docs/README.MD"));
    try testing.expect(isMarkdown("x.markdown"));
    try testing.expect(!isMarkdown("x.mdx"));
    const t = relativeTarget(a, "docs/readme.md", "../a%20b.md#hello").?;
    try testing.expectEqualStrings("a b.md", t.path);
    try testing.expectEqualStrings("hello", t.anchor.?);
    try testing.expect(relativeTarget(a, "readme.md", "../secret") == null);
    try testing.expect(relativeTarget(a, "docs/readme.md", "%2Fetc/passwd") == null);
    try testing.expect(relativeTarget(a, "docs/readme.md", "https://example.com") == null);
    const self_anchor = relativeTarget(a, "docs/readme.md", "#hello").?;
    try testing.expectEqualStrings("docs/readme.md", self_anchor.path);
    try testing.expectEqualStrings("hello", self_anchor.anchor.?);
    try testing.expectEqualStrings("src/a.rs", relativeTarget(a, "docs/readme.md", "zeron-file:src/a.rs").?.path);
}

test "preview retains mail links without allowing active schemes" {
    try testing.expect(webTarget("mailto:reader@example.com"));
    try testing.expect(webTarget("https://example.com"));
    try testing.expect(!webTarget("javascript:alert(1)"));
}

test "comments map to original lines and containing blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "# Título 🦀\r\n\r\nPárrafo\r\nsegunda línea\r\n\r\n- uno\r\n- dos\r\n\r\n```mermaid\r\ngraph TD; A-->B\r\n```\r\n";
    var tree = try mdm.parseFull(testing.allocator, source);
    defer tree.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 6, 9 }, try blockSourceLines(arena.allocator(), source, tree));
    const diagrams = try diagramSources(arena.allocator(), tree);
    try testing.expectEqual(@as(usize, 1), diagrams.len);
}

test "image collection preserves nested and repeated media" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tree = try mdm.parseFull(testing.allocator, "before ![a](a.png) after\n\n> ![b](b.svg)\n\n- ![a](a.png)");
    defer tree.deinit(testing.allocator);
    const srcs = try imageSources(arena.allocator(), tree);
    try testing.expectEqual(@as(usize, 2), srcs.len);
    try testing.expectEqualStrings("a.png", srcs[0]);
    try testing.expectEqualStrings("b.svg", srcs[1]);
}

test "heading slugs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("hello-world-1", try headingSlug(arena.allocator(), &.{.{ .text = "Hello, World 1!" }}));
    try testing.expectEqualStrings("título-", try headingSlug(arena.allocator(), &.{.{ .text = "Título 🦀" }}));
}
