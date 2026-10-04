//! A read-only workspace image — port of zeron `files/image_preview.rs`.
//!
//! Engine workspaces read the bytes on the owning device through
//! `ReadWorkspaceImage` (chunked, identity- and size-checked like
//! `WorkspaceFilesClient::read_image`); local roots read the file directly.
//! Decoding runs off the UI thread; the image shows fitted (never upscaled)
//! in the shared viewer geometry: ⌘/Ctrl-wheel zooms about the cursor, the
//! wheel and a drag pan. A deleted file or an oversized image says so.
//!
//! ```zig
//! const v = try cx.newWith(ImagePreview, ImagePreview.init, .{ files, "assets/logo.png", checkout_id });
//! div().child(v)                 // fills its parent
//! v.update(cx, ImagePreview.deleted, .{});
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const md = @import("zeron_ui_markdown");
const client = @import("client.zig");
const proto = @import("protocol.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const RenderImage = zpui.RenderImage;
const div = zpui.div;
const px = zpui.px;
const image = zpui.image;
const viewer = md.media.viewer;

/// Decoded pixels a preview may hold (`MAX_MEDIA_BYTES`).
pub const max_media_bytes: usize = 64 * 1024 * 1024;
/// `image_preview.rs` gives up after 30s.
pub const load_timeout_ns: u64 = 30 * std.time.ns_per_s;

/// `is_image`: the formats the preview decodes.
pub fn isImage(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub const Loaded = struct {
    decoded: ?image.DecodedImage = null,
    err: ?[]const u8 = null,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        if (self.decoded) |*d| d.deinit(gpa);
        self.decoded = null;
    }
};

/// Background: read (local) and/or decode the bytes.
pub const LoadJob = struct {
    gpa: Allocator,
    io: std.Io,
    /// Local: the absolute file to read.
    file: ?[]u8 = null,
    /// Engine: the assembled bytes.
    bytes: ?[]u8 = null,

    pub fn run(self: *LoadJob) Loaded {
        const bytes = self.bytes orelse blk: {
            const file = self.file orelse return .{ .err = "Image preview unavailable" };
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, file, self.gpa, .limited(proto.max_workspace_image_bytes)) catch |e| return .{ .err = switch (e) {
                error.StreamTooLong => "Image exceeds preview memory limit",
                error.FileNotFound => "This image was removed from the workspace.",
                else => "Image preview unavailable",
            } };
            self.bytes = data;
            break :blk data;
        };
        var decoded = image.decode(self.gpa, bytes, .{ .animate = false }) catch return .{ .err = "This image could not be decoded." };
        var total: usize = 0;
        for (decoded.frames) |f| total += f.pixels.len;
        if (total > max_media_bytes) {
            decoded.deinit(self.gpa);
            return .{ .err = "Image exceeds preview memory limit" };
        }
        return .{ .decoded = decoded };
    }

    pub fn discard(self: *LoadJob, r: Loaded) void {
        var l = r;
        l.deinit(self.gpa);
    }

    pub fn deinit(self: *LoadJob) void {
        if (self.file) |f| self.gpa.free(f);
        if (self.bytes) |b| self.gpa.free(b);
        self.file = null;
        self.bytes = null;
    }
};

