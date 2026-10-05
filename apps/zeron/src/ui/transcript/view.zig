//! `TranscriptView` — the conversation view (port of zeron transcript.rs
//! `Transcript`: `sync`, `render_row`, `render` + rail.rs).
//!
//! A virtualized `ListState` (bottom-aligned, 320px overdraw, tail follow) at
//! block granularity. Rows are rebuilt per entry only when the entry's content
//! fingerprint changes; the row set diffs by (id, version) into one minimal
//! `splice`, so a streaming commit re-measures only the tail block rows.
//!
//! ```zig
//! // Follow the app's selected chat:
//! const tv = try cx.newWith(TranscriptView, TranscriptView.init, .{app_state});
//! // or show one store (previews, subagent tabs, demos):
//! const tv = try cx.newWith(TranscriptView, TranscriptView.initWithStore, .{store});
//! div().child(tv)   // fills its parent
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const md = @import("zeron_ui_markdown");
const assets = @import("zeron_assets");
const rows = @import("rows.zig");
const tools = @import("tools.zig");
const stick = @import("stick.zig");
const files = md.file_icons;
const wl = @import("workspace_links.zig");
const subagents = @import("subagents.zig"); // [wiring] spawn chips → subagent tabs
const blobs_mod = @import("blobs.zig"); // [wiring] "Show full output" (FetchToolBlob)
const media = @import("zeron_media");
const att = model.attachments;

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const AnyElement = zpui.AnyElement;
const Theme = zt.Theme;
const Hsla = zpui.Hsla;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const ListState = zpui.elements.ListState;
const TranscriptStore = model.TranscriptStore;
const AppState = model.AppState;
const Row = rows.Row;
const motion = zt.motion;
const layout = zt.layout;
const protocol = engine.protocol;

/// Re-engage the bottom pin within this many px of the end.
pub const stick_threshold_px: f32 = 70;
pub const overdraw_px: f32 = 320;
pub const user_collapsed_lines: usize = 5;
pub const user_line_height: f32 = 22;

/// `OwnTurnAnchor`: the sent prompt's row and its hold state.
pub const OwnTurn = struct {
    key: u64,
    held: bool = true,
    positioned: bool = false,
    last_tick: ?u64 = null,
};

/// One user message's open/close resize (`FoldState` for user rows).
pub const UserFold = struct {
    from: f32 = 0,
    epoch: u64 = 0,
    toggled_at: u64 = 0,
    duration_ms: u64 = 0,
};

/// Collapsed endpoint incl. the continuation line (so removing "..." on
/// expansion does not jump a line).
pub fn userCollapsedHeight() f32 {
    return @as(f32, @floatFromInt(user_collapsed_lines)) * user_line_height + user_line_height;
}

/// `user_resize_duration_ms`: 220 ms + 0.32 ms/px, capped at 850 ms.
pub fn userResizeDurationMs(height_delta: f32) u64 {
    return @intFromFloat(@round(@min(220.0 + @max(height_delta, 0) * 0.32, 850.0)));
}

/// `user_resize_spec`: short folds ease-out; > 500 px ease-in-out.
pub fn userResizeSpec(height_delta: f32) zt.motion.MotionSpec {
    const curve = if (height_delta > 500) zt.motion.ease_in_out else zt.motion.ease_out;
    return .init(userResizeDurationMs(height_delta), curve);
}
pub const user_collapse_chars: usize = 400;
pub const att_thumb_w: f32 = 112;
pub const att_thumb_h: f32 = 80;
pub const tick_slot: f32 = 10;
pub const tick_gap: f32 = 3;
pub const rail_v_margin: f32 = 24;
pub const max_rail_ticks: usize = 12;
pub const rail_min_container_width: f32 = 768;

/// Optional host hook for the active theme (the shell installs
/// `ui.theme.get`); falls back to Zeron Dark.
pub var theme_provider: ?*const fn (*App) *const Theme = null;
var fallback_theme: ?Theme = null;

pub fn themeOf(app: *App) *const Theme {
    if (theme_provider) |f| return f(app);
    if (fallback_theme == null) fallback_theme = Theme.forSelection(&zt.registry.builtin, .{ .appearance = .dark, .variant_id = "zeron-dark" });
    return &fallback_theme.?;
}

fn mixKey(a: u64, b: u64) u64 {
    var h = std.hash.Wyhash.init(a);
    h.update(std.mem.asBytes(&b));
    return h.final();
}

