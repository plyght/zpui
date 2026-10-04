//! `BrowserPane`: the right-pane Browser surface — port of zeron `browser/mod.rs`
//! (`BrowserSurface`) + `browser/view.rs`.
//!
//! - toolbar (38px surface chrome): back, forward, reload (stop while loading),
//!   the address field (single-line `TextInput`, globe, "go" button while edited),
//!   open in the default browser; a 2px loading bar under it;
//! - body: the native page, or the empty page — "Preview your work" / the error
//!   page ("Couldn’t load this page", Try again) — or, before the first
//!   navigation, the dev-server previews discovered by `WatchPreviews`;
//! - macOS: a WKWebView native child view (`mac.zig`, placed by `zpui.nativeView`);
//!   Linux: zeron's WebKitGTK helper renders offscreen, frames are painted here and
//!   input is forwarded (`linux.zig`); elsewhere navigation opens the default browser.
//!
//! Tab-surface contract with the right-pane host: `render` (draws its own toolbar),
//! `tabTitle()`, `tabIcon()`, events `NewTab{url}` (target=_blank) and `CloseTab`.
//!
//! ```zig
//! const pane = try cx.newWith(BrowserPane, BrowserPane.init, .{ app_state, chat_id, window });
//! pane.update(cx, BrowserPane.navigate, .{"localhost:3000"});
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model_mod = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const model = @import("model.zig");
const Waker = @import("waker.zig").Waker;

const is_mac = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const MacHost = if (is_mac) @import("mac.zig").Host else opaque {};
const linux_mod = if (is_linux) @import("linux.zig") else struct {
    pub const Page = opaque {};
};
const LinuxPage = linux_mod.Page;

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const Icon = ui.icon.Icon;
const es = model_mod.engine_state;
const Bounds = zpui.Bounds(f32);

const log = std.log.scoped(.zeron_browser);

pub const Reload = zpui.action("browser::Reload");
pub const FocusAddress = zpui.action("browser::FocusAddress");
pub const Back = zpui.action("browser::Back");
pub const Forward = zpui.action("browser::Forward");
pub const CloseTab = zpui.action("browser::CloseTab");
pub const NewTabAction = zpui.action("browser::NewTab");

/// target=_blank / "Open link in new tab" (`url` valid during the emit), or
/// mod-t (`url` null).
pub const NewTab = struct { url: ?[]const u8 };
/// mod-w inside the browser.
pub const CloseRequested = struct {};

/// Smoke-test probe (`ZERON_SMOKE_BROWSER_URL`, smoke.zig): set once a page
/// finished loading without error; `smoke_failed` once it failed.
pub var smoke_loaded: std.atomic.Value(bool) = .init(false);
pub var smoke_failed: std.atomic.Value(bool) = .init(false);

const preview_proxy_port: u16 = 7331;

/// `zeron_proto::PreviewSnapshot` (camelCase JSON; fields the UI reads).
pub const PreviewSnapshot = struct {
    services: []const Service = &.{},
    proxyPort: u16 = preview_proxy_port,
    @"error": ?[]const u8 = null,
    projectName: ?[]const u8 = null,
    remote: bool = false,

    pub const Service = struct {
        id: []const u8 = "",
        name: []const u8 = "",
        hostname: []const u8 = "",
        port: u16 = 0,
        deviceName: []const u8 = "",
    };
};

var bound_app: ?*App = null;

/// The "Browser" key context bindings (zeron `browser::bind_keys` defaults).
fn bindKeys(app: *App) void {
    if (bound_app == app) return;
    bound_app = app;
    app.bindKeys(&.{
        .init("secondary-l", FocusAddress{}, "Browser"),
        .init("secondary-r", Reload{}, "Browser"),
        .init("secondary-[", Back{}, "Browser"),
        .init("secondary-]", Forward{}, "Browser"),
        .init("secondary-t", NewTabAction{}, "Browser"),
        .init("secondary-w", CloseTab{}, "Browser"),
    }) catch |err| log.warn("browser keys: {t}", .{err});
}

