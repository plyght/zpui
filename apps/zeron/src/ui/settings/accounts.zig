//! Settings → Providers → (expanded provider) → Accounts (zeron
//! `settings/accounts.rs`, embedded layout): the provider's logins — avatar
//! (accent ring on the live one), email, plan · organization · "In use",
//! two usage meters (indigo → amber ≥80% → red ≥95%; reset times in the
//! tooltip), a `⋯` menu (Switch to this account / Remove account), click a
//! row to switch — then "Connect / Add account" rows per login option, and
//! the one sign-in dialog every provider shares (browser + 1.5s
//! `PollAgentLogin`, Claude's paste-code fallback, Retry / Close / Cancel).
//! Lists are stale-while-revalidate; Switch / Remove are optimistic.
//!
//! RPCs: `ListAgentAccounts{forceUsage}`, `ActivateAgentAccount`,
//! `ForgetAgentAccount`, `StartAgentLogin`, `PollAgentLogin`,
//! `CompleteAgentLogin`, `CancelAgentLogin`.
//!
//! ```zig
//! accounts.ensureFor(view, harness, cx);            // on expand
//! col.child(accounts.embedded(view, harness, t, cx));
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const App = zpui.App;
const Context = zpui.Context;
const Window = zpui.Window;
const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const HarnessId = engine.protocol.HarnessId;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;
const sb = zpui.StyleBuilder.init;
const json = std.json;

// ---- protocol (zeron_proto entities) ------------------------------------------------------

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

pub const Warning = struct { harness: HarnessId, message: []const u8 };
pub const Snapshot = struct { accounts: []Account = &.{}, warnings: []const Warning = &.{} };
pub const LoginStart = struct { loginId: []const u8, url: []const u8, mode: []const u8, callbackPort: ?u16 = null };
pub const LoginPoll = struct { status: []const u8, message: ?[]const u8 = null, url: ?[]const u8 = null, callbackPort: ?u16 = null };

const parse_opts: json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

// ---- pure helpers -----------------------------------------------------------------------

pub const usage_warn_fraction: f32 = 0.80;
pub const usage_critical_fraction: f32 = 0.95;
pub const UsageLevel = enum { normal, warn, critical };

pub fn usageLevel(fraction: f32) UsageLevel {
    if (fraction >= usage_critical_fraction) return .critical;
    if (fraction >= usage_warn_fraction) return .warn;
    return .normal;
}

pub fn usageColor(level: UsageLevel, t: *const Theme) zpui.Hsla {
    return switch (level) {
        .normal => t.accent,
        .warn => t.warning,
        .critical => t.danger,
    };
}

const usage_label_width: f32 = 52;
const usage_bar_width: f32 = 88;
const usage_percent_width: f32 = 34;
const usage_column_width: f32 = usage_label_width + usage_bar_width + usage_percent_width + 16;
const account_action_width: f32 = 112;

pub const LoadTrigger = enum { mount, retry, refresh, post_login, post_action };

pub fn forceUsageFor(trigger: LoadTrigger) bool {
    return trigger != .post_action;
}

/// Only web sign-in pages and loopback callbacks may be opened.
pub fn isOpenableLoginUrl(url: []const u8) bool {
    const sep = std.mem.indexOf(u8, url, "://") orelse return false;
    const scheme = url[0..sep];
    const rest = url[sep + 3 ..];
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(scheme, "http")) return false;
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..auth_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    const host = if (authority.len > 0 and authority[0] == '[')
        (if (std.mem.indexOfScalar(u8, authority, ']')) |e| authority[1..e] else "")
    else
        authority[0 .. std.mem.indexOfScalar(u8, authority, ':') orelse authority.len];
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1");
}

pub const Provider = struct { harness: HarnessId, name: []const u8, command: []const u8 };

pub const providers = [_]Provider{
    .{ .harness = .@"claude-code", .name = "Claude Code", .command = "claude" },
    .{ .harness = .codex, .name = "Codex", .command = "codex" },
    .{ .harness = .cursor, .name = "Cursor", .command = "cursor-agent" },
    .{ .harness = .antigravity, .name = "Antigravity", .command = "Antigravity" },
    .{ .harness = .grok, .name = "Grok", .command = "grok login" },
    .{ .harness = .devin, .name = "Devin", .command = "devin auth login" },
    .{ .harness = .opencode, .name = "OpenCode", .command = "opencode auth login" },
    .{ .harness = .pi, .name = "Pi", .command = "pi" },
    .{ .harness = .hermes, .name = "Hermes", .command = "hermes auth add" },
};

/// Whether `harness` has an Accounts section (and sign-in flow).
pub fn signsIn(h: HarnessId) bool {
    for (providers) |p| if (p.harness == h) return true;
    return false;
}

pub fn providerName(h: HarnessId) []const u8 {
    for (providers) |p| if (p.harness == h) return p.name;
    return "this provider";
}

pub fn reportsUsage(h: HarnessId) bool {
    return h != .antigravity;
}

pub fn keepsOneLogin(h: HarnessId) bool {
    return h == .antigravity;
}

pub fn switchesAccounts(h: HarnessId) bool {
    return h != .hermes and h != .antigravity;
}

pub fn providerNote(h: HarnessId) ?[]const u8 {
    return if (h == .hermes) "Hermes manages its own credential pool and rotates through it. Accounts added here go through `hermes auth add`; remove one with `hermes auth remove`." else null;
}

pub const LoginOption = struct { provider: ?[]const u8, label: []const u8 };

pub fn loginOptions(h: HarnessId) []const LoginOption {
    return switch (h) {
        .opencode => &.{ .{ .provider = "openai", .label = "ChatGPT" }, .{ .provider = "github-copilot", .label = "GitHub Copilot" } },
        .pi => &.{.{ .provider = "openai-codex", .label = "ChatGPT" }},
        .hermes => &.{ .{ .provider = "openai-codex", .label = "ChatGPT" }, .{ .provider = "nous", .label = "Nous Portal" } },
        inline else => |id| &.{.{ .provider = null, .label = comptime providerName(id) }},
    };
}

pub fn addAccountLabel(a: std.mem.Allocator, h: HarnessId, empty: bool) []const u8 {
    if (!empty) return "Add account";
    return std.fmt.allocPrint(a, "Connect a {s} account", .{providerName(h)}) catch "Add account";
}

