//! Platform input events (gpui `interactive.rs` `PlatformInput` and friends).

const geometry = @import("geometry.zig");

pub const Point = geometry.Point(geometry.Pixels);

pub const Modifiers = packed struct(u8) {
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    /// Cmd on macOS, Super/Windows key elsewhere.
    platform: bool = false,
    function: bool = false,
    _pad: u3 = 0,

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
    pub fn none(m: Modifiers) bool {
        return @as(u8, @bitCast(m)) == 0;
    }
    /// The "secondary" modifier: Cmd on macOS, Ctrl elsewhere (gpui `secondary()`).
    pub fn secondary(m: Modifiers) bool {
        return if (@import("builtin").os.tag == .macos) m.platform else m.control;
    }
};

/// A key press as gpui models it: `key` is the layout-independent key name
/// ("a", "enter", "left", "f1", ...), `key_char` the text it would insert if any.
pub const Keystroke = struct {
    modifiers: Modifiers = .{},
    /// Lowercase key name, gpui spelling (e.g. "a", "enter", "escape", "backspace", "tab", "space", "up").
    key: []const u8,
    /// Text produced by this keystroke under the current layout (UTF-8), if any.
    key_char: ?[]const u8 = null,
};

pub const MouseButton = enum { left, right, middle, back, forward };

pub const KeyDownEvent = struct { keystroke: Keystroke, is_held: bool = false, prefer_character_input: bool = false };
pub const KeyUpEvent = struct { keystroke: Keystroke };
pub const ModifiersChangedEvent = struct { modifiers: Modifiers, capslock: bool = false };

pub const MouseDownEvent = struct {
    button: MouseButton,
    position: Point,
    modifiers: Modifiers = .{},
    click_count: u32 = 1,
    first_mouse: bool = false,
};
pub const MouseUpEvent = struct {
    button: MouseButton,
    position: Point,
    modifiers: Modifiers = .{},
    click_count: u32 = 1,
};
pub const MouseMoveEvent = struct {
    position: Point,
    pressed_button: ?MouseButton = null,
    modifiers: Modifiers = .{},
};
pub const MouseExitEvent = struct {
    position: Point,
    pressed_button: ?MouseButton = null,
    modifiers: Modifiers = .{},
};

pub const TouchPhase = enum { started, moved, ended };

pub const ScrollDelta = union(enum) {
    /// Precise (trackpad) delta in logical pixels.
    pixels: Point,
    /// Line-based (wheel) delta.
    lines: Point,
};

pub const ScrollWheelEvent = struct {
    position: Point,
    delta: ScrollDelta,
    modifiers: Modifiers = .{},
    touch_phase: TouchPhase = .moved,
};

pub const FileDropEvent = union(enum) {
    entered: struct { position: Point, paths: []const []const u8 },
    pending: struct { position: Point },
    submit: struct { position: Point },
    exited,
};

pub const PlatformInput = union(enum) {
    key_down: KeyDownEvent,
    key_up: KeyUpEvent,
    modifiers_changed: ModifiersChangedEvent,
    mouse_down: MouseDownEvent,
    mouse_up: MouseUpEvent,
    mouse_move: MouseMoveEvent,
    mouse_exited: MouseExitEvent,
    scroll_wheel: ScrollWheelEvent,
    file_drop: FileDropEvent,
};
