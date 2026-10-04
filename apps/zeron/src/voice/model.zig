//! The pinned Parakeet v3 model (zeron `crates/voice/model.json` and the
//! `manifest` / `download_size` / `installed` / `download` half of
//! `lib.rs`): an immutable Hugging Face revision of the int8 ONNX
//! conversion, every artifact pinned by size and SHA-256. Readiness is the
//! exact sizes plus a `verified` file holding the revision; temporary
//! `.part` files never establish it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Artifact = struct { name: []const u8, size: u64, sha256: []const u8 };

pub const repository = "istupakov/parakeet-tdt-0.6b-v3-onnx";
pub const revision = "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce";
pub const files = [_]Artifact{
    .{ .name = "decoder_joint-model.int8.onnx", .size = 18202004, .sha256 = "eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70" },
    .{ .name = "encoder-model.int8.onnx", .size = 652183999, .sha256 = "6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09" },
    .{ .name = "vocab.txt", .size = 93939, .sha256 = "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d" },
};

/// `{data_dir}/models/<this>` (Rust `dictation::model::init`).
pub const directory_name = "parakeet-tdt-0.6b-v3-int8";

pub fn downloadSize() u64 {
    var total: u64 = 0;
    for (files) |f| total += f.size;
    return total;
}

/// `zeron_voice::installed`.
pub fn installed(io: Io, dir: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer d.close(io);
    for (files) |f| {
        const st = d.statFile(io, f.name, .{}) catch return false;
        if (st.size != f.size) return false;
    }
    var buf: [64]u8 = undefined;
    const got = readSmall(io, d, "verified", &buf) orelse return false;
    return std.mem.eql(u8, got, revision);
}

