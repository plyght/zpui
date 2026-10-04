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

Scorecard (table rows below): ✅ 72 · 🟡 45 · ❌ 76 · ➖ 5.

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
| Engine connect-or-embed | `state.rs` `EngineHandle::bootstrap` (probe port, else embed in-process) | `model/engine_state.zig`, `engine_bin.zig` (probe, else spawn `zeron headless`) | ✅ different by design: the Zig client never embeds the engine, it spawns the engine binary |
| Main window: 1320×880, min 900×600, transparent titlebar, traffic lights 14,14, blur (mac), CSD (Linux), app id | `lib.rs` `open_main_window` | `main.zig` | ✅ |
| Restore / save window geometry per display (`window_geometry`, display uuid, debounced) | `lib.rs` `restored_main_window_bounds`, `save_window_geometry` | — (`windowGeometry` is parsed in `model/settings.zig`, never read or written) | ❌ needs zpui bounds observer + display uuid |
| Close veto (unsaved files) + flush settings on close | `lib.rs` `on_window_should_close` → `Shell::prepare_window_close` | — (`src/window/window.zig` `cbShouldClose` always returns true) | ❌ |
| Graceful quit: flush settings, install pending update, drain engine | `lib.rs` `on_app_quit` | — (no quit hook API in zpui `App`) | ❌ |
| macOS: ⌘W keeps the process alive; dock click reopens the main window | `lib.rs` `ReopenState`, `app.on_reopen` | `main.zig` sets `quit_when_last_window_closes = true`; zpui never registers `PlatformCallbacks.reopen` | ❌ |
| macOS app menu bar (Zeron: About, Check for Updates…, Settings, Services, Hide/Hide Others/Show All, Quit; Edit; View: Appearance System/Light/Dark; Window: Minimize/Zoom/Close) with key equivalents from the keymap | `app_menus.rs` `app_menus()`, `cx.set_menus` | zpui builds a fixed menu with Hide / Hide Others / Show All / Quit only (`src/platform/mac/mac.zig` `buildMainMenu`); no Edit/View/Window menus, no About, no Settings, no Check for Updates | 🟡 |
| `zeron::*` menu actions (About, CheckForUpdates, Quit, Hide, HideOthers, ShowAll, Minimize, Zoom, CloseWindow, Appearance*) | `app_menus.rs` handlers | registered in `actions.zig`, bound in `keymap.zig` (`cmd-q/h/alt-cmd-h/m/w`), **no handlers anywhere**; ⌘Q/⌘H still work through zpui's native menu, ⌘M/⌘W do nothing | ❌ |
| Dock menu | none in Rust | none | ➖ |
| URL scheme `zeron://open/chat/<id>?workspace=…` (Info.plist / `.desktop` `x-scheme-handler/zeron`) | `lib.rs` `register_url_scheme`, `on_open_urls` → `AppState::open_deep_link`; `links.rs` parse/format | `dist/` declares the scheme, but zpui's App never registers `PlatformCallbacks.open_urls` (the mac delegate implements `application:openURLs:`), no `links.rs` port, no routing | ❌ |
| Cold-launch URL argument (`zeron <url>`, `Exec=zeron %u`) | `apps/zeron/src/main.rs` `Cli.open_url` → `UiConfig.initial_url` | `main.zig` ignores positional args | ❌ |
| Single-instance behavior | none (each launch is a new process; engines are shared through the IPC port; only the log file is `flock`ed) | none | ➖ (same as Rust) |
| Notification banner click → focus chat / Settings → Providers | `lib.rs` `open_notification_target`, `notify::on_click` | — | ❌ (no notifications at all, §12) |
| Appshot global-shortcut service | `lib.rs` `start_appshot_service`, `appshots/**` | — | ❌ (§12) |
| Log file `{data_dir}/logs/zeron-headed.log` with rotation + panic hook into it | `apps/zeron/src/main.rs` `open_log_file`, `panic::set_hook` | stderr only | ❌ |
| Crash reporting / telemetry | none in the desktop client (telemetry only in `apps/landing`) | none | ➖ |
| App self-update: release checker, download, install-on-quit, "Check for Updates…", sidebar update strip | `app_update.rs`, `crates/update` | `model/status.zig` `UpdateStore` shows the **engine's** `UpdateStatus`; `ui/sidebar/sidebar.zig` `renderUpdateStrip` is display-only (no click); user-menu "Check for updates" has no handler; `ApplyUpdate` is wired in the model but not reachable from UI | 🟡 |
| Packaging: macOS .app (universal), Linux tarball | release workflow | `zig build zeron-app-bundle`, `zig build zeron-dist` | ✅ |
| Signing / notarization, Linux installer, auto-update channel | release workflow, `crates/update` | — | ❌ |
| System light/dark follow | `appearance.rs` `observe_window` | `src/platform/linux/appearance.zig` (portal + gsettings), `src/platform/mac` appearance callback | ✅ |

