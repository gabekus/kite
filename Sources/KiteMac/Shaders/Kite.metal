// Kite's window chrome shaders. Each draw is one full-screen triangle generated
// from the vertex ID (no vertex buffers), and both views only render on demand.
// Keep the math in sync with the HLSL port planned in docs/windows.md.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv; // 0...1 across the drawable, origin top-left
};

vertex VertexOut kite_fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

// MARK: Shared helpers

static float roundedRectDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

static float3 oklabToLinearSRGB(float3 c) {
    float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return float3(
         4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

static float3 linearToSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

// Dave Hoskins' hash: cheap, stable per pixel, no texture fetch.
static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// MARK: Theme backdrop

struct ThemeUniforms {
    float4 fromLab[4];   // OKLab, converted once on the CPU
    float4 toLab[4];
    float4 cutout;       // web content rect in px: x, y, w, h
    float2 size;         // drawable px
    float fromGrain;
    float toGrain;
    float progress;      // space-switch crossfade, 0...1
    uint fromCount;
    uint toCount;
    float cutoutRadius;  // px
    float fromTint;      // opacity over the window's material, 0...1
    float toTint;
};

// Where each color sits, by palette size.
constant float2 kAnchors[4][4] = {
    { float2(0.5, 0.5), float2(0), float2(0), float2(0) },
    { float2(0.0, 0.0), float2(1.0, 1.0), float2(0), float2(0) },
    { float2(0.0, 0.0), float2(1.0, 0.25), float2(0.35, 1.0), float2(0) },
    { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) },
};

static float3 themeLab(constant float4 *lab, uint count, float2 uv, float aspect) {
    count = clamp(count, 1u, 4u);
    if (count == 1) {
        // A touch of vertical falloff keeps a single color from looking flat.
        float3 c = lab[0].xyz;
        c.x -= 0.05 * uv.y;
        return c;
    }
    float3 sum = 0.0;
    float weights = 0.0;
    for (uint i = 0; i < count; ++i) {
        float2 d = (uv - kAnchors[count - 1][i]) * float2(aspect, 1.0);
        float w = exp(-dot(d, d) * 1.6);
        sum += lab[i].xyz * w;
        weights += w;
    }
    return sum / max(weights, 1e-4);
}

fragment float4 kite_theme_fragment(VertexOut in [[stage_in]], constant ThemeUniforms &u [[buffer(0)]]) {
    float2 px = in.position.xy;

    // The web page covers the middle of the window, so skip pixels nobody will see.
    float2 halfSize = u.cutout.zw * 0.5;
    if (halfSize.x > 0.0 && roundedRectDistance(px - (u.cutout.xy + halfSize), halfSize, u.cutoutRadius) < -2.0) {
        discard_fragment();
    }

    float aspect = u.size.x / max(u.size.y, 1.0);
    float3 lab = mix(themeLab(u.fromLab, u.fromCount, in.uv, aspect),
                     themeLab(u.toLab, u.toCount, in.uv, aspect),
                     u.progress);
    float3 rgb = linearToSRGB(oklabToLinearSRGB(lab));

    float grain = mix(u.fromGrain, u.toGrain, u.progress);
    rgb += (hash12(px) - 0.5) * grain * 0.07;      // film grain
    rgb += (hash12(px + 91.7) - 0.5) / 255.0;      // dither so 8-bit gradients don't band
    float alpha = mix(u.fromTint, u.toTint, u.progress);
    return float4(saturate(rgb) * alpha, alpha);   // premultiplied, over the sidebar material
}

// MARK: Loading glow

struct GlowUniforms {
    float4 rect;       // web content rect in px: x, y, w, h
    float4 primary;    // sRGB
    float4 secondary;
    float2 size;
    float radius;      // px
    float time;        // seconds
    float progress;    // page load, 0...1
    float intensity;   // fades the whole effect in and out
};

fragment float4 kite_glow_fragment(VertexOut in [[stage_in]], constant GlowUniforms &u [[buffer(0)]]) {
    float2 halfSize = u.rect.zw * 0.5;
    float2 p = in.position.xy - (u.rect.xy + halfSize);
    float d = roundedRectDistance(p, halfSize, u.radius);

    // Sharp rim on the edge, wide bloom outward, barely any bleed onto the page.
    float rim = exp(-abs(d) * 0.8);
    float bloom = d > 0.0 ? exp(-d * 0.11) * 0.5 : exp(d * 0.5) * 0.2;

    // Colors travel around the edge; a brighter band sweeps faster as the page loads.
    float angle = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
    float wave = 0.5 + 0.5 * cos((angle - u.time * 0.3) * 2.0 * M_PI_F);
    float3 color = mix(u.primary.rgb, u.secondary.rgb, wave);
    float sweep = pow(0.5 + 0.5 * cos((angle - u.time * (0.6 + u.progress)) * 2.0 * M_PI_F), 8.0);

    float alpha = saturate((rim + bloom) * (0.45 + 0.75 * sweep)) * u.intensity;
    return float4(color * alpha, alpha); // premultiplied for Core Animation
}
