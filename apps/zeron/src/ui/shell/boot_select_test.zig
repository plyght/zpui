//! Boot landing (zeron `Shell::boot_select_chat`, crates/ui/src/shell/tabs.rs):
//! once the first chats frame syncs, the shell opens the most recently active
//! visible chat (`overview_chats().first()`): archived chats, sub-chats and chats
//! of a deleted space never win; a manual selection (or an explicit canvas
//! target) wins over it; with no visible chat the new-session canvas stays and
//! a later frame that brings one still lands. The first landing replaces the
//! boot canvas in the Back history. Headless, on zpui's TestPlatform with no
//! engine (frames are fed straight into the workspace store).

const std = @import("std");
const json = std.json;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const engine_mod = @import("zeron_engine");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const shell_mod = @import("shell.zig");

const testing = std.testing;
const App = zpui.App;
const Entity = zpui.Entity;
const protocol = engine_mod.protocol;

const Harness = struct {
    app: *App,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = testing.io;
        const app = try App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, .{ .gpa = gpa });
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1320, .height = 880 } },
        }, shell_mod.Shell, shell_mod.Shell.init, .{ state, null, true });
        return .{ .app = app, .state = state, .handle = handle };
    }

    fn deinit(h: *Harness) void {
        h.state.release(h.app);
        h.app.deinit();
    }

    fn ws(h: *Harness) Entity(model.WorkspaceStore) {
        return h.state.read(h.app).workspace;
    }

    fn selected(h: *Harness) ?[]const u8 {
        return h.ws().read(h.app).selected_chat;
    }

    fn shell(h: *Harness) *const shell_mod.Shell {
        return h.handle.rootView(h.app).?.read(h.app);
    }

    fn spaces(h: *Harness, bytes: []const u8) !void {
        const frame = try json.parseFromSlice([]protocol.Space, testing.allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        h.ws().update(h.app, model.WorkspaceStore.applySpaces, .{frame});
        h.app.runUntilParked();
    }

    fn chats(h: *Harness, bytes: []const u8) !void {
        const frame = try json.parseFromSlice([]protocol.Chat, testing.allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        h.ws().update(h.app, model.WorkspaceStore.applyChats, .{frame});
        h.app.runUntilParked();
    }

    fn select(h: *Harness, id: ?[]const u8) void {
        h.ws().update(h.app, model.WorkspaceStore.selectChat, .{id});
        h.app.runUntilParked();
    }
};

fn expectSelected(h: *Harness, want: ?[]const u8) !void {
    const got = h.selected();
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else try testing.expect(got == null);
}

const space_json =
    \\[{"id":"sp","deviceId":"dev","path":"/w/app","createdAt":"2026-01-01T00:00:00Z"}]
;

// Newest first by recency: an archived chat, a chat of a deleted space, a
// sub-chat, then the visible winner and an older visible chat.
const chats_json = "[" ++
    \\{"id":"older","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","lastMessageAt":"2026-02-01T00:00:00Z"},
++
    \\{"id":"recent","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","lastMessageAt":"2026-03-01T00:00:00Z"},
++
    \\{"id":"child","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","parentChatId":"recent","lastMessageAt":"2026-04-01T00:00:00Z"},
++
    \\{"id":"orphan","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"gone","lastMessageAt":"2026-05-01T00:00:00Z"},
++
    \\{"id":"archived","deviceId":"dev","archived":true,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","lastMessageAt":"2026-06-01T00:00:00Z"}
++ "]";

test "boot landing: the most recent visible chat once chats sync, not before; Back stays disabled" {
    var h = try Harness.init();
    defer h.deinit();
    try h.spaces(space_json);
    // No chats frame yet: the canvas.
    try expectSelected(&h, null);
    try h.chats(chats_json);
    // The archived, deleted-space and sub-chat rows are newer but not visible.
    try expectSelected(&h, "recent");
    try testing.expect(h.ws().read(h.app).auto_selected);
    // The landing replaced the untouched boot canvas: no dead Back target.
    try testing.expect(!h.shell().canBack());

    // A later frame (a newer chat appears) never re-lands; the user's pick stands.
    h.select("older");
    try testing.expect(h.shell().canBack());
    try h.chats("[" ++
        \\{"id":"older","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","lastMessageAt":"2026-02-01T00:00:00Z"},
    ++
        \\{"id":"newest","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","lastMessageAt":"2026-07-01T00:00:00Z"}
    ++ "]");
    try expectSelected(&h, "older");
    // Back on the canvas (the user's ⌘N), a later frame does not land either.
    h.select(null);
    try h.chats("[" ++
        \\{"id":"newest","deviceId":"dev","archived":false,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp","lastMessageAt":"2026-07-01T00:00:00Z"}
    ++ "]");
    try expectSelected(&h, null);
}

test "boot landing: no chats keeps the canvas until a frame brings one; a project-less chat lands" {
    var h = try Harness.init();
    defer h.deinit();
    try h.spaces(space_json);
    try h.chats("[]");
    try expectSelected(&h, null);
    try testing.expect(!h.ws().read(h.app).auto_selected);
    // Only an archived chat: still the canvas.
    try h.chats("[" ++
        \\{"id":"archived","deviceId":"dev","archived":true,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp"}
    ++ "]");
    try expectSelected(&h, null);
    // Project-less sessions are first-class rows.
    try h.chats("[" ++
        \\{"id":"archived","deviceId":"dev","archived":true,"createdAt":"2026-01-01T00:00:00Z","spaceId":"sp"},
    ++
        \\{"id":"loose","deviceId":"dev","archived":false,"createdAt":"2026-01-02T00:00:00Z"}
    ++ "]");
    try expectSelected(&h, "loose");
}

test "boot landing: a manual pick or an explicit canvas target before sync wins" {
    {
        var h = try Harness.init();
        defer h.deinit();
        try h.spaces(space_json);
        // `pick_space` / `ZERON_OPEN_ROUTE=new`: a late chats frame must not land.
        h.ws().update(h.app, model.WorkspaceStore.suppressBootSelect, .{});
        try h.chats(chats_json);
        try expectSelected(&h, null);
    }
    {
        var h = try Harness.init();
        defer h.deinit();
        try h.spaces(space_json);
        // A deep link / sidebar pick before the frame: the selection stands.
        h.select("older");
        try h.chats(chats_json);
        try expectSelected(&h, "older");
    }
}
