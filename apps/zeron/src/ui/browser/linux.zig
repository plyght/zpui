//! Linux browser host: port of zeron `browser/linux/mod.rs`.
//!
//! WebKitGTK renders offscreen in an isolated helper process
//! (`apps/zeron/native/linux-browser/helper.c`, zeron's `helper.c` verbatim). Only
//! rendered pixels and explicit browser commands cross the pipe; zpui owns every
//! visible window and all input routing, so browser content composites (clips,
//! rounds, blurs, overlays) like any other zpui image. No X11 reparenting or Wayland
//! subsurfaces are involved — zeron dropped those for exactly this design, and it works
//! unchanged on X11, Wayland and Xvfb.
//!
//! Protocol (little endian):
//!   to helper:   u32 length + JSON `{"id":N,"cmd":…}` (create, load, reload, back,
//!                forward, resize, visible, move/down/up/scroll, key_down/key_up,
//!                commit/preedit/unmark, text, copy/cut, select-all, dismiss-menu,
//!                option:N, open-link, copy-link, eval, close)
//!   from helper: kind u8 + id u32 + length u32 + payload, kinds
//!                'F' frame (u32 w, u32 h, f32 scale, BGRA pixels), 'S' page state JSON,
//!                'I' input-method state JSON (merged), 'M' menu JSON, 'C' clipboard text,
//!                'N' open in new tab, 'J' eval result.
//!
//! One helper process serves every page of the app (Rust `BrowserData`); a reader
//! thread demultiplexes packets into per-page `Route`s and wakes the page's view.

const std = @import("std");
const linux = std.os.linux;
const zpui = @import("zpui");
const model = @import("model.zig");
const Waker = @import("waker.zig").Waker;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zeron_browser);

pub const helper_name = "zeron-webkit";
const max_packet: usize = 8192 * 8192 * 4 + 12;

