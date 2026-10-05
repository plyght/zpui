//! Boot gates (zeron `render_gate_card`, `render_org_gate`, `grid_backdrop`):
//! engine failure (quiet copy + Retry), sign-in card, org onboarding — all
//! centered over the faint 44px grid.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const shell_mod = @import("shell.zig");
const wiring = @import("wiring.zig"); // [wiring] org gate create / pick

const Shell = shell_mod.Shell;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const color = zpui.color;

/// 44px hairlines at 3.5%, faded back into the page toward the edges.
pub fn gridBackdrop(theme: *const Theme) zpui.Div {
    const line = theme.hairline(0.035);
    const bg = theme.bg;
    const step: f32 = 44;
    const span: f32 = 2640;
    var d = div().absolute().inset0().overflowHidden();
    var i: f32 = 1;
    while (i * step < span) : (i += 1) d = d.child(div().absolute().left(px(i * step)).top(px(0)).bottom(px(0)).w(px(1)).bg(line));
    i = 1;
    while (i * step < span * 0.75) : (i += 1) d = d.child(div().absolute().top(px(i * step)).left(px(0)).right(px(0)).h(px(1)).bg(line));
    const stop = color.linearColorStop;
    return d
        .child(div().absolute().top(px(0)).left(px(0)).right(px(0)).h(px(120)).bg(color.linearGradient(180, stop(bg, 0), stop(bg.opacity(0), 1))))
        .child(div().absolute().bottom(px(0)).left(px(0)).right(px(0)).h(px(260)).bg(color.linearGradient(0, stop(bg, 0), stop(bg.opacity(0), 1))))
        .child(div().absolute().top(px(0)).bottom(px(0)).left(px(0)).w(px(200)).bg(color.linearGradient(90, stop(bg, 0), stop(bg.opacity(0), 1))))
        .child(div().absolute().top(px(0)).bottom(px(0)).right(px(0)).w(px(200)).bg(color.linearGradient(270, stop(bg, 0), stop(bg.opacity(0), 1))));
}

/// Keyed per phase (zeron App.tsx `<div key={phase} className="animate-in">`):
/// every gate swap replays the 0.5 s FADE_IN entrance.
fn page(theme: *const Theme, key: []const u8, content: zpui.Div) zpui.Div {
    return div().absolute().inset0().bg(theme.bg)
        .child(gridBackdrop(theme))
        .child(div().absolute().inset0().flex().itemsCenter().justifyCenter().child(ui.anim.fadeIn(key, content)));
}

fn onRetry(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
    const e = shell.state.read(cx).engine;
    e.update(cx, model.EngineState.reconnect, .{});
}

fn onSignIn(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
    const auth = shell.state.read(cx).auth;
    auth.update(cx, model.AuthStore.signIn, .{false}) catch {};
}

fn onCancelAuth(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
    const auth = shell.state.read(cx).auth;
    auth.update(cx, model.AuthStore.signOut, .{}) catch {};
}

pub fn failedGate(_: *Shell, message: []const u8, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    return page(theme, "gate-card-failed", div().flex().flexCol().itemsCenter().gap(px(zt.layout.space_md))
        .child(div().textSize(ui.rems(14)).textColor(theme.text_muted).child(message))
        .child(ui.button.outline("retry-engine", "Retry", theme).onClick(cx.listener(onRetry))));
}

fn logo(theme: *const Theme, w: f32, h: f32) zpui.elements.Svg {
    return zpui.svg().source(ui.icon.Icon.zeron_logo.path(), ui.icon.Icon.zeron_logo.svg()).w(px(w)).h(px(h)).flexNone().textColor(theme.text);
}

