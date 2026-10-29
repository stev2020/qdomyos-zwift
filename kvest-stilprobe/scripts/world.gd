class_name World
extends Node3D
## Streams the land around the rider: terrain tiles, grass, trees and the stream, each in the plants and colours of
## its landscape (see Land). The number crunching runs in a worker thread; the main thread only turns the finished
## arrays into meshes, a few per frame, so the ride stays smooth.

const T := Land.TILE
const BLOCK := 3                 # trees and rocks are grouped in blocks of 3 x 1 tiles
const LOD_CELLS := [32, 16, 8]   # terrain cells per tile side for the three levels of detail
const FLOATS := 16               # per instance: 12 for the transform, 4 custom

var origin_u := 0.0
var view_ahead := 528.0
var view_side := 264.0
var grass_density := 1.0
var grass_range := 120.0
var tree_lod := 170.0
var shadows := true

var mat_terrain: ShaderMaterial
var mat_grass: ShaderMaterial
var mat_nature: ShaderMaterial
var mat_water: ShaderMaterial
var grass_mesh: ArrayMesh
var protos: Array = []           # per kind: {"high": ArrayMesh, "low": ArrayMesh}

var tiles := {}                  # Vector2i(ix, iu) -> {"node", "lod", "want", "grass", "mmi"}
var blocks := {}                 # Vector2i(bx, iu) -> {"node"}
var rows := {}                   # iu -> {"node"}

var _thread := Thread.new()
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _jobs: Array = []
var _results: Array = []
var _quit := false
var _busy := 0
var _gen := 0                    # raised by reset(); results of older jobs are thrown away


func setup(materials: Dictionary) -> void:
	mat_terrain = materials["terrain"]
	mat_grass = materials["grass"]
	mat_nature = materials["nature"]
	mat_water = materials["water"]
	grass_mesh = Kit.grass_clump(mat_grass)
	for kind in Kit.COUNT:
		var p := {}
		match kind:
			Kit.BEECH, Kit.BIRCH, Kit.OAK, Kit.MAPLE, Kit.ROWAN, Kit.BUSH, Kit.WILLOW:
				p["high"] = Kit.broadleaf(kind, 100 + kind, false, mat_nature)
				p["low"] = Kit.broadleaf(kind, 100 + kind, true, mat_nature)
			Kit.SPRUCE, Kit.FIR:
				p["high"] = Kit.conifer(kind, 200 + kind, false, mat_nature)
				p["low"] = Kit.conifer(kind, 200 + kind, true, mat_nature)
			Kit.PINE:
				p["high"] = Kit.pine(400, false, mat_nature)
				p["low"] = Kit.pine(400, true, mat_nature)
			Kit.JUNIPER:
				p["high"] = Kit.juniper(410, false, mat_nature)
				p["low"] = Kit.juniper(410, true, mat_nature)
			Kit.MUGO:
				p["high"] = Kit.mugo(420, false, mat_nature)
				p["low"] = Kit.mugo(420, true, mat_nature)
			Kit.ROCK_C:
				p["high"] = Kit.rock(330, mat_nature, true)
				p["low"] = p["high"]
			_:
				# the first two rocks keep their old seeds (308, 309), so they look as before
				p["high"] = Kit.rock(308 + kind - Kit.ROCK_A, mat_nature)
				p["low"] = p["high"]
		protos.append(p)
	_thread.start(_worker)


## Throws all built land away, e.g. after another landscape was chosen. Jobs that are already running are ignored
## when they come back.
func reset() -> void:
	_mutex.lock()
	_busy -= _jobs.size()
	_jobs.clear()
	_mutex.unlock()
	_gen += 1
	for dict in [tiles, blocks, rows]:
		for key in dict.keys():
			_drop(dict, key)


func _exit_tree() -> void:
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()


func is_idle() -> bool:
	return _busy == 0


