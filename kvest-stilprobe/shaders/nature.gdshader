// Trees, bushes, firs and rocks in one material, so each kind needs only one draw call.
// COLOR.a = 1: leaf card with the painted leaf clusters (COLOR.r = shade inside the crown).
// COLOR.a = 0: solid part (bark, fir branches, rock) in the vertex colour.
// UV2.x: how much the wind moves the vertex. INSTANCE_CUSTOM: rgb = leaf tint, a = wind phase. Things without leaves
// that sink into the ground in the distance (the roots across the path) have b < 0 and sink between r and g metres.
// No gloss from the sun (specular_disabled): on the Adreno 740 (Galaxy Tab S9) Godot computes it in half precision,
// and for faces turned away from the camera and the sun a product in it overflows; times the light of 0 that gives
// no number at all, and the pixel turns black. Rough bark and leaves hardly show that gloss anyway.
// Nothing pops up: a block changes between its detailed and its simple models in a fine dissolve (lod_role, lod_mix,
// see World._fade_lods), and at the end of the land the trees fade into the haze.
shader_type spatial;
render_mode cull_disabled, world_vertex_coords, diffuse_lambert_wrap, specular_disabled;

uniform sampler2D leaf_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D leaf_normal : hint_normal, filter_linear_mipmap, repeat_disable;
uniform float alpha_cut = 0.45;
uniform float normal_strength = 0.9;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float wind_strength = 1.0;
// the rider's camera (main.gd): CAMERA_POSITION_WORLD is the light's camera in the shadow pass
uniform vec3 eye = vec3(0.0);
// how far the land reaches ahead and to the sides (World), and the colour of the haze there
uniform float view_ahead = 528.0;
uniform float view_side = 264.0;
uniform vec3 haze : source_color = vec3(0.74, 0.82, 0.88);
// +1: these models come in, -1: they go, 0: they stay; lod_mix: how far the change has come (0 .. 1)
instance uniform float lod_role = 0.0;
instance uniform float lod_mix = 1.0;

varying vec3 v_col;
varying float v_leaf;
varying vec3 v_n;
varying float v_haze;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float w = UV2.x * wind_strength;
	float ph = INSTANCE_CUSTOM.a * 6.2831;
	float sway = 0.5 + 0.5 * sin(TIME * 0.8 + ph + root.x * 0.02);
	VERTEX.xz += wind_dir * (0.05 + 0.14 * sway) * w;
	VERTEX += vec3(sin(TIME * 3.9 + VERTEX.x * 2.1 + VERTEX.y * 1.3),
			sin(TIME * 3.1 + VERTEX.z * 1.9) * 0.6,
			cos(TIME * 4.4 + VERTEX.y * 1.7)) * 0.028 * w * COLOR.a;
	if (INSTANCE_CUSTOM.b < 0.0) {
		VERTEX.y -= 0.45 * smoothstep(INSTANCE_CUSTOM.r, INSTANCE_CUSTOM.g, distance(root, eye));
	}
	// the land ends view_ahead ahead (the path runs towards -z) and view_side to the sides
	v_haze = max(smoothstep(view_ahead - 70.0, view_ahead - 5.0, eye.z - root.z),
			smoothstep(view_side - 45.0, view_side - 5.0, abs(root.x - eye.x)));
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
		// bark and rock: a smaller light wrap than the leaves, so the carved faces stand apart
		SPECULAR = 0.15;
		ROUGHNESS = 0.5;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ALBEDO = c * (1.0 - v_haze);
	EMISSION = haze * v_haze;
	// the dissolve between the two models of a block: the same fine pattern for both, so each pixel shows one of them
	// (after all texture reads: after a discard the derivatives are undefined)
	if (lod_role != 0.0) {
		float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if ((lod_role > 0.0) == (dither >= lod_mix)) {
			discard;
		}
	}
}
