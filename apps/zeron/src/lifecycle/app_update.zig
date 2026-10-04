//! Desktop self-update (port of zeron `crates/ui/src/app_update.rs`): the app's own
//! release checker plus the download / install lifecycle behind the sidebar update
//! strip, "Check for Updates…" (macOS app menu; the account menu elsewhere) and
//! install-on-quit.
//!
//! A found release downloads in the background and is verified; the strip offers
//! "Update ready — restart to apply"; a staged update the user never restarts for is
//! installed when the app quits. `ZERON_AUTO_UPDATE=0` keeps it report-only. Checks run
//! hourly on a wall-clock schedule (sleep cannot stretch it) with failure backoff, and
//! window activation / system wake `poke` the schedule (see update.zig `Schedule`).
//!
//! `AppUpdate` is an app global entity (`AppUpdate.global(app)`) and also the view that
//! renders the "Check for Updates…" dialog (the shell adds it as a child while
//! `prompt != null`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const ui = @import("../ui/components/root.zig");
const dialog = @import("../ui/components/dialog.zig");
const update = @import("update.zig");
const lifecycle = @import("root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const div = zpui.div;
const px = zpui.px;

const log = std.log.scoped(.zeron_update);

pub const Flow = union(enum) {
    idle,
    downloading: []u8,
    /// Staged and verified: "restart to apply", or installed on quit.
    ready: struct { version: []u8, staged: []u8 },
    failed: struct { version: []u8, message: []u8 },
    /// Swapped in; this process is on its way out.
    installed,

    fn deinit(self: Flow, gpa: Allocator) void {
        switch (self) {
            .downloading => |v| gpa.free(v),
            .ready => |r| {
                gpa.free(r.version);
                gpa.free(r.staged);
            },
            .failed => |f| {
                gpa.free(f.version);
                gpa.free(f.message);
            },
            .idle, .installed => {},
        }
    }
};

pub const Prompt = union(enum) {
    checking,
    /// The check finished; the dialog renders from the live status + flow.
    result,
    check_failed: []u8,
};

pub const StripAction = union(enum) {
    none,
    download,
    restart,
    /// Explain why this install can't update itself (dialog).
    explain,
    /// Advisory installs: open the releases page (unmanaged) and dismiss.
    advise: struct { open_releases: bool },
};

pub const Status = struct {
    latest: ?[]u8 = null,
    available: bool = false,
    checked_at_ms: ?i64 = null,
    err: ?[]u8 = null,
};

pub const Options = struct {
    io: std.Io,
    environ: ?*const std.process.Environ.Map = null,
    data_dir: []const u8,
    /// The validated feed base (null = updates not configured).
    base: ?[]const u8,
    install: update.InstallKind,
    automatic: bool = true,
    /// Start the background schedule (off in tests).
    schedule: bool = true,
};

pub const AppUpdate = struct {
    gpa: Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    data_dir: []const u8,
    base: ?[]const u8,
    install: update.InstallKind,
    blocker: ?update.Blocker,
    automatic: bool,
    status: Status = .{},
    flow: Flow = .idle,
    prompt: ?Prompt = null,
    /// Version whose advisory strip the user dismissed.
    dismissed: ?[]u8 = null,
    schedule: update.Schedule = .{},
    checking: bool = false,
    check_task: Task(CheckResult) = .none,
    user_check_task: Task(CheckResult) = .none,
    download_task: Task(StageResult) = .none,
    tick_task: Task(void) = .none,

    pub fn init(opts: Options, cx: *Context(AppUpdate)) !AppUpdate {
        var self: AppUpdate = .{
            .gpa = cx.gpa(),
            .io = opts.io,
            .environ = opts.environ,
            .arena = .init(cx.gpa()),
            .data_dir = undefined,
            .base = null,
            .install = .unmanaged,
            .blocker = null,
            .automatic = opts.automatic,
        };
        const a = self.arena.allocator();
        self.data_dir = try a.dupe(u8, opts.data_dir);
        if (opts.base) |b| self.base = try a.dupe(u8, b);
        self.install = switch (opts.install) {
            .managed => |p| .{ .managed = try a.dupe(u8, p) },
            .mac_app => |p| .{ .mac_app = try a.dupe(u8, p) },
            .unmanaged => .unmanaged,
        };
        self.blocker = if (self.install.supportsDesktopUpdate()) update.blockerFor(self.install) else null;
        if (opts.schedule and self.base != null) {
            self.tick_task = try cx.timer(update.desktop_initial_delay_ms * std.time.ns_per_ms, onTick);
        }
        log.info("desktop update checker: install={t} feed={s} automatic={}", .{ self.install, self.base orelse "(none)", self.automatic });
        return self;
    }

    pub fn deinit(self: *AppUpdate, _: *App) void {
        self.check_task.cancel();
        self.user_check_task.cancel();
        self.download_task.cancel();
        self.tick_task.cancel();
        self.flow.deinit(self.gpa);
        if (self.prompt) |p| if (p == .check_failed) self.gpa.free(p.check_failed);
        if (self.dismissed) |d| self.gpa.free(d);
        freeStatus(self.gpa, &self.status);
        self.arena.deinit();
    }

    fn freeStatus(gpa: Allocator, s: *Status) void {
        if (s.latest) |l| gpa.free(l);
        if (s.err) |e| gpa.free(e);
        s.* = .{};
    }

    pub fn global(app: *App) ?Entity(AppUpdate) {
        const g = app.tryGlobal(Global) orelse return null;
        return g.entity;
    }

    pub const Global = struct {
        entity: Entity(AppUpdate),
        pub fn deinit(self: *Global, app: *App) void {
            self.entity.release(app);
        }
    };

    fn http(self: *const AppUpdate) update.Http {
        return .{ .gpa = self.gpa, .io = self.io, .environ = self.environ };
    }

    /// The newer release the last check found, if any.
    pub fn available(self: *const AppUpdate) ?[]const u8 {
        if (!self.status.available) return null;
        return self.status.latest;
    }

    /// Whether this app downloads and installs updates itself right now.
    pub fn selfUpdating(self: *const AppUpdate) bool {
        return self.install.supportsDesktopUpdate() and self.blocker == null;
    }

    // ---- schedule ----------------------------------------------------------------------

    fn nowS() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @intCast(ts.sec);
    }

    fn onTick(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        self.tick_task.detach();
        const now = nowS();
        if (!self.checking and self.schedule.due(now)) self.startCheck(false, cx);
        self.tick_task = cx.timer(@as(u64, @intCast(self.schedule.wait(now))) * std.time.ns_per_s, onTick) catch .none;
    }

    /// Window activation / wake: check if one is due by the wall clock.
    pub fn poke(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        if (self.base == null or self.tick_task.header == null) return;
        self.tick_task.cancel();
        self.tick_task = cx.timer(0, onTick) catch .none;
    }

    const CheckJob = struct {
        http: update.Http,
        base: []const u8,
        pub fn run(self: *CheckJob) CheckResult {
            var m = update.fetchLatest(self.http, self.base) catch |err| {
                const msg = std.fmt.allocPrint(self.http.gpa, "{t}", .{err}) catch return .{ .err = null };
                return .{ .err = msg };
            };
            defer m.deinit();
            return .{ .ok = self.http.gpa.dupe(u8, m.version) catch null };
        }
        pub fn discard(self: *CheckJob, r: CheckResult) void {
            r.deinit(self.http.gpa);
        }
    };

    pub const CheckResult = union(enum) {
        ok: ?[]u8,
        err: ?[]u8,
        fn deinit(r: CheckResult, gpa: Allocator) void {
            switch (r) {
                inline else => |v| if (v) |s| gpa.free(s),
            }
        }
    };

    fn startCheck(self: *AppUpdate, user: bool, cx: *Context(AppUpdate)) void {
        const base = self.base orelse return;
        const job: CheckJob = .{ .http = self.http(), .base = base };
        if (user) {
            self.user_check_task.cancel();
            self.user_check_task = cx.spawn(job, onUserChecked) catch .none;
        } else {
            self.checking = true;
            self.check_task = cx.spawn(job, onChecked) catch blk: {
                self.checking = false;
                break :blk .none;
            };
        }
    }

    /// Publish a check (Rust `Updater::publish` / the error path).
    fn record(self: *AppUpdate, r: CheckResult) bool {
        switch (r) {
            .ok => |v| {
                const version = v orelse return false;
                freeStatus(self.gpa, &self.status);
                self.status = .{
                    .latest = version,
                    .available = update.versionNewer(version, update.currentVersion()),
                    .checked_at_ms = nowS() * 1000,
                };
                if (self.status.available) log.info("update available: latest={s} current={s}", .{ version, update.currentVersion() });
                return true;
            },
            .err => |e| {
                if (self.status.err) |old| self.gpa.free(old);
                self.status.err = e;
                log.debug("update check failed: {s}", .{e orelse "?"});
                return false;
            },
        }
    }

    fn onChecked(self: *AppUpdate, r: CheckResult, cx: *Context(AppUpdate)) void {
        self.check_task.detach();
        self.checking = false;
        const ok = self.record(r);
        self.schedule.record(nowS(), ok);
        if (ok and self.automatic) self.downloadIfNeeded(cx);
        cx.notify();
    }

    /// "Check for Updates…": check now and report the outcome in the dialog.
    pub fn checkForUpdates(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        self.setPrompt(.checking);
        if (self.base == null) {
            const msg = self.gpa.dupe(u8, "Updates aren't configured for this build (set ZERON_RELEASES_URL).") catch return;
            self.setPrompt(.{ .check_failed = msg });
            cx.notify();
            return;
        }
        self.startCheck(true, cx);
        cx.notify();
    }

    fn onUserChecked(self: *AppUpdate, r: CheckResult, cx: *Context(AppUpdate)) void {
        self.user_check_task.detach();
        const failure: ?[]u8 = switch (r) {
            .err => |e| if (e) |s| (self.gpa.dupe(u8, s) catch null) else null,
            .ok => null,
        };
        const ok = self.record(r);
        if (ok) {
            self.schedule.record(nowS(), true);
            if (self.automatic) self.downloadIfNeeded(cx);
        }
        // The user may have closed the dialog while it was checking.
        if (self.prompt != null) {
            if (ok) self.setPrompt(.result) else self.setPrompt(.{ .check_failed = failure orelse (self.gpa.dupe(u8, "The update check failed.") catch return) });
        } else if (failure) |f| self.gpa.free(f);
        cx.notify();
    }

    fn setPrompt(self: *AppUpdate, p: ?Prompt) void {
        if (self.prompt) |old| if (old == .check_failed) self.gpa.free(old.check_failed);
        self.prompt = p;
    }

    pub fn dismissPrompt(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        self.setPrompt(null);
        self.user_check_task.cancel();
        cx.notify();
    }

    /// Open the dialog on its current result (the strip's "explain" action).
    pub fn showResult(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        self.setPrompt(.result);
        cx.notify();
    }

    // ---- download / stage ----------------------------------------------------------------

    fn downloadIfNeeded(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        if (!self.selfUpdating()) return;
        const latest = self.available() orelse return;
        switch (self.flow) {
            .downloading, .installed => return,
            .ready => |r| if (!update.versionNewer(latest, r.version)) return,
            .idle, .failed => {},
        }
        self.startDownload(cx);
    }

    const StageJob = struct {
        http: update.Http,
        base: []const u8,
        install: update.InstallKind,
        data_dir: []const u8,
        pub fn run(self: *StageJob) StageResult {
            const gpa = self.http.gpa;
            // Re-read the manifest so a long-lived status still downloads the newest
            // release, with that release's checksums.
            var m = update.fetchLatest(self.http, self.base) catch |err| return failure(gpa, err);
            defer m.deinit();
            if (!update.versionNewer(m.version, update.currentVersion())) return failure(gpa, error.ReleaseFeedNoLongerOffersANewerVersion);
            const staged_path = switch (self.install) {
                .mac_app => update.stageMacApp(gpa, self.http.io, self.http, self.base, &m, self.data_dir),
                .managed => |root| update.stageHeadless(gpa, self.http.io, self.http, self.base, &m, root),
                .unmanaged => error.InstallationDoesNotSupportDesktopUpdates,
            } catch |err| return failure(gpa, err);
            const version = gpa.dupe(u8, m.version) catch {
                gpa.free(staged_path);
                return .{ .err = null };
            };
            return .{ .ok = .{ .version = version, .staged = staged_path } };
        }
        fn failure(gpa: Allocator, err: anyerror) StageResult {
            return .{ .err = std.fmt.allocPrint(gpa, "{t}", .{err}) catch null };
        }
        pub fn discard(self: *StageJob, r: StageResult) void {
            r.deinit(self.http.gpa);
        }
    };

    pub const StageResult = union(enum) {
        ok: struct { version: []u8, staged: []u8 },
        err: ?[]u8,
        fn deinit(r: StageResult, gpa: Allocator) void {
            switch (r) {
                .ok => |o| {
                    gpa.free(o.version);
                    gpa.free(o.staged);
                },
                .err => |e| if (e) |s| gpa.free(s),
            }
        }
    };

    pub fn startDownload(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        if (!self.selfUpdating() or self.flow == .downloading) return;
        const base = self.base orelse return;
        const version = self.gpa.dupe(u8, self.available() orelse return) catch return;
        self.flow.deinit(self.gpa);
        self.flow = .{ .downloading = version };
        self.download_task = cx.spawn(StageJob{ .http = self.http(), .base = base, .install = self.install, .data_dir = self.data_dir }, onStaged) catch blk: {
            self.flow.deinit(self.gpa);
            self.flow = .idle;
            break :blk .none;
        };
        cx.notify();
    }

    fn onStaged(self: *AppUpdate, r: StageResult, cx: *Context(AppUpdate)) void {
        self.download_task.detach();
        const version = switch (self.flow) {
            .downloading => |v| v,
            else => null,
        };
        switch (r) {
            .ok => |o| {
                log.info("update staged: {s} at {s}", .{ o.version, o.staged });
                if (version) |v| self.gpa.free(v);
                self.flow = .{ .ready = .{ .version = o.version, .staged = o.staged } };
            },
            .err => |e| {
                const msg = e orelse (self.gpa.dupe(u8, "unknown error") catch "");
                log.warn("update download failed: {s}", .{msg});
                self.flow = .{ .failed = .{ .version = version orelse (self.gpa.dupe(u8, "") catch &.{}), .message = @constCast(msg) } };
            },
        }
        cx.notify();
    }

    /// The staged update "Restart to update" would install.
    pub fn staged(self: *const AppUpdate) ?[]const u8 {
        return switch (self.flow) {
            .ready => |r| r.staged,
            else => null,
        };
    }

    /// Install the staged update and arrange the relaunch. The caller quits on success.
    pub fn installForRestart(self: *AppUpdate, cx: *Context(AppUpdate)) !void {
        const path = self.staged() orelse return error.NothingStaged;
        const copy = try self.gpa.dupe(u8, path);
        defer self.gpa.free(copy);
        update.applyDesktop(self.gpa, self.io, self.install, copy, true) catch |err| {
            log.err("update apply failed: {t}", .{err});
            const msg = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch return err;
            const version = self.gpa.dupe(u8, self.available() orelse "") catch {
                self.gpa.free(msg);
                return err;
            };
            self.flow.deinit(self.gpa);
            self.flow = .{ .failed = .{ .version = version, .message = msg } };
            cx.notify();
            return err;
        };
        self.flow.deinit(self.gpa);
        self.flow = .installed;
        cx.notify();
    }

    /// Quit hook: a staged update the user never restarted for installs now, so the next
    /// launch is current. Runs synchronously inside the quit.
    pub fn installOnQuit(self: *AppUpdate, _: *Context(AppUpdate)) void {
        if (!self.automatic) return;
        const r = switch (self.flow) {
            .ready => |r| r,
            else => return,
        };
        update.applyDesktop(self.gpa, self.io, self.install, r.staged, false) catch |err| {
            log.warn("installing the staged update on quit failed: {t}", .{err});
            return;
        };
        log.info("installed staged update {s} on quit", .{r.version});
        self.flow.deinit(self.gpa);
        self.flow = .installed;
    }

    pub fn dismissAdvisory(self: *AppUpdate, cx: *Context(AppUpdate)) void {
        if (self.dismissed) |d| self.gpa.free(d);
        self.dismissed = if (self.available()) |v| self.gpa.dupe(u8, v) catch null else null;
        cx.notify();
    }

    /// The sidebar strip: null while there is nothing newer (or the advisory was
    /// dismissed for this version). The label is formatted into `buf`.
    pub fn strip(self: *const AppUpdate, buf: []u8) ?struct { []const u8, StripAction } {
        const latest = self.available() orelse return null;
        if (self.dismissed) |d| if (std.mem.eql(u8, d, latest)) return null;
        return stripFor(buf, self.install, self.blocker != null, self.flow, latest);
    }

    // ---- the "Check for Updates…" dialog ---------------------------------------------------

    pub fn render(self: *AppUpdate, window: *Window, cx: *Context(AppUpdate)) zpui.Div {
        const p = self.prompt orelse return div();
        const theme = ui.theme.get(cx).forPopup();
        const t = &theme;
        const current = update.currentVersion();
        var title_buf: [160]u8 = undefined;
        var body_buf: [512]u8 = undefined;
        const Btn = enum { close_cancel, close, close_ok, close_later, close_hide, check_again, download, restart, open_downloads };
        var buttons: [2]?Btn = .{ null, null };
        var title: []const u8 = "";
        var body: []const u8 = "";
        switch (p) {
            .checking => {
                title = "Checking for updates…";
                body = std.fmt.bufPrint(&body_buf, "You're on Zeron {s}.", .{current}) catch "";
                buttons = .{ .close_cancel, null };
            },
            .check_failed => |msg| {
                title = "Couldn't check for updates";
                body = msg;
                buttons = .{ .close, .check_again };
            },
            .result => if (self.available()) |latest| {
                title = std.fmt.bufPrint(&title_buf, "Zeron {s} is available", .{latest}) catch "";
                if (self.blocker) |b| {
                    body = b.message(&body_buf);
                    buttons = .{ .close_later, .open_downloads };
                } else if (self.install.supportsDesktopUpdate()) switch (self.flow) {
                    .idle => {
                        body = std.fmt.bufPrint(&body_buf, "You're on {s}.", .{current}) catch "";
                        buttons = .{ .close_later, .download };
                    },
                    .downloading, .installed => {
                        body = "Downloading the update in the background — you can keep working.";
                        buttons = .{ .close_hide, null };
                    },
                    .ready => |r| {
                        title = std.fmt.bufPrint(&title_buf, "Zeron {s} is ready", .{r.version}) catch "";
                        body = "Restart to finish updating. If you don't, it installs the next time you quit Zeron.";
                        buttons = .{ .close_later, .restart };
                    },
                    .failed => |f| {
                        body = std.fmt.bufPrint(&body_buf, "The download failed: {s}", .{f.message}) catch "";
                        buttons = .{ .close_later, .download };
                    },
                } else if (self.install == .managed) {
                    body = "Run `zeron update` in a terminal to install it.";
                    buttons = .{ .close_ok, null };
                } else {
                    body = "This copy of Zeron wasn't set up by an installer (for example, a source build), so it can't update itself.";
                    buttons = .{ .close_later, .open_downloads };
                }
            } else {
                title = "Zeron is up to date";
                body = std.fmt.bufPrint(&body_buf, "Version {s} is the newest release.", .{current}) catch "";
                buttons = .{ .close_ok, null };
            },
        }
        var row = div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8));
        for (buttons) |maybe| {
            const b = maybe orelse continue;
            row = row.child(switch (b) {
                .close_cancel, .close, .close_ok, .close_later, .close_hide => dialog.btnGhost(t, switch (b) {
                    .close_cancel => "Cancel",
                    .close => "Close",
                    .close_ok => "OK",
                    .close_later => "Later",
                    else => "Hide",
                }).id("update-prompt-close").onClick(cx.listener(AppUpdate.onClose)),
                .check_again => dialog.btnPrimary(t, "Try again").id("update-prompt-check").onClick(cx.listener(AppUpdate.onCheckAgain)),
                .download => dialog.btnPrimary(t, "Download").id("update-prompt-download").onClick(cx.listener(AppUpdate.onDownload)),
                .restart => dialog.btnPrimary(t, "Restart to update").id("update-prompt-restart").onClick(cx.listener(AppUpdate.onRestart)),
                .open_downloads => dialog.btnPrimary(t, "Open download page").id("update-prompt-downloads").onClick(cx.listener(AppUpdate.onOpenDownloads)),
            });
        }
        const card = dialog.card(t)
            .child(dialog.title(t, zpui.fmt("{s}", .{title})))
            .child(div().mt(px(6)).child(dialog.body(t, zpui.fmt("{s}", .{body}))))
            .child(row);
        return div().child(dialog.modal(window, card, cx.listener(AppUpdate.onScrim)));
    }

    fn onClose(self: *AppUpdate, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AppUpdate)) void {
        self.dismissPrompt(cx);
    }
    fn onScrim(self: *AppUpdate, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(AppUpdate)) void {
        self.dismissPrompt(cx);
    }
    fn onCheckAgain(self: *AppUpdate, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AppUpdate)) void {
        self.checkForUpdates(cx);
    }
    fn onDownload(self: *AppUpdate, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AppUpdate)) void {
        self.startDownload(cx);
    }
    fn onRestart(self: *AppUpdate, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AppUpdate)) void {
        self.dismissPrompt(cx);
        lifecycle.restartToUpdate(cx.app);
    }
    fn onOpenDownloads(self: *AppUpdate, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AppUpdate)) void {
        cx.app.platform.vtable.openUrl(cx.app.platform.ptr, update.latest_release_page);
        self.dismissPrompt(cx);
    }
};

