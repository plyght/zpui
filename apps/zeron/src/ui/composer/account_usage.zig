//! The composer footer's plan-usage ring and account switcher (zeron
//! `account_usage.rs`): beside the context ring, an accent ring shows how
//! much of the live account's rate limit the session's harness has used (its
//! most-used window). Clicking it opens the harness's accounts — usage meters
//! per login — and clicking one switches to it with the same optimistic
//! `ActivateAgentAccount` Settings → Accounts runs. Both views share the
//! `AccountsCache` global (per target device; null = this device).
//!
//! RPCs: `ListAgentAccounts {forceUsage, targetDeviceId?}` (a plain list
//! first when nothing is cached, then the forced probe; forced probes at most
//! every 30s, re-probed every 5 min and when the card opens),
//! `ActivateAgentAccount {id, accountId, harness, targetDeviceId?}`.
//!
//! ```zig
//! // ComposerView.renderFooter
//! row = row.child(account_usage.ring(cx.app, self.state, harness, target, theme));
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const chrome = @import("chrome.zig");

const Allocator = std.mem.Allocator;
const json = std.json;
const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = chrome.Theme;
const HarnessId = engine.protocol.HarnessId;

// ---- protocol (the same shapes as settings/accounts.zig) -------------------------------------

pub const UsageWindow = struct {
    label: []const u8,
    usedFraction: f32,
    resetsAt: ?[]const u8 = null,
};

pub const Account = struct {
    id: []const u8,
    harness: HarnessId,
    email: ?[]const u8 = null,
    planLabel: ?[]const u8 = null,
    active: bool,
    usageWindows: []const UsageWindow = &.{},
    usageFetchedAt: ?i64 = null,
    usageError: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    authKind: ?[]const u8 = null,
    switchable: bool = false,
    savedAt: ?i64 = null,
    provider: ?[]const u8 = null,
};

pub const Snapshot = struct { accounts: []Account = &.{}, warnings: []const json.Value = &.{} };

const parse_opts: json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

// ---- pure helpers -------------------------------------------------------------------------

/// `used_fraction`: the binding limit — the most-used window, clamped.
pub fn usedFraction(account: *const Account) ?f32 {
    var best: ?f32 = null;
    for (account.usageWindows) |w| {
        const f = std.math.clamp(w.usedFraction, 0, 1);
        best = if (best) |b| @max(b, f) else f;
    }
    return best;
}

/// `active_account`: the harness's live login.
pub fn activeAccount(snapshot: *const Snapshot, harness: HarnessId) ?*const Account {
    for (snapshot.accounts) |*a| if (a.harness == harness and a.active) return a;
    return null;
}

/// `accounts::signs_in` + `reports_usage` (the harnesses with a ring).
pub fn tracksUsage(h: HarnessId) bool {
    return h != .mock and h != .antigravity;
}

pub const UsageLevel = enum { normal, warn, critical };

pub fn usageLevel(fraction: f32) UsageLevel {
    if (fraction >= 0.95) return .critical;
    if (fraction >= 0.80) return .warn;
    return .normal;
}

pub fn usageColor(level: UsageLevel, t: *const Theme) zpui.Hsla {
    return switch (level) {
        .normal => t.accent,
        .warn => t.warning,
        .critical => t.danger,
    };
}

/// `mark_switched`: `account` becomes the live login of its group (agent,
/// or agent + provider for per-provider agents).
pub fn markSwitched(snapshot: *Snapshot, account_id: []const u8, harness: HarnessId, provider: ?[]const u8) void {
    for (snapshot.accounts) |*row| {
        const same_provider = if (row.provider) |p| (if (provider) |q| std.mem.eql(u8, p, q) else false) else provider == null;
        if (row.harness == harness and same_provider) row.active = std.mem.eql(u8, row.id, account_id);
    }
}

