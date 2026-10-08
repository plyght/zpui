//! Hand-written D3D11 / DXGI / D3DCompiler bindings for the D3D11 renderer.
//!
//! Vtables list every slot in SDK order (inherited first); slots zpui never calls are
//! `Unused` placeholders (or `[N]Unused` runs) so the offsets of the used ones are right.

const std = @import("std");
const w = @import("../../platform/windows/win32.zig");

const WINAPI = w.WINAPI;
const HRESULT = w.HRESULT;
const BOOL = w.BOOL;
const UINT = w.UINT;
const GUID = w.GUID;
const Unused = w.Unused;
const IUnknownMethods = w.IUnknownMethods;

// ---- enums / constants --------------------------------------------------------------------

pub const DXGI_FORMAT = u32;
pub const DXGI_FORMAT_UNKNOWN: DXGI_FORMAT = 0;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: DXGI_FORMAT = 28;
pub const DXGI_FORMAT_R8_UNORM: DXGI_FORMAT = 61;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: DXGI_FORMAT = 87;

pub const DXGI_USAGE_SHADER_INPUT: UINT = 0x10;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;
pub const DXGI_SCALING_STRETCH: UINT = 0;
pub const DXGI_SCALING_NONE: UINT = 1;
pub const DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL: UINT = 3;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: UINT = 4;
pub const DXGI_ALPHA_MODE_UNSPECIFIED: UINT = 0;
pub const DXGI_ALPHA_MODE_PREMULTIPLIED: UINT = 1;
pub const DXGI_ALPHA_MODE_IGNORE: UINT = 3;
pub const DXGI_MWA_NO_ALT_ENTER: UINT = 0x2;
pub const DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: UINT = 0x40;
pub const DXGI_PRESENT_DO_NOT_WAIT: UINT = 0x8;
pub const DXGI_ERROR_WAS_STILL_DRAWING: HRESULT = @bitCast(@as(u32, 0x887A000A));
pub const DXGI_STATUS_OCCLUDED: HRESULT = 0x087A0001;
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));

pub const D3D_DRIVER_TYPE_HARDWARE: UINT = 1;
pub const D3D_DRIVER_TYPE_WARP: UINT = 5;
pub const D3D_FEATURE_LEVEL_11_0: UINT = 0xb000;
pub const D3D_FEATURE_LEVEL_11_1: UINT = 0xb100;
pub const D3D11_SDK_VERSION: UINT = 7;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: UINT = 0x20;
pub const D3D11_CREATE_DEVICE_DEBUG: UINT = 0x2;

pub const D3D11_USAGE_DEFAULT: UINT = 0;
pub const D3D11_USAGE_DYNAMIC: UINT = 2;
pub const D3D11_USAGE_STAGING: UINT = 3;
pub const D3D11_BIND_CONSTANT_BUFFER: UINT = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: UINT = 0x8;
pub const D3D11_BIND_RENDER_TARGET: UINT = 0x20;
pub const D3D11_CPU_ACCESS_WRITE: UINT = 0x10000;
pub const D3D11_CPU_ACCESS_READ: UINT = 0x20000;
pub const D3D11_RESOURCE_MISC_BUFFER_STRUCTURED: UINT = 0x40;
pub const D3D11_MAP_READ: UINT = 1;
pub const D3D11_MAP_WRITE_DISCARD: UINT = 4;
pub const D3D11_STANDARD_MULTISAMPLE_PATTERN: UINT = 0xffffffff;
pub const D3D11_SRV_DIMENSION_BUFFER: UINT = 1;
pub const D3D11_SRV_DIMENSION_TEXTURE2D: UINT = 4;

pub const D3D11_BLEND_ZERO: UINT = 1;
pub const D3D11_BLEND_ONE: UINT = 2;
pub const D3D11_BLEND_SRC_ALPHA: UINT = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: UINT = 6;
pub const D3D11_BLEND_SRC1_COLOR: UINT = 16;
pub const D3D11_BLEND_INV_SRC1_COLOR: UINT = 17;
pub const D3D11_BLEND_OP_ADD: UINT = 1;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: u8 = 0xF;
pub const D3D11_FILL_SOLID: UINT = 3;
pub const D3D11_CULL_NONE: UINT = 1;
pub const D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT: UINT = 0x14;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: UINT = 3;
pub const D3D11_COMPARISON_NEVER: UINT = 1;
pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST: UINT = 4;

