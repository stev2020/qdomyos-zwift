// The stream: clear water, foam along the banks and on the riffles, glints of the sun.
// UV.x: 0 left bank .. 1 right bank, UV.y: metres along the stream (repeats every 512 m).
// COLOR.r: 1 if the water flows forward, 0 if it flows towards the rider.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_lambert_wrap;

uniform sampler2D water_noise : filter_linear_mipmap, repeat_enable;
uniform vec3 deep : source_color = vec3(0.10, 0.29, 0.30);
uniform vec3 shallow : source_color = vec3(0.36, 0.55, 0.47);
uniform vec3 foam_color : source_color = vec3(0.93, 0.96, 0.94);

void fragment() {
	float dir = COLOR.r * 2.0 - 1.0;
	vec2 uv1 = vec2(UV.x * 0.9, UV.y / 8.0 + TIME * 0.32 * dir);
	vec2 uv2 = vec2(UV.x * 1.7 + 0.37, UV.y / 4.0 + TIME * 0.55 * dir);
	float n1 = texture(water_noise, uv1).r;
	float n2 = texture(water_noise, uv2).r;
	float centre = 1.0 - abs(UV.x * 2.0 - 1.0);
	vec3 c = mix(shallow, deep, smoothstep(0.15, 0.9, centre) * 0.85);
	float foam = smoothstep(0.74, 0.9, n1 * 0.55 + n2 * 0.6 - centre * 0.2);
	foam += (1.0 - smoothstep(0.0, 0.18, centre)) * 0.4 * smoothstep(0.4, 0.75, n2);
	foam = clamp(foam, 0.0, 1.0);
	ALBEDO = mix(c, foam_color, foam);
	ALPHA = mix(0.8, 0.96, foam);
	ROUGHNESS = mix(0.14, 0.6, foam);
	SPECULAR = 0.4;
	NORMAL_MAP = vec3(0.5 + (n1 - n2) * 0.7, 0.5 + (n2 - 0.5) * 0.7, 1.0);
	NORMAL_MAP_DEPTH = 1.0;
}
