//! Direct3D 11 renderer for zpui scenes (Windows). Implements the interface documented
//! in `src/renderer/renderer.zig` with the same output as the Vulkan and Metal
//! renderers (shaders.hlsl is a port of src/renderer/vulkan/shaders).
//!
//! * Window targets are DXGI flip-model swapchains created for composition
//!   (`CreateSwapChainForComposition`) and shown through a DirectComposition visual on
//!   the window's HWND: premultiplied alpha for transparent windows, no redirection
//!   bitmap, no stretching (DComp shows the buffer 1:1, so a resize never scales a stale
//!   frame). A second, topmost composition target (the overlay plane) can be stacked
//!   above the window's child HWNDs (native controls) for `drawLayered`.
//! * Every primitive kind has one dynamic structured buffer; each frame uploads the
//!   scene's sorted array once (`Map(WRITE_DISCARD)`) and batches draw instanced unit
//!   quads at their offset (`first_instance` in the constant buffer). Buffers only grow
//!   (powers of two), so steady-state frames allocate nothing.
//! * Paths rasterize into a 4x MSAA intermediate (resolved, then copied as sprites);
//!   backdrop blurs snapshot the target, blur in two separable passes and composite,
//!   in scene order, like the Vulkan renderer.
//! * The framebuffer holds premultiplied color: shaders output straight alpha and blend
//!   `SrcAlpha, 1-SrcAlpha` (color) / `One, 1-SrcAlpha` (alpha).
//! * `suspendTargets` releases swapchains and intermediates (hidden windows) and trims
//!   the driver's allocations; the next draw recreates them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const w = @import("../../platform/windows/win32.zig");
const d3d = @import("d3d11.zig");
const Device = @import("Device.zig");
const iface = @import("../renderer.zig");
const geometry = @import("../../geometry.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const color = @import("../../color.zig");

const Scene = scene_mod.Scene;
const Atlas = atlas_mod.Atlas;
const AtlasTextureId = atlas_mod.AtlasTextureId;
const AtlasTextureKind = atlas_mod.AtlasTextureKind;
const Size = geometry.Size(geometry.DevicePixels);
const Hsla = color.Hsla;
const Program = Device.Program;
const BlendMode = Device.BlendMode;

const Renderer = @This();
const log = std.log.scoped(.d3d11);

const kind_count = @typeInfo(AtlasTextureKind).@"enum".field_names.len;
const swap_format = d3d.DXGI_FORMAT_B8G8R8A8_UNORM;
const offscreen_format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM;
const swap_flags: w.UINT = 0;

pub const PlaneId = enum(u1) { main, overlay };

gpa: Allocator,
dev: *Device,
sprite_atlas: Atlas,
transparent: bool,
size: Size,
hwnd: ?w.HWND,
/// Offscreen target (null when presenting to a window).
offscreen: ?Texture = null,
planes: [2]Plane = .{ .{ .topmost = false }, .{ .topmost = true } },
constants: ?*d3d.ID3D11Buffer = null,
instances: [instance_kinds]InstanceBuffer = initInstanceBuffers(),
atlas_textures: [kind_count]std.ArrayList(GpuTexture) = @splat(.empty),
path_msaa: Texture = .{},
path_resolve: Texture = .{},
blur_scratch: Texture = .{},
blur_a: Texture = .{},
blur_b: Texture = .{},
staging: Texture = .{},
/// Copy the next presented main-plane frame for `takeCapture` (smoke tests, screenshots).
capture_next: bool = false,
captured: ?Capture = null,
warned_surface: bool = false,
/// Swapchains / intermediates released by `suspendTargets`.
suspended: bool = false,
/// Present sync interval: 1 (default) queues behind vblank; 0 never blocks the caller
/// (resize frames drawn outside the vblank cadence).
sync_interval: u32 = 1,

pub const Capture = struct { width: u32, height: u32, rgba: []u8 };

const Texture = struct {
    tex: ?*d3d.ID3D11Texture2D = null,
    rtv: ?*d3d.ID3D11RenderTargetView = null,
    srv: ?*d3d.ID3D11ShaderResourceView = null,
    width: u32 = 0,
    height: u32 = 0,
    format: d3d.DXGI_FORMAT = 0,
    samples: u32 = 1,

    fn release(t: *Texture) void {
        w.releaseOpt(&t.srv);
        w.releaseOpt(&t.rtv);
        w.releaseOpt(&t.tex);
        t.* = .{};
    }
};

const Plane = struct {
    topmost: bool,
    swapchain: ?*d3d.IDXGISwapChain1 = null,
    backbuffer: ?*d3d.ID3D11Texture2D = null,
    rtv: ?*d3d.ID3D11RenderTargetView = null,
    target: ?*w.IDCompositionTarget = null,
    visual: ?*w.IDCompositionVisual = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Something non-transparent is on screen (overlay plane bookkeeping).
    shown: bool = false,

    fn releaseBuffers(p: *Plane) void {
        w.releaseOpt(&p.rtv);
        w.releaseOpt(&p.backbuffer);
    }

    fn release(p: *Plane) void {
        p.releaseBuffers();
        if (p.visual) |v| _ = v.vtbl.SetContent(v, null);
        w.releaseOpt(&p.swapchain);
        if (p.target) |t| _ = t.vtbl.SetRoot(t, null);
        w.releaseOpt(&p.visual);
        w.releaseOpt(&p.target);
        p.width = 0;
        p.height = 0;
        p.shown = false;
    }
};

const GpuTexture = struct {
    tex: Texture = .{},
    generation: u32 = 0,
};

// ---- instance buffers ---------------------------------------------------------------------

const InstanceKind = enum(u4) { shadow, quad, underline, mono_sprite, subpixel_sprite, poly_sprite, path_vertex, path_sprite, backdrop_blur };
const instance_kinds = @typeInfo(InstanceKind).@"enum".field_names.len;

fn strideOf(kind: InstanceKind) u32 {
    return switch (kind) {
        .shadow => @sizeOf(scene_mod.Shadow),
        .quad => @sizeOf(scene_mod.Quad),
        .underline => @sizeOf(scene_mod.Underline),
        .mono_sprite => @sizeOf(scene_mod.MonochromeSprite),
        .subpixel_sprite => @sizeOf(scene_mod.SubpixelSprite),
        .poly_sprite => @sizeOf(scene_mod.PolychromeSprite),
        .path_vertex => @sizeOf(scene_mod.PathRasterizationVertex),
        .path_sprite => @sizeOf(scene_mod.PathSprite),
        .backdrop_blur => @sizeOf(scene_mod.BackdropBlur),
    };
}

const InstanceBuffer = struct {
    buffer: ?*d3d.ID3D11Buffer = null,
    srv: ?*d3d.ID3D11ShaderResourceView = null,
    capacity: u32 = 0,
    stride: u32,

    fn release(b: *InstanceBuffer) void {
        w.releaseOpt(&b.srv);
        w.releaseOpt(&b.buffer);
        b.capacity = 0;
    }
};

fn initInstanceBuffers() [instance_kinds]InstanceBuffer {
    var out: [instance_kinds]InstanceBuffer = undefined;
    for (&out, 0..) |*b, i| b.* = .{ .stride = strideOf(@fromBackingInt(@intCast(i))) };
    return out;
}

/// Mirrors `cbuffer DrawConstants` in shaders.hlsl (64 bytes).
const DrawConstants = extern struct {
    viewport_size: [2]f32 = .{ 0, 0 },
    texture_size: [2]f32 = .{ 0, 0 },
    params0: [4]f32 = .{ 0, 0, 0, 0 },
    params1: [4]f32 = .{ 0, 0, 0, 0 },
    first_instance: u32 = 0,
    _pad: [3]u32 = .{ 0, 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(DrawConstants) == 64);
    }
};