pub const D3DCOMPILE_OPTIMIZATION_LEVEL3: UINT = 1 << 15;
pub const D3DCOMPILE_ENABLE_STRICTNESS: UINT = 1 << 11;

// ---- structs ------------------------------------------------------------------------------

pub const DXGI_SAMPLE_DESC = extern struct { Count: UINT = 1, Quality: UINT = 0 };

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: UINT,
    Height: UINT,
    Format: DXGI_FORMAT,
    Stereo: BOOL = 0,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: UINT,
    BufferCount: UINT,
    Scaling: UINT,
    SwapEffect: UINT,
    AlphaMode: UINT,
    Flags: UINT = 0,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: UINT,
    Usage: UINT,
    BindFlags: UINT,
    CPUAccessFlags: UINT = 0,
    MiscFlags: UINT = 0,
    StructureByteStride: UINT = 0,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    MipLevels: UINT = 1,
    ArraySize: UINT = 1,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    Usage: UINT = D3D11_USAGE_DEFAULT,
    BindFlags: UINT,
    CPUAccessFlags: UINT = 0,
    MiscFlags: UINT = 0,
};

pub const D3D11_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: UINT,
    /// Union: Buffer { FirstElement, NumElements } / Texture2D { MostDetailedMip, MipLevels } / ...
    u: [4]UINT = .{ 0, 0, 0, 0 },
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: UINT = 0,
    SysMemSlicePitch: UINT = 0,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: UINT = 0,
    DepthPitch: UINT = 0,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32 = 0,
    TopLeftY: f32 = 0,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

pub const D3D11_BOX = extern struct { left: UINT, top: UINT, front: UINT = 0, right: UINT, bottom: UINT, back: UINT = 1 };

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = 0,
    SrcBlend: UINT = D3D11_BLEND_ONE,
    DestBlend: UINT = D3D11_BLEND_ZERO,
    BlendOp: UINT = D3D11_BLEND_OP_ADD,
    SrcBlendAlpha: UINT = D3D11_BLEND_ONE,
    DestBlendAlpha: UINT = D3D11_BLEND_ZERO,
    BlendOpAlpha: UINT = D3D11_BLEND_OP_ADD,
    RenderTargetWriteMask: u8 = D3D11_COLOR_WRITE_ENABLE_ALL,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = 0,
    IndependentBlendEnable: BOOL = 0,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC = @splat(.{}),
};

pub const D3D11_RASTERIZER_DESC = extern struct {
    FillMode: UINT = D3D11_FILL_SOLID,
    CullMode: UINT = D3D11_CULL_NONE,
    FrontCounterClockwise: BOOL = 0,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: BOOL = 1,
    ScissorEnable: BOOL = 0,
    MultisampleEnable: BOOL = 0,
    AntialiasedLineEnable: BOOL = 0,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: UINT,
    AddressU: UINT,
    AddressV: UINT,
    AddressW: UINT,
    MipLODBias: f32 = 0,
    MaxAnisotropy: UINT = 1,
    ComparisonFunc: UINT = D3D11_COMPARISON_NEVER,
    BorderColor: [4]f32 = .{ 0, 0, 0, 0 },
    MinLOD: f32 = 0,
    MaxLOD: f32 = 0,
};

// ---- interfaces ---------------------------------------------------------------------------

/// Any D3D11 / DXGI object we only hold and release.
pub const IResource = extern struct {
    vtbl: *const IUnknownMethods(IResource),
};
pub const ID3D11Buffer = IResource;
pub const ID3D11Texture2D = IResource;
pub const ID3D11ShaderResourceView = IResource;
pub const ID3D11RenderTargetView = IResource;
pub const ID3D11VertexShader = IResource;
pub const ID3D11PixelShader = IResource;
pub const ID3D11BlendState = IResource;
pub const ID3D11RasterizerState = IResource;
pub const ID3D11SamplerState = IResource;

