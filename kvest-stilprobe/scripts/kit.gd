class_name Kit
extends RefCounted
## Builds the meshes of the style test in code: the grass clump, broadleaf trees and bushes made of
## leaf-cluster cards, firs and rocks. Every tree is one surface (see shaders/nature.gdshader).

enum { ROUND, TALL, WIDE, BUSH, FIR_A, FIR_B, ROCK_A, ROCK_B, COUNT }

const BARK := Color(0.29, 0.23, 0.18, 0.0)


class Builder:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var tg := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()

	func vert(p: Vector3, nn: Vector3, tangent: Vector3, col: Color, t: Vector2, sway: float) -> int:
		v.append(p)
		n.append(nn)
		tg.append(tangent.x)
		tg.append(tangent.y)
		tg.append(tangent.z)
		tg.append(1.0)
		c.append(col)
		uv.append(t)
		uv2.append(Vector2(sway, 0.0))
		return v.size() - 1

	func tri(a: int, b: int, d: int) -> void:
		idx.append(a)
		idx.append(b)
		idx.append(d)

	func to_mesh(material: Material) -> ArrayMesh:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_TANGENT] = tg
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
		arr[Mesh.ARRAY_INDEX] = idx
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(0, material)
		return m

	## A tapered tube along the points (trunks and branches).
	func tube(points: Array, radii: Array, sides: int, col: Color, sway_from: float, sway_to: float) -> void:
		var rings := []
		var count := points.size()
		for i in count:
			var p: Vector3 = points[i]
			var ahead: Vector3 = points[mini(i + 1, count - 1)]
			var behind: Vector3 = points[maxi(i - 1, 0)]
			var dir := (ahead - behind).normalized()
			var side := dir.cross(Vector3.FORWARD)
			if side.length() < 0.1:
				side = dir.cross(Vector3.RIGHT)
			side = side.normalized()
			var side2 := dir.cross(side).normalized()
			var t := float(i) / float(count - 1)
			var shade := lerpf(0.78, 1.05, t)
			var ring := []
			for s in sides:
				var a := TAU * s / sides
				var off := side * cos(a) + side2 * sin(a)
				ring.append(vert(p + off * float(radii[i]), off, dir, Color(col.r * shade, col.g * shade, col.b * shade, 0.0),
					Vector2.ZERO, lerpf(sway_from, sway_to, t)))
			rings.append(ring)
		for i in count - 1:
			for s in sides:
				var a: int = rings[i][s]
				var b: int = rings[i][(s + 1) % sides]
				var d: int = rings[i + 1][s]
				var e: int = rings[i + 1][(s + 1) % sides]
				tri(a, d, b)
				tri(b, d, e)

	## One card of a leaf cluster. Corner normals point away from the crown centre, so the crown
	## is lit like a soft round volume; COLOR.r darkens the inside of the crown.
	func leaf_card(centre: Vector3, right: Vector3, up: Vector3, size: float, cell: int, flip: bool,
			crown_c: Vector3, crown_r: Vector3, spread: float) -> void:
		var hs := size * 0.5
		var corners := [centre - right * hs - up * hs, centre + right * hs - up * hs, centre - right * hs + up * hs, centre + right * hs + up * hs]
		var cu := float(cell % 2) * 0.5
		var cv := float(cell / 2) / 3.0
		var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(0, 0), Vector2(1, 0)]
		var ids := []
		for k in 4:
			var p: Vector3 = corners[k]
			var q := (p - crown_c) / crown_r
			var nn := q.normalized()
			var low := clampf((p.y - (crown_c.y - crown_r.y)) / (2.0 * crown_r.y), 0.0, 1.0)
			var shade := clampf(0.42 + 0.6 * q.length(), 0.4, 1.06) * (0.74 + 0.26 * low)
			var t: Vector2 = uvs[k]
			if flip:
				t.x = 1.0 - t.x
			var sway := clampf(Vector2(p.x, p.z).length() / maxf(spread, 0.5), 0.15, 1.0) * clampf(p.y / (crown_c.y + crown_r.y), 0.2, 1.0)
			ids.append(vert(p, nn, right, Color(shade, 1.0, 1.0, 1.0), Vector2(cu + t.x * 0.5, cv + t.y / 3.0), sway))
		tri(ids[0], ids[2], ids[1])
		tri(ids[1], ids[2], ids[3])

	## A fir branch card from p0 along dir; the painted branch runs from the trunk (u = 0) to the tip.
	func branch_card(p0: Vector3, dir: Vector3, side: Vector3, length: float, width: float, cell: int,
			axis_r: float, shade_mul: float, sway_mul: float) -> void:
		var cu := float(cell % 2) * 0.5
		var cv := float(cell / 2) / 3.0
		var v0 := cv + 0.2 / 3.0
		var v1 := cv + 0.82 / 3.0
		var p1 := p0 + dir * length
		var corners := [p0 - side * width * 0.25, p0 + side * width * 0.25, p1 - side * width * 0.5, p1 + side * width * 0.5]
		var uvs := [Vector2(cu, v0 + (v1 - v0) * 0.38), Vector2(cu, v0 + (v1 - v0) * 0.62), Vector2(cu + 0.5, v0), Vector2(cu + 0.5, v1)]
		var ids := []
		for k in 4:
			var p: Vector3 = corners[k]
			var out := Vector3(p.x, 0.0, p.z)
			var nn := (out / maxf(axis_r, 0.3) + Vector3.UP * 0.7).normalized()
			var along := 0.0 if k < 2 else 1.0
			var shade := lerpf(0.5, 1.0, along) * shade_mul
			ids.append(vert(p, nn, dir, Color(shade, 1.0, 1.0, 1.0), uvs[k], lerpf(0.1, 1.0, along) * sway_mul))
		tri(ids[0], ids[2], ids[1])
		tri(ids[1], ids[2], ids[3])

	## Three crossing cards: two upright ones at right angles and one lying almost flat.
	func cluster(centre: Vector3, size: float, rng: RandomNumberGenerator, crown_c: Vector3, crown_r: Vector3, cards: int) -> void:
		var a := rng.randf() * TAU
		var r1 := Vector3(cos(a), 0.0, sin(a))
		var r2 := Vector3(cos(a + PI * 0.5), 0.0, sin(a + PI * 0.5))
		var tilt := deg_to_rad(rng.randf_range(-12.0, 12.0))
		var u1 := Vector3.UP.rotated(r1, tilt)
		var u2 := Vector3.UP.rotated(r2, -tilt)
		var u3 := Vector3.UP.rotated(r1, deg_to_rad(rng.randf_range(62.0, 82.0)))
		var planes := [[r1, u1], [r2, u2], [r1.rotated(Vector3.UP, rng.randf_range(-0.6, 0.6)), u3]]
		for k in cards:
			leaf_card(centre, planes[k][0], planes[k][1], size * rng.randf_range(0.9, 1.1), rng.randi() % 4, rng.randf() < 0.5,
				crown_c, crown_r, crown_r.x)


