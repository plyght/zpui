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
const zmodel = @import("zeron_model");
const input = @import("zeron_input");
const comment_ui = @import("../changes/comment_ui.zig");
const editor_view = @import("../editor/view.zig");
const review = @import("../editor/review.zig");
const cm = zmodel.comments;
const FileEditor = editor_view.FileEditor;
const image_preview = @import("image_preview.zig");
const proto = @import("protocol.zig");
const media = md.media;
const RenderImage = zpui.RenderImage;

/// `MAX_MEDIA_ENTRIES`: images (and diagrams) a document previews.
pub const max_media_entries: usize = 32;
/// `MAX_MEDIA_BYTES`: decoded pixels all of a document's images may hold.
pub const max_media_bytes: usize = 64 * 1024 * 1024;

/// One document image (`images`): loading, decoded, or why not.
const Media = union(enum) {
    loading,
    ready: struct { image: *RenderImage, width: f32, height: f32, bytes: usize },
    failed: []const u8,
};

/// An engine image being assembled from `ReadWorkspaceImage` chunks.
const Fetch = struct {
    source: []u8,
    path: []u8,
    bytes: std.ArrayList(u8) = .empty,
    offset: u64 = 0,
    content_hash: ?[]u8 = null,
    mime: ?[]u8 = null,
    size: ?u64 = null,

    fn deinit(f: *Fetch, gpa: Allocator) void {
        gpa.free(f.source);
        gpa.free(f.path);
        f.bytes.deinit(gpa);
        if (f.content_hash) |h| gpa.free(h);
        if (f.mime) |m| gpa.free(m);
    }
};

const LocalLoad = struct { source: []u8, file: []u8 };

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

/// `comment_block`: the top block holding 1-based `line` (the last block
/// starting at or before it). Null without blocks.
pub fn commentBlock(lines: []const u32, line: u32) ?usize {
    if (lines.len == 0) return null;
    var n: usize = 0;
    for (lines) |start| {
        if (start <= line) n += 1 else break;
    }
    return n -| 1;
}

