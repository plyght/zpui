# Liquid Glass (macOS 26+)

zpui and the zeron client can show Apple's **native** Liquid Glass
(`NSGlassEffectView`, `NSGlassEffectContainerView`). Nothing is imitated with shaders:
where the OS lacks these classes (Linux, Windows, macOS 15 and older) nothing changes,
and zeron keeps its frosted look.

**On macOS 26 and later it is the default**: the Glass preference "Theme default"
resolves to Liquid Glass there (for themes that recommend glass). An explicit
**Frosted** or **Opaque** choice is respected. Linux, Windows and macOS 15 and older
are unchanged and stay pixel-identical to the Rust zeron client. So does the headless
test platform, which only pretends to support glass.

## Trying it on a macOS 26 / 27 Mac

```sh
# From the repo root, with Zig 0.17.0:
zig build run-zeron -- --fixtures apps/zeron/fixtures/reference
```

zeron prints `zeron: liquid glass on (macOS 26): sidebar=glass layout=floating` (or
`macOS 27 … layout=flush`) and the accessibility flags. To compare with the frosted
look, open **Settings** (⌘,) → **Appearance** → **Glass** → **Frosted**, or run with
`ZERON_LIQUID_GLASS=0`, which keeps "Theme default" frosted for one run. An explicit
**Liquid Glass** choice is saved to `ui-settings.json` as `"surface":"liquid"`. In
fixture mode the settings stay in memory.

To force it for one run regardless of the setting:

```sh
ZERON_LIQUID_GLASS=1 zig build run-zeron -- --fixtures apps/zeron/fixtures/reference
```

zeron prints `zeron: liquid glass forced: native (NSGlassEffectView)` on macOS 26, or
`... unsupported, frosted fallback` elsewhere. Add `--light` or `--dark` to pick the
appearance.

Where the glass appears in zeron:

| Surface | Liquid Glass | Default (frosted) |
|---|---|---|
| Sidebar | Glass pane that shows the **desktop**: floating, inset 8 px (macOS 26), or flush with the window edges (macOS 27) | Wash column + hairline |
| Titlebar | No strip. One glass **capsule per item group**: the title, the session actions, "Add action", the pane toggles, and (sidebar collapsed) the sidebar-toggle/back/forward group next to the traffic lights. A soft fade under the band, drawn in Metal | Transparent band |
| Composer pill, question wizard, queue/todo panels | Glass | Backdrop blur + tint |
| Popovers, menus, model picker, tooltips, dialogs | Floating glass | Backdrop blur + tint |
| Command palette, add-project palette | Floating glass | Backdrop blur + tint |

Fills that would hide the glass are reduced to a faint wash (`Theme.onGlass`, at most
10 % alpha), and hairline borders are dropped (`Theme.onGlassBorder`). The glass draws
its own rim. The token math is the frosted theme's (`SurfacePreference.liquid`
resolves to `.frosted`).

The window background elsewhere is unchanged: on macOS zeron's window is a
behind-window `NSVisualEffectView` (`ZPUIBlurredView`) plus the theme's glass tint, and
the transcript keeps that dark/light surface. Replacing the whole window background
with an `NSGlassEffectView` was considered and left out: Apple reserves glass for the
navigation and controls layer, not for content backgrounds.

## What changed after the first real-Mac run

Feedback from a real macOS 26 Mac: glass on menus and popovers looked right, but

1. the sidebar glass refracted the app's own background instead of the desktop,
2. the titlebar had a full-width glass strip, and the chat title was missing, and
3. with the sidebar collapsed the top bar looked "better but not the best".

What zeron does now:

* **The sidebar shows the desktop.** Glass samples whatever is composited beneath it.
  Before, that was zeron's window tint and wash. Now zpui paints the tint only *around*
  the pane, leaving alpha 0 under it: a ring of tint whose inner edge is the pane's
  rounded rect, plus the main area. In the default `glass` mode the same rounded rect
  is cut out of the window's behind-window blur (`zpui.backdropHole`, the blurred view's
  `maskImage`). The window is non-opaque with a clear background and the CAMetalLayer is
  non-opaque and premultiplied (unchanged), so the glass samples the wallpaper
  directly. The gutters around a floating pane keep the window tint, like Finder's.
* **Two sidebar recipes**, selectable at run time so you can compare them:

  | `ZERON_SIDEBAR_GLASS=` | What sits under the pane | On top |
  |---|---|---|
  | `glass` (default) | nothing: a hole through zpui's surface **and** the window blur | `NSGlassEffectView`, `.regular` |
  | `vev` | AppKit's behind-window `NSVisualEffectView` (`.sidebar`, follows the window's active state) under zpui's transparent region | `NSGlassEffectView`, `.clear` (rim and refraction only) |

  `vev` is the robust pre-Tahoe recipe. AppKit always punches behind-window vibrancy
  through, so use it if pure glass shows nothing (black or grey) on your Mac.
