//! Typed wrappers for the slice of Metal, QuartzCore (CAMetalLayer) and
//! MetalPerformanceShaders that the Metal renderer uses. Every wrapper names
//! its selector exactly once, with the C argument types from Apple's headers,
//! so signatures are checked in one place.
//!
//! Ownership follows Cocoa rules: `new*`/`alloc`/`copy` results are +1 and must
//! be `release`d; everything else is autoreleased or borrowed.

const objc = @import("objc.zig");

const id = objc.id;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;
const BOOL = objc.BOOL;

// ---------------------------------------------------------------------------
// Enums / option sets (values from <Metal/*.h>)
// ---------------------------------------------------------------------------

pub const PixelFormat = enum(NSUInteger) {
    invalid = 0,
    a8_unorm = 1,
    r8_unorm = 10,
    rg8_unorm = 30,
    rgba8_unorm = 70,
    bgra8_unorm = 80,
    bgra8_unorm_srgb = 81,
    _,
};

/// `MTLResourceOptions` (CPU cache mode | storage mode << 4).
pub const ResourceOptions = struct {
    pub const cpu_cache_mode_default: NSUInteger = 0;
    pub const cpu_cache_mode_write_combined: NSUInteger = 1;
    pub const storage_mode_shared: NSUInteger = 0 << 4;
    pub const storage_mode_managed: NSUInteger = 1 << 4;
    pub const storage_mode_private: NSUInteger = 2 << 4;
};

pub const StorageMode = enum(NSUInteger) { shared = 0, managed = 1, private = 2, memoryless = 3 };

/// `MTLTextureUsage` bit set.
pub const TextureUsage = struct {
    pub const shader_read: NSUInteger = 0x1;
    pub const shader_write: NSUInteger = 0x2;
    pub const render_target: NSUInteger = 0x4;
};

pub const TextureType = enum(NSUInteger) { @"2d" = 2, @"2d_multisample" = 4 };
pub const LoadAction = enum(NSUInteger) { dont_care = 0, load = 1, clear = 2 };
pub const StoreAction = enum(NSUInteger) { dont_care = 0, store = 1, multisample_resolve = 2 };
pub const PrimitiveType = enum(NSUInteger) { point = 0, line = 1, line_strip = 2, triangle = 3, triangle_strip = 4 };

pub const BlendFactor = enum(NSUInteger) {
    zero = 0,
    one = 1,
    source_alpha = 4,
    one_minus_source_alpha = 5,
};

pub const BlendOperation = enum(NSUInteger) { add = 0 };

/// `MTLGPUFamily` (NSInteger).
pub const GPUFamily = enum(NSInteger) { apple1 = 1001, mac2 = 2002, _ };

pub const CommandBufferStatus = enum(NSUInteger) {
    not_enqueued = 0,
    enqueued = 1,
    committed = 2,
    scheduled = 3,
    completed = 4,
    @"error" = 5,
    _,
};

/// `MPSImageEdgeMode`.
pub const MPSImageEdgeMode = enum(NSUInteger) { zero = 0, clamp = 1 };

/// `CAAutoresizingMask`.
pub const AutoresizingMask = struct {
    pub const width_sizable: c_uint = 1 << 1;
    pub const height_sizable: c_uint = 1 << 4;
};

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

