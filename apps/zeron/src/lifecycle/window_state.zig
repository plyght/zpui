//! Main-window geometry persistence (port of zeron `lib.rs`
//! `restored_main_window_bounds` / `save_window_geometry` /
//! `observe_main_window_geometry`): `ui-settings.json` `windowGeometry`
//! `{displayUuid?, x, y, width, height}`.
//!
//! Restore: the remembered display (by uuid) when connected, else the primary, else any
//! valid one; the frame is clamped into that display's visible area (min 900×600) and
//! re-centered when it moved to another display (`WindowGeometry.restore`). Save: every
//! bounds change (debounced write), skipped while fullscreen or maximized (Rust keeps
//! only `WindowBounds::Windowed`); the close path saves without querying displays.
//! Coordinates are the window's top-left relative to its display, logical pixels
//! (zpui `Window.bounds` / `Display.visible_bounds`).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");

const App = zpui.App;
const Window = zpui.Window;
const WindowGeometry = model.settings.WindowGeometry;
const pf = zpui.platform;

/// Lowercase hyphenated UUID text (Rust `uuid::Uuid` Display).
pub fn formatUuid(buf: *[36]u8, bytes: [16]u8) []const u8 {
    const hex = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(buf[0..8], hex[0..8]);
    buf[8] = '-';
    @memcpy(buf[9..13], hex[8..12]);
    buf[13] = '-';
    @memcpy(buf[14..18], hex[12..16]);
    buf[18] = '-';
    @memcpy(buf[19..23], hex[16..20]);
    buf[23] = '-';
    @memcpy(buf[24..36], hex[20..32]);
    return buf;
}

pub const Restored = struct {
    bounds: zpui.Bounds(f32),
    display_id: ?u32,
};

/// Where the main window opens: the saved geometry fitted to the current displays, or
/// `fallback` (1320×880 centered) without a usable saved frame.
pub fn restoredBounds(saved: ?WindowGeometry, displays: []const pf.Display, fallback_size: zpui.Size(f32)) Restored {
    const fallback = centered(displays, fallback_size);
    const g = saved orelse return fallback;
    if (displays.len == 0) return fallback;
    var uuid_store: [16][36]u8 = undefined;
    var geoms: [16]WindowGeometry = undefined;
    const n = @min(displays.len, geoms.len);
    var primary: usize = 0;
    for (displays[0..n], 0..) |d, i| {
        geoms[i] = .{
            .x = d.visible_bounds.origin.x,
            .y = d.visible_bounds.origin.y,
            .width = d.visible_bounds.size.width,
            .height = d.visible_bounds.size.height,
            .displayUuid = if (d.uuid) |u| formatUuid(&uuid_store[i], u) else null,
        };
        if (d.primary) primary = i;
    }
    const r = g.restore(geoms[0..n], primary) orelse return fallback;
    return .{
        .bounds = .{ .origin = .{ .x = r[1].x, .y = r[1].y }, .size = .{ .width = r[1].width, .height = r[1].height } },
        .display_id = displays[r[0]].id,
    };
}

fn centered(displays: []const pf.Display, size: zpui.Size(f32)) Restored {
    for (displays) |d| if (d.primary or displays.len == 1) {
        const v = d.visible_bounds;
        return .{
            .bounds = .{
                .origin = .{ .x = v.origin.x + @max((v.size.width - size.width) / 2, 0), .y = v.origin.y + @max((v.size.height - size.height) / 2, 0) },
                .size = size,
            },
            .display_id = d.id,
        };
    };
    return .{ .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = size }, .display_id = null };
}

