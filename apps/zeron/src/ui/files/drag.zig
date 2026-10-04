//! Workspace path drags out of the Files surface (zeron `files/mod.rs`
//! `WorkspacePathDrag` / `WorkspacePathDragGhost`, `files/drag.rs`).
//!
//! Tree and search rows drag a workspace-relative path. Dropped on the
//! conversation (`chat_dropzone`) it inserts a file reference into that
//! chat's composer; dropped back on the tree (tree rows only) it moves the
//! entry into the folder under the pointer (`destinationPath`), with
//! 650 ms hover-to-expand and edge autoscroll while the pointer rests near
//! the viewport edges (`edgeScrollSpeed`).
//!
//! The payload stays relative (the composer may target a remote device) and
//! carries an `owner` token — the chat whose explorer started it — so a drag
//! that outlives a session switch is dropped (`attach_workspace_drag`).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const icons = @import("icons.zig");
const model = @import("model.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;

/// Where the drag started (`WorkspacePathSource`).
pub const Source = enum { tree, search, file_tab };

/// `WorkspacePathDrag`: copied by value into the active drag.
pub const WorkspacePathDrag = struct {
    /// The originating chat (`ownerOf(chat_id)`); 0 = unknown origin (never attaches).
    owner: u64 = 0,
    source: Source = .search,
    is_directory: bool = false,
    path_buf: [1024]u8 = undefined,
    path_len: u16 = 0,
    revision_buf: [128]u8 = undefined,
    /// 0 = no revision (`None`).
    revision_len: u8 = 0,

    /// Null when `path` / `revision` don't fit (such a row simply doesn't drag).
    pub fn init(owner: u64, source: Source, rel: []const u8, is_directory: bool, rev: ?[]const u8) ?WorkspacePathDrag {
        if (rel.len == 0 or rel.len > 1024) return null;
        var d: WorkspacePathDrag = .{ .owner = owner, .source = source, .is_directory = is_directory };
        @memcpy(d.path_buf[0..rel.len], rel);
        d.path_len = @intCast(rel.len);
        if (rev) |r| {
            if (r.len > d.revision_buf.len) return null;
            @memcpy(d.revision_buf[0..r.len], r);
            d.revision_len = @intCast(r.len);
        }
        return d;
    }

    pub fn path(self: *const WorkspacePathDrag) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn revision(self: *const WorkspacePathDrag) ?[]const u8 {
        return if (self.revision_len == 0) null else self.revision_buf[0..self.revision_len];
    }

    /// The ghost's label: the last path component.
    pub fn title(self: *const WorkspacePathDrag) []const u8 {
        const p = std.mem.trimEnd(u8, self.path(), "/");
        return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
    }

    /// The drag started in chat `chat_id`'s explorer.
    pub fn belongsTo(self: *const WorkspacePathDrag, chat_id: []const u8) bool {
        return self.owner != 0 and self.owner == ownerOf(chat_id);
    }
};

/// The origin token for chat `chat_id`'s Files surfaces.
pub fn ownerOf(chat_id: []const u8) u64 {
    const h = std.hash.Wyhash.hash(0x57_50_44_52, chat_id);
    return if (h == 0) 1 else h;
}

/// `WorkspacePathDragGhost`: the raised 24px chip under the pointer (same
/// surface, hairline, type scale and opacity as surface tabs).
pub const Ghost = struct {
    payload: WorkspacePathDrag,

    pub fn render(self: *Ghost, _: *Window, cx: *Context(Ghost)) zpui.Div {
        const theme = ui.theme.get(cx);
        const name = self.payload.title();
        return div().h(px(24)).maxW(px(220)).px(px(8)).flex().itemsCenter().gap(px(5)).rounded(px(6))
            .bg(theme.surface_raised).border1().borderColor(theme.border_strong)
            .fontFamily(theme.font_sans).textSize(px(11.5)).textColor(theme.text).opacity(0.85)
            .child(icons.entryIcon(if (self.payload.is_directory) .directory else .file, name, theme, 14))
            .child(div().minW0().truncate().whitespaceNowrap().child(name));
    }
};

/// `workspace_path_drag_ghost`.
pub fn buildGhost(payload: *const WorkspacePathDrag, _: zpui.Point(f32), _: *Window, app: *App) Entity(Ghost) {
    return app.new(Ghost, .{ .payload = payload.* }) catch @panic("OOM");
}

/// `destination_path`: where `source` lands when dropped on `directory`
/// ("" = the workspace root). Null for a no-op (same parent) or a folder
/// dropped into itself / a descendant. The server stays authoritative for
/// existence, permissions and collisions.
pub fn destinationPath(a: std.mem.Allocator, source: []const u8, directory: []const u8, is_directory: bool) ?[]const u8 {
    if (source.len == 0) return null;
    if (std.mem.eql(u8, model.parentPath(source), directory)) return null;
    if (is_directory and containsPath(source, directory)) return null;
    const name = model.baseName(source);
    if (directory.len == 0) return a.dupe(u8, name) catch null;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ directory, name }) catch null;
}