// ---------------------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------------------

/// Shared-interface constructor (see `renderer.zig`). `options.surface = .{ .hwnd = h }`
/// presents to that window; null renders offscreen (`readPixels`).
pub fn init(gpa: Allocator, options: iface.Options) !Renderer {
    const hwnd: ?w.HWND = if (options.surface) |s| switch (s) {
        .hwnd => |h| @ptrCast(h),
        else => return error.UnsupportedSurface,
    } else null;
    const dev = try Device.acquire(gpa);
    errdefer dev.release(gpa);
    var atlas_opts = options.atlas;
    atlas_opts.max_size = @min(atlas_opts.max_size, 16384);
    var self: Renderer = .{
        .gpa = gpa,
        .dev = dev,
        .sprite_atlas = .init(gpa, atlas_opts),
        .transparent = options.transparent,
        .size = .{ .width = @max(options.size.width, 1), .height = @max(options.size.height, 1) },
        .hwnd = hwnd,
    };
    errdefer self.destroyResources();
    try w.check(dev.device.vtbl.CreateBuffer(dev.device, &.{
        .ByteWidth = @sizeOf(DrawConstants),
        .Usage = d3d.D3D11_USAGE_DYNAMIC,
        .BindFlags = d3d.D3D11_BIND_CONSTANT_BUFFER,
        .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
    }, null, &self.constants));
    if (hwnd == null) try self.createOffscreenTarget();
    return self;
}

/// Headless renderer drawing into an RGBA8 texture; read it with `readPixels`.
pub fn createOffscreen(gpa: Allocator, size: Size) !Renderer {
    return init(gpa, .{ .size = size });
}

pub fn deinit(self: *Renderer) void {
    self.destroyResources();
    self.* = undefined;
}

fn destroyResources(self: *Renderer) void {
    const ctx = self.dev.context;
    ctx.vtbl.ClearState(ctx);
    for (&self.planes) |*p| p.release();
    if (self.planes[0].target != null or self.planes[1].target != null) self.commit();
    if (self.offscreen) |*t| t.release();
    for (&self.instances) |*b| b.release();
    for (&self.atlas_textures) |*list| {
        for (list.items) |*t| t.tex.release();
        list.deinit(self.gpa);
    }
    self.releaseIntermediates();
    self.staging.release();
    w.releaseOpt(&self.constants);
    if (self.captured) |c| self.gpa.free(c.rgba);
    self.captured = null;
    self.sprite_atlas.deinit();
    // Commit the visual teardown before the device can go away.
    if (self.dev.dcomp) |dc| _ = dc.commit();
    self.dev.release(self.gpa);
}

fn releaseIntermediates(self: *Renderer) void {
    self.path_msaa.release();
    self.path_resolve.release();
    self.blur_scratch.release();
    self.blur_a.release();
    self.blur_b.release();
}

/// The sprite atlas; the renderer uploads its pending tiles every frame.
pub fn atlas(self: *Renderer) *Atlas {
    return &self.sprite_atlas;
}

/// Resize the offscreen target; window planes follow the viewport passed to `drawScene`.
pub fn resize(self: *Renderer, size: Size) !void {
    if (size.width <= 0 or size.height <= 0) return;
    self.size = size;
    if (self.offscreen) |*t| {
        t.release();
        self.offscreen = null;
        try self.createOffscreenTarget();
    }
}

/// Hidden window: drop swapchains, intermediates and staging memory (the atlas stays),
/// and let the driver trim. The next `drawScene` recreates what it needs.
pub fn suspendTargets(self: *Renderer) void {
    if (self.suspended or self.hwnd == null) return;
    self.suspended = true;
    const ctx = self.dev.context;
    ctx.vtbl.ClearState(ctx);
    for (&self.planes) |*p| p.release();
    self.commit();
    self.releaseIntermediates();
    self.staging.release();
    ctx.vtbl.Flush(ctx);
    if (w.queryInterfaceIid(self.dev.dxgi_device, &d3d.IDXGIDevice.iid3, d3d.IDXGIDevice)) |dev3| {
        defer w.release(dev3);
        dev3.vtbl.Trim(dev3);
    }
}

