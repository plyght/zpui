//! Activity monitor over native PipeWire (used when the PulseAudio protocol
//! is unavailable): watches the registry for stream nodes
//! (media.class Stream/Output/Audio = playback, Stream/Input/Audio =
//! capture) of other processes, binds each to follow its state, and
//! reports activity when any is "running". Event-driven on its own
//! `pw_thread_loop`.

const std = @import("std");
const sys = @import("sys.zig");
const pw = @import("pipewire.zig");
const activity = @import("activity.zig");
const ActivityMonitor = activity.ActivityMonitor;
const log = std.log.scoped(.zpui_audio);

const ThreadLoop = opaque {};
const Loop = opaque {};
const PwContext = opaque {};
const Core = opaque {};
const Proxy = opaque {};

const SpaList = extern struct { next: ?*SpaList = null, prev: ?*SpaList = null };
const SpaCallbacks = extern struct { funcs: ?*const anyopaque, data: ?*anyopaque };
const SpaHook = extern struct {
    link: SpaList = .{},
    cb: SpaCallbacks = .{ .funcs = null, .data = null },
    removed: ?*const fn (*SpaHook) callconv(.c) void = null,
    priv: ?*anyopaque = null,
};
const SpaInterface = extern struct { type: ?[*:0]const u8, version: u32, cb: SpaCallbacks };
const SpaDictItem = extern struct { key: [*:0]const u8, value: ?[*:0]const u8 };
const SpaDict = extern struct { flags: u32, n_items: u32, items: [*]const SpaDictItem };

const RegistryEvents = extern struct {
    version: u32 = 0,
    global: ?*const fn (?*anyopaque, u32, u32, [*:0]const u8, u32, ?*const SpaDict) callconv(.c) void = null,
    global_remove: ?*const fn (?*anyopaque, u32) callconv(.c) void = null,
};
const NodeInfo = extern struct {
    id: u32,
    max_input_ports: u32,
    max_output_ports: u32,
    change_mask: u64,
    n_input_ports: u32,
    n_output_ports: u32,
    state: c_int,
    @"error": ?[*:0]const u8,
    props: ?*const SpaDict,
};
const NodeEvents = extern struct {
    version: u32 = 0,
    info: ?*const fn (?*anyopaque, *const NodeInfo) callconv(.c) void = null,
    param: ?*const anyopaque = null,
};
// Method tables (only the leading entries we call).
const CoreMethods = extern struct {
    version: u32,
    add_listener: ?*const anyopaque,
    hello: ?*const anyopaque,
    sync: ?*const anyopaque,
    pong: ?*const anyopaque,
    @"error": ?*const anyopaque,
    get_registry: *const fn (?*anyopaque, u32, usize) callconv(.c) ?*Proxy,
};
const RegistryMethods = extern struct {
    version: u32,
    add_listener: *const fn (?*anyopaque, *SpaHook, *const RegistryEvents, ?*anyopaque) callconv(.c) c_int,
    bind: *const fn (?*anyopaque, u32, [*:0]const u8, u32, usize) callconv(.c) ?*Proxy,
};
const NodeMethods = extern struct {
    version: u32,
    add_listener: *const fn (?*anyopaque, *SpaHook, *const NodeEvents, ?*anyopaque) callconv(.c) c_int,
};
comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(SpaHook) == 48);
        std.debug.assert(@offsetOf(NodeInfo, "state") == 32);
        std.debug.assert(@offsetOf(CoreMethods, "get_registry") == 48);
        std.debug.assert(@offsetOf(RegistryMethods, "bind") == 16);
    }
}

const Fns = struct {
    pw_thread_loop_new: *const fn (?[*:0]const u8, ?*const anyopaque) callconv(.c) ?*ThreadLoop,
    pw_thread_loop_get_loop: *const fn (*ThreadLoop) callconv(.c) ?*Loop,
    pw_thread_loop_start: *const fn (*ThreadLoop) callconv(.c) c_int,
    pw_thread_loop_stop: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_destroy: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_lock: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_unlock: *const fn (*ThreadLoop) callconv(.c) void,
    pw_context_new: *const fn (*Loop, ?*anyopaque, usize) callconv(.c) ?*PwContext,
    pw_context_connect: *const fn (*PwContext, ?*anyopaque, usize) callconv(.c) ?*Core,
    pw_context_destroy: *const fn (*PwContext) callconv(.c) void,
    pw_core_disconnect: *const fn (*Core) callconv(.c) c_int,
    pw_proxy_destroy: *const fn (*Proxy) callconv(.c) void,
};