pub const Origin = extern struct { x: NSUInteger = 0, y: NSUInteger = 0, z: NSUInteger = 0 };
pub const Size = extern struct { width: NSUInteger, height: NSUInteger, depth: NSUInteger = 1 };
pub const Region = extern struct { origin: Origin, size: Size };
pub const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
pub const Viewport = extern struct {
    originX: f64,
    originY: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

// ---------------------------------------------------------------------------
// C functions
// ---------------------------------------------------------------------------

/// +1 reference, or null when no Metal device exists.
pub extern "c" fn MTLCreateSystemDefaultDevice() ?id;
/// +1 `NSArray<id<MTLDevice>>` (macOS only).
pub extern "c" fn MTLCopyAllDevices() ?id;
/// From MetalPerformanceShaders. Referencing it also keeps the framework
/// linked, which `objc_getClass("MPSImageGaussianBlur")` relies on.
pub extern "c" fn MPSSupportsMTLDevice(device: ?id) BOOL;

// ---------------------------------------------------------------------------
// NSArray
// ---------------------------------------------------------------------------

pub fn arrayCount(array: id) NSUInteger {
    return array.msg(NSUInteger, "count", .{});
}

pub fn arrayObjectAt(array: id, index: NSUInteger) id {
    return array.msg(id, "objectAtIndex:", .{index});
}

// ---------------------------------------------------------------------------
// MTLDevice
// ---------------------------------------------------------------------------

pub const Device = struct {
    pub fn isRemovable(device: id) bool {
        return objc.fromBOOL(device.msg(BOOL, "isRemovable", .{}));
    }

    pub fn isLowPower(device: id) bool {
        return objc.fromBOOL(device.msg(BOOL, "isLowPower", .{}));
    }

    pub fn hasUnifiedMemory(device: id) bool {
        return objc.fromBOOL(device.msg(BOOL, "hasUnifiedMemory", .{}));
    }

    pub fn supportsFamily(device: id, family: GPUFamily) bool {
        return objc.fromBOOL(device.msg(BOOL, "supportsFamily:", .{@intFromEnum(family)}));
    }

    pub fn newCommandQueue(device: id) ?id {
        return device.msg(?id, "newCommandQueue", .{});
    }

    /// +1 library; on failure `err_out` receives an autoreleased NSError.
    pub fn newLibraryWithSource(device: id, source: id, err_out: *?id) ?id {
        return device.msg(?id, "newLibraryWithSource:options:error:", .{ source, @as(?id, null), err_out });
    }

    pub fn newRenderPipelineState(device: id, descriptor: id, err_out: *?id) ?id {
        return device.msg(?id, "newRenderPipelineStateWithDescriptor:error:", .{ descriptor, err_out });
    }

    pub fn newBuffer(device: id, length: NSUInteger, options: NSUInteger) ?id {
        return device.msg(?id, "newBufferWithLength:options:", .{ length, options });
    }

    pub fn newBufferWithBytes(device: id, bytes: *const anyopaque, length: NSUInteger, options: NSUInteger) ?id {
        return device.msg(?id, "newBufferWithBytes:length:options:", .{ bytes, length, options });
    }

    pub fn newTexture(device: id, descriptor: id) ?id {
        return device.msg(?id, "newTextureWithDescriptor:", .{descriptor});
    }
};

pub fn newFunction(library: id, name: [:0]const u8) ?id {
    return library.msg(?id, "newFunctionWithName:", .{objc.nsString(name)});
}

// ---------------------------------------------------------------------------
// Pipeline descriptors
// ---------------------------------------------------------------------------

pub const Blend = struct {
    src_rgb: BlendFactor,
    src_alpha: BlendFactor,
    dst_rgb: BlendFactor,
    dst_alpha: BlendFactor,
};

pub const RenderPipelineDescriptor = struct {
    /// +1 `MTLRenderPipelineDescriptor`.
    pub fn new() ?id {
        return (objc.getClass("MTLRenderPipelineDescriptor") orelse return null).new();
    }

    pub fn setLabel(desc: id, label: [:0]const u8) void {
        desc.msg(void, "setLabel:", .{objc.nsString(label)});
    }

    pub fn setVertexFunction(desc: id, function: id) void {
        desc.msg(void, "setVertexFunction:", .{function});
    }

    pub fn setFragmentFunction(desc: id, function: id) void {
        desc.msg(void, "setFragmentFunction:", .{function});
    }

    pub fn setRasterSampleCount(desc: id, count: NSUInteger) void {
        desc.msg(void, "setRasterSampleCount:", .{count});
    }

    pub fn setAlphaToCoverageEnabled(desc: id, enabled: bool) void {
        desc.msg(void, "setAlphaToCoverageEnabled:", .{objc.toBOOL(enabled)});
    }

    /// Configure color attachment 0: pixel format and optional blending (`Add` ops).
    pub fn setColorAttachment0(desc: id, format: PixelFormat, blend: ?Blend) void {
        const attachments = desc.msg(id, "colorAttachments", .{});
        const a = attachments.msg(id, "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        a.msg(void, "setPixelFormat:", .{@intFromEnum(format)});
        if (blend) |b| {
            a.msg(void, "setBlendingEnabled:", .{objc.YES});
            a.msg(void, "setRgbBlendOperation:", .{@intFromEnum(BlendOperation.add)});
            a.msg(void, "setAlphaBlendOperation:", .{@intFromEnum(BlendOperation.add)});
            a.msg(void, "setSourceRGBBlendFactor:", .{@intFromEnum(b.src_rgb)});
            a.msg(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(b.src_alpha)});
            a.msg(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(b.dst_rgb)});
            a.msg(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(b.dst_alpha)});
        } else {
            a.msg(void, "setBlendingEnabled:", .{objc.NO});
        }
    }
};

