# Liquid Glass (macOS 26+)

zpui and the zeron client can show Apple's **native** Liquid Glass
(`NSGlassEffectView`, `NSGlassEffectContainerView`). Nothing is imitated with shaders:
where the OS lacks these classes (Linux, Windows, macOS 15 and older) nothing changes,
and zeron keeps its frosted look.

It is **opt-in**. The default stays pixel-identical to the Rust zeron client.

## Trying it on a macOS 26 Mac

```sh
# From the repo root, with Zig 0.17.0:
zig build run-zeron -- --fixtures apps/zeron/fixtures/reference
```

Then open **Settings** (⌘,) → **Appearance** → **Glass** → **Liquid Glass**. The
option is listed only when the running OS supports it. The choice is saved to
`ui-settings.json` as `"surface":"liquid"`. In fixture mode the settings stay in memory.

To try it for one run without touching the settings:

```sh
ZERON_LIQUID_GLASS=1 zig build run-zeron -- --fixtures apps/zeron/fixtures/reference
```

zeron prints `zeron: liquid glass forced: native (NSGlassEffectView)` on macOS 26, or
`... unsupported, frosted fallback` elsewhere. Add `--light` or `--dark` to pick the
appearance.

Where the glass appears in zeron:

| Surface | Liquid Glass | Default (frosted) |
|---|---|---|
| Sidebar | Floating glass pane, inset 8 px | Wash column + hairline |
| Titlebar band (right of the sidebar) | Glass strip; content scrolls under it | Transparent band |
| Composer pill, question wizard, queue/todo panels | Glass | Backdrop blur + tint |
| Popovers, menus, model picker, tooltips, dialogs | Floating glass | Backdrop blur + tint |
| Command palette, add-project palette | Floating glass | Backdrop blur + tint |

Fills that would hide the glass are reduced to a faint wash (`Theme.onGlass`, at most
10 % alpha), and hairline borders are dropped (`Theme.onGlassBorder`). The glass draws
its own rim. The token math is the frosted theme's (`SurfacePreference.liquid`
resolves to `.frosted`).

The window background is unchanged. On macOS zeron's window is already a
behind-window `NSVisualEffectView` (`ZPUIBlurredView`) plus the theme's glass tint, so
the glass refracts the blurred desktop and app content, which matches the HIG's "glass
floats over content" model. Replacing the window background with an
`NSGlassEffectView` was considered and left out: Apple reserves glass for the
navigation and controls layer, not for content backgrounds.

## How it works

The planes in the window's content view, back to front:

```
main Metal surface      zpui content: window tint, transcript, panels
base glass views        NSGlassEffectView (sidebar, titlebar, composer), pass-through
overlay plane           transparent CAMetalLayer: foreground of base glass, menus' scrim
floating glass views    NSGlassEffectView for menus / popovers / tooltips / palette
top plane               transparent CAMetalLayer: foreground of floating glass
```

* Glass is a native child view placed **above** the main surface. It samples whatever
  zpui drew beneath it, so it refracts real content, not an empty window.
* The content that sits *on* the glass (text, icons, hover washes) is painted into a
  transparent Metal layer above it. Glass geometry and both Metal planes are presented
  in the same Core Animation transaction, so they never drift apart.
* Menus and popovers get their own tier above the first overlay plane, so a menu's
  glass covers the sidebar's text below it.
* The glass never takes the mouse. All input still goes through zpui's hit testing.
* zpui API: `zpui.liquidGlass`, `zpui.liquidGlassGroup`, `zpui.overlayPlane`,
  `zpui.platformSupportsLiquidGlass`, `zpui.liquid_glass.paintGlass`. See
  `docs/elements.md` §5c.
* Runtime gate: `NSClassFromString("NSGlassEffectView")`, `NSGlassEffectContainerView`,
  and `-[NSProcessInfo isOperatingSystemAtLeastVersion:{26,0,0}]`. The answer is cached.
  Optional selectors (`setEffectIsInteractive:`, `setStyle:`, `setTintColor:`,
  `setCornerRadius:`, `setSpacing:`) are sent only if the object responds to them.

## Tests and CI

* Headless (Linux and macOS): `zig build zpui-test -Dtest-filter=liquid` covers element
  bookkeeping, tiers, groups, idle detach and the unsupported path.
  `zig build zeron-app-test` covers the settings gating
  (`apps/zeron/src/ui/settings/liquid_glass_tests.zig`). The test platform pretends
  that macOS 26 is present (`TestPlatform.liquid_glass_supported`).
* CI `zeron-app` (macos-15-intel) runs the app with `ZERON_LIQUID_GLASS=1` and asserts
  the frosted fallback.
* CI `zeron-liquid-glass-macos26` (macos-26-intel) runs the unit tests and a native
  glass smoke run, and uploads `zeron-macos26-liquid-{dark,light}.png`. It also runs
  the glass lab and the smoke run with `ZERON_SMOKE_DIAG=1`, and uploads the captures,
  the Metal readbacks and the logs as `glass-lab`.

## Why glass can look flat, and the glass lab

