//! Native X11 pieces of the Appshot backend (zeron `appshots/linux/x11.rs`, x11rb):
//! the passive global hotkey grab, `_NET_ACTIVE_WINDOW` capture through `GetImage`
//! (decoded with the window visual's channel masks), window identity for AT-SPI
//! matching (`_NET_WM_PID` + exact title, unique in `_NET_CLIENT_LIST`), titles /
//! `WM_CLASS`, `_NET_WM_ICON`, and the `.desktop` entry lookup for names and icons.
//! Every function opens its own libxcb connection (worker threads only).

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const c = @import("linux_c");
const platform = @import("../platform.zig");
const common = @import("../capture_common.zig");
const encode = @import("../../image/encode.zig");

const ATOM_WINDOW: u32 = 33;
const ATOM_CARDINAL: u32 = 6;
const ATOM_STRING: u32 = 31;
const ATOM_WM_NAME: u32 = 39;
const ATOM_WM_CLASS: u32 = 67;
const KEY_PRESS: u8 = 2;

// ModMask bits.
const MOD_SHIFT: u16 = 1;
const MOD_LOCK: u16 = 2;
const MOD_CONTROL: u16 = 4;
const MOD_1: u16 = 8;
const MOD_2: u16 = 16;
const MOD_4: u16 = 64;
const MOD_ANY: u16 = 0x8000;

