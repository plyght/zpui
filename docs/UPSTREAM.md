# Upstream tracking

zpui ports [zui](https://github.com/zeronsh/zui) (zeronsh's gpui fork) and `apps/zeron` ports the
[zeron](https://github.com/zeronsh/zeron) desktop client. Both upstreams keep moving, so we pin the
revision we ported from and diff forward from there.

## Pinned revisions

| upstream | repo | pinned | date | what tracks it |
|---|---|---|---|---|
| zui | https://github.com/zeronsh/zui | `667d0aaf9531d2d1b2d0674a5e55f977df1b09f6` | 2026-09-30 | `src/**` (zpui) |
| zeron | https://github.com/zeronsh/zeron | `9e1a11158b0626237c814f4bd36f5948483ed797` | 2026-10-02 | `apps/zeron/**` |
| gpui-component | https://github.com/zeronsh/gpui-component | `2f73e5c2bc03d6768cb5fcc92442c4cf4b963b70` | — | `apps/zeron/src/ui/editor/**`, `src/elements/scrollbar.zig` (optional) |

zeron's own `Cargo.toml` pins zui at the same `667d0aa` and gpui-component (`gpui-base`) at
`2f73e5c`, so the three pins agree today. The source of truth for the pins is
`tools/upstream/map.json` (`upstreams.*.pinned`); keep this table in sync when bumping.

The local zeron checkout at `/home/user/zeron` has `origin` = `plyght/zeron` (a mirror); the tracker
fetches `zeronsh/zeron` directly.

## The pieces

| file | role |
|---|---|
| `tools/upstream/map.json` | pins, the file-level map (upstream glob → Zig files + port status), generator inputs, version pins, watched Cargo.lock crates |
| `tools/upstream/check.py` | fetch, diff `pinned..HEAD`, group by Zig file, flag unmapped / not-ported changes and generators to re-run, write Markdown (+ JSON) |
| `.github/workflows/upstream.yml` | weekly (Mon 06:17 UTC) + manual; runs `check.py` and opens / updates one issue titled **Upstream changes to port** (closes it when everything is at the pins) |

## Running the check

```sh
# Fresh clones in .upstream-cache/ (git-ignored, partial clones), report on stdout:
python3 tools/upstream/check.py

# Reuse existing checkouts, write files:
python3 tools/upstream/check.py --local zui=/home/user/research/zui --local zeron=/home/user/zeron \
    --out upstream-report.md --json upstream-report.json

# Without network (uses whatever the clones already have), compare against a given rev:
python3 tools/upstream/check.py --offline --local zeron=/home/user/zeron --head zeron=origin/main

# Only one upstream; include the optional gpui-component diff:
python3 tools/upstream/check.py --only zui
python3 tools/upstream/check.py --include-optional

# Which upstream files have no specific mapping? (run after adding upstream files to the map)
python3 tools/upstream/check.py --coverage

# CI-style: exit 2 when there is anything to port
python3 tools/upstream/check.py --fail-on-changes
```

The report contains, per upstream:

1. a summary row (commits, changed files, how many are mapped / not ported / unmapped / need no port)
   with a compare link;
2. **Generators / parity dumps to re-run** — changed inputs of our generators, with the command;
3. **Version pins and dependency bumps** — zeron moving its zui / gpui-component pin (the zui diff is
   then what zeron itself picked up), and `Cargo.lock` bumps of crates we ported line-for-line
   (`pulldown-cmark` 0.12.2, `similar` 2.7.0, `tree-sitter` / `tree-sitter-highlight` 0.26.11, the
   `tree-sitter-*` grammars, plus `mermaid-rs-renderer` for information);
4. **changes by Zig file** — each heading is the Zig file(s) to edit, listing the upstream files that
   changed (+/− lines, link) and the mapping's status/note when it is a partial port;
5. **changes in areas not ported yet** — they widen the gap in `docs/PARITY.md`, nothing to port now;
6. **unmapped changes ⚠** — new upstream files (or files only a catch-all matched); add mappings;
7. collapsed lists of changed files that need no port and of the commits.

### Generators

| generator | upstream inputs | run | outputs |
|---|---|---|---|
| `scripts/gen_styled.py` | zui `crates/gpui_macros/src/styles.rs` | `python3 scripts/gen_styled.py --zui <zui>` | `src/style/styled_generated.zig`, `src/style/builder.zig` |
| shaders (manual) | zui `crates/gpui/src/scene.rs`, `gpui_macos/src/shaders.metal`, `gpui_wgpu/src/shaders*.wgsl`, `blur_kernel.rs` | re-sync `src/scene.zig` GPU structs, copy `shaders.metal` (keep the license header), hand-port WGSL to `src/renderer/vulkan/shaders/*.glsl`, `zig build test` | `src/scene.zig`, `src/renderer/metal/shaders.metal`, `src/renderer/vulkan/shaders/` |
| `apps/zeron/scripts/gen_themes.py` | zeron `crates/theme/src/builtins.rs` | `python3 apps/zeron/scripts/gen_themes.py <zeron> > apps/zeron/src/theme/builtins.zig` | `apps/zeron/src/theme/builtins.zig` |
| `apps/zeron/scripts/theme_parity.rs` | zeron `crates/theme/**`, `crates/ui/src/{theme,typography}.rs`, `settings/wallpaper_colors.rs` | build against a built zeron checkout (header of the script) | `apps/zeron/src/theme/parity_data.zig` |
| `apps/zeron/scripts/gen_assets.py` | zeron `crates/ui/src/icons.rs`, `crates/ui/src/file-icons.json`, `crates/ui/assets/**` | copy changed assets into `apps/zeron/assets/`, then `python3 apps/zeron/scripts/gen_assets.py <zeron> > apps/zeron/src/assets.zig` | `apps/zeron/src/assets.zig` |
| `apps/zeron/scripts/gen_methods.py` | zeron `crates/rpc/src/lib.rs`, `crates/engine/src/rpc.rs` | `python3 apps/zeron/scripts/gen_methods.py <zeron> > apps/zeron/src/engine/methods.zig` | `apps/zeron/src/engine/methods.zig` |
| `apps/zeron/scripts/view_parity.rs` | zeron `crates/proto/src/{view,entities}.rs` | build against a built zeron checkout | `apps/zeron/src/model/testdata/view_parity.json` |
| `gen_md_corpus.py` + `markdown_parity.rs` | zeron `crates/markdown/src/**` | see the script headers | `apps/zeron/src/markdown/testdata/` |
| `syntax_parity.rs` | zeron `crates/syntax/src/**` | see the script header | `apps/zeron/src/syntax/testdata/parity.json` |
| `gen_diff_corpus.py` + `diff_parity.rs` | zeron `crates/ui/src/changes.rs` | see the script headers | `apps/zeron/src/diff/testdata/` |

The `.rs` parity dumpers link against a zeron checkout's `target/debug/deps`, so run them from a
built checkout (`cargo build -p zeron-ui` in zeron), not the partial clone in `.upstream-cache/`.

## Porting workflow

1. Read the issue (or run `check.py`). Work through "changes by Zig file"; re-run the listed
   generators; port pin moves / dependency bumps.
2. Map any **unmapped** files in `tools/upstream/map.json` (and the table below). Use `n/a` for
   files that never need a port, `not-ported` with `"zig": []` for features we have not reached.
   When a not-ported area gets ported, fill in `zig` and set `status` to `ported` / `partial`, and
   update `docs/PARITY.md`.
3. Bump the pin: `python3 tools/upstream/check.py --bump zui` (or `zeron`), which writes the
   fetched head into `map.json`; update the table above; commit. The next weekly run closes the
   issue if nothing else moved.

### Map format

```json
{"upstream": "zeron", "pattern": "crates/ui/src/terminal/panel.rs",
 "zig": ["apps/zeron/src/terminal/session.zig", "apps/zeron/src/ui/shell/terminal_dock.zig"],
 "status": "partial", "note": "local PTY; engine OpenTerminal/SubscribeTerminal not wired"}
```

`pattern` is a glob relative to the upstream root (`*` within a segment, `**` any depth). The most
specific pattern wins (literal characters, then fewest wildcards). `catch_all: true` entries
(`crates/gpui/**`, `crates/gpui_macos/**`, `crates/gpui_linux/**`, `crates/ui/src/**`) only apply
when nothing else matches and are reported as **unmapped**. The map was built from both trees, the
`//!` doc comments in the Zig sources (agents cite the Rust files they port), and the generator
headers; `check.py --coverage` reports 0 uncovered files at the pinned revisions.

## File map (from `map.json`)

Zig paths for zeron are relative to the repo root. "partial" means the Zig file exists but misses
behavior (the note says what; `docs/PARITY.md` has the full picture).

### zui → zpui

| upstream path | Zig | status | note |
|---|---|---|---|
| `crates/gpui/src/action.rs` | `src/app/action.zig` | ported |  |
| `crates/gpui/src/app.rs` | `src/app/app.zig` | partial | no set_menus/on_open_urls/on_reopen/on_app_quit/prompt APIs on App |
| `crates/gpui/src/app/context.rs` | `src/app/context.zig` | ported |  |
| `crates/gpui/src/app/entity_map.rs` | `src/app/entity.zig` | ported |  |
| `crates/gpui/src/app/async_context.rs` | `src/app/executor.zig`, `src/app/context.zig` | partial | no futures; callbacks instead of async contexts |
| `crates/gpui/src/app/test_context.rs` | `src/app/test_platform.zig`, `src/app/app_tests.zig` | partial |  |
| `crates/gpui/src/app/test_app.rs` | `src/app/test_platform.zig` | partial |  |
| `crates/gpui/src/app/headless_app_context.rs` | `src/app/test_platform.zig` | partial |  |
| `crates/gpui/src/app/visual_test_context.rs` | — | **not ported** |  |
| `crates/gpui/src/arena.rs` | `src/window/arena.zig` | ported |  |
| `crates/gpui/src/asset_cache.rs` | `src/image/cache.zig` | partial |  |
| `crates/gpui/src/assets.rs` | `src/image/image.zig`, `src/image/cache.zig` | ported |  |
| `crates/gpui/src/bounds_tree.rs` | `src/bounds_tree.zig` | ported |  |
| `crates/gpui/src/color.rs` | `src/color.zig` | ported |  |
| `crates/gpui/src/colors.rs` | `src/color.zig` | partial |  |
| `crates/gpui/src/element.rs` | `src/window/element.zig` | ported |  |
| `crates/gpui/src/elements/anchored.rs` | `src/elements/anchored.zig` | ported |  |
| `crates/gpui/src/elements/animation.rs` | `src/elements/animation.zig` | ported |  |
| `crates/gpui/src/elements/canvas.rs` | `src/elements/canvas.zig` | ported |  |
| `crates/gpui/src/elements/deferred.rs` | `src/elements/deferred.zig` | ported |  |
| `crates/gpui/src/elements/div.rs` | `src/elements/div.zig` | ported |  |
| `crates/gpui/src/elements/img.rs` | `src/elements/img.zig` | ported |  |
| `crates/gpui/src/elements/list.rs` | `src/elements/list.zig` | ported |  |
| `crates/gpui/src/elements/svg.rs` | `src/elements/svg.zig` | ported |  |
| `crates/gpui/src/elements/text.rs` | `src/elements/text.zig` | ported |  |
| `crates/gpui/src/elements/uniform_list.rs` | `src/elements/uniform_list.zig` | ported |  |
| `crates/gpui/src/elements/image_cache.rs` | `src/image/cache.zig`, `src/window/image.zig` | ported |  |
| `crates/gpui/src/elements/mod.rs` | `src/elements/mod.zig` | ported |  |
| `crates/gpui/src/elements/container_query.rs` | — | **not ported** | used by zeron history.rs |
| `crates/gpui/src/elements/surface.rs` | `src/elements/native_view.zig` | **not ported** | CVPixelBuffer surfaces; native_view.zig is unrelated host for native child views |
| `crates/gpui/src/executor.rs` | `src/app/executor.zig` | ported |  |
| `crates/gpui/src/geometry.rs` | `src/geometry.zig` | ported |  |
| `crates/gpui/src/gestures.rs` | — | **not ported** | pinch/rotate gestures (zeron image_viewer.rs) |
| `crates/gpui/src/global.rs` | `src/app/app.zig` | ported |  |
| `crates/gpui/src/gpui.rs` | `src/zpui.zig` | ported |  |
| `crates/gpui/src/prelude.rs` | `src/zpui.zig` | ported |  |
| `crates/gpui/src/input.rs` | `src/window/input_handler.zig` | ported |  |
| `crates/gpui/src/inspector.rs` | — | **not ported** |  |
| `crates/gpui/src/interactive.rs` | `src/input.zig`, `src/window/events.zig`, `src/window/dispatch.zig` | ported |  |
| `crates/gpui/src/key_dispatch.rs` | `src/app/dispatch_tree.zig`, `src/window/dispatch.zig` | ported |  |
| `crates/gpui/src/keymap.rs` | `src/app/keymap.zig` | ported |  |
| `crates/gpui/src/keymap/binding.rs` | `src/app/keymap.zig` | ported |  |
| `crates/gpui/src/keymap/context.rs` | `src/app/key_context.zig` | ported |  |
| `crates/gpui/src/path_builder.rs` | `src/window/paint.zig`, `src/scene.zig` | partial | paintPath exists; no PathBuilder stroke/tessellation API |
| `crates/gpui/src/platform.rs` | `src/platform/platform.zig` | partial |  |
| `crates/gpui/src/platform/app_menu.rs` | `src/platform/mac/mac.zig` | **not ported** | zpui builds a fixed app menu; no MenuItem/set_menus model |
| `crates/gpui/src/platform/keyboard.rs` | `src/platform/linux/keyboard.zig`, `src/platform/mac/events.zig` | partial |  |
| `crates/gpui/src/platform/keystroke.rs` | `src/input.zig`, `src/app/keymap.zig` | ported |  |
| `crates/gpui/src/platform/popup.rs` | — | **not ported** |  |
| `crates/gpui/src/platform/scap_screen_capture.rs` | — | **not ported** |  |
| `crates/gpui/src/platform/test.rs` | `src/app/test_platform.zig` | ported |  |
| `crates/gpui/src/platform/test/**` | `src/app/test_platform.zig`, `src/text/test_platform.zig` | partial |  |
| `crates/gpui/src/platform/visual_test.rs` | — | **not ported** |  |
| `crates/gpui/src/platform_scheduler.rs` | `src/app/executor.zig` | partial |  |
| `crates/gpui/src/queue.rs` | `src/app/executor.zig` | partial |  |
| `crates/gpui/src/scene.rs` | `src/scene.zig` | ported | GPU structs must stay byte-compatible with both shader sets |
| `crates/gpui/src/shared_uri.rs` | `src/image/cache.zig` | partial |  |
| `crates/gpui/src/style.rs` | `src/style.zig`, `src/layout/style.zig` | ported |  |
| `crates/gpui/src/styled.rs` | `src/styled.zig` | ported |  |
| `crates/gpui/src/subscription.rs` | `src/app/subscriber_set.zig` | ported |  |
| `crates/gpui/src/svg_renderer.rs` | `src/image/svg.zig` | ported |  |
| `crates/gpui/src/tab_stop.rs` | `src/window/focus.zig` | ported |  |
| `crates/gpui/src/taffy.rs` | `src/layout/layout.zig`, `src/layout/flex.zig`, `src/layout/block.zig`, `src/layout/absolute.zig`, `src/layout/style.zig` | partial | pure-Zig flex/block engine; no grid |
| `crates/gpui/src/test.rs` | `src/app/test_platform.zig` | partial |  |
| `crates/gpui/src/text_system.rs` | `src/text/text_system.zig`, `src/text/types.zig` | ported |  |
| `crates/gpui/src/text_system/font_fallbacks.rs` | `src/text/fallback.zig` | ported |  |
| `crates/gpui/src/text_system/font_features.rs` | `src/text/types.zig`, `src/style.zig` | partial |  |
| `crates/gpui/src/text_system/line.rs` | `src/text/line.zig` | ported |  |
| `crates/gpui/src/text_system/line_layout.rs` | `src/text/line_layout.zig` | ported |  |
| `crates/gpui/src/text_system/line_wrapper.rs` | `src/text/line_wrapper.zig` | ported |  |
| `crates/gpui/src/util.rs` | `src/window/paint.zig` | partial |  |
| `crates/gpui/src/view.rs` | `src/window/view.zig` | ported |  |
| `crates/gpui/src/window.rs` | `src/window/window.zig`, `src/window/dispatch.zig`, `src/window/paint.zig`, `src/window/focus.zig` | ported |  |
| `crates/gpui/src/window/a11y.rs` | — | **not ported** | zeron sets roles/aria labels in ~35 files; zpui has no accessibility tree |
| `crates/gpui/src/window/a11y/**` | — | **not ported** |  |
| `crates/gpui/src/window/prompts.rs` | — | **not ported** |  |
| `crates/gpui/**` | — | **not ported** | unmapped gpui file |
| `crates/gpui_macos/src/dispatcher.rs` | `src/platform/mac/dispatcher.zig` | ported |  |
| `crates/gpui_macos/src/display.rs` | `src/platform/mac/mac.zig` | partial | no display uuid |
| `crates/gpui_macos/src/display_link.rs` | `src/platform/mac/display_link.zig` | ported |  |
| `crates/gpui_macos/src/events.rs` | `src/platform/mac/events.zig` | ported |  |
| `crates/gpui_macos/src/keyboard.rs` | `src/platform/mac/events.zig` | partial |  |
| `crates/gpui_macos/src/gpui_macos.rs` | `src/platform/mac/mac.zig` | ported |  |
| `crates/gpui_macos/src/metal_atlas.rs` | `src/atlas.zig`, `src/renderer/metal/renderer.zig` | ported |  |
| `crates/gpui_macos/src/metal_renderer.rs` | `src/renderer/metal/renderer.zig`, `src/renderer/metal/backdrop.zig`, `src/renderer/metal/instance_buffer_pool.zig` | ported |  |
| `crates/gpui_macos/src/shaders.metal` | `src/renderer/metal/shaders.metal` | ported | copied with a license header; also hand-port to src/renderer/vulkan/shaders/ |
| `crates/gpui_macos/src/open_type.rs` | `src/text/coretext.zig` | partial |  |
| `crates/gpui_macos/src/pasteboard.rs` | `src/platform/mac/mac.zig` | partial |  |
| `crates/gpui_macos/src/platform.rs` | `src/platform/mac/mac.zig` | partial | menus, prompts, URL scheme, notifications missing |
| `crates/gpui_macos/src/screen_capture.rs` | — | **not ported** |  |
| `crates/gpui_macos/src/system_notifications.rs` | — | **not ported** |  |
| `crates/gpui_macos/src/text_system.rs` | `src/text/coretext.zig` | ported |  |
| `crates/gpui_macos/src/window.rs` | `src/platform/mac/window.zig` | ported |  |
| `crates/gpui_macos/src/window_appearance.rs` | `src/platform/mac/appkit.zig` | ported |  |
| `crates/gpui_macos/build.rs` | `build.zig` | partial | shader compilation |
| `crates/gpui_macos/**` | `src/platform/mac/mac.zig` | partial | unmapped gpui_macos file |
| `crates/gpui_linux/src/gpui_linux.rs` | `src/platform/linux/linux.zig` | ported |  |
| `crates/gpui_linux/src/linux.rs` | `src/platform/linux/linux.zig` | ported |  |
| `crates/gpui_linux/src/linux/dispatcher.rs` | `src/platform/linux/dispatcher.zig` | ported |  |
| `crates/gpui_linux/src/linux/platform.rs` | `src/platform/linux/linux.zig`, `src/platform/linux/event_loop.zig` | ported |  |
| `crates/gpui_linux/src/linux/keyboard.rs` | `src/platform/linux/keyboard.zig` | ported |  |
| `crates/gpui_linux/src/linux/text_system.rs` | `src/text/freetype.zig` | ported |  |
| `crates/gpui_linux/src/linux/xdg_desktop_portal.rs` | `src/platform/linux/appearance.zig`, `src/platform/linux/dbus.zig`, `src/platform/linux/file_dialog.zig` | partial |  |
| `crates/gpui_linux/src/linux/system_notifications.rs` | — | **not ported** |  |
| `crates/gpui_linux/src/linux/wayland.rs` | `src/platform/linux/wayland.zig` | ported |  |
| `crates/gpui_linux/src/linux/wayland/popup.rs` | — | **not ported** |  |
| `crates/gpui_linux/src/linux/wayland/**` | `src/platform/linux/wayland.zig`, `src/platform/linux/window_common.zig` | ported |  |
| `crates/gpui_linux/src/linux/x11.rs` | `src/platform/linux/x11.zig` | ported |  |
| `crates/gpui_linux/src/linux/x11/**` | `src/platform/linux/x11.zig`, `src/platform/linux/window_common.zig` | ported |  |
| `crates/gpui_linux/**` | `src/platform/linux/linux.zig` | partial | unmapped gpui_linux file |
| `crates/gpui_wgpu/src/wgpu_renderer.rs` | `src/renderer/vulkan/Renderer.zig` | partial | semantic port to raw Vulkan |
| `crates/gpui_wgpu/src/wgpu_context.rs` | `src/renderer/vulkan/Device.zig`, `src/renderer/vulkan/Swapchain.zig` | partial |  |
| `crates/gpui_wgpu/src/wgpu_atlas.rs` | `src/atlas.zig`, `src/renderer/vulkan/Renderer.zig` | ported |  |
| `crates/gpui_wgpu/src/shaders.wgsl` | `src/renderer/vulkan/shaders/` | ported | hand-ported to GLSL |
| `crates/gpui_wgpu/src/shaders_subpixel.wgsl` | `src/renderer/vulkan/shaders/subpixel_sprite.frag`, `src/renderer/vulkan/shaders/subpixel_sprite_fallback.frag` | ported |  |
| `crates/gpui_wgpu/src/blur_kernel.rs` | `src/renderer/vulkan/shaders/blur_pass.frag`, `src/renderer/metal/backdrop.zig` | ported |  |
| `crates/gpui_wgpu/src/cosmic_text_system.rs` | `src/text/freetype.zig`, `src/text/fallback.zig` | partial | FreeType/HarfBuzz/fontconfig instead of cosmic-text |
| `crates/gpui_wgpu/src/gpui_wgpu.rs` | `src/renderer/renderer.zig` | ported |  |
| `crates/gpui_wgpu/src/solid_quad_tests.rs` | `tests/` | partial |  |
| `crates/gpui_macros/src/styles.rs` | `src/style/styled_generated.zig`, `src/style/builder.zig` | ported | generated by scripts/gen_styled.py |
| `crates/gpui_macros/src/derive_refineable.rs` | `src/style/refine.zig` | ported |  |
| `crates/refineable/**` | `src/style/refine.zig` | ported |  |
| `crates/gpui_platform/**` | `src/zpui.zig` | partial |  |
| `crates/gpui/build.rs` | `build.zig` | partial | shader/bindgen build steps |

No port needed (`n/a`): `crates/gpui/src/app/bench_context.rs`, `crates/gpui/src/platform/layer_shell.rs`, `crates/gpui/src/platform/bench_dispatcher.rs`, `crates/gpui/src/profiler.rs`, `crates/gpui/src/profiler/**`, `crates/gpui/src/_*.rs`, `crates/gpui/examples/**`, `crates/gpui/tests/**`, `crates/gpui/Cargo.toml`, `crates/gpui_linux/src/linux/headless.rs`, `crates/gpui_linux/src/linux/headless/**`, `crates/gpui_linux/src/linux/wayland/layer_shell.rs`, `crates/gpui_wgpu/**`, `crates/gpui_macros/**`, `crates/gpui_windows/**`, `crates/gpui_web/**`, `crates/gpui_tokio/**`, `crates/gpui_shared_string/**`, `crates/gpui_util/**`, `crates/media/**`, `crates/collections/**`, `crates/http_client/**`, `crates/http_client_tls/**`, `crates/path/**`, `crates/reqwest_client/**`, `crates/scheduler/**`, `crates/sum_tree/**`, `crates/util/**`, `crates/util_macros/**`, `assets/**`, `crates/gpui/docs/**`, `crates/gpui/resources/**`, `crates/gpui_macos/tests/**`, `crates/*/Cargo.toml`, `crates/*/LICENSE*`, `crates/*/README.md`, `.*`, `.cargo/**`, `.github/**`, `LICENSE*`, `NOTICE`, `rust-toolchain.toml`, `docs/**`, `tooling/**`, `Cargo.toml`, `Cargo.lock`, `*.md`

### zeron → apps/zeron

| upstream path | Zig | status | note |
|---|---|---|---|
| `crates/ui/src/account_usage.rs` | — | **not ported** | plan-usage ring + account switcher in the composer footer |
| `crates/ui/src/app_menus.rs` | `apps/zeron/src/actions.zig`, `apps/zeron/src/keymap.zig` | partial | actions + bindings only; menu bar is zpui's fixed menu, zeron:: actions unhandled |
| `crates/ui/src/app_update.rs` | `apps/zeron/src/model/status.zig`, `apps/zeron/src/ui/sidebar/sidebar.zig` | partial | shows the engine's UpdateStatus; no app self-update/install-on-quit |
| `crates/ui/src/appearance.rs` | `apps/zeron/src/theme/settings.zig`, `apps/zeron/src/ui/settings/store.zig`, `apps/zeron/src/ui/components/theme.zig` | partial |  |
| `crates/ui/src/appshots.rs` | `apps/zeron/src/ui/settings/appshots.zig` | **not ported** | settings page only |
| `crates/ui/src/appshots/**` | — | **not ported** |  |
| `crates/ui/src/attachments.rs` | `apps/zeron/src/ui/composer/composer.zig`, `apps/zeron/src/ui/transcript/view.zig` | partial | staged chips + local thumbnails; no upload/read-back/lightbox |
| `crates/ui/src/badges.rs` | — | **not ported** |  |
| `crates/ui/src/browser/**` | `apps/zeron/src/ui/shell/right_pane.zig`, `apps/zeron/src/actions.zig` | **not ported** | empty 'Preview your work' page only |
| `crates/ui/src/change_requests.rs` | `apps/zeron/src/ui/components/badge.zig`, `apps/zeron/src/ui/sidebar/sidebar.zig` | partial | badge renders from fixtures only |
| `crates/ui/src/changes.rs` | `apps/zeron/src/ui/changes/pane.zig`, `apps/zeron/src/ui/changes/model.zig`, `apps/zeron/src/ui/changes/rows.zig`, `apps/zeron/src/ui/changes/highlight.zig`, `apps/zeron/src/ui/changes/store.zig`, `apps/zeron/src/ui/changes/tabs.zig`, `apps/zeron/src/diff/patch.zig`, `apps/zeron/src/ui/transcript/diff_view.zig` | partial | no review comments |
| `crates/ui/src/comment_ui.rs` | — | **not ported** |  |
| `crates/ui/src/comments.rs` | — | **not ported** |  |
| `crates/ui/src/composer.rs` | `apps/zeron/src/ui/composer/composer.zig`, `apps/zeron/src/ui/composer/metrics.zig`, `apps/zeron/src/ui/composer/slash.zig`, `apps/zeron/src/ui/composer/chrome.zig`, `apps/zeron/src/ui/input/text_input.zig`, `apps/zeron/src/ui/input/editor.zig`, `apps/zeron/src/ui/input/segment.zig`, `apps/zeron/src/actions.zig`, `apps/zeron/src/keymap.zig` | partial | no question wizard, mention chips, provider slash commands, uploads, dictation capture |
| `crates/ui/src/composer/**` | `apps/zeron/src/ui/composer/tests.zig` | partial |  |
| `crates/ui/src/composer_dictation_tests.rs` | — | **not ported** |  |
| `crates/ui/src/composer_dock.rs` | `apps/zeron/src/ui/shell/main_panel.zig` | **not ported** | canvas<->thread dock choreography |
| `crates/ui/src/composer_dock/**` | — | **not ported** |  |
| `crates/ui/src/composer_markdown.rs` | `apps/zeron/src/ui/input/editor.zig` | partial |  |
| `crates/ui/src/context_usage.rs` | `apps/zeron/src/ui/composer/composer.zig` | ported |  |
| `crates/ui/src/dictation.rs` | `apps/zeron/src/ui/settings/voice.zig` | **not ported** |  |
| `crates/ui/src/dictation/**` | — | **not ported** |  |
| `crates/ui/src/edge_fade.rs` | `apps/zeron/src/ui/components/effects.zig` | ported | + src/elements/effects.zig |
| `crates/ui/src/file_icons.rs` | `apps/zeron/src/ui/files/icons.zig`, `apps/zeron/src/ui/markdown/file_icons.zig` | ported |  |
| `crates/ui/src/files/client.rs` | `apps/zeron/src/ui/files/client.zig` | ported |  |
| `crates/ui/src/files/watch.rs` | `apps/zeron/src/ui/files/client.zig` | ported |  |
| `crates/ui/src/files/context_menu.rs` | `apps/zeron/src/ui/files/panel.zig`, `apps/zeron/src/ui/editor/view.zig` | partial |  |
| `crates/ui/src/files/document.rs` | `apps/zeron/src/ui/editor/view.zig` | ported |  |
| `crates/ui/src/files/drag.rs` | `apps/zeron/src/ui/files/panel.zig` | **not ported** | no tree drag-move / drag into chat |
| `crates/ui/src/files/editor.rs` | `apps/zeron/src/ui/editor/root.zig`, `apps/zeron/src/ui/editor/view.zig` | ported |  |
| `crates/ui/src/files/editor_adapter.rs` | `apps/zeron/src/ui/editor/highlight.zig`, `apps/zeron/src/ui/editor/view.zig` | ported |  |
| `crates/ui/src/files/git_status.rs` | `apps/zeron/src/ui/files/decorations.zig`, `apps/zeron/src/ui/files/client.zig` | ported |  |
| `crates/ui/src/files/image_preview.rs` | — | **not ported** |  |
| `crates/ui/src/files/markdown_media.rs` | — | **not ported** |  |
| `crates/ui/src/files/markdown_preview.rs` | — | **not ported** |  |
| `crates/ui/src/files/mod.rs` | `apps/zeron/src/ui/files/panel.zig`, `apps/zeron/src/ui/editor/view.zig`, `apps/zeron/src/ui/files/root.zig` | ported |  |
| `crates/ui/src/files/model.rs` | `apps/zeron/src/ui/files/model.zig` | ported |  |
| `crates/ui/src/files/mutations.rs` | `apps/zeron/src/ui/files/client.zig` | partial |  |
| `crates/ui/src/files/preview.rs` | `apps/zeron/src/ui/editor/view.zig` | partial |  |
| `crates/ui/src/files/rename.rs` | `apps/zeron/src/ui/files/panel.zig` | ported |  |
| `crates/ui/src/files/search.rs` | `apps/zeron/src/ui/files/search.zig` | ported |  |
| `crates/ui/src/files/sections.rs` | `apps/zeron/src/ui/files/panel.zig` | partial | empty states only; never fed |
| `crates/ui/src/files/tree.rs` | `apps/zeron/src/ui/files/panel.zig` | ported |  |
| `crates/ui/src/files/test_support.rs` | `apps/zeron/src/ui/files/panel_test.zig` | ported |  |
| `crates/ui/src/frost.rs` | `apps/zeron/src/ui/components/effects.zig` | ported | + src/elements/effects.zig |
| `crates/ui/src/glass.rs` | `apps/zeron/src/ui/composer/chrome.zig` | ported |  |
| `crates/ui/src/haptics.rs` | — | **not ported** |  |
| `crates/ui/src/history.rs` | `apps/zeron/src/ui/history/pane.zig`, `apps/zeron/src/ui/history/graph.zig`, `apps/zeron/src/ui/history/store.zig`, `apps/zeron/src/ui/history/types.zig` | ported |  |
| `crates/ui/src/icons.rs` | `apps/zeron/src/assets.zig`, `apps/zeron/src/ui/components/icon.zig` | ported | assets.zig generated by scripts/gen_assets.py |
| `crates/ui/src/image_media.rs` | — | partial | zpui src/image/ decodes; no bounded/async media pipeline |
| `crates/ui/src/image_viewer.rs` | — | **not ported** |  |
| `crates/ui/src/lib.rs` | `apps/zeron/src/main.zig` | partial | no URL routing, reopen, quit hooks, window geometry, appshot service |
| `crates/ui/src/links.rs` | — | **not ported** |  |
| `crates/ui/src/loaders.rs` | `apps/zeron/src/ui/components/loaders.zig` | ported |  |
| `crates/ui/src/markdown/inline_code_links.rs` | `apps/zeron/src/markdown/inline_code_links.zig` | ported |  |
| `crates/ui/src/markdown/link_destination.rs` | — | **not ported** |  |
| `crates/ui/src/markdown/link_interaction.rs` | `apps/zeron/src/ui/markdown/rich_text.zig` | partial |  |
| `crates/ui/src/markdown/link_presentation.rs` | — | **not ported** |  |
| `crates/ui/src/markdown/links.rs` | `apps/zeron/src/ui/markdown/rich_text.zig` | partial |  |
| `crates/ui/src/markdown/mermaid.rs` | `apps/zeron/src/markdown/root.zig` | **not ported** | fences detected, rendered as source |
| `crates/ui/src/markdown/mermaid_cache.rs` | — | **not ported** |  |
| `crates/ui/src/markdown/mod.rs` | `apps/zeron/src/markdown/root.zig`, `apps/zeron/src/ui/markdown/root.zig` | ported |  |
| `crates/ui/src/markdown/render.rs` | `apps/zeron/src/ui/markdown/root.zig`, `apps/zeron/src/ui/markdown/rich_text.zig` | ported |  |
| `crates/ui/src/markdown/selection.rs` | `apps/zeron/src/ui/markdown/rich_text.zig` | ported |  |
| `crates/ui/src/markdown/veil.rs` | — | **not ported** |  |
| `crates/ui/src/motion.rs` | `apps/zeron/src/theme/motion.zig`, `apps/zeron/src/ui/components/anim.zig`, `apps/zeron/src/ui/components/hover.zig` | ported |  |
| `crates/ui/src/new_thread_background_*.rs` | — | **not ported** |  |
| `crates/ui/src/notice.rs` | `apps/zeron/src/ui/transcript/view.zig`, `apps/zeron/src/ui/composer/composer.zig` | ported |  |
| `crates/ui/src/notify.rs` | — | **not ported** |  |
| `crates/ui/src/pickers.rs` | `apps/zeron/src/ui/pickers/pickers.zig`, `apps/zeron/src/ui/pickers/paths.zig`, `apps/zeron/src/ui/pickers/menu.zig`, `apps/zeron/src/ui/composer/model_picker.zig`, `apps/zeron/src/ui/composer/run_config.zig` | partial | no repo clone/create, worktree create/delete |
| `crates/ui/src/pickers/compact.rs` | `apps/zeron/src/ui/composer/model_picker.zig` | ported |  |
| `crates/ui/src/popover.rs` | `apps/zeron/src/ui/components/popover.zig`, `apps/zeron/src/ui/components/dialog.zig`, `apps/zeron/src/ui/pickers/menu.zig` | ported |  |
| `crates/ui/src/popover/**` | `apps/zeron/src/ui/settings/select.zig` | partial |  |
| `crates/ui/src/project_actions.rs` | — | **not ported** |  |
| `crates/ui/src/queue.rs` | `apps/zeron/src/ui/composer/composer.zig`, `apps/zeron/src/model/queue_store.zig` | partial | no drag reorder, no edit lease |
| `crates/ui/src/rail.rs` | `apps/zeron/src/ui/transcript/view.zig` | ported |  |
| `crates/ui/src/settings.rs` | `apps/zeron/src/model/settings.zig`, `apps/zeron/src/model/settings_store.zig`, `apps/zeron/src/theme/settings.zig`, `apps/zeron/src/ui/settings/view.zig` | ported |  |
| `crates/ui/src/settings/accounts.rs` | — | **not ported** |  |
| `crates/ui/src/settings/appearance.rs` | `apps/zeron/src/ui/settings/appearance.zig` | partial |  |
| `crates/ui/src/settings/appshots.rs` | `apps/zeron/src/ui/settings/appshots.zig` | ported |  |
| `crates/ui/src/settings/archived.rs` | `apps/zeron/src/ui/settings/archived.zig` | ported |  |
| `crates/ui/src/settings/completion.rs` | — | **not ported** |  |
| `crates/ui/src/settings/composer.rs` | `apps/zeron/src/model/composer_defaults.zig` | ported |  |
| `crates/ui/src/settings/devices.rs` | `apps/zeron/src/ui/settings/devices.zig` | ported |  |
| `crates/ui/src/settings/files.rs` | `apps/zeron/src/ui/settings/files.zig` | ported |  |
| `crates/ui/src/settings/harnesses.rs` | `apps/zeron/src/ui/settings/providers.zig` | partial | no install/cancel install |
| `crates/ui/src/settings/notifications.rs` | `apps/zeron/src/ui/settings/notifications.zig` | ported |  |
| `crates/ui/src/settings/shortcuts.rs` | `apps/zeron/src/ui/settings/shortcuts.zig`, `apps/zeron/src/keymap.zig` | ported |  |
| `crates/ui/src/settings/thread_naming.rs` | `apps/zeron/src/ui/settings/general.zig` | partial |  |
| `crates/ui/src/settings/wallpaper.rs` | — | **not ported** |  |
| `crates/ui/src/settings/wallpaper_colors.rs` | `apps/zeron/src/theme/wallpaper.zig` | ported |  |
| `crates/ui/src/settings/widgets.rs` | `apps/zeron/src/ui/settings/widgets.zig`, `apps/zeron/src/ui/settings/select.zig`, `apps/zeron/src/ui/components/switch.zig`, `apps/zeron/src/ui/components/tooltip.zig` | ported |  |
| `crates/ui/src/shell.rs` | `apps/zeron/src/ui/shell/shell.zig`, `apps/zeron/src/ui/shell/main_panel.zig`, `apps/zeron/src/ui/shell/right_pane.zig`, `apps/zeron/src/ui/shell/titlebar.zig`, `apps/zeron/src/ui/shell/gates.zig`, `apps/zeron/src/ui/shell/terminal_dock.zig`, `apps/zeron/src/ui/sidebar/sidebar.zig`, `apps/zeron/src/ui/components/button.zig`, `apps/zeron/src/actions.zig`, `apps/zeron/src/keymap.zig` | partial |  |
| `crates/ui/src/shell/actions_ui.rs` | — | **not ported** |  |
| `crates/ui/src/shell/chat_dropzone.rs` | — | **not ported** |  |
| `crates/ui/src/shell/command_palette.rs` | `apps/zeron/src/ui/shell/palette.zig` | ported |  |
| `crates/ui/src/shell/file_mutations.rs` | — | **not ported** |  |
| `crates/ui/src/shell/files_panel.rs` | `apps/zeron/src/ui/shell/right_pane.zig`, `apps/zeron/src/ui/files/panel.zig` | ported |  |
| `crates/ui/src/shell/harness_updates.rs` | — | **not ported** | data in model/status.zig; no home island |
| `crates/ui/src/shell/navigation_focus.rs` | `apps/zeron/src/ui/shell/shell.zig` | partial |  |
| `crates/ui/src/shell/project_icon.rs` | `apps/zeron/src/ui/sidebar/project_icon.zig` | partial |  |
| `crates/ui/src/shell/side_chats.rs` | — | **not ported** |  |
| `crates/ui/src/shell/sidebar_pins.rs` | `apps/zeron/src/ui/sidebar/sidebar.zig` | ported |  |
| `crates/ui/src/shell/sidebar_sections.rs` | — | **not ported** |  |
| `crates/ui/src/shell/spaces.rs` | `apps/zeron/src/ui/sidebar/sidebar.zig`, `apps/zeron/src/ui/pickers/add_project.zig` | partial | no space rename/delete |
| `crates/ui/src/shell/tabs.rs` | `apps/zeron/src/ui/shell/titlebar.zig` | ported |  |
| `crates/ui/src/shell/*_tests.rs` | `apps/zeron/src/ui/shell/shell_test.zig` | partial |  |
| `crates/ui/src/sound.rs` | — | **not ported** |  |
| `crates/ui/src/state.rs` | `apps/zeron/src/model/app_state.zig`, `apps/zeron/src/model/engine_state.zig`, `apps/zeron/src/model/workspace.zig`, `apps/zeron/src/model/status.zig`, `apps/zeron/src/model/transcript_store.zig`, `apps/zeron/src/model/queue_store.zig` | ported |  |
| `crates/ui/src/surface_chrome.rs` | `apps/zeron/src/ui/changes/tabs.zig`, `apps/zeron/src/theme/layout.zig` | ported |  |
| `crates/ui/src/syntax_cache.rs` | `apps/zeron/src/ui/changes/highlight.zig`, `apps/zeron/src/ui/editor/highlight.zig` | partial |  |
| `crates/ui/src/terminal/dock.rs` | `apps/zeron/src/ui/shell/terminal_dock.zig` | ported |  |
| `crates/ui/src/terminal/emulator.rs` | `apps/zeron/src/terminal/Emulator.zig`, `apps/zeron/src/terminal/snapshot.zig` | ported |  |
| `crates/ui/src/terminal/mod.rs` | `apps/zeron/src/terminal/root.zig` | ported |  |
| `crates/ui/src/terminal/panel.rs` | `apps/zeron/src/terminal/session.zig`, `apps/zeron/src/ui/shell/terminal_dock.zig` | partial | local PTY; engine OpenTerminal/SubscribeTerminal not wired |
| `crates/ui/src/terminal/view.rs` | `apps/zeron/src/terminal/keys.zig`, `apps/zeron/src/terminal/input.zig`, `apps/zeron/src/terminal/paint.zig`, `apps/zeron/src/terminal/palette.zig`, `apps/zeron/src/ui/shell/terminal_dock.zig` | ported |  |
| `crates/ui/src/theme.rs` | `apps/zeron/src/theme/theme.zig`, `apps/zeron/src/theme/colorspace.zig`, `apps/zeron/src/theme/layout.zig` | ported |  |
| `crates/ui/src/theme_library.rs` | — | **not ported** |  |
| `crates/ui/src/todo_panel.rs` | — | **not ported** |  |
| `crates/ui/src/transcript.rs` | `apps/zeron/src/ui/transcript/view.zig`, `apps/zeron/src/ui/transcript/rows.zig`, `apps/zeron/src/ui/transcript/tools.zig`, `apps/zeron/src/ui/transcript/thought.zig`, `apps/zeron/src/ui/transcript/diff_view.zig` | partial |  |
| `crates/ui/src/typography.rs` | `apps/zeron/src/theme/typography.zig` | ported |  |
| `crates/ui/src/workspace_links.rs` | `apps/zeron/src/ui/transcript/workspace_links.zig` | ported |  |
| `crates/ui/src/**` | — | **not ported** | new/unmapped zeron UI file |
| `crates/ui/assets/icons/**` | `apps/zeron/assets/icons/`, `apps/zeron/src/assets.zig` | ported |  |
| `crates/ui/assets/fonts/**` | `apps/zeron/assets/fonts/`, `apps/zeron/src/assets.zig` | ported |  |
| `crates/ui/assets/file-icons/**` | `apps/zeron/assets/file-icons/`, `apps/zeron/src/assets.zig` | ported |  |
| `crates/ui/assets/sounds/**` | — | **not ported** |  |
| `crates/ui/src/file-icons.json` | `apps/zeron/assets/file-icons/file-icons.json`, `apps/zeron/src/ui/markdown/file_icons.zig`, `apps/zeron/src/ui/files/icons.zig` | ported |  |
| `crates/theme/src/lib.rs` | `apps/zeron/src/theme/model.zig` | ported |  |
| `crates/theme/src/builtins.rs` | `apps/zeron/src/theme/builtins.zig`, `apps/zeron/src/theme/derive.zig` | ported | builtins.zig generated by gen_themes.py |
| `crates/theme/src/library.rs` | — | **not ported** |  |
| `crates/theme/src/vscode.rs` | — | **not ported** |  |
| `crates/markdown/src/lib.rs` | `apps/zeron/src/markdown/root.zig` | ported |  |
| `crates/markdown/src/parser.rs` | `apps/zeron/src/markdown/parser.zig`, `apps/zeron/src/markdown/model.zig` | ported |  |
| `crates/markdown/src/mend.rs` | `apps/zeron/src/markdown/mend.zig` | ported |  |
| `crates/syntax/src/lib.rs` | `apps/zeron/src/syntax/root.zig`, `apps/zeron/src/syntax/language.zig`, `apps/zeron/src/syntax/highlight.zig`, `apps/zeron/src/syntax/query.zig` | ported |  |
| `crates/syntax/**` | `apps/zeron/src/syntax/root_test.zig` | partial |  |
| `crates/proto/src/view.rs` | `apps/zeron/src/model/view.zig` | ported |  |
| `crates/proto/src/motion.rs` | `apps/zeron/src/theme/motion.zig` | ported |  |
| `crates/proto/src/entities.rs` | `apps/zeron/src/engine/protocol.zig`, `apps/zeron/src/ui/files/protocol.zig`, `apps/zeron/src/ui/history/types.zig`, `apps/zeron/src/model/types.zig` | ported |  |
| `crates/proto/src/workspace.rs` | `apps/zeron/src/engine/protocol.zig` | ported |  |
| `crates/proto/src/agent.rs` | `apps/zeron/src/engine/protocol.zig` | ported |  |
| `crates/proto/src/sidebar_pins.rs` | `apps/zeron/src/engine/protocol.zig` | ported |  |
| `crates/proto/src/lib.rs` | `apps/zeron/src/engine/protocol.zig` | ported |  |
| `crates/proto/src/invocation.rs` | `apps/zeron/src/engine/protocol.zig` | partial |  |
| `crates/proto/src/file_mentions.rs` | — | **not ported** |  |
| `crates/proto/src/preview.rs` | — | **not ported** |  |
| `crates/rpc/src/lib.rs` | `apps/zeron/src/engine/methods.zig`, `apps/zeron/src/engine/rpc.zig` | ported | methods.zig generated by gen_methods.py |
| `crates/rpc/src/client.rs` | `apps/zeron/src/engine/rpc.zig` | ported |  |
| `crates/rpc/src/server.rs` | `apps/zeron/src/engine/ws.zig` | ported |  |
| `crates/doc/src/transcript_delta.rs` | `apps/zeron/src/engine/transcript.zig` | ported |  |
| `crates/doc/src/queue.rs` | `apps/zeron/src/model/queue_store.zig` | partial |  |
| `crates/engine/src/rpc.rs` | `apps/zeron/src/engine/methods.zig`, `apps/zeron/src/engine/protocol.zig` | partial | stream classification + wire shapes |
| `crates/update/**` | — | **not ported** | app self-update |
| `crates/voice/**` | — | **not ported** | Parakeet dictation |
| `apps/zeron/src/main.rs` | `apps/zeron/src/main.zig`, `apps/zeron/src/engine_bin.zig` | partial | no URL argument; CLI subcommands live in the engine binary |
| `apps/zeron/src/paths.rs` | `apps/zeron/src/model/settings.zig` | ported |  |
| `dist/**` | `apps/zeron/dist/` | partial | Info.plist, .desktop, icons |

No port needed (`n/a`): `crates/ui/src/motion/**`, `crates/ui/examples/**`, `crates/ui/tests/**`, `crates/ui/Cargo.toml`, `crates/ui/build.rs`, `crates/theme/**`, `crates/markdown/**`, `crates/proto/**`, `crates/rpc/**`, `crates/doc/**`, `crates/engine/**`, `crates/harness/**`, `crates/mcp/**`, `crates/mobile/**`, `crates/client/**`, `crates/sync/**`, `crates/preview/**`, `crates/text/**`, `apps/zeron/**`, `apps/ios/**`, `apps/landing/**`, `apps/www-redirect/**`, `edge/**`, `docs/**`, `scripts/**`, `.github/**`, `Cargo.lock`, `Cargo.toml`, `*.md`, `rust-toolchain.toml`, `LICENSE`, `.*`

### gpui-component → apps/zeron editor

| upstream path | Zig | status | note |
|---|---|---|---|
| `crates/base/src/input/**` | `apps/zeron/src/ui/editor/core.zig`, `apps/zeron/src/ui/editor/view.zig`, `apps/zeron/src/ui/editor/actions.zig`, `apps/zeron/src/ui/editor/wrap.zig`, `apps/zeron/src/ui/editor/buffer.zig` | partial |  |
| `crates/base/src/scrollbar.rs` | `src/elements/scrollbar.zig` | ported |  |

No port needed (`n/a`): `**`

