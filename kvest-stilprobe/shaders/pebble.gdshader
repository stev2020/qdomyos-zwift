// Pebbles on the paths (see World): small stones in the colours of their landscape. Towards the end of their range
// they shrink into the ground, so they never pop up.
// COLOR: the shade of the stone. INSTANCE_CUSTOM.rgb: its colour (linear).
// No gloss from the sun (specular_disabled), as in nature.gdshader.
shader_type spatial;
render_mode cull_back, diffuse_lambert_wrap, specular_disabled;

uniform float fade_start = 34.0;
uniform float fade_end = 46.0;

varying vec3 v_col;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float fade = 1.0 - smoothstep(fade_start, fade_end, distance(root, CAMERA_POSITION_WORLD));
	// the lower part of the stone lies in the shade of the ground
	v_col = COLOR.rgb * INSTANCE_CUSTOM.rgb * mix(0.55, 1.0, smoothstep(-0.3, 0.2, VERTEX.y));
	VERTEX *= fade;
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 0.8;
}