pub fn addOptionLabel(a: std.mem.Allocator, h: HarnessId, option: LoginOption, empty: bool) []const u8 {
    if (option.provider == null) return addAccountLabel(a, h, empty);
    return (if (empty) std.fmt.allocPrint(a, "Connect {s}", .{option.label}) else std.fmt.allocPrint(a, "Add {s} account", .{option.label})) catch option.label;
}

fn loginCopy(h: HarnessId, provider: ?[]const u8) []const u8 {
    return switch (h) {
        .@"claude-code" => "Finish signing in to Claude in your browser. The new login is saved next to your current one — nothing changes until you switch.",
        .codex => "Finish signing in to ChatGPT in your browser. The new login is saved next to your current one — nothing changes until you switch.",
        .cursor => "Finish signing in to Cursor in your browser. This mints a zeron-named API key you can revoke any time from Cursor's dashboard.",
        .antigravity => "Finish signing in to Google in your browser. Antigravity keeps one login on this device; if it is already signed in, this just confirms it.",
        .grok => "Finish signing in to Grok in your browser — approve the code shown below. The new login is saved next to your current one — nothing changes until you switch.",
        .devin => "Finish signing in to Devin in your browser. The new login is saved next to your current one — nothing changes until you switch.",
        .opencode => if (provider != null and std.mem.eql(u8, provider.?, "github-copilot"))
            "Finish signing in to GitHub in your browser — enter the code shown below. The new login is saved next to your current one — nothing changes until you switch."
        else
            "Finish signing in to ChatGPT in your browser. The agent gets its own login, saved next to any current one — nothing changes until you switch.",
        .pi => "Finish signing in to ChatGPT in your browser. The agent gets its own login, saved next to any current one — nothing changes until you switch.",
        .hermes => "Finish signing in in your browser — enter the code shown below. Hermes adds the login to its own credential pool and rotates through it itself.",
        else => "Finish signing in in your browser.",
    };
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The optimistic half of a switch: `account` becomes its group's live login.
pub fn markSwitched(snapshot: *Snapshot, account: *const Account) void {
    for (snapshot.accounts) |*row| if (row.harness == account.harness and eqlOpt(row.provider, account.provider)) {
        row.active = std.mem.eql(u8, row.id, account.id);
    };
}

/// `format_reset` with explicit seconds (`now_s`, the reset as an RFC 3339 string).
pub fn formatReset(a: std.mem.Allocator, resets_at: ?[]const u8, now_s: i64, offset_minutes: i32) ?[]const u8 {
    const at = parseRfc3339(resets_at orelse return null) orelse return null;
    const local = at + @as(i64, offset_minutes) * 60;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(local, 0)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const hours_ahead = @divTrunc(at - now_s, 3600);
    if (hours_ahead < 22) {
        const h24 = ds.getHoursIntoDay();
        const h12: u8 = if (h24 % 12 == 0) 12 else @intCast(h24 % 12);
        return std.fmt.allocPrint(a, "resets {d}:{d:0>2} {s}", .{ h12, ds.getMinutesIntoHour(), if (h24 < 12) "AM" else "PM" }) catch null;
    }
    if (hours_ahead < 24 * 7) {
        const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        return std.fmt.allocPrint(a, "resets {s}", .{names[@intCast(@mod(day.day, 7))]}) catch null;
    }
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.allocPrint(a, "resets {s} {d}", .{ months[md.month.numeric() - 1], md.day_index + 1 }) catch null;
}

/// RFC 3339 → epoch seconds (UTC offsets honoured; fractional seconds ignored).
pub fn parseRfc3339(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const dayn = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) days += if (std.time.epoch.isLeapYear(@intCast(y))) 366 else 365;
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(m));
    days += dayn - 1;
    var secs = days * 86400 + hh * 3600 + mm * 60 + ss;
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        rest = rest[i..];
    }
    if (rest.len >= 6 and (rest[0] == '+' or rest[0] == '-')) {
        const oh = std.fmt.parseInt(i64, rest[1..3], 10) catch 0;
        const om = std.fmt.parseInt(i64, rest[4..6], 10) catch 0;
        const off = oh * 3600 + om * 60;
        secs = if (rest[0] == '+') secs - off else secs + off;
    }
    return secs;
}

// ---- state ------------------------------------------------------------------------------

const LoginStep = union(enum) {
    browser: ?[]u8,
    paste_code: struct { submitting: bool = false, err: ?[]u8 = null },
    failed: []u8,
};

pub const LoginFlow = struct {
    harness: HarnessId,
    provider: ?[]const u8,
    attempt: u64,
    login_id: ?[]u8 = null,
    url: ?[]u8 = null,
    step: LoginStep = .{ .browser = null },

    fn freeStep(self: *LoginFlow, gpa: std.mem.Allocator) void {
        switch (self.step) {
            .browser => |m| if (m) |x| gpa.free(x),
            .paste_code => |p| if (p.err) |x| gpa.free(x),
            .failed => |m| gpa.free(m),
        }
        self.step = .{ .browser = null };
    }

    fn deinit(self: *LoginFlow, gpa: std.mem.Allocator) void {
        self.freeStep(gpa);
        if (self.login_id) |x| gpa.free(x);
        if (self.url) |x| gpa.free(x);
    }

    pub fn title(self: *const LoginFlow, a: std.mem.Allocator) []const u8 {
        for (loginOptions(self.harness)) |o| if (o.provider != null and eqlOpt(o.provider, self.provider)) {
            return std.fmt.allocPrint(a, "Sign in to {s} for {s}", .{ o.label, providerName(self.harness) }) catch "Sign in";
        };
        return std.fmt.allocPrint(a, "Sign in to {s}", .{providerName(self.harness)}) catch "Sign in";
    }

    pub fn status(self: *const LoginFlow) []const u8 {
        return switch (self.step) {
            .browser => |m| m orelse (if (self.url != null) "Waiting for you to finish in the browser…" else "Starting sign-in…"),
            else => "Starting sign-in…",
        };
    }
};

