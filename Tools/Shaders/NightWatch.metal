// Night Watch's living backdrop, as SwiftUI shaders (macOS 14+): the aurora,
// the pulse and the glass rim, ported from Designs/shaders/{aurora,pulse,
// glass}.glsl. SwiftPM's `swift build` does not compile .metal files, so this
// source lives outside Sources/ and Tools/Shaders/build-shaders.sh compiles
// it into the metallib embedded in
// Sources/ClaudePowerMode/UI/Components/NWShaderBlob.generated.swift.
//
// Coordinates are SwiftUI points with the origin at the top left (the GLSL
// had it at the bottom left). Colours come in as sRGB 0...1 numbers and go
// out premultiplied. Time and every phase come from Swift, so a frame at a
// given time is the same frame every time (the render harness relies on it).

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace nw {
    float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x),
                   mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
    }

    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + float2(1.7, 9.2); a *= 0.5; }
        return v;
    }

    // Signed distance to a rounded rectangle centred at the origin (negative inside).
    float roundedBox(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
}

// MARK: - Aurora

/// The header sky: curtains bent by slow noise, streaks, a star field, a
/// vignette. `palette` rows are c1, c2, c3 (curtains), sky top and sky bottom.
/// `mood` = (intensity, curtain speed, star strength, dusk 0...1).
/// `dawn` = (front 0...1 up from the horizon, warm glow 0...1, horizon band
/// 0...1, horizon height as a share of the height from the top).
[[ stitchable ]] half4 nwAurora(float2 position, half4 color, float2 size, float time,
                                float3 c1, float3 c2, float3 c3, float3 skyTop, float3 skyBottom,
                                float4 mood, float4 dawn) {
    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);   // y up, as in the GLSL
    float aspect = size.x / size.y;
    float intensity = mood.x, speed = mood.y, stars = mood.z, dusk = mood.w;
    float t = time * 0.4 * speed;

    // Wide, short header: squash x so the curtains keep the board's rhythm.
    float2 p = float2(uv.x * min(aspect, 2.6), uv.y);
    float warp = nw::fbm(p * 1.4 + float2(t * 0.6, -t * 0.25));
    float band1 = smoothstep(0.34, 0.0, abs(uv.y - 0.60 - 0.16 * sin(p.x * 1.6 + t + warp * 3.0)));
    float band2 = smoothstep(0.26, 0.0, abs(uv.y - 0.80 - 0.10 * sin(p.x * 2.3 - t * 1.3 + warp * 2.0)));
    float band3 = smoothstep(0.42, 0.0, abs(uv.y - 0.42 - 0.18 * sin(p.x * 1.1 + t * 0.7 - warp * 2.5)));
    float streaks = pow(nw::fbm(float2(p.x * 8.0 + warp * 4.0, t * 0.8)), 2.0);
    // Rays: the curtains' fine vertical structure, brightest just above each band.
    float rays = pow(nw::noise(float2(p.x * 22.0 + warp * 6.0, t * 0.3)), 3.0);

    float3 col = mix(skyBottom, skyTop, smoothstep(0.0, 1.0, uv.y));
    float k = intensity * (1.0 - dusk);
    col += c1 * band1 * (0.55 + 0.6 * streaks + 0.5 * rays) * k;
    col += c2 * band2 * (0.45 + 0.5 * streaks + 0.4 * rays) * k;
    col += c3 * band3 * 0.35 * k;

    // Stars, fading towards the horizon; they dim with dusk.
    float2 cell = floor(position * 0.5);
    float s = step(0.9965, nw::hash(cell)) * smoothstep(0.25, 1.0, uv.y);
    col += float3(s) * (0.45 + 0.35 * sin(time * 1.6 + nw::hash(cell + 7.0) * 6.28)) * stars * (1.0 - 0.75 * dusk);

    // Dawn: warm light behind a front rising from the horizon.
    float horizonUp = 1.0 - dawn.w;                    // horizon height from the bottom
    float above = (uv.y - horizonUp) / max(0.001, 1.0 - horizonUp);   // 0 at the horizon ... 1 at the top
    if (dawn.y > 0.0) {
        float lit = smoothstep(dawn.x + 0.18, dawn.x - 0.12, above) * step(-0.25, above);
        float3 warm = mix(float3(0.96, 0.69, 0.30), float3(1.0, 0.85, 0.62), smoothstep(0.0, 1.0, above));
        float nearHorizon = exp(-max(0.0, above) * 2.2);
        col += warm * lit * dawn.y * (0.22 + 0.45 * nearHorizon);
    }
    // The grey horizon band that holds while paused.
    if (dawn.z > 0.0) {
        float d = abs(position.y - size.y * dawn.w);
        col += float3(0.62, 0.64, 0.70) * smoothstep(1.4, 0.0, d) * 0.55 * dawn.z;
        col += float3(0.45, 0.47, 0.55) * exp(-d * 0.35) * 0.06 * dawn.z;
    }

    // Vignette.
    col *= 1.0 - 0.45 * pow(length(uv - float2(0.5, 0.6)), 1.8);
    return half4(half3(saturate(col)), 1.0h);
}

