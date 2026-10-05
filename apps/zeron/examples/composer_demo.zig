//! `zig build composer-demo`: zeron's composer over a dark transcript-like
//! backdrop, plus a single-line `TextInput` field (session rename), on the
//! Linux backend with Geist fonts.
//!
//! The engine is not running: the demo seeds the model stores the composer
//! reads (harness/model catalog, a selected chat with a branch, optionally a
//! queue) exactly as engine replies would. Sending therefore shows the
//! "Engine not connected" warning (the real behavior offline).
//!
//! Flags:
//!   --frames N        quit after N frames (scripted screenshots)
//!   --text "..."      prefill the composer draft
//!   --field "..."     prefill the single-line field
//!   --new-thread      the new-thread canvas (no selected chat)
//!   --queue           seed two queued messages
//!   --mic             (ignored: the mic follows the voice service availability)
//!   --picker          open the model picker
//!   --light           Zeron Light
//!   --fixtures DIR    seed from the reference fixtures (harnesses, models, spaces, chats)
//!   --chat KEY        with --fixtures: the chat to select (seed-ids.json key)
//!   --backend x11|wayland

const std = @import("std");
const zpui = @import("zpui");
const assets = @import("zeron_assets");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const engine = @import("zeron_engine");
const input_mod = @import("zeron_input");
const composer_mod = @import("zeron_composer");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const ComposerView = composer_mod.ComposerView;
const TextInput = input_mod.TextInput;
const protocol = engine.protocol;

const Launch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    max_frames: ?u64 = null,
    text: ?[]const u8 = null,
    field: ?[]const u8 = null,
    new_thread: bool = false,
    queue: bool = false,
    mic: bool = false,
    picker: bool = false,
    light: bool = false,
    /// Reference fixtures dir (`/home/user/research/reference/fixtures`).
    fixtures: ?[]const u8 = null,
    chat_key: []const u8 = "backpressure",
    state: ?Entity(model.AppState) = null,
};