fn createOffscreenTarget(self: *Renderer) !void {
    self.offscreen = try self.createTexture(@intCast(self.size.width), @intCast(self.size.height), offscreen_format, 1, true, true);
}

fn createTexture(self: *Renderer, width: u32, height: u32, format: d3d.DXGI_FORMAT, samples: u32, rt: bool, srv: bool) !Texture {
    const dev = self.dev.device;
    var t: Texture = .{ .width = width, .height = height, .format = format, .samples = samples };
    errdefer t.release();
    var bind: w.UINT = 0;
    if (rt) bind |= d3d.D3D11_BIND_RENDER_TARGET;
    if (srv) bind |= d3d.D3D11_BIND_SHADER_RESOURCE;
    try w.check(dev.vtbl.CreateTexture2D(dev, &.{
        .Width = width,
        .Height = height,
        .Format = format,
        .SampleDesc = .{ .Count = samples, .Quality = if (samples > 1) d3d.D3D11_STANDARD_MULTISAMPLE_PATTERN else 0 },
        .BindFlags = bind,
    }, null, &t.tex));
    if (rt) try w.check(dev.vtbl.CreateRenderTargetView(dev, @ptrCast(t.tex.?), null, &t.rtv));
    if (srv) try w.check(dev.vtbl.CreateShaderResourceView(dev, @ptrCast(t.tex.?), null, &t.srv));
    return t;
}

/// Viewport-sized intermediate, (re)created lazily when the size or format changes.
fn ensureTexture(self: *Renderer, t: *Texture, width: u32, height: u32, format: d3d.DXGI_FORMAT, samples: u32, rt: bool, srv: bool) !void {
    if (t.tex != null and t.width == width and t.height == height and t.format == format and t.samples == samples) return;
    t.release();
    t.* = try self.createTexture(width, height, format, samples, rt, srv);
}

// ---------------------------------------------------------------------------------------
// Window planes (DirectComposition)
// ---------------------------------------------------------------------------------------

fn commit(self: *Renderer) void {
    if (self.dev.dcomp) |dc| _ = dc.commit();
}

/// Create / resize plane `id`'s swapchain for `width`x`height` (synchronous
/// `ResizeBuffers`, so the next present is already the new size).
fn ensurePlane(self: *Renderer, id: PlaneId, width: u32, height: u32) !*Plane {
    const p = &self.planes[@backingInt(id)];
    const dev = self.dev;
    if (p.swapchain == null and dev.dcomp == null) {
        // No DirectComposition (some remote / virtualized sessions): an HWND flip-model
        // swapchain on the main plane, opaque only, and no overlay plane.
        if (id == .overlay) return error.DirectCompositionUnavailable;
        try w.check(dev.factory.vtbl.CreateSwapChainForHwnd(dev.factory, @ptrCast(dev.device), self.hwnd.?, &.{
            .Width = width,
            .Height = height,
            .Format = swap_format,
            .BufferUsage = d3d.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = d3d.DXGI_SCALING_STRETCH,
            .SwapEffect = d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .AlphaMode = d3d.DXGI_ALPHA_MODE_IGNORE,
            .Flags = swap_flags,
        }, null, null, &p.swapchain));
        _ = dev.factory.vtbl.MakeWindowAssociation(dev.factory, self.hwnd.?, d3d.DXGI_MWA_NO_ALT_ENTER);
        p.width = width;
        p.height = height;
    } else if (p.swapchain == null) {
        const dcomp = dev.dcomp.?;
        const transparent = self.transparent or id == .overlay;
        try w.check(dev.factory.vtbl.CreateSwapChainForComposition(dev.factory, @ptrCast(dev.device), &.{
            .Width = width,
            .Height = height,
            .Format = swap_format,
            .BufferUsage = d3d.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = d3d.DXGI_SCALING_STRETCH,
            .SwapEffect = d3d.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            .AlphaMode = if (transparent) d3d.DXGI_ALPHA_MODE_PREMULTIPLIED else d3d.DXGI_ALPHA_MODE_IGNORE,
            .Flags = swap_flags,
        }, null, &p.swapchain));
        errdefer p.release();
        try w.check(dcomp.vtbl.CreateVisual(dcomp, &p.visual));
        try w.check(p.visual.?.vtbl.SetContent(p.visual.?, @ptrCast(p.swapchain.?)));
        try w.check(dcomp.vtbl.CreateTargetForHwnd(dcomp, self.hwnd.?, @intFromBool(p.topmost), &p.target));
        try w.check(p.target.?.vtbl.SetRoot(p.target.?, p.visual));
        try w.check(dcomp.commit());
        p.width = width;
        p.height = height;
    } else if (p.width != width or p.height != height) {
        p.releaseBuffers();
        // Unbind everything that may reference the old buffers.
        dev.context.vtbl.OMSetRenderTargets(dev.context, 0, null, null);
        try w.check(p.swapchain.?.vtbl.ResizeBuffers(p.swapchain.?, 0, width, height, d3d.DXGI_FORMAT_UNKNOWN, swap_flags));
        p.width = width;
        p.height = height;
    }
    if (p.rtv == null) {
        var buf: ?*anyopaque = null;
        try w.check(p.swapchain.?.vtbl.GetBuffer(p.swapchain.?, 0, &d3d.IID_ID3D11Texture2D, &buf));
        p.backbuffer = @ptrCast(@alignCast(buf.?));
        try w.check(dev.device.vtbl.CreateRenderTargetView(dev.device, @ptrCast(p.backbuffer.?), null, &p.rtv));
    }
    return p;
}

