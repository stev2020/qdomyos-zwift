// Far hills and mountains around the horizon, seen through the summer haze.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;

uniform vec3 haze : source_color = vec3(0.74, 0.82, 0.88);
uniform float haze_amount = 0.5;

void fragment() {
	float top = COLOR.a;  // 0 at the foot .. 1 at the summit
	ALBEDO = mix(COLOR.rgb, haze, haze_amount + (1.0 - haze_amount) * (1.0 - top) * 0.55);
}
