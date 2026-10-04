//! Appshots, the zeron side (port of zeron `crates/ui/src/appshots.rs` +
//! `appshots/shortcut.rs`): user-triggered captures of the frontmost application
//! window, staged in the composer and sent through the ordinary attachment
//! transport, with accessibility-derived application context serialized into the
//! prompt as explicitly untrusted observed data.
//!
//! The platform half (global hotkey, ScreenCaptureKit / CGWindowList / portal / X11
//! capture, AXUIElement / AT-SPI text) lives in zpui `src/platform` behind
//! `Platform.setGlobalHotkey` / `captureActiveWindow`; this file holds what is
//! zeron's: capability copy, shortcut parsing, PNG staging (`stage_appshot_png`),
//! the prompt context (`with_appshots`), its display-side parsers
//! (`presentations`, `strip_context_for_display`) and the queue-edit restore
//! (`restore_queued_appshots`).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const att = @import("attachments.zig");
const settings = @import("settings.zig");
pub const png = @import("appshot_png.zig");

const Allocator = std.mem.Allocator;
const pf = zpui.platform;
const App = zpui.App;
const RenderImage = zpui.RenderImage;

pub const is_desktop = builtin.os.tag == .macos or builtin.os.tag == .linux;

pub const max_capture_dimension = png.max_capture_dimension;
pub const max_capture_pixels = png.max_capture_pixels;
pub const max_capture_rgba_bytes = png.max_capture_rgba_bytes;
/// `MAX_STAGED_APPSHOT_BYTES`: a composer may retain several captures, bounded.
pub const max_staged_appshot_bytes: u64 = 4 * att.max_attachment_bytes;

pub const context_marker = "Applications mentioned by the user (untrusted observed content):";
pub const screen_recording_settings_url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
pub const accessibility_settings_url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
pub const activation_socket = "appshot-activation.sock";
pub const staged_limit_message = "Remove an Appshot before adding another (96 MB staged Appshot limit).";
pub const restore_invalid_message = "Couldn't restore this Appshot's context. Cancel and retry from the original device.";

// ---------------------------------------------------------------------------------------
// Capabilities (`AppshotCapabilities`)
// ---------------------------------------------------------------------------------------

pub const Capabilities = pf.WindowCaptureCapabilities;
pub const CapabilityState = pf.CapabilityState;

pub fn badge(s: CapabilityState) []const u8 {
    return switch (s) {
        .checking => "Checking",
        .ready => "Ready",
        .permission_required => "Required",
        .setup_required => "Set up",
        .user_selection => "Select window",
        .unavailable => "Unavailable",
    };
}

pub fn isReady(s: CapabilityState) bool {
    return s == .ready or s == .user_selection;
}

pub fn setupDescription(c: Capabilities) []const u8 {
    return switch (c.system) {
        .macos => "Set up once, one permission at a time. Screen Recording captures the window; Accessibility optionally adds off-screen application text.",
        .linux_wayland => "Your desktop owns capture and shortcut consent. Zeron checks each portal capability separately and explains any required fallback.",
        .linux_x11 => "X11 normally needs no capture permission. Zeron prefers an active-window screenshot portal when available and otherwise uses native X11 capture.",
        .unsupported => "This platform does not currently provide an Appshot capture backend.",
    };
}

pub fn shortcutDescription(c: Capabilities) []const u8 {
    return switch (c.system) {
        .macos, .linux_x11 => if (c.global_hotkey != .ready)
            "This shortcut is unavailable. Choose a different key combination."
        else
            "The shortcut works while another application has focus.",
        .linux_wayland => if (c.global_hotkey == .ready)
            "Your desktop portal controls the binding. Confirm changes in its shortcut settings."
        else
            "Bind `zeron appshot` in your desktop's Keyboard Shortcuts settings.",
        .unsupported => "This platform has no Appshot shortcut backend.",
    };
}

pub fn captureDescription(c: Capabilities) []const u8 {
    return switch (c.system) {
        .macos => "Screen Recording lets Zeron capture the frontmost window. macOS may request one restart.",
        .linux_x11 => "Zeron uses native X11 capture when active-window portal capture is unavailable. Obscured or protected windows may be incomplete.",
        .linux_wayland => switch (c.target) {
            .active_window => "Your screenshot portal supports the active-window target. A system consent surface may appear.",
            .portal_window_picker => "Your portal requires choosing a window for each capture.",
        },
        .unsupported => "Active-window capture is unavailable on this platform.",
    };
}

pub fn semanticDescription(c: Capabilities) []const u8 {
    return switch (c.system) {
        .macos => "Accessibility adds visible and off-screen application text. Screenshots work without it.",
        .linux_wayland => "This portal does not identify the captured window, so Appshots include the screenshot only.",
        .linux_x11 => "Native X11 captures can include AT-SPI text when the process and window can be matched uniquely. Portal captures include the screenshot only.",
        .unsupported => "Semantic application text is unavailable on this platform.",
    };
}

/// `capture_settings_url` / `semantic_settings_url` (macOS only).
pub fn settingsUrl(system: pf.CaptureSystem, kind: pf.CaptureAccess) ?[]const u8 {
    if (system != .macos) return null;
    return switch (kind) {
        .capture => screen_recording_settings_url,
        .semantic => accessibility_settings_url,
    };
}

/// `CaptureError`'s Display.
pub fn errorMessage(e: pf.WindowCaptureError) []const u8 {
    return switch (e) {
        .permission_required => "Window capture permission is required. Open Zeron Settings → Appshots for the platform-specific recovery step.",
        .cancelled => "Appshot capture cancelled.",
        .self_capture => "Switch to another app to capture an Appshot.",
        .no_eligible_window => "No application window is available to capture.",
        .shortcut_unavailable => "The Appshot shortcut could not be registered because another app may be using it.",
        .failed => |m| m,
    };
}

// ---------------------------------------------------------------------------------------
// Shortcut (`shortcut.rs` `Shortcut::parse`)
// ---------------------------------------------------------------------------------------

const supported_named_keys = [_][]const u8{ "space", "tab", "enter", "backspace", "delete", "insert", "up", "down", "left", "right", "home", "end", "pageup", "pagedown" };