pub const State = struct {
    harness: ?HarnessId = null,
    phase: enum { idle, loading, ready, failed } = .idle,
    snapshot: ?json.Parsed(Snapshot) = null,
    load_error: ?[]u8 = null,
    refreshing: bool = false,
    /// Loads in flight; only the last one's reply counts.
    load_seq: u64 = 0,
    busy_account: ?[]u8 = null,
    row_menu: ?[]u8 = null,
    login: ?LoginFlow = null,
    login_attempts: u64 = 0,
    err: ?[]u8 = null,
    code_input: ?zpui.Entity(input.TextInput) = null,
    code_sub: ?zpui.Subscription = null,
    poll_timer: zpui.Task(void) = .none,
    /// The previous list, restored when an optimistic action is refused.
    previous: ?json.Parsed(Snapshot) = null,

    pub fn deinit(self: *State, gpa: std.mem.Allocator, app: *App) void {
        if (self.snapshot) |*p| p.deinit();
        if (self.previous) |*p| p.deinit();
        if (self.load_error) |e| gpa.free(e);
        if (self.busy_account) |e| gpa.free(e);
        if (self.row_menu) |e| gpa.free(e);
        if (self.err) |e| gpa.free(e);
        if (self.login) |*l| l.deinit(gpa);
        if (self.code_sub) |*s| s.deinit();
        if (self.code_input) |i| i.release(app);
        self.poll_timer.cancel();
    }
};

fn setOwned(gpa: std.mem.Allocator, slot: *?[]u8, value: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value) |v| gpa.dupe(u8, v) catch null else null;
}

fn engineOf(v: *SettingsView, cx: anytype) zpui.Entity(model.EngineState) {
    return v.state.read(cx).catalog.read(cx).engine;
}

fn openLoginUrl(app: *App, url: []const u8) void {
    if (isOpenableLoginUrl(url)) app.platform.vtable.openUrl(app.platform.ptr, url);
}

/// The expanded provider changed: follow it (`set_embedded_harness`), loading once.
pub fn ensureFor(v: *SettingsView, h: HarnessId, cx: *Context(SettingsView)) void {
    if (!signsIn(h)) return;
    if (v.accounts.harness != h) {
        v.accounts.harness = h;
        if (v.accounts.login) |*l| l.deinit(v.gpa);
        v.accounts.login = null;
        setOwned(v.gpa, &v.accounts.err, null);
    }
    if (v.accounts.phase == .idle) load(v, forceUsageFor(.mount), cx);
}

const ListParams = struct { forceUsage: bool };

/// `load`: stale-while-revalidate list (`ListAgentAccounts`).
pub fn load(v: *SettingsView, force_usage: bool, cx: *Context(SettingsView)) void {
    const st = &v.accounts;
    if (st.phase != .ready) st.phase = .loading;
    st.refreshing = true;
    st.load_seq += 1;
    model.EngineState.request(engineOf(v, cx), cx, SettingsView, cx.entityId(), .ListAgentAccounts, ListParams{ .forceUsage = force_usage }, onList) catch {
        st.refreshing = false;
        if (st.phase != .ready) {
            st.phase = .failed;
            setOwned(v.gpa, &st.load_error, "Engine not connected");
        }
    };
    cx.notify();
}

fn adopt(v: *SettingsView, val: json.Value, app: *App) bool {
    const parsed = json.parseFromValue(Snapshot, v.gpa, val, parse_opts) catch return false;
    // Share the list with the composer's plan-usage ring (`AccountsSnapshotCache`).
    _ = @import("zeron_composer").account_usage.publish(app, null, val);
    return adoptParsed(v, parsed);
}

fn adoptParsed(v: *SettingsView, parsed: json.Parsed(Snapshot)) bool {
    if (v.accounts.snapshot) |*p| p.deinit();
    v.accounts.snapshot = parsed;
    v.accounts.phase = .ready;
    return true;
}

fn onList(v: *SettingsView, result: model.engine_state.CallResult, cx: *Context(SettingsView)) void {
    const st = &v.accounts;
    st.refreshing = false;
    switch (result) {
        .ok => |val| if (!adopt(v, val, cx.app)) {
            if (st.phase != .ready) st.phase = .failed;
            setOwned(v.gpa, if (st.phase == .ready) &st.err else &st.load_error, "malformed reply");
        },
        .err => |e| if (st.phase == .ready) setOwned(v.gpa, &st.err, e.message) else {
            st.phase = .failed;
            setOwned(v.gpa, &st.load_error, e.message);
        },
    }
    cx.notify();
}

const AccountParams = struct { id: []const u8, accountId: []const u8, harness: HarnessId };

/// Switch / Forget, optimistically (`account_action`).
pub fn accountAction(v: *SettingsView, activate: bool, account_id: []const u8, cx: *Context(SettingsView)) void {
    const st = &v.accounts;
    const snap = if (st.snapshot) |*p| p else return;
    var target: ?Account = null;
    for (snap.value.accounts) |a| if (std.mem.eql(u8, a.id, account_id)) {
        target = a;
    };
    const account = target orelse return;
    // Keep the pre-action list to restore on refusal (a re-parse of the current one).
    if (st.previous) |*p| p.deinit();
    st.previous = cloneSnapshot(v.gpa, snap.value);
    if (activate) {
        markSwitched(&snap.value, &account);
    } else {
        var n: usize = 0;
        for (snap.value.accounts) |a| if (!std.mem.eql(u8, a.id, account_id)) {
            snap.value.accounts[n] = a;
            n += 1;
        };
        snap.value.accounts = snap.value.accounts[0..n];
    }
    setOwned(v.gpa, &st.busy_account, account_id);
    setOwned(v.gpa, &st.err, null);
    const method: engine.Method = if (activate) .ActivateAgentAccount else .ForgetAgentAccount;
    model.EngineState.request(engineOf(v, cx), cx, SettingsView, cx.entityId(), method, AccountParams{ .id = account.id, .accountId = account.id, .harness = account.harness }, onAction) catch |err| {
        restorePrevious(v);
        setOwned(v.gpa, &st.busy_account, null);
        setOwned(v.gpa, &st.err, if (err == error.NotConnected) "Engine not connected" else @errorName(err));
    };
    cx.notify();
}

