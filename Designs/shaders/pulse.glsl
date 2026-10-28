precision highp float;

/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Core
 * @color
 * @default #5EEAD4
 */
uniform vec3 u_core;
/**
 * @label Edge
 * @color
 * @default #38BDF8
 */
uniform vec3 u_edge;
/**
 * @label Rings per second
 * @default 0.45
 * @range 0.05, 2.0
 */
uniform float u_rate;
/**
 * @label Centre X
 * @default 0.5
 * @range 0.0, 1.0
 */
uniform float u_cx;
/**
 * @label Centre Y
 * @default 0.5
 * @range 0.0, 1.0
 */
uniform float u_cy;
/**
 * @label Core size
 * @default 0.06
 * @range 0.01, 0.3
 */
uniform float u_size;

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution.xy;
  vec2 d = uv - vec2(u_cx, 1.0 - u_cy);
  d.x *= u_resolution.x / u_resolution.y;
  float r = length(d);

  // Glowing core.
  float core = smoothstep(u_size, 0.0, r);
  float halo = exp(-r * 7.0) * 0.55;

  // Three expanding rings, fading as they grow; slightly wobbly so it feels alive.
  float rings = 0.0;
  for (int i = 0; i < 3; i++) {
    float phase = fract(u_time * u_rate + float(i) / 3.0);
    float radius = u_size + phase * 0.55;
    float wob = 0.006 * sin(atan(d.y, d.x) * 3.0 + u_time * 2.0 + float(i));
    float ring = smoothstep(0.012, 0.0, abs(r - radius - wob));
    rings += ring * (1.0 - phase) * (1.0 - phase);
  }

  vec3 col = mix(u_core, u_edge, smoothstep(0.0, 0.5, r));
  float a = clamp(core + halo + rings * 0.9, 0.0, 1.0);
  vec3 outc = col * (core * 1.4 + halo + rings) + vec3(1.0) * core * 0.6;
  gl_FragColor = vec4(outc, a);
}
