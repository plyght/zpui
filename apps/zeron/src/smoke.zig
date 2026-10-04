//! Real-app smoke test (CI): `zeron --smoke-frames N` (or `ZERON_SMOKE_FRAMES=N`).
//!
//! After the main window has presented N frames, captures it and exits:
//!   macOS: the on-screen window via `CGWindowListCreateImage` (compositor
//!          output, the same path `examples/mac_window.zig` uses in CI);
//!   Linux: the window's rectangle of the X11 root via ImageMagick
//!          `import -window root … ppm:-` (CI runs under Xvfb; needs X11).
//! and writes `zig-out/zeron-<os>.png` (`zig-out/zeron-<os>-light.png` for the
//! light appearance; `ZERON_SMOKE_OUT=<path>` overrides). Exit status 0 on
//! success, 1 after a `FAIL: <reason>` line when frames never arrive within
//! the watchdog timeout, the capture fails, or the image is blank (one flat
//! color = nothing rendered).
//!
//! `ZERON_SMOKE_BROWSER_URL=<http(s) url>` (needs a selected chat, e.g. fixture mode):
//! after the N frames, open a Browser tab in the right pane on that URL, wait until
//! the page reports loaded (FAIL on a load error or after ~20 s), let it paint, then
//! capture as above. Exercises the native web view (WKWebView child view on macOS,
//! the WebKitGTK helper's offscreen frames on Linux).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");

const App = zpui.App;
const Window = zpui.Window;

pub const Options = struct {
    frames: u64,
    light: bool,
    /// Output path override (else `zig-out/zeron-<os>[-light].png`).
    out: ?[]const u8 = null,
    /// Watchdog: fail if the capture has not happened by then.
    timeout_s: i64 = 90,
    /// Open a Browser tab on this URL before capturing (ZERON_SMOKE_BROWSER_URL).
    browser_url: ?[]const u8 = null,
};

const shell_mod = @import("ui/shell/shell.zig");
const right_pane_mod = @import("ui/shell/right_pane.zig");
const browser = @import("ui/browser/root.zig");

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    done: std.atomic.Value(bool) = .init(false),
    exit_code: u8 = 0,
};

var state: ?State = null;

/// Arm the smoke test for `win` (call once, right after opening the window).
pub fn start(gpa: std.mem.Allocator, io: std.Io, win: *Window, opts: Options) void {
    state = .{ .gpa = gpa, .io = io, .opts = opts };
    std.debug.print("zeron smoke: rendering {d} frames, then capturing (watchdog {d}s)\n", .{ opts.frames, opts.timeout_s });
    if (std.Thread.spawn(.{}, watchdog, .{ io, opts.timeout_s, opts.frames })) |t| t.detach() else |err|
        std.debug.print("WARN: smoke watchdog thread: {t}\n", .{err});
    win.onNextFrame(Tick{ .left = opts.frames }, Tick.tick);
}

/// Exit code for `main` after `App.run` returns (0 when the smoke test is off).
pub fn exitCode() u8 {
    const s = &(state orelse return 0);
    if (!s.done.load(.acquire)) {
        std.debug.print("FAIL: zeron smoke: the app quit before {d} frames were rendered\n", .{s.opts.frames});
        return 1;
    }
    return s.exit_code;
}

var frames_seen: std.atomic.Value(u64) = .init(0);

const Tick = struct {
    left: u64,
    fn tick(self: *const Tick, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        if (self.left > 0) return win.onNextFrame(Tick{ .left = self.left - 1 }, tick);
        const s = &state.?;
        if (s.opts.browser_url) |url| return openBrowser(s, win, app, url);
        finish(s, win, app);
    }

    fn finish(s: *State, win: *Window, app: *App) void {
        s.exit_code = if (capture(s, win)) 0 else |err| blk: {
            std.debug.print("FAIL: zeron smoke: {t}\n", .{err});
            break :blk 1;
        };
        s.done.store(true, .release);
        app.quit();
    }
};

/// Browser smoke: open the tab, then poll every frame until the page loaded.
fn openBrowser(s: *State, win: *Window, app: *App, url: []const u8) void {
    const root = win.root orelse return failNow(s, app, "no root view");
    const shell = root.entity.downcast(shell_mod.Shell) orelse return failNow(s, app, "root view is not the shell");
    const rp = shell.read(app).right_pane;
    std.debug.print("zeron smoke: opening a Browser tab on {s}\n", .{url});
    const pane = rp.update(app, right_pane_mod.RightPane.addBrowser, .{ url, win }) orelse
        return failNow(s, app, "could not open a Browser tab (no selected chat?)");
    _ = pane;
    win.onNextFrame(BrowserWait{ .left = 1200, .settle = 30 }, BrowserWait.tick);
}

