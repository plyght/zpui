# zeron (Rust) → apps/zeron (Zig) parity audit

Snapshot: zeron `9e1a111` (2026-10-02, `crates/ui/src`, 155 files / 184k lines) against zpui
`bf6dbe6` plus the uncommitted work in the tree on 2026-10-04 (in-flight at audit time:
`src/platform/linux/file_dialog.zig` + `dbus.zig` (Linux `promptForPaths`), `readClipboardImage`
in `platform.zig`, `src/elements/native_view.zig`, and — appearing during the audit —
`apps/zeron/src/ui/browser/` and `apps/zeron/src/model/attachments.zig`). Re-audit after those land
(and point `crates/ui/src/browser/**` / `attachments.rs` at them in `tools/upstream/map.json`).

Method: every Rust module in `crates/ui/src` (and the gpui / gpui-base features it calls) was
checked against `apps/zeron/src` and `src/` by reading the Zig ports, their `//!` headers (most
cite the Rust file and list what is "not ported"), and by grepping for the behavior: action
handlers (`onAction`), event subscriptions, RPC method use, and settings-field consumers. Claims
like "button does nothing" mean there is no listener / no subscriber in the Zig tree.

Legend: ✅ done · 🟡 partial (what is missing) · ❌ missing · ➖ not applicable.
Paths: Zig paths are under `apps/zeron/src/` unless they start with `src/` (zpui). Rust paths are
under `crates/ui/src/` unless noted.

Scorecard (table rows below): ✅ 111 · 🟡 38 · ❌ 44 · ➖ 5.

The ported core is strong: engine client, theme (bit-exact), syntax (span-exact), markdown and
diff (exact), transcript rows, Changes / History panes, file explorer + editor, pickers, settings
pages, terminal emulation. What is missing is mostly (1) platform integration (menus, URL scheme,
reopen, notifications, drag-and-drop, file dialogs on macOS, accessibility), (2) the composer's
richer inputs (attachments, mentions, provider commands, wizard, dictation), (3) secondary surfaces
(browser, subagent / side-chat tabs, accounts, project actions, review comments, PR status), and
(4) plumbing: several controls render but nothing listens to them.

---