const Demo = struct {
    composer: Entity(ComposerView),
    field: Entity(TextInput),
    theme: zt.Theme,
    focus: zpui.FocusHandle,
    state: Entity(model.AppState),
    new_thread: bool,
    launch: *Launch,

    /// The selected chat's stores exist once the launch update has flushed:
    /// seed the context usage the footer ring shows (20%).
    fn seedUsage(self: *Demo, cx: *Context(Demo)) void {
        if (self.launch.queue) seedQueue(self.launch, cx.app) catch |err| std.log.err("seed queue: {t}", .{err});
        const t = self.state.read(cx).transcript orelse return;
        var l = t.lease(cx);
        defer l.end();
        l.value.context_usage = .{ .tokens = 40_000, .window = 200_000 };
        l.cx.notify();
        cx.notify();
    }

    fn init(launch: *Launch, window: *Window, cx: *Context(Demo)) !Demo {
        const theme = composer_mod.chrome.defaultTheme(if (launch.light) .light else .dark);
        const state = launch.state.?;
        const composer = try cx.newWith(ComposerView, ComposerView.init, .{state});
        composer.update(cx, ComposerView.setTheme, .{theme});
        composer.update(cx, ComposerView.setAvailableWidth, .{@as(?f32, 768)});
        const field = try cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
            .placeholder = "Session title",
            .single_line = true,
            .key_context = actions.keymap.generic_composer_context,
            .text_size = 13,
            .line_height = 20,
            .colors = input_mod.Colors.fromTheme(&theme),
        }});
        if (launch.field) |t| field.update(cx, TextInput.setText, .{t});
        if (launch.text) |t| composer.read(cx).input.update(cx, TextInput.setText, .{t});
        composer.update(cx, ComposerView.focusInput, .{window});
        if (launch.picker) _ = composer.read(cx).picker.update(cx, composer_mod.ModelPicker.toggle, .{window});
        var seed_task = cx.timer(1, Demo.seedUsage) catch zpui.Task(void).none;
        seed_task.detach();
        return .{ .composer = composer, .field = field, .theme = theme, .focus = cx.focusHandle(), .state = state, .new_thread = launch.new_thread, .launch = launch };
    }

    pub fn deinit(self: *Demo, cx: *App) void {
        self.composer.release(cx);
        self.field.release(cx);
        self.focus.release(cx);
    }

    fn paragraph(theme: *const zt.Theme, s: []const u8) zpui.Div {
        return div().textSize(px(14)).lineHeight(px(22)).textColor(theme.text).child(s);
    }

    pub fn render(self: *Demo, _: *Window, _: *Context(Demo)) zpui.Div {
        const theme = &self.theme;
        const bubble = div().flex().flexRow().justifyEnd().child(div().maxW(zpui.relative(0.8)).px(px(16)).py(px(10)).rounded(px(16))
            .bg(zt.theme.userBubbleBg(theme.appearance)).textSize(px(14)).lineHeight(px(22)).textColor(theme.text)
            .child("Port the composer: the pill, the model chip and a real multiline editor with IME."));
        const transcript = div().w(px(736)).flex().flexCol().gap(px(12)).pt(px(40))
            .child(bubble)
            .child(div().flex().itemsCenter().gap(px(6)).textSize(px(12)).textColor(theme.text_muted).child("Ran 8 commands · edited 3 files · read 5 files"))
            .child(paragraph(theme, "The editor keeps a UTF-8 buffer with grapheme-aware motion, word boundaries from UAX #29, undo coalescing at 700 ms and IME marked text with UTF-16 ranges."))
            .child(paragraph(theme, "The composer pill is frosted over the transcript: radius 26, the composer border tint, the model chip with the harness mark, and the white circular send button."));
        const field_card = div().absolute().top(px(24)).right(px(24)).w(px(320)).flex().flexCol().gap(px(8)).p(px(16))
            .rounded(px(12)).border1().borderColor(theme.border).bg(theme.surface_card)
            .child(div().textSize(px(11)).fontWeight(500).textColor(theme.text_muted).child("RENAME SESSION"))
            .child(div().h(px(32)).px(px(10)).flex().itemsCenter().rounded(px(6)).border1().borderColor(theme.border_strong)
                .bg(theme.inputGlassBg()).child(self.field));
        if (self.new_thread) {
            // The new-thread canvas: the composer sits mid-panel.
            return div().relative().sizeFull().bg(theme.surface).fontFamily(theme.font_sans).flex().flexCol().justifyCenter()
                .child(div().wFull().flexNone().child(self.composer))
                .child(field_card);
        }
        return div().relative().sizeFull().bg(theme.surface).fontFamily(theme.font_sans).flex().flexCol().itemsCenter()
            .child(div().flex1().minH0().overflowHidden().flex().flexCol().itemsCenter().child(transcript))
            .child(div().wFull().flexNone().child(self.composer))
            .child(field_card);
    }
};

fn readFixture(launch: *Launch, name: []const u8) ![]u8 {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ launch.fixtures.?, name });
    return std.Io.Dir.cwd().readFileAlloc(launch.io, path, launch.gpa, .limited(16 << 20));
}

/// Seed the stores from the real app's captured engine replies.
fn seedFixtures(launch: *Launch, app: *App) !void {
    const gpa = launch.gpa;
    const st = launch.state.?.read(app);
    {
        var l = st.catalog.lease(app);
        defer l.end();
        const h = try readFixture(launch, "harnesses.json");
        defer gpa.free(h);
        const hv = try std.json.parseFromSlice(std.json.Value, gpa, h, .{});
        defer hv.deinit();
        l.value.harnesses = try model.status.OwnedJson([]protocol.HarnessDescriptor).fromValue(gpa, hv.value);
        inline for (.{ .{ "models-claude-code.json", protocol.HarnessId.@"claude-code" }, .{ "models-pi.json", protocol.HarnessId.pi }, .{ "models-mock.json", protocol.HarnessId.mock } }) |e| {
            if (readFixture(launch, e[0])) |b| {
                defer gpa.free(b);
                const v = try std.json.parseFromSlice(std.json.Value, gpa, b, .{});
                defer v.deinit();
                l.value.models.set(e[1], try model.status.OwnedJson([]protocol.Model).fromValue(gpa, v.value));
            } else |_| {}
        }
        l.cx.notify();
    }
    const spaces = try readFixture(launch, "spaces.json");
    defer gpa.free(spaces);
    st.workspace.update(app, model.WorkspaceStore.applySpaces, .{try std.json.parseFromSlice([]protocol.Space, gpa, spaces, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })});
    const chats = try readFixture(launch, "chats.json");
    defer gpa.free(chats);
    st.workspace.update(app, model.WorkspaceStore.applyChats, .{try std.json.parseFromSlice([]protocol.Chat, gpa, chats, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })});
    const devices = try readFixture(launch, "devices.json");
    defer gpa.free(devices);
    st.workspace.update(app, model.WorkspaceStore.applyDevices, .{try std.json.parseFromSlice([]protocol.Device, gpa, devices, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })});
    const ids = try readFixture(launch, "seed-ids.json");
    defer gpa.free(ids);
    const idv = try std.json.parseFromSlice(std.json.Value, gpa, ids, .{});
    defer idv.deinit();
    if (launch.new_thread) {
        st.workspace.update(app, model.WorkspaceStore.selectSpace, .{@as(?[]const u8, idv.value.object.get("spaces").?.object.get("aurora").?.string)});
        return;
    }
    const chat_id = idv.value.object.get("chats").?.object.get(launch.chat_key).?.string;
    st.workspace.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, chat_id)});
}

