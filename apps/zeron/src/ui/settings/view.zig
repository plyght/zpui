//! `SettingsView` — the full-window settings mode (zeron `render_settings_page`
//! + `render_settings_nav` + every settings page entity, folded into one view
//! because Zig listeners are `(view, data)` pairs, not closures).
//!
//! ```zig
//! const view = try cx.newWith(SettingsView, SettingsView.init, .{ app_state, fixtures_dir, io, window });
//! try subs.add(gpa, try cx.subscribe(view, Shell.onSettingsClose));   // event: settings.Close
//! div().child(view)                                                   // fills the window under the titlebar strip
//! ```
//!
//! Layout: the section column stands where the chat sidebar was (same width,
//! Back + roving section tabs + the account footer), the page scrolls to the
//! window's top edge with 16px edge fades. Pages live in sibling files
//! (`general.zig`, `appearance.zig`, …) as `render(view, theme, window, cx)`;
//! all state and listeners live here. Every control writes through
//! `SettingsStore` (`store.zig`) and re-themes / rebinds the app live.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const select_mod = @import("select.zig");

const general = @import("general.zig");
const appearance = @import("appearance.zig");
const notifications = @import("notifications.zig");
const voice = @import("voice.zig");
const shortcuts = @import("shortcuts.zig");
const providers = @import("providers.zig");
const devices = @import("devices.zig");
const files = @import("files.zig");
const appshots = @import("appshots.zig");
const archived = @import("archived.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const rems = ui.rems;
const Theme = ui.Theme;
const Hsla = zpui.Hsla;
const settings = model.settings;
const protocol = engine.protocol;
const UiSettings = model.UiSettings;
const ShortcutId = settings.ShortcutId;

pub const Section = settings.SettingsSection;
pub const SelectId = select_mod.SelectId;
pub const Toggle = select_mod.Toggle;

/// Emitted when the user leaves settings (Back, Escape, the gear).
pub const Close = struct {};

/// Sidebar + header label (Rust `SettingsSection::label` in shell.rs).
pub fn sectionLabel(s: Section) []const u8 {
    return switch (s) {
        .archived => "Archived sessions",
        else => s.label(),
    };
}

fn sectionIcon(s: Section) ui.icon.Icon {
    return switch (s) {
        .devices, .appshots => .monitor,
        .harnesses => .widget,
        .agents => .key_minimalistic,
        .appearance => .tuning,
        .files => .folder,
        .notifications => .bell,
        .voice => .microphone,
        .shortcuts => .keyboard,
        .general => .settings,
        .archived => .archive_minimalistic,
    };
}

fn startsNavGroup(s: Section) bool {
    return s == .harnesses or s == .files;
}

fn navHoverKey(s: Section) []const u8 {
    return switch (s) {
        inline else => |t| "settings-nav-" ++ @tagName(t),
    };
}

/// A temporary element arena for listeners that reuse render-time helpers
/// (option lists, visible rows) outside a draw.
pub const Scratch = struct {
    arena: zpui.window.arena_mod.ElementArena,
    prev: ?*zpui.window.arena_mod.ElementArena = null,

    pub fn begin(self: *Scratch) void {
        self.prev = zpui.window.arena_mod.enter(&self.arena);
    }

    pub fn end(self: *Scratch) void {
        zpui.window.arena_mod.exit(self.prev);
        self.arena.deinit();
    }
};

fn scratch(gpa: std.mem.Allocator) Scratch {
    return .{ .arena = .init(gpa) };
}

/// A per-key travel (`SwitchTravel` / `TabSelectionTravel`).
const Tween = struct { from: f32, target: f32, start: u64, ms: u64 };

pub const RenameDialog = struct {
    device_id: []u8,
    input: Entity(input.TextInput),
    sub: zpui.Subscription,
};

pub const SettingsView = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    state: Entity(model.AppState),
    /// Fixture directory (fixture mode) for data the engine would stream.
    fixtures_dir: ?[]const u8,
    focus: zpui.FocusHandle,
    record_focus: zpui.FocusHandle,
    section: Section,
    page_scroll: zpui.ScrollHandle,
    nav_scroll: zpui.ScrollHandle,
    menu_scroll: zpui.ScrollHandle,
    subs: zpui.Subscriptions = .{},

    // ---- select dropdowns ----
    open_select: ?SelectId = null,
    highlighted: usize = 0,
    /// The select a mouse-down-outside just closed (so the trigger's own
    /// click does not reopen it).
    closed_select: ?SelectId = null,
    closed_at: u64 = 0,

    // ---- motion ----
    tweens: std.AutoHashMapUnmanaged(u32, Tween) = .empty,
    animating: bool = false,

    // ---- shortcut recording ----
    recording: ?ShortcutId = null,
    notice: std.ArrayList(u8) = .empty,
    notice_for: ?ShortcutId = null,

    // ---- devices ----
    rename: ?RenameDialog = null,
    copied: ?[]u8 = null,
    /// Local renames (fixture mode / until the engine echoes the change).
    device_names: std.StringHashMapUnmanaged([]u8) = .empty,

    // ---- providers ----
    expanded_harness: ?protocol.HarnessId = null,
    harness_overrides: std.EnumArray(protocol.HarnessId, ?bool) = .initFill(null),
    fixture_updates: ?std.json.Parsed([]model.types.HarnessUpdateStatus) = null,
    update_override: std.EnumArray(protocol.HarnessId, ?model.types.HarnessUpdatePhase) = .initFill(null),
    checking_updates: bool = false,
    /// The provider whose update-policy select is (being) opened.
    policy_harness: ?protocol.HarnessId = null,
    policy_override: std.EnumArray(protocol.HarnessId, ?model.types.HarnessUpdatePolicy) = .initFill(null),

    // ---- appearance ----
    width_hovered: bool = false,
    width_pressed: bool = false,
    width_bounds: zpui.Bounds(f32) = .{ .origin = .zero, .size = .zero },

    // ---- archived ----
    unarchived: std.ArrayList([]u8) = .empty,

    pub const Events = .{Close};

    pub fn init(state: Entity(model.AppState), fixtures_dir: ?[]const u8, io: std.Io, window: *Window, cx: *Context(SettingsView)) !SettingsView {
        store.ensure(cx.app);
        const focus = cx.focusHandle();
        window.focus(focus);
        var self: SettingsView = .{
            .gpa = cx.gpa(),
            .io = io,
            .state = state.retain(cx),
            .fixtures_dir = fixtures_dir,
            .focus = focus,
            .record_focus = cx.focusHandle(),
            .section = store.current(cx).settingsSection.reopenable(),
            .page_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .nav_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .menu_scroll = zpui.ScrollHandle.init(cx.gpa()),
        };
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.catalog, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.auth, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observeGlobal(model.SettingsStore, onSettingsChanged));
        self.loadFixtureUpdates();
        return self;
    }

    pub fn deinit(self: *SettingsView, app: *App) void {
        if (self.recording != null) store.applyKeymap(app);
        self.subs.deinit(self.gpa);
        self.closeRename(app);
        if (self.copied) |c| self.gpa.free(c);
        var it = self.device_names.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.device_names.deinit(self.gpa);
        for (self.unarchived.items) |id| self.gpa.free(id);
        self.unarchived.deinit(self.gpa);
        if (self.fixture_updates) |*p| p.deinit();
        self.notice.deinit(self.gpa);
        self.tweens.deinit(self.gpa);
        self.page_scroll.release();
        self.nav_scroll.release();
        self.menu_scroll.release();
        self.record_focus.release(app);
        self.focus.release(app);
        self.state.release(app);
    }

    fn onModelChanged(_: *SettingsView, _: anytype, cx: *Context(SettingsView)) void {
        cx.notify();
    }

    fn onSettingsChanged(_: *SettingsView, cx: *Context(SettingsView)) void {
        cx.notify();
    }

    fn loadFixtureUpdates(self: *SettingsView) void {
        const dir = self.fixtures_dir orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/harness-updates.json", .{dir}) catch return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 20)) catch return;
        defer self.gpa.free(bytes);
        self.fixture_updates = std.json.parseFromSlice([]model.types.HarnessUpdateStatus, self.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    }

    // ---- helpers -----------------------------------------------------------------------

    pub fn now(cx: anytype) u64 {
        return ui.loaders.nowNs(cx);
    }

    /// Animate `key` toward `target` over `ms` (ease-out cubic), returning
    /// the current value; keeps frames coming while in flight.
    pub fn travel(self: *SettingsView, cx: anytype, key: u32, target: f32, ms: u64) f32 {
        const t_now = now(cx);
        const gop = self.tweens.getOrPut(self.gpa, key) catch return target;
        if (!gop.found_existing) gop.value_ptr.* = .{ .from = target, .target = target, .start = t_now, .ms = ms };
        const tw = gop.value_ptr;
        if (tw.target != target) {
            const cur = tweenValue(tw.*, t_now);
            tw.* = .{ .from = cur, .target = target, .start = t_now, .ms = ms };
        }
        if (reducedMotion(cx)) tw.* = .{ .from = target, .target = target, .start = t_now, .ms = ms };
        const v = tweenValue(tw.*, t_now);
        if (@abs(v - target) > 0.001) self.animating = true;
        return v;
    }

    fn tweenValue(tw: Tween, t_now: u64) f32 {
        const dur = @as(f32, @floatFromInt(tw.ms * std.time.ns_per_ms));
        const elapsed = @as(f32, @floatFromInt(t_now -| tw.start));
        const t = if (dur <= 0) 1 else @min(elapsed / dur, 1);
        const eased = 1 - (1 - t) * (1 - t) * (1 - t);
        return tw.from + (tw.target - tw.from) * eased;
    }

    pub fn reducedMotion(cx: anytype) bool {
        const t = store.current(cx).theme;
        return zt.motion.resolveReduced(t.reduce_motion, false, false, true);
    }

    pub fn theme(cx: anytype) Theme {
        return ui.theme.get(cx).forSettingsSurface();
    }

    // ---- section navigation ------------------------------------------------------------

    pub fn openSection(self: *SettingsView, section: Section, cx: *Context(SettingsView)) void {
        if (self.section == section) return;
        self.closeSelect();
        self.stopRecording(cx);
        self.clearNotice();
        self.section = section;
        self.page_scroll.setOffset(.{ .x = 0, .y = 0 });
        const Set = struct {
            fn f(s_: Section, s: *UiSettings, _: std.mem.Allocator) void {
                s.settingsSection = s_;
            }
        };
        store.update(cx, .debounced, section, Set.f);
        cx.notify();
    }

    fn onNav(self: *SettingsView, section: Section, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        self.openSection(section, cx);
    }

    fn onNavHover(_: *SettingsView, section: Section, hovered: *const bool, _: *Window, cx: *Context(SettingsView)) void {
        ui.hover.set(cx, navHoverKey(section), hovered.*);
    }

    fn onBackHover(_: *SettingsView, hovered: *const bool, _: *Window, cx: *Context(SettingsView)) void {
        ui.hover.set(cx, "settings-back-hover", hovered.*);
    }

    pub fn onBack(_: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        cx.emit(Close{});
    }

    // ---- keyboard ----------------------------------------------------------------------

    fn onKeyCapture(self: *SettingsView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        if (self.recording) |id| {
            self.recordKeystroke(id, ev.keystroke, cx);
            cx.stopPropagation();
            return;
        }
        const key = ev.keystroke.key;
        if (self.open_select) |sel| {
            const count = select_mod.optionCount(self, sel, cx);
            if (std.mem.eql(u8, key, "escape")) {
                self.closeSelect();
            } else if (std.mem.eql(u8, key, "up")) {
                self.highlighted = if (self.highlighted == 0) count -| 1 else self.highlighted - 1;
                self.menu_scroll.scrollToItem(self.highlighted);
            } else if (std.mem.eql(u8, key, "down")) {
                self.highlighted = if (count == 0) 0 else (self.highlighted + 1) % count;
                self.menu_scroll.scrollToItem(self.highlighted);
            } else if (std.mem.eql(u8, key, "home")) {
                self.highlighted = 0;
            } else if (std.mem.eql(u8, key, "end")) {
                self.highlighted = count -| 1;
            } else if (std.mem.eql(u8, key, "enter") or std.mem.eql(u8, key, "space")) {
                const ix = self.highlighted;
                self.closeSelect();
                select_mod.commit(self, sel, ix, cx);
            } else return;
            cx.stopPropagation();
            cx.notify();
            return;
        }
        if (self.rename != null) return;
    }

    fn onKey(self: *SettingsView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(SettingsView)) void {
        const key = ev.keystroke.key;
        if (std.mem.eql(u8, key, "escape")) {
            if (self.rename != null) {
                self.closeRename(cx.app);
                cx.notify();
            } else cx.emit(Close{});
            cx.stopPropagation();
            return;
        }
        // Roving nav: up/down while the page itself has focus.
        if (self.rename == null and ev.keystroke.modifiers.none()) {
            const items = navItems();
            var cur: usize = 0;
            for (items, 0..) |s, i| if (s == self.section) {
                cur = i;
            };
            const next: ?usize = if (std.mem.eql(u8, key, "pageup")) (cur + items.len - 1) % items.len else if (std.mem.eql(u8, key, "pagedown")) (cur + 1) % items.len else null;
            if (next) |n| {
                self.openSection(items[n], cx);
                cx.stopPropagation();
            }
        }
    }

    fn navItems() []const Section {
        const all = comptime blk: {
            var out: [Section.all.len]Section = undefined;
            var n: usize = 0;
            for (Section.all) |s| if (s.visibleInNav()) {
                out[n] = s;
                n += 1;
            };
            break :blk out[0..n].*;
        };
        return &all;
    }

    // ---- selects -----------------------------------------------------------------------

    pub fn closeSelect(self: *SettingsView) void {
        self.open_select = null;
    }

    pub fn onSelectTrigger(self: *SettingsView, id: SelectId, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        if (self.open_select == id) {
            self.closeSelect();
        } else if (self.closed_select == id and now(cx) -| self.closed_at < 250 * std.time.ns_per_ms) {
            // The outside-press that just closed it was this trigger.
        } else {
            self.open_select = id;
            self.highlighted = select_mod.selectedIndex(self, id, cx);
            self.menu_scroll.setOffset(.{ .x = 0, .y = 0 });
            self.menu_scroll.scrollToItem(self.highlighted);
        }
        self.closed_select = null;
        cx.notify();
    }

    pub fn onSelectOutside(self: *SettingsView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
        if (self.open_select) |id| {
            self.closed_select = id;
            self.closed_at = now(cx);
            self.closeSelect();
            cx.notify();
        }
    }

    pub fn onSelectOption(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        cx.stopPropagation();
        const id = self.open_select orelse return;
        self.closeSelect();
        select_mod.commit(self, id, ix, cx);
        cx.notify();
    }

    pub fn onSelectHover(_: *SettingsView, id: SelectId, hovered: *const bool, _: *Window, cx: *Context(SettingsView)) void {
        ui.hover.set(cx, select_mod.hoverKey(id), hovered.*);
    }

    // ---- toggles -----------------------------------------------------------------------

    /// A switch bound to a settings bool: the animated visual inside its
    /// activation target, clickable when `interactive`.
    pub fn toggle(self: *SettingsView, which: Toggle, on: bool, interactive: bool, theme_: *const Theme, cx: *Context(SettingsView)) zpui.StatefulDiv {
        const pos = self.travel(cx, 0x10000 | @as(u32, @intFromEnum(which)), if (on) 1 else 0, 180);
        var d = div().id(.{ "settings-toggle", @intFromEnum(which) }).flexNone()
            .w(px(w.switch_width)).h(px(w.switch_height)).child(w.switchVisual(theme_, pos));
        if (interactive) d = d.cursorPointer().onClick(cx.listenerWith(which, SettingsView.onToggle));
        return d;
    }

    fn onToggle(self: *SettingsView, which: Toggle, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        self.closeSelect();
        select_mod.flip(self, which, cx);
        cx.notify();
    }

    // ---- shortcut recording ------------------------------------------------------------

    pub fn startRecording(self: *SettingsView, id: ShortcutId, window: *Window, cx: *Context(SettingsView)) void {
        self.closeSelect();
        self.recording = id;
        self.clearNotice();
        // Suspend the keymap so the chord being recorded never runs its action.
        cx.app.keymap.clear();
        window.focus(self.record_focus);
        cx.notify();
    }

    pub fn stopRecording(self: *SettingsView, cx: *Context(SettingsView)) void {
        if (self.recording == null) return;
        self.recording = null;
        store.applyKeymap(cx.app);
    }

    pub fn clearNotice(self: *SettingsView) void {
        self.notice.clearRetainingCapacity();
        self.notice_for = null;
    }

    fn recordKeystroke(self: *SettingsView, id: ShortcutId, ks: zpui.input.Keystroke, cx: *Context(SettingsView)) void {
        if (std.ascii.eqlIgnoreCase(ks.key, "escape")) {
            self.stopRecording(cx);
            cx.notify();
            return;
        }
        var buf: [96]u8 = undefined;
        const m = ks.modifiers;
        const combo = settings.comboFromKeystroke(&buf, m.control, m.alt, m.shift, m.platform, ks.key) orelse return;
        self.stopRecording(cx);
        if (shortcuts.refusal(self, id, combo, cx)) |_| {
            self.notice_for = id;
        } else {
            setShortcut(cx, id, combo);
        }
        cx.notify();
    }

    pub fn onRecord(self: *SettingsView, id_ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
        const id = ShortcutId.all[id_ix];
        if (self.recording != null and std.meta.eql(self.recording.?, id)) {
            self.stopRecording(cx);
            cx.notify();
            return;
        }
        self.startRecording(id, window, cx);
    }

    pub fn onResetShortcut(self: *SettingsView, id_ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        self.stopRecording(cx);
        self.clearNotice();
        resetShortcut(cx, ShortcutId.all[id_ix]);
        cx.notify();
    }

    pub fn onRestoreDefaults(self: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        self.stopRecording(cx);
        self.clearNotice();
        const Reset = struct {
            fn f(_: void, s: *UiSettings, _: std.mem.Allocator) void {
                s.keymap = .{};
                s.escapeStopsActiveAgent = false;
                s.composerSendBehavior = .enter;
            }
        };
        store.update(cx, .immediate, {}, Reset.f);
        store.applyKeymap(cx.app);
        cx.notify();
    }

    // ---- devices -----------------------------------------------------------------------

    pub fn deviceName(self: *const SettingsView, d: *const protocol.Device) []const u8 {
        return self.device_names.get(d.id) orelse d.name;
    }

    pub fn onCopyDeviceId(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        const list = self.state.read(cx).workspace.read(cx).devices();
        if (ix >= list.len) return;
        input.text_input.writeClipboard(cx.app, list[ix].id);
        if (self.copied) |c| self.gpa.free(c);
        self.copied = self.gpa.dupe(u8, list[ix].id) catch null;
        cx.notify();
    }

    pub fn onRenameDevice(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
        const list = self.state.read(cx).workspace.read(cx).devices();
        if (ix >= list.len) return;
        self.closeRename(cx.app);
        const t = theme(cx).forPopup();
        const field = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Device name",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 14,
            .line_height = 20,
            .colors = .{ .text = t.text, .placeholder = t.text_muted, .caret = t.caret, .selection = t.selection, .ghost = t.text_faint },
        }}) catch return;
        {
            var l = field.lease(cx);
            defer l.end();
            l.value.setText(self.deviceName(&list[ix]), &l.cx);
            l.value.selectAllText(&l.cx);
        }
        const sub = cx.subscribe(field, onRenameInput) catch {
            field.release(cx);
            return;
        };
        const id = self.gpa.dupe(u8, list[ix].id) catch {
            field.release(cx);
            return;
        };
        self.rename = .{ .device_id = id, .input = field, .sub = sub };
        window.focus(field.read(cx).focusHandle());
        cx.notify();
    }

    fn onRenameInput(self: *SettingsView, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(SettingsView)) void {
        switch (ev.*) {
            .submitted => self.submitRename(cx),
            .escape => {
                self.closeRename(cx.app);
                cx.notify();
            },
            else => {},
        }
    }

    pub fn onRenameCancel(self: *SettingsView, _: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
        self.closeRename(cx.app);
        window.focus(self.focus);
        cx.notify();
    }

    pub fn onRenameSave(self: *SettingsView, _: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
        self.submitRename(cx);
        window.focus(self.focus);
    }

    fn submitRename(self: *SettingsView, cx: *Context(SettingsView)) void {
        const dialog = self.rename orelse return;
        const name = std.mem.trim(u8, dialog.input.read(cx).text(), " \t");
        if (name.len > 0) {
            const ws = self.state.read(cx).workspace;
            ws.update(cx, model.WorkspaceStore.mutate, .{protocol.Mutate{ .renameDevice = .{ .deviceId = dialog.device_id, .name = name } }}) catch {};
            const name_copy = self.gpa.dupe(u8, name) catch null;
            if (name_copy) |nc| {
                if (self.device_names.fetchRemove(dialog.device_id)) |old| {
                    self.gpa.free(old.key);
                    self.gpa.free(old.value);
                }
                if (self.gpa.dupe(u8, dialog.device_id)) |key| {
                    self.device_names.put(self.gpa, key, nc) catch {
                        self.gpa.free(key);
                        self.gpa.free(nc);
                    };
                } else |_| self.gpa.free(nc);
            }
        }
        self.closeRename(cx.app);
        cx.notify();
    }

    fn closeRename(self: *SettingsView, app: *App) void {
        if (self.rename) |*r| {
            r.sub.deinit();
            r.input.release(app);
            self.gpa.free(r.device_id);
        }
        self.rename = null;
    }

    // ---- providers ---------------------------------------------------------------------

    pub fn harnessEnabled(self: *const SettingsView, d: *const protocol.HarnessDescriptor) bool {
        if (self.harness_overrides.get(d.id)) |v| return v;
        return d.enabled orelse d.installed;
    }

    pub fn onHarnessToggle(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        const list = providers.visibleHarnesses(self, cx);
        if (ix >= list.len) return;
        const d = &list[ix];
        const enabled = !self.harnessEnabled(d);
        self.harness_overrides.set(d.id, enabled);
        if (!enabled and self.expanded_harness == d.id) self.expanded_harness = null;
        const catalog = self.state.read(cx).catalog;
        const eng = catalog.read(cx).engine;
        model.EngineState.send(eng, cx, .SetHarnessEnabled, protocol.params.SetHarnessEnabled{ .harness = d.id, .enabled = enabled }) catch {};
        cx.notify();
    }

    pub fn onHarnessDetails(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        const list = providers.visibleHarnesses(self, cx);
        if (ix >= list.len) return;
        const id = list[ix].id;
        self.expanded_harness = if (self.expanded_harness == id) null else id;
        cx.notify();
    }

    pub fn onHarnessUpdate(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        cx.stopPropagation();
        const list = providers.visibleHarnesses(self, cx);
        if (ix >= list.len) return;
        self.update_override.set(list[ix].id, .preparing);
        cx.notify();
    }

    pub fn onCheckUpdates(self: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        const eng = self.state.read(cx).catalog.read(cx).engine;
        model.EngineState.send(eng, cx, .CheckHarnessUpdates, .{}) catch {};
        self.checking_updates = true;
        cx.notify();
    }

    pub fn harnessPolicy(self: *SettingsView, h: protocol.HarnessId, cx: anytype) model.types.HarnessUpdatePolicy {
        if (self.policy_override.get(h)) |p| return p;
        for (self.harnessUpdates(cx)) |st| if (st.harness == h) return st.policy;
        return .notify;
    }

    pub fn setHarnessPolicy(self: *SettingsView, h: protocol.HarnessId, policy: model.types.HarnessUpdatePolicy, cx: *Context(SettingsView)) void {
        self.policy_override.set(h, policy);
        const eng = self.state.read(cx).catalog.read(cx).engine;
        const P = struct { harness: protocol.HarnessId, policy: model.types.HarnessUpdatePolicy };
        model.EngineState.send(eng, cx, .SetHarnessUpdatePolicy, P{ .harness = h, .policy = policy }) catch {};
        cx.notify();
    }

    pub fn onPolicyTrigger(self: *SettingsView, ix: usize, ev: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        const list = providers.visibleHarnesses(self, cx);
        if (ix >= list.len) return;
        if (self.open_select == .update_policy and self.policy_harness != list[ix].id) self.closeSelect();
        self.policy_harness = list[ix].id;
        self.onSelectTrigger(.update_policy, ev, window, cx);
    }

    pub const CompletionKey = struct { ix: u16, dollar: bool };

    pub fn onCompletionToggle(self: *SettingsView, key: CompletionKey, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        const list = providers.visibleHarnesses(self, cx);
        if (key.ix >= list.len) return;
        const C = struct { h: protocol.HarnessId, dollar: bool };
        const Set = struct {
            fn f(c: C, s: *UiSettings, a: std.mem.Allocator) void {
                var prefs = s.skillCompletion(c.h);
                if (c.dollar) prefs.dollar = !prefs.dollar else prefs.separateFromSlash = !prefs.separateFromSlash;
                var map = s.skillCompletionByHarness.map.clone(a) catch return;
                map.put(a, @tagName(c.h), prefs) catch return;
                s.skillCompletionByHarness.map = map;
            }
        };
        store.update(cx, .immediate, C{ .h = list[key.ix].id, .dollar = key.dollar }, Set.f);
        cx.notify();
    }

    pub fn harnessUpdates(self: *SettingsView, cx: anytype) []const model.types.HarnessUpdateStatus {
        const live = self.state.read(cx).catalog.read(cx).harnessUpdates();
        if (live.len > 0) return live;
        if (self.fixture_updates) |p| return p.value;
        return &.{};
    }

    // ---- archived ----------------------------------------------------------------------

    pub fn isUnarchived(self: *const SettingsView, id: []const u8) bool {
        for (self.unarchived.items) |u| if (std.mem.eql(u8, u, id)) return true;
        return false;
    }

    pub fn onUnarchive(self: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        var sc = scratch(self.gpa);
        sc.begin();
        defer sc.end();
        const rows = archived.rows(self, cx, zpui.window.arena_mod.frameAllocator()) catch return;
        if (ix >= rows.len) return;
        const id = rows[ix].id;
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.mutate, .{protocol.Mutate{ .setChatArchived = .{ .chatId = id, .archived = false } }}) catch {};
        const copy = self.gpa.dupe(u8, id) catch return;
        self.unarchived.append(self.gpa, copy) catch self.gpa.free(copy);
        cx.notify();
    }

    // ---- appearance slider -------------------------------------------------------------

    pub fn onWidthHover(self: *SettingsView, hovered: *const bool, _: *Window, cx: *Context(SettingsView)) void {
        self.width_hovered = hovered.*;
        cx.notify();
    }

    pub fn onWidthDown(self: *SettingsView, ev: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
        self.width_pressed = true;
        cx.stopPropagation();
        self.dragWidth(ev.position.x, cx);
    }

    pub fn onWidthMove(self: *SettingsView, ev: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(SettingsView)) void {
        if (!self.width_pressed) return;
        if (ev.pressed_button != .left) {
            self.width_pressed = false;
            cx.notify();
            return;
        }
        self.dragWidth(ev.position.x, cx);
    }

    pub fn onWidthUp(self: *SettingsView, _: *const zpui.input.MouseUpEvent, _: *Window, cx: *Context(SettingsView)) void {
        if (self.width_pressed) {
            self.width_pressed = false;
            cx.notify();
        }
    }

    fn dragWidth(self: *SettingsView, x: f32, cx: *Context(SettingsView)) void {
        const b = self.width_bounds;
        if (b.size.width <= 14) return;
        const frac = std.math.clamp((x - b.origin.x - 7) / (b.size.width - 14), 0, 1);
        const lay = zt.layout;
        const width = settings.normalizeTranscriptWidth(lay.transcript_width_min + frac * (lay.transcript_width_max - lay.transcript_width_min));
        setTranscriptWidth(cx, width);
    }

    pub fn onWidthReset(_: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
        setTranscriptWidth(cx, zt.layout.transcript_width_default);
    }

    // ---- render ------------------------------------------------------------------------

    pub fn render(self: *SettingsView, window: *Window, cx: *Context(SettingsView)) zpui.StatefulDiv {
        self.animating = false;
        const t_val = theme(cx);
        const t = &t_val;
        const sidebar_width = prefs_mod.get(cx).sidebar_width;

        const page = self.renderPage(t, window, cx);
        var root = div().id("settings-page")
            .trackFocus(self.focus)
            .keyContext("Settings")
            .captureKeyDown(cx.listener(SettingsView.onKeyCapture))
            .onKeyDown(cx.listener(SettingsView.onKey))
            .onMouseUp(.left, cx.listener(SettingsView.onWidthUp))
            .onMouseMove(cx.listener(SettingsView.onWidthMove))
            .sizeFull().flex().flexRow()
            .fontFamily(t.font_sans)
            .child(div().w(px(sidebar_width)).hFull().flexNone().flex().flexCol()
            .pt(px(zt.layout.titlebar_height))
            .child(div().flexNone().px(px(zt.layout.space_sm)).child(self.backTab(t, cx)))
            .child(div().flex1().minH0().child(self.renderNav(t, cx)))
            .child(div().p(px(zt.layout.space_sm)).flexNone().child(self.footer(cx))))
            .child(div().flex1().minW0().hFull().flex().flexCol()
            .child(div().flex1().minH0().relative().child(page)))
            .child(div().id("settings-record-focus").trackFocus(self.record_focus).absolute().size(px(0)));
        if (self.rename != null) root = root.child(devices.renameDialog(self, window, cx));
        if (self.animating) window.requestAnimationFrame();
        return root;
    }

    fn sectionTab(self: *SettingsView, t: *const Theme, selected: bool, sel_t: f32, hover_key: []const u8, cx: *Context(SettingsView)) zpui.Div {
        _ = self;
        const base_bg = w.mix(t.wash(0), ui.theme.glassSelectedBg(t), sel_t);
        const base_text = w.mix(t.text_muted, t.text, sel_t);
        const hover_bg = if (selected) base_bg else t.glassHover();
        var d = div().flex().flexRow().itemsCenter().gap(px(8)).rounded(px(8))
            .px(px(zt.layout.space_sm)).py(px(6)).minH(px(32)).flexShrink0()
            .textSize(rems(13))
            .textColor(ui.hover.blend(cx, hover_key, base_text, t.text))
            .bg(ui.hover.blend(cx, hover_key, base_bg, hover_bg));
        if (selected) d = d.fontWeight(500);
        return d;
    }

    fn backTab(self: *SettingsView, t: *const Theme, cx: *Context(SettingsView)) zpui.StatefulDiv {
        const key = "settings-back-hover";
        return self.sectionTab(t, false, 0, key, cx).id("settings-back").cursorPointer()
            .onHover(cx.listener(SettingsView.onBackHover))
            .onClick(cx.listener(SettingsView.onBack))
            .child(ui.icon.of(.arrow_left, 16, ui.hover.blend(cx, key, t.text_muted, t.text)))
            .child("Back");
    }

    fn renderNav(self: *SettingsView, t: *const Theme, cx: *Context(SettingsView)) zpui.AnyElement {
        var list = div().flexNone().px(px(zt.layout.space_sm)).pt(px(zt.layout.space_md)).pb(px(zt.layout.space_sm))
            .flex().flexCol().gap(px(2));
        for (navItems()) |item| {
            const selected = item == self.section;
            const sel_t = self.travel(cx, 0x20000 | @as(u32, @intFromEnum(item)), if (selected) 1 else 0, 150);
            const key = navHoverKey(item);
            const text = ui.hover.blend(cx, key, w.mix(t.text_muted, t.text, sel_t), t.text);
            var tab = self.sectionTab(t, selected, sel_t, key, cx).id(.{ "settings-nav", @intFromEnum(item) })
                .cursorPointer()
                .onHover(cx.listenerWith(item, SettingsView.onNavHover))
                .onClick(cx.listenerWith(item, SettingsView.onNav))
                .child(ui.icon.of(sectionIcon(item), 16, text))
                .child(sectionLabel(item));
            if (startsNavGroup(item)) tab = tab.mt(px(zt.layout.space_lg));
            list = list.child(tab);
        }
        const scroller = div().id("settings-sections").wFull().hFull().overflowYScroll().trackScroll(self.nav_scroll)
            .flex().flexCol().child(list);
        return zpui.intoAnyElement(ui.effects.edgeFaded(scroller, .{ .band = 16, .top = true, .bottom = true, .scroll = self.nav_scroll }));
    }

    /// The chat sidebar's footer (account pill + settings button), held in
    /// place across the swap; the gear shows pressed while settings is open.
    fn footer(self: *SettingsView, cx: *Context(SettingsView)) zpui.Div {
        const t = ui.theme.get(cx).forPopup();
        const app_state = self.state.read(cx);
        const scope = app_state.engine.read(cx).workspaceScope() orelse app_state.workspace.read(cx).workspace_scope;
        var user_line: []const u8 = "Local";
        if (scope) |sc| switch (sc) {
            .local => {},
            .development => user_line = "Development",
            .synced => if (app_state.auth.read(cx).user()) |u| {
                const name = std.mem.trim(u8, u.name orelse "", " ");
                user_line = if (name.len > 0) name else u.email;
            },
        };
        const trimmed = std.mem.trim(u8, user_line, " ");
        const initial: []const u8 = if (trimmed.len > 0) zpui.fmt("{c}", .{std.ascii.toUpper(trimmed[0])}) else "?";
        const pill = div().h(px(28)).minW0().flexShrink1().rounded(px(8)).px(px(zt.layout.space_sm))
            .flex().flexRow().itemsCenter().gap(px(zt.layout.space_sm))
            .textSize(rems(13)).fontWeight(500).textColor(t.text.opacity(0.8))
            .child(div().size(px(16)).flexNone().roundedFull().bg(t.text).flex().itemsCenter().justifyCenter()
            .fontFamily(t.font_mono).textSize(px(10)).lineHeight(px(16)).fontWeight(600).textColor(t.bg)
            .child(div().wFull().textCenter().child(initial)))
            .child(div().minW0().lineHeight(px(17)).child(user_line));
        return div().wFull().flex().itemsCenter().justifyBetween().gap(px(4))
            .child(pill)
            .child(div().id("settings-footer-gear").size(px(28)).flexNone().rounded(px(8))
            .flex().itemsCenter().justifyCenter().cursorPointer()
            .bg(t.glassHover())
            .onClick(cx.listener(SettingsView.onBack))
            .child(ui.icon.of(.settings, 15, t.text_muted)));
    }

    fn renderPage(self: *SettingsView, t: *const Theme, window: *Window, cx: *Context(SettingsView)) zpui.AnyElement {
        const column = switch (self.section) {
            .general => general.render(self, t, window, cx),
            .appearance => appearance.render(self, t, window, cx),
            .notifications => notifications.render(self, t, window, cx),
            .voice => voice.render(self, t, window, cx),
            .shortcuts => shortcuts.render(self, t, window, cx),
            .harnesses, .agents => providers.render(self, t, window, cx),
            .devices => devices.render(self, t, window, cx),
            .files => files.render(self, t, window, cx),
            .appshots => appshots.render(self, t, window, cx),
            .archived => archived.render(self, t, window, cx),
        };
        const scroller = div().id(.{ "settings-page-scroll", @intFromEnum(self.section) }).sizeFull()
            .overflowYScroll().trackScroll(self.page_scroll).child(column);
        return zpui.intoAnyElement(div().relative().sizeFull()
            .child(ui.effects.edgeFaded(scroller, .{ .band = 16, .top = true, .bottom = true, .scroll = self.page_scroll }))
            .child(zpui.scrollbar(self.page_scroll).id("settings-page-scrollbar").mode(.hover)
            .withStyle(.{ .thumb = t.text.opacity(0.30), .thumb_hover = t.text.opacity(0.42), .thumb_active = t.text.opacity(0.55) })));
    }
};