## Grass clump: 6 crossing cards (12 triangles). The UV covers one atlas cell; the shader picks the cell.
static func grass_clump(material: Material) -> ArrayMesh:
	var b := Builder.new()
	# yaw (degrees), width, height, offset x, offset z, lean of the top edge
	var cards := [
		[0.0, 1.0, 0.5, 0.0, 0.0, 0.12], [60.0, 1.0, 0.5, 0.0, 0.0, -0.12], [120.0, 1.0, 0.5, 0.0, 0.0, 0.12],
		[30.0, 0.62, 0.42, 0.16, 0.08, -0.1], [150.0, 0.62, 0.44, -0.14, 0.12, 0.1], [90.0, 0.62, 0.4, 0.03, -0.17, 0.1]]
	for i in cards.size():
		var cd: Array = cards[i]
		var yaw := deg_to_rad(cd[0])
		var right := Vector3(cos(yaw), 0.0, sin(yaw))
		var normal := Vector3(-sin(yaw), 0.0, cos(yaw))
		var base := Vector3(cd[3], -0.04, cd[4])
		var w: float = cd[1]
		var h: float = cd[2]
		var lean: float = cd[5]
		var flip := i >= 3
		var u0 := 1.0 if flip else 0.0
		var u1 := 0.0 if flip else 1.0
		var bl := b.vert(base - right * w * 0.5, Vector3.UP, right, Color.WHITE, Vector2(u0, 1), 0.0)
		var br := b.vert(base + right * w * 0.5, Vector3.UP, right, Color.WHITE, Vector2(u1, 1), 0.0)
		var tl := b.vert(base - right * w * 0.5 + Vector3.UP * h + normal * lean, Vector3.UP, right, Color.WHITE, Vector2(u0, 0), 1.0)
		var tr := b.vert(base + right * w * 0.5 + Vector3.UP * h + normal * lean, Vector3.UP, right, Color.WHITE, Vector2(u1, 0), 1.0)
		b.tri(bl, tl, br)
		b.tri(br, tl, tr)
	return b.to_mesh(material)