pub const TranscriptView = struct {
    gpa: Allocator,
    app_state: ?Entity(AppState) = null,
    store: ?Entity(TranscriptStore) = null,
    subs: zpui.Subscriptions = .{},
    store_subs: zpui.Subscriptions = .{},
    parsers: rows.Parsers,
    entries: std.StringHashMapUnmanaged(*rows.EntryRows) = .empty,
    /// Flattened rows (borrowed from `entries`), plus their diff keys.
    order: std.ArrayList(*const Row) = .empty,
    keys: std.ArrayList(u64) = .empty,
    versions: std.ArrayList(u64) = .empty,
    list: ListState,
    synced_revision: ?u64 = null,
    synced_store: ?zpui.EntityId = null,
    folds: std.AutoHashMapUnmanaged(u64, tools.Fold) = .empty,
    details: std.AutoHashMapUnmanaged(u64, tools.Fold) = .empty,
    user_expanded: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// [motion] Long user messages: measured full text height cells (heap,
    /// written by a paint probe) and the running open/close resize tween.
    user_heights: std.AutoHashMapUnmanaged(u64, *f32) = .empty,
    user_folds: std.AutoHashMapUnmanaged(u64, UserFold) = .empty,
    /// Row key → entrance start (ns) for rows that arrived live.
    entrance: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// [motion] Tool arrival starts per (row, part) and group header starts
    /// (`tool_group_reveals`); null = historical / settled.
    tool_starts: std.AutoHashMapUnmanaged(u64, ?u64) = .empty,
    tool_headers: std.AutoHashMapUnmanaged(u64, ?u64) = .empty,
    hovered_entry: u64 = 0,
    hovered_row: u64 = 0,
    copied_entry: u64 = 0,
    copied_at: u64 = 0,
    /// The first non-empty sync happened (later arrivals animate in).
    loaded: bool = false,
    focus: zpui.FocusHandle,
    // Layout knobs (the shell sets these from settings / chrome).
    content_width: f32 = layout.transcript_width_default,
    /// Space above the first row: titlebar + turn gap + 10 (zeron's
    /// non-override first-row gap).
    top_inset: f32 = layout.titlebar_height + layout.space_lg + 10,
    /// Composer/status stack the transcript scrolls under.
    bottom_clearance: f32 = 0,
    rail_enabled: bool = true,
    /// Open at the top instead of following the tail (demos, deep links).
    start_at_top: bool = false,
    rail_hover: ?usize = null,
    /// Minutes east of UTC for hover timestamps.
    utc_offset_minutes: i32 = 0,
    /// Frozen wall clock (ms) for tests/demos; null = real time.
    now_override_ms: ?i64 = null,
    /// Local workspace root for inline-code file links (owned); null = off.
    workspace_root: ?[]u8 = null,
    probe: wl.Probe = undefined,
    roots_buf: [1][]const u8 = undefined,
    /// The full-size preview of a transcript image (attachment-ui.tsx dialog).
    lightbox: ?Entity(media.Lightbox) = null,
    lightbox_sub: ?zpui.Subscription = null,

    /// [wiring] Fetched sidecar blobs (full outputs / diffs) + in-flight requests.
    blobs: blobs_mod.Blobs = .{},
    blob_requests: std.ArrayList(Entity(BlobRequest)) = .empty,
    /// [wiring] The "Scroll to bottom" pill is offered (hysteresis: 320px / 2px).
    show_jump: bool = false,

    /// Compact mode (`transcriptCompactMode`) as last applied to the row split.
    compact_mode: bool = false,
    /// Natural heights of compact-fold body rows (row key → px), written by
    /// each row's paint probe; the shell header tweens one budget over them.
    compact_heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Compact work headers that were live this session: "Worked for" fades
    /// in only for those, not historical rows.
    compact_live: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// When a compact work header first settled this session (ns).
    compact_worked_fade_at: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Entry id hash → the last live trailer elapsed (s): "Worked for" when
    /// the doc carries no `durationMs`.
    compact_last_elapsed: std.AutoHashMapUnmanaged(u64, i64) = .empty,
    /// Pending close-sweep timer for a compact fold (drops the body rows once
    /// the close tween ends).
    compact_settle: zpui.Task(void) = .none,
    /// [motion] The rail's scroll-to-row glide (`scroll_to_row`,
    /// SCROLL_GLIDE 500 ms ease-in-out): 16 ms ticks re-aim at the row's
    /// live offset, so the landing is exact once the row is measured.
    rail_glide: ?struct { row: usize, from: f32, start_ns: u64 } = null,
    rail_glide_task: zpui.Task(void) = .none,
    /// [motion] The stick-to-bottom spring (`engage_pin` / `step_spring`):
    /// glides back to the end instead of snapping; lands in tail-follow.
    spring: stick.StickSpring = .{},
    spring_on: bool = false,
    spring_last: ?u64 = null,
    spring_settled_at: ?u64 = null,
    /// [motion] A locally-sent prompt's hold (`OwnTurnAnchor`): the list
    /// reserves the reply's runway below it and the prompt glides to the top
    /// inset; filled runway hands off to the bottom pin.
    own_turn: ?OwnTurn = null,
    /// [motion] `retain_for_route_exit`: leaving for Home keeps the old
    /// conversation mounted while the dock fades it out; the main panel
    /// calls `finishRouteExit` once its fade has run out.
    exit_pending: bool = false,

    /// Streaming fade veils, one per live markdown row (dropped on the
    /// live→complete flip).
    veils: std.AutoHashMapUnmanaged(u64, *md.veil.RowVeil) = .empty,
    /// Live rows already carrying text when the transcript attached: their
    /// veils start seeded, so only post-attach appends fade in.
    veil_baseline: std.AutoHashMapUnmanaged(u64, void) = .empty,
    veil_attach_pending: bool = true,

    // [wiring] spawn-chip links: the shell hosts the subagent surface.
    pub const Events = .{subagents.OpenSubagent};

    pub fn init(app_state: Entity(AppState), cx: *Context(TranscriptView)) !TranscriptView {
        var self = initBase(cx);
        self.app_state = app_state.retain(cx);
        try self.subs.add(cx.gpa(), try cx.subscribe(app_state, onSelectedStores));
        try self.subs.add(cx.gpa(), try cx.observe(app_state, onAppStateChanged));
        self.follow(app_state, cx);
        return self;
    }

    pub fn initWithStore(store: Entity(TranscriptStore), cx: *Context(TranscriptView)) !TranscriptView {
        var self = initBase(cx);
        try self.attach(store, cx);
        return self;
    }

    fn initBase(cx: *Context(TranscriptView)) TranscriptView {
        const list = ListState.init(cx.gpa(), 0, .bottom, overdraw_px);
        list.setFollowMode(.tail);
        return .{ .gpa = cx.gpa(), .parsers = .init(cx.gpa()), .list = list, .focus = cx.focusHandle() };
    }

    pub fn deinit(self: *TranscriptView, app: *App) void {
        self.subs.deinit(self.gpa);
        self.store_subs.deinit(self.gpa);
        if (self.store) |s| s.release(app);
        if (self.app_state) |s| s.release(app);
        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.keys.deinit(self.gpa);
        self.versions.deinit(self.gpa);
        self.parsers.deinit();
        if (self.workspace_root) |r| self.gpa.free(r);
        self.folds.deinit(self.gpa);
        self.details.deinit(self.gpa);
        self.compact_heights.deinit(self.gpa);
        self.compact_live.deinit(self.gpa);
        self.compact_worked_fade_at.deinit(self.gpa);
        self.compact_last_elapsed.deinit(self.gpa);
        self.compact_settle.cancel();
        self.rail_glide_task.cancel();
        self.clearVeils();
        self.veils.deinit(self.gpa);
        self.veil_baseline.deinit(self.gpa);
        self.user_expanded.deinit(self.gpa);
        self.clearUserHeights();
        self.user_heights.deinit(self.gpa);
        self.user_folds.deinit(self.gpa);
        self.entrance.deinit(self.gpa);
        self.tool_starts.deinit(self.gpa);
        self.tool_headers.deinit(self.gpa);
        self.list.release();
        self.blobs.deinit(self.gpa); // [wiring]
        for (self.blob_requests.items) |r| r.release(app);
        self.blob_requests.deinit(self.gpa);
        self.focus.release(app);
        self.closeLightbox(app);
    }

    // ---- images (attachments.rs read-back + the shared lightbox) ----

    fn closeLightbox(self: *TranscriptView, app: *App) void {
        if (self.lightbox_sub) |*sub| sub.deinit();
        self.lightbox_sub = null;
        if (self.lightbox) |lb| lb.release(app);
        self.lightbox = null;
    }

    fn onLightboxClosed(self: *TranscriptView, _: Entity(media.Lightbox), _: *const media.LightboxClosed, window: *Window, cx: *Context(TranscriptView)) void {
        self.closeLightbox(cx.app);
        window.focus(self.focus);
        cx.notify();
    }

    fn onLightboxClosedNoWindow(self: *TranscriptView, _: Entity(media.Lightbox), _: *const media.LightboxClosed, cx: *Context(TranscriptView)) void {
        self.closeLightbox(cx.app);
        cx.notify();
    }

    const ImageClick = struct { key: u64 };

    /// Open the lightbox for the cache entry `key` (device/path/mime key hash
    /// resolved at click time from the row's attachment).
    fn openImage(self: *TranscriptView, img: *zpui.RenderImage, name: []const u8, window: *Window, cx: *Context(TranscriptView)) void {
        self.closeLightbox(cx.app);
        const lb = cx.newWith(media.Lightbox, media.Lightbox.init, .{ media.LightboxOptions{
            .image = img,
            .name = name,
            .release = att.releaseImage,
            .appearance = themeOf(cx.app).appearance,
        }, window }) catch return;
        self.lightbox = lb;
        self.lightbox_sub = cx.subscribe(lb, onLightboxClosedNoWindow) catch null;
        cx.notify();
    }

    /// `open_diagram_preview`: the diagram enlarged for the viewport, on the
    /// fence plate, in the shared lightbox.
    fn openDiagram(owner: u64, key: u64, window: ?*Window, app: *App) void {
        const win = window orelse return;
        const weak: zpui.WeakEntity(TranscriptView) = .{ .id = @enumFromInt(owner) };
        const ent = weak.upgrade(app) orelse return;
        defer ent.release(app);
        const vp = win.viewportSize();
        const e = md.diagrams.get(key) orelse return;
        const img = md.diagrams.enlarged(key, .{ .width = vp.width * 0.9, .height = vp.height * 0.85 }, win.scaleFactor()) orelse return;
        const natural: media.viewer.Size = .{ .width = e.natural.width, .height = e.natural.height };
        const theme = themeOf(app);
        var l = ent.lease(app);
        defer l.end();
        const self = l.value;
        const cx = &l.cx;
        self.closeLightbox(app);
        const lb = cx.newWith(media.Lightbox, media.Lightbox.init, .{ media.LightboxOptions{
            .image = img,
            .name = "Mermaid diagram",
            .natural = natural,
            .plate = theme.bg.blend(theme.ink(0.035)),
            .release = md.diagrams.releaseImage,
            .appearance = theme.appearance,
        }, win }) catch {
            md.diagrams.releaseImage(app, img);
            return;
        };
        // The lightbox retained its own reference.
        img.release();
        self.lightbox = lb;
        self.lightbox_sub = cx.subscribe(lb, onLightboxClosedNoWindow) catch null;
        cx.notify();
    }

    /// Devices that may own a user message's attachment files: the chat's
    /// host device plus this device (`attachment_device_ids`).
    fn attachmentDevices(self: *const TranscriptView, cx: *Context(TranscriptView), out: [][]const u8) [][]const u8 {
        const st = (self.app_state orelse return out[0..0]).read(cx);
        const ws = st.workspace.read(cx);
        var n: usize = 0;
        if (ws.selectedChatRow()) |c| {
            out[n] = c.deviceId;
            n += 1;
        }
        if (ws.local_device_id) |l| if (n == 0 or !std.mem.eql(u8, out[0], l)) {
            out[n] = l;
            n += 1;
        };
        return out[0..n];
    }

    fn localDevice(self: *const TranscriptView, cx: *Context(TranscriptView)) ?[]const u8 {
        const st = (self.app_state orelse return null).read(cx);
        return st.workspace.read(cx).local_device_id;
    }

    fn engineEntity(self: *const TranscriptView, cx: *Context(TranscriptView)) ?Entity(model.EngineState) {
        if (self.app_state) |a| return a.read(cx).engine;
        if (self.store) |s| return s.read(cx).engine;
        return null;
    }

    fn imageState(self: *TranscriptView, devices: []const []const u8, path: []const u8, mime: ?[]const u8, cx: *Context(TranscriptView)) att.Snapshot {
        const eng = self.engineEntity(cx) orelse return .{ .failed = .{ .retry_in_ns = std.math.maxInt(u64) } };
        return att.attachmentState(cx.app, eng, devices, self.localDevice(cx), path, mime);
    }

    const ThumbClick = struct { row: u64, aix: u32 };

    fn onThumbClick(self: *TranscriptView, data: ThumbClick, _: *const zpui.ClickEvent, window: *Window, cx: *Context(TranscriptView)) void {
        for (self.order.items) |row| {
            if (row.key != data.row) continue;
            switch (row.kind) {
                .user => |u| {
                    if (data.aix >= u.attachments.len) return;
                    const a = u.attachments[data.aix];
                    var buf: [4][]const u8 = undefined;
                    const devices = self.attachmentDevices(cx, &buf);
                    switch (self.imageState(devices, a.path, null, cx)) {
                        .loaded => |l| self.openImage(l.image, l.name, window, cx),
                        else => {},
                    }
                },
                .generated_image => |g| {
                    var fb: [4][]const u8 = undefined;
                    var buf: [6][]const u8 = undefined;
                    const devices = att.generatedImageDevices(g.owner, self.attachmentDevices(cx, &fb), &buf);
                    switch (self.imageState(devices, g.path, g.mime_type, cx)) {
                        .loaded => |l| self.openImage(l.image, g.name, window, cx),
                        else => {},
                    }
                },
                else => {},
            }
            return;
        }
    }

    /// One user-attachment thumbnail (`render_user_attachments`).
    fn attachmentThumb(self: *TranscriptView, row: *const Row, a: rows.Attachment, aix: usize, theme: *const Theme, window: *Window, cx: *Context(TranscriptView)) zpui.StatefulDiv {
        var buf: [4][]const u8 = undefined;
        const devices = self.attachmentDevices(cx, &buf);
        const state = self.imageState(devices, a.path, null, cx);
        const key = mixKey(row.key, aix);
        const frame = div().id(.{ "att", key }).flexNone().w(px(att_thumb_w)).h(px(att_thumb_h)).rounded(px(8)).overflowHidden();
        const sending = std.mem.startsWith(u8, a.path, "pending://") or std.mem.startsWith(u8, a.path, "pending/");
        const now = cx.app.executor.now();
        switch (state) {
            .loaded => |l| {
                var thumb = frame.role(.button).ariaLabel(zpui.fmt("Preview {s}", .{std.fs.path.basename(a.path)})).relative().border1().borderColor(theme.hairline(0.11)).bg(theme.ink(0.035)).cursorPointer()
                    .onClick(cx.listenerWith(ThumbClick{ .row = row.key, .aix = @intCast(aix) }, onThumbClick))
                    .child(zpui.img(l.image).w(px(att_thumb_w - 2)).h(px(att_thumb_h - 2)).rounded(px(7)).objectFit(.cover));
                if (sending) {
                    // Progress on the thumbnail: this transfer's percent, else
                    // the send-wide upload's, else the indeterminate spinner.
                    const pulse = media.widgets.pulseWave(now);
                    const pct = att.Cache.of(cx.app).uploadPercent();
                    const indicator = if (pct) |p| media.widgets.progressRing(p, 34) else media.widgets.miniGlyphSpinner(3, theme.glyph.rows(), media.widgets.phaseAt(now, zt.motion.gradient_spin));
                    thumb = thumb.child(div().absolute().inset0().rounded(px(7)).flex().itemsCenter().justifyCenter()
                        .bg(zpui.hsla(0, 0, 0, 0.38 + 0.05 * pulse)).child(indicator));
                    window.requestAnimationFrame();
                }
                return thumb;
            },
            .failed => return frame.border1().borderDashed().borderColor(theme.hairline(0.14)).bg(theme.ink(0.025)),
            .loading => {
                window.requestAnimationFrame();
                return frame.border1().borderColor(theme.hairline(0.08)).bg(theme.ink(0.055))
                    .opacity(0.35 + 0.4 * media.widgets.pulseWave(now));
            },
        }
    }

    /// A generated image part (`render_generated_image`).
    fn generatedImage(self: *TranscriptView, row: *const Row, theme: *const Theme, cx: *Context(TranscriptView)) AnyElement {
        const g = row.kind.generated_image;
        var fb: [4][]const u8 = undefined;
        var buf: [6][]const u8 = undefined;
        const devices = att.generatedImageDevices(g.owner, self.attachmentDevices(cx, &fb), &buf);
        const state = self.imageState(devices, g.path, g.mime_type, cx);
        const frame = div().id(.{ "gen-img", row.key }).w(px(512)).maxWFull().h(px(320)).maxH(px(420)).flex().itemsCenter().justifyCenter()
            .rounded(px(12)).overflowHidden().bg(theme.ink(0.045));
        return zpui.intoAnyElement(switch (state) {
            .loaded => |l| blk: {
                const size = l.image.size(0);
                const w: f32 = @floatFromInt(@max(size.width, 1));
                const h: f32 = @floatFromInt(@max(size.height, 1));
                const scale = @min(@min(512.0 / w, 420.0 / h), 1.0);
                break :blk frame.role(.button).ariaLabel("Preview generated image").w(px(w * scale)).h(px(h * scale)).cursorPointer()
                    .onClick(cx.listenerWith(ThumbClick{ .row = row.key, .aix = 0 }, onThumbClick))
                    .child(zpui.img(l.image).sizeFull().rounded(px(12)).objectFit(.contain));
            },
            .loading => frame.textColor(theme.text_muted).child("Loading generated image\u{2026}"),
            .failed => frame.textColor(theme.text_muted).child("Generated image unavailable"),
        });
    }

    fn clearVeils(self: *TranscriptView) void {
        var it = self.veils.valueIterator();
        while (it.next()) |v| {
            v.*.deinit();
            self.gpa.destroy(v.*);
        }
        self.veils.clearRetainingCapacity();
    }

    fn dropVeil(self: *TranscriptView, key: u64) void {
        const kv = self.veils.fetchRemove(key) orelse return;
        kv.value.deinit();
        self.gpa.destroy(kv.value);
    }

    /// The veil of a live markdown row (created on first paint; seeded when
    /// the row was already on screen at attach time).
    fn veilFor(self: *TranscriptView, key: u64) ?*md.veil.RowVeil {
        const gop = self.veils.getOrPut(self.gpa, key) catch return null;
        if (!gop.found_existing) {
            const v = self.gpa.create(md.veil.RowVeil) catch {
                _ = self.veils.remove(key);
                return null;
            };
            v.* = if (self.veil_baseline.contains(key)) .seeded(self.gpa) else .init(self.gpa);
            gop.value_ptr.* = v;
        }
        return gop.value_ptr.*;
    }

    fn clearEntries(self: *TranscriptView) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    // ---- store wiring --------------------------------------------------------------

    fn attach(self: *TranscriptView, store: Entity(TranscriptStore), cx: *Context(TranscriptView)) !void {
        if (self.store) |old| {
            if (old.id == store.id) return;
            old.release(cx);
        }
        self.store_subs.deinit(self.gpa);
        self.store_subs = .{};
        self.store = store.retain(cx);
        try self.store_subs.add(cx.gpa(), try cx.subscribe(store, onStoreChanged));
        try self.store_subs.add(cx.gpa(), try cx.subscribe(store, onStoreText));
        // A different chat: fresh rows, list and per-row UI state.
        self.resetRows();
        cx.notify();
    }

    fn detach(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        if (self.store) |old| old.release(cx);
        self.store = null;
        self.store_subs.deinit(self.gpa);
        self.store_subs = .{};
        self.resetRows();
        cx.notify();
    }

    fn resetRows(self: *TranscriptView) void {
        self.clearEntries();
        self.order.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        self.versions.clearRetainingCapacity();
        self.folds.clearRetainingCapacity();
        self.details.clearRetainingCapacity();
        self.compact_heights.clearRetainingCapacity();
        self.clearVeils();
        self.veil_baseline.clearRetainingCapacity();
        self.veil_attach_pending = true;
        self.entrance.clearRetainingCapacity();
        self.tool_starts.clearRetainingCapacity();
        self.tool_headers.clearRetainingCapacity();
        self.own_turn = null;
        self.spring_on = false;
        self.spring.reset();
        self.list.setTailReservation(null);
        self.user_expanded.clearRetainingCapacity();
        self.clearUserHeights();
        self.user_folds.clearRetainingCapacity();
        self.synced_revision = null;
        self.loaded = false;
        self.list.reset(0);
        self.list.setFollowMode(.tail);
    }

    fn onSelectedStores(self: *TranscriptView, state: Entity(AppState), _: *const model.app_state.SelectedChatStoresChanged, cx: *Context(TranscriptView)) void {
        self.follow(state, cx);
    }

    fn onAppStateChanged(self: *TranscriptView, state: Entity(AppState), cx: *Context(TranscriptView)) void {
        self.follow(state, cx);
    }

    fn follow(self: *TranscriptView, state: Entity(AppState), cx: *Context(TranscriptView)) void {
        const ws = state.read(cx).workspace.read(cx);
        const cwd: ?[]const u8 = if (ws.selectedChatRow()) |c| c.cwd else null;
        self.setWorkspaceRoot(cwd);
        if (state.read(cx).transcript) |t| {
            self.exit_pending = false;
            self.attach(t, cx) catch {};
        } else if (self.store != null) {
            if (appReduced(cx.app)) return self.detach(cx);
            self.exit_pending = true;
            cx.notify();
        }
    }

    /// `finish_route_exit`: drop the departed conversation.
    pub fn finishRouteExit(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        if (!self.exit_pending) return;
        self.exit_pending = false;
        if (self.store != null) self.detach(cx);
    }

    fn onStoreChanged(_: *TranscriptView, _: Entity(TranscriptStore), _: *const model.transcript_store.Changed, cx: *Context(TranscriptView)) void {
        cx.notify();
    }

    fn onStoreText(_: *TranscriptView, _: Entity(TranscriptStore), _: *const model.transcript_store.TextChanged, cx: *Context(TranscriptView)) void {
        cx.notify();
    }

    // ---- row sync --------------------------------------------------------------------

    /// Rebuild changed entries and splice the list (cheap when nothing moved).
    pub fn sync(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        const store_e = self.store orelse return;
        const store = store_e.read(cx);
        if (self.synced_revision == store.revision and self.synced_store != null and self.synced_store.? == store_e.id) return;
        self.synced_revision = store.revision;
        self.synced_store = store_e.id;
        self.rebuild(store, cx.app.executor.now()) catch |err| std.log.scoped(.transcript).warn("row sync failed: {t}", .{err});
    }

    /// Set (or clear) the local workspace root that inline-code file links
    /// resolve against. Rebuilds rows.
    pub fn setWorkspaceRoot(self: *TranscriptView, root: ?[]const u8) void {
        if (self.workspace_root) |r| {
            if (root != null and std.mem.eql(u8, r, root.?)) return;
            self.gpa.free(r);
        }
        self.workspace_root = if (root) |r| self.gpa.dupe(u8, r) catch null else null;
        self.clearEntries();
        self.synced_revision = null;
    }

    fn rebuild(self: *TranscriptView, store: *const TranscriptStore, now_ns: u64) !void {
        const gpa = self.gpa;
        if (self.workspace_root) |root| {
            self.roots_buf[0] = root;
            self.probe = .{ .io = store.io, .roots = self.roots_buf[0..1], .arena = gpa };
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        var new_order: std.ArrayList(*const Row) = .empty;
        defer new_order.deinit(gpa);

        const n = store.len();
        var i: usize = 0;
        while (i < n) : (i += 1) try self.syncEntry(store.entry(i), false, now_ns, &seen, &new_order);
        for (store.pendingEchoes()) |*echo| {
            if (store.findEntry(echo.entry.id) != null) continue;
            try self.syncEntry(&echo.entry, true, now_ns, &seen, &new_order);
        }
        // Sweep entries that left the transcript.
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(gpa);
        var it = self.entries.iterator();
        while (it.next()) |e| if (!seen.contains(e.key_ptr.*)) try stale.append(gpa, e.key_ptr.*);
        // Rows of stale entries are still referenced by `self.order` until
        // the swap below; free them afterwards.
        var stale_rows: std.ArrayList(*rows.EntryRows) = .empty;
        defer stale_rows.deinit(gpa);
        var stale_keys: std.ArrayList([]const u8) = .empty;
        defer stale_keys.deinit(gpa);
        for (stale.items) |k| {
            const kv = self.entries.fetchRemove(k).?;
            try stale_rows.append(gpa, kv.value);
            try stale_keys.append(gpa, kv.key);
        }

        // Diff (id, version) and splice.
        const new_rows = try gpa.alloc(Row, new_order.items.len);
        defer gpa.free(new_rows);
        for (new_order.items, new_rows) |r, *o| o.* = r.*;
        var old_keys: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer old_keys.deinit(gpa);
        for (self.keys.items) |k| try old_keys.put(gpa, k, {});
        if (rows.diffRows(self.keys.items, self.versions.items, new_rows)) |sp| {
            self.list.splice(.{ .start = sp.start, .end = sp.old_end }, sp.new_count);
            // The previous last row carries the bottom clearance + trailer.
            if (sp.start > 0 and sp.start == self.keys.items.len and sp.new_count > 0)
                self.list.remeasureItems(.{ .start = sp.start - 1, .end = sp.start });
        }
        if (self.loaded) {
            // Compact-fold body rows reveal under the fold tween, not the entrance.
            for (new_rows) |r| if (!old_keys.contains(r.key) and r.compact_fold == null) try self.entrance.put(gpa, r.key, now_ns);
        }
        // [motion] Tool arrival bookkeeping (what streamed before attach is history).
        try tools.updateReveals(self, new_rows, &old_keys, !self.loaded, now_ns);
        // [motion] `on_own_send`: a pending (optimistic) user row that just
        // appeared is our own send; hold it at the top with the reply runway.
        if (self.loaded) {
            var sent: ?u64 = null;
            for (new_rows) |r| if (r.kind == .user and r.kind.user.pending and !old_keys.contains(r.key)) {
                sent = r.key;
            };
            if (sent) |key| self.onOwnSend(key);
        }
        if (new_rows.len > 0 and !self.loaded and self.start_at_top) {
            self.list.setFollowMode(.normal);
            self.list.scrollTo(.{ .item_ix = 0, .offset_in_item = 0 });
        }
        if (new_rows.len > 0) self.loaded = true;

        // Text already streamed before this (re)attach is the veil baseline:
        // captured from the first non-empty sync after attach.
        if (self.veil_attach_pending and new_rows.len > 0) {
            self.veil_attach_pending = false;
            self.veil_baseline.clearRetainingCapacity();
            for (new_rows) |r| if (r.kind == .markdown and r.kind.markdown.live) try self.veil_baseline.put(gpa, r.key, {});
        }
        // Veils live exactly as long as their live row.
        {
            var live: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer live.deinit(gpa);
            for (new_rows) |r| if (r.kind == .markdown and r.kind.markdown.live) try live.put(gpa, r.key, {});
            var drop: std.ArrayList(u64) = .empty;
            defer drop.deinit(gpa);
            var vit = self.veils.keyIterator();
            while (vit.next()) |k| if (!live.contains(k.*)) try drop.append(gpa, k.*);
            for (drop.items) |k| self.dropVeil(k);
            drop.clearRetainingCapacity();
            var bit = self.veil_baseline.keyIterator();
            while (bit.next()) |k| if (!live.contains(k.*)) try drop.append(gpa, k.*);
            for (drop.items) |k| _ = self.veil_baseline.remove(k);
        }

        self.order.clearRetainingCapacity();
        try self.order.appendSlice(gpa, new_order.items);
        self.keys.clearRetainingCapacity();
        self.versions.clearRetainingCapacity();
        for (new_rows) |r| {
            try self.keys.append(gpa, r.key);
            try self.versions.append(gpa, r.version);
        }
        for (stale_rows.items, stale_keys.items) |er, k| {
            er.deinit(gpa);
            gpa.destroy(er);
            gpa.free(k);
        }
    }

    fn syncEntry(self: *TranscriptView, entry: *const protocol.SessionMessageEntry, pending: bool, now_ns: u64, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(*const Row)) !void {
        const gpa = self.gpa;
        const fp = rows.entryFingerprint(entry, pending, self.compact_mode);
        const gop = try self.entries.getOrPut(gpa, entry.id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, entry.id);
            gop.value_ptr.* = try gpa.create(rows.EntryRows);
            gop.value_ptr.*.* = try rows.buildEntryRows(gpa, &self.parsers, entry, self.buildOpts(pending), fp);
        } else if (gop.value_ptr.*.fingerprint != fp) {
            const fresh = try rows.buildEntryRows(gpa, &self.parsers, entry, self.buildOpts(pending), fp);
            // The old rows may still be referenced by `self.order` (until the
            // swap in `rebuild`) — but only through Row copies made before; the
            // list diff reads `new_rows` copies, so freeing now is safe.
            gop.value_ptr.*.deinit(gpa);
            gop.value_ptr.*.* = fresh;
        }
        try seen.put(gpa, gop.key_ptr.*, {});
        const worked = self.compactWorkedSecsFor(entry);
        for (gop.value_ptr.*.rows) |*r| {
            if (worked) |secs| switch (r.kind) {
                .tool_group => |*g| if (g.compact_shell) {
                    g.worked_secs = secs;
                },
                else => {},
            };
            if (r.compact_fold) |work_id| if (!self.compactFoldMounted(rows.hashStr(work_id), now_ns)) continue;
            try out.append(gpa, r);
        }
    }

    fn buildOpts(self: *TranscriptView, pending: bool) rows.BuildOptions {
        return .{ .pending = pending, .probe = if (self.workspace_root != null) &self.probe else null, .compact = self.compact_mode };
    }

    // ---- compact mode -----------------------------------------------------------------

    /// Settle window of a closing compact fold (`FOLD_TWEEN_WINDOW`).
    pub const fold_tween_window_ns: u64 = 400 * std.time.ns_per_ms;

    /// Apply the `transcriptCompactMode` setting: the mode is part of the row
    /// split, so every entry rebuilds.
    pub fn setCompactMode(self: *TranscriptView, on: bool) void {
        if (self.compact_mode == on) return;
        self.compact_mode = on;
        self.compact_heights.clearRetainingCapacity();
        self.clearEntries();
        self.synced_revision = null;
    }

    fn syncCompactSetting(self: *TranscriptView, app: *App) void {
        const s = model.settings_store.current(app) orelse return;
        self.setCompactMode(s.transcriptCompactMode);
    }

    /// `compact_worked_secs_for`: the doc's duration, else the live trailer's
    /// last elapsed seconds for that entry.
    fn compactWorkedSecsFor(self: *const TranscriptView, entry: *const protocol.SessionMessageEntry) ?i64 {
        if (!self.compact_mode or entry.role != .assistant or entry.status == .streaming) return null;
        if (entry.durationMs) |ms| return if (ms > 0) @max(@divTrunc(ms, 1000), 1) else null;
        const secs = self.compact_last_elapsed.get(rows.hashStr(entry.id)) orelse return null;
        return if (secs > 0) secs else null;
    }

    /// A compact fold's body rows stay in the list while it is open, and
    /// through the close tween (the settle sweep drops them afterwards).
    fn compactFoldMounted(self: *const TranscriptView, key: u64, now_ns: u64) bool {
        const fold = self.folds.get(key) orelse return false;
        if (fold.open orelse false) return true;
        const at = fold.toggled_at orelse return false;
        return now_ns -| at < zt.motion.scaledNs(fold_tween_window_ns);
    }

    /// `compact_body_height`: the fold's animated body budget.
    pub fn compactBodyHeight(fold: tools.Fold, total: f32, reduced: bool, now_ns: u64) f32 {
        const target: f32 = if (fold.open orelse false) total else 0;
        const at = fold.toggled_at orelse return target;
        if (reduced) return target;
        const t = tools.tool_fold.progressAt(now_ns -| at, 1.0);
        return fold.from + (target - fold.from) * t;
    }

    /// Natural height of the body rows following the shell at `shell_ix`.
    fn compactFoldTotal(self: *const TranscriptView, shell_ix: usize, work_id: []const u8) f32 {
        var total: f32 = 0;
        var i = shell_ix + 1;
        while (i < self.order.items.len) : (i += 1) {
            const r = self.order.items[i];
            const f = r.compact_fold orelse break;
            if (!std.mem.eql(u8, f, work_id)) break;
            total += self.compact_heights.get(r.key) orelse 0;
        }
        return total;
    }

    /// `compact_fold_geometry`: `(prefix, own, total)` natural heights over the
    /// contiguous `work_id` run containing `ix`.
    pub fn compactFoldGeometry(order: []const *const Row, heights: *const std.AutoHashMapUnmanaged(u64, f32), work_id: []const u8, ix: usize) [3]f32 {
        var start = ix;
        while (start > 0) {
            const f = order[start - 1].compact_fold orelse break;
            if (!std.mem.eql(u8, f, work_id)) break;
            start -= 1;
        }
        var prefix: f32 = 0;
        var own: f32 = 0;
        var total: f32 = 0;
        var j = start;
        while (j < order.len) : (j += 1) {
            const f = order[j].compact_fold orelse break;
            if (!std.mem.eql(u8, f, work_id)) break;
            const h = heights.get(order[j].key) orelse 0;
            if (j < ix) prefix += h else if (j == ix) own = h;
            total += h;
        }
        return .{ prefix, own, total };
    }

    pub fn toggleCompactFold(self: *TranscriptView, key: u64, reduced: bool, cx: *Context(TranscriptView)) void {
        const now = cx.app.executor.now();
        const shell_ix = self.indexOfKey(key) orelse return;
        const shell = self.order.items[shell_ix];
        const gop = self.folds.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const total = self.compactFoldTotal(shell_ix, shell.id);
        // The tween opens from the body's CURRENT rendered height (reversals
        // included), not the header's chip height.
        gop.value_ptr.from = compactBodyHeight(gop.value_ptr.*, total, reduced, now);
        const now_open = !(gop.value_ptr.open orelse false);
        gop.value_ptr.open = now_open;
        gop.value_ptr.toggled_at = if (reduced) null else now;
        // Mount the folded rows so the tween has content to reveal — or drop
        // them right away under reduced motion.
        self.synced_revision = null;
        self.compact_settle.cancel();
        self.compact_settle = .none;
        if (!now_open and !reduced) {
            self.compact_settle = cx.timer(zt.motion.scaledNs(fold_tween_window_ns) + 50 * std.time.ns_per_ms, onCompactSettle) catch .none;
        }
        cx.notify();
    }

    fn onCompactSettle(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        self.compact_settle = .none;
        self.synced_revision = null;
        cx.notify();
    }

    /// Probe that records a compact-fold body row's natural height.
    const HeightProbe = struct { view: *TranscriptView, key: u64 };

    fn probeHeight(p: HeightProbe, b: zpui.Bounds(f32), _: *Window, _: *App) void {
        const gop = p.view.compact_heights.getOrPut(p.view.gpa, p.key) catch return;
        if (!gop.found_existing or @abs(gop.value_ptr.* - b.size.height) > 0.5) gop.value_ptr.* = b.size.height;
    }

    /// A compact-fold body row: each clips to `budget - prefix`, reproducing
    /// an ordinary fold's single overflow-hidden container.
    fn compactFoldBody(self: *TranscriptView, ix: usize, row: *const Row, work_id: []const u8, outer: zpui.StatefulDiv, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        const body = div().relative().flexNone().wFull().child(outer)
            .child(zpui.canvas(HeightProbe{ .view = self, .key = row.key }, probeHeight).absolute().inset0());
        const fold = self.folds.get(rows.hashStr(work_id)) orelse tools.Fold{};
        const open = fold.open orelse false;
        const reduced = window.prefersReducedMotion();
        const now = cx.app.executor.now();
        const animating = !reduced and fold.toggled_at != null and now -| fold.toggled_at.? < tools.tool_fold.totalNs(1.0);
        if (!animating) return if (open) zpui.intoAnyElement(body) else zpui.empty();
        const g = compactFoldGeometry(self.order.items, &self.compact_heights, work_id, ix);
        const clip = std.math.clamp(compactBodyHeight(fold, g[2], reduced, now) - g[0], 0, g[1]);
        window.requestAnimationFrame();
        if (g[1] > 0 and clip >= g[1]) return zpui.intoAnyElement(body);
        if (g[1] > 0 and clip <= 0) return zpui.empty();
        return zpui.intoAnyElement(div().relative().wFull().overflowHidden().h(px(clip)).child(body));
    }

    pub fn rowCount(self: *const TranscriptView) usize {
        return self.order.items.len;
    }

    pub fn rowAt(self: *const TranscriptView, ix: usize) *const Row {
        return self.order.items[ix];
    }

    fn indexOfKey(self: *const TranscriptView, key: u64) ?usize {
        for (self.keys.items, 0..) |k, i| if (k == key) return i;
        return null;
    }

    fn remeasureKey(self: *TranscriptView, key: u64) void {
        if (self.indexOfKey(key)) |ix| self.list.remeasureItems(.{ .start = ix, .end = ix + 1 });
    }

    // ---- listeners -----------------------------------------------------------------

    pub fn onToggleGroup(self: *TranscriptView, data: tools.GroupToggle, _: *const zpui.ClickEvent, window: *Window, cx: *Context(TranscriptView)) void {
        cx.app.propagate_event = false;
        if (data.compact_shell) return self.toggleCompactFold(data.key, window.prefersReducedMotion(), cx);
        const gop = self.folds.getOrPut(self.gpa, data.key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const currently = gop.value_ptr.open orelse data.auto_open;
        gop.value_ptr.open = !currently;
        gop.value_ptr.from = data.height;
        gop.value_ptr.toggled_at = cx.app.executor.now();
        self.remeasureKey(groupRowKey(self, data.key));
        cx.notify();
    }

    fn groupRowKey(_: *TranscriptView, key: u64) u64 {
        return key;
    }

    pub fn onToggleDetail(self: *TranscriptView, data: tools.DetailToggle, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        cx.app.propagate_event = false;
        const gop = self.details.getOrPut(self.gpa, data.key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const currently = gop.value_ptr.open orelse data.open;
        gop.value_ptr.open = !currently;
        gop.value_ptr.from = data.height + tools.tool_tree_row_height - tools.chip_card_height;
        gop.value_ptr.toggled_at = cx.app.executor.now();
        self.list.remeasure();
        cx.notify();
    }

    fn onToggleUser(self: *TranscriptView, key: u64, _: *const zpui.ClickEvent, window: *Window, cx: *Context(TranscriptView)) void {
        const was_open = self.user_expanded.contains(key);
        if (was_open) _ = self.user_expanded.remove(key) else self.user_expanded.put(self.gpa, key, {}) catch {};
        // `toggle_user_fold`: tween from the current endpoint, over a span
        // that scales with the travel (`user_resize_duration_ms`).
        if (!window.prefersReducedMotion()) {
            const collapsed_h = userCollapsedHeight();
            const full_h = @max(if (self.user_heights.get(key)) |c| c.* else 0, collapsed_h);
            const prev = self.user_folds.get(key) orelse UserFold{};
            self.user_folds.put(self.gpa, key, .{
                .from = if (was_open) full_h else collapsed_h,
                .epoch = prev.epoch +% 1,
                .toggled_at = cx.app.executor.now(),
                .duration_ms = userResizeDurationMs(full_h - collapsed_h),
            }) catch {};
        }
        self.remeasureKey(key);
        cx.notify();
    }

    fn clearUserHeights(self: *TranscriptView) void {
        var it = self.user_heights.valueIterator();
        while (it.next()) |c| self.gpa.destroy(c.*);
        self.user_heights.clearRetainingCapacity();
    }

    /// The measured-height cell for a user message (created on first use).
    fn userHeightCell(self: *TranscriptView, key: u64) ?*f32 {
        if (self.user_heights.get(key)) |c| return c;
        const c = self.gpa.create(f32) catch return null;
        c.* = 0;
        self.user_heights.put(self.gpa, key, c) catch {
            self.gpa.destroy(c);
            return null;
        };
        return c;
    }

    fn measureUserText(cell: *f32, bounds: zpui.Bounds(f32), _: *Window, _: *App) void {
        cell.* = bounds.size.height;
    }

    fn noUserPaint(_: *f32, _: zpui.Bounds(f32), _: *Window, _: *App) void {}

    fn onRowHover(self: *TranscriptView, keys: [2]u64, hovered: *const bool, _: *Window, cx: *Context(TranscriptView)) void {
        if (hovered.*) {
            if (self.hovered_row == keys[0] and self.hovered_entry == keys[1]) return;
            const changed = self.hovered_entry != keys[1];
            self.hovered_row = keys[0];
            self.hovered_entry = keys[1];
            if (changed) cx.notify();
        } else if (self.hovered_row == keys[0]) {
            self.hovered_row = 0;
            self.hovered_entry = 0;
            cx.notify();
        }
    }

    fn onCopyMessage(self: *TranscriptView, entry_key: u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        cx.app.propagate_event = false;
        for (self.order.items) |r| if (rows.hashStr(r.entry_id) == entry_key) if (r.copy_text) |t| {
            md.copyToClipboard(cx.app, t);
            self.copied_entry = entry_key;
            self.copied_at = cx.app.executor.now();
            md.scheduleRefresh(cx.app, 1700 * std.time.ns_per_ms);
            cx.notify();
            return;
        };
    }

    fn onMouseDownCapture(_: *TranscriptView, _: *const zpui.input.MouseDownEvent, window: *Window, _: *Context(TranscriptView)) void {
        // A fresh press clears the selection; the text under the pointer
        // (if any) starts a new one in the bubble phase.
        if (md.registry.sel_key != 0) {
            md.registry.clearSelection();
            window.refresh();
        }
    }

    fn onKey(_: *TranscriptView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(TranscriptView)) void {
        const k = ev.keystroke;
        if ((k.modifiers.control or k.modifiers.platform) and std.mem.eql(u8, k.key, "c")) {
            if (md.registry.selectedText()) |t| {
                md.copyToClipboard(cx.app, t);
                cx.app.propagate_event = false;
            }
        }
    }

    fn onRailHover(self: *TranscriptView, ix: usize, hovered: *const bool, _: *Window, cx: *Context(TranscriptView)) void {
        if (hovered.*) self.rail_hover = ix else if (self.rail_hover == ix) self.rail_hover = null;
        cx.notify();
    }

    fn onRailClick(self: *TranscriptView, row_ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(TranscriptView)) void {
        self.rail_glide_task.cancel();
        self.rail_glide_task = .none;
        self.rail_glide = null;
        if (window.prefersReducedMotion()) {
            self.list.scrollTo(.{ .item_ix = row_ix, .offset_in_item = 0 });
            cx.notify();
            return;
        }
        self.list.setFollowMode(.normal);
        self.rail_glide = .{ .row = row_ix, .from = self.list.scrollPxOffsetForScrollbar().y * -1, .start_ns = cx.app.executor.now() };
        self.railGlideTick(cx);
    }

    fn railGlideTick(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        self.rail_glide_task = .none;
        const g = self.rail_glide orelse return;
        const total = zt.motion.scroll_glide.totalNs(1.0);
        const elapsed = cx.app.executor.now() -| g.start_ns;
        if (elapsed >= total or g.row >= self.list.itemCount()) {
            self.rail_glide = null;
            if (g.row < self.list.itemCount()) self.list.scrollTo(.{ .item_ix = g.row, .offset_in_item = 0 });
            cx.notify();
            return;
        }
        const raw: f32 = @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total)));
        const target = self.list.offsetForItem(g.row);
        const want = zt.motion.lerp(g.from, target, zt.motion.scroll_glide.progress(raw));
        const current = -self.list.scrollPxOffsetForScrollbar().y;
        self.list.scrollBy(want - current);
        cx.notify();
        self.rail_glide_task = cx.timer(16 * std.time.ns_per_ms, railGlideTick) catch .none;
    }

    // ---- render --------------------------------------------------------------------

    pub fn render(self: *TranscriptView, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        self.syncCompactSetting(cx.app);
        self.sync(cx);
        // [motion] Scroll motion steps once per frame, after the last layout.
        {
            const now = cx.app.executor.now();
            const reduced = window.prefersReducedMotion();
            if (self.own_turn != null) self.stepOwnTurn(reduced, now, window);
            if (self.spring_on) self.stepSpring(now, window);
        }
        md.setClock(cx.app);
        {
            const list_width = self.list.viewportBounds().size.width;
            const column = if (list_width > 0) @min(self.content_width, list_width) else self.content_width;
            md.diagrams.beginFrame(column, window.scaleFactor());
        }
        const theme = themeOf(cx.app);
        var root = div().id("transcript").trackFocus(self.focus).relative().sizeFull().minH0()
            .textColor(theme.text).fontFamily(theme.font_sans)
            .captureAnyMouseDown(cx.listener(onMouseDownCapture))
            .onKeyDown(cx.listener(onKey));
        if (self.order.items.len > 0) {
            root = root.child(zpui.elements.list(self.list, cx, renderRow).sizeFull());
            root = root.child(self.renderRail(theme, window, cx));
        }
        if (self.lightbox) |lb| root = root.child(lb);
        // [wiring] "Scroll to bottom" pill over the composer.
        self.list.setScrollHandler(cx.listener(onListScroll));
        if (self.order.items.len > 0) self.updateJump();
        if (self.show_jump) root = root.child(self.renderJump(theme, cx));
        return zpui.intoAnyElement(root);
    }

    // ---- [wiring] jump to bottom ---------------------------------------------------

    /// Distance (px) from the end of the list, from the last layout.
    pub fn distanceFromEnd(self: *const TranscriptView) f32 {
        const max = self.list.maxOffsetForScrollbar().y;
        const cur = -self.list.scrollPxOffsetForScrollbar().y;
        return @max(max - cur, 0);
    }

    /// `jump_visibility`: offered past 320px, kept until within 2px.
    pub fn jumpVisibility(was_shown: bool, distance: f32) bool {
        return distance > (if (was_shown) jump_at_bottom_px else jump_threshold_px);
    }

    fn updateJump(self: *TranscriptView) void {
        const held = if (self.own_turn) |t| t.held else false;
        self.show_jump = jumpVisibility(self.show_jump, self.distanceFromEnd()) and !self.spring_on and !held;
    }

    fn onListScroll(self: *TranscriptView, _: *const zpui.elements.list_mod.ListScrollEvent, _: *Window, cx: *Context(TranscriptView)) void {
        // [motion] A wheel takes the viewport back from automatic scrolling
        // (`handle_scroll` → `cancel_user_hold`; the hold stands down).
        if (self.own_turn) |*t| t.held = false;
        if (self.spring_on) self.stopSpring();
        const was = self.show_jump;
        self.updateJump();
        if (was != self.show_jump) cx.notify();
    }

    /// The pill's click: back to the end, re-pinned to the tail
    /// (`jump_to_bottom` → `engage_pin`: a spring glide, not a snap).
    pub fn jumpToBottom(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        if (self.own_turn) |*t| t.held = false;
        self.show_jump = false;
        self.engagePin(appReduced(cx.app), cx.app.executor.now());
        cx.notify();
    }

    // ---- [motion] stick-to-bottom spring + own-turn hold -------------------------------

    fn appReduced(app: *App) bool {
        if (app.windows.items.len == 0) return false;
        const w = app.windows.items[0] orelse return false;
        return w.prefersReducedMotion();
    }

    /// `engage_pin`: long jumps teleport to within 2.5 viewports, then the
    /// spring glides the rest; reduced motion snaps to the tail.
    fn engagePin(self: *TranscriptView, reduced: bool, now: u64) void {
        if (reduced) {
            self.stopSpring();
            self.list.setFollowMode(.tail);
            self.list.scrollToEnd();
            return;
        }
        // Tail-follow would snap on the next layout; the spring owns it now.
        self.list.setFollowMode(.normal);
        const viewport = self.list.viewportBounds().size.height;
        const distance = self.distanceFromEnd();
        const glide_max = stick.glide_max_viewports * viewport;
        if (viewport > 0 and distance > glide_max) self.list.scrollBy(distance - glide_max);
        if (self.spring_settled_at) |at| if (now -| at >= stick.settle_grace_ms * std.time.ns_per_ms) {
            self.spring.reset();
            self.spring_last = null;
        };
        self.spring_settled_at = null;
        self.spring_on = true;
    }

    fn stopSpring(self: *TranscriptView) void {
        self.spring_on = false;
        self.spring.reset();
        self.spring_last = null;
        self.spring_settled_at = null;
    }

    /// `step_spring`: one frame of the glide toward the end (after the
    /// previous layout); landing re-enters tail-follow.
    fn stepSpring(self: *TranscriptView, now: u64, window: *Window) void {
        const frames = stick.framesSince(self.spring_last, now);
        self.spring_last = now;
        const target = self.list.maxOffsetForScrollbar().y;
        var distance = self.distanceFromEnd();
        const viewport = self.list.viewportBounds().size.height;
        const glide_max = stick.glide_max_viewports * viewport;
        if (viewport > 0 and distance > glide_max) {
            self.list.scrollBy(distance - glide_max);
            distance = glide_max;
        }
        const pos = target - distance;
        const next = self.spring.step(pos, target, frames);
        if (next > pos) self.list.scrollBy(next - pos);
        if (target - next <= 0.5) {
            // Land on the final item, not the estimated pixel total.
            self.list.setFollowMode(.tail);
            self.list.scrollToEnd();
            self.spring_on = false;
            self.spring_settled_at = now;
            return;
        }
        window.requestAnimationFrame();
    }

    /// `on_own_send`: un-glue the offset (a glued offset re-snaps to the end
    /// every layout, skipping the glide), then hold the prompt.
    fn onOwnSend(self: *TranscriptView, key: u64) void {
        self.stopSpring();
        self.list.setFollowMode(.normal);
        self.list.scrollBy(-1);
        self.own_turn = .{ .key = key };
        self.show_jump = false;
    }

    /// `own_send_inset`: row 0 carries the titlebar chrome in its own gap.
    fn ownSendInset(ix: usize) f32 {
        return if (ix == 0) 0 else layout.titlebar_height + 10;
    }

    /// `update_runway_minimum` + `step_own_turn`: size the reservation, hand
    /// a filled runway to the bottom pin, glide the prompt to its inset
    /// (`1 − 0.85^frames` per tick, snapping within 1 px), then hold it.
    fn stepOwnTurn(self: *TranscriptView, reduced: bool, now: u64, window: *Window) void {
        const turn = if (self.own_turn) |*t| t else return;
        const ix = self.indexOfKey(turn.key) orelse return; // the echo may land next frame
        const inset = ownSendInset(ix);
        self.list.setTailReservation(.{ .start = ix, .inset = inset - stick.own_send_scroll_slack_px });
        if (self.list.tailReservationFilled()) {
            const held = turn.held;
            self.own_turn = null;
            self.list.setTailReservation(null);
            if (held or self.distanceFromEnd() <= stick.at_bottom_px) self.engagePin(reduced, now);
            window.requestAnimationFrame();
            return;
        }
        if (!turn.held) return;
        const viewport = self.list.viewportBounds();
        if (viewport.size.height <= 0) {
            window.requestAnimationFrame();
            return;
        }
        const err: f32 = if (self.list.boundsForItem(ix)) |b|
            b.origin.y - (viewport.origin.y + inset)
        else
            (self.list.offsetForItem(ix) - inset) - (-self.list.scrollPxOffsetForScrollbar().y);
        if (turn.positioned) {
            // Landed: re-assert only real drift (the slack below is legal rest).
            if (err > 0.5 or err < -(stick.own_send_scroll_slack_px + 2.0)) {
                const frames = stick.framesSince(turn.last_tick, now);
                turn.last_tick = now;
                if (@abs(err) <= stick.own_send_glide_snap_px or reduced) self.list.scrollBy(err) else self.list.scrollBy(err * stick.glideEase(frames));
                window.requestAnimationFrame();
            } else turn.last_tick = null;
            return;
        }
        const frames = stick.framesSince(turn.last_tick, now);
        turn.last_tick = now;
        if (reduced or @abs(err) <= stick.own_send_glide_snap_px) {
            self.list.scrollBy(err);
            turn.positioned = true;
            turn.last_tick = null;
        } else self.list.scrollBy(err * stick.glideEase(frames));
        window.requestAnimationFrame();
    }

    fn onJumpClick(self: *TranscriptView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        self.jumpToBottom(cx);
    }

    fn renderJump(self: *TranscriptView, theme_in: *const Theme, cx: *Context(TranscriptView)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const glass = theme.isFrost();
        var pill = div().id("jump-to-bottom").role(.button).ariaLabel("Scroll to bottom").h(px(30)).roundedFull().border1().borderColor(theme.border).cursorPointer()
            .bg(if (glass) (if (theme.appearance.isDark()) theme.composerSidebarTint() else theme.glassOverlay()) else theme.surface_raised)
            .hover(sb.bg(if (glass) theme.glassHover() else theme.surface_raised_hover))
            .onClick(cx.listener(onJumpClick))
            .child(div().hFull().roundedFull().flex().itemsCenter().gap(px(6)).pl(px(11)).pr(px(13))
                .child(div().textSize(px(13)).textColor(theme.text_muted).child("\u{2193}"))
                .child(div().textSize(px(13)).textColor(theme.text).child("Scroll to bottom")));
        if (!glass) pill = pill.shadowMd();
        // Floating just above the composer pill (Rust: `top(-36)` over the
        // docked composer; the shell's clearance = pill stack + 64).
        const bottom = @max(self.bottom_clearance - 18, 12);
        // Frosted like the composer pill (one scene layer: blur, then the pill).
        // Frost OUTSIDE the entrance (Rust: `frosted(15, MENU_BLUR, dialog_in(anim_key, pill))`).
        return div().absolute().left(px(0)).right(px(10)).bottom(px(bottom)).flex().justifyCenter()
            .child(zpui.frosted(15, layout.menu_blur, zpui.withAnimation(pill, "jump-to-bottom-in", zt.motion.dialog_in.animation(), jumpInFrame)));
    }

    /// `motion::dialog_in` on the jump pill (opacity 0→1, 2px rise, 180 ms).
    fn jumpInFrame(el: zpui.StatefulDiv, t: f32) zpui.StatefulDiv {
        const f = zt.motion.dialogInFrame(t);
        return el.relative().opacity(f.opacity).top(px(f.offset_y));
    }

    // ---- [wiring] sidecar blobs ------------------------------------------------------

    /// "Show full output": fetch the blob (or re-show a fetched one).
    pub fn requestBlob(self: *TranscriptView, blob_ref: []const u8, cx: *Context(TranscriptView)) void {
        if (!self.blobs.request(self.gpa, blob_ref)) return cx.notify();
        const store = (self.store orelse return).read(cx);
        const req = cx.newWith(BlobRequest, BlobRequest.init, .{ cx.entityId(), blob_ref }) catch return;
        self.blob_requests.append(self.gpa, req) catch {};
        model.EngineState.request(store.engine, cx, BlobRequest, req.id, .FetchToolBlob, .{ .blobRef = blob_ref }, BlobRequest.onResult) catch {
            self.blobs.land(self.gpa, blob_ref, null);
        };
        self.remeasureAll();
        cx.notify();
    }

    pub fn onBlobClick(self: *TranscriptView, data: BlobClick, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        const ix = self.indexOfKey(data.row_key) orelse return;
        const row = self.order.items[ix];
        if (row.kind != .tool_group or data.tool_ix >= row.kind.tool_group.tools.len) return;
        var buf: [96]u8 = undefined;
        const aff = self.blobs.affordance(row.kind.tool_group.tools[data.tool_ix], &buf) orelse return;
        self.requestBlob(aff.blob_ref, cx);
    }

    /// A fetch landed (`text` null = failed): the detail upgrades in place.
    pub fn landBlob(self: *TranscriptView, blob_ref: []const u8, text: ?[]const u8, req_id: zpui.EntityId, cx: *Context(TranscriptView)) void {
        self.blobs.land(self.gpa, blob_ref, text);
        for (self.blob_requests.items, 0..) |r, i| if (r.id == req_id) {
            self.blob_requests.swapRemove(i).release(cx);
            break;
        };
        self.remeasureAll();
        cx.notify();
    }

    fn remeasureAll(self: *TranscriptView) void {
        self.list.remeasure();
    }

    fn nowMs(self: *const TranscriptView, cx: *Context(TranscriptView)) i64 {
        if (self.now_override_ms) |m| return m;
        const store = (self.store orelse return 0).read(cx);
        return model.Timestamp.now(store.io).toUnixMillis();
    }

    fn renderRow(self: *TranscriptView, ix: usize, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        if (ix >= self.order.items.len) return zpui.empty();
        const row = self.order.items[ix];
        const theme = themeOf(cx.app);
        const now = cx.app.executor.now();
        const top_gap: f32 = if (ix == 0) self.top_inset else rows.topGapFor(self.order.items[ix - 1], row);
        const is_last = ix + 1 == self.order.items.len;
        const bottom_pad: f32 = if (is_last) self.bottom_clearance + layout.transcript_fade_band + 8 else 0;

        // Per-appended-chunk fade veil on live rows (reduced motion: none; the
        // text painted meanwhile becomes the next veil's baseline).
        var row_veil: ?*md.veil.RowVeil = null;
        if (row.kind == .markdown and row.kind.markdown.live) {
            if (window.prefersReducedMotion()) {
                self.dropVeil(row.key);
                self.veil_baseline.put(self.gpa, row.key, {}) catch {};
            } else row_veil = self.veilFor(row.key);
        }
        const inner: AnyElement = switch (row.kind) {
            .user => self.renderUser(row, theme, window, cx),
            .markdown => |m| md.renderTopBlock(m.tree.*, m.block_ix, .{
                .veil = row_veil,
                .now_ns = now,
                .theme = theme,
                .key = row.key,
                .copy = true,
                .fit_toggle = true,
                // Live rows highlight too: the cache is keyed by content.
                .highlight = true,
                .file_links = self.workspace_root != null,
                // A streaming reply's tail fence keeps its source until the
                // reply moves past it.
                .diagrams = !m.live or m.block_ix + 1 < m.tree.blocks.len,
                .diagram_open = .{ .owner = @intFromEnum(cx.entityId()), .f = openDiagram },
            }, window),
            .tool_group => tools.renderGroup(self, row, theme, window, cx),
            .input_chip => |c| inputChip(c.header, c.resolved, theme),
            .error_chip => |c| errorChip(c.message, row.key, theme),
            .fork_marker => |f| forkMarker(f.source_title, theme),
            .generated_image => self.generatedImage(row, theme, cx),
        };
        if (row_veil) |v| {
            // The attach pass for this row is done: elements appearing from
            // the next pass on are newly streamed and fade normally.
            v.finishSeeding();
            if (v.isFading()) window.requestAnimationFrame();
        }

        const entry_key = rows.hashStr(row.entry_id);
        var column = div().wFull().maxW(px(self.content_width)).minW0().child(inner);
        if (row.timestamp) |ms| column = column.child(self.renderStrip(row, ms, entry_key, theme, cx));
        if (is_last) if (self.renderTrailer(theme, window, cx)) |t| {
            column = column.child(t);
        };

        // Entrance (FADE_IN: 500ms ease-out-expo, rise 4px) for live arrivals.
        if (self.entrance.get(row.key)) |start| {
            const reduced = window.prefersReducedMotion();
            const t = motion.fade_in.progressReduced(@as(f32, @floatFromInt(now -| start)) / @as(f32, @floatFromInt(motion.fade_in.totalNs(1.0))), reduced);
            if (t >= 1) {
                _ = self.entrance.remove(row.key);
            } else {
                const f = motion.fadeInFrame(t);
                column = column.relative().top(px(f.offset_y)).opacity(f.opacity);
                window.requestAnimationFrame();
            }
        }

        const outer = div().id(.{ "row", row.key })
            .onHover(cx.listenerWith([2]u64{ row.key, entry_key }, onRowHover))
            .wFull().flex().justifyCenter().pt(px(top_gap)).pb(px(bottom_pad)).px(px(48))
            .child(column);
        if (row.compact_fold) |work_id| return self.compactFoldBody(ix, row, work_id, outer, window, cx);
        return zpui.intoAnyElement(outer);
    }

    /// Hover-revealed metadata lane (reserved 32px) under an entry's last row.
    fn renderStrip(self: *TranscriptView, row: *const Row, ms: i64, entry_key: u64, theme: *const Theme, cx: *Context(TranscriptView)) zpui.Div {
        var strip = div().h(px(layout.space_sm + layout.space_md * 2)).pt(px(layout.space_sm)).wFull().flex().itemsCenter();
        if (row.is_user) strip = strip.justifyEnd();
        if (self.hovered_entry != entry_key) return strip;
        const ts = rows.formatTimestamp(zpui.window.arena_mod.frameAllocator().alloc(u8, 32) catch return strip, ms, self.utc_offset_minutes);
        var meta = div().flex().flexRow().itemsCenter().gap(px(layout.space_sm))
            .child(div().textSize(px(12)).textColor(theme.text_muted.opacity(0.55)).child(ts));
        if (row.copy_text != null) {
            const copied = self.copied_entry == entry_key and cx.app.executor.now() -| self.copied_at < 1600 * std.time.ns_per_ms;
            meta = meta.child(div().id(.{ "copy-msg", entry_key }).role(.button).ariaLabel(if (copied) "Copied" else "Copy message").size(px(layout.space_md * 2)).flex().itemsCenter().justifyCenter()
                .rounded(px(layout.control_radius)).cursorPointer().hover(sb.bg(theme.ink(0.08)))
                .onClick(cx.listenerWith(entry_key, onCopyMessage))
                .child(md.icon(if (copied) .check else .copy, 14, theme.text_muted)));
        }
        // `meta-{row}`: the revealed metadata fades in (FADE_QUICK).
        return strip.child(zpui.withAnimation(meta, .{ "meta", entry_key }, zt.motion.fade_quick.animation(), metaFade));
    }

    fn metaFade(el: zpui.Div, t: f32) zpui.Div {
        return el.opacity(t);
    }

    fn renderUser(self: *TranscriptView, row: *const Row, theme: *const Theme, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        const u = row.kind.user;
        var column = div().wFull().flex().flexCol();
        if (u.attachments.len > 0) {
            var strip = div().wFull().minW0().flexNone().flex().flexRow().flexWrap().justifyEnd().itemsStart().gap(px(8)).px(px(4)).pt(px(4)).pb(px(6));
            for (u.attachments, 0..) |a, aix| strip = strip.child(self.attachmentThumb(row, a, aix, theme, window, cx));
            column = column.child(strip);
        }
        if (u.badges.len > 0) {
            var strip = div().wFull().flex().flexRow().flexWrap().justifyEnd().itemsCenter().gap(px(6)).pb(px(6));
            for (u.badges, 0..) |*b, bix| strip = strip.child(rows.badges.pill(.{ "badge", mixKey(row.key, bix) }, b, theme));
            column = column.child(strip);
        }
        if (u.text.len > 0) {
            const collapsible = userNeedsCollapse(u.text);
            const expanded = self.user_expanded.contains(row.key);
            const flat = md.flatten(&.{.{ .text = u.text }}, theme, 400, theme.text);
            var text_el = div().relative().child(md.flatElement(flat, row.key ^ 0x55E7, .{ .theme = theme, .key = row.key }));
            // The full text stays laid out behind the clip; a probe records its height.
            if (collapsible) if (self.userHeightCell(row.key)) |cell| {
                text_el = text_el.child(zpui.canvas(cell, noUserPaint).withPrepaint(*f32, measureUserText).absolute().inset0());
            };
            var body = div().relative();
            const collapsed_text_h = @as(f32, @floatFromInt(user_collapsed_lines)) * user_line_height;
            // [motion] `{row}-user-resize-{epoch}`: the clip height glides
            // between the collapsed and full heights (incl. the "..." line).
            const fold = self.user_folds.get(row.key);
            const now = cx.app.executor.now();
            const collapsed_h = userCollapsedHeight();
            const full_h = @max(if (self.user_heights.get(row.key)) |c| c.* else 0, collapsed_h);
            const animating = collapsible and !window.prefersReducedMotion() and if (fold) |f|
                now -| f.toggled_at < zt.motion.scaledNs((@max(f.duration_ms, userResizeDurationMs(full_h - collapsed_h)) + 200) * std.time.ns_per_ms)
            else
                false;
            if (animating) {
                const f = fold.?;
                const to = if (expanded) full_h else collapsed_h;
                const ellipsis_h: f32 = if (expanded) 0 else user_line_height;
                const spec = userResizeSpec(full_h - collapsed_h);
                const raw = @as(f32, @floatFromInt(now -| f.toggled_at)) / @as(f32, @floatFromInt(@max(spec.totalNs(1.0), 1)));
                const h = @max(zt.motion.lerp(f.from, to, spec.progress(raw)) - ellipsis_h, 0);
                if (raw < 1) window.requestAnimationFrame();
                text_el = div().h(px(h)).overflowHidden().child(text_el);
                body = body.child(text_el);
                if (!expanded) body = body.child(div().h(px(user_line_height)).child("..."));
            } else if (collapsible and !expanded) {
                text_el = div().h(px(collapsed_text_h)).overflowHidden().child(text_el);
                body = body.child(text_el).child(div().h(px(user_line_height)).child("..."));
            } else body = body.child(text_el);
            if (collapsible) {
                body = body.child(div().mt(px(8)).flex().itemsStart().child(
                    div().id(.{ "user-exp", row.key }).role(.button).ariaLabel(if (expanded) "Collapse message" else "Expand message").ariaExpanded(expanded).group("user-toggle").flex().itemsCenter().gap(px(5))
                        .textSize(px(14)).lineHeight(px(user_line_height)).textColor(theme.text_muted).cursorPointer()
                        .hover(sb.textColor(theme.text))
                        .onClick(cx.listenerWith(row.key, onToggleUser))
                        .child(if (expanded) "Show less" else "Show more")
                        .child(div().flex().textColor(theme.text_muted).groupHover("user-toggle", sb.textColor(theme.text))
                            .child(md.iconInherit(if (expanded) .alt_arrow_up else .alt_arrow_down, 12))),
                ));
            }
            var bubble = div().minW0().maxW(px(self.content_width * layout.user_bubble_max_fraction))
                .bg(zt.theme.userBubbleBg(theme.appearance)).rounded(px(layout.bubble_radius))
                .px(px(layout.user_bubble_padding_x)).py(px(layout.user_bubble_padding_y))
                .textSize(px(14)).lineHeight(px(user_line_height)).textColor(theme.text).child(body);
            if (u.pending) bubble = bubble.opacity(0.65);
            column = column.child(div().wFull().flex().justifyEnd().child(bubble));
        }
        return zpui.intoAnyElement(column);
    }

    /// The working loader under the last row while the run is live.
    // ---- [wiring] retry + spawn chips -------------------------------------------------

    fn onRetryClick(self: *TranscriptView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        self.retrySend(cx);
    }

    /// `retry_send`: restart the pending-send grace window and ask the engine
    /// for a fresh delivery attempt (`RetryDelivery {chatId}`).
    pub fn retrySend(self: *TranscriptView, cx: *Context(TranscriptView)) void {
        const store = self.store orelse return;
        store.update(cx, TranscriptStore.retryPendingSend, .{});
        const st = store.read(cx);
        model.EngineState.send(st.engine, cx, .RetryDelivery, engine.protocol.params.ChatId{ .chatId = st.chat_id }) catch |err| {
            std.log.scoped(.zeron_transcript).warn("delivery retry RPC failed: {t}", .{err});
        };
        cx.notify();
    }

    /// A spawn chip (`row_key`, tool `ix`): emit `OpenSubagent` for its doc.
    pub fn onSpawnClick(self: *TranscriptView, data: [2]u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        const ix = self.indexOfKey(data[0]) orelse return;
        const row = self.order.items[ix];
        if (row.kind != .tool_group) return;
        const tools_ = row.kind.tool_group.tools;
        if (data[1] >= tools_.len) return;
        const item = tools_[data[1]];
        const doc = item.subagent_ref orelse return;
        const store = (self.store orelse return).read(cx);
        // The event is delivered after this handler: a static title buffer.
        const buf = &spawn_title_buf;
        const title = blk: {
            const entry = store.findEntry(row.entry_id) orelse break :blk "Subagent";
            const t = subagents.findTool(entry, item.part_id) orelse break :blk "Subagent";
            break :blk subagents.subagentTabTitle(buf, t.call);
        };
        cx.emit(subagents.OpenSubagent{ .chat_id = store.chat_id, .doc_id = doc, .title = title, .frozen = subagents.isFrozen(item.subagent_status) });
    }

    fn renderTrailer(self: *TranscriptView, theme: *const Theme, window: *Window, cx: *Context(TranscriptView)) ?zpui.Div {
        const store_e = self.store orelse return null;
        const store = store_e.read(cx);
        const n = store.len();
        const now_ms = self.nowMs(cx);
        var sending = false;
        var started_ms: i64 = now_ms;
        var working = false;
        if (n > 0) {
            const last = store.entry(n - 1);
            if (last.role == .assistant and last.status == .streaming) {
                working = true;
                // The turn began at the prompt that opened it.
                started_ms = last.createdAt;
                var i = n - 1;
                while (i > 0) : (i -= 1) if (store.entry(i - 1).role == .user) {
                    started_ms = store.entry(i - 1).createdAt;
                    break;
                };
            }
        }
        if (store.pendingEchoes().len > 0 or store.pending_send != null) {
            const ts = model.Timestamp.fromUnixMillis(now_ms);
            if (store.sendUndelivered(ts)) {
                // [wiring] the trailer IS the retry affordance (`retry_send`).
                return div().child(div().id("undelivered-retry").role(.button).flex().flexRow().itemsCenter().gap(px(layout.space_sm)).pt(px(layout.space_lg))
                    .textSize(px(12)).textColor(theme.danger).cursorPointer()
                    .onClick(cx.listener(onRetryClick))
                    .child("Not delivered \u{2014} click to retry"));
            }
            if (!working) {
                working = true;
                sending = true;
            }
        }
        if (!working) return null;
        const elapsed: i64 = @divTrunc(@max(now_ms - started_ms, 0), 1000);
        if (self.compact_mode and !sending and elapsed > 0) {
            var i = n;
            while (i > 0) {
                i -= 1;
                const e = store.entry(i);
                if (e.role != .assistant) continue;
                self.compact_last_elapsed.put(self.gpa, rows.hashStr(e.id), elapsed) catch {};
                break;
            }
        }
        const seed = rows.fnv1a(store.chat_id);
        const word = if (sending) "Sending" else rows.flavourWord(seed, elapsed);
        const phase = spinPhase(cx.app.executor.now(), window.prefersReducedMotion());
        window.requestAnimationFrame();
        var t = div().flex().flexRow().itemsCenter().gap(px(layout.space_sm)).pt(px(layout.space_lg)).textSize(px(11))
            .child(gradientSpinner(2.5, phase))
            .child(div().textSize(px(12)).textColor(theme.text_muted).child(zpui.fmt("{s}\u{2026}", .{word})));
        if (!sending) {
            var buf: [32]u8 = undefined;
            t = t.child(div().relative().top(px(1)).textColor(theme.text_faint).child(zpui.window.arena_mod.dupe(rows.formatElapsed(&buf, elapsed))));
        }
        return t;
    }

    // ---- message rail ------------------------------------------------------------------

    fn renderRail(self: *TranscriptView, theme: *const Theme, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        if (!self.rail_enabled) return zpui.empty();
        const vp = self.list.viewportBounds();
        if (vp.size.width > 0 and vp.size.width < rail_min_container_width) return zpui.empty();
        const a = zpui.window.arena_mod.frameAllocator();
        var tick_rows: std.ArrayList(usize) = .empty;
        for (self.order.items, 0..) |r, i| if (r.is_user) tick_rows.append(a, i) catch {};
        if (tick_rows.items.len < 2) return zpui.empty();
        // Active: the last prompt row at or above the reading line.
        const read_top = vp.origin.y + layout.titlebar_height + 10 + 0.5;
        var top_row = self.list.logicalScrollTop().item_ix;
        while (self.list.boundsForItem(top_row + 1)) |b| {
            if (b.origin.y <= read_top) top_row += 1 else break;
        }
        var active: usize = 0;
        for (tick_rows.items, 0..) |r, i| if (r <= top_row) {
            active = i;
        };
        const h = if (vp.size.height > 0) vp.size.height else 600;
        const usable = @max(h - 2 * rail_v_margin, tick_slot);
        const capacity = @min(@max(@as(usize, @intFromFloat(@floor((usable + tick_gap) / (tick_slot + tick_gap)))), 1), max_rail_ticks);
        const total = tick_rows.items.len;
        const cap = std.math.clamp(capacity, 1, total);
        var rail = div().absolute().left(px(16)).top0().bottom0().w(px(26)).flex().flexCol().itemsStart().justifyCenter().gap(px(tick_gap));
        var k: usize = 0;
        while (k < cap) : (k += 1) {
            const start = k * total / cap;
            const end = (k + 1) * total / cap;
            const rep = if (active >= start and active < end) active else start;
            const is_active = active >= start and active < end;
            const is_hovered = self.rail_hover == k;
            const bar_color = if (is_active or is_hovered) theme.text.opacity(0.8) else theme.ink(0.16);
            var tick = div().id(.{ "rail-tick", k }).role(.button).ariaLabel(zpui.fmt("Jump to message {d}", .{rep + 1})).relative().h(px(tick_slot)).wFull().flex().itemsCenter().cursorPointer()
                .onHover(cx.listenerWith(k, onRailHover))
                .onClick(cx.listenerWith(tick_rows.items[rep], onRailClick))
                .child(div().h(px(2)).w(px(if (is_hovered) 20 else 12)).rounded(px(1)).bg(bar_color));
            if (is_hovered) tick = tick.child(self.railCard(tick_rows.items[rep], end - start, theme));
            rail = rail.child(tick);
        }
        _ = window;
        return zpui.intoAnyElement(rail);
    }

    fn railCard(self: *TranscriptView, row_ix: usize, bucket_len: usize, theme: *const Theme) AnyElement {
        const r = self.order.items[row_ix];
        const a = zpui.window.arena_mod.frameAllocator();
        const prompt = truncatePreview(a, r.kind.user.text, 160);
        var reply: ?[]const u8 = null;
        var i = row_ix + 1;
        while (i < self.order.items.len and !self.order.items[i].is_user) : (i += 1) {
            const rr = self.order.items[i];
            if (rr.kind == .markdown) {
                const m = rr.kind.markdown;
                const blk = m.tree.blocks[m.block_ix].block;
                if (blk == .paragraph) {
                    var buf: std.ArrayList(u8) = .empty;
                    for (blk.paragraph) |run| buf.appendSlice(a, run.text) catch {};
                    reply = truncatePreview(a, buf.items, 200);
                    break;
                }
            }
        }
        var card = div().border1().borderColor(theme.border).rounded(px(layout.popover_card_radius)).shadowLg()
            .bg(theme.surface_overlay).w(px(280)).p(px(layout.space_sm)).flex().flexCol().gap(px(6))
            .child(div().textSize(px(12)).textColor(theme.text).child(prompt));
        if (reply) |rp| card = card.child(div().textSize(px(11)).textColor(theme.text_muted).child(rp));
        if (bucket_len > 1) card = card.child(div().textSize(px(10)).textColor(theme.text_muted).child(zpui.fmt("{d} prompts", .{bucket_len})));
        return zpui.intoAnyElement(zpui.deferred(zpui.anchored().snapToWindowWithMargin(.all(8))
            .child(div().pl(px(26)).child(card))).withPriority(2));
    }
};