fn cloneSnapshot(gpa: std.mem.Allocator, s: Snapshot) ?json.Parsed(Snapshot) {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    json.Stringify.value(s, .{}, &aw.writer) catch return null;
    return json.parseFromSlice(Snapshot, gpa, aw.written(), parse_opts) catch null;
}

fn restorePrevious(v: *SettingsView) void {
    const prev = v.accounts.previous orelse return;
    if (v.accounts.snapshot) |*p| p.deinit();
    v.accounts.snapshot = prev;
    v.accounts.previous = null;
}

fn onAction(v: *SettingsView, result: model.engine_state.CallResult, cx: *Context(SettingsView)) void {
    const st = &v.accounts;
    setOwned(v.gpa, &st.busy_account, null);
    switch (result) {
        // The reply is the fresh list; an older engine's bare reply → refetch.
        .ok => |val| if (!adopt(v, val, cx.app)) load(v, forceUsageFor(.post_action), cx),
        .err => |e| {
            restorePrevious(v);
            setOwned(v.gpa, &st.err, e.message);
        },
    }
    if (st.previous) |*p| {
        p.deinit();
        st.previous = null;
    }
    cx.notify();
}

// ---- sign-in -----------------------------------------------------------------------------

const StartParams = struct { harness: HarnessId, provider: ?[]const u8 = null };
const LoginIdParams = struct { loginId: []const u8 };
const CodeParams = struct { loginId: []const u8, code: []const u8 };

fn currentAttempt(v: *SettingsView, attempt: u64) ?*LoginFlow {
    const l = if (v.accounts.login) |*x| x else return null;
    return if (l.attempt == attempt) l else null;
}

/// `start_login` (and Retry).
pub fn startLogin(v: *SettingsView, h: HarnessId, provider: ?[]const u8, cx: *Context(SettingsView)) void {
    const st = &v.accounts;
    st.login_attempts += 1;
    if (st.login) |*l| l.deinit(v.gpa);
    st.login = .{ .harness = h, .provider = provider, .attempt = st.login_attempts };
    st.poll_timer.cancel();
    st.poll_timer = .none;
    setOwned(v.gpa, &st.err, null);
    model.EngineState.request(engineOf(v, cx), cx, SettingsView, cx.entityId(), .StartAgentLogin, StartParams{ .harness = h, .provider = provider }, onStart) catch |err| {
        failLogin(v, st.login_attempts, "Couldn't start the sign-in: {s}", .{if (err == error.NotConnected) "Engine not connected" else @errorName(err)});
    };
    cx.notify();
}

fn failLogin(v: *SettingsView, attempt: u64, comptime fmt: []const u8, args: anytype) void {
    const l = currentAttempt(v, attempt) orelse return;
    l.freeStep(v.gpa);
    l.step = .{ .failed = std.fmt.allocPrint(v.gpa, fmt, args) catch @constCast("The sign-in failed.") };
}

fn onStart(v: *SettingsView, result: model.engine_state.CallResult, cx: *Context(SettingsView)) void {
    const attempt = v.accounts.login_attempts;
    const l = currentAttempt(v, attempt) orelse return;
    switch (result) {
        .ok => |val| {
            const parsed = json.parseFromValue(LoginStart, v.gpa, val, parse_opts) catch {
                failLogin(v, attempt, "Couldn't start the sign-in: {s}", .{"malformed reply"});
                return cx.notify();
            };
            defer parsed.deinit();
            const start = parsed.value;
            if (start.url.len > 0) {
                openLoginUrl(cx.app, start.url);
                setOwned(v.gpa, &l.url, start.url);
            }
            setOwned(v.gpa, &l.login_id, start.loginId);
            if (std.mem.eql(u8, start.mode, "paste-code")) {
                l.freeStep(v.gpa);
                l.step = .{ .paste_code = .{} };
                const field = ensureCodeInput(v, cx);
                field.update(cx, input.TextInput.setText, .{""});
            } else schedulePoll(v, cx);
        },
        .err => |e| failLogin(v, attempt, "Couldn't start the sign-in: {s}", .{e.message}),
    }
    cx.notify();
}

fn ensureCodeInput(v: *SettingsView, cx: *Context(SettingsView)) zpui.Entity(input.TextInput) {
    if (v.accounts.code_input) |i| return i;
    const theme = ui.theme.get(cx).forPopup();
    const field = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
        .placeholder = "Paste the authorization code",
        .single_line = true,
        .edge_fade = false,
        .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
    }}) catch @panic("OOM");
    v.accounts.code_input = field;
    v.accounts.code_sub = cx.subscribe(field, onCodeInput) catch null;
    return field;
}

fn onCodeInput(v: *SettingsView, _: zpui.Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(SettingsView)) void {
    if (ev.* == .submitted) submitCode(v, cx);
}

/// `submit_code`: Claude's paste-code fallback.
pub fn submitCode(v: *SettingsView, cx: *Context(SettingsView)) void {
    const l = if (v.accounts.login) |*x| x else return;
    const login_id = l.login_id orelse return;
    if (l.step != .paste_code or l.step.paste_code.submitting) return;
    const field = v.accounts.code_input orelse return;
    const code = std.mem.trim(u8, field.read(cx).text(), " \t\r\n");
    if (code.len == 0) return;
    l.step.paste_code.submitting = true;
    model.EngineState.request(engineOf(v, cx), cx, SettingsView, cx.entityId(), .CompleteAgentLogin, CodeParams{ .loginId = login_id, .code = code }, onCompleted) catch {
        l.step.paste_code.submitting = false;
    };
    cx.notify();
}

fn onCompleted(v: *SettingsView, result: model.engine_state.CallResult, cx: *Context(SettingsView)) void {
    const l = currentAttempt(v, v.accounts.login_attempts) orelse return;
    switch (result) {
        .ok => {
            l.deinit(v.gpa);
            v.accounts.login = null;
            load(v, forceUsageFor(.post_login), cx);
        },
        .err => |e| {
            l.freeStep(v.gpa);
            l.step = .{ .paste_code = .{ .err = v.gpa.dupe(u8, e.message) catch null } };
        },
    }
    cx.notify();
}

fn schedulePoll(v: *SettingsView, cx: *Context(SettingsView)) void {
    v.accounts.poll_timer.cancel();
    v.accounts.poll_timer = cx.timer(1500 * std.time.ns_per_ms, onPollTimer) catch .none;
}

