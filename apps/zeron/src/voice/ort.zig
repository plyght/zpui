//! ONNX Runtime through its C API, loaded at run time (`dlopen`), so the
//! build never depends on it: when no runtime is found, dictation reports
//! itself unavailable. Rust zeron links ONNX Runtime 1.28.0 statically
//! through ort-sys 2.0.0-rc.13; ship the same release's shared library
//! (`libonnxruntime.so` / `libonnxruntime.dylib`) next to the binary, in
//! `<bundle>/Contents/Frameworks`, in `../lib`, or point
//! `ZERON_ONNXRUNTIME` at it.
//!
//! Only the handful of `OrtApi` entries parakeet-rs's TDT path uses are
//! bound; the table indices are those of `struct OrtApi` in
//! onnxruntime_c_api.h (stable across releases: the table only grows).
//! Sessions are configured as parakeet-rs `ExecutionConfig::default()`
//! builds them through ort: CPU, `GraphOptimizationLevel::Level3`
//! (ORT_ENABLE_LAYOUT), 4 intra-op threads, 1 inter-op thread, an env named
//! "default" logging at ERROR.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");

pub const Env = opaque {};
pub const Session = opaque {};
pub const SessionOptions = opaque {};
pub const Value = opaque {};
pub const Status = opaque {};
pub const MemoryInfo = opaque {};
pub const TensorTypeAndShapeInfo = opaque {};

pub const ElementType = enum(c_int) { float = 1, int32 = 6, int64 = 7 };

const ApiBase = extern struct {
    GetApi: *const fn (version: u32) callconv(.c) ?*const anyopaque,
    GetVersionString: *const fn () callconv(.c) [*:0]const u8,
};

/// Minimum API version requested (ONNX Runtime 1.16+ provide it; zeron
/// pins 1.28 whose ORT_API_VERSION is 28).
const api_version: u32 = 16;

const Fn = struct {
    const GetErrorMessage = *const fn (*const Status) callconv(.c) [*:0]const u8;
    const CreateEnv = *const fn (c_int, [*:0]const u8, *?*Env) callconv(.c) ?*Status;
    const CreateSession = *const fn (*const Env, [*:0]const u8, *const SessionOptions, *?*Session) callconv(.c) ?*Status;
    const Run = *const fn (*Session, ?*const anyopaque, [*]const [*:0]const u8, [*]const ?*const Value, usize, [*]const [*:0]const u8, usize, [*]?*Value) callconv(.c) ?*Status;
    const CreateSessionOptions = *const fn (*?*SessionOptions) callconv(.c) ?*Status;
    const SetLevel = *const fn (*SessionOptions, c_int) callconv(.c) ?*Status;
    const SetThreads = *const fn (*SessionOptions, c_int) callconv(.c) ?*Status;
    const CreateTensor = *const fn (*const MemoryInfo, *anyopaque, usize, [*]const i64, usize, ElementType, *?*Value) callconv(.c) ?*Status;
    const GetTensorMutableData = *const fn (*Value, *?*anyopaque) callconv(.c) ?*Status;
    const GetDimensionsCount = *const fn (*const TensorTypeAndShapeInfo, *usize) callconv(.c) ?*Status;
    const GetDimensions = *const fn (*const TensorTypeAndShapeInfo, [*]i64, usize) callconv(.c) ?*Status;
    const GetTensorTypeAndShape = *const fn (*const Value, *?*TensorTypeAndShapeInfo) callconv(.c) ?*Status;
    const CreateCpuMemoryInfo = *const fn (c_int, c_int, *?*MemoryInfo) callconv(.c) ?*Status;
    const Release = *const fn (?*anyopaque) callconv(.c) void;
};

const Index = struct {
    const GetErrorMessage = 2;
    const CreateEnv = 3;
    const CreateSession = 7;
    const Run = 9;
    const CreateSessionOptions = 10;
    const SetSessionGraphOptimizationLevel = 23;
    const SetIntraOpNumThreads = 24;
    const SetInterOpNumThreads = 25;
    const CreateTensorWithDataAsOrtValue = 49;
    const GetTensorMutableData = 51;
    const GetDimensionsCount = 61;
    const GetDimensions = 62;
    const GetTensorTypeAndShape = 65;
    const CreateCpuMemoryInfo = 69;
    const ReleaseEnv = 92;
    const ReleaseStatus = 93;
    const ReleaseMemoryInfo = 94;
    const ReleaseSession = 95;
    const ReleaseValue = 96;
    const ReleaseTensorTypeAndShapeInfo = 99;
    const ReleaseSessionOptions = 100;
};

