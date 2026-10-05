//! Installing, replacing and removing the new-thread background (zeron
//! `settings.rs` `install_new_thread_composer_background`,
//! `prepare_background_file`, `commit_background`,
//! `remove_new_thread_composer_background`, `set_new_thread_background_*`,
//! and `wallpaper_colors::{set_enabled, ensure_color}`).
//!
//! ```zig
//! install.installAsync(app, "/Users/me/Pictures/dune.jpg"); // decode + copy on a worker
//! install.remove(app);
//! install.lastError(app)  // ?[]const u8 for the Appearance page
//! ```
//!
//! The chosen file is read verbatim, validated by the renderer's decoder,
//! copied to `{data_dir}/new-thread-backgrounds/new-thread-background-<uuid>.<ext>`
//! and persisted (`ui-settings.json` is written before the previous managed
//! copy is deleted). Hand-edited paths outside that directory are never
//! deleted. In fixture mode (in-memory store, no data dir) the source path is
//! referenced directly and nothing is written.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const artwork = @import("artwork.zig");
const cache = @import("cache.zig");
const anim = @import("anim_decode.zig");
const video = @import("video.zig");
const player = @import("player.zig");
const store = @import("../settings/store.zig");

const App = zpui.App;
const Allocator = std.mem.Allocator;
const UiSettings = model.UiSettings;
const att = model.attachments;

pub const backgrounds_dir = "new-thread-backgrounds";
pub const managed_prefix = "new-thread-background-";
pub const history_limit = 8;

pub const msg_unsupported = "This background image is unsupported or damaged. Choose a valid image such as PNG or JPEG.";
pub const msg_restart = "Unable to save the image. Restart Zeron and try again.";
pub const msg_permissions = "Unable to save the image. Check folder permissions and try again.";
pub const msg_remove_permissions = "Unable to remove the image. Check folder permissions and try again.";

// ---- error surface ----------------------------------------------------------

/// The last background/wallpaper error, shown under the Appearance rows
/// (`AppearancePage::background_error`).
pub const Errors = struct {
    gpa: Allocator,
    message: ?[]u8 = null,

    pub fn deinit(self: *Errors, _: *App) void {
        if (self.message) |m| self.gpa.free(m);
    }
};

pub fn setError(app: *App, message: ?[]const u8) void {
    if (app.tryGlobal(Errors) == null) app.setGlobal(Errors{ .gpa = app.gpa }) catch return;
    const e: *Errors = @constCast(app.tryGlobal(Errors).?);
    if (e.message) |m| e.gpa.free(m);
    e.message = if (message) |m| (e.gpa.dupe(u8, m) catch null) else null;
    app.refreshWindows();
}

pub fn lastError(app: *App) ?[]const u8 {
    const e = app.tryGlobal(Errors) orelse return null;
    return e.message;
}

// ---- helpers ----------------------------------------------------------------

/// `wallpaper::remember`: most recent first, unique, at most eight.
pub fn remember(a: Allocator, history: []const []const u8, source: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, try a.dupe(u8, source));
    for (history) |h| {
        if (out.items.len >= history_limit) break;
        if (!std.mem.eql(u8, h, source)) try out.append(a, h);
    }
    return out.items;
}

fn storeOf(app: *App) ?*const model.SettingsStore {
    store.ensure(app);
    return app.tryGlobal(model.SettingsStore);
}

/// The settings' data dir, or null for an in-memory (fixture) store.
pub fn dataDir(app: *App) ?[]const u8 {
    const s = storeOf(app) orelse return null;
    if (!s.persist or s.data_dir.len == 0) return null;
    return s.data_dir;
}

pub fn ioOf(app: *App) std.Io {
    return (storeOf(app) orelse unreachable).io;
}

/// Whether the configured image file exists (`Path::is_file`).
pub fn available(app: *App, s: *const UiSettings) bool {
    const bg = s.newThreadComposerBackground orelse return false;
    if (cache.status(app, bg.path)) |st| if (st == .ready) return true;
    const st = std.Io.Dir.cwd().statFile(ioOf(app), bg.path, .{}) catch return false;
    return st.kind == .file;
}

