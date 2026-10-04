//! Attachments (port of zeron `crates/ui/src/attachments.rs`): the composer's
//! staged images, the chunked upload to the chat's host device
//! (`UploadChunk`/`UploadCommit`, base64), the plain-text attachment-ref
//! transport that rides the prompt, the transcript read-back
//! (`ReadAttachmentChunk`) and its decoded-image cache keyed by
//! `(deviceId, path[, expected mime])`.
//!
//! Threading: staging, uploads and read-backs are background jobs (they block
//! on files / RPC replies on a worker); everything else, including the cache,
//! is main-thread only. Bytes are shared through `Blob` (atomic refcount) so a
//! job never borrows memory the UI might free; decoded images are zpui
//! `RenderImage`s whose atlas tiles are dropped from every window on release.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const es = @import("engine_state.zig");

const App = zpui.App;
const RenderImage = zpui.RenderImage;
const image = zpui.image;
const Client = engine_mod.Client;
const json = std.json;
const log = std.log.scoped(.attachments);

/// use-attachments.ts `MAX_ATTACHMENT_BYTES`.
pub const max_attachment_bytes: u64 = 24 * 1024 * 1024;
/// Base64 chars per `UploadChunk` (fits one 1 MiB relay frame; multiple of 4).
pub const upload_chunk_b64_chars: usize = 680_000;
/// state.ts `MAX_ATTACHMENT_READ_CHUNKS`.
pub const max_read_chunks: usize = 1_000;
/// Chunks in flight at once (`seq` slots are idempotent engine-side).
pub const upload_concurrency: usize = 3;
pub const first_chunk_timeout_ns: u64 = 90 * std.time.ns_per_s;
pub const chunk_timeout_ns: u64 = 30 * std.time.ns_per_s;
pub const commit_timeout_ns: u64 = 150 * std.time.ns_per_s;
pub const read_chunk_timeout_ns: u64 = 20 * std.time.ns_per_s;
/// Retained encoded bytes plus estimated CPU/GPU pixels.
pub const image_cache_budget_bytes: usize = 64 * 1024 * 1024;
/// Engine version that understands `pending://` refs + transfer escorts.
pub const queued_attachments_min = [3]u64{ 0, 2, 12 };

// ---------------------------------------------------------------------------
// Text transport (message-attachments.ts)
// ---------------------------------------------------------------------------

/// The body used for image-only sends (`use-attachments.ts`).
pub const attachment_only_text = "See the attached image(s).";

/// `with_attachments`: plain paths appended to the prompt (caller frees).
pub fn withAttachments(gpa: Allocator, text: []const u8, paths: []const []const u8) Allocator.Error![]u8 {
    if (paths.len == 0) return gpa.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, if (text.len == 0) attachment_only_text else text);
    try out.appendSlice(gpa, "\n\nAttached images (local files — open them to view):\n");
    for (paths, 0..) |p, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, "- ");
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

/// A file's display name (`name_from_path`).
pub fn nameFromPath(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| name = path[i + 1 ..];
    name = std.mem.trim(u8, name, " \t");
    return if (name.len == 0) "image" else name;
}

// ---------------------------------------------------------------------------
// Formats + staging (use-attachments.ts intake)
// ---------------------------------------------------------------------------

/// Image formats the whole pipeline supports (gpui decoders ∩ the engine's
/// `mime_by_ext` read-back jail).
pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,
    svg,
    bmp,
    tiff,

    pub fn extension(f: Format) []const u8 {
        return switch (f) {
            .png => "png",
            .jpeg => "jpeg",
            .gif => "gif",
            .webp => "webp",
            .svg => "svg",
            .bmp => "bmp",
            .tiff => "tiff",
        };
    }

    pub fn mime(f: Format) []const u8 {
        return switch (f) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .svg => "image/svg+xml",
            .bmp => "image/bmp",
            .tiff => "image/tiff",
        };
    }

    /// `format_by_extension`.
    pub fn fromPath(path: []const u8) ?Format {
        const base = nameFromPath(path);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
        if (dot == 0) return null;
        const ext = base[dot + 1 ..];
        const table = [_]struct { []const u8, Format }{
            .{ "png", .png },   .{ "jpg", .jpeg },  .{ "jpeg", .jpeg }, .{ "gif", .gif },
            .{ "webp", .webp }, .{ "svg", .svg },   .{ "bmp", .bmp },   .{ "tif", .tiff },
            .{ "tiff", .tiff },
        };
        for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
        return null;
    }

    pub fn fromClipboard(f: zpui.platform.ClipboardImageFormat) Format {
        return switch (f) {
            .png => .png,
            .jpeg => .jpeg,
            .gif => .gif,
            .webp => .webp,
            .bmp => .bmp,
            .tiff => .tiff,
            .svg => .svg,
        };
    }
};

/// `ensure_extension`: a staged name carries a type-matching extension
/// (agents sniff images by extension). Caller frees.
pub fn ensureExtension(gpa: Allocator, name: []const u8, format: Format) Allocator.Error![]u8 {
    const has_ext = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| blk: {
        const stem = name[0..dot];
        const ext = name[dot + 1 ..];
        if (stem.len == 0 or ext.len < 2 or ext.len > 5) break :blk false;
        for (ext) |ch| if (!std.ascii.isAlphanumeric(ch)) break :blk false;
        break :blk true;
    } else false;
    if (has_ext) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, format.extension() });
}

/// `Path::with_extension("png")`.
pub fn withPngExtension(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| (if (dot > 0) name[0..dot] else name) else name;
    return std.fmt.allocPrint(gpa, "{s}.png", .{stem});
}

/// Windows screenshots are BMP, but no agent harness inlines BMP: convert to PNG.
pub fn bmpToPng(gpa: Allocator, bmp: []const u8) ![]u8 {
    var decoded = try image.decode(gpa, bmp, .{ .max_dimension = std.math.maxInt(u32), .animate = false, .apply_orientation = false });
    defer decoded.deinit(gpa);
    const f = decoded.frames[0];
    return image.encodePng(gpa, f.pixels, f.width, f.height, .bgra);
}

