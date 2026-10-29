// Ground: painted patches of grass, bare sand and scree, the path and the bed of the stream, in the colours of the
// four landscapes. Path and stream are computed here from the same formulas as in land.gd, so their edges stay
// sharp even where the terrain mesh is coarse.
// COLOR: the share of each landscape (r Laubland, g Heide, b Flusstal, a Hochland).
// UV.x: bare ground (0 .. 1), UV.y: grass strip in the middle of the path (0 .. 1).
// UV2.x: half the width of the path, UV2.y: cart ruts (0 .. 1), see Land.path_style.
//
// The path has four layers: the painted surface (textures/path.png in two sizes), the cart ruts with hoof prints in the
// middle (textures/hoof.png), the fine relief of grains, pebbles and cracks, and the pebbles as models (World). Ruts,
// prints and relief exist only in the light: they tilt the normal, the ground itself stays flat.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

#include "res://shaders/land.gdshaderinc"

uniform sampler2D patch_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D path_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D hoof_tex : filter_linear_mipmap, repeat_enable;
// one colour per landscape: Laubland, Heide, Flusstal, Hochland
uniform vec3 grass_a[4] : source_color;
uniform vec3 grass_b[4] : source_color;
uniform vec3 grass_c[4] : source_color;
uniform vec3 under[4] : source_color;
uniform vec3 bare_color[4] : source_color;
uniform vec3 path_color[4] : source_color;
uniform vec3 path_rim[4] : source_color;
uniform vec3 bed_color[4] : source_color;
uniform vec3 stone_color[4] : source_color;
uniform float grass_fade = 52.0;

// width of the stream per landscape, as Land.STREAM_WIDTH
const vec4 STREAM_WIDTH = vec4(1.0, 0.0, 1.6, 0.6);
// per landscape: depth and half width of a cart rut in metres (only for the light; ruts in sand are wide and deep), how
// much darker the rut is, how much the painted pebbles stand out (0: in the colour of the ground, 1: in the colour of
// stone), and how strong the fine relief is
const vec4 RUT_DEPTH = vec4(0.045, 0.07, 0.035, 0.0);
const vec4 RUT_WIDTH = vec4(0.11, 0.18, 0.12, 0.1);
const vec4 RUT_TINT = vec4(0.8, 0.8, 0.86, 1.0);
const vec4 PEBBLES = vec4(0.45, 0.35, 1.0, 1.0);
const vec4 RELIEF = vec4(0.9, 0.55, 1.0, 1.2);
// how much of the bare path shows through the grass strip (the grass on sand is sparse)
const vec4 STRIP_SOIL = vec4(0.2, 0.45, 0.3, 0.3);
// half the distance between the wheels of a cart (1.4 m)
const float GAUGE = 0.7;
// the painted surface repeats every 1.7 m; a second, larger and blurred copy every 4.3 m breaks up the repeat. The hoof
// prints repeat every 4 m.
const float SURFACE = 1.7;
const float SURFACE2 = 4.3;
const float BLUR = 6.0;
const float HOOF_LEN = 4.0;
// how steep the slopes painted into the textures are in the light
const float SLOPE = 2.4;
const float HOOF_SLOPE = 2.4;

