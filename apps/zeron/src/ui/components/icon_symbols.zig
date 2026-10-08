//! SF Symbols for zeron's control icons (macOS; re-exported as `icon.symbols`).
//!
//! With Settings → Appearance → Use SF Symbols on (the default; `model.sf_symbols`),
//! control icons draw as the SF Symbol in `table` instead of their SVG.
//! `icon.installSystemSymbols(app)` registers `resolve` as zpui's svg → symbol
//! resolver, so every `svg()` of an `icons/*.svg` path switches, including call sites
//! that build the svg themselves: nothing at a call site changes, and layout boxes stay
//! the same (the symbol is centered in, and fit to, the icon's box). A symbol the OS
//! lacks falls back to its next candidate, then to the SVG. Brand marks, file-type
//! glyphs and icons without a good symbol stay SVG (`keep_svg`). docs/SF_SYMBOLS.md
//! documents the table.

const std = @import("std");
const zpui = @import("zpui");
const assets = @import("zeron_assets");
const model = @import("zeron_model");

const Icon = assets.Icon;
const Weight = zpui.system_symbols.Weight;

/// One icon's SF Symbol: candidates in preference order (all in SF Symbols 4, macOS 13,
/// unless a fallback follows), an optional weight, and an optical size factor on
/// the default (`options`).
pub const Spec = struct {
    names: []const []const u8,
    weight: ?Weight = null,
    scale: f32 = 1,
};

const KV = struct { []const u8, Spec };

fn sym(comptime stem: []const u8, comptime names: []const []const u8) KV {
    return .{ "icons/" ++ stem ++ ".svg", .{ .names = names } };
}
fn symScaled(comptime stem: []const u8, comptime names: []const []const u8, comptime scale: f32) KV {
    return .{ "icons/" ++ stem ++ ".svg", .{ .names = names, .scale = scale } };
}

