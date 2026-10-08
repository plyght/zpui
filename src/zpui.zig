//! zpui — a GPU-accelerated UI framework for Zig, ported from zui (zeronsh's gpui fork).

pub const geometry = @import("geometry.zig");
pub const layout = @import("layout/layout.zig");

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const ScaledPixels = geometry.ScaledPixels;
pub const DevicePixels = geometry.DevicePixels;
pub const Rems = geometry.Rems;
pub const AbsoluteLength = geometry.AbsoluteLength;
pub const DefiniteLength = geometry.DefiniteLength;
pub const Length = geometry.Length;
pub const px = geometry.px;
pub const rems = geometry.rems;
pub const relative = geometry.relative;
pub const auto = geometry.auto;

pub const color = @import("color.zig");
pub const Hsla = color.Hsla;
pub const Rgba = color.Rgba;
pub const Background = color.Background;
pub const rgb = color.rgb;
pub const rgba = color.rgba;
pub const hsla = color.hsla;

pub const atlas = @import("atlas.zig");
pub const bounds_tree = @import("bounds_tree.zig");
pub const scene = @import("scene.zig");
pub const Scene = scene.Scene;

pub const input = @import("input.zig");
pub const platform = @import("platform/platform.zig");
pub const renderer = @import("renderer/renderer.zig");
/// Linux backend (Wayland/X11); an empty namespace on other targets.
pub const linux_platform = if (@import("builtin").os.tag == .linux) @import("platform/linux/linux.zig") else struct {};
/// macOS backend (AppKit + Metal + CoreText); an empty namespace on other targets.
pub const mac_platform = if (@import("builtin").os.tag == .macos) @import("platform/mac/mac.zig") else struct {};
/// The Windows backend (Win32 + D3D11/DirectComposition + DirectWrite); see src/platform/windows/windows.zig.
pub const windows_platform = if (@import("builtin").os.tag == .windows) @import("platform/windows/windows.zig") else struct {};
pub const text = @import("text/text.zig");
/// Image decoding, SVG rendering, image cache and object-fit (src/image/).
pub const image = @import("image/image.zig");
/// Low-latency sound-effect playback (src/audio/); also the standalone `zpui_audio` module.
pub const audio = @import("audio/audio.zig");

pub const style = @import("style.zig");
pub const Style = style.Style;
pub const StyleRefinement = style.StyleRefinement;
pub const TextStyle = style.TextStyle;
pub const TextStyleRefinement = style.TextStyleRefinement;
pub const BoxShadow = style.BoxShadow;
pub const Refinement = style.Refinement;
pub const styled = @import("styled.zig");
pub const Styled = styled.Styled;
pub const StyleBuilder = styled.StyleBuilder;

/// Reactive core: App, entities, contexts, executors, actions, keymap (docs/core-model.md).
pub const core = @import("app/mod.zig");
pub const App = core.App;
pub const Context = core.Context;
pub const Entity = core.Entity;
pub const WeakEntity = core.WeakEntity;
pub const AnyEntity = core.AnyEntity;
pub const EntityId = core.EntityId;
pub const Subscription = core.Subscription;
pub const Subscriptions = core.Subscriptions;
pub const Task = core.Task;
pub const action = core.action.action;
pub const AnyAction = core.AnyAction;
pub const KeyContext = core.KeyContext;
pub const KeyBinding = core.KeyBinding;
pub const Keymap = core.Keymap;
pub const Listener = core.Listener;
pub const WindowHandle = core.app.WindowHandle;
/// App lifecycle + menu bar (src/app/lifecycle.zig): `app.setMenus(&.{ zpui.Menu{...} })`.
pub const lifecycle = core.lifecycle;
pub const Menu = lifecycle.Menu;
pub const MenuItem = lifecycle.MenuItem;
/// What an `app.onQuitAsync` listener returns (gpui `on_app_quit` future).
pub const QuitTeardown = lifecycle.QuitTeardown;

