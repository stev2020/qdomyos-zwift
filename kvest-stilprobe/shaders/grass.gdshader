// Grass clumps: six crossing cards with a painted grass texture (12 triangles per clump).
// INSTANCE_CUSTOM: x = atlas cell (0..7, see tools/make_textures.py), y = brightness, z = random phase, w = dryness.
// In the distance each clump sinks into the ground at a distance of its own between fade_start and fade_end, so the
// grass thins out over that band instead of ending at a line. Beyond it the ground is painted in the colours the
// grass has from afar (terrain.gdshader).
shader_type spatial;
render_mode cull_disabled, world_vertex_coords, diffuse_lambert_wrap;

#include "res://shaders/land.gdshaderinc"

uniform sampler2D grass_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D patch_noise : filter_linear_mipmap, repeat_enable;
uniform float alpha_cut = 0.42;
uniform float fade_start = 36.0;
uniform float fade_end = 57.0;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float wind_strength = 1.0;
uniform vec3 dry_tint : source_color = vec3(1.0, 0.9, 0.62);

varying float v_h;
varying vec3 v_tint;
varying float v_gust;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float h = 1.0 - UV.y;
	float cell = INSTANCE_CUSTOM.x;
	float col = mod(cell, 2.0);
	float row = floor(cell / 2.0 + 0.01);
	// each cell is 256 rows high, the grass is painted in the upper 240
	UV = vec2(UV.x * 0.5 + col * 0.5, (UV.y * (240.0 / 256.0) + row) / 4.0);

	float dist = distance(root, CAMERA_POSITION_WORLD);
	float own_end = mix(fade_start + 3.0, fade_end, INSTANCE_CUSTOM.z);
	float fade = 1.0 - smoothstep(own_end - 3.0, own_end, dist);

	// gusts: patches of stronger wind that travel across the meadow
	vec2 np = vec2(root.x, -root.z + noise_shift);
	float g = texture(patch_noise, np / 64.0 - wind_dir * TIME * 0.035).r;
	float wave = 0.5 + 0.5 * sin(dot(root.xz, wind_dir) * 0.08 - TIME * 1.6);
	float gust = clamp(g * 1.7 - 0.45, 0.0, 1.0) * (0.55 + 0.45 * wave);
	float flutter = sin(TIME * 3.3 + INSTANCE_CUSTOM.z * 31.0) * 0.05 + sin(TIME * 5.1 + VERTEX.x * 3.0) * 0.02;
	float bend = (0.12 + 0.55 * gust) * wind_strength + flutter;
	float vh = VERTEX.y - root.y;
	VERTEX.xz += wind_dir * bend * vh * h;
	VERTEX.y -= abs(bend) * vh * h * 0.3;
	// shrink into the ground in the distance, so the edge of the grass is invisible
	VERTEX = mix(vec3(VERTEX.x, root.y - 0.05, VERTEX.z), VERTEX, fade);

	float patch = texture(patch_noise, np / 256.0).r;
	vec3 tint = vec3(INSTANCE_CUSTOM.y) * mix(vec3(0.9, 0.95, 0.85), vec3(1.08, 1.04, 0.92), smoothstep(0.35, 0.65, patch));
	v_tint = mix(tint, tint * dry_tint, INSTANCE_CUSTOM.w);
	v_h = h;
	v_gust = gust;
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	vec4 t = texture(grass_tex, UV);
	// mipmaps average the thin blades away; push the alpha up with the mip level to keep them
	vec2 sz = vec2(textureSize(grass_tex, 0));
	vec2 dx = dFdx(UV * sz);
	vec2 dy = dFdy(UV * sz);
	float lod = max(0.0, 0.5 * log2(max(dot(dx, dx), dot(dy, dy))));
	// discard instead of ALPHA_SCISSOR_THRESHOLD: same result, and it renders correctly on every driver we tried
	// the lowest part of the cards is hidden: the blades seem to grow out of the dark ground
	if (t.a * (1.0 + lod * 0.2) * smoothstep(0.02, 0.16, v_h) < alpha_cut) {
		discard;
	}
	vec3 c = t.rgb * v_tint * (1.0 + v_gust * v_h * 0.18) * mix(0.8, 1.0, smoothstep(0.0, 0.5, v_h));
	ALBEDO = c;
	// every card is lit like the meadow under it, also from behind: there the normal would point down, and the
	// Adreno 740 (Galaxy Tab S9) draws such blades black
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	BACKLIGHT = c * 0.35 * v_h;
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
	AO = mix(0.78, 1.0, v_h);
	AO_LIGHT_AFFECT = 0.35;
}