pub const BrowserPane = struct {
    gpa: Allocator,
    io: std.Io,
    state: Entity(model_mod.AppState),
    window_id: zpui.WindowId,
    focus: zpui.FocusHandle,
    address: Entity(input.TextInput),
    subs: zpui.Subscriptions = .{},
    page: model.PageState = .{},
    address_edited: bool = false,
    validation: ?[]const u8 = null,
    remote: bool = false,
    presentation: model.Presentation = .live,
    waker: *Waker,

    // Previews (WatchPreviews).
    chat_id: ?[]u8 = null,
    previews: ?std.json.Parsed(PreviewSnapshot) = null,
    previews_loading: bool = true,
    previews_watching: bool = false,
    previews_error: ?[]const u8 = null,
    watch: es.Watch = .{},
    engine_sub: ?zpui.Subscription = null,
    retry_task: zpui.Task(void) = .none,

    // Native hosts.
    mac_host: ?*MacHost = null,
    native_view: ?zpui.NativeViewId = null,
    linux_page: ?*LinuxPage = null,

    pub const Events = .{ NewTab, CloseRequested };

    pub fn init(state: Entity(model_mod.AppState), chat_id: ?[]const u8, window: *Window, cx: *Context(BrowserPane)) !BrowserPane {
        bindKeys(cx.app);
        const theme = ui.theme.get(cx);
        const address = try cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Website or localhost:3000",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 11,
            .line_height = 16,
            .edge_fade = false,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }});
        errdefer address.release(cx);
        const weak = cx.weakEntity();
        const waker = try Waker.create(cx.gpa(), cx.app, @intFromEnum(weak.id), onWake);
        var self: BrowserPane = .{
            .gpa = cx.gpa(),
            .io = state.read(cx).workspace.read(cx).io,
            .state = state.retain(cx),
            .window_id = window.id,
            .focus = cx.focusHandle(),
            .address = address,
            .waker = waker,
        };
        try self.subs.add(cx.gpa(), try cx.subscribe(address, onAddressEvent));
        if (chat_id) |c| self.watchPreviews(c, cx);
        return self;
    }

    pub fn deinit(self: *BrowserPane, app: *App) void {
        self.closeNative(app);
        self.waker.disarm();
        self.waker.release();
        self.subs.deinit(self.gpa);
        if (self.engine_sub) |*s| s.deinit();
        self.retry_task.cancel();
        self.watch.close();
        if (self.previews) |p| p.deinit();
        if (self.chat_id) |c| self.gpa.free(c);
        self.page.deinit(self.gpa);
        self.address.release(app);
        self.focus.release(app);
        self.state.release(app);
    }

    fn closeNative(self: *BrowserPane, app: *App) void {
        if (is_mac) {
            if (self.native_view) |v| if (app.windowById(self.window_id)) |w| w.detachNativeView(v);
            self.native_view = null;
            if (self.mac_host) |h| h.destroy();
            self.mac_host = null;
        }
        if (is_linux) {
            if (self.linux_page) |p| p.destroy();
            self.linux_page = null;
        }
    }

    // ---- tab surface contract -----------------------------------------------------------

    pub fn tabTitle(self: *const BrowserPane) []const u8 {
        return self.page.label();
    }

    pub fn tabIcon(_: *const BrowserPane) Icon {
        return .globe;
    }

    pub fn focusHandle(self: *const BrowserPane) zpui.FocusHandle {
        return self.focus;
    }

    pub fn hasNative(self: *const BrowserPane) bool {
        return self.mac_host != null or self.linux_page != null;
    }

    // ---- navigation (Rust `navigate` / `submit` / `reload` / `history`) ----------------

    pub fn navigate(self: *BrowserPane, text: []const u8, cx: *Context(BrowserPane)) void {
        const url = model.normalizeAddress(self.gpa, text) catch |err| {
            self.validation = switch (err) {
                error.OutOfMemory => "Out of memory.",
                else => |e| model.message(e),
            };
            cx.notify();
            return;
        };
        defer self.gpa.free(url);
        self.navigateUrl(url, cx);
    }

    /// Load an already-normalized http(s) URL (preview rows, new tabs, smoke).
    pub fn navigateUrl(self: *BrowserPane, url: []const u8, cx: *Context(BrowserPane)) void {
        self.validation = null;
        self.address.update(cx, input.TextInput.setText, .{url});
        self.address_edited = false;
        self.page.setUrl(self.gpa, url);
        self.page.setTitle(self.gpa, "");
        self.page.setError(self.gpa, null);
        self.page.progress = null;
        smoke_loaded.store(false, .release);
        var ok = true;
        if (is_mac) {
            if (self.mac_host == null) self.mac_host = MacHost.create(self.gpa, self.waker) catch |err| blk: {
                self.setOpenError(err);
                ok = false;
                break :blk null;
            };
            if (self.mac_host) |h| h.load(url) catch |err| {
                self.setOpenError(err);
                ok = false;
            };
        } else if (is_linux) {
            if (self.linux_page == null) self.linux_page = LinuxPage.create(self.gpa, self.io, self.waker) catch |err| blk: {
                self.setOpenError(err);
                ok = false;
                break :blk null;
            };
            if (self.linux_page) |p| {
                p.present(self.presentation);
                if (!p.load(url)) {
                    self.page.setError(self.gpa, "Could not open this page: the browser helper is not running.");
                    ok = false;
                }
            }
        } else {
            cx.app.platform.vtable.openUrl(cx.app.platform.ptr, url);
        }
        self.page.loading = ok and (is_mac or is_linux);
        if (cx.app.windowById(self.window_id)) |w| w.focus(self.focus);
        cx.notify();
    }

    fn setOpenError(self: *BrowserPane, err: anyerror) void {
        var buf: [256]u8 = undefined;
        const detail = switch (err) {
            error.HelperNotFound => "the WebKitGTK helper (zeron-webkit) was not found next to zeron. Install the WebKitGTK 4.1 runtime and rebuild, or set ZERON_WEBKIT_HELPER.",
            error.HelperSpawnFailed => "WebKitGTK could not start. Install the WebKitGTK 4.1 runtime for your distribution.",
            error.WebKitUnavailable => "WebKit is unavailable.",
            else => @errorName(err),
        };
        const msg = std.fmt.bufPrint(&buf, "Could not open this page: {s}", .{detail}) catch "Could not open this page.";
        self.page.setError(self.gpa, msg);
        smoke_failed.store(true, .release);
    }

    fn submit(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        const text = self.gpa.dupe(u8, self.address.read(cx).text()) catch return;
        defer self.gpa.free(text);
        self.navigate(text, cx);
    }

    pub fn reload(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        const had_error = self.page.@"error" != null;
        if (had_error) if (self.page.url) |u| {
            const url = self.gpa.dupe(u8, u) catch return;
            defer self.gpa.free(url);
            return self.navigateUrl(url, cx);
        };
        if (is_mac) if (self.mac_host) |h| h.reload();
        if (is_linux) if (self.linux_page) |p| p.reload();
        if (!self.hasNative()) self.openExternal(cx);
        cx.notify();
    }

    pub fn stop(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        if (is_mac) if (self.mac_host) |h| h.stop();
        // zeron's WebKitGTK helper has no stop command; a reload replaces the load.
        cx.notify();
    }

    pub fn history(self: *BrowserPane, forward: bool, cx: *Context(BrowserPane)) void {
        if (is_mac) if (self.mac_host) |h| h.history(forward);
        if (is_linux) if (self.linux_page) |p| p.history(forward);
        cx.notify();
    }

    pub fn openExternal(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        const url = self.page.url orelse return;
        if (!model.allowedNavigation(url)) return;
        cx.app.platform.vtable.openUrl(cx.app.platform.ptr, url);
    }

    pub fn focusAddress(self: *BrowserPane, window: *Window, cx: *Context(BrowserPane)) void {
        if (is_mac) if (self.native_view != null) window.focusNativeView(null);
        window.focus(self.address.read(cx).focusHandle());
        self.address.update(cx, input.TextInput.selectAllText, .{});
    }

    /// Hide/show native content (the host's active-tab state; Rust `set_presentation`).
    pub fn setPresentation(self: *BrowserPane, p: model.Presentation, cx: *Context(BrowserPane)) void {
        if (self.presentation == p) return;
        self.presentation = p;
        if (is_linux) if (self.linux_page) |page| page.present(p);
        cx.notify();
    }

    // ---- native events (Rust `on_native_event`) -----------------------------------------

    fn onWake(bits: u64, app: *App) void {
        const weak: zpui.WeakEntity(BrowserPane) = .{ .id = @enumFromInt(bits) };
        const e = weak.upgrade(app) orelse return;
        defer e.release(app);
        e.update(app, onNative, .{});
    }

    fn onNative(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        var changed = false;
        if (is_mac) if (self.mac_host) |h| {
            changed = h.state(&self.page);
            var tabs = h.takeNewTabs();
            defer {
                for (tabs.items) |u| self.gpa.free(u);
                tabs.deinit(self.gpa);
            }
            if (self.presentation == .live) for (tabs.items) |u| cx.emit(NewTab{ .url = u });
        };
        if (is_linux) if (self.linux_page) |p| {
            var d = p.drain();
            defer d.deinit(self.gpa);
            if (d.state) |s| {
                const v = s.value;
                var snap: model.PageState = .{
                    .url = @constCast(if (v.url) |u| (if (u.len > 0) u else self.page.url) else self.page.url),
                    .title = @constCast(v.title),
                    .@"error" = @constCast(v.@"error"),
                    .loading = v.loading and v.@"error" == null,
                    .can_back = v.can_back,
                    .can_forward = v.can_forward,
                };
                _ = &snap;
                changed = self.page.assign(self.gpa, snap) or changed;
            }
            if (d.helper_died and self.page.@"error" == null) {
                self.page.setError(self.gpa, "The browser helper stopped. Check that WebKitGTK 4.1 is installed, then reopen the tab.");
                self.page.loading = false;
                changed = true;
            }
            if (d.clipboard) |text| cx.app.platform.vtable.writeClipboard(cx.app.platform.ptr, text);
            if (self.presentation == .live) for (d.new_tabs.items) |u| cx.emit(NewTab{ .url = u });
        };
        // Keep the address in sync unless the user is editing it.
        if (!self.addressFocused(cx)) if (self.page.url) |u| {
            if (!std.mem.eql(u8, self.address.read(cx).text(), u)) self.address.update(cx, input.TextInput.setText, .{u});
            self.address_edited = false;
        };
        if (self.page.url != null and !self.page.loading) {
            if (self.page.@"error" == null) smoke_loaded.store(true, .release) else smoke_failed.store(true, .release);
        }
        cx.notify();
    }

    fn addressFocused(self: *BrowserPane, cx: *Context(BrowserPane)) bool {
        const w = cx.app.windowById(self.window_id) orelse return false;
        return self.address.read(cx).isFocused(w);
    }

    fn onAddressEvent(self: *BrowserPane, entity: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(BrowserPane)) void {
        switch (ev.*) {
            .edited => {
                const t = entity.read(cx).text();
                self.address_edited = !std.mem.eql(u8, t, self.page.url orelse "");
                self.validation = null;
                cx.notify();
            },
            .submitted, .modified_submitted => self.submit(cx),
            .escape => if (cx.app.windowById(self.window_id)) |w| self.restoreAddress(w, cx),
            else => {},
        }
    }

    /// Escape in the address: restore the page URL and give focus back to the page.
    fn restoreAddress(self: *BrowserPane, window: *Window, cx: *Context(BrowserPane)) void {
        const copy = self.gpa.dupe(u8, self.page.url orelse "") catch return;
        defer self.gpa.free(copy);
        self.address.update(cx, input.TextInput.setText, .{copy});
        self.address_edited = false;
        self.validation = null;
        window.focus(self.focus);
        cx.notify();
    }

    // ---- previews (Rust `watch_previews`) ------------------------------------------------

    fn watchPreviews(self: *BrowserPane, chat_id: []const u8, cx: *Context(BrowserPane)) void {
        self.chat_id = self.gpa.dupe(u8, chat_id) catch return;
        self.previews_watching = true;
        const engine = self.state.read(cx).engine;
        self.engine_sub = cx.subscribe(engine, onEngineEvent) catch null;
        self.openWatch(cx);
    }

    fn openWatch(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        const chat = self.chat_id orelse return;
        const conn = self.state.read(cx).engine.read(cx).conn orelse return;
        self.watch.open(conn, .WatchPreviews, .{ .chatId = chat }) catch {
            self.previewsDown(cx);
        };
    }

    fn previewsDown(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        if (self.previews) |p| p.deinit();
        self.previews = null;
        self.previews_error = "Connecting to preview discovery\u{2026}";
        self.previews_loading = false;
        cx.notify();
        if (self.retry_task.header == null) self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch .none;
    }

    fn onRetry(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        self.retry_task.detach();
        if (!self.watch.isOpen()) self.openWatch(cx);
    }

    fn onEngineEvent(self: *BrowserPane, _: Entity(es.EngineState), ev: *const es.EngineEvent, cx: *Context(BrowserPane)) void {
        switch (ev.*) {
            .connected => self.openWatch(cx),
            .disconnected => {
                self.retry_task.cancel();
                self.watch.close();
            },
            .wake => self.drainPreviews(cx),
        }
    }

    fn drainPreviews(self: *BrowserPane, cx: *Context(BrowserPane)) void {
        while (self.watch.next()) |payload| {
            const parsed = engine_mod.rpc.decode(PreviewSnapshot, payload) catch |err| {
                log.warn("dropping malformed preview frame: {t}", .{err});
                continue;
            };
            self.setPreviews(parsed, cx);
        }
        if (self.watch.isOpen()) switch (self.watch.end(null)) {
            .open => {},
            .closed => self.watch.close(),
            .unknown_method => {
                self.watch.unsupported = true;
                self.watch.close();
            },
            .done, .remote => {
                self.watch.close();
                self.previewsDown(cx);
            },
        };
    }

    fn setPreviews(self: *BrowserPane, parsed: std.json.Parsed(PreviewSnapshot), cx: *Context(BrowserPane)) void {
        if (self.previews) |p| p.deinit();
        self.previews = parsed;
        self.previews_error = null;
        self.previews_loading = false;
        cx.notify();
    }

    /// Engine-free feed (fixtures): `bytes` is one `WatchPreviews` frame.
    pub fn applyPreviewFixture(self: *BrowserPane, bytes: []const u8, cx: *Context(BrowserPane)) void {
        const parsed = std.json.parseFromSlice(PreviewSnapshot, self.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            log.warn("previews fixture: {t}", .{err});
            return;
        };
        self.previews_watching = true;
        self.setPreviews(parsed, cx);
    }

    // ---- listeners ------------------------------------------------------------------------

    fn onBack(self: *BrowserPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        self.history(false, cx);
    }
    fn onForward(self: *BrowserPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        self.history(true, cx);
    }
    fn onReloadClick(self: *BrowserPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        if (self.page.loading) self.stop(cx) else self.reload(cx);
    }
    fn onExternal(self: *BrowserPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        self.openExternal(cx);
    }
    fn onGo(self: *BrowserPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        self.submit(cx);
    }
    fn onAddressDown(self: *BrowserPane, _: *const zpui.input.MouseDownEvent, window: *Window, _: *Context(BrowserPane)) void {
        // Take the keyboard back from the web view (Rust `focus_chrome`).
        if (is_mac) if (self.native_view != null) window.focusNativeView(null);
    }
    fn onGoDown(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
        window.preventDefault();
    }
    fn onEmptyAction(self: *BrowserPane, _: *const zpui.ClickEvent, window: *Window, cx: *Context(BrowserPane)) void {
        if (self.page.@"error" != null) self.reload(cx) else self.focusAddress(window, cx);
    }
    fn onEnterAddress(self: *BrowserPane, _: *const zpui.ClickEvent, window: *Window, cx: *Context(BrowserPane)) void {
        self.focusAddress(window, cx);
    }
    fn onPreview(self: *BrowserPane, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        cx.stopPropagation();
        const snap = (self.previews orelse return).value;
        if (ix >= snap.services.len or snap.@"error" != null) return;
        const s = snap.services[ix];
        const url = std.fmt.allocPrint(self.gpa, "http://{s}:{d}/", .{ s.hostname, snap.proxyPort }) catch return;
        defer self.gpa.free(url);
        self.navigateUrl(url, cx);
    }

    fn actReload(self: *BrowserPane, _: *const Reload, _: *Window, cx: *Context(BrowserPane)) void {
        self.reload(cx);
    }
    fn actFocusAddress(self: *BrowserPane, _: *const FocusAddress, window: *Window, cx: *Context(BrowserPane)) void {
        self.focusAddress(window, cx);
    }
    fn actBack(self: *BrowserPane, _: *const Back, _: *Window, cx: *Context(BrowserPane)) void {
        self.history(false, cx);
    }
    fn actForward(self: *BrowserPane, _: *const Forward, _: *Window, cx: *Context(BrowserPane)) void {
        self.history(true, cx);
    }
    fn actNewTab(_: *BrowserPane, _: *const NewTabAction, _: *Window, cx: *Context(BrowserPane)) void {
        cx.emit(NewTab{ .url = null });
    }
    fn actClose(_: *BrowserPane, _: *const CloseTab, _: *Window, cx: *Context(BrowserPane)) void {
        cx.emit(CloseRequested{});
    }

    // Linux: forward page input to the helper (Rust view.rs `linux_pointer`, `key_down`).
    fn onPageDown(self: *BrowserPane, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        if (cx.app.hasActiveDrag()) return;
        window.focus(self.focus);
        p.pointer("down", ev.position, ev.button, ev.modifiers);
        cx.stopPropagation();
    }
    fn onPageUp(self: *BrowserPane, ev: *const zpui.input.MouseUpEvent, _: *Window, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        p.pointer("up", ev.position, ev.button, ev.modifiers);
        cx.stopPropagation();
    }
    fn onPageUpOut(self: *BrowserPane, ev: *const zpui.input.MouseUpEvent, _: *Window, _: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        p.pointer("up", ev.position, ev.button, ev.modifiers);
    }
    fn onPageMove(self: *BrowserPane, ev: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        if (cx.app.hasActiveDrag()) return;
        p.pointer("move", ev.position, ev.pressed_button, ev.modifiers);
    }
    fn onPageScroll(self: *BrowserPane, ev: *const zpui.input.ScrollWheelEvent, _: *Window, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        const d = switch (ev.delta) {
            .pixels => |v| v,
            .lines => |v| zpui.Point(f32){ .x = v.x * 16, .y = v.y * 16 },
        };
        p.scroll(ev.position, d.x, d.y, ev.modifiers);
        cx.stopPropagation();
    }
    fn onKeyDown(self: *BrowserPane, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Context(BrowserPane)) void {
        // The address field ("PaletteSearch" context) leaves enter/escape to its owner.
        const m = ev.keystroke.modifiers;
        if (self.address.read(cx).isFocused(window) and !m.secondary() and !m.alt) {
            if (std.mem.eql(u8, ev.keystroke.key, "enter") and !m.shift) {
                self.submit(cx);
                cx.stopPropagation();
            } else if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
                self.restoreAddress(window, cx);
                cx.stopPropagation();
            }
            return;
        }
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        if (p.menu != null) {
            self.menuKey(ev.keystroke.key, cx);
            cx.stopPropagation();
            return;
        }
        if (!self.focus.isFocused(window) or self.presentation != .live) return;
        const k = ev.keystroke;
        if (k.modifiers.control and !k.modifiers.alt) {
            if (std.mem.eql(u8, k.key, "c") or std.mem.eql(u8, k.key, "x")) {
                _ = p.command(.{ .cmd = if (k.key[0] == 'c') "copy" else "cut" });
                cx.stopPropagation();
                return;
            }
            if (std.mem.eql(u8, k.key, "v")) {
                if (cx.app.platform.vtable.readClipboard(cx.app.platform.ptr, self.gpa)) |text| {
                    defer self.gpa.free(text);
                    _ = p.command(.{ .cmd = "text", .text = text });
                }
                cx.stopPropagation();
                return;
            }
        }
        p.key(k, true);
        cx.stopPropagation();
    }
    fn onKeyUp(self: *BrowserPane, ev: *const zpui.input.KeyUpEvent, window: *Window, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        if (!self.focus.isFocused(window)) return;
        p.key(ev.keystroke, false);
        cx.stopPropagation();
    }

    fn menuKey(self: *BrowserPane, key: []const u8, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        const m = p.menu orelse return;
        const items = m.value.items;
        if (std.mem.eql(u8, key, "escape")) {
            p.dismissMenu();
        } else if (std.mem.eql(u8, key, "enter")) {
            self.chooseMenu(p.menu_active, cx);
        } else if ((std.mem.eql(u8, key, "up") or std.mem.eql(u8, key, "down")) and items.len > 0) {
            for (0..items.len) |_| {
                p.menu_active = if (key[0] == 'd') (p.menu_active + 1) % items.len else (p.menu_active + items.len - 1) % items.len;
                if (items[p.menu_active].enabled) break;
            }
        }
        cx.notify();
    }

    fn chooseMenu(self: *BrowserPane, index: usize, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        if (p.menu) |m| if (index < m.value.items.len and m.value.items[index].enabled) {
            const action = m.value.items[index].action;
            if (std.mem.eql(u8, action, "text")) {
                if (cx.app.platform.vtable.readClipboard(cx.app.platform.ptr, self.gpa)) |text| {
                    defer self.gpa.free(text);
                    _ = p.command(.{ .cmd = "text", .text = text });
                }
            } else _ = p.command(.{ .cmd = action });
        };
        p.dismissMenu();
        cx.notify();
    }

    fn onMenuRow(self: *BrowserPane, index: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(BrowserPane)) void {
        cx.stopPropagation();
        self.chooseMenu(index, cx);
    }
    fn onMenuOut(self: *BrowserPane, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(BrowserPane)) void {
        if (!is_linux) return;
        if (self.linux_page) |p| p.dismissMenu();
        cx.notify();
    }

    // ---- render -----------------------------------------------------------------------------

    pub fn render(self: *BrowserPane, window: *Window, cx: *Context(BrowserPane)) zpui.StatefulDiv {
        const theme = ui.theme.get(cx);
        const address_focused = self.address.read(cx).isFocused(window);
        const has_page = self.page.url != null;
        const external = !(is_mac or is_linux);

        var toolbar = surfaceToolbar(theme);
        if (!external) toolbar = toolbar
            .child(toolbarButton("browser-back", .arrow_left, "Back", self.page.can_back, theme).when(self.page.can_back, zpui.StatefulDiv.onClick, .{cx.listener(onBack)}))
            .child(toolbarButton("browser-forward", .arrow_right, "Forward", self.page.can_forward, theme).when(self.page.can_forward, zpui.StatefulDiv.onClick, .{cx.listener(onForward)}))
            .child(toolbarButton("browser-reload", if (self.page.loading) .close else .refresh, if (self.page.loading) "Stop loading" else "Reload page", has_page, theme)
                .when(has_page, zpui.StatefulDiv.onClick, .{cx.listener(onReloadClick)}));
        var address = div().id("browser-address").h(px(24)).minW0().flex1().px(px(8)).rounded(px(6)).bg(theme.ink(0.035))
            .flex().itemsCenter().gap(px(6))
            .onMouseDown(.left, cx.listener(onAddressDown))
            .child(ui.icon.of(.globe, 12, theme.text_faint))
            .child(div().flex1().minW0().h(px(16)).overflowHidden().child(self.address));
        if (self.validation != null) address = address.border1().borderColor(theme.danger);
        if (address_focused or self.address_edited) address = address.child(div().id("browser-go").size(px(18)).flexNone().rounded(px(4))
            .flex().itemsCenter().justifyCenter().cursorPointer().hover(sb.bg(theme.wash(0.10)))
            .onMouseDown(.left, onGoDown)
            .onClick(cx.listener(onGo))
            .tooltipWith(@as([]const u8, "Go to address"), ui.tooltip.build)
            .child(ui.icon.of(.@"return", 12, theme.text_muted)));
        toolbar = toolbar.child(address)
            .child(toolbarButton("browser-external", .arrow_up_right, "Open in default browser", has_page, theme).when(has_page, zpui.StatefulDiv.onClick, .{cx.listener(onExternal)}));

        var root = div().id("browser-surface").sizeFull().flex().flexCol().relative()
            .trackFocus(self.focus).keyContext("Browser")
            .onKeyDown(cx.listener(onKeyDown))
            .onKeyUp(cx.listener(onKeyUp))
            .onAction(Reload, cx.listener(actReload))
            .onAction(FocusAddress, cx.listener(actFocusAddress))
            .onAction(Back, cx.listener(actBack))
            .onAction(Forward, cx.listener(actForward))
            .onAction(NewTabAction, cx.listener(actNewTab))
            .onAction(CloseTab, cx.listener(actClose))
            .child(div().relative().flexNone().child(toolbar).child(self.progressBar(theme)));
        if (self.validation) |v| root = root.child(div().px(px(12)).py(px(8)).textSize(ui.rems(11)).textColor(theme.danger).child(v));
        if (self.remote and has_page and model.loopbackUrl(self.page.url.?)) root = root.child(div().px(px(12)).py(px(8)).borderB1().borderColor(theme.border)
            .textSize(ui.rems(11)).textColor(theme.text_muted)
            .child("Localhost opens on this device. Open a detected preview from a new tab to reach your other device."));

        var body = div().id("browser-page").relative().flex1().minH0().overflowHidden();
        if (has_page) body = body.bg(theme.bg);
        if (self.hasNative() and self.page.@"error" == null) {
            body = self.nativeBody(body, window, cx);
        } else {
            body = body.child(self.emptyBody(theme, cx));
        }
        root = root.child(body);
        if (external) root = root.child(div().h(px(26)).px(px(10)).flex().itemsCenter().gap(px(5)).borderT1().borderColor(theme.border)
            .textSize(ui.rems(10)).textColor(theme.text_faint)
            .child(ui.icon.of(.arrow_up_right, 11, theme.text_faint)).child("Opens in your default browser"));
        return root;
    }

    fn progressBar(self: *const BrowserPane, theme: *const Theme) ?zpui.AnyElement {
        if (!self.page.loading) return null;
        const track = div().absolute().left(px(0)).right(px(0)).bottom(px(0)).h(px(2)).overflowHidden();
        if (self.page.progress) |p| {
            const frac = std.math.clamp(p, 0.08, 1);
            return zpui.intoAnyElement(track.child(div().hFull().w(zpui.relative(frac)).bg(theme.accent)));
        }
        // Indeterminate (WebKitGTK reports no progress): a sliding segment.
        const Slide = struct {
            fn f(el: zpui.Div, t: f32) zpui.Div {
                return el.left(zpui.relative(-0.3 + 1.3 * t));
            }
        };
        return zpui.intoAnyElement(track.child(zpui.withAnimation(div().absolute().top(px(0)).hFull().w(zpui.relative(0.3)).bg(theme.accent),
            "browser-progress", zpui.Animation.ms(1100).repeat().withEasing(zpui.easing.ease_in_out), Slide.f)));
    }

    fn nativeBody(self: *BrowserPane, body: zpui.StatefulDiv, window: *Window, cx: *Context(BrowserPane)) zpui.StatefulDiv {
        if (is_mac) {
            const h = self.mac_host.?;
            if (self.native_view == null) self.native_view = window.attachNativeView(h.view(), .{}) catch |err| blk: {
                log.err("attach web view: {t}", .{err});
                break :blk null;
            };
            const v = self.native_view orelse return body;
            return body.child(zpui.nativeView(v).absolute().inset0());
        }
        if (is_linux) {
            const theme = ui.theme.get(cx);
            var b = body
                .onMouseDown(.left, cx.listener(onPageDown))
                .onMouseDown(.right, cx.listener(onPageDown))
                .onMouseDown(.middle, cx.listener(onPageDown))
                .onMouseUp(.left, cx.listener(onPageUp))
                .onMouseUp(.right, cx.listener(onPageUp))
                .onMouseUp(.middle, cx.listener(onPageUp))
                .onMouseUpOut(.left, cx.listener(onPageUpOut))
                .onMouseMove(cx.listener(onPageMove))
                .onScrollWheel(cx.listener(onPageScroll))
                .child(zpui.canvas(self, paintLinux).absolute().inset0());
            if (self.linuxMenu(theme, cx)) |m| b = b.child(m);
            return b;
        }
        return body;
    }

    fn paintLinux(self: *BrowserPane, bounds: Bounds, window: *Window, _: *App) void {
        if (!is_linux) return;
        const p = self.linux_page orelse return;
        p.evictStale(window);
        p.sync(bounds, window.scaleFactor());
        const img = p.image orelse return;
        // The page's own background under not-yet-painted tiles (Rust: first pixel).
        if (img.asBytes(0)) |bytes| if (bytes.len >= 4) {
            window.paintQuad(zpui.fill(bounds, zpui.rgb((@as(u32, bytes[2]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[0]).toHsla()));
        };
        // Keep the previous frame at its own scale while WebKit reflows: clip, never stretch.
        const size = img.size(0);
        const viewport: Bounds = .{ .origin = bounds.origin, .size = .{
            .width = @as(f32, @floatFromInt(size.width)) / p.image_scale,
            .height = @as(f32, @floatFromInt(size.height)) / p.image_scale,
        } };
        window.paintImage(viewport, zpui.Corners(f32).all(0), img, 0, false);
    }

    fn linuxMenu(self: *BrowserPane, theme: *const Theme, cx: *Context(BrowserPane)) ?zpui.AnyElement {
        if (!is_linux) return null;
        const p = self.linux_page orelse return null;
        const m = p.menu orelse return null;
        const pt = zpui.window.arena_mod.current().create(Theme, theme.forPopup());
        var rows = div().id("browser-menu-options").flex().flexCol().maxH(px(320)).overflowYScroll();
        for (m.value.items, 0..) |item, i| {
            var row = ui.popover.menuRow(pt, i == p.menu_active).id(.{ "browser-option", i }).child(item.label);
            row = if (item.enabled) row.onClick(cx.listenerWith(i, onMenuRow)) else row.opacity(0.4);
            rows = rows.child(row);
        }
        const card = ui.popover.card(pt).w(px(240)).onMouseDownOut(cx.listener(onMenuOut)).child(rows);
        return zpui.intoAnyElement(div().absolute().left(px(@floatCast(m.value.x))).top(px(@floatCast(m.value.y))).child(zpui.deferred(
            zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8)).child(div().occlude().child(card)),
        ).withPriority(2)));
    }

    fn emptyBody(self: *BrowserPane, theme: *const Theme, cx: *Context(BrowserPane)) zpui.AnyElement {
        if (self.page.url == null and self.previews_watching) return self.previewBody(theme, cx);
        const external = !(is_mac or is_linux);
        const has_error = self.page.@"error" != null;
        const title = if (has_error) "Couldn\u{2019}t load this page" else if (external and self.page.url != null) "Opened in your browser" else "Preview your work";
        const description = self.page.@"error" orelse if (external)
            "Open a website or local app in your default browser. Embedded browsing is available on macOS and Linux."
        else
            "Preview your local app or keep a website beside your conversation.";
        var action = div().mt(px(6)).id("browser-empty-action").h(px(28)).px(px(10)).rounded(px(6))
            .border1().borderColor(theme.border).bg(theme.surface_raised).cursorPointer()
            .hover(sb.bg(theme.wash(0.10))).flex().itemsCenter().gap(px(8))
            .textSize(ui.rems(12)).textColor(theme.text)
            .onClick(cx.listener(onEmptyAction))
            .child(if (has_error) "Try again" else "Enter an address");
        if (!has_error) action = action.child(div().textSize(ui.rems(10)).textColor(theme.text_faint).child(if (is_mac) "\u{2318}L" else "Ctrl L"));
        return zpui.intoAnyElement(div().sizeFull().flex().itemsCenter().justifyCenter().p(px(24))
            .child(div().wFull().maxW(px(300)).flex().flexCol().itemsCenter().gap(px(12))
                .child(div().size(px(44)).rounded(px(12)).border1().borderColor(theme.border)
                    .bg(theme.surface_raised.opacity(0.5)).flex().itemsCenter().justifyCenter()
                    .child(ui.icon.of(.globe, 22, theme.text_muted)))
                .child(div().mt(px(4)).textSize(ui.rems(14)).fontWeight(500).textColor(theme.text).child(title))
                .child(div().textCenter().textSize(ui.rems(12)).lineHeight(px(19)).textColor(theme.text_muted).child(description))
                .child(action)));
    }

    fn previewBody(self: *BrowserPane, theme: *const Theme, cx: *Context(BrowserPane)) zpui.AnyElement {
        const snap: PreviewSnapshot = if (self.previews) |p| p.value else .{};
        const err = self.previews_error orelse snap.@"error";
        const available = err == null;
        var content = div().wFull().maxW(px(280)).flexShrink0().myAuto().flex().flexCol().gap(px(8))
            .child(div().mb(px(4)).textSize(ui.rems(12)).textColor(theme.text_muted)
                .child(if (snap.remote) "Running on your device" else "Running locally"));
        for (snap.services, 0..) |s, i| {
            const label = if (snap.remote)
                zpui.fmt("{s} \u{b7} localhost:{d}", .{ s.deviceName, s.port })
            else
                zpui.fmt("localhost:{d}", .{s.port});
            var row = div().id(.{ "preview-row", i }).wFull().h(px(56)).px(px(14)).rounded(px(10))
                .border1().borderColor(theme.border).bg(theme.ink(0.02))
                .flex().itemsCenter().gap(px(10))
                .child(div().flex1().minW0().flex().flexCol().gap(px(2))
                    .child(div().textSize(ui.rems(13)).fontWeight(500).textColor(theme.text).truncate().child(s.name))
                    .child(div().textSize(ui.rems(11)).textColor(theme.text_muted).truncate().child(label)));
            var open = div().id(.{ "open-preview", i }).h(px(28)).px(px(6)).flexShrink0().rounded(px(6))
                .flex().itemsCenter().justifyCenter().textSize(ui.rems(12)).textColor(theme.text_muted).child("Open");
            if (available) {
                row = row.cursorPointer().hover(sb.bg(theme.ink(0.05)).borderColor(theme.border_strong)).onClick(cx.listenerWith(i, onPreview));
                open = open.cursorPointer().hover(sb.bg(theme.ink(0.05))).onClick(cx.listenerWith(i, onPreview));
            } else open = open.opacity(0.4);
            content = content.child(row.child(open));
        }
        if (snap.services.len == 0) {
            const msg = if (self.previews_loading)
                "Looking for dev servers\u{2026}"
            else if (snap.remote)
                "Start a dev server in this project on your other device. Its preview will appear here when that device is online."
            else
                "Start a dev server in this project. It will appear here automatically, ready to open.";
            content = content.child(div().p(px(16)).rounded(px(8)).border1().borderColor(theme.border)
                .textSize(ui.rems(12)).lineHeight(px(19)).textColor(theme.text_muted).child(msg));
        }
        if (err) |e| content = content.child(div().textSize(ui.rems(11)).lineHeight(px(17)).textColor(theme.text_muted).child(e));
        content = content.child(div().id("preview-enter-address").mt(px(8)).textSize(ui.rems(11)).textColor(theme.text_muted)
            .cursorPointer().onClick(cx.listener(onEnterAddress)).child("Or enter a website address"));
        return zpui.intoAnyElement(div().id("browser-previews").sizeFull().overflowYScroll().p(px(16))
            .flex().flexCol().itemsCenter().child(content));
    }
};

/// `surface_chrome::toolbar`: 38px, 8px inset, hairlines above and below.
fn surfaceToolbar(theme: *const Theme) zpui.Div {
    return div().h(px(zt.layout.titlebar_height)).wFull().flexNone().px(px(8)).flex().itemsCenter().gap(px(4))
        .borderT1().borderB1().borderColor(theme.border)
        .bg(if (theme.isGlass()) theme.surface.opacity(0.26) else theme.surface);
}

fn toolbarButton(id: []const u8, i: Icon, label: []const u8, enabled: bool, theme: *const Theme) zpui.StatefulDiv {
    var b = div().id(id).size(px(24)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(6))
        .tooltipWith(label, ui.tooltip.build)
        .child(ui.icon.of(i, 14, theme.text_muted));
    b = if (enabled) b.cursorPointer().hover(sb.bg(theme.wash(0.10))) else b.opacity(0.35);
    return b;
}
