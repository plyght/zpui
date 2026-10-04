//! [liquid-glass] Window-side bookkeeping for native Liquid Glass (`zpui.liquidGlass`,
//! `zpui.liquidGlassGroup`; macOS 26 `NSGlassEffectView` / `NSGlassEffectContainerView`).
//!
//! Glass views are native children owned by the window, keyed by the painting element's
//! global id. Each frame the element calls `paint`, which attaches the view on first use
//! (or re-attaches it when its tier / group changed), pushes a changed config to the
//! backend, and records the placement like `paintNativeView`. A view not painted in a
//! presented frame is hidden by the normal native-view pass and detached after
//! `keep_idle_presents` presents (so menus that open and close reuse their glass).
//!
//! Tiers (see `platform.OverlayPlane`): glass painted by the window's floating pass
//! (deferred menus / popovers, tooltips, drag previews) or inside a floating glass's
//! foreground is `.floating` (an `.above_overlay` child; its foreground goes to the top
//! plane). Everything else — including glass nested in a base glass's foreground or in
//! an `overlayPlane` — is `.base` (an `.above_content` child; foreground on the overlay
//! plane).

const std = @import("std");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

const Bounds = geometry.Bounds(geometry.Pixels);

pub const Tier = enum { base, floating };

pub const Entry = struct {
    key: u64,
    view: platform.NativeViewId,
    kind: platform.LiquidGlassKind,
    tier: Tier,
    parent: ?platform.NativeViewId,
    config: platform.LiquidGlassConfig,
    idle_presents: u32 = 0,
};

/// Presents a glass view may go unpainted before it is detached.
pub const keep_idle_presents: u32 = 120;

pub const Pool = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Open `liquidGlassGroup` containers during paint (innermost last).
    groups: std.ArrayList(platform.NativeViewId) = .empty,
    /// Cached support answer; null until first asked.
    supported: ?bool = null,
    /// Total attaches (diagnostics / tests).
    attach_count: u32 = 0,
    /// > 0 while the window paints deferred draws / tooltips / drags.
    floating_depth: u32 = 0,
    /// Keys placed this frame: a repeated key (two instances of one element id
    /// under the same parent) is re-derived by occurrence, deterministically.
    frame_keys: std.ArrayList(u64) = .empty,

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.groups.deinit(gpa);
        self.frame_keys.deinit(gpa);
    }

    pub fn find(self: *const Pool, key: u64) ?usize {
        for (self.entries.items, 0..) |e, i| if (e.key == key) return i;
        return null;
    }
};

/// Both the window backend and the OS can show native glass.
pub fn supported(w: *Window) bool {
    if (w.liquid_glass.supported) |s| return s;
    const s = w.platform_window.hasLiquidGlass() and w.app.platform.supportsLiquidGlass();
    w.liquid_glass.supported = s;
    return s;
}

fn configEql(a: platform.LiquidGlassConfig, b: platform.LiquidGlassConfig) bool {
    return std.meta.eql(a, b);
}

/// Paint phase: place glass `key` at `bounds`. Returns its tier, or null when glass is
/// unavailable (the caller then paints its fallback).
pub fn paint(w: *Window, element_key: u64, kind: platform.LiquidGlassKind, bounds: Bounds, config_in: platform.LiquidGlassConfig) ?Tier {
    var config = config_in;
    if (config.dark == null) config.dark = w.glass_dark;
    std.debug.assert(w.phase == .paint);
    if (!supported(w)) return null;
    const pool = &w.liquid_glass;
    var key = element_key;
    var n: u64 = 0;
    while (std.mem.indexOfScalar(u64, pool.frame_keys.items, key) != null) {
        n += 1;
        key = std.hash.Wyhash.hash(n, std.mem.asBytes(&element_key));
    }
    pool.frame_keys.append(w.gpa, key) catch @panic("OOM");
    const tier: Tier = if (pool.floating_depth > 0 or w.top_depth > 0) .floating else .base;
    const parent: ?platform.NativeViewId = if (kind == .glass and pool.groups.items.len > 0) pool.groups.items[pool.groups.items.len - 1] else null;

    var view: ?platform.NativeViewId = null;
    if (pool.find(key)) |i| {
        const e = &pool.entries.items[i];
        if (e.tier != tier or e.kind != kind or !std.meta.eql(e.parent, parent)) {
            detachAt(w, i);
        } else {
            if (!configEql(e.config, config)) {
                w.platform_window.configureLiquidGlass(e.view, config);
                e.config = config;
            }
            view = e.view;
        }
    }
    if (view == null) {
        // A sidebar material sits under the main surface (zpui leaves alpha 0 above it).
        const z: platform.NativeViewZ = if (kind == .sidebar_material) .below_content else if (tier == .base) .above_content else .above_overlay;
        const v = w.platform_window.attachLiquidGlass(.{ .kind = kind, .z = z, .parent = parent }) catch |err| {
            std.log.scoped(.liquid_glass).warn("attach failed ({t}); falling back", .{err});
            pool.supported = false;
            return null;
        };
        w.platform_window.configureLiquidGlass(v, config);
        pool.entries.append(w.gpa, .{ .key = key, .view = v, .kind = kind, .tier = tier, .parent = parent, .config = config }) catch @panic("OOM");
        pool.attach_count += 1;
        view = v;
    }
    w.paintNativeView(view.?, bounds, config.corner_radius);
    return tier;
}

/// Detach entry `i` (a container takes its member glass with it).
fn detachAt(w: *Window, i: usize) void {
    const pool = &w.liquid_glass;
    const e = pool.entries.orderedRemove(i);
    if (e.kind == .container) {
        var j: usize = 0;
        while (j < pool.entries.items.len) {
            const m = pool.entries.items[j];
            if (m.parent != null and m.parent.? == e.view) {
                _ = pool.entries.orderedRemove(j);
                w.detachNativeView(m.view);
            } else j += 1;
        }
    }
    w.detachNativeView(e.view);
}

/// Present: age unpainted glass and detach what stayed unused too long.
pub fn sweep(w: *Window) void {
    const pool = &w.liquid_glass;
    pool.frame_keys.clearRetainingCapacity();
    if (pool.entries.items.len == 0) return;
    const painted = w.rendered_frame.native_views.items;
    var stale = false;
    for (pool.entries.items) |*e| {
        const used = for (painted) |p| {
            if (p.id == e.view) break true;
        } else false;
        if (used) e.idle_presents = 0 else e.idle_presents += 1;
        if (e.idle_presents > keep_idle_presents) stale = true;
    }
    if (!stale) return;
    // Detach one at a time: a container takes its members along, shifting indices.
    outer: while (true) {
        for (pool.entries.items, 0..) |e, i| if (e.idle_presents > keep_idle_presents) {
            detachAt(w, i);
            continue :outer;
        };
        break;
    }
}

pub fn pushGroup(w: *Window, view: platform.NativeViewId) void {
    w.liquid_glass.groups.append(w.gpa, view) catch @panic("OOM");
}

pub fn popGroup(w: *Window) void {
    _ = w.liquid_glass.groups.pop();
}
