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

struct PostParams
{
    float4 p0;
    float4 p1;
    float4 p2;
    float4 p3;
};

constant spvUnsafeArray<float3, 16> _293 = spvUnsafeArray<float3, 16>({ float3(0.5381000041961669921875, 0.18559999763965606689453125, 0.4318999946117401123046875), float3(0.13789999485015869140625, 0.248600006103515625, 0.4429999887943267822265625), float3(0.3370999991893768310546875, 0.567900002002716064453125, 0.0057000000961124897003173828125), float3(-0.699899971485137939453125, -0.0450999997556209564208984375, 0.0019000000320374965667724609375), float3(0.068899996578693389892578125, -0.159799993038177490234375, 0.854700028896331787109375), float3(0.056000001728534698486328125, 0.0068999999202787876129150390625, 0.184300005435943603515625), float3(-0.014600000344216823577880859375, 0.14020000398159027099609375, 0.076200000941753387451171875), float3(0.00999999977648258209228515625, -0.19239999353885650634765625, 0.03440000116825103759765625), float3(-0.35769999027252197265625, -0.53009998798370361328125, 0.4357999861240386962890625), float3(-0.3169000148773193359375, 0.10629999637603759765625, 0.015799999237060546875), float3(0.010300000198185443878173828125, -0.5868999958038330078125, 0.0046000001020729541778564453125), float3(-0.08969999849796295166015625, -0.4939999878406524658203125, 0.328700006008148193359375), float3(0.7118999958038330078125, -0.015399999916553497314453125, 0.091799996793270111083984375), float3(-0.053300000727176666259765625, 0.0595999993383884429931640625, 0.541100025177001953125), float3(0.03519999980926513671875, -0.063100002706050872802734375, 0.546000003814697265625), float3(-0.4776000082492828369140625, 0.2847000062465667724609375, 0.0271000005304813385009765625) });

struct ssao_frag_out
{
    float4 out_ao [[color(0)]];
};

static inline __attribute__((always_inline))
float3 view_pos(thread const float2& uv, thread const float& depth, const device FrameBuf& b_frame)
{
    float4 p = b_frame.f.inv_proj * float4((uv * 2.0) - float2(1.0), depth, 1.0);
    return p.xyz / float3(p.w);
}

fragment ssao_frag_out ssao_frag(constant PostParams& P [[buffer(0)]], const device FrameBuf& b_frame [[buffer(6)]], texture2d<float> tex0 [[texture(1)]], sampler tex0Smplr [[sampler(1)]], float4 gl_FragCoord [[position]])
{
    ssao_frag_out out = {};
    float2 uv = gl_FragCoord.xy * P.p1.xy;
    float depth = tex0.sample(tex0Smplr, uv).x;
    if (depth <= 0.0)
    {
        out.out_ao = float4(1.0);
        return out;
    }
    float2 param = uv;
    float param_1 = depth;
    float3 p = view_pos(param, param_1, b_frame);
    float2 param_2 = uv + float2(P.p1.x, 0.0);
    float param_3 = tex0.sample(tex0Smplr, (uv + float2(P.p1.x, 0.0))).x;
    float3 px = view_pos(param_2, param_3, b_frame);
    float2 param_4 = uv + float2(0.0, P.p1.y);
    float param_5 = tex0.sample(tex0Smplr, (uv + float2(0.0, P.p1.y))).x;
    float3 py = view_pos(param_4, param_5, b_frame);
    float3 n = fast::normalize(cross(px - p, py - p));
    if (dot(n, -p) < 0.0)
    {
        n = -n;
    }
    float angle = 6.283185482025146484375 * fract(52.98291778564453125 * fract(dot(gl_FragCoord.xy, float2(0.067110560834407806396484375, 0.005837149918079376220703125))));
    float3 rnd = float3(cos(angle), sin(angle), 0.0);
    float3 t = fast::normalize(rnd - (n * dot(rnd, n)));
    float3 b = cross(n, t);
    float3x3 tbn = float3x3(float3(t), float3(b), float3(n));
    float radius = P.p0.x;
    int count = clamp(int(P.p0.z), 4, 16);
    float occlusion = 0.0;
    for (int i = 0; i < 16; i++)
    {
        if (i >= count)
        {
            break;
        }
        float3 k = _293[i];
        k.z = abs(k.z);
        float scale = mix(0.20000000298023223876953125, 1.0, float(i + 1) / float(count));
        float3 s = p + (((tbn * k) * radius) * scale);
        float4 clip = b_frame.f.proj * float4(s, 1.0);
        float2 suv = ((clip.xy / float2(clip.w)) * 0.5) + float2(0.5);
        bool _345 = suv.x < 0.0;
        bool _352;
        if (!_345)
        {
            _352 = suv.y < 0.0;
        }
        else
        {
            _352 = _345;
        }
        bool _359;
        if (!_352)
        {
            _359 = suv.x > 1.0;
        }
        else
        {
            _359 = _352;
        }
        bool _366;
        if (!_359)
        {
            _366 = suv.y > 1.0;
        }
        else
        {
            _366 = _359;
        }
        if (_366)
        {
            continue;
        }
        float sd = tex0.sample(tex0Smplr, suv).x;
        if (sd <= 0.0)
        {
            continue;
        }
        float2 param_6 = suv;
        float param_7 = sd;
        float scene_z = view_pos(param_6, param_7, b_frame).z;
        float range = smoothstep(0.0, 1.0, radius / fast::max(abs(p.z - scene_z), 9.9999997473787516355514526367188e-05));
        occlusion += (float(scene_z >= (s.z + P.p0.w)) * range);
    }
    out.out_ao = float4(float3(1.0 - (occlusion / float(count))), 1.0);
    return out;
}