## 1. App lifecycle and platform integration

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Boot: settings → fonts → typography → theme → keymap → AppState → main window | `lib.rs` `run_app` | `main.zig` `onLaunch` | ✅ |
| Engine connect-or-embed | `state.rs` `EngineHandle::bootstrap` (probe port, else embed in-process) | `model/engine_state.zig`, `engine_bin.zig` (probe, else spawn the bundled `zeron-engine headless`: Zeron.app `Contents/Helpers/`, next to the binary in the Linux tarball; built from the pinned zeron by `apps/zeron/scripts/build-engine.sh` / `apps/zeron/engine-host`, no gpui). A data dir whose `engine.lock` is held (Rust app / daemon starting) is waited for, never double-spawned | ✅ different by design: the Zig client never embeds the engine, it spawns the bundled engine binary (no Rust Zeron install needed) |
| Main window: 1320×880, min 900×600, transparent titlebar, traffic lights 14,14, blur (mac), CSD (Linux), app id | `lib.rs` `open_main_window` | `main.zig` | ✅ |
| Restore / save window geometry per display (`window_geometry`, display uuid, debounced) | `lib.rs` `restored_main_window_bounds`, `save_window_geometry` | `lifecycle/window_state.zig`: restore on the remembered display (uuid; macOS `CGDisplayCreateUUIDFromDisplayID`), clamp/re-center (`WindowGeometry.restore`), `Window.observeBounds` → debounced save, close path saves without a display query; skipped while fullscreen/maximized like Rust | ✅ (macOS display uuid: CI) |
| Close veto (unsaved files) + flush settings on close | `lib.rs` `on_window_should_close` → `Shell::prepare_window_close` | `Window.onShouldClose` (zpui) + `lifecycle/root.zig` `prepareExit`: dirty editors are saved, the close resumes when clean; an unsavable file (conflict / failed save / deleted) cancels and is revealed with its banner; geometry save + settings flush on close. Linux CSD close goes through the same gate | ✅ |
| Graceful quit: flush settings, install pending update, drain engine | `lib.rs` `on_app_quit` | `App.onQuit` / `onShouldQuit` (src/app/lifecycle.zig): settings flush + `installOnQuit`; ⌘Q / Dock Quit go through the unsaved-files gate (macOS `applicationShouldTerminate:` cancels and re-requests). Engine stop on quit (both platforms): an `App.onQuitAsync` teardown (`EngineState.quitTeardown`) SIGTERMs the engine this client spawned (the engine's graceful `shutdown_signal`) and reaps it within gpui's 200 ms `SHUTDOWN_TIMEOUT` (it finishes draining on its own after that); an engine it only attached to is left running | ✅ |
| macOS: ⌘W keeps the process alive; dock click reopens the main window | `lib.rs` `ReopenState`, `app.on_reopen` | `quit_when_last_window_closes` = Linux only; `App.onReopen` → `lifecycle.openMainWindow` (new Shell around the live AppState) | ✅ (dock: CI) |
| macOS app menu bar (Zeron: About, Check for Updates…, Settings, Services, Hide/Hide Others/Show All, Quit; Edit; View: Appearance System/Light/Dark; Window: Minimize/Zoom/Close) with key equivalents from the keymap | `app_menus.rs` `app_menus()`, `cx.set_menus` | `lifecycle/app_menus.zig` `appMenus()` (same items/order) via `App.setMenus` (src/platform/mac/menu.zig): key equivalents from the keymap, `validateMenuItem:` from action availability, Services/Window menus, cut:/copy:/paste:/selectAll: selectors; refreshed when the keymap changes | ✅ (native rendering: CI) |
| `zeron::*` menu actions (About, CheckForUpdates, Quit, Hide, HideOthers, ShowAll, Minimize, Zoom, CloseWindow, Appearance*) | `app_menus.rs` handlers | `lifecycle/app_menus.zig` `install`: all 12 handled (About = standard about panel; ⌘W closes the right-pane surface first, then the window through the gate) | ✅ |
| Dock menu | none in Rust | none | ➖ |
| URL scheme `zeron://open/chat/<id>?workspace=…` (Info.plist / `.desktop` `x-scheme-handler/zeron`) | `lib.rs` `register_url_scheme`, `on_open_urls` → `AppState::open_deep_link`; `links.rs` parse/format | `App.onOpenUrls` → `lifecycle/links.zig` (`links.rs` port: encode/parse, sha256 workspace locator, pending link retried as identity/chats load, sidebar notices) | ✅ |
| Cold-launch URL argument (`zeron <url>`, `Exec=zeron %u`) | `apps/zeron/src/main.rs` `Cli.open_url` → `UiConfig.initial_url` | `main.zig` positional argument → `zpui.lifecycle.openUrls` (queued until the router listens) | ✅ |
| Single-instance behavior | none (each launch is a new process; engines are shared through the IPC port; only the log file is `flock`ed) | none | ➖ (same as Rust) |
| Notification banner click → focus chat / Settings → Providers | `lib.rs` `open_notification_target`, `notify::on_click` | `App.onNotificationActivated` → `lifecycle.openNotificationTarget` (reopens the window if needed; agent-update banners open Settings → Agents) | ✅ |
| Appshot global-shortcut service | `lib.rs` `start_appshot_service`, `appshots/**` | `appshots/service.zig`: hotkey via `Platform.setGlobalHotkey` following `appshotsEnabled` / `captureAppshot` / shortcut recording; skips while a Zeron window is focused; coalesces presses in flight; worker staging; delivery to the Shell (reopens the main window, else queues); `foregroundAfterCapture`; Linux `appshot-activation.sock` + `zeron appshot` CLI | ✅ (§12) |
| Log file `{data_dir}/logs/zeron-headed.log` with rotation + panic hook into it | `apps/zeron/src/main.rs` `open_log_file`, `panic::set_hook` | `lifecycle/log_file.zig`: same path, `flock` + `.old` rotation, pid-suffixed overflow + week-old sweep, `std_options.logFn` mirror (info default, `ZERON_LOG`), panic handler writes into it | ✅ |
| Crash reporting / telemetry | none in the desktop client (telemetry only in `apps/landing`) | none | ➖ |
| App self-update: release checker, download, install-on-quit, "Check for Updates…", sidebar update strip | `app_update.rs`, `crates/update` | `lifecycle/update.zig` + `app_update.zig`: same manifest / `latest.txt` format, sha256 via `.partial`, managed symlink + macOS bundle (`ditto`) installs, `--version` check of staged binaries, relauncher, hourly wall-clock schedule with backoff, install on quit, `ZERON_AUTO_UPDATE=0`, strip + dialog. Feed: `ZERON_RELEASES_URL` / `-Dzeron-releases-url` (default off: Zig builds are not published) | ✅ (feed hosting: release work) |
| Packaging: macOS .app (universal), Linux tarball | release workflow | `zig build zeron-app-bundle`, `zig build zeron-dist` | ✅ |
| Signing / notarization, Linux installer, auto-update channel | release workflow, `crates/update` | — | ❌ |
| System light/dark follow | `appearance.rs` `observe_window` | `src/platform/linux/appearance.zig` (portal + gsettings), `src/platform/mac` appearance callback | ✅ |

## 2. Keyboard shortcuts (`actions!` groups)

Bindings are ported 1:1 (`keymap.zig` `defaultBindings`, tested on both platforms); the gaps are
handlers. Customizable combos come from `KeymapConfig` (`mod` = cmd on macOS, ctrl elsewhere).

| Action | Default binding | Handler in Zig | Status |
|---|---|---|---|
| `composer::*` (39 editing actions: motions, selection, word/line delete, copy/cut/paste, undo/redo, Newline, Submit, ModifiedSubmit, MessageNewlineOrAccept, MentionTab, OutdentList) | arrows, home/end, cmd/alt/ctrl variants, `enter` / `mod-enter` per send setting | `ui/input/text_input.zig` (all listed) | ✅ |
| `composer::ToggleDictation` | `mod-d` | `ui/input/text_input.zig` hold-to-talk: press/release (key-up or released modifier, blur), auto-repeat ignored, propagates when Voice is off | ✅ |
| `shell::ToggleSidebar` | `mod-b` | `ui/shell/shell.zig` `actToggleSidebar` | ✅ |
| `shell::ToggleChanges` | `mod-r` | `actToggleChanges` | ✅ |
| `shell::ToggleFiles` | `mod-e` | `actToggleFiles` | ✅ |
| `terminal::ToggleTerminal` | `mod-j` | `actToggleTerminal` | ✅ |
| `shell::NewSession` | `mod-n` | `actNewSession` | ✅ |
| `shell::AddSpacePalette` | `mod-shift-n` | `actAddSpace` | ✅ |
| `shell::ToggleCommandPalette` | `mod-k` | `actTogglePalette` | ✅ |
| `shell::OpenSettings` | `mod-,` | `actOpenSettings` | ✅ |
| `shell::NextSession` / `PrevSession` | `ctrl-tab` / `ctrl-shift-tab` (mac), `mod-tab` / `mod-shift-tab` | `actNext` / `actPrev` | ✅ |
| `shell::JumpSession(n)` | `mod-1…9` | `actJump` | ✅ |
| `shell::ArchiveSession` | `mod-shift-a` | `ui/shell/wiring.zig` `actArchiveSession` (optimistic + `setChatArchived`, skipped while an overlay owns the keyboard) | ✅ |
| `shell::OpenModelPicker` | `mod-/` | `ui/shell/wiring.zig` `actOpenModelPicker` → `ComposerView.toggleModelPicker` | ✅ |
| `shell::SaveFile` | `mod-s` | `ui/shell/wiring.zig` `actSaveFile`: saves the active file tab while the pane is open (`save_active_document`) | ✅ |
| `shell::RandomWallpaper` | `mod-u` | `wiring.actRandomWallpaper` | ✅ |
| File editor bindings (gpui-base input keymap: motions, selection, delete, indent, find/replace, go-to-line, save) | reinstalled by `shell::apply_keymap` after clearing | `keymap.zig` `component_bindings` hook (run first after every clear, like `gpui_base::init`); the shell installs `ui/editor/actions.zig` `bindDefaults` into it, so settings-driven rebuilds keep it | ✅ |
| `browser::Reload/FocusAddress/NewTab/CloseTab/Back/Forward` | `mod-shift-r`, `mod-l/t/w/[/]` (Browser context) | — | ❌ (no browser) |
| `zeron::*` (menu verbs) | `cmd-q/h/alt-cmd-h/m/w`, `mod-,` | bound and handled (see §1) | ✅ |
| Appshot capture (global) | `ctrl-alt-space` / `mod-alt-space` | `appshots/service.zig` (registered through the platform, not the in-app keymap) | ✅ |
| Settings → Shortcuts: record, conflict detection, reset, restore defaults, live rebind | `settings/shortcuts.rs` | `ui/settings/shortcuts.zig`, `ui/settings/store.zig` `applyKeymap` | ✅ |
| Escape stops the active agent (setting) | `composer.rs` | `wiring.onShellKey` → `ComposerView.escapeStop` | ✅ |

## 3. Shell, titlebar, gates

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Glass window frame, sidebar \| main \| right pane, drag-resize with width tweens | `shell.rs` | `ui/shell/shell.zig` | ✅ |
| Unified 38px titlebar: control cluster, session identity (harness mark + title), `+` new session, right tab strip in the band | `shell.rs` `render_titlebar_cluster`, `render_session_title_bar`, `shell/tabs.rs` | `ui/shell/titlebar.zig` | ✅ |
| Linux CSD caption buttons + resize borders | `render_linux_caption_controls`, `render_linux_resize_borders` | `ui/shell/titlebar.zig` | ✅ |
| Boot splash (matrix spinner) | `loaders.rs` | `ui/components/loaders.zig`, `ui/shell/shell.zig` | ✅ |
| Engine failure gate + Retry | `render_gate_card` | `ui/shell/gates.zig` | ✅ |
| Sign-in gate (browser login) | `render_gate_card` | `ui/shell/gates.zig` `signInGate` → `AuthStore.signIn` | ✅ |
| Login dialog ("Enable sync" / "Open browser again" / Cancel; Rust has no paste-code UI) | `start_sign_in`, `render_sync_overlay` `SyncFlow::Enabling/Canceling`, `cancel_auth_setup` | `ui/shell/wiring.zig` (Enabling / Canceling) + `ui/shell/sync_flow.zig` (the post-sign-in SwitchOffer wizard, Switching, import, restart fallback) | ✅ |
| Org gate: create workspace / pick org / sign out | `render_org_gate` | `ui/shell/gates.zig` + `ui/shell/wiring.zig`: name field (Enter or Create → `CreateOrg`, name validation), org rows → `SelectOrg`, `ListOrgs` on first show, errors under the field | ✅ |
| Signed-out restart prompt, sync overlay, local-workspace import (`ImportLocalWorkspace`) | `render_signed_out_restart`, `render_sync_overlay`, `spawn_local_import`, `start_local_runtime_transition` | `ui/shell/sync_flow.zig`: every `SyncFlow` step (Sync is ready → Bring my work / Start fresh / Switch now / Later, Switching, Importing N of M + progress bar, You're all set, Import didn't finish + Retry, Sync needs a restart → Quit, Sign out? → Signing out…, full-window "Signed out" + Retry local mode); account menu rows via `account_menu_action`; `sync_flow_after_auth` on auth/engine/scope changes; parity `sidebar_sync_parity_test.zig` | 🟡 runtime swaps are `StopEngine` + reconnect (the Zig client respawns `zeron headless`) instead of Rust's in-process re-bootstrap; no data-dir lock wait |
| Persist pane layout (sidebar width/collapsed, right pane width/open, files panel width, terminal height/open) | `settings.rs` debounced saves | `ui/shell/prefs.zig` `mut` → `writeSettings` (debounced): sidebar width/collapsed, right pane width, view-menu choices. `rightPaneOpen`/`terminalOpen` are legacy in Rust too; files panel and terminal have no resizer yet (values kept as loaded) | ✅ |
| Harness-updates island on Home ("4 agent updates · MacBook Pro (2)" capsule: overlapping brand marks, title, spinner / check / danger glyph, chevron → 360px list of per-agent rows with Update / Cancel / Check again / View steps) | `shell/harness_updates.rs` | `ui/shell/harness_updates.zig`, mounted by `main_panel.zig` 24px above the window bottom on Home (not under an open terminal dock): one `WatchHarnessUpdates{targetDeviceId}` per `harness-updates-v1` host (registry + connected engine) with Rust's presence reconciliation and 1→15s retry backoff; actions send `ApplyHarnessUpdate` / `CancelHarnessUpdate` / `CheckHarnessUpdates` `{harness, targetDeviceId}` (the RPCs Settings → Agents uses); failures → sidebar notice; View steps → Settings → Agents (`wiring.zig`); Escape and outside clicks collapse; RESIZE tween for size / radius / mark collapse / row reveal; marks layered via `effects.layered`. Parity: `harness_updates_test.zig` against a fixture dumped from the Rust helpers (`scripts/harness_updates_parity.rs`) | ✅ (no focus ring / aria, no overlay scroll rail; View steps does not pre-select a remote device: the Agents page has no device target) |
| GitHub star banner | `render_github_star_banner` | `ui/sidebar/sidebar.zig` `renderStarBanner`: accent chip above the update strip, click opens the repo, either click or ✕ persists `githubStarBannerDismissed` (hidden in fixture runs unless `meta.githubStarBanner`) | ✅ |
| Project actions (titlebar Run/Setup menu, edit/delete/import, `RunProjectAction`) | `project_actions.rs`, `shell/actions_ui.rs` | `ui/shell/project_actions.zig` (controller with per-(device, space) cache + generations, split control: loading / preferred action / unavailable retry / Add action, menu with run · edit · Import from zeron.json · Add, editor + delete confirm, `last_project_action_by_space_id`), mounted by `titlebar.zig`; a run reserves a named tab in the chat's bottom terminal drawer (`ui/shell/terminal_panel.zig` `reserveTab` → `attachReserved` streams the engine PTY, `failReserved` prints the red failure line) and opens the drawer on it; worktree setup actions (`TakeProjectActionSetup` polled after the queued run, `extras.zig` `WorktreeSetup`) attach as "<name> (setup)" tabs (`attachWorktreeSetup`, "Setup action failed: …" notice) | ✅ (the drawer's open flag is global, not per chat) |
| Chat drop zone (drop files onto the conversation) | `shell/chat_dropzone.rs`, `shell/side_chats.rs` | `ui/shell/main_panel.zig`: `onDrop(ExternalPaths)` → `ComposerView.addPaths`; a right-pane file tab or an explorer row (`files.WorkspacePathDrag`, owner-checked like `attach_workspace_drag`) → `addWorkspacePath`; "Drop to attach" overlay via typed `dragOver`. Side chats get their own drop zone (`surfaces.zig` `SideChatSurface`: workspace references into the reply field, no OS files). Tests: `wiring_test.zig` "chat drop zone", `composer/attachments_test.zig`, `files/panel_test.zig` | ✅ |
| Navigation focus recovery | `shell/navigation_focus.rs` | `ui/shell/shell.zig` (focus on open/close of overlays) | 🟡 |
| Connection / status strip | `render_status_strip`, `render_connection_pill` | `ui/shell/main_panel.zig` reserves the strip height; no pill | 🟡 |