pub const Error = error{ RuntimeUnavailable, OrtFailure, OutOfMemory };

/// The loaded runtime: the function table and one process-wide env.
pub const Api = struct {
    table: [*]const ?*const anyopaque,
    env: *Env,
    cpu: *MemoryInfo,
    version: [*:0]const u8,

    fn get(self: *const Api, comptime T: type, comptime index: usize) T {
        return @ptrCast(@alignCast(self.table[index].?));
    }

    /// Converts a failing status into `error.OrtFailure`, logging its message.
    pub fn check(self: *const Api, status: ?*Status) Error!void {
        const s = status orelse return;
        const msg = self.get(Fn.GetErrorMessage, Index.GetErrorMessage)(s);
        log.warn("onnxruntime: {s}", .{msg});
        self.get(Fn.Release, Index.ReleaseStatus)(s);
        return error.OrtFailure;
    }

    pub fn createSession(self: *const Api, path: [:0]const u8) Error!*Session {
        var opts: ?*SessionOptions = null;
        try self.check(self.get(Fn.CreateSessionOptions, Index.CreateSessionOptions)(&opts));
        defer self.get(Fn.Release, Index.ReleaseSessionOptions)(opts);
        try self.check(self.get(Fn.SetLevel, Index.SetSessionGraphOptimizationLevel)(opts.?, 3));
        try self.check(self.get(Fn.SetThreads, Index.SetIntraOpNumThreads)(opts.?, 4));
        try self.check(self.get(Fn.SetThreads, Index.SetInterOpNumThreads)(opts.?, 1));
        var session: ?*Session = null;
        try self.check(self.get(Fn.CreateSession, Index.CreateSession)(self.env, path.ptr, opts.?, &session));
        return session.?;
    }

    pub fn releaseSession(self: *const Api, s: *Session) void {
        self.get(Fn.Release, Index.ReleaseSession)(s);
    }

    /// A tensor over caller-owned memory (must outlive the value).
    pub fn tensor(self: *const Api, comptime T: type, values: []T, shape: []const i64) Error!*Value {
        const ty: ElementType = switch (T) {
            f32 => .float,
            i32 => .int32,
            i64 => .int64,
            else => @compileError("unsupported tensor type"),
        };
        var v: ?*Value = null;
        try self.check(self.get(Fn.CreateTensor, Index.CreateTensorWithDataAsOrtValue)(self.cpu, @ptrCast(values.ptr), values.len * @sizeOf(T), shape.ptr, shape.len, ty, &v));
        return v.?;
    }

    pub fn releaseValue(self: *const Api, v: ?*Value) void {
        if (v) |p| self.get(Fn.Release, Index.ReleaseValue)(p);
    }

    pub fn run(self: *const Api, session: *Session, input_names: []const [*:0]const u8, inputs: []const ?*const Value, output_names: []const [*:0]const u8, outputs: []?*Value) Error!void {
        std.debug.assert(input_names.len == inputs.len and output_names.len == outputs.len);
        @memset(outputs, null);
        try self.check(self.get(Fn.Run, Index.Run)(session, null, input_names.ptr, inputs.ptr, inputs.len, output_names.ptr, output_names.len, outputs.ptr));
    }

    /// The tensor's data viewed as `T` (owned by the value).
    pub fn data(self: *const Api, comptime T: type, v: *Value) Error![]T {
        var p: ?*anyopaque = null;
        try self.check(self.get(Fn.GetTensorMutableData, Index.GetTensorMutableData)(v, &p));
        var dim_buf: [8]i64 = undefined;
        const shape = try self.dims(v, &dim_buf);
        var n: usize = 1;
        for (shape) |d| n *= @intCast(@max(d, 0));
        const ptr: [*]T = @ptrCast(@alignCast(p orelse return &.{}));
        return ptr[0..n];
    }

    pub fn dims(self: *const Api, v: *Value, buf: *[8]i64) Error![]i64 {
        var info: ?*TensorTypeAndShapeInfo = null;
        try self.check(self.get(Fn.GetTensorTypeAndShape, Index.GetTensorTypeAndShape)(v, &info));
        defer self.get(Fn.Release, Index.ReleaseTensorTypeAndShapeInfo)(info);
        var count: usize = 0;
        try self.check(self.get(Fn.GetDimensionsCount, Index.GetDimensionsCount)(info.?, &count));
        if (count > buf.len) return error.OrtFailure;
        try self.check(self.get(Fn.GetDimensions, Index.GetDimensions)(info.?, buf, count));
        return buf[0..count];
    }
};

