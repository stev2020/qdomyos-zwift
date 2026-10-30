class_name World
extends Node3D
## Streams the land around the rider: terrain tiles, grass, trees, the stream and the things on and beside the path
## (pebbles, stones, fallen trunks), each in the plants and colours of its landscape (see Land). The number crunching
## runs in a worker thread; the main thread only turns the finished arrays into meshes, a few per frame, so the ride
## stays smooth.

const T := Land.TILE
const BLOCK := 3                 # trees and rocks are grouped in blocks of 3 x 1 tiles
const LOD_CELLS := [32, 16, 8]   # terrain cells per tile side for the three levels of detail
const FLOATS := 16               # per instance: 12 for the transform, 4 custom
const CHUNK := 24.0              # the pebbles are drawn in pieces of 24 m of path
const PEBBLE_SHAPES := 3
const ROOT_RANGE := 70.0         # roots across the path are drawn up to this distance
const GRASS_TILE_REACH := 35.0   # from the middle of a tile to its farthest corner (Godot measures to the middle)
const FAR_SHARE := 0.25          # the share of the clumps that goes on as far clumps (grass.gdshader)
const LOD_FADE_TIME := 0.7       # seconds for the change between the detailed and the simple models of a block
const LOD_MARGIN := 8.0          # metres beyond tree_lod before a block changes back, so it does not flip to and fro

var origin_u := 0.0
var view_ahead := 528.0
var view_side := 264.0
var grass_density := 1.0
var grass_range := 149.0          # grass is built for tiles up to this distance
var grass_end := 57.0             # the last clumps sink into the ground here, except the far clumps (grass.gdshader)
var grass_far := 114.0            # the last far clumps sink into the ground here
var tree_lod := 170.0
var shadows := true
var gravel_range := 46.0         # the biggest pebbles are drawn up to this distance, smaller ones less far; 0: none

var mat_terrain: ShaderMaterial
var mat_grass: ShaderMaterial
var mat_nature: ShaderMaterial
var mat_water: ShaderMaterial
var mat_pebble: ShaderMaterial
var grass_mesh: ArrayMesh
var pebble_meshes: Array = []    # a few shapes of pebbles
var protos: Array = []           # per kind: {"high": ArrayMesh, "low": ArrayMesh}

var tiles := {}                  # Vector2i(ix, iu) -> {"node", "lod", "want", "grass", "mmi"}
var blocks := {}                 # Vector2i(bx, iu) -> {"node"}
var rows := {}                   # iu -> {"node", "pebbles"}: the stream and the pebbles on the path

var _thread := Thread.new()
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _jobs: Array = []
var _results: Array = []
var _quit := false
var _busy := 0
var _gen := 0                    # raised by reset(); results of older jobs are thrown away
var _cam_u := 0.0                # where the rider was at the last update
var _cam_x := 0.0


func setup(materials: Dictionary) -> void:
	mat_terrain = materials["terrain"]
	mat_grass = materials["grass"]
	mat_nature = materials["nature"]
	mat_water = materials["water"]
	mat_pebble = materials["pebble"]
	grass_mesh = Kit.grass_clump(mat_grass)
	for shape in PEBBLE_SHAPES:
		pebble_meshes.append(Kit.pebble(shape, mat_pebble))
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
			Kit.LOG:
				p["high"] = Kit.fallen_trunk(430, false, mat_nature)
				p["low"] = Kit.fallen_trunk(430, true, mat_nature)
			Kit.ROOT:
				p["high"] = Kit.roots(440, mat_nature)
				p["low"] = p["high"]
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
	grass_end = p["fade"] * 1.1
	grass_far = p["fade"] * 2.2
	grass_range = grass_far + GRASS_TILE_REACH
	view_ahead = p["ahead"]
	view_side = p["side"]
	tree_lod = p["tree_lod"]
	shadows = p["shadows"]
	gravel_range = p["gravel_range"]
	for key in tiles:
		var t: Dictionary = tiles[key]
		if t.has("mmi") and is_instance_valid(t["mmi"]):
			t["mmi"].visibility_range_end = grass_far + GRASS_TILE_REACH
	_thin_grass()
	for key in blocks:
		var node: Node3D = blocks[key]["node"]
		if not is_instance_valid(node):
			continue
		for child in node.get_children():
			_set_lod(child)
	_show_pebbles()