func set_quality(p: Dictionary) -> void:
	grass_density = p["density"]
	view_ahead = p["ahead"]
	view_side = p["side"]
	tree_lod = p["tree_lod"]
	shadows = p["shadows"]
	for key in tiles:
		var t: Dictionary = tiles[key]
		if t.has("mmi") and is_instance_valid(t["mmi"]):
			var mm: MultiMesh = t["mmi"].multimesh
			mm.visible_instance_count = int(mm.instance_count * grass_density)
	for key in blocks:
		var node: Node3D = blocks[key]["node"]
		if not is_instance_valid(node):
			continue
		for child in node.get_children():
			_set_lod(child)


func _set_lod(mmi: GeometryInstance3D) -> void:
	if mmi.has_meta("rock"):
		mmi.visibility_range_end = tree_lod
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	elif mmi.has_meta("low"):
		mmi.visibility_range_begin = tree_lod
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		mmi.visibility_range_end = tree_lod
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func shift_origin(d: float) -> void:
	origin_u += d
	for dict in [tiles, blocks, rows]:
		for key in dict:
			var node = dict[key].get("node")
			if node != null and is_instance_valid(node):
				node.position.z += d


## Keeps the land around the rider complete. max_apply: how many finished jobs to build this frame.
func update(cam_u: float, cam_x: float, max_apply: int) -> void:
	var ixc := floori(cam_x / T)
	var side := ceili(view_side / T)
	var iu_min := floori((cam_u - T) / T)
	var iu_max := floori((cam_u + view_ahead) / T)
	for key in tiles.keys():
		if key.y < iu_min or key.y > iu_max or absi(key.x - ixc) > side + 1:
			_drop(tiles, key)
	var bx_min := floori(float(ixc - side) / BLOCK)
	var bx_max := floori(float(ixc + side) / BLOCK)
	for key in blocks.keys():
		if key.y < iu_min or key.y > iu_max or key.x < bx_min - 1 or key.x > bx_max + 1:
			_drop(blocks, key)
	for iu in rows.keys():
		if iu < iu_min or iu > iu_max:
			_drop(rows, iu)

	for iu in range(iu_min, iu_max + 1):
		var du := (iu + 0.5) * T - cam_u
		if not rows.has(iu):
			rows[iu] = {"node": null}
			_request({"type": "water", "key": iu, "prio": absf(du) + 5.0})
		var corridor := _corridor(iu)
		for ix in range(ixc - side, ixc + side + 1):
			var key := Vector2i(ix, iu)
			var dx := (ix + 0.5) * T - cam_x
			var d := sqrt(dx * dx + du * du)
			if not tiles.has(key):
				tiles[key] = {"node": null, "lod": 99, "want": 99, "grass": false}
			var t: Dictionary = tiles[key]
			var lod := 0 if d < 115.0 else (1 if d < 275.0 else 2)
			if lod < t["want"]:
				t["want"] = lod
				_request({"type": "terrain", "key": key, "lod": lod, "prio": d})
			if not t["grass"] and d < grass_range and ix * T < corridor.y and (ix + 1) * T > corridor.x:
				t["grass"] = true
				_request({"type": "grass", "key": key, "prio": d - 20.0})
		for bx in range(bx_min, bx_max + 1):
			var bkey := Vector2i(bx, iu)
			if not blocks.has(bkey):
				blocks[bkey] = {"node": null}
				var bdx := (bx + 0.5) * BLOCK * T - cam_x
				_request({"type": "trees", "key": bkey, "prio": sqrt(bdx * bdx + du * du) + 10.0})
	_apply(max_apply)


## x range of the grass corridor along the path in this row of tiles.
func _corridor(iu: int) -> Vector2:
	var lo := INF
	var hi := -INF
	for k in 5:
		var px := Land.path_x((iu + k / 4.0) * T)
		lo = minf(lo, px)
		hi = maxf(hi, px)
	return Vector2(lo - 46.0, hi + 46.0)


## Blocks until all requested work is built (previews and recordings).
func wait_idle() -> void:
	while _busy > 0:
		_apply(1000)
		if _busy > 0:
			OS.delay_msec(2)


func _drop(dict: Dictionary, key) -> void:
	var node = dict[key].get("node")
	if node != null and is_instance_valid(node):
		node.queue_free()
	dict.erase(key)


func _request(job: Dictionary) -> void:
	job["gen"] = _gen
	_mutex.lock()
	_jobs.append(job)
	_mutex.unlock()
	_busy += 1
	_sem.post()