## 2. Keyboard shortcuts (`actions!` groups)

Bindings are ported 1:1 (`keymap.zig` `defaultBindings`, tested on both platforms); the gaps are
handlers. Customizable combos come from `KeymapConfig` (`mod` = cmd on macOS, ctrl elsewhere).

| Action | Default binding | Handler in Zig | Status |
|---|---|---|---|
| `composer::*` (39 editing actions: motions, selection, word/line delete, copy/cut/paste, undo/redo, Newline, Submit, ModifiedSubmit, MessageNewlineOrAccept, MentionTab, OutdentList) | arrows, home/end, cmd/alt/ctrl variants, `enter` / `mod-enter` per send setting | `ui/input/text_input.zig` (all listed) | ✅ |
| `composer::ToggleDictation` | `mod-d` | `ui/input/text_input.zig` emits; composer flips the mic visual only | 🟡 (no capture) |
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
| `shell::ArchiveSession` | `mod-shift-a` | — | ❌ |
| `shell::OpenModelPicker` | `mod-/` | — | ❌ |
| `shell::SaveFile` | `mod-s` | — (the editor's own `file_editor::Save` exists, see next row) | ❌ |
| `shell::RandomWallpaper` | `mod-u` | — | ❌ |
| File editor bindings (gpui-base input keymap: motions, selection, delete, indent, find/replace, go-to-line, save) | reinstalled by `shell::apply_keymap` after clearing | `ui/editor/actions.zig` `bindDefaults` exists but is only called from tests and `files_demo.zig`; `keymap.zig` `applyKeymap` clears the keymap and never installs it → **in the app the editor accepts typed text (IME path) but arrows, backspace, ⌘S, find do nothing** | ❌ (bug, small fix) |
| `browser::Reload/FocusAddress/NewTab/CloseTab/Back/Forward` | `mod-shift-r`, `mod-l/t/w/[/]` (Browser context) | — | ❌ (no browser) |
| `zeron::*` (menu verbs) | `cmd-q/h/alt-cmd-h/m/w`, `mod-,` | see §1 | ❌ |
| Appshot capture (global) | `ctrl-alt-space` / `mod-alt-space` | — | ❌ |
| Settings → Shortcuts: record, conflict detection, reset, restore defaults, live rebind | `settings/shortcuts.rs` | `ui/settings/shortcuts.zig`, `ui/settings/store.zig` `applyKeymap` | ✅ |
| Escape stops the active agent (setting) | `composer.rs` | setting stored (`escapeStopsActiveAgent`), no consumer | ❌ |

## 3. Shell, titlebar, gates

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Glass window frame, sidebar \| main \| right pane, drag-resize with width tweens | `shell.rs` | `ui/shell/shell.zig` | ✅ |
| Unified 38px titlebar: control cluster, session identity (harness mark + title), `+` new session, right tab strip in the band | `shell.rs` `render_titlebar_cluster`, `render_session_title_bar`, `shell/tabs.rs` | `ui/shell/titlebar.zig` | ✅ |
| Linux CSD caption buttons + resize borders | `render_linux_caption_controls`, `render_linux_resize_borders` | `ui/shell/titlebar.zig` | ✅ |
| Boot splash (matrix spinner) | `loaders.rs` | `ui/components/loaders.zig`, `ui/shell/shell.zig` | ✅ |
| Engine failure gate + Retry | `render_gate_card` | `ui/shell/gates.zig` | ✅ |
| Sign-in gate (browser login) | `render_gate_card` | `ui/shell/gates.zig` `signInGate` → `AuthStore.signIn` | ✅ |
| Login dialog (paste-code fallback, "Open browser again") | `render_login_dialog` | — (`AuthStore.completeSignIn` exists in `model/status.zig`, no UI) | ❌ |
| Org gate: create workspace / pick org / sign out | `render_org_gate` | `ui/shell/gates.zig` `orgGate`: renders, but only "sign out" has a listener (create-org and org rows are inert) | 🟡 |
| Signed-out restart prompt, sync overlay, local-workspace import (`ImportLocalWorkspace`) | `render_signed_out_restart`, `render_sync_overlay`, `render_import_dialog` | — | ❌ |
| Persist pane layout (sidebar width/collapsed, right pane width/open, files panel width, terminal height/open) | `settings.rs` debounced saves | read at boot (`ui/shell/prefs.zig` `applySettings`), **never written back**; `rightPaneOpen`, `terminalHeight`, `terminalOpen` not read either | 🟡 |
| Harness-updates island on Home | `shell/harness_updates.rs` | — (data in `model/status.zig` `HarnessUpdates`) | ❌ |
| GitHub star banner | `render_github_star_banner` | — | ❌ |
| Project actions (titlebar Run/Setup menu, edit/delete/import, `RunProjectAction`) | `project_actions.rs`, `shell/actions_ui.rs` | — | ❌ |
| Chat drop zone (drop files onto the conversation) | `shell/chat_dropzone.rs` | — | ❌ (also blocked on zpui external drops) |
| Navigation focus recovery | `shell/navigation_focus.rs` | `ui/shell/shell.zig` (focus on open/close of overlays) | 🟡 |
| Connection / status strip | `render_status_strip`, `render_connection_pill` | `ui/shell/main_panel.zig` reserves the strip height; no pill | 🟡 |

## 4. Sidebar

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Space filter dropdown ("All projects", search) | `shell/spaces.rs` | `ui/sidebar/sidebar.zig` | ✅ |
| Pinned / Sessions / Archived disclosures, detailed + compact rows, status glyphs, harness/branch/project labels | `shell.rs` `render_chat_row`, `spaces.rs` | `ui/sidebar/sidebar.zig` | ✅ |
| Pin drag-reorder (optimistic overlay, `changeSidebarPin move`) | `shell/sidebar_pins.rs` | `ui/sidebar/sidebar.zig` `PinDrag` | ✅ |
| View menu (organize by device/project/none, sort, show branch/PR/harness/icon/location) | `render_sidebar_view_menu` | `ui/sidebar/sidebar.zig` — works, but choices are not persisted (`sidebarGrouped/Organization/Sort` have no consumer) | 🟡 |
| Custom sidebar sections (account-synced: create, edit, archive all, delete, move chats) | `shell/sidebar_sections.rs` | — | ❌ |
| Chat context menu: Rename, Pin/Unpin, Archive, Copy ▸ (link / path / zeron link), Delete… (confirm) | `shell.rs` ~9630–9910 | `ui/sidebar/sidebar.zig` `renderCtxMenu`: Pin and Archive work; Rename, Copy, Delete are `onCtxNoop` | 🟡 |
| Rename session dialog | `render_rename_dialog` | — | ❌ |
| Space management (rename / delete / reorder via row menus) | `shell/spaces.rs` | — | ❌ |
| Project artwork (repo avatars via `ResolveGitAvatars`, local icon detection) | `shell/project_icon.rs` | `ui/sidebar/project_icon.zig` (local files only; RPC fetch not ported) | 🟡 |
| PR badge (`#413`) | `render_pull_request_badge`, `change_requests.rs` | `ui/components/badge.zig` renders it, data only from fixtures (`ui/shell/prefs.zig` `pull_requests`) | 🟡 |
| Footer: account pill + user menu (Enable sync, sync progress/restart, Sign out, Check for updates) | `render_user_menu`, `render_sidebar_footer` | `ui/sidebar/sidebar.zig` `renderFooter`: Sign out works; Enable sync and Check for updates have no handler | 🟡 |
| Update strip | `render_update_strip` | display-only | 🟡 |
| Moving-session animation when a row changes section | `render_moving_sidebar_session` | — | ❌ |

## 5. Command palette and pickers

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Command palette (mod-k): actions, chat search, key hints | `shell/command_palette.rs` | `ui/shell/palette.zig` | ✅ |
| Add-space palette (devices → drives → folders, typed paths, ⌘⏎) | `shell/spaces.rs` `AddSpaceFlow` | `ui/pickers/add_project.zig` | ✅ |
| New-session target pickers: project, device, checkout (local / new worktree / reuse worktree), ref (`ListRefs`, `SwitchRef`) | `pickers.rs` | `ui/pickers/pickers.zig`, `paths.zig`, `menu.zig` | ✅ |
| Repo picker clone / create (`ListRepos`, `CloneRepo`, `CreateRepo`, `AddRepo`) | `pickers.rs` | — | ❌ |
| Worktree delete (`DeleteWorktree`) | `pickers.rs` | — | ❌ |
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
| "Not delivered — click to retry" (`RetryDelivery`) | `transcript.rs` `retry_send` | text shown in `ui/transcript/view.zig` `renderTrailer`, not clickable; `RetryDelivery` unused | 🟡 |
| Per-chat drafts | `composer.rs` | `ComposerView.drafts` | ✅ |
| Sticky composer defaults (`composer-defaults.json`) | `settings/composer.rs` | `model/composer_defaults.zig` | ✅ |
| Queue tray: rows, remove, edit, send-now / steer | `queue.rs` | `ui/composer/composer.zig` `renderQueue`, `model/queue_store.zig` | 🟡 no drag reorder (handle is drawn, `MoveQueuedMessage` unused from UI), edit without the host lease (`Begin/Renew/FinishQueuedMessageEdit` unused), attachment rows' interrupt offer |
| Todo panel above the composer | `todo_panel.rs` | — | ❌ |
| Context-usage ring | `context_usage.rs` | `ComposerView.renderFooter` | ✅ |
| Plan-usage ring + account switcher (`ListAgentAccounts`, `ActivateAgentAccount`) | `account_usage.rs` | — | ❌ |
| Session footer: checkout + branch / new-session checkout + ref chips | `pickers.rs` `render_footer` | `ComposerView.renderFooter`, `ui/pickers/pickers.zig` `PickerRow` | ✅ |
| Slash popup: built-in workspace commands (`/settings`, …) | `composer.rs` `WorkspaceCommand::catalog` | `ui/composer/slash.zig` + popup: the command is emitted as `ComposerEvent.workspace_command`, **but nothing subscribes to `ComposerEvent`** | 🟡 |
| Provider slash commands + skills (`ListCommands`, `ListSkills`), per-agent completion prefs | `composer.rs`, `settings/completion.rs` | — | ❌ |
| `@` file mentions: popup (`SearchFiles`), mention chips, projection into the prompt | `composer.rs`, `crates/proto/src/file_mentions.rs` | token detection only (`slash.zig`) | ❌ |
| Attachments: paste images, drop files, paperclip picker, staged chips, chunked upload (`UploadChunk/UploadCommit`), attachment-ref transport | `attachments.rs` | chips + `addPaths` exist; paperclip emits `attach_requested` (no subscriber); no paste-image, no drop, no upload | 🟡 |
| Question wizard (pending input replaces the composer) | `composer.rs` wizard reducer | — (`input_chip` in the transcript only) | ❌ |
| Markdown-aware editing (list continuation/indent, faces) | `composer_markdown.rs` | `OutdentList` action only | 🟡 |
| Dictation (mic button, waveform, glass, Parakeet transcription) | `dictation.rs`, `dictation/**`, `crates/voice` | mic visual toggles; event has no subscriber | ❌ |
| Dock choreography (canvas ↔ thread position, panel hand-off fade) | `composer_dock.rs`, `composer_dock/**` | — | ❌ |
| Message badges (fold staged context into the prompt, pill in the transcript) | `badges.rs` | — | ❌ |

## 7. Transcript

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Virtualized block-granular rows, stick-to-bottom, minimal splices on stream | `transcript.rs` | `ui/transcript/view.zig`, `rows.zig` | ✅ |
| Tool-group accordion, chips, detail folds with tweens, inline diffs | `transcript.rs` | `ui/transcript/tools.zig`, `diff_view.zig` | ✅ |
| Reasoning ("Thought process") | `transcript.rs` | `ui/transcript/thought.zig` | ✅ |
| User bubble collapse/expand, copy message | `transcript.rs` | `ui/transcript/view.zig` | ✅ |
| Error chip, fork marker, input (question) chip, working trailer with flavour words | `transcript.rs`, `notice.rs` | `ui/transcript/view.zig` | ✅ |
| "Worked for …" summary | `transcript.rs` | — | ❌ |
| Message rail (minimap ticks, hover preview, click to scroll) | `rail.rs` | `ui/transcript/view.zig` | ✅ |
| Jump / "Scroll to bottom" button | `render_jump_to_bottom` | — | ❌ |
| Text selection across rows + copy | `markdown/selection.rs` | `ui/markdown/rich_text.zig` registry | ✅ |
| Streaming fade veil | `markdown/veil.rs` | — | ❌ |
| User attachments in bubbles (read-back via `ReadAttachmentChunk`), preview lightbox | `attachments.rs`, `image_viewer.rs` | thumbnails from local paths only (`attachmentThumb`); no fetch from the host device; no lightbox | 🟡 |
| Generated images + "Preview generated image" | `render_generated_image` | rendered from local path; no preview | 🟡 |
| "Show full output" / full diff (`FetchToolBlob`) | `transcript.rs` | label rendered (`ui/transcript/tools.zig`), fetch not implemented | 🟡 |
| Subagent spawn chips → open subagent transcript tab | `transcript.rs` "Open subagent", `shell.rs` `RightSurface::Subagent` | chip renders (`subagentChip`), no click handler; `TranscriptView.initWithStore` can show a store but no tab kind hosts it | 🟡 |
| Inline-code / Markdown file links → open in the right pane | `workspace_links.rs`, `markdown/link_interaction.rs` | links resolved (`ui/transcript/workspace_links.zig`), but `rich_text.registry.handler` is never set, so clicks go to `platform.openUrl` (external app) | 🟡 |
| Link destination disclosure, width-dependent link presentation | `markdown/link_destination.rs`, `link_presentation.rs` | — | ❌ |
| Mermaid diagrams (lazy background render, cache, preview) | `markdown/mermaid.rs`, `mermaid_cache.rs` | fences detected (`markdown/root.zig` `isMermaid`) and shown as source | ❌ |
| Compact transcript mode (setting) | `transcript.rs` | setting stored, no consumer | ❌ |
| Code fences fit-content toggle | `markdown/render.rs` | ✅ per block (`fit_toggle`); the `codeFencesFitContent` default is not read | 🟡 |

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
| Tab kinds `Subagent`, `SideChat` | `shell.rs` | — (`Kind = diffs, history, terminal, browser, files`) | ❌ |
| **Changes**: scope (working tree / branch / latest turn / commit), ref selector, discard + confirm, split / wrap, collapse all, sticky headers, full-document syntax, virtualized rows | `changes.rs` | `ui/changes/**` | ✅ |
| Review comments on diff lines and editor lines (comment adder/cards/drafts, folded into the prompt) | `comments.rs`, `comment_ui.rs` | — | ❌ |
| PR / change-request status for the checkout (`WatchCheckoutChangeRequest`) | `change_requests.rs` | — | ❌ |
| **History**: lane graph, paging, search, fetch all, branch tips, columns, author avatar ⇄ name, commit tabs | `history.rs` | `ui/history/**` | ✅ (column reorder `gitHistoryColumnOrder` not applied; avatars via `ResolveGitAvatars` not fetched) |
| **Terminal**: tabs, Ghostty VT, keys/mouse/paste encoding, theme palette, 12 ms coalescer | `terminal/**` | `terminal/**`, `ui/shell/terminal_dock.zig` | 🟡 runs a **local** PTY (`terminal/pty.zig`) instead of the engine's `OpenTerminal`/`SubscribeTerminal` (so remote-device sessions get a local shell); no tab drag-reorder, no middle-click close, PTYs not kept across navigation, height not persisted |
| **Browser**: device-local tabs, address bar, back/forward/reload, WKWebView (mac) / offscreen WebKitGTK helper (Linux) | `browser/**` | empty "Preview your work" page (`ui/shell/right_pane.zig`) | ❌ (`src/elements/native_view.zig` in progress) |
| **Files explorer**: lazy tree, search, git status, hidden/ignored toggle, keyboard nav, context menu, inline rename, delete confirm | `files/**`, `shell/files_panel.rs` | `ui/files/**` | ✅ |
| Explorer "Add to chat" / drag files into the chat / drag-move entries | `files/drag.rs`, `files/context_menu.rs` | `AddToChat` emitted, nobody subscribes; no drag | ❌ |
| Explorer Subagents / Chats sections | `files/sections.rs` | `FilesPanel.setSections` exists, never called (empty states only) | 🟡 |
| Rename/delete propagation to open editors | `shell/file_mutations.rs` | `EntryRenamed/EntryDeleted` emitted, not subscribed | ❌ |
| **Editor**: rope buffer, virtualized rows, soft wrap, gutter, indent guides, find/replace, go-to-line, hash-guarded save, conflict banners, syntax | `files/editor*.rs`, `files/document.rs`, `files/preview.rs`, gpui-base | `ui/editor/**` | 🟡 keymap not installed in the app (§2); autosave / default word wrap settings not read |
| Markdown preview, image preview | `files/markdown_preview.rs`, `files/markdown_media.rs`, `files/image_preview.rs` | — | ❌ |
| Side chats (fork from a chat, agent-spawned chats, `ForkSideChat`) | `shell/side_chats.rs` | — | ❌ |

## 10. Settings

| Page / feature | Rust | Zig | Status |
|---|---|---|---|
| Full-window settings mode, nav, Back/Escape, page scaffolding, selects, switches, tooltips | `settings.rs`, `settings/widgets.rs` | `ui/settings/view.zig`, `widgets.zig`, `select.zig` | ✅ |
| General: send key, compact transcript, compact model picker, Escape stops agent | `settings/shortcuts.rs` (general half) | `ui/settings/general.zig` — controls persist; three of four have no runtime consumer (§15) | 🟡 |
| General → Thread naming (`Get/SetTitleSettings`, model picker in title-bound mode) | `settings/thread_naming.rs` | a one-option stub select ("Session agent"); RPCs unused | 🟡 |
| Appearance: scheme cards, light/dark variants, accent, glass, fonts, sizes, conversation width | `settings/appearance.rs` | `ui/settings/appearance.zig` | ✅ |
| Appearance: match wallpaper colors | `settings/wallpaper_colors.rs` | `theme/wallpaper.zig` (needs a wallpaper source, which never gets set) | 🟡 |
| Appearance: new-thread background image + effects + adjustment dialog | `new_thread_background_*.rs` | "Choose image" button without a listener | ❌ |
| Appearance: wallpaper folder rotation (`RandomWallpaper`) | `settings/wallpaper.rs` | "Choose folder" without a listener | ❌ |
| Appearance: theme library / VS Code theme import | `theme_library.rs`, `crates/theme/src/{library,vscode}.rs` | "Add theme" without a listener; importer not ported (`theme/root.zig` TODO) | ❌ |
| Appearance: reduce motion (on/off/system), pause animations in background | `motion.rs` | stored; zpui reads only the OS preference (`Window.prefersReducedMotion`) | 🟡 |
| Notifications page | `settings/notifications.rs` | `ui/settings/notifications.zig` (persists; nothing notifies) | 🟡 |
| Voice page (opt-in, model download, microphone, hold-to-dictate) | `dictation/model.rs` | `ui/settings/voice.zig` (switch + recorder only) | 🟡 |
| Shortcuts page | `settings/shortcuts.rs` | `ui/settings/shortcuts.zig` | ✅ |
| Providers: harness rows, enable switch (`SetHarnessEnabled`), update policy, check now | `settings/harnesses.rs` | `ui/settings/providers.zig` | 🟡 Install / Cancel install (`InstallHarness`, `CancelInstall`) and Update (`ApplyHarnessUpdate`, the button only sets a local "preparing" override) not wired; device switcher commit is a no-op |
| Accounts: provider cards, account rows (plan, usage meters, reset), Switch / Forget, shared sign-in dialog (`StartAgentLogin/Poll/Complete/Cancel`) | `settings/accounts.rs` | routed to the Providers page (`.agents` → `providers.render`) | ❌ |
| Per-agent completion preferences | `settings/completion.rs` | toggles exist in `providers.zig` (`onCompletionToggle`); the composer ignores them | 🟡 |
| Devices: list, presence, copy id, rename | `settings/devices.rs` | `ui/settings/devices.zig` | ✅ |
| Files: autosave, delay, word wrap, hidden/ignored | `settings/files.rs` | `ui/settings/files.zig` (persists; editor/explorer don't read the defaults) | 🟡 |
| Appshots page | `settings/appshots.rs` | `ui/settings/appshots.zig` (UI only) | 🟡 |
| Archived sessions + Unarchive | `settings/archived.rs` | `ui/settings/archived.zig` | ✅ |

## 11. Theme, typography, motion

| Feature | Rust | Zig | Status |
|---|---|---|---|
| 30 built-in themes, seed derivation, semantic tokens, light designed separately | `crates/theme`, `theme.rs` | `theme/**` (bit-exact parity) | ✅ |
| Typography: bundled fonts, UI/terminal/code families + sizes, rem size | `typography.rs` | `theme/typography.zig`, `ui/settings/store.zig` | ✅ |
| Motion catalog (fade-in, menu-in, dialog-in, hover blend, stagger) | `motion.rs` | `theme/motion.zig`, `ui/components/anim.zig`, `hover.zig` | ✅ |
| Frost / glass / edge-fade surfaces | `frost.rs`, `glass.rs`, `edge_fade.rs` | `src/elements/effects.zig`, `ui/components/effects.zig`, `ui/composer/chrome.zig` | ✅ |
| Live theme switching from settings and OS | `appearance.rs` | `ui/settings/store.zig` `applyTheme` | ✅ (menu Appearance actions missing, §1) |

## 12. Voice, appshots, sounds, notifications, haptics

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Voice dictation (Parakeet v3 on-device, resampling, level meter, waveform) | `crates/voice`, `dictation/**` | — | ❌ |
| Appshots (capture the frontmost app window + AX/AT-SPI context; macOS native, Linux portal/X11) | `appshots/**` | — | ❌ |
| Session sounds (completion / input / attention / appshot chimes via afplay / paplay…) | `sound.rs`, `assets/sounds` | — (sounds not even copied into `apps/zeron/assets`) | ❌ |
| Desktop banners on status transitions (NSUserNotification / notify-send), background-only, agent-update banners, click routing | `notify.rs`, `shell::on_state_changed` | — | ❌ |
| Haptics on control detents (macOS) | `haptics.rs` | — | ❌ |

## 13. Accessibility

| Feature | Rust | Zig | Status |
|---|---|---|---|
| Roles, labels, placeholders on inputs, buttons, menus, lists (321 call sites in 35 files: `.role()`, `.aria_label()`), backed by zui's AccessKit integration (`gpui/src/window/a11y.rs`, accesskit_macos / accesskit_unix) | throughout | zpui has no accessibility tree; only the OS reduce-motion flag is read | ❌ |
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

## 15. Settings that persist but have no runtime effect

From `model/settings.zig` `UiSettings`, fields with no reader outside `ui/settings/`:
`windowGeometry`, `compactModelPicker`, `transcriptCompactMode`, `escapeStopsActiveAgent`,
`skillsInSlashMenu`, `skillCompletionByHarness`, `sidebarGrouped`, `sidebarOrganization`,
`sidebarSort`, `sidebarSectionsByProfile`, `githubStarBannerDismissed`, `lastSpaceId`,
`lastProjectActionBySpaceId`, `spaceFilter`, `soundEnabled` (+3 cue flags),
`notificationsEnabled`, `notificationsBackgroundOnly`, `agentUpdateNotifications`,
`rightPaneOpen`, `terminalHeight`, `terminalOpen`, `appshotsEnabled`, `appshotSoundEnabled`,
`appshotDestination`, `dictationEnabled`, `dictationInput`, `codeFencesFitContent`,
`openWebLinksInZeron`, `filesAutosaveEnabled`, `filesAutosaveDelayMs`, `filesWordWrap`,
`filesShowAll`, `newThreadComposerBackground`, `newThreadBackgroundEffect`, `wallpaperFolder`,
`wallpaperSource`, `wallpaperHistory`, `gitHistoryColumnOrder`. Layout fields
(`sidebarWidth`, `sidebarCollapsed`, `rightPaneWidth`, `filesPanelWidth`) are read at boot but
never saved.

## 16. zpui framework gaps (gpui features zeron uses)

| gpui feature | used by zeron for | zpui today | Status |
|---|---|---|---|
| `cx.set_menus` / `MenuItem` / `OsAction` / key-equivalent display | app menu bar | fixed native menu in `src/platform/mac/mac.zig` | ❌ |
| `on_open_urls`, `register_url_scheme`, `on_reopen` | deep links, dock reopen | mac delegate implements `application:openURLs:` and reopen, but `App` never calls `Platform.setCallbacks`; Linux has nothing | ❌ |
| `on_app_quit` (async teardown) | flush, install-on-quit, engine drain | — | ❌ |
| `on_window_should_close` veto | unsaved files | platform callback exists; core always returns true | ❌ |
| `observe_window_bounds`, `window_bounds()`, `displays()` with `uuid()`, `display_id` in options | window geometry restore | `displays` exists; `moved` callback not surfaced; no display uuid | 🟡 |
| `prompt_for_paths` | attach, wallpaper folder, background image, theme import | Linux portal (in progress, `file_dialog.zig`); macOS NSOpenPanel missing | 🟡 |
| `window.prompt` (modal alert) | rare confirmations | — (zeron mostly draws its own dialogs) | ❌ |
| External file drag-and-drop (`ExternalPaths`, `on_drop`, `drag_over`) | attachments, chat drop zone | macOS window receives drops but `src/window/dispatch.zig` turns them into mouse moves (TODO: payload); Wayland `onDndDrop` is a no-op; no XDND | ❌ |
| Internal drag-and-drop (`on_drag`, `on_drop`, drag ghosts) | tabs, pins, queue | `div.onDrag/onDrop/onDragMove` | ✅ |
| Clipboard images (`ClipboardEntry::Image`) | paste screenshots | `readClipboardImage` vtable slot being added | 🟡 |
| System notifications (zui `gpui_macos/system_notifications.rs`, `gpui_linux/system_notifications.rs`) | banners | — | ❌ (zeron itself uses ObjC / notify-send, so this can live in the app) |
| Accessibility (`role`, `aria_*`, AccessKit) | everything | — | ❌ |
| `container_query` | History responsive columns | — | ❌ |
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
| App hide / hide others / unhide as API | menu actions | only via native menu selectors | 🟡 |
| Keyboard-layout-change callback | shortcut display | platform callback slot unused | 🟡 |
| Grid layout (taffy) | not used by zeron | — | ➖ |
| Inspector / profiler / visual tests | dev only | — | ➖ |

---

## Remaining work, prioritized

Sizes: **S** ≤ 1 day · **M** 2–4 days · **L** 1–2 weeks · **XL** > 2 weeks.

1. **Install the editor keymap in the app** (call `ui/editor/actions.zig` `bindDefaults` from
   `keymap.zig` `applyKeymap`, like Rust reinstalls gpui-base's keymap) and handle
   `shell::SaveFile`. Without it the file editor can't move the caret or save. — S
2. **Subscribe to `ComposerEvent` in the shell**: workspace slash commands, paperclip →
   `promptForPaths` (+ macOS NSOpenPanel in zpui), dictation toggle; wire explorer `AddToChat`,
   transcript link handler (`rich_text.registry.handler` → open in the right pane),
   "click to retry" (`RetryDelivery`). — S/M
3. **App lifecycle in zpui + app**: `App` registers `PlatformCallbacks` (open_urls, reopen,
   quit); `on_app_quit` hook; should-close veto; keep the process alive on macOS ⌘W and reopen
   from the dock; `zeron://open/chat/…` routing + positional URL argument (port `links.rs`). — M
4. **Menu bar**: a `setMenus` API in zpui (MenuItem / separators / OS submenus / key
   equivalents from the keymap) and handlers for every `zeron::*` action (About, Check for
   Updates, Settings, Edit verbs, Appearance, Minimize, Zoom, Close Window). — M
5. **Persist shell state**: sidebar/right-pane/files/terminal sizes and open flags, sidebar view
   menu choices, window geometry per display (needs bounds observer + display uuid in zpui). — M
6. **Chat & space management**: rename (dialog + title bar), Copy ▸ link/path, Delete with
   confirm, `ArchiveSession`/`OpenModelPicker` handlers, space rename/delete, custom sidebar
   sections, org-gate create/select, login paste-code dialog. — M
7. **Attachments end to end**: external drops in zpui (mac payload, Wayland/X11 DnD), clipboard
   image paste, chunked upload, transcript read-back from the host, image viewer / lightbox
   (+ pinch gestures), chat drop zone. — L
8. **Composer completions**: `@` file mentions (`SearchFiles`) with chips, provider slash
   commands and skills (`ListCommands`, `ListSkills`) honoring completion prefs. — M/L
9. **Run-time surfaces around the composer**: question wizard, todo panel, account-usage ring,
   queue drag-reorder + edit lease, jump-to-bottom, "Show full output" (`FetchToolBlob`),
   "Worked for". — M
10. **Subagent and side-chat tabs**: `Subagent` / `SideChat` right-pane kinds hosting
    `TranscriptView.initWithStore`, spawn-chip click, explorer sections, `ForkSideChat`. — M
11. **Settings → Accounts + provider actions**: agent accounts (list / switch / forget / login
    dialog), harness install / update / cancel RPCs, thread-naming RPCs, device switcher, and
    make every persisted setting in §15 take effect (compact transcript, Escape stops agent,
    reduce-motion override, files defaults, …). — L
12. **Notifications and sounds**: banners (UNUserNotification/NSUserNotification on macOS,
    `org.freedesktop.Notifications` or notify-send on Linux), click routing, chimes (copy
    `assets/sounds`), background-only gating. — M
13. **Engine-backed terminal**: `OpenTerminal`/`SubscribeTerminal`/`WriteTerminal`/`ResizeTerminal`
    so remote-device sessions work; keep PTYs across navigation; tab drag / middle-click. — M
14. **App self-update + release plumbing**: port `crates/update` checker/installer, install on
    quit, update strip and menu actions; signing / notarization; logs to a rotating file with
    a panic handler. — L
15. **Browser pane**: finish `native_view.zig` (WKWebView child on macOS), WebKitGTK offscreen
    helper on Linux, tabs/address bar/navigation, `browser::*` actions. — XL
16. **Review comments + PR status**: diff/editor comment cards folded into the prompt, message
    badges, `WatchCheckoutChangeRequest` for the sidebar badge and Changes header. — M/L
17. **Mermaid rendering** (port or embed a renderer; lazy background cache; preview). — L
18. **Files extras**: markdown preview, image preview (`ReadWorkspaceImage`), drag-move in the
    tree, rename/delete propagation to open editors. — M
19. **Project actions** (titlebar Run/Setup menu and editor). — M
20. **Voice dictation** (audio capture + Parakeet inference, waveform UI). — XL
21. **Appshots** (window capture + AX/AT-SPI context, global shortcut). — L
22. **Accessibility tree in zpui** (NSAccessibility / AT-SPI bridge; adopt roles/labels in the
    app). — XL
23. **Appearance extras**: theme library + VS Code import, wallpaper folder rotation, new-thread
    background + effects. — L
24. **Polish**: composer dock choreography, streaming veil, link destination disclosure,
    harness-updates island, GitHub star banner, sync overlay / local import, moving-row
    animation, haptics, repo avatars, repo clone/create. — L total