/// The global hotkey of a stored combo (`mod-` resolved per platform); null when the
/// combo is not a supported modified key. `key_buf` backs the returned key.
pub fn parseShortcut(combo: []const u8, key_buf: *[32]u8) ?pf.GlobalHotkey {
    return parseShortcutOn(combo, builtin.os.tag == .macos, key_buf);
}

pub fn parseShortcutOn(combo: []const u8, mac: bool, key_buf: *[32]u8) ?pf.GlobalHotkey {
    var pbuf: [96]u8 = undefined;
    const resolved = settings.platformComboOn(&pbuf, mac, combo);
    var mem: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    const ks = zpui.core.parseKeystroke(fba.allocator(), resolved) catch return null;
    const key = ks.key;
    const m = ks.modifiers;
    var supported = key.len == 1 and std.ascii.isAlphanumeric(key[0]);
    for (supported_named_keys) |n| supported = supported or std.mem.eql(u8, key, n);
    if (key.len >= 2 and key[0] == 'f') {
        if (std.fmt.parseInt(u8, key[1..], 10)) |n| {
            supported = supported or (n >= 1 and n <= 20 and std.ascii.isDigit(key[1]));
        } else |_| {}
    }
    if (!supported or m.function or !(m.control or m.alt or m.platform)) return null;
    if (key.len > key_buf.len) return null;
    @memcpy(key_buf[0..key.len], key);
    return .{ .key = key_buf[0..key.len], .control = m.control, .alt = m.alt, .shift = m.shift, .platform = m.platform };
}

pub fn validateShortcut(combo: []const u8) bool {
    var b: [32]u8 = undefined;
    return parseShortcut(combo, &b) != null;
}

/// `activation_socket_path`: `{data_dir}/appshot-activation.sock` (owned).
pub fn activationSocketPath(gpa: Allocator, data_dir: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, activation_socket });
}

// ---------------------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------------------

const Utf8Iter = struct {
    s: []const u8,
    i: usize = 0,
    /// Next code point (invalid bytes → U+FFFD, one byte each).
    fn next(it: *Utf8Iter) ?u21 {
        if (it.i >= it.s.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch {
            it.i += 1;
            return 0xfffd;
        };
        if (it.i + n > it.s.len) {
            it.i += 1;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(it.s[it.i..][0..n]) catch {
            it.i += 1;
            return 0xfffd;
        };
        it.i += n;
        return cp;
    }
};

fn appendCp(gpa: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch std.unicode.utf8Encode(0xfffd, &b) catch unreachable;
    try out.appendSlice(gpa, b[0..n]);
}

fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// Rust `str::trim` (Unicode whitespace).
fn trimUnicode(s: []const u8) []const u8 {
    var start: usize = 0;
    var it: Utf8Iter = .{ .s = s };
    while (true) {
        const at = it.i;
        const cp = it.next() orelse return "";
        if (!isUnicodeWhitespace(cp)) {
            start = at;
            break;
        }
    }
    var end = s.len;
    while (end > start) {
        var b = end - 1;
        while (b > start and (s[b] & 0xc0) == 0x80) b -= 1;
        var t: Utf8Iter = .{ .s = s[b..end] };
        const cp = t.next() orelse break;
        if (!isUnicodeWhitespace(cp)) break;
        end = b;
    }
    return s[start..end];
}

/// The first `n` characters of `s` (owned).
fn takeChars(gpa: Allocator, s: []const u8, n: usize) Allocator.Error![]u8 {
    var it: Utf8Iter = .{ .s = s };
    var count: usize = 0;
    while (count < n) : (count += 1) if (it.next() == null) break;
    return gpa.dupe(u8, s[0..it.i]);
}

/// `safe_app_name`: OS application names as one safe filename component (owned).
pub fn safeAppName(gpa: Allocator, value: []const u8) Allocator.Error![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var it: Utf8Iter = .{ .s = value };
    var chars: usize = 0;
    while (it.next()) |cp| {
        if (chars >= 100) break;
        chars += 1;
        const control = cp < 0x20 or (cp >= 0x7f and cp <= 0x9f);
        try appendCp(gpa, &raw, if (control or cp == '/' or cp == '\\' or cp == ':') '-' else cp);
    }
    // split_whitespace().join(" ")
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var jt: Utf8Iter = .{ .s = raw.items };
    var pending = false;
    while (jt.next()) |cp| {
        if (isUnicodeWhitespace(cp)) {
            pending = joined.items.len > 0;
            continue;
        }
        if (pending) try joined.append(gpa, ' ');
        pending = false;
        try appendCp(gpa, &joined, cp);
    }
    const trimmed = std.mem.trim(u8, joined.items, ".- ");
    return gpa.dupe(u8, if (trimmed.len == 0) "Application" else trimmed);
}

/// `xml_escape`, appended to `out`.
pub fn xmlEscape(gpa: Allocator, out: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    var it: Utf8Iter = .{ .s = value };
    while (it.next()) |cp| switch (cp) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&apos;"),
        '\r' => try out.appendSlice(gpa, "&#13;"),
        '\n' => try out.appendSlice(gpa, "&#10;"),
        '\t' => try out.appendSlice(gpa, "&#9;"),
        // XML 1.0 cannot represent these, even as references.
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0xfffe, 0xffff => try appendCp(gpa, out, 0xfffd),
        else => try appendCp(gpa, out, cp),
    };
}

// ---------------------------------------------------------------------------------------
// A captured Appshot (`CapturedAppshot`)
// ---------------------------------------------------------------------------------------

pub const Accessibility = struct {
    format_version: u32 = 1,
    /// Owned.
    content: []u8 = &.{},
    truncated: bool = false,
};

/// Without an App (tests, workers) only the reference is dropped.
fn releaseImg(app: ?*App, r: *RenderImage) void {
    if (app) |a| att.releaseImage(a, r) else r.release();
}

pub const Captured = struct {
    id: [36]u8,
    app_name: []u8,
    bundle_identifier: ?[]u8 = null,
    window_title: ?[]u8 = null,
    accessibility: Accessibility = .{},
    screenshot: att.Staged,
    /// Pixel dimensions of the captured PNG (sizes the composer tile).
    dimensions: ?[2]u32 = null,
    /// Presentation only: never uploaded or serialized.
    icon: ?*RenderImage = null,

    /// `app` may be null only when no image (screenshot preview / icon) is attached.
    pub fn deinit(self: *Captured, gpa: Allocator, app: ?*App) void {
        gpa.free(self.app_name);
        if (self.bundle_identifier) |s| gpa.free(s);
        if (self.window_title) |s| gpa.free(s);
        gpa.free(self.accessibility.content);
        gpa.free(self.screenshot.name);
        self.screenshot.blob.release();
        if (self.screenshot.image) |r| releaseImg(app, r);
        if (self.icon) |r| releaseImg(app, r);
        self.* = undefined;
    }

    pub fn clone(self: *const Captured, gpa: Allocator) Allocator.Error!Captured {
        var out: Captured = .{
            .id = self.id,
            .app_name = try gpa.dupe(u8, self.app_name),
            .screenshot = undefined,
            .dimensions = self.dimensions,
            .accessibility = .{ .format_version = self.accessibility.format_version, .truncated = self.accessibility.truncated },
        };
        errdefer gpa.free(out.app_name);
        out.bundle_identifier = if (self.bundle_identifier) |s| try gpa.dupe(u8, s) else null;
        out.window_title = if (self.window_title) |s| try gpa.dupe(u8, s) else null;
        out.accessibility.content = try gpa.dupe(u8, self.accessibility.content);
        out.screenshot = try self.screenshot.clone(gpa);
        out.icon = if (self.icon) |r| r.retain() else null;
        return out;
    }

    pub fn bytes(self: *const Captured) []const u8 {
        return self.screenshot.bytes();
    }
};

/// Sum of the staged screenshot bytes.
pub fn stagedBytes(shots: []const Captured) u64 {
    var n: u64 = 0;
    for (shots) |*s| n += s.bytes().len;
    return n;
}

/// Worker-side result of `prepare` (the capture staged as an attachment, decoded).
pub const Prepared = struct {
    app_name: []u8,
    bundle_identifier: ?[]u8,
    window_title: ?[]u8,
    accessibility: []u8,
    truncated: bool,
    /// "{safe app name} Appshot.png" (owned).
    name: []u8,
    png: []u8,
    dimensions: [2]u32,
    preview: ?zpui.image.DecodedImage = null,
    icon: ?zpui.image.DecodedImage = null,

    pub fn deinit(self: *Prepared, gpa: Allocator) void {
        gpa.free(self.app_name);
        if (self.bundle_identifier) |s| gpa.free(s);
        if (self.window_title) |s| gpa.free(s);
        gpa.free(self.accessibility);
        gpa.free(self.name);
        gpa.free(self.png);
        if (self.preview) |*d| d.deinit(gpa);
        if (self.icon) |*d| d.deinit(gpa);
    }
};

pub const PrepareResult = union(enum) { ok: Prepared, err: []u8 };

/// `stage_appshot_png`: bound, trim transparent backing-surface padding and validate a
/// capture's PNG; returns the staged PNG + dimensions or a user-facing message
/// (owned). Takes `bytes`.
pub fn stagePng(gpa: Allocator, bytes: []u8) Allocator.Error!union(enum) { ok: struct { png: []u8, dims: [2]u32 }, err: []u8 } {
    var msg: ?[]u8 = null;
    if (bytes.len > att.max_attachment_bytes) {
        gpa.free(bytes);
        return .{ .err = try gpa.dupe(u8, "The captured window is larger than Zeron's 24 MB image limit.") };
    }
    var out = bytes;
    if (png.trimPadding(gpa, bytes, &msg)) |trimmed| {
        if (trimmed) |t| {
            gpa.free(bytes);
            out = t;
        }
    } else |e| {
        gpa.free(bytes);
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Failed => .{ .err = msg.? },
        };
    }
    const dims = png.dimensions(out) orelse {
        gpa.free(out);
        return .{ .err = try gpa.dupe(u8, "The captured window is not a valid PNG image.") };
    };
    _ = png.validateDimensions(gpa, dims[0], dims[1], &msg) catch |e| {
        gpa.free(out);
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Failed => .{ .err = msg.? },
        };
    };
    return .{ .ok = .{ .png = out, .dims = dims } };
}