pub const XConn = struct {
    conn: *c.xcb_connection_t,
    root: u32,

    pub fn open() ?XConn {
        var screen_ix: c_int = 0;
        const conn = c.xcb_connect(null, &screen_ix) orelse return null;
        if (c.xcb_connection_has_error(conn) != 0) {
            c.xcb_disconnect(conn);
            return null;
        }
        var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
        var i: c_int = 0;
        while (i < screen_ix and it.rem > 0) : (i += 1) c.xcb_screen_next(&it);
        if (it.rem == 0) {
            c.xcb_disconnect(conn);
            return null;
        }
        return .{ .conn = conn, .root = it.data.*.root };
    }

    pub fn close(self: XConn) void {
        c.xcb_disconnect(self.conn);
    }

    pub fn atom(self: XConn, name: []const u8) ?u32 {
        const reply = c.xcb_intern_atom_reply(self.conn, c.xcb_intern_atom(self.conn, 0, @intCast(name.len), name.ptr), null) orelse return null;
        defer std.c.free(reply);
        return reply.*.atom;
    }

    /// The raw property value, or null when the request failed.
    fn property(self: XConn, gpa: Allocator, window: u32, prop: u32, prop_type: u32) ?struct { format: u8, bytes: []u8 } {
        const reply = c.xcb_get_property_reply(self.conn, c.xcb_get_property(self.conn, 0, window, prop, prop_type, 0, std.math.maxInt(u32) / 4), null) orelse return null;
        defer std.c.free(reply);
        const len: usize = @intCast(c.xcb_get_property_value_length(reply));
        const ptr: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply) orelse return .{ .format = reply.*.format, .bytes = gpa.alloc(u8, 0) catch return null });
        return .{ .format = reply.*.format, .bytes = gpa.dupe(u8, ptr[0..len]) catch return null };
    }

    /// `property_u32`: a format-32 property (null on failure or another format).
    pub fn propertyU32(self: XConn, gpa: Allocator, window: u32, prop: u32, prop_type: u32) ?[]u32 {
        const p = self.property(gpa, window, prop, prop_type) orelse return null;
        defer gpa.free(p.bytes);
        if (p.format != 32) return null;
        const n = p.bytes.len / 4;
        const out = gpa.alloc(u32, n) catch return null;
        for (0..n) |i| out[i] = std.mem.readInt(u32, p.bytes[i * 4 ..][0..4], .little);
        return out;
    }

    fn firstU32(self: XConn, gpa: Allocator, window: u32, prop: u32, prop_type: u32) ?u32 {
        const vals = self.propertyU32(gpa, window, prop, prop_type) orelse return null;
        defer gpa.free(vals);
        return if (vals.len > 0) vals[0] else null;
    }

    pub fn activeWindow(self: XConn, gpa: Allocator) ?u32 {
        const a = self.atom("_NET_ACTIVE_WINDOW") orelse return null;
        return self.firstU32(gpa, self.root, a, ATOM_WINDOW);
    }

    pub fn windowPid(self: XConn, gpa: Allocator, window: u32) ?u32 {
        const a = self.atom("_NET_WM_PID") orelse return null;
        return self.firstU32(gpa, window, a, ATOM_CARDINAL);
    }

    /// `window_title`: `_NET_WM_NAME` (UTF8_STRING); `WM_NAME` only when that request
    /// itself fails (Rust's `or_else` on the request, not on an empty value).
    pub fn windowTitle(self: XConn, gpa: Allocator, window: u32) ?[]u8 {
        const utf8 = self.atom("UTF8_STRING") orelse return null;
        const net_name = self.atom("_NET_WM_NAME") orelse return null;
        const p = self.property(gpa, window, net_name, utf8) orelse self.property(gpa, window, ATOM_WM_NAME, ATOM_STRING) orelse return null;
        if (!std.unicode.utf8ValidateSlice(p.bytes) or std.mem.trim(u8, p.bytes, " \t\r\n").len == 0) {
            gpa.free(p.bytes);
            return null;
        }
        return p.bytes;
    }

    /// `window_class`: the last non-empty `WM_CLASS` part (the class name).
    pub fn windowClass(self: XConn, gpa: Allocator, window: u32) ?[]u8 {
        const p = self.property(gpa, window, ATOM_WM_CLASS, ATOM_STRING) orelse return null;
        defer gpa.free(p.bytes);
        var last: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, p.bytes, 0);
        while (it.next()) |part| {
            if (!std.unicode.utf8ValidateSlice(part) or std.mem.trim(u8, part, " \t\r\n").len == 0) continue;
            last = part;
        }
        return gpa.dupe(u8, last orelse return null) catch null;
    }

    /// `window_belongs_to_viewer`.
    pub fn belongsToSelf(self: XConn, gpa: Allocator, window: u32) bool {
        return (self.windowPid(gpa, window) orelse return false) == @as(u32, @intCast(linux.getpid()));
    }

    /// `property_icon`: the `_NET_WM_ICON` image closest to 64×64, as PNG.
    pub fn iconPng(self: XConn, gpa: Allocator, window: u32) ?[]u8 {
        const a = self.atom("_NET_WM_ICON") orelse return null;
        const values = self.propertyU32(gpa, window, a, ATOM_CARDINAL) orelse return null;
        defer gpa.free(values);
        return iconFromValues(gpa, values);
    }
};

pub fn iconFromValues(gpa: Allocator, values: []const u32) ?[]u8 {
    var best: ?struct { score: usize, w: usize, h: usize, px: []const u32 } = null;
    var offset: usize = 0;
    while (offset + 2 <= values.len) {
        const w: usize = values[offset];
        const h: usize = values[offset + 1];
        offset += 2;
        const len = std.math.mul(usize, w, h) catch return null;
        if (w > 512 or h > 512 or len > 512 * 512) {
            offset = std.math.add(usize, offset, len) catch return null;
            continue;
        }
        if (w > 0 and h > 0 and offset + len <= values.len) {
            const score = (if (w > 64) w - 64 else 64 - w) + (if (h > 64) h - 64 else 64 - h);
            if (best == null or score < best.?.score) best = .{ .score = score, .w = w, .h = h, .px = values[offset .. offset + len] };
        }
        offset +|= len;
    }
    const b = best orelse return null;
    const rgba = gpa.alloc(u8, b.w * b.h * 4) catch return null;
    defer gpa.free(rgba);
    for (b.px, 0..) |argb, i| {
        rgba[i * 4 + 0] = @truncate(argb >> 16);
        rgba[i * 4 + 1] = @truncate(argb >> 8);
        rgba[i * 4 + 2] = @truncate(argb);
        rgba[i * 4 + 3] = @truncate(argb >> 24);
    }
    return encode.encodePng(gpa, rgba, @intCast(b.w), @intCast(b.h), .rgba) catch null;
}

