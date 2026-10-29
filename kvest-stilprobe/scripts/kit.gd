class_name Kit
extends RefCounted
## Builds the meshes of the style test in code: the grass clump, broadleaf trees and bushes made of
## leaf-cluster cards, spruces and firs of branch cards, and rocks. Every tree is one surface
## (see shaders/nature.gdshader).

enum { BEECH, BIRCH, OAK, MAPLE, ROWAN, BUSH, SPRUCE, FIR, ROCK_A, ROCK_B, COUNT }

## Cells of textures/leaves.png (2 x 4): 0-1 oval leaves, 2-3 small leaves, 4-5 fir branches, 6-7 maple leaves.
const ATLAS_ROWS := 4.0

## Crown centre height, radii, sub-crowns, clusters per sub-crown, card size, leaf cells, bark, trunk radius, stems,
## ridges (depth of the furrows in the bark) and roots (size of the root buttresses at the foot).
const SPECIES := {
	BEECH: {"cy": 5.6, "rx": 4.0, "ry": 3.5, "lobes": 8, "per": 5, "size": 1.75, "cells": [0, 1], "bark": Color(0.25, 0.245, 0.215, 0.0), "trunk": 0.34, "stems": 1, "ridges": 0.0, "roots": 0.45},
	BIRCH: {"cy": 6.6, "rx": 2.3, "ry": 3.8, "lobes": 7, "per": 4, "size": 1.45, "cells": [2, 3], "bark": Color(0.8, 0.78, 0.71, 0.0), "trunk": 0.2, "stems": 1, "ridges": 0.0, "roots": 0.2},
	OAK: {"cy": 5.6, "rx": 5.0, "ry": 2.9, "lobes": 9, "per": 5, "size": 1.8, "cells": [0, 1], "bark": Color(0.11, 0.08, 0.045, 0.0), "trunk": 0.42, "stems": 1, "ridges": 0.22, "roots": 0.45},
	MAPLE: {"cy": 5.2, "rx": 3.8, "ry": 3.6, "lobes": 9, "per": 6, "size": 1.75, "cells": [6, 7], "bark": Color(0.15, 0.1, 0.05, 0.0), "trunk": 0.3, "stems": 1, "ridges": 0.14, "roots": 0.4},
	ROWAN: {"cy": 3.9, "rx": 2.4, "ry": 2.2, "lobes": 6, "per": 4, "size": 1.3, "cells": [2, 3], "bark": Color(0.19, 0.175, 0.14, 0.0), "trunk": 0.15, "stems": 3, "ridges": 0.0, "roots": 0.15},
	BUSH: {"cy": 0.85, "rx": 1.55, "ry": 1.0, "lobes": 3, "per": 5, "size": 1.15, "cells": [0, 1, 2, 3], "bark": Color(0.3, 0.25, 0.2, 0.0), "trunk": 0.0, "stems": 0, "ridges": 0.0, "roots": 0.0},
}