## 4. Sidebar

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Space filter dropdown ("All projects", search) | `shell/spaces.rs` | `ui/sidebar/sidebar.zig` | ✅ |
| Pinned / Sessions / Archived disclosures, detailed + compact rows, status glyphs, harness/branch/project labels | `shell.rs` `render_chat_row`, `spaces.rs` | `ui/sidebar/sidebar.zig` | ✅ |
| Pin drag-reorder (optimistic overlay, `changeSidebarPin move`) | `shell/sidebar_pins.rs` | `ui/sidebar/sidebar.zig` `PinDrag` | ✅ |
| View menu (organize by device/project/none, sort, show branch/PR/harness/icon/location) | `render_sidebar_view_menu` | `ui/sidebar/sidebar.zig`; choices persist (`sidebarOrganization`/`Sort`/`Show*`/`Compact`) and are read back at boot | ✅ |
| Custom sidebar sections (account-synced: create, edit, archive all, delete, move chats) | `shell/sidebar_sections.rs` | `ui/sidebar/sections.zig` (projection, one synced write queue for pins + section intents over `changeSidebarPin`, 20 s unconfirmed-write cutoff `markUnconfirmed`, local `sidebarSectionsByProfile` / `sidebarPinnedSessionIdsByProfile`, one-time import) + `sections_ui.zig` (disclosures with the 180 ms height + chevron tween, ⋯ menu with ↑/↓/Enter/Escape, New/Edit section dialog, Archive all, drag between Pinned / sections / Sessions); pins follow the account snapshot + queued writes (`syncPins`, `active_sidebar_pins`); parity vs zeron_proto in `sidebar_sync_parity_test.zig` | ✅ |
| Chat context menu: Rename, Pin/Unpin, Archive, Copy ▸ (path / Zeron link / Codex link / harness session id), Delete… (confirm) | `shell.rs` ~9630–9910 | `ui/sidebar/sidebar.zig` + `ui/sidebar/chat_menu.zig` (links.rs `workspace_locator` / `zeron_conversation_link` port); copies report in the sidebar notice; Delete… → `ui/shell/wiring.zig` "Delete session?" modal → leave the chat, purge its draft, `deleteChat` | ✅ (side-chat tab variants and tab-close rows not ported) |
| Rename session (inline title field on the row) | `open_rename_chat` / `finish_rename_chat` | `Sidebar.beginRename`: single-line field seeded + selected; Enter / blur commit a changed non-empty title (`renameChat`), Escape drops; `/rename` uses it too | ✅ (no auto-scroll-into-view of the edited row) |
| Space management (rename / delete via row menus) | `shell/spaces.rs` `render_space_overlays` | right-click a project in the spaces menu → Rename… ("Rename project" dialog → `renameSpace`) / Remove… ("Remove project?" with the session count → `deleteSpace`) | 🟡 the row menu opens beside the spaces card (zpui composites the frosted card above a later overlay); no reorder |
| Project artwork (repo avatars via `ResolveGitAvatars`, local icon detection) | `shell/project_icon.rs` | `ui/sidebar/project_icon.zig` (local files only; RPC fetch not ported) | 🟡 |
| PR badge (`#413`) | `render_pull_request_badge`, `change_requests.rs` | `ui/components/change_request_badge.zig` (tone by state, `PR #N · State` tooltip card, click opens the PR) from `model/change_requests.zig`; sidebar rows + composer git chip row; fixture numbers (`ui/shell/prefs.zig`) keep the static `ui/components/badge.zig` chip | ✅ (command palette / file-tree sections rows not wired) |
| Footer: account pill + user menu (Enable sync, sync progress/restart, Sign out, Check for updates) | `render_user_menu`, `render_sidebar_footer` | `ui/sidebar/sidebar.zig` `renderFooter` with `sync_flow.identity` / `accountMenuAction`: Enable sync, Sync setup in progress, Finish sync setup, Sign out (confirm), Check for updates | ✅ |
| Update strip | `render_update_strip` | driven by the app's own updater (`lifecycle/app_update.zig` `strip`); click = download / restart / explain / advise | ✅ |
| Moving-session animation when a row changes section | `render_moving_sidebar_session` | `ui/sidebar/sections_ui.zig` `renderMoving`: the dragged row follows the pointer on a raised surface; the source slot collapses (row + gap) while another group previews the drop and re-opens on the way home (`sourceSlot`); destinations open a gap tween; a cancelled drop slides home (TAB_SLIDE); a 16 ms loop scrolls the list near its edges for non-pinned rows (`dragScrollDelta`, 48 px band, 12 px/frame); destination siblings at/after the row-level insertion point slide apart by one slot and slide back on cancel (`placeRow`, `gapOffset`, `render_sidebar_gap_row`); the end gap opens only in the previewed accordion and never in the source group | 🟡 pinned rows have no edge autoscroll (Rust `pinned_session_autoscroll_tick`) |