// ---- settings writes --------------------------------------------------------------------

pub fn setShortcut(cx: *Context(SettingsView), id: ShortcutId, combo: []const u8) void {
    const C = struct { id: ShortcutId, combo: []const u8 };
    const Set = struct {
        fn f(c: C, s: *UiSettings, a: std.mem.Allocator) void {
            const owned = a.dupe(u8, c.combo) catch return;
            s.keymap.set(c.id, owned);
        }
    };
    store.update(cx, .immediate, C{ .id = id, .combo = combo }, Set.f);
    store.applyKeymap(cx.app);
}

pub fn resetShortcut(cx: *Context(SettingsView), id: ShortcutId) void {
    const Set = struct {
        fn f(i: ShortcutId, s: *UiSettings, _: std.mem.Allocator) void {
            s.keymap.reset(i);
        }
    };
    store.update(cx, .immediate, id, Set.f);
    store.applyKeymap(cx.app);
}

pub fn setTranscriptWidth(cx: *Context(SettingsView), width: f32) void {
    const Set = struct {
        fn f(v: f32, s: *UiSettings, _: std.mem.Allocator) void {
            s.transcriptWidth = v;
        }
    };
    store.update(cx, .debounced, width, Set.f);
    prefs_mod.mut(cx).transcript_width = width;
}
