// The space's theme backdrop: an HLSL port of kite_fullscreen_vertex and kite_theme_fragment
// in the Mac's Shaders/Kite.metal, line for line. One full-screen triangle from the vertex
// id (no vertex buffer). core/ThemeBackdrop.cpp is the CPU reference this is tested against
// (Kite.exe --backdrop-test); change all three together.

struct VertexOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;  // 0...1 across the drawable, origin top-left
};

VertexOut FullscreenVertex(uint vid : SV_VertexID) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VertexOut o;
    o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

// MARK: Shared helpers

float3 OklabToLinearSRGB(float3 c) {
    float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return float3(
         4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

float3 LinearToSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 curve = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    float3 low = 12.92 * c;
    return float3(c.x <= 0.0031308 ? low.x : curve.x,
                  c.y <= 0.0031308 ? low.y : curve.y,
                  c.z <= 0.0031308 ? low.z : curve.z);
}

// Dave Hoskins' hash: cheap, stable per pixel, no texture fetch. Kite.metal's
// `p3 += dot(p3, p3.yzx + 33.33)`, with the dot written out in the CPU reference's order and
// `precise` so no driver fuses or reorders it: the last frac() works on values near 1e4, where
// another rounding shifts the grain by up to ~4e-4, more than the reference checks allow.
float Hash12(float2 p) {
    precise float3 p3 = frac(float3(p.xyx) * 0.1031);
    precise float d = p3.x * (p3.y + 33.33) + p3.y * (p3.z + 33.33) + p3.z * (p3.x + 33.33);
    p3 += d;
    precise float h = frac((p3.x + p3.y) * p3.z);
    return h;
}

// MARK: Theme backdrop

// The Mac's ThemeUniforms, 176 bytes; core/ThemeBackdrop.h has the C++ side.
cbuffer ThemeUniforms : register(b0) {
    float4 fromLab[4];  // OKLab, converted once on the CPU
    float4 toLab[4];
    float2 size;        // drawable px
    float fromGrain;
    float toGrain;
    float progress;     // space-switch crossfade, 0...1
    uint fromCount;
    uint toCount;
    float fromTint;     // opacity over the window's material, 0...1
    float toTint;
};

// Where each colour sits, by palette size.
static const float2 kAnchors[4][4] = {
    { float2(0.5, 0.5), float2(0, 0), float2(0, 0), float2(0, 0) },
    { float2(0.0, 0.0), float2(1.0, 1.0), float2(0, 0), float2(0, 0) },
    { float2(0.0, 0.0), float2(1.0, 0.25), float2(0.35, 1.0), float2(0, 0) },
    { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) },
};

float3 ThemeLab(bool to, uint count, float2 uv, float aspect) {
    count = clamp(count, 1u, 4u);
    if (count == 1) {
        // A touch of vertical falloff keeps a single colour from looking flat.
        float3 c = to ? toLab[0].xyz : fromLab[0].xyz;
        c.x -= 0.05 * uv.y;
        return c;
    }
    float3 sum = 0.0;
    float weights = 0.0;
    [unroll] for (uint i = 0; i < 4; ++i) {
        if (i < count) {
            float2 d = (uv - kAnchors[count - 1][i]) * float2(aspect, 1.0);
            float w = exp(-dot(d, d) * 1.6);
            sum += (to ? toLab[i].xyz : fromLab[i].xyz) * w;
            weights += w;
        }
    }
    return sum / max(weights, 1e-4);
}

float4 ThemePixel(VertexOut i) : SV_Target {
    float2 px = i.position.xy;

    float aspect = size.x / max(size.y, 1.0);
    float3 lab = lerp(ThemeLab(false, fromCount, i.uv, aspect), ThemeLab(true, toCount, i.uv, aspect), progress);
    float3 rgb = LinearToSRGB(OklabToLinearSRGB(lab));

    rgb += (Hash12(px + 91.7) - 0.5) / 255.0;  // dither so 8-bit gradients don't band
    float alpha = lerp(fromTint, toTint, progress);
    float4 color = float4(saturate(rgb) * alpha, alpha);  // premultiplied, over the window's material

    // Film grain, multiplied in: a grey grain (mean 0.73, sd 0.21) at 26% opacity per unit of
    // the theme's grain, one grain per device pixel.
    float grain = lerp(fromGrain, toGrain, progress) * 0.259;
    float grey = saturate(0.73 + (Hash12(px) - 0.5) * 0.735);
    float4 grainColor = float4(grey, grey, grey, 1.0) * grain;  // premultiplied
    return grainColor * color + grainColor * (1.0 - color.a) + color * (1.0 - grainColor.a);
}