pub const ID3D11Device = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        base: IUnknownMethods(ID3D11Device),
        CreateBuffer: *const fn (*ID3D11Device, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(WINAPI) HRESULT,
        CreateTexture1D: Unused,
        CreateTexture2D: *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(WINAPI) HRESULT,
        CreateTexture3D: Unused,
        CreateShaderResourceView: *const fn (*ID3D11Device, *IResource, ?*const D3D11_SHADER_RESOURCE_VIEW_DESC, *?*ID3D11ShaderResourceView) callconv(WINAPI) HRESULT,
        CreateUnorderedAccessView: Unused,
        CreateRenderTargetView: *const fn (*ID3D11Device, *IResource, ?*const anyopaque, *?*ID3D11RenderTargetView) callconv(WINAPI) HRESULT,
        CreateDepthStencilView: Unused,
        CreateInputLayout: Unused,
        CreateVertexShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11VertexShader) callconv(WINAPI) HRESULT,
        CreateGeometryShader: Unused,
        CreateGeometryShaderWithStreamOutput: Unused,
        CreatePixelShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11PixelShader) callconv(WINAPI) HRESULT,
        CreateHullShader: Unused,
        CreateDomainShader: Unused,
        CreateComputeShader: Unused,
        CreateClassLinkage: Unused,
        CreateBlendState: *const fn (*ID3D11Device, *const D3D11_BLEND_DESC, *?*ID3D11BlendState) callconv(WINAPI) HRESULT,
        CreateDepthStencilState: Unused,
        CreateRasterizerState: *const fn (*ID3D11Device, *const D3D11_RASTERIZER_DESC, *?*ID3D11RasterizerState) callconv(WINAPI) HRESULT,
        CreateSamplerState: *const fn (*ID3D11Device, *const D3D11_SAMPLER_DESC, *?*ID3D11SamplerState) callconv(WINAPI) HRESULT,
        CreateQuery: Unused,
        CreatePredicate: Unused,
        CreateCounter: Unused,
        CreateDeferredContext: Unused,
        OpenSharedResource: Unused,
        CheckFormatSupport: Unused,
        CheckMultisampleQualityLevels: *const fn (*ID3D11Device, DXGI_FORMAT, UINT, *UINT) callconv(WINAPI) HRESULT,
        CheckCounterInfo: Unused,
        CheckCounter: Unused,
        CheckFeatureSupport: Unused,
        GetPrivateData: Unused,
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetFeatureLevel: *const fn (*ID3D11Device) callconv(WINAPI) UINT,
        GetCreationFlags: Unused,
        GetDeviceRemovedReason: *const fn (*ID3D11Device) callconv(WINAPI) HRESULT,
    };
};

