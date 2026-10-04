//! Reduced motion as a setting (zeron `motion.rs` `MotionState`, `resolve`,
//! `window_activation_changed`): the persisted preference (System / On /
//! Off) and "Pause animations in background" combined with the OS setting
//! and main-window focus into each window's reduced-motion flag, which every
//! zpui animation, tween and zeron loader reads
//! (`Window.prefersReducedMotion`).
//!
//! ```zig
//! motion.sync(window, app); // once per shell frame (cheap; re-reads the OS on refocus)
//! motion.systemReduces(app) // the OS value, for the Settings helper text
//! ```

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const store = @import("store.zig");

const App = zpui.App;
const Window = zpui.Window;

/// The OS value as last read, and the focus it was read under.
pub const State = struct {
    system: bool,
    active: bool,

    pub fn deinit(_: *State, _: *App) void {}
};

fn readSystem(app: *App) bool {
    return app.platform.vtable.prefersReducedMotion(app.platform.ptr);
}

fn stateMut(app: *App) *State {
    if (app.tryGlobal(State) == null) {
        app.setGlobal(State{ .system = readSystem(app), .active = true }) catch @panic("OOM");
    }
    return @constCast(app.tryGlobal(State).?);
}

/// The OS setting (drives "Following reduced system motion…").
pub fn systemReduces(app: *App) bool {
    return stateMut(app).system;
}

/// `resolve` for this window right now.
pub fn reducedFor(app: *App, active: bool) bool {
    const s = store.current(app).theme;
    return zt.motion.resolveReduced(s.reduce_motion, stateMut(app).system, s.pause_animations_in_background, active);
}

/// Bring `window`'s flag in line with the settings. Regaining focus re-reads
/// the OS setting (changing it means visiting System Settings).
pub fn sync(window: *Window, app: *App) void {
    const st = stateMut(app);
    const active = window.isWindowActive();
    if (active and !st.active) st.system = readSystem(app);
    st.active = active;
    window.prefers_reduced_motion = reducedFor(app, active);
}

/// After a settings change: every window at once.
pub fn applyAll(app: *App) void {
    for (app.windows.items) |slot| if (slot) |w| sync(w, app);
}

/// The Appearance helper line (`reduce_motion_helper`).
pub fn helper(preference: zt.motion.ReduceMotion, system: bool) []const u8 {
    return switch (preference) {
        .system => if (system) "Following reduced system motion. Activity indicators use a gentle brightness pulse." else "Following the system, which currently allows motion.",
        .on => "Animations skip straight to their final state.",
        .off => "Animations play even if the system asks for less motion.",
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "the preference, the OS and background pausing combine like Rust's resolve" {
    try testing.expect(zt.motion.resolveReduced(.on, false, false, true));
    try testing.expect(!zt.motion.resolveReduced(.off, true, false, true));
    try testing.expect(zt.motion.resolveReduced(.system, true, false, true));
    try testing.expect(!zt.motion.resolveReduced(.system, false, false, true));
    try testing.expect(zt.motion.resolveReduced(.off, false, true, false));
    try testing.expect(!zt.motion.resolveReduced(.off, false, true, true));
}
