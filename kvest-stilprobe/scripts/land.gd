class_name Land
extends RefCounted
## The made-up land of the style test: one endless path that winds forward, rolling hills and a
## stream that runs beside the path at a changing distance. Everything is a pure function of the
## position, so any piece of land can be built at any time and always fits its neighbours.
##
## Coordinates: u is the distance forward along the main direction, x is sideways (right = +x).
## In the scene, z = -(u - origin_u); the world shifts its origin now and then (see World).
## The same path and stream formulas live in shaders/land.gdshaderinc for the shaders.

const TILE := 48.0
const PATH_A := [38.0, 17.0, 6.0]
const PATH_L := [173.0, 71.0, 29.0]
const PATH_P := [0.4, 1.3, 2.1]
const STREAM_BASE := 36.0
const STREAM_A := [24.0, 3.0]
const STREAM_L := [430.0, 41.0]
const STREAM_P := [2.0, 0.7]
const PATH_HALF := 1.3
## The noise textures of the shaders repeat every NOISE_PERIOD metres.
const NOISE_PERIOD := 256.0

static var big: FastNoiseLite
static var mid: FastNoiseLite
static var small: FastNoiseLite
static var forest: FastNoiseLite
static var meadow: FastNoiseLite
static var firs: FastNoiseLite


static func init() -> void:
	big = _noise(11, 0.003, 3)
	mid = _noise(23, 0.014, 1)
	small = _noise(37, 0.07, 1)
	forest = _noise(51, 0.011, 2)
	meadow = _noise(73, 0.022, 2)
	firs = _noise(91, 0.006, 1)


static func _noise(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = frequency
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	if octaves <= 1:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
	else:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
	return n


static func path_x(u: float) -> float:
	return PATH_A[0] * sin(u / PATH_L[0] + PATH_P[0]) + PATH_A[1] * sin(u / PATH_L[1] + PATH_P[1]) \
		+ PATH_A[2] * sin(u / PATH_L[2] + PATH_P[2])


static func path_dx(u: float) -> float:
	return PATH_A[0] / PATH_L[0] * cos(u / PATH_L[0] + PATH_P[0]) + PATH_A[1] / PATH_L[1] * cos(u / PATH_L[1] + PATH_P[1]) \
		+ PATH_A[2] / PATH_L[2] * cos(u / PATH_L[2] + PATH_P[2])


static func stream_x(u: float) -> float:
	return path_x(u) + STREAM_BASE + STREAM_A[0] * sin(u / STREAM_L[0] + STREAM_P[0]) + STREAM_A[1] * sin(u / STREAM_L[1] + STREAM_P[1])


static func stream_dx(u: float) -> float:
	return path_dx(u) + STREAM_A[0] / STREAM_L[0] * cos(u / STREAM_L[0] + STREAM_P[0]) \
		+ STREAM_A[1] / STREAM_L[1] * cos(u / STREAM_L[1] + STREAM_P[1])


## Height of the path itself: the large hills only, so it climbs and falls gently.
static func path_height(u: float) -> float:
	var px := path_x(u)
	return big.get_noise_2d(px, u) * 7.0 + mid.get_noise_2d(px, u) * 0.8


## Water level of the stream.
static func stream_level(u: float) -> float:
	var sx := stream_x(u)
	return big.get_noise_2d(sx, u) * 7.0 - 0.9


## Everything that only depends on u, shared by a whole row of points:
## [path x, 1/length of the path tangent, path height, stream x, 1/length of the stream tangent, water level]
static func row(u: float) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(6)
	var pdx := path_dx(u)
	var sdx := stream_dx(u)
	r[0] = path_x(u)
	r[1] = 1.0 / sqrt(1.0 + pdx * pdx)
	r[2] = path_height(u)
	r[3] = stream_x(u)
	r[4] = 1.0 / sqrt(1.0 + sdx * sdx)
	r[5] = stream_level(u)
	return r


static func dist_path(x: float, r: PackedFloat64Array) -> float:
	return absf(x - r[0]) * r[1]


static func dist_stream(x: float, r: PackedFloat64Array) -> float:
	return absf(x - r[3]) * r[4]


static func height(x: float, u: float, r: PackedFloat64Array) -> float:
	var h := big.get_noise_2d(x, u) * 7.0 + mid.get_noise_2d(x, u) * 2.2 + small.get_noise_2d(x, u) * 0.3
	var dp := absf(x - r[0]) * r[1]
	if dp < PATH_HALF + 7.0:
		h = lerpf(r[2] - 0.05, h, smoothstep(PATH_HALF + 0.3, PATH_HALF + 7.0, dp))
	var ds := absf(x - r[3]) * r[4]
	if ds < 8.0:
		var water: float = r[5]
		var lift := water + 0.35 - h
		if lift > 0.0:
			h += lift * (1.0 - smoothstep(3.4, 8.0, ds))
		h = lerpf(water - 0.7, h, smoothstep(0.7, 3.4, ds))
	return h