/// zeron icon path → SF Symbol (docs/SF_SYMBOLS.md mirrors this table).
pub const table = std.StaticStringMap(Spec).initComptime(.{
    // Composer + toolbar
    sym("microphone", &.{"mic"}),
    sym("microphone-off", &.{"mic.slash"}),
    sym("phone-hang-up", &.{"phone.down"}),
    sym("fast-tier", &.{"bolt"}),
    sym("fast-tier-bold", &.{"bolt.fill"}),
    sym("paperclip", &.{"paperclip"}),
    sym("queue-paperclip", &.{"paperclip"}),
    sym("queue-send", &.{"arrow.right"}),
    sym("queue-check", &.{"checkmark"}),
    sym("queue-close", &.{"xmark"}),
    symScaled("stop", &.{"stop.fill"}, 0.9),
    sym("return", &.{"return"}),
    sym("command", &.{"command"}),
    sym("keyboard", &.{"keyboard"}),
    sym("key-minimalistic", &.{"key"}),
    sym("tuning", &.{"slider.vertical.3"}),
    sym("settings", &.{"gearshape"}),
    sym("settings-minimalistic", &.{"slider.horizontal.3"}),
    sym("magic-stick-3", &.{"wand.and.stars"}),
    // Appearance + devices
    sym("monitor", &.{"display"}),
    sym("sun", &.{"sun.max"}),
    sym("moon", &.{"moon"}),
    sym("laptop", &.{"laptopcomputer"}),
    sym("smartphone", &.{"iphone"}),
    sym("remote-server", &.{"server.rack"}),
    sym("hard-drive", &.{"internaldrive"}),
    sym("home", &.{"house"}),
    sym("cloud", &.{"cloud"}),
    sym("globe", &.{ "globe.americas", "globe" }),
    sym("global", &.{"globe"}),
    sym("wifi-off", &.{"wifi.slash"}),
    // Sidebar, threads, sessions
    sym("pen-new-square", &.{"square.and.pencil"}),
    sym("pen", &.{"pencil"}),
    sym("pin", &.{"pin"}),
    sym("archive-minimalistic", &.{"archivebox"}),
    sym("archive-up-minimalistic", &.{"tray.and.arrow.up"}),
    sym("trash-bin-minimalistic", &.{"trash"}),
    sym("more-horizontal", &.{"ellipsis"}),
    sym("sort", &.{"line.3.horizontal.decrease"}),
    sym("sort-vertical", &.{"arrow.up.arrow.down"}),
    sym("list", &.{"text.alignleft"}),
    sym("checklist", &.{ "checklist", "list.bullet" }),
    sym("clock-circle", &.{"clock"}),
    sym("calendar", &.{"calendar"}),
    sym("chat-round-line", &.{ "text.bubble", "bubble.left" }),
    sym("bell", &.{"bell"}),
    sym("volume-loud", &.{"speaker.wave.2"}),
    sym("star", &.{"star"}),
    sym("star-bold", &.{"star.fill"}),
    sym("tag", &.{"tag"}),
    sym("eye", &.{"eye"}),
    sym("eye-closed", &.{"eye.slash"}),
    sym("logout-2", &.{"rectangle.portrait.and.arrow.right"}),
    sym("widget", &.{"square.grid.2x2"}),
    sym("gallery", &.{"photo"}),
    // Files + git
    sym("folder", &.{"folder"}),
    sym("folder-with-files", &.{"folder"}),
    sym("file-tree", &.{"list.bullet.indent"}),
    sym("document", &.{"doc"}),
    sym("document-add", &.{"doc.badge.plus"}),
    sym("copy", &.{"doc.on.doc"}),
    sym("floppy-disk", &.{"square.and.arrow.down"}),
    sym("git-branch", &.{"arrow.triangle.branch"}),
    sym("fork", &.{"arrow.triangle.branch"}),
    sym("pull-request", &.{"arrow.triangle.pull"}),
    sym("split-columns", &.{"rectangle.split.2x1"}),
    sym("fold-vertical", &.{ "arrow.down.and.line.horizontal.and.arrow.up", "rectangle.compress.vertical" }),
    sym("terminal", &.{"terminal"}),
    // Navigation
    sym("arrow-left", &.{"arrow.left"}),
    sym("arrow-right", &.{"arrow.right"}),
    sym("arrow-up", &.{"arrow.up"}),
    sym("arrow-down", &.{"arrow.down"}),
    sym("arrow-up-right", &.{"arrow.up.right"}),
    sym("alt-arrow-down", &.{"chevron.down"}),
    sym("alt-arrow-up", &.{"chevron.up"}),
    sym("alt-arrow-left", &.{"chevron.left"}),
    sym("alt-arrow-right", &.{"chevron.right"}),
    sym("expand-arrows", &.{"arrow.up.left.and.arrow.down.right"}),
    sym("collapse-arrows", &.{"arrow.down.right.and.arrow.up.left"}),
    sym("sidebar-minimalistic", &.{"sidebar.right"}),
    sym("sidebar-minimalistic-left", &.{"sidebar.left"}),
    sym("refresh", &.{"arrow.clockwise"}),
    sym("restart", &.{"arrow.counterclockwise"}),
    sym("magnifer", &.{"magnifyingglass"}),
    sym("palette-search", &.{"magnifyingglass"}),
    // Status
    sym("plus", &.{"plus"}),
    sym("add-circle", &.{"plus.circle"}),
    sym("close", &.{"xmark"}),
    sym("close-circle", &.{"xmark.circle"}),
    sym("check", &.{"checkmark"}),
    sym("info-circle", &.{"info.circle"}),
    sym("danger-triangle", &.{"exclamationmark.triangle"}),
    // Project actions
    sym("action-play", &.{"play"}),
    sym("action-test", &.{ "flask", "testtube.2" }),
    sym("action-lint", &.{"text.badge.checkmark"}),
    sym("action-configure", &.{"slider.horizontal.3"}),
    sym("action-build", &.{"shippingbox"}),
    sym("action-debug", &.{"ant"}),
});

