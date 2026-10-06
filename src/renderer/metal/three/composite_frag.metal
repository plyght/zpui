#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct PostParams
{
    float4 p0;
    float4 p1;
    float4 p2;
    float4 p3;
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

struct composite_frag_out
{
    float4 out_color [[color(0)]];
};

struct composite_frag_in
{
    float2 v_uv [[user(locn0)]];
};

static inline __attribute__((always_inline))
float corner_sdf(thread const float2& point, constant PostParams& P)
{
    float2 half_size = P.p0.zw * 0.5;
    float2 center_to_point = point - (P.p0.xy + half_size);
    float _43;
    if (center_to_point.x < 0.0)
    {
        float _50;
        if (center_to_point.y < 0.0)
        {
            _50 = P.p2.x;
        }
        else
        {
            _50 = P.p2.w;
        }
        _43 = _50;
    }
    else
    {
        float _66;
        if (center_to_point.y < 0.0)
        {
            _66 = P.p2.y;
        }
        else
        {
            _66 = P.p2.z;
        }
        _43 = _66;
    }
    float r = _43;
    float2 cc = (abs(center_to_point) - half_size) + float2(r);
    if (r == 0.0)
    {
        return fast::max(cc.x, cc.y);
    }
    return (length(fast::max(float2(0.0), cc)) + fast::min(0.0, fast::max(cc.x, cc.y))) - r;
}

fragment composite_frag_out composite_frag(composite_frag_in in [[stage_in]], constant PostParams& P [[buffer(0)]], texture2d<float> tex0 [[texture(1)]], sampler tex0Smplr [[sampler(1)]], float4 gl_FragCoord [[position]])
{
    composite_frag_out out = {};
    float2 p = gl_FragCoord.xy;
    bool _120 = p.x < P.p1.x;
    bool _129;
    if (!_120)
    {
        _129 = p.y < P.p1.y;
    }
    else
    {
        _129 = _120;
    }
    bool _141;
    if (!_129)
    {
        _141 = p.x > (P.p1.x + P.p1.z);
    }
    else
    {
        _141 = _129;
    }
    bool _153;
    if (!_141)
    {
        _153 = p.y > (P.p1.y + P.p1.w);
    }
    else
    {
        _153 = _141;
    }
    if (_153)
    {
        discard_fragment();
    }
    float4 c = tex0.sample(tex0Smplr, in.v_uv);
    float2 param = p;
    float coverage = fast::clamp(0.5 - corner_sdf(param, P), 0.0, 1.0) * P.p3.z;
    out.out_color = c * coverage;
    return out;
}