pub fn signInGate(_: *Shell, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    const card = div().w(px(360)).px(px(32)).py(px(40)).rounded(px(12))
        .border1().borderColor(theme.border).bg(theme.surface_card).shadowLg()
        .flex().flexCol().itemsCenter().textCenter()
        .child(logo(theme, 31.4, 36))
        .child(div().mt(px(24)).textSize(ui.rems(18)).fontWeight(600).textColor(theme.text).child("Log in to Zeron"))
        .child(div().mt(px(6)).mb(px(24)).textSize(ui.rems(13)).lineHeight(px(19)).textColor(theme.text_muted)
        .child("This opens your browser to finish logging in — you'll come right back."))
        .child(ui.button.solid("sign-in", "Log in", theme).wFull().onClick(cx.listener(onSignIn)));
    return page(theme, "gate-card-signin", card);
}

pub fn orgGate(shell: *Shell, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    const state = shell.state.read(cx);
    const auth = state.auth.read(cx);
    const email: ?[]const u8 = if (auth.user()) |u| u.email else null;
    const local_setup = state.workspace.read(cx).workspace_scope == .local;
    const blurb = if (email) |e|
        zpui.fmt("Zeron is organized around workspaces — create one for yourself or your team. Signed in as {s}.", .{e})
    else
        "Zeron is organized around workspaces — create one for yourself or your team.";
    var card = div().w(px(400)).px(px(32)).py(px(36)).rounded(px(12))
        .border1().borderColor(theme.border).bg(theme.surface_card).shadowLg()
        .flex().flexCol()
        .child(logo(theme, 24.4, 28))
        .child(div().mt(px(20)).textSize(ui.rems(18)).fontWeight(600).textColor(theme.text).child("Create your workspace"))
        .child(div().mt(px(6)).mb(px(24)).textSize(ui.rems(13)).lineHeight(px(19)).textColor(theme.text_muted).child(blurb))
        .child(div().flex().flexRow().gap(px(8))
            .child(div().flex1().minW0().h(px(36)).flex().itemsCenter().px(px(12)).rounded(px(8))
                .border1().borderColor(theme.border).bg(theme.bg).textSize(ui.rems(13)).textColor(theme.text)
                .child(wiring.orgInput(shell, cx)))
            .child(div().id("create-org").role(.button).h(px(36)).px(px(16)).flex().itemsCenter().rounded(px(6)).bg(theme.text)
                .textSize(ui.rems(14)).fontWeight(500).textColor(theme.on_solid).cursorPointer().hover(sb.opacity(0.9))
                .opacity(if (shell.wiring.org_submitting) 0.5 else 1)
                .onClick(cx.listener(wiring.onCreateOrgClick))
                .child(if (shell.wiring.org_submitting) "Creating…" else "Create")));
    if (shell.wiring.org_error) |e| card = card.child(div().mt(px(8)).textSize(ui.rems(12)).textColor(theme.danger).child(e));
    if (auth.orgs.len > 0) {
        var rows = div().flex().flexCol().gap(px(4));
        for (auth.orgs, 0..) |o, i| {
            rows = rows.child(div().id(.{ "org-row", i }).role(.button).px(px(12)).py(px(8)).rounded(px(8)).border1().borderColor(theme.border)
                .bg(theme.bg).textSize(ui.rems(13)).textColor(theme.text).cursorPointer().hover(sb.bg(theme.wash(0.11)))
                .onClick(cx.listenerWith(i, wiring.onPickOrg))
                .child(o.name));
        }
        card = card.child(div().mt(px(24)).flex().flexCol()
            .child(div().pb(px(8)).textSize(ui.rems(11)).fontWeight(500).textColor(theme.text_muted.opacity(0.6)).child("Or continue in a workspace you belong to"))
            .child(rows));
    }
    card = card.child(div().mt(px(24)).flex().flexRow()
        .child(div().id("org-signout").role(.button).textSize(ui.rems(12)).textColor(theme.text_muted.opacity(0.6)).cursorPointer()
        .hover(sb.textColor(theme.text)).onClick(cx.listener(onCancelAuth))
        .child(if (local_setup) "Cancel sync setup" else "Use a different account")));
    return page(theme, "org-gate-card", card);
}