pub const TextureDescriptor = struct {
    pub const Options = struct {
        width: NSUInteger,
        height: NSUInteger,
        format: PixelFormat,
        usage: NSUInteger,
        storage: StorageMode,
        texture_type: TextureType = .@"2d",
        sample_count: NSUInteger = 1,
    };

    /// +1 `MTLTextureDescriptor` configured from `o`.
    pub fn new(o: Options) ?id {
        const desc = (objc.getClass("MTLTextureDescriptor") orelse return null).new() orelse return null;
        desc.msg(void, "setTextureType:", .{@intFromEnum(o.texture_type)});
        desc.msg(void, "setPixelFormat:", .{@intFromEnum(o.format)});
        desc.msg(void, "setWidth:", .{o.width});
        desc.msg(void, "setHeight:", .{o.height});
        desc.msg(void, "setUsage:", .{o.usage});
        desc.msg(void, "setStorageMode:", .{@intFromEnum(o.storage)});
        if (o.sample_count > 1) desc.msg(void, "setSampleCount:", .{o.sample_count});
        return desc;
    }
};

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

pub const Texture = struct {
    pub fn width(texture: id) NSUInteger {
        return texture.msg(NSUInteger, "width", .{});
    }

    pub fn height(texture: id) NSUInteger {
        return texture.msg(NSUInteger, "height", .{});
    }

    pub fn pixelFormat(texture: id) PixelFormat {
        return @enumFromInt(texture.msg(NSUInteger, "pixelFormat", .{}));
    }

    pub fn replaceRegion(texture: id, region: Region, bytes: *const anyopaque, bytes_per_row: NSUInteger) void {
        texture.msg(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(NSUInteger, 0), bytes, bytes_per_row });
    }
};

pub const Buffer = struct {
    pub fn contents(buffer: id) [*]u8 {
        return buffer.msg([*]u8, "contents", .{});
    }

    pub fn length(buffer: id) NSUInteger {
        return buffer.msg(NSUInteger, "length", .{});
    }

    /// Managed-storage buffers only: flush CPU writes in `range` to the GPU.
    pub fn didModifyRange(buffer: id, range: objc.NSRange) void {
        buffer.msg(void, "didModifyRange:", .{range});
    }
};

// ---------------------------------------------------------------------------
// Command submission
// ---------------------------------------------------------------------------

pub const CommandBuffer = struct {
    /// Autoreleased command buffer from `queue`.
    pub fn fromQueue(queue: id) ?id {
        return queue.msg(?id, "commandBuffer", .{});
    }

    pub fn renderCommandEncoder(cb: id, pass: id) ?id {
        return cb.msg(?id, "renderCommandEncoderWithDescriptor:", .{pass});
    }

    pub fn blitCommandEncoder(cb: id) ?id {
        return cb.msg(?id, "blitCommandEncoder", .{});
    }

    pub fn presentDrawable(cb: id, drawable: id) void {
        cb.msg(void, "presentDrawable:", .{drawable});
    }

    pub fn commit(cb: id) void {
        cb.msg(void, "commit", .{});
    }

    pub fn waitUntilCompleted(cb: id) void {
        cb.msg(void, "waitUntilCompleted", .{});
    }

    pub fn waitUntilScheduled(cb: id) void {
        cb.msg(void, "waitUntilScheduled", .{});
    }

    pub fn status(cb: id) CommandBufferStatus {
        return @enumFromInt(cb.msg(NSUInteger, "status", .{}));
    }

    pub fn @"error"(cb: id) ?id {
        return cb.msg(?id, "error", .{});
    }
};