fn onPollTimer(v: *SettingsView, cx: *Context(SettingsView)) void {
    v.accounts.poll_timer.detach();
    v.accounts.poll_timer = .none;
    const l = if (v.accounts.login) |*x| x else return;
    const id = l.login_id orelse return;
    model.EngineState.request(engineOf(v, cx), cx, SettingsView, cx.entityId(), .PollAgentLogin, LoginIdParams{ .loginId = id }, onPoll) catch |err| {
        failLogin(v, l.attempt, "Lost track of the sign-in: {s}", .{@errorName(err)});
        cx.notify();
    };
}

/// `apply_poll`: every ending shows the account or an error — never a silent reset.
fn onPoll(v: *SettingsView, result: model.engine_state.CallResult, cx: *Context(SettingsView)) void {
    const attempt = v.accounts.login_attempts;
    const l = currentAttempt(v, attempt) orelse return;
    switch (result) {
        .ok => |val| {
            const parsed = json.parseFromValue(LoginPoll, v.gpa, val, parse_opts) catch {
                failLogin(v, attempt, "Lost track of the sign-in: {s}", .{"malformed reply"});
                return cx.notify();
            };
            defer parsed.deinit();
            const poll = parsed.value;
            if (std.mem.eql(u8, poll.status, "done")) {
                l.deinit(v.gpa);
                v.accounts.login = null;
                load(v, forceUsageFor(.post_login), cx);
            } else if (std.mem.eql(u8, poll.status, "error")) {
                failLogin(v, attempt, "{s}", .{poll.message orelse "The sign-in failed."});
            } else {
                if (poll.url) |u| if (!eqlOpt(l.url, u)) {
                    openLoginUrl(cx.app, u);
                    setOwned(v.gpa, &l.url, u);
                };
                l.freeStep(v.gpa);
                l.step = .{ .browser = if (poll.message) |m| v.gpa.dupe(u8, m) catch null else null };
                schedulePoll(v, cx);
            }
        },
        .err => |e| failLogin(v, attempt, "Lost track of the sign-in: {s}", .{e.message}),
    }
    cx.notify();
}

/// `cancel_login` (also Close after a failure).
pub fn cancelLogin(v: *SettingsView, cx: *Context(SettingsView)) void {
    var l = v.accounts.login orelse return;
    v.accounts.login = null;
    v.accounts.poll_timer.cancel();
    v.accounts.poll_timer = .none;
    if (l.step != .failed) if (l.login_id) |id| {
        model.EngineState.send(engineOf(v, cx), cx, .CancelAgentLogin, LoginIdParams{ .loginId = id }) catch {};
    };
    l.deinit(v.gpa);
    cx.notify();
}

pub fn dismissOnEscape(v: *SettingsView, cx: *Context(SettingsView)) bool {
    if (v.accounts.login == null) return false;
    cancelLogin(v, cx);
    return true;
}

// ---- listeners ----------------------------------------------------------------------------

const AddPick = struct { option: u8 };

fn onAdd(v: *SettingsView, pick: AddPick, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const h = v.accounts.harness orelse return;
    const opts = loginOptions(h);
    if (pick.option >= opts.len) return;
    startLogin(v, h, opts[pick.option].provider, cx);
}

fn onRefresh(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    load(v, forceUsageFor(.refresh), cx);
}

fn onRetryLoad(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    load(v, forceUsageFor(.retry), cx);
}

fn onDismissError(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    setOwned(v.gpa, &v.accounts.err, null);
    cx.notify();
}

fn rowAccount(v: *SettingsView, ix: usize) ?Account {
    const snap = v.accounts.snapshot orelse return null;
    const h = v.accounts.harness orelse return null;
    var n: usize = 0;
    for (snap.value.accounts) |a| if (a.harness == h) {
        if (n == ix) return a;
        n += 1;
    };
    return null;
}

fn onRowClick(v: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const a = rowAccount(v, ix) orelse return;
    if (a.active or !a.switchable) return;
    const id = v.gpa.dupe(u8, a.id) catch return;
    defer v.gpa.free(id);
    accountAction(v, true, id, cx);
}

fn onMore(v: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    cx.stopPropagation();
    const a = rowAccount(v, ix) orelse return;
    const open = if (v.accounts.row_menu) |m| std.mem.eql(u8, m, a.id) else false;
    setOwned(v.gpa, &v.accounts.row_menu, if (open) null else a.id);
    cx.notify();
}

fn onMenuOutside(v: *SettingsView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    setOwned(v.gpa, &v.accounts.row_menu, null);
    cx.notify();
}

const MenuPick = struct { ix: u16, activate: bool };

fn onMenuPick(v: *SettingsView, pick: MenuPick, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    cx.stopPropagation();
    setOwned(v.gpa, &v.accounts.row_menu, null);
    const a = rowAccount(v, pick.ix) orelse return;
    const id = v.gpa.dupe(u8, a.id) catch return;
    defer v.gpa.free(id);
    accountAction(v, pick.activate, id, cx);
}

fn onCancel(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    cancelLogin(v, cx);
}

fn onRetryLogin(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const l = v.accounts.login orelse return;
    startLogin(v, l.harness, l.provider, cx);
}

fn onSubmitCode(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    submitCode(v, cx);
}

fn onReopen(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const l = v.accounts.login orelse return;
    if (l.url) |u| openLoginUrl(cx.app, u);
}

// ---- rendering ----------------------------------------------------------------------------

fn usageMeter(win: UsageWindow, t: *const Theme) zpui.Div {
    const fraction = std.math.clamp(win.usedFraction, 0, 1);
    const level = usageLevel(fraction);
    const fill = usageColor(level, t).opacity(if (level == .normal) 0.8 else 0.9);
    var bar = div().w(px(usage_bar_width)).flexNone().h(px(4)).roundedFull().overflowHidden().bg(t.wash(0.08));
    if (fraction > 0) bar = bar.child(div().hFull().w(zpui.relative(@max(fraction, 0.015))).roundedFull().bg(fill));
    return div().h(px(16)).flex().flexRow().itemsCenter().gap(px(8)).textSize(rems(11.5))
        .child(div().w(px(usage_label_width)).flexNone().truncate().textColor(t.text_muted).child(win.label))
        .child(bar)
        .child(div().w(px(usage_percent_width)).flexNone().textRight().textColor(if (level == .normal) t.text_muted else usageColor(level, t))
        .child(zpui.fmt("{d}%", .{@as(u32, @intFromFloat(@round(fraction * 100)))})));
}