/// Shared immutable bytes (atomic refcount; any thread).
pub const Blob = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    bytes: []u8,

    /// Takes ownership of `bytes` (allocated with `gpa`).
    pub fn create(gpa: Allocator, bytes: []u8) Allocator.Error!*Blob {
        const b = try gpa.create(Blob);
        b.* = .{ .gpa = gpa, .bytes = bytes };
        return b;
    }

    pub fn retain(b: *Blob) *Blob {
        _ = b.refs.fetchAdd(1, .monotonic);
        return b;
    }

    pub fn release(b: *Blob) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        b.gpa.free(b.bytes);
        b.gpa.destroy(b);
    }
};

/// Free a decoded image and its atlas tiles in every window (zui fork
/// `ImageSource::evict`). Main thread.
pub fn releaseImage(app: *App, r: *RenderImage) void {
    if (r.refs.load(.acquire) == 1) {
        var atlases: [16]*zpui.atlas.Atlas = undefined;
        var n: usize = 0;
        for (app.windows.items) |slot| if (slot) |w| {
            if (n < atlases.len) {
                atlases[n] = w.sprite_atlas;
                n += 1;
            }
        };
        image.dropImage(r, atlases[0..n]);
    }
    r.release();
}

/// An image staged in the composer, before upload.
pub const Staged = struct {
    id: [36]u8,
    /// File name with a type-matching extension (owned).
    name: []u8,
    format: Format,
    blob: *Blob,
    /// Decoded preview (thumbnail + lightbox); null when undecodable (TIFF).
    image: ?*RenderImage = null,

    pub fn bytes(self: *const Staged) []const u8 {
        return self.blob.bytes;
    }

    /// A second owner of the same bytes / image.
    pub fn clone(self: *const Staged, gpa: Allocator) Allocator.Error!Staged {
        return .{
            .id = self.id,
            .name = try gpa.dupe(u8, self.name),
            .format = self.format,
            .blob = self.blob.retain(),
            .image = if (self.image) |r| r.retain() else null,
        };
    }

    pub fn deinit(self: *Staged, gpa: Allocator, app: *App) void {
        gpa.free(self.name);
        self.blob.release();
        if (self.image) |r| releaseImage(app, r);
        self.* = undefined;
    }
};

/// What a stage job produced for one input.
pub const StageOutcome = union(enum) {
    ok: struct { name: []u8, format: Format, bytes: []u8, decoded: ?image.DecodedImage },
    /// User-facing message (owned).
    err: []u8,
};

pub const StageInput = union(enum) {
    /// Picker / drop / pasted paths (owned). Non-images are skipped silently.
    paths: [][]u8,
    /// Clipboard image bytes (owned).
    clipboard: struct { format: Format, bytes: []u8 },
};

/// Background staging (`stage_in_background`): file reads, BMP → PNG and the
/// preview decode stay off the UI thread.
pub const StageJob = struct {
    gpa: Allocator,
    io: std.Io,
    input: StageInput,

    pub fn run(self: *StageJob) []StageOutcome {
        var out: std.ArrayList(StageOutcome) = .empty;
        switch (self.input) {
            .paths => |paths| for (paths) |p| {
                if (Format.fromPath(p) == null) continue;
                const o = stageFile(self.gpa, self.io, p) catch continue;
                out.append(self.gpa, o) catch {};
            },
            .clipboard => |c| {
                const o = stageClipboard(self.gpa, c.format, c.bytes) catch return out.toOwnedSlice(self.gpa) catch &.{};
                self.input.clipboard.bytes = &.{}; // ownership moved
                out.append(self.gpa, o) catch {};
            },
        }
        return out.toOwnedSlice(self.gpa) catch &.{};
    }

    pub fn discard(self: *StageJob, result: []StageOutcome) void {
        freeOutcomes(self.gpa, result);
    }

    pub fn deinit(self: *StageJob) void {
        switch (self.input) {
            .paths => |paths| {
                for (paths) |p| self.gpa.free(p);
                self.gpa.free(paths);
            },
            .clipboard => |c| self.gpa.free(c.bytes),
        }
    }
};

pub fn freeOutcomes(gpa: Allocator, outcomes: []StageOutcome) void {
    for (outcomes) |*o| freeOutcome(gpa, o);
    gpa.free(outcomes);
}

pub fn freeOutcome(gpa: Allocator, o: *StageOutcome) void {
    switch (o.*) {
        .ok => |*v| {
            gpa.free(v.name);
            gpa.free(v.bytes);
            if (v.decoded) |*d| d.deinit(gpa);
        },
        .err => |m| gpa.free(m),
    }
}