/// Worker thread: turn a platform capture into a staged Appshot (consumes `capture`).
pub fn prepare(gpa: Allocator, capture: *pf.WindowCapture) Allocator.Error!PrepareResult {
    const staged = try stagePng(gpa, capture.png);
    capture.png = &.{};
    defer capture.deinit(gpa);
    const ok = switch (staged) {
        .err => |m| return .{ .err = m },
        .ok => |o| o,
    };
    errdefer gpa.free(ok.png);
    const safe = try safeAppName(gpa, capture.app_name);
    defer gpa.free(safe);
    const name = try std.fmt.allocPrint(gpa, "{s} Appshot.png", .{safe});
    var p: Prepared = .{
        .app_name = capture.app_name,
        .bundle_identifier = capture.bundle_identifier,
        .window_title = capture.window_title,
        .accessibility = capture.accessibility,
        .truncated = capture.accessibility_truncated,
        .name = name,
        .png = ok.png,
        .dimensions = ok.dims,
    };
    // Moved into `p`.
    capture.app_name = &.{};
    capture.bundle_identifier = null;
    capture.window_title = null;
    capture.accessibility = &.{};
    p.preview = zpui.image.decode(gpa, p.png, .{ .animate = false }) catch null;
    if (capture.icon_png) |icon| p.icon = zpui.image.decode(gpa, icon, .{ .animate = false }) catch null;
    return .{ .ok = p };
}

fn renderOf(gpa: Allocator, decoded: *?zpui.image.DecodedImage) ?*RenderImage {
    const d = decoded.* orelse return null;
    decoded.* = null;
    return RenderImage.create(gpa, d) catch {
        var dd = d;
        dd.deinit(gpa);
        return null;
    };
}

/// Main thread: the composer-ready Appshot (consumes `p`).
pub fn finish(gpa: Allocator, io: std.Io, p: *Prepared) Allocator.Error!Captured {
    errdefer p.deinit(gpa);
    const blob = try att.Blob.create(gpa, p.png);
    var staged: att.Staged = .{ .id = undefined, .name = p.name, .format = .png, .blob = blob, .image = renderOf(gpa, &p.preview) };
    att.uuidV4(io, &staged.id);
    var out: Captured = .{
        .id = undefined,
        .app_name = p.app_name,
        .bundle_identifier = p.bundle_identifier,
        .window_title = p.window_title,
        .accessibility = .{ .content = p.accessibility, .truncated = p.truncated },
        .screenshot = staged,
        .dimensions = p.dimensions,
        .icon = renderOf(gpa, &p.icon),
    };
    att.uuidV4(io, &out.id);
    p.* = undefined;
    return out;
}