func _apply(max_apply: int) -> void:
	for i in max_apply:
		_mutex.lock()
		var res = _results.pop_front() if not _results.is_empty() else null
		_mutex.unlock()
		if res == null:
			return
		_busy -= 1
		if res["gen"] != _gen:
			continue
		match res["type"]:
			"terrain":
				_apply_terrain(res)
			"grass":
				_apply_grass(res)
			"trees":
				_apply_trees(res)
			"water":
				_apply_water(res)


func _node_for(dict: Dictionary, key, pos: Vector3) -> Node3D:
	var entry: Dictionary = dict[key]
	var node = entry.get("node")
	if node == null or not is_instance_valid(node):
		node = Node3D.new()
		node.position = pos
		add_child(node)
		entry["node"] = node
	return node


func _tile_pos(key: Vector2i) -> Vector3:
	return Vector3(key.x * T, 0.0, -(key.y * T - origin_u))


func _apply_terrain(res: Dictionary) -> void:
	var key: Vector2i = res["key"]
	if not tiles.has(key):
		return
	var t: Dictionary = tiles[key]
	if res["lod"] > t["lod"]:
		return
	t["lod"] = res["lod"]
	var node := _node_for(tiles, key, _tile_pos(key))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = res["v"]
	arr[Mesh.ARRAY_NORMAL] = res["n"]
	arr[Mesh.ARRAY_COLOR] = res["c"]
	arr[Mesh.ARRAY_TEX_UV] = res["uv"]
	arr[Mesh.ARRAY_INDEX] = res["i"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, mat_terrain)
	var mi: MeshInstance3D = t.get("terrain")
	if mi == null or not is_instance_valid(mi):
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
		t["terrain"] = mi
	mi.mesh = mesh


func _multimesh(mesh: Mesh, buf: PackedFloat32Array, aabb: AABB) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = buf.size() / FLOATS
	mm.buffer = buf
	mm.custom_aabb = aabb
	return mm


func _apply_grass(res: Dictionary) -> void:
	var key: Vector2i = res["key"]
	if not tiles.has(key) or res["buf"].is_empty():
		return
	var node := _node_for(tiles, key, _tile_pos(key))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _multimesh(grass_mesh, res["buf"], AABB(Vector3(-1, res["hmin"] - 1.0, -T - 1), Vector3(T + 2, res["hmax"] - res["hmin"] + 3.0, T + 2)))
	mmi.multimesh.visible_instance_count = int(mmi.multimesh.instance_count * grass_density)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(mmi)
	tiles[key]["mmi"] = mmi


func _apply_trees(res: Dictionary) -> void:
	var key: Vector2i = res["key"]
	if not blocks.has(key):
		return
	var node := _node_for(blocks, key, Vector3(key.x * BLOCK * T, 0.0, -(key.y * T - origin_u)))
	var aabb := AABB(Vector3(-8, res["hmin"] - 2.0, -T - 8), Vector3(BLOCK * T + 16, res["hmax"] - res["hmin"] + 22.0, T + 16))
	for kind in Kit.COUNT:
		var buf: PackedFloat32Array = res["bufs"][kind]
		if buf.is_empty():
			continue
		var high := MultiMeshInstance3D.new()
		high.multimesh = _multimesh(protos[kind]["high"], buf, aabb)
		high.visibility_range_end_margin = 8.0
		if kind >= Kit.ROCK_A:
			high.set_meta("rock", true)
		node.add_child(high)
		_set_lod(high)
		if kind >= Kit.ROCK_A:
			continue
		var low := MultiMeshInstance3D.new()
		low.set_meta("low", true)
		low.multimesh = _multimesh(protos[kind]["low"], buf, aabb)
		low.visibility_range_begin_margin = 8.0
		node.add_child(low)
		_set_lod(low)