// ---------------------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------------------

pub const Identity = struct {
    window: u32,
    pid: u32,
    title: []u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.window == b.window and a.pid == b.pid and std.mem.eql(u8, a.title, b.title);
    }
};

/// `read_identity`: pid + exact title, unique among `_NET_CLIENT_LIST`.
pub fn readIdentity(x: XConn, gpa: Allocator, active: u32) ?Identity {
    const pid = x.windowPid(gpa, active) orelse return null;
    const title = x.windowTitle(gpa, active) orelse return null;
    const clients_atom = x.atom("_NET_CLIENT_LIST") orelse {
        gpa.free(title);
        return null;
    };
    const clients = x.propertyU32(gpa, x.root, clients_atom, ATOM_WINDOW) orelse {
        gpa.free(title);
        return null;
    };
    defer gpa.free(clients);
    var matches: usize = 0;
    var only_active = true;
    for (clients) |w| {
        if ((x.windowPid(gpa, w) orelse continue) != pid) continue;
        const t = x.windowTitle(gpa, w) orelse continue;
        defer gpa.free(t);
        if (!std.mem.eql(u8, t, title)) continue;
        matches += 1;
        if (w != active) only_active = false;
    }
    if (pid == 0 or matches != 1 or !only_active) {
        gpa.free(title);
        return null;
    }
    return .{ .window = active, .pid = pid, .title = title };
}

pub fn currentIdentity(gpa: Allocator) ?Identity {
    const x = XConn.open() orelse return null;
    defer x.close();
    const active = x.activeWindow(gpa) orelse return null;
    return readIdentity(x, gpa, active);
}

/// `viewer_is_active`: the window manager's active window belongs to this process.
pub fn viewerIsActive(gpa: Allocator) bool {
    const x = XConn.open() orelse return false;
    defer x.close();
    const active = x.activeWindow(gpa) orelse return false;
    return x.belongsToSelf(gpa, active);
}

pub const Native = struct {
    identity: ?Identity,
    png: []u8,
    title: ?[]u8,
    wm_class: ?[]u8,
    desktop: ?DesktopEntry,
    icon_png: ?[]u8,

    pub fn deinit(self: *Native, gpa: Allocator) void {
        if (self.identity) |i| gpa.free(i.title);
        gpa.free(self.png);
        if (self.title) |t| gpa.free(t);
        if (self.wm_class) |t| gpa.free(t);
        if (self.desktop) |*d| d.deinit(gpa);
        if (self.icon_png) |p| gpa.free(p);
    }
};

pub const NativeResult = union(enum) { ok: Native, err: platform.WindowCaptureResult };

fn failedX(gpa: Allocator, what: []const u8) NativeResult {
    return .{ .err = common.failed(gpa, "X11 Appshot capture failed: {s}", .{what}) };
}

