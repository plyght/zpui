//! [liquid-glass] Native Liquid Glass elements (macOS 26+ `NSGlassEffectView` /
//! `NSGlassEffectContainerView`; docs/elements.md §5c, docs/LIQUID_GLASS.md).
//!
//! ```zig
//! zpui.liquidGlass("sidebar-glass", .{ .shape = .{ .rounded = 16 } }, sidebar_content)
//! zpui.liquidGlass("send", .{ .shape = .capsule, .style = .clear, .interactive = true }, button)
//! zpui.liquidGlassGroup("tools", .{ .spacing = 12 }, div().flex().gap(px(8)).child(a).child(b))
//! zpui.overlayPlane(titlebar_buttons)   // plain content that must stay above base glass
//! if (zpui.platformSupportsLiquidGlass(cx)) ... else ... // offer the option at all?
//! ```
//!
//! `liquidGlass` places a native glass view at the child's bounds (an
//! `.above_content` native child, mouse pass-through): the glass samples and refracts
//! everything zpui painted on the main surface below it. The child — the glass's
//! foreground: text, icons, hover washes — is painted on the overlay plane above the
//! glass. Glass painted by the window's floating pass (deferred menus / popovers,
//! tooltips, drag previews) or inside a floating glass's foreground is floating: it
//! sits above the overlay plane and its foreground goes to the top plane, so a menu's
//! glass covers the sidebar's text. Elements with the same id under the same parent
//! are told apart by paint order. Without native glass (Linux, Windows, macOS < 26, a window without native
//! views) the element just paints the child: callers style the fallback (e.g.
//! frost) themselves.
//!
//! Shapes: `.rounded` (uniform radius; NSGlassEffectView draws continuous corners)
//! and `.capsule` (radius = half the short side, recomputed each frame). Concave or
//! per-corner shapes are not available natively; merge simple shapes with a group.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const platform = @import("../platform/platform.zig");
const App = @import("../app/app.zig").App;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const arena_mod = @import("../window/arena.zig");

const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds(Pixels);

pub const Style = platform.LiquidGlassStyle;
pub const Tier = window_mod.liquid_glass_mod.Tier;

pub const Shape = union(enum) {
    /// Uniform corner radius (0 = square).
    rounded: Pixels,
    /// Fully rounded ends: radius = min(width, height) / 2.
    capsule,
    /// The window's own corner radius (a full-window glass, like Ghostty's).
    window,

    pub fn radius(self: Shape, bounds: Bounds) Pixels {
        return switch (self) {
            .rounded => |r| @max(r, 0),
            .capsule => @max(@min(bounds.size.width, bounds.size.height) / 2, 0),
            .window => default_window_radius,
        };
    }
};

pub const Options = struct {
    style: Style = .regular,
    shape: Shape = .{ .rounded = 0 },
    /// Tint the glass toward this color (`NSGlassEffectView.tintColor`).
    tint: ?color.Hsla = null,
    /// Interactive highlight on press (`effectIsInteractive`, macOS 27+ AppKit; a no-op
    /// where the selector is missing).
    interactive: bool = false,
    /// false: paint the child as if glass were unavailable (pass-through).
    enabled: bool = true,
    /// Under the main surface (needs a transparent window): the child is painted in
    /// place on top of the glass, as content with its own alpha (Ghostty's
    /// `macos-glass-regular` window background).
    behind_content: bool = false,
};

/// Fallback for `.window` when the platform can't report its corner radius (Tahoe's
/// titled windows without a toolbar).
pub const default_window_radius: Pixels = 16;

pub fn config(opts: Options, bounds: Bounds) platform.LiquidGlassConfig {
    return .{
        .style = opts.style,
        .tint = if (opts.tint) |t| blk: {
            const c = t.toRgba();
            break :blk .{ c.r, c.g, c.b, c.a };
        } else null,
        .interactive = opts.interactive,
        .corner_radius = opts.shape.radius(bounds),
        .behind_content = opts.behind_content,
    };
}

/// Whether native Liquid Glass can be shown on this machine (macOS 26+ with
/// NSGlassEffectView; the headless test platform pretends yes). `cx`: `*App` or a
/// `*Context(T)`.
pub fn platformSupportsLiquidGlass(cx: anytype) bool {
    const app: *App = if (@TypeOf(cx) == *App) cx else cx.app;
    return app.platform.supportsLiquidGlass();
}

/// The macOS major version whose Liquid Glass design is shown (26 Tahoe, 27 Golden
/// Gate, ...), 0 without native glass. For layout choices that changed between
/// releases (e.g. macOS 27's edge-to-edge sidebars). `cx`: `*App` or a `*Context(T)`.
pub fn liquidGlassRevision(cx: anytype) u32 {
    const app: *App = if (@TypeOf(cx) == *App) cx else cx.app;
    return app.platform.liquidGlassRevision();
}

