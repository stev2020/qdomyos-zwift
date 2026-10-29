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

varying vec3 v_col;
varying float v_leaf;
varying vec3 v_n;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float w = UV2.x * wind_strength;
	float ph = INSTANCE_CUSTOM.a * 6.2831;
	float sway = 0.5 + 0.5 * sin(TIME * 0.8 + ph + root.x * 0.02);
	VERTEX.xz += wind_dir * (0.05 + 0.14 * sway) * w;
	VERTEX += vec3(sin(TIME * 3.9 + VERTEX.x * 2.1 + VERTEX.y * 1.3),
			sin(TIME * 3.1 + VERTEX.z * 1.9) * 0.6,
			cos(TIME * 4.4 + VERTEX.y * 1.7)) * 0.028 * w * COLOR.a;
	v_leaf = COLOR.a;
	v_col = COLOR.a > 0.5 ? INSTANCE_CUSTOM.rgb * COLOR.r : COLOR.rgb;
	v_n = NORMAL;
}

void fragment() {
	vec3 c = v_col;
	// the crowns are lit like round volumes: the normals of the mesh, also on the back side. Built here with care
	// (no NaN from a length near zero): on the Adreno 740 (Galaxy Tab S9) such leaves turned black.
	vec3 n = v_n;
	float n_len = length(n);
	n = n_len > 0.0001 ? n / n_len : vec3(0.0, 1.0, 0.0);
	if (v_leaf > 0.5) {
		vec4 t = texture(leaf_tex, UV);
		// sampled before the discard: after it the derivatives for the mip level are undefined
		vec2 relief = texture(leaf_normal, UV).rg * 2.0 - 1.0;
		vec2 sz = vec2(textureSize(leaf_tex, 0));
		vec2 dx = dFdx(UV * sz);
		vec2 dy = dFdy(UV * sz);
		float lod = max(0.0, 0.5 * log2(max(dot(dx, dx), dot(dy, dy))));
		if (t.a * (1.0 + lod * 0.25) < alpha_cut) {
			discard;
		}
		c *= t.rgb;
		// the painted relief of the leaves, in a frame of the crown normal: the tangents of the mesh lie in the card
		// and can be almost parallel to that normal, and the frame Godot builds from them then fell apart
		vec3 side = cross(vec3(0.0, 1.0, 0.0), n);
		float side_len = length(side);
		side = side_len > 0.0001 ? side / side_len : vec3(1.0, 0.0, 0.0);
		n = normalize(n + (side * relief.x + cross(n, side) * relief.y) * normal_strength);
		BACKLIGHT = v_col * 0.32;
		SPECULAR = 0.12;
		ROUGHNESS = 0.85;
	} else {
		SPECULAR = 0.15;
		ROUGHNESS = 0.95;
		BACKLIGHT = c * 0.12;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ALBEDO = c;
}
