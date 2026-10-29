// Ground: painted patches of meadow, the dirt path and the pebbly bed of the stream.
// Path and stream are computed here from the same formulas as in land.gd, so their edges stay
// sharp even where the terrain mesh is coarse.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

#include "res://shaders/land.gdshaderinc"

uniform sampler2D patch_noise : filter_linear_mipmap, repeat_enable;
uniform vec3 grass_a : source_color = vec3(0.30, 0.44, 0.10);
uniform vec3 grass_b : source_color = vec3(0.46, 0.56, 0.14);
uniform vec3 grass_c : source_color = vec3(0.60, 0.60, 0.22);
uniform vec3 under : source_color = vec3(0.25, 0.37, 0.09);
uniform vec3 path_color : source_color = vec3(0.72, 0.60, 0.40);
uniform vec3 path_rim : source_color = vec3(0.42, 0.36, 0.24);
uniform float grass_fade = 52.0;
uniform vec3 bed_color : source_color = vec3(0.58, 0.55, 0.47);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float u = -wpos.z;
	vec2 np = noise_pos(wpos);
	float n1 = texture(patch_noise, np / 256.0).r;
	float n2 = texture(patch_noise, np / 64.0).r;
	float n3 = texture(patch_noise, np / 8.0).r;
	float n4 = texture(patch_noise, np / 2.0).r;

	vec3 col = mix(grass_a, grass_b, smoothstep(0.35, 0.65, n1));
	col = mix(col, grass_c, smoothstep(0.58, 0.82, n2) * 0.55);
	col *= 0.86 + 0.22 * n3 + 0.1 * (n4 - 0.5);
	// under the grass clumps the ground is in their shade
	float cam_d = distance(wpos, CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(grass_fade - 18.0, grass_fade + 6.0, cam_d);
	col = mix(col, under * (0.85 + 0.3 * n3), near * 0.6);

	// dirt path with a frayed edge
	float px = path_x(u);
	float pdx = path_dx(u);
	float dp = abs(wpos.x - px) / sqrt(1.0 + pdx * pdx);
	float edge = dp + (n4 - 0.5) * 0.35 + (n3 - 0.5) * 0.45;
	float on_path = 1.0 - smoothstep(PATH_HALF - 0.2, PATH_HALF + 0.12, edge);
	float rim = smoothstep(PATH_HALF - 0.55, PATH_HALF, edge);
	vec3 dirt = path_color * (0.9 + 0.18 * n4 + 0.08 * n3);
	// two faint wheel tracks
	float track = smoothstep(0.18, 0.0, abs(abs(wpos.x - px) - 0.45)) * 0.08;
	dirt *= 1.0 + track;
	dirt = mix(dirt, path_rim, rim * 0.55);
	col = mix(col, dirt, on_path);

	// stream bed: sand and pebbles
	float sx = stream_x(u);
	float sdx = stream_dx(u);
	float ds = abs(wpos.x - sx) / sqrt(1.0 + sdx * sdx);
	float bed = 1.0 - smoothstep(2.6, 3.7, ds + (n4 - 0.5) * 0.7);
	vec3 pebbles = bed_color * (0.75 + 0.5 * n4);
	col = mix(col, pebbles, bed);

	ALBEDO = col;
	ROUGHNESS = 0.96;
	SPECULAR = 0.2;
}
