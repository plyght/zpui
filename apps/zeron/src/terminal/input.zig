//! Mouse, wheel, paste and focus encoding for the PTY (Ghostty encoders,
//! driven by the emulator's current modes).
const std = @import("std");
const Allocator = std.mem.Allocator;
const vt = @import("ghostty-vt");
const Emulator = @import("Emulator.zig");
const keys = @import("keys.zig");

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

pub const MouseButton = enum { left, right, middle, back, forward, wheel_up, wheel_down, wheel_left, wheel_right };
pub const MouseAction = enum { press, release, motion };

/// Where the grid is on screen, in pixels (device or logical, as long as
/// event positions use the same space).
pub const Geometry = struct {
    /// Position of the first cell's top-left corner.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    cell_width: f32,
    cell_height: f32,
};

pub const MouseEvent = struct {
    action: MouseAction,
    /// Null for motion with no button held.
    button: ?MouseButton = null,
    mods: keys.Mods = .{},
    /// Pointer position in the same space as `Geometry`.
    x: f32,
    y: f32,
    /// Whether any button is held (for motion/out-of-viewport reporting).
    any_button_pressed: bool = false,
};

fn toVtButton(b: MouseButton) vt.input.MouseButton {
    return switch (b) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .wheel_up => .four,
        .wheel_down => .five,
        .wheel_left => .six,
        .wheel_right => .seven,
        .back => .eight,
        .forward => .nine,
    };
}

fn toVtMods(m: keys.Mods) vt.input.KeyMods {
    return .{ .shift = m.shift, .ctrl = m.control, .alt = m.alt, .super = m.platform };
}

const RendererSize = @FieldType(vt.input.MouseEncodeOptions, "size");

/// Encode a mouse event per the active reporting mode (X10/normal/button/
/// any) and format (X10/UTF-8/SGR/URxvt/SGR-pixels). Returns null when the
/// program did not ask for this event.
pub fn encodeMouse(emu: *Emulator, ev: MouseEvent, geo: Geometry, buf: []u8) ?[]const u8 {
    if (!emu.mouseReporting()) return null;
    const cw = @max(geo.cell_width, 1);
    const ch = @max(geo.cell_height, 1);
    const cols: f32 = @floatFromInt(emu.cols());
    const rows: f32 = @floatFromInt(emu.rows());
    const size: RendererSize = .{
        .screen = .{ .width = @intFromFloat(@ceil(cols * cw)), .height = @intFromFloat(@ceil(rows * ch)) },
        .cell = .{ .width = @intFromFloat(@round(cw)), .height = @intFromFloat(@round(ch)) },
        .padding = .{},
    };
    var opts: vt.input.MouseEncodeOptions = .fromTerminal(&emu.terminal, size);
    opts.any_button_pressed = ev.any_button_pressed or (ev.action == .press);
    opts.last_cell = &emu.mouse_last_cell;
    // Pixel positions relative to the grid, scaled to the integer cell size
    // the encoder divides by.
    const sx = @as(f32, @floatFromInt(size.cell.width)) / cw;
    const sy = @as(f32, @floatFromInt(size.cell.height)) / ch;
    const event: vt.input.MouseEncodeEvent = .{
        .action = switch (ev.action) {
            .press => .press,
            .release => .release,
            .motion => .motion,
        },
        .button = if (ev.button) |b| toVtButton(b) else null,
        .mods = toVtMods(ev.mods),
        .pos = .{ .x = (ev.x - geo.origin_x) * sx, .y = (ev.y - geo.origin_y) * sy },
    };
    var w: std.Io.Writer = .fixed(buf);
    vt.input.encodeMouse(&w, event, opts) catch return null;
    const out = w.buffered();
    return if (out.len == 0) null else out;
}

// ---------------------------------------------------------------------------
// Wheel
// ---------------------------------------------------------------------------

pub const WheelResult = union(enum) {
    /// Bytes for the PTY (mouse wheel reports, or arrow keys for
    /// alternate-scroll in full-screen apps).
    bytes: []const u8,
    /// No PTY bytes: the viewport was scrolled locally.
    scrolled,
};

/// Handle `lines` of wheel motion (positive = up/back in history) at a
/// pointer position: mouse-reporting programs get wheel events; the alt
/// screen with mode 1007 (alternate scroll, default on) gets arrow keys;
/// otherwise the scrollback viewport moves.
pub fn wheel(emu: *Emulator, lines: i32, ev_pos: struct { x: f32, y: f32, mods: keys.Mods = .{} }, geo: Geometry, buf: []u8) WheelResult {
    if (lines == 0) return .scrolled;
    const n: usize = @abs(lines);
    if (emu.mouseReporting()) {
        var len: usize = 0;
        for (0..n) |_| {
            const one = encodeMouse(emu, .{
                .action = .press,
                .button = if (lines > 0) .wheel_up else .wheel_down,
                .mods = ev_pos.mods,
                .x = ev_pos.x,
                .y = ev_pos.y,
            }, geo, buf[len..]) orelse break;
            len += one.len;
            if (buf.len - len < 32) break;
        }
        return .{ .bytes = buf[0..len] };
    }
    if (emu.altScreen() and emu.mode(.mouse_alternate_scroll)) {
        const app = emu.appCursorMode();
        const seq: []const u8 = if (lines > 0)
            (if (app) "\x1bOA" else "\x1b[A")
        else
            (if (app) "\x1bOB" else "\x1b[B");
        var len: usize = 0;
        for (0..n) |_| {
            if (len + seq.len > buf.len) break;
            @memcpy(buf[len..][0..seq.len], seq);
            len += seq.len;
        }
        return .{ .bytes = buf[0..len] };
    }
    emu.scroll(lines);
    return .scrolled;
}

// ---------------------------------------------------------------------------
// Paste
// ---------------------------------------------------------------------------

/// Encode pasted text for the PTY: bracketed (mode 2004) when the program
/// asked for it, with xterm's unsafe control bytes replaced; newlines become
/// CR when not bracketed. Caller owns the result.
pub fn paste(emu: *const Emulator, gpa: Allocator, text: []const u8) ![]u8 {
    return pasteWith(gpa, text, emu.bracketedPasteMode());
}

pub fn pasteWith(gpa: Allocator, text: []const u8, bracketed: bool) ![]u8 {
    const data = try gpa.dupe(u8, text);
    defer gpa.free(data);
    const parts = vt.input.encodePaste(data, .{ .bracketed = bracketed });
    var total: usize = 0;
    for (parts) |p| total += p.len;
    const out = try gpa.alloc(u8, total);
    var i: usize = 0;
    for (parts) |p| {
        @memcpy(out[i..][0..p.len], p);
        i += p.len;
    }
    return out;
}

/// Whether pasting `text` could execute commands without confirmation
/// (newlines outside bracketed paste, or an embedded end-of-paste marker).
pub fn isSafePaste(emu: *const Emulator, text: []const u8) bool {
    _ = emu;
    return vt.input.isSafePaste(text);
}

// ---------------------------------------------------------------------------
// Focus
// ---------------------------------------------------------------------------

/// `CSI I` / `CSI O` when the program enabled focus reporting (1004).
pub fn focus(emu: *const Emulator, focused: bool) ?[]const u8 {
    if (!emu.focusReporting()) return null;
    return if (focused) "\x1b[I" else "\x1b[O";
}