func _apply_water(res: Dictionary) -> void:
	var iu: int = res["key"]
	if not rows.has(iu) or res["v"].is_empty():
		return
	var node := _node_for(rows, iu, Vector3(0.0, 0.0, -(iu * T - origin_u)))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = res["v"]
	arr[Mesh.ARRAY_NORMAL] = res["n"]
	arr[Mesh.ARRAY_TANGENT] = res["tg"]
	arr[Mesh.ARRAY_COLOR] = res["c"]
	arr[Mesh.ARRAY_TEX_UV] = res["uv"]
	arr[Mesh.ARRAY_INDEX] = res["i"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, mat_water)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(mi)


# ------------------------------------------------------------------ worker thread
func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		var job = null
		if not _jobs.is_empty():
			var best := 0
			for i in _jobs.size():
				if _jobs[i]["prio"] < _jobs[best]["prio"]:
					best = i
			job = _jobs[best]
			_jobs.remove_at(best)
		_mutex.unlock()
		if job == null:
			continue
		var res: Dictionary
		match job["type"]:
			"terrain":
				res = _job_terrain(job["key"], job["lod"])
			"grass":
				res = _job_grass(job["key"])
			"trees":
				res = _job_trees(job["key"])
			_:
				res = _job_water(job["key"])
		res["gen"] = job["gen"]
		_mutex.lock()
		_results.append(res)
		_mutex.unlock()


static func _job_terrain(key: Vector2i, lod: int) -> Dictionary:
	var n: int = LOD_CELLS[lod]
	var step := T / n
	var x0 := key.x * T
	var u0 := key.y * T
	var w := n + 3
	var hs := PackedFloat32Array()
	hs.resize(w * w)
	var rws := []
	for j in w:
		var u := u0 + (j - 1) * step
		var r := Land.row(u)
		rws.append(r)
		for i in w:
			hs[j * w + i] = Land.height(x0 + (i - 1) * step, u, r)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	# colour: the share of each landscape (r Laubland, g Heide, b Flusstal, a Hochland); uv.x: bare ground
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	for j in n + 1:
		var r: PackedFloat64Array = rws[j + 1]
		var wc := Color(r[Land.W], r[Land.W + 1], r[Land.W + 2], r[Land.W + 3])
		for i in n + 1:
			var c := (j + 1) * w + (i + 1)
			verts.append(Vector3(i * step, hs[c], -j * step))
			norms.append(Vector3(hs[c - 1] - hs[c + 1], 2.0 * step, hs[c + w] - hs[c - w]).normalized())
			cols.append(wc)
			uvs.append(Vector2(Land.bare(x0 + i * step, u0 + j * step, r), 0.0))
	var idx := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			idx.append_array([a, a + n + 1, a + 1, a + 1, a + n + 1, a + n + 2])
	# skirts hide the cracks between tiles of different detail
	var edges := []
	for i in n + 1:
		edges.append(i)
	var top := []
	for i in n + 1:
		top.append(n * (n + 1) + i)
	var left := []
	var right := []
	for j in n + 1:
		left.append(j * (n + 1))
		right.append(j * (n + 1) + n)
	for edge in [edges, top, left, right]:
		var first := verts.size()
		for vi in edge:
			verts.append(verts[vi] - Vector3(0, 3.0, 0))
			norms.append(norms[vi])
			cols.append(cols[vi])
			uvs.append(uvs[vi])
		for k in edge.size() - 1:
			idx.append_array([edge[k], first + k, edge[k + 1], edge[k + 1], first + k, first + k + 1])
	return {"type": "terrain", "key": key, "lod": lod, "v": verts, "n": norms, "c": cols, "uv": uvs, "i": idx}


static func _grid_height(hs: PackedFloat32Array, w: int, fx: float, fu: float) -> float:
	var i := clampi(floori(fx), 0, w - 2)
	var j := clampi(floori(fu), 0, w - 2)
	var a := clampf(fx - i, 0.0, 1.0)
	var b := clampf(fu - j, 0.0, 1.0)
	var h00 := hs[j * w + i]
	var h10 := hs[j * w + i + 1]
	var h01 := hs[(j + 1) * w + i]
	var h11 := hs[(j + 1) * w + i + 1]
	if a + b <= 1.0:
		return h00 + (h10 - h00) * a + (h01 - h00) * b
	return h11 + (h01 - h11) * (1.0 - a) + (h10 - h11) * (1.0 - b)


