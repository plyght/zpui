//! Moving new-thread backgrounds: install (poster + animation copies,
//! settings compatibility), playback timing on the test clock (frame
//! durations, the 30 fps cap, loop counts, the replay cache), reduce motion
//! and pausing, effects on frames, and video when a backend is present.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const ui = @import("../components/root.zig");
const store = @import("../settings/store.zig");
const artwork = @import("artwork.zig");
const anim = @import("anim_decode.zig");
const cache = @import("cache.zig");
const install = @import("install.zig");
const player = @import("player.zig");
const video = @import("video.zig");
const wallpaper = @import("wallpaper.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const ms = std.time.ns_per_ms;

const red: [3]u8 = .{ 255, 0, 0 };
const blue: [3]u8 = .{ 0, 0, 255 };
const green: [3]u8 = .{ 0, 255, 0 };
const white: [3]u8 = .{ 255, 255, 255 };

const Env = struct {
    tmp: testing.TmpDir,
    root: []u8,
    data: []u8,
    app: *zpui.App,

    fn init() !Env {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try cache.test_support.path(tmp.dir, "");
        errdefer gpa.free(root);
        const data = try std.fs.path.join(gpa, &.{ root, "data" });
        errdefer gpa.free(data);
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try ui.theme.install(app, zt.Theme.dark());
        try model.settings_store.init(app, io, data);
        return .{ .tmp = tmp, .root = root, .data = data, .app = app };
    }

    fn deinit(e: *Env) void {
        e.app.deinit();
        gpa.free(e.data);
        gpa.free(e.root);
        e.tmp.cleanup();
    }

    fn write(e: *Env, name: []const u8, bytes: []const u8) ![]u8 {
        try e.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        return std.fs.path.join(gpa, &.{ e.root, name });
    }

    /// A 16×8 GIF of solid frames (palette: red, blue, green, white).
    fn gif(e: *Env, name: []const u8, frames: []const u8, delay_cs: u16, loops: ?u16) ![]u8 {
        const bytes = try anim.fixtures.gif(gpa, 16, 8, &.{ red, blue, green, white }, frames, delay_cs, loops);
        defer gpa.free(bytes);
        return e.write(name, bytes);
    }

    fn settings(e: *Env) *const model.UiSettings {
        return store.current(e.app);
    }

    fn exists(path: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        return true;
    }

    /// One frame request at the current clock (the hero's call).
    fn frame(e: *Env, path: []const u8, effect: artwork.Effect, mode: player.Mode) ?player.Frame {
        return player.frame(e.app, io, path, effect, false, mode, null, e.app.executor.now());
    }

    /// Open the player and fill its queue; returns the first frame.
    fn start(e: *Env, path: []const u8) !player.Frame {
        _ = e.frame(path, .none, .play);
        e.app.runUntilParked();
        _ = e.frame(path, .none, .play);
        e.app.runUntilParked();
        return e.frame(path, .none, .play) orelse error.NoFrame;
    }

    fn tick(e: *Env, ns: u64) ?player.Frame {
        e.app.advanceClock(ns);
        const f = e.frame(e.lastPath(), .none, .play);
        e.app.runUntilParked();
        return f;
    }

    var last_path: []const u8 = "";
    fn lastPath(_: *Env) []const u8 {
        return last_path;
    }
};

/// The RGB of a rendered (BGRA) frame's first pixel.
fn rgbOf(img: *const zpui.image.RenderImage) [3]u8 {
    const p = img.frames[0].pixels;
    return .{ p[2], p[1], p[0] };
}

test "choosing a GIF stores a poster PNG (what Rust shows) plus the animation, and Remove deletes both" {
    var e = try Env.init();
    defer e.deinit();
    const src = try e.gif("loop.gif", &.{ 0, 1, 2 }, 5, 0);
    defer gpa.free(src);
    install.installAsync(e.app, src);
    e.app.runUntilParked();
    try testing.expect(install.lastError(e.app) == null);
    const bg = e.settings().newThreadComposerBackground.?;
    try testing.expectEqualStrings("loop.gif", bg.name);
    const motion = bg.motionPath.?;
    try testing.expect(install.isManaged(e.data, bg.path) and install.isManaged(e.data, motion));
    try testing.expect(std.mem.endsWith(u8, bg.path, ".png") and std.mem.endsWith(u8, motion, ".gif"));
    // One id names both copies.
    try testing.expectEqualStrings(std.fs.path.stem(bg.path), std.fs.path.stem(motion));
    try testing.expect(Env.exists(bg.path) and Env.exists(motion));
    // Rust's decoder reads the poster: the first frame.
    const poster_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bg.path, gpa, .limited(1 << 20));
    defer gpa.free(poster_bytes);
    var poster = try artwork.decode(gpa, poster_bytes);
    defer poster.deinit(gpa);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, poster.pixels[0]);
    try testing.expectEqual(@as(u32, 16), poster.width);
    // The animation copy is verbatim.
    const copied = try std.Io.Dir.cwd().readFileAlloc(io, motion, gpa, .limited(1 << 20));
    defer gpa.free(copied);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(1 << 20));
    defer gpa.free(original);
    try testing.expectEqualSlices(u8, original, copied);
    // Wallpaper colors come from the poster.
    const c = e.settings().theme.wallpaper_color.?;
    try testing.expect(c.r > c.b);
    // The poster's proxy seeded the still cache.
    try testing.expectEqual(cache.Status.ready, cache.status(e.app, bg.path).?);

    // Persisted; the extra field round-trips and a file without it still parses.
    var loaded = try model.settings.load(gpa, io, e.data);
    defer loaded.deinit();
    try testing.expectEqualStrings(motion, loaded.value.newThreadComposerBackground.?.motionPath.?);
    var rust = try model.settings.parse(gpa,
        \\{"newThreadComposerBackground":{"path":"/d/new-thread-backgrounds/a.png","name":"a.gif","adjustment":{"focalX":0.5,"focalY":0.5,"zoom":1}}}
    );
    defer rust.deinit();
    try testing.expect(rust.value.newThreadComposerBackground.?.motionPath == null);
    const text = try rust.value.toJson(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "motionPath") == null);

    // Framing changes keep the animation.
    install.setAdjustment(e.app, .{ .focalX = 0.2, .focalY = 0.5, .zoom = 1.5 });
    try testing.expectEqualStrings(motion, e.settings().newThreadComposerBackground.?.motionPath.?);

    const poster_path = try gpa.dupe(u8, bg.path);
    defer gpa.free(poster_path);
    const motion_path = try gpa.dupe(u8, motion);
    defer gpa.free(motion_path);
    try testing.expect(install.remove(e.app) == null);
    try testing.expect(!Env.exists(poster_path) and !Env.exists(motion_path));
}