// ---------------------------------------------------------------------------------------
// Prompt context (`with_appshots`)
// ---------------------------------------------------------------------------------------

/// Staged screenshot id → final image path (`image_paths`).
pub const PathMap = struct {
    ids: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},

    pub fn get(self: PathMap, id: []const u8) ?[]const u8 {
        for (self.ids, 0..) |k, i| if (std.mem.eql(u8, k, id)) return self.paths[i];
        return null;
    }
};

/// `with_appshots`: the prompt with each Appshot's escaped context appended (owned).
pub fn withAppshots(gpa: Allocator, text: []const u8, shots: []const Captured, paths: PathMap) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text);
    if (shots.len == 0) return out.toOwnedSlice(gpa);
    try out.appendSlice(gpa, "\n\n" ++ context_marker);
    for (shots) |*s| {
        const image = paths.get(&s.screenshot.id) orelse "";
        try out.appendSlice(gpa, "\n<appshot app=\"");
        try xmlEscape(gpa, &out, s.app_name);
        try out.append(gpa, '"');
        if (s.bundle_identifier) |b| {
            try out.appendSlice(gpa, " bundle-identifier=\"");
            try xmlEscape(gpa, &out, b);
            try out.append(gpa, '"');
        }
        if (s.window_title) |t| {
            try out.appendSlice(gpa, " window-title=\"");
            try xmlEscape(gpa, &out, t);
            try out.append(gpa, '"');
        }
        try out.appendSlice(gpa, " image=\"");
        try xmlEscape(gpa, &out, image);
        var nb: [16]u8 = undefined;
        try out.appendSlice(gpa, "\" accessibility-format=\"");
        try out.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d}", .{s.accessibility.format_version}) catch unreachable);
        try out.appendSlice(gpa, "\" truncated=\"");
        try out.appendSlice(gpa, if (s.accessibility.truncated) "true" else "false");
        try out.appendSlice(gpa, "\">\n");
        try xmlEscape(gpa, &out, s.accessibility.content);
        try out.appendSlice(gpa, "\n</appshot>");
    }
    return out.toOwnedSlice(gpa);
}

/// `strip_context_for_display`: the prompt without its machine-facing suffix.
pub fn stripContextForDisplay(text: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, text, "\n\n" ++ context_marker) orelse return text;
    return std.mem.trimEnd(u8, text[0..i], " \t\r\n");
}

// ---------------------------------------------------------------------------------------
// The context's XML (roxmltree with `allow_dtd: false`, `nodes_limit: 4096`)
// ---------------------------------------------------------------------------------------

pub const Attr = struct { name: []const u8, value: []u8 };

