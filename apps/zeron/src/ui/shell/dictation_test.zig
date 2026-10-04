//! [dictation] App-side dictation tests (Rust `dictation.rs` / `dictation/model.rs`
//! tests): the native transcriber's finish-before-permission, the voice model's
//! partial-cache removal, microphone choice across disconnection, and the
//! opt-in switch that preserves the download.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const input_mod = @import("zeron_input");
const service = @import("../../voice/service.zig");
const model_files = @import("../../voice/model.zig");

const App = zpui.App;
const dict = input_mod.dictation;
const testing = std.testing;

test "finishing before permission does not wait or start capture" {
    const gpa = testing.allocator;
    const n = try gpa.create(service.Native);
    n.* = .{ .gpa = gpa, .io = testing.io, .origin_window = 0, .dir = try gpa.dupe(u8, ""), .device = null };
    const t = n.transcriber();
    t.finish();
    const ev = t.poll().?;
    try testing.expectEqualStrings("", ev.final);
    try testing.expect(t.poll() == null);
    try testing.expect(n.sess == null);
    t.deinit();
}

const Harness = struct {
    app: *App,
    tmp: testing.TmpDir,
    root: [256]u8 = undefined,
    root_len: usize = 0,

    fn init() !Harness {
        var h: Harness = .{ .app = try App.initTest(testing.allocator), .tmp = testing.tmpDir(.{}) };
        const r = try std.fmt.bufPrint(&h.root, ".zig-cache/tmp/{s}", .{h.tmp.sub_path});
        h.root_len = r.len;
        try model.settings_store.initMemory(h.app, testing.io);
        return h;
    }
    fn install(h: *Harness) void {
        service.install(h.app, testing.io, null, h.root[0..h.root_len]);
    }
    fn deinit(h: *Harness) void {
        h.app.deinit();
        h.tmp.cleanup();
    }
    fn vm(h: *Harness) zpui.Entity(service.VoiceModel) {
        return service.voiceModel(h.app).?;
    }
};

test "a partial model cache is removable after restart" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(testing.io, "models/" ++ model_files.directory_name);
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "models/" ++ model_files.directory_name ++ "/encoder-model.int8.onnx.part", .data = "partial" });
    h.install();
    const m = h.vm().read(h.app);
    try testing.expect(!m.ready);
    try testing.expectEqual(@as(u64, 0), m.progress);
    try testing.expect(m.cache_present);
    h.vm().update(h.app, service.VoiceModel.remove, .{});
    try testing.expect(!h.vm().read(h.app).cache_present);
    try testing.expect(!h.vm().read(h.app).ready);
    try testing.expectError(error.FileNotFound, h.tmp.dir.statFile(testing.io, "models/" ++ model_files.directory_name, .{}));
}

fn setDevices(m: *service.VoiceModel, _: *zpui.Context(service.VoiceModel)) void {
    m.setDevices(&.{ .{ "coreaudio:built-in", "MacBook Pro Microphone" }, .{ "coreaudio:usb", "USB Microphone" } }) catch unreachable;
}

test "the microphone choice survives disconnection" {
    var h = try Harness.init();
    defer h.deinit();
    h.install();
    h.vm().update(h.app, setDevices, .{});
    const m = h.vm().read(h.app);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts, const sel = m.inputOptions(a, null);
    try testing.expectEqual(@as(usize, 3), opts.len);
    try testing.expectEqual(@as(usize, 0), sel);
    try testing.expectEqualStrings("System default", opts[0].label);
    try testing.expectEqual(@as(usize, 2), m.inputOptions(a, "coreaudio:usb")[1]);
    const gone, const gone_sel = m.inputOptions(a, "coreaudio:gone");
    try testing.expectEqual(@as(usize, 4), gone.len);
    try testing.expectEqual(@as(usize, 3), gone_sel);
    try testing.expectEqualStrings("Disconnected microphone", gone[3].label);
    try testing.expect(m.inputIdAt(0, null) == null);
    try testing.expectEqualStrings("coreaudio:usb", m.inputIdAt(2, null).?);
    try testing.expectEqualStrings("coreaudio:gone", m.inputIdAt(3, "coreaudio:gone").?);
}

fn markReady(m: *service.VoiceModel, _: *zpui.Context(service.VoiceModel)) void {
    m.ready = true;
}

test "dictation is opt-in and disabling preserves the download" {
    var h = try Harness.init();
    defer h.deinit();
    h.install();
    try testing.expect(!dict.enabled(h.app));
    h.vm().update(h.app, markReady, .{});
    try testing.expect(!model.settings_store.current(h.app).?.dictationEnabled);
    try testing.expect(!dict.enabled(h.app));
    h.vm().update(h.app, service.VoiceModel.primary, .{});
    try testing.expect(dict.enabled(h.app));
    h.vm().update(h.app, service.VoiceModel.primary, .{});
    try testing.expect(h.vm().read(h.app).ready);
    try testing.expect(!dict.enabled(h.app));
}