* **Layout.** `floating` puts the pane 8 px from the window edges with radius 12, as
  on Tahoe. `flush` follows the WWDC26 sidebar: it runs to the top, left and bottom
  window edges with a square inner edge and a hairline seam, and the window's own
  corner mask rounds its outer corners. The default is `floating` on macOS 26 and
  `flush` on macOS 27 (`zpui.liquidGlassRevision`).
  `ZERON_SIDEBAR_LAYOUT=floating|flush` overrides it.
* **Titlebar: capsules, not a strip** (Option B in the research notes). zeron keeps its
  Metal-drawn titlebar, and each item group sits in its own capsule of native glass
  (30 px high, centred on the controls). All capsules are members of one
  `NSGlassEffectContainerView` (`spacing` 6), so neighbours that come close, for
  example while the sidebar collapses, melt into each other. Their content is each
  capsule's foreground, painted on the plane *above* the glass. That fixes the missing
  title. The nav group (sidebar toggle, back, forward, +) gets a capsule only when the
  sidebar no longer lies under it; over the sidebar it sits bare on the pane, as on
  Tahoe. Capsules for buttons set `effectIsInteractive` on macOS 27. A soft
  scroll-edge fade (the window tint fading to transparent over 50 px) is drawn in
  Metal over the transcript under the band.
* **macOS 27 tint:** 27 renders near-opaque glass tints as a solid fill, so zpui caps a
  glass `tint`'s alpha at 0.3 there. zeron's chrome glass uses no tint.

### Comparing the modes on your Mac

```sh
F="--fixtures apps/zeron/fixtures/reference"
zig build zeron
./zig-out/bin/zeron $F                                              # default: glass, by-OS layout
ZERON_SIDEBAR_GLASS=vev ./zig-out/bin/zeron $F                      # AppKit sidebar material + clear glass
ZERON_SIDEBAR_LAYOUT=flush ./zig-out/bin/zeron $F                   # macOS 27 style on 26
ZERON_SIDEBAR_LAYOUT=floating ./zig-out/bin/zeron $F                # macOS 26 style on 27
ZERON_LIQUID_GLASS=0 ./zig-out/bin/zeron $F                         # frosted, for reference
```

Move the window over a colourful part of the wallpaper. The sidebar should take on the
wallpaper's colours, and the transcript should keep zeron's dark or light surface.

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
  is composited beneath it: zpui's drawing, or, where zpui leaves alpha 0 and the
  behind-window blur has a hole (`zpui.backdropHole`), the desktop.
* The content that sits *on* the glass (text, icons, hover washes) is painted into a
  transparent Metal layer above it. Glass geometry and both Metal planes are presented
  in the same Core Animation transaction, so they never drift apart.
* Menus and popovers get their own tier above the first overlay plane, so a menu's
  glass covers the sidebar's text below it.
* The glass never takes the mouse. All input still goes through zpui's hit testing.
* zpui API: `zpui.liquidGlass`, `zpui.liquidGlassGroup`, `zpui.overlayPlane`,
  `zpui.platformSupportsLiquidGlass`, `zpui.liquidGlassRevision`, `zpui.backdropHole`,
  `zpui.sidebarMaterial`, `zpui.liquid_glass.paintGlass`. See `docs/elements.md` §5c.
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
  Before capturing, it tries to switch Reduce Transparency off (`defaults write
  com.apple.universalaccess reduceTransparency -bool false`, user, `-currentHost` and
  sudo, then `killall cfprefsd`). The app's `accessibility reduceTransparency=` line
  says whether that took. If it did not, the captures are solid, which is expected and
  does not fail the job. It also captures the sidebar variants
  (`zeron-macos26-sidebar-{glass,vev}-floating.png`, `…-glass-flush.png`) with Liquid
  Glass as the default.
* CI `zeron-macos27` runs on the `xcode-27` image (macOS 27, arm64, public preview,
  `continue-on-error`). It runs the unit tests, a native build, and checks that the
  `LC_BUILD_VERSION` stamp has sdk 27.0 (`vtool`, `otool` and
  `apps/zeron/scripts/macho-build-version.py`). The Liquid Glass gate must report native
  glass at revision 27. It also builds for the bundle target `aarch64-macos.12.0` and
  checks minos 12.0. The smoke launch is informational: the runner has no real GPU.

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
  26.x it is skipped. zpui's glass never takes the mouse (zpui hit-tests), so AppKit
  may not animate it even on 27.
* The flush sidebar's outer corners use radius 12 and rely on the window's corner
  mask. AppKit does not let zpui read the window radius, so check those corners on 27.
* The backdrop hole is a stretchable mask image (1 px per point) on the window's
  behind-window blur. Its edge sits under the glass rim. While a hole is open, the black
  base under the blur (kept so Mission Control snapshots read solid) is dropped.
* The glass follows the window's effective `NSAppearance`. zeron's light and dark
  themes drive that appearance; custom themes with an unusual contrast may need tint
  tuning (`liquid_fill_alpha` in `apps/zeron/src/theme/theme.zig`).