fn usageMissing(v: *SettingsView, a: *const Account) ?[]const u8 {
    if (!reportsUsage(a.harness)) return null;
    if (!a.switchable and switchesAccounts(a.harness)) return if (a.harness == .@"claude-code") "Credentials unavailable" else "Couldn't identify this login";
    if (a.usageError) |e| return e;
    return if (v.accounts.refreshing) "Checking usage…" else "Usage unavailable";
}

fn accountRow(v: *SettingsView, a: *const Account, ix: usize, first: bool, t: *const Theme, now_s: i64, cx: *Context(SettingsView)) zpui.Div {
    const fa = zpui.window.arena_mod.frameAllocator();
    const email = a.email orelse a.displayName orelse "Unknown account";
    const can_switch = !a.active and a.switchable;
    var meta: std.ArrayList(w.Fragment) = .empty;
    if (a.planLabel) |p| meta.append(fa, .{ .text = p }) catch {};
    if (a.organization) |org| if (a.email == null or !std.mem.startsWith(u8, org, a.email.?)) meta.append(fa, .{ .text = org }) catch {};
    if (a.active) meta.append(fa, .{ .text = "In use", .color = t.accent }) catch {};
    const usage: zpui.Div = if (a.usageWindows.len == 0) blk: {
        if (usageMissing(v, a)) |note| meta.append(fa, .{ .text = note }) catch {};
        break :blk div().w(px(usage_column_width)).flexNone();
    } else blk: {
        var col = div().w(px(usage_column_width)).flexNone().flex().flexCol().gap(px(2));
        for (a.usageWindows[0..@min(2, a.usageWindows.len)]) |uw| col = col.child(usageMeter(uw, t));
        break :blk col;
    };
    var resets: std.ArrayList(u8) = .empty;
    for (a.usageWindows, 0..) |uw, i| {
        if (i > 0) resets.appendSlice(fa, " · ") catch {};
        if (formatReset(fa, uw.resetsAt, now_s, 0)) |r| resets.print(fa, "{s}: {s}", .{ uw.label, r }) catch {} else resets.appendSlice(fa, uw.label) catch {};
    }
    const initial: []const u8 = if (email.len > 0) zpui.fmt("{c}", .{std.ascii.toUpper(email[0])}) else "?";
    const avatar = div().flexNone().size(px(32)).roundedFull().border(px(1.5)).borderColor(if (a.active) t.accent else zpui.hsla(0, 0, 0, 0))
        .flex().itemsCenter().justifyCenter()
        .child(div().size(px(25)).roundedFull().bg(t.wash(0.09)).flex().itemsCenter().justifyCenter()
        .textSize(rems(11.5)).fontWeight(500).textColor(if (a.active) t.text else t.text_muted).child(initial));
    const menu_open = if (v.accounts.row_menu) |m| std.mem.eql(u8, m, a.id) else false;
    var more = w.actionButton(t, .quiet).id(.{ "account-more", ix }).role(.button).ariaLabel(zpui.fmt("Actions for {s}", .{email})).ariaExpanded(menu_open).w(px(28)).px(px(0)).justifyCenter().relative()
        .onClick(cx.listenerWith(ix, onMore))
        .child(ui.icon.of(.more_horizontal, 16, t.text_muted));
    if (menu_open) {
        const pt_val = t.forPopup();
        const pt = &pt_val;
        var menu = ui.popover.card(pt).w(px(208)).flex().flexCol().onMouseDownOut(cx.listener(onMenuOutside));
        const i: u16 = @intCast(ix);
        if (can_switch) menu = menu.child(ui.popover.menuRow(pt, false).id(.{ "account-menu-switch", ix }).role(.menu_item)
            .onClick(cx.listenerWith(MenuPick{ .ix = i, .activate = true }, onMenuPick)).child("Switch to this account"));
        if (a.switchable) menu = menu.child(ui.popover.menuRow(pt, false).id(.{ "account-menu-remove", ix }).role(.menu_item).textColor(pt.danger_muted)
            .onClick(cx.listenerWith(MenuPick{ .ix = i, .activate = false }, onMenuPick)).child("Remove account"));
        more = more.bg(t.glassHover()).child(div().absolute().top(zpui.relative(1)).right(px(0)).child(zpui.deferred(
            zpui.anchored().anchorCorner(.top_right).snapToWindowWithMargin(.all(8))
                .child(ui.anim.menuIn("account-menu", div().occlude().pt(px(6)).child(ui.popover.frostedCard(menu)), -2)),
        ).withPriority(1)));
    }
    const hover_key = zpui.fmt("account-row-{d}-hover", .{ix});
    var body = div().id(.{ "account-row", ix }).mx(px(-10)).px(px(10)).py(px(10)).minH(px(56)).rounded(px(10))
        .flex().flexRow().itemsCenter().gap(px(14))
        .child(avatar)
        .child(div().flex1().minW0().child(w.rowTitle(t, email).truncate()).child(if (meta.items.len > 0) w.metaLine(t, meta.items) else div()))
        .child(if (resets.items.len > 0) div().id(.{ "account-usage", ix }).child(usage).tooltipWith(@as([]const u8, resets.items), ui.tooltip.build) else div().id(.{ "account-usage", ix }).child(usage))
        .child(div().w(px(28)).flexNone().child(if (a.switchable) more else div().id(.{ "account-more", ix })));
    if (can_switch) body = body.cursorPointer().bg(ui.hover.blend(cx, hover_key, t.wash(0), t.wash(0.04)))
        .onHover(cx.listenerWith(ix, onRowHover))
        .onClick(cx.listenerWith(ix, onRowClick));
    var row = div().py(px(2)).child(body);
    if (!first) row = row.borderT1().borderColor(w.rowDivider(t));
    return row;
}

fn onRowHover(_: *SettingsView, ix: usize, hovered: *const bool, _: *Window, cx: *Context(SettingsView)) void {
    ui.hover.set(cx, zpui.fmt("account-row-{d}-hover", .{ix}), hovered.*);
}