/// `save_window_geometry(window, query_display)`.
pub fn save(window: *Window, app: *App, query_display: bool) void {
    if (window.isFullscreen() or window.isMaximized()) return;
    const b = window.bounds();
    var g: WindowGeometry = .{ .x = b.origin.x, .y = b.origin.y, .width = b.size.width, .height = b.size.height };
    if (!g.isValid()) return;
    var uuid_buf: [36]u8 = undefined;
    var uuid: ?[]const u8 = null;
    if (query_display) {
        if (window.displayId()) |id| {
            var ds: [16]pf.Display = undefined;
            const count = app.displays(&ds);
            for (ds[0..count]) |d| if (d.id == id) if (d.uuid) |u| {
                uuid = formatUuid(&uuid_buf, u);
            };
        }
    } else if (model.settings_store.current(app)) |s| if (s.windowGeometry) |old| {
        uuid = old.displayUuid; // keep the display recorded by the last bounds change
    };
    g.displayUuid = uuid;
    const Set = struct {
        fn set(geom: WindowGeometry, s: *model.UiSettings, a: std.mem.Allocator) void {
            var copy = geom;
            if (geom.displayUuid) |u| copy.displayUuid = a.dupe(u8, u) catch null;
            s.windowGeometry = copy;
        }
    };
    _ = model.settings_store.update(app, .debounced, g, Set.set);
}

/// Save on every move / resize of `window` (`observe_main_window_geometry`).
pub fn observe(window: *Window) !void {
    try window.observeBounds({}, struct {
        fn f(_: void, w: *Window, app: *App) void {
            save(w, app, true);
        }
    }.f);
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "uuid formatting matches Rust's Display" {
    var buf: [36]u8 = undefined;
    const bytes = [16]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    try testing.expectEqualStrings("12345678-9abc-def0-0123-456789abcdef", formatUuid(&buf, bytes));
}

test "restore: saved frame on its display, clamped; unknown display re-centers on primary" {
    const a = [16]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const b = [16]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const displays = [_]pf.Display{
        .{ .id = 10, .bounds = .{ .origin = .zero, .size = .{ .width = 1440, .height = 900 } }, .visible_bounds = .{ .origin = .{ .x = 0, .y = 25 }, .size = .{ .width = 1440, .height = 875 } }, .scale_factor = 2, .uuid = a, .primary = true },
        .{ .id = 11, .bounds = .{ .origin = .zero, .size = .{ .width = 2560, .height = 1440 } }, .visible_bounds = .{ .origin = .zero, .size = .{ .width = 2560, .height = 1440 } }, .scale_factor = 1, .uuid = b },
    };
    var ubuf: [36]u8 = undefined;
    // On display B, inside.
    var r = restoredBounds(.{ .displayUuid = formatUuid(&ubuf, b), .x = 100, .y = 50, .width = 1200, .height = 800 }, &displays, .{ .width = 1320, .height = 880 });
    try testing.expectEqual(@as(?u32, 11), r.display_id);
    try testing.expectEqual(@as(f32, 100), r.bounds.origin.x);
    // Too big / off-screen on display A: clamped into the visible area, min 900×600.
    r = restoredBounds(.{ .displayUuid = formatUuid(&ubuf, a), .x = 2000, .y = -40, .width = 3000, .height = 400 }, &displays, .{ .width = 1320, .height = 880 });
    try testing.expectEqual(@as(?u32, 10), r.display_id);
    try testing.expectEqual(@as(f32, 1440), r.bounds.size.width);
    try testing.expectEqual(@as(f32, 600), r.bounds.size.height);
    try testing.expectEqual(@as(f32, 0), r.bounds.origin.x);
    try testing.expectEqual(@as(f32, 25), r.bounds.origin.y);
    // Remembered display gone: primary, centered.
    r = restoredBounds(.{ .displayUuid = "00000000-0000-0000-0000-000000000009", .x = 5, .y = 5, .width = 1000, .height = 700 }, &displays, .{ .width = 1320, .height = 880 });
    try testing.expectEqual(@as(?u32, 10), r.display_id);
    try testing.expectEqual(@as(f32, 220), r.bounds.origin.x);
    // Nothing saved: centered default size on the primary.
    r = restoredBounds(null, &displays, .{ .width = 1320, .height = 880 });
    try testing.expectEqual(@as(f32, 1320), r.bounds.size.width);
    try testing.expectEqual(@as(f32, 60), r.bounds.origin.x);
}