static func _put(buf: PackedFloat32Array, basis: Basis, o: Vector3, custom: Color) -> void:
	buf.append_array([basis.x.x, basis.y.x, basis.z.x, o.x, basis.x.y, basis.y.y, basis.z.y, o.y,
		basis.x.z, basis.y.z, basis.z.z, o.z, custom.r, custom.g, custom.b, custom.a])


static func _job_grass(key: Vector2i) -> Dictionary:
	var x0 := key.x * T
	var u0 := key.y * T
	var n: int = LOD_CELLS[0]
	var step := T / n
	var w := n + 1
	var hs := PackedFloat32Array()
	hs.resize(w * w)
	for j in w:
		var u := u0 + j * step
		var r := Land.row(u)
		for i in w:
			hs[j * w + i] = Land.height(x0 + i * step, u, r)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(key.x, key.y, 3))
	var spacing := 0.6
	var m := int(T / spacing)
	var buf := PackedFloat32Array()
	var hmin := INF
	var hmax := -INF
	for gj in m:
		var u := u0 + (gj + 0.5) * spacing
		var r := Land.row(u)
		for gi in m:
			var x := x0 + (gi + rng.randf()) * spacing
			var uu := u + (rng.randf() - 0.5) * spacing
			var dp := Land.dist_path(x, r)
			if dp < Land.PATH_HALF - 0.2 or dp > 46.0:
				continue
			var sw: float = r[Land.SW]
			var ds := Land.dist_stream(x, r)
			if sw > 0.01 and ds < 2.45 * sw:
				continue
			# sand and scree stay bare
			if Land.bare(x, uu, r) > 0.42 + 0.16 * rng.randf():
				continue
			var k := _pick(r, Land.W, rng.randf())
			var mval := Land.meadow.get_noise_2d(x, uu)
			var variant := 0
			var hscale := rng.randf_range(0.8, 1.3)
			var dry := rng.randf() * 0.35
			var bright := rng.randf_range(0.88, 1.12)
			if sw > 0.01 and ds < 4.3 * sw:
				# reeds along the water
				variant = 5
				hscale *= 1.3
				dry = 0.0
			elif k == Land.HEIDE:
				# heather in wide carpets, between them short, dry grass and tussocks
				if mval > -0.3 and rng.randf() < 0.75:
					variant = 6
					hscale = rng.randf_range(0.8, 1.15)
					dry = 0.0
				elif rng.randf() < 0.45:
					variant = 7
					hscale = rng.randf_range(0.6, 0.95)
					dry = 0.45 + rng.randf() * 0.35
					bright *= 0.82
				else:
					variant = 2 if rng.randf() < 0.6 else 1
					hscale *= 0.75
					dry = 0.55 + rng.randf() * 0.35
					bright *= 0.8
			elif k == Land.HOCH:
				# thin, short and tough: tussocks, short grass, a few flowers
				if rng.randf() < 0.3:
					continue
				var pick := rng.randf()
				hscale = rng.randf_range(0.6, 0.95)
				if pick < 0.42:
					variant = 7
					dry = 0.4 + rng.randf() * 0.3
				elif pick < 0.82:
					variant = 2
					dry = 0.4 + rng.randf() * 0.3
				elif pick < 0.9:
					variant = 3
				else:
					variant = 1
					dry = 0.5
				bright *= 0.76
			else:
				# Laubland and Flusstal: the meadows; a few thinner patches, so the meadow is not a carpet
				if rng.randf() > 0.62 + 0.38 * smoothstep(-0.6, -0.1, mval):
					continue
				if dp < Land.PATH_HALF + 0.5:
					variant = 2
				elif mval > 0.3 and rng.randf() < 0.5:
					variant = 3
				elif k == Land.LAUB and mval < -0.35 and rng.randf() < 0.55:
					variant = 4
				elif rng.randf() < 0.28:
					variant = 1
					dry += 0.25
				elif rng.randf() < 0.3:
					variant = 2
				if k == Land.FLUSS:
					dry *= 0.6
			hscale *= lerpf(0.5, 1.0, smoothstep(Land.PATH_HALF - 0.2, Land.PATH_HALF + 2.0, dp))
			var h := _grid_height(hs, w, (x - x0) / step, (uu - u0) / step)
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)
			var ws := rng.randf_range(0.85, 1.25)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(ws, hscale, ws))
			_put(buf, basis, Vector3(x - x0, h - 0.02, -(uu - u0)), Color(variant, bright, rng.randf(), dry))
	# shuffle, so that drawing only the first part of the list thins the meadow out evenly
	var count := buf.size() / FLOATS
	var out := PackedFloat32Array()
	out.resize(buf.size())
	var order := range(count)
	order.shuffle()
	for k in count:
		var src: int = order[k] * FLOATS
		var dst := k * FLOATS
		for f in FLOATS:
			out[dst + f] = buf[src + f]
	return {"type": "grass", "key": key, "buf": out, "hmin": hmin if count > 0 else 0.0, "hmax": hmax if count > 0 else 0.0}


