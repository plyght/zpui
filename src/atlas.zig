//! Texture atlas: GPU-visible handle types referenced by sprite primitives
//! (gpui `platform.rs`) plus a backend-agnostic atlas allocator shared by the
//! Metal and Vulkan renderers.
//!
//! `Atlas` ports the behavior of zui's `WgpuAtlas`/`MetalAtlas`: one list of
//! textures per `AtlasTextureKind`, shelf packing within each texture (in the
//! spirit of etagere's `BucketedAtlasAllocator`), growth by adding textures,
//! an `AtlasKey -> AtlasTile` cache and `remove` (used by
//! `ImageSource::evict` / `Window::drop_image`) that frees tile space and
//! releases a texture once nothing references it.
//!
//! The allocator owns no GPU objects. Backends, once per frame:
//!  1. call `textureSlots(kind)` / `textureInfo(id)` and (re)create or destroy
//!     their GPU texture for every slot whose `generation` changed;
//!  2. copy every `pendingUploads()` entry into the texture;
//!  3. call `clearUploads()`.
//!
//! Not thread-safe: callers that rasterize glyphs off the main thread must
//! serialize access themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");

const DevicePixels = geometry.DevicePixels;
const DeviceSize = geometry.Size(DevicePixels);
const DeviceBounds = geometry.Bounds(DevicePixels);

/// What a given atlas texture stores; selects pixel format and shader path.
pub const AtlasTextureKind = enum(u32) {
    /// Single-channel coverage (glyphs, SVG masks). Metal: A8, wgpu/Vulkan: R8.
    monochrome = 0,
    /// Full-color BGRA (images, emoji), straight alpha.
    polychrome = 1,
    /// Per-channel LCD coverage for subpixel text (BGRA, wgpu/Vulkan only).
    subpixel = 2,

    /// Bytes per texel of the tile data passed to `Atlas.getOrInsertWith`.
    pub fn bytesPerPixel(kind: AtlasTextureKind) u32 {
        return switch (kind) {
            .monochrome => 1,
            .polychrome, .subpixel => 4,
        };
    }
};

/// Identifies one texture inside an atlas. `u32` index (not usize) for shader compatibility.
pub const AtlasTextureId = extern struct {
    index: u32,
    kind: AtlasTextureKind,

    pub fn eql(a: AtlasTextureId, b: AtlasTextureId) bool {
        return a.index == b.index and a.kind == b.kind;
    }
};

/// Allocation id of a tile within its texture (serialized etagere `AllocId` in gpui).
pub const TileId = u32;

/// A rectangle of an atlas texture holding one rasterized glyph/image/SVG.
/// 32 bytes; WGSL `AtlasTile` (align 8 due to `vec2<i32>` bounds) has the same layout.
pub const AtlasTile = extern struct {
    texture_id: AtlasTextureId,
    tile_id: TileId,
    /// Padding (in device pixels) around the tile content.
    padding: u32,
    /// Bounds of the tile within the texture, in device pixels.
    bounds: geometry.Bounds(geometry.DevicePixels),

    comptime {
        std.debug.assert(@sizeOf(AtlasTile) == 32);
        std.debug.assert(@offsetOf(AtlasTile, "bounds") == 16);
    }
};

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// gpui `RenderGlyphParams`. Floats are stored as bit patterns so the key hashes exactly.
pub const GlyphKey = struct {
    font_id: u32,
    glyph_id: u32,
    font_size_bits: u32,
    scale_factor_bits: u32,
    subpixel_variant: [2]u8 = .{ 0, 0 },
    is_emoji: bool = false,
    subpixel_rendering: bool = false,
    dilation: u8 = 0,
    /// `RenderGlyphParams.raster_transform` (a, b, c, d) as bit patterns; identity by default.
    raster_transform_bits: [4]u32 = .{ @bitCast(@as(f32, 1)), 0, 0, @bitCast(@as(f32, 1)) },

    pub fn init(font_id: u32, glyph_id: u32, font_size: f32, scale_factor: f32) GlyphKey {
        return .{
            .font_id = font_id,
            .glyph_id = glyph_id,
            .font_size_bits = @bitCast(font_size),
            .scale_factor_bits = @bitCast(scale_factor),
        };
    }
};