/// `capture_native`: grab the active window's pixels and metadata.
pub fn captureNative(gpa: Allocator, home: ?[]const u8) NativeResult {
    const x = XConn.open() orelse return failedX(gpa, "cannot connect to the X server");
    defer x.close();
    const active_atom = x.atom("_NET_ACTIVE_WINDOW") orelse return failedX(gpa, "cannot intern _NET_ACTIVE_WINDOW");
    const active = x.firstU32(gpa, x.root, active_atom, ATOM_WINDOW) orelse return .{ .err = .{ .err = .no_eligible_window } };
    if (x.belongsToSelf(gpa, active)) return .{ .err = .{ .err = .self_capture } };
    var identity = readIdentity(x, gpa, active);
    errdefer if (identity) |i| gpa.free(i.title);
    const geo = c.xcb_get_geometry_reply(x.conn, c.xcb_get_geometry(x.conn, active), null) orelse {
        if (identity) |i| gpa.free(i.title);
        return failedX(gpa, "GetGeometry failed");
    };
    const width: u16 = geo.*.width;
    const height: u16 = geo.*.height;
    std.c.free(geo);
    if (width == 0 or height == 0) {
        if (identity) |i| gpa.free(i.title);
        return .{ .err = .{ .err = .no_eligible_window } };
    }
    const rgba_len = switch (common.validateDimensions(width, height)) {
        .ok => |n| n,
        .err => |e| {
            if (identity) |i| gpa.free(i.title);
            return .{ .err = common.failedDims(gpa, e) };
        },
    };
    const png = grabImage(x, gpa, active, width, height, rgba_len) catch |e| {
        if (identity) |i| gpa.free(i.title);
        return switch (e) {
            error.UnknownVisual => .{ .err = common.failed(gpa, "X11 returned an unknown visual.", .{}) },
            error.InvalidBuffer => .{ .err = common.failed(gpa, "X11 returned an invalid pixel buffer.", .{}) },
            error.EncodeFailed => .{ .err = common.failed(gpa, "X11 Appshot encoding failed.", .{}) },
            else => failedX(gpa, @errorName(e)),
        };
    };
    const still = x.firstU32(gpa, x.root, active_atom, ATOM_WINDOW);
    if (still == null or still.? != active) {
        gpa.free(png);
        if (identity) |i| gpa.free(i.title);
        return .{ .err = common.failed(gpa, "The active X11 window changed during capture; try again.", .{}) };
    }
    const title = x.windowTitle(gpa, active);
    const wm_class = x.windowClass(gpa, active);
    const desktop = if (wm_class) |cls| findDesktopEntry(gpa, cls, home) else null;
    var icon = x.iconPng(gpa, active);
    if (icon == null) if (desktop) |d| if (d.icon) |name| {
        icon = loadThemeIcon(gpa, name, home);
    };
    const out: Native = .{ .identity = identity, .png = png, .title = title, .wm_class = wm_class, .desktop = desktop, .icon_png = icon };
    identity = null;
    return .{ .ok = out };
}

const ImageError = error{ UnknownVisual, InvalidBuffer, EncodeFailed, GetImageFailed, OutOfMemory };

fn grabImage(x: XConn, gpa: Allocator, window: u32, width: u16, height: u16, rgba_len: usize) ImageError![]u8 {
    const reply = c.xcb_get_image_reply(x.conn, c.xcb_get_image(x.conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, window, 0, 0, width, height, std.math.maxInt(u32)), null) orelse return error.GetImageFailed;
    defer std.c.free(reply);
    const setup = c.xcb_get_setup(x.conn);
    const visual = findVisual(setup, reply.*.visual) orelse return error.UnknownVisual;
    if (visual._class != c.XCB_VISUAL_CLASS_TRUE_COLOR and visual._class != c.XCB_VISUAL_CLASS_DIRECT_COLOR) return error.UnknownVisual;
    const fmt = pixmapFormat(setup, reply.*.depth) orelse return error.InvalidBuffer;
    const data_len: usize = @intCast(c.xcb_get_image_data_length(reply));
    const data_ptr: [*]const u8 = @ptrCast(c.xcb_get_image_data(reply) orelse return error.InvalidBuffer);
    const layout: Layout = .{
        .red = Channel.fromMask(visual.red_mask) orelse return error.UnknownVisual,
        .green = Channel.fromMask(visual.green_mask) orelse return error.UnknownVisual,
        .blue = Channel.fromMask(visual.blue_mask) orelse return error.UnknownVisual,
    };
    const rgba = try gpa.alloc(u8, rgba_len);
    defer gpa.free(rgba);
    try decodeImage(data_ptr[0..data_len], width, height, fmt.bpp, fmt.pad, setup.*.image_byte_order == c.XCB_IMAGE_ORDER_MSB_FIRST, layout, rgba);
    const png = encode.encodePng(gpa, rgba, width, height, .rgba) catch return error.EncodeFailed;
    if (png.len > common.max_attachment_bytes) {
        gpa.free(png);
        return error.EncodeFailed;
    }
    return png;
}