/// A prewritten managed copy (deleted again unless committed).
pub const Prepared = struct {
    path: []u8,
    name: []u8,
    /// False in fixture mode: `path` is the source itself.
    managed: bool,
    /// A moving background's managed copy (`path` is then its poster still).
    motion: ?[]u8 = null,

    pub fn discard(self: *Prepared, gpa: Allocator, io: std.Io) void {
        if (self.managed) {
            std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
            if (self.motion) |m| std.Io.Dir.cwd().deleteFile(io, m) catch {};
        }
        self.free(gpa);
    }

    pub fn free(self: *Prepared, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.name);
        if (self.motion) |m| gpa.free(m);
        self.* = undefined;
    }
};

/// `stage_file_verbatim`: the exact bytes plus a display name with the right extension.
pub const Staged = struct { bytes: []u8, name: []u8 };

pub fn stageVerbatim(gpa: Allocator, io: std.Io, path: []const u8) error{ OutOfMemory, Failed }!union(enum) { ok: Staged, err: []u8 } {
    const display = att.nameFromPath(path);
    const format = att.Format.fromPath(path) orelse return .{ .err = std.fmt.allocPrint(gpa, "{s} is not a supported image.", .{display}) catch return error.OutOfMemory };
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .err = std.fmt.allocPrint(gpa, "{s} could not be read.", .{display}) catch return error.OutOfMemory };
    if (st.size > att.max_attachment_bytes) return .{ .err = std.fmt.allocPrint(gpa, "{s} is too large (24 MB max).", .{display}) catch return error.OutOfMemory };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(att.max_attachment_bytes + 1)) catch return .{ .err = std.fmt.allocPrint(gpa, "{s} could not be read.", .{display}) catch return error.OutOfMemory };
    const name = att.ensureExtension(gpa, display, format) catch {
        gpa.free(bytes);
        return error.OutOfMemory;
    };
    return .{ .ok = .{ .bytes = bytes, .name = name } };
}

/// `prepare_background_file` (worker-safe). `data_dir == null` references `source`.
pub fn prepareFile(gpa: Allocator, io: std.Io, data_dir: ?[]const u8, source: []const u8, staged: Staged) error{ OutOfMemory, Failed }!Prepared {
    const name = try gpa.dupe(u8, staged.name);
    errdefer gpa.free(name);
    const dir = data_dir orelse return .{ .path = try gpa.dupe(u8, source), .name = name, .managed = false };
    const folder = try std.fs.path.join(gpa, &.{ dir, backgrounds_dir });
    defer gpa.free(folder);
    std.Io.Dir.cwd().createDirPath(io, folder) catch return error.Failed;
    const ext_raw = std.fs.path.extension(staged.name);
    const ext = if (ext_raw.len > 1) ext_raw[1..] else "png";
    var id: [36]u8 = undefined;
    att.uuidV4(io, &id);
    const file = try std.fmt.allocPrint(gpa, "{s}{s}.{s}", .{ managed_prefix, &id, ext });
    defer gpa.free(file);
    const dest = try std.fs.path.join(gpa, &.{ folder, file });
    errdefer gpa.free(dest);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{dest});
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = staged.bytes }) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return error.Failed;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), dest, io) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return error.Failed;
    };
    return .{ .path = dest, .name = name, .managed = true };
}

// ---- moving backgrounds (zpui-only) --------------------------------------------

/// Videos are copied, not read into memory; this caps the managed copy.
pub const max_video_bytes: u64 = 512 * 1024 * 1024;

/// A background file ready to install: a still (exactly Rust's staging and
/// decoding), or a moving one with its poster (first frame).
pub const Loaded = struct {
    /// Verbatim bytes (empty for a video, which is copied from the source).
    staged: Staged,
    /// The still, or the moving file's poster frame.
    image: artwork.Rgba,
    motion: ?anim.Kind = null,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        gpa.free(self.staged.bytes);
        gpa.free(self.staged.name);
        self.image.deinit(gpa);
    }
};

