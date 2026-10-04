//! Attachments end to end on the headless test platform against an in-process
//! fake engine: an external file drop (zpui `ExternalPaths`, simulated through
//! the TestPlatform's `file_drop` input) on a conversation drop zone stages the
//! image in the composer (chip + thumbnail), a send uploads it with
//! `UploadChunk` / `UploadCommit` (base64, `targetDeviceId` = the chat's
//! device) and the Run carries the committed path both in the prompt trailer
//! (`with_attachments`) and in `attachments` — Rust `Composer::send` +
//! `attachments::upload_attachment`. The echo bubble splits the trailer back
//! into attachments.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const composer_mod = @import("composer.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;
const ComposerView = composer_mod.ComposerView;
const test_server = model.fake_server;
const testing = std.testing;
const json = std.json;
const Io = std.Io;
const io = testing.io;
const div = zpui.div;
const px = zpui.px;

const chat_id = "11111111-2222-3333-4444-555555555555";
/// A valid 1×1 RGBA PNG.
const png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

const Request = struct { method: []u8, params: []u8 };

/// Answers the bootstrap barrier, acks every `UploadChunk`, commits uploads to
/// `/uploads/<fileName>` and records every request.
const FakeEngine = struct {
    gpa: std.mem.Allocator,
    server: test_server.Server,
    mutex: Io.Mutex = .init,
    peer: ?*test_server.Peer = null,
    requests: std.ArrayList(Request) = .empty,
    stopping: bool = false,
    thread: Io.Future(void) = undefined,

    fn start(gpa: std.mem.Allocator) !*FakeEngine {
        const f = try gpa.create(FakeEngine);
        f.* = .{ .gpa = gpa, .server = try test_server.Server.init(io) };
        f.thread = try io.concurrent(run, .{f});
        return f;
    }

    fn port(f: *FakeEngine) u16 {
        return f.server.address().getPort();
    }

    fn stop(f: *FakeEngine) void {
        f.mutex.lockUncancelable(io);
        f.stopping = true;
        if (f.peer) |p| p.stream.shutdown(io, .both) catch {};
        f.mutex.unlock(io);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(f.port()) };
        if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        f.thread.await(io);
        for (f.requests.items) |r| {
            f.gpa.free(r.method);
            f.gpa.free(r.params);
        }
        f.requests.deinit(f.gpa);
        f.server.deinit();
        f.gpa.destroy(f);
    }

    fn run(f: *FakeEngine) void {
        while (true) {
            const peer = f.server.accept(f.gpa) catch return;
            f.mutex.lockUncancelable(io);
            if (f.stopping) {
                f.mutex.unlock(io);
                peer.deinit();
                return;
            }
            f.peer = peer;
            f.mutex.unlock(io);
            f.serve(peer);
            f.mutex.lockUncancelable(io);
            if (f.peer == peer) f.peer = null;
            const stopping = f.stopping;
            f.mutex.unlock(io);
            peer.deinit();
            if (stopping) return;
        }
    }

    fn serve(f: *FakeEngine, peer: *test_server.Peer) void {
        while (true) {
            const text = peer.recvText() catch return;
            const parsed = json.parseFromSlice(json.Value, f.gpa, text, .{}) catch continue;
            defer parsed.deinit();
            const obj = parsed.value.object;
            const id: u64 = @intCast(obj.get("id").?.integer);
            const method = if (obj.get("method")) |m| m.string else "";
            const params = obj.get("params");
            if (std.mem.eql(u8, method, "EngineInfo")) {
                f.sendFmt("{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev-local\",\"workspaceScope\":\"local\",\"capabilities\":[\"message-queue-v1\"]}}}}", .{id});
                continue;
            }
            if (std.mem.eql(u8, method, "LocalDevice")) {
                f.sendFmt("{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev-local\"}}}}", .{id});
                continue;
            }
            if (std.mem.eql(u8, method, "EngineReady") or std.mem.eql(u8, method, "UploadChunk")) {
                f.sendFmt("{{\"id\":{d},\"ok\":{{}}}}", .{id});
            } else if (std.mem.eql(u8, method, "UploadCommit")) {
                const name = params.?.object.get("fileName").?.string;
                f.sendFmt("{{\"id\":{d},\"ok\":{{\"path\":\"/uploads/{s}\"}}}}", .{ id, name });
            }
            const p = if (params) |v| json.Stringify.valueAlloc(f.gpa, v, .{}) catch continue else f.gpa.dupe(u8, "null") catch continue;
            f.mutex.lockUncancelable(io);
            f.requests.append(f.gpa, .{ .method = f.gpa.dupe(u8, method) catch unreachable, .params = p }) catch unreachable;
            f.mutex.unlock(io);
        }
    }

    fn sendFmt(f: *FakeEngine, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const p = f.peer orelse return;
        p.sendText(text) catch {};
    }

    /// Params of the last `method` request (copy), or null.
    fn last(f: *FakeEngine, method: []const u8) ?[]u8 {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        var i = f.requests.items.len;
        while (i > 0) {
            i -= 1;
            const r = f.requests.items[i];
            if (std.mem.eql(u8, r.method, method)) return testing.allocator.dupe(u8, r.params) catch null;
        }
        return null;
    }
};

