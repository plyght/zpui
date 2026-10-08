//! The process-wide D3D11 device shared by every zpui window: the device and its
//! immediate context, the DXGI factory, the DirectComposition device, the compiled
//! shaders and the fixed pipeline state objects. Reference counted (`acquire` /
//! `release`); main thread only, like the immediate context.
//!
//! Shaders (shaders.hlsl) compile at runtime with D3DCompile (FXC, vs_5_0 / ps_5_0).
//! Compiled bytecode is cached on disk under %LOCALAPPDATA%\zpui\shader-cache\ keyed
//! by a hash of the source, so only the first launch after a shader change pays for
//! compilation.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("../../platform/windows/win32.zig");
const d3d = @import("d3d11.zig");

const Device = @This();
const log = std.log.scoped(.d3d11);

pub const hlsl_source = @embedFile("shaders.hlsl");

device: *d3d.ID3D11Device,
context: *d3d.ID3D11DeviceContext,
dxgi_device: *d3d.IDXGIDevice,
factory: *d3d.IDXGIFactory2,
/// Null when DirectComposition is unavailable (offscreen use still works).
dcomp: ?*w.IDCompositionDevice,
/// WARP (software) device: no GPU on this machine (CI runners, RDP sessions).
software: bool,
msaa4: bool,
shaders: Shaders = .{},
blend: [4]?*d3d.ID3D11BlendState = .{ null, null, null, null },
rasterizer: ?*d3d.ID3D11RasterizerState = null,
sampler: ?*d3d.ID3D11SamplerState = null,
refs: u32 = 1,

pub const BlendMode = enum(u2) { none, straight, premultiplied, dual_source };

pub const Program = struct {
    vs: ?*d3d.ID3D11VertexShader = null,
    ps: ?*d3d.ID3D11PixelShader = null,
};

pub const Shaders = struct {
    quad: Program = .{},
    shadow: Program = .{},
    underline: Program = .{},
    mono_sprite: Program = .{},
    subpixel_sprite: Program = .{},
    poly_sprite: Program = .{},
    path_rasterization: Program = .{},
    path_sprite: Program = .{},
    blur_pass: Program = .{},
    backdrop_blur: Program = .{},
};

/// (field, vertex entry, pixel entry)
const programs = [_]struct { []const u8, [:0]const u8, [:0]const u8 }{
    .{ "quad", "quad_vertex", "quad_fragment" },
    .{ "shadow", "shadow_vertex", "shadow_fragment" },
    .{ "underline", "underline_vertex", "underline_fragment" },
    .{ "mono_sprite", "mono_sprite_vertex", "mono_sprite_fragment" },
    .{ "subpixel_sprite", "mono_sprite_vertex", "subpixel_sprite_fragment" },
    .{ "poly_sprite", "poly_sprite_vertex", "poly_sprite_fragment" },
    .{ "path_rasterization", "path_rasterization_vertex", "path_rasterization_fragment" },
    .{ "path_sprite", "path_sprite_vertex", "path_sprite_fragment" },
    .{ "blur_pass", "blur_pass_vertex", "blur_pass_fragment" },
    .{ "backdrop_blur", "backdrop_blur_vertex", "backdrop_blur_fragment" },
};

var shared: ?*Device = null;

/// The shared device (created on first use).
pub fn acquire(gpa: std.mem.Allocator) !*Device {
    if (shared) |d| {
        if (d.device.vtbl.GetDeviceRemovedReason(d.device) >= 0) {
            d.refs += 1;
            return d;
        }
        // Device lost (driver update / TDR): leave it to its current users, start fresh.
        log.warn("D3D11 device removed; creating a new one", .{});
        shared = null;
    }
    const d = try gpa.create(Device);
    errdefer gpa.destroy(d);
    d.* = try create(gpa);
    shared = d;
    return d;
}

pub fn release(d: *Device, gpa: std.mem.Allocator) void {
    d.refs -= 1;
    if (d.refs > 0) return;
    if (shared == d) shared = null;
    d.destroy();
    gpa.destroy(d);
}

