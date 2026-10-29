class_name Land
extends RefCounted
## The made-up land of the style test: one endless path that winds forward, a stream that runs beside the path
## at a changing distance, and four landscapes, each with its own relief, water, ground and plants:
## Laubland, Heide, Flusstal and Hochland. Everything is a pure function of the position, so any piece of land can be
## built at any time and always fits its neighbours.
##
## Until the map of Kvest exists, the landscapes take turns along the path, STRETCH metres each. The look changes
## over BLEND metres, the relief over RELIEF_BLEND metres, so the climb into the highland stays long and even.
## Land.mode can hold a single landscape instead (button "Landschaft", --land).
##
## The path itself changes every few hundred metres between a busy cart track, a quiet one with a strip of grass in the
## middle and a narrow footpath (path_style).
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
## Half the width of a cart track, of the mule track of the highland and of a footpath.
const PATH_HALF := 1.3
const MULE_HALF := 0.9
const FOOT_HALF := 0.45
## The noise lanes picks the kind of path: below FOOT_BELOW a footpath (about 12 % of the way), above QUIET_ABOVE a
## quiet track with a grass strip (about 45 %), in between a busy cart track.
const FOOT_BELOW := -0.39
const QUIET_ABOVE := 0.03
## The noise textures of the shaders repeat every NOISE_PERIOD metres.
const NOISE_PERIOD := 256.0

enum { LAUB, HEIDE, FLUSS, HOCH, KINDS }
const NAMES := ["Laubland", "Heide", "Flusstal", "Hochland"]
## The order on the endless ride: the heath lies beside the broadleaf land, the highland between two river valleys.
const ORDER := [LAUB, HEIDE, LAUB, FLUSS, HOCH, FLUSS]
const STRETCH := 4000.0
const BLEND := 600.0
const RELIEF_BLEND := 1800.0
## Width of the stream: 1 = the brook of the broadleaf land, 0 = no water (heath), then the river of the valley and the
## mountain brook of the highland. The same numbers are in shaders/terrain.gdshader.
const STREAM_WIDTH := [1.0, 0.0, 1.6, 0.6]

## Fields of row(u): path x, 1/length of the path tangent, path height, stream x, 1/length of the stream tangent,
## water level, then the share of each landscape in the look (W) and in the relief (RW), the stream width (SW), and the
## kind of path: half its width (PH), the grass strip in the middle (QUIET) and the cart ruts (RUTS), see path_style.
const W := 6
const RW := 10
const SW := 14
const PH := 15
const QUIET := 16
const RUTS := 17

## -1: the landscapes take turns along the path; LAUB .. HOCH: only this landscape.
static var mode := -1

static var big: FastNoiseLite
static var mid: FastNoiseLite
static var small: FastNoiseLite
static var forest: FastNoiseLite
static var meadow: FastNoiseLite
static var firs: FastNoiseLite
static var huge: FastNoiseLite      # the long climbs of the highland
static var humps: FastNoiseLite     # the short climbs in the river valley
static var patches: FastNoiseLite   # sand in the heath, scree in the highland
static var lanes: FastNoiseLite     # the kind of path along the way


static func init() -> void:
	big = _noise(11, 0.003, 3)
	mid = _noise(23, 0.014, 1)
	small = _noise(37, 0.07, 1)
	forest = _noise(51, 0.011, 2)
	meadow = _noise(73, 0.022, 2)
	firs = _noise(91, 0.006, 1)
	huge = _noise(101, 0.0004, 1)
	humps = _noise(113, 0.005, 1)
	patches = _noise(127, 0.028, 2)
	lanes = _noise(131, 0.002, 2)


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