var spawn_title_buf: [256]u8 = undefined;

/// [wiring] `SCROLL_BUTTON_THRESHOLD_PX` / `AT_BOTTOM_PX`.
pub const jump_threshold_px: f32 = 320;
pub const jump_at_bottom_px: f32 = 2;

/// [wiring] A chip's blob affordance click target.
pub const BlobClick = struct { row_key: u64, tool_ix: usize };

/// [wiring] One in-flight `FetchToolBlob`, routing its reply to the view.
pub const BlobRequest = struct {
    gpa: Allocator,
    view: zpui.EntityId,
    blob_ref: []u8,

    pub fn init(view: zpui.EntityId, blob_ref: []const u8, cx: *Context(BlobRequest)) !BlobRequest {
        return .{ .gpa = cx.gpa(), .view = view, .blob_ref = try cx.gpa().dupe(u8, blob_ref) };
    }

    pub fn deinit(self: *BlobRequest) void {
        self.gpa.free(self.blob_ref);
    }

    pub fn onResult(self: *BlobRequest, result: model.engine_state.CallResult, cx: *Context(BlobRequest)) void {
        const text: ?[]const u8 = switch (result) {
            .ok => |v| if (v == .object) (if (v.object.get("text")) |t| (if (t == .string) t.string else null) else null) else null,
            .err => null,
        };
        const weak: zpui.WeakEntity(TranscriptView) = .{ .id = self.view };
        _ = weak.update(cx.app, TranscriptView.landBlob, .{ self.blob_ref, text, cx.entityId() });
    }
};