fn readSmall(io: Io, d: Io.Dir, name: []const u8, buf: []u8) ?[]const u8 {
    const file = d.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    var n: usize = 0;
    while (n < buf.len) {
        n += file.readStreaming(io, &.{buf[n..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return null,
        };
    }
    return buf[0..n];
}

/// Whether `dir` exists at all (Rust `cache_present`).
pub fn present(io: Io, dir: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    d.close(io);
    return true;
}

/// `std::fs::remove_dir_all`; a missing directory is success.
pub fn remove(io: Io, dir: []const u8) !void {
    try Io.Dir.cwd().deleteTree(io, dir);
    if (present(io, dir)) return error.RemoveFailed;
}

/// Lower-case hex SHA-256 of `dir/name` (Rust `Recognizer::load`'s check).
pub fn sha256File(io: Io, d: Io.Dir, name: []const u8) ![64]u8 {
    const file = try d.openFile(io, name, .{});
    defer file.close(io);
    var h: Sha256 = .init(.{});
    var buf: [256 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Every artifact matches its pinned digest (verified before handing bytes
/// to the native runtime, including after restart).
pub fn verify(io: Io, dir: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer d.close(io);
    for (files) |f| {
        const got = sha256File(io, d, f.name) catch return false;
        if (!std.mem.eql(u8, &got, f.sha256)) return false;
    }
    return true;
}

pub const DownloadError = error{ Cancelled, UnexpectedSize, ChecksumMismatch, HttpStatus, DownloadFailed };

/// `zeron_voice::download`: stream each artifact through `<name>.part`,
/// verify size and SHA-256, rename, and only then write `verified`.
/// `progress` receives the running byte total. Called on a worker thread.
pub fn download(
    gpa: Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    dir: []const u8,
    cancel: *const std.atomic.Value(bool),
    progress: *std.atomic.Value(u64),
) !void {
    try Io.Dir.cwd().createDirPath(io, dir);
    var d = try Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var total: u64 = 0;
    for (files) |f| {
        if (cancel.load(.acquire)) return error.Cancelled;
        var part_buf: [128]u8 = undefined;
        const part = try std.fmt.bufPrint(&part_buf, "{s}.part", .{f.name});
        fetchOne(gpa, io, environ, d, f, part, cancel, progress, &total) catch |err| {
            d.deleteFile(io, part) catch {};
            return err;
        };
    }
    if (cancel.load(.acquire)) return error.Cancelled;
    try d.writeFile(io, .{ .sub_path = "verified", .data = revision });
}

fn fetchOne(
    gpa: Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    d: Io.Dir,
    f: Artifact,
    part: []const u8,
    cancel: *const std.atomic.Value(bool),
    progress: *std.atomic.Value(u64),
    total: *u64,
) !void {
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://huggingface.co/{s}/resolve/{s}/{s}", .{ repository, revision, f.name });
    const file = try d.createFile(io, part, .{ .truncate = true });
    var closed = false;
    defer if (!closed) file.close(io);
    var sink: Sink = .{ .io = io, .file = file, .limit = f.size, .cancel = cancel, .progress = progress, .total = total };
    var buf: [64 * 1024]u8 = undefined;
    sink.interface = .{ .vtable = &Sink.vtable, .buffer = &buf };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var proxy_arena: std.heap.ArenaAllocator = .init(gpa);
    defer proxy_arena.deinit();
    if (environ) |env| client.initDefaultProxies(proxy_arena.allocator(), env) catch {};
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &sink.interface,
        .keep_alive = false,
    }) catch |err| return sink.failure orelse err;
    sink.interface.flush() catch return sink.failure orelse error.DownloadFailed;
    if (sink.failure) |e| return e;
    if (result.status.class() != .success) return error.HttpStatus;
    if (sink.size != f.size) return error.UnexpectedSize;
    var digest: [32]u8 = undefined;
    sink.hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, f.sha256)) return error.ChecksumMismatch;
    try file.sync(io);
    file.close(io);
    closed = true;
    try Io.Dir.rename(d, part, d, f.name, io);
}

/// Hashes, bounds and writes the body; observes cancellation per chunk.
const Sink = struct {
    interface: Io.Writer = undefined,
    io: Io,
    file: Io.File,
    hasher: Sha256 = .init(.{}),
    size: u64 = 0,
    limit: u64,
    cancel: *const std.atomic.Value(bool),
    progress: *std.atomic.Value(u64),
    total: *u64,
    failure: ?anyerror = null,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn consume(self: *Sink, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (self.cancel.load(.acquire)) {
            self.failure = error.Cancelled;
            return error.WriteFailed;
        }
        self.size += bytes.len;
        if (self.size > self.limit) {
            self.failure = error.UnexpectedSize;
            return error.WriteFailed;
        }
        self.hasher.update(bytes);
        self.file.writeStreamingAll(self.io, bytes) catch {
            self.failure = error.DownloadFailed;
            return error.WriteFailed;
        };
        self.total.* += bytes.len;
        self.progress.store(self.total.*, .release);
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        try self.consume(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |b| {
            try self.consume(b);
            n += b.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.consume(last);
            n += last.len;
        }
        return n;
    }
};

const testing = std.testing;

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "manifest pins only v3 artifacts and exact size" {
    try testing.expectEqual(@as(usize, 40), revision.len);
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqual(@as(u64, 670479942), downloadSize());
    for (files) |f| {
        try testing.expectEqual(@as(usize, 64), f.sha256.len);
        try testing.expect(std.mem.indexOfScalar(u8, f.name, '/') == null);
    }
}

test "cancelled download never establishes readiness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    var cancel: std.atomic.Value(bool) = .init(true);
    var progress: std.atomic.Value(u64) = .init(0);
    try testing.expectError(error.Cancelled, download(testing.allocator, testing.io, null, dir, &cancel, &progress));
    try testing.expectEqual(@as(u64, 0), progress.load(.acquire));
    try testing.expect(!installed(testing.io, dir));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "verified", .{}));
    for (files) |f| {
        var pb: [128]u8 = undefined;
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, f.name, .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, try std.fmt.bufPrint(&pb, "{s}.part", .{f.name}), .{}));
    }
}

test "partial or corrupt model cannot load, and a partial cache is removable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const dir = try tmpPath(&tmp, &buf);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = files[0].name, .data = "corrupt" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "encoder-model.int8.onnx.part", .data = "partial" });
    try testing.expect(!installed(testing.io, dir));
    try testing.expect(!verify(testing.io, dir));
    try testing.expect(present(testing.io, dir));
    try remove(testing.io, dir);
    try testing.expect(!present(testing.io, dir));
    try remove(testing.io, dir); // already gone
}