fn findVisual(setup: *const c.xcb_setup_t, id: u32) ?c.xcb_visualtype_t {
    var screens = c.xcb_setup_roots_iterator(setup);
    while (screens.rem > 0) : (c.xcb_screen_next(&screens)) {
        var depths = c.xcb_screen_allowed_depths_iterator(screens.data);
        while (depths.rem > 0) : (c.xcb_depth_next(&depths)) {
            var visuals = c.xcb_depth_visuals_iterator(depths.data);
            while (visuals.rem > 0) : (c.xcb_visualtype_next(&visuals)) {
                if (visuals.data.*.visual_id == id) return visuals.data.*;
            }
        }
    }
    return null;
}

fn pixmapFormat(setup: *const c.xcb_setup_t, depth: u8) ?struct { bpp: u8, pad: u8 } {
    const formats = c.xcb_setup_pixmap_formats(setup);
    const n: usize = @intCast(c.xcb_setup_pixmap_formats_length(setup));
    for (formats[0..n]) |f| if (f.depth == depth) return .{ .bpp = f.bits_per_pixel, .pad = f.scanline_pad };
    return null;
}

/// x11rb `ColorComponent`: a channel of `width` bits at `shift`, expanded to 16 bits
/// by bit replication.
pub const Channel = struct {
    width: u5,
    shift: u5,

    pub fn fromMask(mask: u32) ?Channel {
        if (mask == 0) return null;
        const shift: u5 = @intCast(@ctz(mask));
        const width_raw = @popCount(mask);
        if (width_raw > 16) return null;
        if ((mask >> shift) != (@as(u32, 1) << @intCast(width_raw)) - 1) return null;
        return .{ .width = @intCast(width_raw), .shift = shift };
    }

    pub fn decode(self: Channel, pixel: u32) u16 {
        const mask: u32 = ((@as(u32, 1) << self.width) - 1);
        var value: u32 = (pixel >> self.shift) & mask;
        var width: u32 = self.width;
        value <<= @intCast(16 - width);
        while (width < 16) {
            value |= value >> @intCast(width);
            width <<= 1;
        }
        return @truncate(value);
    }
};

pub const Layout = struct { red: Channel, green: Channel, blue: Channel };

/// Decode a ZPixmap image into opaque RGBA (`capture_native`'s pixel loop).
pub fn decodeImage(data: []const u8, width: u16, height: u16, bpp: u8, pad: u8, msb_first: bool, layout: Layout, rgba: []u8) ImageError!void {
    if (bpp != 8 and bpp != 16 and bpp != 24 and bpp != 32) return error.InvalidBuffer;
    const pad_bits: usize = if (pad == 0) 8 else pad;
    const stride = ((@as(usize, width) * bpp + pad_bits - 1) / pad_bits) * pad_bits / 8;
    if (data.len < stride * height or rgba.len != @as(usize, width) * height * 4) return error.InvalidBuffer;
    const bytes_pp: usize = bpp / 8;
    for (0..height) |y| {
        const row = data[y * stride ..];
        for (0..width) |xi| {
            const p = row[xi * bytes_pp ..][0..bytes_pp];
            var pixel: u32 = 0;
            for (0..bytes_pp) |k| {
                const b: u32 = p[if (msb_first) k else bytes_pp - 1 - k];
                pixel = (pixel << 8) | b;
            }
            const o = (y * @as(usize, width) + xi) * 4;
            rgba[o] = @truncate(layout.red.decode(pixel) >> 8);
            rgba[o + 1] = @truncate(layout.green.decode(pixel) >> 8);
            rgba[o + 2] = @truncate(layout.blue.decode(pixel) >> 8);
            rgba[o + 3] = 255;
        }
    }
}

