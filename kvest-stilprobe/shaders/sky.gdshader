// Summer sky: soft gradient, a glow around the sun and painted fair-weather clouds.
// The clouds do not move (no TIME), so the light of the sky is only computed once.
shader_type sky;

uniform vec3 zenith : source_color = vec3(0.30, 0.52, 0.88);
uniform vec3 horizon : source_color = vec3(0.80, 0.87, 0.93);
uniform vec3 ground : source_color = vec3(0.50, 0.57, 0.52);
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade : source_color = vec3(0.64, 0.70, 0.80);
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform float cloud_cover = 0.52;
uniform float sun_glow = 0.25;
// brightness of the whole sky (the light mood): the sky stays bright when the exposure of the picture goes down
uniform float sky_energy = 1.0;

void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 col = mix(horizon, zenith, pow(smoothstep(-0.02, 0.65, h), 0.65));
	float sd = max(dot(d, LIGHT0_DIRECTION), 0.0);
	col += LIGHT0_COLOR * (pow(sd, 5.0) * sun_glow + pow(sd, 48.0) * 0.35);
	if (h > 0.0) {
		vec2 cuv = d.xz / (h + 0.1) * 0.22;
		float n = texture(cloud_noise, cuv).r * 0.7 + texture(cloud_noise, cuv * 2.9 + 0.31).r * 0.3;
		float cover = smoothstep(cloud_cover, cloud_cover + 0.16, n) * smoothstep(0.0, 0.14, h);
		float n_sun = texture(cloud_noise, cuv + LIGHT0_DIRECTION.xz * 0.035).r * 0.7 + texture(cloud_noise, (cuv + LIGHT0_DIRECTION.xz * 0.035) * 2.9 + 0.31).r * 0.3;
		vec3 cc = mix(cloud_shade, cloud_lit, clamp(0.55 + (n - n_sun) * 4.0, 0.0, 1.0));
		cc += LIGHT0_COLOR * pow(sd, 6.0) * 0.35 * (1.0 - cover * 0.5);
		col = mix(col, cc, cover * 0.95);
	} else {
		col = mix(horizon, ground, smoothstep(0.0, -0.25, h));
	}
	if (!AT_CUBEMAP_PASS) {
		col += LIGHT0_COLOR * smoothstep(0.99935, 0.9996, sd) * 6.0;
	}
	COLOR = col * sky_energy;
}