fn truncatePreview(a: Allocator, text: []const u8, max_chars: usize) []const u8 {
    const flat = model.view.singleLine(a, text) catch return text;
    const n = std.unicode.utf8CountCodepoints(flat) catch flat.len;
    if (n <= max_chars) return flat;
    var it = std.unicode.Utf8View.initUnchecked(flat).iterator();
    var k: usize = 0;
    while (k + 1 < max_chars) : (k += 1) _ = it.nextCodepointSlice();
    return std.fmt.allocPrint(a, "{s}\u{2026}", .{std.mem.trimEnd(u8, flat[0..it.i], " ")}) catch flat;
}

pub fn userNeedsCollapse(text: []const u8) bool {
    var lines: usize = 1;
    for (text) |c| lines += @intFromBool(c == '\n');
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    return lines > user_collapsed_lines or chars > user_collapse_chars;
}

fn spinPhase(now_ns: u64, reduced: bool) f32 {
    if (reduced) return 0;
    const period = motion.gradient_spin.totalNs(1.0) * 2;
    return @as(f32, @floatFromInt(now_ns % period)) / @as(f32, @floatFromInt(period));
}

/// The 3×3 gradient spinner (loaders.rs `gradient_spinner`).
pub fn gradientSpinner(cell: f32, phase: f32) zpui.Div {
    var col = div().flex().flexCol().gap(px(cell / 2));
    const side = motion.matrix_side;
    for (0..side) |r| {
        var line = div().flex().flexRow().gap(px(cell / 2));
        const tint = zpui.rgb(motion.gspin_row_tints[r]).toHsla();
        for (0..side) |c| line = line.child(div().size(px(cell)).rounded(px(cell / 2)).bg(tint)
            .opacity(motion.gspinOpacity(phase + motion.gspinCellPhase(r, c), motion.gspin_dim)));
        col = col.child(line);
    }
    return col;
}

