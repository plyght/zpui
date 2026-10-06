#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct FrameData
{
    float4x4 view_proj;
    float4x4 view;
    float4x4 proj;
    float4x4 inv_proj;
    float4x4 light_view_proj;
    float4 camera_pos;
    float4 sun_dir;
    float4 sun_color;
    float4 sky;
    float4 ground;
    float4 fog;
    float4 shadow;
    float4 viewport;
    float4 env;
    float4 sh[9];
};

struct FrameBuf
{
    FrameData f;
};

struct DrawData
{
    float4 base_color;
    float4 emissive;
    float4 pbr;
    float4 toon;
    float4 detail;
    float4 outline_color;
    float4 outline;
    float4 highlight_color;
    uint4 flags;
};

struct DrawBuf
{
    DrawData d;
};

struct PositionsBuf
{
    float v[1];
};

struct NormalsBuf
{
    float v[1];
};

struct UvsBuf
{
    float v[1];
};

struct ColorsBuf
{
    uint v[1];
};

struct IdsBuf
{
    uint v[1];
};

struct Instance
{
    float4x4 model;
    float4 tint;
    uint pick_id;
    uint palette_row;
    uint user;
    uint pad;
};

struct InstancesBuf
{
    Instance v[1];
};

constant spvUnsafeArray<float2, 12> _185 = spvUnsafeArray<float2, 12>({ float2(-0.3260000050067901611328125, -0.4059999883174896240234375), float2(-0.839999973773956298828125, -0.07400000095367431640625), float2(-0.69599997997283935546875, 0.4569999873638153076171875), float2(-0.20299999415874481201171875, 0.620999991893768310546875), float2(0.96200001239776611328125, -0.194999992847442626953125), float2(0.472999989986419677734375, -0.4799999892711639404296875), float2(0.518999993801116943359375, 0.767000019550323486328125), float2(0.185000002384185791015625, -0.89300000667572021484375), float2(0.507000029087066650390625, 0.064000003039836883544921875), float2(0.89600002765655517578125, 0.412000000476837158203125), float2(-0.3219999969005584716796875, -0.933000028133392333984375), float2(-0.791999995708465576171875, -0.597999989986419677734375) });

struct outline_frag_out
{
    float4 out_color [[color(0)]];
};

struct outline_frag_in
{
    float v_view_depth [[user(locn0)]];
};

static inline __attribute__((always_inline))
float3 apply_fog(thread const float3& color, thread const float& view_depth, const device FrameBuf& b_frame)
{
    float density = ((device float*)&b_frame.f.fog)[3u];
    if (density <= 0.0)
    {
        return color;
    }
    float f = 1.0 - exp((((-density) * density) * view_depth) * view_depth);
    return mix(color, b_frame.f.fog.xyz, float3(fast::clamp(f, 0.0, 1.0)));
}

fragment outline_frag_out outline_frag(outline_frag_in in [[stage_in]], const device FrameBuf& b_frame [[buffer(6)]], const device DrawBuf& b_draw [[buffer(7)]])
{
    outline_frag_out out = {};
    float4 c = b_draw.d.outline_color;
    float3 _82;
    if ((((device uint*)&b_draw.d.flags)[0u] & 64u) != 0u)
    {
        float3 param = c.xyz;
        float param_1 = in.v_view_depth;
        _82 = apply_fog(param, param_1, b_frame);
    }
    else
    {
        _82 = c.xyz;
    }
    float3 rgb = _82;
    out.out_color = float4(rgb * c.w, c.w);
    return out;
}