/// gpui `RenderSvgParams`; the path string is identified by a caller-computed hash.
pub const SvgKey = struct {
    path_hash: u64,
    size: [2]DevicePixels,
};

/// A system symbol (`image/system_symbol.zig`): name hash, configuration and device scale.
pub const SymbolKey = struct {
    name_hash: u64,
    point_size_bits: u32,
    fit_bits: u32,
    scale_factor_bits: u32,
    weight: u8,
    scale: u8,
};

/// gpui `RenderImageParams`.
pub const ImageKey = struct {
    image_id: u64,
    frame_index: u32 = 0,
};

/// gpui `AtlasKey`: what a tile was rasterized from.
pub const AtlasKey = union(enum) {
    glyph: GlyphKey,
    svg: SvgKey,
    image: ImageKey,
    symbol: SymbolKey,

    /// Texture kind the key's tile lives in (gpui `AtlasKey::texture_kind`).
    pub fn textureKind(key: AtlasKey) AtlasTextureKind {
        return switch (key) {
            .glyph => |g| if (g.is_emoji) .polychrome else if (g.subpixel_rendering) .subpixel else .monochrome,
            .svg, .symbol => .monochrome,
            .image => .polychrome,
        };
    }
};

// ---------------------------------------------------------------------------
// Shelf packer
// ---------------------------------------------------------------------------