* Developed and cross-compiled on Linux. The first version was checked on a real
  macOS 26 Mac (feedback above). The desktop-showing sidebar, the backdrop hole, the
  capsules and the 27 behaviour have **not** been run on a Mac yet; see the checklist
  below.

## macOS 27 (Golden Gate)

* **SDK stamp.** AppKit enables the new design, and macOS 27's linked-on behaviours,
  based on the SDK a binary was *linked* against: `LC_BUILD_VERSION.sdk`. Binaries
  linked against an SDK older than 26 run in compatibility mode with no Liquid Glass.
  Zig 0.17 stamps **sdk 27.0** on every Mac build that links libc, from its bundled
  `lib/libc/darwin/SDKSettings.json`. This does not depend on the installed Xcode, and
  `-Dmacos-sdk` only adds framework search paths.
  Verified here: a libc-linked `aarch64-macos` / `x86_64-macos` executable built on
  Linux reads `minos=15.0 sdk=27.0`, and with `-target …-macos.12.0` it reads
  `minos=12.0 sdk=27.0`.
  Check a binary with `vtool -show-build`, `otool -l | grep -A5 LC_BUILD_VERSION`, or
  `apps/zeron/scripts/macho-build-version.py`, which works anywhere.
* **minos.** A plain `-Dtarget=aarch64-macos` gives minos 15.0 (Zig 0.17's default
  macOS floor), and a native build gives the host's version. The Zeron.app bundle in CI
  now builds `-Dtarget={x86_64,aarch64}-macos.12.0`, which matches the Rust app's
  `LSMinimumSystemVersion` of 12.0 in `apps/zeron/dist/macos/Info.plist`.
  Everything newer is gated at run time: glass by
  `NSClassFromString("NSGlassEffectView")` plus an OS check, the revision by
  `isOperatingSystemAtLeastVersion:`, and 27-only selectors by `respondsToSelector:`.
* **Behaviour on 27:**
  * The sidebar defaults to `flush`.
  * Glass tint alpha is capped at 0.3.
  * Button capsules ask for `effectIsInteractive`.
  * The titlebar keeps zeron's soft fade. 27's "hard edge with a free-floating title"
    rule does not apply, because the title sits in a capsule.

## Checklist for your Mac (macOS 26 or 27)

1. `zig build run-zeron -- --fixtures apps/zeron/fixtures/reference` without any env
   var prints `zeron: liquid glass on (macOS 26|27): sidebar=glass layout=…`. Liquid
   Glass is now the default.
2. **Sidebar shows the desktop.** Drag the window over a colourful wallpaper. The
   sidebar pane should be tinted and lensed by the *wallpaper*, not by zeron's grey.
   The transcript area keeps its dark or light surface. The gutters around a floating
   pane are window-coloured.
   * If the pane is black, grey or empty, run with `ZERON_SIDEBAR_GLASS=vev` and tell us
     which one looks right.
   * Check the pane's rounded corners for crisp-desktop specks; there should be none.
3. **Layouts.** Compare `ZERON_SIDEBAR_LAYOUT=floating` and `=flush`.
   * Flush: the pane meets the window's left, top and bottom edges, with a straight seam
     and hairline on the right.
   * Floating: 8 px gutters all round.
4. **Titlebar, sidebar expanded.**
   * There is no full-width strip.
   * The chat **title is visible**, in its own capsule.
   * The new-side-chat and fork icons share a capsule. "Add action" is a capsule, and
     the files and right-pane toggles share one.
   * The toggle, back and forward buttons sit bare on the sidebar pane next to the
     traffic lights.
5. **Titlebar, sidebar collapsed (⌘\ or the toggle).** The toggle, back, forward and +
   buttons get a capsule right of the traffic lights, and the title capsule sits clear
   of it. During the collapse animation, neighbouring capsules may briefly melt
   together; that is intended.
6. **Scroll edge.** Scroll the transcript. Text passing under the titlebar fades
   softly, and there is no hard band.
7. Menus (sidebar ⋯, model picker, the composer's `/` and `@` popups), tooltips, the
   command palette (⌘K) and dialogs are glass and cover the sidebar text beneath them.
8. Resize the window and drag the sidebar seam. The glass, the hole in the blur and
   the capsules track the content in the same frame, without lag or flicker, and no
   crisp desktop shows at the seam.
9. Switch Settings → Glass between Theme default, Frosted and Liquid Glass. Frosted
   must look exactly as before.
10. Switch the system appearance between light and dark, and check text contrast on
    the sidebar and the capsules over a bright and a dark wallpaper.
11. Make the window inactive. The glass may go flat (by design), and the `vev`
    sidebar follows the window's active state.
12. Open the Browser pane (a WKWebView native child) with Liquid Glass on. Menus over
    the web view still work.
13. On macOS 27: `vtool -show-build zig-out/bin/zeron` shows `sdk 27.0`.