fn create(gpa: std.mem.Allocator) !Device {
    const levels = [_]w.UINT{ d3d.D3D_FEATURE_LEVEL_11_1, d3d.D3D_FEATURE_LEVEL_11_0 };
    var flags: w.UINT = d3d.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if (w.hasEnv("ZPUI_D3D_DEBUG")) flags |= d3d.D3D11_CREATE_DEVICE_DEBUG;
    var device: ?*d3d.ID3D11Device = null;
    var context: ?*d3d.ID3D11DeviceContext = null;
    var software = w.hasEnv("ZPUI_D3D_WARP");
    var hr: w.HRESULT = -1;
    if (!software) {
        hr = d3d.D3D11CreateDevice(null, d3d.D3D_DRIVER_TYPE_HARDWARE, null, flags, &levels, levels.len, d3d.D3D11_SDK_VERSION, &device, null, &context);
        // Windows 7-era runtimes reject 11_1 in the list; retry with 11_0 only.
        if (hr < 0) hr = d3d.D3D11CreateDevice(null, d3d.D3D_DRIVER_TYPE_HARDWARE, null, flags, levels[1..].ptr, 1, d3d.D3D11_SDK_VERSION, &device, null, &context);
    }
    if (hr < 0) {
        software = true;
        hr = d3d.D3D11CreateDevice(null, d3d.D3D_DRIVER_TYPE_WARP, null, flags, &levels, levels.len, d3d.D3D11_SDK_VERSION, &device, null, &context);
    }
    try w.check(hr);
    errdefer {
        w.release(context);
        w.release(device);
    }

    const dxgi_device = w.queryInterface(device.?, d3d.IDXGIDevice) orelse return error.NoDxgiDevice;
    errdefer w.release(dxgi_device);
    // One queued frame: input-to-photon latency over throughput.
    _ = dxgi_device.vtbl.SetMaximumFrameLatency(dxgi_device, 1);
    var adapter: ?*d3d.IDXGIAdapter = null;
    try w.check(dxgi_device.vtbl.GetAdapter(dxgi_device, &adapter));
    defer w.release(adapter);
    var factory_raw: ?*anyopaque = null;
    try w.check(adapter.?.vtbl.GetParent(adapter.?, &d3d.IDXGIFactory2.iid, &factory_raw));
    const factory: *d3d.IDXGIFactory2 = @ptrCast(@alignCast(factory_raw.?));
    errdefer w.release(factory);

    var dcomp_raw: ?*anyopaque = null;
    const dcomp: ?*w.IDCompositionDevice = if (w.DCompositionCreateDevice(@ptrCast(dxgi_device), &w.IDCompositionDevice.iid, &dcomp_raw) >= 0)
        @ptrCast(@alignCast(dcomp_raw.?))
    else
        null;
    errdefer w.release(dcomp);

    var quality: w.UINT = 0;
    const msaa4 = device.?.vtbl.CheckMultisampleQualityLevels(device.?, d3d.DXGI_FORMAT_B8G8R8A8_UNORM, 4, &quality) >= 0 and quality > 0;

    var self: Device = .{
        .device = device.?,
        .context = context.?,
        .dxgi_device = dxgi_device,
        .factory = factory,
        .dcomp = dcomp,
        .software = software,
        .msaa4 = msaa4,
    };
    errdefer self.destroyStates();
    try self.createStates();
    try self.compileShaders(gpa);
    if (software) log.info("using the WARP software rasterizer", .{});
    return self;
}

fn destroyStates(self: *Device) void {
    inline for (@typeInfo(Shaders).@"struct".field_names) |name| {
        const p = &@field(self.shaders, name);
        w.releaseOpt(&p.vs);
        w.releaseOpt(&p.ps);
    }
    for (&self.blend) |*b| w.releaseOpt(b);
    w.releaseOpt(&self.rasterizer);
    w.releaseOpt(&self.sampler);
}

