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

constant spvUnsafeArray<float2, 12> _342 = spvUnsafeArray<float2, 12>({ float2(-0.839999973773956298828125, -0.07400000095367431640625), float2(0.96200001239776611328125, -0.194999992847442626953125), float2(0.518999993801116943359375, 0.767000019550323486328125), float2(0.185000002384185791015625, -0.89300000667572021484375), float2(-0.3260000050067901611328125, -0.4059999883174896240234375), float2(-0.69599997997283935546875, 0.4569999873638153076171875), float2(-0.20299999415874481201171875, 0.620999991893768310546875), float2(0.472999989986419677734375, -0.4799999892711639404296875), float2(0.507000029087066650390625, 0.064000003039836883544921875), float2(0.89600002765655517578125, 0.412000000476837158203125), float2(-0.3219999969005584716796875, -0.933000028133392333984375), float2(-0.791999995708465576171875, -0.597999989986419677734375) });

struct mesh_frag_out
{
    float4 out_color [[color(0)]];
};

struct mesh_frag_in
{
    float3 v_world [[user(locn0)]];
    float3 v_normal [[user(locn1)]];
    float2 v_uv [[user(locn2)]];
    float4 v_color [[user(locn3)]];
    uint v_id [[user(locn4)]];
    uint v_palette_row [[user(locn5)]];
    float3 v_shadow [[user(locn6)]];
    float v_view_depth [[user(locn7)]];
};

static inline __attribute__((always_inline))
float hash12(thread const float2& p)
{
    uint2 q = uint2(int2(floor(p)) + int2(32768));
    uint h = (q.x * 1597334677u) ^ (q.y * 3812015801u);
    h = (h ^ (h >> 16u)) * 2246822519u;
    h ^= (h >> 13u);
    return float(h & 65535u) / 65535.0;
}