/// `input_chip`: a passive one-line chip marking a question the agent asked.
pub fn inputChip(header: []const u8, resolved: bool, theme: *const Theme) AnyElement {
    return zpui.intoAnyElement(div().py(px(4)).wFull().child(
        div().h(px(34)).wFull().flex().itemsCenter().gap(px(8)).overflowHidden().rounded(px(10)).border1()
            .borderColor(theme.hairline(0.08)).bg(theme.ink(0.045)).px(px(8)).textSize(px(12))
            .child(div().flexNone().size(px(20)).rounded(px(6)).bg(theme.ink(0.09)).flex().itemsCenter().justifyCenter()
                .child(md.icon(.chat_round_line, 12, theme.text_muted)))
            .child(div().flexNone().fontWeight(500).textColor(theme.text_muted).child("Question"))
            .child(div().minW0().flex1().truncate().textColor(theme.text.opacity(0.9))
                .child(if (resolved) header else "Awaiting your answer\u{2026}")),
    ));
}

/// `error_chip`: the tinted notice card (notice.rs, tile variant).
pub fn errorChip(message: []const u8, key: u64, theme: *const Theme) AnyElement {
    const accent = theme.danger;
    const muted = theme.danger_muted;
    const header = div().flex().itemsCenter().gap(px(8))
        .child(div().flexNone().size(px(20)).rounded(px(6)).bg(accent.opacity(0.12)).flex().itemsCenter().justifyCenter()
            .child(md.icon(.danger_triangle, 12, muted.opacity(0.8))))
        .child(div().fontWeight(500).textColor(muted.opacity(0.8)).child("Error"))
        .child(div().flex1())
        .child(div().id(.{ "notice-copy", key }).flexNone().size(px(20)).rounded(px(6)).flex().itemsCenter().justifyCenter()
            .cursorPointer().hover(sb.bg(accent.opacity(0.12)))
            .child(md.icon(.copy, 12, muted.opacity(0.8))));
    return zpui.intoAnyElement(div().py(px(4)).wFull().child(
        div().overflowHidden().wFull().flex().flexCol().gap(px(6)).rounded(px(10)).border1().borderColor(accent.opacity(0.16))
            .bg(accent.opacity(0.05)).px(px(10)).py(px(8)).textSize(px(12))
            .child(header)
            .child(div().minW0().wFull().textColor(theme.text.opacity(0.8)).child(message)),
    ));
}