fn errOutcome(gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!StageOutcome {
    return .{ .err = try std.fmt.allocPrint(gpa, fmt, args) };
}

fn previewDecode(gpa: Allocator, bytes: []const u8, format: Format) ?image.DecodedImage {
    if (format == .tiff) return null;
    return image.decode(gpa, bytes, .{ .animate = false }) catch null;
}

/// `stage_file`: read a file from disk; a BMP is converted to PNG.
pub fn stageFile(gpa: Allocator, io: std.Io, path: []const u8) Allocator.Error!StageOutcome {
    const display = nameFromPath(path);
    const format = Format.fromPath(path) orelse return errOutcome(gpa, "{s} is not a supported image.", .{display});
    const dir = std.Io.Dir.cwd();
    const stat = dir.statFile(io, path, .{}) catch return errOutcome(gpa, "{s} could not be read.", .{display});
    if (stat.size > max_attachment_bytes) return errOutcome(gpa, "{s} is too large (24 MB max).", .{display});
    const raw = dir.readFileAlloc(io, path, gpa, .limited(max_attachment_bytes + 1)) catch return errOutcome(gpa, "{s} could not be read.", .{display});
    var name = try ensureExtension(gpa, display, format);
    if (format == .bmp) {
        defer gpa.free(raw);
        const png = bmpToPng(gpa, raw) catch {
            defer gpa.free(name);
            return errOutcome(gpa, "{s} is not a valid image.", .{name});
        };
        const renamed = try withPngExtension(gpa, name);
        gpa.free(name);
        name = renamed;
        return .{ .ok = .{ .name = name, .format = .png, .bytes = png, .decoded = previewDecode(gpa, png, .png) } };
    }
    return .{ .ok = .{ .name = name, .format = format, .bytes = raw, .decoded = previewDecode(gpa, raw, format) } };
}

/// `stage_clipboard_image`: a pasted BMP becomes PNG when it decodes; takes
/// ownership of `bytes`.
pub fn stageClipboard(gpa: Allocator, format_in: Format, bytes: []u8) Allocator.Error!StageOutcome {
    var format = format_in;
    var data = bytes;
    if (format == .bmp) if (bmpToPng(gpa, bytes)) |png| {
        gpa.free(bytes);
        data = png;
        format = .png;
    } else |_| {};
    const name = try ensureExtension(gpa, "image", format);
    return .{ .ok = .{ .name = name, .format = format, .bytes = data, .decoded = previewDecode(gpa, data, format) } };
}

/// Turn a successful outcome into a `Staged` (main thread; consumes the outcome's buffers).
pub fn stagedFromOutcome(gpa: Allocator, io: std.Io, outcome: *StageOutcome) !Staged {
    const v = &outcome.ok;
    var id: [36]u8 = undefined;
    uuidV4(io, &id);
    const blob = try Blob.create(gpa, v.bytes);
    errdefer blob.release();
    var rendered: ?*RenderImage = null;
    if (v.decoded) |d| {
        rendered = RenderImage.create(gpa, d) catch blk: {
            var dd = d;
            dd.deinit(gpa);
            break :blk null;
        };
        v.decoded = null;
    }
    const staged: Staged = .{ .id = id, .name = v.name, .format = v.format, .blob = blob, .image = rendered };
    v.bytes = &.{};
    v.name = &.{};
    return staged;
}

pub fn uuidV4(io: std.Io, out: *[36]u8) void {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 15];
        o += 2;
    }
}

// ---------------------------------------------------------------------------
// Upload (state.ts uploadAttachment)
// ---------------------------------------------------------------------------

/// Whole-attachment deadline: `min(120 + 15 * chunks, 900)` seconds.
pub fn attachmentDeadlineSecs(n_chunks: usize) u64 {
    return @min(120 + 15 * @as(u64, n_chunks), 900);
}

/// `(seq, start, end)` of chunk `seq`, or null past the end. An empty file
/// still sends one empty chunk.
pub const ChunkRange = struct { seq: u64, start: usize, end: usize };

pub fn chunkCount(b64_len: usize) usize {
    if (b64_len == 0) return 1;
    return (b64_len + upload_chunk_b64_chars - 1) / upload_chunk_b64_chars;
}

pub fn chunkRange(b64_len: usize, seq: usize) ChunkRange {
    const start = seq * upload_chunk_b64_chars;
    return .{ .seq = seq, .start = start, .end = @min(start + upload_chunk_b64_chars, b64_len) };
}

/// Send-wide upload progress (state.rs `UploadProgress`): binary bytes landed
/// out of `total`. Shared by the job (writer) and the UI (reader).
pub const Progress = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    done: std.atomic.Value(u64) = .init(0),
    total: u64,

    pub fn create(gpa: Allocator, total: u64) Allocator.Error!*Progress {
        const p = try gpa.create(Progress);
        p.* = .{ .gpa = gpa, .total = total };
        return p;
    }
    pub fn retain(p: *Progress) *Progress {
        _ = p.refs.fetchAdd(1, .monotonic);
        return p;
    }
    pub fn release(p: *Progress) void {
        if (p.refs.fetchSub(1, .acq_rel) == 1) p.gpa.destroy(p);
    }
    /// `upload_progress_percent`: clamped to 99 (the last point is the commit).
    pub fn percent(p: *const Progress) ?u8 {
        if (p.total == 0) return null;
        const done = @min(p.done.load(.monotonic), p.total);
        return @intCast(@min((done * 100) / p.total, 99));
    }
};

pub const UploadItem = struct {
    upload_id: []u8,
    name: []u8,
    blob: *Blob,
};

pub const UploadResult = union(enum) {
    /// Committed absolute paths, one per item (owned).
    ok: [][]u8,
    /// Raw cause (the composer shows friendly copy).
    err: []u8,
    canceled,
};

const ChunkParams = struct {
    uploadId: []const u8,
    seq: u64,
    data: []const u8,
    targetDeviceId: ?[]const u8 = null,
};

const CommitParams = struct {
    uploadId: []const u8,
    fileName: []const u8,
    targetDeviceId: ?[]const u8 = null,
};

/// Chunked upload of every item, in order (`upload_attachment` per item).
/// `client` must stay alive for the job's lifetime (the owner holds a
/// `Connection` reference and releases it on the main thread).
pub const UploadJob = struct {
    gpa: Allocator,
    client: *Client,
    conn: ?*es.Connection = null,
    items: []UploadItem,
    target_device_id: ?[]u8 = null,
    progress: ?*Progress = null,

    pub fn run(self: *UploadJob, token: zpui.core.executor.CancelToken) UploadResult {
        var paths: std.ArrayList([]u8) = .empty;
        for (self.items) |item| {
            const r = uploadOne(self.gpa, self.client, self.target_device_id, item, self.progress, token);
            switch (r) {
                .ok => |p| paths.append(self.gpa, p) catch {
                    self.gpa.free(p);
                    freePaths(self.gpa, paths.items);
                    paths.deinit(self.gpa);
                    return .{ .err = self.gpa.dupe(u8, "out of memory") catch &.{} };
                },
                .err => |e| {
                    for (paths.items) |p| self.gpa.free(p);
                    paths.deinit(self.gpa);
                    return .{ .err = e };
                },
                .canceled => {
                    for (paths.items) |p| self.gpa.free(p);
                    paths.deinit(self.gpa);
                    return .canceled;
                },
            }
        }
        return .{ .ok = paths.toOwnedSlice(self.gpa) catch &.{} };
    }

    pub fn discard(self: *UploadJob, result: UploadResult) void {
        freeUploadResult(self.gpa, result);
    }

    pub fn deinit(self: *UploadJob) void {
        for (self.items) |it| {
            self.gpa.free(it.upload_id);
            self.gpa.free(it.name);
            it.blob.release();
        }
        self.gpa.free(self.items);
        if (self.target_device_id) |t| self.gpa.free(t);
        if (self.progress) |p| p.release();
        if (self.conn) |c| c.release();
    }
};