const log = std.log.scoped(.zeron_voice);

var load_lock: sync.Mutex = .{};
var load_done: std.atomic.Value(bool) = .init(false);
var loaded: ?Api = null;

/// The runtime, loaded once per process; null when it is not installed.
pub fn api() ?*const Api {
    if (!load_done.load(.acquire)) {
        load_lock.lock();
        defer load_lock.unlock();
        if (!load_done.load(.acquire)) {
            loadOnce();
            load_done.store(true, .release);
        }
    }
    return if (loaded) |*a| a else null;
}

/// True when an ONNX Runtime library can be loaded (dictation's
/// "unavailable" state otherwise).
pub fn available() bool {
    return api() != null;
}

var warming: std.atomic.Value(bool) = .init(false);

/// Load the runtime on a background thread (dlopen of a ~40 MB library
/// must not stall the UI thread).
pub fn warm() void {
    if (load_done.load(.acquire) or warming.swap(true, .acq_rel)) return;
    const t = std.Thread.spawn(.{}, struct {
        fn run() void {
            _ = api();
        }
    }.run, .{}) catch {
        _ = api();
        return;
    };
    t.detach();
}

/// Non-blocking `available`: null until a load attempt has finished.
pub fn tryAvailable() ?bool {
    if (!load_done.load(.acquire)) return null;
    return loaded != null;
}

fn loadOnce() void {
    const handle = openLibrary() orelse {
        log.info("onnxruntime not found; dictation unavailable", .{});
        return;
    };
    const get_base: *const fn () callconv(.c) ?*const ApiBase = @ptrCast(@alignCast(std.c.dlsym(handle, "OrtGetApiBase") orelse return));
    const base = get_base() orelse return;
    const table: [*]const ?*const anyopaque = @ptrCast(@alignCast(base.GetApi(api_version) orelse {
        log.warn("onnxruntime {s} lacks C API v{d}", .{ base.GetVersionString(), api_version });
        return;
    }));
    var a: Api = .{ .table = table, .env = undefined, .cpu = undefined, .version = base.GetVersionString() };
    var env: ?*Env = null;
    a.check(a.get(Fn.CreateEnv, Index.CreateEnv)(3, "default", &env)) catch return; // ORT_LOGGING_LEVEL_ERROR
    var cpu: ?*MemoryInfo = null;
    // OrtArenaAllocator, OrtMemTypeDefault.
    a.check(a.get(Fn.CreateCpuMemoryInfo, Index.CreateCpuMemoryInfo)(1, 0, &cpu)) catch return;
    a.env = env.?;
    a.cpu = cpu.?;
    loaded = a;
    log.info("onnxruntime {s} loaded", .{a.version});
}

const lib_name = if (builtin.os.tag == .macos) "libonnxruntime.dylib" else "libonnxruntime.so";

extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

fn exeDir(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var path: []const u8 = undefined;
    if (builtin.os.tag == .macos) {
        var size: u32 = buf.len;
        if (_NSGetExecutablePath(buf, &size) != 0) return null;
        path = std.mem.sliceTo(buf, 0);
    } else {
        const n = std.c.readlink("/proc/self/exe", buf, buf.len);
        if (n <= 0) return null;
        path = buf[0..@intCast(n)];
    }
    return std.fs.path.dirname(path);
}

fn openLibrary() ?*anyopaque {
    const flags: std.c.RTLD = .{ .NOW = true };
    if (std.c.getenv("ZERON_ONNXRUNTIME")) |p| {
        if (std.c.dlopen(p, flags)) |h| return h;
        log.warn("ZERON_ONNXRUNTIME={s} could not be loaded", .{p});
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (exeDir(&exe_buf)) |dir| {
        const rels = [_][]const u8{ "", "../Frameworks/", "../lib/", "lib/" };
        for (rels) |rel| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}{s}", .{ dir, rel, lib_name }, 0) catch continue;
            if (std.c.dlopen(p, flags)) |h| return h;
        }
    }
    const names = if (builtin.os.tag == .macos)
        [_][:0]const u8{ "libonnxruntime.dylib", "libonnxruntime.1.28.0.dylib", "/opt/homebrew/lib/libonnxruntime.dylib", "/usr/local/lib/libonnxruntime.dylib" }
    else
        [_][:0]const u8{ "libonnxruntime.so", "libonnxruntime.so.1", "libonnxruntime.so.1.28.0", "/usr/local/lib/libonnxruntime.so" };
    for (names) |n| if (std.c.dlopen(n, flags)) |h| return h;
    return null;
}