/// `fork_marker`: a quiet labeled seam between copied history and new turns.
pub fn forkMarker(title: []const u8, theme: *const Theme) AnyElement {
    const rule = struct {
        fn f(t: *const Theme) zpui.Div {
            return div().flex1().minW0().h(px(1)).bg(t.border_strong);
        }
    }.f;
    return zpui.intoAnyElement(div().py(px(14)).wFull().minW0().overflowHidden().flex().flexCol().gap(px(6))
        .child(div().wFull().minW0().flex().itemsCenter().gap(px(10))
            .child(rule(theme))
            .child(div().flexNone().textSize(px(12)).textColor(theme.text_muted.opacity(0.7)).child("Forked from"))
            .child(rule(theme)))
        .child(div().wFull().minW0().truncate().textCenter().textSize(px(13)).fontWeight(500).textColor(theme.text_muted).child(title)));
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Parse a transcript fixture: a bare `[SessionMessageEntry]`, a `{reset}`
/// frame, a `TranscriptUpdate` (`{frame: …}`) or `{entries: […]}`.
pub fn parseFixture(arena: Allocator, bytes: []const u8) ![]protocol.SessionMessageEntry {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, opts);
    const arr: std.json.Value = switch (v) {
        .array => v,
        .object => |o| if (o.get("reset")) |r| r else if (o.get("entries")) |e| e else if (o.get("frame")) |f| (if (f == .object) f.object.get("reset") orelse return error.NotAReset else return error.NotAReset) else if (o.get("transcript")) |t| t else return error.UnknownFixture,
        else => return error.UnknownFixture,
    };
    return std.json.parseFromValueLeaky([]protocol.SessionMessageEntry, arena, arr, opts);
}