fn freePaths(gpa: Allocator, paths: []const []u8) void {
    for (paths) |p| gpa.free(p);
}

pub fn freeUploadResult(gpa: Allocator, result: UploadResult) void {
    switch (result) {
        .ok => |paths| {
            freePaths(gpa, paths);
            gpa.free(paths);
        },
        .err => |e| gpa.free(e),
        .canceled => {},
    }
}

fn monoNow(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(ts.nanoseconds, 0));
}

fn waitFor(client: *Client, call: *engine_mod.Call, remaining_ns: u64, diag: *engine_mod.Diagnostic) !engine_mod.Payload {
    return call.wait(.{
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@intCast(@max(remaining_ns, 1))), .clock = .awake } },
        .diag = diag,
    }) catch |err| {
        _ = client;
        return err;
    };
}

fn sleepNs(io: std.Io, ns: u64) void {
    io.sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

const InFlight = struct {
    seq: usize,
    call: *engine_mod.Call,
    started: u64,
    attempt: u32,
};

fn uploadOne(gpa: Allocator, client: *Client, target: ?[]const u8, item: UploadItem, progress: ?*Progress, token: zpui.core.executor.CancelToken) union(enum) { ok: []u8, err: []u8, canceled } {
    const io = client.io;
    const enc = std.base64.standard.Encoder;
    const b64 = gpa.alloc(u8, enc.calcSize(item.blob.bytes.len)) catch return .{ .err = gpa.dupe(u8, "out of memory") catch &.{} };
    defer gpa.free(b64);
    _ = enc.encode(b64, item.blob.bytes);
    const n_chunks = chunkCount(b64.len);
    const deadline = monoNow(io) + attachmentDeadlineSecs(n_chunks) * std.time.ns_per_s;

    var inflight: std.ArrayList(InFlight) = .empty;
    defer {
        for (inflight.items) |f| f.call.deinit();
        inflight.deinit(gpa);
    }
    var next: usize = 0;
    var diag: engine_mod.Diagnostic = .{};
    while (next < n_chunks or inflight.items.len > 0) {
        if (token.isCanceled()) return .canceled;
        if (monoNow(io) > deadline) return .{ .err = std.fmt.allocPrint(gpa, "attachment upload exceeded {d}s", .{attachmentDeadlineSecs(n_chunks)}) catch &.{} };
        // Fill the window.
        while (next < n_chunks and inflight.items.len < upload_concurrency) {
            const call = startChunk(client, item.upload_id, b64, next, target) catch |err| return .{ .err = std.fmt.allocPrint(gpa, "UploadChunk failed: {t}", .{err}) catch &.{} };
            inflight.append(gpa, .{ .seq = next, .call = call, .started = monoNow(io), .attempt = 0 }) catch {
                call.deinit();
                return .{ .err = gpa.dupe(u8, "out of memory") catch &.{} };
            };
            next += 1;
        }
        // Wait for the oldest.
        const f = inflight.orderedRemove(0);
        // The first WINDOW (not just seq 0) gets the cold-dial allowance.
        const limit = if (f.seq < upload_concurrency) first_chunk_timeout_ns else chunk_timeout_ns;
        const elapsed = monoNow(io) -| f.started;
        const remaining = @min(limit -| elapsed, deadline -| monoNow(io));
        const result = waitFor(client, f.call, remaining, &diag);
        f.call.deinit();
        if (result) |payload| {
            payload.deinit();
            if (progress) |p| {
                const r = chunkRange(b64.len, f.seq);
                _ = p.done.fetchAdd(@intCast((r.end - r.start) * 3 / 4), .monotonic);
            }
            continue;
        } else |err| {
            if (f.attempt >= 2) {
                return .{ .err = std.fmt.allocPrint(gpa, "UploadChunk {s}: {t} {s}", .{ if (err == error.Timeout) "timed out" else "failed", err, diag.message() }) catch &.{} };
            }
            log.warn("upload chunk retry seq={d} attempt={d}: {t}", .{ f.seq, f.attempt + 1, err });
            // Stagger by seq so parallel chunks that failed together don't re-collide.
            sleepNs(io, 50 * std.time.ns_per_ms * (f.attempt + 1) * (f.seq + 1));
            const call = startChunk(client, item.upload_id, b64, f.seq, target) catch |e| return .{ .err = std.fmt.allocPrint(gpa, "UploadChunk failed: {t}", .{e}) catch &.{} };
            inflight.insert(gpa, 0, .{ .seq = f.seq, .call = call, .started = monoNow(io), .attempt = f.attempt + 1 }) catch {
                call.deinit();
                return .{ .err = gpa.dupe(u8, "out of memory") catch &.{} };
            };
        }
    }
    if (token.isCanceled()) return .canceled;
    const commit = client.start(.UploadCommit, CommitParams{ .uploadId = item.upload_id, .fileName = item.name, .targetDeviceId = target }) catch |err|
        return .{ .err = std.fmt.allocPrint(gpa, "UploadCommit failed: {t}", .{err}) catch &.{} };
    defer commit.deinit();
    const reply = waitFor(client, commit, @min(commit_timeout_ns, deadline -| monoNow(io)), &diag) catch |err|
        return .{ .err = std.fmt.allocPrint(gpa, "UploadCommit {s}: {t} {s}", .{ if (err == error.Timeout) "timed out" else "failed", err, diag.message() }) catch &.{} };
    defer reply.deinit();
    const path = switch (reply.value) {
        .object => |o| if (o.get("path")) |p| (if (p == .string) p.string else null) else null,
        else => null,
    } orelse return .{ .err = gpa.dupe(u8, "upload commit returned no path") catch &.{} };
    return .{ .ok = gpa.dupe(u8, path) catch return .{ .err = gpa.dupe(u8, "out of memory") catch &.{} } };
}

fn startChunk(client: *Client, upload_id: []const u8, b64: []const u8, seq: usize, target: ?[]const u8) !*engine_mod.Call {
    const r = chunkRange(b64.len, seq);
    return client.start(.UploadChunk, ChunkParams{ .uploadId = upload_id, .seq = r.seq, .data = b64[r.start..r.end], .targetDeviceId = target });
}

// ---------------------------------------------------------------------------
// Read-back (state.ts readAttachmentImage)
// ---------------------------------------------------------------------------

pub const ReadResult = union(enum) {
    ok: struct { name: []u8, decoded: image.DecodedImage },
    failed,
};

const ReadParams = struct {
    path: []const u8,
    offset: u64,
    targetDeviceId: ?[]const u8 = null,
};

/// `ReadAttachmentChunk` loop (45 KB base64 chunks until `done`, bounded,
/// with the stuck-offset guard), then the decode.
pub const ReadJob = struct {
    gpa: Allocator,
    client: *Client,
    conn: ?*es.Connection = null,
    key: []u8,
    path: []u8,
    target_device_id: ?[]u8 = null,
    /// Generated images: the advertised raster type, validated against the bytes.
    expected_mime: ?[]u8 = null,
    app: *App,

    pub fn run(self: *ReadJob) ReadResult {
        return readAttachment(self.gpa, self.client, self.target_device_id, self.path, self.expected_mime);
    }

    pub fn finish(self: *ReadJob, result: ReadResult) void {
        const cache = Cache.of(self.app);
        switch (result) {
            .ok => |v| {
                const r = RenderImage.create(self.gpa, v.decoded) catch {
                    var d = v.decoded;
                    d.deinit(self.gpa);
                    self.gpa.free(v.name);
                    cache.storeError(self.app, self.key);
                    return;
                };
                cache.storeLoaded(self.app, self.key, v.name, r);
                self.gpa.free(v.name);
                r.release();
            },
            .failed => cache.storeError(self.app, self.key),
        }
        self.app.refreshWindows();
    }

    pub fn discard(self: *ReadJob, result: ReadResult) void {
        switch (result) {
            .ok => |v| {
                var d = v.decoded;
                d.deinit(self.gpa);
                self.gpa.free(v.name);
            },
            .failed => {},
        }
    }

    pub fn deinit(self: *ReadJob) void {
        self.gpa.free(self.key);
        self.gpa.free(self.path);
        if (self.target_device_id) |t| self.gpa.free(t);
        if (self.expected_mime) |m| self.gpa.free(m);
        if (self.conn) |c| c.release();
    }
};

pub fn readAttachment(gpa: Allocator, client: *Client, target: ?[]const u8, path: []const u8, expected_mime: ?[]const u8) ReadResult {
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(gpa);
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    var mime_buf: [64]u8 = undefined;
    var mime: []const u8 = "";
    var offset: u64 = 0;
    var done = false;
    var diag: engine_mod.Diagnostic = .{};
    var i: usize = 0;
    while (i < max_read_chunks) : (i += 1) {
        const call = client.start(.ReadAttachmentChunk, ReadParams{ .path = path, .offset = offset, .targetDeviceId = target }) catch return .failed;
        defer call.deinit();
        const reply = waitFor(client, call, read_chunk_timeout_ns, &diag) catch return .failed;
        defer reply.deinit();
        const o = if (reply.value == .object) reply.value.object else return .failed;
        const n = o.get("name") orelse return .failed;
        const m = o.get("mimeType") orelse return .failed;
        if (n != .string or m != .string) return .failed;
        name.clearRetainingCapacity();
        name.appendSlice(gpa, n.string) catch return .failed;
        if (m.string.len > mime_buf.len) return .failed;
        @memcpy(mime_buf[0..m.string.len], m.string);
        mime = mime_buf[0..m.string.len];
        if (expected_mime) |e| if (!std.mem.eql(u8, e, mime)) return .failed;
        const data = o.get("data") orelse return .failed;
        if (data != .string) return .failed;
        if (expected_mime != null and b64.items.len + data.string.len > (max_attachment_bytes + 2) / 3 * 4) return .failed;
        b64.appendSlice(gpa, data.string) catch return .failed;
        const d = o.get("done") orelse return .failed;
        if (d != .bool) return .failed;
        done = d.bool;
        if (done) break;
        const nx = o.get("nextOffset") orelse return .failed;
        const next: u64 = switch (nx) {
            .integer => |v| if (v < 0) return .failed else @intCast(v),
            else => return .failed,
        };
        if (next <= offset) return .failed;
        offset = next;
    }
    if (!done or b64.items.len == 0) return .failed;
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(b64.items) catch return .failed;
    const bytes = gpa.alloc(u8, size) catch return .failed;
    defer gpa.free(bytes);
    dec.decode(bytes, b64.items) catch return .failed;
    var options: image.DecodeOptions = .{ .animate = false };
    if (expected_mime) |e| {
        // Generated previews: only static rasters whose bytes match the metadata, ≤ 2048 px.
        const ok_mime = std.mem.eql(u8, e, "image/png") or std.mem.eql(u8, e, "image/jpeg") or std.mem.eql(u8, e, "image/webp") or std.mem.eql(u8, e, "image/gif");
        if (!ok_mime or bytes.len > max_attachment_bytes) return .failed;
        const actual = image.guessFormat(bytes) orelse return .failed;
        if (!std.mem.eql(u8, actual.mimeType(), e)) return .failed;
        const info = image.probe(bytes) orelse return .failed;
        if (info.width > 4096 or info.height > 4096) return .failed;
        options.max_dimension = 2048;
    }
    const decoded = image.decode(gpa, bytes, options) catch return .failed;
    const owned_name = gpa.dupe(u8, if (name.items.len == 0) nameFromPath(path) else name.items) catch {
        var d = decoded;
        d.deinit(gpa);
        return .failed;
    };
    return .{ .ok = .{ .name = owned_name, .decoded = decoded } };
}

// ---------------------------------------------------------------------------
// Transcript image cache (transcript-attachment-cache.ts)
// ---------------------------------------------------------------------------

/// `retry_delay`: 2s doubling, capped at 15s.
pub fn retryDelayNs(attempts: u32) u64 {
    const ms: u64 = @min(@as(u64, 2_000) << @intCast(@min(attempts, 3)), 15_000);
    return ms * std.time.ns_per_ms;
}

/// Cache key: device, path and validation policy (expected raster mime).
pub fn keyFor(buf: []u8, device: []const u8, path: []const u8, mime: ?[]const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\x00{s}\x00{s}", .{ device, path, mime orelse "" }) catch "";
}

pub const Snapshot = union(enum) {
    loading,
    loaded: struct { image: *RenderImage, name: []const u8 },
    /// `retry_in_ns`: until `beginLoad` hands out another attempt (maxInt = never).
    failed: struct { retry_in_ns: u64 },
};

/// The App-global decoded-image cache.
pub const Cache = struct {
    gpa: Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    tick: u64 = 0,
    loaded_bytes: usize = 0,
    generated_bytes: usize = 0,
    /// `(device, path)` keys shielded from eviction (the open transcript).
    protected: std.StringHashMapUnmanaged(void) = .empty,
    /// Send-wide upload progress for the in-flight send (one at a time).
    upload_progress: ?*Progress = null,

    const Entry = union(enum) {
        loading: u32,
        loaded: struct { image: *RenderImage, name: []u8, bytes: usize, last_used: u64 },
        failed: struct { attempts: u32, at_ns: u64 },
    };

    pub fn of(app: *App) *Cache {
        if (!app.hasGlobal(Cache)) app.setGlobal(Cache{ .gpa = app.gpa }) catch @panic("OOM");
        return app.globalMut(Cache);
    }

    pub fn deinit(self: *Cache, _: *App) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.* == .loaded) {
                self.gpa.free(e.value_ptr.loaded.name);
                e.value_ptr.loaded.image.release();
            }
        }
        self.entries.deinit(self.gpa);
        var pit = self.protected.keyIterator();
        while (pit.next()) |k| self.gpa.free(k.*);
        self.protected.deinit(self.gpa);
        if (self.upload_progress) |p| p.release();
    }

    fn nowNs(app: *App) u64 {
        return app.executor.now();
    }

    fn isGenerated(key: []const u8) bool {
        return !std.mem.endsWith(u8, key, "\x00");
    }

    /// `attachment_snapshot_for` (incl. the queued-send upload alias fallback).
    pub fn snapshot(self: *Cache, app: *App, key: []const u8) Snapshot {
        self.tick += 1;
        if (self.entries.getPtr(key)) |e| switch (e.*) {
            .loaded => |*l| {
                l.last_used = self.tick;
                return .{ .loaded = .{ .image = l.image, .name = l.name } };
            },
            .failed => |f| return .{ .failed = .{ .retry_in_ns = retryDelayNs(f.attempts -| 1) -| (nowNs(app) -| f.at_ns) } },
            .loading => return .loading,
        };
        // Queued-send alias: the host rewrites `pending://{id}/{name}` to
        // `{uploads}/{id8}-{name}`; the id8 prefix resolves to the seeded bytes.
        if (!isGenerated(key)) if (aliasKeyFor(key)) |alias| {
            if (self.entries.get(alias.slice())) |e| if (e == .loaded) {
                const name = self.gpa.dupe(u8, e.loaded.name) catch return .loading;
                defer self.gpa.free(name);
                self.storeLoaded(app, key, name, e.loaded.image);
                const l = self.entries.get(key).?.loaded;
                return .{ .loaded = .{ .image = l.image, .name = l.name } };
            };
        };
        return .loading;
    }

    /// `begin_load_for`: true ⇒ the caller starts fetching now.
    pub fn beginLoad(self: *Cache, app: *App, key: []const u8) bool {
        const gop = self.entries.getOrPut(self.gpa, key) catch return false;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch {
                self.entries.removeByPtr(gop.key_ptr);
                return false;
            };
            gop.value_ptr.* = .{ .loading = 0 };
            return true;
        }
        switch (gop.value_ptr.*) {
            .failed => |f| if (nowNs(app) -| f.at_ns >= retryDelayNs(f.attempts -| 1)) {
                gop.value_ptr.* = .{ .loading = f.attempts };
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn storeError(self: *Cache, app: *App, key: []const u8) void {
        const attempts: u32 = if (self.entries.get(key)) |e| switch (e) {
            .loading => |a| a + 1,
            .failed => |f| f.attempts,
            .loaded => 1,
        } else 1;
        self.put(app, key, .{ .failed = .{ .attempts = attempts, .at_ns = nowNs(app) } });
    }

    /// Insert a decoded image (retains `img`).
    pub fn storeLoaded(self: *Cache, app: *App, key: []const u8, name: []const u8, img: *RenderImage) void {
        const owned_name = self.gpa.dupe(u8, name) catch return;
        const size = img.byteSize() * 2 + 64;
        self.tick += 1;
        self.put(app, key, .{ .loaded = .{ .image = img.retain(), .name = owned_name, .bytes = size, .last_used = self.tick } });
        const generated = isGenerated(key);
        self.loaded_bytes += size;
        if (generated) self.generated_bytes += size;
        // Separate budgets for generated previews and user attachments.
        while ((if (generated) self.generated_bytes else self.loaded_bytes -| self.generated_bytes) > image_cache_budget_bytes) {
            var oldest: ?[]const u8 = null;
            var oldest_tick: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (std.mem.eql(u8, k, key) or isGenerated(k) != generated) continue;
                if (!generated and self.isProtected(k)) continue;
                if (e.value_ptr.* == .loaded and e.value_ptr.loaded.last_used < oldest_tick) {
                    oldest_tick = e.value_ptr.loaded.last_used;
                    oldest = k;
                }
            }
            const victim = oldest orelse break;
            const kv = self.entries.fetchRemove(victim).?;
            self.dropEntry(app, kv.value);
            self.gpa.free(kv.key);
        }
    }

    /// Seed the cache with local bytes after a send (`seed_attachment`).
    pub fn seed(self: *Cache, app: *App, device: []const u8, path: []const u8, name: []const u8, img: *RenderImage) void {
        var buf: [4096]u8 = undefined;
        self.storeLoaded(app, keyFor(&buf, device, path, null), name, img);
    }

    /// Seed under the upload identity's id8 alias (`seed_attachment_alias`).
    pub fn seedAlias(self: *Cache, app: *App, device: []const u8, upload_id: []const u8, name: []const u8, img: *RenderImage) void {
        var path_buf: [64]u8 = undefined;
        const alias = std.fmt.bufPrint(&path_buf, "upload-alias://{s}", .{upload_id[0..@min(8, upload_id.len)]}) catch return;
        self.seed(app, device, alias, name, img);
    }

    /// Replace the eviction shield with `(device, path)` keys (borrowed; copied).
    pub fn protect(self: *Cache, keys: []const []const u8) void {
        var pit = self.protected.keyIterator();
        while (pit.next()) |k| self.gpa.free(k.*);
        self.protected.clearRetainingCapacity();
        for (keys) |k| {
            const owned = self.gpa.dupe(u8, k) catch continue;
            self.protected.put(self.gpa, owned, {}) catch self.gpa.free(owned);
        }
    }

    fn isProtected(self: *const Cache, key: []const u8) bool {
        return self.protected.contains(key);
    }

    fn put(self: *Cache, app: *App, key: []const u8, value: Entry) void {
        const gop = self.entries.getOrPut(self.gpa, key) catch {
            if (value == .loaded) {
                self.gpa.free(value.loaded.name);
                value.loaded.image.release();
            }
            return;
        };
        if (gop.found_existing) {
            self.dropEntry(app, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch {
                self.entries.removeByPtr(gop.key_ptr);
                return;
            };
        }
        gop.value_ptr.* = value;
    }

    fn dropEntry(self: *Cache, app: *App, e: Entry) void {
        if (e != .loaded) return;
        self.loaded_bytes -|= e.loaded.bytes;
        // Only generated keys count toward the generated budget; recompute lazily.
        self.generated_bytes = @min(self.generated_bytes, self.loaded_bytes);
        self.gpa.free(e.loaded.name);
        releaseImage(app, e.loaded.image);
    }

    /// Start (or replace) the send-wide upload progress.
    pub fn beginUploadProgress(self: *Cache, p: *Progress) void {
        if (self.upload_progress) |old| old.release();
        self.upload_progress = p.retain();
    }

    pub fn endUploadProgress(self: *Cache) void {
        if (self.upload_progress) |p| p.release();
        self.upload_progress = null;
    }

    pub fn uploadPercent(self: *const Cache) ?u8 {
        const p = self.upload_progress orelse return null;
        return p.percent();
    }
};

const AliasKey = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const AliasKey) []const u8 {
        return self.buf[0..self.len];
    }
};