pub const LoadOutcome = union(enum) { ok: Loaded, err: []u8 };

fn headIsVideo(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buf: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return false;
    return anim.looksLikeVideo(buf[0..n]);
}

fn isAnimatableImage(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    for (anim.image_extensions) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    return false;
}

fn errOut(gpa: Allocator, comptime f: []const u8, args: anytype) Allocator.Error!LoadOutcome {
    return .{ .err = try std.fmt.allocPrint(gpa, f, args) };
}

/// Stage and decode `source` (worker-safe). Stills follow Rust exactly
/// (`stage_file_verbatim` + `decode`); GIF / APNG / animated WebP / video
/// become moving backgrounds.
pub fn load(gpa: Allocator, io: std.Io, source: []const u8) Allocator.Error!LoadOutcome {
    const display = att.nameFromPath(source);
    if (anim.isVideoExtension(source) or (att.Format.fromPath(source) == null and headIsVideo(io, source))) {
        const st = std.Io.Dir.cwd().statFile(io, source, .{}) catch return errOut(gpa, "{s} could not be read.", .{display});
        if (st.kind != .file) return errOut(gpa, "{s} could not be read.", .{display});
        if (st.size > max_video_bytes) return errOut(gpa, "{s} is too large (512 MB max).", .{display});
        const poster = video.firstFrame(gpa, source) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => .{ .err = try gpa.dupe(u8, video.msg_unsupported) },
            error.InvalidVideo => .{ .err = try gpa.dupe(u8, video.msg_undecodable) },
        };
        return .{ .ok = .{ .staged = .{ .bytes = &.{}, .name = try gpa.dupe(u8, display) }, .image = poster, .motion = .video } };
    }
    // An animated image above the attachment cap (a still that size keeps Rust's error).
    if (isAnimatableImage(source)) big: {
        const st = std.Io.Dir.cwd().statFile(io, source, .{}) catch break :big;
        if (st.size <= att.max_attachment_bytes or st.size > player.max_image_bytes) break :big;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, source, gpa, .limited(player.max_image_bytes)) catch break :big;
        const kind = anim.classify(bytes);
        if (!kind.isMotion() or kind == .video) {
            gpa.free(bytes);
            break :big;
        }
        const poster = anim.firstFrame(gpa, bytes, kind) catch {
            gpa.free(bytes);
            return .{ .err = try gpa.dupe(u8, msg_unsupported) };
        };
        const name = gpa.dupe(u8, display) catch |e| {
            gpa.free(bytes);
            return e;
        };
        return .{ .ok = .{ .staged = .{ .bytes = bytes, .name = name }, .image = poster, .motion = kind } };
    }
    const staged = switch (stageVerbatim(gpa, io, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .err = try gpa.dupe(u8, msg_unsupported) },
    }) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    const kind = anim.classify(staged.bytes);
    const still = artwork.decode(gpa, staged.bytes);
    if (kind == .gif or kind == .apng or kind == .webp) {
        // Moving: the poster is the animation's first composited frame.
        if (anim.firstFrame(gpa, staged.bytes, kind)) |poster| {
            if (still) |img| {
                var i = img;
                i.deinit(gpa);
            } else |_| {}
            return .{ .ok = .{ .staged = staged, .image = poster, .motion = kind } };
        } else |_| {}
    }
    const image = still catch {
        gpa.free(staged.bytes);
        gpa.free(staged.name);
        return .{ .err = try gpa.dupe(u8, msg_unsupported) };
    };
    return .{ .ok = .{ .staged = staged, .image = image } };
}

fn motionExtension(kind: anim.Kind, name: []const u8) []const u8 {
    const raw = std.fs.path.extension(name);
    const ext = if (raw.len > 1) raw[1..] else "";
    return switch (kind) {
        .gif => "gif",
        // Never `.png`: that is the poster's name.
        .apng => "apng",
        .webp => "webp",
        .video => if (ext.len > 0 and ext.len <= 5) ext else "mp4",
        .still => "png",
    };
}