fn present(self: *Renderer, p: *Plane) !void {
    const hr = p.swapchain.?.vtbl.Present(p.swapchain.?, self.sync_interval, 0);
    // The RTV of a flip-model buffer must be rebound after every present.
    p.releaseBuffers();
    if (hr == d3d.DXGI_ERROR_DEVICE_REMOVED or hr == d3d.DXGI_ERROR_DEVICE_RESET) {
        log.err("D3D11 device lost (0x{x})", .{@as(u32, @bitCast(self.dev.device.vtbl.GetDeviceRemovedReason(self.dev.device)))});
        return error.DeviceLost;
    }
    if (hr < 0 and hr != d3d.DXGI_STATUS_OCCLUDED) try w.check(hr);
}

// ---------------------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------------------

/// Draw `scene` (already `finish`ed) and present it (window) or keep it for
/// `readPixels` (offscreen). `clear` is premultiplied before clearing; opaque
/// windows force alpha to 1.
pub fn drawScene(self: *Renderer, scene: *const Scene, viewport: Size, scale_factor: f32, clear: Hsla) !void {
    _ = scale_factor;
    if (viewport.width <= 0 or viewport.height <= 0) return;
    const width: u32 = @intCast(viewport.width);
    const height: u32 = @intCast(viewport.height);
    if (self.offscreen) |*t| {
        if (t.width != width or t.height != height) try self.resize(viewport);
        const target = self.offscreen.?;
        try self.render(scene, target.rtv.?, target.tex.?, width, height, clear, true);
        return;
    }
    self.suspended = false;
    self.size = viewport;
    const p = try self.ensurePlane(.main, width, height);
    try self.render(scene, p.rtv.?, p.backbuffer.?, width, height, clear, false);
    if (self.capture_next) {
        self.capture_next = false;
        self.captureTexture(p.backbuffer.?, width, height, swap_format) catch |err| log.warn("frame capture failed: {t}", .{err});
    }
    try self.present(p);
}

/// The overlay plane (topmost DirectComposition target, above the window's child
/// HWNDs). An empty scene clears and hides it after one transparent frame.
pub fn drawOverlay(self: *Renderer, scene: *const Scene, viewport: Size) !void {
    if (self.hwnd == null or viewport.width <= 0 or viewport.height <= 0) return;
    const plane = &self.planes[@backingInt(PlaneId.overlay)];
    const empty = scene.isEmpty();
    if (empty and !plane.shown) return;
    const width: u32 = @intCast(viewport.width);
    const height: u32 = @intCast(viewport.height);
    if (self.dev.dcomp == null) return; // no overlay plane without DirectComposition
    const p = try self.ensurePlane(.overlay, width, height);
    try self.render(scene, p.rtv.?, p.backbuffer.?, width, height, color.transparent_black, true);
    try self.present(p);
    p.shown = !empty;
}

/// Ask for a copy of the next presented frame (`takeCapture`).
pub fn requestCapture(self: *Renderer) void {
    self.capture_next = true;
}

/// The captured frame (RGBA8, premultiplied, rows top-down); caller owns `rgba`.
pub fn takeCapture(self: *Renderer) ?Capture {
    const c = self.captured;
    self.captured = null;
    return c;
}

/// The last offscreen frame as tightly packed RGBA8 rows (top row first),
/// premultiplied alpha. Caller owns the slice.
pub fn readPixels(self: *Renderer, gpa: Allocator) ![]u8 {
    const t = self.offscreen orelse return error.NotOffscreen;
    try self.captureTexture(t.tex.?, t.width, t.height, offscreen_format);
    const c = self.captured.?;
    self.captured = null;
    defer self.gpa.free(c.rgba);
    return gpa.dupe(u8, c.rgba);
}

fn captureTexture(self: *Renderer, src: *d3d.ID3D11Texture2D, width: u32, height: u32, format: d3d.DXGI_FORMAT) !void {
    const dev = self.dev;
    const ctx = dev.context;
    if (self.staging.tex == null or self.staging.width != width or self.staging.height != height or self.staging.format != format) {
        self.staging.release();
        try w.check(dev.device.vtbl.CreateTexture2D(dev.device, &.{
            .Width = width,
            .Height = height,
            .Format = format,
            .Usage = d3d.D3D11_USAGE_STAGING,
            .BindFlags = 0,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_READ,
        }, null, &self.staging.tex));
        self.staging.width = width;
        self.staging.height = height;
        self.staging.format = format;
    }
    ctx.vtbl.CopyResource(ctx, @ptrCast(self.staging.tex.?), @ptrCast(src));
    var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
    try w.check(ctx.vtbl.Map(ctx, @ptrCast(self.staging.tex.?), 0, d3d.D3D11_MAP_READ, 0, &mapped));
    defer ctx.vtbl.Unmap(ctx, @ptrCast(self.staging.tex.?), 0);
    const row = width * 4;
    const out = try self.gpa.alloc(u8, @as(usize, row) * height);
    const base: [*]const u8 = @ptrCast(mapped.pData.?);
    for (0..height) |y| {
        const dst = out[y * row ..][0..row];
        @memcpy(dst, base[y * mapped.RowPitch ..][0..row]);
        if (format == d3d.DXGI_FORMAT_B8G8R8A8_UNORM) {
            var i: usize = 0;
            while (i < dst.len) : (i += 4) std.mem.swap(u8, &dst[i], &dst[i + 2]);
        }
    }
    if (self.captured) |c| self.gpa.free(c.rgba);
    self.captured = .{ .width = width, .height = height, .rgba = out };
}

const Target = struct {
    rtv: *d3d.ID3D11RenderTargetView,
    tex: *d3d.ID3D11Texture2D,
    width: u32,
    height: u32,
};