/// Label + click action of the strip (Rust `strip_for`).
pub fn stripFor(buf: []u8, install: update.InstallKind, blocked: bool, flow: Flow, latest: []const u8) struct { []const u8, StripAction } {
    if (install.supportsDesktopUpdate()) {
        if (blocked) return .{ std.fmt.bufPrint(buf, "Update available — v{s}", .{latest}) catch "", .explain };
        return switch (flow) {
            .idle => .{ std.fmt.bufPrint(buf, "Update available — v{s}", .{latest}) catch "", .download },
            .downloading => |v| .{ std.fmt.bufPrint(buf, "Downloading v{s}…", .{v}) catch "", .none },
            .ready => .{ "Update ready — restart to apply", .restart },
            .failed => |f| .{ std.fmt.bufPrint(buf, "Update failed: {s}", .{f.message}) catch "", .download },
            .installed => .{ "Restarting…", .none },
        };
    }
    if (install == .managed) return .{
        std.fmt.bufPrint(buf, "Update available — v{s} · run `zeron update`", .{latest}) catch "",
        .{ .advise = .{ .open_releases = false } },
    };
    return .{
        std.fmt.bufPrint(buf, "Update available — v{s} · download from GitHub", .{latest}) catch "",
        .{ .advise = .{ .open_releases = true } },
    };
}