pub const ID3D11DeviceContext = extern struct {
    vtbl: *const VTable,
    const Ctx = ID3D11DeviceContext;
    pub const VTable = extern struct {
        base: IUnknownMethods(Ctx),
        // ID3D11DeviceChild
        GetDevice: Unused,
        GetPrivateData: Unused,
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        // ID3D11DeviceContext
        VSSetConstantBuffers: *const fn (*Ctx, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(WINAPI) void,
        PSSetShaderResources: *const fn (*Ctx, UINT, UINT, [*]const ?*ID3D11ShaderResourceView) callconv(WINAPI) void,
        PSSetShader: *const fn (*Ctx, ?*ID3D11PixelShader, ?*const anyopaque, UINT) callconv(WINAPI) void,
        PSSetSamplers: *const fn (*Ctx, UINT, UINT, [*]const ?*ID3D11SamplerState) callconv(WINAPI) void,
        VSSetShader: *const fn (*Ctx, ?*ID3D11VertexShader, ?*const anyopaque, UINT) callconv(WINAPI) void,
        DrawIndexed: Unused,
        Draw: *const fn (*Ctx, UINT, UINT) callconv(WINAPI) void,
        Map: *const fn (*Ctx, *IResource, UINT, UINT, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(WINAPI) HRESULT,
        Unmap: *const fn (*Ctx, *IResource, UINT) callconv(WINAPI) void,
        PSSetConstantBuffers: *const fn (*Ctx, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(WINAPI) void,
        IASetInputLayout: *const fn (*Ctx, ?*IResource) callconv(WINAPI) void,
        IASetVertexBuffers: Unused,
        IASetIndexBuffer: Unused,
        DrawIndexedInstanced: Unused,
        DrawInstanced: *const fn (*Ctx, UINT, UINT, UINT, UINT) callconv(WINAPI) void,
        GSSetConstantBuffers: Unused,
        GSSetShader: Unused,
        IASetPrimitiveTopology: *const fn (*Ctx, UINT) callconv(WINAPI) void,
        VSSetShaderResources: *const fn (*Ctx, UINT, UINT, [*]const ?*ID3D11ShaderResourceView) callconv(WINAPI) void,
        VSSetSamplers: Unused,
        Begin: Unused,
        End: Unused,
        GetData: Unused,
        SetPredication: Unused,
        GSSetShaderResources: Unused,
        GSSetSamplers: Unused,
        OMSetRenderTargets: *const fn (*Ctx, UINT, ?[*]const ?*ID3D11RenderTargetView, ?*IResource) callconv(WINAPI) void,
        OMSetRenderTargetsAndUnorderedAccessViews: Unused,
        OMSetBlendState: *const fn (*Ctx, ?*ID3D11BlendState, ?*const [4]f32, UINT) callconv(WINAPI) void,
        OMSetDepthStencilState: Unused,
        SOSetTargets: Unused,
        DrawAuto: Unused,
        DrawIndexedInstancedIndirect: Unused,
        DrawInstancedIndirect: Unused,
        Dispatch: Unused,
        DispatchIndirect: Unused,
        RSSetState: *const fn (*Ctx, ?*ID3D11RasterizerState) callconv(WINAPI) void,
        RSSetViewports: *const fn (*Ctx, UINT, [*]const D3D11_VIEWPORT) callconv(WINAPI) void,
        RSSetScissorRects: *const fn (*Ctx, UINT, [*]const w.RECT) callconv(WINAPI) void,
        CopySubresourceRegion: *const fn (*Ctx, *IResource, UINT, UINT, UINT, UINT, *IResource, UINT, ?*const D3D11_BOX) callconv(WINAPI) void,
        CopyResource: *const fn (*Ctx, *IResource, *IResource) callconv(WINAPI) void,
        UpdateSubresource: *const fn (*Ctx, *IResource, UINT, ?*const D3D11_BOX, *const anyopaque, UINT, UINT) callconv(WINAPI) void,
        CopyStructureCount: Unused,
        ClearRenderTargetView: *const fn (*Ctx, *ID3D11RenderTargetView, *const [4]f32) callconv(WINAPI) void,
        ClearUnorderedAccessViewUint: Unused,
        ClearUnorderedAccessViewFloat: Unused,
        ClearDepthStencilView: Unused,
        GenerateMips: Unused,
        SetResourceMinLOD: Unused,
        GetResourceMinLOD: Unused,
        ResolveSubresource: *const fn (*Ctx, *IResource, UINT, *IResource, UINT, DXGI_FORMAT) callconv(WINAPI) void,
        ExecuteCommandList: Unused,
        // HS/DS/CS setters (52..64) and every getter (65..102).
        _unused: [51]Unused,
        ClearState: *const fn (*Ctx) callconv(WINAPI) void,
        Flush: *const fn (*Ctx) callconv(WINAPI) void,
    };
};

/// IDXGIDevice3 (Windows 8.1+; `Trim`), usable as IDXGIDevice / IDXGIDevice1 too.
pub const IDXGIDevice = extern struct {
    vtbl: *const VTable,
    pub const iid = GUID.parse("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    pub const iid3 = GUID.parse("6007896c-3244-4afd-bf18-a6d3beda5023");
    pub const VTable = extern struct {
        base: IUnknownMethods(IDXGIDevice),
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        GetAdapter: *const fn (*IDXGIDevice, *?*IDXGIAdapter) callconv(WINAPI) HRESULT,
        CreateSurface: Unused,
        QueryResourceResidency: Unused,
        SetGPUThreadPriority: Unused,
        GetGPUThreadPriority: Unused,
        // IDXGIDevice1
        SetMaximumFrameLatency: *const fn (*IDXGIDevice, UINT) callconv(WINAPI) HRESULT,
        GetMaximumFrameLatency: Unused,
        // IDXGIDevice2
        OfferResources: Unused,
        ReclaimResources: Unused,
        EnqueueSetEvent: Unused,
        // IDXGIDevice3 (only call through a pointer obtained with `iid3`)
        Trim: *const fn (*IDXGIDevice) callconv(WINAPI) void,
    };
};

pub const IDXGIAdapter = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        base: IUnknownMethods(IDXGIAdapter),
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: *const fn (*IDXGIAdapter, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        EnumOutputs: *const fn (*IDXGIAdapter, UINT, *?*IDXGIOutput) callconv(WINAPI) HRESULT,
    };
};

pub const IDXGIOutput = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        base: IUnknownMethods(IDXGIOutput),
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        GetDesc: Unused,
        GetDisplayModeList: Unused,
        FindClosestMatchingMode: Unused,
        WaitForVBlank: *const fn (*IDXGIOutput) callconv(WINAPI) HRESULT,
    };
};

pub const IDXGIFactory2 = extern struct {
    vtbl: *const VTable,
    pub const iid = GUID.parse("50c83a1c-e072-4c48-87b0-3630fa36a6d0");
    /// IDXGIFactory1 (only the IDXGIFactory slots are valid through it).
    pub const iid1 = GUID.parse("770aae78-f26f-4dba-a829-253c83d1b387");
    pub const VTable = extern struct {
        base: IUnknownMethods(IDXGIFactory2),
        // IDXGIObject
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        // IDXGIFactory
        EnumAdapters: *const fn (*IDXGIFactory2, UINT, *?*IDXGIAdapter) callconv(WINAPI) HRESULT,
        MakeWindowAssociation: *const fn (*IDXGIFactory2, w.HWND, UINT) callconv(WINAPI) HRESULT,
        GetWindowAssociation: Unused,
        CreateSwapChain: Unused,
        CreateSoftwareAdapter: Unused,
        // IDXGIFactory1
        EnumAdapters1: Unused,
        IsCurrent: Unused,
        // IDXGIFactory2
        IsWindowedStereoEnabled: Unused,
        CreateSwapChainForHwnd: *const fn (*IDXGIFactory2, *w.IUnknown, w.HWND, *const DXGI_SWAP_CHAIN_DESC1, ?*const anyopaque, ?*anyopaque, *?*IDXGISwapChain1) callconv(WINAPI) HRESULT,
        CreateSwapChainForCoreWindow: Unused,
        GetSharedResourceAdapterLuid: Unused,
        RegisterStereoStatusWindow: Unused,
        RegisterStereoStatusEvent: Unused,
        UnregisterStereoStatus: Unused,
        RegisterOcclusionStatusWindow: Unused,
        RegisterOcclusionStatusEvent: Unused,
        UnregisterOcclusionStatus: Unused,
        CreateSwapChainForComposition: *const fn (*IDXGIFactory2, *w.IUnknown, *const DXGI_SWAP_CHAIN_DESC1, ?*anyopaque, *?*IDXGISwapChain1) callconv(WINAPI) HRESULT,
    };
};

/// IDXGISwapChain2 layout (DXGI 1.3, Windows 8.1+); the 1.3 slots are only called
/// through a pointer queried with `iid2`.
pub const IDXGISwapChain1 = extern struct {
    vtbl: *const VTable,
    pub const iid2 = GUID.parse("a8be2ac4-199f-4946-b331-79599fb98de7");
    pub const VTable = extern struct {
        base: IUnknownMethods(IDXGISwapChain1),
        // IDXGIObject
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        // IDXGIDeviceSubObject
        GetDevice: Unused,
        // IDXGISwapChain
        Present: *const fn (*IDXGISwapChain1, UINT, UINT) callconv(WINAPI) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain1, UINT, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        SetFullscreenState: Unused,
        GetFullscreenState: Unused,
        GetDesc: Unused,
        ResizeBuffers: *const fn (*IDXGISwapChain1, UINT, UINT, UINT, DXGI_FORMAT, UINT) callconv(WINAPI) HRESULT,
        ResizeTarget: Unused,
        GetContainingOutput: Unused,
        GetFrameStatistics: Unused,
        GetLastPresentCount: Unused,
        // IDXGISwapChain1
        GetDesc1: Unused,
        GetFullscreenDesc: Unused,
        GetHwnd: Unused,
        GetCoreWindow: Unused,
        Present1: Unused,
        IsTemporaryMonoSupported: Unused,
        GetRestrictToOutput: Unused,
        SetBackgroundColor: Unused,
        GetBackgroundColor: Unused,
        SetRotation: Unused,
        GetRotation: Unused,
        // IDXGISwapChain2
        SetSourceSize: Unused,
        GetSourceSize: Unused,
        SetMaximumFrameLatency: *const fn (*IDXGISwapChain1, UINT) callconv(WINAPI) HRESULT,
        GetMaximumFrameLatency: Unused,
        GetFrameLatencyWaitableObject: *const fn (*IDXGISwapChain1) callconv(WINAPI) ?w.HANDLE,
    };
};

pub const IID_ID3D11Texture2D = GUID.parse("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

pub const ID3DBlob = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        base: IUnknownMethods(ID3DBlob),
        GetBufferPointer: *const fn (*ID3DBlob) callconv(WINAPI) [*]const u8,
        GetBufferSize: *const fn (*ID3DBlob) callconv(WINAPI) usize,
    };
    pub fn bytes(self: *ID3DBlob) []const u8 {
        return self.vtbl.GetBufferPointer(self)[0..self.vtbl.GetBufferSize(self)];
    }
};