/// Windows, the element protocol, views, focus, paint API (docs/elements.md).
pub const window = @import("window/window.zig");
pub const Window = window.Window;
pub const WindowOptions = window.WindowOptions;
pub const WindowId = window.WindowId;
pub const Hitbox = window.Hitbox;
pub const HitboxBehavior = window.HitboxBehavior;
pub const ContentMask = window.ContentMask;
pub const EdgeFade = window.EdgeFade;
pub const DispatchPhase = window.DispatchPhase;
pub const AnyElement = window.element.AnyElement;
pub const ElementId = window.element.ElementId;
pub const GlobalElementId = window.element.GlobalElementId;
pub const LayoutId = window.element.LayoutId;
pub const AvailableSpace = window.element.AvailableSpace;
pub const intoAnyElement = window.element.intoAnyElement;
pub const empty = window.element.empty;
pub const AnyView = window.view.AnyView;
/// Files dragged in from other apps (`div().onDrop(ExternalPaths, l)`).
pub const ExternalPaths = @import("window/external_paths.zig").ExternalPaths;
pub const FocusHandle = window.focus_mod.FocusHandle;
pub const events = @import("window/events.zig");
pub const ClickEvent = events.ClickEvent;
pub const DragMoveEvent = events.DragMoveEvent;
pub const RenderImage = image.RenderImage;
pub const ImageSource = image.ImageSource;
/// App-owned image cache / SVG renderer glue (`setAssetSource`, `evict`).
pub const images = window.image;
pub const ElementInputHandler = window.input_handler.ElementInputHandler;
pub const PaintQuad = window.paint_mod.PaintQuad;
pub const fill = window.paint_mod.fill;
pub const outline = window.paint_mod.outline;
pub const quad = window.paint_mod.quad;
/// `std.fmt.allocPrint` into the frame arena (valid until the frame is presented).
pub const fmt = window.arena_mod.fmt;

/// Built-in elements: div, text, canvas, deferred, anchored, img, svg.
pub const elements = @import("elements/mod.zig");
/// Accessibility tree (`div().id(..).role(.button).ariaLabel("Save")`, src/a11y.zig).
pub const a11y = @import("a11y.zig");
pub const Role = a11y.Role;
pub const div = elements.div;
pub const Div = elements.Div;
pub const StatefulDiv = elements.StatefulDiv;
pub const ScrollHandle = elements.ScrollHandle;
pub const StyledText = elements.StyledText;
pub const InteractiveText = elements.InteractiveText;
pub const Highlight = elements.Highlight;
pub const styledText = elements.styledText;
pub const canvas = elements.canvas;
/// Render children from the element's laid-out size (gpui `container_query`).
pub const containerQuery = elements.containerQuery;
pub const ContainerQuery = elements.ContainerQuery;
/// Host a native child view at an element's bounds (`platform.NativeViewId`).
pub const nativeView = elements.nativeView;
pub const nativeViewWith = elements.nativeViewWith;