pub fn providerName(h: HarnessId) []const u8 {
    return switch (h) {
        .@"claude-code" => "Claude Code",
        .codex => "Codex",
        .cursor => "Cursor",
        .antigravity => "Antigravity",
        .grok => "Grok",
        .devin => "Devin",
        .opencode => "OpenCode",
        .pi => "Pi",
        .hermes => "Hermes",
        .mock => "Agent",
    };
}

// ---- the shared cache (AccountsSnapshotCache) -----------------------------------------------

pub const AccountsCache = struct {
    gpa: Allocator,
    entries: std.ArrayList(struct { target: ?[]u8, snapshot: json.Parsed(Snapshot) }) = .empty,

    pub fn deinit(self: *AccountsCache, _: *App) void {
        for (self.entries.items) |*e| {
            if (e.target) |t| self.gpa.free(t);
            e.snapshot.deinit();
        }
        self.entries.deinit(self.gpa);
    }

    fn index(self: *const AccountsCache, target: ?[]const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            const same = if (e.target) |t| (if (target) |q| std.mem.eql(u8, t, q) else false) else target == null;
            if (same) return i;
        }
        return null;
    }

    pub fn get(self: *const AccountsCache, target: ?[]const u8) ?*Snapshot {
        const i = self.index(target) orelse return null;
        return &self.entries.items[i].snapshot.value;
    }

    /// Takes ownership of `snapshot`.
    pub fn put(self: *AccountsCache, target: ?[]const u8, snapshot: json.Parsed(Snapshot)) void {
        if (self.index(target)) |i| {
            self.entries.items[i].snapshot.deinit();
            self.entries.items[i].snapshot = snapshot;
            return;
        }
        const t: ?[]u8 = if (target) |x| self.gpa.dupe(u8, x) catch {
            snapshot.deinit();
            return;
        } else null;
        self.entries.append(self.gpa, .{ .target = t, .snapshot = snapshot }) catch {
            if (t) |x| self.gpa.free(x);
            snapshot.deinit();
        };
    }

    /// An owned copy of the cached snapshot (to restore after a refusal).
    pub fn clone(self: *const AccountsCache, target: ?[]const u8) ?json.Parsed(Snapshot) {
        const s = self.get(target) orelse return null;
        return cloneSnapshot(self.gpa, s.*);
    }
};

pub fn cloneSnapshot(gpa: Allocator, s: Snapshot) ?json.Parsed(Snapshot) {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    json.Stringify.value(s, .{}, &aw.writer) catch return null;
    return json.parseFromSlice(Snapshot, gpa, aw.written(), parse_opts) catch null;
}

fn cache(app: *App) *AccountsCache {
    if (!app.hasGlobal(AccountsCache)) app.setGlobal(AccountsCache{ .gpa = app.gpa }) catch {};
    return app.globalMut(AccountsCache);
}

/// Store a `ListAgentAccounts` / `ActivateAgentAccount` reply for `target`
/// (Settings → Accounts publishes its lists here too) and redraw.
pub fn publish(app: *App, target: ?[]const u8, value: json.Value) bool {
    const parsed = json.parseFromValue(Snapshot, app.gpa, value, parse_opts) catch return false;
    cache(app).put(target, parsed);
    app.refreshWindows();
    return true;
}

/// Attached to an engine (headless tests: calls go to `EngineState.test_sink`).
fn attached(es: *const model.EngineState) bool {
    return es.conn != null or model.engine_state.test_sink != null;
}

// ---- the ring view (AccountUsage) -----------------------------------------------------------

const force_min_interval_ns: u64 = 30 * std.time.ns_per_s;
const poll_interval_ns: u64 = 5 * 60 * std.time.ns_per_s;