/// Shelf (row) rectangle packer with deallocation. Each shelf has a fixed
/// height; items fill free horizontal spans. Empty shelves are recycled for
/// any height that fits, and trailing empty shelves give their space back.
pub const ShelfAllocator = struct {
    size: DeviceSize,
    shelves: std.ArrayList(Shelf) = .empty,
    allocs: std.ArrayList(Alloc) = .empty,
    free_ids: std.ArrayList(u32) = .empty,
    /// Bottom edge of the last shelf.
    next_y: i32 = 0,

    const Span = struct { x: i32, w: i32 };
    const Shelf = struct {
        y: i32,
        height: i32,
        /// Free horizontal spans, sorted by `x`, never adjacent.
        free: std.ArrayList(Span) = .empty,
        live: u32 = 0,
    };
    const Alloc = struct { shelf: u32, x: i32, w: i32, live: bool };

    pub const Allocation = struct { id: u32, origin: geometry.Point(DevicePixels) };

    pub fn init(size: DeviceSize) ShelfAllocator {
        return .{ .size = size };
    }

    pub fn deinit(self: *ShelfAllocator, gpa: Allocator) void {
        for (self.shelves.items) |*s| s.free.deinit(gpa);
        self.shelves.deinit(gpa);
        self.allocs.deinit(gpa);
        self.free_ids.deinit(gpa);
        self.* = undefined;
    }

    /// Reserve a `w`x`h` rect. Returns null when it does not fit.
    pub fn allocate(self: *ShelfAllocator, gpa: Allocator, w: i32, h: i32) Allocator.Error!?Allocation {
        if (w <= 0 or h <= 0 or w > self.size.width or h > self.size.height) return null;

        // Best fit among shelves that waste at most half the item height (or any empty shelf).
        var best: ?struct { shelf: u32, span: usize, waste: i32 } = null;
        for (self.shelves.items, 0..) |*s, i| {
            if (s.height < h) continue;
            const waste = s.height - h;
            if (s.live > 0 and waste > @max(@divTrunc(h, 2), 4)) continue;
            const span = findSpan(s, w) orelse continue;
            if (best == null or waste < best.?.waste) best = .{ .shelf = @intCast(i), .span = span, .waste = waste };
        }
        if (best == null and self.next_y + h <= self.size.height) {
            // New shelf; round its height up a little so similar items can share it.
            const rounded = @min(std.mem.alignForward(i32, h, 4), self.size.height - self.next_y);
            try self.shelves.ensureUnusedCapacity(gpa, 1);
            var shelf: Shelf = .{ .y = self.next_y, .height = rounded };
            try shelf.free.append(gpa, .{ .x = 0, .w = self.size.width });
            self.shelves.appendAssumeCapacity(shelf);
            self.next_y += rounded;
            best = .{ .shelf = @intCast(self.shelves.items.len - 1), .span = 0, .waste = 0 };
        }
        if (best == null) {
            // Last resort: any shelf tall enough, regardless of waste.
            for (self.shelves.items, 0..) |*s, i| {
                if (s.height < h) continue;
                const span = findSpan(s, w) orelse continue;
                best = .{ .shelf = @intCast(i), .span = span, .waste = 0 };
                break;
            }
        }
        const pick = best orelse return null;

        try self.allocs.ensureUnusedCapacity(gpa, 1);
        const shelf = &self.shelves.items[pick.shelf];
        const span = &shelf.free.items[pick.span];
        const x = span.x;
        span.x += w;
        span.w -= w;
        if (span.w == 0) _ = shelf.free.orderedRemove(pick.span);
        shelf.live += 1;

        const record: Alloc = .{ .shelf = pick.shelf, .x = x, .w = w, .live = true };
        const id: u32 = if (self.free_ids.pop()) |reused| blk: {
            self.allocs.items[reused] = record;
            break :blk reused;
        } else blk: {
            self.allocs.appendAssumeCapacity(record);
            break :blk @intCast(self.allocs.items.len - 1);
        };
        return .{ .id = id, .origin = .{ .x = x, .y = shelf.y } };
    }

    fn findSpan(shelf: *const Shelf, w: i32) ?usize {
        for (shelf.free.items, 0..) |s, i| if (s.w >= w) return i;
        return null;
    }

    /// Free a previous allocation. Invalid or already-freed ids are ignored.
    pub fn deallocate(self: *ShelfAllocator, gpa: Allocator, id: u32) Allocator.Error!void {
        if (id >= self.allocs.items.len or !self.allocs.items[id].live) return;
        try self.free_ids.ensureUnusedCapacity(gpa, 1);
        const a = &self.allocs.items[id];
        a.live = false;
        self.free_ids.appendAssumeCapacity(id);

        const shelf = &self.shelves.items[a.shelf];
        shelf.live -= 1;
        if (shelf.live == 0) {
            shelf.free.clearRetainingCapacity();
            shelf.free.appendAssumeCapacity(.{ .x = 0, .w = self.size.width });
            // Give trailing empty shelves back to the free vertical space.
            while (self.shelves.items.len > 0 and self.shelves.items[self.shelves.items.len - 1].live == 0) {
                var last = self.shelves.pop().?;
                self.next_y = last.y;
                last.free.deinit(gpa);
            }
            return;
        }
        // Insert the span, merging with neighbours.
        var i: usize = 0;
        while (i < shelf.free.items.len and shelf.free.items[i].x < a.x) i += 1;
        var span: Span = .{ .x = a.x, .w = a.w };
        if (i < shelf.free.items.len and shelf.free.items[i].x == span.x + span.w) {
            span.w += shelf.free.items[i].w;
            _ = shelf.free.orderedRemove(i);
        }
        if (i > 0 and shelf.free.items[i - 1].x + shelf.free.items[i - 1].w == span.x) {
            shelf.free.items[i - 1].w += span.w;
            return;
        }
        try shelf.free.insert(gpa, i, span);
    }
};

// ---------------------------------------------------------------------------
// Atlas
// ---------------------------------------------------------------------------

