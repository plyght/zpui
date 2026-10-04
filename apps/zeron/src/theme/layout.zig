//! Layout constants in logical pixels. Numbers drive layout; they never depend
//! on the painted palette. Gathered from zeron `crates/ui/src/theme.rs`
//! (`Theme::*` consts), settings.rs, composer.rs, popover.rs, shell.rs,
//! surface_chrome.rs, frost.rs, changes.rs, terminal/*, transcript.rs, queue.rs.

// ---- window chrome (theme.rs, shell.rs) ----
/// In-card header height (zeron `h-11`).
pub const header_height: f32 = 44;
/// Unified window titlebar (traffic lights + cluster + tabs).
pub const titlebar_height: f32 = 38;
/// Top-only titlebar padding (38/2 + 4/2 = 21 = macOS traffic-light center).
pub const titlebar_top_pad: f32 = 4;
pub const titlebar_control_gap: f32 = 2;
pub const titlebar_group_gap: f32 = space_sm;
pub const titlebar_identity_gap: f32 = space_md;
pub const titlebar_action_edge_inset: f32 = 6;
pub const cluster_buttons_width: f32 = 24.0 * 3.0 + titlebar_group_gap + titlebar_control_gap;
pub const linux_window_corner_radius: f32 = 10;
/// Reserved status strip under the content outlet (zeron `h-6`).
pub const status_strip_height: f32 = 24;
/// Gradient band fading the transcript into the panel at its bottom edge.
pub const transcript_fade_band: f32 = 24;

// ---- radii (theme.rs, popover.rs, composer.rs, queue.rs) ----
pub const bubble_radius: f32 = 16;
pub const panel_radius: f32 = 10;
pub const control_radius: f32 = 6;
pub const popover_card_radius: f32 = 12;
pub const popover_card_inset: f32 = 4;
pub const menu_gap: f32 = 2;
/// Concentric with the card: rows sit inside its 1px border and padding.
pub const menu_item_radius: f32 = popover_card_radius - 1.0 - popover_card_inset;
pub const palette_radius: f32 = 16;
pub const palette_item_radius: f32 = 14.0 - popover_card_inset;
pub const composer_radius: f32 = 26;
pub const queue_panel_radius: f32 = 16;
pub const queue_row_radius: f32 = 8;
pub const inline_code_radius: f32 = 4.5;

// ---- spacing ladder (theme.rs) ----
pub const space_xs: f32 = 4;
pub const space_sm: f32 = 8;
pub const space_md: f32 = 12;
pub const space_lg: f32 = 16;
/// Optical gap for a tight title/description stack (outside the ladder).
pub const text_stack_gap: f32 = 1;

// ---- frost (frost.rs) ----
/// Backdrop-blur sigma shared by menus, popovers, palettes and the composer.
pub const menu_blur: f32 = 16;

// ---- resizable panes (settings.rs) ----
pub const sidebar_min: f32 = 224;
pub const sidebar_max: f32 = 400;
pub const sidebar_default: f32 = 256;
pub const files_panel_min: f32 = 220;
pub const files_panel_max: f32 = 440;
pub const files_panel_default: f32 = 286;
pub const right_pane_min: f32 = 360;
pub const right_pane_default: f32 = 520;
pub const chat_panel_min: f32 = 300;
pub const terminal_min_height: f32 = 160;
/// Terminal max height as a fraction of the viewport.
pub const terminal_max_vh: f32 = 0.55;
pub const terminal_abs_max_height: f32 = 2000;
pub const terminal_default_height: f32 = 280;
pub const transcript_width_min: f32 = 560;
pub const transcript_width_max: f32 = 1200;
pub const transcript_width_default: f32 = 736;
pub const transcript_width_step: f32 = 16;

// ---- composer (composer.rs) ----
pub const composer_textarea_pad_v: f32 = 20;
pub const composer_textarea_min: f32 = 76;
pub const composer_textarea_max: f32 = 260;
pub const composer_actions_row_height: f32 = 2.0 + 32.0 + 8.0;
pub const composer_pill_border_v: f32 = 2;
pub const composer_min_height: f32 = composer_textarea_min + composer_actions_row_height + composer_pill_border_v;
pub const composer_max_height: f32 = composer_textarea_max + composer_actions_row_height + composer_pill_border_v;
pub const composer_compact_height: f32 = 49;
pub const composer_max_width: f32 = 768;
pub const composer_min_compact_input_width: f32 = 200;
pub const composer_action_utility_gap: f32 = 2;
pub const composer_action_primary_gap: f32 = space_sm;
pub const composer_caret_blink_ms: u64 = 500;

// ---- surface chrome (surface_chrome.rs) ----
pub const chrome_header_height: f32 = titlebar_height;
pub const chrome_control_size: f32 = 24;
pub const chrome_control_radius: f32 = 6;
pub const chrome_icon_size: f32 = 14;
pub const chrome_control_gap: f32 = 4;
pub const chrome_edge_inset: f32 = 8;

// ---- markdown (markdown/render.rs) ----
pub const code_padding_x: f32 = 12;
pub const code_padding_y: f32 = 10;
pub const code_header_height: f32 = 28;
pub const code_action_size: f32 = 22;
pub const table_cell_padding: f32 = 12;
pub const table_divider: f32 = 1;
pub const table_min_column_content: f32 = 48;
pub const table_min_column_width: f32 = 96;
pub const inline_code_pad_x: f32 = 2;
pub const inline_code_inset_y: f32 = 2;

// ---- transcript (transcript.rs) ----
pub const user_bubble_padding_x: f32 = 16;
pub const user_bubble_padding_y: f32 = 10;
/// Max user bubble width as a fraction of the column.
pub const user_bubble_max_fraction: f32 = 0.80;
pub const user_collapsed_lines: usize = 5;
pub const tool_group_header_height: f32 = 26;
pub const tool_tree_row_height: f32 = 32;
pub const activity_gutter_width: f32 = 48;
pub const chip_height: f32 = 38;
pub const chip_card_height: f32 = 30;
pub const stick_threshold: f32 = 70;
pub const scroll_button_threshold: f32 = 320;

// ---- diff (changes.rs) ----
pub const diff_hunk_header_height: f32 = 28;
pub const diff_line_height: f32 = 21;
pub const diff_gutter_width: f32 = 36;
pub const diff_marker_width: f32 = 28;
pub const diff_accent_bar_width: f32 = 3;
pub const diff_split_marker_width: f32 = 18;

// ---- terminal (terminal/view.rs, terminal/panel.rs) ----
pub const terminal_padding: f32 = 12;
pub const terminal_tab_width: f32 = 118;
pub const terminal_tab_bar_height: f32 = 40;

// ---- lists ----
pub const queue_row_height: f32 = 36;
pub const queue_row_pad_x: f32 = 8;
pub const files_tree_row_height: f32 = 27;
pub const files_tree_indent: f32 = 14;
pub const sidebar_row_height: f32 = 45;
pub const sidebar_row_height_compact: f32 = 29;
pub const sidebar_row_gap: f32 = 2;
pub const menu_row_gap: f32 = 10;
pub const menu_row_padding_x: f32 = 8;
pub const menu_row_padding_y: f32 = 6;
pub const badge_height: f32 = 24;
pub const settings_select_height: f32 = 32;
pub const settings_switch_width: f32 = 44.8;