fn writeAtomic(io: std.Io, dest: []const u8, tmp: []const u8, data: ?[]const u8, copy_from: ?[]const u8) bool {
    const cwd = std.Io.Dir.cwd();
    if (data) |d| {
        cwd.writeFile(io, .{ .sub_path = tmp, .data = d }) catch {
            cwd.deleteFile(io, tmp) catch {};
            return false;
        };
    } else {
        std.Io.Dir.copyFile(cwd, copy_from.?, cwd, tmp, io, .{}) catch {
            cwd.deleteFile(io, tmp) catch {};
            return false;
        };
    }
    std.Io.Dir.rename(cwd, tmp, cwd, dest, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return false;
    };
    return true;
}

/// `prepareFile` for any loaded background: a moving one gets two managed
/// files sharing one id: `<id>.png` (the poster, the setting's `path`, which
/// Rust shows) and `<id>.<gif|apng|webp|mp4|…>` (`motionPath`).
pub fn prepareLoaded(gpa: Allocator, io: std.Io, data_dir: ?[]const u8, source: []const u8, loaded: *const Loaded) error{ OutOfMemory, Failed }!Prepared {
    const kind = loaded.motion orelse return prepareFile(gpa, io, data_dir, source, loaded.staged);
    const name = try gpa.dupe(u8, loaded.staged.name);
    errdefer gpa.free(name);
    const dir = data_dir orelse {
        const path = try gpa.dupe(u8, source);
        errdefer gpa.free(path);
        return .{ .path = path, .name = name, .managed = false, .motion = try gpa.dupe(u8, source) };
    };
    const folder = try std.fs.path.join(gpa, &.{ dir, backgrounds_dir });
    defer gpa.free(folder);
    std.Io.Dir.cwd().createDirPath(io, folder) catch return error.Failed;
    var id: [36]u8 = undefined;
    att.uuidV4(io, &id);
    const motion_file = try std.fmt.allocPrint(gpa, "{s}{s}.{s}", .{ managed_prefix, &id, motionExtension(kind, loaded.staged.name) });
    defer gpa.free(motion_file);
    const motion = try std.fs.path.join(gpa, &.{ folder, motion_file });
    errdefer gpa.free(motion);
    const poster_file = try std.fmt.allocPrint(gpa, "{s}{s}.png", .{ managed_prefix, &id });
    defer gpa.free(poster_file);
    const poster = try std.fs.path.join(gpa, &.{ folder, poster_file });
    errdefer gpa.free(poster);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{motion});
    defer gpa.free(tmp);
    if (!writeAtomic(io, motion, tmp, if (kind == .video) null else loaded.staged.bytes, source)) return error.Failed;
    const img = loaded.image;
    const bgra = try gpa.alloc(u8, img.pixels.len * 4);
    defer gpa.free(bgra);
    for (img.pixels, 0..) |p, i| bgra[i * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
    const png = zpui.image.encodePng(gpa, bgra, img.width, img.height, .bgra) catch {
        std.Io.Dir.cwd().deleteFile(io, motion) catch {};
        return error.Failed;
    };
    defer gpa.free(png);
    const ptmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{poster});
    defer gpa.free(ptmp);
    if (!writeAtomic(io, poster, ptmp, png, null)) {
        std.Io.Dir.cwd().deleteFile(io, motion) catch {};
        return error.Failed;
    }
    return .{ .path = poster, .name = name, .managed = true, .motion = motion };
}

/// Only copies directly inside `{data_dir}/new-thread-backgrounds` are disposable.
pub fn isManaged(data_dir: []const u8, path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    const pdir = std.fs.path.dirname(parent) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(parent), backgrounds_dir) and std.mem.eql(u8, std.mem.trimEnd(u8, pdir, "/"), std.mem.trimEnd(u8, data_dir, "/"));
}

fn removeManaged(app: *App, bg: ?model.settings.NewThreadComposerBackground) void {
    const b = bg orelse return;
    cache.forget(app, b.path);
    player.forget(app, b.path);
    if (b.motionPath) |m| player.forget(app, m);
    const dir = dataDir(app) orelse return;
    if (isManaged(dir, b.path)) std.Io.Dir.cwd().deleteFile(ioOf(app), b.path) catch {};
    if (b.motionPath) |m| if (isManaged(dir, m)) std.Io.Dir.cwd().deleteFile(ioOf(app), m) catch {};
}