/// `upload_alias_id8`: the alias key of a committed upload's path (basename
/// `{id8}-{name}`), keyed under the same device.
fn aliasKeyFor(key: []const u8) ?AliasKey {
    const dev_end = std.mem.indexOfScalar(u8, key, 0) orelse return null;
    const rest = key[dev_end + 1 ..];
    const path_end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    const path = rest[0..path_end];
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    if (base.len < 9 or base[8] != '-') return null;
    for (base[0..8]) |ch| if (!std.ascii.isAlphanumeric(ch)) return null;
    var out: AliasKey = .{};
    const s = std.fmt.bufPrint(&out.buf, "{s}\x00upload-alias://{s}\x00", .{ key[0..dev_end], base[0..8] }) catch return null;
    out.len = s.len;
    return out;
}

/// `generated_image_devices`: the owner first, then the fallbacks, deduped.
pub fn generatedImageDevices(owner: []const u8, fallback: []const []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    const all = [_][]const []const u8{ &.{owner}, fallback };
    for (all) |list| for (list) |d| {
        if (d.len == 0 or n >= out.len) continue;
        var dup = false;
        for (out[0..n]) |e| dup = dup or std.mem.eql(u8, e, d);
        if (!dup) {
            out[n] = d;
            n += 1;
        }
    };
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Loader glue for views
// ---------------------------------------------------------------------------

/// `attachment_state`: the effective load state across candidate devices.
/// Starts reads (one per `(device, path)`) and schedules a repaint for the
/// retry backoff. `local_device` is served directly; others are relay-forwarded.
pub fn attachmentState(app: *App, engine: zpui.Entity(es.EngineState), devices: []const []const u8, local_device: ?[]const u8, path: []const u8, expected_mime: ?[]const u8) Snapshot {
    const cache = Cache.of(app);
    var buf: [4096]u8 = undefined;
    for (devices) |d| switch (cache.snapshot(app, keyFor(&buf, d, path, expected_mime))) {
        .loaded => |l| return .{ .loaded = l },
        else => {},
    };
    var any_loading = false;
    var min_retry: ?u64 = null;
    for (devices) |d| {
        const key = keyFor(&buf, d, path, expected_mime);
        if (cache.beginLoad(app, key)) startRead(app, engine, key, d, local_device, path, expected_mime);
        switch (cache.snapshot(app, key)) {
            .loaded => |l| return .{ .loaded = l },
            .loading => {
                if (expected_mime != null) return .loading;
                any_loading = true;
            },
            .failed => |f| min_retry = if (min_retry) |m| @min(m, f.retry_in_ns) else f.retry_in_ns,
        }
    }
    if (any_loading) return .loading;
    if (min_retry) |r| {
        scheduleRepaint(app, r + 60 * std.time.ns_per_ms);
        return .{ .failed = .{ .retry_in_ns = r } };
    }
    return .{ .failed = .{ .retry_in_ns = std.math.maxInt(u64) } };
}

fn startRead(app: *App, engine: zpui.Entity(es.EngineState), key: []const u8, device: []const u8, local_device: ?[]const u8, path: []const u8, expected_mime: ?[]const u8) void {
    const cache = Cache.of(app);
    const st = engine.read(app);
    const conn = st.conn orelse return cache.storeError(app, key);
    const gpa = app.gpa;
    const remote = if (local_device) |l| !std.mem.eql(u8, l, device) else true;
    const job: ReadJob = .{
        .gpa = gpa,
        .client = conn.client(),
        .conn = conn.retain(),
        .key = gpa.dupe(u8, key) catch return cache.storeError(app, key),
        .path = gpa.dupe(u8, path) catch return cache.storeError(app, key),
        .target_device_id = if (remote) (gpa.dupe(u8, device) catch null) else null,
        .expected_mime = if (expected_mime) |m| (gpa.dupe(u8, m) catch null) else null,
        .app = app,
    };
    var task = app.backgroundExecutor().spawn(job) catch {
        var j = job;
        j.deinit();
        return cache.storeError(app, key);
    };
    task.detach();
}

const RepaintJob = struct {
    app: *App,
    pub fn finish(self: *RepaintJob) void {
        self.app.refreshWindows();
    }
};

/// One window refresh after `delay_ns` (retry backoff wake-up).
pub fn scheduleRepaint(app: *App, delay_ns: u64) void {
    var t = app.foregroundExecutor().timer(delay_ns, RepaintJob{ .app = app }) catch return;
    t.detach();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "with_attachments transport" {
    const gpa = testing.allocator;
    const plain = try withAttachments(gpa, "hello", &.{});
    defer gpa.free(plain);
    try testing.expectEqualStrings("hello", plain);
    const two = try withAttachments(gpa, "look at these", &.{ "/data/uploads/ab-cat.png", "/x/dog.jpg" });
    defer gpa.free(two);
    try testing.expectEqualStrings("look at these\n\nAttached images (local files — open them to view):\n- /data/uploads/ab-cat.png\n- /x/dog.jpg", two);
    const only = try withAttachments(gpa, "", &.{"/a/b.png"});
    defer gpa.free(only);
    try testing.expect(std.mem.startsWith(u8, only, attachment_only_text));
}

test "ensure_extension matches the browser heuristic" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, Format, []const u8 }{
        .{ "shot.png", .png, "shot.png" },
        .{ "image", .png, "image.png" },
        .{ "photo.j", .jpeg, "photo.j.jpeg" },
        .{ "archive.tar.gz", .png, "archive.tar.gz" },
    };
    for (cases) |c| {
        const got = try ensureExtension(gpa, c[0], c[1]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "supported formats match the engine jail" {
    try testing.expectEqual(Format.png, Format.fromPath("f.png").?);
    try testing.expectEqual(Format.jpeg, Format.fromPath("f.JPG").?);
    try testing.expectEqual(Format.webp, Format.fromPath("f.webp").?);
    try testing.expectEqual(Format.svg, Format.fromPath("f.svg").?);
    try testing.expectEqual(Format.tiff, Format.fromPath("/a/f.tif").?);
    try testing.expect(Format.fromPath("f.ico") == null);
    try testing.expect(Format.fromPath("f.txt") == null);
}

test "chunk plan and deadlines" {
    try testing.expect(upload_chunk_b64_chars + 1024 < 1_048_576);
    try testing.expectEqual(@as(usize, 0), upload_chunk_b64_chars % 4);
    try testing.expectEqual(@as(usize, 1), chunkCount(0));
    try testing.expectEqual(@as(usize, 2), chunkCount(upload_chunk_b64_chars * 2));
    const tail = chunkRange(upload_chunk_b64_chars + 7, 1);
    try testing.expectEqual(upload_chunk_b64_chars, tail.start);
    try testing.expectEqual(upload_chunk_b64_chars + 7, tail.end);
    try testing.expectEqual(@as(u64, 135), attachmentDeadlineSecs(1));
    try testing.expectEqual(@as(u64, 900), attachmentDeadlineSecs(1_000));
}

test "retry ladder is 2s doubling capped at 15s" {
    try testing.expectEqual(2_000 * std.time.ns_per_ms, retryDelayNs(0));
    try testing.expectEqual(4_000 * std.time.ns_per_ms, retryDelayNs(1));
    try testing.expectEqual(8_000 * std.time.ns_per_ms, retryDelayNs(2));
    try testing.expectEqual(15_000 * std.time.ns_per_ms, retryDelayNs(3));
    try testing.expectEqual(15_000 * std.time.ns_per_ms, retryDelayNs(9));
}

/// A 1x1 32-bit BI_RGB bitmap as the Windows clipboard produces it.
fn clipboardBmp() [58]u8 {
    var bmp: [58]u8 = @splat(0);
    bmp[0] = 'B';
    bmp[1] = 'M';
    const fields = [_]u32{ 58, 0, 54, 40, 1, 1 };
    for (fields, 0..) |f, i| std.mem.writeInt(u32, bmp[2 + i * 4 ..][0..4], f, .little);
    bmp[26] = 1;
    bmp[28] = 32;
    bmp[54] = 30;
    bmp[55] = 20;
    bmp[56] = 10;
    bmp[57] = 0;
    return bmp;
}

test "pasted BMP screenshot is staged as an opaque PNG" {
    const gpa = testing.allocator;
    const bmp = clipboardBmp();
    var o = try stageClipboard(gpa, .bmp, try gpa.dupe(u8, &bmp));
    defer freeOutcome(gpa, &o);
    try testing.expectEqual(Format.png, o.ok.format);
    try testing.expectEqualStrings("image.png", o.ok.name);
    const d = o.ok.decoded.?;
    // BGRA 10,20,30 opaque.
    try testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255 }, d.frames[0].pixels);
}

test "undecodable BMP stays as pasted" {
    const gpa = testing.allocator;
    var o = try stageClipboard(gpa, .bmp, try gpa.dupe(u8, "BM not really a bitmap"));
    defer freeOutcome(gpa, &o);
    try testing.expectEqual(Format.bmp, o.ok.format);
    try testing.expectEqualStrings("image.bmp", o.ok.name);
}

test "upload alias keys" {
    const k = aliasKeyFor("dev\x00/host/uploads/abcd1234-cat.png\x00").?;
    try testing.expectEqualStrings("dev\x00upload-alias://abcd1234\x00", k.slice());
    try testing.expect(aliasKeyFor("dev\x00/host/uploads/cat.png\x00") == null);
}

test "generated image owner candidates" {
    var out: [4][]const u8 = undefined;
    const a = generatedImageDevices("owner", &.{ "host", "local", "owner" }, &out);
    try testing.expectEqual(@as(usize, 3), a.len);
    try testing.expectEqualStrings("owner", a[0]);
    const b = generatedImageDevices("", &.{ "host", "host", "" }, &out);
    try testing.expectEqual(@as(usize, 1), b.len);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(Cache);
    testing.refAllDecls(UploadJob);
    testing.refAllDecls(ReadJob);
    testing.refAllDecls(StageJob);
}