fn render(self: *Renderer, scene: *const Scene, rtv: *d3d.ID3D11RenderTargetView, tex: *d3d.ID3D11Texture2D, width: u32, height: u32, clear: Hsla, keep_alpha: bool) !void {
    try self.syncAtlasTextures();
    self.uploadAtlas();
    try self.uploadInstances(scene);

    const rgba = clear.toRgba();
    const alpha: f32 = if (self.transparent or keep_alpha) rgba.a else 1;
    var rec: Recorder = .{
        .r = self,
        .target = .{ .rtv = rtv, .tex = tex, .width = width, .height = height },
    };
    rec.setupPipeline();
    const ctx = self.dev.context;
    ctx.vtbl.ClearRenderTargetView(ctx, rtv, &.{ rgba.r * alpha, rgba.g * alpha, rgba.b * alpha, alpha });
    rec.bindMain();
    try rec.drawBatches(scene);
    // Leave nothing bound that a later frame (or another plane) writes to.
    const nulls = [_]?*d3d.ID3D11ShaderResourceView{ null, null };
    ctx.vtbl.PSSetShaderResources(ctx, 0, 2, &nulls);
    ctx.vtbl.VSSetShaderResources(ctx, 0, 1, &nulls);
    ctx.vtbl.OMSetRenderTargets(ctx, 0, null, null);
}

// ---------------------------------------------------------------------------------------
// Uploads
// ---------------------------------------------------------------------------------------

fn instanceBuffer(self: *Renderer, kind: InstanceKind) *InstanceBuffer {
    return &self.instances[@backingInt(kind)];
}

/// Copy `bytes` into `kind`'s buffer (growing it), discarding its previous contents.
fn upload(self: *Renderer, kind: InstanceKind, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try self.reserve(kind, bytes.len);
    const b = self.instanceBuffer(kind);
    const dev = self.dev;
    const ctx = dev.context;
    var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
    try w.check(ctx.vtbl.Map(ctx, @ptrCast(b.buffer.?), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped));
    const dst: [*]u8 = @ptrCast(mapped.pData.?);
    @memcpy(dst[0..bytes.len], bytes);
    ctx.vtbl.Unmap(ctx, @ptrCast(b.buffer.?), 0);
}

fn uploadInstances(self: *Renderer, scene: *const Scene) !void {
    try self.upload(.shadow, std.mem.sliceAsBytes(scene.shadows.items));
    try self.upload(.quad, std.mem.sliceAsBytes(scene.quads.items));
    try self.upload(.underline, std.mem.sliceAsBytes(scene.underlines.items));
    try self.upload(.mono_sprite, std.mem.sliceAsBytes(scene.monochrome_sprites.items));
    try self.upload(.subpixel_sprite, std.mem.sliceAsBytes(scene.subpixel_sprites.items));
    try self.upload(.poly_sprite, std.mem.sliceAsBytes(scene.polychrome_sprites.items));
    try self.upload(.backdrop_blur, std.mem.sliceAsBytes(scene.backdrop_blurs.items));
}

fn atlasFormat(kind: AtlasTextureKind) d3d.DXGI_FORMAT {
    return switch (kind) {
        .monochrome => d3d.DXGI_FORMAT_R8_UNORM,
        .polychrome, .subpixel => d3d.DXGI_FORMAT_B8G8R8A8_UNORM,
    };
}

/// Create / destroy GPU textures to mirror the atlas' live slots.
fn syncAtlasTextures(self: *Renderer) !void {
    inline for (comptime std.enums.values(AtlasTextureKind)) |kind| {
        const list = &self.atlas_textures[@backingInt(kind)];
        const slots = self.sprite_atlas.textureSlots(kind);
        while (list.items.len < slots) try list.append(self.gpa, .{});
        for (list.items, 0..) |*gpu, i| {
            const info = self.sprite_atlas.textureInfo(.{ .index = @intCast(i), .kind = kind });
            const want_gen: u32 = if (info) |inf| inf.generation else 0;
            if (gpu.generation == want_gen and (gpu.tex.tex != null or info == null)) continue;
            gpu.tex.release();
            gpu.generation = 0;
            if (info) |inf| {
                const width: u32 = @intCast(inf.size.width);
                const height: u32 = @intCast(inf.size.height);
                gpu.tex = try self.createTexture(width, height, atlasFormat(kind), 1, false, true);
                // New tiles must start transparent: clear with one zeroed upload.
                const bpp: usize = AtlasTextureKind.bytesPerPixel(kind);
                const zeros = try self.gpa.alloc(u8, @as(usize, width) * height * bpp);
                defer self.gpa.free(zeros);
                @memset(zeros, 0);
                const ctx = self.dev.context;
                ctx.vtbl.UpdateSubresource(ctx, @ptrCast(gpu.tex.tex.?), 0, null, zeros.ptr, @intCast(width * bpp), 0);
                gpu.generation = inf.generation;
            }
        }
    }
}

fn uploadAtlas(self: *Renderer) void {
    const ctx = self.dev.context;
    for (self.sprite_atlas.pendingUploads()) |u| {
        const list = &self.atlas_textures[@backingInt(u.texture_id.kind)];
        if (u.texture_id.index >= list.items.len) continue;
        const t = list.items[u.texture_id.index].tex.tex orelse continue;
        const bpp = AtlasTextureKind.bytesPerPixel(u.texture_id.kind);
        const b = u.bounds;
        if (b.size.width <= 0 or b.size.height <= 0) continue;
        const box: d3d.D3D11_BOX = .{
            .left = @intCast(b.origin.x),
            .top = @intCast(b.origin.y),
            .right = @intCast(b.origin.x + b.size.width),
            .bottom = @intCast(b.origin.y + b.size.height),
        };
        ctx.vtbl.UpdateSubresource(ctx, @ptrCast(t), 0, &box, u.data.ptr, @intCast(@as(u32, @intCast(b.size.width)) * bpp), 0);
    }
    self.sprite_atlas.clearUploads();
}