// MARK: - Pulse

/// The pulse's soft parts: halo and ripple rings (the crisp ring and core are
/// drawn by SwiftUI above). `geom` = (core radius, inner ring radius, outer
/// ring radius, glow 0...1), points. `rings` holds (progress, alpha) pairs
/// worked out in Swift by PulseModel.
[[ stitchable ]] half4 nwPulse(float2 position, half4 color, float2 size, float time,
                               float3 core, float3 edge, float4 geom,
                               device const float *rings, int count) {
    float2 d = position - size * 0.5;
    float r = length(d);
    float coreR = geom.x, inner = geom.y, outer = geom.z, glow = geom.w;

    float halo = exp(-r / max(1.0, coreR * 1.7)) * 0.75 * glow;
    float ringSum = 0.0;
    int n = count / 2;
    float angle = atan2(d.y, d.x);
    for (int i = 0; i < n && i < 6; i++) {
        float p = rings[2 * i], a = rings[2 * i + 1];
        float radius = mix(inner, outer, p);
        float wob = 0.45 * sin(angle * 3.0 + time * 2.0 + float(i) * 1.7);
        float w = 0.9 + 0.5 * p;
        ringSum += smoothstep(w, 0.0, abs(r - radius - wob)) * a;
        // A faint bloom round each ring.
        ringSum += exp(-abs(r - radius) * 0.45) * a * 0.18;
    }
    float3 col = mix(core, edge, smoothstep(0.0, outer, r));
    // Everything fades out before the layer's edge, so no square ever shows.
    float edgeFade = smoothstep(size.x * 0.5, size.x * 0.5 - 10.0, r);
    float alpha = saturate(halo + ringSum) * edgeFade;
    return half4(half3(col * alpha), half(alpha));
}

// MARK: - Glass

/// The glass rim over its own layer: near the edge the content is pulled in
/// from further inside (thicker glass at the rim; a layer has nothing beyond
/// its own edge to bend in, unlike the desktop glass.glsl sampled) and softly
/// blurred, and a slow specular runs along the top-left edge. The shape is a
/// rounded rectangle the size of the layer; `shape` = (corner radius,
/// refraction in points, rim width, 1 when the bottom edge is open: the rim
/// then fades out down the sides). `light` is the edge light colour.
[[ stitchable ]] half4 nwGlass(float2 position, SwiftUI::Layer layer, float2 size, float time,
                               float4 shape, float3 light) {
    float radius = shape.x, refract = shape.y, rimWidth = shape.z;
    float2 halfSize = size * 0.5;
    float2 centre = halfSize;
    if (shape.w > 0.5) { halfSize.y = size.y; centre.y = size.y; }   // no rim along the bottom
    float2 p = position - centre;
    float sd = nw::roundedBox(p, halfSize, radius);
    float inside = -sd;                                               // points inside the edge
    float e = 0.75;
    float2 grad = float2(nw::roundedBox(p + float2(e, 0), halfSize, radius) - nw::roundedBox(p - float2(e, 0), halfSize, radius),
                         nw::roundedBox(p + float2(0, e), halfSize, radius) - nw::roundedBox(p - float2(0, e), halfSize, radius));
    float2 n = normalize(grad + 1e-5);                                // outward normal

    float rim = 1.0 - smoothstep(0.0, rimWidth, inside);
    if (shape.w > 0.5) { rim *= smoothstep(size.y * 0.85, size.y * 0.25, position.y); }
    float2 offset = -n * rim * refract;

    half4 acc = half4(0.0h);
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * 0.785398;
        acc += layer.sample(position + offset + float2(cos(ang), sin(ang)) * (1.0 + 2.0 * rim));
    }
    half4 c = acc / 8.0h;
    half4 base = layer.sample(position);
    c = mix(base, c, half(rim));

    // Light from above, a touch to the left: it catches the top edge and the
    // top-left corner, not the sides.
    float lit = rim * pow(max(0.0, dot(n, normalize(float2(-0.35, -0.94)))), 3.0);
    float sweep = 0.5 + 0.5 * sin(time * 0.8 + position.x / size.x * 4.0);
    float3 add = light * lit * (0.30 + 0.35 * sweep) + float3(1.0) * smoothstep(1.5, 0.0, inside) * 0.18;
    c.rgb += half3(add) * c.a;
    return c;
}
