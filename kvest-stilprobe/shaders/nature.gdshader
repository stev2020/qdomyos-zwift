// Trees, bushes, firs and rocks in one material, so each kind needs only one draw call.
// COLOR.a = 1: leaf card with the painted leaf clusters (COLOR.r = shade inside the crown).
// COLOR.a = 0: solid part (bark, fir branches, rock) in the vertex colour.
// UV2.x: how much the wind moves the vertex. INSTANCE_CUSTOM: rgb = leaf tint, a = wind phase.
shader_type spatial;
render_mode cull_disabled, world_vertex_coords, diffuse_lambert_wrap;

uniform sampler2D leaf_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D leaf_normal : hint_normal, filter_linear_mipmap, repeat_disable;
uniform float alpha_cut = 0.45;
uniform float normal_strength = 0.9;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float wind_strength = 1.0;
// kvest_test (test button of the style test, finding graphics problems of a device): 1 no sheen, 2 no light
// shining through, 3 no tint per plant, 4 no wind, 5 no mip trick for the cut-out, 6 back sides lit like the front
global uniform int kvest_test;

varying vec3 v_col;
varying float v_leaf;
varying vec3 v_n;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float w = kvest_test == 4 ? 0.0 : UV2.x * wind_strength;
	float ph = INSTANCE_CUSTOM.a * 6.2831;
	float sway = 0.5 + 0.5 * sin(TIME * 0.8 + ph + root.x * 0.02);
	VERTEX.xz += wind_dir * (0.05 + 0.14 * sway) * w;
	VERTEX += vec3(sin(TIME * 3.9 + VERTEX.x * 2.1 + VERTEX.y * 1.3),
			sin(TIME * 3.1 + VERTEX.z * 1.9) * 0.6,
			cos(TIME * 4.4 + VERTEX.y * 1.7)) * 0.028 * w * COLOR.a;
	v_leaf = COLOR.a;
	v_col = COLOR.a > 0.5 ? (kvest_test == 3 ? vec3(0.45, 0.6, 0.25) : INSTANCE_CUSTOM.rgb) * COLOR.r : COLOR.rgb;
	v_n = NORMAL;
}

void fragment() {
	vec3 c = v_col;
	if (v_leaf > 0.5) {
		vec4 t = texture(leaf_tex, UV);
		vec2 sz = vec2(textureSize(leaf_tex, 0));
		vec2 dx = dFdx(UV * sz);
		vec2 dy = dFdy(UV * sz);
		float lod = kvest_test == 5 ? 0.0 : max(0.0, 0.5 * log2(max(dot(dx, dx), dot(dy, dy))));
		if (t.a * (1.0 + lod * 0.25) < alpha_cut) {
			discard;
		}
		c *= t.rgb;
		NORMAL_MAP = texture(leaf_normal, UV).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
		BACKLIGHT = kvest_test == 2 ? vec3(0.0) : v_col * 0.32;
		SPECULAR = kvest_test == 1 ? 0.0 : 0.12;
		ROUGHNESS = 0.85;
	} else {
		SPECULAR = kvest_test == 1 ? 0.0 : 0.15;
		ROUGHNESS = 0.95;
		BACKLIGHT = kvest_test == 2 ? vec3(0.0) : c * 0.12;
	}
	// the crowns are lit like round volumes: use the normals of the mesh, also on the back side
	NORMAL = normalize((VIEW_MATRIX * vec4(v_n, 0.0)).xyz);
	ALBEDO = c;
}