## Birch branches, the dark dashes in birch bark, and the moss at the foot of the trunks.
const BIRCH_BRANCH := Color(0.55, 0.52, 0.47, 0.0)
const BIRCH_MARK := Color(0.035, 0.032, 0.03, 0.0)
const MOSS := Color(0.075, 0.11, 0.03, 0.0)


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

	## A tapered trunk or branch along the points, carved in flat faces: every face between two rings has
	## its own normal and its own shade, so the bark catches the light face by face. The faces wind slowly
	## around the tube and its corners lie unevenly. ridges sets every other corner deeper (furrowed bark),
	## roots adds three root buttresses at the foot. marks: for each segment, the chance of a dark dash
	## (birch bark).
	func bark(points: Array, radii: Array, sides: int, col: Color, sway_from: float, sway_to: float,
			rng: RandomNumberGenerator, ridges := 0.0, roots := 0.0, marks: Array = []) -> void:
		var count := points.size()
		# how far the faces wind around the tube per metre
		var twist := rng.randf_range(0.06, 0.14) * (1.0 if rng.randf() < 0.5 else -1.0)
		var along := 0.0
		var lobes := rng.randf() * TAU
		# an uneven cross-section that stays the same all the way up, so the faces run on in long strips
		var shape := []
		for s in sides:
			shape.append(rng.randf_range(0.88, 1.08))
		var rings := []
		var dirs := []
		var side := Vector3.ZERO
		for i in count:
			var p: Vector3 = points[i]
			var ahead: Vector3 = points[mini(i + 1, count - 1)]
			var behind: Vector3 = points[maxi(i - 1, 0)]
			var dir := (ahead - behind).normalized()
			if i == 0:
				side = dir.cross(Vector3.FORWARD)
				if side.length() < 0.1:
					side = dir.cross(Vector3.RIGHT)
			# the frame travels along the tube, so the faces do not wind where it bends
			side = (side - dir * side.dot(dir)).normalized()
			var side2 := dir.cross(side)
			if i > 0:
				along += p.distance_to(points[i - 1])
			var foot := pow(1.0 - clampf(p.y / 0.9, 0.0, 1.0), 2.0)
			var ring := []
			for s in sides:
				var a0 := TAU * s / sides
				var a := a0 + twist * along
				var r: float = radii[i] * float(shape[s]) * rng.randf_range(0.98, 1.02)
				if s % 2 == 1:
					r *= 1.0 - ridges
				r *= 1.0 + roots * foot * maxf(0.0, cos(3.0 * a0 + lobes))
				ring.append(p + (side * cos(a) + side2 * sin(a)) * r)
			rings.append(ring)
			dirs.append(dir)
		# streaks running up the bark: every side of the tube a little lighter or darker
		var streaks := []
		for s in sides:
			streaks.append(rng.randf_range(0.8, 1.12))
		for i in count - 1:
			var sway_a := lerpf(sway_from, sway_to, float(i) / float(count - 1))
			var sway_b := lerpf(sway_from, sway_to, float(i + 1) / float(count - 1))
			var centre: Vector3 = ((points[i] as Vector3) + (points[i + 1] as Vector3)) * 0.5
			var chance: float = marks[i] if i < marks.size() else 0.0
			var dash := false
			for s in sides:
				var a: Vector3 = rings[i][s]
				var b: Vector3 = rings[i][(s + 1) % sides]
				var d: Vector3 = rings[i + 1][s]
				var e: Vector3 = rings[i + 1][(s + 1) % sides]
				var nn := (e - a).cross(b - d)
				if nn.dot((a + b + d + e) * 0.25 - centre) < 0.0:
					nn = -nn
				nn = nn.normalized()
				var y := (a.y + b.y + d.y + e.y) * 0.25
				var f: float = streaks[s] * rng.randf_range(0.9, 1.1) * lerpf(0.7, 1.0, smoothstep(-0.2, 0.9, y))
				var c := Color(col.r * f, col.g * f, col.b * f, 0.0)
				if roots > 0.0:
					# moss on the shady side of the foot
					c = c.lerp(MOSS, clampf(nn.z * 1.4, 0.0, 1.0) * (1.0 - smoothstep(0.1, 1.3, y)) * 0.6)
				# dashes are wider than high: a dark face often continues on the next side
				dash = rng.randf() < (maxf(chance, 0.55) if dash else chance)
				if dash:
					c = BIRCH_MARK
				var up: Vector3 = dirs[i]
				var ia := vert(a, nn, up, c, Vector2.ZERO, sway_a)
				var ib := vert(b, nn, up, c, Vector2.ZERO, sway_a)
				var id := vert(d, nn, up, c, Vector2.ZERO, sway_b)
				var ie := vert(e, nn, up, c, Vector2.ZERO, sway_b)
				tri(ia, id, ib)
				tri(ib, id, ie)

	## One card of a leaf cluster. Corner normals point away from the crown centre, so the crown
	## is lit like a soft round volume; COLOR.r darkens the inside of the crown.
	func leaf_card(centre: Vector3, right: Vector3, up: Vector3, size: float, cell: int, flip: bool,
			crown_c: Vector3, crown_r: Vector3, spread: float) -> void:
		var hs := size * 0.5
		var corners := [centre - right * hs - up * hs, centre + right * hs - up * hs, centre - right * hs + up * hs, centre + right * hs + up * hs]
		var cu := float(cell % 2) * 0.5
		var cv := float(cell / 2) / ATLAS_ROWS
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
			ids.append(vert(p, nn, right, Color(shade, 1.0, 1.0, 1.0), Vector2(cu + t.x * 0.5, cv + t.y / ATLAS_ROWS), sway))
		tri(ids[0], ids[2], ids[1])
		tri(ids[1], ids[2], ids[3])

	## A fir branch card from p0 along dir; the painted branch runs from the trunk (u = 0) to the tip.
	func branch_card(p0: Vector3, dir: Vector3, side: Vector3, length: float, width: float, cell: int,
			axis_r: float, shade_mul: float, sway_mul: float) -> void:
		var cu := float(cell % 2) * 0.5
		var cv := float(cell / 2) / ATLAS_ROWS
		var v0 := cv + 0.2 / ATLAS_ROWS
		var v1 := cv + 0.82 / ATLAS_ROWS
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
	func cluster(centre: Vector3, size: float, rng: RandomNumberGenerator, crown_c: Vector3, crown_r: Vector3, cards: int, cells: Array) -> void:
		var a := rng.randf() * TAU
		var r1 := Vector3(cos(a), 0.0, sin(a))
		var r2 := Vector3(cos(a + PI * 0.5), 0.0, sin(a + PI * 0.5))
		var tilt := deg_to_rad(rng.randf_range(-12.0, 12.0))
		var u1 := Vector3.UP.rotated(r1, tilt)
		var u2 := Vector3.UP.rotated(r2, -tilt)
		var u3 := Vector3.UP.rotated(r1, deg_to_rad(rng.randf_range(62.0, 82.0)))
		var planes := [[r1, u1], [r2, u2], [r1.rotated(Vector3.UP, rng.randf_range(-0.6, 0.6)), u3]]
		for k in cards:
			leaf_card(centre, planes[k][0], planes[k][1], size * rng.randf_range(0.9, 1.1), cells[rng.randi() % cells.size()], rng.randf() < 0.5,
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
	var sp: Dictionary = SPECIES[kind]
	var cy: float = sp["cy"]
	var rx: float = sp["rx"]
	var ry: float = sp["ry"]
	var bark: Color = sp["bark"]
	var trunk_r: float = sp["trunk"]
	var cells: Array = sp["cells"]
	var scale := rx / 4.0 if kind == BUSH else 1.0
	var lean := Vector3(rng.randf_range(-0.5, 0.5), 0.0, rng.randf_range(-0.5, 0.5)) * (0.0 if kind == BUSH else 1.0)
	if kind == BIRCH:
		lean *= 1.6
	var crown_c := Vector3(lean.x, cy, lean.z)
	var crown_r := Vector3(rx, ry, rx)
	var trunk_top := Vector3(lean.x * 0.9, cy * 0.92, lean.z * 0.9)
	var sides := 5 if low else (6 if kind == ROWAN else (10 if kind == OAK else 8))
	var stems: int = sp["stems"]
	# the bark draws from random numbers of its own
	var brng := RandomNumberGenerator.new()
	brng.seed = seed_value * 31 + 7
	for st in stems:
		var spread := Vector3.ZERO
		if stems > 1:
			var a := TAU * st / stems + rng.randf_range(-0.3, 0.3)
			spread = Vector3(cos(a), 0.0, sin(a)) * rx * 0.35
		if kind != BUSH:
			_trunk(b, kind, trunk_top + spread, trunk_r, sides, low, sp, brng)
	var centres := []
	for i in int(sp["lobes"]):
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 1.0), rng.randf_range(-1, 1)).normalized()
		centres.append(crown_c + dir * crown_r * 0.52)
	centres.append(crown_c + Vector3(0, ry * 0.45, 0))
	for lc in centres:
		var lr := rng.randf_range(1.3, 1.9) * scale * (0.75 if kind == ROWAN else 1.0)
		if kind != BUSH and not low:
			var start := Vector3(0, cy * rng.randf_range(0.5, 0.85), 0).lerp(trunk_top, 0.5)
			var end: Vector3 = start.lerp(lc, 0.85)
			var bc := BIRCH_BRANCH if kind == BIRCH else bark
			b.bark([start, start.lerp(end, 0.5) + Vector3(0, 0.3, 0), end], [trunk_r * 0.42, trunk_r * 0.28, trunk_r * 0.12], 5, bc, 0.2, 0.7, brng)
		var count := 2 if low else int(sp["per"])
		for k in count:
			var off := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.8, 1), rng.randf_range(-1, 1)).limit_length(1.0)
			var size: float = float(sp["size"]) * (1.55 if low else 1.0) * rng.randf_range(0.85, 1.15) * scale
			b.cluster(lc + off * lr * 0.7, size, rng, crown_c, crown_r, 2 if low else 3, cells)
	return b.to_mesh(material)


