package app.page.android.ui.nw.components

import android.graphics.RuntimeShader
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import app.page.android.ui.nw.theme.Rgba

/**
 * The shader half of the living backdrop: AGSL ports of the boards' aurora, pulse and glass GLSL
 * (Designs/shaders/aurora.glsl, pulse.glsl, glass.glsl), the same three as iOS's NWNightWatch.metal (`nwAurora`,
 * `nwPulse`, `nwGlassRim`). A [RuntimeShader] needs Android 13 (API 33); below that, or if a device refuses to
 * compile one, the Canvas drawings take over (`NWAuroraCanvas`), so there is always a picture.
 */
object NWShaders {
    val available: Boolean get() = !forceCanvas && Build.VERSION.SDK_INT >= 33 && compiles

    /**
     * Set only by the debug render harness (`--ez page_canvas true`), to see the Canvas drawings a device below
     * Android 13 gets. Never set in a release build.
     */
    @Volatile var forceCanvas: Boolean = false

    /** Set only by the debug render harness (`--ez page_noblur true`): the Canvas aurora as a phone below Android 12 draws it, with no blur. */
    @Volatile var forceNoBlur: Boolean = false

    private val compiles: Boolean by lazy {
        if (Build.VERSION.SDK_INT < 33) false else runCatching { RuntimeShader(AURORA); RuntimeShader(PULSE); RuntimeShader(GLASS_RIM) }.isSuccess
    }

    private const val COMMON = """
float nw_hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float nw_ss(float e0, float e1, float x) { float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float nw_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(nw_hash(i), nw_hash(i + float2(1.0, 0.0)), u.x), mix(nw_hash(i + float2(0.0, 1.0)), nw_hash(i + float2(1.0, 1.0)), u.x), u.y);
}
float nw_fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * nw_noise(p); p = p * 2.03 + float2(1.7, 9.2); a *= 0.5; }
    return v;
}
"""

    /**
     * aurora.glsl: curtains bent by slow noise, streaks, stars fading towards the horizon and a vignette, over the
     * palette's sky gradient. `intensity` 0 is the bare sky (dusk). `stars` scales the scatter of stars. `phase` moves
     * the curtains: the GLSL's time * u_speed, accumulated in Kotlin ([nwAuroraPhase]) so a change of speed never jumps
     * them; `time` is the stars' own twinkle clock.
     */
    const val AURORA = COMMON + """
uniform float2 size;
uniform float time;
uniform float phase;
uniform float starCell;
layout(color) uniform half4 skyTop;
layout(color) uniform half4 skyBottom;
layout(color) uniform half4 c1;
layout(color) uniform half4 c2;
layout(color) uniform half4 c3;
uniform float intensity;
uniform float stars;

half4 main(float2 fragCoord) {
    float2 uv = float2(fragCoord.x / size.x, 1.0 - fragCoord.y / size.y);
    float aspect = size.x / size.y;
    float2 p = float2(uv.x * aspect, uv.y);
    float t = phase;

    float warp = nw_fbm(p * 1.4 + float2(t * 0.6, -t * 0.25));
    float band1 = nw_ss(0.35, 0.0, abs(uv.y - 0.62 - 0.18 * sin(p.x * 1.6 + t + warp * 3.0)));
    float band2 = nw_ss(0.30, 0.0, abs(uv.y - 0.78 - 0.12 * sin(p.x * 2.3 - t * 1.3 + warp * 2.0)));
    float band3 = nw_ss(0.45, 0.0, abs(uv.y - 0.45 - 0.2 * sin(p.x * 1.1 + t * 0.7 - warp * 2.5)));
    float streaks = pow(nw_fbm(float2(p.x * 8.0 + warp * 4.0, t * 0.8)), 2.0);

    float3 col = mix(skyBottom.rgb, skyTop.rgb, nw_ss(0.0, 1.0, uv.y));
    col += c1.rgb * band1 * (0.55 + 0.6 * streaks) * intensity;
    col += c2.rgb * band2 * (0.45 + 0.5 * streaks) * intensity;
    col += c3.rgb * band3 * 0.35 * intensity;

    // Stars, fading towards the horizon (about two device pixels each).
    float2 cell = floor(fragCoord / starCell);
    float s = step(0.9975, nw_hash(cell)) * nw_ss(0.3, 1.0, uv.y);
    col += float3(s) * (0.6 + 0.4 * sin(time * 3.0 + nw_hash(cell + 7.0) * 6.28)) * stars;

    col *= 1.0 - 0.55 * pow(length(uv - float2(0.5, 0.55)), 1.6);
    return half4(half3(col), 1.0);
}
"""