/// Icons that stay SVG with SF Symbols on (docs/SF_SYMBOLS.md says why).
pub const keep_svg = [_][]const u8{
    // Brand marks: zeron's logo and the harness marks.
    "zeron-logo",      "claude-mark",       "openai-mark",     "cursor-mark",     "devin-mark",
    "grok-mark",       "hermes-mark",       "pi-mark",         "opencode-mark",   "antigravity-mark",
    // File-type glyphs (transcript badges).
    "file-code",       "file-style",        "file-data",       "file-markdown",   "file-image",
    // No good SF Symbol.
    "project-default", "drag-handle",       "queue-drag-handle", "wrap-text",     "worktree",
    "bot",
    // Linux client-side-decoration captions (never drawn on macOS).
    "window-minimize", "window-maximize",   "window-restore",
};

/// Symbol options for an icon drawn in a `box`-px square: for the usual 16-17 px boxes
/// the point size (0.8 × box) is the neighbouring 13-14 pt text's, so the symbol sits
/// at that text's optical size; regular weight, medium at 12 px and below (where
/// regular strokes thin out next to text); fit to the box so nothing overflows it.
pub fn options(spec: Spec, box: f32) zpui.SystemSymbolOptions {
    const pt = @max(6, @round(box * 0.8 * spec.scale * 2) / 2);
    return .{
        .point_size = pt,
        .weight = spec.weight orelse if (box <= 12) .medium else .regular,
        .scale = .medium,
        .fit = box,
    };
}

/// The SF Symbol for icon `path` in a `box`-px square, or null (SVG).
pub fn symbolFor(path: []const u8, box: f32) ?zpui.system_symbols.Symbol {
    const spec = table.get(path) orelse return null;
    return .{ .names = spec.names, .options = options(spec, box) };
}

/// The zpui resolver: macOS with the setting on, mapped icons only.
pub fn resolve(_: ?*anyopaque, app: *zpui.App, path: []const u8, size: zpui.Size(zpui.Pixels)) ?zpui.system_symbols.Symbol {
    if (!model.sf_symbols.enabled(app)) return null;
    return symbolFor(path, @min(size.width, size.height));
}

pub fn isKept(stem: []const u8) bool {
    for (keep_svg) |k| if (std.mem.eql(u8, k, stem)) return true;
    return false;
}

// ---- tests ----------------------------------------------------------------------

const testing = std.testing;

test "every control icon has an SF Symbol or is deliberately kept as SVG" {
    for (std.enums.values(Icon)) |i| {
        const mapped = table.get(i.path()) != null;
        if (mapped == isKept(i.fileName())) {
            std.debug.print("icon {s}: mapped={} kept={}\n", .{ i.fileName(), mapped, isKept(i.fileName()) });
            return error.TestUnexpectedResult;
        }
    }
    for (table.keys()) |k| try testing.expect(table.get(k).?.names.len > 0);
}

test "symbol options match the neighbouring text and keep the box" {
    const o = options(.{ .names = &.{"folder"} }, 16);
    try testing.expectEqual(@as(f32, 13), o.point_size);
    try testing.expectEqual(Weight.regular, o.weight);
    try testing.expectEqual(@as(f32, 16), o.fit);
    const small = options(.{ .names = &.{"xmark"} }, 12);
    try testing.expectEqual(@as(f32, 9.5), small.point_size);
    try testing.expectEqual(Weight.medium, small.weight);
    try testing.expect(symbolFor("icons/claude-mark.svg", 16) == null);
    try testing.expect(symbolFor("icons/file-code.svg", 16) == null);
    try testing.expectEqualStrings("folder", symbolFor(Icon.folder.path(), 14).?.names[0]);
}

test "the resolver follows the setting (macOS only)" {
    const app = try zpui.App.initTest(testing.allocator);
    defer app.deinit();
    const size: zpui.Size(zpui.Pixels) = .{ .width = zpui.px(16), .height = zpui.px(16) };
    try testing.expectEqual(model.sf_symbols.supported, resolve(null, app, Icon.folder.path(), size) != null);
    model.sf_symbols.set(app, false);
    try testing.expect(resolve(null, app, Icon.folder.path(), size) == null);
}
