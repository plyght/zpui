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

struct blur_frag_out
{
    float4 out_color [[color(0)]];
};

static inline __attribute__((always_inline))
float4 fetch(thread const float2& uv, texture2d<float> tex0, sampler tex0Smplr, constant PostParams& P, texture2d<float> tex1, sampler tex1Smplr)
{
    float4 c = tex0.sample(tex0Smplr, uv);
    if (P.p0.w > 0.5)
    {
        float4 _50 = c;
        float3 _52 = _50.xyz * mix(1.0, tex1.sample(tex1Smplr, uv).x, P.p1.w);
        c.x = _52.x;
        c.y = _52.y;
        c.z = _52.z;
    }
    return c;
}

fragment blur_frag_out blur_frag(constant PostParams& P [[buffer(0)]], texture2d<float> tex0 [[texture(1)]], texture2d<float> tex1 [[texture(2)]], sampler tex0Smplr [[sampler(1)]], sampler tex1Smplr [[sampler(2)]], float4 gl_FragCoord [[position]])
{
    blur_frag_out out = {};
    float2 uv = (gl_FragCoord.xy * P.p1.z) * P.p1.xy;
    float2 dir = P.p0.xy * P.p1.xy;
    float sigma = fast::max(P.p0.z, 0.5);
    int radius = min(int(ceil(sigma * 3.0)), 24);
    float2 param = uv;
    float4 sum = fetch(param, tex0, tex0Smplr, P, tex1, tex1Smplr);
    float wsum = 1.0;
    for (int i = 1; i <= 24; i++)
    {
        if (i > radius)
        {
            break;
        }
        float w = exp(((-0.5) * float(i * i)) / (sigma * sigma));
        float2 param_1 = uv + (dir * float(i));
        float2 param_2 = uv - (dir * float(i));
        sum += ((fetch(param_1, tex0, tex0Smplr, P, tex1, tex1Smplr) + fetch(param_2, tex0, tex0Smplr, P, tex1, tex1Smplr)) * w);
        wsum += (2.0 * w);
    }
    out.out_color = sum / float4(wsum);
    return out;
}