    /** pulse.glsl: the glowing core, its halo and the expanding rings, drawn behind the pulse glyph. The rings are not on a clock of their own: the caller passes each ring's progress (`PulseModel.ripples`), -1 for none, so the shader and the Canvas fallback always agree. */
    const val PULSE = """
uniform float2 size;
uniform float time;
layout(color) uniform half4 core;
layout(color) uniform half4 edge;
uniform float coreSize;
uniform float glow;
uniform float4 rings;
uniform float ringAlpha;

half4 main(float2 fragCoord) {
    float2 d = (fragCoord - size * 0.5) / min(size.x, size.y);
    float r = length(d);
    float coreLight = clamp(1.0 - r / coreSize, 0.0, 1.0);
    coreLight = coreLight * coreLight * (3.0 - 2.0 * coreLight) * glow;
    float halo = exp(-r * 7.0) * 0.55 * glow;

    float ringLight = 0.0;
    for (int i = 0; i < 4; i++) {
        float phase = rings[i];
        if (phase >= 0.0) {
            float radius = 0.25 + phase * 0.25;
            float wob = 0.004 * sin(atan(d.y, d.x) * 3.0 + time * 2.0 + float(i));
            float x = clamp(1.0 - abs(r - radius - wob) / 0.008, 0.0, 1.0);
            float ring = x * x * (3.0 - 2.0 * x);
            ringLight += ring * (1.0 - phase) * (1.0 - phase);
        }
    }
    ringLight *= ringAlpha;

    float k = clamp(r / 0.5, 0.0, 1.0);
    k = k * k * (3.0 - 2.0 * k);
    float3 col = mix(core.rgb, edge.rgb, k);
    float a = clamp(coreLight + halo + ringLight * 0.9, 0.0, 1.0);
    float3 outc = col * (coreLight * 1.4 + halo + ringLight) + float3(1.0) * coreLight * 0.6;
    return half4(half3(clamp(outc, 0.0, 1.0)), half(a));
}
"""

    /** glass.glsl's edge light: thicker glass at the rim catches a light from the top-left, with a slow sheen along it and a fine inner highlight. A surface cannot hand a view its backdrop, so the refraction stays out; this is the rim alone, drawn over a glass surface. `strength` follows the Card glow setting (0 draws nothing). */
    const val GLASS_RIM = """
uniform float2 size;
uniform float radius;
uniform float sheen;
uniform float px;
layout(color) uniform half4 edgeLight;
uniform float strength;

float nw_roundedBox(float2 p, float2 halfSize, float rad) {
    float2 q = abs(p) - halfSize + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}

half4 main(float2 fragCoord) {
    float2 p = fragCoord - size * 0.5;
    float dist = -nw_roundedBox(p, size * 0.5, radius);
    if (dist < 0.0 || strength <= 0.0) return half4(0.0);
    // The board's widths are in points; AGSL measures in pixels.
    float rk = clamp(dist / (14.0 * px), 0.0, 1.0);
    float rim = 1.0 - rk * rk * (3.0 - 2.0 * rk);
    float e = 0.5 * px;
    float2 grad = float2(nw_roundedBox(p + float2(e, 0.0), size * 0.5, radius) - nw_roundedBox(p - float2(e, 0.0), size * 0.5, radius),
                         nw_roundedBox(p + float2(0.0, e), size * 0.5, radius) - nw_roundedBox(p - float2(0.0, e), size * 0.5, radius));
    float2 n = normalize(grad + 0.00001);
    float light = rim * max(0.0, dot(n, normalize(float2(-0.6, -0.8))));
    float sweep = 0.5 + 0.5 * sin(sheen + fragCoord.x / size.x * 4.0);
    float inner = clamp(1.0 - dist / (1.5 * px), 0.0, 1.0);
    float a = light * (0.35 + 0.35 * sweep) + inner * inner * (3.0 - 2.0 * inner) * 0.25;
    a = clamp(a * strength, 0.0, 1.0);
    return half4(edgeLight.rgb * half(a), half(a));
}
"""

    @RequiresApi(33)
    fun setColor(shader: RuntimeShader, name: String, c: Rgba) {
        shader.setColorUniform(name, Color(c.r.toFloat(), c.g.toFloat(), c.b.toFloat(), c.a.toFloat()).toArgb())
    }
}