pub const ImagePreview = struct {
    gpa: Allocator,
    files: Entity(client.WorkspaceFiles),
    path: []u8,
    checkout_id: ?[]u8,
    generation: u64 = 0,
    task: Task(Loaded) = .none,
    timeout: Task(void) = .none,
    image: ?*RenderImage = null,
    natural: viewer.Size = .{},
    err: ?[]const u8 = null,
    state: viewer.ViewState = .{},
    focus: zpui.FocusHandle,
    // Engine chunk assembly (`read_image`).
    bytes: std.ArrayList(u8) = .empty,
    offset: u64 = 0,
    content_hash: ?[]u8 = null,
    mime: ?[]u8 = null,
    size: ?u64 = null,

    pub fn init(files: Entity(client.WorkspaceFiles), path: []const u8, checkout_id: ?[]const u8, cx: *Context(ImagePreview)) !ImagePreview {
        const gpa = cx.gpa();
        var self: ImagePreview = .{
            .gpa = gpa,
            .files = files.retain(cx),
            .path = try gpa.dupe(u8, path),
            .checkout_id = if (checkout_id) |c| try gpa.dupe(u8, c) else null,
            .focus = cx.focusHandle(),
        };
        self.reload(cx);
        return self;
    }

    pub fn deinit(self: *ImagePreview, app: *App) void {
        self.cancel(app);
        self.files.release(app);
        self.focus.release(app);
        self.gpa.free(self.path);
        if (self.checkout_id) |c| self.gpa.free(c);
        self.bytes.deinit(self.gpa);
    }

    fn resetChunks(self: *ImagePreview) void {
        self.bytes.clearRetainingCapacity();
        self.offset = 0;
        if (self.content_hash) |h| self.gpa.free(h);
        if (self.mime) |m| self.gpa.free(m);
        self.content_hash = null;
        self.mime = null;
        self.size = null;
    }

    /// `suspend`: drop the load in flight and the image.
    fn cancel(self: *ImagePreview, app: *App) void {
        self.generation +%= 1;
        self.task.cancel();
        self.task = .none;
        self.timeout.cancel();
        self.timeout = .none;
        self.resetChunks();
        if (self.image) |img| @import("zeron_model").attachments.releaseImage(app, img);
        self.image = null;
    }

    pub fn reload(self: *ImagePreview, cx: *Context(ImagePreview)) void {
        self.cancel(cx.app);
        self.err = null;
        self.state = .{};
        const files = self.files.read(cx);
        if (files.localRoot()) |root| {
            const file = std.fs.path.join(self.gpa, &.{ root, self.path }) catch return;
            self.task = cx.spawn(LoadJob{ .gpa = self.gpa, .io = files.io, .file = file }, onLoaded) catch .none;
        } else {
            const checkout = self.checkout_id orelse {
                self.err = "Workspace checkout identity unavailable";
                return cx.notify();
            };
            files.readImageChunk(cx, self.path, checkout, 0, null, onChunk);
        }
        self.timeout = cx.timer(load_timeout_ns, onTimeout) catch .none;
        cx.notify();
    }

    /// The file moved: follow it.
    pub fn setPath(self: *ImagePreview, path: []const u8, cx: *Context(ImagePreview)) void {
        if (std.mem.eql(u8, path, self.path)) return;
        self.gpa.free(self.path);
        self.path = self.gpa.dupe(u8, path) catch @panic("OOM");
        self.reload(cx);
    }

    /// `deleted`: the image left the workspace.
    pub fn deleted(self: *ImagePreview, cx: *Context(ImagePreview)) void {
        self.cancel(cx.app);
        self.err = "This image was removed from the workspace.";
        cx.notify();
    }

    fn onTimeout(self: *ImagePreview, cx: *Context(ImagePreview)) void {
        self.timeout = .none;
        if (self.image != null or self.err != null) return;
        self.cancel(cx.app);
        self.err = "Image preview timed out";
        cx.notify();
    }

    fn fail(self: *ImagePreview, msg: []const u8, cx: *Context(ImagePreview)) void {
        self.cancel(cx.app);
        self.err = msg;
        cx.notify();
    }

    /// One `ReadWorkspaceImage` chunk (`read_image`'s validation).
    fn onChunk(self: *ImagePreview, res: client.Result(proto.ImageChunk), cx: *Context(ImagePreview)) void {
        defer res.deinit();
        if (self.err != null or self.image != null) return;
        if (res.err) |_| return self.fail("Image preview unavailable", cx);
        const chunk = res.value orelse return self.fail("Image preview unavailable", cx);
        const checkout = self.checkout_id orelse return;
        const b64 = std.base64.standard.Decoder;
        if (!std.mem.eql(u8, chunk.checkoutId, checkout) or chunk.contentHash.len == 0 or
            chunk.size > proto.max_workspace_image_bytes or
            chunk.data.len > (proto.workspace_image_chunk_bytes + 2) / 3 * 4 or
            (self.content_hash != null and !std.mem.eql(u8, self.content_hash.?, chunk.contentHash)) or
            (self.mime != null and !std.mem.eql(u8, self.mime.?, chunk.mimeType)) or
            (self.size != null and self.size.? != chunk.size))
            return self.fail("Image identity or size changed", cx);
        const n = b64.calcSizeForSlice(chunk.data) catch return self.fail("Invalid image chunk offset", cx);
        const start = self.bytes.items.len;
        self.bytes.resize(self.gpa, start + n) catch return self.fail("Image exceeds preview memory limit", cx);
        b64.decode(self.bytes.items[start..], chunk.data) catch return self.fail("Invalid image chunk offset", cx);
        if (n == 0 or self.offset + n != chunk.nextOffset or chunk.nextOffset > chunk.size or chunk.done != (chunk.nextOffset == chunk.size))
            return self.fail("Invalid image chunk offset", cx);
        if (chunk.done) {
            const bytes = self.bytes.toOwnedSlice(self.gpa) catch return self.fail("Image exceeds preview memory limit", cx);
            self.resetChunks();
            self.task = cx.spawn(LoadJob{ .gpa = self.gpa, .io = self.files.read(cx).io, .bytes = bytes }, onLoaded) catch .none;
            return;
        }
        if (self.offset == 0) {
            self.content_hash = self.gpa.dupe(u8, chunk.contentHash) catch null;
            self.mime = self.gpa.dupe(u8, chunk.mimeType) catch null;
            self.size = chunk.size;
        }
        self.offset = chunk.nextOffset;
        if (self.bytes.items.len > proto.max_workspace_image_bytes) return self.fail("Image chunk limit exceeded", cx);
        self.files.read(cx).readImageChunk(cx, self.path, checkout, self.offset, self.content_hash, onChunk);
    }

    fn onLoaded(self: *ImagePreview, res: Loaded, cx: *Context(ImagePreview)) void {
        self.task = .none;
        self.timeout.cancel();
        self.timeout = .none;
        var r = res;
        if (r.err) |e| {
            self.err = e;
            return cx.notify();
        }
        const decoded = r.decoded orelse return;
        r.decoded = null;
        const img = RenderImage.create(self.gpa, decoded) catch {
            var d = decoded;
            d.deinit(self.gpa);
            self.err = "Image exceeds preview memory limit";
            return cx.notify();
        };
        self.image = img;
        const s = img.size(0);
        const scale = if (img.scale_factor > 0) img.scale_factor else 1;
        self.natural = .{ .width = @max(@as(f32, @floatFromInt(s.width)) / scale, 1), .height = @max(@as(f32, @floatFromInt(s.height)) / scale, 1) };
        self.state = .{};
        cx.notify();
    }

    // ---- viewer input (image_viewer.rs) -------------------------------------------------

    fn onWheel(self: *ImagePreview, ev: *const zpui.input.ScrollWheelEvent, window: *Window, cx: *Context(ImagePreview)) void {
        if (self.state.wheel(ev)) {
            cx.stopPropagation();
            window.preventDefault();
            cx.notify();
        }
    }

    fn onDown(self: *ImagePreview, ev: *const zpui.input.MouseDownEvent, window: *Window, _: *Context(ImagePreview)) void {
        self.state.pointerDown(ev.position);
        window.focus(self.focus);
    }

    fn onMove(self: *ImagePreview, ev: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(ImagePreview)) void {
        if (self.state.pointerMove(ev)) cx.notify();
    }

    fn onUp(self: *ImagePreview, _: *const zpui.input.MouseUpEvent, _: *Window, _: *Context(ImagePreview)) void {
        self.state.drag = null;
    }

    const Measure = struct { id: zpui.EntityId };

    /// Records the viewport (origin for pointer math, size for the fit).
    fn paintMeasure(m: Measure, bounds: zpui.Bounds(f32), _: *Window, app: *App) void {
        const weak: zpui.WeakEntity(ImagePreview) = .{ .id = m.id };
        const e = weak.upgrade(app) orelse return;
        defer e.release(app);
        var l = e.lease(app);
        defer l.end();
        const s = &l.value.state;
        s.origin = .{ .x = bounds.origin.x, .y = bounds.origin.y };
        const vp: viewer.Size = .{ .width = @max(bounds.size.width, 1), .height = @max(bounds.size.height, 1) };
        if (vp.width != s.geometry.viewport.width or vp.height != s.geometry.viewport.height) {
            s.geometry.resize(l.value.natural, vp);
            l.cx.notify();
        }
    }

    pub fn render(self: *ImagePreview, _: *Window, cx: *Context(ImagePreview)) zpui.AnyElement {
        const theme = md.rich_text.card_theme orelse zt.Theme.forSelection(&zt.registry.builtin, .{ .appearance = .dark, .variant_id = "zeron-dark" });
        var root = div().id("file-image-preview").trackFocus(self.focus).sizeFull().minW0().minH0().relative().overflowHidden()
            .flex().itemsCenter().justifyCenter();
        if (self.image) |img| {
            const g = self.state.geometry;
            const o = g.imageOrigin();
            root = root
                .onScrollWheel(cx.listener(onWheel))
                .onMouseDown(.left, cx.listener(onDown))
                .onMouseMove(cx.listener(onMove))
                .onMouseUp(.left, cx.listener(onUp))
                .child(zpui.img(img).absolute().left(px(o.x)).top(px(o.y))
                .w(px(self.natural.width * g.scale)).h(px(self.natural.height * g.scale)).objectFit(.contain));
        } else {
            root = root.child(div().px(px(16)).textSize(px(12)).textColor(theme.text_muted)
                .child(self.err orelse "Loading image\u{2026}"));
        }
        return zpui.intoAnyElement(root.child(zpui.canvas(Measure{ .id = cx.entityId() }, paintMeasure).absolute().inset0()));
    }
};

test "recognizes only supported workspace formats" {
    for ([_][]const u8{ "a.PNG", "a.jpeg", "a.JPG", "a.gif", "a.webp", "a.svg", "a.bmp", "a.tif", "a.tiff" }) |p| try std.testing.expect(isImage(p));
    for ([_][]const u8{ "a.rs", "a.md", "a", "a.png.txt", "a.avif" }) |p| try std.testing.expect(!isImage(p));
}