func _set_lod(mmi: GeometryInstance3D) -> void:
	if mmi.has_meta("rock") or mmi.has_meta("low"):
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	elif mmi.has_meta("root"):
		# up to the farthest root in the box; each root sinks into the ground before ROOT_RANGE (nature.gdshader)
		mmi.visibility_range_end = minf(tree_lod, ROOT_RANGE) + float(mmi.get_meta("reach"))
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Each block shows its detailed models (and rocks) near the rider and its simple ones further away; the change takes
## LOD_FADE_TIME in a fine dissolve (nature.gdshader), so no group of trees pops up. Godot's visibility ranges would
## switch at once, and measured to the middle of the block.
func _fade_lods() -> void:
	var dt := clampf(get_process_delta_time(), 0.0, 0.2)
	for key in blocks:
		var b: Dictionary = blocks[key]
		if not b.has("near"):
			continue
		var dx: float = (key.x + 0.5) * BLOCK * T - _cam_x
		var du: float = (key.y + 0.5) * T - _cam_u
		var d := sqrt(dx * dx + du * du)
		var lod: int = b["lod"]
		if (lod == 0 and d > tree_lod + LOD_MARGIN) or (lod == 1 and d < tree_lod - LOD_MARGIN):
			b["lod"] = 1 - lod
			# a change that turns back in the middle goes on from where it was
			b["mix"] = 1.0 - b["mix"]
		elif b["mix"] >= 1.0:
			continue
		else:
			b["mix"] = minf(1.0, b["mix"] + dt / LOD_FADE_TIME)
		_show_lods(b)


## Ends all changes at once (previews: they jump from place to place).
func settle_lods() -> void:
	_fade_lods()
	for key in blocks:
		var b: Dictionary = blocks[key]
		if b.has("near") and b["mix"] < 1.0:
			b["mix"] = 1.0
			_show_lods(b)


## Shows the models of a block for its lod and how far its change has come.
func _show_lods(b: Dictionary) -> void:
	var mix: float = b["mix"]
	var lists := [b["near"], b["far"]] if b["lod"] == 0 else [b["far"], b["near"]]
	for k in 2:
		for mmi in lists[k]:
			if not is_instance_valid(mmi):
				continue
			# k = 0: the models of the lod come in, k = 1: the others go
			mmi.visible = k == 0 or mix < 1.0
			mmi.set_instance_shader_parameter("lod_role", 0.0 if mix >= 1.0 else (1.0 if k == 0 else -1.0))
			mmi.set_instance_shader_parameter("lod_mix", mix)


func shift_origin(d: float) -> void:
	origin_u += d
	for dict in [tiles, blocks, rows]:
		for key in dict:
			var node = dict[key].get("node")
			if node != null and is_instance_valid(node):
				node.position.z += d


## Keeps the land around the rider complete. max_apply: how many finished jobs to build this frame.
func update(cam_u: float, cam_x: float, max_apply: int) -> void:
	_cam_u = cam_u
	_cam_x = cam_x
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
			_request({"type": "path", "key": iu, "prio": absf(du) + 3.0})
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
	_show_pebbles()
	_thin_grass()
	_fade_lods()


## In tiles that lie wholly beyond the end of the near grass only the far clumps are drawn: they come first in the list
## of a tile (see _job_grass).
func _thin_grass() -> void:
	for key in tiles:
		_thin_tile(key)


func _thin_tile(key: Vector2i) -> void:
	var mmi = tiles[key].get("mmi")
	if mmi == null or not is_instance_valid(mmi):
		return
	var mm: MultiMesh = mmi.multimesh
	# the distance to the nearest point of the tile
	var dx := maxf(0.0, maxf(key.x * T - _cam_x, _cam_x - (key.x + 1) * T))
	var du := maxf(0.0, maxf(key.y * T - _cam_u, _cam_u - (key.y + 1) * T))
	var share := grass_density
	if sqrt(dx * dx + du * du) > grass_end:
		share = minf(share, FAR_SHARE)
	var n := int(mm.instance_count * share)
	if mm.visible_instance_count != n:
		mm.visible_instance_count = n


## Of each piece of pebbles, only those within their reach are drawn (see _job_path): the pieces are sorted so that
## these are always the first part of the list.
func _show_pebbles() -> void:
	for iu in rows:
		var pieces = rows[iu].get("pebbles")
		if pieces != null:
			for p in pieces:
				_count_pebbles(p, iu)


