// Ground: painted patches of grass, bare sand and scree, the path and the bed of the stream, in the colours of the
// four landscapes. Path and stream are computed here from the same formulas as in land.gd, so their edges stay
// sharp even where the terrain mesh is coarse.
// COLOR: the share of each landscape (r Laubland, g Heide, b Flusstal, a Hochland). UV.x: bare ground (0 .. 1).
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

#include "res://shaders/land.gdshaderinc"

uniform sampler2D patch_noise : filter_linear_mipmap, repeat_enable;
// one colour per landscape: Laubland, Heide, Flusstal, Hochland
uniform vec3 grass_a[4] : source_color;
uniform vec3 grass_b[4] : source_color;
uniform vec3 grass_c[4] : source_color;
uniform vec3 under[4] : source_color;
uniform vec3 bare_color[4] : source_color;
uniform vec3 path_color[4] : source_color;
uniform vec3 path_rim[4] : source_color;
uniform vec3 bed_color[4] : source_color;
uniform float grass_fade = 52.0;

// width of the stream per landscape, as Land.STREAM_WIDTH
const vec4 STREAM_WIDTH = vec4(1.0, 0.0, 1.6, 0.6);
// grain of bare ground and path per landscape: dark earth, fine sand, gravel, stones
const vec4 GRAIN = vec4(0.12, 0.1, 0.3, 0.42);

#define LAND(c) (c[0] * w.x + c[1] * w.y + c[2] * w.z + c[3] * w.w)

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 w = COLOR / max(dot(COLOR, vec4(1.0)), 0.001);
	float u = -wpos.z;
	vec2 np = noise_pos(wpos);
	float n1 = texture(patch_noise, np / 256.0).r;
	float n2 = texture(patch_noise, np / 64.0).r;
	float n3 = texture(patch_noise, np / 8.0).r;
	float n4 = texture(patch_noise, np / 2.0).r;

	vec3 col = mix(LAND(grass_a), LAND(grass_b), smoothstep(0.35, 0.65, n1));
	col = mix(col, LAND(grass_c), smoothstep(0.58, 0.82, n2) * 0.55);
	col *= 0.86 + 0.22 * n3 + 0.1 * (n4 - 0.5);
	// under the grass clumps the ground is in their shade
	float cam_d = distance(wpos, CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(grass_fade - 18.0, grass_fade + 6.0, cam_d);
	col = mix(col, LAND(under) * (0.85 + 0.3 * n3), near * 0.6);

	// small stones and grains in two sizes: light flecks with darker gaps, strongest on scree
	float n5 = texture(patch_noise, np / 0.6).r;
	float n6 = texture(patch_noise, np / 1.3 + 0.37).r;
	float grain = 1.0 + dot(w, GRAIN) * ((smoothstep(0.3, 0.8, n5) * 0.6 + smoothstep(0.3, 0.8, n6) * 0.4) * 2.0 - 1.0);

	// bare ground with a frayed edge: sand in the heath, scree in the highland
	float bare = smoothstep(0.42, 0.6, UV.x + (n3 - 0.5) * 0.3 + (n4 - 0.5) * 0.2);
	col = mix(col, LAND(bare_color) * (0.8 + 0.3 * n3 + 0.18 * (n4 - 0.5)) * grain, bare);

	// the path with a frayed edge
	float px = path_x(u);
	float pdx = path_dx(u);
	float dp = abs(wpos.x - px) / sqrt(1.0 + pdx * pdx);
	float edge = dp + (n4 - 0.5) * 0.35 + (n3 - 0.5) * 0.45;
	float on_path = 1.0 - smoothstep(PATH_HALF - 0.2, PATH_HALF + 0.12, edge);
	float rim = smoothstep(PATH_HALF - 0.55, PATH_HALF, edge);
	vec3 dirt = LAND(path_color) * (0.9 + 0.18 * n4 + 0.08 * n3) * mix(1.0, grain, 0.7);
	// two faint wheel tracks
	float track = smoothstep(0.18, 0.0, abs(abs(wpos.x - px) - 0.45)) * 0.08;
	dirt *= 1.0 + track;
	dirt = mix(dirt, LAND(path_rim), rim * 0.55);
	col = mix(col, dirt, on_path);

	// stream bed: sand and pebbles, gravel banks along the river; no stream in the heath
	float sw = dot(w, STREAM_WIDTH);
	if (sw > 0.01) {
		float sx = stream_x(u);
		float sdx = stream_dx(u);
		float ds = abs(wpos.x - sx) / sqrt(1.0 + sdx * sdx);
		float bed = 1.0 - smoothstep(2.6 * sw, 3.7 * sw, ds + (n4 - 0.5) * 0.7);
		vec3 pebbles = LAND(bed_color) * (0.75 + 0.5 * n4);
		col = mix(col, pebbles, bed);
	}

	ALBEDO = col;
	ROUGHNESS = 0.96;
	SPECULAR = 0.2;
}