#define LAND(c) (c[0] * w.x + c[1] * w.y + c[2] * w.z + c[3] * w.w)

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 w = COLOR / max(dot(COLOR, vec4(1.0)), 0.001);
	float u = -wpos.z;
	vec2 np = noise_pos(wpos);
	float n1 = texture(patch_noise, np / 256.0).r;
	float n2 = texture(patch_noise, np / 64.0).r;
	float n3 = texture(patch_noise, np / 8.0).r;
	float n4 = texture(patch_noise, np / 2.0).r;

	vec3 col = mix(LAND(grass_a), LAND(grass_b), smoothstep(0.35, 0.65, n1));
	col = mix(col, LAND(grass_c), smoothstep(0.58, 0.82, n2) * 0.55);
	col *= 0.86 + 0.22 * n3 + 0.1 * (n4 - 0.5);
	// under the grass clumps the ground is in their shade
	float cam_d = distance(wpos, CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(grass_fade - 18.0, grass_fade + 6.0, cam_d);
	col = mix(col, LAND(under) * (0.85 + 0.3 * n3), near * 0.6);

	// the path: s across it (positive to the right), t along it. The texture coordinates and their derivatives are
	// taken here, outside the branches below, so the mip levels stay defined everywhere.
	float px = path_x(u);
	float pdx = path_dx(u);
	float inv = inversesqrt(1.0 + pdx * pdx);
	float s = (wpos.x - px) * inv;
	float t = u;
	vec2 pc = vec2(s, t);
	vec2 pc_dx = dFdx(pc);
	vec2 pc_dy = dFdy(pc);
	vec2 wc = vec2(wpos.x, u);
	vec2 wc_dx = dFdx(wc);
	vec2 wc_dy = dFdy(wc);
	// relief, ruts and prints tilt the light only near the rider; far away they would flicker
	float detail = 1.0 - smoothstep(40.0, 110.0, cam_d);
	vec2 slope_bare = vec2(0.0);
	vec2 slope_path = vec2(0.0);

	// bare ground with a frayed edge: sand in the heath, scree in the highland
	float bare = smoothstep(0.42, 0.6, UV.x + (n3 - 0.5) * 0.3 + (n4 - 0.5) * 0.2);
	if (bare > 0.0) {
		vec4 a = textureGrad(path_tex, wc / SURFACE, wc_dx / SURFACE, wc_dy / SURFACE);
		float b = textureGrad(path_tex, wc / SURFACE2 + 0.31, wc_dx * (BLUR / SURFACE2), wc_dy * (BLUR / SURFACE2)).r;
		float surf = a.r * 0.65 + b * 0.35;
		vec3 ground = LAND(bare_color) * (0.8 + 0.3 * n3 + 0.18 * (n4 - 0.5)) * (0.55 + 0.9 * surf);
		vec3 stone = mix(LAND(bare_color) * 0.85, LAND(stone_color), dot(w, PEBBLES)) * (0.5 + 0.6 * a.r);
		ground = mix(ground, stone, a.g);
		col = mix(col, ground, bare);
		slope_bare = (a.ba - 0.5) * 0.75 * SLOPE * dot(w, RELIEF) * bare;
	}

	float half_w = UV2.x;
	float dp = abs(s);
	float on_path = 0.0;
	if (dp < half_w + 0.6) {
		// narrow paths have a finer frayed edge
		float fray = clamp(half_w / 1.3, 0.35, 1.0);
		float edge = dp + ((n4 - 0.5) * 0.35 + (n3 - 0.5) * 0.45) * fray;
		on_path = 1.0 - smoothstep(half_w - 0.2 * fray, half_w + 0.12 * fray, edge);
		float rim = smoothstep(half_w - 0.55 * fray, half_w, edge);

		// layer 1: the painted surface with its pebbles
		vec4 a = textureGrad(path_tex, pc / SURFACE, pc_dx / SURFACE, pc_dy / SURFACE);
		float b = textureGrad(path_tex, pc / SURFACE2 + 0.31, pc_dx * (BLUR / SURFACE2), pc_dy * (BLUR / SURFACE2)).r;
		float surf = a.r * 0.65 + b * 0.35;
		vec3 dirt = LAND(path_color) * (0.9 + 0.18 * n4 + 0.08 * n3) * (0.6 + 0.8 * surf);
		vec3 stone = mix(LAND(path_color) * 0.85, LAND(stone_color), dot(w, PEBBLES)) * (0.5 + 0.6 * a.r);
		dirt = mix(dirt, stone, a.g);
		// layer 3: the fine relief of grains, pebbles and cracks
		vec2 g = (a.ba - 0.5) * 0.75 * SLOPE * dot(w, RELIEF);

		// layer 2: the cart ruts, two narrow grooves of iron-shod wooden wheels that wander a little
		float ruts = UV2.y;
		if (ruts > 0.01) {
			float rw = dot(w, RUT_WIDTH);
			float depth = dot(w, RUT_DEPTH) * ruts;
			float sr = s - (0.035 * sin(t * 0.21 + 0.6) + 0.02 * sin(t * 0.67 + 2.0));
			float xr = (abs(sr) - GAUGE) / rw;
			float ax = abs(xr);
			// a bowl in the rut and a low ridge of pushed-aside soil beside it
			float bowl_d = ax < 1.0 ? -4.0 * xr * (1.0 - xr * xr) : 0.0;
			float rq = (ax - 1.35) / 0.35;
			float ridge_d = exp(-rq * rq) * (-2.0 * rq / 0.35) * sign(xr);
			g.x += (-depth * bowl_d + 0.25 * depth * ridge_d) / rw * sign(sr) * (1.0 - smoothstep(60.0, 120.0, cam_d));
			float in_rut = (1.0 - smoothstep(0.4, 1.0, ax)) * ruts * (1.0 - smoothstep(120.0, 220.0, cam_d));
			dirt *= mix(1.0, dot(w, RUT_TINT), in_rut);
		}

		// hoof prints in the middle: many on busy tracks and mule tracks, few on quiet tracks and footpaths
		float quiet = UV.y;
		float narrow = clamp((0.9 - half_w) / 0.45, 0.0, 1.0);
		float hoofs = mix(mix(0.8, 0.25, narrow), mix(1.0, 0.15, quiet), ruts);
		vec2 h1c = vec2((s + 0.4) / 0.8, t / HOOF_LEN);
		vec2 h2c = vec2((0.4 - s) / 0.8, t / (HOOF_LEN * 1.37) + 0.37);
		vec4 h1 = textureGrad(hoof_tex, h1c, vec2(pc_dx.x / 0.8, pc_dx.y / HOOF_LEN), vec2(pc_dy.x / 0.8, pc_dy.y / HOOF_LEN));
		vec4 h2 = textureGrad(hoof_tex, h2c, vec2(-pc_dx.x / 0.8, pc_dx.y / (HOOF_LEN * 1.37)), vec2(-pc_dy.x / 0.8, pc_dy.y / (HOOF_LEN * 1.37)));
		float middle = 1.0 - smoothstep(0.32, 0.42, dp);
		dirt *= 1.0 - (max(h1.r, h2.r) * 0.32 + max(h1.g, h2.g) * 0.12) * hoofs * middle;
		// the second lookup is mirrored across the path, so its slope across changes sign
		g += (vec2(h1.b - 0.5, h1.a - 0.5) + vec2(0.5 - h2.b, h2.a - 0.5)) * HOOF_SLOPE * hoofs * middle;

		// the grass strip in the middle of quiet tracks
		float strip = (1.0 - smoothstep(0.2, 0.32, dp + (n4 - 0.5) * 0.12)) * quiet;
		dirt = mix(dirt, mix(LAND(under) * (0.85 + 0.3 * n3), dirt, dot(w, STRIP_SOIL)), strip);
		g *= 1.0 - strip;

		dirt = mix(dirt, LAND(path_rim), rim * 0.55);
		col = mix(col, dirt, on_path);
		slope_path = g * on_path;
	}

	// stream bed: sand and pebbles, gravel banks along the river; no stream in the heath
	float sw = dot(w, STREAM_WIDTH);
	if (sw > 0.01) {
		float sx = stream_x(u);
		float sdx = stream_dx(u);
		float ds = abs(wpos.x - sx) / sqrt(1.0 + sdx * sdx);
		float bed = 1.0 - smoothstep(2.6 * sw, 3.7 * sw, ds + (n4 - 0.5) * 0.7);
		vec3 pebbles = LAND(bed_color) * (0.75 + 0.5 * n4);
		col = mix(col, pebbles, bed);
	}

	// tilt the normal: on bare ground along x and u, on the path across and along it
	if (detail > 0.0 && (bare > 0.0 || on_path > 0.0)) {
		vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 across = vec3(inv, 0.0, pdx * inv);
		vec3 along = vec3(pdx * inv, 0.0, -inv);
		nw -= (vec3(1.0, 0.0, 0.0) * slope_bare.x + vec3(0.0, 0.0, -1.0) * slope_bare.y) * (1.0 - on_path) * detail;
		nw -= (across * slope_path.x + along * slope_path.y) * detail;
		NORMAL = normalize((VIEW_MATRIX * vec4(normalize(nw), 0.0)).xyz);
	}

	ALBEDO = col;
	ROUGHNESS = 0.96;
	SPECULAR = 0.2;
}
