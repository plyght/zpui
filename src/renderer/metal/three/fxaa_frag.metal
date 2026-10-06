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

struct fxaa_frag_out
{
    float4 out_color [[color(0)]];
};

static inline __attribute__((always_inline))
float luma(thread const float3& c)
{
    return dot(c, float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
}

static inline __attribute__((always_inline))
float lum(thread const float2& uv, texture2d<float> tex0, sampler tex0Smplr)
{
    float3 param = tex0.sample(tex0Smplr, uv).xyz;
    return luma(param);
}

fragment fxaa_frag_out fxaa_frag(constant PostParams& P [[buffer(0)]], texture2d<float> tex0 [[texture(1)]], sampler tex0Smplr [[sampler(1)]], float4 gl_FragCoord [[position]])
{
    fxaa_frag_out out = {};
    float2 px = P.p2.xy;
    float2 uv = gl_FragCoord.xy * px;
    float4 center = tex0.sample(tex0Smplr, uv);
    float3 param = center.xyz;
    float m = luma(param);
    float2 param_1 = uv + float2(0.0, -px.y);
    float n = lum(param_1, tex0, tex0Smplr);
    float2 param_2 = uv + float2(0.0, px.y);
    float s = lum(param_2, tex0, tex0Smplr);
    float2 param_3 = uv + float2(px.x, 0.0);
    float e = lum(param_3, tex0, tex0Smplr);
    float2 param_4 = uv + float2(-px.x, 0.0);
    float w = lum(param_4, tex0, tex0Smplr);
    float lo = fast::min(m, fast::min(fast::min(n, s), fast::min(e, w)));
    float hi = fast::max(m, fast::max(fast::max(n, s), fast::max(e, w)));
    float range = hi - lo;
    if (range < fast::max(0.031199999153614044189453125, hi * 0.125))
    {
        out.out_color = center;
        return out;
    }
    float2 param_5 = uv + float2(-px.x, -px.y);
    float nw = lum(param_5, tex0, tex0Smplr);
    float2 param_6 = uv + float2(px.x, -px.y);
    float ne = lum(param_6, tex0, tex0Smplr);
    float2 param_7 = uv + float2(-px.x, px.y);
    float sw = lum(param_7, tex0, tex0Smplr);
    float2 param_8 = uv + float2(px.x, px.y);
    float se = lum(param_8, tex0, tex0Smplr);
    float horiz = (abs((nw + ne) - (2.0 * n)) + (2.0 * abs((w + e) - (2.0 * m)))) + abs((sw + se) - (2.0 * s));
    float vert = (abs((nw + sw) - (2.0 * w)) + (2.0 * abs((n + s) - (2.0 * m)))) + abs((ne + se) - (2.0 * e));
    bool is_h = horiz >= vert;
    float l1 = is_h ? n : w;
    float l2 = is_h ? s : e;
    float g1 = abs(l1 - m);
    float g2 = abs(l2 - m);
    float _266;
    if (is_h)
    {
        _266 = px.y;
    }
    else
    {
        _266 = px.x;
    }
    float step_len = _266;
    float grad = fast::max(g1, g2);
    float edge_l = 0.5 * (m + ((g1 >= g2) ? l1 : l2));
    if (g1 >= g2)
    {
        step_len = -step_len;
    }
    float2 euv = uv;
    if (is_h)
    {
        euv.y += (step_len * 0.5);
    }
    else
    {
        euv.x += (step_len * 0.5);
    }
    float2 _317;
    if (is_h)
    {
        _317 = float2(px.x, 0.0);
    }
    else
    {
        _317 = float2(0.0, px.y);
    }
    float2 off = _317;
    float2 uv1 = euv - off;
    float2 uv2 = euv + off;
    float2 param_9 = uv1;
    float e1 = lum(param_9, tex0, tex0Smplr) - edge_l;
    float2 param_10 = uv2;
    float e2 = lum(param_10, tex0, tex0Smplr) - edge_l;
    bool done1 = abs(e1) >= (grad * 0.25);
    bool done2 = abs(e2) >= (grad * 0.25);
    for (int i = 0; i < 8; i++)
    {
        if (done1 && done2)
        {
            break;
        }
        if (!done1)
        {
            uv1 -= (off * 1.5);
            float2 param_11 = uv1;
            e1 = lum(param_11, tex0, tex0Smplr) - edge_l;
            done1 = abs(e1) >= (grad * 0.25);
        }
        if (!done2)
        {
            uv2 += (off * 1.5);
            float2 param_12 = uv2;
            e2 = lum(param_12, tex0, tex0Smplr) - edge_l;
            done2 = abs(e2) >= (grad * 0.25);
        }
    }
    float _420;
    if (is_h)
    {
        _420 = uv.x - uv1.x;
    }
    else
    {
        _420 = uv.y - uv1.y;
    }
    float d1 = _420;
    float _437;
    if (is_h)
    {
        _437 = uv2.x - uv.x;
    }
    else
    {
        _437 = uv2.y - uv.y;
    }
    float d2 = _437;
    bool near1 = d1 < d2;
    float dist = fast::min(d1, d2);
    float span = d1 + d2;
    bool correct = ((near1 ? e1 : e2) < 0.0) != ((m - edge_l) < 0.0);
    float _477;
    if (correct)
    {
        _477 = ((-dist) / span) + 0.5;
    }
    else
    {
        _477 = 0.0;
    }
    float offset = _477;
    float sub = fast::clamp(abs(((((((2.0 * (((n + s) + e) + w)) + nw) + ne) + sw) + se) / 12.0) - m) / range, 0.0, 1.0);
    float sub_off = ((((-2.0) * sub) + 3.0) * sub) * sub;
    offset = fast::max(offset, (sub_off * sub_off) * 0.75);
    float2 fuv = uv;
    if (is_h)
    {
        fuv.y += (offset * step_len);
    }
    else
    {
        fuv.x += (offset * step_len);
    }
    out.out_color = tex0.sample(tex0Smplr, fuv);
    return out;
}

