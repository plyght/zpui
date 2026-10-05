# Animations: zeron (Rust) → apps/zeron (Zig)

Every motion in the Rust client (`crates/ui/src`, plus the gpui-base pieces it uses) and where
it lives in the Zig port. Rust paths are under `zeron/crates/ui/src/`, Zig paths under
`apps/zeron/src/` unless they start with `src/` (zpui).

Legend: ✅ ported (same trigger, span, curve, reduced-motion rule) · 🟡 partial (difference noted)
· ❌ missing · ➖ the Rust feature itself is not in the Zig client yet, so its motion has nowhere to go.

## Shared rules

| Rule | Rust | Zig | Status |
|---|---|---|---|
| Motion catalog: `FADE_IN` 500 ms `cubic-bezier(.16,1,.3,1)`, `FADE_QUICK` 150 ms ease, `MENU_IN` 140, `MENU_OUT` 100, `DIALOG_IN` 180, `SPLASH_OUT` 150+500, `RESIZE` 200 ease-out, `TAB_SLIDE` 150 ease-out, `COLLAPSE` 180 ease-out, `NEW_THREAD_TRANSITION` 420 quint, `CHEVRON` 200, `SCROLL_GLIDE` 500 ease-in-out, `HOVER_FADE` 150 tailwind, `ZERON_PULSE` 2.4 s, `GRADIENT_SPIN` 750 ms, `WALLPAPER_CROSSFADE` 180 | `motion.rs` | `theme/motion.zig` (exact `CubicBezier`, `MotionSpec`), `MotionSpec.animation()` builds the `zpui.Animation`; `ui/components/anim.zig` helpers (`fadeIn`, `settleDown`, `fadeQuick`, `menuIn`, `dialogIn`, `menuOutFrame`) | ✅ |
| Reduced motion: oneshots snap to the end state, loops rest at phase 0, no frames scheduled | gpui `App::reduce_motion` + `with_animation` | `src/elements/animation.zig` (`window.prefersReducedMotion()`), hand-driven tweens check the flag (`motion.Tween.eval`, shell `reduced_motion`, sidebar `sec.reduced`, composer, transcript) | ✅ |
| Preference × OS × focus (`reduceMotion` on/off/system, pause in background) | `motion.rs` `ReduceMotion`, `resolve`, `window_activation_changed` | `ui/settings/motion.zig` → each window's flag; `theme/motion.zig` `resolveReduced` | ✅ |
| Activity grids keep a gentle 2.4 s brightness pulse under *system* reduced motion only | `motion.rs` `ActivityPulse` | `theme/motion.zig` `activityAnimates` / `activityOpacity`, `ui/components/loaders.zig` | ✅ |
| `ZERON_MOTION_SCALE` (clamped 0.01–100) stretches every catalog span, hover fades, manual tweens, the dock clock, composer morph clock and voice morph (loops are not stretched, as in Rust's `repeating()`) | `motion.rs` `speed_scale()` | `theme/motion.zig` `speed_scale` (set in `main.zig`), `MotionSpec.totalNs`/`animation()`, `scaledNs`, `HoverFades`, `ui/shell/dock.zig` `duration`, composer `nowMs`, `voice.zig` `Tween` | ✅ |
| Hover color fades (`transition-colors`, premultiplied blend, re-anchored on reversal) | `motion.rs` `HoverFades`, `hover_blend` | `theme/motion.zig` `HoverFades`, `ui/components/hover.zig` | ✅ |

## Element animations (`with_animation` / helpers)

| # | Animation | Rust | Trigger → property, span / curve | Zig | Status |
|---|---|---|---|---|---|
| 1 | App entrance | `shell.rs:12835`, `:13034` `fade_in("phase-app")` | gate → Ready: opacity 0→1, y 4→0, FADE_IN | `ui/shell/shell.zig` `ui.anim.fadeIn("phase-app")` | ✅ |
| 2 | Boot splash exit | `loaders.rs:373` `splash_out` | Ready: 150 ms hold, opacity 1→0 + lift 6 px, 500 ms ease | `ui/shell/shell.zig` (`splash_out.progressAt`, `splashOutFrame`; reduced motion now drops it at once) | ✅ |
| 3 | Gate cards (sign-in / failed / org) | `shell.rs:11808` (keyed per phase), `:12041` | phase swap replays FADE_IN | `ui/shell/gates.zig` `page(theme, key, …)`: `gate-card-signin` / `gate-card-failed` / `org-gate-card` | ✅ (keys per phase fixed) |
| 4 | Signed-out restart card | `shell.rs:11082` | FADE_IN | `ui/shell/sync_flow.zig` | ✅ |
| 5 | No-projects canvas | `shell.rs:10239` `fade_in("no-spaces-canvas")` | FADE_IN | `ui/shell/main_panel.zig` `onboarding` | ✅ (added) |
| 6 | Connection pill | `shell.rs:7986` | FADE_IN | — (the connectivity pill is not ported) | ➖ |
| 7 | Modal dialogs | `popover.rs:897` `modal` → `dialog_in` | mount: opacity 0→1, y 2→0, 180 ms ease | `ui/components/dialog.zig` `modal` → `anim.dialogIn` (was MENU_IN from 0.3) | ✅ (fixed); settings' own modals (`settings/devices.zig`, `accounts.zig`, `background_adjust.zig`, `theme_library.zig`) still use `menuIn(…, 2)` 🟡 — settings files were owned by another agent |
| 8 | Command palette / New project palette | `shell/command_palette.rs:525` `palette_overlay` | none (card mounts as is) | `ui/shell/palette.zig`, `ui/pickers/add_project.zig` | ✅ (removed the extra MENU_IN the Zig port had added) |
| 9 | Jump-to-bottom pill | `shell.rs:10553` `dialog_in` inside frost | DIALOG_IN | `ui/transcript/view.zig` `renderJump` (`jumpInFrame`) | ✅ (added) |
| 10 | Popover / menu entrance | `popover.rs:532` `menu_in_from`, MENU_TRAVEL 4 for upward menus | opacity 0.3→1, y from→0, 140 ms ease | `ui/components/popover.zig` `anchoredAbove/Below/Right/At`, pickers, changes, right pane | ✅ (context menus via `anchoredAt` gained it) |
| 11 | Popover / menu exit | `popover.rs:529` `menu_out_toward`, `exit_progress`, `frosted_menu` blur ride-down, `reap_popup` | close: opacity 1→0, retreat half the travel, 100 ms; blur radius follows | `anim.menuOutFrame` exists; menus still unmount on close | ❌ (needs a closing phase per popup owner) |
| 12 | Agent details reveal (Settings → Agents) | `settings/harnesses.rs:271` `menu_in` (none under reduced motion) | MENU_IN | `ui/settings/providers.zig:244` | ✅ |
| 13 | Dictation outcome strip | `composer.rs:9597` `fade_in("dictation-message-enter")` | FADE_IN | `ui/composer/voice.zig` `renderStatus` (now `fade_in.animation()`, scaled) | ✅ |
| 14 | Composer queue notice (offline / degraded delivery) | `composer.rs:10123` | FADE_IN | — (delivery-degraded notice not ported) | ➖ |
| 15 | Question wizard swap | `composer.rs:10142` `fade_quick("composer-wizard")` | FADE_QUICK | `ui/composer/composer.zig` `fadeQuick("composer-wizard")` | ✅ (added) |
| 16 | Todo tray / queue tray mount | `composer.rs:10161`, `:10166` | FADE_QUICK | `ui/composer/composer.zig` `composer-todo`, `composer-queue` | ✅ (added) |
| 17 | Todo rows per toggle | `todo_panel.rs:344` `todo-rows-{epoch}` | FADE_QUICK | `ui/composer/extras.zig` `renderTodo` keyed by `st.epoch` | ✅ (added) |
| 18 | File-mention path tooltip | `composer.rs:4460` | FADE_QUICK | — (tooltip not ported) | ➖ |
| 19 | Transcript hover metadata | `transcript.rs:6931` `fade_quick("meta-…")` | hover → FADE_QUICK | `ui/transcript/view.zig` `renderStrip` (`metaFade`) | ✅ (added) |
| 20 | Long user message open / close | `transcript.rs:5757`, `user_resize_duration_ms` (220 + 0.32 ms/px ≤ 850), `user_resize_spec` (ease-out, ease-in-out > 500 px) | Show more / less: clip height glides, "…" line in the endpoints | `ui/transcript/view.zig` `renderUser`, `onToggleUser`, `userResizeDurationMs`, `userResizeSpec`; full height measured by a paint probe | ✅ (added) |
| 21 | Changes per-file fold | `changes.rs:3464` | COLLAPSE height | `ui/changes/pane.zig` (`collapse.animation()`) | ✅ |
| 22 | Changes fold chevron | `changes.rs:3522` | CHEVRON opacity .25→1 | `ui/changes/pane.zig` (`chevron.animation()`) | ✅ |
| 23 | History search open / close | `history.rs:1812` (`Collapsing` mode, RESIZE) | width 24↔full, opacity .45↔1 | `ui/history/pane.zig` `searchControl` (`history-search-morph`), `beginCollapse` (unmounts after RESIZE) | ✅ (added; Rust's idle auto-dismiss is not ported) |
| 24 | History branch fold rows enter / exit | `history.rs:4146`, `history_transition_rows`, settle after COLLAPSE | height 36·k, opacity .35→1 | — (fold re-lays out at once) | ❌ |
| 25 | History graph compact ⇄ full morph | `history.rs:4448` `interpolate_graph_geometry` | COLLAPSE | `ui/history/pane.zig` `morph`, `history/graph.zig` `interpolate` (parity-tested) | ✅ |
| 26 | History hover clear | `history.rs:2821` (clear after HOVER_FADE) | hover fade | `ui/history/pane.zig` (`ui.hover`) | ✅ |
| 27 | Sidebar group disclosures (Pinned, Sessions, Archived, project / device groups, custom sections) | `shell/spaces.rs:2329` body, `:2366` chevron | COLLAPSE: height, opacity .35→1, y −3→0; chevron quarter turn | `ui/sidebar/sections_ui.zig` (`disclosureBody`, `headerChevron`, `toggleMotion`); used by custom sections and now Pinned / Sessions / Archived / groups in `sidebar.zig` | ✅ (built-in groups added) |
| 28 | Sidebar resort glide | `shell.rs:8199` `resort_offsets`, `RESORT` 260 ms quint | order change: FLIP top dy→0 | `ui/sidebar/sidebar.zig` `updateResort`, `resortRow`, `resortOffsets` (Rust's tests ported) | ✅ (added; header heights approximated) |
| 29 | New sidebar row | `shell.rs:8205` `row-in` | FADE_QUICK | `ui/sidebar/sidebar.zig` `resortRow` | ✅ (added) |
| 30 | Pinned reorder slide | `shell.rs:8182` `pinned-session-slide` | TAB_SLIDE | `ui/sidebar/sidebar.zig` `pin-slide` | ✅ (curve fixed: was ease-out-quint) |
| 31 | Moving row slides home on cancel | `shell/spaces.rs:2766` | TAB_SLIDE | `ui/sidebar/sections_ui.zig` `renderMoving` | ✅ (curve fixed; return timer scaled) |
| 32 | Destination siblings slide apart | `shell/spaces.rs:2521` `render_sidebar_gap_row`, `sidebar_gap_offset` | drag: rows at/after the insertion point offset one slot (instant); cancel: slide back over TAB_SLIDE | `ui/sidebar/sections_ui.zig` `placeRow`, `gapOffset`, `onRowDragMove`, `extraGapIn` (the end gap opens only in the previewed accordion, never in the source group) | ✅ (added) |
| 33 | Source slot collapse / destination gap | `shell/spaces.rs` `section_gaps`, `source_collapse` | TAB_SLIDE | `ui/sidebar/sections_ui.zig` `sourceSlot`, `extraGap` | ✅ (curve fixed) |
| 34 | Right-pane tab drag slide | `shell.rs:11466` | TAB_SLIDE | `ui/shell/right_pane.zig` | ✅ (curve fixed) |
| 35 | Terminal tab drag slide | `terminal/panel.rs:1609` | TAB_SLIDE | — (terminal tabs have no drag reorder yet) | ➖ |
| 36 | Queue row drag slide | `queue.rs:687` | TAB_SLIDE from the previous to the current offset | `ui/composer/extras.zig` `queueRow` (was an instant offset) | ✅ (added) |
| 37 | Files panel sections (Subagents / Chats) | `files/sections.rs:672`, `:713` | COLLAPSE body (height, opacity .35→1, y −3→0) + chevron quarter turn | `ui/files/panel.zig` `renderSection`, `SectionMotion` | ✅ (added) |
| 38 | Tool group arrival: header reveal, per-row reveal (360 ms expo, 90 ms first delay, 65 ms stagger), connector draw (480 ms quint) | `transcript.rs:2601`, `:2610`, `:7470`, `tool_connector_parts` | new tools: rows grow in, rails draw | — (rows and rails appear at once) | ❌ |
| 39 | Tool title shimmer | `transcript.rs` 3.4 s sweep | live groups | `ui/transcript/tools.zig` `shimmerAmount` | ✅ |
| 40 | Tool fold (140) / chip detail fold (180) | `transcript.rs` `TOOL_FOLD`, detail | height | `ui/transcript/tools.zig` | ✅ |
| 41 | "Worked for" crossfade | `transcript.rs` | FADE_IN | `ui/transcript/tools.zig` `compactWorkTitle` | ✅ |
| 42 | Row entrance (live rows) | `transcript.rs` | FADE_IN | `ui/transcript/view.zig` `entrance` | ✅ |
| 43 | Streaming veil | `markdown/veil.rs` | per-element fade, EMA cadence | `ui/markdown/veil.zig` (parity-tested) | ✅ |

## Hand-driven tweens and clocks

| # | Animation | Rust | Behaviour | Zig | Status |
|---|---|---|---|---|---|
| 44 | Sidebar / right pane / explorer width | `shell.rs:1276` `WidthTween`, `eval_tween` | RESIZE from the painted width; reduced → target | `ui/shell/shell.zig` `Tween` (now snaps under reduced motion, scaled) | ✅ |
| 45 | Resize-edge bounce | `motion.rs:498` `resize_drag_sample`, `:542` `resize_bounce_offset`, `shell.rs:4433`, `:4498` | dragging past min / max nudges 5 px once (220 ms, two-phase smoothstep) | `ui/shell/shell.zig` `onSidebarDrag` / `onRightDrag`, `EdgeBounce` | ✅ (added; the edge latch is not cleared on mouse-up) |
| 46 | Terminal drawer open / close | `shell.rs:4365` `terminal_tween`, `render_terminal_container` | Cmd-J: height 0↔`terminal_height` over RESIZE, fixed inner clipped; drag cancels | `ui/shell/main_panel.zig` (`terminal_tween`, `terminal_painted`) | ✅ (added) |
| 47 | Composer dock choreography | `composer_dock.rs` (`Glide` critically damped 420 / 470 ms, `Visuals` stages, `PanelHandoff` 320 ms fade-through, `position_at`, `layout_width`) | Home ↔ thread: composer glides between the hero slot and the dock; transcript fades + rises 8 px; hero artwork dissolves | `ui/shell/dock.zig` (verbatim port, parity-tested against `scripts/dock_parity.rs`); `ui/shell/main_panel.zig` `renderDockTransition` drives the vertical glide, transcript fade/rise, hero dissolve (as opacity) and the hand-off opacity | 🟡 the pane hand-off is not fed (main panel does not know the right pane's target width), the hero/thread height reflow (`DockLayout`, `DockReflow`) and the selector/footer visuals inside the composer are not wired, the width glide is computed but not applied |
| 48 | Composer compact ⇄ expanded flip | `composer.rs` `FlipMorph`, `flip_morph_step` | COLLAPSE height + inner geometry | `ui/composer/metrics.zig` | ✅ (morph clock now divided by `ZERON_MOTION_SCALE`) |
| 49 | New-thread flip (`FlipMorph::new_thread_transition`, 420 ms) | `composer.rs:7797` | first send / return to Home | — | 🟡 the dock owns layout during a route change in Rust (`dock_frame.active` cancels the flip), so the visible part is the dock row above |
| 50 | Send / Queue / Stop morph | `composer.rs` | button morph | `ui/composer/composer.zig` | ✅ |
| 51 | Voice morph (mic ↔ Stop, waveform track) | `composer.rs:1742` `VOICE_MORPH` 420 ms `cubic-bezier(.2,0,0,1)` | interruptible | `ui/composer/voice.zig` `Tween` | ✅ (`ZERON_MOTION_SCALE` now honoured) |
| 52 | Dictation waveform / glass glow / mini spinner | `dictation/waveform.rs`, `dictation/glass.rs` | live | `ui/composer/voice.zig`, `ui/input/dictation.zig` | ✅ |
| 53 | Appshot tile entrance | `composer.rs:6698` (240 ms expo, 8 px rise, entity-owned start) | new capture | `ui/composer/composer.zig` `renderAppshotStrip` | ✅ (span now scaled) |
| 54 | Compact model picker: height (RESIZE), page reveal, fast-mode energy + shimmer, fast toggle fade, effort slider glide, press, chip width | `pickers/compact.rs:126`, `:796`, `:935`, `:1035`, `:1195`, `pickers.rs:2923` | `ScalarTransition` (RESIZE, retargetable) | `ui/composer/model_picker.zig` has no motion | ❌ (composer model selection was owned by another agent) |
| 55 | Settings switch travel | `settings/widgets.rs:662` (180 ms cubic-out) | toggle | `ui/settings/view.zig` `travel(…, 180)` | ✅ |
| 56 | Settings tab selection fade | `settings/widgets.rs:989` (TAB_SLIDE, scaled) | selection | `ui/settings/view.zig` `travel(…, 150)` | 🟡 cubic-out instead of TAB_SLIDE's ease-out, not scaled, and `SettingsView.reducedMotion` ignores the OS / background pause |
| 57 | Message rail click → scroll glide | `rail.rs:263` (SCROLL_GLIDE over the distance, re-aimed at the measured row) | click a tick | `ui/transcript/view.zig` `onRailClick` / `railGlideTick` | ✅ (added; pixel glide re-aimed at `offsetForItem` each 16 ms tick) |
| 58 | Transcript stick-to-bottom spring and own-turn glide | `transcript.rs:184` (`SPRING_*`), `own_turn_*` | streaming growth is chased by a spring; a sent prompt glides to the top | `src/elements/list.zig` tail follow (instant) | ❌ |
| 59 | Harness-updates island | `shell/harness_updates.rs:380` | RESIZE size / radius / mark collapse / row reveal | `ui/shell/harness_updates.zig` (parity-tested) | ✅ |
| 60 | New-thread artwork crossfade | `new_thread_background_effects.rs:33` | WALLPAPER_CROSSFADE | `ui/background/hero.zig` | ✅ |
| 61 | Loaders: zeron pulse, gradient spinner, mini glyph / mono spinner, mark loader, activity grids | `loaders.rs`, `motion.rs` | repeating | `ui/components/loaders.zig`, `theme/motion.zig` | ✅ |
| 62 | Caret blink (500 ms, solid while typing) | gpui-base `input/base/blink_cursor.rs` | | `ui/input/text_input.zig` | ✅ |
| 63 | Scrollbar idle fade (2 s hold, 1 − t¹⁰) | gpui-base `scrollbar.rs:971` | | `src/elements/scrollbar.zig` | ✅ |
| 64 | Browser loading bar | none in Rust | | `ui/browser/pane.zig` sliding segment | ➖ Zig-only |

## Parity tests

- `ui/shell/dock.zig` "dock parity with composer_dock.rs": glide trajectories, all four visual
  schedules and four whole-route runs (hero → thread, reversal, panel departure, panel return
  with an idle gap) against `ui/shell/testdata/dock_parity.zig`, dumped by
  `scripts/dock_parity.rs` from the Rust source lifted verbatim.
- `ui/sidebar/sidebar.zig` "resort offsets match shell.rs" (the Rust unit cases).
- `theme/motion.zig` "manual tween" (RESIZE eval, reduced motion, `ZERON_MOTION_SCALE`).
- Existing: veil (`ui/markdown`), history graph morph (`history/graph.zig`), harness updates.

## Known gaps (to port next)

Popover exit (11), history fold rows (24), tool arrival choreography
(38), compact picker motion (54), transcript spring / own-turn glide (58), the dock's height
reflow, selector / footer visuals and pane hand-off wiring (47), and the settings-owned items
(7 settings modals, 56).