/// Native form controls (macOS AppKit controls; zpui-drawn fallbacks elsewhere;
/// src/elements/native_control.zig).
pub const native_control = elements.native_control;
pub const nativeSwitch = elements.native_control.nativeSwitch;
pub const nativeCheckbox = elements.native_control.nativeCheckbox;
pub const nativeSlider = elements.native_control.nativeSlider;
pub const nativeSegmented = elements.native_control.nativeSegmented;
pub const nativePopup = elements.native_control.nativePopup;
pub const native_popover = elements.native_popover;
pub const nativePopover = elements.nativePopover;
pub const NativePopover = elements.NativePopover;
pub const NativePopoverOptions = elements.native_popover.Options;
pub const PopoverAnchor = elements.native_popover.Anchor;
pub const popoverContent = elements.popoverContent;
pub const nativeStepper = elements.native_control.nativeStepper;
pub const nativeControlsAvailable = elements.native_control.nativeControlsAvailable;
/// Drawn libadwaita / Breeze controls for `native*` elements where the platform has none
/// (opt-in: `Window.setDesktopControls`; src/elements/desktop_controls.zig) and the
/// per-desktop preference-page blocks (src/elements/prefs.zig).
pub const desktop_controls = elements.desktop_controls;
pub const desktop_theme = elements.desktop_theme;
pub const prefs = elements.prefs;
pub const NativeControlEvent = elements.native_control.Event;
pub const NativeViewId = platform.NativeViewId;
/// Native context menus (macOS NSMenu; false elsewhere so callers draw their own;
/// src/window/context_menu.zig).
pub const context_menu = @import("window/context_menu.zig");
pub const showContextMenu = context_menu.show;
pub const contextMenusAvailable = context_menu.supported;
pub const ContextMenuItem = context_menu.MenuItem;
pub const ContextMenuSelection = context_menu.Selection;
/// [liquid-glass] Native Liquid Glass (macOS 26+; src/elements/liquid_glass.zig).
pub const liquid_glass = elements.liquid_glass;
pub const liquidGlass = elements.liquidGlass;
pub const liquidGlassGroup = elements.liquidGlassGroup;
pub const overlayPlane = elements.overlayPlane;
pub const platformSupportsLiquidGlass = elements.platformSupportsLiquidGlass;
pub const liquidGlassRevision = elements.liquid_glass.liquidGlassRevision;
pub const sidebarMaterial = elements.liquid_glass.sidebarMaterial;
pub const backdropHole = elements.liquid_glass.backdropHole;
pub const LiquidGlassStyle = platform.LiquidGlassStyle;
pub const deferred = elements.deferred;
pub const anchored = elements.anchored;
pub const img = elements.img;
pub const svg = elements.svg;
/// System symbols (macOS SF Symbols) as tinted icons: `systemSymbol(name, opts)`,
/// `svg().symbol(name, opts)` with the SVG as fallback, `system_symbols.setResolver`
/// (src/window/system_symbol.zig).
pub const systemSymbol = elements.systemSymbol;
pub const system_symbols = @import("window/system_symbol.zig");
pub const SystemSymbolOptions = system_symbols.Options;
pub const Svg = elements.Svg;
pub const StatefulSvg = elements.StatefulSvg;
pub const SvgTransformation = elements.SvgTransformation;
pub const list = elements.list;
pub const List = elements.List;
pub const ListState = elements.ListState;
pub const ListOffset = elements.ListOffset;
pub const ListAlignment = elements.ListAlignment;
pub const ListScrollEvent = elements.ListScrollEvent;
pub const ListSizingBehavior = elements.ListSizingBehavior;
pub const FollowMode = elements.FollowMode;
pub const Range = elements.Range;
pub const uniformList = elements.uniformList;
pub const UniformList = elements.UniformList;
pub const UniformListScrollHandle = elements.UniformListScrollHandle;
pub const ScrollStrategy = elements.ScrollStrategy;
pub const animation = elements.animation;
pub const Animation = elements.Animation;
pub const Easing = elements.Easing;
pub const easing = elements.easing;
pub const withAnimation = elements.withAnimation;
pub const withAnimationCtx = elements.withAnimationCtx;
pub const withAnimations = elements.withAnimations;
pub const scrollbar = elements.scrollbar;
pub const Scrollbar = elements.Scrollbar;
pub const ScrollbarStyle = elements.ScrollbarStyle;
pub const ScrollbarMode = elements.ScrollbarMode;
pub const ScrollbarAxis = elements.ScrollbarAxis;
pub const TailReservation = elements.TailReservation;
/// Edge fade / frost / layer wrappers (src/elements/effects.zig).
pub const effects = elements.effects;
pub const edgeFaded = elements.edgeFaded;
pub const frosted = elements.frosted;
pub const layered = elements.layered;
/// The frame arena allocator (valid until the frame is presented).
pub const frameAllocator = window.arena_mod.frameAllocator;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("window/tests.zig");
    _ = @import("window/system_symbol_tests.zig");
    _ = @import("image/system_symbol.zig");
    _ = @import("window/external_paths.zig");
    _ = @import("a11y.zig");
    _ = @import("window/a11y_tests.zig");
    _ = @import("window/context_menu_tests.zig");
    _ = @import("window/native_popover_tests.zig");
    _ = @import("platform/desktop.zig");
    if (@import("builtin").os.tag == .linux) {
        _ = @import("platform/linux/global_input.zig");
        _ = @import("platform/linux/tray.zig");
    }
}