/// Replace a store's transcript with `entries` (fixture mode, no engine).
pub fn loadEntries(store: Entity(TranscriptStore), entries: []protocol.SessionMessageEntry, app: *App) !void {
    const Apply = struct {
        fn run(s: *TranscriptStore, e: []protocol.SessionMessageEntry, cx: *Context(TranscriptStore)) void {
            s.transcript.apply(.{ .reset = e }) catch return;
            s.replayed = true;
            s.revision +%= 1;
            cx.emit(model.transcript_store.Changed{ .reset = true });
            cx.notify();
        }
    };
    store.update(app, Apply.run, .{entries});
}

/// Apply one delta/reset frame to a store (fixture streaming).
pub fn applyFrame(store: Entity(TranscriptStore), frame: protocol.TranscriptFrame, app: *App) void {
    const Apply = struct {
        fn run(s: *TranscriptStore, f: protocol.TranscriptFrame, cx: *Context(TranscriptStore)) void {
            s.transcript.apply(f) catch |err| std.log.scoped(.transcript).warn("fixture frame: {t}", .{err});
            s.replayed = true;
            s.revision +%= 1;
            const text_only = f == .delta and f.delta.upsert.len == 0 and f.delta.remove.len == 0;
            if (text_only) cx.emit(model.transcript_store.TextChanged{}) else {
                cx.emit(model.transcript_store.Changed{});
                cx.notify();
            }
        }
    };
    store.update(app, Apply.run, .{frame});
}