## The trunk of a broadleaf tree, from below the ground up into the crown: a wide foot with root
## buttresses, then even steps. Birches get thin bands between the steps for the dark dashes of their bark,
## and a dark foot.
static func _trunk(b: Builder, kind: int, top: Vector3, trunk_r: float, sides: int, low: bool, sp: Dictionary,
		rng: RandomNumberGenerator) -> void:
	var ys := [-0.5, 0.0]
	if low:
		ys.append_array([0.4, top.y * 0.5, top.y])
	elif kind == BIRCH:
		ys.append_array([0.12, 0.3])
		var y := 0.42
		while y < top.y - 0.6:
			ys.append_array([y, y + 0.07])
			y += 0.42
		ys.append(top.y)
	else:
		ys.append_array([0.12, 0.3, 0.6, 1.0])
		for k in 5:
			ys.append(lerpf(1.0, top.y, float(k + 1) / 5.0))
	var pts := []
	var radii := []
	var marks := []
	# the trunk bends in a gentle wave on its way up
	var wave := Vector3(rng.randf() * TAU, rng.randf_range(0.9, 1.5), rng.randf() * TAU)
	for i in ys.size():
		var y: float = ys[i]
		var t := (y + 0.5) / (top.y + 0.5)
		var p := Vector3(top.x * t, y, top.z * t)
		p += Vector3(sin(y * wave.y + wave.x), 0.0, sin(y * wave.y * 0.8 + wave.z)) * 0.08 * (1.0 - absf(t - 0.5) * 2.0)
		pts.append(p)
		# the foot widens in a soft curve into the ground
		var flare := 1.0 + 0.5 * pow(1.0 - clampf(y, 0.0, 1.0), 3.0)
		radii.append(lerpf(trunk_r * 1.2, trunk_r * 0.38, pow(t, 0.8)) * flare)
		if kind == BIRCH and i + 1 < ys.size():
			# dark foot, then dark dashes in the thin bands, more of them low down
			var thin: bool = float(ys[i + 1]) - y < 0.1
			marks.append(1.0 if y < 0.1 else (0.5 if y < 0.25 else (lerpf(0.7, 0.25, t) if thin else lerpf(0.12, 0.0, t))))
	b.bark(pts, radii, sides, sp["bark"], 0.0, 0.25, rng, sp["ridges"], sp["roots"], marks)