pub const AccountUsage = struct {
    gpa: Allocator,
    state: Entity(model.AppState),
    theme: Theme,
    target: ?[]u8 = null,
    harness: ?HarnessId = null,
    loaded: bool = false,
    last_forced: ?u64 = null,
    err: ?[]u8 = null,
    open: bool = false,
    /// Replies carry no context: `true` = a forced probe, in send order.
    loads: std.ArrayList(bool) = .empty,
    /// The pre-switch list, restored if the engine refuses.
    previous: ?json.Parsed(Snapshot) = null,
    previous_target: ?[]u8 = null,
    poll: zpui.Task(void) = .none,

    pub fn init(state: Entity(model.AppState), theme: Theme, cx: *Context(AccountUsage)) AccountUsage {
        var self: AccountUsage = .{ .gpa = cx.gpa(), .state = state.retain(cx), .theme = theme };
        self.poll = cx.timer(poll_interval_ns, onPoll) catch .none;
        return self;
    }

    pub fn deinit(self: *AccountUsage, app: *App) void {
        self.poll.cancel();
        if (self.target) |t| self.gpa.free(t);
        if (self.err) |e| self.gpa.free(e);
        if (self.previous) |p| p.deinit();
        if (self.previous_target) |t| self.gpa.free(t);
        self.loads.deinit(self.gpa);
        self.state.release(app);
    }

    fn onPoll(self: *AccountUsage, cx: *Context(AccountUsage)) void {
        self.poll.detach();
        if (self.harness != null) self.load(true, cx);
        self.poll = cx.timer(poll_interval_ns, onPoll) catch .none;
    }

    /// `track`: follow the session's harness and device; loads on first sight
    /// of a device. Cheap enough to call every render.
    pub fn track(self: *AccountUsage, harness: ?HarnessId, target: ?[]const u8, theme: *const Theme, cx: *Context(AccountUsage)) void {
        self.theme = theme.*;
        self.harness = if (harness) |h| (if (tracksUsage(h)) h else null) else null;
        const same = if (self.target) |t| (if (target) |q| std.mem.eql(u8, t, q) else false) else target == null;
        if (!same) {
            if (self.target) |t| self.gpa.free(t);
            self.target = if (target) |q| self.gpa.dupe(u8, q) catch null else null;
            self.loaded = false;
            self.last_forced = null;
            setErr(self, null);
        }
        if (self.harness != null and !self.loaded) {
            self.loaded = true;
            self.load(true, cx);
        }
    }

    fn setErr(self: *AccountUsage, msg: ?[]const u8) void {
        if (self.err) |e| self.gpa.free(e);
        self.err = if (msg) |m| self.gpa.dupe(u8, m) catch null else null;
    }

    const ListParams = struct { forceUsage: bool, targetDeviceId: ?[]const u8 = null };

    /// `load`: a plain list first when nothing is cached (the engine's
    /// persisted usage paints at once), then the forced probe.
    fn load(self: *AccountUsage, force_usage: bool, cx: *Context(AccountUsage)) void {
        const now = cx.app.executor.now();
        if (force_usage) {
            if (self.last_forced) |at| if (now -| at < force_min_interval_ns) return;
            self.last_forced = now;
        }
        const es = self.state.read(cx).engine;
        if (!attached(es.read(cx))) return;
        const paint_first = force_usage and cache(cx.app).get(self.target) == null;
        if (paint_first) self.request(false, cx);
        self.request(force_usage, cx);
    }

    fn request(self: *AccountUsage, force: bool, cx: *Context(AccountUsage)) void {
        const es = self.state.read(cx).engine;
        self.loads.append(self.gpa, force) catch return;
        model.EngineState.request(es, cx, AccountUsage, cx.entityId(), .ListAgentAccounts, ListParams{ .forceUsage = force, .targetDeviceId = self.target }, onList) catch {
            _ = self.loads.pop();
        };
    }

    fn onList(self: *AccountUsage, result: model.engine_state.CallResult, cx: *Context(AccountUsage)) void {
        if (self.loads.items.len > 0) _ = self.loads.orderedRemove(0);
        switch (result) {
            .ok => |v| _ = publish(cx.app, self.target, v),
            .err => {},
        }
        cx.notify();
    }

    const ActivateParams = struct { id: []const u8, accountId: []const u8, harness: HarnessId, targetDeviceId: ?[]const u8 = null };

    /// `switch`: optimistic, like Settings → Accounts.
    fn switchTo(self: *AccountUsage, account_id: []const u8, cx: *Context(AccountUsage)) void {
        const es = self.state.read(cx).engine;
        if (!attached(es.read(cx))) return;
        const c = cache(cx.app);
        const snap = c.get(self.target) orelse return;
        var harness: ?HarnessId = null;
        var provider: ?[]const u8 = null;
        for (snap.accounts) |a| if (std.mem.eql(u8, a.id, account_id)) {
            harness = a.harness;
            provider = a.provider;
        };
        const h = harness orelse return;
        if (self.previous) |p| p.deinit();
        self.previous = c.clone(self.target);
        if (self.previous_target) |t| self.gpa.free(t);
        self.previous_target = if (self.target) |t| self.gpa.dupe(u8, t) catch null else null;
        const id = self.gpa.dupe(u8, account_id) catch return;
        defer self.gpa.free(id);
        const prov: ?[]u8 = if (provider) |p| self.gpa.dupe(u8, p) catch null else null;
        defer if (prov) |p| self.gpa.free(p);
        markSwitched(snap, id, h, prov);
        setErr(self, null);
        model.EngineState.request(es, cx, AccountUsage, cx.entityId(), .ActivateAgentAccount, ActivateParams{ .id = id, .accountId = id, .harness = h, .targetDeviceId = self.target }, onActivate) catch {
            restore(self, cx);
        };
        cx.app.refreshWindows();
        cx.notify();
    }

    fn restore(self: *AccountUsage, cx: *Context(AccountUsage)) void {
        if (self.previous) |p| cache(cx.app).put(self.previous_target, p);
        self.previous = null;
    }

    fn onActivate(self: *AccountUsage, result: model.engine_state.CallResult, cx: *Context(AccountUsage)) void {
        switch (result) {
            // The reply is the fresh list; an older engine's bare reply → refetch.
            .ok => |v| if (!publish(cx.app, self.target, v)) self.load(false, cx),
            .err => |e| {
                restore(self, cx);
                setErr(self, e.message);
            },
        }
        if (self.previous) |p| p.deinit();
        self.previous = null;
        cx.notify();
    }

    /// The ring's reading (`fraction`).
    fn fraction(self: *const AccountUsage, app: *App) ?f32 {
        const h = self.harness orelse return null;
        const snap = cache(app).get(self.target) orelse return null;
        return usedFraction(activeAccount(snap, h) orelse return null);
    }

    fn onToggle(self: *AccountUsage, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AccountUsage)) void {
        if (self.open) {
            self.open = false;
            return cx.notify();
        }
        // Opening the card is the moment someone cares: re-probe.
        self.load(true, cx);
        self.open = true;
        cx.notify();
    }

    fn onOutside(self: *AccountUsage, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(AccountUsage)) void {
        self.open = false;
        cx.notify();
    }

    fn onRow(self: *AccountUsage, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(AccountUsage)) void {
        const h = self.harness orelse return;
        const snap = cache(cx.app).get(self.target) orelse return;
        var n: usize = 0;
        for (snap.accounts) |a| if (a.harness == h) {
            if (n == ix) {
                if (a.active or !a.switchable) return;
                const id = self.gpa.dupe(u8, a.id) catch return;
                defer self.gpa.free(id);
                return self.switchTo(id, cx);
            }
            n += 1;
        };
    }

    fn meter(win: UsageWindow, t: *const Theme) zpui.Div {
        const f = std.math.clamp(win.usedFraction, 0, 1);
        const level = usageLevel(f);
        const fill = usageColor(level, t).opacity(if (level == .normal) 0.8 else 0.9);
        var bar = div().w(px(88)).flexNone().h(px(4)).roundedFull().overflowHidden().bg(t.wash(0.08));
        if (f > 0) bar = bar.child(div().hFull().w(zpui.relative(@max(f, 0.015))).roundedFull().bg(fill));
        return div().h(px(16)).flex().flexRow().itemsCenter().gap(px(8)).textSize(chrome.rems(11.5))
            .child(div().w(px(52)).flexNone().truncate().textColor(t.text_muted).child(win.label))
            .child(bar)
            .child(div().w(px(34)).flexNone().textRight().textColor(if (level == .normal) t.text_muted else usageColor(level, t))
            .child(zpui.fmt("{d}%", .{@as(u32, @intFromFloat(@round(f * 100)))})));
    }

    /// `accounts_card`.
    fn card(self: *AccountUsage, cx: *Context(AccountUsage)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, self.theme.forPopup());
        const a = zpui.window.arena_mod.frameAllocator();
        const title = zpui.fmt("{s} accounts", .{if (self.harness) |h| providerName(h) else "Agent"});
        var heading: std.ArrayList(u8) = .empty;
        for (title, 0..) |ch, i| {
            if (i > 0) heading.appendSlice(a, "\u{200A}") catch {};
            heading.append(a, std.ascii.toUpper(ch)) catch {};
        }
        var c = chrome.card(theme).w(px(400)).flex().flexCol()
            .onMouseDownOut(cx.listener(onOutside))
            .child(div().px(px(8)).pb(px(4)).pt(px(6)).textSize(chrome.rems(10)).fontWeight(500).textColor(theme.text_muted).child(heading.items));
        if (self.harness) |h| if (cache(cx.app).get(self.target)) |snap| {
            var ix: usize = 0;
            for (snap.accounts) |acc| {
                if (acc.harness != h) continue;
                defer ix += 1;
                const email = acc.email orelse acc.displayName orelse "Unknown account";
                const can_switch = !acc.active and acc.switchable;
                var meta = div().mt(px(2)).minW0().flex().flexRow().flexWrap().itemsCenter().gap(px(8))
                    .textSize(chrome.rems(12)).lineHeight(chrome.rems(16)).textColor(theme.text_muted);
                var fragments: usize = 0;
                if (acc.planLabel) |p| {
                    meta = meta.child(div().child(p));
                    fragments += 1;
                }
                const extra: ?zpui.Div = if (acc.active)
                    div().textColor(theme.accent).child("In use")
                else if (acc.usageError) |reason| (if (acc.usageWindows.len == 0) div().child(reason) else null) else null;
                if (extra) |x| {
                    if (fragments > 0) meta = meta.child(div().textColor(theme.text_muted.opacity(0.3)).child("·"));
                    meta = meta.child(x);
                    fragments += 1;
                }
                var info = div().flex1().minW0().child(div().truncate().textSize(px(12.5)).fontWeight(500).child(email));
                if (fragments > 0) info = info.child(meta);
                var meters = div().flexNone().flex().flexCol().gap(px(2));
                for (acc.usageWindows, 0..) |w, wi| {
                    if (wi >= 2) break;
                    meters = meters.child(meter(w, theme));
                }
                var row = chrome.menuRow(theme, .{ "account-usage-row", ix }, acc.active);
                if (!can_switch) row = row.cursorDefault() else row = row.onClick(cx.listenerWith(ix, onRow));
                c = c.child(row.child(info).child(meters));
            }
        };
        if (self.err) |e| c = c.child(div().px(px(8)).py(px(4)).textSize(px(12)).textColor(theme.danger).child(e));
        return c;
    }

    pub fn render(self: *AccountUsage, _: *Window, cx: *Context(AccountUsage)) zpui.Div {
        const theme = &self.theme;
        const f = self.fraction(cx.app) orelse return div();
        const level = usageLevel(f);
        var chip = div().id("account-usage").relative().flexNone().flex().itemsCenter().gap(px(5)).h(px(24)).px(px(6)).rounded(px(6))
            .textSize(px(11)).textColor(if (level == .normal) theme.text_muted else usageColor(level, theme)).cursorPointer()
            .hover(sb.bg(theme.ink(0.05)))
            .onClick(cx.listener(onToggle))
            .child(chrome.ring(f, usageColor(level, theme), theme.text_faint.opacity(0.25)))
            .child(zpui.fmt("{d}%", .{@as(u32, @intFromFloat(@round(f * 100)))}));
        if (self.open) chip = chip.bg(theme.ink(0.05)).child(anchoredAboveEnd(chrome.frosted(theme, chrome.card_radius, chrome.menu_blur, self.card(cx))));
        return div().flex().itemsCenter().child(chip);
    }
};