## Broadleaf trees and bushes. low = the version for the distance (fewer, bigger cards).
static func broadleaf(kind: int, seed_value: int, low: bool, material: Material) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var b := Builder.new()
	var cy := 6.2
	var rx := 4.0
	var ry := 3.3
	var lobes := 7
	var per_lobe := 5
	var csize := 1.75
	match kind:
		TALL:
			cy = 7.6
			rx = 3.0
			ry = 4.3
		WIDE:
			cy = 6.0
			rx = 5.3
			ry = 2.5
			lobes = 8
		BUSH:
			cy = 0.85
			rx = 1.55
			ry = 1.0
			lobes = 3
			per_lobe = 5
			csize = 1.15
	var lean := Vector3(rng.randf_range(-0.5, 0.5), 0.0, rng.randf_range(-0.5, 0.5)) * (0.0 if kind == BUSH else 1.0)
	var crown_c := Vector3(lean.x, cy, lean.z)
	var crown_r := Vector3(rx, ry, rx)
	var trunk_top := Vector3(lean.x * 0.9, cy * 0.92, lean.z * 0.9)
	if kind != BUSH:
		var pts := [Vector3(0, -0.5, 0), Vector3(rng.randf_range(-0.1, 0.1), cy * 0.3, rng.randf_range(-0.1, 0.1)),
			Vector3(lean.x * 0.45, cy * 0.62, lean.z * 0.45), trunk_top]
		b.tube(pts, [0.36, 0.27, 0.2, 0.12], 5 if low else 8, BARK, 0.0, 0.25)
	var centres := []
	for i in lobes:
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.35, 1.0), rng.randf_range(-1, 1)).normalized()
		centres.append(crown_c + dir * crown_r * 0.6)
	centres.append(crown_c + Vector3(0, ry * 0.45, 0))
	for lc in centres:
		var lr := rng.randf_range(1.3, 1.9) * (rx / 4.0 if kind == BUSH else 1.0)
		if kind != BUSH and not low:
			var start := Vector3(0, cy * rng.randf_range(0.5, 0.85), 0).lerp(trunk_top, 0.5)
			var end: Vector3 = start.lerp(lc, 0.85)
			b.tube([start, start.lerp(end, 0.5) + Vector3(0, 0.3, 0), end], [0.11, 0.08, 0.05], 5, BARK, 0.2, 0.7)
		var count := 2 if low else per_lobe
		for k in count:
			var off := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.8, 1), rng.randf_range(-1, 1)).limit_length(1.0)
			var size := csize * (1.55 if low else 1.0) * rng.randf_range(0.85, 1.15) * (rx / 4.0 if kind == BUSH else 1.0) * 1.0
			b.cluster(lc + off * lr * 0.7, size, rng, crown_c, crown_r, 2 if low else 3)
	return b.to_mesh(material)