/// A texel copy the backend must perform into texture `texture_id`.
pub const Upload = struct {
    texture_id: AtlasTextureId,
    bounds: DeviceBounds,
    /// Tightly packed rows, `AtlasTextureKind.bytesPerPixel` bytes per texel. Owned by the atlas.
    data: []u8,
};

/// What a backend needs to create the GPU texture for one atlas slot.
pub const TextureInfo = struct {
    id: AtlasTextureId,
    size: DeviceSize,
    /// Unique per created texture; changes when a slot is freed and reused.
    generation: u32,
};

/// Result of an `Atlas.getOrInsertWith` build callback.
pub const BuiltTile = struct {
    size: DeviceSize,
    /// Tile texels (borrowed; copied by the atlas).
    bytes: []const u8,
};

pub const Atlas = struct {
    gpa: Allocator,
    options: Options,
    lists: [kind_count]TextureList = @splat(.{}),
    tiles: std.AutoHashMapUnmanaged(AtlasKey, AtlasTile) = .empty,
    uploads: std.ArrayList(Upload) = .empty,
    next_generation: u32 = 1,

    const kind_count = @typeInfo(AtlasTextureKind).@"enum".field_names.len;
    /// Empty texel kept right and below every tile so linear sampling never bleeds.
    const gutter = 1;

    pub const Options = struct {
        /// Size of a fresh texture (grown to fit larger tiles).
        default_size: DevicePixels = 1024,
        /// Device limit (`maxImageDimension2D` / `maxTextureDimension2D`).
        max_size: DevicePixels = 8192,
    };

    pub const Error = Allocator.Error || error{ TileTooLarge, InvalidTileData };

    const Texture = struct {
        size: DeviceSize,
        packer: ShelfAllocator,
        live: u32 = 0,
        generation: u32,
    };

    const TextureList = struct {
        textures: std.ArrayList(?Texture) = .empty,
        free_slots: std.ArrayList(u32) = .empty,
    };

    pub fn init(gpa: Allocator, options: Options) Atlas {
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *Atlas) void {
        self.clear();
        for (&self.lists) |*list| {
            list.textures.deinit(self.gpa);
            list.free_slots.deinit(self.gpa);
        }
        self.tiles.deinit(self.gpa);
        self.uploads.deinit(self.gpa);
        self.* = undefined;
    }

    /// Drop every texture, tile and pending upload (zui `WgpuAtlas::clear`).
    pub fn clear(self: *Atlas) void {
        for (&self.lists) |*list| {
            for (list.textures.items) |*slot| if (slot.*) |*t| t.packer.deinit(self.gpa);
            list.textures.clearRetainingCapacity();
            list.free_slots.clearRetainingCapacity();
        }
        self.tiles.clearRetainingCapacity();
        self.clearUploads();
    }

    /// Cached tile for `key`, if any.
    pub fn get(self: *const Atlas, key: AtlasKey) ?AtlasTile {
        return self.tiles.get(key);
    }

    /// gpui `PlatformAtlas::get_or_insert_with`. On a miss calls
    /// `builder.build()`, which returns `!?BuiltTile` (null: nothing to draw,
    /// e.g. an empty glyph), then allocates space and queues the upload.
    pub fn getOrInsertWith(self: *Atlas, key: AtlasKey, builder: anytype) !?AtlasTile {
        if (self.tiles.get(key)) |tile| return tile;
        const built: BuiltTile = (try builder.build()) orelse return null;
        return try self.insert(key, built.size, built.bytes);
    }

    /// Allocate a tile for `key` and queue `bytes` for upload. Replaces any existing tile.
    pub fn insert(self: *Atlas, key: AtlasKey, size: DeviceSize, bytes: []const u8) Error!AtlasTile {
        const kind = key.textureKind();
        const expected = @as(usize, @intCast(@max(size.width, 0))) * @as(usize, @intCast(@max(size.height, 0))) * kind.bytesPerPixel();
        if (size.width <= 0 or size.height <= 0 or bytes.len != expected) return error.InvalidTileData;
        self.remove(key);

        try self.tiles.ensureUnusedCapacity(self.gpa, 1);
        try self.uploads.ensureUnusedCapacity(self.gpa, 1);
        const data = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(data);
        const tile = try self.allocate(kind, size);
        self.tiles.putAssumeCapacity(key, tile);
        self.uploads.appendAssumeCapacity(.{ .texture_id = tile.texture_id, .bounds = tile.bounds, .data = data });
        return tile;
    }

    /// gpui `PlatformAtlas::remove`: free the tile's space; a texture with no
    /// remaining tiles is released (its slot becomes reusable).
    pub fn remove(self: *Atlas, key: AtlasKey) void {
        const kv = self.tiles.fetchRemove(key) orelse return;
        const id = kv.value.texture_id;
        const list = &self.lists[@backingInt(id.kind)];
        if (id.index >= list.textures.items.len) return;
        const slot = &list.textures.items[id.index];
        const texture = &(slot.* orelse return);
        // Deallocation only fails to grow a free-span list; the space then just stays used.
        texture.packer.deallocate(self.gpa, kv.value.tile_id) catch {};
        texture.live -= 1;
        if (texture.live == 0) {
            texture.packer.deinit(self.gpa);
            slot.* = null;
            list.free_slots.append(self.gpa, id.index) catch {};
            var i: usize = 0;
            while (i < self.uploads.items.len) {
                if (self.uploads.items[i].texture_id.eql(id)) {
                    self.gpa.free(self.uploads.orderedRemove(i).data);
                } else i += 1;
            }
        }
    }

    /// Remove every frame of an image (zui `Window::drop_image`, used by `ImageSource::evict`).
    pub fn evictImage(self: *Atlas, image_id: u64, frame_count: u32) void {
        for (0..frame_count) |frame| self.remove(.{ .image = .{ .image_id = image_id, .frame_index = @intCast(frame) } });
    }

    /// Number of texture slots (live or free) for `kind`; iterate `0..textureSlots(kind)` with `textureInfo`.
    pub fn textureSlots(self: *const Atlas, kind: AtlasTextureKind) u32 {
        return @intCast(self.lists[@backingInt(kind)].textures.items.len);
    }

    /// The live texture in a slot, or null if the slot is free.
    pub fn textureInfo(self: *const Atlas, id: AtlasTextureId) ?TextureInfo {
        const list = &self.lists[@backingInt(id.kind)];
        if (id.index >= list.textures.items.len) return null;
        const t = list.textures.items[id.index] orelse return null;
        return .{ .id = id, .size = t.size, .generation = t.generation };
    }

    /// Texel copies queued since the last `clearUploads`, in insertion order.
    pub fn pendingUploads(self: *const Atlas) []const Upload {
        return self.uploads.items;
    }

    /// Free the pending uploads once the backend has copied them.
    pub fn clearUploads(self: *Atlas) void {
        for (self.uploads.items) |u| self.gpa.free(u.data);
        self.uploads.clearRetainingCapacity();
    }

    fn allocate(self: *Atlas, kind: AtlasTextureKind, size: DeviceSize) Error!AtlasTile {
        const list = &self.lists[@backingInt(kind)];
        // Newest textures first, like zui.
        var i = list.textures.items.len;
        while (i > 0) {
            i -= 1;
            if (list.textures.items[i]) |*t| {
                if (try allocateIn(self.gpa, t, @intCast(i), kind, size)) |tile| return tile;
            }
        }
        const index = try self.pushTexture(kind, size);
        const t = &list.textures.items[index].?;
        return (try allocateIn(self.gpa, t, index, kind, size)) orelse error.TileTooLarge;
    }

    fn allocateIn(gpa: Allocator, t: *Texture, index: u32, kind: AtlasTextureKind, size: DeviceSize) Allocator.Error!?AtlasTile {
        const w = if (size.width + gutter <= t.size.width) size.width + gutter else size.width;
        const h = if (size.height + gutter <= t.size.height) size.height + gutter else size.height;
        const a = (try t.packer.allocate(gpa, w, h)) orelse return null;
        t.live += 1;
        return .{
            .texture_id = .{ .index = index, .kind = kind },
            .tile_id = a.id,
            .padding = 0,
            .bounds = .{ .origin = a.origin, .size = size },
        };
    }

    fn pushTexture(self: *Atlas, kind: AtlasTextureKind, min_size: DeviceSize) Error!u32 {
        const max = self.options.max_size;
        if (min_size.width > max or min_size.height > max) return error.TileTooLarge;
        const size: DeviceSize = .{
            .width = @min(max, @max(self.options.default_size, min_size.width)),
            .height = @min(max, @max(self.options.default_size, min_size.height)),
        };
        const list = &self.lists[@backingInt(kind)];
        try list.textures.ensureUnusedCapacity(self.gpa, 1);
        const texture: Texture = .{ .size = size, .packer = .init(size), .generation = self.next_generation };
        self.next_generation +%= 1;
        if (list.free_slots.pop()) |slot| {
            list.textures.items[slot] = texture;
            return slot;
        }
        list.textures.appendAssumeCapacity(texture);
        return @intCast(list.textures.items.len - 1);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn imageKey(id: u64) AtlasKey {
    return .{ .image = .{ .image_id = id } };
}

fn sz(w: i32, h: i32) DeviceSize {
    return .{ .width = w, .height = h };
}

fn insertZeroed(atlas: *Atlas, key: AtlasKey, size: DeviceSize) !AtlasTile {
    const bytes = try testing.allocator.alloc(u8, @intCast(size.width * size.height * @as(i32, @intCast(key.textureKind().bytesPerPixel()))));
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);
    return atlas.insert(key, size, bytes);
}

test "shelf allocator packs without overlap and reuses freed space" {
    const gpa = testing.allocator;
    var packer: ShelfAllocator = .init(sz(256, 256));
    defer packer.deinit(gpa);
    var rects: std.ArrayList(DeviceBounds) = .empty;
    defer rects.deinit(gpa);
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(42);
    const rand = prng.random();
    while (true) {
        const w = rand.intRangeAtMost(i32, 4, 40);
        const h = rand.intRangeAtMost(i32, 4, 40);
        const a = (try packer.allocate(gpa, w, h)) orelse break;
        try rects.append(gpa, .{ .origin = a.origin, .size = sz(w, h) });
        try ids.append(gpa, a.id);
    }
    try testing.expect(rects.items.len > 20);
    for (rects.items, 0..) |a, i| {
        try testing.expect(a.origin.x >= 0 and a.right() <= 256 and a.origin.y >= 0 and a.bottom() <= 256);
        for (rects.items[i + 1 ..]) |b| try testing.expect(!a.intersects(b));
    }
    for (ids.items) |id| try packer.deallocate(gpa, id);
    try testing.expectEqual(@as(i32, 0), packer.next_y);
    const full = (try packer.allocate(gpa, 256, 256)).?;
    try testing.expectEqual(@as(i32, 0), full.origin.x);
}

test "atlas caches tiles and only builds on a miss" {
    var atlas: Atlas = .init(testing.allocator, .{});
    defer atlas.deinit();
    const Builder = struct {
        calls: u32 = 0,
        pixels: [4]u8 = .{ 1, 2, 3, 4 },
        fn build(self: *@This()) !?BuiltTile {
            self.calls += 1;
            return .{ .size = sz(2, 2), .bytes = &self.pixels };
        }
    };
    var b: Builder = .{};
    const key: AtlasKey = .{ .glyph = .init(1, 65, 14, 2) };
    try testing.expectEqual(AtlasTextureKind.monochrome, key.textureKind());
    const t1 = (try atlas.getOrInsertWith(key, &b)).?;
    const t2 = (try atlas.getOrInsertWith(key, &b)).?;
    try testing.expectEqual(@as(u32, 1), b.calls);
    try testing.expectEqual(t1, t2);
    try testing.expectEqual(@as(usize, 1), atlas.pendingUploads().len);
    try testing.expectEqualSlices(u8, &b.pixels, atlas.pendingUploads()[0].data);
    atlas.clearUploads();

    const Empty = struct {
        fn build(_: @This()) !?BuiltTile {
            return null;
        }
    };
    try testing.expect((try atlas.getOrInsertWith(imageKey(9), Empty{})) == null);
    try testing.expectError(error.InvalidTileData, atlas.insert(imageKey(9), sz(2, 2), &.{ 0, 0 }));
}

test "atlas grows by adding textures and keeps kinds separate" {
    var atlas: Atlas = .init(testing.allocator, .{ .default_size = 128, .max_size = 512 });
    defer atlas.deinit();
    const a = try insertZeroed(&atlas, imageKey(1), sz(100, 100));
    const b = try insertZeroed(&atlas, imageKey(2), sz(100, 100));
    try testing.expect(!a.texture_id.eql(b.texture_id));
    try testing.expectEqual(@as(u32, 2), atlas.textureSlots(.polychrome));
    // Larger than the default size: gets its own, bigger texture.
    const big = try insertZeroed(&atlas, imageKey(3), sz(300, 200));
    try testing.expectEqual(sz(300, 200), atlas.textureInfo(big.texture_id).?.size);
    try testing.expectError(error.TileTooLarge, insertZeroed(&atlas, imageKey(4), sz(600, 10)));
    const g = try insertZeroed(&atlas, .{ .glyph = .init(1, 1, 12, 1) }, sz(8, 8));
    try testing.expectEqual(AtlasTextureKind.monochrome, g.texture_id.kind);
    try testing.expectEqual(@as(u32, 0), g.texture_id.index);
}

test "remove frees space for reuse and releases unreferenced textures" {
    var atlas: Atlas = .init(testing.allocator, .{});
    defer atlas.deinit();
    // Mirrors zui's `remove_deallocates_tile_space_for_reuse`.
    const keeper = try insertZeroed(&atlas, imageKey(1), sz(64, 64));
    const tile_a = try insertZeroed(&atlas, imageKey(2), sz(700, 700));
    try testing.expect(keeper.texture_id.eql(tile_a.texture_id));
    atlas.remove(imageKey(2));
    const tile_b = try insertZeroed(&atlas, imageKey(3), sz(700, 700));
    try testing.expect(tile_b.texture_id.eql(keeper.texture_id));
    try testing.expect(atlas.get(imageKey(2)) == null);

    // Removing the last tile frees the texture and drops its pending uploads.
    const gen = atlas.textureInfo(keeper.texture_id).?.generation;
    atlas.remove(imageKey(1));
    atlas.remove(imageKey(3));
    try testing.expect(atlas.textureInfo(keeper.texture_id) == null);
    try testing.expectEqual(@as(usize, 0), atlas.pendingUploads().len);
    // The slot is reused with a new generation.
    const again = try insertZeroed(&atlas, imageKey(5), sz(4, 4));
    try testing.expectEqual(keeper.texture_id.index, again.texture_id.index);
    try testing.expect(atlas.textureInfo(again.texture_id).?.generation != gen);

    // evictImage removes every frame.
    _ = try insertZeroed(&atlas, .{ .image = .{ .image_id = 7, .frame_index = 0 } }, sz(4, 4));
    _ = try insertZeroed(&atlas, .{ .image = .{ .image_id = 7, .frame_index = 1 } }, sz(4, 4));
    atlas.evictImage(7, 2);
    try testing.expect(atlas.get(.{ .image = .{ .image_id = 7, .frame_index = 1 } }) == null);
}