/// The conversation: Rust `chat_dropzone` around the composer.
const Host = struct {
    composer: Entity(ComposerView),

    fn init(state: Entity(model.AppState), window: *Window, cx: *Context(Host)) !Host {
        const c = try cx.newWith(ComposerView, ComposerView.init, .{state});
        c.update(cx, ComposerView.focusInput, .{window});
        return .{ .composer = c };
    }

    pub fn deinit(self: *Host, cx: *App) void {
        self.composer.release(cx);
    }

    fn onDrop(self: *Host, paths: *const zpui.ExternalPaths, _: *Window, cx: *Context(Host)) void {
        self.composer.update(cx, ComposerView.addPaths, .{paths.paths});
    }

    pub fn render(self: *Host, _: *Window, cx: *Context(Host)) zpui.StatefulDiv {
        return div().id("chat-dropzone").size(px(900)).flex().flexCol().justifyEnd()
            .onDrop(zpui.ExternalPaths, cx.listener(Host.onDrop))
            .child(self.composer);
    }
};

fn pumpUntil(app: *App, state: Entity(model.AppState), ctx: anytype, comptime cond: fn (@TypeOf(ctx), *App) bool) !void {
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(10));
    const eng = state.read(app).engine;
    while (true) {
        app.runUntilParked();
        _ = model.EngineState.pollWake(eng, app);
        app.runUntilParked();
        if (cond(ctx, app)) return;
        if (Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

fn engineReady(state: Entity(model.AppState), app: *App) bool {
    const st = state.read(app);
    return st.engine.read(app).isReady() and st.workspace.read(app).local_device_id != null;
}

fn hasStaged(c: Entity(ComposerView), app: *App) bool {
    return c.read(app).staged().len > 0;
}

fn sentRun(f: *FakeEngine, _: *App) bool {
    const p = f.last("QueueCommand") orelse return false;
    testing.allocator.free(p);
    return true;
}

test "drop an image on the conversation, send: UploadChunk/UploadCommit, then a Run carrying the committed path" {
    model.engine_state.test_sink = null;
    const fake = try FakeEngine.start(testing.allocator);
    defer fake.stop();
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try actions.registerAll(app);
    try actions.keymap.applyKeymap(app, &.{}, .enter);
    const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{
        .port = fake.port(),
        .zeron_path = null,
        .reconnect = false,
        .wake_mode = .poll,
    } });
    defer {
        state.release(app);
        app.runUntilParked();
    }
    try pumpUntil(app, state, state, engineReady);

    // A chat on this machine, selected.
    const chats = try json.parseFromSlice([]engine.protocol.Chat, testing.allocator,
        \\[{"id":"11111111-2222-3333-4444-555555555555","deviceId":"dev-local","title":"T","archived":false,"cwd":"/repo","createdAt":"2026-10-01T00:00:00Z","config":{"harness":"claude-code","sandbox":"workspace-write"}}]
    , .{ .ignore_unknown_fields = true });
    const ws = state.read(app).workspace;
    ws.update(app, model.WorkspaceStore.applyChats, .{chats});
    ws.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, chat_id)});
    app.runUntilParked();

    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 900, .height = 900 } } }, Host, Host.init, .{state});
    const tw = TestWindow.of(handle.window(app).?.platform_window);
    tw.frame(true);
    const composer = handle.rootView(app).?.read(app).composer;

    // The screenshot on disk.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var png: [128]u8 = undefined;
    const png_len = try std.base64.standard.Decoder.calcSizeForSlice(png_b64);
    try std.base64.standard.Decoder.decode(png[0..png_len], png_b64);
    try tmp.dir.writeFile(io, .{ .sub_path = "shot.png", .data = png[0..png_len] });
    const shot = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/shot.png", .{&tmp.sub_path});
    defer testing.allocator.free(shot);

    // Drag it in from a file manager (non-images are skipped) and drop.
    const paths = [_][]const u8{ shot, "/tmp/notes.txt" };
    _ = tw.simulateInput(.{ .file_drop = .{ .entered = .{ .position = .{ .x = 400, .y = 300 }, .paths = &paths } } });
    try testing.expect(app.hasActiveDrag());
    _ = tw.simulateInput(.{ .file_drop = .{ .pending = .{ .position = .{ .x = 420, .y = 320 } } } });
    _ = tw.simulateInput(.{ .file_drop = .{ .submit = .{ .position = .{ .x = 420, .y = 320 } } } });
    _ = tw.simulateInput(.{ .file_drop = .exited });
    try testing.expect(!app.hasActiveDrag());
    try pumpUntil(app, state, composer, hasStaged);
    tw.frame(true);
    {
        const list = composer.read(app).staged();
        try testing.expectEqual(@as(usize, 1), list.len);
        try testing.expectEqualStrings("shot.png", list[0].name);
        try testing.expect(list[0].image != null); // the chip's thumbnail
        try testing.expectEqual(@as(usize, 0), composer.read(app).failure.items.len);
    }

    // Type and send.
    for ("look") |c| _ = tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = &.{c}, .key_char = &.{c} } } });
    tw.typeKey("enter");
    try pumpUntil(app, state, fake, sentRun);
    tw.frame(true);

    const chunk = fake.last("UploadChunk").?;
    defer testing.allocator.free(chunk);
    try testing.expect(std.mem.indexOf(u8, chunk, "\"seq\":0") != null);
    try testing.expect(std.mem.indexOf(u8, chunk, "\"data\":\"" ++ png_b64 ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, chunk, "\"targetDeviceId\":\"dev-local\"") != null);
    const commit = fake.last("UploadCommit").?;
    defer testing.allocator.free(commit);
    try testing.expect(std.mem.indexOf(u8, commit, "\"fileName\":\"shot.png\"") != null);
    const run = fake.last("QueueCommand").?;
    defer testing.allocator.free(run);
    try testing.expect(std.mem.indexOf(u8, run, "look\\n\\nAttached images (local files — open them to view):\\n- /uploads/shot.png") != null or
        std.mem.indexOf(u8, run, "look\\n\\nAttached images (local files \\u2014 open them to view):\\n- /uploads/shot.png") != null);
    try testing.expect(std.mem.indexOf(u8, run, "\"attachments\":[\"/uploads/shot.png\"]") != null);
    // The draft and its chips are consumed.
    try testing.expectEqual(@as(usize, 0), composer.read(app).staged().len);
    try testing.expectEqualStrings("", composer.read(app).input.read(app).text());
}