// ---------------------------------------------------------------------------------------
// liquidGlass
// ---------------------------------------------------------------------------------------

pub const LiquidGlassData = struct {
    id: ElementId,
    opts: Options,
    child: AnyElement,
};

/// Native glass behind `child` (at `child`'s bounds); `child` paints on top of it.
pub fn liquidGlass(id: anytype, opts: Options, child: anytype) LiquidGlass {
    return .{ .d = arena_mod.current().create(LiquidGlassData, .{
        .id = ElementId.from(id),
        .opts = opts,
        .child = element.intoAnyElement(child),
    }) };
}

pub const LiquidGlass = struct {
    d: *LiquidGlassData,

    pub fn intoAnyElement(self: LiquidGlass) AnyElement {
        return AnyElement.new(LiquidGlassElement{ .d = self.d });
    }
};

const LiquidGlassElement = struct {
    d: *LiquidGlassData,

    pub fn elementId(self: *LiquidGlassElement) ?ElementId {
        return self.d.id;
    }
    pub fn requestLayout(self: *LiquidGlassElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.d.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *LiquidGlassElement, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.d.child.prepaint(window, cx);
    }
    pub fn paint(self: *LiquidGlassElement, gid: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        const d = self.d;
        var cfg = config(d.opts, bounds);
        if (d.opts.shape == .window) if (window.platform_window.windowCornerRadius()) |r| {
            cfg.corner_radius = r;
        };
        const tier = if (d.opts.enabled and gid != null)
            window.paintLiquidGlass(gid.?, .glass, bounds, cfg)
        else
            null;
        // Glass behind the main surface: its content paints in place, over it.
        paintForeground(if (d.opts.behind_content) null else tier, d.child, window, cx);
    }
};

/// For custom wrapper elements (e.g. an app's frost wrapper switching to glass):
/// place glass `name` (scoped under the current element id, so it adds no id level
/// for `child`) at `bounds` and paint `child` as its foreground. Returns false and
/// paints nothing when native glass is unavailable — paint the fallback then.
pub fn paintGlass(window: *Window, cx: *App, name: []const u8, bounds: Bounds, opts: Options, child: AnyElement) bool {
    const gid = window.pushElementId(ElementId.from(name));
    window.popElementId();
    const tier = window.paintLiquidGlass(gid, .glass, bounds, config(opts, bounds)) orelse return false;
    paintForeground(tier, child, window, cx);
    return true;
}

/// Paint `child` on the plane above glass of `tier` (or in place for null).
pub fn paintForeground(tier: ?Tier, child: AnyElement, window: *Window, cx: *App) void {
    switch (tier orelse return child.paint(window, cx)) {
        .base => {
            window.pushOverlayPlane();
            defer window.popOverlayPlane();
            child.paint(window, cx);
        },
        .floating => {
            window.pushTopPlane();
            defer window.popTopPlane();
            child.paint(window, cx);
        },
    }
}

// ---------------------------------------------------------------------------------------
// liquidGlassGroup
// ---------------------------------------------------------------------------------------

pub const GroupOptions = struct {
    /// Distance at which member shapes start to merge (`spacing`).
    spacing: Pixels = 0,
    enabled: bool = true,
};

pub const LiquidGlassGroupData = struct {
    id: ElementId,
    opts: GroupOptions,
    child: AnyElement,
};

/// `NSGlassEffectContainerView` at `child`'s bounds: `liquidGlass` elements painted
/// inside become members (descendants of the container) and merge / morph when closer
/// than `spacing`. The container draws nothing itself.
pub fn liquidGlassGroup(id: anytype, opts: GroupOptions, child: anytype) LiquidGlassGroup {
    return .{ .d = arena_mod.current().create(LiquidGlassGroupData, .{
        .id = ElementId.from(id),
        .opts = opts,
        .child = element.intoAnyElement(child),
    }) };
}

pub const LiquidGlassGroup = struct {
    d: *LiquidGlassGroupData,

    pub fn intoAnyElement(self: LiquidGlassGroup) AnyElement {
        return AnyElement.new(LiquidGlassGroupElement{ .d = self.d });
    }
};