pub const RenderPassDescriptor = struct {
    pub const Attachment = struct {
        texture: id,
        resolve_texture: ?id = null,
        load: LoadAction,
        store: StoreAction,
        clear: ClearColor = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
    };

    /// Autoreleased pass descriptor with color attachment 0 configured.
    pub fn new(a: Attachment) ?id {
        const desc = (objc.getClass("MTLRenderPassDescriptor") orelse return null)
            .msg(?id, "renderPassDescriptor", .{}) orelse return null;
        const attachments = desc.msg(id, "colorAttachments", .{});
        const c = attachments.msg(id, "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        c.msg(void, "setTexture:", .{a.texture});
        if (a.resolve_texture) |r| c.msg(void, "setResolveTexture:", .{r});
        c.msg(void, "setLoadAction:", .{@intFromEnum(a.load)});
        c.msg(void, "setStoreAction:", .{@intFromEnum(a.store)});
        if (a.load == .clear) c.msg(void, "setClearColor:", .{a.clear});
        return desc;
    }
};

pub const RenderEncoder = struct {
    pub fn setPipeline(enc: id, pipeline: id) void {
        enc.msg(void, "setRenderPipelineState:", .{pipeline});
    }

    pub fn setViewport(enc: id, viewport: Viewport) void {
        enc.msg(void, "setViewport:", .{viewport});
    }

    pub fn setVertexBuffer(enc: id, buffer: id, offset: NSUInteger, index: NSUInteger) void {
        enc.msg(void, "setVertexBuffer:offset:atIndex:", .{ buffer, offset, index });
    }

    pub fn setFragmentBuffer(enc: id, buffer: id, offset: NSUInteger, index: NSUInteger) void {
        enc.msg(void, "setFragmentBuffer:offset:atIndex:", .{ buffer, offset, index });
    }

    /// Inline constant data (< 4 KiB), copied at encode time.
    pub fn setVertexBytes(enc: id, bytes: *const anyopaque, len: NSUInteger, index: NSUInteger) void {
        enc.msg(void, "setVertexBytes:length:atIndex:", .{ bytes, len, index });
    }

    pub fn setFragmentBytes(enc: id, bytes: *const anyopaque, len: NSUInteger, index: NSUInteger) void {
        enc.msg(void, "setFragmentBytes:length:atIndex:", .{ bytes, len, index });
    }

    pub fn setFragmentTexture(enc: id, texture: id, index: NSUInteger) void {
        enc.msg(void, "setFragmentTexture:atIndex:", .{ texture, index });
    }

    pub fn draw(enc: id, primitive: PrimitiveType, start: NSUInteger, count: NSUInteger) void {
        enc.msg(void, "drawPrimitives:vertexStart:vertexCount:", .{ @intFromEnum(primitive), start, count });
    }

    pub fn drawInstanced(enc: id, primitive: PrimitiveType, start: NSUInteger, count: NSUInteger, instances: NSUInteger) void {
        enc.msg(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @intFromEnum(primitive), start, count, instances });
    }

    pub fn endEncoding(enc: id) void {
        enc.msg(void, "endEncoding", .{});
    }
};