const PW_NODE_STATE_RUNNING = 3;
const max_nodes = 128;

const Node = struct {
    id: u32 = 0,
    proxy: ?*Proxy = null,
    hook: SpaHook = .{},
    capture: bool = false,
    running: bool = false,
    mon: *Monitor = undefined,
};

fn call(comptime M: type, obj: anytype) struct { m: *const M, data: ?*anyopaque } {
    const iface: *const SpaInterface = @ptrCast(@alignCast(obj));
    return .{ .m = @ptrCast(@alignCast(iface.cb.funcs.?)), .data = iface.cb.data };
}

fn hookRemove(h: *SpaHook) void {
    if (h.link.next) |next| {
        h.link.prev.?.next = next;
        next.prev = h.link.prev;
        h.link = .{};
    }
    if (h.removed) |r| r(h);
}

fn dictGet(d: ?*const SpaDict, key: []const u8) ?[]const u8 {
    const dict = d orelse return null;
    for (dict.items[0..dict.n_items]) |it| {
        if (std.mem.eql(u8, std.mem.span(it.key), key)) return if (it.value) |v| std.mem.span(v) else null;
    }
    return null;
}

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    fns: Fns,
    owner: *ActivityMonitor,
    tl: *ThreadLoop,
    context: *PwContext = undefined,
    core: *Core = undefined,
    registry: *Proxy = undefined,
    registry_hook: SpaHook = .{},
    registry_events: RegistryEvents = .{},
    node_events: NodeEvents = .{},
    nodes: [max_nodes]Node = @splat(.{}),
    own_pid: u32,
    own_clients: [16]u32 = undefined,
    n_own_clients: usize = 0,

    pub fn open(gpa: std.mem.Allocator, owner: *ActivityMonitor) ?*Monitor {
        if (pw.library() == null) return null; // pw_init
        const lib = sys.DynLib.open(&.{ "libpipewire-0.3.so.0", "libpipewire-0.3.so" }) orelse return null;
        const fns = lib.load(Fns) orelse return null;
        const tl = fns.pw_thread_loop_new("zpui-activity", null) orelse return null;
        const self = gpa.create(Monitor) catch {
            fns.pw_thread_loop_destroy(tl);
            return null;
        };
        self.* = .{ .gpa = gpa, .fns = fns, .owner = owner, .tl = tl, .own_pid = activity.ownPid() };
        self.registry_events = .{ .global = onGlobal, .global_remove = onGlobalRemove };
        self.node_events = .{ .info = onNodeInfo };
        const loop = fns.pw_thread_loop_get_loop(tl) orelse return self.fail(false);
        self.context = fns.pw_context_new(loop, null, 0) orelse return self.fail(false);
        self.core = fns.pw_context_connect(self.context, null, 0) orelse {
            fns.pw_context_destroy(self.context);
            return self.fail(false);
        };
        if (fns.pw_thread_loop_start(tl) < 0) {
            _ = fns.pw_core_disconnect(self.core);
            fns.pw_context_destroy(self.context);
            return self.fail(false);
        }
        fns.pw_thread_loop_lock(tl);
        const c = call(CoreMethods, self.core);
        const reg = c.m.get_registry(c.data, 3, 0);
        if (reg) |r| {
            self.registry = r;
            const rc = call(RegistryMethods, r);
            _ = rc.m.add_listener(rc.data, &self.registry_hook, &self.registry_events, self);
        }
        fns.pw_thread_loop_unlock(tl);
        if (reg == null) {
            fns.pw_thread_loop_stop(tl);
            _ = fns.pw_core_disconnect(self.core);
            fns.pw_context_destroy(self.context);
            return self.fail(false);
        }
        return self;
    }

    fn fail(self: *Monitor, _: bool) ?*Monitor {
        self.fns.pw_thread_loop_destroy(self.tl);
        self.gpa.destroy(self);
        return null;
    }

    pub fn close(self: *Monitor) void {
        const fns = self.fns;
        fns.pw_thread_loop_lock(self.tl);
        for (&self.nodes) |*n| if (n.proxy != null) self.dropNode(n);
        hookRemove(&self.registry_hook);
        fns.pw_proxy_destroy(self.registry);
        fns.pw_thread_loop_unlock(self.tl);
        fns.pw_thread_loop_stop(self.tl);
        _ = fns.pw_core_disconnect(self.core);
        fns.pw_context_destroy(self.context);
        fns.pw_thread_loop_destroy(self.tl);
        self.gpa.destroy(self);
    }

    fn dropNode(self: *Monitor, n: *Node) void {
        hookRemove(&n.hook);
        self.fns.pw_proxy_destroy(n.proxy.?);
        n.* = .{};
    }

    fn publish(self: *Monitor) void {
        var a: activity.Activity = .{};
        for (&self.nodes) |*n| if (n.proxy != null and n.running) {
            if (n.capture) a.mic_in_use = true else a.other_audio = true;
        };
        self.owner.publish(a);
    }

    fn onGlobal(data: ?*anyopaque, id: u32, _: u32, type_: [*:0]const u8, _: u32, props: ?*const SpaDict) callconv(.c) void {
        const self: *Monitor = @ptrCast(@alignCast(data.?));
        const t = std.mem.span(type_);
        if (std.mem.eql(u8, t, "PipeWire:Interface:Client")) {
            // Stream nodes rarely carry the pid; their client does.
            const pid = dictGet(props, "application.process.id") orelse dictGet(props, "pipewire.sec.pid") orelse return;
            if ((std.fmt.parseInt(u32, pid, 10) catch 0) != self.own_pid) return;
            if (self.n_own_clients < self.own_clients.len) {
                self.own_clients[self.n_own_clients] = id;
                self.n_own_clients += 1;
            }
            return;
        }
        if (!std.mem.eql(u8, t, "PipeWire:Interface:Node")) return;
        const class = dictGet(props, "media.class") orelse return;
        const capture = if (std.mem.eql(u8, class, "Stream/Output/Audio"))
            false
        else if (std.mem.eql(u8, class, "Stream/Input/Audio"))
            true
        else
            return;
        if (dictGet(props, "application.process.id")) |pid| {
            if ((std.fmt.parseInt(u32, pid, 10) catch 0) == self.own_pid) return;
        }
        if (dictGet(props, "client.id")) |cid| {
            const c = std.fmt.parseInt(u32, cid, 10) catch std.math.maxInt(u32);
            for (self.own_clients[0..self.n_own_clients]) |own| if (own == c) return;
        }
        // pavucontrol-style level meters are capture streams too.
        if (dictGet(props, "media.name")) |n| if (std.mem.eql(u8, n, "Peak detect")) return;
        const slot = for (&self.nodes) |*n| {
            if (n.proxy == null) break n;
        } else {
            log.debug("audio: activity monitor: too many streams", .{});
            return;
        };
        const r = call(RegistryMethods, self.registry);
        const proxy = r.m.bind(r.data, id, "PipeWire:Interface:Node", 3, 0) orelse return;
        slot.* = .{ .id = id, .proxy = proxy, .capture = capture, .mon = self };
        const nm = call(NodeMethods, proxy);
        _ = nm.m.add_listener(nm.data, &slot.hook, &self.node_events, slot);
    }

    fn onGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
        const self: *Monitor = @ptrCast(@alignCast(data.?));
        for (&self.nodes) |*n| if (n.proxy != null and n.id == id) {
            const was = n.running;
            self.dropNode(n);
            if (was) self.publish();
            return;
        };
    }

    fn onNodeInfo(data: ?*anyopaque, info: *const NodeInfo) callconv(.c) void {
        const n: *Node = @ptrCast(@alignCast(data.?));
        const running = info.state == PW_NODE_STATE_RUNNING;
        if (running == n.running) return;
        n.running = running;
        n.mon.publish();
    }
};