/// `anchored_menu_above_end`: opens upward, right-aligned to the trigger.
fn anchoredAboveEnd(content: anytype) zpui.Div {
    return div().absolute().top(px(0)).right(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.bottom_right).snapToWindowWithMargin(.all(8))
            .child(div().occlude().pb(px(6)).child(content)),
    ).withPriority(1));
}

/// The app's one ring view (the main composer's footer).
const Slot = struct { view: ?Entity(AccountUsage) = null };

/// The ring cluster's account half for the composer footer: tracks
/// `harness` / `target` and renders nothing until there is a reading.
pub fn ring(app: *App, state: Entity(model.AppState), harness: ?HarnessId, target: ?[]const u8, theme: *const Theme) ?Entity(AccountUsage) {
    if (!app.hasGlobal(Slot)) app.setGlobal(Slot{}) catch return null;
    const slot = app.globalMut(Slot);
    if (slot.view == null) slot.view = app.newWith(AccountUsage, AccountUsage.init, .{ state, theme.* }) catch return null;
    const v = slot.view.?;
    v.update(app, AccountUsage.track, .{ harness, target, theme });
    return v;
}

// ---- tests (account_usage.rs) --------------------------------------------------------------------

const testing = std.testing;

fn acct(h: HarnessId, id: []const u8, active: bool, used: []const UsageWindow) Account {
    return .{ .id = id, .harness = h, .active = active, .switchable = true, .usageWindows = used };
}

