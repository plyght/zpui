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

struct resolve_frag_out
{
    float4 out_color [[color(0)]];
};

static inline __attribute__((always_inline))
float3 pbr_neutral(thread float3& color)
{
    float x = fast::min(color.x, fast::min(color.y, color.z));
    float _50;
    if (x < 0.07999999821186065673828125)
    {
        _50 = x - ((6.25 * x) * x);
    }
    else
    {
        _50 = 0.039999999105930328369140625;
    }
    float offset = _50;
    color -= float3(offset);
    float peak = fast::max(color.x, fast::max(color.y, color.z));
    if (peak < 0.7599999904632568359375)
    {
        return color;
    }
    float new_peak = 1.0 - (0.057599999010562896728515625 / ((peak + 0.23999999463558197021484375) - 0.7599999904632568359375));
    color *= (new_peak / peak);
    float g = 1.0 - (1.0 / ((0.1500000059604644775390625 * (peak - new_peak)) + 1.0));
    return mix(color, float3(new_peak), float3(g));
}

static inline __attribute__((always_inline))
float3 aces(thread const float3& x)
{
    return fast::clamp((x * ((x * 2.5099999904632568359375) + float3(0.02999999932944774627685546875))) / ((x * ((x * 2.4300000667572021484375) + float3(0.589999973773956298828125))) + float3(0.14000000059604644775390625)), float3(0.0), float3(1.0));
}

static inline __attribute__((always_inline))
float luma(thread const float3& c)
{
    return dot(c, float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
}

static inline __attribute__((always_inline))
float3 srgb_oetf(thread const float3& c)
{
    return mix(c * 12.9200000762939453125, (pow(c, float3(0.4166666567325592041015625)) * 1.05499994754791259765625) - float3(0.054999999701976776123046875), step(float3(0.003130800090730190277099609375), c));
}

fragment resolve_frag_out resolve_frag(constant PostParams& P [[buffer(0)]], texture2d<float> tex0 [[texture(1)]], texture2d<float> tex1 [[texture(2)]], texture2d<float> tex2 [[texture(3)]], sampler tex0Smplr [[sampler(1)]], sampler tex1Smplr [[sampler(2)]], sampler tex2Smplr [[sampler(3)]], float4 gl_FragCoord [[position]])
{
    resolve_frag_out out = {};
    float2 uv = gl_FragCoord.xy * P.p2.xy;
    float4 c = tex0.sample(tex0Smplr, uv);
    if (P.p1.x > 0.0)
    {
        float4 _201 = c;
        float3 _203 = _201.xyz * mix(1.0, tex1.sample(tex1Smplr, uv).x, P.p1.x);
        c.x = _203.x;
        c.y = _203.y;
        c.z = _203.z;
    }
    if (P.p1.w > 0.5)
    {
        float k = smoothstep(P.p1.z * 0.5, (P.p1.z * 0.5) + 0.2800000011920928955078125, abs(uv.y - P.p1.y));
        c = mix(c, tex2.sample(tex2Smplr, uv), float4(k));
    }
    if (c.w <= 0.0)
    {
        out.out_color = float4(0.0);
        return out;
    }
    float3 rgb = (c.xyz / float3(c.w)) * P.p0.x;
    int tm = int(P.p0.y + 0.5);
    if (tm == 1)
    {
        float3 param = rgb;
        float3 _273 = pbr_neutral(param);
        rgb = _273;
    }
    else
    {
        if (tm == 2)
        {
            float3 param_1 = rgb;
            rgb = aces(param_1);
        }
    }
    rgb = fast::clamp(rgb, float3(0.0), float3(1.0));
    if (abs(P.p0.z - 1.0) > 0.001000000047497451305389404296875)
    {
        float3 param_2 = rgb;
        rgb = fast::clamp(mix(float3(luma(param_2)), rgb, float3(P.p0.z)), float3(0.0), float3(1.0));
    }
    if (P.p0.w > 0.0)
    {
        rgb *= (1.0 - (smoothstep(0.3499999940395355224609375, 0.85000002384185791015625, length(uv - float2(0.5))) * P.p0.w));
    }
    float a = fast::clamp(c.w, 0.0, 1.0);
    float3 param_3 = rgb;
    out.out_color = float4(srgb_oetf(param_3) * a, a);
    return out;
}