func _count_pebbles(p: Dictionary, iu: int) -> void:
	var n := 0
	if gravel_range > 0.0:
		# on a lower quality the reach is shorter (the shader scales it); the list then ends a little later than
		# needed, and the shader hides the rest
		var factor := gravel_range / GRAVEL_FAR
		n = p["keys"].bsearch(_cam_u - iu * T - (1.0 - factor) * GRAVEL_NEAR, false)
	var mmi: MultiMeshInstance3D = p["mmi"]
	if mmi.multimesh.visible_instance_count != n:
		mmi.multimesh.visible_instance_count = n
		mmi.visible = n > 0


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
			"path":
				_apply_path(res)


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
	arr[Mesh.ARRAY_TEX_UV2] = res["uv2"]
	arr[Mesh.ARRAY_CUSTOM0] = res["custom"]
	arr[Mesh.ARRAY_INDEX] = res["i"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
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
	# tiles whose clumps have all sunk into the ground are not drawn at all
	mmi.visibility_range_end = grass_far + GRASS_TILE_REACH
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(mmi)
	tiles[key]["mmi"] = mmi
	_thin_tile(key)


func _apply_trees(res: Dictionary) -> void:
	var key: Vector2i = res["key"]
	if not blocks.has(key):
		return
	var node := _node_for(blocks, key, Vector3(key.x * BLOCK * T, 0.0, -(key.y * T - origin_u)))
	var aabb := AABB(Vector3(-8, res["hmin"] - 2.0, -T - 8), Vector3(BLOCK * T + 16, res["hmax"] - res["hmin"] + 22.0, T + 16))
	var b: Dictionary = blocks[key]
	b["near"] = []
	b["far"] = []
	for kind in Kit.COUNT:
		var buf: PackedFloat32Array = res["bufs"][kind]
		if not buf.is_empty():
			_add_models(node, kind, buf, aabb, b)
	var dx := (key.x + 0.5) * BLOCK * T - _cam_x
	var du := (key.y + 0.5) * T - _cam_u
	b["lod"] = 0 if sqrt(dx * dx + du * du) < tree_lod else 1
	b["mix"] = 1.0
	_show_lods(b)


## Trees, rocks, trunks or roots of one kind: the detailed models near the rider, the simple ones further away (rocks
## and roots have only one).
func _add_models(node: Node3D, kind: int, buf: PackedFloat32Array, aabb: AABB, b: Dictionary) -> void:
	var high := MultiMeshInstance3D.new()
	if kind == Kit.ROOT:
		# Godot measures the range to the middle of the box: for the roots that is a box around them on the path, not
		# the whole block, else they came up only a few metres ahead or not at all
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for i in buf.size() / FLOATS:
			var o := Vector3(buf[i * FLOATS + 3], buf[i * FLOATS + 7], buf[i * FLOATS + 11])
			lo = lo.min(o)
			hi = hi.max(o)
		aabb = AABB(lo - Vector3(3.5, 0.8, 3.5), hi - lo + Vector3(7.0, 1.6, 7.0))
		high.set_meta("root", true)
		high.set_meta("reach", Vector2(aabb.size.x, aabb.size.z).length() * 0.5)
	high.multimesh = _multimesh(protos[kind]["high"], buf, aabb)
	if kind >= Kit.ROCK_A:
		high.set_meta("rock", true)
	node.add_child(high)
	_set_lod(high)
	if kind == Kit.ROOT:
		high.visibility_range_end_margin = 8.0
		return
	# rocks and the detailed models near the rider; rocks have no simple version and are gone in the distance
	b["near"].append(high)
	if kind >= Kit.ROCK_A:
		return
	var low := MultiMeshInstance3D.new()
	low.set_meta("low", true)
	low.multimesh = _multimesh(protos[kind]["low"], buf, aabb)
	node.add_child(low)
	_set_lod(low)
	b["far"].append(low)


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


func _apply_path(res: Dictionary) -> void:
	var iu: int = res["key"]
	if not rows.has(iu):
		return
	var node := _node_for(rows, iu, Vector3(0.0, 0.0, -(iu * T - origin_u)))
	var pieces := []
	for c in res["chunks"]:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _multimesh(pebble_meshes[c["shape"]], c["buf"], c["aabb"])
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mmi)
		var p := {"mmi": mmi, "keys": c["keys"]}
		_count_pebbles(p, iu)
		pieces.append(p)
	rows[iu]["pebbles"] = pieces


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
			"path":
				res = _job_path(job["key"])
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
	# colour: the share of each landscape (r Laubland, g Heide, b Flusstal, a Hochland); uv.x: bare ground, uv.y: the
	# grass strip in the middle of the path; uv2: half the width of the path and its cart ruts (see Land.path_style);
	# custom0: how dense the wood is (Land.woods) and the noise meadow, which picks flowers and heather
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var custom := PackedFloat32Array()
	for j in n + 1:
		var r: PackedFloat64Array = rws[j + 1]
		var wc := Color(r[Land.W], r[Land.W + 1], r[Land.W + 2], r[Land.W + 3])
		var style := Vector2(r[Land.PH], r[Land.RUTS])
		for i in n + 1:
			var c := (j + 1) * w + (i + 1)
			verts.append(Vector3(i * step, hs[c], -j * step))
			norms.append(Vector3(hs[c - 1] - hs[c + 1], 2.0 * step, hs[c + w] - hs[c - w]).normalized())
			cols.append(wc)
			uvs.append(Vector2(Land.bare(x0 + i * step, u0 + j * step, r), r[Land.QUIET]))
			uv2s.append(style)
			custom.append(Land.woods(x0 + i * step, u0 + j * step, r))
			custom.append(Land.meadow.get_noise_2d(x0 + i * step, u0 + j * step))
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
			uv2s.append(uv2s[vi])
			custom.append(custom[vi * 2])
			custom.append(custom[vi * 2 + 1])
		for k in edge.size() - 1:
			idx.append_array([edge[k], first + k, edge[k + 1], edge[k + 1], first + k, first + k + 1])
	return {"type": "terrain", "key": key, "lod": lod, "v": verts, "n": norms, "c": cols, "uv": uvs, "uv2": uv2s, "custom": custom,
		"i": idx}


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
	# a second one, so the clumps stay where they were before the far clumps came
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = hash(Vector3i(key.x, key.y, 13))
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
			var half: float = r[Land.PH]
			if dp < half - 0.2 or dp > 46.0:
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
				if dp < half + 0.5:
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
			hscale *= lerpf(0.5, 1.0, smoothstep(half - 0.2, half + 2.0, dp))
			# in the wood the grass grows thinner and lies in the shade
			var wd := Land.woods(x, uu, r)
			if wd > 0.0 and rng.randf() < 0.55 * wd:
				continue
			bright *= lerpf(1.0, 0.7, wd)
			var h := _grid_height(hs, w, (x - x0) / step, (uu - u0) / step)
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)
			var ws := rng.randf_range(0.85, 1.25)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(ws, hscale, ws))
			var phase := rng.randf()
			# the meadow thins out towards the edge of its strip along the path, so the far clumps do not end at a line
			if dp > 32.0 and rng2.randf() < smoothstep(32.0, 46.0, dp):
				continue
			_put(buf, basis, Vector3(x - x0, h - 0.02, -(uu - u0)), Color(variant, bright, phase, dry))
	# the grass strip in the middle of quiet cart tracks: short, dense clumps in a narrow line
	var along := 0.3
	for gj in int(T / along):
		var u := u0 + (gj + rng.randf()) * along
		var px := Land.path_x(u)
		if px < x0 - 1.0 or px > x0 + T + 1.0:
			continue
		var r := Land.row(u)
		if rng.randf() >= r[Land.QUIET]:
			continue
		var x: float = px + rng.randf_range(-0.1, 0.1) / r[1]
		if x < x0 or x >= x0 + T:
			continue
		var k := _pick(r, Land.W, rng.randf())
		var variant := 2 if rng.randf() < 0.8 else (7 if k == Land.HEIDE else 0)
		var dry := rng.randf() * 0.3
		var bright := rng.randf_range(0.82, 1.0)
		if k == Land.HEIDE:
			dry += 0.35
			bright *= 0.85
		bright *= lerpf(1.0, 0.7, Land.woods(x, u, r))
		var h := _grid_height(hs, w, (x - x0) / step, (u - u0) / step)
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
		var ws := rng.randf_range(0.35, 0.5)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(ws, rng.randf_range(0.35, 0.7), ws))
		_put(buf, basis, Vector3(x - x0, h - 0.02, -(u - u0)), Color(variant, bright, rng.randf(), dry))
	# shuffle, so that drawing only the first part of the list thins the meadow out evenly. INSTANCE_CUSTOM.z then
	# gives the place in the list: the first FAR_SHARE of the clumps are the far clumps (grass.gdshader)
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
		out[dst + 14] = (k + 0.5) / count
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
## The pebbles on the paths, per landscape: how many lie on a square metre at most, how evenly they spread (1: all
## over the path; 0: pushed to its edges and out of the ruts), their size in metres, the share of bigger stones and
## their size.
const GRAVEL_MAX := [16.0, 8.0, 45.0, 32.0]
const GRAVEL_EVEN := [0.25, 0.3, 0.55, 0.8]
const GRAVEL_SIZE := [Vector2(0.02, 0.045), Vector2(0.015, 0.035), Vector2(0.02, 0.05), Vector2(0.025, 0.06)]
const GRAVEL_BIG := [0.12, 0.08, 0.15, 0.2]
const GRAVEL_BIG_SIZE := [Vector2(0.05, 0.09), Vector2(0.04, 0.07), Vector2(0.05, 0.1), Vector2(0.06, 0.14)]
## How far a pebble is seen: 900 m per metre of its size, at least 36 m, at most 46 m. Further away even the big ones
## are hardly a dot; there the painted stones of the path take over.
const GRAVEL_REACH := 900.0
const GRAVEL_NEAR := 36.0
const GRAVEL_FAR := 46.0
## Their colours (linear): brown and grey stones in the Laubland, sandstone and grey flint in the heath, grey river
## gravel in the valley, grey-brown rock in the highland. All a little warm: the blue light of the sky cools them down.
const GRAVEL_COLORS := [
	[Color(0.2, 0.15, 0.1), Color(0.27, 0.23, 0.18), Color(0.16, 0.13, 0.1)],
	[Color(0.46, 0.4, 0.3), Color(0.34, 0.3, 0.25), Color(0.52, 0.46, 0.36)],
	[Color(0.3, 0.28, 0.25), Color(0.42, 0.39, 0.34), Color(0.2, 0.18, 0.16)],
	[Color(0.28, 0.24, 0.19), Color(0.36, 0.32, 0.27), Color(0.2, 0.17, 0.14)],
]
## Beside the path, per landscape: the chance of a stone on either side every 4 m and of a fallen trunk every 8 m
## (trunks only near woods), and in a wood the chance of roots across the path every 1.5 m.
const EDGE_STONES := [0.07, 0.05, 0.1, 0.15]
const EDGE_LOGS := [0.05, 0.03, 0.035, 0.0]
const ROOTS := [0.3, 0.3, 0.35, 0.0]


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
					# open heath: groves of pines and birches, junipers standing alone. In a wood the trees come closer to
					# the path (see Land.wood).
					var thick := Land.wood(Land.HEIDE, f, dp, r)
					if dp > lerpf(5.5, 3.5, thick) and rng.randf() < thick * lerpf(0.55, 0.75, r[Land.WOOD]) + 0.006:
						kind = Kit.PINE if rng.randf() < 0.6 else Kit.BIRCH
					elif rng.randf() < 0.035 + 0.05 * smoothstep(-0.3, 0.3, f):
						kind = Kit.JUNIPER
						scale = rng.randf_range(0.6, 1.25)
				Land.FLUSS:
					# willows along the river, spruces and firs on the slopes, rowans and a few conifers on the floor
					var side := Land.valley_side(x, r[0], r[3])
					var thick := Land.wood(Land.FLUSS, f, dp, r)
					if sw > 0.01 and ds < 14.0 and dp > 5.0 and rng.randf() < 0.3:
						kind = Kit.WILLOW
						scale = rng.randf_range(0.75, 1.15)
					elif side > 0.0 and rng.randf() < smoothstep(0.0, 40.0, side) * 0.48 + 0.05:
						kind = _valley_conifer(x, u, rng)
					elif dp > lerpf(5.5, 4.5, thick) and rng.randf() < thick * lerpf(0.45, 0.8, r[Land.WOOD]) + 0.012:
						# where the path runs through a wood, it is a wood of spruces and firs
						kind = Kit.ROWAN if rng.randf() < lerpf(0.35, 0.1, r[Land.WOOD]) else _valley_conifer(x, u, rng)
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
					# broadleaf woods and meadows: beech, oak and maple, big single trees by the path, bushes. In a wood
					# the trees come closer to the path.
					var thick := Land.wood(Land.LAUB, f, dp, r)
					if dp > lerpf(5.5, 4.0, thick) and rng.randf() < thick * 0.85 + 0.02:
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
			if dp < maxf(2.2, r[Land.PH] + size * 1.2) or rng.randf() > p:
				continue
			var h := Land.height(x, u, r)
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)
			var basis := Basis(Vector3(rng.randf_range(-0.2, 0.2), 1, rng.randf_range(-0.2, 0.2)).normalized(), rng.randf() * TAU).scaled(Vector3(size, size, size))
			_put(bufs[kind], basis, Vector3(x - x0, h - 0.25 * size, -(u - u0)), Color(1, 1, 1, 0))
	# stones and fallen trunks beside the path, if the path passes this block (they reach up to about 10 m from it)
	var px_lo := INF
	var px_hi := -INF
	for k in 9:
		var px := Land.path_x(u0 + k * T / 8.0)
		px_lo = minf(px_lo, px)
		px_hi = maxf(px_hi, px)
	if px_hi + 12.0 >= x0 and px_lo - 12.0 < x0 + bw:
		for t in _path_things(key.y):
			var p: Vector3 = t[2]
			if p.x < x0 or p.x >= x0 + bw:
				continue
			hmin = minf(hmin, p.y)
			hmax = maxf(hmax, p.y)
			# roots sink into the ground towards the end of their range instead of popping up (nature.gdshader)
			var custom := Color(ROOT_RANGE - 15.0, ROOT_RANGE, -1.0, 0.0) if t[0] == Kit.ROOT else Color(1, 1, 1, 0)
			_put(bufs[t[0]], t[1], Vector3(p.x - x0, p.y, -(p.z - u0)), custom)
	return {"type": "trees", "key": key, "bufs": bufs, "hmin": hmin if hmin < INF else 0.0, "hmax": hmax if hmax > -INF else 0.0}