## Firs: whorls of drooping branches, each branch two crossing cards with the painted fir branch.
static func fir(seed_value: int, low: bool, material: Material) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var b := Builder.new()
	var h := rng.randf_range(10.0, 13.0)
	var r0 := rng.randf_range(2.6, 3.2)
	b.tube([Vector3(0, -0.5, 0), Vector3(0, h * 0.5, 0), Vector3(0, h * 0.97, 0)], [0.26, 0.17, 0.05], 5 if low else 7, Color(0.17, 0.12, 0.09, 0), 0.0, 0.3)
	var layers := 7 if low else 12
	for l in layers:
		var t := float(l) / float(layers - 1)
		var y := 1.3 + t * (h - 1.9)
		var r := pow(1.0 - t, 0.9) * r0 + 0.5
		var count := 4 if low else (7 if t < 0.5 else (6 if t < 0.8 else 5))
		var a0 := rng.randf() * TAU
		for k in count:
			var a := a0 + TAU * k / count + rng.randf_range(-0.25, 0.25)
			var out := Vector3(cos(a), 0.0, sin(a))
			var droop := deg_to_rad(rng.randf_range(18.0, 34.0) + 10.0 * (1.0 - t))
			var dir := (out * cos(droop) + Vector3.DOWN * sin(droop)).normalized()
			var side := out.cross(Vector3.UP).normalized()
			var p0 := Vector3(0, y, 0) + out * 0.08
			var length := r * rng.randf_range(0.9, 1.1) * (1.25 if low else 1.0)
			var width := length * 0.62
			var shade := lerpf(0.72, 1.0, t)
			var cell := 4 + rng.randi() % 2
			# two cards along the branch, tilted against each other like a shallow V
			for tilt in ([0.0] if low else [-0.55, 0.55]):
				b.branch_card(p0, dir, side.rotated(dir, tilt), length, width, cell, r, shade, 0.3 + 0.7 * t)
	# the tip
	var tip := Vector3(0, h * 0.97, 0)
	for k in (2 if low else 3):
		var a := TAU * k / 3.0
		var out := Vector3(cos(a), 0.0, sin(a))
		b.branch_card(tip + Vector3.DOWN * 0.9, (Vector3.UP * 0.9 + out * 0.3).normalized(), out.cross(Vector3.UP).normalized(), 1.4, 0.9, 4, 0.6, 1.0, 1.0)
	return b.to_mesh(material)


## Rounded rocks with moss on top.
static func rock(seed_value: int, material: Material) -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.9
	var verts := [Vector3(-1, 1.618, 0), Vector3(1, 1.618, 0), Vector3(-1, -1.618, 0), Vector3(1, -1.618, 0),
		Vector3(0, -1, 1.618), Vector3(0, 1, 1.618), Vector3(0, -1, -1.618), Vector3(0, 1, -1.618),
		Vector3(1.618, 0, -1), Vector3(1.618, 0, 1), Vector3(-1.618, 0, -1), Vector3(-1.618, 0, 1)]
	for i in verts.size():
		verts[i] = verts[i].normalized()
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for level in 2:
		var cache := {}
		var next := []
		for f in faces:
			var m := []
			for e in 3:
				var a: int = f[e]
				var c: int = f[(e + 1) % 3]
				var key := Vector2i(mini(a, c), maxi(a, c))
				if not cache.has(key):
					verts.append(((verts[a] + verts[c]) * 0.5).normalized())
					cache[key] = verts.size() - 1
				m.append(cache[key])
			next.append([f[0], m[0], m[2]])
			next.append([f[1], m[1], m[0]])
			next.append([f[2], m[2], m[1]])
			next.append([m[0], m[1], m[2]])
		faces = next
	var pos := []
	for p in verts:
		var r := 1.0 + noise.get_noise_3dv(p) * 0.28 + noise.get_noise_3dv(p * 3.1) * 0.08
		pos.append(Vector3(p.x * r, p.y * r * 0.62, p.z * r * 0.85))
	var normals := []
	normals.resize(pos.size())
	normals.fill(Vector3.ZERO)
	for f in faces:
		var fn: Vector3 = (pos[f[2]] - pos[f[0]]).cross(pos[f[1]] - pos[f[0]])
		for k in 3:
			normals[f[k]] += fn
	var b := Builder.new()
	for i in pos.size():
		var nn: Vector3 = normals[i].normalized()
		if nn.dot(pos[i]) < 0.0:
			nn = -nn
		var g := 0.5 + noise.get_noise_3dv(pos[i] * 2.0) * 0.12
		var col := Color(g, g * 0.99, g * 0.95, 0.0).lerp(Color(0.33, 0.42, 0.17, 0.0), smoothstep(0.45, 0.85, nn.y) * 0.85)
		col.a = 0.0
		b.vert(pos[i], nn, Vector3.RIGHT, col, Vector2.ZERO, 0.0)
	for f in faces:
		b.tri(f[0], f[1], f[2])
	return b.to_mesh(material)