/// The preview's open comment draft (`comment_draft`).
pub const CommentDraft = struct { line: u32, input: Entity(input.TextInput), editing: bool };

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
    /// Each top block's first source line (`block_lines`).
    block_lines: std.ArrayList(u32) = .empty,
    /// Hash of the parsed source (`parsed_source`): a comment opens only
    /// while the editor still holds exactly what is shown.
    parsed_hash: u64 = 0,
    /// Review comments (`set_comments`): the owning editor, its staged file
    /// comments (copies) and its open draft.
    comment_owner: ?zpui.WeakEntity(FileEditor) = null,
    comments: []cm.ReviewComment = &.{},
    comments_arena: std.heap.ArenaAllocator,
    comment_draft: ?CommentDraft = null,
    comments_key: u64 = 0,
    /// The editor accepts comments (editable and loaded).
    comments_editable: bool = false,
    /// Document images by source (owned keys): the engine fetch queue and
    /// local reads load one at a time, then decode off-thread.
    images: std.StringHashMapUnmanaged(Media) = .empty,
    fetch_queue: std.ArrayList(Fetch) = .empty,
    fetching: ?Fetch = null,
    fetch_timeout: zpui.Task(void) = .none,
    decode_task: zpui.Task(image_preview.Loaded) = .none,
    decoding: ?[]u8 = null,
    local_queue: std.ArrayList(LocalLoad) = .empty,
    /// The workspace checkout engine images are read from (the editor's).
    checkout_id: ?[]u8 = null,
    /// The shared lightbox (an image or a diagram enlarged).
    lightbox: ?Entity(media.Lightbox) = null,
    lightbox_sub: ?zpui.Subscription = null,
    /// Focus returns to the preview after the lightbox closes.
    refocus_pending: bool = false,

    pub const Events = .{OpenPath};

    pub fn init(files: Entity(client.WorkspaceFiles), path: []const u8, cx: *Context(MarkdownPreview)) !MarkdownPreview {
        const gpa = cx.gpa();
        return .{
            .gpa = gpa,
            .files = files.retain(cx),
            .path = try gpa.dupe(u8, path),
            .anchor_arena = .init(gpa),
            .comments_arena = .init(gpa),
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
        self.block_lines.deinit(self.gpa);
        if (self.comment_draft) |d| d.input.release(app);
        self.comments_arena.deinit();
        self.closeLightbox(app);
        self.dropImages(app);
        self.images.deinit(self.gpa);
        self.fetch_queue.deinit(self.gpa);
        self.local_queue.deinit(self.gpa);
        if (self.checkout_id) |c| self.gpa.free(c);
        self.gpa.free(self.path);
    }

    // ---- media (`load_images`, `media_element`, the lightbox) -------------------------

    const no_connection = "Workspace image connection unavailable";

    /// The checkout engine images are read from (`media_client`).
    pub fn setCheckout(self: *MarkdownPreview, checkout: ?[]const u8, cx: *Context(MarkdownPreview)) void {
        const same = if (self.checkout_id) |c| (if (checkout) |n| std.mem.eql(u8, c, n) else false) else checkout == null;
        if (same) return;
        if (self.checkout_id) |c| self.gpa.free(c);
        self.checkout_id = if (checkout) |c| self.gpa.dupe(u8, c) catch null else null;
        // Sources that failed for want of a checkout retry with it.
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.images.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .failed and std.mem.eql(u8, e.value_ptr.failed, no_connection)) stale.append(self.gpa, e.key_ptr.*) catch {};
        for (stale.items) |k| if (self.images.fetchRemove(k)) |kv| self.gpa.free(kv.key);
        self.loadImages(cx);
    }

    fn releaseMedia(app: *App, m: Media) void {
        if (m == .ready) zmodel.attachments.releaseImage(app, m.ready.image);
    }

    /// Cancel every load and drop every image (`release_media`).
    fn dropImages(self: *MarkdownPreview, app: *App) void {
        self.fetch_timeout.cancel();
        self.fetch_timeout = .none;
        self.decode_task.cancel();
        self.decode_task = .none;
        if (self.decoding) |d| self.gpa.free(d);
        self.decoding = null;
        if (self.fetching) |*f| f.deinit(self.gpa);
        self.fetching = null;
        for (self.fetch_queue.items) |*f| f.deinit(self.gpa);
        self.fetch_queue.clearRetainingCapacity();
        for (self.local_queue.items) |q| {
            self.gpa.free(q.source);
            self.gpa.free(q.file);
        }
        self.local_queue.clearRetainingCapacity();
        var it = self.images.iterator();
        while (it.next()) |e| {
            releaseMedia(app, e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.images.clearRetainingCapacity();
    }

    fn putImage(self: *MarkdownPreview, source: []const u8, m: Media) void {
        if (self.images.getPtr(source)) |v| {
            v.* = m;
            return;
        }
        const k = self.gpa.dupe(u8, source) catch return;
        self.images.put(self.gpa, k, m) catch self.gpa.free(k);
    }

    /// `load_images`: the first 32 distinct sources load (local roots read
    /// the file, engine workspaces stream `ReadWorkspaceImage`); web images
    /// are never fetched; sources no longer referenced release their media.
    fn loadImages(self: *MarkdownPreview, cx: *Context(MarkdownPreview)) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const sources = imageSources(a, self.tree) catch return;
        const allowed = sources[0..@min(sources.len, max_media_entries)];
        var removed: std.ArrayList([]const u8) = .empty;
        var it = self.images.iterator();
        while (it.next()) |e| {
            const keep = for (sources) |src| {
                if (std.mem.eql(u8, src, e.key_ptr.*)) break true;
            } else false;
            if (!keep) removed.append(a, e.key_ptr.*) catch {};
        }
        for (removed.items) |k| if (self.images.fetchRemove(k)) |kv| {
            releaseMedia(cx.app, kv.value);
            self.gpa.free(kv.key);
        };
        const files = self.files.read(cx);
        for (allowed) |src| {
            if (self.images.contains(src)) continue;
            if (std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "http://")) continue;
            const t = if (pathIsOutside(self.path)) null else relativeTarget(a, self.path, src);
            const target = t orelse {
                self.putImage(src, .{ .failed = "Image path is outside the workspace" });
                continue;
            };
            if (files.localRoot()) |root| {
                const file = std.fs.path.join(self.gpa, &.{ root, target.path }) catch continue;
                const owned = self.gpa.dupe(u8, src) catch {
                    self.gpa.free(file);
                    continue;
                };
                self.local_queue.append(self.gpa, .{ .source = owned, .file = file }) catch {
                    self.gpa.free(owned);
                    self.gpa.free(file);
                    continue;
                };
                self.putImage(src, .loading);
            } else if (self.checkout_id != null) {
                const owned = self.gpa.dupe(u8, src) catch continue;
                const path = self.gpa.dupe(u8, target.path) catch {
                    self.gpa.free(owned);
                    continue;
                };
                self.fetch_queue.append(self.gpa, .{ .source = owned, .path = path }) catch {
                    self.gpa.free(owned);
                    self.gpa.free(path);
                    continue;
                };
                self.putImage(src, .loading);
            } else self.putImage(src, .{ .failed = no_connection });
        }
        self.pump(cx);
    }

    /// Start the next load when nothing is in flight.
    fn pump(self: *MarkdownPreview, cx: *Context(MarkdownPreview)) void {
        if (self.decoding != null or self.fetching != null) return;
        if (self.local_queue.items.len > 0) {
            const q = self.local_queue.orderedRemove(0);
            self.decoding = q.source;
            const io = self.files.read(cx).io;
            self.decode_task = cx.spawn(image_preview.LoadJob{ .gpa = self.gpa, .io = io, .file = q.file }, onDecoded) catch {
                self.gpa.free(q.file);
                return self.finishImage(.{ .failed = "Image preview unavailable" }, cx);
            };
            return;
        }
        if (self.fetch_queue.items.len == 0) return;
        const checkout = self.checkout_id orelse return;
        self.fetching = self.fetch_queue.orderedRemove(0);
        self.fetch_timeout.cancel();
        self.fetch_timeout = cx.timer(image_preview.load_timeout_ns, onFetchTimeout) catch .none;
        self.files.read(cx).readImageChunk(cx, self.fetching.?.path, checkout, 0, null, onChunk);
    }

    fn onFetchTimeout(self: *MarkdownPreview, cx: *Context(MarkdownPreview)) void {
        self.fetch_timeout.detach();
        self.fetch_timeout = .none;
        if (self.fetching == null) return;
        self.failFetch("Image preview timed out", cx);
    }

    fn failFetch(self: *MarkdownPreview, msg: []const u8, cx: *Context(MarkdownPreview)) void {
        var f = self.fetching orelse return;
        self.fetching = null;
        self.fetch_timeout.cancel();
        self.fetch_timeout = .none;
        self.putImage(f.source, .{ .failed = msg });
        f.deinit(self.gpa);
        self.list.remeasure();
        cx.notify();
        self.pump(cx);
    }

    /// One `ReadWorkspaceImage` chunk (`read_image`'s identity / size checks).
    fn onChunk(self: *MarkdownPreview, res: client.Result(proto.ImageChunk), cx: *Context(MarkdownPreview)) void {
        defer res.deinit();
        const f = if (self.fetching) |*x| x else return;
        if (res.err) |_| return self.failFetch("Image preview unavailable", cx);
        const chunk = res.value orelse return self.failFetch("Image preview unavailable", cx);
        const checkout = self.checkout_id orelse return self.failFetch(no_connection, cx);
        const b64 = std.base64.standard.Decoder;
        if (!std.mem.eql(u8, chunk.checkoutId, checkout) or chunk.contentHash.len == 0 or
            chunk.size > proto.max_workspace_image_bytes or
            chunk.data.len > (proto.workspace_image_chunk_bytes + 2) / 3 * 4 or
            (f.content_hash != null and !std.mem.eql(u8, f.content_hash.?, chunk.contentHash)) or
            (f.mime != null and !std.mem.eql(u8, f.mime.?, chunk.mimeType)) or
            (f.size != null and f.size.? != chunk.size))
            return self.failFetch("Image identity or size changed", cx);
        const n = b64.calcSizeForSlice(chunk.data) catch return self.failFetch("Invalid image chunk offset", cx);
        const start = f.bytes.items.len;
        f.bytes.resize(self.gpa, start + n) catch return self.failFetch("Image exceeds preview memory limit", cx);
        b64.decode(f.bytes.items[start..], chunk.data) catch return self.failFetch("Invalid image chunk offset", cx);
        if (n == 0 or f.offset + n != chunk.nextOffset or chunk.nextOffset > chunk.size or chunk.done != (chunk.nextOffset == chunk.size))
            return self.failFetch("Invalid image chunk offset", cx);
        if (chunk.done) {
            const bytes = f.bytes.toOwnedSlice(self.gpa) catch return self.failFetch("Image exceeds preview memory limit", cx);
            var done = self.fetching.?;
            self.fetching = null;
            self.fetch_timeout.cancel();
            self.fetch_timeout = .none;
            self.decoding = self.gpa.dupe(u8, done.source) catch null;
            done.deinit(self.gpa);
            if (self.decoding == null) {
                self.gpa.free(bytes);
                return self.pump(cx);
            }
            self.decode_task = cx.spawn(image_preview.LoadJob{ .gpa = self.gpa, .io = self.files.read(cx).io, .bytes = bytes }, onDecoded) catch
                return self.finishImage(.{ .failed = "Image preview unavailable" }, cx);
            return;
        }
        if (f.offset == 0) {
            f.content_hash = self.gpa.dupe(u8, chunk.contentHash) catch null;
            f.mime = self.gpa.dupe(u8, chunk.mimeType) catch null;
            f.size = chunk.size;
        }
        f.offset = chunk.nextOffset;
        if (f.bytes.items.len > proto.max_workspace_image_bytes) return self.failFetch("Image chunk limit exceeded", cx);
        self.files.read(cx).readImageChunk(cx, f.path, checkout, f.offset, f.content_hash, onChunk);
    }

    /// Settle the image being decoded and start the next load.
    fn finishImage(self: *MarkdownPreview, m: Media, cx: *Context(MarkdownPreview)) void {
        const source = self.decoding orelse {
            releaseMedia(cx.app, m);
            return;
        };
        self.decoding = null;
        defer self.gpa.free(source);
        if (self.images.contains(source)) self.putImage(source, m) else releaseMedia(cx.app, m);
        self.list.remeasure();
        cx.notify();
        self.pump(cx);
    }

    /// Decoded off-thread (`admit_media`: 64 MB across the document).
    fn onDecoded(self: *MarkdownPreview, res: image_preview.Loaded, cx: *Context(MarkdownPreview)) void {
        self.decode_task = .none;
        var r = res;
        if (r.err) |e| return self.finishImage(.{ .failed = e }, cx);
        const decoded = r.decoded orelse return self.finishImage(.{ .failed = "Image preview unavailable" }, cx);
        r.decoded = null;
        var bytes: usize = 0;
        for (decoded.frames) |fr| bytes += fr.pixels.len;
        var used: usize = 0;
        var it = self.images.valueIterator();
        while (it.next()) |v| if (v.* == .ready) {
            used += v.ready.bytes;
        };
        if (used +| bytes > max_media_bytes) {
            var d = decoded;
            d.deinit(self.gpa);
            return self.finishImage(.{ .failed = "Document media preview memory limit reached" }, cx);
        }
        const img = RenderImage.create(self.gpa, decoded) catch {
            var d = decoded;
            d.deinit(self.gpa);
            return self.finishImage(.{ .failed = "Image exceeds preview memory limit" }, cx);
        };
        const sz = img.size(0);
        const scale = if (img.scale_factor > 0) img.scale_factor else 1;
        self.finishImage(.{ .ready = .{
            .image = img,
            .width = @max(@as(f32, @floatFromInt(sz.width)) / scale, 1),
            .height = @max(@as(f32, @floatFromInt(sz.height)) / scale, 1),
            .bytes = bytes,
        } }, cx);
    }

    fn closeLightbox(self: *MarkdownPreview, app: *App) void {
        if (self.lightbox_sub) |*sub| sub.deinit();
        self.lightbox_sub = null;
        if (self.lightbox) |lb| lb.release(app);
        self.lightbox = null;
    }

    fn onLightboxClosed(self: *MarkdownPreview, _: Entity(media.Lightbox), _: *const media.LightboxClosed, cx: *Context(MarkdownPreview)) void {
        self.closeLightbox(cx.app);
        self.refocus_pending = true;
        cx.notify();
    }

    /// `media_element` click: the image enlarged in the shared lightbox.
    fn onImageClick(self: *MarkdownPreview, key: u64, _: *const zpui.ClickEvent, window: *Window, cx: *Context(MarkdownPreview)) void {
        cx.stopPropagation();
        var it = self.images.iterator();
        const found = while (it.next()) |e| {
            if (std.hash.Wyhash.hash(0, e.key_ptr.*) == key) break e;
        } else return;
        const m = found.value_ptr.*;
        if (m != .ready) return;
        self.closeLightbox(cx.app);
        const theme = ui.theme.get(cx);
        // The lightbox retains the image; its release drops that reference.
        const lb = cx.newWith(media.Lightbox, media.Lightbox.init, .{ media.LightboxOptions{
            .image = m.ready.image,
            .name = baseName(found.key_ptr.*),
            .natural = .{ .width = m.ready.width, .height = m.ready.height },
            .release = zmodel.attachments.releaseImage,
            .appearance = theme.appearance,
        }, window }) catch return;
        self.lightbox = lb;
        self.lightbox_sub = cx.subscribe(lb, onLightboxClosed) catch null;
        cx.notify();
    }

    fn baseName(source: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, source, "/");
        return if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
    }

    /// "Open image link": the image's link through the preview's routing.
    fn onImageLink(self: *MarkdownPreview, key: u64, _: *const zpui.ClickEvent, window: *Window, cx: *Context(MarkdownPreview)) void {
        cx.stopPropagation();
        const target = self.linkFor(key) orelse return;
        if (!self.routeLink(target, cx)) md.rich_text.openLink(target, window, cx.app);
    }

    /// An external image's fallback text opens its source.
    fn onImageSource(self: *MarkdownPreview, key: u64, _: *const zpui.ClickEvent, window: *Window, cx: *Context(MarkdownPreview)) void {
        cx.stopPropagation();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        for (imageSources(scratch.allocator(), self.tree) catch return) |src| {
            if (std.hash.Wyhash.hash(1, src) == key) {
                if (!self.routeLink(src, cx)) md.rich_text.openLink(src, window, cx.app);
                return;
            }
        }
    }

    /// The link of the image whose (source, link) hashes to `key`.
    fn linkFor(self: *MarkdownPreview, key: u64) ?[]const u8 {
        for (self.tree.blocks) |top| if (findLink(top.block, key)) |l| return l;
        return null;
    }

    fn linkInRuns(runs: []const InlineRun, key: u64) ?[]const u8 {
        for (runs) |r| if (r.style.image) |img| if (img.link) |l| {
            if (linkKey(img.source, l) == key) return l;
        };
        return null;
    }

    fn findLink(b: Block, key: u64) ?[]const u8 {
        switch (b) {
            .paragraph => |r| return linkInRuns(r, key),
            .heading => |h| return linkInRuns(h.runs, key),
            .block_quote => |c| for (c) |child| if (findLink(child, key)) |l| return l,
            .list => |l| for (l.items) |item| for (item) |child| if (findLink(child, key)) |x| return x,
            .table => |t| {
                for (t.header) |cell| if (linkInRuns(cell, key)) |l| return l;
                for (t.rows) |row| for (row) |cell| if (linkInRuns(cell, key)) |l| return l;
            },
            else => {},
        }
        return null;
    }

    fn linkKey(source: []const u8, link: []const u8) u64 {
        var h = std.hash.Wyhash.init(2);
        h.update(source);
        h.update(&.{0});
        h.update(link);
        return h.final();
    }

    /// Per-render context for `MediaUi::image`.
    const ImageUiCtx = struct { self: *MarkdownPreview, cx: *Context(MarkdownPreview) };

    /// `MediaUi::image`: a loaded image (click → lightbox, plus "Open image
    /// link"), else `alt — <why>` (external sources open on click).
    fn renderImage(ctx_ptr: *const anyopaque, image: mdm.InlineImage, id_key: u64, theme: *const Theme) ?zpui.AnyElement {
        const ctx: *const ImageUiCtx = @ptrCast(@alignCast(ctx_ptr));
        const self = ctx.self;
        const cx = ctx.cx;
        const state = self.images.get(image.source);
        if (state) |m| if (m == .ready) {
            const r = m.ready;
            const el = div().id(.{ "md-image", id_key }).wFull().maxW(px(r.width)).mxAuto().maxH(px(480))
                .aspectRatio(r.width / r.height).cursorPointer().role(.button).ariaLabel("Enlarge image")
                .onClick(cx.listenerWith(std.hash.Wyhash.hash(0, image.source), onImageClick))
                .child(zpui.img(r.image).sizeFull().objectFit(.contain));
            var col = div().flex().flexCol().gap(px(4)).child(el);
            if (image.link) |l| col = col.child(div().id(.{ "markdown-image-link", id_key }).size(px(editor_view.control_size)).flexNone()
                .rounded(px(6)).flex().itemsCenter().justifyCenter().cursorPointer().role(.button).ariaLabel("Open image link").occlude()
                .hover(zpui.StyleBuilder.init.bg(theme.wash(0.14)))
                .tooltipWith(@as([]const u8, "Open image link"), ui.tooltip.build)
                .onClick(cx.listenerWith(linkKey(image.source, l), onImageLink))
                .child(ui.icon.of(.arrow_up_right, 14, theme.text_muted)));
            return zpui.intoAnyElement(col);
        };
        const external = std.mem.startsWith(u8, image.source, "https://") or std.mem.startsWith(u8, image.source, "http://");
        const allowed = blk: {
            const srcs = imageSources(zpui.window.arena_mod.frameAllocator(), self.tree) catch break :blk true;
            for (srcs[0..@min(srcs.len, max_media_entries)]) |s2| if (std.mem.eql(u8, s2, image.source)) break :blk true;
            break :blk false;
        };
        const why: []const u8 = if (external) image.source else if (state) |m| switch (m) {
            .failed => |e| e,
            else => "Loading image\u{2026}",
        } else if (allowed) "Loading image\u{2026}" else "Document image preview limit reached";
        var text = div().id(.{ "md-image-alt", id_key }).textColor(theme.text_muted).child(zpui.fmt("{s} \u{2014} {s}", .{ image.alt, why }));
        if (external) text = text.cursorPointer().onClick(cx.listenerWith(std.hash.Wyhash.hash(1, image.source), onImageSource));
        return zpui.intoAnyElement(text);
    }

    /// `open_diagram_preview` for the preview's Mermaid fences.
    fn openDiagram(owner: u64, key: u64, window: ?*Window, app: *App) void {
        const win = window orelse return;
        const weak: zpui.WeakEntity(MarkdownPreview) = .{ .id = @enumFromInt(owner) };
        const ent = weak.upgrade(app) orelse return;
        defer ent.release(app);
        const vp = win.viewportSize();
        const e = md.diagrams.get(key) orelse return;
        const img = md.diagrams.enlarged(key, .{ .width = vp.width * 0.9, .height = vp.height * 0.85 }, win.scaleFactor()) orelse return;
        var l = ent.lease(app);
        defer l.end();
        const self = l.value;
        const cx = &l.cx;
        const theme = ui.theme.get(cx);
        self.closeLightbox(app);
        const lb = cx.newWith(media.Lightbox, media.Lightbox.init, .{ media.LightboxOptions{
            .image = img,
            .name = "Mermaid diagram",
            .natural = .{ .width = e.natural.width, .height = e.natural.height },
            .plate = theme.bg.blend(theme.ink(0.035)),
            .release = md.diagrams.releaseImage,
            .appearance = theme.appearance,
        }, win }) catch {
            md.diagrams.releaseImage(app, img);
            return;
        };
        img.release();
        self.lightbox = lb;
        self.lightbox_sub = cx.subscribe(lb, onLightboxClosed) catch null;
        cx.notify();
    }

    /// `set_comments`: the owner's staged comments on this file and its open
    /// draft; rows re-measure when either changes.
    pub fn setComments(self: *MarkdownPreview, owner: zpui.WeakEntity(FileEditor), comments: []const cm.ReviewComment, draft: ?CommentDraft, editable: bool, cx: *Context(MarkdownPreview)) void {
        self.comment_owner = owner;
        var h = std.hash.Wyhash.init(@intFromBool(editable));
        for (comments) |c| {
            h.update(c.id);
            h.update(std.mem.asBytes(&c.line));
            h.update(c.body);
        }
        if (draft) |d| {
            h.update(std.mem.asBytes(&d.line));
            h.update(std.mem.asBytes(&d.input.id));
            h.update(&.{@intFromBool(d.editing)});
        }
        const key = h.final();
        if (key == self.comments_key) return;
        self.comments_key = key;
        self.comments_editable = editable;
        _ = self.comments_arena.reset(.retain_capacity);
        const a = self.comments_arena.allocator();
        const out: []cm.ReviewComment = a.alloc(cm.ReviewComment, comments.len) catch @constCast(&[_]cm.ReviewComment{});
        for (out, comments[0..out.len]) |*o, c| o.* = .{
            .id = a.dupe(u8, c.id) catch "",
            .path = a.dupe(u8, c.path) catch "",
            .line = c.line,
            .body = a.dupe(u8, c.body) catch "",
            .source = .file,
        };
        self.comments = out;
        if (self.comment_draft) |d| d.input.release(cx);
        self.comment_draft = if (draft) |d| .{ .line = d.line, .input = d.input.retain(cx), .editing = d.editing } else null;
        self.list.remeasure();
        cx.notify();
    }

    fn withOwner(self: *MarkdownPreview, cx: *Context(MarkdownPreview)) ?Entity(FileEditor) {
        const w = self.comment_owner orelse return null;
        return w.upgrade(cx.app);
    }

    /// `open_comment` → the editor's `open_markdown_comment`.
    fn openComment(self: *MarkdownPreview, line: u32, window: *Window, cx: *Context(MarkdownPreview)) void {
        if (self.truncated) return;
        const ed = self.withOwner(cx) orelse return;
        defer ed.release(cx);
        ed.update(cx, review.openFromPreview, .{ line, self.parsed_hash, window });
    }

    fn cancelComment(self: *MarkdownPreview, cx: *Context(MarkdownPreview)) void {
        const ed = self.withOwner(cx) orelse return;
        defer ed.release(cx);
        ed.update(cx, review.cancelDraft, .{});
    }

    fn commitComment(self: *MarkdownPreview, cx: *Context(MarkdownPreview)) void {
        const ed = self.withOwner(cx) orelse return;
        defer ed.release(cx);
        ed.update(cx, review.commitDraft, .{});
    }

    fn editComment(self: *MarkdownPreview, id: []const u8, window: *Window, cx: *Context(MarkdownPreview)) void {
        const ed = self.withOwner(cx) orelse return;
        defer ed.release(cx);
        ed.update(cx, review.editComment, .{ id, window });
    }

    fn removeComment(self: *MarkdownPreview, id: []const u8, cx: *Context(MarkdownPreview)) void {
        const ed = self.withOwner(cx) orelse return;
        defer ed.release(cx);
        ed.update(cx, review.removeComment, .{id});
    }

    fn onAdder(self: *MarkdownPreview, line: u32, window: *Window, cx: *Context(MarkdownPreview)) void {
        self.openComment(line, window, cx);
    }

    /// `comment_elements`: block `ix`'s cards, then the draft when it lands there.
    fn commentElements(self: *MarkdownPreview, ix: usize, theme: *const Theme, cx: *Context(MarkdownPreview)) zpui.Div {
        const column: comment_ui.ContentColumn = .{ .max_width = max_preview_content_width, .gutter = 24 };
        var out = div().wFull().flex().flexCol();
        for (self.comments) |*c| {
            if (commentBlock(self.block_lines.items, c.line) != ix) continue;
            out = out.child(comment_ui.card(MarkdownPreview, c, theme, cx, editComment, removeComment, column));
        }
        if (self.comment_draft) |d| if (commentBlock(self.block_lines.items, d.line) == ix) {
            out = out.child(comment_ui.draft(MarkdownPreview, self.path, d.line, d.input, d.editing, theme, cx, cancelComment, commitComment, column));
        };
        return out;
    }

    pub fn setPath(self: *MarkdownPreview, path: []const u8, cx: *Context(MarkdownPreview)) void {
        if (std.mem.eql(u8, path, self.path)) return;
        self.gpa.free(self.path);
        self.path = self.gpa.dupe(u8, path) catch @panic("OOM");
        self.source_key = null;
        // Relative images resolve against the new folder.
        self.dropImages(cx.app);
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
        self.parsed_hash = std.hash.Wyhash.hash(0, source);
        {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            self.block_lines.clearRetainingCapacity();
            if (blockSourceLines(scratch.allocator(), source, tree)) |lines| {
                self.block_lines.appendSlice(self.gpa, lines) catch {};
            } else |_| {}
        }
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
        self.loadImages(cx);
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
        return l.value.routeLink(url, &l.cx);
    }

    /// The preview's link routing; false = a web/mail link for the app handler.
    fn routeLink(self: *MarkdownPreview, url: []const u8, cx: *Context(MarkdownPreview)) bool {
        if (webTarget(url)) return false;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (pathIsOutside(self.path)) return true;
        const t = relativeTarget(arena.allocator(), self.path, url) orelse return true;
        if (std.mem.eql(u8, t.path, self.path)) {
            if (t.anchor) |anc| if (self.anchors.get(anc)) |ix| {
                self.list.scrollTo(.{ .item_ix = ix, .offset_in_item = 0 });
                cx.notify();
            };
            return true;
        }
        self.open_buf.clearRetainingCapacity();
        self.open_buf.appendSlice(self.gpa, t.path) catch return true;
        cx.emit(OpenPath{ .path = self.open_buf.items });
        return true;
    }

    /// `TaskUi::toggle` → the editor's `toggle_markdown_task`.
    fn onTask(owner: u64, marker: mdm.TaskMarker, _: ?*Window, app: *App) void {
        const weak: zpui.WeakEntity(MarkdownPreview) = .{ .id = @enumFromInt(owner) };
        const ent = weak.upgrade(app) orelse return;
        defer ent.release(app);
        const self = ent.read(app);
        if (self.truncated) return;
        const w = self.comment_owner orelse return;
        const ed = w.upgrade(app) orelse return;
        defer ed.release(app);
        ed.update(app, FileEditor.toggleMarkdownTask, .{ self.parsed_hash, marker.range.start, marker.range.end, marker.checked });
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
        const img_ui = a.create(ImageUiCtx) catch @panic("OOM");
        img_ui.* = .{ .self = self, .cx = cx };
        var key = std.hash.Wyhash.init(self.scope);
        key.update(std.mem.asBytes(&ix));
        const row_key = key.final();
        const block = md.renderTopBlock(self.tree, ix, .{
            .theme = theme,
            .key = row_key,
            .copy = true,
            .fit_toggle = true,
            .tasks = .checkbox,
            .images = true,
            .image_resolver = .{ .ctx = img_ctx, .f = resolveImage },
            .diagrams = true,
            .link_owner = .{ .owner = @intFromEnum(cx.entityId()), .f = onLink },
            .image_ui = .{ .ctx = img_ui, .f = renderImage },
            .diagram_open = .{ .owner = @intFromEnum(cx.entityId()), .f = openDiagram },
            .task_toggle = if (self.comment_owner != null and !self.truncated and self.comments_editable) .{ .owner = @intFromEnum(cx.entityId()), .f = onTask } else null,
        }, window);
        // A hovered block offers `+` in its gutter (`render_comment_adder`);
        // the group spans the gutter so moving onto the button keeps it.
        const group = zpui.fmt("md-comment-{d}-{d}", .{ self.scope, ix });
        var column = div().wFull().maxW(px(max_preview_content_width)).minW0().relative();
        const can_comment = self.comment_owner != null and !self.truncated and self.comments_editable and ix < self.block_lines.items.len;
        if (can_comment) column = column.child(div().absolute().left(px(-20)).top(px(3)).opacity(0).groupHover(group, zpui.StyleBuilder.init.opacity(1))
            .child(comment_ui.adder(MarkdownPreview, .{ "md-comment-add", row_key }, theme, cx, self.block_lines.items[ix], onAdder)));
        return zpui.intoAnyElement(div().wFull().flex().flexCol().pb(px(md.block_gap)).group(group)
            .child(div().wFull().flex().justifyCenter().px(px(preview_gutter))
                .child(column.child(block)))
            .child(self.commentElements(ix, theme, cx)));
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
        if (self.lightbox) |lb| root = root.child(lb);
        if (self.refocus_pending) {
            self.refocus_pending = false;
            window.focus(self.focus);
        }
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
    const lines = [_]u32{ 1, 3, 6, 9 };
    try testing.expectEqual(@as(?usize, 1), commentBlock(&lines, 4));
    try testing.expectEqual(@as(?usize, 2), commentBlock(&lines, 7));
    try testing.expectEqual(@as(?usize, 3), commentBlock(&lines, 10));
    try testing.expectEqual(@as(?usize, 3), commentBlock(&lines, 11));
    try testing.expectEqual(@as(?usize, null), commentBlock(&.{}, 1));
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
