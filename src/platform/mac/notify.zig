//! macOS desktop banners and sounds (port of zeron `crates/ui/src/notify.rs` /
//! `sound.rs` onto zpui's objc bindings).
//!
//! Banners go through `NSUserNotificationCenter` — deprecated since 10.14 but shipping,
//! attributed to the app's bundle (name + icon) and enough for title/body/click. A
//! delegate answers "present" unconditionally (whether to ping is the caller's decision)
//! and reports clicks: the banner's `userInfo["zpuiTag"]` goes to
//! `PlatformCallbacks.notification_activated`. Unbundled dev runs have no center; like
//! zeron (the terminal-notifier technique) they adopt `Notification.fallback_bundle_id`
//! when that app is installed by overriding `-[NSBundle bundleIdentifier]` for the main
//! bundle only. Without either, `osascript -e 'display notification …'` is the fallback.
//!
//! Sounds: `NSSound initWithData:` + `play` (asynchronous). The last few players are kept
//! alive so playback is not cut short by deallocation.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const pf = @import("../platform.zig");

const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;

const log = std.log.scoped(.mac_notify);

pub const tag_key = "zpuiTag";

/// Set by the platform: where clicks are reported.
pub var callbacks: *const pf.PlatformCallbacks = &no_callbacks;
const no_callbacks: pf.PlatformCallbacks = .{};

// ---------------------------------------------------------------------------
// Banners
// ---------------------------------------------------------------------------

pub fn post(n: pf.Notification, fallback_bundle_id: ?[]const u8) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    if (postUserNotification(n, fallback_bundle_id)) return;
    postOsascript(n);
}

fn postUserNotification(n: pf.Notification, fallback_bundle_id: ?[]const u8) bool {
    // Defensive lookup: the deprecated API's one real removal risk.
    const center_class = objc.getClass("NSUserNotificationCenter") orelse return false;
    var center = center_class.msg(?id, "defaultUserNotificationCenter", .{});
    if (center == null) if (fallback_bundle_id) |bid| if (identity.adopt(bid)) {
        center = center_class.msg(?id, "defaultUserNotificationCenter", .{});
    };
    const c = center orelse return false;
    // The center holds its delegate weakly; ours is a process-lifetime singleton.
    c.msg(void, "setDelegate:", .{delegateInstance()});
    const note = ak.class("NSUserNotification").msg(id, "new", .{});
    defer note.release();
    note.msg(void, "setTitle:", .{ak.nsString(n.title)});
    note.msg(void, "setInformativeText:", .{ak.nsString(n.body)});
    if (n.tag) |tag| {
        const info = ak.class("NSDictionary").msg(id, "dictionaryWithObject:forKey:", .{ ak.nsString(tag), ak.nsString(tag_key) });
        note.msg(void, "setUserInfo:", .{info});
    }
    c.msg(void, "deliverNotification:", .{note});
    return true;
}

var delegate_obj: ?id = null;

fn delegateInstance() id {
    if (delegate_obj) |d| return d;
    const B = ak.enc_bool;
    const cls = if (objc.ClassBuilder.init("NSObject", "ZpuiNotificationDelegate")) |b| blk: {
        _ = b.addMethod("userNotificationCenter:shouldPresentNotification:", &shouldPresent, B ++ "@:@@");
        _ = b.addMethod("userNotificationCenter:didActivateNotification:", &didActivate, "v@:@@");
        break :blk b.register();
    } else objc.getClass("ZpuiNotificationDelegate").?;
    const obj = cls.msg(id, "new", .{});
    delegate_obj = obj;
    return obj;
}

fn shouldPresent(_: id, _: SEL, _: ?id, _: ?id) callconv(.c) BOOL {
    return objc.YES;
}

/// AppKit calls this on the main thread after activating the app.
fn didActivate(_: id, _: SEL, _: ?id, notification: ?id) callconv(.c) void {
    const note = notification orelse return;
    const info = note.msg(?id, "userInfo", .{}) orelse return;
    const value = info.msg(?id, "objectForKey:", .{ak.nsString(tag_key)}) orelse return;
    const tag = ak.stringBytes(value);
    if (callbacks.notification_activated) |f| f(callbacks.ctx, tag);
}