// ---------------------------------------------------------------------------------------
// Desktop entries
// ---------------------------------------------------------------------------------------

pub const DesktopEntry = struct {
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    icon: ?[]u8 = null,

    pub fn deinit(self: *DesktopEntry, gpa: Allocator) void {
        if (self.id) |s| gpa.free(s);
        if (self.name) |s| gpa.free(s);
        if (self.icon) |s| gpa.free(s);
    }
};

/// `desktop_fields`: `Name` / `Icon` / `StartupWMClass` of the `[Desktop Entry]` group
/// (first occurrence wins when read back).
pub fn desktopField(contents: []const u8, key: []const u8) ?[]const u8 {
    var in_entry = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "[")) {
            in_entry = std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], key)) return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

fn desktopDirs(buf: *[3][]const u8, home_buf: []u8, home: ?[]const u8) [][]const u8 {
    var n: usize = 0;
    if (home) |h| if (std.fmt.bufPrint(home_buf, "{s}/.local/share/applications", .{h})) |p| {
        buf[n] = p;
        n += 1;
    } else |_| {};
    buf[n] = "/usr/share/applications";
    buf[n + 1] = "/usr/local/share/applications";
    return buf[0 .. n + 2];
}

fn readSmallFile(gpa: Allocator, file_path: []const u8, limit: usize) ?[]u8 {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (file_path.len >= path_z.len) return null;
    @memcpy(path_z[0..file_path.len], file_path);
    path_z[file_path.len] = 0;
    const rc = linux.open(@ptrCast(&path_z), .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) {
            out.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        if (out.items.len + n > limit) {
            out.deinit(gpa);
            return null;
        }
        out.appendSlice(gpa, chunk[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// `find_desktop_entry`: the first `.desktop` file (by directory order) whose stem or
/// `StartupWMClass` matches `wm_class` (ASCII case-insensitive); otherwise an id of
/// `linux-x11:<lowercase class>`.
pub fn findDesktopEntry(gpa: Allocator, wm_class: []const u8, home: ?[]const u8) ?DesktopEntry {
    var dirs_buf: [3][]const u8 = undefined;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (desktopDirs(&dirs_buf, &home_buf, home)) |dir| {
        if (findInDir(gpa, dir, wm_class)) |e| return e;
    }
    const lower = std.ascii.allocLowerString(gpa, wm_class) catch return null;
    defer gpa.free(lower);
    return .{ .id = std.fmt.allocPrint(gpa, "linux-x11:{s}", .{lower}) catch null };
}

fn findInDir(gpa: Allocator, dir: []const u8, wm_class: []const u8) ?DesktopEntry {
    var dir_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= dir_z.len) return null;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    const rc = linux.open(@ptrCast(&dir_z), .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return null;
        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            off += ent.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (!std.mem.endsWith(u8, name, ".desktop") or name.len == ".desktop".len) continue;
            const stem = name[0 .. name.len - ".desktop".len];
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
            const contents = readSmallFile(gpa, full, 1 << 20) orelse continue;
            defer gpa.free(contents);
            if (!std.unicode.utf8ValidateSlice(contents)) continue;
            const file_matches = std.ascii.eqlIgnoreCase(stem, wm_class);
            const class_matches = if (desktopField(contents, "StartupWMClass")) |v| std.ascii.eqlIgnoreCase(v, wm_class) else false;
            if (!file_matches and !class_matches) continue;
            return .{
                .id = gpa.dupe(u8, name) catch null,
                .name = if (desktopField(contents, "Name")) |v| gpa.dupe(u8, v) catch null else null,
                .icon = if (desktopField(contents, "Icon")) |v| gpa.dupe(u8, v) catch null else null,
            };
        }
    }
}

/// `load_theme_icon`: an absolute path, else PNGs in the usual hicolor / pixmaps dirs.
pub fn loadThemeIcon(gpa: Allocator, name: []const u8, home: ?[]const u8) ?[]u8 {
    if (std.mem.startsWith(u8, name, "/")) return readSmallFile(gpa, name, 8 << 20);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (home) |h| if (std.fmt.bufPrint(&buf, "{s}/.local/share/icons/hicolor/64x64/apps/{s}.png", .{ h, name })) |p| {
        if (readSmallFile(gpa, p, 8 << 20)) |b| return b;
    } else |_| {};
    const dirs = [_][]const u8{ "/usr/share/pixmaps", "/usr/share/icons/hicolor/64x64/apps", "/usr/share/icons/hicolor/128x128/apps" };
    for (dirs) |d| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ d, name }) catch continue;
        if (readSmallFile(gpa, p, 8 << 20)) |b| return b;
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Global hotkey (passive key grab on the root window)
// ---------------------------------------------------------------------------------------

pub const Grab = struct {
    x: XConn,
    keycode: ?u8 = null,

    pub fn open() ?Grab {
        return .{ .x = XConn.open() orelse return null };
    }

    pub fn close(self: *Grab) void {
        self.ungrab();
        self.x.close();
    }

    pub fn fd(self: *const Grab) linux.fd_t {
        return c.xcb_get_file_descriptor(self.x.conn);
    }

    pub fn ungrab(self: *Grab) void {
        if (self.keycode) |k| {
            _ = c.xcb_ungrab_key(self.x.conn, k, self.x.root, MOD_ANY);
            _ = c.xcb_flush(self.x.conn);
        }
        self.keycode = null;
    }

    /// `register_shortcut`: grab `hotkey` with Lock / NumLock variants. False when the
    /// key is not on the keyboard or another client holds the chord.
    pub fn grab(self: *Grab, hotkey: platform.GlobalHotkey) bool {
        self.ungrab();
        const keysym = common.x11Keysym(hotkey.key) orelse return false;
        const keycode = self.keycodeFor(keysym) orelse return false;
        var base: u16 = 0;
        if (hotkey.control) base |= MOD_CONTROL;
        if (hotkey.alt) base |= MOD_1;
        if (hotkey.shift) base |= MOD_SHIFT;
        if (hotkey.platform) base |= MOD_4;
        for ([_]u16{ base, base | MOD_LOCK, base | MOD_2, base | MOD_LOCK | MOD_2 }) |mods| {
            const cookie = c.xcb_grab_key_checked(self.x.conn, 0, self.x.root, mods, keycode, c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC);
            if (c.xcb_request_check(self.x.conn, cookie)) |err| {
                std.c.free(err);
                // A partial registration must not keep consuming the chord.
                _ = c.xcb_ungrab_key(self.x.conn, keycode, self.x.root, MOD_ANY);
                _ = c.xcb_flush(self.x.conn);
                return false;
            }
        }
        _ = c.xcb_flush(self.x.conn);
        self.keycode = keycode;
        return true;
    }

    fn keycodeFor(self: *Grab, keysym: u32) ?u8 {
        const setup = c.xcb_get_setup(self.x.conn);
        const min: u8 = setup.*.min_keycode;
        const count: u8 = setup.*.max_keycode -| min +| 1;
        const reply = c.xcb_get_keyboard_mapping_reply(self.x.conn, c.xcb_get_keyboard_mapping(self.x.conn, min, count), null) orelse return null;
        defer std.c.free(reply);
        const per: usize = reply.*.keysyms_per_keycode;
        if (per == 0) return null;
        const syms: [*]const u32 = @ptrCast(c.xcb_get_keyboard_mapping_keysyms(reply));
        const n: usize = @intCast(c.xcb_get_keyboard_mapping_keysyms_length(reply));
        var i: usize = 0;
        while (i + per <= n) : (i += per) {
            for (syms[i .. i + per]) |s| if (s == keysym) return min +| @as(u8, @intCast(i / per));
        }
        return null;
    }

    /// Drain pending events; returns how many presses of the grabbed key arrived.
    pub fn drain(self: *Grab) usize {
        var presses: usize = 0;
        while (c.xcb_poll_for_event(self.x.conn)) |ev| {
            defer std.c.free(ev);
            if ((ev.*.response_type & 0x7f) == KEY_PRESS) {
                const kp: *const c.xcb_key_press_event_t = @ptrCast(ev);
                if (self.keycode != null and kp.detail == self.keycode.?) presses += 1;
            }
        }
        return presses;
    }

    pub fn broken(self: *const Grab) bool {
        return c.xcb_connection_has_error(self.x.conn) != 0;
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "channel masks decode with x11rb bit replication" {
    const r = Channel.fromMask(0xff0000).?;
    try testing.expectEqual(@as(u16, 0xabab), r.decode(0xab1234));
    const g5 = Channel.fromMask(0x07e0).?; // 6-bit green of RGB565
    try testing.expectEqual(@as(u16, 0xffff), g5.decode(0x07e0));
    try testing.expectEqual(@as(?Channel, null), Channel.fromMask(0));
    try testing.expectEqual(@as(?Channel, null), Channel.fromMask(0b1010));
}

test "ZPixmap decode honours stride, byte order and channel layout" {
    const layout: Layout = .{ .red = Channel.fromMask(0xff0000).?, .green = Channel.fromMask(0xff00).?, .blue = Channel.fromMask(0xff).? };
    // 2×2, 32 bpp, LSB first (BGRX in memory).
    const data = [_]u8{ 0x30, 0x20, 0x10, 0, 0x60, 0x50, 0x40, 0, 0x90, 0x80, 0x70, 0, 0xc0, 0xb0, 0xa0, 0 };
    var out: [16]u8 = undefined;
    try decodeImage(&data, 2, 2, 32, 32, false, layout, &out);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 255, 0x40, 0x50, 0x60, 255, 0x70, 0x80, 0x90, 255, 0xa0, 0xb0, 0xc0, 255 }, &out);
    // 24 bpp rows padded to 32 bits.
    const d24 = [_]u8{ 3, 2, 1, 0 };
    var o1: [4]u8 = undefined;
    try decodeImage(&d24, 1, 1, 24, 32, false, layout, &o1);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &o1);
    try testing.expectError(error.InvalidBuffer, decodeImage(d24[0..2], 1, 1, 24, 32, false, layout, &o1));
}

test "_NET_WM_ICON picks the size closest to 64 and skips oversized entries" {
    const gpa = testing.allocator;
    var values: std.ArrayList(u32) = .empty;
    defer values.deinit(gpa);
    try values.appendSlice(gpa, &.{ 600, 1 }); // skipped (too wide), its 600 pixels follow
    try values.appendNTimes(gpa, 0, 600);
    try values.appendSlice(gpa, &.{ 2, 2, 0xff112233, 0xff112233, 0xff112233, 0xff112233 });
    try values.appendSlice(gpa, &.{ 1, 1, 0x80aabbcc });
    const png = iconFromValues(gpa, values.items).?;
    defer gpa.free(png);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
}

test "desktop entry fields come from the [Desktop Entry] group only" {
    const contents = "[Desktop Entry]\nName=Text Editor\nIcon=org.gnome.TextEditor\nStartupWMClass=gnome-text-editor\n[Desktop Action new]\nName=New Window\n";
    try testing.expectEqualStrings("Text Editor", desktopField(contents, "Name").?);
    try testing.expectEqualStrings("gnome-text-editor", desktopField(contents, "StartupWMClass").?);
    try testing.expectEqual(@as(?[]const u8, null), desktopField("[Other]\nName=x\n", "Name"));
}
