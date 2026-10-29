// Pebbles on the paths (see World): small stones in the colours of their landscape, each one seen up to its reach
// (big ones further than small ones). Towards the end of its reach a pebble shrinks into the ground, so it never pops
// up. COLOR: the shade of the stone. INSTANCE_CUSTOM.rgb: its colour (linear), INSTANCE_CUSTOM.a: its reach in metres.
// No gloss from the sun (specular_disabled), as in nature.gdshader.
shader_type spatial;
render_mode cull_back, diffuse_lambert_wrap, specular_disabled;

// all reaches are scaled by this: shorter on a lower quality
uniform float reach_scale = 1.0;

varying vec3 v_col;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float reach = INSTANCE_CUSTOM.a * reach_scale;
	float fade = 1.0 - smoothstep(reach * 0.75, reach, distance(root, CAMERA_POSITION_WORLD));
	// the edge of the stone lies in the shade of the ground
	v_col = COLOR.rgb * INSTANCE_CUSTOM.rgb * mix(0.55, 1.0, smoothstep(-0.25, 0.25, VERTEX.y));
	VERTEX *= fade;
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 0.8;
}