## The pebbles on the path for one row of tiles, in pieces of CHUNK metres. Each pebble is seen up to its reach (see
## GRAVEL_REACH): the big ones far, the small ones only near the rider. The pebbles of a piece are sorted by the place
## where the rider brings them into reach (the keys), so World draws only the first part of the list.
static func _job_path(iu: int) -> Dictionary:
	var u0 := iu * T
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(iu, 0, 7))
	var heights := {}
	var row_cache := {}
	var chunks := []
	var pieces := int(T / CHUNK)
	var along := 0.5
	for c in pieces:
		var buf := PackedFloat32Array()
		var keys := PackedFloat32Array()
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for k in int(CHUNK / along):
			var u := u0 + c * CHUNK + (k + 0.5) * along
			var r := Land.row(u)
			var half: float = r[Land.PH]
			var quiet: float = r[Land.QUIET]
			var ruts: float = r[Land.RUTS]
			# footpaths have fewer pebbles, spread evenly
			var narrow := clampf((0.9 - half) / 0.45, 0.0, 1.0)
			var most := 0.0
			for lk in Land.KINDS:
				most += r[Land.W + lk] * GRAVEL_MAX[lk]
			most *= lerpf(1.0, 0.4, narrow)
			var span := half - 0.05
			for i in int(most * 2.0 * span * along + rng.randf()):
				var s := rng.randf_range(-span, span)
				var kind := _pick(r, Land.W, rng.randf())
				if rng.randf() >= _gravel_share(s, half, quiet, ruts, lerpf(GRAVEL_EVEN[kind], 1.0, narrow)):
					continue
				var uu := u + (rng.randf() - 0.5) * along
				var x: float = Land.path_x(uu) + s / r[1]
				var sz: Vector2 = GRAVEL_BIG_SIZE[kind] if rng.randf() < GRAVEL_BIG[kind] else GRAVEL_SIZE[kind]
				var size := rng.randf_range(sz.x, sz.y)
				var reach := clampf(size * GRAVEL_REACH, GRAVEL_NEAR, GRAVEL_FAR)
				var h := _mesh_height(heights, row_cache, x, uu)
				# tilted only a little, so the open underside of the dome stays in the ground
				var tilt := Vector3(rng.randf_range(-0.06, 0.06), 1.0, rng.randf_range(-0.06, 0.06)).normalized()
				var stretch := Vector3(rng.randf_range(0.8, 1.25), rng.randf_range(0.7, 1.1), rng.randf_range(0.8, 1.25))
				var palette: Array = GRAVEL_COLORS[kind]
				var col: Color = palette[rng.randi() % palette.size()] * rng.randf_range(0.82, 1.15)
				col.a = reach
				var p := Vector3(x, h, -(uu - u0))
				_put(buf, Basis(tilt, rng.randf() * TAU).scaled(stretch * size), p, col)
				keys.append(uu - u0 - reach)
				lo = lo.min(p)
				hi = hi.max(p)
		if not buf.is_empty():
			var aabb := AABB(lo - Vector3(0.2, 0.2, 0.2), hi - lo + Vector3(0.4, 0.4, 0.4))
			var sorted := _sorted(buf, keys)
			chunks.append({"buf": sorted[0], "keys": sorted[1], "aabb": aabb, "shape": posmod(iu * pieces + c, PEBBLE_SHAPES)})
	return {"type": "path", "key": iu, "chunks": chunks}