static inline __attribute__((always_inline))
float value_noise(thread const float2& p)
{
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = (f * f) * (float2(3.0) - (f * 2.0));
    float2 param = i;
    float a = hash12(param);
    float2 param_1 = i + float2(1.0, 0.0);
    float b = hash12(param_1);
    float2 param_2 = i + float2(0.0, 1.0);
    float c = hash12(param_2);
    float2 param_3 = i + float2(1.0);
    float d = hash12(param_3);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline __attribute__((always_inline))
float3 view_vector(thread const float3& world, const device FrameBuf& b_frame)
{
    if (((device float*)&b_frame.f.camera_pos)[3u] > 0.5)
    {
        return fast::normalize(float3(((device float*)&b_frame.f.view[0])[2u], ((device float*)&b_frame.f.view[1])[2u], ((device float*)&b_frame.f.view[2])[2u]));
    }
    return fast::normalize(b_frame.f.camera_pos.xyz - world);
}

static inline __attribute__((always_inline))
float sample_shadow(depth2d<float> map, sampler mapSmplr, thread const float3& lp, const device FrameBuf& b_frame)
{
    if (((device float*)&b_frame.f.sun_dir)[3u] < 0.5)
    {
        return 1.0;
    }
    float2 uv = (lp.xy * 0.5) + float2(0.5);
    bool _225 = uv.x <= 0.0;
    bool _232;
    if (!_225)
    {
        _232 = uv.y <= 0.0;
    }
    else
    {
        _232 = _225;
    }
    bool _239;
    if (!_232)
    {
        _239 = uv.x >= 1.0;
    }
    else
    {
        _239 = _232;
    }
    bool _246;
    if (!_239)
    {
        _246 = uv.y >= 1.0;
    }
    else
    {
        _246 = _239;
    }
    bool _253;
    if (!_246)
    {
        _253 = lp.z >= 1.0;
    }
    else
    {
        _253 = _246;
    }
    if (_253)
    {
        return 1.0;
    }
    float ref = lp.z - ((device float*)&b_frame.f.shadow)[0u];
    float radius = ((device float*)&b_frame.f.shadow)[3u] * ((device float*)&b_frame.f.shadow)[2u];
    if (radius <= 0.0)
    {
        float3 _279 = float3(uv, ref);
        return map.sample_compare(mapSmplr, _279.xy, _279.z);
    }
    float3 _289 = float3(uv, ref);
    float sum = map.sample_compare(mapSmplr, _289.xy, _289.z);
    for (int i = 0; i < 4; i++)
    {
        float3 _354 = float3(uv + (_342[i] * radius), ref);
        sum += map.sample_compare(mapSmplr, _354.xy, _354.z);
    }
    if ((sum <= 0.0) || (sum >= 5.0))
    {
        return sum * 0.20000000298023223876953125;
    }
    for (int i_1 = 4; i_1 < 12; i_1++)
    {
        float3 _394 = float3(uv + (_342[i_1] * radius), ref);
        sum += map.sample_compare(mapSmplr, _394.xy, _394.z);
    }
    return sum / 13.0;
}

static inline __attribute__((always_inline))
float3 sh_irradiance(thread const float3& n, const device FrameBuf& b_frame)
{
    float3 L00 = b_frame.f.sh[0].xyz;
    float3 L1m1 = b_frame.f.sh[1].xyz;
    float3 L10 = b_frame.f.sh[2].xyz;
    float3 L11 = b_frame.f.sh[3].xyz;
    float3 L2m2 = b_frame.f.sh[4].xyz;
    float3 L2m1 = b_frame.f.sh[5].xyz;
    float3 L20 = b_frame.f.sh[6].xyz;
    float3 L21 = b_frame.f.sh[7].xyz;
    float3 L22 = b_frame.f.sh[8].xyz;
    float x = n.x;
    float y = n.y;
    float z = n.z;
    float3 e = ((((((L22 * 0.429042994976043701171875) * ((x * x) - (y * y))) + (((L20 * 0.743125021457672119140625) * z) * z)) + (L00 * 0.88622701168060302734375)) - (L20 * 0.2477079927921295166015625)) + (((((L2m2 * x) * y) + ((L21 * x) * z)) + ((L2m1 * y) * z)) * 0.85808598995208740234375)) + ((((L11 * x) + (L1m1 * y)) + (L10 * z)) * 1.02332794666290283203125);
    return fast::max(e, float3(0.0)) * ((device float*)&b_frame.f.env)[0u];
}

static inline __attribute__((always_inline))
float3 ambient_irradiance(thread const float3& n, const device FrameBuf& b_frame)
{
    float3 hemi = mix(b_frame.f.ground.xyz, b_frame.f.sky.xyz, float3((n.y * 0.5) + 0.5));
    if (((device float*)&b_frame.f.env)[0u] > 0.0)
    {
        float3 param = n;
        hemi += sh_irradiance(param, b_frame);
    }
    return hemi;
}

static inline __attribute__((always_inline))
float3 shade_toon(thread const float3& albedo, thread const float3& n, thread const float& shadow, const device FrameBuf& b_frame, const device DrawBuf& b_draw)
{
    float lit = fast::max(dot(n, b_frame.f.sun_dir.xyz), 0.0);
    float bands = fast::max(((device float*)&b_draw.d.toon)[0u], 1.0);
    float level0 = 0.0;
    float soft = fast::max(((device float*)&b_draw.d.toon)[2u], 9.9999997473787516355514526367188e-05);
    for (int k = 1; k < 8; k++)
    {
        if (float(k) >= bands)
        {
            break;
        }
        float t = float(k) / bands;
        level0 += smoothstep(t - soft, t + soft, lit);
    }
    float _835;
    if (bands > 1.0)
    {
        _835 = ((device float*)&b_draw.d.toon)[1u] + (((1.0 - ((device float*)&b_draw.d.toon)[1u]) * level0) / (bands - 1.0));
    }
    else
    {
        _835 = 1.0;
    }
    float ramp = _835;
    float3 param = n;
    return (albedo / float3(3.1415927410125732421875)) * (((b_frame.f.sun_color.xyz * ramp) * shadow) + ambient_irradiance(param, b_frame));
}

static inline __attribute__((always_inline))
float d_ggx(thread const float& n_h, thread const float& a)
{
    float a2 = a * a;
    float d = ((n_h * n_h) * (a2 - 1.0)) + 1.0;
    return a2 / ((3.1415927410125732421875 * d) * d);
}

static inline __attribute__((always_inline))
float v_smith(thread const float& n_v, thread const float& n_l, thread const float& a)
{
    float a2 = a * a;
    float gv = n_l * sqrt(((n_v * n_v) * (1.0 - a2)) + a2);
    float gl = n_v * sqrt(((n_l * n_l) * (1.0 - a2)) + a2);
    return 0.5 / fast::max(gv + gl, 9.9999997473787516355514526367188e-06);
}

static inline __attribute__((always_inline))
float3 shade_pbr(thread const float3& albedo, thread const float& metallic, thread const float& roughness, thread const float3& n, thread const float3& v, thread const float& shadow, const device FrameBuf& b_frame)
{
    float3 l = b_frame.f.sun_dir.xyz;
    float3 h = fast::normalize(v + l);
    float n_l = fast::max(dot(n, l), 0.0);
    float n_v = fast::max(dot(n, v), 9.9999997473787516355514526367188e-05);
    float n_h = fast::max(dot(n, h), 0.0);
    float v_h = fast::max(dot(v, h), 0.0);
    float a = roughness * roughness;
    float3 f0 = mix(float3(0.039999999105930328369140625), albedo, float3(metallic));
    float3 fres = f0 + ((float3(1.0) - f0) * pow(1.0 - v_h, 5.0));
    float3 diffuse_color = albedo * (1.0 - metallic);
    float param = n_h;
    float param_1 = a;
    float param_2 = n_v;
    float param_3 = n_l;
    float param_4 = a;
    float3 spec = (fres * d_ggx(param, param_1)) * v_smith(param_2, param_3, param_4);
    float3 direct = ((((diffuse_color / float3(3.1415927410125732421875)) + spec) * b_frame.f.sun_color.xyz) * n_l) * shadow;
    float3 param_5 = n;
    float3 indirect = (diffuse_color / float3(3.1415927410125732421875)) * ambient_irradiance(param_5, b_frame);
    float3 r = reflect(-v, n);
    float3 param_6 = fast::normalize(mix(r, n, float3(roughness * roughness)));
    float3 env = ambient_irradiance(param_6, b_frame) / float3(3.1415927410125732421875);
    float4 rr = (float4(-1.0, -0.0274999998509883880615234375, -0.572000026702880859375, 0.02199999988079071044921875) * roughness) + float4(1.0, 0.0425000004470348358154296875, 1.03999996185302734375, -0.039999999105930328369140625);
    float a004 = (fast::min(rr.x * rr.x, exp2((-9.27999973297119140625) * n_v)) * rr.x) + rr.y;
    float2 ab = (float2(-1.03999996185302734375, 1.03999996185302734375) * a004) + rr.zw;
    float3 env_spec = env * ((f0 * ab.x) + float3(ab.y));
    return (direct + indirect) + env_spec;
}

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

fragment mesh_frag_out mesh_frag(mesh_frag_in in [[stage_in]], const device FrameBuf& b_frame [[buffer(6)]], const device DrawBuf& b_draw [[buffer(7)]], depth2d<float> shadow_map [[texture(8)]], texture2d<float> base_texture [[texture(9)]], texture2d<float> palette [[texture(10)]], sampler shadow_mapSmplr [[sampler(8)]], sampler base_textureSmplr [[sampler(9)]], sampler paletteSmplr [[sampler(10)]])
{
    mesh_frag_out out = {};
    uint flags = ((device uint*)&b_draw.d.flags)[0u];
    float4 base = b_draw.d.base_color * in.v_color;
    if ((flags & 8u) != 0u)
    {
        base *= base_texture.sample(base_textureSmplr, in.v_uv);
    }
    if ((flags & 16u) != 0u)
    {
        float4 _945 = base;
        float3 _947 = _945.xyz * palette.read(uint2(int2(int(in.v_id), int(in.v_palette_row))), 0).xyz;
        base.x = _947.x;
        base.y = _947.y;
        base.z = _947.z;
    }
    if (((device float*)&b_draw.d.detail)[1u] != 0.0)
    {
        float2 param = in.v_world.xz * ((device float*)&b_draw.d.detail)[0u];
        float4 _974 = base;
        float3 _976 = _974.xyz * (1.0 + ((((device float*)&b_draw.d.detail)[1u] * (value_noise(param) - 0.5)) * 2.0));
        base.x = _976.x;
        base.y = _976.y;
        base.z = _976.z;
    }
    if ((flags & 128u) != 0u)
    {
        if (base.w < ((device float*)&b_draw.d.pbr)[2u])
        {
            discard_fragment();
        }
        base.w = 1.0;
    }
    if ((flags & 1024u) == 0u)
    {
        base.w = 1.0;
    }
    float3 param_1 = in.v_world;
    float3 v = view_vector(param_1, b_frame);
    float3 _1013;
    if ((flags & 1u) != 0u)
    {
        _1013 = fast::normalize(in.v_normal);
    }
    else
    {
        _1013 = fast::normalize(cross(dfdx(in.v_world), dfdy(in.v_world)));
    }
    float3 n = _1013;
    bool _1029 = (flags & 1u) == 0u;
    bool _1036;
    if (_1029)
    {
        _1036 = dot(n, v) < 0.0;
    }
    else
    {
        _1036 = _1029;
    }
    if (_1036)
    {
        n = -n;
    }
    bool _1044 = (flags & 512u) != 0u;
    bool _1051;
    if (_1044)
    {
        _1051 = dot(n, v) < 0.0;
    }
    else
    {
        _1051 = _1044;
    }
    if (_1051)
    {
        n = -n;
    }
    uint model = ((device uint*)&b_draw.d.flags)[2u];
    float shadow = 1.0;
    bool _1066 = ((flags & 32u) != 0u) && (model != 2u);
    bool _1081;
    if (_1066)
    {
        bool _1070 = model == 1u;
        bool _1080;
        if (!_1070)
        {
            _1080 = dot(n, b_frame.f.sun_dir.xyz) > 0.0;
        }
        else
        {
            _1080 = _1070;
        }
        _1081 = _1080;
    }
    else
    {
        _1081 = _1066;
    }
    if (_1081)
    {
        float3 param_2 = in.v_shadow;
        shadow = sample_shadow(shadow_map, shadow_mapSmplr, param_2, b_frame);
    }
    float3 color;
    if (model == 2u)
    {
        color = base.xyz;
    }
    else
    {
        if (model == 1u)
        {
            float3 param_3 = base.xyz;
            float3 param_4 = n;
            float param_5 = shadow;
            color = shade_toon(param_3, param_4, param_5, b_frame, b_draw);
        }
        else
        {
            float3 param_6 = base.xyz;
            float param_7 = ((device float*)&b_draw.d.pbr)[0u];
            float param_8 = ((device float*)&b_draw.d.pbr)[1u];
            float3 param_9 = n;
            float3 param_10 = v;
            float param_11 = shadow;
            color = shade_pbr(param_6, param_7, param_8, param_9, param_10, param_11, b_frame);
        }
    }
    color += b_draw.d.emissive.xyz;
    bool _1134 = (flags & 256u) != 0u;
    bool _1141;
    if (_1134)
    {
        _1141 = in.v_id == ((device uint*)&b_draw.d.flags)[1u];
    }
    else
    {
        _1141 = _1134;
    }
    if (_1141)
    {
        color = mix(color, b_draw.d.highlight_color.xyz, float3(((device float*)&b_draw.d.highlight_color)[3u]));
    }
    if ((flags & 64u) != 0u)
    {
        float3 param_12 = color;
        float param_13 = in.v_view_depth;
        color = apply_fog(param_12, param_13, b_frame);
    }
    out.out_color = float4(color * base.w, base.w);
    return out;
}