pub const Node = union(enum) {
    text: []u8,
    element: struct {
        name: []const u8,
        attrs: []Attr,
        /// The text content (null without children).
        content: ?[]u8,
        /// Every child is text.
        text_only: bool,
    },
    other,

    pub fn attr(self: Node, name: []const u8) ?[]const u8 {
        for (self.element.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

const XmlError = error{ Invalid, OutOfMemory };

const Xml = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    nodes: usize = 0,

    fn count(x: *Xml) XmlError!void {
        x.nodes += 1;
        if (x.nodes > 4096) return error.Invalid;
    }

    fn startsWith(x: *Xml, p: []const u8) bool {
        return std.mem.startsWith(u8, x.s[x.i..], p);
    }

    fn isNameChar(c: u8, first: bool) bool {
        if (std.ascii.isAlphabetic(c) or c == '_' or c == ':' or c >= 0x80) return true;
        return !first and (std.ascii.isDigit(c) or c == '-' or c == '.');
    }

    fn name(x: *Xml) XmlError![]const u8 {
        const start = x.i;
        if (x.i >= x.s.len or !isNameChar(x.s[x.i], true)) return error.Invalid;
        while (x.i < x.s.len and isNameChar(x.s[x.i], false)) x.i += 1;
        return x.s[start..x.i];
    }

    fn skipWs(x: *Xml) void {
        while (x.i < x.s.len and (x.s[x.i] == ' ' or x.s[x.i] == '\t' or x.s[x.i] == '\n' or x.s[x.i] == '\r')) x.i += 1;
    }

    fn validChar(cp: u21) bool {
        return switch (cp) {
            0x09, 0x0a, 0x0d => true,
            0x20...0xd7ff, 0xe000...0xfffd, 0x10000...0x10ffff => true,
            else => false,
        };
    }

    /// Decode `raw` (text or attribute value): references, line ends, and (for
    /// attributes) whitespace normalization.
    fn decode(x: *Xml, raw: []const u8, attribute: bool) XmlError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(x.a);
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '&') {
                const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.Invalid;
                const ent = raw[i + 1 .. semi];
                i = semi + 1;
                if (std.mem.eql(u8, ent, "lt")) try out.append(x.a, '<') else if (std.mem.eql(u8, ent, "gt")) try out.append(x.a, '>') else if (std.mem.eql(u8, ent, "amp")) try out.append(x.a, '&') else if (std.mem.eql(u8, ent, "apos")) try out.append(x.a, '\'') else if (std.mem.eql(u8, ent, "quot")) try out.append(x.a, '"') else if (ent.len > 1 and ent[0] == '#') {
                    const hex = ent[1] == 'x';
                    const digits = if (hex) ent[2..] else ent[1..];
                    if (digits.len == 0) return error.Invalid;
                    for (digits) |d| if (!(if (hex) std.ascii.isHex(d) else std.ascii.isDigit(d))) return error.Invalid;
                    const v = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return error.Invalid;
                    if (v > 0x10ffff or !validChar(@intCast(v))) return error.Invalid;
                    try appendCp(x.a, &out, @intCast(v));
                } else return error.Invalid;
                continue;
            }
            if (c == '<') return error.Invalid;
            if (c == '\r') {
                i += 1;
                if (i < raw.len and raw[i] == '\n') i += 1;
                try out.append(x.a, if (attribute) ' ' else '\n');
                continue;
            }
            if (attribute and (c == '\n' or c == '\t')) {
                i += 1;
                try out.append(x.a, ' ');
                continue;
            }
            var it: Utf8Iter = .{ .s = raw[i..] };
            const cp = it.next().?;
            if (!validChar(cp) or (cp == 0xfffd and !std.mem.startsWith(u8, raw[i..], "\u{fffd}"))) return error.Invalid;
            try out.appendSlice(x.a, raw[i..][0..it.i]);
            i += it.i;
        }
        return out.toOwnedSlice(x.a);
    }

    /// Children until `</close>` (null = end of input). Text runs (incl. CDATA) merge.
    fn children(x: *Xml, close: ?[]const u8, out: *std.ArrayList(Node)) XmlError!void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(x.a);
        var have_text = false;
        while (true) {
            if (x.i >= x.s.len) {
                if (close != null) return error.Invalid;
                break;
            }
            if (x.s[x.i] != '<') {
                const end = std.mem.indexOfScalarPos(u8, x.s, x.i, '<') orelse x.s.len;
                const raw = x.s[x.i..end];
                if (std.mem.indexOf(u8, raw, "]]>") != null) return error.Invalid;
                const d = try x.decode(raw, false);
                defer x.a.free(d);
                try text.appendSlice(x.a, d);
                have_text = true;
                x.i = end;
                continue;
            }
            if (x.startsWith("<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, x.s, x.i + 9, "]]>") orelse return error.Invalid;
                try text.appendSlice(x.a, x.s[x.i + 9 .. end]);
                have_text = true;
                x.i = end + 3;
                continue;
            }
            if (have_text) {
                try x.count();
                try out.append(x.a, .{ .text = try text.toOwnedSlice(x.a) });
                have_text = false;
            }
            if (x.startsWith("</")) {
                x.i += 2;
                const n = try x.name();
                x.skipWs();
                if (x.i >= x.s.len or x.s[x.i] != '>') return error.Invalid;
                x.i += 1;
                if (close == null or !std.mem.eql(u8, n, close.?)) return error.Invalid;
                return;
            }
            if (x.startsWith("<!--")) {
                const end = std.mem.indexOfPos(u8, x.s, x.i + 4, "-->") orelse return error.Invalid;
                x.i = end + 3;
                try x.count();
                try out.append(x.a, .other);
                continue;
            }
            if (x.startsWith("<?")) {
                const end = std.mem.indexOfPos(u8, x.s, x.i + 2, "?>") orelse return error.Invalid;
                x.i = end + 2;
                try x.count();
                try out.append(x.a, .other);
                continue;
            }
            if (x.startsWith("<!")) return error.Invalid; // DTDs are refused
            try x.count();
            try out.append(x.a, try x.element());
        }
        if (have_text) {
            try x.count();
            try out.append(x.a, .{ .text = try text.toOwnedSlice(x.a) });
        }
    }

    fn element(x: *Xml) XmlError!Node {
        x.i += 1;
        const n = try x.name();
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            const before = x.i;
            x.skipWs();
            if (x.i >= x.s.len) return error.Invalid;
            if (x.startsWith("/>")) {
                x.i += 2;
                return .{ .element = .{ .name = n, .attrs = try attrs.toOwnedSlice(x.a), .content = null, .text_only = true } };
            }
            if (x.s[x.i] == '>') {
                x.i += 1;
                break;
            }
            if (before == x.i) return error.Invalid; // attributes need whitespace
            const an = try x.name();
            x.skipWs();
            if (x.i >= x.s.len or x.s[x.i] != '=') return error.Invalid;
            x.i += 1;
            x.skipWs();
            if (x.i >= x.s.len or (x.s[x.i] != '"' and x.s[x.i] != '\'')) return error.Invalid;
            const q = x.s[x.i];
            const end = std.mem.indexOfScalarPos(u8, x.s, x.i + 1, q) orelse return error.Invalid;
            const v = try x.decode(x.s[x.i + 1 .. end], true);
            x.i = end + 1;
            for (attrs.items) |a| if (std.mem.eql(u8, a.name, an)) return error.Invalid;
            try attrs.append(x.a, .{ .name = an, .value = v });
        }
        var kids: std.ArrayList(Node) = .empty;
        try x.children(n, &kids);
        var text_only = true;
        var content: ?[]u8 = null;
        for (kids.items) |k| switch (k) {
            .text => |t| content = content orelse t,
            else => text_only = false,
        };
        return .{ .element = .{ .name = n, .attrs = try attrs.toOwnedSlice(x.a), .content = content, .text_only = text_only } };
    }
};

/// Parse the context that follows the marker (`<appshots>{context}</appshots>`) into
/// its top-level nodes, allocated in `arena`. Null when malformed or over budget.
pub fn parseContext(arena: Allocator, context: []const u8) ?[]Node {
    if (context.len > 4 * 1024 * 1024) return null;
    var x: Xml = .{ .a = arena, .s = context, .nodes = 1 };
    var out: std.ArrayList(Node) = .empty;
    x.children(null, &out) catch return null;
    return out.items;
}

/// The context after the marker, without an older host's attachment trailer.
fn contextOf(text: []const u8) ?[]const u8 {
    const marker = "\n\n" ++ context_marker;
    const i = std.mem.indexOf(u8, text, marker) orelse return null;
    const ctx = text[i + marker.len ..];
    const end = std.mem.indexOf(u8, ctx, "\n\nAttached images (local files") orelse ctx.len;
    return ctx[0..end];
}

/// Display metadata carried by the prompt (`AppshotPresentation`). The observed
/// accessibility payload is never returned.
pub const Presentation = struct {
    path: []const u8,
    app_name: []const u8,
    window_title: ?[]const u8 = null,
    bundle_identifier: ?[]const u8 = null,

    pub fn title(self: Presentation) []const u8 {
        if (self.window_title) |t| if (trimUnicode(t).len > 0) return t;
        return self.app_name;
    }
};