## Stones and fallen trunks beside the path in the row iu and roots across it, as [kind, basis, Vector3(x, height, u)].
## They go into the blocks of trees and rocks (each block takes the ones on its ground), so they need hardly any draw
## calls of their own. Every block of the row computes the same list.
static func _path_things(iu: int) -> Array:
	var u0 := iu * T
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(iu, 0, 9))
	var heights := {}
	var row_cache := {}
	var things := []
	# stones beside the path, now and then on either side
	for k in int(T / 4.0):
		var u := u0 + (k + rng.randf()) * 4.0
		var r := Land.row(u)
		var kind := _pick(r, Land.W, rng.randf())
		for side in [-1.0, 1.0]:
			if rng.randf() >= EDGE_STONES[kind]:
				continue
			var size := rng.randf_range(0.18, 0.4) if rng.randf() < 0.88 else rng.randf_range(0.45, 0.65)
			# right at the edge, where the grass is short
			var x: float = r[0] + side * (r[Land.PH] + rng.randf_range(-0.05, 0.45) + size * 0.6) / r[1]
			var sw: float = r[Land.SW]
			if sw > 0.01 and Land.dist_stream(x, r) < 3.0 * sw + 1.0:
				continue
			# grey, angular stones: the round, mossy ones look white from the side
			var h := _mesh_height(heights, row_cache, x, u)
			var tilt := Vector3(rng.randf_range(-0.2, 0.2), 1.0, rng.randf_range(-0.2, 0.2)).normalized()
			things.append([Kit.ROCK_C, Basis(tilt, rng.randf() * TAU).scaled(Vector3.ONE * size), Vector3(x, h - 0.25 * size, u)])
	# fallen trunks near woods, lying at a slant to the path, so the rider sees them along their length
	for k in int(T / 8.0):
		var u := u0 + (k + rng.randf()) * 8.0
		var r := Land.row(u)
		var kind := _pick(r, Land.W, rng.randf())
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var woods := maxf(smoothstep(-0.15, 0.25, Land.forest.get_noise_2d(r[0] + side * 6.0, u)), r[Land.WOOD])
		if rng.randf() >= EDGE_LOGS[kind] * woods:
			continue
		var scale := rng.randf_range(0.8, 1.15)
		var yaw := rng.randf_range(0.35, 1.2) * (1.0 if rng.randf() < 0.5 else -1.0)
		# the trunk keeps 0.4 m off the path with both ends
		var reach := 2.5 * scale * absf(sin(yaw)) + 0.35 * scale
		var x: float = r[0] + side * (r[Land.PH] + 0.4 + reach + rng.randf_range(0.0, 1.5)) / r[1]
		var sw: float = r[Land.SW]
		if sw > 0.01 and Land.dist_stream(x, r) < 3.0 * sw + 4.0:
			continue
		var dir := Vector3(Land.path_dx(u), 0.0, -1.0).normalized().rotated(Vector3.UP, yaw)
		if rng.randf() < 0.5:
			dir = -dir
		# it lies on the ground with both ends: tilted up or down along its length
		var foot := Vector3(x, 0.0, -u) - dir * 2.5 * scale
		var tip := Vector3(x, 0.0, -u) + dir * 2.5 * scale
		var hf := _mesh_height(heights, row_cache, foot.x, -foot.z)
		var ht := _mesh_height(heights, row_cache, tip.x, -tip.z)
		var pitch := atan2(ht - hf, 5.0 * scale)
		var xa := dir * cos(pitch) + Vector3.UP * sin(pitch)
		var ya := Vector3.UP * cos(pitch) - dir * sin(pitch)
		var h := (hf + ht) * 0.5 - 0.06 * scale
		things.append([Kit.LOG, Basis(xa, ya, xa.cross(ya)).scaled(Vector3.ONE * scale), Vector3(x, h, u)])
	# roots across the path where it runs through a wood, at a slant, the thick end on either side, some mirrored
	for k in int(T / 1.5):
		var u := u0 + (k + rng.randf()) * 1.5
		var r := Land.row(u)
		var kind := _pick(r, Land.W, rng.randf())
		if rng.randf() >= ROOTS[kind] * Land.woods(r[0], u, r):
			continue
		var xa := Vector3(1.0, 0.0, Land.path_dx(u)).normalized().rotated(Vector3.UP, rng.randf_range(-0.6, 0.6))
		if rng.randf() < 0.5:
			xa = -xa
		var za := xa.cross(Vector3.UP) * (1.0 if rng.randf() < 0.5 else -1.0)
		var x: float = r[0] + rng.randf_range(-0.3, 0.3) / r[1]
		var h := _mesh_height(heights, row_cache, x, u)
		var scale := rng.randf_range(0.8, 1.2)
		# tilted with the ground, uphill and downhill and across, so no end sticks out where the ground falls away
		var mid := Vector3(x, 0.0, -u)
		var a := mid + xa * 2.0 * scale
		var b := mid - xa * 2.0 * scale
		var c := mid + za * 1.0 * scale
		var d := mid - za * 1.0 * scale
		var sx := (_mesh_height(heights, row_cache, a.x, -a.z) - _mesh_height(heights, row_cache, b.x, -b.z)) / (4.0 * scale)
		var sz := (_mesh_height(heights, row_cache, c.x, -c.z) - _mesh_height(heights, row_cache, d.x, -d.z)) / (2.0 * scale)
		var axes := Basis(xa + Vector3.UP * sx, Vector3.UP - xa * sx - za * sz, za + Vector3.UP * sz).orthonormalized()
		things.append([Kit.ROOT, axes.scaled(Vector3.ONE * scale), Vector3(x, h, u)])
	return things