## Summer greens and the share of trees that already turn (per species).
const LEAF_TINTS := {
	Kit.BEECH: [[Color(0.50, 0.68, 0.17), Color(0.44, 0.62, 0.15), Color(0.56, 0.72, 0.19)], [Color(0.95, 0.70, 0.20)], 0.08],
	Kit.BIRCH: [[Color(0.62, 0.78, 0.22), Color(0.56, 0.74, 0.20)], [Color(1.0, 0.84, 0.28)], 0.15],
	Kit.OAK: [[Color(0.40, 0.58, 0.15), Color(0.34, 0.52, 0.13)], [Color(0.85, 0.62, 0.22)], 0.05],
	Kit.MAPLE: [[Color(0.40, 0.62, 0.15), Color(0.34, 0.55, 0.13)], [Color(1.0, 0.52, 0.12), Color(0.95, 0.40, 0.10)], 0.15],
	Kit.ROWAN: [[Color(0.48, 0.64, 0.18)], [Color(0.95, 0.32, 0.10), Color(1.0, 0.55, 0.15)], 0.35],
	Kit.BUSH: [[Color(0.46, 0.64, 0.16), Color(0.38, 0.56, 0.14), Color(0.55, 0.70, 0.18)], [Color(0.9, 0.55, 0.18)], 0.05],
	Kit.WILLOW: [[Color(0.44, 0.56, 0.30), Color(0.40, 0.52, 0.28)], [Color(0.92, 0.82, 0.32)], 0.08],
}
## Needles: Scots pine blue-green, juniper bluish and dark, mountain pine dark green.
const NEEDLE_TINTS := {
	Kit.PINE: Color(0.2, 0.34, 0.17),
	Kit.JUNIPER: Color(0.15, 0.27, 0.19),
	Kit.MUGO: Color(0.15, 0.29, 0.12),
}
## The trees of the broadleaf woods.
const BROADLEAF_WEIGHTS := [[Kit.BEECH, 0.45], [Kit.OAK, 0.3], [Kit.MAPLE, 0.25]]


static func _pick_broadleaf(rng: RandomNumberGenerator) -> int:
	var r := rng.randf()
	for w in BROADLEAF_WEIGHTS:
		r -= w[1]
		if r <= 0.0:
			return w[0]
	return Kit.BEECH


## Picks a landscape by its share in r (the shares start at the field first): where two landscapes meet, their plants
## mingle.
static func _pick(r: PackedFloat64Array, first: int, x: float) -> int:
	var last := 0
	for k in Land.KINDS:
		var w: float = r[first + k]
		if w <= 0.0:
			continue
		last = k
		x -= w
		if x <= 0.0:
			return k
	return last


## Spruces and firs of the river valley, each in patches of their own, and a few rowans among them.
static func _valley_conifer(x: float, u: float, rng: RandomNumberGenerator) -> int:
	if rng.randf() < 0.08:
		return Kit.ROWAN
	return Kit.FIR if Land.firs.get_noise_2d(x, u) > 0.1 and rng.randf() < 0.8 else Kit.SPRUCE