/// `presentations`: image path → presentation (allocated in `arena`).
pub fn presentations(arena: Allocator, text: []const u8) Allocator.Error![]Presentation {
    const ctx = contextOf(text) orelse return &.{};
    const nodes = parseContext(arena, ctx) orelse return &.{};
    var out: std.ArrayList(Presentation) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (nodes) |node| {
        if (node != .element) continue;
        const e = node.element;
        if (!std.mem.eql(u8, e.name, "appshot") or !e.text_only) continue;
        const path = node.attr("image") orelse continue;
        const app = node.attr("app") orelse continue;
        var dup = false;
        for (seen.items) |s| dup = dup or std.mem.eql(u8, s, path);
        if (dup) {
            var i: usize = 0;
            while (i < out.items.len) {
                if (std.mem.eql(u8, out.items[i].path, path)) _ = out.orderedRemove(i) else i += 1;
            }
            continue;
        }
        try seen.append(arena, path);
        if (path.len == 0 or trimUnicode(app).len == 0) continue;
        try out.append(arena, .{
            .path = path,
            .app_name = try takeChars(arena, app, 200),
            .window_title = if (node.attr("window-title")) |t| try takeChars(arena, t, 512) else null,
            .bundle_identifier = node.attr("bundle-identifier"),
        });
    }
    return out.items;
}

pub fn presentationFor(list: []const Presentation, path: []const u8) ?Presentation {
    for (list) |p| if (std.mem.eql(u8, p.path, path)) return p;
    return null;
}

// ---------------------------------------------------------------------------------------
// Queue-edit restore (`restore_queued_appshots`)
// ---------------------------------------------------------------------------------------

pub const Restored = struct {
    ordinary: std.ArrayList(att.Staged) = .empty,
    shots: std.ArrayList(Captured) = .empty,

    pub fn deinit(self: *Restored, gpa: Allocator, app: ?*App) void {
        for (self.ordinary.items) |*s| {
            gpa.free(s.name);
            s.blob.release();
            if (s.image) |r| releaseImg(app, r);
        }
        self.ordinary.deinit(gpa);
        for (self.shots.items) |*s| s.deinit(gpa, app);
        self.shots.deinit(gpa);
    }
};