/// Write `next` to disk now (no-op for an in-memory store).
fn persist(app: *App, next: *const UiSettings) bool {
    const s = storeOf(app) orelse return false;
    if (!s.persist) return true;
    model.settings.save(next, s.gpa, s.io, s.data_dir) catch return false;
    return true;
}

// ---- commit / remove ----------------------------------------------------------

const CommitCtx = struct { source: []const u8, path: []const u8, name: []const u8, color: ?zt.Color, motion: ?[]const u8 = null };

fn commitMut(c: CommitCtx, s: *UiSettings, a: Allocator) void {
    var history = s.wallpaperHistory;
    if (s.wallpaperSource) |prev| history = remember(a, history, prev) catch history;
    history = remember(a, history, c.source) catch history;
    s.wallpaperHistory = history;
    s.wallpaperSource = a.dupe(u8, c.source) catch c.source;
    s.theme.wallpaper_color = c.color;
    s.newThreadComposerBackground = .{
        .path = a.dupe(u8, c.path) catch return,
        .name = a.dupe(u8, c.name) catch return,
        .adjustment = .{},
        .motionPath = if (c.motion) |m| (a.dupe(u8, m) catch return) else null,
    };
}

/// `commit_background`: persist, then retire the previous managed copy.
/// Takes ownership of `prepared` (discarded on failure). Returns an error message.
pub fn commit(app: *App, source: []const u8, prepared: *Prepared, color: ?zt.Color, preloaded: ?*cache.Source) ?[]const u8 {
    const gpa = app.gpa;
    const io = ioOf(app);
    const current = store.current(app);
    // Persist the pointer before retiring the old file.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var next = current.*;
    const ctx: CommitCtx = .{ .source = source, .path = prepared.path, .name = prepared.name, .color = color, .motion = prepared.motion };
    commitMut(ctx, &next, arena.allocator());
    if (!persist(app, &next)) {
        prepared.discard(gpa, io);
        if (preloaded) |p| p.release();
        return msg_permissions;
    }
    const previous = current.newThreadComposerBackground;
    var prev_copy: ?model.settings.NewThreadComposerBackground = null;
    if (previous) |p| prev_copy = .{
        .path = gpa.dupe(u8, p.path) catch "",
        .name = "",
        .adjustment = .{},
        .motionPath = if (p.motionPath) |m| (gpa.dupe(u8, m) catch null) else null,
    };
    defer if (prev_copy) |p| {
        if (p.path.len > 0) gpa.free(p.path);
        if (p.motionPath) |m| gpa.free(m);
    };
    store.update(app, .immediate, ctx, commitMut);
    if (preloaded) |p| cache.install(app, io, prepared.path, p);
    prepared.free(gpa);
    if (prev_copy) |p| if (p.path.len > 0 and !std.mem.eql(u8, p.path, store.current(app).newThreadComposerBackground.?.path)) removeManaged(app, p);
    if (store.current(app).theme.wallpaper_theme_colors) store.applyTheme(app);
    app.refreshWindows();
    return null;
}

/// `remove_new_thread_composer_background`.
pub fn remove(app: *App) ?[]const u8 {
    const current = store.current(app);
    const previous = current.newThreadComposerBackground orelse {
        setError(app, null);
        return null;
    };
    var next = current.*;
    next.newThreadComposerBackground = null;
    next.wallpaperSource = null;
    next.theme.wallpaper_color = null;
    if (!persist(app, &next)) return msg_remove_permissions;
    const prev_path = app.gpa.dupe(u8, previous.path) catch return msg_remove_permissions;
    defer app.gpa.free(prev_path);
    const prev_motion: ?[]u8 = if (previous.motionPath) |m| (app.gpa.dupe(u8, m) catch return msg_remove_permissions) else null;
    defer if (prev_motion) |m| app.gpa.free(m);
    const Clear = struct {
        fn f(_: void, s: *UiSettings, _: Allocator) void {
            s.newThreadComposerBackground = null;
            s.wallpaperSource = null;
            s.theme.wallpaper_color = null;
        }
    };
    store.update(app, .immediate, {}, Clear.f);
    removeManaged(app, .{ .path = prev_path, .name = "", .motionPath = prev_motion });
    if (store.current(app).theme.wallpaper_theme_colors) store.applyTheme(app);
    app.refreshWindows();
    return null;
}