/// Locate the helper binary: `ZERON_WEBKIT_HELPER`, next to the executable,
/// `../libexec/zeron/` from it. Caller frees.
pub fn helperPath(gpa: Allocator) ?[]u8 {
    if (std.c.getenv("ZERON_WEBKIT_HELPER")) |p| return gpa.dupe(u8, std.mem.span(p)) catch null;
    var buf: [4096]u8 = undefined;
    const rc = linux.readlink("/proc/self/exe", &buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    const exe = buf[0..rc];
    const dir = std.fs.path.dirname(exe) orelse return null;
    for ([_][]const u8{ helper_name, "../libexec/zeron/" ++ helper_name }) |rel| {
        const path = std.fs.path.join(gpa, &.{ dir, rel }) catch return null;
        const z = gpa.dupeSentinel(u8, path, 0) catch {
            gpa.free(path);
            return null;
        };
        defer gpa.free(z);
        if (linux.errno(linux.access(z, linux.X_OK)) == .SUCCESS) return path;
        gpa.free(path);
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Worker: the helper process + reader thread (shared by every page)
// ---------------------------------------------------------------------------------------

const Frame = struct { width: u32, height: u32, scale: f32, pixels: []u8 };

/// Per-page mailbox written by the reader thread. Guarded by `Worker.lock`.
const Route = struct {
    waker: *Waker,
    state: ?[]u8 = null,
    frame: ?Frame = null,
    /// 'I' packets merged (Rust keeps a JSON object; we keep the fields it reads).
    input_text: ?[]u8 = null,
    input_cursor: usize = 0,
    input_selection: usize = 0,
    input_focused: bool = false,
    caret: [4]f32 = .{ 0, 0, 1, 18 },
    menu: ?[]u8 = null,
    clipboard: ?[]u8 = null,
    new_tabs: std.ArrayList([]u8) = .empty,
    helper_died: bool = false,

    fn deinit(r: *Route, gpa: Allocator) void {
        if (r.state) |s| gpa.free(s);
        if (r.frame) |f| gpa.free(f.pixels);
        if (r.input_text) |t| gpa.free(t);
        if (r.menu) |m| gpa.free(m);
        if (r.clipboard) |c| gpa.free(c);
        for (r.new_tabs.items) |u| gpa.free(u);
        r.new_tabs.deinit(gpa);
        r.waker.release();
    }
};

const Worker = struct {
    gpa: Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_fd: linux.fd_t,
    stdout_fd: linux.fd_t,
    lock: std.Io.Mutex = .init,
    write_lock: std.Io.Mutex = .init,
    routes: std.AutoHashMapUnmanaged(u32, *Route) = .empty,
    next_id: u32 = 1,
    /// Pages using this worker (main thread).
    users: usize = 0,
    dead: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn spawn(gpa: Allocator, io: std.Io) !*Worker {
        const path = helperPath(gpa) orelse return error.HelperNotFound;
        defer gpa.free(path);
        const child = std.process.spawn(io, .{
            .argv = &.{path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch |err| {
            log.warn("could not start {s}: {t}", .{ path, err });
            return error.HelperSpawnFailed;
        };
        const w = try gpa.create(Worker);
        w.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
        };
        w.thread = std.Thread.spawn(.{}, readLoop, .{w}) catch |err| {
            w.child.kill(io);
            gpa.destroy(w);
            return err;
        };
        return w;
    }

    fn destroy(w: *Worker) void {
        // Closing stdin makes the helper quit (gtk_main_quit on EOF); its stdout then
        // closes and the reader thread ends.
        w.child.kill(w.io);
        if (w.thread) |t| t.join();
        var it = w.routes.valueIterator();
        while (it.next()) |r| {
            r.*.deinit(w.gpa);
            w.gpa.destroy(r.*);
        }
        w.routes.deinit(w.gpa);
        w.gpa.destroy(w);
    }

    /// Send one command (`cmd` is a struct; `id` is added). Main thread.
    fn send(w: *Worker, id: u32, cmd: anytype) bool {
        if (w.dead.load(.acquire)) return false;
        const Cmd = @TypeOf(cmd);
        const body = std.json.Stringify.valueAlloc(w.gpa, struct {
            c: Cmd,
            id: u32,
            pub fn jsonStringify(self: @This(), jw: anytype) !void {
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(self.id);
                inline for (@typeInfo(Cmd).@"struct".field_names) |name| {
                    try jw.objectField(name);
                    try jw.write(@field(self.c, name));
                }
                try jw.endObject();
            }
        }{ .c = cmd, .id = id }, .{}) catch return false;
        defer w.gpa.free(body);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(body.len), .little);
        w.write_lock.lockUncancelable(w.io);
        defer w.write_lock.unlock(w.io);
        return writeAll(w.stdin_fd, &len) and writeAll(w.stdin_fd, body);
    }

    fn readLoop(w: *Worker) void {
        const gpa = w.gpa;
        while (true) {
            var header: [9]u8 = undefined;
            if (!readAll(w.stdout_fd, &header)) break;
            const kind = header[0];
            const id = std.mem.readInt(u32, header[1..5], .little);
            const length: usize = std.mem.readInt(u32, header[5..9], .little);
            if (length > max_packet) break;
            const data = gpa.alloc(u8, length) catch break;
            if (!readAll(w.stdout_fd, data)) {
                gpa.free(data);
                break;
            }
            w.deliver(kind, id, data);
        }
        w.dead.store(true, .release);
        w.lock.lockUncancelable(w.io);
        defer w.lock.unlock(w.io);
        var it = w.routes.valueIterator();
        while (it.next()) |r| {
            r.*.helper_died = true;
            r.*.waker.wake();
        }
    }

    /// Reader thread: fold one packet into its route (takes `data`).
    fn deliver(w: *Worker, kind: u8, id: u32, data: []u8) void {
        const gpa = w.gpa;
        var keep = false;
        defer if (!keep) gpa.free(data);
        w.lock.lockUncancelable(w.io);
        defer w.lock.unlock(w.io);
        const r = w.routes.get(id) orelse return;
        switch (kind) {
            'F' => {
                if (data.len < 12) return;
                const width = std.mem.readInt(u32, data[0..4], .little);
                const height = std.mem.readInt(u32, data[4..8], .little);
                const scale: f32 = @bitCast(std.mem.readInt(u32, data[8..12], .little));
                if (!std.math.isFinite(scale) or scale < 0.5 or scale > 4) return;
                if (@as(usize, width) * height * 4 != data.len - 12) return;
                // Pixels stay in place: the 12-byte prefix is dropped by the consumer.
                if (r.frame) |f| gpa.free(f.pixels);
                r.frame = .{ .width = width, .height = height, .scale = scale, .pixels = data };
                keep = true;
            },
            'S' => {
                if (r.state) |s| gpa.free(s);
                r.state = data;
                keep = true;
            },
            'I' => mergeInput(gpa, r, data),
            'M' => {
                if (r.menu) |m| gpa.free(m);
                r.menu = data;
                keep = true;
            },
            'C' => {
                if (r.clipboard) |c| gpa.free(c);
                r.clipboard = data;
                keep = true;
            },
            'N' => {
                r.new_tabs.append(gpa, data) catch return;
                keep = true;
            },
            else => return,
        }
        // At most one latest frame is retained per page; the view coalesces wakes.
        r.waker.wake();
    }

    fn mergeInput(gpa: Allocator, r: *Route, data: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const o = parsed.value.object;
        if (o.get("text")) |v| if (v == .string) {
            if (r.input_text) |t| gpa.free(t);
            r.input_text = gpa.dupe(u8, v.string) catch null;
        };
        if (o.get("cursor")) |v| if (v == .integer) {
            r.input_cursor = @intCast(@max(v.integer, 0));
        };
        if (o.get("selection")) |v| if (v == .integer) {
            r.input_selection = @intCast(@max(v.integer, 0));
        };
        if (o.get("focused")) |v| if (v == .bool) {
            r.input_focused = v.bool;
        };
        if (o.get("caret")) |v| if (v == .array and v.array.items.len == 4) {
            for (v.array.items, 0..) |e, i| r.caret[i] = switch (e) {
                .integer => |n| @floatFromInt(n),
                .float => |f| @floatCast(f),
                else => r.caret[i],
            };
        };
    }
};

fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn readAll(fd: linux.fd_t, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf[off..].ptr, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += rc;
            },
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

var shared_worker: ?*Worker = null;

fn acquireWorker(gpa: Allocator, io: std.Io) !*Worker {
    if (shared_worker) |w| {
        if (!w.dead.load(.acquire)) {
            w.users += 1;
            return w;
        }
        // A dead helper is replaced; pages still holding it keep their (dead) routes.
        if (w.users == 0) w.destroy();
        shared_worker = null;
    }
    const w = try Worker.spawn(gpa, io);
    w.users = 1;
    shared_worker = w;
    return w;
}

fn releaseWorker(w: *Worker) void {
    w.users -= 1;
    if (w.users > 0) return;
    if (shared_worker == w) shared_worker = null;
    w.destroy();
}

// ---------------------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------------------

pub const Menu = struct {
    x: f32 = 0,
    y: f32 = 0,
    items: []Item = &.{},
    active: usize = 0,

    pub const Item = struct { label: []const u8, action: []const u8, enabled: bool, selected: bool };
};

/// One browser page in the shared helper (Rust `NativePage`).
pub const Page = struct {
    gpa: Allocator,
    worker: *Worker,
    route: *Route,
    id: u32,
    /// Where the page is painted (window coordinates) and at which scale.
    bounds: zpui.Bounds(f32) = .{ .origin = .zero, .size = .{ .width = 0, .height = 0 } },
    scale: f32 = 1,
    geometry: ?[3]u32 = null,
    presentation: model.Presentation = .live,
    /// Latest frame (BGRA, straight alpha) as a zpui image, and its scale.
    image: ?*zpui.RenderImage = null,
    image_scale: f32 = 1,
    /// Images replaced since the last paint; their atlas tiles are evicted there.
    stale: std.ArrayList(*zpui.RenderImage) = .empty,
    menu: ?std.json.Parsed(MenuJson) = null,
    menu_active: usize = 0,
    preedit: std.ArrayList(u8) = .empty,
    pressed: ?zpui.input.MouseButton = null,

    pub const MenuJson = struct {
        x: f64 = 0,
        y: f64 = 0,
        items: []const struct { label: []const u8 = "", action: []const u8 = "", enabled: bool = false, selected: bool = false } = &.{},
    };

    /// `waker` is retained by the page.
    pub fn create(gpa: Allocator, io: std.Io, waker: *Waker) !*Page {
        const worker = try acquireWorker(gpa, io);
        errdefer releaseWorker(worker);
        const route = try gpa.create(Route);
        errdefer gpa.destroy(route);
        waker.retain();
        route.* = .{ .waker = waker };
        const id = worker.next_id;
        worker.next_id += 1;
        {
            worker.lock.lockUncancelable(worker.io);
            defer worker.lock.unlock(worker.io);
            worker.routes.put(gpa, id, route) catch |err| {
                waker.release();
                return err;
            };
        }
        const self = try gpa.create(Page);
        self.* = .{ .gpa = gpa, .worker = worker, .route = route, .id = id };
        _ = worker.send(id, .{ .cmd = "create" });
        return self;
    }

    pub fn destroy(self: *Page) void {
        const gpa = self.gpa;
        _ = self.command(.{ .cmd = "close" });
        {
            self.worker.lock.lockUncancelable(self.worker.io);
            defer self.worker.lock.unlock(self.worker.io);
            _ = self.worker.routes.remove(self.id);
        }
        self.route.deinit(gpa);
        gpa.destroy(self.route);
        releaseWorker(self.worker);
        if (self.image) |img| img.release();
        for (self.stale.items) |img| img.release();
        self.stale.deinit(gpa);
        if (self.menu) |m| m.deinit();
        self.preedit.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn command(self: *Page, cmd: anytype) bool {
        return self.worker.send(self.id, cmd);
    }

    pub fn load(self: *Page, url: []const u8) bool {
        return self.command(.{ .cmd = "load", .url = url });
    }
    pub fn reload(self: *Page) void {
        _ = self.command(.{ .cmd = "reload" });
    }
    pub fn history(self: *Page, forward: bool) void {
        _ = self.command(.{ .cmd = if (forward) "forward" else "back" });
    }

    pub fn present(self: *Page, p: model.Presentation) void {
        if ((self.presentation == .hidden) != (p == .hidden))
            _ = self.command(.{ .cmd = "visible", .value = @as(u8, @intFromBool(p != .hidden)) });
        if (p == .hidden and self.menu != null) self.dismissMenu();
        self.presentation = p;
    }

    /// Track where the page paints; resizes the offscreen view when that changes.
    pub fn sync(self: *Page, bounds: zpui.Bounds(f32), scale: f32) void {
        self.bounds = bounds;
        self.scale = scale;
        const geo: [3]u32 = .{
            @intFromFloat(std.math.clamp(@round(bounds.size.width * scale), 1, 8192)),
            @intFromFloat(std.math.clamp(@round(bounds.size.height * scale), 1, 8192)),
            @bitCast(scale),
        };
        if (self.geometry) |g| if (std.mem.eql(u32, &g, &geo)) return;
        _ = self.command(.{ .cmd = "resize", .width = geo[0], .height = geo[1], .scale = scale });
        self.geometry = geo;
    }

    pub const Drained = struct {
        state: ?std.json.Parsed(StateJson) = null,
        new_tabs: std.ArrayList([]u8) = .empty,
        clipboard: ?[]u8 = null,
        menu_changed: bool = false,
        frame_changed: bool = false,
        helper_died: bool = false,

        pub fn deinit(d: *Drained, gpa: Allocator) void {
            if (d.state) |s| s.deinit();
            for (d.new_tabs.items) |u| gpa.free(u);
            d.new_tabs.deinit(gpa);
            if (d.clipboard) |c| gpa.free(c);
        }
    };

    pub const StateJson = struct {
        url: ?[]const u8 = null,
        title: []const u8 = "",
        @"error": ?[]const u8 = null,
        loading: bool = false,
        can_back: bool = false,
        can_forward: bool = false,
    };

    /// Main thread: take everything the reader thread delivered since last time.
    pub fn drain(self: *Page) Drained {
        const gpa = self.gpa;
        var out: Drained = .{};
        var state: ?[]u8 = null;
        var frame: ?Frame = null;
        var menu: ?[]u8 = null;
        {
            self.worker.lock.lockUncancelable(self.worker.io);
            defer self.worker.lock.unlock(self.worker.io);
            const r = self.route;
            state = r.state;
            r.state = null;
            frame = r.frame;
            r.frame = null;
            menu = r.menu;
            r.menu = null;
            out.clipboard = r.clipboard;
            r.clipboard = null;
            out.new_tabs = r.new_tabs;
            r.new_tabs = .empty;
            out.helper_died = r.helper_died;
        }
        if (state) |s| {
            defer gpa.free(s);
            out.state = std.json.parseFromSlice(StateJson, gpa, s, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
        }
        if (frame) |f| {
            out.frame_changed = true;
            self.installFrame(f) catch gpa.free(f.pixels);
        }
        if (menu) |m| {
            defer gpa.free(m);
            if (std.json.parseFromSlice(MenuJson, gpa, m, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed| {
                if (self.presentation == .live) {
                    if (self.menu) |old| old.deinit();
                    self.menu_active = 0;
                    for (parsed.value.items, 0..) |item, i| if (item.selected) {
                        self.menu_active = i;
                        break;
                    };
                    self.menu = parsed;
                    out.menu_changed = true;
                } else {
                    parsed.deinit();
                    _ = self.command(.{ .cmd = "dismiss-menu" });
                }
            } else |_| {}
        }
        return out;
    }

    /// Turn the packet into a RenderImage in place (drop the 12-byte header).
    fn installFrame(self: *Page, f: Frame) !void {
        const gpa = self.gpa;
        const n = @as(usize, f.width) * f.height * 4;
        std.mem.copyForwards(u8, f.pixels[0..n], f.pixels[12 .. 12 + n]);
        const pixels = gpa.realloc(f.pixels, n) catch f.pixels[0..n];
        const frames = try gpa.alloc(zpui.image.Frame, 1);
        frames[0] = .{ .width = f.width, .height = f.height, .pixels = pixels };
        const img = zpui.RenderImage.create(gpa, .{ .frames = frames, .scale_factor = f.scale }) catch |err| {
            gpa.free(frames);
            return err;
        };
        if (self.image) |old| self.stale.append(gpa, old) catch old.release();
        self.image = img;
        self.image_scale = f.scale;
    }

    /// Paint phase: evict replaced frames' atlas tiles (Rust `window.drop_image`).
    pub fn evictStale(self: *Page, window: *zpui.Window) void {
        for (self.stale.items) |img| {
            window.sprite_atlas.evictImage(img.id, @intCast(img.frameCount()));
            img.release();
        }
        self.stale.clearRetainingCapacity();
    }

    // ---- input forwarding (Rust `linux_pointer` / `linux_key`) ------------------------

    pub fn pointer(self: *Page, kind: []const u8, position: zpui.Point(f32), button: ?zpui.input.MouseButton, mods: zpui.input.Modifiers) void {
        if (self.presentation != .live) return;
        if (std.mem.eql(u8, kind, "down")) self.pressed = button;
        if (std.mem.eql(u8, kind, "up")) {
            const was = self.pressed;
            self.pressed = null;
            if (!std.meta.eql(was, button)) return;
        }
        const x = position.x - self.bounds.origin.x;
        const y = position.y - self.bounds.origin.y;
        var m = modifiersMask(mods);
        if (std.mem.eql(u8, kind, "move")) if (button) |b| {
            m |= @as(u32, 1) << @intCast(mouseButton(b) + 7);
        };
        _ = self.command(.{ .cmd = kind, .x = x, .y = y, .button = if (button) |b| mouseButton(b) else 0, .mods = m });
    }

    pub fn scroll(self: *Page, position: zpui.Point(f32), dx: f32, dy: f32, mods: zpui.input.Modifiers) void {
        _ = self.command(.{
            .cmd = "scroll",
            .x = position.x - self.bounds.origin.x,
            .y = position.y - self.bounds.origin.y,
            .dx = -dx / 40,
            .dy = -dy / 40,
            .mods = modifiersMask(mods),
        });
    }

    pub fn key(self: *Page, keystroke: zpui.input.Keystroke, down: bool) void {
        const ch = keystroke.key_char orelse "";
        const printable = ch.len > 0 and std.unicode.utf8CountCodepoints(ch) catch 0 == 1 and ch[0] >= 0x20 and ch[0] != 0x7f and
            !keystroke.modifiers.control and !keystroke.modifiers.platform;
        const k = if (printable) ch else gdkKeyName(keystroke.key);
        _ = self.command(.{ .cmd = if (down) "key_down" else "key_up", .key = k, .text = ch, .mods = modifiersMask(keystroke.modifiers) });
    }

    pub fn dismissMenu(self: *Page) void {
        if (self.menu) |m| m.deinit();
        self.menu = null;
        _ = self.command(.{ .cmd = "dismiss-menu" });
    }

    // ---- IME state (Rust `EntityInputHandler for BrowserSurface`) --------------------

    pub fn inputFocused(self: *Page) bool {
        self.worker.lock.lockUncancelable(self.worker.io);
        defer self.worker.lock.unlock(self.worker.io);
        return self.route.input_focused;
    }

    pub fn caretBounds(self: *Page) zpui.Bounds(f32) {
        self.worker.lock.lockUncancelable(self.worker.io);
        defer self.worker.lock.unlock(self.worker.io);
        const c = self.route.caret;
        return .{
            .origin = .{ .x = self.bounds.origin.x + c[0] / self.scale, .y = self.bounds.origin.y + c[1] / self.scale },
            .size = .{ .width = c[2] / self.scale, .height = c[3] / self.scale },
        };
    }
};

pub fn modifiersMask(m: zpui.input.Modifiers) u32 {
    return @as(u32, @intFromBool(m.shift)) | (@as(u32, @intFromBool(m.control)) << 2) |
        (@as(u32, @intFromBool(m.alt)) << 3) | (@as(u32, @intFromBool(m.platform)) << 26);
}

fn mouseButton(b: zpui.input.MouseButton) u32 {
    return switch (b) {
        .left => 1,
        .middle => 2,
        .right => 3,
        .back => 8,
        .forward => 9,
    };
}

fn gdkKeyName(k: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "enter", "Return" },    .{ "backspace", "BackSpace" }, .{ "delete", "Delete" },
        .{ "escape", "Escape" },   .{ "tab", "Tab" },             .{ "left", "Left" },
        .{ "right", "Right" },     .{ "up", "Up" },               .{ "down", "Down" },
        .{ "home", "Home" },       .{ "end", "End" },             .{ "pageup", "Page_Up" },
        .{ "pagedown", "Page_Down" }, .{ "space", "space" },
    };
    for (map) |e| if (std.mem.eql(u8, e[0], k)) return e[1];
    return k;
}

test "modifier masks and key names match zeron" {
    try std.testing.expectEqual(@as(u32, 1 | 4), modifiersMask(.{ .shift = true, .control = true }));
    try std.testing.expectEqualStrings("Return", gdkKeyName("enter"));
    try std.testing.expectEqualStrings("a", gdkKeyName("a"));
}