## Spruces (narrow, drooping) and firs (wider, flatter): whorls of branches, each branch two
## crossing cards with the painted fir branch.
static func conifer(kind: int, seed_value: int, low: bool, material: Material) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var b := Builder.new()
	var spruce := kind == SPRUCE
	var h := rng.randf_range(11.0, 14.0) if spruce else rng.randf_range(9.0, 12.0)
	var r0 := rng.randf_range(2.2, 2.6) if spruce else rng.randf_range(2.9, 3.4)
	# red-brown spruce bark, grey fir bark
	var brng := RandomNumberGenerator.new()
	brng.seed = seed_value * 31 + 7
	var bark := Color(0.17, 0.078, 0.04, 0.0) if spruce else Color(0.16, 0.135, 0.1, 0.0)
	b.bark([Vector3(0, -0.5, 0), Vector3(0, 0.0, 0), Vector3(0, 0.45, 0), Vector3(0, h * 0.5, 0), Vector3(0, h * 0.97, 0)],
		[0.4, 0.38, 0.29, 0.17, 0.05], 5 if low else 7, bark, 0.0, 0.3, brng, 0.12, 0.3)
	var layers := (7 if low else 13) if spruce else (6 if low else 11)
	for l in layers:
		var t := float(l) / float(layers - 1)
		var y := 1.3 + t * (h - 1.9)
		var r := pow(1.0 - t, 0.9) * r0 + 0.5
		var count := 4 if low else (7 if t < 0.5 else (6 if t < 0.8 else 5))
		var a0 := rng.randf() * TAU
		for k in count:
			var a := a0 + TAU * k / count + rng.randf_range(-0.25, 0.25)
			var out := Vector3(cos(a), 0.0, sin(a))
			var droop_deg := (rng.randf_range(26.0, 40.0) + 8.0 * (1.0 - t)) if spruce else (rng.randf_range(12.0, 24.0) + 6.0 * (1.0 - t))
			var droop := deg_to_rad(droop_deg)
			var dir := (out * cos(droop) + Vector3.DOWN * sin(droop)).normalized()
			var side := out.cross(Vector3.UP).normalized()
			var p0 := Vector3(0, y, 0) + out * 0.08
			var length := r * rng.randf_range(0.9, 1.1) * (1.25 if low else 1.0)
			var width := length * (0.58 if spruce else 0.66)
			var shade := lerpf(0.72, 1.0, t)
			var cell := 4 + rng.randi() % 2
			# two cards along the branch, tilted against each other like a shallow V
			for tilt in ([0.0] if low else [-0.55, 0.55]):
				b.branch_card(p0, dir, side.rotated(dir, tilt), length, width, cell, r, shade, 0.3 + 0.7 * t)
	var tip := Vector3(0, h * 0.97, 0)
	for k in (2 if low else 3):
		var a := TAU * k / 3.0
		var out := Vector3(cos(a), 0.0, sin(a))
		b.branch_card(tip + Vector3.DOWN * 0.7, (Vector3.UP * 0.9 + out * 0.3).normalized(), out.cross(Vector3.UP).normalized(), 1.0, 0.6, 4, 0.6, 0.85, 1.0)
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