pub const BlitEncoder = struct {
    pub fn copyTexture(enc: id, src: id, src_origin: Origin, size: Size, dst: id, dst_origin: Origin) void {
        enc.msg(void, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            src,       @as(NSUInteger, 0), @as(NSUInteger, 0), src_origin, size,
            dst,       @as(NSUInteger, 0), @as(NSUInteger, 0), dst_origin,
        });
    }

    pub fn copyTextureToBuffer(enc: id, src: id, size: Size, dst: id, bytes_per_row: NSUInteger) void {
        enc.msg(void, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
            src,                @as(NSUInteger, 0), @as(NSUInteger, 0), Origin{},             size,
            dst,                @as(NSUInteger, 0), bytes_per_row,      bytes_per_row * size.height,
        });
    }

    pub fn endEncoding(enc: id) void {
        enc.msg(void, "endEncoding", .{});
    }
};

// ---------------------------------------------------------------------------
// CAMetalLayer / CAMetalDrawable
// ---------------------------------------------------------------------------

pub const Layer = struct {
    /// +1 `CAMetalLayer`.
    pub fn new() ?id {
        return (objc.getClass("CAMetalLayer") orelse return null).new();
    }

    pub fn setDevice(layer: id, device: id) void {
        layer.msg(void, "setDevice:", .{device});
    }

    pub fn setPixelFormat(layer: id, format: PixelFormat) void {
        layer.msg(void, "setPixelFormat:", .{@intFromEnum(format)});
    }

    pub fn setOpaque(layer: id, is_opaque: bool) void {
        layer.msg(void, "setOpaque:", .{objc.toBOOL(is_opaque)});
    }

    pub fn setMaximumDrawableCount(layer: id, count: NSUInteger) void {
        layer.msg(void, "setMaximumDrawableCount:", .{count});
    }

    pub fn setFramebufferOnly(layer: id, value: bool) void {
        layer.msg(void, "setFramebufferOnly:", .{objc.toBOOL(value)});
    }

    pub fn setAllowsNextDrawableTimeout(layer: id, value: bool) void {
        layer.msg(void, "setAllowsNextDrawableTimeout:", .{objc.toBOOL(value)});
    }

    pub fn setNeedsDisplayOnBoundsChange(layer: id, value: bool) void {
        layer.msg(void, "setNeedsDisplayOnBoundsChange:", .{objc.toBOOL(value)});
    }

    pub fn setAutoresizingMask(layer: id, mask: c_uint) void {
        layer.msg(void, "setAutoresizingMask:", .{mask});
    }

    pub fn setPresentsWithTransaction(layer: id, value: bool) void {
        layer.msg(void, "setPresentsWithTransaction:", .{objc.toBOOL(value)});
    }

    pub fn setDrawableSize(layer: id, size: objc.CGSize) void {
        layer.msg(void, "setDrawableSize:", .{size});
    }

    pub fn drawableSize(layer: id) objc.CGSize {
        return layer.msg(objc.CGSize, "drawableSize", .{});
    }

    /// Autoreleased `id<CAMetalDrawable>`; null on timeout.
    pub fn nextDrawable(layer: id) ?id {
        return layer.msg(?id, "nextDrawable", .{});
    }
};

pub fn drawableTexture(drawable: id) id {
    return drawable.msg(id, "texture", .{});
}

pub fn drawablePresent(drawable: id) void {
    drawable.msg(void, "present", .{});
}

// ---------------------------------------------------------------------------
// MPSImageGaussianBlur
// ---------------------------------------------------------------------------

pub const GaussianBlur = struct {
    /// +1 `MPSImageGaussianBlur` with the given sigma and clamp edges.
    pub fn new(device: id, sigma: f32) ?id {
        const class = objc.getClass("MPSImageGaussianBlur") orelse return null;
        const alloc = class.msg(?id, "alloc", .{}) orelse return null;
        const kernel = alloc.msg(?id, "initWithDevice:sigma:", .{ device, sigma }) orelse return null;
        // Clamp edges: the default zero edge mode bleeds transparent black
        // into blurs near the window border (dark vignette).
        kernel.msg(void, "setEdgeMode:", .{@intFromEnum(MPSImageEdgeMode.clamp)});
        return kernel;
    }

    pub fn encode(kernel: id, command_buffer: id, source: id, destination: id) void {
        kernel.msg(void, "encodeToCommandBuffer:sourceTexture:destinationTexture:", .{ command_buffer, source, destination });
    }
};
