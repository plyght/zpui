//! Shared zeron UI primitives (owned by the shell; other views may use them).
//!
//! ```zig
//! const ui = @import("../components/root.zig");
//! const theme = ui.theme.get(cx);
//! ui.icon.of(.folder, 16, theme.text_muted)
//! ui.button.windowControl("x", .plus, "New session", theme).onClick(...)
//! ui.popover.card(&theme.forPopup())
//! ui.effects.frosted(12, 16, child) / ui.effects.edgeFaded(child, .{...}) / ui.effects.fadedText(s, .{})
//! ui.badge.pullRequest(413, theme) / ui.badge.avatar("A", 16, theme)
//! ui.loaders.gradientSpinner(2.5, phase)
//! ```
//! Other agents may add files next to these but should not edit them.

pub const theme = @import("theme.zig");
pub const icon = @import("icon.zig");
pub const effects = @import("effects.zig");
pub const tooltip = @import("tooltip.zig");
pub const popover = @import("popover.zig");
pub const button = @import("button.zig");
pub const badge = @import("badge.zig");
pub const loaders = @import("loaders.zig");
pub const switch_ = @import("switch.zig");
pub const hover = @import("hover.zig");
pub const anim = @import("anim.zig");

pub const rems = theme.rems;
pub const Theme = theme.Theme;