fn destroy(self: *Device) void {
    self.context.vtbl.ClearState(self.context);
    self.context.vtbl.Flush(self.context);
    self.destroyStates();
    w.release(self.dcomp);
    w.release(self.factory);
    w.release(self.dxgi_device);
    w.release(self.context);
    w.release(self.device);
}

fn createStates(self: *Device) !void {
    const dev = self.device;
    for (std.enums.values(BlendMode)) |mode| {
        var desc: d3d.D3D11_BLEND_DESC = .{};
        const rt = &desc.RenderTarget[0];
        // Alpha always composites source-over so transparent targets stay premultiplied.
        rt.SrcBlendAlpha = d3d.D3D11_BLEND_ONE;
        rt.DestBlendAlpha = d3d.D3D11_BLEND_INV_SRC_ALPHA;
        switch (mode) {
            .none => {},
            .straight => {
                rt.BlendEnable = 1;
                rt.SrcBlend = d3d.D3D11_BLEND_SRC_ALPHA;
                rt.DestBlend = d3d.D3D11_BLEND_INV_SRC_ALPHA;
            },
            .premultiplied => {
                rt.BlendEnable = 1;
                rt.SrcBlend = d3d.D3D11_BLEND_ONE;
                rt.DestBlend = d3d.D3D11_BLEND_INV_SRC_ALPHA;
            },
            .dual_source => {
                rt.BlendEnable = 1;
                rt.SrcBlend = d3d.D3D11_BLEND_SRC1_COLOR;
                rt.DestBlend = d3d.D3D11_BLEND_INV_SRC1_COLOR;
            },
        }
        try w.check(dev.vtbl.CreateBlendState(dev, &desc, &self.blend[@backingInt(mode)]));
    }
    try w.check(dev.vtbl.CreateRasterizerState(dev, &.{ .ScissorEnable = 1 }, &self.rasterizer));
    try w.check(dev.vtbl.CreateSamplerState(dev, &.{
        .Filter = d3d.D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT,
        .AddressU = d3d.D3D11_TEXTURE_ADDRESS_CLAMP,
        .AddressV = d3d.D3D11_TEXTURE_ADDRESS_CLAMP,
        .AddressW = d3d.D3D11_TEXTURE_ADDRESS_CLAMP,
    }, &self.sampler));
}

// ---------------------------------------------------------------------------------------
// Shader compilation + disk cache
// ---------------------------------------------------------------------------------------

const cache_magic = "zpuiDX11";

fn compileShaders(self: *Device, gpa: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    const loaded = cache.load(gpa);
    var dirty = false;
    inline for (programs) |p| {
        const prog = &@field(self.shaders, p[0]);
        const vs = try self.bytecode(gpa, &cache, &dirty, p[1], "vs_5_0");
        try w.check(self.device.vtbl.CreateVertexShader(self.device, vs.ptr, vs.len, null, &prog.vs));
        const ps = try self.bytecode(gpa, &cache, &dirty, p[2], "ps_5_0");
        try w.check(self.device.vtbl.CreatePixelShader(self.device, ps.ptr, ps.len, null, &prog.ps));
    }
    if (dirty or !loaded) cache.store(gpa);
}

fn bytecode(_: *Device, gpa: std.mem.Allocator, cache: *Cache, dirty: *bool, comptime entry: [:0]const u8, comptime profile: [:0]const u8) ![]const u8 {
    if (cache.get(entry, profile)) |code| return code;
    var code_blob: ?*d3d.ID3DBlob = null;
    var errors: ?*d3d.ID3DBlob = null;
    const hr = d3d.D3DCompile(hlsl_source.ptr, hlsl_source.len, "shaders.hlsl", null, null, entry, profile, d3d.D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code_blob, &errors);
    defer w.release(errors);
    if (hr < 0) {
        if (errors) |e| log.err("HLSL {s}: {s}", .{ entry, e.bytes() });
        w.release(code_blob);
        return error.ShaderCompileFailed;
    }
    defer w.release(code_blob);
    dirty.* = true;
    return cache.put(gpa, entry, profile, code_blob.?.bytes());
}

