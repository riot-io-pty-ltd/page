precision highp float;

/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/**
 * @label Speed
 * @default 0.35
 * @range 0.0, 2.0
 */
uniform float u_speed;
/**
 * @label Base
 * @color
 * @default #06080D
 */
uniform vec3 u_base;
/**
 * @label Cyan
 * @color
 * @default #5EEAD4
 */
uniform vec3 u_c1;
/**
 * @label Sky
 * @color
 * @default #38BDF8
 */
uniform vec3 u_c2;
/**
 * @label Violet
 * @color
 * @default #7C5CFF
 */
uniform vec3 u_c3;
/**
 * @label Intensity
 * @default 0.9
 * @range 0.0, 2.0
 */
uniform float u_intensity;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + vec2(1.7, 9.2); a *= 0.5; }
  return v;
}

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution.xy;
  float aspect = u_resolution.x / u_resolution.y;
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = u_time * u_speed;

  // Curtains: bands bent by slow noise, brighter near the top.
  float warp = fbm(p * 1.4 + vec2(t * 0.6, -t * 0.25));
  float band1 = smoothstep(0.35, 0.0, abs(uv.y - 0.62 - 0.18 * sin(p.x * 1.6 + t + warp * 3.0)));
  float band2 = smoothstep(0.30, 0.0, abs(uv.y - 0.78 - 0.12 * sin(p.x * 2.3 - t * 1.3 + warp * 2.0)));
  float band3 = smoothstep(0.45, 0.0, abs(uv.y - 0.45 - 0.2 * sin(p.x * 1.1 + t * 0.7 - warp * 2.5)));
  float streaks = pow(fbm(vec2(p.x * 8.0 + warp * 4.0, t * 0.8)), 2.0);

  vec3 col = u_base;
  col += u_c1 * band1 * (0.55 + 0.6 * streaks) * u_intensity;
  col += u_c2 * band2 * (0.45 + 0.5 * streaks) * u_intensity;
  col += u_c3 * band3 * 0.35 * u_intensity;

  // Stars, fading towards the horizon.
  float s = step(0.9975, hash(floor(gl_FragCoord.xy * 0.5))) * smoothstep(0.3, 1.0, uv.y);
  col += vec3(s) * (0.6 + 0.4 * sin(u_time * 3.0 + hash(floor(gl_FragCoord.xy)) * 6.28));

  // Vignette.
  col *= 1.0 - 0.55 * pow(length(uv - vec2(0.5, 0.55)), 1.6);
  gl_FragColor = vec4(col, 1.0);
}
