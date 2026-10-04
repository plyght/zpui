//! The new-thread background (zeron `new_thread_background_*.rs`,
//! `settings::{install,remove}_new_thread_composer_background`,
//! `settings/wallpaper.rs`, `settings/wallpaper_colors.rs`).
//!
//! - `artwork`: decoding contract, 2048px proxy, effect rasters (pure);
//! - `cache`: per-path decoded sources + effect rasters (background jobs);
//! - `hero`: cover framing, composer cutout mask, crossfade, the canvas layer;
//! - `install`: choose / replace / remove / effect / adjustment / wallpaper colors;
//! - `wallpaper`: folder rotation (mod-u, Shuffle) with a warm lookahead.

pub const artwork = @import("artwork.zig");
pub const cache = @import("cache.zig");
pub const hero = @import("hero.zig");
pub const install = @import("install.zig");
pub const wallpaper = @import("wallpaper.zig");

test {
    _ = artwork;
    _ = cache;
    _ = hero;
    _ = install;
    _ = wallpaper;
    _ = @import("tests.zig");
}
