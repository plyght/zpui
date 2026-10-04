//! Metal renderer, ported from zui's `MetalRenderer`
//! (crates/gpui_macos/src/metal_renderer.rs).
//!
//! Draws a `Scene` batch by batch with one pipeline per primitive kind, into
//! either a `CAMetalLayer` drawable (windows) or an offscreen texture
//! (`readPixels`). Paths rasterize into a 4x MSAA intermediate and are then
//! composited; backdrop blurs break the render pass, snapshot the padded
//! region, blur it with `MPSImageGaussianBlur` and paint it back.
//!
//! Compositing: shaders output straight alpha, blended with
//! `SourceAlpha, OneMinusSourceAlpha` on RGB and `One, OneMinusSourceAlpha` on
//! alpha, so the framebuffer accumulates premultiplied source-over.
//!
//! Instance data lives in pooled buffers (see `instance_buffer_pool.zig`).
//! Completed frames are reclaimed by polling command-buffer status rather than
//! completion-handler blocks, which keeps everything on the calling thread.
//! Large scratch textures (path intermediates, blur snapshots) are released
//! after `backdrop.scratch_release_after_frames` frames without use.

const std = @import("std");
const Allocator = std.mem.Allocator;

const objc = @import("../../platform/mac/objc.zig");
const mtl = @import("../../platform/mac/metal.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const geometry = @import("../../geometry.zig");
const color = @import("../../color.zig");
const renderer = @import("../renderer.zig");
const pool_mod = @import("instance_buffer_pool.zig");
const backdrop = @import("backdrop.zig");

const log = std.log.scoped(.metal);

const id = objc.id;
const NSUInteger = objc.NSUInteger;
const Scene = scene_mod.Scene;
const DeviceSize = geometry.Size(geometry.DevicePixels);
const Atlas = atlas_mod.Atlas;
const AtlasTextureId = atlas_mod.AtlasTextureId;
const AtlasTextureKind = atlas_mod.AtlasTextureKind;

/// Shader source, compiled at startup with `newLibraryWithSource`.
const shader_source = @embedFile("shaders.metal");

/// 4x MSAA for paths; every Metal device supports it.
const path_sample_count = 4;
/// Offscreen frames committed without readback before the CPU waits on the oldest.
const max_frames_in_flight = 3;
/// Metal's maximum 2D texture size on all modern Apple GPUs.
const max_atlas_size = 16384;
const target_format: mtl.PixelFormat = .bgra8_unorm;

/// Buffer/texture argument indices; must match the enums in shaders.metal.
const Index = struct {
    // Shared by quads, shadows, underlines, sprites, path sprites, blurs, surfaces.
    const vertices = 0;
    const instances = 1;
    const viewport_size = 2;
    // Sprites / path sprites.
    const atlas_texture_size = 3;
    const atlas_texture = 4;
    // Backdrop blur.
    const blur_source_texture = 3;
    const blur_source_rect = 4;
    // Path rasterization.
    const path_vertices = 0;
    const path_viewport_size = 1;
};

pub const Error = error{
    NoMetalDevice,
    ShaderCompilationFailed,
    PipelineCreationFailed,
    ResourceCreationFailed,
    CommandBufferFailed,
    NoDrawable,
    ReadbackUnsupported,
    UnsupportedSurface,
    GpuError,
};

const blend_straight: mtl.Blend = .{
    .src_rgb = .source_alpha,
    .src_alpha = .one,
    .dst_rgb = .one_minus_source_alpha,
    // Alpha accumulates as `src.a + dst.a * (1 - src.a)`; an additive `One`
    // would saturate translucent destinations (dark rings on transparent windows).
    .dst_alpha = .one_minus_source_alpha,
};

const blend_premultiplied: mtl.Blend = .{
    .src_rgb = .one,
    .src_alpha = .one,
    .dst_rgb = .one_minus_source_alpha,
    .dst_alpha = .one_minus_source_alpha,
};

const Pipelines = struct {
    path_rasterization: id,
    path_sprites: id,
    shadows: id,
    backdrop_blur: id,
    quads: id,
    underlines: id,
    monochrome_sprites: id,
    polychrome_sprites: id,
    surfaces: id,

    fn deinit(self: *Pipelines) void {
        inline for (@typeInfo(Pipelines).@"struct".field_names) |name| @field(self, name).release();
    }
};

/// Creates/destroys instance buffers for the pool.
const BufferGpu = struct {
    device: id,
    unified_memory: bool,

    pub fn create(self: *BufferGpu, size: usize) Error!id {
        return mtl.Device.newBuffer(self.device, size, sharedOrManaged(self.unified_memory)) orelse error.ResourceCreationFailed;
    }

    pub fn destroy(_: *BufferGpu, buffer: id) void {
        buffer.release();
    }
};

/// Snapshot (blit destination / gaussian source) + blurred result.
const ScratchPair = struct { scratch: id, blurred: id };

/// Creates/destroys blur scratch textures and gaussian kernels.
const BlurGpu = struct {
    device: id,

    pub fn create(self: *BlurGpu, width: u64, height: u64, format: mtl.PixelFormat) Error!ScratchPair {
        const scratch = try newTexture(self.device, .{
            .width = width,
            .height = height,
            .format = format,
            .usage = mtl.TextureUsage.shader_read,
            .storage = .private,
        });
        errdefer scratch.release();
        // The gaussian kernel writes via compute: the destination needs ShaderWrite.
        const blurred = try newTexture(self.device, .{
            .width = width,
            .height = height,
            .format = format,
            .usage = mtl.TextureUsage.shader_read | mtl.TextureUsage.shader_write,
            .storage = .private,
        });
        return .{ .scratch = scratch, .blurred = blurred };
    }

    pub fn destroy(_: *BlurGpu, pair: ScratchPair) void {
        pair.scratch.release();
        pair.blurred.release();
    }

    pub fn createKernel(self: *BlurGpu, sigma: f32) Error!id {
        return mtl.GaussianBlur.new(self.device, sigma) orelse error.ResourceCreationFailed;
    }

    pub fn destroyKernel(_: *BlurGpu, kernel: id) void {
        kernel.release();
    }
};

const InstancePool = pool_mod.InstanceBufferPool(id, BufferGpu);
const ScratchCache = backdrop.ScratchCache(ScratchPair, mtl.PixelFormat, BlurGpu);
const KernelCache = backdrop.KernelCache(id, BlurGpu);

const InFlight = struct { command_buffer: id, buffer: InstancePool.Acquired };

const AtlasTexture = struct { texture: id, generation: u32, size: DeviceSize };

/// The instance buffer being filled for one frame.
const Frame = struct {
    buffer: id,
    contents: [*]u8,
    size: usize,
    offset: usize = 0,

    /// Reserve `len` bytes at a 256-byte aligned offset ("Metal happy").
    fn reserve(self: *Frame, len: usize) error{InstanceBufferOverflow}!struct { offset: usize, bytes: []u8 } {
        const start = std.mem.alignForward(usize, self.offset, 256);
        if (start + len > self.size) return error.InstanceBufferOverflow;
        self.offset = start + len;
        return .{ .offset = start, .bytes = self.contents[start..][0..len] };
    }

    fn write(self: *Frame, bytes: []const u8) error{InstanceBufferOverflow}!usize {
        const r = try self.reserve(bytes.len);
        @memcpy(r.bytes, bytes);
        return r.offset;
    }

    /// Typed view of reserved bytes. Offsets are 256-aligned and the buffer is
    /// page-aligned, so 4-byte-aligned GPU structs can be written in place.
    fn reserveSlice(self: *Frame, comptime T: type, count: usize) error{InstanceBufferOverflow}!struct { offset: usize, items: []T } {
        const r = try self.reserve(count * @sizeOf(T));
        const ptr: [*]T = @ptrCast(@alignCast(r.bytes.ptr));
        return .{ .offset = r.offset, .items = ptr[0..count] };
    }
};

pub const MetalRenderer = struct {
    gpa: Allocator,
    device: id,
    command_queue: id,
    library: id,
    pipelines: Pipelines,
    /// Six vertices of the unit quad as two triangles.
    unit_vertices: id,
    is_apple_gpu: bool,
    is_unified_memory: bool,
    /// Opaque targets clear to alpha 1 and let the compositor skip blending.
    is_opaque: bool,
    presents_with_transaction: bool = false,
    /// Window mode: the `CAMetalLayer` presented to (retained).
    metal_layer: ?id,
    /// zui `new_overlay`: a second, transparent `CAMetalLayer` (retained) drawn with the
    /// same device, pipelines and sprite atlas (`createOverlayLayer` / `drawOverlay`).
    overlay_layer: ?id = null,
    /// [liquid-glass] The top plane: a third transparent layer above floating native
    /// glass (`createTopLayer` / `drawTop`).
    top_layer: ?id = null,
    /// [glass-lab] Diagnostics: copy each window plane's next drawable to the CPU
    /// (`armLayerCapture` / `takeLayerCapture`), to separate what zpui drew from
    /// what AppKit composited on top (native glass).
    layer_capture_armed: bool = false,
    drawing_plane: Plane = .main,
    layer_captures: [3]?LayerCapture = .{ null, null, null },
    /// Offscreen mode: the render target (private storage).
    offscreen_target: ?id = null,
    /// Shared buffer offscreen targets are blitted into by `readPixels`.
    readback: ?id = null,
    size: DeviceSize,

    buffer_gpu: BufferGpu,
    instance_buffers: InstancePool = .{},
    in_flight: std.ArrayList(InFlight) = .empty,

    sprite_atlas: Atlas,
    atlas_textures: [atlas_kind_count]std.ArrayList(?AtlasTexture) = @splat(.empty),

    path_intermediate: ?id = null,
    path_intermediate_msaa: ?id = null,

    blur_gpu: BlurGpu,
    backdrop_textures: ScratchCache = .{},
    backdrop_kernels: KernelCache = .{},
    /// `MPSSupportsMTLDevice`; without it blurs composite the unblurred snapshot.
    mps_supported: bool,
    /// Consecutive frames rendered without any backdrop blur / any path.
    blur_free_frames: u32 = 0,
    path_free_frames: u32 = 0,
    warned_unsupported: std.EnumSet(enum { surfaces, subpixel, mps }) = .empty,

    const atlas_kind_count = @typeInfo(AtlasTextureKind).@"enum".field_names.len;

    /// [glass-lab] The window planes (main surface, overlay plane, top plane).
    pub const Plane = enum(u2) { main, overlay, top };
    /// [glass-lab] A plane's drawable as presented: premultiplied RGBA8, rows top-down.
    pub const LayerCapture = struct { width: u32, height: u32, rgba: []u8 };

    /// [glass-lab] Capture every plane drawn from now on (until `disarmLayerCapture`);
    /// drops older captures.
    pub fn armLayerCapture(self: *MetalRenderer) void {
        for (&self.layer_captures) |*c| if (c.*) |cap| {
            self.gpa.free(cap.rgba);
            c.* = null;
        };
        self.layer_capture_armed = true;
    }

    pub fn disarmLayerCapture(self: *MetalRenderer) void {
        self.layer_capture_armed = false;
    }

    /// [glass-lab] The latest capture of `plane` (caller owns `rgba`, gpa), or null.
    pub fn takeLayerCapture(self: *MetalRenderer, plane: Plane) ?LayerCapture {
        const c = self.layer_captures[@backingInt(plane)] orelse return null;
        self.layer_captures[@backingInt(plane)] = null;
        return c;
    }

    /// [glass-lab] Encode a copy of `texture` into a new shared buffer (returned, +1).
    fn encodeLayerCapture(self: *MetalRenderer, command_buffer: id, texture: id, viewport: DeviceSize) ?id {
        const width: usize = @intCast(viewport.width);
        const height: usize = @intCast(viewport.height);
        const buf = mtl.Device.newBuffer(self.device, width * height * 4, mtl.ResourceOptions.storage_mode_shared) orelse return null;
        const blit = mtl.CommandBuffer.blitCommandEncoder(command_buffer) orelse {
            buf.release();
            return null;
        };
        mtl.BlitEncoder.copyTextureToBuffer(blit, texture, .{ .width = width, .height = height }, buf, width * 4);
        mtl.BlitEncoder.endEncoding(blit);
        return buf;
    }

    fn finishLayerCapture(self: *MetalRenderer, command_buffer: id, buf: id, viewport: DeviceSize) void {
        defer buf.release();
        mtl.CommandBuffer.waitUntilCompleted(command_buffer);
        if (mtl.CommandBuffer.status(command_buffer) != .completed) return;
        const width: usize = @intCast(viewport.width);
        const height: usize = @intCast(viewport.height);
        const len = width * height * 4;
        const out = self.gpa.alloc(u8, len) catch return;
        bgraToRgba(out, mtl.Buffer.contents(buf)[0..len]);
        const slot = &self.layer_captures[@backingInt(self.drawing_plane)];
        if (slot.*) |old| self.gpa.free(old.rgba);
        slot.* = .{ .width = @intCast(width), .height = @intCast(height), .rgba = out };
    }

    pub fn init(gpa: Allocator, options: renderer.Options) !MetalRenderer {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const device = selectDevice() orelse return error.NoMetalDevice;
        errdefer device.release();
        const is_unified_memory = mtl.Device.hasUnifiedMemory(device);
        // Apple GPU families support memoryless render targets and shared textures.
        const is_apple_gpu = mtl.Device.supportsFamily(device, .apple1);

        const library = try compileLibrary(device);
        errdefer library.release();
        var pipelines = try buildPipelines(device, library);
        errdefer pipelines.deinit();

        const command_queue = mtl.Device.newCommandQueue(device) orelse return error.ResourceCreationFailed;
        errdefer command_queue.release();

        const unit: [6][2]f32 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } };
        const unit_vertices = mtl.Device.newBufferWithBytes(device, &unit, @sizeOf(@TypeOf(unit)), sharedOrManaged(is_unified_memory)) orelse
            return error.ResourceCreationFailed;
        errdefer unit_vertices.release();

        var self: MetalRenderer = .{
            .gpa = gpa,
            .device = device,
            .command_queue = command_queue,
            .library = library,
            .pipelines = pipelines,
            .unit_vertices = unit_vertices,
            .is_apple_gpu = is_apple_gpu,
            .is_unified_memory = is_unified_memory,
            .is_opaque = !options.transparent,
            .metal_layer = null,
            .size = .zero,
            .buffer_gpu = .{ .device = device, .unified_memory = is_unified_memory },
            .sprite_atlas = .init(gpa, .{
                .default_size = options.atlas.default_size,
                .max_size = @min(options.atlas.max_size, max_atlas_size),
            }),
            .blur_gpu = .{ .device = device },
            .mps_supported = objc.fromBOOL(mtl.MPSSupportsMTLDevice(device)),
        };
        errdefer self.sprite_atlas.deinit();

        if (options.surface) |surface| switch (surface) {
            .metal_layer => |existing| self.metal_layer = try self.configureLayer(existing, options.transparent),
            .vulkan => return error.UnsupportedSurface,
        };
        errdefer if (self.metal_layer) |l| l.release();
        try self.resize(options.size);
        return self;
    }

    pub fn deinit(self: *MetalRenderer) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        for (self.in_flight.items) |f| {
            mtl.CommandBuffer.waitUntilCompleted(f.command_buffer);
            f.command_buffer.release();
            f.buffer.buffer.release();
        }
        self.in_flight.deinit(self.gpa);
        self.instance_buffers.deinit(self.gpa, &self.buffer_gpu);
        for (&self.atlas_textures) |*list| {
            for (list.items) |slot| if (slot) |t| t.texture.release();
            list.deinit(self.gpa);
        }
        self.sprite_atlas.deinit();
        self.releaseBackdropResources();
        self.backdrop_textures.deinit(self.gpa, &self.blur_gpu);
        self.releasePathIntermediates();
        if (self.offscreen_target) |t| t.release();
        if (self.readback) |b| b.release();
        if (self.metal_layer) |l| l.release();
        if (self.overlay_layer) |l| l.release();
        if (self.top_layer) |l| l.release();
        for (self.layer_captures) |c| if (c) |cap| self.gpa.free(cap.rgba);
        self.pipelines.deinit();
        self.unit_vertices.release();
        self.library.release();
        self.command_queue.release();
        self.device.release();
        self.* = undefined;
    }

    /// The sprite atlas. Rasterize into it; the renderer uploads pending tiles each frame.
    pub fn atlas(self: *MetalRenderer) *Atlas {
        return &self.sprite_atlas;
    }

    /// The `CAMetalLayer*` in window mode (attach it to an NSView), else null.
    pub fn layer(self: *const MetalRenderer) ?*anyopaque {
        return if (self.metal_layer) |l| @ptrCast(l) else null;
    }

    /// Present synchronously within a Core Animation transaction (live resize).
    pub fn setPresentsWithTransaction(self: *MetalRenderer, value: bool) void {
        self.presents_with_transaction = value;
        if (self.metal_layer) |l| mtl.Layer.setPresentsWithTransaction(l, value);
        if (self.overlay_layer) |l| mtl.Layer.setPresentsWithTransaction(l, value);
        if (self.top_layer) |l| mtl.Layer.setPresentsWithTransaction(l, value);
    }

    /// Create (once) the transparent overlay `CAMetalLayer` (zui `new_overlay`): it
    /// resolves the same atlas tiles as the main layer. Returns the layer to host in a view.
    pub fn createOverlayLayer(self: *MetalRenderer) !*anyopaque {
        if (self.overlay_layer) |l| return @ptrCast(l);
        const l = try self.configureLayer(null, true);
        mtl.Layer.setPresentsWithTransaction(l, self.presents_with_transaction);
        self.overlay_layer = l;
        return @ptrCast(l);
    }

    /// [liquid-glass] Create (once) the top-plane layer (same device / atlas).
    pub fn createTopLayer(self: *MetalRenderer) !*anyopaque {
        if (self.top_layer) |l| return @ptrCast(l);
        const l = try self.configureLayer(null, true);
        mtl.Layer.setPresentsWithTransaction(l, self.presents_with_transaction);
        self.top_layer = l;
        return @ptrCast(l);
    }

    /// [liquid-glass] Render `scene` into the top layer (like `drawOverlay`).
    pub fn drawTop(self: *MetalRenderer, scene: *const Scene, viewport: DeviceSize, scale_factor: f32) !void {
        self.drawing_plane = .top;
        defer self.drawing_plane = .main;
        return self.drawTransparentLayer(self.top_layer orelse return error.NoTopLayer, scene, viewport, scale_factor);
    }

    /// Render `scene` into the overlay layer, cleared to transparent, and present it.
    pub fn drawOverlay(self: *MetalRenderer, scene: *const Scene, viewport: DeviceSize, scale_factor: f32) !void {
        self.drawing_plane = .overlay;
        defer self.drawing_plane = .main;
        return self.drawTransparentLayer(self.overlay_layer orelse return error.NoOverlayLayer, scene, viewport, scale_factor);
    }

    fn drawTransparentLayer(self: *MetalRenderer, overlay: id, scene: *const Scene, viewport: DeviceSize, scale_factor: f32) !void {
        if (viewport.width <= 0 or viewport.height <= 0) return;
        const size = mtl.Layer.drawableSize(overlay);
        const want: objc.CGSize = .{ .width = @floatFromInt(viewport.width), .height = @floatFromInt(viewport.height) };
        if (size.width != want.width or size.height != want.height) mtl.Layer.setDrawableSize(overlay, want);
        // Draw through the main path with the layer and opacity swapped in; `size`
        // matches the main drawable, so no resize (and no intermediate churn) happens.
        const saved_layer = self.metal_layer;
        const saved_opaque = self.is_opaque;
        self.metal_layer = overlay;
        self.is_opaque = false;
        defer {
            self.metal_layer = saved_layer;
            self.is_opaque = saved_opaque;
        }
        try self.drawScene(scene, viewport, scale_factor, color.transparent_black);
    }

    pub fn setTransparent(self: *MetalRenderer, transparent: bool) void {
        self.is_opaque = !transparent;
        if (self.metal_layer) |l| mtl.Layer.setOpaque(l, !transparent);
    }

    /// Resize the drawable (window) or the offscreen target. Drops the path
    /// intermediates; the next frame with paths recreates them.
    pub fn resize(self: *MetalRenderer, size: DeviceSize) !void {
        self.releasePathIntermediates();
        if (self.metal_layer) |l| {
            mtl.Layer.setDrawableSize(l, .{ .width = @floatFromInt(@max(size.width, 0)), .height = @floatFromInt(@max(size.height, 0)) });
        } else if (size.width != self.size.width or size.height != self.size.height or self.offscreen_target == null) {
            if (self.offscreen_target) |t| t.release();
            self.offscreen_target = null;
            if (size.width > 0 and size.height > 0) {
                self.offscreen_target = try newTexture(self.device, .{
                    .width = @intCast(size.width),
                    .height = @intCast(size.height),
                    .format = target_format,
                    .usage = mtl.TextureUsage.render_target | mtl.TextureUsage.shader_read,
                    .storage = .private,
                });
            }
        }
        self.size = size;
    }

    /// Render `scene` (in scaled/device pixels) and present it (window mode)
    /// or leave it in the offscreen target. `clear` is the straight-alpha
    /// background; opaque targets composite it over black.
    pub fn drawScene(
        self: *MetalRenderer,
        scene: *const Scene,
        viewport: DeviceSize,
        scale_factor: f32,
        clear: color.Hsla,
    ) !void {
        _ = scale_factor; // primitives are already in device pixels
        // Display-link callbacks need not coincide with an AppKit pool drain:
        // bound temporary encoders/drawables to this frame.
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        if (viewport.width <= 0 or viewport.height <= 0) return;
        if (viewport.width != self.size.width or viewport.height != self.size.height) try self.resize(viewport);

        self.reclaimCompleted();
        while (self.in_flight.items.len >= max_frames_in_flight) {
            mtl.CommandBuffer.waitUntilCompleted(self.in_flight.items[0].command_buffer);
            self.reclaimCompleted();
        }
        try self.syncAtlas();

        var drawable: ?id = null;
        const target = if (self.metal_layer) |l| blk: {
            drawable = mtl.Layer.nextDrawable(l) orelse {
                log.err("failed to retrieve next drawable ({d}x{d})", .{ viewport.width, viewport.height });
                return error.NoDrawable;
            };
            break :blk mtl.drawableTexture(drawable.?);
        } else self.offscreen_target.?;

        try self.in_flight.ensureUnusedCapacity(self.gpa, 1);
        while (true) {
            const acquired = try self.instance_buffers.acquire(&self.buffer_gpu);
            const command_buffer = self.encodeFrame(scene, acquired, target, viewport, clear) catch |err| switch (err) {
                error.InstanceBufferOverflow => {
                    self.instance_buffers.grow(&self.buffer_gpu) catch |grow_err| {
                        log.err("instance buffer size grew too large: {d}", .{self.instance_buffers.buffer_size});
                        self.instance_buffers.release(self.gpa, &self.buffer_gpu, acquired);
                        return grow_err;
                    };
                    log.info("increased instance buffer size to {d}", .{self.instance_buffers.buffer_size});
                    self.instance_buffers.release(self.gpa, &self.buffer_gpu, acquired);
                    continue;
                },
                else => {
                    self.instance_buffers.release(self.gpa, &self.buffer_gpu, acquired);
                    return err;
                },
            };

            if (drawable) |d| {
                // [glass-lab] Diagnostics readback of what this plane presents.
                const capture: ?id = if (self.layer_capture_armed) self.encodeLayerCapture(command_buffer, target, viewport) else null;
                if (self.presents_with_transaction) {
                    mtl.CommandBuffer.commit(command_buffer);
                    mtl.CommandBuffer.waitUntilScheduled(command_buffer);
                    mtl.drawablePresent(d);
                } else {
                    mtl.CommandBuffer.presentDrawable(command_buffer, d);
                    mtl.CommandBuffer.commit(command_buffer);
                }
                if (capture) |buf| self.finishLayerCapture(command_buffer, buf, viewport);
            } else {
                mtl.CommandBuffer.commit(command_buffer);
            }
            self.in_flight.appendAssumeCapacity(.{ .command_buffer = command_buffer.retain(), .buffer = acquired });
            return;
        }
    }

    /// Copy the offscreen target to CPU memory as tightly packed, premultiplied
    /// RGBA8, rows top-down (the shared `readPixels` contract). Waits for the GPU.
    /// Caller owns the returned slice.
    pub fn readPixels(self: *MetalRenderer, gpa: Allocator) ![]u8 {
        const target = self.offscreen_target orelse return error.ReadbackUnsupported;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const width: usize = @intCast(self.size.width);
        const height: usize = @intCast(self.size.height);
        const bytes_per_row = width * 4;
        const len = bytes_per_row * height;
        if (self.readback) |b| if (mtl.Buffer.length(b) < len) {
            b.release();
            self.readback = null;
        };
        if (self.readback == null) {
            self.readback = mtl.Device.newBuffer(self.device, len, mtl.ResourceOptions.storage_mode_shared) orelse
                return error.ResourceCreationFailed;
        }
        const readback = self.readback.?;

        // Same queue: executes after every previously committed frame.
        const command_buffer = mtl.CommandBuffer.fromQueue(self.command_queue) orelse return error.CommandBufferFailed;
        const blit = mtl.CommandBuffer.blitCommandEncoder(command_buffer) orelse return error.CommandBufferFailed;
        mtl.BlitEncoder.copyTextureToBuffer(blit, target, .{ .width = width, .height = height }, readback, bytes_per_row);
        mtl.BlitEncoder.endEncoding(blit);
        mtl.CommandBuffer.commit(command_buffer);
        mtl.CommandBuffer.waitUntilCompleted(command_buffer);
        if (mtl.CommandBuffer.status(command_buffer) != .completed) {
            log.err("readback failed: {s}", .{objc.errorDescription(mtl.CommandBuffer.@"error"(command_buffer))});
            return error.GpuError;
        }
        self.reclaimCompleted();

        const out = try gpa.alloc(u8, len);
        bgraToRgba(out, mtl.Buffer.contents(readback)[0..len]);
        return out;
    }

    /// API validation errors seen so far. Metal validation reports through the
    /// Metal API Validation layer (MTL_DEBUG_LAYER=1) itself, so always 0.
    pub fn validationErrors(self: *const MetalRenderer) u32 {
        _ = self;
        return 0;
    }

    /// Release scratch resources the last frame did not use (a parked window
    /// may render no more frames). Mirrors zui `trim_idle_resources`.
    pub fn trimIdleResources(self: *MetalRenderer) void {
        if (self.backdrop_textures.trimUnused(&self.blur_gpu)) self.releaseBackdropResources();
        if (self.path_free_frames > 0) self.releasePathIntermediates();
    }

    // -----------------------------------------------------------------------
    // Frame encoding
    // -----------------------------------------------------------------------

    const EncodeError = Error || Allocator.Error || error{InstanceBufferOverflow};

    /// Port of `draw_primitives_to_texture`. Returns the (autoreleased) command
    /// buffer, ready to commit. On error every encoder has been ended.
    fn encodeFrame(
        self: *MetalRenderer,
        scene: *const Scene,
        acquired: InstancePool.Acquired,
        target: id,
        viewport: DeviceSize,
        clear: color.Hsla,
    ) EncodeError!id {
        const command_buffer = mtl.CommandBuffer.fromQueue(self.command_queue) orelse return error.CommandBufferFailed;
        var frame: Frame = .{
            .buffer = acquired.buffer,
            .contents = mtl.Buffer.contents(acquired.buffer),
            .size = acquired.size,
        };

        // Big scratch textures are only worth holding while in use. Releasing
        // is safe with frames in flight: command buffers retain their resources.
        self.backdrop_textures.beginFrame();
        if (scene.backdrop_blurs.items.len == 0) {
            self.blur_free_frames +|= 1;
            if (self.blur_free_frames >= backdrop.scratch_release_after_frames) self.releaseBackdropResources();
        } else self.blur_free_frames = 0;
        if (scene.paths.items.len == 0) {
            self.path_free_frames +|= 1;
            if (self.path_free_frames >= backdrop.scratch_release_after_frames) self.releasePathIntermediates();
        } else {
            self.path_free_frames = 0;
            try self.ensurePathIntermediates(viewport);
        }

        var encoder: ?id = try beginPass(command_buffer, target, viewport, .{ .clear = self.clearColor(clear) });
        errdefer if (encoder) |e| mtl.RenderEncoder.endEncoding(e);

        const blurs = scene.backdrop_blurs.items;
        var blur_index: usize = 0;
        var batches = scene.batches();
        while (batches.next()) |batch| {
            // Backdrop blurs interleave by draw order OUTSIDE the batch stream.
            const first_order = batch.firstOrder(scene);
            while (blur_index < blurs.len and blurs[blur_index].order <= first_order) : (blur_index += 1) {
                try self.applyBackdropBlur(command_buffer, &encoder, &frame, target, viewport, blurs[blur_index]);
            }
            const enc = encoder.?;
            const vp = &viewport;
            switch (batch) {
                .shadow => |r| try self.drawInstances(enc, &frame, self.pipelines.shadows, scene_mod.Shadow, scene.shadows.items[r.start..r.end], vp, null),
                .quad => |r| try self.drawInstances(enc, &frame, self.pipelines.quads, scene_mod.Quad, scene.quads.items[r.start..r.end], vp, null),
                .underline => |r| try self.drawInstances(enc, &frame, self.pipelines.underlines, scene_mod.Underline, scene.underlines.items[r.start..r.end], vp, null),
                .monochrome_sprite => |s| if (self.atlasTexture(s.texture_id)) |t| {
                    try self.drawInstances(enc, &frame, self.pipelines.monochrome_sprites, scene_mod.MonochromeSprite, scene.monochrome_sprites.items[s.range.start..s.range.end], vp, t);
                },
                .polychrome_sprite => |s| if (self.atlasTexture(s.texture_id)) |t| {
                    try self.drawInstances(enc, &frame, self.pipelines.polychrome_sprites, scene_mod.PolychromeSprite, scene.polychrome_sprites.items[s.range.start..s.range.end], vp, t);
                },
                .path => |r| {
                    const paths = scene.paths.items[r.start..r.end];
                    mtl.RenderEncoder.endEncoding(enc);
                    encoder = null;
                    const drawn = try self.drawPathsToIntermediate(command_buffer, &frame, paths, viewport);
                    encoder = try beginPass(command_buffer, target, viewport, .load);
                    if (drawn) try self.drawPathsFromIntermediate(encoder.?, &frame, paths, viewport);
                },
                // zui's Metal backend never produces subpixel sprites (wgpu-only feature).
                .subpixel_sprite => self.warnOnce(.subpixel, "subpixel sprites are not supported on Metal; skipped"),
                // TODO: CVPixelBuffer surfaces (CVMetalTextureCache) are not ported yet.
                .surface => self.warnOnce(.surfaces, "surfaces are not supported yet; skipped"),
            }
        }
        // Blurs after the last batch still blur what was painted below them.
        while (blur_index < blurs.len) : (blur_index += 1) {
            try self.applyBackdropBlur(command_buffer, &encoder, &frame, target, viewport, blurs[blur_index]);
        }

        mtl.RenderEncoder.endEncoding(encoder.?);
        encoder = null;

        // Managed buffers must be flushed to the GPU.
        if (!self.is_unified_memory) mtl.Buffer.didModifyRange(frame.buffer, .{ .location = 0, .length = frame.offset });
        self.instance_buffers.noteUsage(&self.buffer_gpu, frame.offset);
        return command_buffer;
    }

    const SpriteTexture = AtlasTexture;

    /// One instanced draw of `items` with the shared buffer layout
    /// (unit vertices, instances, viewport size[, atlas size, atlas texture]).
    fn drawInstances(
        self: *MetalRenderer,
        enc: id,
        frame: *Frame,
        pipeline: id,
        comptime T: type,
        items: []const T,
        viewport: *const DeviceSize,
        sprite_texture: ?SpriteTexture,
    ) error{InstanceBufferOverflow}!void {
        if (items.len == 0) return;
        const offset = try frame.write(std.mem.sliceAsBytes(items));
        mtl.RenderEncoder.setPipeline(enc, pipeline);
        mtl.RenderEncoder.setVertexBuffer(enc, self.unit_vertices, 0, Index.vertices);
        mtl.RenderEncoder.setVertexBuffer(enc, frame.buffer, offset, Index.instances);
        mtl.RenderEncoder.setFragmentBuffer(enc, frame.buffer, offset, Index.instances);
        mtl.RenderEncoder.setVertexBytes(enc, viewport, @sizeOf(DeviceSize), Index.viewport_size);
        if (sprite_texture) |t| {
            mtl.RenderEncoder.setVertexBytes(enc, &t.size, @sizeOf(DeviceSize), Index.atlas_texture_size);
            mtl.RenderEncoder.setFragmentTexture(enc, t.texture, Index.atlas_texture);
        }
        mtl.RenderEncoder.drawInstanced(enc, .triangle, 0, 6, items.len);
    }

    /// End the pass, snapshot the padded blur region, gaussian-blur it, resume
    /// the pass with `Load` and paint the blurred region back (no blending).
    fn applyBackdropBlur(
        self: *MetalRenderer,
        command_buffer: id,
        encoder: *?id,
        frame: *Frame,
        target: id,
        viewport: DeviceSize,
        blur: scene_mod.BackdropBlur,
    ) EncodeError!void {
        const drawable_width = mtl.Texture.width(target);
        const drawable_height = mtl.Texture.height(target);
        const region = backdrop.snapshotRegion(blur, @intCast(drawable_width), @intCast(drawable_height)) orelse return;

        mtl.RenderEncoder.endEncoding(encoder.*.?);
        encoder.* = null;

        const entry = try self.backdrop_textures.ensure(
            self.gpa,
            &self.blur_gpu,
            region.width(),
            region.height(),
            drawable_width,
            drawable_height,
            mtl.Texture.pixelFormat(target),
        );
        const scratch = entry.pair.scratch;
        const copy_x = backdrop.copyOrigin(region.x0, drawable_width, entry.width);
        const copy_y = backdrop.copyOrigin(region.y0, drawable_height, entry.height);

        const blit = mtl.CommandBuffer.blitCommandEncoder(command_buffer) orelse return error.CommandBufferFailed;
        mtl.BlitEncoder.copyTexture(blit, target, .{ .x = copy_x, .y = copy_y }, .{ .width = entry.width, .height = entry.height }, scratch, .{});
        mtl.BlitEncoder.endEncoding(blit);

        var source = scratch;
        if (try self.gaussianKernel(backdrop.sigma(blur))) |kernel| {
            mtl.GaussianBlur.encode(kernel, command_buffer, scratch, entry.pair.blurred);
            source = entry.pair.blurred;
        }

        encoder.* = try beginPass(command_buffer, target, viewport, .load);
        const enc = encoder.*.?;
        const source_rect: [4]f32 = .{
            @floatFromInt(copy_x),
            @floatFromInt(copy_y),
            @floatFromInt(entry.width),
            @floatFromInt(entry.height),
        };
        const offset = try frame.write(std.mem.asBytes(&blur));
        mtl.RenderEncoder.setPipeline(enc, self.pipelines.backdrop_blur);
        mtl.RenderEncoder.setVertexBuffer(enc, self.unit_vertices, 0, Index.vertices);
        mtl.RenderEncoder.setVertexBuffer(enc, frame.buffer, offset, Index.instances);
        mtl.RenderEncoder.setFragmentBuffer(enc, frame.buffer, offset, Index.instances);
        mtl.RenderEncoder.setVertexBytes(enc, &viewport, @sizeOf(DeviceSize), Index.viewport_size);
        mtl.RenderEncoder.setFragmentBytes(enc, &source_rect, @sizeOf(@TypeOf(source_rect)), Index.blur_source_rect);
        mtl.RenderEncoder.setFragmentTexture(enc, source, Index.blur_source_texture);
        mtl.RenderEncoder.drawInstanced(enc, .triangle, 0, 6, 1);
    }

    /// The cached `MPSImageGaussianBlur` for `sigma`, or null when MPS is
    /// unavailable on this device (e.g. paravirtualized CI GPUs).
    fn gaussianKernel(self: *MetalRenderer, sigma: f32) Error!?id {
        if (!self.mps_supported) {
            self.warnOnce(.mps, "MetalPerformanceShaders unsupported on this device; backdrop blurs are drawn unblurred");
            return null;
        }
        return try self.backdrop_kernels.ensure(&self.blur_gpu, sigma);
    }

    /// Rasterize `paths` into the (MSAA) intermediate. False if nothing to composite.
    fn drawPathsToIntermediate(
        self: *MetalRenderer,
        command_buffer: id,
        frame: *Frame,
        paths: []const scene_mod.Path,
        viewport: DeviceSize,
    ) EncodeError!bool {
        const intermediate = self.path_intermediate orelse return false;
        var vertex_count: usize = 0;
        for (paths) |p| vertex_count += p.vertices.items.len;
        if (vertex_count == 0) return false;

        const reserved = try frame.reserveSlice(scene_mod.PathRasterizationVertex, vertex_count);
        var i: usize = 0;
        for (paths) |p| {
            const clipped = p.clippedBounds();
            for (p.vertices.items) |v| {
                reserved.items[i] = .{ .xy_position = v.xy_position, .st_position = v.st_position, .color = p.color, .bounds = clipped };
                i += 1;
            }
        }

        const pass = if (self.path_intermediate_msaa) |msaa| mtl.RenderPassDescriptor.new(.{
            .texture = msaa,
            .resolve_texture = intermediate,
            .load = .clear,
            .store = .multisample_resolve,
        }) else mtl.RenderPassDescriptor.new(.{ .texture = intermediate, .load = .clear, .store = .store });
        const enc = mtl.CommandBuffer.renderCommandEncoder(command_buffer, pass orelse return error.CommandBufferFailed) orelse
            return error.CommandBufferFailed;
        defer mtl.RenderEncoder.endEncoding(enc);
        mtl.RenderEncoder.setPipeline(enc, self.pipelines.path_rasterization);
        mtl.RenderEncoder.setVertexBuffer(enc, frame.buffer, reserved.offset, Index.path_vertices);
        mtl.RenderEncoder.setVertexBytes(enc, &viewport, @sizeOf(DeviceSize), Index.path_viewport_size);
        mtl.RenderEncoder.setFragmentBuffer(enc, frame.buffer, reserved.offset, Index.path_vertices);
        mtl.RenderEncoder.draw(enc, .triangle, 0, vertex_count);
        return true;
    }

    /// Composite the intermediate onto the target. Each pixel must be copied
    /// once (translucent paths): same-order paths are disjoint, so copy each
    /// path's bounds; mixed orders copy one spanning rect.
    fn drawPathsFromIntermediate(
        self: *MetalRenderer,
        enc: id,
        frame: *Frame,
        paths: []const scene_mod.Path,
        viewport: DeviceSize,
    ) error{InstanceBufferOverflow}!void {
        if (paths.len == 0) return;
        const intermediate = self.path_intermediate orelse return;
        const same_order = paths[paths.len - 1].order == paths[0].order;
        const reserved = try frame.reserveSlice(scene_mod.PathSprite, if (same_order) paths.len else 1);
        if (same_order) {
            for (paths, reserved.items) |p, *s| s.* = .{ .bounds = p.clippedBounds() };
        } else {
            var bounds = paths[0].clippedBounds();
            for (paths[1..]) |p| bounds = bounds.unionWith(p.clippedBounds());
            reserved.items[0] = .{ .bounds = bounds };
        }
        mtl.RenderEncoder.setPipeline(enc, self.pipelines.path_sprites);
        mtl.RenderEncoder.setVertexBuffer(enc, self.unit_vertices, 0, Index.vertices);
        mtl.RenderEncoder.setVertexBuffer(enc, frame.buffer, reserved.offset, Index.instances);
        mtl.RenderEncoder.setVertexBytes(enc, &viewport, @sizeOf(DeviceSize), Index.viewport_size);
        mtl.RenderEncoder.setFragmentTexture(enc, intermediate, Index.atlas_texture);
        mtl.RenderEncoder.drawInstanced(enc, .triangle, 0, 6, reserved.items.len);
    }

    // -----------------------------------------------------------------------
    // Resources
    // -----------------------------------------------------------------------

    fn clearColor(self: *const MetalRenderer, clear: color.Hsla) mtl.ClearColor {
        const c = clear.toRgba();
        // Premultiplied; an opaque target shows the clear color over black.
        const a: f64 = if (self.is_opaque) 1 else c.a;
        const k: f64 = c.a;
        return .{ .red = c.r * k, .green = c.g * k, .blue = c.b * k, .alpha = a };
    }

    /// Reclaim instance buffers of frames the GPU finished.
    fn reclaimCompleted(self: *MetalRenderer) void {
        var i: usize = 0;
        while (i < self.in_flight.items.len) {
            const f = self.in_flight.items[i];
            switch (mtl.CommandBuffer.status(f.command_buffer)) {
                .completed, .@"error" => {
                    if (mtl.CommandBuffer.status(f.command_buffer) == .@"error") {
                        log.err("frame failed: {s}", .{objc.errorDescription(mtl.CommandBuffer.@"error"(f.command_buffer))});
                    }
                    f.command_buffer.release();
                    self.instance_buffers.release(self.gpa, &self.buffer_gpu, f.buffer);
                    _ = self.in_flight.orderedRemove(i);
                },
                else => i += 1,
            }
        }
    }

    /// Create/replace GPU textures for changed atlas slots and copy pending uploads.
    fn syncAtlas(self: *MetalRenderer) !void {
        for (std.enums.values(AtlasTextureKind)) |kind| {
            const list = &self.atlas_textures[@backingInt(kind)];
            const slots = self.sprite_atlas.textureSlots(kind);
            while (list.items.len > slots) if (list.pop().?) |t| t.texture.release();
            if (list.items.len < slots) {
                const old_len = list.items.len;
                try list.resize(self.gpa, slots);
                @memset(list.items[old_len..], null);
            }
            for (list.items, 0..) |*slot, index| {
                const info = self.sprite_atlas.textureInfo(.{ .index = @intCast(index), .kind = kind });
                if (slot.*) |t| if (info == null or info.?.generation != t.generation) {
                    t.texture.release();
                    slot.* = null;
                };
                if (slot.* == null) if (info) |in| {
                    slot.* = .{
                        .texture = try newTexture(self.device, .{
                            .width = @intCast(in.size.width),
                            .height = @intCast(in.size.height),
                            .format = atlasFormat(kind),
                            .usage = mtl.TextureUsage.shader_read,
                            // Shared storage is only available on Apple GPU families.
                            .storage = if (self.is_apple_gpu) .shared else .managed,
                        }),
                        .generation = in.generation,
                        .size = in.size,
                    };
                };
            }
        }
        for (self.sprite_atlas.pendingUploads()) |upload| {
            const texture = self.atlasTexture(upload.texture_id) orelse continue;
            const b = upload.bounds;
            const region: mtl.Region = .{
                .origin = .{ .x = @intCast(b.origin.x), .y = @intCast(b.origin.y) },
                .size = .{ .width = @intCast(b.size.width), .height = @intCast(b.size.height) },
            };
            const bytes_per_row = @as(NSUInteger, @intCast(b.size.width)) * upload.texture_id.kind.bytesPerPixel();
            mtl.Texture.replaceRegion(texture.texture, region, upload.data.ptr, bytes_per_row);
        }
        self.sprite_atlas.clearUploads();
    }

    fn atlasTexture(self: *const MetalRenderer, texture_id: AtlasTextureId) ?AtlasTexture {
        const list = self.atlas_textures[@backingInt(texture_id.kind)].items;
        if (texture_id.index >= list.len) return null;
        return list[texture_id.index];
    }

    /// Lazily create drawable-sized path intermediates (the resolve texture is
    /// ~24 MB at retina fullscreen, so path-free frames should not pay for it).
    fn ensurePathIntermediates(self: *MetalRenderer, size: DeviceSize) !void {
        // Zero-sized textures abort in Metal validation.
        if (size.width <= 0 or size.height <= 0) {
            self.releasePathIntermediates();
            return;
        }
        if (self.path_intermediate) |t| {
            if (mtl.Texture.width(t) == @as(usize, @intCast(size.width)) and mtl.Texture.height(t) == @as(usize, @intCast(size.height))) return;
        }
        self.releasePathIntermediates();
        const width: usize = @intCast(size.width);
        const height: usize = @intCast(size.height);
        self.path_intermediate = try newTexture(self.device, .{
            .width = width,
            .height = height,
            .format = target_format,
            .usage = mtl.TextureUsage.render_target | mtl.TextureUsage.shader_read,
            .storage = .private,
        });
        // MSAA is rendered and resolved in one pass: memoryless on Apple GPUs.
        self.path_intermediate_msaa = try newTexture(self.device, .{
            .width = width,
            .height = height,
            .format = target_format,
            .usage = mtl.TextureUsage.render_target,
            .storage = if (self.is_apple_gpu) .memoryless else .private,
            .texture_type = .@"2d_multisample",
            .sample_count = path_sample_count,
        });
    }

    fn releasePathIntermediates(self: *MetalRenderer) void {
        if (self.path_intermediate) |t| t.release();
        if (self.path_intermediate_msaa) |t| t.release();
        self.path_intermediate = null;
        self.path_intermediate_msaa = null;
    }

    /// Drop blur scratch textures and cached kernels; recreated on demand.
    fn releaseBackdropResources(self: *MetalRenderer) void {
        self.backdrop_textures.clear(&self.blur_gpu);
        self.backdrop_kernels.clear(&self.blur_gpu);
    }

    fn configureLayer(self: *MetalRenderer, existing: ?*anyopaque, transparent: bool) !id {
        const l: id = if (existing) |ptr| @as(id, @ptrCast(ptr)).retain() else mtl.Layer.new() orelse return error.ResourceCreationFailed;
        mtl.Layer.setDevice(l, self.device);
        mtl.Layer.setPixelFormat(l, target_format);
        // Direct-to-display when the window is opaque.
        mtl.Layer.setOpaque(l, !transparent);
        // One displayed drawable plus one for the next frame; `nextDrawable`
        // provides backpressure. A third adds memory to every idle window.
        mtl.Layer.setMaximumDrawableCount(l, 2);
        // The backdrop blur blits from the drawable, which framebuffer-only
        // textures do not formally allow.
        mtl.Layer.setFramebufferOnly(l, false);
        mtl.Layer.setAllowsNextDrawableTimeout(l, false);
        mtl.Layer.setNeedsDisplayOnBoundsChange(l, true);
        mtl.Layer.setAutoresizingMask(l, mtl.AutoresizingMask.width_sizable | mtl.AutoresizingMask.height_sizable);
        return l;
    }

    fn warnOnce(self: *MetalRenderer, comptime what: @TypeOf(self.warned_unsupported).Key, comptime message: []const u8) void {
        if (self.warned_unsupported.contains(what)) return;
        self.warned_unsupported.insert(what);
        log.warn(message, .{});
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn sharedOrManaged(unified_memory: bool) NSUInteger {
    // Write-only buffers benefit from the write-combined CPU cache.
    return if (unified_memory)
        mtl.ResourceOptions.storage_mode_shared | mtl.ResourceOptions.cpu_cache_mode_write_combined
    else
        mtl.ResourceOptions.storage_mode_managed;
}

fn atlasFormat(kind: AtlasTextureKind) mtl.PixelFormat {
    return switch (kind) {
        .monochrome => .a8_unorm,
        .polychrome, .subpixel => .bgra8_unorm,
    };
}

fn newTexture(device: id, options: mtl.TextureDescriptor.Options) Error!id {
    const desc = mtl.TextureDescriptor.new(options) orelse return error.ResourceCreationFailed;
    defer desc.release();
    return mtl.Device.newTexture(device, desc) orelse error.ResourceCreationFailed;
}

const PassLoad = union(enum) { clear: mtl.ClearColor, load };

fn beginPass(command_buffer: id, texture: id, viewport: DeviceSize, load: PassLoad) Error!id {
    const pass = mtl.RenderPassDescriptor.new(.{
        .texture = texture,
        .load = if (load == .clear) .clear else .load,
        .store = .store,
        .clear = if (load == .clear) load.clear else undefined,
    }) orelse return error.CommandBufferFailed;
    const enc = mtl.CommandBuffer.renderCommandEncoder(command_buffer, pass) orelse return error.CommandBufferFailed;
    mtl.RenderEncoder.setViewport(enc, .{
        .originX = 0,
        .originY = 0,
        .width = @floatFromInt(viewport.width),
        .height = @floatFromInt(viewport.height),
        .znear = 0,
        .zfar = 1,
    });
    return enc;
}

/// Prefer non-removable, then low-power GPUs (integrated on Intel Macs; on
/// Apple Silicon there is only one). Falls back to the system default, since
/// `MTLCopyAllDevices` can come back empty.
fn selectDevice() ?id {
    if (mtl.MTLCopyAllDevices()) |all| {
        defer all.release();
        var best: ?id = null;
        var best_rank: u8 = std.math.maxInt(u8);
        for (0..mtl.arrayCount(all)) |i| {
            const d = mtl.arrayObjectAt(all, i);
            const rank = @as(u8, @intFromBool(mtl.Device.isRemovable(d))) * 2 + @intFromBool(!mtl.Device.isLowPower(d));
            if (rank < best_rank) {
                best = d;
                best_rank = rank;
            }
        }
        if (best) |d| return d.retain();
    }
    log.warn("unable to enumerate Metal devices; using the system default device", .{});
    return mtl.MTLCreateSystemDefaultDevice();
}

fn compileLibrary(device: id) Error!id {
    var err: ?id = null;
    // A library with warnings still comes back non-null alongside an NSError.
    return mtl.Device.newLibraryWithSource(device, objc.nsString(shader_source), &err) orelse {
        log.err("shader compilation failed: {s}", .{objc.errorDescription(err)});
        return error.ShaderCompilationFailed;
    };
}

fn buildPipeline(
    device: id,
    library: id,
    label: [:0]const u8,
    vertex_name: [:0]const u8,
    fragment_name: [:0]const u8,
    blend: ?mtl.Blend,
    sample_count: NSUInteger,
) Error!id {
    const vertex_fn = mtl.newFunction(library, vertex_name) orelse {
        log.err("missing vertex function {s}", .{vertex_name});
        return error.PipelineCreationFailed;
    };
    defer vertex_fn.release();
    const fragment_fn = mtl.newFunction(library, fragment_name) orelse {
        log.err("missing fragment function {s}", .{fragment_name});
        return error.PipelineCreationFailed;
    };
    defer fragment_fn.release();

    const desc = mtl.RenderPipelineDescriptor.new() orelse return error.PipelineCreationFailed;
    defer desc.release();
    mtl.RenderPipelineDescriptor.setLabel(desc, label);
    mtl.RenderPipelineDescriptor.setVertexFunction(desc, vertex_fn);
    mtl.RenderPipelineDescriptor.setFragmentFunction(desc, fragment_fn);
    if (sample_count > 1) {
        mtl.RenderPipelineDescriptor.setRasterSampleCount(desc, sample_count);
        mtl.RenderPipelineDescriptor.setAlphaToCoverageEnabled(desc, false);
    }
    mtl.RenderPipelineDescriptor.setColorAttachment0(desc, target_format, blend);

    var err: ?id = null;
    return mtl.Device.newRenderPipelineState(device, desc, &err) orelse {
        log.err("pipeline {s} failed: {s}", .{ label, objc.errorDescription(err) });
        return error.PipelineCreationFailed;
    };
}

fn buildPipelines(device: id, library: id) Error!Pipelines {
    var p: Pipelines = undefined;
    const specs = .{
        .{ "path_rasterization", "paths_rasterization", "path_rasterization_vertex", "path_rasterization_fragment", blend_premultiplied, path_sample_count },
        .{ "path_sprites", "path_sprites", "path_sprite_vertex", "path_sprite_fragment", blend_premultiplied, 1 },
        .{ "shadows", "shadows", "shadow_vertex", "shadow_fragment", blend_straight, 1 },
        // Blending disabled: the blur REPLACES the region (outside fragments discard).
        .{ "backdrop_blur", "backdrop_blur", "backdrop_blur_vertex", "backdrop_blur_fragment", null, 1 },
        .{ "quads", "quads", "quad_vertex", "quad_fragment", blend_straight, 1 },
        .{ "underlines", "underlines", "underline_vertex", "underline_fragment", blend_straight, 1 },
        .{ "monochrome_sprites", "monochrome_sprites", "monochrome_sprite_vertex", "monochrome_sprite_fragment", blend_straight, 1 },
        .{ "polychrome_sprites", "polychrome_sprites", "polychrome_sprite_vertex", "polychrome_sprite_fragment", blend_straight, 1 },
        .{ "surfaces", "surfaces", "surface_vertex", "surface_fragment", blend_straight, 1 },
    };
    comptime std.debug.assert(specs.len == @typeInfo(Pipelines).@"struct".field_names.len);
    var built: usize = 0;
    errdefer inline for (specs, 0..) |s, i| {
        if (i < built) @field(p, s[0]).release();
    };
    inline for (specs) |s| {
        @field(p, s[0]) = try buildPipeline(device, library, s[1], s[2], s[3], s[4], s[5]);
        built += 1;
    }
    return p;
}

/// BGRA8 (GPU order) -> RGBA8, keeping premultiplied alpha.
fn bgraToRgba(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len and src.len % 4 == 0);
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        dst[i + 0] = src[i + 2];
        dst[i + 1] = src[i + 1];
        dst[i + 2] = src[i + 0];
        dst[i + 3] = src[i + 3];
    }
}

test "bgra to rgba" {
    var out: [8]u8 = undefined;
    bgraToRgba(&out, &.{ 10, 20, 30, 255, 0, 64, 128, 128 });
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255, 128, 64, 0, 128 }, &out);
}