// ---------------------------------------------------------------------------------------
// Command recording
// ---------------------------------------------------------------------------------------

const Recorder = struct {
    r: *Renderer,
    target: Target,
    bound_program: ?*const Program = null,
    bound_blend: ?BlendMode = null,

    fn ctx(rec: *const Recorder) *d3d.ID3D11DeviceContext {
        return rec.r.dev.context;
    }

    fn viewportSize(rec: *const Recorder) [2]f32 {
        return .{ @floatFromInt(rec.target.width), @floatFromInt(rec.target.height) };
    }

    fn setupPipeline(rec: *Recorder) void {
        const c = rec.ctx();
        const dev = rec.r.dev;
        c.vtbl.IASetInputLayout(c, null);
        c.vtbl.IASetPrimitiveTopology(c, d3d.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        c.vtbl.RSSetState(c, dev.rasterizer);
        const samplers = [_]?*d3d.ID3D11SamplerState{dev.sampler};
        c.vtbl.PSSetSamplers(c, 0, 1, &samplers);
        const cbs = [_]?*d3d.ID3D11Buffer{rec.r.constants};
        c.vtbl.VSSetConstantBuffers(c, 0, 1, &cbs);
        c.vtbl.PSSetConstantBuffers(c, 0, 1, &cbs);
    }

    fn setViewport(rec: *Recorder, width: f32, height: f32, scissor: w.RECT) void {
        const c = rec.ctx();
        const vp = [_]d3d.D3D11_VIEWPORT{.{ .Width = width, .Height = height }};
        c.vtbl.RSSetViewports(c, 1, &vp);
        const sc = [_]w.RECT{scissor};
        c.vtbl.RSSetScissorRects(c, 1, &sc);
    }

    fn fullRect(rec: *const Recorder) w.RECT {
        return .{ .left = 0, .top = 0, .right = @intCast(rec.target.width), .bottom = @intCast(rec.target.height) };
    }

    /// Render into the frame's target with a full viewport.
    fn bindMain(rec: *Recorder) void {
        const c = rec.ctx();
        // A texture about to be a render target must not stay bound as a shader input.
        const nulls = [_]?*d3d.ID3D11ShaderResourceView{ null, null };
        c.vtbl.PSSetShaderResources(c, 0, 2, &nulls);
        const rtvs = [_]?*d3d.ID3D11RenderTargetView{rec.target.rtv};
        c.vtbl.OMSetRenderTargets(c, 1, &rtvs, null);
        const vs = rec.viewportSize();
        rec.setViewport(vs[0], vs[1], rec.fullRect());
    }

    fn setConstants(rec: *Recorder, k: DrawConstants) !void {
        const c = rec.ctx();
        const cb = rec.r.constants.?;
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
        try w.check(c.vtbl.Map(c, @ptrCast(cb), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped));
        @as(*align(1) DrawConstants, @ptrCast(mapped.pData.?)).* = k;
        c.vtbl.Unmap(c, @ptrCast(cb), 0);
    }

    fn bind(rec: *Recorder, program: *const Program, blend: BlendMode) void {
        const c = rec.ctx();
        if (rec.bound_program != program) {
            c.vtbl.VSSetShader(c, program.vs, null, 0);
            c.vtbl.PSSetShader(c, program.ps, null, 0);
            rec.bound_program = program;
        }
        if (rec.bound_blend != blend) {
            c.vtbl.OMSetBlendState(c, rec.r.dev.blend[@backingInt(blend)], null, 0xffffffff);
            rec.bound_blend = blend;
        }
    }

    fn bindResources(rec: *Recorder, instances: ?*d3d.ID3D11ShaderResourceView, texture: ?*d3d.ID3D11ShaderResourceView) void {
        const c = rec.ctx();
        const vs = [_]?*d3d.ID3D11ShaderResourceView{instances};
        c.vtbl.VSSetShaderResources(c, 0, 1, &vs);
        const ps = [_]?*d3d.ID3D11ShaderResourceView{ instances, texture };
        c.vtbl.PSSetShaderResources(c, 0, 2, &ps);
    }

    /// One instanced unit-quad draw for `count` primitives starting at `first`.
    fn drawInstances(rec: *Recorder, program: *const Program, blend: BlendMode, kind: InstanceKind, first: usize, count: usize, texture: ?*const Texture) !void {
        if (count == 0) return;
        var k: DrawConstants = .{ .viewport_size = rec.viewportSize(), .first_instance = @intCast(first) };
        if (texture) |t| k.texture_size = .{ @floatFromInt(t.width), @floatFromInt(t.height) };
        try rec.setConstants(k);
        rec.bind(program, blend);
        rec.bindResources(rec.r.instanceBuffer(kind).srv, if (texture) |t| t.srv else null);
        const c = rec.ctx();
        c.vtbl.DrawInstanced(c, 6, @intCast(count), 0, 0);
    }

    fn atlasTexture(rec: *Recorder, id: AtlasTextureId) ?*const Texture {
        const list = &rec.r.atlas_textures[@backingInt(id.kind)];
        if (id.index >= list.items.len) return null;
        const t = &list.items[id.index].tex;
        return if (t.tex != null) t else null;
    }

    fn drawBatches(rec: *Recorder, scene: *const Scene) !void {
        const r = rec.r;
        const s = &r.dev.shaders;
        var blur_index: usize = 0;
        var it = scene.batches();
        while (it.next()) |batch| {
            // Backdrop blurs interleave by draw order outside the batch stream.
            const first = batch.firstOrder(scene);
            while (blur_index < scene.backdrop_blurs.items.len and scene.backdrop_blurs.items[blur_index].order <= first) : (blur_index += 1) {
                try rec.drawBackdropBlur(scene, blur_index);
            }
            const range = batch.range();
            const n = range.end - range.start;
            switch (batch) {
                .shadow => try rec.drawInstances(&s.shadow, .straight, .shadow, range.start, n, null),
                .quad => try rec.drawInstances(&s.quad, .straight, .quad, range.start, n, null),
                .underline => try rec.drawInstances(&s.underline, .straight, .underline, range.start, n, null),
                .monochrome_sprite => |sp| if (rec.atlasTexture(sp.texture_id)) |t|
                    try rec.drawInstances(&s.mono_sprite, .straight, .mono_sprite, range.start, n, t),
                .subpixel_sprite => |sp| if (rec.atlasTexture(sp.texture_id)) |t|
                    try rec.drawInstances(&s.subpixel_sprite, .dual_source, .subpixel_sprite, range.start, n, t),
                .polychrome_sprite => |sp| if (rec.atlasTexture(sp.texture_id)) |t|
                    try rec.drawInstances(&s.poly_sprite, .straight, .poly_sprite, range.start, n, t),
                .path => try rec.drawPaths(scene.paths.items[range.start..range.end]),
                .surface => if (!r.warned_surface) {
                    r.warned_surface = true;
                    log.warn("surfaces are not supported by the D3D11 renderer yet; skipping", .{});
                },
            }
        }
        while (blur_index < scene.backdrop_blurs.items.len) : (blur_index += 1) {
            try rec.drawBackdropBlur(scene, blur_index);
        }
    }

    /// Rasterize paths into the (MSAA) intermediate, resolve, then composite.
    fn drawPaths(rec: *Recorder, paths: []const scene_mod.Path) !void {
        if (paths.len == 0) return;
        const r = rec.r;
        const c = rec.ctx();
        const width = rec.target.width;
        const height = rec.target.height;
        const msaa = r.dev.msaa4;
        try r.ensureTexture(&r.path_resolve, width, height, swap_format, 1, true, true);
        if (msaa) try r.ensureTexture(&r.path_msaa, width, height, swap_format, 4, true, false);

        // Vertices go straight into the mapped buffer (no CPU-side scratch).
        var vertex_count: usize = 0;
        for (paths) |path| vertex_count += path.vertices.items.len;
        const V = scene_mod.PathRasterizationVertex;
        if (vertex_count > 0) {
            const b = r.instanceBuffer(.path_vertex);
            try r.reserve(.path_vertex, vertex_count * @sizeOf(V));
            var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
            try w.check(c.vtbl.Map(c, @ptrCast(b.buffer.?), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped));
            var out: [*]align(1) V = @ptrCast(mapped.pData.?);
            for (paths) |path| {
                const clipped = path.clippedBounds();
                for (path.vertices.items) |v| {
                    out[0] = .{ .xy_position = v.xy_position, .st_position = v.st_position, .color = path.color, .bounds = clipped };
                    out += 1;
                }
            }
            c.vtbl.Unmap(c, @ptrCast(b.buffer.?), 0);
        }

        const raster_target = if (msaa) &r.path_msaa else &r.path_resolve;
        const nulls = [_]?*d3d.ID3D11ShaderResourceView{ null, null };
        c.vtbl.PSSetShaderResources(c, 0, 2, &nulls);
        const rtvs = [_]?*d3d.ID3D11RenderTargetView{raster_target.rtv};
        c.vtbl.OMSetRenderTargets(c, 1, &rtvs, null);
        c.vtbl.ClearRenderTargetView(c, raster_target.rtv.?, &.{ 0, 0, 0, 0 });
        if (vertex_count > 0) {
            try rec.setConstants(.{ .viewport_size = rec.viewportSize() });
            rec.bind(&r.dev.shaders.path_rasterization, .premultiplied);
            rec.bindResources(r.instanceBuffer(.path_vertex).srv, null);
            c.vtbl.Draw(c, @intCast(vertex_count), 0);
        }
        if (msaa) c.vtbl.ResolveSubresource(c, @ptrCast(r.path_resolve.tex.?), 0, @ptrCast(r.path_msaa.tex.?), 0, swap_format);

        rec.bindMain();
        // Copy each pixel once: per-path rects when all orders match (disjoint), else their union.
        const S = scene_mod.PathSprite;
        var sprites: [64]S = undefined;
        var count: usize = 0;
        if (paths[paths.len - 1].order == paths[0].order and paths.len <= sprites.len) {
            for (paths, 0..) |path, i| sprites[i] = .{ .bounds = path.clippedBounds() };
            count = paths.len;
        } else {
            var bounds = paths[0].clippedBounds();
            for (paths[1..]) |path| bounds = bounds.unionWith(path.clippedBounds());
            sprites[0] = .{ .bounds = bounds };
            count = 1;
        }
        try r.upload(.path_sprite, std.mem.sliceAsBytes(sprites[0..count]));
        try rec.drawInstances(&r.dev.shaders.path_sprite, .premultiplied, .path_sprite, 0, count, &r.path_resolve);
    }

    /// Snapshot the padded blur region, blur it (horizontal pass with downsampling,
    /// then vertical) and composite inside the rounded bounds.
    fn drawBackdropBlur(rec: *Recorder, scene: *const Scene, index: usize) !void {
        const r = rec.r;
        const c = rec.ctx();
        const blur = &scene.backdrop_blurs.items[index];
        const wf: f32 = @floatFromInt(rec.target.width);
        const hf: f32 = @floatFromInt(rec.target.height);
        const sigma = @max(blur.blur_radius, 1.0);
        const downsample = std.math.clamp(@floor(sigma / 8.0), 1.0, 4.0);
        const sigma_t = @max(sigma / downsample, 0.5);
        const pad = @ceil(sigma * 3.0) + 2.0 + 2.0 * downsample;
        const visible = blur.bounds.intersect(blur.content_mask.bounds);
        const x0 = @max(@floor(visible.origin.x - pad), 0);
        const y0 = @max(@floor(visible.origin.y - pad), 0);
        const x1 = @min(@ceil(visible.right() + pad), wf);
        const y1 = @min(@ceil(visible.bottom() + pad), hf);
        if (x1 <= x0 or y1 <= y0 or visible.isEmpty()) return;

        const width = rec.target.width;
        const height = rec.target.height;
        try r.ensureTexture(&r.blur_scratch, width, height, swap_format, 1, false, true);
        try r.ensureTexture(&r.blur_a, width, height, swap_format, 1, true, true);
        try r.ensureTexture(&r.blur_b, width, height, swap_format, 1, true, true);

        // 1. Snapshot (the target is R8G8B8A8 offscreen or B8G8R8A8 swapchain: copy needs
        //    matching formats, so the scratch follows the target's format).
        const target_format: d3d.DXGI_FORMAT = if (r.offscreen != null) offscreen_format else swap_format;
        if (r.blur_scratch.format != target_format) {
            r.blur_scratch.release();
            r.blur_scratch = try r.createTexture(width, height, target_format, 1, false, true);
        }
        const box: d3d.D3D11_BOX = .{
            .left = @intFromFloat(x0),
            .top = @intFromFloat(y0),
            .right = @intFromFloat(x1),
            .bottom = @intFromFloat(y1),
        };
        c.vtbl.OMSetRenderTargets(c, 0, null, null);
        c.vtbl.CopySubresourceRegion(c, @ptrCast(r.blur_scratch.tex.?), 0, box.left, box.top, 0, @ptrCast(rec.target.tex), 0, &box);

        // 2. Separable gaussian in a `downsample`-scaled grid.
        const bw = @ceil(wf / downsample);
        const bh = @ceil(hf / downsample);
        const bx0 = @max(@floor(x0 / downsample), 0);
        const by0 = @max(@floor(y0 / downsample), 0);
        const bx1 = @min(@ceil(x1 / downsample), bw);
        const by1 = @min(@ceil(y1 / downsample), bh);
        const area: w.RECT = .{ .left = @intFromFloat(bx0), .top = @intFromFloat(by0), .right = @intFromFloat(bx1), .bottom = @intFromFloat(by1) };
        const tex_size: [2]f32 = .{ wf, hf };
        try rec.blurPass(&r.blur_a, &r.blur_scratch, area, bw, bh, .{
            .texture_size = tex_size,
            .params0 = .{ 1, 0, sigma_t, downsample },
            .params1 = .{ downsample, wf, hf, 0 },
        });
        try rec.blurPass(&r.blur_b, &r.blur_a, area, bw, bh, .{
            .texture_size = tex_size,
            .params0 = .{ 0, 1, sigma_t, 1 },
            .params1 = .{ 1, bw, bh, 0 },
        });

        // 3. Composite (blending disabled; the shader discards outside the rounded rect).
        rec.bindMain();
        try rec.setConstants(.{
            .viewport_size = rec.viewportSize(),
            .texture_size = tex_size,
            .params0 = .{ downsample, bw, bh, 0 },
            .first_instance = @intCast(index),
        });
        rec.bind(&r.dev.shaders.backdrop_blur, .none);
        rec.bindResources(r.instanceBuffer(.backdrop_blur).srv, r.blur_b.srv);
        c.vtbl.DrawInstanced(c, 6, 1, 0, 0);
    }

    fn blurPass(rec: *Recorder, dst: *Texture, src: *const Texture, area: w.RECT, vw: f32, vh: f32, k: DrawConstants) !void {
        const c = rec.ctx();
        const nulls = [_]?*d3d.ID3D11ShaderResourceView{ null, null };
        c.vtbl.PSSetShaderResources(c, 0, 2, &nulls);
        const rtvs = [_]?*d3d.ID3D11RenderTargetView{dst.rtv};
        c.vtbl.OMSetRenderTargets(c, 1, &rtvs, null);
        rec.setViewport(vw, vh, area);
        var kk = k;
        kk.viewport_size = .{ vw, vh };
        try rec.setConstants(kk);
        rec.bind(&rec.r.dev.shaders.blur_pass, .none);
        rec.bindResources(null, src.srv);
        c.vtbl.Draw(c, 3, 0);
    }
};

/// Make sure `kind`'s buffer holds at least `bytes` (contents are then rewritten).
fn reserve(self: *Renderer, kind: InstanceKind, bytes: usize) !void {
    const b = self.instanceBuffer(kind);
    if (b.capacity >= bytes and b.buffer != null) return;
    b.release();
    const dev = self.dev;
    const cap: u32 = @intCast(std.math.ceilPowerOfTwo(usize, @max(bytes, 16 * 1024)) catch bytes);
    const elems = cap / b.stride;
    try w.check(dev.device.vtbl.CreateBuffer(dev.device, &.{
        .ByteWidth = elems * b.stride,
        .Usage = d3d.D3D11_USAGE_DYNAMIC,
        .BindFlags = d3d.D3D11_BIND_SHADER_RESOURCE,
        .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
        .MiscFlags = d3d.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
        .StructureByteStride = b.stride,
    }, null, &b.buffer));
    try w.check(dev.device.vtbl.CreateShaderResourceView(dev.device, @ptrCast(b.buffer.?), &.{
        .Format = d3d.DXGI_FORMAT_UNKNOWN,
        .ViewDimension = d3d.D3D11_SRV_DIMENSION_BUFFER,
        .u = .{ 0, elems, 0, 0 },
    }, &b.srv));
    b.capacity = elems * b.stride;
}