static func _tint(kind: int, rng: RandomNumberGenerator) -> Color:
	var c := Color(1, 1, 1)
	if LEAF_TINTS.has(kind):
		var t: Array = LEAF_TINTS[kind]
		var pool: Array = t[1] if rng.randf() < t[2] else t[0]
		c = pool[rng.randi() % pool.size()] * rng.randf_range(0.92, 1.08)
	elif NEEDLE_TINTS.has(kind):
		c = NEEDLE_TINTS[kind] * rng.randf_range(0.9, 1.08)
	elif kind == Kit.SPRUCE:
		c = Color(0.86, 0.9, 0.84) * rng.randf_range(0.9, 1.08)
	elif kind == Kit.FIR:
		c = Color(1.0, 1.0, 0.94) * rng.randf_range(0.9, 1.08)
	c.a = rng.randf()
	return c


static func _job_trees(key: Vector2i) -> Dictionary:
	var x0 := key.x * BLOCK * T
	var u0 := key.y * T
	var bw := BLOCK * T
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(key.x, key.y, 5))
	var bufs := []
	for k in Kit.COUNT:
		bufs.append(PackedFloat32Array())
	var hmin := INF
	var hmax := -INF
	var spacing := 6.5
	for gj in int(T / spacing):
		for gi in int(bw / spacing):
			var x := x0 + (gi + rng.randf()) * spacing
			var u := u0 + (gj + rng.randf()) * spacing
			var r := Land.row(u)
			var dp := Land.dist_path(x, r)
			var ds := Land.dist_stream(x, r)
			var sw: float = r[Land.SW]
			if dp < 3.2 or (sw > 0.01 and ds < 4.6 * sw):
				continue
			var f := Land.forest.get_noise_2d(x, u)
			var kind := -1
			var scale := rng.randf_range(0.82, 1.18)
			match _pick(r, Land.W, rng.randf()):
				Land.HEIDE:
					# open heath: groves of pines and birches, junipers standing alone
					if dp > 5.5 and rng.randf() < smoothstep(0.15, 0.55, f) * 0.55 + 0.006:
						kind = Kit.PINE if rng.randf() < 0.6 else Kit.BIRCH
					elif rng.randf() < 0.035 + 0.05 * smoothstep(-0.3, 0.3, f):
						kind = Kit.JUNIPER
						scale = rng.randf_range(0.6, 1.25)
				Land.FLUSS:
					# willows along the river, spruces and firs on the slopes, rowans and a few conifers on the floor
					var side := Land.valley_side(x, r[0], r[3])
					if sw > 0.01 and ds < 14.0 and dp > 5.0 and rng.randf() < 0.3:
						kind = Kit.WILLOW
						scale = rng.randf_range(0.75, 1.15)
					elif side > 0.0 and rng.randf() < smoothstep(0.0, 40.0, side) * 0.48 + 0.05:
						kind = _valley_conifer(x, u, rng)
					elif dp > 5.5 and rng.randf() < smoothstep(0.2, 0.55, f) * 0.45 + 0.012:
						kind = Kit.ROWAN if rng.randf() < 0.35 else _valley_conifer(x, u, rng)
				Land.HOCH:
					# mountain pines in wide patches and a few small rowans; nothing grows on the scree
					if Land.bare(x, u, r) > 0.5:
						continue
					if dp > 4.5 and rng.randf() < smoothstep(-0.2, 0.3, f) * 0.5:
						kind = Kit.MUGO
						scale = rng.randf_range(0.75, 1.3)
					elif dp > 4.0 and rng.randf() < 0.03:
						kind = Kit.ROWAN
						scale = rng.randf_range(0.5, 0.75)
				_:
					# broadleaf woods and meadows: beech, oak and maple, big single trees by the path, bushes
					if dp > 5.5 and rng.randf() < smoothstep(0.06, 0.42, f) * 0.85 + 0.02:
						kind = _pick_broadleaf(rng)
					elif dp > 6.0 and dp < 11.0 and rng.randf() < 0.035:
						kind = [Kit.BEECH, Kit.OAK, Kit.MAPLE][rng.randi() % 3]
						scale *= 1.4
					elif (dp < 12.0 or f > -0.08) and rng.randf() < 0.16:
						kind = Kit.BUSH
			if kind < 0:
				continue
			var h := Land.height(x, u, r)
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)
			var tint := _tint(kind, rng)
			var sx := scale * rng.randf_range(0.9, 1.1)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sx, scale, sx))
			_put(bufs[kind], basis, Vector3(x - x0, h - 0.1, -(u - u0)), tint)
	# rocks: a few in the meadows, more along the water, boulders in the heath, scree and crags in the highland
	var rs := 5.0
	for gj in int(T / rs):
		for gi in int(bw / rs):
			var x := x0 + (gi + rng.randf()) * rs
			var u := u0 + (gj + rng.randf()) * rs
			var r := Land.row(u)
			var dp := Land.dist_path(x, r)
			var ds := Land.dist_stream(x, r)
			var sw: float = r[Land.SW]
			var p := 0.012
			var size := rng.randf_range(0.5, 1.5)
			var kind := Kit.ROCK_A + rng.randi() % 2
			match _pick(r, Land.W, rng.randf()):
				Land.HEIDE:
					p = 0.004
					size = rng.randf_range(1.0, 2.4)
					kind = Kit.ROCK_C
				Land.FLUSS:
					if sw > 0.01 and ds < 6.5 * sw:
						p = 0.42
						size = rng.randf_range(0.3, 1.1)
						kind = Kit.ROCK_A + rng.randi() % 3
					elif Land.valley_side(x, r[0], r[3]) > 0.0:
						p = 0.03
						size = rng.randf_range(0.8, 2.2)
						kind = Kit.ROCK_C
					else:
						p = 0.01
				Land.HOCH:
					kind = Kit.ROCK_C
					var b := Land.bare(x, u, r)
					if b > 0.5:
						p = 0.45
						size = rng.randf_range(0.3, 1.0)
					elif b > 0.05:
						# a rim of bigger rocks around the scree
						p = 0.3
						size = rng.randf_range(0.6, 1.8)
					else:
						p = 0.06
						size = rng.randf_range(0.6, 2.0) * (2.2 if rng.randf() < 0.1 else 1.0)
				_:
					if sw > 0.01 and ds < 6.0 * sw:
						p = 0.35
						size = rng.randf_range(0.35, 1.0)
			# big rocks keep off the path
			if dp < maxf(2.2, Land.PATH_HALF + size * 1.2) or rng.randf() > p:
				continue
			var h := Land.height(x, u, r)
			var basis := Basis(Vector3(rng.randf_range(-0.2, 0.2), 1, rng.randf_range(-0.2, 0.2)).normalized(), rng.randf() * TAU).scaled(Vector3(size, size, size))
			_put(bufs[kind], basis, Vector3(x - x0, h - 0.25 * size, -(u - u0)), Color(1, 1, 1, 0))
	return {"type": "trees", "key": key, "bufs": bufs, "hmin": hmin if hmin < INF else 0.0, "hmax": hmax if hmax > -INF else 0.0}