Liquid Glass shows what is *behind* it: it blurs, lenses and highlights the content
beneath its edges. Over a uniform surface it correctly renders as a near-uniform panel
(near-white in light mode, near-black in dark) with only a faint rim. zeron's chrome
mostly sits over its own window tint (`Theme.glass()`, high alpha in light mode) and a
plain transcript card, so screenshots of an idle zeron show little lensing even when
everything works. Other causes, and how to tell them apart:

| Cause | What you see | Evidence |
|---|---|---|
| Nothing varied behind the glass | flat panel, rim only | glass lab panels over stripes are *not* flat |
| Reduce Transparency / Increase Contrast | solid panels everywhere, also AppKit's own | `reduceTransparency=true` in the logs; the AppKit reference views are solid too |
| The capture path | window capture flat, display capture glassy | `-window.png` vs `-onscreen.png` / `-screencapture.png` |
| WindowServer without backdrop effects (VM GPU) | no blur even in the in-window `NSVisualEffectView` reference | `metal device:` line; reference views flat |
| zpui layering | zpui glass flat, the direct `NSGlassEffectView` reference glassy | layer-tree dump: opaque / masked / rasterized layer above the Metal surface |

Reduce Transparency is honoured the way AppKit does it: AppKit draws the glass (and
the window's behind-window material) solid, and zpui does not override that.
`ZPUIBlurredView` leaves AppKit's solid fill alone while the setting is on, and zeron
logs `zeron: accessibility reduceTransparency=...` when Liquid Glass is forced.

**Glass lab** (`ZERON_GLASS_LAB=1`, or `zig build glass-lab`): a window full of
gradient, diagonal stripes, saturated blocks, large text and a band that moves every
frame, with native glass over it (regular / clear, rounded / capsule, tinted, a merged
group). On macOS it adds three reference views that bypass zpui's hosting: an
`NSGlassEffectView` added straight to the content view, a within-window
`NSVisualEffectView`, and an AppKit-only scene (CALayer stripes under glass).

```sh
ZERON_GLASS_LAB=1 ZERON_GLASS_LAB_BG=opaque ./zig-out/bin/zeron --smoke-frames 90 --light
```

With `--smoke-frames N` it prints the diagnostics (accessibility flags, Metal device,
window and layer flags, each glass view's properties and private layer tree), writes
`zig-out/glass-lab/<bg>-<appearance>-{window,onscreen,display,screencapture}.png` and a
readback of zpui's Metal planes (`-metal-{main,overlay,top}.png`), and prints per-panel
numbers: the luminance spread inside each glass and its mean difference from the Metal
readback. `ZERON_SMOKE_DIAG=1` adds the same diagnostics and captures to the normal
zeron smoke test. CI uploads all of it as the `glass-lab` artifact.

## Known limitations

* Shapes are limited to a uniform corner radius or a capsule. Concave and per-corner
  shapes are not available natively; use a `liquidGlassGroup` to merge simple shapes.
* A partly scrolled-out glass view is clipped with a rectangular `masksToBounds`, not a
  rounded mask, because backdrop effects inside masked layers render offscreen.
* There is one plane per tier. Foreground content of two overlapping *base* glass
  views share the overlay plane, so the lower view's text would show through the upper
  glass. zeron's chrome does not overlap this way. Floating glass (menus) does cover
  base foregrounds correctly.
* Anything zpui paints on top of base glass must sit inside the glass element or in
  `zpui.overlayPlane(true, ...)`. Otherwise it renders on the main surface and ends up
  under the glass.
* In-scene backdrop blur (`frosted`) only sees its own plane. In Liquid Glass mode
  zeron routes every frosted surface to native glass, which avoids the problem.
* `effectIsInteractive` (press highlight) is documented by Apple for macOS 27. On
  26.x it is skipped.
* The glass follows the window's effective `NSAppearance`. zeron's light and dark
  themes drive that appearance; custom themes with an unusual contrast may need tint
  tuning (`liquid_fill_alpha` in `apps/zeron/src/theme/theme.zig`).
* Developed and cross-compiled on Linux. The AppKit code has not been run on a real
  macOS 26 machine yet; see the checklist below.

## Checklist for the first run on a macOS 26 Mac

1. `ZERON_LIQUID_GLASS=1 zig build run-zeron -- --fixtures apps/zeron/fixtures/reference`
   prints `native (NSGlassEffectView)`.
2. The sidebar shows as a floating glass pane. Its rows, text and hover washes are
   crisp and sit on top of the glass, and clicking rows works.
3. The titlebar strip and the composer pill are glass. Transcript text scrolling under
   the titlebar is visibly refracted or blurred.
4. Menus (sidebar ⋯, model picker, the composer's `/` and `@` popups), tooltips, the
   command palette (⌘K) and dialogs are glass and cover the sidebar text beneath them.
5. Resize the window and drag the sidebar seam: the glass tracks the content in the
   same frame, without lag or flicker.
6. Switch Settings → Glass between Frosted and Liquid Glass. Frosted must look exactly
   as before.
7. Switch the system appearance between light and dark, and check text contrast on
   glass.
8. Open the Browser pane (a WKWebView native child) with Liquid Glass on: menus over
   the web view still work.
