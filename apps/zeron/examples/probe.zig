//! zeron-probe: connect to (or start) a zeron engine, print EngineInfo, list
//! chats, and tail one chat's transcript as plain text.
//!
//! Usage: zeron-probe [--port N] [--zeron PATH] [--data-dir DIR] [--no-spawn]
//!                    [--chat ID] [--seconds N] [--keep-engine]
//! `ZERON_IPC_PORT` is honored when `--port` is absent. `--data-dir` sets
//! `ZERON_DATA_DIR` for a spawned `zeron headless`.

const std = @import("std");
const Io = std.Io;
const zeron = @import("zeron_engine");
const protocol = zeron.protocol;

const Args = struct {
    port: ?u16 = null,
    zeron_path: ?[]const u8 = "zeron",
    data_dir: ?[]const u8 = null,
    chat: ?[]const u8 = null,
    seconds: ?i64 = null,
    keep_engine: bool = false,
};

fn parseArgs(arena: std.mem.Allocator, args: std.process.Args) !Args {
    const argv = try args.toSlice(arena);
    var out: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const value = if (i + 1 < argv.len) argv[i + 1] else "";
        if (std.mem.eql(u8, a, "--port")) {
            out.port = try std.fmt.parseInt(u16, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--zeron")) {
            out.zeron_path = value;
            i += 1;
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            out.data_dir = value;
            i += 1;
        } else if (std.mem.eql(u8, a, "--chat")) {
            out.chat = value;
            i += 1;
        } else if (std.mem.eql(u8, a, "--seconds")) {
            out.seconds = try std.fmt.parseInt(i64, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--no-spawn")) {
            out.zeron_path = null;
        } else if (std.mem.eql(u8, a, "--keep-engine")) {
            out.keep_engine = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.InvalidArgs;
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try parseArgs(init.arena.allocator(), init.minimal.args);

    var out_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_writer.interface;

    const port = args.port orelse zeron.portFromEnv(init.environ_map);
    var child_env = try init.environ_map.clone(gpa);
    defer child_env.deinit();
    var port_buf: [8]u8 = undefined;
    try child_env.put("ZERON_IPC_PORT", try std.fmt.bufPrint(&port_buf, "{d}", .{port}));
    if (args.data_dir) |dir| try child_env.put("ZERON_DATA_DIR", dir);

    try out.print("connecting to ws://127.0.0.1:{d} ...\n", .{port});
    try out.flush();
    var engine = zeron.Engine.connect(gpa, io, .{
        .port = port,
        .zeron_path = args.zeron_path,
        .spawn_environ = &child_env,
    }) catch |err| {
        std.debug.print("could not reach an engine: {t}\n", .{err});
        return err;
    };
    defer engine.deinitWith(.{ .stop_spawned = !args.keep_engine });

    const info = engine.info.value;
    try out.print("engine: device={s} scope={t} sdk={s} spawned={}\n", .{
        info.deviceId, info.workspaceScope, info.cursorSdkVersion orelse "-", engine.child != null,
    });
    for (info.capabilities) |c| try out.print("  capability {s}\n", .{c});

    // Chats: the first WatchChats item is the current snapshot.
    const chats_sub = try engine.watchChats();
    defer chats_sub.deinit();
    const snapshot = (try chats_sub.wait(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } })) orelse
        return error.ChatsStreamEnded;
    const chats = try zeron.decode([]protocol.Chat, snapshot);
    defer chats.deinit();
    try out.print("{d} chat(s):\n", .{chats.value.len});
    var newest: ?protocol.Chat = null;
    for (chats.value) |chat| {
        try out.print("  {s}  {s}{s}  [{s}]\n", .{
            chat.id,
            chat.title orelse "(untitled)",
            if (chat.archived) " (archived)" else "",
            chat.lastMessageAt orelse chat.createdAt,
        });
        if (chat.archived) continue;
        const key = chat.lastMessageAt orelse chat.createdAt;
        if (newest == null or std.mem.order(u8, key, newest.?.lastMessageAt orelse newest.?.createdAt) == .gt) newest = chat;
    }
    try out.flush();

    const chat_id = args.chat orelse if (newest) |c| c.id else {
        try out.print("no chat to tail\n", .{});
        try out.flush();
        return;
    };
    try tail(gpa, io, &engine, chat_id, args.seconds, out);
}

/// Stream a transcript, printing only newly arrived text.
fn tail(gpa: std.mem.Allocator, io: Io, engine: *zeron.Engine, chat_id: []const u8, seconds: ?i64, out: *Io.Writer) !void {
    try out.print("── tailing {s} ──\n", .{chat_id});
    try out.flush();
    var t = zeron.Transcript.init(gpa);
    defer t.deinit();
    // Bytes already printed per "entryId/partId".
    var printed: std.StringHashMapUnmanaged(usize) = .empty;
    defer {
        var it = printed.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        printed.deinit(gpa);
    }

    const deadline: Io.Timeout = if (seconds) |s|
        (Io.Timeout{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } }).toDeadline(io)
    else
        .none;

    resubscribe: while (true) {
        const sub = try engine.watchTranscript(chat_id, false);
        defer sub.deinit();
        while (true) {
            const payload = sub.wait(.{ .timeout = deadline }) catch |err| switch (err) {
                error.Timeout => return,
                else => |e| return e,
            } orelse return; // stream done
            const update = zeron.decode(protocol.TranscriptUpdate, payload) catch |err| {
                std.debug.print("malformed transcript frame ({t}); resubscribing\n", .{err});
                continue :resubscribe;
            };
            defer update.deinit();
            t.applyUpdate(update.value) catch |err| switch (err) {
                error.Desync => {
                    std.debug.print("transcript desync {any}; resubscribing\n", .{t.last_desync});
                    continue :resubscribe;
                },
                else => |e| return e,
            };
            try printNew(gpa, &t, &printed, out);
            try out.flush();
        }
    }
}