/// `mutations::contains_path`: `candidate` is `ancestor` or below it.
pub fn containsPath(ancestor: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, ancestor, candidate)) return true;
    return candidate.len > ancestor.len and std.mem.startsWith(u8, candidate, ancestor) and candidate[ancestor.len] == '/';
}

/// `edge_scroll_speed`: px/s toward the nearer edge inside a 28px band
/// (negative = up), zero outside the viewport.
pub fn edgeScrollSpeed(y: f32, top: f32, bottom: f32) f32 {
    if (y < top or y > bottom or bottom <= top) return 0;
    const band = @min(28.0, (bottom - top) / 2.0);
    if (y < top + band) return -540.0 * (1.0 - (y - top) / band);
    if (y > bottom - band) return 540.0 * (1.0 - (bottom - y) / band);
    return 0;
}

/// Hover-to-expand delay over a collapsed folder.
pub const hover_expand_ns: u64 = 650 * std.time.ns_per_ms;
/// The drag tick (autoscroll + hover expand).
pub const tick_ns: u64 = 16 * std.time.ns_per_ms;
/// The scrollbar rail at the tree's right edge is not a drop target.
pub const rail_width: f32 = 12;

// ---- tests -----------------------------------------------------------------------------

const testing = std.testing;

test "autoscroll is bounded and stops outside the viewport" {
    try testing.expectEqual(@as(f32, -540), edgeScrollSpeed(100, 100, 500));
    try testing.expectEqual(@as(f32, 540), edgeScrollSpeed(500, 100, 500));
    try testing.expectEqual(@as(f32, 0), edgeScrollSpeed(300, 100, 500));
    try testing.expectEqual(@as(f32, 0), edgeScrollSpeed(99, 100, 500));
    try testing.expect(edgeScrollSpeed(486, 100, 500) > 0);
}

test "tree drop resolves parent, root and descendants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("b/file", destinationPath(a, "a/file", "b", false).?);
    try testing.expectEqualStrings("file", destinationPath(a, "a/file", "", false).?);
    try testing.expect(destinationPath(a, "a/file", "a", false) == null);
    try testing.expect(destinationPath(a, "a", "a/sub", true) == null);
    try testing.expect(destinationPath(a, "a", "a", true) == null);
    try testing.expectEqualStrings("ab/a", destinationPath(a, "a", "ab", true).?);
    // A root-level entry dropped on the root is a no-op (Rust: parent_path("a") == Some("")).
    try testing.expect(destinationPath(a, "a.txt", "", false) == null);
}

test "payload keeps the relative path, title and origin" {
    const d = WorkspacePathDrag.init(ownerOf("chat-a"), .tree, "src/lib/", true, "r1").?;
    try testing.expectEqualStrings("src/lib/", d.path());
    try testing.expectEqualStrings("lib", d.title());
    try testing.expectEqualStrings("r1", d.revision().?);
    try testing.expect(d.belongsTo("chat-a"));
    try testing.expect(!d.belongsTo("chat-b"));
    const unknown = WorkspacePathDrag.init(0, .search, "a", false, null).?;
    try testing.expect(!unknown.belongsTo("chat-a"));
    try testing.expect(unknown.revision() == null);
}