fn seed(launch: *Launch, app: *App) !void {
    if (launch.fixtures != null) return seedFixtures(launch, app);
    const state = launch.state.?;
    const gpa = launch.gpa;
    const st = state.read(app);
    // Harness / model catalog (as ListHarnesses / ListModels would reply).
    {
        const harnesses =
            \\[{"id":"claude-code","name":"Claude Code","supportsSteering":true,"steeringMode":"step-boundary","reasoningLevels":["low","medium","high","xhigh","max"]},
            \\ {"id":"codex","name":"Codex","supportsSteering":true,"steeringMode":"turn-boundary","reasoningLevels":["minimal","low","medium","high"]},
            \\ {"id":"cursor","name":"Cursor","supportsSteering":false,"steeringMode":"turn-boundary","reasoningLevels":[]},
            \\ {"id":"opencode","name":"opencode","supportsSteering":false,"steeringMode":"turn-boundary","reasoningLevels":[]}]
        ;
        const models =
            \\[{"id":"claude-fable-5","label":"Fable"},{"id":"claude-opus-4-6","label":"Opus 4.6"},{"id":"claude-sonnet-4-6","label":"Sonnet 4.6"},{"id":"claude-haiku-4-5","label":"Haiku 4.5","reasoningLevels":[]}]
        ;
        const codex_models =
            \\[{"id":"gpt-5.3-codex","label":"GPT-5.3 Codex"},{"id":"gpt-5.3","label":"GPT-5.3"}]
        ;
        var l = st.catalog.lease(app);
        defer l.end();
        const hv = try std.json.parseFromSlice(std.json.Value, gpa, harnesses, .{});
        defer hv.deinit();
        const mv = try std.json.parseFromSlice(std.json.Value, gpa, models, .{});
        defer mv.deinit();
        const cv = try std.json.parseFromSlice(std.json.Value, gpa, codex_models, .{});
        defer cv.deinit();
        l.value.harnesses = try model.status.OwnedJson([]protocol.HarnessDescriptor).fromValue(gpa, hv.value);
        l.value.models.set(.@"claude-code", try model.status.OwnedJson([]protocol.Model).fromValue(gpa, mv.value));
        l.value.models.set(.codex, try model.status.OwnedJson([]protocol.Model).fromValue(gpa, cv.value));
        l.cx.notify();
    }
    const spaces =
        \\[{"id":"space-comet","deviceId":"local","path":"/home/user/comet","name":"comet","gitDetected":true,"createdAt":"2026-10-01T00:00:00Z"}]
    ;
    st.workspace.update(app, model.WorkspaceStore.applySpaces, .{try std.json.parseFromSlice([]protocol.Space, gpa, spaces, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })});
    if (launch.new_thread) return;
    // A selected chat with a branch (as WatchChats would deliver).
    const chats =
        \\[{"id":"demo-chat","deviceId":"local","spaceId":"space-comet","archived":false,"cwd":"/home/user/comet","branch":"comet/takeover-cluster","createdAt":"2026-10-04T00:00:00Z",
        \\  "config":{"harness":"claude-code","model":"claude-fable-5","reasoning":"high","sandbox":"workspace-write"}}]
    ;
    const parsed = try std.json.parseFromSlice([]protocol.Chat, gpa, chats, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    st.workspace.update(app, model.WorkspaceStore.applyChats, .{parsed});
    st.workspace.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, "demo-chat")});
}