## The share of each landscape at u; the shares add up to 1. blend: the length of a transition.
static func weights(u: float, blend: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(KINDS)
	w.fill(0.0)
	if mode >= 0:
		w[mode] = 1.0
		return w
	# u = 0 lies in the middle of the first stretch
	var s := u + STRETCH * 0.5
	var i := floori(s / STRETCH)
	var t := s - i * STRETCH
	var here: int = ORDER[posmod(i, ORDER.size())]
	var other := here
	var share := 0.0
	if t < STRETCH * 0.5:
		other = ORDER[posmod(i - 1, ORDER.size())]
		share = 1.0 - smoothstep(-blend * 0.5, blend * 0.5, t)
	else:
		other = ORDER[posmod(i + 1, ORDER.size())]
		share = smoothstep(-blend * 0.5, blend * 0.5, t - STRETCH)
	w[here] += 1.0 - share
	w[other] += share
	return w


## The landscape that has the largest share in the look at u.
static func kind_at(u: float) -> int:
	var w := weights(u, BLEND)
	var best := 0
	for k in KINDS:
		if w[k] > w[best]:
			best = k
	return best


static func stream_width(u: float) -> float:
	var w := weights(u, BLEND)
	var sw := 0.0
	for k in KINDS:
		sw += w[k] * STREAM_WIDTH[k]
	return sw


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


# ------------------------------------------------------------------ relief of each landscape
# nb, nm, ns: the big, middle and small noise at the point. The path takes only part of the smaller noise, so it climbs
# and falls more gently than the land beside it.

## Height of the open land, without path and stream.
static func _ground(k: int, x: float, u: float, px: float, sx: float, nb: float, nm: float, ns: float) -> float:
	match k:
		HEIDE:
			return nb * 2.2 + nm * 0.9 + ns * 0.25
		FLUSS:
			return nb * 2.5 + _hump(x, u) + nm * 1.2 + ns * 0.3 + _slopes(x, u, px, sx, nm)
		HOCH:
			return _lift(x, u) + nb * 4.5 + nm * 2.0 + ns * 0.45 + _hillside(x, u, px)
	return nb * 7.0 + nm * 2.2 + ns * 0.3


## Height of the path.
static func _path(k: int, px: float, u: float, nb: float, nm: float) -> float:
	match k:
		HEIDE:
			return nb * 2.2 + nm * 0.25
		FLUSS:
			return nb * 2.5 + _hump(px, u) + nm * 0.4
		HOCH:
			return _lift(px, u) + nb * 2.5 + nm * 0.3
	return nb * 7.0 + nm * 0.8


## The smooth land under the stream; the water lies a little below it.
static func _base(k: int, x: float, u: float, px: float, nb: float) -> float:
	match k:
		HEIDE:
			return nb * 2.2
		FLUSS:
			return nb * 2.5
		HOCH:
			return _lift(x, u) + nb * 2.5 + _hillside(x, u, px)
	return nb * 7.0


## River valley: short climbs where the path crosses a spur of the slope.
static func _hump(x: float, u: float) -> float:
	var n := maxf(0.0, humps.get_noise_2d(x, u) - 0.15) / 0.85
	return 6.0 * n * n


## River valley: the land rises beyond a flat valley floor that holds the path and the river.
static func _slopes(x: float, u: float, px: float, sx: float, nm: float) -> float:
	var d := valley_side(x, px, sx)
	if d <= 0.0:
		return 0.0
	var s := smoothstep(0.0, 170.0, d)
	return s * (52.0 + 16.0 * big.get_noise_2d(x * 1.7 + 9000.0, u * 1.7)) + nm * 3.0 * s


## River valley: how far x lies beyond the valley floor (negative on the floor).
static func valley_side(x: float, px: float, sx: float) -> float:
	return maxf(minf(px, sx) - 30.0 - x, x - maxf(px, sx) - 30.0)


## Highland: the land lies higher, with long climbs and descents over a kilometre and more.
static func _lift(x: float, u: float) -> float:
	return 25.0 + 45.0 * huge.get_noise_2d(x, u)


## Highland: the path runs along hillsides; the land rises on one side and falls on the other.
static func _hillside(x: float, u: float, px: float) -> float:
	var d := x - px
	return 0.12 * sin(u / 650.0 + 0.8) * d * smoothstep(6.0, 40.0, absf(d))


## Height of the path itself.
static func path_height(u: float) -> float:
	var px := path_x(u)
	var nb := big.get_noise_2d(px, u)
	var nm := mid.get_noise_2d(px, u)
	var w := weights(u, RELIEF_BLEND)
	var h := 0.0
	for k in KINDS:
		if w[k] > 0.0:
			h += w[k] * _path(k, px, u, nb, nm)
	return h


## Water level of the stream. It always stays half a metre below the path beside it, so the water never seems to stand
## higher than the way.
static func stream_level(u: float) -> float:
	var sx := stream_x(u)
	var px := path_x(u)
	var nb := big.get_noise_2d(sx, u)
	var w := weights(u, RELIEF_BLEND)
	var h := 0.0
	for k in KINDS:
		if w[k] > 0.0:
			h += w[k] * _base(k, sx, u, px, nb)
	return minf(h - 0.9, path_height(u) - 0.5)


## The path at u: [half its width, grass strip in the middle (0 .. 1), cart ruts (0 .. 1)]. The kind changes every few
## hundred metres: a busy cart track with a trodden middle full of hoof prints, a quiet one with a strip of grass in
## the middle, and now and then a narrow footpath. Grass strips grow only on earth and sand; the river valley has gravel
## roads, the highland mule tracks without cart ruts.
static func path_style(u: float) -> Vector3:
	var n := lanes.get_noise_1d(u)
	var foot := 1.0 - smoothstep(FOOT_BELOW - 0.06, FOOT_BELOW + 0.06, n)
	var calm := smoothstep(QUIET_ABOVE - 0.06, QUIET_ABOVE + 0.06, n)
	var w := weights(u, BLEND)
	var half := 0.0
	var quiet := 0.0
	var ruts := 0.0
	for k in KINDS:
		if w[k] <= 0.0:
			continue
		var track := PATH_HALF
		var grass := calm
		var carts := 1.0
		if k == FLUSS:
			grass = 0.0
		elif k == HOCH:
			track = MULE_HALF
			grass = 0.0
			carts = 0.0
		half += w[k] * lerpf(track, FOOT_HALF, foot)
		quiet += w[k] * grass * (1.0 - foot)
		ruts += w[k] * carts * (1.0 - foot)
	return Vector3(half, quiet, ruts)


## Everything that only depends on u, shared by a whole row of points (see the fields W .. RUTS above).
static func row(u: float) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(18)
	var pdx := path_dx(u)
	var sdx := stream_dx(u)
	r[0] = path_x(u)
	r[1] = 1.0 / sqrt(1.0 + pdx * pdx)
	r[2] = path_height(u)
	r[3] = stream_x(u)
	r[4] = 1.0 / sqrt(1.0 + sdx * sdx)
	r[5] = stream_level(u)
	var w := weights(u, BLEND)
	var wr := weights(u, RELIEF_BLEND)
	var sw := 0.0
	for k in KINDS:
		r[W + k] = w[k]
		r[RW + k] = wr[k]
		sw += w[k] * STREAM_WIDTH[k]
	r[SW] = sw
	var style := path_style(u)
	r[PH] = style.x
	r[QUIET] = style.y
	r[RUTS] = style.z
	return r


static func dist_path(x: float, r: PackedFloat64Array) -> float:
	return absf(x - r[0]) * r[1]


static func dist_stream(x: float, r: PackedFloat64Array) -> float:
	return absf(x - r[3]) * r[4]


## Bare ground, from 0 (grown over) to 1 (bare): sand in the heath, scree in the highland.
static func bare(x: float, u: float, r: PackedFloat64Array) -> float:
	var wh: float = r[W + HEIDE]
	var wk: float = r[W + HOCH]
	if wh <= 0.0 and wk <= 0.0:
		return 0.0
	var b := 0.0
	if wh > 0.0:
		b += wh * smoothstep(0.34, 0.55, patches.get_noise_2d(x, u))
	if wk > 0.0:
		# smaller patches of scree, in a part of the noise of their own
		b += wk * smoothstep(0.26, 0.48, patches.get_noise_2d(x * 1.8 + 7000.0, u * 1.8))
	return b


static func height(x: float, u: float, r: PackedFloat64Array) -> float:
	var nb := big.get_noise_2d(x, u)
	var nm := mid.get_noise_2d(x, u)
	var ns := small.get_noise_2d(x, u)
	var h := 0.0
	for k in KINDS:
		var wk: float = r[RW + k]
		if wk > 0.0:
			h += wk * _ground(k, x, u, r[0], r[3], nb, nm, ns)
	var dp := absf(x - r[0]) * r[1]
	var half: float = r[PH]
	if dp < half + 7.0:
		h = lerpf(r[2] - 0.05, h, smoothstep(half + 0.3, half + 7.0, dp))
	var sw: float = r[SW]
	if sw > 0.01:
		var ds := absf(x - r[3]) * r[4]
		if ds < 8.0 * sw:
			var water: float = r[5]
			var lift := water + 0.35 - h
			if lift > 0.0:
				h += lift * (1.0 - smoothstep(3.4 * sw, 8.0 * sw, ds))
			h = lerpf(water - 0.7, h, smoothstep(0.7 * sw, 3.4 * sw, ds))
	return h
