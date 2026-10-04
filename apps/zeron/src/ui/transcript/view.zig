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
const files = md.file_icons;
const wl = @import("workspace_links.zig");

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
    /// Row key → entrance start (ns) for rows that arrived live.
    entrance: std.AutoHashMapUnmanaged(u64, u64) = .empty,
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
        self.user_expanded.deinit(self.gpa);
        self.entrance.deinit(self.gpa);
        self.list.release();
        self.focus.release(app);
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
        self.entrance.clearRetainingCapacity();
        self.user_expanded.clearRetainingCapacity();
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
        if (state.read(cx).transcript) |t| self.attach(t, cx) catch {} else if (self.store != null) self.detach(cx);
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
        while (i < n) : (i += 1) try self.syncEntry(store.entry(i), false, &seen, &new_order);
        for (store.pendingEchoes()) |*echo| {
            if (store.findEntry(echo.entry.id) != null) continue;
            try self.syncEntry(&echo.entry, true, &seen, &new_order);
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
            for (new_rows) |r| if (!old_keys.contains(r.key)) try self.entrance.put(gpa, r.key, now_ns);
        }
        if (new_rows.len > 0 and !self.loaded and self.start_at_top) {
            self.list.setFollowMode(.normal);
            self.list.scrollTo(.{ .item_ix = 0, .offset_in_item = 0 });
        }
        if (new_rows.len > 0) self.loaded = true;

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

    fn syncEntry(self: *TranscriptView, entry: *const protocol.SessionMessageEntry, pending: bool, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(*const Row)) !void {
        const gpa = self.gpa;
        const fp = rows.entryFingerprint(entry, pending, false);
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
        for (gop.value_ptr.*.rows) |*r| try out.append(gpa, r);
    }

    fn buildOpts(self: *TranscriptView, pending: bool) rows.BuildOptions {
        return .{ .pending = pending, .probe = if (self.workspace_root != null) &self.probe else null };
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

    pub fn onToggleGroup(self: *TranscriptView, data: tools.GroupToggle, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        cx.app.propagate_event = false;
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

    fn onToggleUser(self: *TranscriptView, key: u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        if (self.user_expanded.contains(key)) _ = self.user_expanded.remove(key) else self.user_expanded.put(self.gpa, key, {}) catch {};
        self.remeasureKey(key);
        cx.notify();
    }

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

    fn onRailClick(self: *TranscriptView, row_ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TranscriptView)) void {
        self.list.scrollTo(.{ .item_ix = row_ix, .offset_in_item = 0 });
        cx.notify();
    }

    // ---- render --------------------------------------------------------------------

    pub fn render(self: *TranscriptView, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        self.sync(cx);
        md.setClock(cx.app);
        const theme = themeOf(cx.app);
        var root = div().id("transcript").trackFocus(self.focus).relative().sizeFull().minH0()
            .textColor(theme.text).fontFamily(theme.font_sans)
            .captureAnyMouseDown(cx.listener(onMouseDownCapture))
            .onKeyDown(cx.listener(onKey));
        if (self.order.items.len > 0) {
            root = root.child(zpui.elements.list(self.list, cx, renderRow).sizeFull());
            root = root.child(self.renderRail(theme, window, cx));
        }
        return zpui.intoAnyElement(root);
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

        const inner: AnyElement = switch (row.kind) {
            .user => self.renderUser(row, theme, window, cx),
            .markdown => |m| md.renderTopBlock(m.tree.*, m.block_ix, .{
                .theme = theme,
                .key = row.key,
                .copy = true,
                .fit_toggle = true,
                // Live rows highlight too: the cache is keyed by content.
                .highlight = true,
                .file_links = self.workspace_root != null,
            }, window),
            .tool_group => tools.renderGroup(self, row, theme, window, cx),
            .input_chip => |c| inputChip(c.header, c.resolved, theme),
            .error_chip => |c| errorChip(c.message, row.key, theme),
            .fork_marker => |f| forkMarker(f.source_title, theme),
            .generated_image => |g| generatedImage(g.path, row.key, theme),
        };

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

        return zpui.intoAnyElement(div().id(.{ "row", row.key })
            .onHover(cx.listenerWith([2]u64{ row.key, entry_key }, onRowHover))
            .wFull().flex().justifyCenter().pt(px(top_gap)).pb(px(bottom_pad)).px(px(48))
            .child(column));
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
            meta = meta.child(div().id(.{ "copy-msg", entry_key }).size(px(layout.space_md * 2)).flex().itemsCenter().justifyCenter()
                .rounded(px(layout.control_radius)).cursorPointer().hover(sb.bg(theme.ink(0.08)))
                .onClick(cx.listenerWith(entry_key, onCopyMessage))
                .child(md.icon(if (copied) .check else .copy, 14, theme.text_muted)));
        }
        return strip.child(meta);
    }

    fn renderUser(self: *TranscriptView, row: *const Row, theme: *const Theme, window: *Window, cx: *Context(TranscriptView)) AnyElement {
        _ = window;
        const u = row.kind.user;
        var column = div().wFull().flex().flexCol();
        if (u.attachments.len > 0) {
            var strip = div().wFull().minW0().flexNone().flex().flexRow().flexWrap().justifyEnd().itemsStart().gap(px(8)).px(px(4)).pt(px(4)).pb(px(6));
            for (u.attachments, 0..) |att, aix| strip = strip.child(attachmentThumb(att, mixKey(row.key, aix), theme));
            column = column.child(strip);
        }
        if (u.text.len > 0) {
            const collapsible = userNeedsCollapse(u.text);
            const expanded = self.user_expanded.contains(row.key);
            const flat = md.flatten(&.{.{ .text = u.text }}, theme, 400, theme.text);
            var text_el = div().child(md.flatElement(flat, row.key ^ 0x55E7, .{ .theme = theme, .key = row.key }));
            var body = div().relative();
            if (collapsible and !expanded) {
                text_el = div().h(px(@as(f32, @floatFromInt(user_collapsed_lines)) * user_line_height)).overflowHidden().child(text_el);
                body = body.child(text_el).child(div().h(px(user_line_height)).child("..."));
            } else body = body.child(text_el);
            if (collapsible) {
                body = body.child(div().mt(px(8)).flex().itemsStart().child(
                    div().id(.{ "user-exp", row.key }).group("user-toggle").flex().itemsCenter().gap(px(5))
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
                return div().flex().flexRow().itemsCenter().gap(px(layout.space_sm)).pt(px(layout.space_lg))
                    .textSize(px(12)).textColor(theme.danger).child("Not delivered \u{2014} click to retry");
            }
            if (!working) {
                working = true;
                sending = true;
            }
        }
        if (!working) return null;
        const elapsed: i64 = @divTrunc(@max(now_ms - started_ms, 0), 1000);
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
            var tick = div().id(.{ "rail-tick", k }).relative().h(px(tick_slot)).wFull().flex().itemsCenter().cursorPointer()
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

fn attachmentThumb(att: rows.Attachment, key: u64, theme: *const Theme) zpui.StatefulDiv {
    const frame = div().id(.{ "att", key }).flexNone().w(px(att_thumb_w)).h(px(att_thumb_h)).rounded(px(8)).overflowHidden()
        .relative().border1().borderColor(theme.hairline(0.11)).bg(theme.ink(0.035));
    const pending = std.mem.startsWith(u8, att.path, "pending://") or std.mem.startsWith(u8, att.path, "pending/");
    if (pending) return frame.child(div().absolute().inset0().flex().itemsCenter().justifyCenter().bg(zpui.hsla(0, 0, 0, 0.38)));
    return frame.child(zpui.img(zpui.ImageSource{ .path = att.path }).w(px(att_thumb_w - 2)).h(px(att_thumb_h - 2))
        .rounded(px(7)).objectFit(.cover));
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

/// A generated image part (`render_generated_image`).
pub fn generatedImage(path: []const u8, key: u64, theme: *const Theme) AnyElement {
    return zpui.intoAnyElement(div().id(.{ "gen-img", key }).w(px(512)).maxWFull().h(px(320)).flex().itemsCenter().justifyCenter()
        .rounded(px(12)).overflowHidden().bg(theme.ink(0.045)).textColor(theme.text_muted)
        .child(zpui.img(zpui.ImageSource{ .path = path }).sizeFull().rounded(px(12)).objectFit(.contain)));
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