/// `set_new_thread_background_effect`.
pub fn setEffect(app: *App, effect: artwork.Effect) void {
    const Set = struct {
        fn f(e: artwork.Effect, s: *UiSettings, _: Allocator) void {
            s.newThreadBackgroundEffect = e;
        }
    };
    store.update(app, .immediate, effect, Set.f);
}

/// `set_new_thread_background_adjustment` (only while an image is set).
pub fn setAdjustment(app: *App, adjustment: model.settings.NewThreadBackgroundAdjustment) void {
    const Set = struct {
        fn f(adj: model.settings.NewThreadBackgroundAdjustment, s: *UiSettings, _: Allocator) void {
            if (s.newThreadComposerBackground) |*bg| bg.adjustment = adj.normalized();
        }
    };
    store.update(app, .immediate, adjustment, Set.f);
}

// ---- install (worker) -----------------------------------------------------------

const InstallResult = union(enum) {
    ok: struct { prepared: Prepared, color: ?zt.Color, source: ?*cache.Source },
    err: []u8,
};

const InstallJob = struct {
    app: *App,
    gpa: Allocator,
    io: std.Io,
    source: []u8,
    data_dir: ?[]u8,

    pub fn run(self: *InstallJob) InstallResult {
        return installWork(self.gpa, self.io, self.data_dir, self.source);
    }

    pub fn finish(self: *InstallJob, result: InstallResult) void {
        defer {
            self.gpa.free(self.source);
            if (self.data_dir) |d| self.gpa.free(d);
        }
        switch (result) {
            .err => |m| {
                setError(self.app, m);
                self.gpa.free(m);
            },
            .ok => |v| {
                var prepared = v.prepared;
                setError(self.app, commit(self.app, self.source, &prepared, v.color, v.source));
            },
        }
    }
};

/// Validate, measure and copy `source` (worker-safe; returns owned results).
pub fn installWork(gpa: Allocator, io: std.Io, data_dir: ?[]const u8, source: []const u8) InstallResult {
    const dup = struct {
        fn f(g: Allocator, m: []const u8) InstallResult {
            return .{ .err = g.dupe(u8, m) catch @constCast("") };
        }
    }.f;
    // Do not persist the candidate until the renderer's decoder accepts these exact bytes.
    var loaded = switch (load(gpa, io, source) catch return dup(gpa, msg_unsupported)) {
        .ok => |l| l,
        .err => |m| return .{ .err = m },
    };
    defer loaded.deinit(gpa);
    const image = loaded.image;
    const color = artwork.colorOf(gpa, image);
    const src: ?*cache.Source = if (artwork.Proxy.fromImage(gpa, image)) |p| (cache.Source.create(gpa, p) catch blk: {
        var pp = p;
        pp.deinit(gpa);
        break :blk null;
    }) else |_| null;
    const prepared = prepareLoaded(gpa, io, data_dir, source, &loaded) catch {
        if (src) |s| s.release();
        return dup(gpa, msg_permissions);
    };
    return .{ .ok = .{ .prepared = prepared, .color = color, .source = src } };
}

/// Install `source` as the new-thread background (decode + copy off the main
/// thread; errors land in `lastError`).
pub fn installAsync(app: *App, source: []const u8) void {
    setError(app, null);
    if (storeOf(app) == null) return setError(app, msg_restart);
    const gpa = app.gpa;
    const job: InstallJob = .{
        .app = app,
        .gpa = gpa,
        .io = ioOf(app),
        .source = gpa.dupe(u8, source) catch return,
        .data_dir = if (dataDir(app)) |d| (gpa.dupe(u8, d) catch null) else null,
    };
    var task = app.backgroundExecutor().spawn(job) catch {
        gpa.free(job.source);
        if (job.data_dir) |d| gpa.free(d);
        return;
    };
    task.detach();
}

