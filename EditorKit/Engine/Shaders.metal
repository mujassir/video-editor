#include <metal_stdlib>
using namespace metal;

// One textured quad per layer. Geometry and UVs are computed on the CPU
// (crop / rotation / flips / fit / transitions), so the GPU only interpolates.

struct QuadVertex {
    float2 position;   // NDC
    float2 uv;         // source texture coordinate
    float2 local;      // 0...1 across the quad (for vignette)
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float2 local;
};

vertex VSOut quad_vertex(uint vid [[vertex_id]], constant QuadVertex *verts [[buffer(0)]]) {
    VSOut out;
    out.position = float4(verts[vid].position, 0, 1);
    out.uv = verts[vid].uv;
    out.local = verts[vid].local;
    return out;
}

struct LayerUniforms {
    float exposure;
    float contrast;
    float saturation;
    float warmth;
    float highlights;
    float shadows;
    float vignette;
    float sharpen;
    float opacity;
    float lutIntensity;   // 0 = no LUT
    float brightness;     // multiplies rgb (fade-through-black)
    float blurRadius;     // in texels (transition blur)
    float wipeProgress;   // <0 disables wipe; else visible where canvas x < progress
    float glitch;         // 0...1
    float maskMode;       // 0 none, 1 keep subject over transparent, 2 subject over blurred, 3 subject over colour
    float time;
    float4 maskColor;
    float2 texelSize;
    float2 canvasSize;
};

static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float4 sampleBlurred(texture2d<float> tex, sampler s, float2 uv, float2 texel, float radius) {
    if (radius < 0.5) { return tex.sample(s, uv); }
    // 13-tap golden-angle disc blur: cheap and good enough while moving.
    float4 acc = tex.sample(s, uv);
    float total = 1;
    for (int i = 1; i <= 12; i++) {
        float r = sqrt(float(i) / 12.0) * radius;
        float a = float(i) * 2.39996323;
        float2 o = float2(cos(a), sin(a)) * r * texel;
        acc += tex.sample(s, uv + o);
        total += 1;
    }
    return acc / total;
}

static float3 adjust(float3 c, constant LayerUniforms &u) {
    c *= exp2(u.exposure * 1.5);
    float l = luma(c);
    // Highlights / shadows: weighted gain on bright / dark regions.
    float hw = smoothstep(0.45, 1.0, l);
    float sw = 1.0 - smoothstep(0.0, 0.55, l);
    c += c * (u.highlights * 0.45 * hw);
    c += (u.shadows * 0.35 * sw);
    c = (c - 0.5) * (1.0 + u.contrast * 0.8) + 0.5;
    l = luma(c);
    c = mix(float3(l), c, 1.0 + u.saturation);
    c.r += u.warmth * 0.08;
    c.b -= u.warmth * 0.08;
    return clamp(c, 0.0, 1.0);
}

fragment float4 layer_fragment(VSOut in [[stage_in]],
                               texture2d<float> source [[texture(0)]],
                               texture3d<float> lut [[texture(1)]],
                               texture2d<float> mask [[texture(2)]],
                               texture2d<float> blurred [[texture(3)]],
                               constant LayerUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;

    if (u.glitch > 0.001) {
        // Horizontal slice jitter + RGB split.
        float slice = floor(in.position.y / max(u.canvasSize.y, 1.0) * 24.0);
        float n = fract(sin(slice * 91.7 + floor(u.time * 30.0) * 13.3) * 43758.5453);
        uv.x += (n - 0.5) * 0.08 * u.glitch * step(0.6, n);
    }

    float4 color = sampleBlurred(source, s, uv, u.texelSize, u.blurRadius);

    if (u.glitch > 0.001) {
        float shift = 0.012 * u.glitch;
        color.r = source.sample(s, uv + float2(shift, 0)).r;
        color.b = source.sample(s, uv - float2(shift, 0)).b;
    }

    if (u.sharpen > 0.001) {
        float4 n = source.sample(s, uv + float2(u.texelSize.x, 0)) + source.sample(s, uv - float2(u.texelSize.x, 0))
                 + source.sample(s, uv + float2(0, u.texelSize.y)) + source.sample(s, uv - float2(0, u.texelSize.y));
        color.rgb = color.rgb + (color.rgb - n.rgb * 0.25) * (u.sharpen * 1.5);
    }

    float3 rgb = adjust(color.rgb, u);

    if (u.lutIntensity > 0.001) {
        constexpr sampler ls(address::clamp_to_edge, filter::linear);
        // Sample texel centres of the LUT.
        float size = float(lut.get_width());
        float3 coord = rgb * ((size - 1.0) / size) + 0.5 / size;
        float3 graded = lut.sample(ls, coord).rgb;
        rgb = mix(rgb, graded, u.lutIntensity);
    }

    if (u.vignette > 0.001) {
        float2 d = in.local - 0.5;
        float v = smoothstep(0.85, 0.2, length(d) * 1.2);
        rgb *= mix(1.0, v, u.vignette);
    }

    rgb *= u.brightness;
    float alpha = color.a * u.opacity;

    if (u.maskMode > 0.5) {
        float m = mask.sample(s, uv).r;
        m = smoothstep(0.15, 0.85, m);
        if (u.maskMode < 1.5) {
            alpha *= m;
        } else if (u.maskMode < 2.5) {
            float3 bg = blurred.sample(s, uv).rgb * u.brightness;
            rgb = mix(bg, rgb, m);
        } else {
            rgb = mix(u.maskColor.rgb, rgb, m);
        }
    }

    if (u.wipeProgress >= 0.0) {
        float x = in.position.x / max(u.canvasSize.x, 1.0);
        float edge = 0.02;
        alpha *= 1.0 - smoothstep(u.wipeProgress - edge, u.wipeProgress + edge, x);
    }

    return float4(rgb * alpha, alpha); // premultiplied
}

// Overlays (text, captions, stickers) are pre-rendered premultiplied BGRA.
struct OverlayUniforms {
    float opacity;
};

fragment float4 overlay_fragment(VSOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant OverlayUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv) * u.opacity;
}

// Solid colour fill (canvas background, dip-to-black).
fragment float4 solid_fragment(VSOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return float4(color.rgb * color.a, color.a);
}