test "ring shows the most used window" {
    try testing.expectEqual(@as(?f32, null), usedFraction(&acct(.codex, "a", true, &.{})));
    const two = [_]UsageWindow{ .{ .label = "5h", .usedFraction = 0.12 }, .{ .label = "5h", .usedFraction = 0.64 } };
    try testing.expectEqual(@as(?f32, 0.64), usedFraction(&acct(.codex, "a", true, &two)));
    const over = [_]UsageWindow{.{ .label = "5h", .usedFraction = 1.4 }};
    try testing.expectEqual(@as(?f32, 1.0), usedFraction(&acct(.codex, "a", true, &over)));
}

test "active account is scoped to the harness; switches stay in their group" {
    const w = [_]UsageWindow{.{ .label = "5h", .usedFraction = 0.3 }};
    var accounts = [_]Account{ acct(.@"claude-code", "c", true, &w), acct(.codex, "x", false, &w), acct(.codex, "y", true, &w) };
    var snap: Snapshot = .{ .accounts = &accounts };
    try testing.expectEqualStrings("y", activeAccount(&snap, .codex).?.id);
    try testing.expect(activeAccount(&snap, .cursor) == null);
    markSwitched(&snap, "x", .codex, null);
    try testing.expectEqualStrings("x", activeAccount(&snap, .codex).?.id);
    try testing.expectEqualStrings("c", activeAccount(&snap, .@"claude-code").?.id);
    try testing.expectEqual(UsageLevel.warn, usageLevel(0.8));
    try testing.expectEqual(UsageLevel.critical, usageLevel(0.95));
}
