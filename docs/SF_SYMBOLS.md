# SF Symbols for zeron's icons (macOS)

On macOS the Zig client draws its control icons as Apple's SF Symbols instead of
zeron's SVG set. **Settings → Appearance → Use SF Symbols** turns it on and off
(on by default, macOS only); off restores the SVGs exactly.

## How it works

- **zpui** (`src/window/system_symbol.zig`, `src/image/system_symbol.zig`,
  `src/platform/mac/system_symbol.zig`): `Platform.renderSystemSymbol` renders
  `NSImage(systemSymbolName:accessibilityDescription:)` configured with
  `NSImageSymbolConfiguration(pointSize:weight:scale:)` into a CGBitmapContext at
  device scale and keeps the alpha channel. The mask goes into the monochrome
  sprite atlas (`AtlasKey.symbol`: symbol, point size, weight, scale, fit box,
  device scale) and paints as a `MonochromeSprite` in the element's text color,
  exactly like an SVG icon, so hover/active tints and opacity work unchanged.
  A symbol the OS lacks returns null; the miss is cached and the caller's SVG paints.
  Linux has no backend (always the SVG); the TestPlatform fakes a configurable
  set of symbols (`system_symbols`) for tests (`src/window/system_symbol_tests.zig`).
- **API**: `zpui.systemSymbol(name, opts)` (symbol only), `svg().source(..).symbol(name, opts)`
  / `.symbols(&.{a, b}, opts)` (symbol with fallbacks, then the SVG), and
  `zpui.system_symbols.setResolver(app, r)`: a hook every `svg()` consults with its
  path and size; `available(app, name, opts)` checks a symbol.
- **zeron** (`apps/zeron/src/ui/components/icon_symbols.zig`, exposed as
  `icon.symbols`): the table below, registered at launch by
  `icon.installSystemSymbols(app)`. Because it is a resolver keyed by icon path, every
  `icons/*.svg` svg switches, including the markdown, transcript and composer call
  sites that build their svg themselves; no call site changes.
- **Sizing**: point size = 0.8 × the icon box (rounded to 0.5 pt), so the usual
  16–17 px boxes beside 13–14 pt text get the text's optical size; regular weight
  (medium at 12 px boxes and below), medium symbol scale. The symbol is centered in
  the icon's box and scaled down to fit it, so layout boxes are identical and nothing
  shifts or overflows.
- **Setting**: `model.sf_symbols`, stored in its own `sf-symbols.json`
  (`{"enabled": true}`) in the data dir. The Rust app rewrites `ui-settings.json` from
  a typed struct and drops unknown keys, so the sidecar file keeps the Rust app safe.
  Fixture runs read it from `ZERON_FIXTURE_SETTINGS_DIR`.

All symbols below exist in SF Symbols 4 (macOS 13) unless a fallback is listed; the
first name the running macOS has wins, and the SVG is the last fallback.

## Mapping

**Composer + toolbar**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `microphone` | `mic` | — |
| `microphone-off` | `mic.slash` | — |
| `phone-hang-up` | `phone.down` | — |
| `fast-tier` | `bolt` | — |
| `fast-tier-bold` | `bolt.fill` | — |
| `paperclip` | `paperclip` | — |
| `queue-paperclip` | `paperclip` | — |
| `queue-send` | `arrow.right` | — |
| `queue-check` | `checkmark` | — |
| `queue-close` | `xmark` | — |
| `stop` | `stop.fill` (×0.9 size) | — |
| `return` | `return` | — |
| `command` | `command` | — |
| `keyboard` | `keyboard` | — |
| `key-minimalistic` | `key` | — |
| `tuning` | `slider.vertical.3` | — |
| `settings` | `gearshape` | — |
| `settings-minimalistic` | `slider.horizontal.3` | — |
| `magic-stick-3` | `wand.and.stars` | — |

**Appearance + devices**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `monitor` | `display` | — |
| `sun` | `sun.max` | — |
| `moon` | `moon` | — |
| `laptop` | `laptopcomputer` | — |
| `smartphone` | `iphone` | — |
| `remote-server` | `server.rack` | — |
| `hard-drive` | `internaldrive` | — |
| `home` | `house` | — |
| `cloud` | `cloud` | — |
| `globe` | `globe.americas` | `globe` |
| `global` | `globe` | — |
| `wifi-off` | `wifi.slash` | — |

