//! The composer's model chip and its harness / model popover — the
//! `PickerKind::HarnessModel` slice of zeron `crates/ui/src/pickers.rs`:
//!
//! - chip (`trigger_chip`): 32px ghost pill, harness brand mark (16px) +
//!   model label (12px medium, text @ 0.9) + reasoning effort as the muted
//!   second tone (text_muted @ 0.7, brightening to text @ 0.85 when it
//!   departs from the model default), hover / open wash `element_hover`;
//! - popover: the compact picker (`pickers/compact.rs`, what the app shows
//!   by default) — a 256px frosted card anchored above the chip's trailing
//!   edge with two pages: the panel (effort title over the model name,
//!   fast-mode bolt, the glass effort slider with stops, model option rows
//!   such as Context Window) and the model list — every offered provider's
//!   models (a chat's fixed provider: its own), starred first; above it the
//!   back button beside the provider tab strip (each tab jumps to its group,
//!   the group at the top of the scroll lights its tab), then the search
//!   `TextInput` in the `PaletteSearch` context; 32px rows with the harness
//!   mark, star on hover, selection = light glass plate. Keys as in Rust:
//!   ↑/↓ open the list beside the selection, ←/→/Home/End step the effort,
//!   Enter opens / picks, Esc backs out.
//!
//! Data comes from `AppState.catalog` (`CatalogStore`: `ListHarnesses`, per
//! harness `ListModels` on demand), the selected chat's `ChatConfig` and the
//! sticky `ComposerDefaults`. Picks stay a draft on this entity (Rust's
//! `config`) and resolve through `run_config.zig`.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const input_mod = @import("zeron_input");
const chrome = @import("chrome.zig");
const rc = @import("run_config.zig");
const composer_store = model.composer_store;
const metrics = @import("metrics.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const protocol = engine.protocol;
const Theme = zt.Theme;
const TextInput = input_mod.TextInput;
const HarnessId = protocol.HarnessId;
const rems = chrome.rems;

/// The user committed a pick (model / harness / reasoning changed).
pub const Picked = struct {};
/// The popover closed (the composer takes focus back).
pub const Closed = struct {};

pub const ModelPicker = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    theme: Theme,
    open: bool = false,
    /// Committed picks (Rust `Pickers::config`); model id owned.
    draft: rc.Draft = .{},
    draft_model_buf: std.ArrayList(u8) = .empty,
    /// Keyboard / hover cursor row.
    active: usize = 0,
    /// Compact picker page (`CompactPage`): the effort panel or the model list.
    page: Page = .panel,
    /// The model list's scroll (the provider tabs read its top row) and the
    /// tab strip's sideways scroll + the tab last brought into view.
    list_scroll: zpui.ScrollHandle,
    strip_scroll: zpui.ScrollHandle,
    strip_viewed: ?usize = null,
    /// Explicit model option picks (`modelOptions`), keys/values owned.
    options: protocol.JsonMap = .{},
    search: Entity(TextInput),
    focus: zpui.FocusHandle,
    defaults: ?*const rc.ComposerDefaults = null,
    allow_mock: bool = false,
    subs: zpui.Subscriptions = .{},

    pub const Events = .{ Picked, Closed };

    pub const Page = enum { panel, models };

    pub fn init(state: Entity(model.AppState), cx: *Context(ModelPicker)) !ModelPicker {
        const theme = chrome.defaultTheme(.dark);
        const popup = theme.forPopup();
        const search = try cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
            .placeholder = "Search models…",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 13,
            .line_height = 18,
            .colors = input_mod.Colors.fromTheme(&popup),
        }});
        var self: ModelPicker = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .theme = theme,
            .search = search,
            .focus = cx.focusHandle(),
            .list_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .strip_scroll = zpui.ScrollHandle.init(cx.gpa()),
        };
        const catalog = state.read(cx).catalog;
        try self.subs.add(cx.gpa(), try cx.observe(catalog, ModelPicker.onCatalog));
        try self.subs.add(cx.gpa(), try cx.subscribe(search, ModelPicker.onSearch));
        // Sticky picks / Settings → General defaults changed: re-resolve the chip.
        try self.subs.add(cx.gpa(), try cx.observeGlobal(composer_store.ComposerStore, ModelPicker.onDefaultsChanged));
        return self;
    }

    fn onDefaultsChanged(_: *ModelPicker, cx: *Context(ModelPicker)) void {
        cx.notify();
    }

    fn appOf(cx: anytype) *App {
        return if (@TypeOf(cx) == *App) cx else cx.app;
    }

    /// The sticky last-used picks: the host's override, else the
    /// `ComposerStore` global (`composer-defaults.json`).
    fn stickyDefaults(self: *const ModelPicker, cx: anytype) ?*const rc.ComposerDefaults {
        return self.defaults orelse composer_store.sticky(appOf(cx));
    }

    /// On the new-thread canvas (Rust: no selected chat), picks also land in
    /// the sticky memory (`Pickers::save_defaults`).
    fn onCanvas(self: *const ModelPicker, cx: anytype) bool {
        return self.state.read(cx).workspace.read(cx).selected_chat == null;
    }

    /// `pick_reasoning`'s sticky half: the level for the resolved model.
    fn rememberReasoning(self: *const ModelPicker, level: protocol.ReasoningLevel, cx: *Context(ModelPicker)) void {
        if (!self.onCanvas(cx)) return;
        const in = self.inputs(cx);
        composer_store.rememberReasoning(cx.app, rc.effectiveHarness(&in), rc.effectiveModelId(&in), level);
    }

    pub fn deinit(self: *ModelPicker, cx: *App) void {
        self.subs.deinit(self.gpa);
        self.list_scroll.release();
        self.strip_scroll.release();
        self.search.release(cx);
        self.focus.release(cx);
        self.state.release(cx);
        self.draft_model_buf.deinit(self.gpa);
        self.clearOptions();
        self.options.map.deinit(self.gpa);
    }

    fn onCatalog(_: *ModelPicker, catalog: Entity(model.CatalogStore), cx: *Context(ModelPicker)) void {
        // `remember_labels`: every loaded catalog feeds the label cache.
        if (cx.app.hasGlobal(composer_store.ComposerStore)) {
            const c = catalog.read(cx);
            for (std.enums.values(HarnessId)) |h| if (c.modelList(h)) |list| composer_store.rememberLabels(cx.app, list);
        }
        cx.notify();
    }

    fn onSearch(self: *ModelPicker, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Context(ModelPicker)) void {
        switch (ev.*) {
            .edited => {
                self.active = 0;
                cx.notify();
            },
            else => {},
        }
    }

    pub fn setTheme(self: *ModelPicker, theme: Theme, cx: *Context(ModelPicker)) void {
        self.theme = theme;
        const popup = theme.forPopup();
        self.search.update(cx, TextInput.setColors, .{input_mod.Colors.fromTheme(&popup)});
        cx.notify();
    }

    pub fn setDefaults(self: *ModelPicker, defaults: ?*const rc.ComposerDefaults, cx: *Context(ModelPicker)) void {
        self.defaults = defaults;
        cx.notify();
    }

    /// Drop draft picks (navigation to another chat).
    fn clearOptions(self: *ModelPicker) void {
        var it = self.options.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.string);
        }
        self.options.map.clearRetainingCapacity();
    }

    pub fn resetDraft(self: *ModelPicker, cx: *Context(ModelPicker)) void {
        self.clearOptions();
        self.draft = .{};
        self.draft_model_buf.clearRetainingCapacity();
        cx.notify();
    }

    // ---- resolution --------------------------------------------------------------------

    fn modelsFor(ctx: *const anyopaque, h: HarnessId) ?[]const protocol.Model {
        const c: *const model.CatalogStore = @ptrCast(@alignCast(ctx));
        return c.modelList(h);
    }

    /// The resolution inputs as of now (borrowed from the stores).
    pub fn inputs(self: *const ModelPicker, cx: anytype) rc.Inputs {
        const st = self.state.read(cx);
        const catalog = st.catalog.read(cx);
        const ws = st.workspace.read(cx);
        const chat = ws.selectedChatRow();
        const harnesses = catalog.harnessList();
        return .{
            .draft = self.draft,
            .chat_config = if (chat) |c| (if (c.config) |*cfg| cfg else null) else null,
            .existing_chat = chat != null,
            .defaults = self.stickyDefaults(cx),
            .preferred = composer_store.preferred(appOf(cx)),
            .harnesses = if (catalog.harnesses != null) harnesses else null,
            .models_for = modelsFor,
            .models_ctx = catalog,
            .allow_mock = self.allow_mock,
        };
    }

    pub fn resolved(self: *const ModelPicker, cx: anytype) rc.Resolved {
        const in = self.inputs(cx);
        var r = rc.resolved(&in);
        if (self.options.map.count() > 0) r.model_options = self.options;
        return r;
    }

    /// The current choice of model option `opt` (explicit pick, chat config,
    /// else the option default).
    fn optionChoice(self: *const ModelPicker, opt: *const protocol.ModelOption) []const u8 {
        if (self.options.map.get(opt.id)) |v| if (v == .string) return v.string;
        return opt.defaultChoice;
    }

    fn setOption(self: *ModelPicker, id: []const u8, choice: []const u8) void {
        if (self.options.map.fetchSwapRemove(id)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.string);
        }
        const k = self.gpa.dupe(u8, id) catch @panic("OOM");
        const v = self.gpa.dupe(u8, choice) catch @panic("OOM");
        self.options.map.put(self.gpa, k, .{ .string = v }) catch @panic("OOM");
    }

    /// Load the models of every provider the list can show (the effective
    /// harness first) on demand.
    fn ensureLoaded(self: *ModelPicker, cx: *Context(ModelPicker)) void {
        const catalog = self.state.read(cx).catalog;
        var hbuf: [16]protocol.HarnessDescriptor = undefined;
        const in = self.inputs(cx);
        var want: [17]HarnessId = undefined;
        var n: usize = 0;
        if (rc.effectiveHarness(&in)) |h| {
            want[0] = h;
            n = 1;
        }
        for (self.railDescriptors(cx, &hbuf)) |d| {
            if (std.mem.indexOfScalar(HarnessId, want[0..n], d.id) == null and n < want.len) {
                want[n] = d.id;
                n += 1;
            }
        }
        for (want[0..n]) |h| {
            if (catalog.read(cx).modelList(h) == null and !catalog.read(cx).models_loading.contains(h)) {
                catalog.update(cx, model.CatalogStore.loadModels, .{ h, false });
            }
        }
    }

    /// `harness_locked`: a chat's provider is fixed.
    fn harnessLocked(self: *const ModelPicker, cx: anytype) bool {
        return !self.onCanvas(cx);
    }

    /// `rail_descriptors`: the providers on offer (plus the effective one when
    /// installed but not offered); a chat's fixed provider alone.
    fn railDescriptors(self: *const ModelPicker, cx: anytype, out: []protocol.HarnessDescriptor) []protocol.HarnessDescriptor {
        const catalog = self.state.read(cx).catalog.read(cx);
        const list = catalog.harnessList();
        var offered = rc.offeredHarnesses(list, self.allow_mock, out[0 .. out.len - 1]);
        const in = self.inputs(cx);
        const effective = rc.effectiveHarness(&in);
        if (effective) |e| {
            const present = for (offered) |d| {
                if (d.id == e) break true;
            } else false;
            if (!present) for (list) |d| if (d.id == e and d.installed) {
                std.mem.copyBackwards(protocol.HarnessDescriptor, out[1 .. offered.len + 1], offered);
                out[0] = d;
                offered = out[0 .. offered.len + 1];
                break;
            };
        }
        if (self.harnessLocked(cx)) {
            for (offered) |d| if (effective != null and d.id == effective.?) {
                out[0] = d;
                return out[0..1];
            };
            return out[0..0];
        }
        return offered;
    }

    // ---- open / close / pick -----------------------------------------------------------

    pub fn isOpen(self: *const ModelPicker) bool {
        return self.open;
    }

    pub fn toggle(self: *ModelPicker, window: *Window, cx: *Context(ModelPicker)) void {
        if (self.open) return self.close(window, cx);
        self.open = true;
        self.page = .panel;
        self.search.update(cx, TextInput.setText, .{""});
        self.active = self.selectedRowIndex(cx) orelse 0;
        window.focus(self.focus);
        self.ensureLoaded(cx);
        cx.notify();
    }

    pub fn close(self: *ModelPicker, _: *Window, cx: *Context(ModelPicker)) void {
        if (!self.open) return;
        self.open = false;
        cx.emit(Closed{});
        cx.notify();
    }

    fn onChipClick(self: *ModelPicker, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.toggle(window, cx);
    }

    fn commitModel(self: *ModelPicker, h: HarnessId, id: []const u8, window: *Window, cx: *Context(ModelPicker)) void {
        self.draft_model_buf.clearRetainingCapacity();
        self.draft_model_buf.appendSlice(self.gpa, id) catch @panic("OOM");
        self.draft.harness = h;
        self.draft.model = self.draft_model_buf.items;
        if (self.onCanvas(cx)) {
            self.draft.reasoning = null; // effort follows the model (`pick_model`)
            const catalog = self.state.read(cx).catalog.read(cx);
            var label: []const u8 = id;
            if (catalog.modelList(h)) |list| for (list) |row| if (std.mem.eql(u8, row.id, id)) {
                label = row.label;
            };
            composer_store.rememberModel(cx.app, h, id, label);
        }
        cx.emit(Picked{});
        self.close(window, cx);
    }

    fn onModelRow(self: *ModelPicker, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.activate(ix, window, cx);
    }

    fn activate(self: *ModelPicker, ix: usize, window: *Window, cx: *Context(ModelPicker)) void {
        var buf: [256]Row = undefined;
        const list = self.rows(cx, &buf);
        if (ix >= list.len) return;
        self.commitModel(list[ix].harness, list[ix].model.id, window, cx);
    }

    fn onHoverRow(self: *ModelPicker, ix: usize, hovered: *const bool, _: *Window, cx: *Context(ModelPicker)) void {
        if (hovered.* and self.active != ix) {
            self.active = ix;
            cx.notify();
        }
    }

    fn onReasoning(self: *ModelPicker, level: protocol.ReasoningLevel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ModelPicker)) void {
        self.draft.reasoning = level;
        self.rememberReasoning(level, cx);
        cx.emit(Picked{});
        cx.notify();
    }

    /// Assistive technology moved the reasoning slider (set value / increment / decrement).
    fn onA11yEffort(self: *ModelPicker, req: *const zpui.a11y.ActionRequest, _: *Window, cx: *Context(ModelPicker)) void {
        const in = self.inputs(cx);
        const ladder = rc.traitLadder(&in);
        if (ladder.len == 0) return;
        const effort = rc.effectiveReasoning(&in);
        var cur: usize = 0;
        for (ladder, 0..) |l, i| if (effort == l) {
            cur = i;
        };
        const next: usize = switch (req.action) {
            .increment => @min(cur + 1, ladder.len - 1),
            .decrement => cur -| 1,
            else => @intFromFloat(std.math.clamp(@round(req.numeric orelse return), 0, @as(f64, @floatFromInt(ladder.len - 1)))),
        };
        self.draft.reasoning = ladder[next];
        self.rememberReasoning(ladder[next], cx);
        cx.emit(Picked{});
        cx.notify();
    }

    /// The native (macOS 26+ Liquid Glass) effort slider moved: its value is the
    /// ladder index (tick marks only). Continuous drags report every movement, so
    /// only an actual level change is picked and remembered.
    fn onNativeEffort(self: *ModelPicker, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(ModelPicker)) void {
        const in = self.inputs(cx);
        const ladder = rc.traitLadder(&in);
        if (ladder.len == 0) return;
        const next: usize = @intFromFloat(std.math.clamp(@round(ev.value), 0, @as(f64, @floatFromInt(ladder.len - 1))));
        if (rc.effectiveReasoning(&in) == ladder[next]) return;
        self.draft.reasoning = ladder[next];
        self.rememberReasoning(ladder[next], cx);
        cx.emit(Picked{});
        cx.notify();
    }

    /// `show_compact_models`: open on the current model — its provider's
    /// group at the top when the model sits near the start of it (one row of
    /// the previous group stays above under the edge fade), else centred.
    fn showModels(self: *ModelPicker, window: *Window, cx: *Context(ModelPicker)) void {
        self.page = .models;
        self.strip_viewed = null;
        self.ensureLoaded(cx);
        const selected = self.selectedRowIndex(cx) orelse 0;
        self.active = selected;
        var gbuf: [24]Group = undefined;
        const gs = self.groups(cx, &gbuf);
        var start: usize = 0;
        for (gs) |g| if (g.start <= selected) {
            start = g.start;
        };
        if (selected - start < @as(usize, @intFromFloat(compact_list_rows)) - 2) {
            self.list_scroll.scrollToTopOfItem(start -| @intFromBool(start > 0));
        } else self.list_scroll.scrollToItem(selected);
        window.focus(self.search.read(cx).focus);
        cx.notify();
    }

    fn showPanel(self: *ModelPicker, window: *Window, cx: *Context(ModelPicker)) void {
        self.page = .panel;
        self.search.update(cx, TextInput.setText, .{""});
        window.focus(self.focus);
        cx.notify();
    }

    fn onShowModels(self: *ModelPicker, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.showModels(window, cx);
    }
    fn onBack(self: *ModelPicker, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.showPanel(window, cx);
    }
    fn onToggleFast(self: *ModelPicker, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ModelPicker)) void {
        const in = self.inputs(cx);
        const m = rc.selectedModel(&in) orelse return;
        for (m.options) |*o| if (std.mem.eql(u8, o.id, "fastMode")) {
            const on = std.mem.eql(u8, self.optionChoice(o), "on");
            self.setOption(o.id, if (on) "off" else "on");
            cx.emit(Picked{});
            return cx.notify();
        };
    }
    fn onCycleOption(self: *ModelPicker, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ModelPicker)) void {
        const in = self.inputs(cx);
        const m = rc.selectedModel(&in) orelse return;
        if (ix >= m.options.len) return;
        const o = &m.options[ix];
        if (o.choices.len == 0) return;
        const cur = self.optionChoice(o);
        var next: usize = 0;
        for (o.choices, 0..) |c, i| if (std.mem.eql(u8, c.id, cur)) {
            next = (i + 1) % o.choices.len;
        };
        self.setOption(o.id, o.choices[next].id);
        cx.emit(Picked{});
        cx.notify();
    }
    fn stepEffort(self: *ModelPicker, delta: isize, cx: *Context(ModelPicker)) void {
        const in = self.inputs(cx);
        const ladder = rc.traitLadder(&in);
        if (ladder.len == 0) return;
        const cur = rc.effectiveReasoning(&in);
        var ix: isize = 0;
        for (ladder, 0..) |l, i| if (cur == l) {
            ix = @intCast(i);
        };
        const next: usize = @intCast(std.math.clamp(ix + delta, 0, @as(isize, @intCast(ladder.len - 1))));
        self.draft.reasoning = ladder[next];
        self.rememberReasoning(ladder[next], cx);
        cx.emit(Picked{});
        cx.notify();
    }

    fn onFrameKey(self: *ModelPicker, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Context(ModelPicker)) void {
        const k = ev.keystroke.key;
        const eq = std.mem.eql;
        if (self.page == .panel) {
            if (eq(u8, k, "escape")) {
                self.close(window, cx);
            } else if (eq(u8, k, "up") or eq(u8, k, "down")) {
                // Open the list on the model beside the selected one.
                self.showModels(window, cx);
                var rb: [256]Row = undefined;
                const n = self.rows(cx, &rb).len;
                if (n > 0) self.active = if (eq(u8, k, "down")) (self.active + 1) % n else (self.active + n - 1) % n;
            } else if (eq(u8, k, "enter") or eq(u8, k, "space")) {
                self.showModels(window, cx);
            } else if (eq(u8, k, "left")) {
                self.stepEffort(-1, cx);
            } else if (eq(u8, k, "right")) {
                self.stepEffort(1, cx);
            } else if (eq(u8, k, "home")) {
                self.stepEffort(-100, cx);
            } else if (eq(u8, k, "end")) {
                self.stepEffort(100, cx);
            } else return;
            return cx.stopPropagation();
        }
        var buf: [256]Row = undefined;
        const n = self.rows(cx, &buf).len;
        if (eq(u8, k, "escape")) {
            self.showPanel(window, cx);
        } else if (eq(u8, k, "down")) {
            if (n > 0) self.active = (self.active + 1) % n;
            self.list_scroll.scrollToItem(self.active);
            cx.notify();
        } else if (eq(u8, k, "up")) {
            if (n > 0) self.active = (self.active + n - 1) % n;
            self.list_scroll.scrollToItem(self.active);
            cx.notify();
        } else if (eq(u8, k, "enter")) {
            self.activate(self.active, window, cx);
        } else return;
        cx.stopPropagation();
    }

    fn onOutside(self: *ModelPicker, _: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.close(window, cx);
    }

    // ---- rows --------------------------------------------------------------------------

    pub const Row = struct { harness: HarnessId, model: *const protocol.Model };

    /// `popover::match_rank`: 0 = prefix, 1 = substring (empty query: 1).
    fn matchRank(query: []const u8, label: []const u8) ?usize {
        const q = std.mem.trim(u8, query, " \t");
        if (q.len == 0) return 1;
        if (q.len <= label.len and std.ascii.eqlIgnoreCase(label[0..q.len], q)) return 0;
        if (std.ascii.findIgnoreCase(label, q) != null) return 1;
        return null;
    }

    fn isFavorite(self: *const ModelPicker, cx: anytype, h: HarnessId, id: []const u8) bool {
        const d = self.stickyDefaults(cx) orelse return false;
        return d.isFavorite(h, id);
    }

    /// `scoped_model_rows`: every rail provider's models, starred first (a
    /// chat's fixed provider: its own, starred first). A query ranks label
    /// prefix < label substring < description hit, stars then input order
    /// breaking ties (starred first across providers).
    pub fn rows(self: *const ModelPicker, cx: anytype, out: []Row) []Row {
        const catalog = self.state.read(cx).catalog.read(cx);
        const query = std.mem.trim(u8, self.search.read(cx).text(), " ");
        var hbuf: [16]protocol.HarnessDescriptor = undefined;
        const descs = self.railDescriptors(cx, &hbuf);
        const locked = self.harnessLocked(cx);
        var n: usize = 0;
        if (query.len > 0) {
            const Ranked = struct { rank: usize, unstarred: bool, ix: usize };
            var keys: [256]Ranked = undefined;
            var input_ix: usize = 0;
            for (descs) |d| {
                const list = catalog.modelList(d.id) orelse continue;
                for (list) |*m| {
                    defer input_ix += 1;
                    if (n >= out.len) break;
                    var buf: [512]u8 = undefined;
                    const hay = std.fmt.bufPrint(&buf, "{s} {s}", .{ m.description orelse "", m.label }) catch m.label;
                    const by_label = matchRank(query, m.label);
                    const by_desc: ?usize = if (matchRank(query, hay)) |r| r + 2 else null;
                    const rank = if (by_label) |l| (if (by_desc) |dd| @min(l, dd) else l) else by_desc orelse continue;
                    out[n] = .{ .harness = d.id, .model = m };
                    keys[n] = .{ .rank = rank, .unstarred = !self.isFavorite(cx, d.id, m.id), .ix = input_ix };
                    n += 1;
                }
            }
            // Insertion sort (lists are short) on the Rust sort key.
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const kr = keys[i];
                const rr = out[i];
                var j = i;
                while (j > 0 and rankedLess(kr, keys[j - 1], locked)) : (j -= 1) {
                    keys[j] = keys[j - 1];
                    out[j] = out[j - 1];
                }
                keys[j] = kr;
                out[j] = rr;
            }
            return out[0..n];
        }
        // Unsearched: starred first (stable), then the rest in provider order.
        for ([_]bool{ true, false }) |starred| {
            for (descs) |d| {
                const list = catalog.modelList(d.id) orelse continue;
                for (list) |*m| {
                    if (self.isFavorite(cx, d.id, m.id) != starred or n >= out.len) continue;
                    out[n] = .{ .harness = d.id, .model = m };
                    n += 1;
                }
            }
        }
        return out[0..n];
    }

    fn rankedLess(a: anytype, b: @TypeOf(a), locked: bool) bool {
        if (locked) {
            if (a.rank != b.rank) return a.rank < b.rank;
            if (a.unstarred != b.unstarred) return !a.unstarred;
        } else {
            if (a.unstarred != b.unstarred) return !a.unstarred;
            if (a.rank != b.rank) return a.rank < b.rank;
        }
        return a.ix < b.ix;
    }

    /// One provider tab: the starred run (null) or a provider's run.
    pub const Group = struct { harness: ?HarnessId, start: usize };

    /// `compact_groups`: where each provider's group starts in the
    /// unsearched list — starred models first, then one run per provider.
    pub fn groups(self: *const ModelPicker, cx: anytype, out: []Group) []Group {
        var buf: [256]Row = undefined;
        const list = self.rows(cx, &buf);
        var n: usize = 0;
        for (list, 0..) |r, ix| {
            const g: ?HarnessId = if (self.isFavorite(cx, r.harness, r.model.id)) null else r.harness;
            if (n == 0 or out[n - 1].harness != g) {
                if (n == out.len) break;
                out[n] = .{ .harness = g, .start = ix };
                n += 1;
            }
        }
        return out[0..n];
    }

    fn selectedRowIndex(self: *const ModelPicker, cx: anytype) ?usize {
        var buf: [256]Row = undefined;
        const list = self.rows(cx, &buf);
        const in = self.inputs(cx);
        const sel = rc.selectedModel(&in) orelse return null;
        for (list, 0..) |r, i| if (r.model == sel) return i;
        return null;
    }

    // ---- render ------------------------------------------------------------------------

    pub fn render(self: *ModelPicker, window: *Window, cx: *Context(ModelPicker)) zpui.Div {
        _ = window;
        const theme = &self.theme;
        const in = self.inputs(cx);
        const catalog = self.state.read(cx).catalog.read(cx);
        const harness = rc.effectiveHarness(&in);
        const label: ?[]const u8 = rc.modelLabel(&in);
        const effort = rc.effectiveReasoning(&in);
        const ladder = rc.traitLadder(&in);
        const customized = effort != null and effort != rc.defaultReasoning(ladder);
        const loading = catalog.harnesses == null;

        var chip = div().id("picker-model").role(.button).ariaLabel(zpui.fmt("Model: {s}", .{label orelse if (loading) "Loading" else "No agents available"})).ariaExpanded(self.open).relative()
            .h(px(metrics.model_chip_height)).maxW(px(metrics.model_chip_max_width)).minW0()
            .flex().flexRow().itemsCenter().gap(px(6)).px(px(6)).rounded(px(8))
            .textSize(rems(12)).fontWeight(500)
            .textColor(theme.text.opacity(0.9))
            .cursorPointer()
            .hover(sb.bg(theme.element_hover).textColor(theme.text))
            .onClick(cx.listener(ModelPicker.onChipClick));
        if (self.open) chip = chip.bg(theme.element_hover);
        if (harness) |h| {
            const mark, const tint = chrome.harnessMark(h);
            chip = chip.child(chrome.icon(mark, 16, tint orelse theme.text_muted));
        } else if (!loading) {
            chip = chip.child(chrome.icon(.terminal, 16, theme.text_muted));
        } else {
            chip = chip.child(chrome.icon(.claude_mark, 16, zt.theme.claude_brand));
        }
        if (label) |l| {
            chip = chip.child(div().minW0().truncate().child(l));
        } else if (loading or harness != null) {
            // Ghost label while the model resolves.
            chip = chip.child(div().w(px(56)).h(px(10)).roundedFull().bg(theme.ink(0.08)));
        } else {
            chip = chip.child(div().minW0().truncate().child("No agents available"));
        }
        if (effort) |e| {
            const color = if (customized) theme.text.opacity(0.85) else theme.text_muted.opacity(0.7);
            chip = chip.child(div().flexShrink(1000).minW0().textColor(color).truncate().child(rc.reasoningLabel(e)));
        }

        var root = div().relative().flex().flexRow().itemsCenter().minW0().gap(px(4)).child(chip);
        if (self.open) {
            root = root.child(div().absolute().bottomFull().right0().child(
                zpui.deferred(div().occlude().pb(px(6)).child(self.renderPopover(cx))).withPriority(1),
            ));
        }
        return root;
    }

    // ---- compact picker (pickers/compact.rs) --------------------------------------

    const compact_width: f32 = 256;
    const compact_row_height: f32 = 32;
    const compact_list_rows: f32 = 7;
    const slider_height: f32 = 36;
    const rail_height: f32 = 28;
    const thumb_width: f32 = 44;
    const thumb_height: f32 = 32;
    const header_height: f32 = 48;
    const header_height_single: f32 = 36;
    const fast_button_width: f32 = 32;
    /// `LIST_HEADER`: the back button with the provider tab strip (one row
    /// plus the card inset above and below, 40), then the search row (40).
    const list_header: f32 = 80;
    /// Card 256 − 2 border − 2 × 4 inset − 2 × 8 slider padding.
    const slider_width: f32 = compact_width - 2 - 2 * chrome.card_inset - 16;

    fn compactListHeight(n: usize) f32 {
        const r: f32 = if (n == 0) 4 else @min(@as(f32, @floatFromInt(n)), compact_list_rows);
        return r * (compact_row_height + chrome.menu_gap) + 2 * chrome.card_inset;
    }

    fn renderPopover(self: *ModelPicker, cx: *Context(ModelPicker)) chrome.Frosted {
        const base = self.theme;
        const theme = base.forPopup();
        const content = switch (self.page) {
            .panel => zpui.intoAnyElement(self.renderPanel(&theme, cx)),
            .models => zpui.intoAnyElement(self.renderModels(&theme, cx)),
        };
        const card = chrome.card(&theme).p(px(0)).w(px(compact_width)).flex().flexCol()
            .id("model-popover")
            .keyContext("ModelPicker")
            .trackFocus(self.focus)
            .onKeyDown(cx.listener(ModelPicker.onFrameKey))
            .onMouseDownOut(cx.listener(ModelPicker.onOutside))
            .child(content);
        return chrome.frosted(&base, chrome.card_radius, chrome.menu_blur, card);
    }

    /// `compact_model_back_header`: back to the panel, then the providers
    /// as tabs. Each tab jumps the list to its group; the group at the top of
    /// the scroll lights its tab. The strip fades at both edges over the tabs
    /// scrolled past them.
    fn backHeader(self: *ModelPicker, theme: *const Theme, cx: *Context(ModelPicker)) zpui.Div {
        const searching = std.mem.trim(u8, self.search.read(cx).text(), " ").len > 0;
        var gbuf: [24]Group = undefined;
        const gs: []Group = if (searching) gbuf[0..0] else self.groups(cx, &gbuf);
        // Rows share one pitch, so the scroll offset names the top row.
        const top: usize = @intFromFloat(@max(@round(-self.list_scroll.offset().y / (compact_row_height + chrome.menu_gap)), 0));
        var current: ?usize = null;
        for (gs, 0..) |g, i| if (g.start <= top) {
            current = i;
        };
        if (current != self.strip_viewed) {
            self.strip_viewed = current;
            if (current) |i| self.strip_scroll.scrollToItem(i);
        }
        var header = div().h(px(compact_row_height + 2 * chrome.card_inset)).flexNone().px(px(chrome.card_inset))
            .flex().itemsCenter().gap(px(chrome.menu_gap))
            .child(div().id("compact-model-back").role(.button).ariaLabel("Back").flexNone().size(px(compact_row_height))
                .rounded(px(chrome.menu_item_radius)).flex().itemsCenter().justifyCenter().cursorPointer()
                .hover(sb.bg(theme.ink(0.05)))
                .onClick(cx.listener(ModelPicker.onBack))
                .child(chrome.icon(.alt_arrow_left, 14, theme.text_muted)));
        if (gs.len > 0) {
            var tabs = div().id("compact-group-strip").flex1().minW0().hFull().flex().itemsCenter().gap(px(chrome.menu_gap))
                .overflowXScroll().trackScroll(self.strip_scroll);
            for (gs, 0..) |g, i| {
                const viewed = current == i;
                const mark: chrome.Icon, const tint: ?zpui.Hsla, const name: []const u8 = if (g.harness) |h| blk: {
                    const m, const t = chrome.harnessMark(h);
                    break :blk .{ m, t, chrome.harnessName(h) };
                } else .{ .star_bold, null, "Starred" };
                var tab = div().id(.{ "compact-group", g.start }).role(.button).ariaLabel(zpui.fmt("Jump to {s}", .{name}))
                    .tooltipWith(chrome.TipData{ .text = name, .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                    .flexNone().size(px(compact_row_height)).rounded(px(chrome.menu_item_radius))
                    .flex().itemsCenter().justifyCenter().cursorPointer()
                    .onClick(cx.listenerWith(g.start, ModelPicker.onGroupTab))
                    .child(chrome.icon(mark, 14, tint orelse if (viewed) theme.text else theme.text_muted));
                tab = if (viewed) tab.bg(theme.ink(0.08)) else tab.opacity(0.7).hover(sb.bg(theme.ink(0.05)).opacity(1.0));
                tabs = tabs.child(tab);
            }
            header = header.child(tabs);
        }
        return header;
    }

    fn onGroupTab(self: *ModelPicker, start: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ModelPicker)) void {
        self.active = start;
        self.list_scroll.scrollToTopOfItem(start);
        cx.notify();
    }

    /// The search row under the tab strip (full-bleed hairline below).
    fn searchRow(self: *ModelPicker, theme: *const Theme) zpui.Div {
        return div().h(px(40)).flexNone().px(px(chrome.card_inset + 8)).borderB1().borderColor(theme.hairline(0.08))
            .flex().itemsCenter().child(div().flex1().minW0().textSize(rems(13)).child(self.search));
    }

    fn renderModels(self: *ModelPicker, theme: *const Theme, cx: *Context(ModelPicker)) zpui.Div {
        var rows_buf: [256]Row = undefined;
        const list = self.rows(cx, &rows_buf);
        const in = self.inputs(cx);
        const selected = rc.selectedModel(&in);
        const catalog = self.state.read(cx).catalog.read(cx);
        var col = div().id("model-menu-scroll").flex().flexCol().gap(px(chrome.menu_gap)).p(px(chrome.card_inset))
            .h(px(compactListHeight(list.len))).overflowYScroll().trackScroll(self.list_scroll);
        if (list.len == 0) {
            const viewed = rc.effectiveHarness(&in);
            const note = if (catalog.harnesses == null or (viewed != null and catalog.modelList(viewed.?) == null))
                "Loading models…"
            else
                "No models found";
            col = col.child(div().px(px(8)).py(px(10)).textSize(rems(12)).textColor(theme.text_muted).child(note));
        }
        for (list, 0..) |r, ix| {
            const is_selected = selected == r.model;
            const hovered = ix == self.active;
            const fav = if (self.stickyDefaults(cx)) |d| d.isFavorite(r.harness, r.model.id) else false;
            const mark, const tint = chrome.harnessMark(r.harness);
            var row = div().id(.{ "model-row", ix }).role(.list_box_option).ariaLabel(zpui.fmt("{s} · {s}", .{ r.model.label, chrome.harnessName(r.harness) })).ariaSelected(is_selected).h(px(compact_row_height)).flexNone().pl(px(8)).pr(px(4))
                .rounded(px(chrome.menu_item_radius)).flex().itemsCenter().gap(px(8)).cursorPointer()
                .textColor(theme.text)
                .onClick(cx.listenerWith(ix, ModelPicker.onModelRow))
                .onHover(cx.listenerWith(ix, ModelPicker.onHoverRow));
            row = if (is_selected) chrome.lightPlate(theme, 1).apply(row) else row.border1().borderColor(zpui.hsla(0, 0, 0, 0));
            if (!is_selected and hovered) row = row.bg(theme.ink(0.05));
            if (hovered) row = row.ariaActiveDescendant();
            row = row.child(chrome.icon(mark, 14, tint orelse theme.text_muted))
                .child(div().flex1().minW0().flex().itemsBaseline().gap(px(6)).textSize(rems(12))
                    .child(div().flexNone().maxWFull().truncate().fontWeight(500).child(r.model.label)))
                .child(div().size(px(24)).rounded(px(6)).flex().itemsCenter().justifyCenter()
                    .opacity(if (fav or hovered) 1 else 0)
                    .child(chrome.icon(if (fav) .star_bold else .star, 13, if (fav) theme.text else theme.text_muted)));
            col = col.child(row);
        }
        return div().flex().flexCol().child(self.backHeader(theme, cx)).child(self.searchRow(theme)).child(col);
    }

    const SliderPaint = struct { fraction: f32, count: usize, filled: zpui.Hsla, open: zpui.Hsla };

    fn paintStops(ctx: SliderPaint, b: zpui.Bounds(f32), window: *Window, _: *App) void {
        if (ctx.count < 2) return;
        const inset = thumb_width / 2;
        const run = @max(b.size.width - 2 * inset, 0);
        for (0..ctx.count) |i| {
            const stop = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ctx.count - 1));
            const x = b.origin.x + inset + stop * run;
            const color = if (stop <= ctx.fraction) ctx.filled else ctx.open;
            window.paintQuad(zpui.fill(zpui.Bounds(f32){ .origin = .{ .x = x - 2, .y = b.origin.y + slider_height / 2 - 2 }, .size = .{ .width = 4, .height = 4 } }, color).cornerRadii(2));
        }
    }

    fn renderPanel(self: *ModelPicker, theme: *const Theme, cx: *Context(ModelPicker)) zpui.Div {
        const in = self.inputs(cx);
        const ladder = rc.traitLadder(&in);
        const effort = rc.effectiveReasoning(&in);
        const label = rc.modelLabel(&in) orelse "Default";
        const m = rc.selectedModel(&in);
        var selected_ix: usize = 0;
        for (ladder, 0..) |l, i| if (effort == l) {
            selected_ix = i;
        };
        // Header: title (effort over model name), fast mode.
        var title = div().id("compact-select-model").role(.button).ariaLabel(zpui.fmt("{s} · {s} · Change model", .{ if (ladder.len > 0) rc.reasoningLabel(ladder[selected_ix]) else "Default", label })).flex1().minW0().hFull().px(px(8)).rounded(px(chrome.menu_item_radius))
            .flex().flexCol().itemsStart().justifyCenter().cursorPointer()
            .hover(sb.bg(theme.ink(0.05)))
            .onClick(cx.listener(ModelPicker.onShowModels));
        if (ladder.len > 0) {
            title = title.child(div().textSize(rems(14)).lineHeight(px(17)).fontWeight(600).textColor(theme.text).child(rc.reasoningLabel(ladder[selected_ix])))
                .child(div().maxWFull().minW0().flex().itemsCenter().gap(px(3)).textSize(rems(12)).lineHeight(px(15)).textColor(theme.text_muted)
                    .child(div().minW0().truncate().child(label))
                    .child(div().flexNone().opacity(0.55).child(chrome.icon(.alt_arrow_right, 10, theme.text_muted))));
        } else {
            title = title.child(div().maxWFull().minW0().flex().itemsCenter().gap(px(3)).textSize(rems(14)).lineHeight(px(17)).fontWeight(600).textColor(theme.text)
                .child(div().minW0().truncate().child(label))
                .child(div().flexNone().opacity(0.55).child(chrome.icon(.alt_arrow_right, 10, theme.text_muted))));
        }
        var header = div().h(px(if (ladder.len > 0) header_height else header_height_single)).flexNone().flex().gap(px(chrome.card_inset));
        header = header.child(title);
        var fast_option: ?*const protocol.ModelOption = null;
        if (m) |mm| for (mm.options) |*o| if (std.mem.eql(u8, o.id, "fastMode")) {
            fast_option = o;
        };
        if (fast_option) |o| {
            const on = std.mem.eql(u8, self.optionChoice(o), "on");
            header = header.child(div().id("compact-fast").role(.button).ariaLabel("Fast mode").ariaToggled(on).w(px(fast_button_width)).hFull().flexNone()
                .rounded(px(chrome.menu_item_radius)).flex().itemsCenter().justifyCenter().cursorPointer()
                .hover(sb.bg(theme.ink(0.05)))
                .tooltipWith(chrome.TipData{ .text = if (on) "Fast mode on · Turn off" else "Fast mode off · Turn on", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                .onClick(cx.listener(ModelPicker.onToggleFast))
                .child(chrome.icon(if (on) .fast_tier_bold else .fast_tier, 15, if (on) theme.accent else theme.text_muted)));
        }
        var panel = div().p(px(chrome.card_inset)).flex().flexCol().child(header);
        if (ladder.len > 0) {
            const fraction: f32 = if (ladder.len > 1) @as(f32, @floatFromInt(selected_ix)) / @as(f32, @floatFromInt(ladder.len - 1)) else 0;
            var hits = div().absolute().inset0().flex().flexRow();
            for (ladder, 0..) |level, i| {
                hits = hits.child(div().id(.{ "effort-stop", i }).role(.button).ariaLabel(rc.reasoningLabel(level)).ariaSelected(i == selected_ix).flex1().hFull().cursorPointer().onClick(cx.listenerWith(level, ModelPicker.onReasoning)));
            }
            const slider = div().id("compact-effort-slider").role(.slider).ariaLabel("Reasoning effort").ariaValue(rc.reasoningLabel(ladder[selected_ix]))
                .ariaNumericValue(@floatFromInt(selected_ix)).ariaMinNumericValue(0).ariaMaxNumericValue(@floatFromInt(ladder.len - 1)).ariaNumericValueStep(1)
                .ariaOrientation(.horizontal).ariaDescription("Use Left and Right to adjust reasoning; Home and End select the first and last levels")
                .onA11yAction(.set_value, cx.listener(ModelPicker.onA11yEffort)).onA11yAction(.increment, cx.listener(ModelPicker.onA11yEffort)).onA11yAction(.decrement, cx.listener(ModelPicker.onA11yEffort))
                .relative().h(px(slider_height))
                .child(chrome.lightPlate(theme, 1).apply(div().absolute().left0().right0().top(px((slider_height - rail_height) / 2)).h(px(rail_height)).roundedFull()))
                // The accent fill runs a rail radius past the thumb centre.
                .child(chrome.accentPlate(theme, 1, 0).apply(div().absolute().left0().top(px((slider_height - rail_height) / 2)).h(px(rail_height)).roundedFull()
                    .w(px(@min(thumb_width / 2 + fraction * (slider_width - thumb_width) + rail_height / 2, slider_width)))))
                .child(zpui.canvas(SliderPaint{ .fraction = fraction, .count = ladder.len, .filled = zpui.hsla(0, 0, 1, 0.4), .open = theme.text_muted.opacity(0.28) }, paintStops).absolute().inset0())
                .child(div().absolute().left(px(thumb_width / 2)).right(px(thumb_width / 2)).top(px((slider_height - thumb_height) / 2)).h(px(thumb_height))
                    .child(chrome.thumbPlate(theme).apply(div().absolute().left(zpui.relative(fraction)).ml(px(-thumb_width / 2)).w(px(thumb_width)).h(px(thumb_height)).roundedFull())))
                .child(hits);
            // macOS 26+: AppKit's NSSlider (Liquid Glass knob that lifts while
            // dragging) with a tick mark per level, values on the ticks only. It
            // sits in the popover's deferred pass, so it floats above the overlay
            // plane with the card. Elsewhere (Linux, macOS < 26, tests) the drawn
            // glass slider above. Keys stay with the panel (the control refuses
            // first responder).
            const effort_slider = if (ladder.len > 1 and zpui.liquidGlassRevision(cx) >= 26)
                zpui.intoAnyElement(div().h(px(slider_height)).flex().flexCol().justifyCenter().child(zpui.nativeSlider("compact-effort-native", .{
                    .value = @floatFromInt(selected_ix),
                    .min = 0,
                    .max = @floatFromInt(ladder.len - 1),
                    .step = 1,
                    .label = "Reasoning effort",
                    .width = px(slider_width),
                }, cx.listener(ModelPicker.onNativeEffort), slider)))
            else
                zpui.intoAnyElement(slider);
            panel = panel.child(div().px(px(8)).pt(px(2)).pb(px(4)).child(effort_slider));
        }
        if (m) |mm| {
            var opts = div().mt(px(4)).flex().flexCol().gap(px(2)).pt(px(2)).pb(px(2));
            var any = false;
            for (mm.options, 0..) |*o, ix| {
                if (std.mem.eql(u8, o.id, "fastMode")) continue;
                any = true;
                const cur = self.optionChoice(o);
                var cur_label: []const u8 = cur;
                for (o.choices) |c| if (std.mem.eql(u8, c.id, cur)) {
                    cur_label = c.label;
                };
                opts = opts.child(div().id(.{ "compact-option", ix }).role(.button).ariaLabel(zpui.fmt("{s}: {s}", .{ o.label, cur_label })).h(px(26)).px(px(8)).rounded(px(chrome.menu_item_radius))
                    .flex().itemsCenter().gap(px(8)).cursorPointer().hover(sb.bg(theme.ink(0.05)))
                    .onClick(cx.listenerWith(ix, ModelPicker.onCycleOption))
                    .child(div().flex1().minW0().truncate().textSize(rems(13)).fontWeight(500).textColor(theme.text).child(o.label))
                    .child(div().flexNone().textSize(rems(13)).textColor(theme.text_muted).child(cur_label))
                    .child(div().ml(px(3)).child(chrome.icon(.alt_arrow_right, 12, theme.text_muted))));
            }
            if (any) panel = panel.child(opts);
        }
        return panel;
    }

};