const LiquidGlassGroupElement = struct {
    d: *LiquidGlassGroupData,

    pub fn elementId(self: *LiquidGlassGroupElement) ?ElementId {
        return self.d.id;
    }
    pub fn requestLayout(self: *LiquidGlassGroupElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.d.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *LiquidGlassGroupElement, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.d.child.prepaint(window, cx);
    }
    pub fn paint(self: *LiquidGlassGroupElement, gid: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        const d = self.d;
        const lg = window_mod.liquid_glass_mod;
        if (!d.opts.enabled or gid == null) return d.child.paint(window, cx);
        if (window.paintLiquidGlass(gid.?, .container, bounds, .{ .spacing = d.opts.spacing }) == null)
            return d.child.paint(window, cx);
        const pool = &window.liquid_glass;
        // The key actually used (re-derived when the id repeats under one parent).
        const key = pool.frame_keys.items[pool.frame_keys.items.len - 1];
        const view = pool.entries.items[pool.find(key).?].view;
        lg.pushGroup(window, view);
        defer lg.popGroup(window);
        d.child.paint(window, cx);
    }
};

// ---------------------------------------------------------------------------------------
// overlayPlane
// ---------------------------------------------------------------------------------------

/// Paint `child` on the overlay plane (above base-tier glass and other native
/// children) — for plain content that overlaps glass without being its foreground,
/// e.g. titlebar buttons over a glass sidebar. A pass-through when `on` is false.
pub fn overlayPlane(on: bool, child: anytype) OverlayPlane {
    return .{ .on = on, .child = element.intoAnyElement(child) };
}

pub const OverlayPlane = struct {
    on: bool,
    child: AnyElement,

    pub fn requestLayout(self: *OverlayPlane, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *OverlayPlane, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }
    pub fn paint(self: *OverlayPlane, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        if (!self.on) return self.child.paint(window, cx);
        window.pushOverlayPlane();
        defer window.popOverlayPlane();
        self.child.paint(window, cx);
    }
};

// ---------------------------------------------------------------------------------------
// sidebarMaterial / backdropHole
// ---------------------------------------------------------------------------------------

pub const MaterialOptions = struct {
    /// Uniform corner radius of the material.
    corner_radius: Pixels = 0,
    enabled: bool = true,
    /// Also attach the material where the OS has no Liquid Glass (macOS 11-15 keep the
    /// classic `.sidebar` vibrancy): the pre-Tahoe source-list sidebar. Default: only
    /// alongside native glass.
    without_glass: bool = false,
};

pub const SidebarMaterialData = struct {
    id: ElementId,
    opts: MaterialOptions,
    child: AnyElement,
};

/// A behind-window sidebar material (macOS `NSVisualEffectView` `.sidebar`) at
/// `child`'s bounds, attached UNDER the main surface: it only shows where zpui paints
/// nothing (alpha 0) above it. `child` paints in place (main surface). Without native
/// glass support it just paints `child`. Used as the fallback backing of a sidebar
/// glass pane (docs/LIQUID_GLASS.md, `ZERON_SIDEBAR_GLASS=vev`).
pub fn sidebarMaterial(id: anytype, opts: MaterialOptions, child: anytype) SidebarMaterial {
    return .{ .d = arena_mod.current().create(SidebarMaterialData, .{
        .id = ElementId.from(id),
        .opts = opts,
        .child = element.intoAnyElement(child),
    }) };
}

pub const SidebarMaterial = struct {
    d: *SidebarMaterialData,

    pub fn intoAnyElement(self: SidebarMaterial) AnyElement {
        return AnyElement.new(SidebarMaterialElement{ .d = self.d });
    }
};

const SidebarMaterialElement = struct {
    d: *SidebarMaterialData,

    pub fn elementId(self: *SidebarMaterialElement) ?ElementId {
        return self.d.id;
    }
    pub fn requestLayout(self: *SidebarMaterialElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.d.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *SidebarMaterialElement, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.d.child.prepaint(window, cx);
    }
    pub fn paint(self: *SidebarMaterialElement, gid: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        const d = self.d;
        if (d.opts.enabled and gid != null)
            _ = window.paintLiquidGlass(gid.?, .sidebar_material, bounds, .{ .corner_radius = d.opts.corner_radius, .without_glass = d.opts.without_glass });
        d.child.paint(window, cx);
    }
};

/// Cut `child`'s bounds (rounded by `corner_radii`: tl, tr, br, bl) out of the window's
/// behind-window material (`Window.paintBackdropHole`), so native glass above a region
/// zpui leaves at alpha 0 refracts the desktop itself. `child` paints in place. Must be
/// painted every frame by a view that is always redrawn (the root view).
pub fn backdropHole(on: bool, corner_radii: [4]Pixels, child: anytype) BackdropHole {
    return .{ .on = on, .radii = corner_radii, .child = element.intoAnyElement(child) };
}

pub const BackdropHole = struct {
    on: bool,
    radii: [4]Pixels,
    child: AnyElement,

    pub fn requestLayout(self: *BackdropHole, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *BackdropHole, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }
    pub fn paint(self: *BackdropHole, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        if (self.on) window.paintBackdropHole(bounds, self.radii);
        self.child.paint(window, cx);
    }
};
