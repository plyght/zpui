//! Settings → Providers (zeron `settings/harnesses.rs`): one row per agent
//! harness — brand tile, install hint / update status / transport meta,
//! the Update action, a details chevron, Install for missing CLIs, and the
//! enable switch (the last runnable agent cannot be switched off). The
//! header carries "Check now" and the device switcher.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const ui = @import("../components/root.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");
const accounts = @import("accounts.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const rems = ui.rems;
const protocol = engine.protocol;
const HarnessId = protocol.HarnessId;
const types = model.types;

/// Mock is only listed when it is the only harness (`visible_harnesses`).
pub fn visibleHarnesses(v: *SettingsView, cx: anytype) []protocol.HarnessDescriptor {
    const list = v.state.read(cx).catalog.read(cx).harnessList();
    const a = zpui.window.arena_mod.frameAllocator();
    var out: std.ArrayList(protocol.HarnessDescriptor) = .empty;
    for (list) |d| if (d.id != .mock) out.append(a, d) catch {};
    if (out.items.len == 0) for (list) |d| out.append(a, d) catch {};
    return out.items;
}

pub fn cliName(h: HarnessId) []const u8 {
    return switch (h) {
        .@"claude-code" => "claude",
        .codex => "codex",
        .cursor => "cursor-agent",
        .devin => "devin",
        .grok => "grok",
        .hermes => "hermes",
        .pi => "pi",
        .opencode => "opencode",
        .antigravity => "Antigravity",
        .mock => "mock",
    };
}

fn installHint(h: HarnessId, enabled: bool, can_install: bool) []const u8 {
    if (h == .antigravity) return if (can_install) "Install Antigravity to enable" else "Set ANTIGRAVITY_ACP_EXECUTABLE to enable Antigravity";
    if (enabled) return zpui.fmt("{s} CLI not installed — turn it off or install it", .{cliName(h)});
    return zpui.fmt("Install the {s} CLI to enable", .{cliName(h)});
}

fn updateLabel(st: types.HarnessUpdateStatus, t: *const Theme) w.Fragment {
    const installed = if (st.installedVersion) |ver| zpui.fmt("v{s}", .{ver}) else "Version unavailable";
    const label: []const u8 = switch (st.phase) {
        .dormant => "Update monitoring off",
        .checking => "Checking for updates…",
        .current => zpui.fmt("{s} · Up to date", .{installed}),
        .available => blk: {
            const avail = if (st.latestVersion) |l| zpui.fmt("{s} · v{s} available", .{ installed, l }) else zpui.fmt("{s} · Update available", .{installed});
            break :blk if (st.manualCommand) |m| zpui.fmt("{s} · {s}", .{ avail, m }) else avail;
        },
        .@"waiting-for-idle" => zpui.fmt("{s} · Waiting for agent to be idle", .{installed}),
        .preparing => zpui.fmt("{s} · Preparing update…", .{installed}),
        .downloading => zpui.fmt("{s} · Downloading…", .{installed}),
        .installing => zpui.fmt("{s} · Installing…", .{installed}),
        .verifying => "Verifying updated CLI…",
        .updated => zpui.fmt("{s} · Updated", .{installed}),
        .@"manual-action-required" => if (st.manualCommand) |m| zpui.fmt("{s} · {s}", .{ installed, m }) else zpui.fmt("{s} · Manual update checks", .{installed}),
        .failed => if (st.@"error") |e| zpui.fmt("Update check failed · {s}", .{e.message}) else "Update check failed",
    };
    const color = switch (st.phase) {
        .available => t.accent,
        .updated => t.success,
        .failed => t.danger,
        .@"manual-action-required" => t.warning_muted,
        else => t.text_muted.opacity(0.75),
    };
    return .{ .text = label, .color = color };
}

fn findUpdate(v: *SettingsView, h: HarnessId, cx: anytype) ?types.HarnessUpdateStatus {
    for (v.harnessUpdates(cx)) |st| if (st.harness == h) {
        var out = st;
        if (v.update_override.get(h)) |p| out.phase = p;
        return out;
    };
    return null;
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const list = visibleHarnesses(v, cx);
    var enabled_count: usize = 0;
    for (list) |*d| if (v.harnessEnabled(d)) {
        enabled_count += 1;
    };

    var card = w.sectionCard(t);
    for (list, 0..) |*d, ix| {
        const h = d.id;
        const enabled = v.harnessEnabled(d);
        const last_enabled = enabled and enabled_count == 1 and d.installed;
        const interactive = !last_enabled and (enabled or d.installed);
        const update = findUpdate(v, h, cx);

        var meta: [4]w.Fragment = undefined;
        var n: usize = 0;
        const installing = v.installing == h;
        // Installing REPLACES the not-installed hint in place.
        if (installing) {
            meta[n] = .{ .text = zpui.fmt("Installing {s}…", .{d.name}) };
            n += 1;
        } else if (!d.installed) {
            meta[n] = .{ .text = installHint(h, enabled, d.canInstall), .color = t.warning_muted.opacity(0.9) };
            n += 1;
        }
        if (update) |st| {
            meta[n] = updateLabel(st, t);
            n += 1;
        }
        switch (h) {
            .cursor => {
                meta[n] = .{ .text = "Cursor SDK · Managed by Zeron", .color = t.text_muted.opacity(0.65) };
                n += 1;
            },
            .pi => {
                meta[n] = .{ .text = "Pi RPC · Native connection", .color = t.text_muted.opacity(0.65) };
                n += 1;
            },
            else => {},
        }
        const frags = zpui.window.arena_mod.frameAllocator().dupe(w.Fragment, meta[0..n]) catch &.{};

        const mark, const tint = ui.icon.harnessMark(h);
        const tile = div().flexNone().size(px(36)).rounded(px(10)).bg(t.wash(0.06))
            .flex().itemsCenter().justifyCenter().child(ui.icon.of(mark, 16, tint orelse t.text_muted));
        const expanded = enabled and v.expanded_harness == h;

        var text = div().flex1().minW0().flex().flexCol().child(w.rowTitle(t, d.name));
        if (n > 0) text = text.child(w.metaLine(t, frags));

        const group_name = zpui.fmt("harness-details-{d}", .{ix});
        var trigger = div().id(.{ "harness-details-trigger", ix }).group(group_name)
            .flex1().minW(px(180)).minH(px(44)).px(px(4)).rounded(px(8))
            .flex().flexRow().itemsCenter().gap(px(12))
            .child(tile).child(text);
        if (update) |st| {
            const primary = (st.phase == .available or st.phase == .@"manual-action-required") and st.canApply;
            const cancel = st.phase == .@"waiting-for-idle" or st.phase == .preparing or st.phase == .downloading;
            if (primary or cancel) {
                var b = div().id(.{ "harness-update", ix }).flexNone().px(px(9)).py(px(5)).rounded(px(6))
                    .textSize(rems(11)).cursorPointer().onClick(cx.listenerWith(ix, SettingsView.onHarnessUpdate));
                b = if (primary)
                    b.bg(t.accent_wash).fontWeight(500).textColor(t.accent).hover(sb.bg(t.accent.opacity(0.16))).child("Update")
                else
                    b.textColor(t.text_muted).hover(sb.bg(t.ink(0.05))).child("Cancel");
                trigger = trigger.child(b);
            }
        }
        if (enabled) {
            trigger = trigger.cursorPointer().onClick(cx.listenerWith(ix, SettingsView.onHarnessDetails))
                .child(ui.icon.of(if (expanded) .alt_arrow_down else .alt_arrow_right, 14, t.text_muted)
                .groupHover(group_name, sb.textColor(t.text)));
        }
        var header = w.cardRow(t, ix == 0).child(trigger);
        if (!d.installed and !installing) header = header.opacity(0.55);
        if (h != .mock and !d.installed and d.canInstall and !installing) {
            var install = w.actionButton(t, .quiet).id(.{ "harness-install", ix }).child("Install");
            if (v.installing == null) install = install.onClick(cx.listenerWith(ix, SettingsView.onHarnessInstall));
            header = header.child(install);
        }
        if (installing) header = header.child(w.actionButton(t, .quiet).id(.{ "harness-cancel-install", ix })
            .onClick(cx.listener(SettingsView.onCancelInstall)).child("Cancel"));
        header = header.child(harnessSwitch(v, ix, h, enabled, interactive, t, cx));
        var block = div().flex().flexCol().child(header);
        if (expanded) block = block.child(details(v, ix, t, d, update, cx));
        card = card.child(block);
    }

    const check = div().id("check-harness-updates").flexNone().px(px(9)).py(px(5)).rounded(px(6))
        .textSize(rems(11)).textColor(t.text_muted).cursorPointer().hover(sb.bg(t.ink(0.05)))
        .onClick(cx.listener(SettingsView.onCheckUpdates)).child("Check now");
    var page = w.pageColumn()
        .child(div().flex().flexRow().itemsCenter().justifyBetween()
        .child(w.pageHeader(t, "Providers", null))
        .child(div().flex().itemsCenter().gap(px(6)).child(check).child(select.render(v, .provider_device, t, cx))))
        .child(card);
    if (v.provider_error) |e| page = page.child(w.errorStrip(t, e));
    return page;
}

fn harnessSwitch(v: *SettingsView, ix: usize, h: HarnessId, enabled: bool, interactive: bool, t: *const Theme, cx: *zpui.Context(SettingsView)) zpui.StatefulDiv {
    const pos = v.travel(cx, 0x40000 | @as(u32, @intFromEnum(h)), if (enabled) 1 else 0, 180);
    var d = div().id(.{ "harness-toggle", ix }).flexNone().w(px(w.switch_width)).h(px(w.switch_height))
        .child(w.switchVisual(t, pos));
    if (!interactive and !enabled) d = d.opacity(0.55);
    if (interactive) d = d.cursorPointer().onClick(cx.listenerWith(ix, SettingsView.onHarnessToggle));
    return d;
}

/// Expanded agent preferences (`render_agent_details`): no box of its own,
/// indented to the row title — Completion switches, then the update policy.
fn details(v: *SettingsView, ix: usize, t: *const Theme, d: *const protocol.HarnessDescriptor, update: ?types.HarnessUpdateStatus, cx: *zpui.Context(SettingsView)) zpui.AnyElement {
    const inset: f32 = 4 + 36 + 12;
    const s = @import("store.zig").current(cx);
    const prefs = s.skillCompletion(d.id);
    var completion = div().flex().flexCol().child(detailsLabel(t, "Completion"));
    const rows = [_]struct { bool, []const u8, []const u8, bool }{
        .{ true, "Use $ for skills", "Type $ in the composer to pick a skill.", prefs.dollar },
        .{ false, "Separate / commands", "Keep skills out of the / menu.", prefs.separateFromSlash },
    };
    for (rows, 0..) |r, i| {
        const pos = v.travel(cx, 0x50000 | @as(u32, @intCast(ix * 2 + i)), if (r[3]) 1 else 0, 180);
        var row = div().id(.{ "completion", ix * 2 + i }).minH(px(52)).py(px(10))
            .flex().flexRow().itemsCenter().gap(px(16)).cursorPointer()
            .onClick(cx.listenerWith(SettingsView.CompletionKey{ .ix = @intCast(ix), .dollar = r[0] }, SettingsView.onCompletionToggle))
            .child(div().flex1().minW0().child(w.rowTitle(t, r[1])).child(w.metaLine(t, &.{.{ .text = r[2] }})))
            .child(w.switchVisual(t, pos));
        if (i > 0) row = row.borderT1().borderColor(w.rowDivider(t));
        completion = completion.child(row);
    }
    var col = div().mx(px(16)).pl(px(inset)).pb(px(16)).flex().flexCol().gap(px(20)).child(completion);
    if (update != null) {
        const policy = v.harnessPolicy(d.id, cx);
        const sel_ix = select.policyIndex(policy);
        col = col.child(div().flex().flexCol().child(detailsLabel(t, "Updates"))
            .child(div().minH(px(52)).py(px(10)).flex().flexRow().itemsCenter().gap(px(16))
            .child(div().flex1().minW0().child(w.rowTitle(t, "Update policy"))
            .child(w.metaLine(t, &.{.{ .text = select.update_policies[sel_ix][2] }})))
            .child(policyTrigger(v, ix, policy, t, cx))));
    }
    // Accounts (sign-in providers): the provider's logins and its sign-in flow.
    if (accounts.signsIn(d.id)) {
        accounts.ensureFor(v, d.id, cx);
        const now_s = @import("../shell/prefs.zig").get(cx).now(v.io).secs;
        col = col.child(accounts.embedded(v, d.id, t, now_s, cx));
    }
    return zpui.intoAnyElement(ui.anim.menuIn(zpui.fmt("agent-details-{d}", .{ix}), col, -2));
}

fn detailsLabel(t: *const Theme, label: []const u8) zpui.Div {
    return div().minH(px(32)).flex().flexRow().itemsCenter().textSize(rems(13)).lineHeight(rems(17)).textColor(t.text_muted).child(label);
}

/// The policy select trigger for row `ix` (the menu is shared via `.update_policy`).
fn policyTrigger(v: *SettingsView, ix: usize, policy: types.HarnessUpdatePolicy, t: *const Theme, cx: *zpui.Context(SettingsView)) zpui.StatefulDiv {
    const open = v.open_select == .update_policy and v.policy_harness != null and v.policy_harness.? == visibleHarnesses(v, cx)[ix].id;
    var trigger = w.selectTrigger(t, if (open) w.selectFill(t, true) else w.selectFill(t, false)).id(.{ "harness-update-policy", ix }).w(px(136))
        .hover(sb.bg(w.selectFill(t, true)))
        .onClick(cx.listenerWith(ix, SettingsView.onPolicyTrigger))
        .child(div().flex1().minW0().truncate().child(select.update_policies[select.policyIndex(policy)][1]))
        .child(w.selectChevron(t, open));
    if (open) trigger = trigger.child(select.menuFor(v, .update_policy, t, cx));
    return trigger;
}