/// `entry/profile -> bytecode`, persisted as one file per shader-source hash.
const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    const Entry = struct { key: []u8, code: []u8 };

    fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        for (c.entries.items) |e| {
            gpa.free(e.key);
            gpa.free(e.code);
        }
        c.entries.deinit(gpa);
    }

    fn keyBuf(buf: []u8, entry: []const u8, profile: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry, profile }) catch entry;
    }

    fn get(c: *Cache, entry: []const u8, profile: []const u8) ?[]const u8 {
        var buf: [96]u8 = undefined;
        const key = keyBuf(&buf, entry, profile);
        for (c.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.code;
        return null;
    }

    fn put(c: *Cache, gpa: std.mem.Allocator, entry: []const u8, profile: []const u8, code: []const u8) ![]const u8 {
        var buf: [96]u8 = undefined;
        const key = try gpa.dupe(u8, keyBuf(&buf, entry, profile));
        errdefer gpa.free(key);
        const owned = try gpa.dupe(u8, code);
        errdefer gpa.free(owned);
        try c.entries.append(gpa, .{ .key = key, .code = owned });
        return owned;
    }

    /// %LOCALAPPDATA%\zpui\shader-cache\<hash>.bin (UTF-16, NUL-terminated).
    fn path(buf: []u16) ?[:0]const u16 {
        var local: [512]u16 = undefined;
        const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &local, local.len);
        if (n == 0 or n >= local.len) return null;
        const hash = std.hash.Wyhash.hash(0, hlsl_source);
        var name: [64]u8 = undefined;
        const tail = std.fmt.bufPrint(&name, "\\zpui\\shader-cache\\{x:0>16}.bin", .{hash}) catch return null;
        if (n + tail.len + 1 > buf.len) return null;
        @memcpy(buf[0..n], local[0..n]);
        for (tail, 0..) |ch, i| buf[n + i] = ch;
        buf[n + tail.len] = 0;
        return buf[0 .. n + tail.len :0];
    }

    fn load(c: *Cache, gpa: std.mem.Allocator) bool {
        var pbuf: [700]u16 = undefined;
        const p = path(&pbuf) orelse return false;
        const bytes = w.readFileAlloc(gpa, p, 16 << 20) orelse return false;
        defer gpa.free(bytes);
        if (bytes.len < cache_magic.len or !std.mem.eql(u8, bytes[0..cache_magic.len], cache_magic)) return false;
        var at: usize = cache_magic.len;
        while (at + 8 <= bytes.len) {
            const klen = std.mem.readInt(u32, bytes[at..][0..4], .little);
            const clen = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
            at += 8;
            if (at + klen + clen > bytes.len) return false;
            const key = gpa.dupe(u8, bytes[at..][0..klen]) catch return false;
            const code = gpa.dupe(u8, bytes[at + klen ..][0..clen]) catch {
                gpa.free(key);
                return false;
            };
            c.entries.append(gpa, .{ .key = key, .code = code }) catch {
                gpa.free(key);
                gpa.free(code);
                return false;
            };
            at += klen + clen;
        }
        return true;
    }

    fn store(c: *Cache, gpa: std.mem.Allocator) void {
        var pbuf: [700]u16 = undefined;
        const p = path(&pbuf) orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        out.appendSlice(gpa, cache_magic) catch return;
        for (c.entries.items) |e| {
            var hdr: [8]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], @intCast(e.key.len), .little);
            std.mem.writeInt(u32, hdr[4..8], @intCast(e.code.len), .little);
            out.appendSlice(gpa, &hdr) catch return;
            out.appendSlice(gpa, e.key) catch return;
            out.appendSlice(gpa, e.code) catch return;
        }
        w.writeFileCreatingDirs(p, out.items);
    }
};