fn parseU32Strict(s: []const u8) ?u32 {
    const digits = if (s.len > 0 and s[0] == '+') s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |d| if (!std.ascii.isDigit(d)) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// Restore the serialized Appshots of a queued message onto its loaded images
/// (`attachments`, aligned with `paths`; cloned, never consumed). Malformed or
/// unmatched metadata is `error.Invalid` (`restore_invalid_message`).
pub fn restoreQueued(gpa: Allocator, io: std.Io, text: []const u8, paths: []const []const u8, attachments: []const att.Staged) (Allocator.Error || error{Invalid})!Restored {
    var out: Restored = .{};
    errdefer out.deinit(gpa, null);
    const marker = "\n\n" ++ context_marker;
    if (std.mem.indexOf(u8, text, marker) == null) {
        for (attachments) |*a| try out.ordinary.append(gpa, try a.clone(gpa));
        return out;
    }
    const ctx_full = text[std.mem.indexOf(u8, text, marker).? + marker.len ..];
    if (paths.len != attachments.len or ctx_full.len > 4 * 1024 * 1024) return error.Invalid;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = parseContext(arena, contextOf(text).?) orelse return error.Invalid;
    const used = try arena.alloc(bool, attachments.len);
    @memset(used, false);
    for (nodes) |node| {
        switch (node) {
            .text => |t| if (trimUnicode(t).len == 0) continue else return error.Invalid,
            .other => return error.Invalid,
            .element => {},
        }
        const e = node.element;
        if (!std.mem.eql(u8, e.name, "appshot") or !e.text_only) return error.Invalid;
        const image = node.attr("image") orelse return error.Invalid;
        var index: ?usize = null;
        for (paths, 0..) |p, i| if (std.mem.eql(u8, p, image)) {
            index = i;
            break;
        };
        const ix = index orelse return error.Invalid;
        if (used[ix]) return error.Invalid;
        used[ix] = true;
        const app = node.attr("app") orelse return error.Invalid;
        const format = parseU32Strict(node.attr("accessibility-format") orelse return error.Invalid) orelse return error.Invalid;
        const trunc_s = node.attr("truncated") orelse return error.Invalid;
        const truncated = if (std.mem.eql(u8, trunc_s, "true")) true else if (std.mem.eql(u8, trunc_s, "false")) false else return error.Invalid;
        var content: []const u8 = e.content orelse "";
        if (std.mem.startsWith(u8, content, "\n")) content = content[1..];
        if (std.mem.endsWith(u8, content, "\n")) content = content[0 .. content.len - 1];

        var screenshot = try attachments[ix].clone(gpa);
        // Older captures may hold backing-surface padding: normalize the bytes too,
        // keeping the attachment id.
        if (png.dimensions(screenshot.bytes()) != null) {
            var msg: ?[]u8 = null;
            const trimmed = png.trimPadding(gpa, screenshot.bytes(), &msg) catch |err| {
                if (msg) |m| gpa.free(m);
                gpa.free(screenshot.name);
                screenshot.blob.release();
                if (screenshot.image) |r| r.release();
                return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
            };
            if (trimmed) |t| {
                screenshot.blob.release();
                screenshot.blob = att.Blob.create(gpa, t) catch |err| {
                    gpa.free(t);
                    return err;
                };
                // The old preview no longer matches the bytes.
                if (screenshot.image) |r| r.release();
                screenshot.image = null;
                if (zpui.image.decode(gpa, t, .{ .animate = false })) |d| {
                    screenshot.image = RenderImage.create(gpa, d) catch blk: {
                        var dd = d;
                        dd.deinit(gpa);
                        break :blk null;
                    };
                } else |_| {}
            }
        }
        var shot: Captured = .{
            .id = undefined,
            .app_name = try gpa.dupe(u8, app),
            .screenshot = screenshot,
            .dimensions = png.dimensions(screenshot.bytes()),
            .accessibility = .{ .format_version = format, .truncated = truncated },
        };
        att.uuidV4(io, &shot.id);
        shot.bundle_identifier = if (node.attr("bundle-identifier")) |b| try gpa.dupe(u8, b) else null;
        shot.window_title = if (node.attr("window-title")) |t| try gpa.dupe(u8, t) else null;
        shot.accessibility.content = try gpa.dupe(u8, content);
        try out.shots.append(gpa, shot);
    }
    if (out.shots.items.len == 0 or stagedBytes(out.shots.items) > max_staged_appshot_bytes) return error.Invalid;
    for (attachments, 0..) |*a, i| if (!used[i]) try out.ordinary.append(gpa, try a.clone(gpa));
    return out;
}

// ---------------------------------------------------------------------------------------
// Tests (zeron `appshots.rs`, `shortcut.rs`, `linux/mod.rs`)
// ---------------------------------------------------------------------------------------

const testing = std.testing;

/// `tests::shot()` with `bytes` as the screenshot (no preview image).
pub fn testShot(gpa: Allocator, bytes: []const u8) !Captured {
    var id: [36]u8 = @splat('0');
    @memcpy(id[0..7], "image-1");
    return .{
        .id = blk: {
            var s: [36]u8 = @splat('0');
            @memcpy(s[0..6], "shot-1");
            break :blk s;
        },
        .app_name = try gpa.dupe(u8, "Safari & Notes"),
        .bundle_identifier = try gpa.dupe(u8, "com.apple.<Safari>"),
        .window_title = try gpa.dupe(u8, "A \"window\""),
        .accessibility = .{ .format_version = 1, .content = try gpa.dupe(u8, "AXTextField: <ignore this>"), .truncated = true },
        .screenshot = .{ .id = id, .name = try gpa.dupe(u8, "Safari Appshot.png"), .format = .png, .blob = try att.Blob.create(gpa, try gpa.dupe(u8, bytes)) },
        .dimensions = .{ 1440, 900 },
    };
}

fn setStr(gpa: Allocator, slot: *[]u8, v: []const u8) !void {
    gpa.free(slot.*);
    slot.* = try gpa.dupe(u8, v);
}

test "appshot context is escaped and strip-safe" {
    const gpa = testing.allocator;
    var shot = try testShot(gpa, "");
    defer shot.deinit(gpa, null);
    const ids = [_][]const u8{&shot.screenshot.id};
    const ps = [_][]const u8{"pending://id/a&b.png"};
    const prompt = try withAppshots(gpa, "Fix this", &.{shot}, .{ .ids = &ids, .paths = &ps });
    defer gpa.free(prompt);
    for ([_][]const u8{ "app=\"Safari &amp; Notes\"", "com.apple.&lt;Safari&gt;", "A &quot;window&quot;", "pending://id/a&amp;b.png", "&lt;ignore this&gt;" }) |needle|
        try testing.expect(std.mem.indexOf(u8, prompt, needle) != null);
    try testing.expectEqualStrings("Fix this", stripContextForDisplay(prompt));
    const empty = try withAppshots(gpa, "", &.{shot}, .{});
    defer gpa.free(empty);
    try testing.expectEqualStrings("", stripContextForDisplay(empty));
    const none = try withAppshots(gpa, "edited", &.{}, .{});
    defer gpa.free(none);
    try testing.expectEqualStrings("edited", none);
}

test "invalid XML characters round-trip through the queue and presentation" {
    const gpa = testing.allocator;
    const io = testing.io;
    var shot = try testShot(gpa, "");
    defer shot.deinit(gpa, null);
    try setStr(gpa, &shot.app_name, "App\x00 & Notes");
    try setStr(gpa, &shot.window_title.?, "Title\x1b\u{fffe}\u{ffff}");
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    for (0..32) |c| try content.append(gpa, @intCast(c));
    try content.appendSlice(gpa, "valid\t\r\n<&>é🦀\x7f\u{85}\u{10000}");
    try setStr(gpa, &shot.accessibility.content, content.items);
    const path = "/host/image.png";
    const ids = [_][]const u8{&shot.screenshot.id};
    const encoded = try withAppshots(gpa, "inspect", &.{shot}, .{ .ids = &ids, .paths = &.{path} });
    defer gpa.free(encoded);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const pres = try presentations(arena.allocator(), encoded);
    const p = presentationFor(pres, path).?;
    try testing.expectEqualStrings("App\u{fffd} & Notes", p.app_name);
    try testing.expectEqualStrings("Title\u{fffd}\u{fffd}\u{fffd}", p.window_title.?);

    var restored = try restoreQueued(gpa, io, encoded, &.{path}, &.{shot.screenshot});
    defer restored.deinit(gpa, null);
    try testing.expectEqualStrings("App\u{fffd} & Notes", restored.shots.items[0].app_name);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (0..9) |_| try expected.appendSlice(gpa, "\u{fffd}");
    try expected.appendSlice(gpa, "\t\n");
    for (0..2) |_| try expected.appendSlice(gpa, "\u{fffd}");
    try expected.appendSlice(gpa, "\r");
    for (0..18) |_| try expected.appendSlice(gpa, "\u{fffd}");
    try expected.appendSlice(gpa, "valid\t\r\n<&>é🦀\x7f\u{85}\u{10000}");
    try testing.expectEqualStrings(expected.items, restored.shots.items[0].accessibility.content);
}

test "queued edit round trip keeps context and rebinds uploaded images" {
    const gpa = testing.allocator;
    const io = testing.io;
    var original = try testShot(gpa, "");
    defer original.deinit(gpa, null);
    try setStr(gpa, &original.window_title.?, "Line 1\nLine 2\t&\"");
    try setStr(gpa, &original.accessibility.content, "\n<&secret>\r\n  text\n");
    var ordinary = try original.screenshot.clone(gpa);
    defer {
        gpa.free(ordinary.name);
        ordinary.blob.release();
    }
    ordinary.id = @splat('o');
    const paths = [_][]const u8{ "/host/ordinary.png", "/host/a&b.png" };
    const ids = [_][]const u8{&original.screenshot.id};
    const encoded = try withAppshots(gpa, "inspect", &.{original}, .{ .ids = &ids, .paths = paths[1..] });
    defer gpa.free(encoded);
    const legacy = try att.withAttachments(gpa, encoded, &paths);
    defer gpa.free(legacy);
    for ([_][]const u8{ encoded, legacy }) |text| {
        var r = try restoreQueued(gpa, io, text, &paths, &.{ ordinary, original.screenshot });
        defer r.deinit(gpa, null);
        try testing.expectEqual(@as(usize, 1), r.ordinary.items.len);
        try testing.expectEqualSlices(u8, &ordinary.id, &r.ordinary.items[0].id);
        try testing.expectEqual(@as(usize, 1), r.shots.items.len);
        const s = &r.shots.items[0];
        try testing.expectEqualStrings(original.accessibility.content, s.accessibility.content);
        try testing.expect(s.accessibility.truncated);
        try testing.expectEqualStrings(original.window_title.?, s.window_title.?);
        try testing.expectEqualStrings(original.app_name, s.app_name);
        const rid = [_][]const u8{&s.screenshot.id};
        const rebound = try withAppshots(gpa, "edited", r.shots.items, .{ .ids = &rid, .paths = &.{"/new/renamed.png"} });
        defer gpa.free(rebound);
        try testing.expect(std.mem.indexOf(u8, rebound, "image=\"/new/renamed.png\"") != null);
        try testing.expect(std.mem.indexOf(u8, rebound, "/host/") == null);
        try testing.expectEqualStrings("edited", stripContextForDisplay(rebound));
    }
}

test "queued edit rejects invalid or unmatched context without losing images" {
    const gpa = testing.allocator;
    const io = testing.io;
    var original = try testShot(gpa, "");
    defer original.deinit(gpa, null);
    const paths = [_][]const u8{"/host/image.png"};
    const ids = [_][]const u8{&original.screenshot.id};
    const valid = try withAppshots(gpa, "", &.{original}, .{ .ids = &ids, .paths = &paths });
    defer gpa.free(valid);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tail = valid[std.mem.indexOf(u8, valid, context_marker).? + context_marker.len ..];
    const invalid = [_][]const u8{
        try std.mem.replaceOwned(u8, a, valid, "/host/image.png", "/missing.png"),
        try std.mem.replaceOwned(u8, a, valid, "</appshot>", "</broken>"),
        try std.mem.replaceOwned(u8, a, valid, "<appshot ", "<other "),
        try std.fmt.allocPrint(a, "{s}\n{s}", .{ valid, tail }),
    };
    for (invalid) |text| try testing.expectError(error.Invalid, restoreQueued(gpa, io, text, &paths, &.{original.screenshot}));
    var plain = try restoreQueued(gpa, io, "plain", &paths, &.{original.screenshot});
    defer plain.deinit(gpa, null);
    try testing.expectEqual(@as(usize, 1), plain.ordinary.items.len);
    try testing.expectEqual(@as(usize, 0), plain.shots.items.len);
}

test "restored queue appshots trim legacy padding without changing attachment identity" {
    const gpa = testing.allocator;
    const io = testing.io;
    const pixels = [_]u8{ 0, 0, 0, 0, 44, 55, 66, 255, 0, 0, 0, 0 };
    const fixture = try png.fixturePng(gpa, 3, 1, &pixels, 8);
    defer gpa.free(fixture);
    var original = try testShot(gpa, fixture);
    defer original.deinit(gpa, null);
    const path = "/host/legacy.png";
    const ids = [_][]const u8{&original.screenshot.id};
    const text = try withAppshots(gpa, "edit", &.{original}, .{ .ids = &ids, .paths = &.{path} });
    defer gpa.free(text);
    var r = try restoreQueued(gpa, io, text, &.{path}, &.{original.screenshot});
    defer r.deinit(gpa, null);
    try testing.expectEqualSlices(u8, &original.screenshot.id, &r.shots.items[0].screenshot.id);
    try testing.expectEqual([2]u32{ 1, 1 }, r.shots.items[0].dimensions.?);
    try testing.expectEqual([2]u32{ 3, 1 }, png.dimensions(original.bytes()).?);
}

test "presentations drop duplicated paths and keep display metadata only" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "hi\n\n" ++ context_marker ++
        "\n<appshot app=\"Safari\" window-title=\"  \" image=\"/a.png\" accessibility-format=\"1\" truncated=\"false\">\nsecret\n</appshot>" ++
        "\n<appshot app=\"X\" image=\"/b.png\" accessibility-format=\"1\" truncated=\"false\">\n\n</appshot>" ++
        "\n<appshot app=\"Y\" image=\"/b.png\" accessibility-format=\"1\" truncated=\"false\">\n\n</appshot>";
    const pres = try presentations(a, text);
    try testing.expectEqual(@as(usize, 1), pres.len);
    try testing.expectEqualStrings("Safari", pres[0].title());
    try testing.expectEqual(@as(usize, 0), (try presentations(a, "hi\n\n" ++ context_marker ++ "\n<appshot")).len);
}