test "a single-frame GIF stays a still exactly as in Rust" {
    var e = try Env.init();
    defer e.deinit();
    const src = try e.gif("one.gif", &.{1}, 5, null);
    defer gpa.free(src);
    install.installAsync(e.app, src);
    e.app.runUntilParked();
    const bg = e.settings().newThreadComposerBackground.?;
    try testing.expect(bg.motionPath == null);
    try testing.expect(std.mem.endsWith(u8, bg.path, ".gif"));
    try testing.expect(e.frame(bg.path, .none, .play) == null);
    e.app.runUntilParked();
    try testing.expectEqual(player.Status.still, player.status(e.app, bg.path).?);
    try testing.expect(e.frame(bg.path, .none, .play) == null);
}

test "frames follow their delays on the app clock and loop" {
    var e = try Env.init();
    defer e.deinit();
    const path = try e.gif("rgb.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(path);
    Env.last_path = path;
    const first = try e.start(path);
    try testing.expectEqual(red, rgbOf(first.image));
    // Frames are effect rasters at the motion proxy size.
    try testing.expectEqual(artwork.motion_proxy_side, first.image.frames[0].width);
    try testing.expectEqual(@as(u32, 512), first.image.frames[0].height);
    try testing.expect(first.image == e.tick(39 * ms).?.image);
    try testing.expectEqual(blue, rgbOf(e.tick(1 * ms).?.image));
    try testing.expectEqual(green, rgbOf(e.tick(40 * ms).?.image));
    // Infinite loop: back to the first frame, again and again.
    try testing.expectEqual(red, rgbOf(e.tick(40 * ms).?.image));
    try testing.expectEqual(blue, rgbOf(e.tick(40 * ms).?.image));
    // The stream id is stable (the hero swaps frames without crossfading).
    try testing.expectEqual(first.stream, e.frame(path, .none, .play).?.stream);
}

test "a long stall restarts the clock instead of fast-forwarding" {
    var e = try Env.init();
    defer e.deinit();
    const path = try e.gif("stall.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(path);
    Env.last_path = path;
    _ = try e.start(path);
    const before = player.framesShown(e.app, path);
    // Ten seconds away: one step, not 250 frames.
    _ = e.tick(10_000 * ms);
    try testing.expectEqual(before + 1, player.framesShown(e.app, path));
}

test "GIF loop counts are honoured: the last frame stays" {
    var e = try Env.init();
    defer e.deinit();
    // NETSCAPE loop 1 → two plays.
    const path = try e.gif("twice.gif", &.{ 0, 1, 2 }, 4, 1);
    defer gpa.free(path);
    Env.last_path = path;
    _ = try e.start(path);
    var last: ?player.Frame = null;
    for (0..12) |_| last = e.tick(40 * ms);
    try testing.expectEqual(@as(u64, 6), player.framesShown(e.app, path));
    try testing.expectEqual(green, rgbOf(last.?.image));
    // Without the extension a GIF plays once.
    const once = try e.gif("once.gif", &.{ 0, 1 }, 4, null);
    defer gpa.free(once);
    Env.last_path = once;
    _ = try e.start(once);
    for (0..6) |_| last = e.tick(40 * ms);
    try testing.expectEqual(@as(u64, 2), player.framesShown(e.app, once));
    try testing.expectEqual(blue, rgbOf(last.?.image));
}

test "frames faster than 30 fps are merged" {
    var e = try Env.init();
    defer e.deinit();
    // 20 ms frames: red, blue, green, white → shown as red (40 ms), green (40 ms).
    const path = try e.gif("fast.gif", &.{ 0, 1, 2, 3 }, 2, 0);
    defer gpa.free(path);
    Env.last_path = path;
    const first = try e.start(path);
    try testing.expectEqual(red, rgbOf(first.image));
    try testing.expect(first.image == e.tick(39 * ms).?.image);
    try testing.expectEqual(green, rgbOf(e.tick(1 * ms).?.image));
    try testing.expectEqual(red, rgbOf(e.tick(40 * ms).?.image));
}

test "a small animation replays from memory; a large one streams" {
    var e = try Env.init();
    defer e.deinit();
    const path = try e.gif("cached.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(path);
    Env.last_path = path;
    _ = try e.start(path);
    for (0..6) |_| _ = e.tick(40 * ms);
    const jobs = player.jobsStarted(e.app);
    for (0..9) |_| _ = e.tick(40 * ms);
    try testing.expectEqual(jobs, player.jobsStarted(e.app));

    const saved = player.loop_budget_bytes;
    defer player.loop_budget_bytes = saved;
    player.loop_budget_bytes = 0;
    const big = try e.gif("streamed.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(big);
    Env.last_path = big;
    _ = try e.start(big);
    for (0..6) |_| _ = e.tick(40 * ms);
    const jobs2 = player.jobsStarted(e.app);
    var colors: [6][3]u8 = undefined;
    for (&colors) |*c| c.* = rgbOf(e.tick(40 * ms).?.image);
    try testing.expect(player.jobsStarted(e.app) > jobs2);
    // Streaming keeps the sequence.
    for (colors[0..3], colors[3..6]) |a, b| try testing.expectEqual(a, b);
}

test "reduce motion shows the still; pausing holds the frame and resumes without a jump" {
    var e = try Env.init();
    defer e.deinit();
    const path = try e.gif("pause.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(path);
    // Reduced: no player at all (the hero paints `bg.path`'s still).
    try testing.expect(e.frame(path, .none, .still) == null);
    try testing.expect(player.status(e.app, path) == null);
    Env.last_path = path;
    const first = try e.start(path);
    // Paused (window inactive): the clock moves, the frame doesn't, no timers.
    e.app.advanceClock(500 * ms);
    try testing.expect(e.frame(path, .none, .paused).?.image == first.image);
    e.app.advanceClock(500 * ms);
    try testing.expect(e.frame(path, .none, .paused).?.image == first.image);
    // Resumed: the held frame gets its full delay again.
    try testing.expect(e.frame(path, .none, .play).?.image == first.image);
    try testing.expect(e.tick(39 * ms).?.image == first.image);
    try testing.expectEqual(blue, rgbOf(e.tick(1 * ms).?.image));
}

test "nothing decodes or wakes once frames stop being requested" {
    var e = try Env.init();
    defer e.deinit();
    const saved = player.loop_budget_bytes;
    defer player.loop_budget_bytes = saved;
    player.loop_budget_bytes = 0;
    const path = try e.gif("idle.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(path);
    Env.last_path = path;
    _ = try e.start(path);
    e.app.advanceClock(40 * ms);
    const jobs = player.jobsStarted(e.app);
    const shown = player.framesShown(e.app, path);
    // The page is gone: the clock runs on, nothing happens.
    e.app.advanceClock(5000 * ms);
    try testing.expectEqual(jobs, player.jobsStarted(e.app));
    try testing.expectEqual(shown, player.framesShown(e.app, path));
}

test "frames go through the effect pipeline; changing the effect re-renders" {
    var e = try Env.init();
    defer e.deinit();
    const path = try e.gif("fx.gif", &.{ 0, 1, 2 }, 4, 0);
    defer gpa.free(path);
    Env.last_path = path;
    const plain = try e.start(path);
    const stream = plain.stream;
    _ = e.frame(path, .scanlines, .play);
    e.app.runUntilParked();
    const lined = e.frame(path, .scanlines, .play).?;
    try testing.expectEqual(stream, lined.stream);
    // Row 0 of scanlines is darkened (×0.52); the same pipeline as stills.
    const px = lined.image.frames[0].pixels;
    try testing.expectEqual(@as(u8, 132), px[2]);
}

test "APNG and animated WebP play through the same player" {
    var e = try Env.init();
    defer e.deinit();
    const apng_bytes = try anim.fixtures.apng(gpa, 8, 4, &.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 } }, 60, 0);
    defer gpa.free(apng_bytes);
    const apng = try e.write("a.png", apng_bytes);
    defer gpa.free(apng);
    Env.last_path = apng;
    const f0 = try e.start(apng);
    try testing.expectEqual(red, rgbOf(f0.image));
    try testing.expectEqual(blue, rgbOf(e.tick(60 * ms).?.image));

    const webp = try e.write("a.webp", @embedFile("testdata/anim.webp"));
    defer gpa.free(webp);
    try testing.expectEqual(anim.Kind.webp, anim.classify(@embedFile("testdata/anim.webp")));
    // zpui's still decoder can't read an animated WebP; the poster fallback can.
    try testing.expectError(error.InvalidImage, artwork.decode(gpa, @embedFile("testdata/anim.webp")));
    var still = cache.decodeStill(gpa, io, webp).?;
    defer still.deinit(gpa);
    try testing.expectEqual(@as(u32, 32), still.width);
    Env.last_path = webp;
    // Three lossless frames (red, green, blue, 100 ms each), looping forever.
    try testing.expectEqual(red, rgbOf((try e.start(webp)).image));
    try testing.expectEqual(green, rgbOf(e.tick(100 * ms).?.image));
    try testing.expectEqual(blue, rgbOf(e.tick(100 * ms).?.image));
    try testing.expectEqual(red, rgbOf(e.tick(100 * ms).?.image));
}

test "the wallpaper folder picks moving files too, with poster colors" {
    var e = try Env.init();
    defer e.deinit();
    const src = try e.gif("only.gif", &.{ 2, 0 }, 5, 0);
    defer gpa.free(src);
    var c = try wallpaper.choose(gpa, io, e.root, &.{});
    defer c.deinit(gpa);
    try testing.expectEqual(anim.Kind.gif, c.loaded.motion.?);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, c.loaded.image.pixels[0]);
}

test "videos install with a poster when a backend decodes them; damaged ones report why" {
    var e = try Env.init();
    defer e.deinit();
    const bad = try e.write("broken.webm", "\x1a\x45\xdf\xa3 not really a video");
    defer gpa.free(bad);
    install.installAsync(e.app, bad);
    e.app.runUntilParked();
    const err = install.lastError(e.app).?;
    try testing.expect(std.mem.eql(u8, err, video.msg_unsupported) or std.mem.eql(u8, err, video.msg_undecodable));
    try testing.expect(e.settings().newThreadComposerBackground == null);

    if (builtin.os.tag != .linux or !video.available()) return error.SkipZigTest;
    const clip = try e.write("clip.webm", @embedFile("testdata/clip.webm"));
    defer gpa.free(clip);
    install.installAsync(e.app, clip);
    e.app.runUntilParked();
    if (install.lastError(e.app)) |m| {
        // GStreamer without VP8 / Matroska.
        if (std.mem.eql(u8, m, video.msg_undecodable)) return error.SkipZigTest;
        return error.UnexpectedError;
    }
    const bg = e.settings().newThreadComposerBackground.?;
    try testing.expect(std.mem.endsWith(u8, bg.motionPath.?, ".webm"));
    try testing.expect(std.mem.endsWith(u8, bg.path, ".png"));
    Env.last_path = bg.motionPath.?;
    const f0 = try e.start(bg.motionPath.?);
    try testing.expect(rgbOf(f0.image)[0] > 200);
    const f1 = e.tick(100 * ms).?;
    try testing.expect(rgbOf(f1.image)[1] > 200);
    const f2 = e.tick(100 * ms).?;
    try testing.expect(rgbOf(f2.image)[2] > 200);
    // Video loops forever: back to red.
    try testing.expect(rgbOf(e.tick(100 * ms).?.image)[0] > 200);
}