fn skeleton(t: *const Theme) zpui.Div {
    const ghost = struct {
        fn f(th: *const Theme, wd: f32, h: f32) zpui.Div {
            return div().flexNone().w(px(wd)).h(px(h)).rounded(px(4)).bg(th.wash(0.07));
        }
    }.f;
    var out = div().opacity(0.72);
    for (0..2) |i| {
        var meters = div().w(px(usage_column_width)).flexNone().flex().flexCol().gap(px(8));
        for (0..2) |_| meters = meters.child(div().flex().flexRow().itemsCenter().gap(px(8))
            .child(ghost(t, usage_label_width - 12, 8)).child(div().w(px(usage_bar_width)).h(px(4)).roundedFull().bg(t.wash(0.06))));
        var row = div().minH(px(56)).py(px(10)).flex().flexRow().itemsCenter().gap(px(16))
            .child(div().flex1().flex().flexCol().gap(px(6)).child(ghost(t, 176, 11)).child(ghost(t, 48, 9)))
            .child(meters).child(div().w(px(account_action_width)).flexNone());
        if (i > 0) row = row.borderT1().borderColor(w.rowDivider(t)).opacity(0.6);
        out = out.child(row);
    }
    return out;
}

/// The expanded provider's Accounts block (`render_embedded_provider`).
pub fn embedded(v: *SettingsView, h: HarnessId, t: *const Theme, now_s: i64, cx: *Context(SettingsView)) zpui.StatefulDiv {
    const fa = zpui.window.arena_mod.frameAllocator();
    const st = &v.accounts;
    const refreshing = st.refreshing or st.phase == .loading;
    const content: zpui.AnyElement = switch (st.phase) {
        .idle, .loading => zpui.intoAnyElement(skeleton(t)),
        .failed => zpui.intoAnyElement(w.errorStrip(t, st.load_error orelse "Couldn't load accounts").mt(px(4)).id("accounts-inline-retry").role(.button).ariaLabel("Retry loading accounts").cursorPointer()
            .onClick(cx.listener(onRetryLoad)).child(div().flex1()).child(div().flexNone().textColor(t.text_muted).child("Retry"))),
        .ready => blk: {
            var col = div().flex().flexCol();
            var n: usize = 0;
            if (st.snapshot) |snap| for (snap.value.accounts) |*a| if (a.harness == h) {
                col = col.child(accountRow(v, a, n, n == 0, t, now_s, cx));
                n += 1;
            };
            const empty = n == 0;
            if (empty or !keepsOneLogin(h)) {
                var adds = div().py(px(8)).flex().flexRow().flexWrap().gap(px(4));
                if (!empty) adds = adds.borderT1().borderColor(w.rowDivider(t));
                for (loginOptions(h), 0..) |o, i| {
                    var b = w.actionButton(t, .quiet).id(.{ "accounts-add", i }).role(.button).onClick(cx.listenerWith(AddPick{ .option = @intCast(i) }, onAdd))
                        .child(ui.icon.of(.plus, 14, t.text_muted)).child(addOptionLabel(fa, h, o, empty));
                    if (i == 0) b = b.ml(px(-10));
                    adds = adds.child(b);
                }
                col = col.child(adds);
            }
            break :blk zpui.intoAnyElement(col);
        },
    };
    var refresh = w.actionButton(t, .quiet).id("accounts-refresh").role(.button).ariaLabel("Refresh accounts").mr(px(-8)).w(px(32)).px(px(0)).justifyCenter()
        .onClick(cx.listener(onRefresh)).child(ui.icon.of(.refresh, 14, t.text_muted));
    if (refreshing) refresh = refresh.opacity(0.5);
    var header = div().flex().flexRow().itemsCenter().gap(px(4))
        .child(div().minH(px(32)).flex().flexRow().itemsCenter().textSize(rems(13)).lineHeight(rems(17)).textColor(t.text_muted).child("Accounts"));
    if (st.refreshing and st.phase == .ready) header = header.child(div().ml(px(6)).flexNone().child(ui.loaders.miniGlyphSpinner(1.5, t.glyph.rows(), ui.loaders.phaseOf(cx, @import("zeron_theme").motion.gradient_spin))));
    header = header.child(div().flex1()).child(refresh);
    var block = div().id("accounts-embedded").wFull().minW0().flex().flexCol().child(header);
    if (st.err) |e| block = block.child(w.errorStrip(t, e).mt(px(4)).id("accounts-action-error").role(.button).ariaLabel("Dismiss account error").cursorPointer().onClick(cx.listener(onDismissError)));
    if (st.phase == .ready) if (st.snapshot) |snap| for (snap.value.warnings) |warn| if (warn.harness == h) {
        block = block.child(div().mt(px(4)).px(px(16)).py(px(10)).rounded(px(12)).border1().borderColor(t.warning.opacity(0.2)).bg(t.warning.opacity(0.06))
            .textSize(rems(12.5)).textColor(t.warning).child(warn.message));
    };
    if (providerNote(h)) |note| block = block.child(div().mt(px(4)).textSize(rems(12)).textColor(t.text_muted).child(note));
    return block.child(content);
}