const BrowserWait = struct {
    left: u64,
    settle: u64,
    loaded: bool = false,
    fn tick(self: *const BrowserWait, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        const s = &state.?;
        if (browser.pane.smoke_failed.load(.acquire)) return failNow(s, app, "the browser page failed to load");
        var next = self.*;
        if (!next.loaded and browser.pane.smoke_loaded.load(.acquire)) {
            next.loaded = true;
            std.debug.print("zeron smoke: browser page loaded\n", .{});
        }
        if (next.loaded) {
            if (next.settle == 0) return Tick.finish(s, win, app);
            next.settle -= 1;
        } else {
            if (next.left == 0) return failNow(s, app, "the browser page did not finish loading in time");
            next.left -= 1;
        }
        win.refresh(); // keep frames coming while the page paints
        win.onNextFrame(next, tick);
    }
};

fn failNow(s: *State, app: *App, reason: []const u8) void {
    std.debug.print("FAIL: zeron smoke: {s}\n", .{reason});
    s.exit_code = 1;
    s.done.store(true, .release);
    app.quit();
}

fn watchdog(io: std.Io, timeout_s: i64, frames: u64) void {
    io.sleep(.fromSeconds(timeout_s), .awake) catch return;
    if (state) |*s| if (s.done.load(.acquire)) return;
    std.debug.print(
        \\FAIL: zeron smoke: only {d}/{d} frames presented within {d}s.
        \\      The window never got (enough) frames: no GPU/display (macOS: Metal device,
        \\      GUI session; Linux: DISPLAY + Vulkan ICD, e.g. VK_ICD_FILENAMES=lvp_icd.json).
        \\
    , .{ frames_seen.load(.monotonic), frames, timeout_s });
    std.process.exit(1);
}

const os_name = switch (builtin.os.tag) {
    .macos => "macos",
    .linux => "linux",
    else => @tagName(builtin.os.tag),
};

fn capture(s: *State, win: *Window) !void {
    const gpa = s.gpa;
    const img = switch (builtin.os.tag) {
        .macos => try captureMac(gpa, win.platform_window),
        .linux => try captureX11(gpa, s.io, win.platform_window),
        else => return error.CaptureUnsupportedOnThisOs,
    };
    defer gpa.free(img.pixels);

    var buf: [64]u8 = undefined;
    const path = s.opts.out orelse
        try std.fmt.bufPrint(&buf, "zig-out/zeron-{s}{s}.png", .{ os_name, if (s.opts.light) "-light" else "" });
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
    const encoded = try encodePng(gpa, img.width, img.height, img.pixels);
    defer gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = encoded });
    std.debug.print("zeron smoke: wrote {s} ({d}x{d})\n", .{ path, img.width, img.height });

    const st = stats(img.pixels);
    std.debug.print("zeron smoke: {d:.2}% of pixels differ from the corner color, {d} distinct colors (quantized)\n", .{ st.differing * 100, st.distinct });
    if (st.differing < 0.01 or st.distinct < 8) return error.BlankFrame;
}

const Image = struct { width: u32, height: u32, pixels: []u8 };

const Stats = struct { differing: f64, distinct: usize };

/// Fraction of pixels that differ from pixel 0 (by > 8 in any channel) and the
/// number of distinct colors after quantizing to 4 bits per channel.
fn stats(rgba: []const u8) Stats {
    const n = rgba.len / 4;
    if (n == 0) return .{ .differing = 0, .distinct = 0 };
    var seen: std.StaticBitSet(1 << 16) = .empty;
    var differing: usize = 0;
    const ref = rgba[0..4];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = rgba[i * 4 ..][0..4];
        var diff = false;
        for (p, ref) |a, b| diff = diff or @abs(@as(i16, a) - @as(i16, b)) > 8;
        if (diff) differing += 1;
        const key = (@as(u16, p[0] >> 4) << 12) | (@as(u16, p[1] >> 4) << 8) | (@as(u16, p[2] >> 4) << 4) | (p[3] >> 4);
        seen.set(key);
    }
    return .{ .differing = @as(f64, @floatFromInt(differing)) / @as(f64, @floatFromInt(n)), .distinct = seen.count() };
}

