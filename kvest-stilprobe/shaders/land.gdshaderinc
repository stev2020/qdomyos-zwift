// The path and the stream of scripts/land.gd for the shaders.
// u is the forward distance in scene coordinates (u = -z). The phases already contain the
// current world origin (set by main.gd), so the numbers stay small however far one rides.
global uniform vec3 path_phase;
global uniform vec2 stream_phase;
global uniform float noise_shift;

const vec3 PATH_A = vec3(38.0, 17.0, 6.0);
const vec3 PATH_L = vec3(173.0, 71.0, 29.0);
const float PATH_HALF = 1.3;

float path_x(float u) {
	return dot(PATH_A, sin(vec3(u) / PATH_L + path_phase));
}

float path_dx(float u) {
	return dot(PATH_A / PATH_L, cos(vec3(u) / PATH_L + path_phase));
}

float stream_x(float u) {
	return path_x(u) + 36.0 + 24.0 * sin(u / 430.0 + stream_phase.x) + 3.0 * sin(u / 41.0 + stream_phase.y);
}

float stream_dx(float u) {
	return path_dx(u) + 24.0 / 430.0 * cos(u / 430.0 + stream_phase.x) + 3.0 / 41.0 * cos(u / 41.0 + stream_phase.y);
}

// world position -> position on the noise textures (repeat every 256 m)
vec2 noise_pos(vec3 wp) {
	return vec2(wp.x, -wp.z + noise_shift);
}
