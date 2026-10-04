//! The native path prompts behind Appearance (zeron `appearance.rs`
//! `choose_new_thread_background`, `choose_wallpaper_folder`,
//! `choose_import_source`): `NSOpenPanel` on macOS, the XDG portal on Linux
//! (`App.platform.promptForPaths`). The answer arrives on the main thread
//! and is handed to the background installer / wallpaper rotation / theme
//! importer. Tests (and `ZERON_PROMPT_PATH`-style automation) bypass the
//! dialog with `override`.
//!
//! ```zig
//! file_prompts.chooseBackground(app);      // → install.installAsync(app, path)
//! file_prompts.chooseWallpaperFolder(app); // → wallpaper.setFolder(app, path)
//! file_prompts.prompt(app, .theme_import, ctx, onPicked);
//! ```

const std = @import("std");
const zpui = @import("zpui");
const background = @import("../background/root.zig");

const App = zpui.App;

pub const Kind = enum {
    background_image,
    wallpaper_folder,
    theme_import,

    pub fn options(self: Kind) zpui.platform.PathPromptOptions {
        return switch (self) {
            .background_image => .{ .files = true, .directories = false, .multiple = false, .title = "Choose New Thread Composer Background" },
            .wallpaper_folder => .{ .files = false, .directories = true, .multiple = false, .title = "Choose Wallpaper Folder" },
            .theme_import => .{ .files = true, .directories = false, .multiple = false, .title = "Import VS Code Theme" },
        };
    }
};

/// Tests / automation: answer the prompt without a dialog (null = cancelled).
pub var override: ?*const fn (kind: Kind) ?[]const u8 = null;

pub const Done = *const fn (app: *App, ctx: ?*anyopaque, path: ?[]const u8) void;

const Pending = struct { app: *App, ctx: ?*anyopaque, done: Done };

fn onPaths(raw: ?*anyopaque, paths: ?[]const []const u8) void {
    const p: *Pending = @ptrCast(@alignCast(raw.?));
    const pending = p.*;
    pending.app.gpa.destroy(p);
    const list = paths orelse return pending.done(pending.app, pending.ctx, null);
    // `paths.pop()`: the last selection wins.
    pending.done(pending.app, pending.ctx, if (list.len > 0) list[list.len - 1] else null);
}

/// Ask for one path of `kind`; `done` runs on the main thread (path null when cancelled).
pub fn prompt(app: *App, kind: Kind, ctx: ?*anyopaque, done: Done) void {
    if (override) |f| return done(app, ctx, f(kind));
    const p = app.gpa.create(Pending) catch return;
    p.* = .{ .app = app, .ctx = ctx, .done = done };
    app.platform.promptForPaths(kind.options(), .{ .ctx = p, .func = onPaths });
}

fn onBackground(app: *App, _: ?*anyopaque, path: ?[]const u8) void {
    background.install.installAsync(app, path orelse return);
}

fn onFolder(app: *App, _: ?*anyopaque, path: ?[]const u8) void {
    background.wallpaper.setFolder(app, path orelse return);
}

/// "Choose image" / "Replace image".
pub fn chooseBackground(app: *App) void {
    background.install.setError(app, null);
    prompt(app, .background_image, null, onBackground);
}

/// "Choose folder" (and mod-u without a folder).
pub fn chooseWallpaperFolder(app: *App) void {
    prompt(app, .wallpaper_folder, null, onFolder);
}