fn printNew(gpa: std.mem.Allocator, t: *const zeron.Transcript, printed: *std.StringHashMapUnmanaged(usize), out: *Io.Writer) !void {
    for (0..t.len()) |i| {
        const entry = t.entry(i);
        for (entry.parts) |*part_const| {
            var part = part_const.*;
            var key_buf: [512]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ entry.id, part.id() }) catch continue;
            const gop = try printed.getOrPut(gpa, key);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, key);
                gop.value_ptr.* = 0;
            }
            const seen = gop.value_ptr.*;
            switch (part) {
                .text, .reasoning => {
                    const body = part.textBody().?.*;
                    if (seen == 0 and body.len > 0) try out.print("\n[{t}{s}] ", .{ entry.role, if (part == .reasoning) " thinking" else "" });
                    if (body.len > seen) try out.writeAll(body[@min(seen, body.len)..]);
                    gop.value_ptr.* = body.len;
                },
                .tool => |tool| if (seen == 0) {
                    try out.print("\n[tool {t}]", .{std.meta.activeTag(tool.call)});
                    switch (tool.call) {
                        .exec => |e| try out.print(" $ {s}", .{e.command}),
                        .readFile => |f| try out.print(" {s}", .{f.path}),
                        .writeFile => |f| try out.print(" {s}", .{f.path}),
                        .editFile => |f| try out.print(" {s}", .{f.path}),
                        else => {},
                    }
                    gop.value_ptr.* = 1;
                },
                .@"error" => |e| if (seen == 0) {
                    try out.print("\n[error] {s}", .{e.message});
                    gop.value_ptr.* = 1;
                },
                .input, .image, .fork => if (seen == 0) {
                    try out.print("\n[{t}]", .{std.meta.activeTag(part)});
                    gop.value_ptr.* = 1;
                },
            }
        }
    }
}