/// The sidebar strip's click (Rust `StripAction` dispatch in `render_update_strip`).
pub fn onStripClick(app: *App) void {
    const entity = AppUpdate.global(app) orelse return;
    var buf: [128]u8 = undefined;
    const s = entity.read(app).strip(&buf) orelse return;
    switch (s[1]) {
        .none => {},
        .download => entity.update(app, AppUpdate.startDownload, .{}),
        .restart => lifecycle.restartToUpdate(app),
        .explain => entity.update(app, AppUpdate.showResult, .{}),
        .advise => |adv| {
            if (adv.open_releases) app.platform.vtable.openUrl(app.platform.ptr, update.releases_page);
            entity.update(app, AppUpdate.dismissAdvisory, .{});
        },
    }
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "strip follows the flow on self-updating installs (Rust strip_for)" {
    var buf: [128]u8 = undefined;
    const mac: update.InstallKind = .{ .mac_app = "/Applications/Zeron.app" };
    var s = stripFor(&buf, mac, false, .idle, "0.2.86");
    try testing.expectEqualStrings("Update available — v0.2.86", s[0]);
    try testing.expect(s[1] == .download);
    var v = "0.2.86".*;
    s = stripFor(&buf, mac, false, .{ .downloading = &v }, "0.2.86");
    try testing.expectEqualStrings("Downloading v0.2.86…", s[0]);
    try testing.expect(s[1] == .none);
    var staged = "/tmp/Zeron.app".*;
    s = stripFor(&buf, mac, false, .{ .ready = .{ .version = &v, .staged = &staged } }, "0.2.86");
    try testing.expectEqualStrings("Update ready — restart to apply", s[0]);
    try testing.expect(s[1] == .restart);
    var msg = "offline".*;
    s = stripFor(&buf, mac, false, .{ .failed = .{ .version = &v, .message = &msg } }, "0.2.86");
    try testing.expectEqualStrings("Update failed: offline", s[0]);
    try testing.expect(s[1] == .download);
    s = stripFor(&buf, mac, true, .idle, "0.2.86");
    try testing.expect(s[1] == .explain);
}

test "strip advises installs without a desktop path" {
    var buf: [128]u8 = undefined;
    const s = stripFor(&buf, .unmanaged, false, .idle, "0.2.86");
    try testing.expectEqualStrings("Update available — v0.2.86 · download from GitHub", s[0]);
    try testing.expect(s[1].advise.open_releases);
    const managed = stripFor(&buf, .{ .managed = "/home/u/.zeron/app" }, false, .idle, "0.2.86");
    if (@import("builtin").os.tag == .linux) {
        try testing.expect(managed[1] == .download);
    } else {
        try testing.expectEqualStrings("Update available — v0.2.86 · run `zeron update`", managed[0]);
    }
}