fn captureMac(gpa: std.mem.Allocator, pw: zpui.platform.Window) !Image {
    if (builtin.os.tag != .macos) unreachable;
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const number = mac.MacWindow.fromWindow(pw).windowNumber();
    const create_image = cf.cgWindowListCreateImage() orelse return error.CGWindowListCreateImageUnavailable;
    const image = create_image(cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, number, cf.kCGWindowImageBoundsIgnoreFraming | cf.kCGWindowImageBestResolution) orelse
        return error.CGWindowListCreateImageReturnedNull; // no Screen Recording permission?
    defer cf.CGImageRelease(image);
    const w = cf.CGImageGetWidth(image);
    const h = cf.CGImageGetHeight(image);
    if (w == 0 or h == 0) return error.EmptyWindowImage;
    const pixels = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);
    const space = cf.CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, cf.kCGImageAlphaPremultipliedLast | cf.kCGBitmapByteOrder32Big) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    cf.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    unpremultiply(pixels);
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}

/// X11 only: crops the window's rectangle out of the root window with
/// ImageMagick's `import` (PPM on stdout, parsed here).
fn captureX11(gpa: std.mem.Allocator, io: std.Io, pw: zpui.platform.Window) !Image {
    const b = pw.bounds();
    const scale = pw.scaleFactor();
    const content = pw.contentSize();
    const w: u32 = @intFromFloat(@round(content.width * scale));
    const h: u32 = @intFromFloat(@round(content.height * scale));
    const x: i32 = @intFromFloat(@round(b.origin.x * scale));
    const y: i32 = @intFromFloat(@round(b.origin.y * scale));
    var crop_buf: [64]u8 = undefined;
    const crop = try std.fmt.bufPrint(&crop_buf, "{d}x{d}+{d}+{d}", .{ w, h, @max(x, 0), @max(y, 0) });
    std.debug.print("zeron smoke: import -window root -crop {s}\n", .{crop});
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "import", "-window", "root", "-crop", crop, "+repage", "-depth", "8", "ppm:-" },
        .stdout_limit = .limited(256 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("zeron smoke: could not run ImageMagick `import` ({t}); install imagemagick (X11 only)\n", .{err});
        return error.ImportUnavailable;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.term.success()) {
        std.debug.print("zeron smoke: import failed: {s}\n", .{res.stderr});
        return error.ImportFailed;
    }
    return parsePpm(gpa, res.stdout);
}

/// Binary PPM (P6, maxval 255) → RGBA8 (alpha 255).
fn parsePpm(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    var pos: usize = 0;
    var fields: [4]u32 = undefined; // magic placeholder, width, height, maxval
    if (bytes.len < 2 or !std.mem.eql(u8, bytes[0..2], "P6")) return error.NotPpm;
    pos = 2;
    for (fields[1..]) |*f| {
        while (pos < bytes.len) {
            if (bytes[pos] == '#') {
                while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
            } else if (std.ascii.isWhitespace(bytes[pos])) pos += 1 else break;
        }
        const start_pos = pos;
        while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) pos += 1;
        f.* = std.fmt.parseInt(u32, bytes[start_pos..pos], 10) catch return error.BadPpmHeader;
    }
    pos += 1; // single whitespace before the raster
    const w = fields[1];
    const h = fields[2];
    if (fields[3] != 255) return error.UnsupportedPpmDepth;
    const n = @as(usize, w) * h;
    if (bytes.len < pos + n * 3) return error.TruncatedPpm;
    const pixels = try gpa.alloc(u8, n * 4);
    for (0..n) |i| {
        pixels[i * 4 ..][0..3].* = bytes[pos + i * 3 ..][0..3].*;
        pixels[i * 4 + 3] = 255;
    }
    return .{ .width = w, .height = h, .pixels = pixels };
}

fn unpremultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}

// Minimal RGBA8 PNG encoder (same as examples/png.zig, which this module can't import).
fn encodePng(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    const flate = std.compress.flate;
    const stride = @as(usize, width) * 4;
    var raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const row = pixels[y * stride ..][0..stride];
        const out = raw[y * (stride + 1) ..][0 .. stride + 1];
        out[0] = 1; // Sub filter
        for (row, 0..) |byte, i| out[1 + i] = byte -% (if (i >= 4) row[i - 4] else 0);
    }
    var zlib: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer zlib.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compress = try flate.Compress.init(&zlib.writer, window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", zlib.written());
    try writeChunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "ppm parse + blank detection" {
    const gpa = std.testing.allocator;
    const ppm = "P6\n# c\n2 1\n255\n" ++ "\x00\x00\x00\xff\xff\xff";
    const img = try parsePpm(gpa, ppm);
    defer gpa.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 }, img.pixels);
    var flat: [64 * 4]u8 = undefined;
    for (0..64) |i| flat[i * 4 ..][0..4].* = .{ 10, 10, 10, 255 };
    const st = stats(&flat);
    try std.testing.expect(st.differing == 0 and st.distinct == 1);
    const png = try encodePng(gpa, 2, 1, img.pixels);
    defer gpa.free(png);
    try std.testing.expectEqualSlices(u8, "\x89PNG", png[0..4]);
}