test "app names are bounded and safe before staging" {
    const gpa = testing.allocator;
    const a = try safeAppName(gpa, "Bad\nApp/../../name");
    defer gpa.free(a);
    try testing.expectEqualStrings("Bad-App-..-..-name", a);
    const b = try safeAppName(gpa, "\x00\n");
    defer gpa.free(b);
    try testing.expectEqualStrings("Application", b);
}

test "global shortcuts require a supported modified key" {
    var kb: [32]u8 = undefined;
    for ([_][]const u8{ "a", "shift-a", "fn-a", "ctrl-mystery", "ctrl-f25" }) |c| try testing.expect(parseShortcutOn(c, false, &kb) == null);
    for ([_][]const u8{ "ctrl-alt-space", "mod-shift-k", "alt-f12", "ctrl-pageup" }) |c| try testing.expect(parseShortcutOn(c, false, &kb) != null);
    const linux_default = parseShortcutOn("mod-alt-space", false, &kb).?;
    try testing.expect(linux_default.control and linux_default.alt and !linux_default.platform);
    try testing.expectEqualStrings("space", linux_default.key);
    const mac = parseShortcutOn("mod-alt-space", true, &kb).?;
    try testing.expect(mac.platform and !mac.control);
}

test "wayland capabilities explain picker and system shortcut fallbacks" {
    const c: Capabilities = .{ .system = .linux_wayland, .global_hotkey = .setup_required, .window_capture = .user_selection, .application_text = .ready, .target = .portal_window_picker };
    try testing.expect(std.mem.indexOf(u8, shortcutDescription(c), "zeron appshot") != null);
    try testing.expect(std.mem.indexOf(u8, captureDescription(c), "each capture") != null);
    try testing.expect(isReady(c.window_capture));
    try testing.expectEqualStrings("Select window", badge(.user_selection));
}

test "activation path stays inside the data directory" {
    const p = try activationSocketPath(testing.allocator, "/tmp/zeron-test");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/tmp/zeron-test/appshot-activation.sock", p);
}

test {
    _ = png;
}