/// The sign-in dialog (`render_login_dialog`), mounted by the view.
pub fn loginDialog(v: *SettingsView, window: *Window, cx: *Context(SettingsView)) ?zpui.AnyElement {
    const l = v.accounts.login orelse return null;
    const fa = zpui.window.arena_mod.frameAllocator();
    const t_val = ui.theme.get(cx).forPopup();
    const t = &t_val;
    const red = t.danger_muted.opacity(0.9);
    const failed = l.step == .failed;
    const copy = if (l.step == .paste_code)
        "Your browser opened Claude's sign-in page. Approve access, then paste the code Anthropic shows you below. Your current login is untouched until you switch."
    else
        loginCopy(l.harness, l.provider);
    var card = dialog.card(t).id("add-account-card").role(.dialog).ariaLabel(l.title(fa))
        .child(dialog.title(t, l.title(fa)))
        .child(div().mt(px(8)).child(dialog.body(t, copy)));
    if (l.url != null and !failed) card = card.child(div().id("login-open-url").role(.button).mt(px(6)).textSize(rems(12)).textColor(t.text_muted).truncate()
        .cursorPointer().hover(sb.textColor(t.text)).onClick(cx.listener(onReopen)).child("Reopen the sign-in page"));
    switch (l.step) {
        .browser => {
            card = card.child(div().mt(px(16)).flex().flexRow().itemsCenter().gap(px(8))
                .child(ui.loaders.gradientSpinner(3, ui.loaders.phaseOf(cx, @import("zeron_theme").motion.gradient_spin)))
                .child(div().textSize(rems(12.5)).textColor(t.text_muted).child(l.status())));
            window.requestAnimationFrame();
        },
        .paste_code => |p| {
            var col = div().mt(px(12)).flex().flexCol().gap(px(8))
                .child(div().wFull().px(px(12)).py(px(8)).rounded(px(8)).border1().borderColor(t.hairline(0.08)).bg(t.ink(0.04))
                .fontFamily(t.font_mono).textSize(rems(13)).child(v.accounts.code_input.?));
            if (p.err) |e| col = col.child(div().textSize(rems(12)).textColor(red).child(e));
            card = card.child(col);
        },
        .failed => |m| card = card.child(div().mt(px(16)).child(div().textSize(rems(12)).textColor(red).child(m))),
    }
    var buttons = div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8));
    switch (l.step) {
        .browser => buttons = buttons.child(w.textAction(t, .quiet, "Cancel").id("login-cancel").role(.button).onClick(cx.listener(onCancel))),
        .paste_code => |p| {
            var submit = w.textAction(t, .solid, if (p.submitting) "Verifying…" else "Add account").id("login-submit-code").role(.button).onClick(cx.listener(onSubmitCode));
            if (p.submitting) submit = submit.opacity(0.5);
            buttons = buttons.child(w.textAction(t, .quiet, "Cancel").id("login-cancel").role(.button).onClick(cx.listener(onCancel))).child(submit);
        },
        .failed => buttons = buttons.child(w.textAction(t, .quiet, "Close").id("login-cancel").role(.button).onClick(cx.listener(onCancel)))
            .child(w.textAction(t, .solid, "Retry").id("login-retry").role(.button).onClick(cx.listener(onRetryLogin))),
    }
    card = card.child(buttons);
    const vp = window.viewportSize();
    return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 }).child(
        div().id("add-account-dialog").occlude().w(px(vp.width)).h(px(vp.height)).bg(zpui.color.black.alpha(0.35))
            .flex().itemsCenter().justifyCenter()
            .child(ui.anim.menuIn("add-account-dialog", div().child(ui.effects.frosted(16, @import("zeron_theme").layout.menu_blur, card)), 2)),
    )).withPriority(3));
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "usage thresholds and sign-in URL policy match zeron" {
    try testing.expectEqual(UsageLevel.normal, usageLevel(0.79));
    try testing.expectEqual(UsageLevel.warn, usageLevel(0.8));
    try testing.expectEqual(UsageLevel.critical, usageLevel(0.95));
    try testing.expect(isOpenableLoginUrl("https://claude.ai/oauth"));
    try testing.expect(isOpenableLoginUrl("http://localhost:5432/cb"));
    try testing.expect(isOpenableLoginUrl("http://[::1]:80/"));
    try testing.expect(isOpenableLoginUrl("http://user@127.0.0.1/x"));
    try testing.expect(!isOpenableLoginUrl("http://evil.example/"));
    try testing.expect(!isOpenableLoginUrl("file:///etc/passwd"));
    try testing.expect(!isOpenableLoginUrl("zeron://x"));
    try testing.expect(forceUsageFor(.mount) and forceUsageFor(.post_login) and !forceUsageFor(.post_action));
}

test "providers, options and labels" {
    try testing.expect(signsIn(.@"claude-code") and signsIn(.hermes) and !signsIn(.mock));
    try testing.expectEqual(@as(usize, 2), loginOptions(.opencode).len);
    try testing.expect(loginOptions(.codex)[0].provider == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Connect a Codex account", addOptionLabel(a, .codex, loginOptions(.codex)[0], true));
    try testing.expectEqualStrings("Add account", addOptionLabel(a, .codex, loginOptions(.codex)[0], false));
    try testing.expectEqualStrings("Connect GitHub Copilot", addOptionLabel(a, .opencode, loginOptions(.opencode)[1], true));
    try testing.expectEqualStrings("Add ChatGPT account", addOptionLabel(a, .pi, loginOptions(.pi)[0], false));
    const flow: LoginFlow = .{ .harness = .opencode, .provider = "github-copilot", .attempt = 1 };
    try testing.expectEqualStrings("Sign in to GitHub Copilot for OpenCode", flow.title(a));
}

test "a switch moves the live login only within its provider group" {
    var accounts = [_]Account{
        .{ .id = "a", .harness = .opencode, .provider = "openai", .active = true },
        .{ .id = "b", .harness = .opencode, .provider = "openai", .active = false },
        .{ .id = "c", .harness = .opencode, .provider = "github-copilot", .active = true },
    };
    var snap: Snapshot = .{ .accounts = &accounts };
    markSwitched(&snap, &accounts[1]);
    try testing.expect(!accounts[0].active and accounts[1].active and accounts[2].active);
}

test "reset times read as clock time, weekday, or month day" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = parseRfc3339("2026-10-04T12:00:00Z").?;
    try testing.expectEqualStrings("resets 3:45 PM", formatReset(a, "2026-10-04T15:45:00Z", now, 0).?);
    try testing.expectEqualStrings("resets Wed", formatReset(a, "2026-10-07T09:00:00.123Z", now, 0).?);
    try testing.expectEqualStrings("resets Nov 2", formatReset(a, "2026-11-02T09:00:00+00:00", now, 0).?);
    try testing.expect(formatReset(a, null, now, 0) == null);
    try testing.expectEqual(parseRfc3339("2026-10-04T14:00:00+02:00").?, now);
}

/// Reply handlers, for driving the flows in headless tests (no engine).
pub const replies = struct {
    pub const list = onList;
    pub const action = onAction;
    pub const start = onStart;
    pub const poll = onPoll;
    pub const pollTimer = onPollTimer;
};
