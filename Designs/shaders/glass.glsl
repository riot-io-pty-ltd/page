precision highp float;

/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/** @backdrop */
uniform sampler2D u_backdrop;
/** @sdf */
uniform sampler2D u_sdf;
/**
 * @label Tint
 * @color
 * @default #12151B
 */
uniform vec3 u_tint;
/**
 * @label Tint amount
 * @default 0.55
 * @range 0.0, 1.0
 */
uniform float u_tintAmount;
/**
 * @label Refraction
 * @default 18.0
 * @range 0.0, 60.0
 */
uniform float u_refract;
/**
 * @label Edge light
 * @color
 * @default #9FF5E8
 */
uniform vec3 u_edge;

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution.xy;
  vec4 s = texture2D(u_sdf, uv);
  float dist = s.r;                 // pixels inside the shape
  vec2 grad = s.gb;

  // Bend the backdrop near the rim (thicker glass at the edge).
  float rim = 1.0 - smoothstep(0.0, 22.0, dist);
  vec2 offset = -normalize(grad + 1e-5) * rim * u_refract / u_resolution;

  // Soft blur: a few taps around the refracted point.
  vec3 acc = vec3(0.0);
  for (int i = 0; i < 8; i++) {
    float ang = float(i) * 0.785398;
    acc += texture2D(u_backdrop, uv + offset + vec2(cos(ang), sin(ang)) * 6.0 / u_resolution).rgb;
  }
  vec3 back = acc / 8.0;
  vec3 col = mix(back, u_tint, u_tintAmount);

  // Moving specular along the top-left rim.
  float light = rim * max(0.0, dot(normalize(grad + 1e-5), normalize(vec2(-0.6, 0.8))));
  float sweep = 0.5 + 0.5 * sin(u_time * 0.8 + uv.x * 4.0);
  col += u_edge * light * (0.35 + 0.35 * sweep);
  col += vec3(1.0) * smoothstep(1.5, 0.0, dist) * 0.25;

  gl_FragColor = vec4(col, 1.0);
}