/// Test hook: deliver a click for a notification tagged `tag` through the delegate.
pub fn simulateActivate(tag: []const u8) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const note = ak.class("NSUserNotification").msg(id, "new", .{});
    defer note.release();
    note.msg(void, "setUserInfo:", .{ak.class("NSDictionary").msg(id, "dictionaryWithObject:forKey:", .{ ak.nsString(tag), ak.nsString(tag_key) })});
    didActivate(delegateInstance(), objc.sel("userNotificationCenter:didActivateNotification:"), null, note);
}

/// Bundle-identity adoption for unbundled (dev) processes.
const identity = struct {
    extern "c" fn class_getInstanceMethod(cls: *objc.Class, name: SEL) ?*anyopaque;
    extern "c" fn method_getImplementation(method: *anyopaque) ?objc.IMP;
    extern "c" fn method_setImplementation(method: *anyopaque, imp: objc.IMP) ?objc.IMP;

    var original: ?*const fn (id, SEL) callconv(.c) ?id = null;
    var bundle_id_buf: [128]u8 = undefined;
    var bundle_id_len: usize = 0;
    var tried = false;
    var adopted = false;

    fn override(this: id, sel: SEL) callconv(.c) ?id {
        const main = ak.class("NSBundle").msg(id, "mainBundle", .{});
        if (this == main) return ak.nsString(bundle_id_buf[0..bundle_id_len]);
        const f = original orelse return null;
        return f(this, sel);
    }

    /// Install once; false when the identity cannot be adopted (the app isn't installed).
    fn adopt(bundle_id: []const u8) bool {
        if (tried) return adopted;
        tried = true;
        if (bundle_id.len > bundle_id_buf.len) return false;
        const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
        if (ws.msg(?id, "URLForApplicationWithBundleIdentifier:", .{ak.nsString(bundle_id)}) == null) return false;
        const method = class_getInstanceMethod(ak.class("NSBundle"), objc.sel("bundleIdentifier")) orelse return false;
        const imp = method_getImplementation(method) orelse return false;
        @memcpy(bundle_id_buf[0..bundle_id.len], bundle_id);
        bundle_id_len = bundle_id.len;
        original = @ptrCast(@alignCast(imp));
        _ = method_setImplementation(method, @ptrCast(&override));
        adopted = true;
        return true;
    }
};

/// Escape for a double-quoted AppleScript literal (zeron `applescript_escape`).
pub fn applescriptEscape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '"' => try out.appendSlice(gpa, "\\\""),
        '\n', '\r' => try out.append(gpa, ' '),
        else => try out.append(gpa, ch),
    };
}

fn postOsascript(n: pf.Notification) void {
    const gpa = std.heap.c_allocator;
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    script.appendSlice(gpa, "display notification \"") catch return;
    applescriptEscape(&script, gpa, n.body) catch return;
    script.appendSlice(gpa, "\" with title \"") catch return;
    applescriptEscape(&script, gpa, n.title) catch return;
    script.append(gpa, '"') catch return;
    spawnDetached(&.{ "/usr/bin/osascript", "-e", script.items });
}

// ---------------------------------------------------------------------------
// Sounds
// ---------------------------------------------------------------------------

var players: [4]?id = @splat(null);
var next_player: usize = 0;

pub fn playSound(bytes: []const u8) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const data = ak.class("NSData").msg(id, "dataWithBytes:length:", .{ bytes.ptr, @as(ak.NSUInteger, bytes.len) });
    const sound = ak.class("NSSound").msg(id, "alloc", .{}).msg(?id, "initWithData:", .{data}) orelse {
        log.debug("NSSound could not decode the sound", .{});
        return;
    };
    if (players[next_player]) |old| {
        old.msg(void, "stop", .{});
        old.release();
    }
    players[next_player] = sound;
    next_player = (next_player + 1) % players.len;
    if (!objc.fromBOOL(sound.msg(BOOL, "play", .{}))) log.debug("NSSound play failed", .{});
}

// ---------------------------------------------------------------------------

extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

/// Fire-and-forget `fork` + `execv` (double fork: no zombie).
fn spawnDetached(argv: []const []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return;
    for (argv, 0..) |a, i| argv_z[i] = (arena.dupeSentinel(u8, a, 0) catch return).ptr;
    const pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        if (fork() == 0) {
            _ = execv(argv_z[0].?, argv_z.ptr);
        }
        _exit(0);
    }
    _ = waitpid(pid, null, 0);
}

test "applescript escaping (zeron notify.rs)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try applescriptEscape(&out, gpa, "say \"hi\" \\ bye\ntwo");
    try std.testing.expectEqualStrings("say \\\"hi\\\" \\\\ bye two", out.items);
}