pub extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: UINT,
    software: ?*anyopaque,
    flags: UINT,
    feature_levels: ?[*]const UINT,
    num_levels: UINT,
    sdk_version: UINT,
    device: *?*ID3D11Device,
    feature_level: ?*UINT,
    context: *?*ID3D11DeviceContext,
) callconv(WINAPI) HRESULT;

pub extern "dxgi" fn CreateDXGIFactory1(iid: *const GUID, factory: *?*anyopaque) callconv(WINAPI) HRESULT;

pub extern "d3dcompiler_47" fn D3DCompile(
    src: [*]const u8,
    len: usize,
    name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entry: [*:0]const u8,
    target: [*:0]const u8,
    flags1: UINT,
    flags2: UINT,
    code: *?*ID3DBlob,
    errors: *?*ID3DBlob,
) callconv(WINAPI) HRESULT;

pub const IID_IDCompositionDevice = w.IDCompositionDevice.iid;

// Slot checks: a wrong offset is a silent crash at runtime, so pin the ones zpui calls.
comptime {
    const slot = struct {
        fn of(comptime T: type, comptime name: []const u8) usize {
            return @offsetOf(T, name) / @sizeOf(usize);
        }
    }.of;
    std.debug.assert(slot(ID3D11Device.VTable, "CreateBuffer") == 3);
    std.debug.assert(slot(ID3D11Device.VTable, "CreateTexture2D") == 5);
    std.debug.assert(slot(ID3D11Device.VTable, "CreateRenderTargetView") == 9);
    std.debug.assert(slot(ID3D11Device.VTable, "CreateVertexShader") == 12);
    std.debug.assert(slot(ID3D11Device.VTable, "CreatePixelShader") == 15);
    std.debug.assert(slot(ID3D11Device.VTable, "CreateBlendState") == 20);
    std.debug.assert(slot(ID3D11Device.VTable, "CreateSamplerState") == 23);
    std.debug.assert(slot(ID3D11Device.VTable, "CheckMultisampleQualityLevels") == 30);
    std.debug.assert(slot(ID3D11Device.VTable, "GetDeviceRemovedReason") == 39);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "VSSetConstantBuffers") == 7);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "Draw") == 13);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "Map") == 14);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "DrawInstanced") == 21);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "IASetPrimitiveTopology") == 24);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "OMSetRenderTargets") == 33);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "OMSetBlendState") == 35);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "RSSetState") == 43);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "CopySubresourceRegion") == 46);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "UpdateSubresource") == 48);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "ClearRenderTargetView") == 50);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "ResolveSubresource") == 57);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "ClearState") == 110);
    std.debug.assert(slot(ID3D11DeviceContext.VTable, "Flush") == 111);
    std.debug.assert(slot(IDXGIFactory2.VTable, "MakeWindowAssociation") == 8);
    std.debug.assert(slot(IDXGIFactory2.VTable, "CreateSwapChainForHwnd") == 15);
    std.debug.assert(slot(IDXGIFactory2.VTable, "CreateSwapChainForComposition") == 24);
    std.debug.assert(slot(IDXGISwapChain1.VTable, "Present") == 8);
    std.debug.assert(slot(IDXGISwapChain1.VTable, "ResizeBuffers") == 13);
    std.debug.assert(slot(IDXGISwapChain1.VTable, "SetMaximumFrameLatency") == 31);
    std.debug.assert(slot(IDXGISwapChain1.VTable, "GetFrameLatencyWaitableObject") == 33);
    std.debug.assert(slot(IDXGIDevice.VTable, "GetAdapter") == 7);
    std.debug.assert(slot(IDXGIDevice.VTable, "SetMaximumFrameLatency") == 12);
    std.debug.assert(slot(IDXGIDevice.VTable, "Trim") == 17);
    std.debug.assert(slot(IDXGIAdapter.VTable, "EnumOutputs") == 7);
    std.debug.assert(slot(IDXGIOutput.VTable, "WaitForVBlank") == 10);
    std.debug.assert(slot(w.IDCompositionDevice.VTable, "CreateTargetForHwnd") == 6);
    std.debug.assert(slot(w.IDCompositionDevice.VTable, "CreateVisual") == 7);
    std.debug.assert(slot(w.IDCompositionVisual.VTable, "SetContent") == 15);
}
