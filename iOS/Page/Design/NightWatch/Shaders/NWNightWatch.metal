// Night Watch's living backdrop as SwiftUI shaders: ports of the boards'
// GLSL (Designs/shaders/aurora.glsl, pulse.glsl, glass.glsl) to Metal
// [[stitchable]] functions for `.colorEffect`. The app target compiles this
// into default.metallib; the widget extension and the macOS proxy renderer
// have no metallib and draw the Canvas versions instead (`NWShaders`).
//
// SwiftUI hands each function the pixel's position in points from the
// view's top-left; the GLSL measured from the bottom-left, so y is flipped.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float nw_hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

static float nw_noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(nw_hash(i), nw_hash(i + float2(1.0, 0.0)), u.x),
               mix(nw_hash(i + float2(0.0, 1.0)), nw_hash(i + float2(1.0, 1.0)), u.x), u.y);
}

static float nw_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * nw_noise(p); p = p * 2.03 + float2(1.7, 9.2); a *= 0.5; }
    return v;
}

// aurora.glsl: curtains bent by slow noise, streaks, stars fading towards the
// horizon and a vignette, over the palette's sky gradient. `intensity` 0 is
// the bare sky (dusk). `stars` scales the scatter of stars.
[[ stitchable ]] half4 nwAurora(float2 position, half4 color, float2 size, float time, float speed,
                                half4 skyTop, half4 skyBottom, half4 c1, half4 c2, half4 c3,
                                float intensity, float stars) {
    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
    float aspect = size.x / size.y;
    float2 p = float2(uv.x * aspect, uv.y);
    float t = time * speed;

    float warp = nw_fbm(p * 1.4 + float2(t * 0.6, -t * 0.25));
    float band1 = smoothstep(0.35, 0.0, abs(uv.y - 0.62 - 0.18 * sin(p.x * 1.6 + t + warp * 3.0)));
    float band2 = smoothstep(0.30, 0.0, abs(uv.y - 0.78 - 0.12 * sin(p.x * 2.3 - t * 1.3 + warp * 2.0)));
    float band3 = smoothstep(0.45, 0.0, abs(uv.y - 0.45 - 0.2 * sin(p.x * 1.1 + t * 0.7 - warp * 2.5)));
    float streaks = pow(nw_fbm(float2(p.x * 8.0 + warp * 4.0, t * 0.8)), 2.0);

    float3 col = mix(float3(skyBottom.rgb), float3(skyTop.rgb), smoothstep(0.0, 1.0, uv.y));
    col += float3(c1.rgb) * band1 * (0.55 + 0.6 * streaks) * intensity;
    col += float3(c2.rgb) * band2 * (0.45 + 0.5 * streaks) * intensity;
    col += float3(c3.rgb) * band3 * 0.35 * intensity;

    // Stars, fading towards the horizon (about two device pixels each).
    float2 cell = floor(position * 1.5);
    float s = step(0.9975, nw_hash(cell)) * smoothstep(0.3, 1.0, uv.y);
    col += float3(s) * (0.6 + 0.4 * sin(time * 3.0 + nw_hash(cell + 7.0) * 6.28)) * stars;

    col *= 1.0 - 0.55 * pow(length(uv - float2(0.5, 0.55)), 1.6);
    return half4(half3(col), 1.0);
}

// pulse.glsl: the glowing core, its halo and the expanding rings, drawn
// behind the pulse glyph. The rings are not on a clock of their own: Swift
// passes each ring's progress (PulseModel.ripples), -1 for none, so the
// shader and the Canvas fallback always agree. Premultiplied alpha.
[[ stitchable ]] half4 nwPulse(float2 position, half4 color, float2 size, float time,
                               half4 core, half4 edge, float coreSize, float glow, float4 rings, float ringAlpha) {
    float2 d = (position - size * 0.5) / min(size.x, size.y);
    float r = length(d);

    float coreLight = smoothstep(coreSize, 0.0, r) * glow;
    float halo = exp(-r * 7.0) * 0.55 * glow;

    float ringLight = 0.0;
    for (int i = 0; i < 4; i++) {
        float phase = rings[i];
        if (phase < 0.0) continue;
        float radius = 0.25 + phase * 0.25;
        // Slightly wobbly, so it feels alive.
        float wob = 0.004 * sin(atan2(d.y, d.x) * 3.0 + time * 2.0 + float(i));
        float ring = smoothstep(0.008, 0.0, abs(r - radius - wob));
        ringLight += ring * (1.0 - phase) * (1.0 - phase);
    }
    ringLight *= ringAlpha;

    float3 col = mix(float3(core.rgb), float3(edge.rgb), smoothstep(0.0, 0.5, r));
    float a = clamp(coreLight + halo + ringLight * 0.9, 0.0, 1.0);
    float3 outc = col * (coreLight * 1.4 + halo + ringLight) + float3(1.0) * coreLight * 0.6;
    // Light, not paint: the colour may run past alpha, which composites additively.
    return half4(half3(clamp(outc, 0.0, 1.0)), half(a));
}

// Signed distance to a rounded rectangle centred on the origin.
static float nw_roundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// glass.glsl's edge light: thicker glass at the rim catches a light from the
// top-left, with a slow sheen along it and a fine inner highlight. SwiftUI
// cannot hand a view its backdrop, so the refraction stays out; this is the
// rim alone, drawn over a glass surface. `strength` follows the Card glow
// setting (0 draws nothing). Premultiplied alpha.
[[ stitchable ]] half4 nwGlassRim(float2 position, half4 color, float2 size, float radius, float sheen,
                                  half4 edgeLight, float strength) {
    float2 p = position - size * 0.5;
    float dist = -nw_roundedBox(p, size * 0.5, radius);   // points inside the shape
    if (dist < 0.0 || strength <= 0.0) return half4(0.0);
    float rim = 1.0 - smoothstep(0.0, 14.0, dist);
    // The outward normal, from the distance field's gradient.
    float e = 0.5;
    float2 grad = float2(nw_roundedBox(p + float2(e, 0), size * 0.5, radius) - nw_roundedBox(p - float2(e, 0), size * 0.5, radius),
                         nw_roundedBox(p + float2(0, e), size * 0.5, radius) - nw_roundedBox(p - float2(0, e), size * 0.5, radius));
    float2 n = normalize(grad + 1e-5);
    float light = rim * max(0.0, dot(n, normalize(float2(-0.6, -0.8))));
    float sweep = 0.5 + 0.5 * sin(sheen + position.x / size.x * 4.0);
    float a = light * (0.35 + 0.35 * sweep) + smoothstep(1.5, 0.0, dist) * 0.25;
    a = clamp(a * strength, 0.0, 1.0);
    return half4(edgeLight.rgb * half(a), half(a));
}
