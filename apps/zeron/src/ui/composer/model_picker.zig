//! The composer's model chip and its harness / model popover — the
//! `PickerKind::HarnessModel` slice of zeron `crates/ui/src/pickers.rs`:
//!
//! - chip (`trigger_chip`): 32px ghost pill, harness brand mark (16px) +
//!   model label (12px medium, text @ 0.9) + reasoning effort as the muted
//!   second tone (text_muted @ 0.7, brightening to text @ 0.85 when it
//!   departs from the model default), hover / open wash `element_hover`;
//! - popover: the compact picker (`pickers/compact.rs`, what the app shows
//!   by default) — a 256px frosted card anchored above the chip's trailing
//!   edge with three pages: the panel (provider button, effort title over the
//!   model name, fast-mode bolt, the glass effort slider with stops, model
//!   option rows such as Context Window), the model list (back + search
//!   `TextInput` in the `PaletteSearch` context, 32px rows with the harness
//!   mark, star on hover, selection = light glass plate) and the provider
//!   list. Keys as in Rust: ↑/↓ open the list beside the selection,
//!   ←/→/Home/End step the effort, Enter opens / picks, Esc backs out.
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
    /// The tab being browsed: null = favorites, else a harness.
    viewed: ?HarnessId = null,
    favorites_view: bool = false,
    /// Keyboard / hover cursor row.
    active: usize = 0,
    /// Compact picker page (`CompactPage`): the effort panel, the model
    /// list or the provider list.
    page: Page = .panel,
    /// Explicit model option picks (`modelOptions`), keys/values owned.
    options: protocol.JsonMap = .{},
    search: Entity(TextInput),
    focus: zpui.FocusHandle,
    defaults: ?*const rc.ComposerDefaults = null,
    allow_mock: bool = false,
    subs: zpui.Subscriptions = .{},

    pub const Events = .{ Picked, Closed };

    pub const Page = enum { panel, models, providers };

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
        };
        const catalog = state.read(cx).catalog;
        try self.subs.add(cx.gpa(), try cx.observe(catalog, ModelPicker.onCatalog));
        try self.subs.add(cx.gpa(), try cx.subscribe(search, ModelPicker.onSearch));
        return self;
    }

    pub fn deinit(self: *ModelPicker, cx: *App) void {
        self.subs.deinit(self.gpa);
        self.search.release(cx);
        self.focus.release(cx);
        self.state.release(cx);
        self.draft_model_buf.deinit(self.gpa);
        self.clearOptions();
        self.options.map.deinit(self.gpa);
    }

    fn onCatalog(_: *ModelPicker, _: Entity(model.CatalogStore), cx: *Context(ModelPicker)) void {
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
            .defaults = self.defaults,
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

    /// Load the effective harness's models (and the catalog) on demand.
    fn ensureLoaded(self: *ModelPicker, cx: *Context(ModelPicker)) void {
        const catalog = self.state.read(cx).catalog;
        const in = self.inputs(cx);
        const h = self.viewed orelse rc.effectiveHarness(&in) orelse return;
        if (catalog.read(cx).modelList(h) == null and !catalog.read(cx).models_loading.contains(h)) {
            catalog.update(cx, model.CatalogStore.loadModels, .{ h, false });
        }
    }

    // ---- open / close / pick -----------------------------------------------------------

    pub fn isOpen(self: *const ModelPicker) bool {
        return self.open;
    }

    pub fn toggle(self: *ModelPicker, window: *Window, cx: *Context(ModelPicker)) void {
        if (self.open) return self.close(window, cx);
        self.open = true;
        self.page = .panel;
        self.favorites_view = false;
        const in = self.inputs(cx);
        self.viewed = rc.effectiveHarness(&in);
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

    fn pickHarness(self: *ModelPicker, h: HarnessId, cx: *Context(ModelPicker)) void {
        self.favorites_view = false;
        self.viewed = h;
        self.active = 0;
        self.ensureLoaded(cx);
        cx.notify();
    }



    fn commitModel(self: *ModelPicker, h: HarnessId, id: []const u8, window: *Window, cx: *Context(ModelPicker)) void {
        self.draft_model_buf.clearRetainingCapacity();
        self.draft_model_buf.appendSlice(self.gpa, id) catch @panic("OOM");
        self.draft.harness = h;
        self.draft.model = self.draft_model_buf.items;
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
        cx.emit(Picked{});
        cx.notify();
    }

    fn showModels(self: *ModelPicker, window: *Window, cx: *Context(ModelPicker)) void {
        self.page = .models;
        self.favorites_view = false;
        self.active = self.selectedRowIndex(cx) orelse 0;
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
    fn onShowProviders(self: *ModelPicker, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ModelPicker)) void {
        self.page = .providers;
        self.active = 0;
        cx.notify();
    }
    fn onBack(self: *ModelPicker, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.showPanel(window, cx);
    }
    fn onProviderRow(self: *ModelPicker, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ModelPicker)) void {
        var hbuf: [16]protocol.HarnessDescriptor = undefined;
        const offered = rc.offeredHarnesses(self.state.read(cx).catalog.read(cx).harnessList(), self.allow_mock, &hbuf);
        if (ix == 0) {
            self.favorites_view = true;
            self.page = .models;
            self.active = 0;
            window.focus(self.search.read(cx).focus);
            return cx.notify();
        }
        if (ix - 1 >= offered.len) return;
        self.pickHarness(offered[ix - 1].id, cx);
        self.draft.harness = offered[ix - 1].id;
        self.draft.model = null;
        cx.emit(Picked{});
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
        const n = if (self.page == .models) self.rows(cx, &buf).len else blk: {
            var hbuf: [16]protocol.HarnessDescriptor = undefined;
            break :blk 1 + rc.offeredHarnesses(self.state.read(cx).catalog.read(cx).harnessList(), self.allow_mock, &hbuf).len;
        };
        if (eq(u8, k, "escape")) {
            self.showPanel(window, cx);
        } else if (eq(u8, k, "down")) {
            if (n > 0) self.active = (self.active + 1) % n;
            cx.notify();
        } else if (eq(u8, k, "up")) {
            if (n > 0) self.active = (self.active + n - 1) % n;
            cx.notify();
        } else if (eq(u8, k, "enter")) {
            if (self.page == .models) self.activate(self.active, window, cx) else {
                const click: zpui.ClickEvent = undefined;
                self.onProviderRow(self.active, &click, window, cx);
            }
        } else return;
        cx.stopPropagation();
    }

    fn onOutside(self: *ModelPicker, _: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(ModelPicker)) void {
        self.close(window, cx);
    }

    // ---- rows --------------------------------------------------------------------------

    pub const Row = struct { harness: HarnessId, model: *const protocol.Model };

    fn matches(query: []const u8, m: *const protocol.Model) bool {
        if (query.len == 0) return true;
        return std.ascii.findIgnoreCase(m.label, query) != null or std.ascii.findIgnoreCase(m.id, query) != null;
    }

    /// The visible rows for the viewed tab, filtered by the search query.
    pub fn rows(self: *const ModelPicker, cx: anytype, out: []Row) []Row {
        const catalog = self.state.read(cx).catalog.read(cx);
        const query = std.mem.trim(u8, self.search.read(cx).text(), " ");
        var n: usize = 0;
        if (self.favorites_view) {
            const d = self.defaults orelse return out[0..0];
            for (d.favorites) |fav| {
                const list = catalog.modelList(fav.harness) orelse continue;
                for (list) |*m| if (std.mem.eql(u8, m.id, fav.model) and matches(query, m) and n < out.len) {
                    out[n] = .{ .harness = fav.harness, .model = m };
                    n += 1;
                };
            }
            return out[0..n];
        }
        const in = self.inputs(cx);
        const h = self.viewed orelse rc.effectiveHarness(&in) orelse return out[0..0];
        const list = catalog.modelList(h) orelse return out[0..0];
        for (list) |*m| {
            if (!matches(query, m) or n >= out.len) continue;
            out[n] = .{ .harness = h, .model = m };
            n += 1;
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

        var chip = div().id("picker-model").relative()
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
    const list_header: f32 = 40;
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
            .providers => zpui.intoAnyElement(self.renderProviders(&theme, cx)),
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

    fn listHeader(self: *ModelPicker, theme: *const Theme, cx: *Context(ModelPicker)) zpui.Div {
        return div().h(px(list_header)).flexNone().px(px(chrome.card_inset)).borderB1().borderColor(theme.hairline(0.08))
            .flex().itemsCenter().gap(px(4))
            .child(chrome.menuRow(theme, "compact-list-back", false).flexNone().onClick(cx.listener(ModelPicker.onBack))
                .child(chrome.icon(.alt_arrow_left, 14, theme.text_muted)))
            .child(div().flex1().minW0().textSize(rems(13)).child(self.search));
    }

    fn renderModels(self: *ModelPicker, theme: *const Theme, cx: *Context(ModelPicker)) zpui.Div {
        var rows_buf: [256]Row = undefined;
        const list = self.rows(cx, &rows_buf);
        const in = self.inputs(cx);
        const selected = rc.selectedModel(&in);
        const catalog = self.state.read(cx).catalog.read(cx);
        var col = div().id("model-menu-scroll").flex().flexCol().gap(px(chrome.menu_gap)).p(px(chrome.card_inset))
            .h(px(compactListHeight(list.len))).overflowYScroll();
        if (list.len == 0) {
            const viewed = self.viewed orelse rc.effectiveHarness(&in);
            const note = if (catalog.harnesses == null or (viewed != null and catalog.modelList(viewed.?) == null))
                "Loading models…"
            else if (self.favorites_view)
                "No starred models yet"
            else
                "No models found";
            col = col.child(div().px(px(8)).py(px(10)).textSize(rems(12)).textColor(theme.text_muted).child(note));
        }
        for (list, 0..) |r, ix| {
            const is_selected = selected == r.model;
            const hovered = ix == self.active;
            const fav = if (self.defaults) |d| d.isFavorite(r.harness, r.model.id) else false;
            const mark, const tint = chrome.harnessMark(r.harness);
            var row = div().id(.{ "model-row", ix }).h(px(compact_row_height)).flexNone().pl(px(8)).pr(px(4))
                .rounded(px(chrome.menu_item_radius)).flex().itemsCenter().gap(px(8)).cursorPointer()
                .textColor(theme.text)
                .onClick(cx.listenerWith(ix, ModelPicker.onModelRow))
                .onHover(cx.listenerWith(ix, ModelPicker.onHoverRow));
            row = if (is_selected) chrome.lightPlate(theme, 1).apply(row) else row.border1().borderColor(zpui.hsla(0, 0, 0, 0));
            if (!is_selected and hovered) row = row.bg(theme.ink(0.05));
            row = row.child(chrome.icon(mark, 14, tint orelse theme.text_muted))
                .child(div().flex1().minW0().flex().itemsBaseline().gap(px(6)).textSize(rems(12))
                    .child(div().flexNone().maxWFull().truncate().fontWeight(500).child(r.model.label)))
                .child(div().size(px(24)).rounded(px(6)).flex().itemsCenter().justifyCenter()
                    .opacity(if (fav or hovered) 1 else 0)
                    .child(chrome.icon(if (fav) .star_bold else .star, 13, if (fav) theme.text else theme.text_muted)));
            col = col.child(row);
        }
        return div().flex().flexCol().child(self.listHeader(theme, cx)).child(col);
    }

    fn renderProviders(self: *ModelPicker, theme: *const Theme, cx: *Context(ModelPicker)) zpui.Div {
        var hbuf: [16]protocol.HarnessDescriptor = undefined;
        const offered = rc.offeredHarnesses(self.state.read(cx).catalog.read(cx).harnessList(), self.allow_mock, &hbuf);
        const in = self.inputs(cx);
        const effective = rc.effectiveHarness(&in);
        var col = div().flex().flexCol().gap(px(chrome.menu_gap)).p(px(chrome.card_inset)).h(px(compactListHeight(offered.len + 1)));
        var ix: usize = 0;
        while (ix <= offered.len) : (ix += 1) {
            const is_star = ix == 0;
            const sel = !is_star and effective == offered[ix - 1].id;
            const mark, const tint = if (is_star) .{ chrome.Icon.star_bold, @as(?zpui.Hsla, null) } else chrome.harnessMark(offered[ix - 1].id);
            var row = div().id(.{ "compact-provider", ix }).h(px(compact_row_height)).flexNone().px(px(8))
                .rounded(px(chrome.menu_item_radius)).flex().itemsCenter().gap(px(8)).cursorPointer().textColor(theme.text)
                .onClick(cx.listenerWith(ix, ModelPicker.onProviderRow))
                .onHover(cx.listenerWith(ix, ModelPicker.onHoverRow));
            row = if (sel) chrome.lightPlate(theme, 1).apply(row) else row.border1().borderColor(zpui.hsla(0, 0, 0, 0));
            if (!sel and ix == self.active) row = row.bg(theme.ink(0.05));
            row = row.child(chrome.icon(mark, 14, tint orelse theme.text_muted))
                .child(div().flex1().minW0().truncate().textSize(rems(12)).fontWeight(500)
                .child(if (is_star) "Starred" else offered[ix - 1].name));
            if (sel) row = row.child(chrome.icon(.check, 13, theme.text_muted));
            col = col.child(row);
        }
        return div().flex().flexCol()
            .child(div().h(px(list_header)).flexNone().px(px(chrome.card_inset)).borderB1().borderColor(theme.hairline(0.08))
                .flex().itemsCenter().gap(px(4))
                .child(chrome.menuRow(theme, "compact-provider-back", false).flexNone().onClick(cx.listener(ModelPicker.onBack))
                    .child(chrome.icon(.alt_arrow_left, 14, theme.text_muted)))
                .child(div().textSize(rems(13)).textColor(theme.text_muted).child("Providers")))
            .child(col);
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
        const harness = rc.effectiveHarness(&in);
        const label = rc.modelLabel(&in) orelse "Default";
        const m = rc.selectedModel(&in);
        var selected_ix: usize = 0;
        for (ladder, 0..) |l, i| if (effort == l) {
            selected_ix = i;
        };
        // Header: provider button, title (effort over model name), fast mode.
        var title = div().id("compact-select-model").flex1().minW0().hFull().px(px(8)).rounded(px(chrome.menu_item_radius))
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
        if (harness) |h| {
            const mark, const tint = chrome.harnessMark(h);
            header = header.child(div().id("compact-select-provider").w(px(fast_button_width)).hFull().flexNone()
                .rounded(px(chrome.menu_item_radius)).flex().itemsCenter().justifyCenter().cursorPointer()
                .hover(sb.bg(theme.ink(0.05)))
                .tooltipWith(chrome.TipData{ .text = chrome.harnessName(h), .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                .onClick(cx.listener(ModelPicker.onShowProviders))
                .child(chrome.icon(mark, 16, tint orelse theme.text_muted)));
        }
        header = header.child(title);
        var fast_option: ?*const protocol.ModelOption = null;
        if (m) |mm| for (mm.options) |*o| if (std.mem.eql(u8, o.id, "fastMode")) {
            fast_option = o;
        };
        if (fast_option) |o| {
            const on = std.mem.eql(u8, self.optionChoice(o), "on");
            header = header.child(div().id("compact-fast").w(px(fast_button_width)).hFull().flexNone()
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
                hits = hits.child(div().id(.{ "effort-stop", i }).flex1().hFull().cursorPointer().onClick(cx.listenerWith(level, ModelPicker.onReasoning)));
            }
            const slider = div().id("compact-effort-slider").relative().h(px(slider_height))
                .child(chrome.lightPlate(theme, 1).apply(div().absolute().left0().right0().top(px((slider_height - rail_height) / 2)).h(px(rail_height)).roundedFull()))
                // The accent fill runs a rail radius past the thumb centre.
                .child(chrome.accentPlate(theme, 1, 0).apply(div().absolute().left0().top(px((slider_height - rail_height) / 2)).h(px(rail_height)).roundedFull()
                    .w(px(@min(thumb_width / 2 + fraction * (slider_width - thumb_width) + rail_height / 2, slider_width)))))
                .child(zpui.canvas(SliderPaint{ .fraction = fraction, .count = ladder.len, .filled = zpui.hsla(0, 0, 1, 0.4), .open = theme.text_muted.opacity(0.28) }, paintStops).absolute().inset0())
                .child(div().absolute().left(px(thumb_width / 2)).right(px(thumb_width / 2)).top(px((slider_height - thumb_height) / 2)).h(px(thumb_height))
                    .child(chrome.thumbPlate(theme).apply(div().absolute().left(zpui.relative(fraction)).ml(px(-thumb_width / 2)).w(px(thumb_width)).h(px(thumb_height)).roundedFull())))
                .child(hits);
            panel = panel.child(div().px(px(8)).pt(px(2)).pb(px(4)).child(slider));
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
                opts = opts.child(div().id(.{ "compact-option", ix }).h(px(26)).px(px(8)).rounded(px(chrome.menu_item_radius))
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