static func _job_water(iu: int) -> Dictionary:
	var u0 := iu * T
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var tg := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	var steps := 24
	var water := false
	for k in steps + 1:
		var u := u0 + k * T / steps
		# the stream is wider in the river valley, narrower in the highland and dries up in the heath
		var hw := 2.7 * Land.stream_width(u)
		water = water or hw > 0.03
		var sx := Land.stream_x(u)
		var sdx := Land.stream_dx(u)
		var inv := 1.0 / sqrt(1.0 + sdx * sdx)
		var ax := inv
		var au := -sdx * inv
		var lvl := Land.stream_level(u)
		var flow := 1.0 if Land.stream_level(u + 1.0) < lvl else 0.0
		var along := fposmod(u, 512.0)
		for s in [-1.0, 1.0]:
			v.append(Vector3(sx + ax * hw * s, lvl, -((u + au * hw * s) - u0)))
			n.append(Vector3.UP)
			tg.append_array([ax, 0.0, -au, 1.0])
			c.append(Color(flow, 0, 0, 1))
			uv.append(Vector2(0.5 + 0.5 * s, along))
		if k > 0:
			var a := (k - 1) * 2
			idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	if not water:
		v.clear()
	return {"type": "water", "key": iu, "v": v, "n": n, "tg": tg, "c": c, "uv": uv, "i": idx}