## 5. Command palette and pickers

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Command palette (mod-k): actions, chat search, key hints | `shell/command_palette.rs` | `ui/shell/palette.zig` | ✅ |
| Add-space palette (devices → drives → folders, typed paths, ⌘⏎) | `shell/spaces.rs` `AddSpaceFlow` | `ui/pickers/add_project.zig` | ✅ |
| New-session target pickers: project, device, checkout (local / new worktree / reuse worktree), ref (`ListRefs`, `SwitchRef`) | `pickers.rs` | `ui/pickers/pickers.zig`, `paths.zig`, `menu.zig` | ✅ |
| Repo picker clone / create (`ListRepos`, `CloneRepo`, `CreateRepo`, `AddRepo`) | — (engine RPCs only; zeron's UI at the pin never calls them) | — | ➖ nothing to port |
| Worktree delete (`DeleteWorktree`) | — (engine RPC only; no UI caller in zeron) | — | ➖ nothing to port |
| Harness/model picker, compact presentation (effort slider, fast mode, model options, provider page, favorites) | `pickers/compact.rs` | `ui/composer/model_picker.zig`, `run_config.zig` | ✅ |
| Full (non-compact) model picker (`compactModelPicker = false`) | `pickers.rs` `render_harness_model_popover` | — (setting has no consumer; compact is always shown) | ❌ |
| Popover primitives: frosted card, menu-in motion, keyboard nav, ranked search, outside-click dismissal | `popover.rs` | `ui/components/popover.zig`, `ui/pickers/menu.zig` | ✅ |
| Nested-menu hover intent; dropdown containment in dialogs | `popover/hover_intent.rs`, `popover/contained.rs` | — (only flat menus exist) | ❌ |

## 6. Composer

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Hand-written multiline input: soft wrap, auto-grow, IME, mouse selection, multi-click, autoscroll, undo/redo, clipboard | `composer.rs` `ComposerInput` | `ui/input/text_input.zig`, `editor.zig`, `segment.zig` | ✅ |
| Compact ↔ expanded pill with hysteresis + height tween | `composer.rs` | `ui/composer/composer.zig`, `metrics.zig` | ✅ |
| Send / Queue / Stop morph, optimistic echo, failure notice | `composer.rs` | `ui/composer/composer.zig` | ✅ |
| "Not delivered — click to retry" (`RetryDelivery`) | `transcript.rs` `retry_send` | `TranscriptView.retrySend`: restarts the grace window (`TranscriptStore.retryPendingSend`) + `RetryDelivery {chatId}` | ✅ |
| Per-chat drafts | `composer.rs` | `ComposerView.drafts` | ✅ |
| Sticky composer defaults (`composer-defaults.json`): last harness, model per harness, reasoning, label cache — loaded at boot, written on new-thread picks | `settings/composer.rs`, `pickers.rs` `save_defaults` | `model/composer_defaults.zig` + `model/composer_store.zig` (global), `ui/composer/model_picker.zig` writes; model-option picks, favorites toggling and device/project restore not wired yet | 🟡 |
| Zig-only: explicit Default agent / Default model for new threads (Settings → General, "Last used" default; falls back to last used, then first offered) | — | `ui/settings/new_thread_defaults.zig`, `model/composer_store.zig` (`new-thread-defaults.json`, a sidecar Rust never rewrites), `ui/composer/run_config.zig` | ✅ |
| Queue tray: rows, remove, edit, send-now / steer | `queue.rs` | `ui/composer/composer.zig` `renderQueue` + `ui/composer/extras.zig`: whole-row drag reorder (slide offsets, optimistic `QueueStore.moveLocal` + `MoveQueuedMessage`), leased edit (`BeginQueuedMessageEdit` → 20s `RenewQueuedMessageEdit` → `FinishQueuedMessageEdit` commit / discard / cancel, Rust's failure copy, capability gate); the edit restores the row's attachments from the chat's host (`attachments.QueuedLoadJob`, `queue_visible_text`) and displaces the draft's own | 🟡 no Appshot restore; no slide tween; attachment rows' interrupt offer |
| Todo panel above the composer | `todo_panel.rs` | `ui/composer/todo_panel.zig` (pure: latest list, summary, fold window, per-chat state) + `extras.zig` `renderTodo` (header, fold rows, dismiss while idle, auto-tidy) | ✅ (no fade-in tween / scroll cap on long expanded lists; the in-progress glyph is static) |
| Context-usage ring | `context_usage.rs` | `ComposerView.renderFooter` | ✅ |
| Plan-usage ring + account switcher (`ListAgentAccounts`, `ActivateAgentAccount`) | `account_usage.rs` | `ui/composer/account_usage.zig` (ring in `ComposerView.renderFooter`, 400px accounts card, optimistic switch, 30s forced-probe floor, 5 min poll; `AccountsCache` global shared with Settings → Accounts) | ✅ |
| Session footer: checkout + branch / new-session checkout + ref chips | `pickers.rs` `render_footer` | `ComposerView.renderFooter`, `ui/pickers/pickers.zig` `PickerRow` | ✅ |
| Slash popup: built-in workspace commands (`/settings`, …) | `composer.rs` `WorkspaceCommand::catalog` | `ComposerEvent.workspace_command` → `ui/shell/wiring.zig` `executeWorkspaceCommand` (model, new, resume, settings, diff, files, terminal, rename, stop) | ✅ |
| Provider slash commands + skills (`ListCommands`, `ListSkills`), per-agent completion prefs | `composer.rs`, `settings/completion.rs` | `ui/composer/completions.zig` (`invocation_candidates`, `with_workspace_commands`, `Invocation::link`/`prompt_text`, `completion_trigger`) + `extras.zig` (catalog per workspace/harness, `$` skills, `composer-references-v1` gate, Rust's empty/error copy); verified against a live engine | ✅ (no catalog cache across tokens, no pasted-reference resolution, no skeleton rows) |
| `@` file mentions: popup (`SearchFiles`), mention chips, projection into the prompt | `composer.rs`, `crates/proto/src/file_mentions.rs` | `ui/composer/mentions.zig` (`local_file_link`, `local_path_is_safe`, `reference_suffix`, `dropped_file_mention`) + `extras.zig` (80ms debounce, `SearchFiles`, keyboard nav, canonical `[name](zeron-file:path)` insert); verified against a live engine | 🟡 no chip projection in the input (the link text shows), no retry on a cold relay, no hover tooltips |
| Attachments: paste images, drop files, paperclip picker, staged chips, chunked upload (`UploadChunk/UploadCommit`), attachment-ref transport | `attachments.rs` | `model/attachments.zig` + `ui/composer/composer.zig`: picker (`promptForPaths`), pasted images / file URIs, drops; background staging (BMP→PNG, 24 MB cap), 56px thumbnail chips + lightbox; send = 3-wide chunked upload with retries/deadlines, queued-attachment flow (`pending://` + transfers, engines ≥ 0.2.12) else host-committed paths, `with_attachments` trailer + Run `attachments`; Stop cancels the upload. E2E test vs a fake engine: `composer/attachments_test.zig` | ✅ |
| Question wizard (pending input replaces the composer) | `composer.rs` wizard reducer | `ui/composer/wizard.zig` (reducer, `pending_input_request`, `input_request_resolved`) + `extras.zig` panel (header + counter, numbered options, free-text override, Back/Next/Submit, 1–9 / Enter / Escape keys, 220ms auto-advance, latch, `respondInput`, 2s re-show) | ✅ |
| Markdown-aware editing (list continuation/indent, faces) | `composer_markdown.rs` | `OutdentList` action only | 🟡 |
| Dictation (mic button, waveform, glass, Parakeet transcription) | `dictation.rs`, `dictation/**`, `crates/voice` | `ui/input/dictation.zig` (Phase/Meter/Dictation) + `TextInput` session (partials/final over the begin selection as one undo step, cancel on edit/move/undo/Escape/IME, send-after-final, 30 s finalize deadline); `ui/composer/voice.zig` (mic↔Stop morph, accent/light glass, waveform canvas, clock, Cancel slot, outcome strip, tap/permission/hold sources, focus-out + window deactivation cancel); `voice/service.zig` Native transcriber; tests in `ui/input/tests.zig`, `ui/composer/dictation_test.zig`, `ui/shell/dictation_test.zig`. Gaps: window activation is sampled at render (no observer in zpui), mini spinner approximated | ✅ |
| Dock choreography (canvas ↔ thread position, panel hand-off fade) | `composer_dock.rs`, `composer_dock/**` | `ui/shell/dock.zig` (Glide, Visuals, PanelHandoff, DockState ported verbatim; parity-tested against `scripts/dock_parity.rs`), driven by `main_panel.zig` `renderDockTransition`: the composer glides between the hero slot and the thread dock, the transcript fades / rises 8 px, the hero dissolves (opacity) | 🟡 pane hand-off not fed (no right-pane target width in the main panel), hero ↔ thread height reflow (`DockLayout` / `DockReflow`) and the composer's selector / footer visuals not wired, width glide not applied. See docs/ANIMATIONS.md |
| Message badges (fold staged context into the prompt, pill in the transcript) | `badges.rs` | `ui/transcript/badges.zig`: `split` over the extractor list (review comments via `model/comments.zig` `extractBadge`), the pill (24px, `chat-round-line`, hover card after 280ms, frosted popover card) in sent user bubbles (`rows.zig` → `view.zig`); the composer folds staged comments on send (`review_comments.foldPrompt`); parity-tested (`transcript/parity_test.zig`) | ✅ |

## 7. Transcript

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Virtualized block-granular rows, stick-to-bottom, minimal splices on stream | `transcript.rs` | `ui/transcript/view.zig`, `rows.zig` | ✅ |
| Tool-group accordion, chips, detail folds with tweens, inline diffs | `transcript.rs` | `ui/transcript/tools.zig`, `diff_view.zig` | ✅ |
| Reasoning ("Thought process") | `transcript.rs` | `ui/transcript/thought.zig` | ✅ |
| User bubble collapse/expand, copy message | `transcript.rs` | `ui/transcript/view.zig` | ✅ |
| Error chip, fork marker, input (question) chip, working trailer with flavour words | `transcript.rs`, `notice.rs` | `ui/transcript/view.zig` | ✅ |
| "Worked for …" summary | `transcript.rs` | compact work header: `durationMs` (≥1s), else the live trailer's last elapsed; the summary crossfades into "Worked for 5m 10s" (FADE_IN, 4px rise) only for headers that were live this session (`ui/transcript/tools.zig` `compactWorkTitle`) | ✅ |
| Message rail (minimap ticks, hover preview, click to scroll) | `rail.rs` | `ui/transcript/view.zig` | ✅ |
| Jump / "Scroll to bottom" button | `render_jump_to_bottom` | `TranscriptView` (`jump_visibility` 320/2px hysteresis, frosted pill above the composer, click re-pins the tail); matches `transcript-mock-top-dark.png` | ✅ (rendered inside the transcript, not the composer dock) |
| Text selection across rows + copy | `markdown/selection.rs` | `ui/markdown/rich_text.zig` registry | ✅ |
| Streaming fade veil | `markdown/veil.rs` | `ui/markdown/veil.zig` (`ElemVeil`/`RowVeil`, mugen cadence EMA, `(1−p)^1.6`, fast-stream boost, `applyVeil`, `sliceSpans` per code line); `TranscriptView` keeps one veil per live row, seeded for rows already on screen at attach, none under reduced motion; parity-tested against Rust | ✅ |
| User attachments in bubbles (read-back via `ReadAttachmentChunk`), preview lightbox | `attachments.rs`, `image_viewer.rs` | `ui/transcript/view.zig` `attachmentThumb`: decoded-image cache keyed by (device, path, mime), `ReadAttachmentChunk` read-back from the chat's host / this device with the retry ladder, upload aliases seeded on send, shared lightbox (`ui/media/viewer.zig`) | ✅ |
| Generated images + "Preview generated image" | `render_generated_image` | rendered from local path; no preview | 🟡 |
| "Show full output" / full diff (`FetchToolBlob`) | `transcript.rs` | `ui/transcript/blobs.zig` (request / land / most-recent-wins detail upgrade, affordance ladder incl. loading + retry, `blob_detail` 400-line cap) wired into `tools.zig` | ✅ (no 20s timeout) |
| Subagent spawn chips → open subagent transcript tab | `transcript.rs` "Open subagent", `shell.rs` `RightSurface::Subagent` | chip click → `OpenSubagent` (`ui/transcript/subagents.zig` `subagent_tab_title`) → `ui/shell/surfaces.zig` `SubagentSurface` (frozen: `FetchToolBlob {source}/{doc}` then the doc watch on failure; live: `WatchDocMessages` on the doc) | ✅ (no jump pill / working trailer tuned for subagent docs) |
| Inline-code / Markdown file links → open in the right pane | `workspace_links.rs`, `markdown/link_interaction.rs` | `ui/shell/wiring.zig` sets `rich_text.registry.handler`: `file://` / relative links open the editor tab at `:line[:col]` (`FileEditor.goToLineWhenLoaded`); web links open in the session Browser (`openWebLinksInZeron`) or the system browser; the transcript's inline-code link root follows the selected local chat | 🟡 no link context menu / keyboard focus, no outside-root read-only open |
| Link destination disclosure, width-dependent link presentation | `markdown/link_destination.rs`, `link_presentation.rs` | `ui/markdown/rich_text.zig`: hovering a link segment shows the destination card (file links: decoded path; zero-width break points, natural width ≤ 360px, scrolls past 160px); `ui/markdown/link_presentation.zig`: a web link wider than the line truncates at a grapheme prefix + `…` during measure, re-presented at the final width; selection / copy map back through the omission offsets | ✅ (no keyboard-focus disclosure; graphemes approximated by code points + combining marks) |
| Mermaid diagrams (lazy background render, cache, preview) | `markdown/mermaid.rs`, `mermaid_cache.rs` | `apps/zeron/src/mermaid` (renderer port) + `ui/markdown/diagrams.zig` (lazy one-at-a-time background render of painted fences, 64 MB LRU, source toggle, failure notice) + the transcript lightbox (`openDiagram`) | ✅ |
| Compact transcript mode (setting) | `transcript.rs` | `rows.zig` `buildRows(.., compact)`: the whole turn's work (tools, thoughts, narration as "Wrote" chips) folds into one `{entry}#work` header; the reply (trailing text run) stays rows; expanded = the compact-off rows tagged `compact_fold`, mounted while open / through the close tween and clipped to one shared height budget (`compactFoldGeometry`, paint-probed heights, settle sweep); nothing auto-opens; `transcriptCompactMode` read live. Parity-tested against `rows_for_entry` | ✅ |
| Code fences fit-content toggle | `markdown/render.rs` | `ui/markdown/root.zig` `code_state.fit_hooks`: every fence (transcript and Markdown preview) follows the global `codeFencesFitContent`; the toggle flips the setting (immediate save) and refreshes windows (`wiring.zig`) | ✅ |

## 8. Markdown, syntax, diff

| Feature | Rust | Zig | Status |
|---|---|---|---|
| pulldown-cmark 0.12.2 parse, block tree, incremental streaming reparse, mend | `crates/markdown`, `markdown/mod.rs` | `markdown/**` (exact parity tests) | ✅ |
| Render: headings, lists, tasks, tables, quotes, code blocks with copy + per-line highlight, images, file-link tiles | `markdown/render.rs` | `ui/markdown/root.zig`, `rich_text.zig`, `file_icons.zig` | ✅ |
| Inline-code file links | `markdown/inline_code_links.rs` | `markdown/inline_code_links.zig` | ✅ |
| Tree-sitter highlighting (27 grammars) | `crates/syntax`, `syntax_cache.rs` | `syntax/**`, `vendor/tree-sitter` (span-exact) | ✅ (no bounded document cache like `syntax_cache.rs`) |
| Patch parsing, `similar` diffs | `changes.rs`, `similar` | `diff/**` (exact) | ✅ |

## 9. Right pane surfaces

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Surface host: per-chat tabs, `+` menu (Files, Browser, Terminal, Diff, History), drag reorder, takeover, close-on-empty | `shell.rs` `render_right_pane`, `RightSurface` | `ui/shell/right_pane.zig` | ✅ |
| Tab kinds `Subagent`, `SideChat` | `shell.rs` | `right_pane.zig` `Surface.subagent` / `.side_chat` (`surfaces.zig`, `right_pane_chats.zig`) | ✅ |
| **Changes**: scope (working tree / branch / latest turn / commit), ref selector, discard + confirm, split / wrap, collapse all, sticky headers, full-document syntax, virtualized rows | `changes.rs` | `ui/changes/**` | ✅ |
| Review comments on diff lines and editor lines (comment adder/cards/drafts, folded into the prompt) | `comments.rs`, `comment_ui.rs`, `changes.rs`, `files/preview.rs`, `state.rs` | `model/comments.zig` (fold / badge extract / card metrics / editor anchors; parity fixture from comments.rs compiled verbatim, `scripts/comments_parity.rs`), `model/review_comments.zig` (in-memory store per composer key + flushes, like Rust), `ui/changes/comment_ui.zig`, `ui/changes/pane.zig` (hover `+`, cards, drafts, edit/remove, split right column), `ui/editor/review.zig` (gutter cells, popover card/draft, anchors through edits, flush until saved; the Markdown preview shows the same file comments as cards under their blocks with a hover `+` per block, `openFromPreview`), composer fold/chip/send-block (`ui/composer/review_chip.zig`) | ✅ |
| PR / change-request status for the checkout (`WatchCheckoutChangeRequest`) | `change_requests.rs`, `state.rs` | `model/change_requests.zig` `ChangeRequestStore` (one watch per active checkout, local vs `targetDeviceId` routing, UnknownMethod → unsupported until the device version changes, re-validated per chat, hidden with the sidebar PR setting) | ✅ (Rust has no checks/CI state either) |
| **History**: lane graph, paging, search, fetch all, branch tips, columns, author avatar ⇄ name, commit tabs | `history.rs` | `ui/history/**` | ✅ (column reorder `gitHistoryColumnOrder` not applied; avatars via `ResolveGitAvatars` not fetched) |
| **Terminal**: tabs, Ghostty VT, keys/mouse/paste encoding, theme palette, 12 ms coalescer | `terminal/**` | `terminal/**`, `ui/shell/terminal_dock.zig` (one session), `ui/shell/terminal_panel.zig` (the bottom drawer: per-chat tab sets kept across chat switches, 118px tabs with live OSC titles, close / middle-click close, New terminal, Hide; reserved tabs for Project Actions), height from `terminalHeight` with a top-edge resize drag (double-click resets) in `main_panel.zig` | 🟡 "+" tabs run a **local** PTY (`terminal/pty.zig`) instead of the engine's `OpenTerminal`/`SubscribeTerminal` (so remote-device sessions get a local shell; Project Actions do stream the engine PTY); no tab drag-reorder; the open flag is global, not per chat (the open/close height tween is ported: `main_panel.zig` `terminal_tween`, RESIZE) |
| **Browser**: device-local tabs, address bar, back/forward/reload, WKWebView (mac) / offscreen WebKitGTK helper (Linux) | `browser/**` | empty "Preview your work" page (`ui/shell/right_pane.zig`) | ❌ (`src/elements/native_view.zig` in progress) |
| **Files explorer**: lazy tree, search, git status, hidden/ignored toggle, keyboard nav, context menu, inline rename, delete confirm | `files/**`, `shell/files_panel.rs` | `ui/files/**` | ✅ |
| Explorer "Add to chat" / drag files into the chat / drag-move entries | `files/drag.rs`, `files/context_menu.rs` | "Add to chat" → `RightPane.AddToChat` → `ComposerView.addWorkspacePath` (`dropped_file_mention`); tree and search rows drag a `WorkspacePathDrag` (`ui/files/drag.zig`: raised chip ghost, owner = the explorer's chat) onto the conversation / a side chat (file reference) or onto a tree folder (move via rename, 650 ms hover-expand, edge autoscroll, `destination_path`); tests in `files/panel_test.zig` | ✅ |
| Explorer Subagents / Chats sections | `files/sections.rs` | `right_pane_chats.zig` `syncSections` (`subagent_rows` order, `child_chat_rows`, fingerprinted per transcript revision / minute); rows open subagent / side-chat tabs; `+` = new side chat, fork = `ForkSideChat` | ✅ |
| Rename/delete propagation to open editors | `shell/file_mutations.rs` | `ui/shell/right_pane.zig` subscribes each explorer's `EntryRenamed` / `EntryDeleted`: every editor tab of the chats sharing that workspace follows a moved file or folder (`FileEditor.setPath`, buffer kept) or shows "Deleted on disk" (`markDeleted`); image previews reload / report removal (test in `ui/shell/wiring_test.zig`) | ✅ (the mutation itself is not serialized across surfaces: no wait-for-pending-save) |
| **Editor**: rope buffer, virtualized rows, soft wrap, gutter, indent guides, find/replace, go-to-line, hash-guarded save, conflict banners, syntax | `files/editor*.rs`, `files/document.rs`, `files/preview.rs`, gpui-base | `ui/editor/**` | ✅ (autosave / word wrap follow Settings → Files via `RightPane.editorOptions`) |
| Markdown preview, image preview | `files/markdown_preview.rs`, `files/markdown_media.rs`, `files/image_preview.rs` | `ui/files/markdown_preview.zig`: `.md`/`.markdown` tabs open rendered (toolbar eye / file-code toggle, line navigation shows the code), virtualized 900px column over the live buffer (2 MB clip, truncation notice), task checkboxes that toggle the buffer marker (`FileEditor.toggleMarkdownTask`, undoable, stale-source guarded), code copy + fit, Mermaid (click → lightbox), heading anchors, relative links → editor tabs (`OpenPath`), web/mail → app handler, others rejected; review comments as cards + drafts per block; images (first 32, 64 MB decoded cap) load from disk for local workspaces or via chunked `ReadWorkspaceImage` against the editor's checkout, click → shared lightbox, "Open image link" for linked images, web images stay `alt — url` (click opens). `ui/files/image_preview.zig`: chunked `ReadWorkspaceImage` (identity/size/offset checks) or a local read, off-thread decode, 64 MB cap, 30s timeout, fitted viewer with ⌘/Ctrl-wheel zoom + pan | 🟡 images load one at a time (Rust: 3 in parallel); code-fence horizontal scroll offsets are not reset when the fit setting flips |
| Side chats (fork from a chat, agent-spawned chats, `ForkSideChat`) | `shell/side_chats.rs` | `surfaces.zig` `SideChatSurface`: the child's transcript + a reply field (Run with the chat's config, optimistic echo) and its own drop zone for workspace references (`side-chat-dropzone`); "New side chat" is minted locally and written on its first send (`createChat` with `parentChatId`); fork → `ForkSideChat` | 🟡 the reply field is not the full composer (no model picker / attachments / queue); no side-chat inline rename |

## 10. Settings

| Page / feature | Rust | Zig | Status |
|---|---|---|---|
| Full-window settings mode, nav, Back/Escape, page scaffolding, selects, switches, tooltips | `settings.rs`, `settings/widgets.rs` | `ui/settings/view.zig`, `widgets.zig`, `select.zig` | ✅ |
| General: send key, compact transcript, compact model picker, Escape stops agent | `settings/shortcuts.rs` (general half) | `ui/settings/general.zig`; Escape-stops drives `wiring.onShellKey` → `ComposerView.escapeStop` (`resolve_shell_escape`); compact transcript drives `TranscriptView.setCompactMode`. The full (non-compact) model picker is not ported, so that switch still only persists | 🟡 |
| General → Thread naming (`Get/SetTitleSettings`, model picker in title-bound mode) | `settings/thread_naming.rs` | `ui/settings/thread_naming.zig`: Get on open, Set on pick / Reset; dropdown = Session agent + title-capable agents' models (`ListModels`), brand chip, error row. A flat model list rather than the composer picker's harness tabs | 🟡 |
| Appearance: scheme cards, light/dark variants, accent, glass, fonts, sizes, conversation width | `settings/appearance.rs` | `ui/settings/appearance.zig`; searchable installed-font pickers `fonts.zig` over `zpui.text.font_catalog` (CoreText / fontconfig+FreeType, measured fixed width for the terminal, fallback when a family disappears) | ✅ |
| Appearance: match wallpaper colors | `settings/wallpaper_colors.rs` | `theme/wallpaper.zig` + `ui/background/install.zig` (color extracted on install / backfilled off-thread) | ✅ |
| Appearance: new-thread background image + effects + adjustment dialog | `new_thread_background_*.rs` | `ui/background/**` (off-thread decode, cover fit, mask, crossfade, 5 effects, managed copies in `new-thread-backgrounds/`), `ui/settings/appearance.zig` (Choose/Replace/Remove/thumbnail/unavailable/error/effect), `file_prompts.zig` (NSOpenPanel / portal), `background_adjust.zig` (Adjust dialog). Pixel-compared with Rust (RMSE < 0.7%, dark/light/halftone) | ✅ |
| Appearance: moving backgrounds (zpui-only: GIF / APNG / animated WebP / video) | — (Rust shows stills only) | `ui/background/anim_decode.zig` (streamed stb GIF, APNG/WebP frame rebuild + compositing), `video.zig` (AVFoundation on macOS, GStreamer via dlopen on Linux), `player.zig` (off-thread decode + effect per frame at 1024 px, 30 fps cap, loop counts, replay cache ≤ 48 MB, reduce motion → poster, pause when inactive, idle when not visible); installs `<id>.png` poster as `path` (Rust shows it) + `<id>.<ext>` as `motionPath`; Adjust preview animates; wallpaper folder/Shuffle include them. Tests: `ui/background/motion_tests.zig`, `runtime_tests.zig` | ✅ |
| Appearance: wallpaper folder rotation (`RandomWallpaper`) | `settings/wallpaper.rs` | `ui/background/wallpaper.zig` (warm lookahead of 3), Choose folder / Shuffle, mod-u (`wiring.actRandomWallpaper`; no folder → Appearance + folder prompt) | ✅ |
| Appearance: theme library / VS Code theme import | `theme_library.rs`, `crates/theme/src/{library,vscode}.rs` | `theme/vscode.zig` (JSONC/JSON5, include chains, token files, `.tmTheme` plists, packages, hardening, reports), `theme/library.zig` (serde-compatible `theme-library.json`, backup swap, reload/unlink/duplicate-as-editable/remove), `registry.active()`, `ui/settings/theme_library.zig` (Add-a-theme dialog, Review, rows) | ✅ |
| Appearance: reduce motion (on/off/system), pause animations in background | `motion.rs` | `ui/settings/motion.zig` sets each window's reduced-motion flag from preference × OS × focus (OS re-read on refocus) | ✅ |
| Notifications page | `settings/notifications.rs` | `ui/settings/notifications.zig`; consumed by `lifecycle/notify.zig` | ✅ |
| Voice page (opt-in, model download, microphone, hold-to-dictate) | `dictation/model.rs` | `ui/settings/voice.zig` + `voice/service.zig` `VoiceModel`: switch = download (progress, cancel) / toggle, microphone select (system default, disconnected device kept, 3 s rescans while visible), shortcut, errors, Speech model + Remove | ✅ |
| Shortcuts page | `settings/shortcuts.rs` | `ui/settings/shortcuts.zig` | ✅ |
| Providers: harness rows, enable switch (`SetHarnessEnabled`), update policy, check now | `settings/harnesses.rs` | `ui/settings/providers.zig`: Install / Cancel (`InstallHarness`, `CancelInstall`, "Installing …" in place), Update / Cancel (`ApplyHarnessUpdate`, `CancelHarnessUpdate`), Check now (`CheckHarnessUpdates` reply), error strip | 🟡 device switcher commit (`targetDeviceId`) is still a no-op |
| Accounts: provider cards, account rows (plan, usage meters, reset), Switch / Forget, shared sign-in dialog (`StartAgentLogin/Poll/Complete/Cancel`) | `settings/accounts.rs` | `ui/settings/accounts.zig`, embedded in the expanded provider like Rust (`.agents` aliases Providers): rows, meters, ⋯ menu, optimistic Switch/Remove, Connect/Add per login option, sign-in dialog (browser poll, paste code, Retry) | ✅ (times shown in UTC like the rest of the Zig app) |
| Per-agent completion preferences | `settings/completion.rs` | toggles in `providers.zig` (`onCompletionToggle`); the composer's `$` skill completion reads them (`extras.zig` → `UiSettings.skillCompletion`) | ✅ |
| Devices: list, presence, copy id, rename | `settings/devices.rs` | `ui/settings/devices.zig` | ✅ |
| Files: autosave, delay, word wrap, hidden/ignored | `settings/files.rs` | `ui/settings/files.zig`; `editor/view.zig` autosave (`schedule_autosave`), `right_pane.zig` applies wrap/autosave/show-all live and writes back the editor/explorer toggles | ✅ |
| Appshots page | `settings/appshots.rs` | `ui/settings/appshots.zig`: switches, shortcut + live readiness badge, destination, capture / application-text rows with platform copy, "Allow window capture" / "Enable text capture" → "Open System Settings", "Check again" | ✅ |
| Archived sessions + Unarchive | `settings/archived.rs` | `ui/settings/archived.zig` | ✅ |

## 11. Theme, typography, motion

| Feature | Rust | Zig | Status |
|---|---|---|---|
| 30 built-in themes, seed derivation, semantic tokens, light designed separately | `crates/theme`, `theme.rs` | `theme/**` (bit-exact parity) | ✅ |
| Typography: bundled fonts, UI/terminal/code families + sizes, rem size | `typography.rs` | `theme/typography.zig`, `ui/settings/store.zig` | ✅ |
| Motion catalog (fade-in, menu-in, dialog-in, hover blend, stagger), `ZERON_MOTION_SCALE` | `motion.rs` | `theme/motion.zig` (`MotionSpec.animation()`, `speed_scale` from `main.zig`, `Tween`), `ui/components/anim.zig`, `hover.zig`. Every Rust animation with its Zig location and status: docs/ANIMATIONS.md | 🟡 popover exit, history fold rows, tool arrival choreography, compact picker motion, transcript spring (docs/ANIMATIONS.md "Known gaps") |
| Frost / glass / edge-fade surfaces | `frost.rs`, `glass.rs`, `edge_fade.rs` | `src/elements/effects.zig`, `ui/components/effects.zig`, `ui/composer/chrome.zig` | ✅ |
| Live theme switching from settings and OS | `appearance.rs` | `ui/settings/store.zig` `applyTheme` | ✅ (menu Appearance actions missing, §1) |

## 12. Voice, appshots, sounds, notifications, haptics

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Voice dictation (Parakeet v3 on-device, resampling, level meter, waveform) | `crates/voice`, `dictation/**` | `apps/zeron/src/voice/`: pinned manifest + verified download, rubato FftFixedInOut resampler and parakeet-rs log-mel/TDT greedy decode/detokenizer ports, ONNX Runtime C API via dlopen (optional; absent → "Dictation unavailable"), session worker (BusyGuard, 30 s model cache, capture thread), PulseAudio/PipeWire (dlopen) and macOS AudioQueue capture + AVCaptureDevice permission. `zig build voice-test`: resampler/feature parity vs Rust fixtures (`scripts/voice_parity.rs`), E2E transcript of `fixtures/voice/speech.wav` identical to Rust with `ZERON_VOICE_MODEL`/`ZERON_ONNXRUNTIME`. Unverified: real microphones (macOS AudioQueue/permission, Pulse capture) | ✅ |
| Appshots (capture the frontmost app window + AX/AT-SPI context; macOS native, Linux portal/X11) | `appshots/**` | Platform (zpui): `src/platform/platform.zig` (`GlobalHotkey`, `captureActiveWindow`, capabilities), `capture_common.zig`; macOS `mac/window_capture.zig` (Carbon hotkey, CGWindowList + ScreenCaptureKit / CGWindowListCreateImage, Screen Recording + AX permission, AXUIElement text); Linux `linux/window_capture.zig` + `portal_capture.zig` (Screenshot + GlobalShortcuts portals over `dbus.zig`), `x11_capture.zig` (key grab, GetImage, `_NET_WM_ICON`, desktop entries), `atspi_client.zig` (AT-SPI text). Zeron: `model/appshots.zig` (+ `appshot_png.zig` padding trim) — staging, `with_appshots`, `presentations`, `strip_context_for_display`, `restore_queued_appshots`; composer staging/strip/send (`ui/composer/composer.zig` [appshots]); shell routing `ui/shell/appshots.zig`; transcript strips the context. Gaps: transcript/queue Appshot presentation tiles (app name/icon overlay), queue-edit Appshot restore wiring (`restoreQueued` exists, extras.zig not wired), macOS app icons for remote presentations | 🟡 |
| Session sounds (completion / input / attention / appshot chimes via afplay / paplay…) | `sound.rs`, `assets/sounds` | `lifecycle/notify.zig` (same detector, settings, 250 ms attention gate, `ZERON_DISABLE_SOUND`); assets in `apps/zeron/assets/sounds`; `App.playSound` = NSSound (macOS) / paplay → pw-play → aplay → ffplay → mpv (Linux). Appshot cue: `zeron_sounds.appshot` on capture (`pixels_ready`) | ✅ |
| Desktop banners on status transitions (NSUserNotification / notify-send), background-only, agent-update banners, click routing | `notify.rs`, `shell::on_state_changed` | `lifecycle/notify.zig` + `App.postNotification`: NSUserNotification (+ installed-bundle identity, osascript fallback) / `org.freedesktop.Notifications` over dbus.zig with click reporting (notify-send fallback) | ✅ |
| Haptics on control detents (macOS) | `haptics.rs` | — | ❌ |

## 13. Accessibility

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Roles, labels, placeholders on inputs, buttons, menus, lists (321 call sites in 35 files: `.role()`, `.aria_label()`), backed by zui's AccessKit integration (`gpui/src/window/a11y.rs`, accesskit_macos / accesskit_unix) | throughout | Tree: `src/a11y.zig` (built in prepaint from `div().id(..).role(..).aria*(..)`, text content names buttons / fills inputs / becomes static text, cached views copy their subtree, per-frame diff; `ariaUrl`, `ariaTextSelection`; `Tree.unroled` audits interactive elements without a role), `Window.a11y*`, `onA11yAction`; macOS NSAccessibility bridge `src/platform/mac/a11y.zig` (incl. text-range attributes: selected text/range(s), number of characters, line/range/string/frame for range, insertion line, AXURL, AXSelectedTextChanged); Linux AT-SPI2 bridge `src/platform/linux/atspi.zig` (Accessible, Application, Component, Action, Text with caret/selection (SetCaretOffset/SetSelection, TextCaretMoved/TextSelectionChanged), EditableText, Value, Selection, Table, Hyperlink, Image, Collection, Cache, Window Activate/Deactivate events). Adopted across the zeron UI with Rust's roles/labels/states: sidebar (rows, groups, menus, account/settings/spaces/view triggers), composer (send/stop/attach, attachment chips, queue tray, todo panel, ask-user wizard, slash/@ results), transcript (links with URL, tool groups/chips, copy/expand, rail, jump), changes/history panes, file tree/search/sections/editor find bar, browser pane, pickers (model list-box options, reasoning slider, footer chips, add-project crumbs), command palette, right-pane tabs/cards/+ menu, harness-update island, every Settings page (switches, selects as menu-item-radio, fonts, accents, shortcuts, devices, accounts, providers/completion, theme library, background-adjust slider) and dialogs. `ui/settings/a11y_tests.zig` walks the full shell (sidebar menus, pickers, right pane surfaces, files, palette, new-session, every settings section, theme import) and asserts every interactive element has a role and a name. Gaps: link context menu (not ported), Appshot/dictation chips (their own areas) | ✅ |
| Keyboard reachability (tab stops, roving focus, Escape dismissal) | throughout | widely ported (`tabIndex`, `focusable`, key contexts) | 🟡 |

## 14. Engine RPC coverage

Generated `engine/methods.zig` lists 109 methods. Referenced by the Zig UI/model (60):
`ListHarnesses SetHarnessEnabled ListModels QueueCommand WatchDocMessages FocusChat WatchQueue
QueueMessage UpdateQueuedMessage MoveQueuedMessage RemoveQueuedMessage SendQueuedMessageNow
SteerQueuedMessageNow ProbeSync SyncStatus WatchConnectivity WatchTransfers WatchChats
WatchSidebarPreferences WatchDevices WatchSessions WatchSpaces Mutate LocalDevice EngineInfo
EngineReady StopEngine AuthStatus SignIn SignInHeadless CompleteSignIn SignOut ListOrgs CreateOrg
SelectOrg ListBranches ListRefs ListGitHistory SearchGitHistory FetchAll SwitchRef ListFolders
ListDrives ListWorkspaceDirectory SearchWorkspaceFiles ReadWorkspaceFile MoveWorkspaceEntry
DeleteWorkspaceEntry WriteWorkspaceFile WatchWorkspaceFiles WatchCheckoutDiffs
WatchWorkspaceGitStatus GetCheckoutDiff DiscardWorkingTree GetCheckoutFileDiffText UpdateStatus
ApplyUpdate WatchHarnessUpdates CheckHarnessUpdates SetHarnessUpdatePolicy`.

Never called (49; each one is a missing feature): `WatchPreviews InstallHarness CancelInstall
GetTitleSettings SetTitleSettings ListSkills ListCommands TakeProjectActionSetup RelayCommand
RetryDelivery ForkSideChat BeginQueuedMessageEdit RenewQueuedMessageEdit FinishQueuedMessageEdit
LocalImportStatus ImportLocalWorkspace ListRepos AddRepo CloneRepo CreateRepo ResolveGitAvatars
SearchFiles ReadWorkspaceImage CreateWorktree DeleteWorktree ListProjectActions
UpsertProjectAction DeleteProjectAction RunProjectAction OpenTerminal SubscribeTerminal
WriteTerminal ResizeTerminal CloseTerminal WatchCheckoutChangeRequest ListAgentAccounts
ActivateAgentAccount ForgetAgentAccount StartAgentLogin CompleteAgentLogin PollAgentLogin
CancelAgentLogin UploadChunk UploadCommit ReadAttachmentChunk FetchToolBlob ApplyHarnessUpdate
CancelHarnessUpdate DismissHarnessUpdate`. (`CreateOrg`/`SelectOrg` are in the model but the
org-gate buttons don't call them; `CompleteSignIn` has no UI.)

Since wired (shell/composer/transcript wiring pass): `ListSkills ListCommands RetryDelivery ForkSideChat
BeginQueuedMessageEdit RenewQueuedMessageEdit FinishQueuedMessageEdit SearchFiles FetchToolBlob`, plus
`CreateOrg`/`SelectOrg`/`ListOrgs` from the org gate and `MoveQueuedMessage` from the queue tray.
Since wired (Home agent-update island + Settings → Agents): `ApplyHarnessUpdate CancelHarnessUpdate`
(with `targetDeviceId` from the island), `InstallHarness CancelInstall`; `DismissHarnessUpdate` is
unused in Rust's UI too.

## 15. Settings that persist but have no runtime effect

Now consumed (settings pass): `escapeStopsActiveAgent`, `reduceMotion`, `pauseAnimationsInBackground`,
`openWebLinksInZeron` (web links open in the session Browser), `filesAutosaveEnabled`,
`filesAutosaveDelayMs`, `filesWordWrap`, `filesShowAll`, `newThreadComposerBackground`,
`newThreadBackgroundEffect`, `wallpaperFolder`, `wallpaperSource`, `wallpaperHistory`, the font
families (installed fonts, with fallback), `transcriptCompactMode`. Still without a runtime consumer (their features are not
ported): `compactModelPicker` (no full picker),
`skillsInSlashMenu` / `skillCompletionByHarness` in the composer, `appshots*`, `dictation*`,
`sidebarGrouped`, `sidebarSectionsByProfile`, `githubStarBannerDismissed`, `lastSpaceId`,
`lastProjectActionBySpaceId`, `terminalHeight`, `terminalOpen`, `gitHistoryColumnOrder`.

## 16. zpui framework gaps (gpui features zeron uses)

| gpui feature | used by zeron for | zpui today | Status |
|---|---|---|---|
| `cx.set_menus` / `MenuItem` / `OsAction` / key-equivalent display | app menu bar | `App.setMenus` (src/app/lifecycle.zig), `Platform.setMenus` (src/platform/mac/menu.zig) | ✅ |
| `on_open_urls`, `register_url_scheme`, `on_reopen` | deep links, dock reopen | `App` registers `PlatformCallbacks` (open_urls, reopen, quit, should_quit, system_wake, keyboard layout, menu, notification) and exposes listeners | ✅ |
| `on_app_quit` (async teardown) | flush, install-on-quit, engine drain | `App.onQuit` (sync) + `App.onQuitAsync` → `QuitTeardown` task; the exit waits up to `shutdown_timeout_ns` (gpui `SHUTDOWN_TIMEOUT`, 200 ms) for the tasks' background phase (TestPlatform: runs them deterministically) | ✅ |
| `on_window_should_close` veto | unsaved files | `Window.onShouldClose` (every listener must agree); macOS `windowShouldClose:`, Linux CSD/WM close, `TestWindow.simulateCloseButton` | ✅ |
| `observe_window_bounds`, `window_bounds()`, `displays()` with `uuid()`, `display_id` in options | window geometry restore | `displays` exists; `moved` callback not surfaced; no display uuid | 🟡 |
| `prompt_for_paths` | attach, wallpaper folder, background image, theme import | `Platform.promptForPaths`: NSOpenPanel (`mac/file_dialog.zig`), XDG portal (`linux/file_dialog.zig`) | ✅ |
| `window.prompt` (modal alert) | rare confirmations | — (zeron mostly draws its own dialogs) | ❌ |
| External file drag-and-drop (`ExternalPaths`, `on_drop`, `drag_over`) | attachments, chat drop zone | `src/window/external_paths.zig`: platform `FileDropEvent`s become an `ExternalPaths` drag (entered → drag + move, pending → move, submit → drop, exited → cancel), so `onDrop`/`dragOver`/`canDrop` work as for internal drags. macOS NSDraggingDestination (`NSFilenamesPboardType`), Wayland `wl_data_device` `text/uri-list`, X11 XDND; `TestWindow.simulateInput(.file_drop)` | ✅ |
| Internal drag-and-drop (`on_drag`, `on_drop`, drag ghosts) | tabs, pins, queue | `div.onDrag/onDrop/onDragMove` | ✅ |
| Clipboard images (`ClipboardEntry::Image`) | paste screenshots | `readClipboardImage` vtable slot being added | 🟡 |
| System notifications (zui `gpui_macos/system_notifications.rs`, `gpui_linux/system_notifications.rs`) | banners | `Platform.postNotification` (src/platform/mac/notify.zig, src/platform/linux/notifications.zig) | ✅ |
| Accessibility (`role`, `aria_*`, AccessKit) | everything | `src/a11y.zig` + NSAccessibility / AT-SPI2 bridges (see §13) | ✅ |
| `container_query` | History responsive columns | `src/elements/container_query.zig` (`zpui.containerQuery`), used by `ui/history/pane.zig` (count/comparison, commit column ref area, graph geometry from the area's own width) | ✅ (compactness flips morph width + lane spacing over COLLAPSE: `graph.interpolate`, `HistoryPane.updateGeometry`) |
| Gestures (pinch / magnify) | image viewer | — | ❌ |
| `PathBuilder` stroke / tessellation | history lanes | `paintPath` exists (`src/window/paint.zig`) | 🟡 |
| Surfaces / native child views | browser (WKWebView), video | `src/elements/native_view.zig` in progress | 🟡 |
| `list` / `uniform_list` virtualization, `ListState` alignment, scroll handles | transcript, explorer, editor | `src/elements/list.zig`, `uniform_list.zig` | ✅ |
| Animation (`with_animation`), deferred, anchored, canvas, img, svg | everywhere | `src/elements/*` | ✅ |
| Frost / backdrop blur, edge fade (zui fork primitives) | glass UI | `src/elements/effects.zig`, both renderers | ✅ |
| Text: shaping, wrapping, `StyledText`, font features | everywhere | `src/text/**`, `src/style.zig` | ✅ |
| IME (`EntityInputHandler`) | composer, editor | `src/window/input_handler.zig` (macOS + Wayland text-input-v3 + X11 XIM) | ✅ |
| Keymap, key contexts, actions, focus / tab stops | everywhere | `src/app/**`, `src/window/focus.zig` | ✅ |
| Window controls: start move/resize, minimize, zoom, fullscreen, CSD insets | titlebar | `src/platform/platform.zig` window vtable | ✅ |
| App hide / hide others / unhide as API | menu actions | `App.hide` / `hideOtherApps` / `unhideOtherApps` (`Platform.appCommand`) | ✅ |
| Keyboard-layout-change callback | shortcut display | platform callback slot unused | 🟡 |
| Grid layout (taffy) | not used by zeron | — | ➖ |
| Inspector / profiler / visual tests | dev only | — | ➖ |

---

## Remaining work, prioritized

Sizes: **S** ≤ 1 day · **M** 2–4 days · **L** 1–2 weeks · **XL** > 2 weeks.

1. ~~**Install the editor keymap in the app**~~ (done: `keymap.zig` `component_bindings`, `ui/shell/wiring.zig`) (call `ui/editor/actions.zig` `bindDefaults` from
   `keymap.zig` `applyKeymap`, like Rust reinstalls gpui-base's keymap) and handle
   `shell::SaveFile`. Without it the file editor can't move the caret or save. — S
2. ~~**Subscribe to `ComposerEvent` in the shell**~~ (done in `ui/shell/wiring.zig`; dictation stays a no-op hook, the paperclip is the composer's own picker): workspace slash commands, paperclip →
   `promptForPaths` (+ macOS NSOpenPanel in zpui), dictation toggle; wire explorer `AddToChat`,
   transcript link handler (`rich_text.registry.handler` → open in the right pane),
   "click to retry" (`RetryDelivery`). — S/M
3. ✅ (done, `apps/zeron/src/lifecycle`) **App lifecycle in zpui + app**: `App` registers `PlatformCallbacks` (open_urls, reopen,
   quit); `on_app_quit` hook; should-close veto; keep the process alive on macOS ⌘W and reopen
   from the dock; `zeron://open/chat/…` routing + positional URL argument (port `links.rs`). — M
4. ✅ (done, `apps/zeron/src/lifecycle`) **Menu bar**: a `setMenus` API in zpui (MenuItem / separators / OS submenus / key
   equivalents from the keymap) and handlers for every `zeron::*` action (About, Check for
   Updates, Settings, Edit verbs, Appearance, Minimize, Zoom, Close Window). — M
5. ✅ (done, `apps/zeron/src/lifecycle`) **Persist shell state**: sidebar/right-pane/files/terminal sizes and open flags, sidebar view
   menu choices, window geometry per display (needs bounds observer + display uuid in zpui). — M
6. **Chat & space management** (done except custom sidebar sections and the post-sign-in switch wizard; see §3/§4): rename (dialog + title bar), Copy ▸ link/path, Delete with
   confirm, `ArchiveSession`/`OpenModelPicker` handlers, space rename/delete, custom sidebar
   sections, org-gate create/select, login paste-code dialog. — M
7. **Attachments end to end**: external drops in zpui (mac payload, Wayland/X11 DnD), clipboard
   image paste, chunked upload, transcript read-back from the host, image viewer / lightbox
   (+ pinch gestures), chat drop zone. — L
8. **Composer completions** (done except mention chip projection; see §6): `@` file mentions (`SearchFiles`) with chips, provider slash
   commands and skills (`ListCommands`, `ListSkills`) honoring completion prefs. — M/L
9. **Run-time surfaces around the composer** (done except account-usage ring; see §6/§7): question wizard, todo panel, account-usage ring,
   queue drag-reorder + edit lease, jump-to-bottom, "Show full output" (`FetchToolBlob`),
   "Worked for". — M
10. ~~**Subagent and side-chat tabs**~~ (done; the side chat has a reply field, not a full composer): `Subagent` / `SideChat` right-pane kinds hosting
    `TranscriptView.initWithStore`, spawn-chip click, explorer sections, `ForkSideChat`. — M
11. **Settings → Accounts + provider actions**: agent accounts (list / switch / forget / login
    dialog), harness install / update / cancel RPCs, thread-naming RPCs, device switcher, and
    make every persisted setting in §15 take effect (compact transcript, Escape stops agent,
    reduce-motion override, files defaults, …). — L
12. ✅ (done, `apps/zeron/src/lifecycle`) **Notifications and sounds**: banners (UNUserNotification/NSUserNotification on macOS,
    `org.freedesktop.Notifications` or notify-send on Linux), click routing, chimes (copy
    `assets/sounds`), background-only gating. — M
13. **Engine-backed terminal**: `OpenTerminal`/`SubscribeTerminal`/`WriteTerminal`/`ResizeTerminal`
    so remote-device sessions work; keep PTYs across navigation; tab drag / middle-click. — M
14. 🟡 (done except signing / notarization and hosting a feed for Zig builds) **App self-update + release plumbing**: port `crates/update` checker/installer, install on
    quit, update strip and menu actions; signing / notarization; logs to a rotating file with
    a panic handler. — L
15. **Browser pane**: finish `native_view.zig` (WKWebView child on macOS), WebKitGTK offscreen
    helper on Linux, tabs/address bar/navigation, `browser::*` actions. — XL
16. **Review comments + PR status**: diff/editor comment cards folded into the prompt, message
    badges, `WatchCheckoutChangeRequest` for the sidebar badge and Changes header. — M/L
17. ✅ (done) **Mermaid rendering** (port or embed a renderer; lazy background cache; preview). — L
18. **Files extras** (done except drag-move in the tree; see §9): markdown preview, image preview (`ReadWorkspaceImage`), drag-move in the
    tree, rename/delete propagation to open editors. — M
19. **Project actions** (titlebar Run/Setup menu and editor). — M
20. **Voice dictation** (audio capture + Parakeet inference, waveform UI). — XL
21. **Appshots** (window capture + AX/AT-SPI context, global shortcut). — L
22. **Accessibility tree in zpui** (NSAccessibility / AT-SPI bridge; adopt roles/labels in the
    app). — XL
23. **Appearance extras**: theme library + VS Code import, wallpaper folder rotation, new-thread
    background + effects. — L
24. **Polish** (streaming veil and link destination disclosure done): composer dock choreography,
    GitHub star banner, sync overlay / local import, moving-row
    animation, haptics, repo avatars, repo clone/create. — L total
