//! Window-layer glue for system symbols (`image/system_symbol.zig`, macOS SF Symbols):
//! rasterizing through the platform into the monochrome sprite atlas, a negative cache for
//! symbols the OS lacks, and the App's optional SVG → symbol resolver.
//!
//! ```zig
//! zpui.systemSymbol("folder", .{ .point_size = 13 }).size(px(16)).textColor(muted)  // symbol only
//! zpui.svg().source(path, bytes).symbol("folder", .{})   // symbol, else the SVG
//! zpui.system_symbols.setResolver(app, .{ .resolve = myMap })  // every svg() consults it
//! ```
//!
//! A symbol paints centered on the element's bounds at its own (device-scale) size, so the
//! layout box is the same as the SVG's. Tiles are cached per symbol, point size, weight,
//! scale, fit box and device scale; a symbol the platform does not have is remembered as a
//! miss and the caller's SVG is painted instead. Backends without symbols (Linux) never
//! reach the platform.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const atlas_mod = @import("../atlas.zig");
const sym = @import("../image/system_symbol.zig");
const App = @import("../app/app.zig").App;
const image_glue = @import("image.zig");

pub const Options = sym.Options;
pub const Weight = sym.Weight;
pub const Scale = sym.Scale;
pub const Request = sym.Request;
pub const Mask = sym.Mask;

/// A symbol to draw instead of an SVG: candidate names in preference order (the first
/// the OS has wins; static lifetime) and their configuration.
pub const Symbol = struct {
    names: []const []const u8,
    options: Options = .{},
};

/// Maps an `svg()`'s path and logical size to a symbol, or null to keep the SVG. Called
/// while painting every svg without an explicit `.symbol(...)`; keep it cheap.
pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    resolve: *const fn (ctx: ?*anyopaque, app: *App, path: []const u8, size: geometry.Size(geometry.Pixels)) ?Symbol,
};

/// Per-App state (lives in `ImageServices`).
pub const State = struct {
    misses: std.AutoHashMapUnmanaged(atlas_mod.SymbolKey, void) = .empty,
    resolver: ?Resolver = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.misses.deinit(gpa);
    }
};

fn state(app: *App) *State {
    return &image_glue.services(app).symbols;
}

/// Install (or with null, remove) the App's svg → symbol resolver; windows repaint.
pub fn setResolver(app: *App, resolver: ?Resolver) void {
    state(app).resolver = resolver;
    app.refreshWindows();
}

/// The resolver's symbol for an svg at `path` drawn at `size`, if any.
pub fn resolve(app: *App, path: []const u8, size: geometry.Size(geometry.Pixels)) ?Symbol {
    if (!app.platform.supportsSystemSymbols()) return null;
    const services = app.image_services orelse return null;
    const r = services.symbols.resolver orelse return null;
    return r.resolve(r.ctx, app, path, size);
}

/// Whether the platform has `name` (rendered once at 1x; misses are cached).
pub fn available(app: *App, name: []const u8, options: Options) bool {
    if (!app.platform.supportsSystemSymbols()) return false;
    const req: Request = .{ .name = name, .options = options, .scale_factor = 1 };
    const key = sym.atlasKey(req).symbol;
    const st = state(app);
    if (st.misses.contains(key)) return false;
    var mask = app.platform.renderSystemSymbol(app.gpa, req) orelse {
        st.misses.put(app.gpa, key, {}) catch {};
        return false;
    };
    mask.deinit(app.gpa);
    return true;
}

const Builder = struct {
    app: *App,
    request: Request,
    mask: ?Mask = null,

    pub fn build(self: *Builder) !?atlas_mod.BuiltTile {
        const m = self.app.platform.renderSystemSymbol(self.app.gpa, self.request) orelse return null;
        self.mask = m;
        if (m.width == 0 or m.height == 0 or m.bytes.len != @as(usize, m.width) * m.height) return null;
        return .{ .size = .{ .width = @intCast(m.width), .height = @intCast(m.height) }, .bytes = m.bytes };
    }

    fn deinit(self: *Builder) void {
        if (self.mask) |*m| m.deinit(self.app.gpa);
    }
};

/// The atlas tile for `request` (rendering it on a miss), or null when the platform has
/// no such symbol.
pub fn rasterize(app: *App, atlas: *atlas_mod.Atlas, request: Request) ?atlas_mod.AtlasTile {
    const key = sym.atlasKey(request);
    if (atlas.get(key)) |t| return t;
    if (!app.platform.supportsSystemSymbols()) return null;
    const st = state(app);
    if (st.misses.contains(key.symbol)) return null;
    var b: Builder = .{ .app = app, .request = request };
    defer b.deinit();
    const tile = atlas.getOrInsertWith(key, &b) catch |err| {
        std.log.warn("system symbol {s} failed: {t}", .{ request.name, err });
        return null;
    };
    if (tile == null) st.misses.put(app.gpa, key.symbol, {}) catch {};
    return tile;
}