**Sidebar, threads, sessions**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `pen-new-square` | `square.and.pencil` | — |
| `pen` | `pencil` | — |
| `pin` | `pin` | — |
| `archive-minimalistic` | `archivebox` | — |
| `archive-up-minimalistic` | `tray.and.arrow.up` | — |
| `trash-bin-minimalistic` | `trash` | — |
| `more-horizontal` | `ellipsis` | — |
| `sort` | `line.3.horizontal.decrease` | — |
| `sort-vertical` | `arrow.up.arrow.down` | — |
| `list` | `text.alignleft` | — |
| `checklist` | `checklist` | `list.bullet` |
| `clock-circle` | `clock` | — |
| `calendar` | `calendar` | — |
| `chat-round-line` | `text.bubble` | `bubble.left` |
| `bell` | `bell` | — |
| `volume-loud` | `speaker.wave.2` | — |
| `star` | `star` | — |
| `star-bold` | `star.fill` | — |
| `tag` | `tag` | — |
| `eye` | `eye` | — |
| `eye-closed` | `eye.slash` | — |
| `logout-2` | `rectangle.portrait.and.arrow.right` | — |
| `widget` | `square.grid.2x2` | — |
| `gallery` | `photo` | — |

**Files + git**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `folder` | `folder` | — |
| `folder-with-files` | `folder` | — |
| `file-tree` | `list.bullet.indent` | — |
| `document` | `doc` | — |
| `document-add` | `doc.badge.plus` | — |
| `copy` | `doc.on.doc` | — |
| `floppy-disk` | `square.and.arrow.down` | — |
| `git-branch` | `arrow.triangle.branch` | — |
| `fork` | `arrow.triangle.branch` | — |
| `pull-request` | `arrow.triangle.pull` | — |
| `split-columns` | `rectangle.split.2x1` | — |
| `fold-vertical` | `arrow.down.and.line.horizontal.and.arrow.up` | `rectangle.compress.vertical` |
| `terminal` | `terminal` | — |

**Navigation**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `arrow-left` | `arrow.left` | — |
| `arrow-right` | `arrow.right` | — |
| `arrow-up` | `arrow.up` | — |
| `arrow-down` | `arrow.down` | — |
| `arrow-up-right` | `arrow.up.right` | — |
| `alt-arrow-down` | `chevron.down` | — |
| `alt-arrow-up` | `chevron.up` | — |
| `alt-arrow-left` | `chevron.left` | — |
| `alt-arrow-right` | `chevron.right` | — |
| `expand-arrows` | `arrow.up.left.and.arrow.down.right` | — |
| `collapse-arrows` | `arrow.down.right.and.arrow.up.left` | — |
| `sidebar-minimalistic` | `sidebar.right` | — |
| `sidebar-minimalistic-left` | `sidebar.left` | — |
| `refresh` | `arrow.clockwise` | — |
| `restart` | `arrow.counterclockwise` | — |
| `magnifer` | `magnifyingglass` | — |
| `palette-search` | `magnifyingglass` | — |

**Status**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `plus` | `plus` | — |
| `add-circle` | `plus.circle` | — |
| `close` | `xmark` | — |
| `close-circle` | `xmark.circle` | — |
| `check` | `checkmark` | — |
| `info-circle` | `info.circle` | — |
| `danger-triangle` | `exclamationmark.triangle` | — |

**Project actions**

| zeron icon | SF Symbol | Fallback |
|---|---|---|
| `action-play` | `play` | — |
| `action-test` | `flask` | `testtube.2` |
| `action-lint` | `text.badge.checkmark` | — |
| `action-configure` | `slider.horizontal.3` | — |
| `action-build` | `shippingbox` | — |
| `action-debug` | `ant` | — |

## Kept as SVG

| zeron icon | Why |
|---|---|
| `zeron-logo`, `claude-mark`, `openai-mark`, `cursor-mark`, `devin-mark`, `grok-mark`, `hermes-mark`, `pi-mark`, `opencode-mark`, `antigravity-mark` | Brand marks |
| `file-code`, `file-style`, `file-data`, `file-markdown`, `file-image` | File-type glyphs (transcript badges); vscode-symbols file icons are images, not icons |
| `project-default` | `< >` without the slash; `chevron.left.forwardslash.chevron.right` reads as "code", not a project |
| `drag-handle`, `queue-drag-handle` | Six-dot grips; SF has no grip that small and crisp |
| `wrap-text` | No line-wrap symbol |
| `worktree` | No worktree symbol (`arrow.triangle.branch` is taken by branches) |
| `bot` | No robot/agent head symbol |
| `window-minimize`, `window-maximize`, `window-restore` | Linux client-side caption glyphs, never drawn on macOS |

The sidebar toggles in the titlebar are drawn from quads (`icon.sidebarGlyph`, an
animated morph), not SVGs, so they are unaffected; `sidebar-minimalistic[-left]` svgs
elsewhere map to `sidebar.right` / `sidebar.left`.

A test (`icon_symbols.zig`) fails when an icon is added to `assets.zig` without
either a mapping or a `keep_svg` entry.