## How many of the pebbles stay at s (across the path, 0 = middle), from 0 to 1: wheels and hooves push them to the
## edges and out of the ruts, and the grass strip of quiet tracks has none. even: see GRAVEL_EVEN.
static func _gravel_share(s: float, half: float, quiet: float, ruts: float, even: float) -> float:
	var a := absf(s)
	var f := 0.45
	if a > half - 0.35:
		f = 1.0
	elif a < 0.25:
		f = lerpf(0.35, 0.5 * (1.0 - quiet), ruts)
	if absf(a - 0.7) < 0.14:
		f *= lerpf(1.0, 0.15, ruts)
	return lerpf(f, 1.0, even) * (1.0 - quiet * (1.0 - smoothstep(0.2, 0.32, a)))


## The height of the terrain at x, u as it is drawn near the rider (the finest level of detail), so the pebbles lie
## on the drawn ground. heights and row_cache keep the grid points and rows already computed.
static func _mesh_height(heights: Dictionary, row_cache: Dictionary, x: float, u: float) -> float:
	var step: float = T / LOD_CELLS[0]
	var fx := x / step
	var fu := u / step
	var i := floori(fx)
	var j := floori(fu)
	var a := fx - i
	var b := fu - j
	var h00 := _grid_point(heights, row_cache, i, j)
	var h10 := _grid_point(heights, row_cache, i + 1, j)
	var h01 := _grid_point(heights, row_cache, i, j + 1)
	var h11 := _grid_point(heights, row_cache, i + 1, j + 1)
	if a + b <= 1.0:
		return h00 + (h10 - h00) * a + (h01 - h00) * b
	return h11 + (h01 - h11) * (1.0 - a) + (h10 - h11) * (1.0 - b)


static func _grid_point(heights: Dictionary, row_cache: Dictionary, i: int, j: int) -> float:
	var key := Vector2i(i, j)
	if not heights.has(key):
		var step: float = T / LOD_CELLS[0]
		if not row_cache.has(j):
			row_cache[j] = Land.row(j * step)
		heights[key] = Land.height(i * step, j * step, row_cache[j])
	return heights[key]


## The instances of buf and their keys, sorted by the keys from small to large: [buf, keys].
static func _sorted(buf: PackedFloat32Array, keys: PackedFloat32Array) -> Array:
	var order := range(keys.size())
	order.sort_custom(func(a: int, b: int) -> bool: return keys[a] < keys[b])
	var out := PackedFloat32Array()
	out.resize(buf.size())
	var out_keys := PackedFloat32Array()
	out_keys.resize(keys.size())
	for k in order.size():
		var src: int = order[k] * FLOATS
		var dst := k * FLOATS
		for f in FLOATS:
			out[dst + f] = buf[src + f]
		out_keys[k] = keys[order[k]]
	return [out, out_keys]


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