// ---- wallpaper colors ---------------------------------------------------------

/// `wallpaper_colors::set_enabled`.
pub fn setWallpaperColors(app: *App, enabled: bool) void {
    const Set = struct {
        fn f(e: bool, s: *UiSettings, _: Allocator) void {
            s.theme.wallpaper_theme_colors = e;
        }
    };
    store.update(app, .immediate, enabled, Set.f);
    store.applyTheme(app);
    ensureColor(app);
    app.refreshWindows();
}

const ColorPending = struct {
    path: ?[]u8 = null,
    gpa: Allocator,

    pub fn deinit(self: *ColorPending, _: *App) void {
        if (self.path) |p| self.gpa.free(p);
    }
};

/// Backfill the wallpaper color of a background saved before extraction existed.
pub fn ensureColor(app: *App) void {
    const s = store.current(app);
    if (!s.theme.wallpaper_theme_colors or s.theme.wallpaper_color != null) return;
    const bg = s.newThreadComposerBackground orelse return;
    if (app.tryGlobal(ColorPending)) |p| if (p.path) |pp| if (std.mem.eql(u8, pp, bg.path)) return;
    app.setGlobal(ColorPending{ .gpa = app.gpa, .path = app.gpa.dupe(u8, bg.path) catch null }) catch return;
    const job: ColorJob = .{ .app = app, .gpa = app.gpa, .io = ioOf(app), .path = app.gpa.dupe(u8, bg.path) catch return };
    var task = app.backgroundExecutor().spawn(job) catch {
        app.gpa.free(job.path);
        return;
    };
    task.detach();
}

const ColorJob = struct {
    app: *App,
    gpa: Allocator,
    io: std.Io,
    path: []u8,

    pub fn run(self: *ColorJob) ?zt.Color {
        var image = cache.decodeStill(self.gpa, self.io, self.path) orelse return null;
        defer image.deinit(self.gpa);
        return artwork.colorOf(self.gpa, image);
    }

    pub fn finish(self: *ColorJob, color: ?zt.Color) void {
        defer self.gpa.free(self.path);
        const app = self.app;
        const s = store.current(app);
        const bg = s.newThreadComposerBackground orelse return;
        if (!std.mem.eql(u8, bg.path, self.path) or s.theme.wallpaper_color != null) return;
        const c = color orelse return;
        const Set = struct {
            fn f(v: zt.Color, st: *UiSettings, _: Allocator) void {
                st.theme.wallpaper_color = v;
            }
        };
        store.update(app, .immediate, c, Set.f);
        store.applyTheme(app);
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "history keeps the eight most recent unique sources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: []const []const u8 = &.{};
    var buf: [16]u8 = undefined;
    for (0..10) |i| h = try remember(a, h, try std.fmt.bufPrint(&buf, "/w/{d}", .{i}));
    try testing.expectEqual(@as(usize, 8), h.len);
    try testing.expectEqualStrings("/w/9", h[0]);
    h = try remember(a, h, "/w/5");
    try testing.expectEqualStrings("/w/5", h[0]);
    try testing.expectEqual(@as(usize, 8), h.len);
    var n: usize = 0;
    for (h) |p| if (std.mem.eql(u8, p, "/w/5")) {
        n += 1;
    };
    try testing.expectEqual(@as(usize, 1), n);
}

test "only files directly inside the managed directory are disposable" {
    try testing.expect(isManaged("/d", "/d/new-thread-backgrounds/new-thread-background-x.png"));
    try testing.expect(isManaged("/d/", "/d/new-thread-backgrounds/a.png"));
    try testing.expect(!isManaged("/d", "/elsewhere/new-thread-backgrounds/a.png"));
    try testing.expect(!isManaged("/d", "/d/a.png"));
    try testing.expect(!isManaged("/d", "/d/new-thread-backgrounds/sub/a.png"));
}