fn seedQueue(launch: *Launch, app: *App) !void {
    const st = launch.state.?.read(app);
    const q = st.queue orelse return;
    const items =
        \\{"items":[{"id":"q1","text":"Then run the full test suite and fix anything that breaks","issuedBy":"local","issuedAt":0},
        \\ {"id":"q2","text":"Add screenshots to the PR description","attachments":["/tmp/shot.png"],"issuedBy":"local","issuedAt":0}]}
    ;
    const parsed = try std.json.parseFromSlice(protocol.QueueSnapshot, launch.gpa, items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    q.update(app, model.QueueStore.applyQueue, .{parsed});
}

fn onLaunch(launch: *Launch, app: *App) void {
    app.quit_when_last_window_closes = true;
    for ([_]assets.Font{ .geist_regular, .geist_medium, .geist_semi_bold, .geist_bold, .geist_mono_regular, .geist_mono_medium }) |f|
        app.addFont(f.info().data) catch |err| std.log.err("addFont: {t}", .{err});
    actions.registerAll(app) catch @panic("registerAll");
    actions.keymap.applyKeymap(app, &.{}, .enter) catch @panic("applyKeymap");
    app.bindKeys(&.{.init("tab", FocusNext{}, null)}) catch {};
    launch.state = app.newWith(model.AppState, model.AppState.init, .{ launch.io, model.engine_state.Config{
        .port = 1,
        .zeron_path = null,
        .reconnect = false,
    } }) catch @panic("AppState");
    seed(launch, app) catch |err| std.log.err("seed: {t}", .{err});
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        .titlebar = .{ .title = "zeron composer" },
        .app_id = "dev.zeron.composer-demo",
    }, Demo, Demo.init, .{launch}) catch |err| {
        std.log.err("openWindow failed: {t}", .{err});
        app.quit();
        return;
    };
    if (launch.max_frames) |n| {
        const Quit = struct {
            left: u64,
            fn tick(self: *const @This(), win: *Window, a: *App) void {
                if (self.left == 0) a.quit() else win.onNextFrame(@This(){ .left = self.left - 1 }, tick);
            }
        };
        handle.window(app).?.onNextFrame(Quit{ .left = n }, Quit.tick);
    }
}

const FocusNext = zpui.action("composer_demo::FocusNext");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var launch: Launch = .{ .gpa = gpa, .io = init.io };
    var backend: ?zpui.linux_platform.BackendKind = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--frames") and i + 1 < argv.len) {
            i += 1;
            launch.max_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--text") and i + 1 < argv.len) {
            i += 1;
            launch.text = argv[i];
        } else if (std.mem.eql(u8, a, "--field") and i + 1 < argv.len) {
            i += 1;
            launch.field = argv[i];
        } else if (std.mem.eql(u8, a, "--backend") and i + 1 < argv.len) {
            i += 1;
            backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, argv[i]);
        } else if (std.mem.eql(u8, a, "--fixtures") and i + 1 < argv.len) {
            i += 1;
            launch.fixtures = argv[i];
        } else if (std.mem.eql(u8, a, "--chat") and i + 1 < argv.len) {
            i += 1;
            launch.chat_key = argv[i];
        } else if (std.mem.eql(u8, a, "--new-thread")) {
            launch.new_thread = true;
        } else if (std.mem.eql(u8, a, "--queue")) {
            launch.queue = true;
        } else if (std.mem.eql(u8, a, "--mic")) {
            launch.mic = true;
        } else if (std.mem.eql(u8, a, "--picker")) {
            launch.picker = true;
        } else if (std.mem.eql(u8, a, "--light")) {
            launch.light = true;
        }
    }
    const plat = try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend });
    const app = try App.init(gpa, plat);
    defer app.deinit();
    defer if (launch.state) |s| s.release(app);
    app.run(&launch, onLaunch);
}
