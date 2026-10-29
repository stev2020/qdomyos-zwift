extends Node3D
## Kvest style test: an endless ride through the landscapes of Kvest (Laubland, Heide, Flusstal, Hochland) in its
## painted style. The speed comes from Kvestrun (or QZ) on the same tablet; without them it rides at a demo speed.
##
## Previews on a computer (command line, after "--"):
##   --capture <folder> --at 0,400,900 [--light abend] [--quality hoch]   saves screenshots
##   --land laub|heide|fluss|hoch                                          only this landscape (default: they take turns)
##   --demo <km/h> --start <metres>                                        for recordings with --write-movie

const SHIFT := 1024.0
## gravel: share of the pebbles on the path that are drawn, gravel_range: up to which distance (0: none).
const LEVELS := [
	{"name": "Hoch", "density": 1.0, "fade": 52.0, "ahead": 528.0, "side": 264.0, "tree_lod": 170.0, "shadows": true, "scale": 0.85, "msaa": Viewport.MSAA_2X, "pollen": true, "fog": 0.0019, "gravel": 1.0, "gravel_range": 46.0},
	{"name": "Mittel", "density": 0.6, "fade": 44.0, "ahead": 432.0, "side": 216.0, "tree_lod": 130.0, "shadows": true, "scale": 0.75, "msaa": Viewport.MSAA_2X, "pollen": true, "fog": 0.0024, "gravel": 0.6, "gravel_range": 32.0},
	{"name": "Niedrig", "density": 0.35, "fade": 34.0, "ahead": 336.0, "side": 168.0, "tree_lod": 95.0, "shadows": false, "scale": 0.65, "msaa": Viewport.MSAA_DISABLED, "pollen": false, "fog": 0.0034, "gravel": 0.0, "gravel_range": 0.0},
]
## Names for --land, in the order of Land.LAUB .. Land.HOCH
const LAND_ARGS := ["laub", "heide", "fluss", "hoch"]
## Ground colours per landscape: Laubland (dark earth), Heide (light sand), Flusstal (gravel), Hochland (rock and scree).
## See shaders/terrain.gdshader.
const GROUND := {
	"grass_a": [Color(0.30, 0.44, 0.10), Color(0.40, 0.42, 0.17), Color(0.26, 0.42, 0.13), Color(0.36, 0.41, 0.19)],
	"grass_b": [Color(0.46, 0.56, 0.14), Color(0.52, 0.50, 0.22), Color(0.40, 0.54, 0.17), Color(0.47, 0.49, 0.26)],
	"grass_c": [Color(0.60, 0.60, 0.22), Color(0.66, 0.60, 0.33), Color(0.52, 0.58, 0.25), Color(0.58, 0.55, 0.38)],
	"under": [Color(0.25, 0.37, 0.09), Color(0.33, 0.30, 0.16), Color(0.22, 0.35, 0.10), Color(0.30, 0.33, 0.17)],
	"bare_color": [Color(0.36, 0.28, 0.19), Color(0.76, 0.67, 0.49), Color(0.55, 0.53, 0.48), Color(0.5, 0.48, 0.44)],
	"path_color": [Color(0.46, 0.36, 0.25), Color(0.76, 0.67, 0.50), Color(0.58, 0.55, 0.49), Color(0.52, 0.47, 0.40)],
	"path_rim": [Color(0.31, 0.24, 0.16), Color(0.58, 0.50, 0.36), Color(0.42, 0.40, 0.35), Color(0.38, 0.34, 0.28)],
	"bed_color": [Color(0.58, 0.55, 0.47), Color(0.72, 0.65, 0.50), Color(0.60, 0.58, 0.52), Color(0.52, 0.51, 0.47)],
	"stone_color": [Color(0.56, 0.54, 0.50), Color(0.84, 0.80, 0.70), Color(0.66, 0.64, 0.60), Color(0.60, 0.58, 0.55)],
}
## Height of the far hills and mountains per landscape: low over the heath, high around the valley and the highland.
const BACKDROP_SCALE := [1.0, 0.6, 1.45, 1.8]

var world: World
var rider := Rider.new()
var link := Link.new()
var cam: Camera3D
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ShaderMaterial
var hud: Hud
var backdrop: Node3D
var pollen: GPUParticles3D
var mats := {}

var quality := "auto"
var level := 0
var light := "tag"
var land := -1
var demo_kmh := 20.0
var _gfx := ""

var _loading := true
var _since_ready := 0.0
var _fps_time := 0.0
var _fps_frames := 0
var _fps := 0.0
var _slow_windows := 0
var _hud_time := 0.0

var _capture_dir := ""
var _capture_at: Array = []
var _capture_i := 0
var _capture_wait := -1
var _movie := false
var _gallery := ""
var _no_hud := false


func _ready() -> void:
	Land.init()
	_read_args()
	Land.mode = land
	_make_materials()
	_make_environment()
	cam = Camera3D.new()
	cam.fov = 66.0
	cam.near = 0.1
	cam.far = 1700.0
	add_child(cam)
	cam.current = true
	world = World.new()
	add_child(world)
	world.setup(mats)
	_make_backdrop()
	_make_pollen()
	hud = Hud.new()
	add_child(hud)
	hud.quality_pressed.connect(_on_quality)
	hud.light_pressed.connect(_on_light)
	hud.land_pressed.connect(_on_land)
	hud.demo_step.connect(func(d): demo_kmh = clampf(demo_kmh + d, 4.0, 60.0))
	var drivers := {"vulkan": "Vulkan", "opengl3": "OpenGL", "opengl3_es": "OpenGL ES"}
	var driver := RenderingServer.get_current_rendering_driver_name()
	_gfx = "%s · %s" % [drivers.get(driver, driver), RenderingServer.get_video_adapter_name()]
	hud.visible = not _no_hud
	_apply_level(0 if quality == "auto" else ["hoch", "mittel", "niedrig"].find(quality))
	_apply_light()
	if _gallery != "":
		_make_gallery()
		return
	_shift_to(rider.u)
	rider.place(cam, world.origin_u, 0.0, true)
	world.update(rider.u, Land.path_x(rider.u), 0)
	hud.show_loading(_capture_dir == "")


## All plants on a plain meadow (previews only): --gallery sommer|herbst
## Back row: the trees. Front row: bush, juniper, mountain pine, two rocks, heather, tussocks and a fallen trunk.
func _make_gallery() -> void:
	hud.visible = false
	backdrop.visible = false
	pollen.visible = false
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.3, 0.42, 0.12)
	ground.material_override = gm
	add_child(ground)
	var back := [Kit.BEECH, Kit.BIRCH, Kit.OAK, Kit.MAPLE, Kit.WILLOW, Kit.ROWAN, Kit.PINE, Kit.SPRUCE, Kit.FIR]
	for i in back.size():
		_gallery_plant(back[i], Vector3((i - 4.0) * 10.0, 0.0, 0.0))
	var front := [Kit.BUSH, Kit.JUNIPER, Kit.MUGO, Kit.ROCK_A, Kit.ROCK_C]
	for i in front.size():
		_gallery_plant(front[i], Vector3((i - 3.5) * 6.0, 0.0, 16.0))
	_gallery_plant(Kit.LOG, Vector3(21.0, 0.0, 16.0))
	# heather (6) and tussocks (7) as small patches of grass clumps
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = world.grass_mesh
	mm.instance_count = 40
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for k in 40:
		var variant := 6 if k < 20 else 7
		var p := Vector3((9.0 if variant == 6 else 15.0) + rng.randf_range(-1.6, 1.6), 0.0, 16.0 + rng.randf_range(-1.6, 1.6))
		mm.set_instance_transform(k, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.8, 1.1)), p))
		mm.set_instance_custom_data(k, Color(variant, 1.0, rng.randf(), 0.0 if variant == 6 else 0.4))
	var grass := MultiMeshInstance3D.new()
	grass.multimesh = mm
	add_child(grass)
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0, -0.06, -1).normalized(), Vector3.UP), Vector3(0, 7.0, 46))
	cam.fov = 60.0
	_capture_at = [0.0]


func _gallery_plant(kind: int, pos: Vector3) -> void:
	var tint := Color(1, 1, 1)
	if World.LEAF_TINTS.has(kind):
		var pool: Array = World.LEAF_TINTS[kind][1 if _gallery == "herbst" else 0]
		tint = pool[0]
	elif World.NEEDLE_TINTS.has(kind):
		tint = World.NEEDLE_TINTS[kind]
	elif kind == Kit.SPRUCE:
		tint = Color(0.86, 0.9, 0.84)
	tint.a = 0.3
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = world.protos[kind]["high"]
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis(), pos))
	mm.set_instance_custom_data(0, tint)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)


func _read_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var a: String = args[i]
		var val: String = args[i + 1] if i + 1 < args.size() else ""
		match a:
			"--capture":
				_capture_dir = val
			"--at":
				for part in val.split(","):
					_capture_at.append(float(part))
			"--light":
				light = val
			"--quality":
				quality = val
			"--demo":
				demo_kmh = float(val)
			"--start":
				rider.u = float(val)
			"--gallery":
				_gallery = val
			"--land":
				land = LAND_ARGS.find(val)
			"--no-hud":
				_no_hud = true
	_movie = Engine.get_write_movie_path() != ""
	if _capture_dir != "" and _capture_at.is_empty():
		_capture_at = [0.0]


func _noise_tex(seed_value: int, frequency: float, size: int, octaves: int) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = frequency
	n.fractal_octaves = octaves
	var t := NoiseTexture2D.new()
	t.width = size
	t.height = size
	t.seamless = true
	t.generate_mipmaps = true
	t.noise = n
	return t


func _shader_mat(path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path)
	return m


func _make_materials() -> void:
	var patch := _noise_tex(5, 0.025, 256, 4)
	mats["terrain"] = _shader_mat("res://shaders/terrain.gdshader")
	mats["terrain"].set_shader_parameter("patch_noise", patch)
	mats["terrain"].set_shader_parameter("path_tex", load("res://textures/path.png"))
	mats["terrain"].set_shader_parameter("hoof_tex", load("res://textures/hoof.png"))
	for key in GROUND:
		mats["terrain"].set_shader_parameter(key, PackedColorArray(GROUND[key]))
	mats["grass"] = _shader_mat("res://shaders/grass.gdshader")
	mats["grass"].set_shader_parameter("grass_tex", load("res://textures/grass.png"))
	mats["grass"].set_shader_parameter("patch_noise", patch)
	mats["nature"] = _shader_mat("res://shaders/nature.gdshader")
	mats["nature"].set_shader_parameter("leaf_tex", load("res://textures/leaves.png"))
	mats["nature"].set_shader_parameter("leaf_normal", load("res://textures/leaves_n.png"))
	mats["water"] = _shader_mat("res://shaders/water.gdshader")
	mats["water"].set_shader_parameter("water_noise", _noise_tex(9, 0.045, 256, 3))
	mats["pebble"] = _shader_mat("res://shaders/pebble.gdshader")


func _make_environment() -> void:
	sky_mat = _shader_mat("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("cloud_noise", _noise_tex(17, 0.008, 512, 5))
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_normalized = false
	env.glow_bloom = 0.04
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 0.9
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	env.adjustment_contrast = 1.08
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 70.0
	sun.shadow_blur = 2.2
	# summer shade is full of light from the sky: shadows are never black
	sun.shadow_opacity = 0.78
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.2
	add_child(sun)


func _apply_light() -> void:
	if light == "abend":
		sun.rotation_degrees = Vector3(-11.0, 163.0, 0.0)
		sun.light_color = Color(1.0, 0.72, 0.45)
		sun.light_energy = 1.75
		sky_mat.set_shader_parameter("zenith", Color(0.40, 0.53, 0.76))
		sky_mat.set_shader_parameter("horizon", Color(1.0, 0.85, 0.64))
		sky_mat.set_shader_parameter("cloud_lit", Color(1.0, 0.88, 0.70))
		sky_mat.set_shader_parameter("cloud_shade", Color(0.70, 0.64, 0.68))
		sky_mat.set_shader_parameter("sun_glow", 0.55)
		env.fog_light_color = Color(0.96, 0.80, 0.62)
		env.fog_sun_scatter = 0.45
		env.ambient_light_energy = 0.7
		env.glow_intensity = 0.95
	else:
		sun.rotation_degrees = Vector3(-38.0, 158.0, 0.0)
		sun.light_color = Color(1.0, 0.95, 0.86)
		sun.light_energy = 1.7
		sky_mat.set_shader_parameter("zenith", Color(0.30, 0.52, 0.88))
		sky_mat.set_shader_parameter("horizon", Color(0.80, 0.87, 0.93))
		sky_mat.set_shader_parameter("cloud_lit", Color(1.0, 0.98, 0.95))
		sky_mat.set_shader_parameter("cloud_shade", Color(0.64, 0.70, 0.80))
		sky_mat.set_shader_parameter("sun_glow", 0.25)
		env.fog_light_color = Color(0.74, 0.82, 0.88)
		env.fog_sun_scatter = 0.15
		env.ambient_light_energy = 0.82
		env.glow_intensity = 0.6
	if backdrop != null:
		for child in backdrop.get_children():
			child.material_override.set_shader_parameter("haze", env.fog_light_color)


func _apply_level(l: int) -> void:
	level = clampi(l, 0, LEVELS.size() - 1)
	var p: Dictionary = LEVELS[level]
	world.set_quality(p)
	var vp := get_viewport()
	vp.scaling_3d_scale = p["scale"]
	vp.msaa_3d = p["msaa"]
	sun.shadow_enabled = p["shadows"]
	env.fog_density = p["fog"]
	mats["grass"].set_shader_parameter("fade_start", p["fade"] - 12.0)
	mats["grass"].set_shader_parameter("fade_end", p["fade"])
	mats["terrain"].set_shader_parameter("grass_fade", p["fade"])
	mats["pebble"].set_shader_parameter("fade_start", p["gravel_range"] - 12.0)
	mats["pebble"].set_shader_parameter("fade_end", p["gravel_range"])
	if pollen != null:
		pollen.emitting = p["pollen"]
		pollen.visible = p["pollen"]
	_slow_windows = 0


## The button "Landschaft": first the landscapes take turns (Wechsel), then each one on its own. The land is built anew.
func _on_land() -> void:
	land += 1
	if land >= Land.KINDS:
		land = -1
	Land.mode = land
	world.reset()
	_loading = true
	hud.show_loading(true)


func _on_quality() -> void:
	var order := ["auto", "hoch", "mittel", "niedrig"]
	quality = order[(order.find(quality) + 1) % order.size()]
	_apply_level(0 if quality == "auto" else order.find(quality) - 1)


func _on_light() -> void:
	light = "abend" if light == "tag" else "tag"
	_apply_light()


func _make_backdrop() -> void:
	backdrop = Node3D.new()
	add_child(backdrop)
	var hn := FastNoiseLite.new()
	hn.seed = 3
	hn.frequency = 0.9
	var mat := _shader_mat("res://shaders/backdrop.gdshader")
	# far mountains, then nearer wooded hills
	for ring in [[1300.0, 90.0, 240.0, Color(0.42, 0.48, 0.55), true, 0.62], [820.0, 22.0, 70.0, Color(0.20, 0.32, 0.22), false, 0.42]]:
		var r: float = ring[0]
		var segs := 220
		var v := PackedVector3Array()
		var c := PackedColorArray()
		var idx := PackedInt32Array()
		for k in segs + 1:
			var a := TAU * k / segs
			var n1 := hn.get_noise_1d(k * 0.12 + r) * 0.5 + 0.5
			var n2 := hn.get_noise_1d(k * 0.45 + r * 2.0) * 0.5 + 0.5
			var h: float = ring[1] + (ring[2] - ring[1]) * clampf(n1 * 0.8 + n2 * 0.35, 0.0, 1.0)
			var dirv := Vector3(cos(a), 0.0, sin(a))
			var base_col: Color = ring[3]
			var top_col: Color = base_col.lerp(Color(0.62, 0.66, 0.72), 0.35) if ring[4] else base_col.lerp(Color(0.34, 0.46, 0.30), 0.3)
			if ring[4] and h > 200.0:
				top_col = Color(0.93, 0.95, 0.98)
			v.append(dirv * r + Vector3(0, -60.0, 0))
			c.append(Color(base_col.r, base_col.g, base_col.b, 0.0))
			v.append(dirv * r + Vector3(0, h * 0.55, 0))
			c.append(Color(base_col.lerp(top_col, 0.4).r, base_col.lerp(top_col, 0.4).g, base_col.lerp(top_col, 0.4).b, 0.55))
			v.append(dirv * r + Vector3(0, h, 0))
			c.append(Color(top_col.r, top_col.g, top_col.b, 1.0))
			if k > 0:
				var p0 := (k - 1) * 3
				var p1 := k * 3
				for s in 2:
					idx.append_array([p0 + s, p1 + s, p0 + s + 1, p0 + s + 1, p1 + s, p1 + s + 1])
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var m := mat.duplicate()
		m.set_shader_parameter("haze_amount", ring[5])
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 2000.0
		backdrop.add_child(mi)
	_apply_light()


func _make_pollen() -> void:
	pollen = GPUParticles3D.new()
	pollen.amount = 150
	pollen.lifetime = 8.0
	pollen.preprocess = 8.0
	pollen.local_coords = false
	pollen.visibility_aabb = AABB(Vector3(-20, -8, -20), Vector3(40, 16, 40))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(14, 3.0, 14)
	pm.direction = Vector3(0.7, 0.2, 0.5)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.35
	pm.gravity = Vector3(0.05, -0.02, 0.03)
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.set_color(1, Color(1, 1, 1, 0))
	fade.add_point(0.2, Color(1, 1, 1, 1))
	fade.add_point(0.8, Color(1, 1, 1, 1))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	pollen.process_material = pm
	var dot := GradientTexture2D.new()
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(1.0, 0.5)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	dot.gradient = g
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1.0, 0.96, 0.84, 0.8)
	m.albedo_texture = dot
	var q := QuadMesh.new()
	q.size = Vector2(0.04, 0.04)
	q.material = m
	pollen.draw_pass_1 = q
	add_child(pollen)


func _update_globals() -> void:
	var o := world.origin_u
	RenderingServer.global_shader_parameter_set("path_phase", Vector3(
		fposmod(o / Land.PATH_L[0] + Land.PATH_P[0], TAU), fposmod(o / Land.PATH_L[1] + Land.PATH_P[1], TAU), fposmod(o / Land.PATH_L[2] + Land.PATH_P[2], TAU)))
	RenderingServer.global_shader_parameter_set("stream_phase", Vector2(
		fposmod(o / Land.STREAM_L[0] + Land.STREAM_P[0], TAU), fposmod(o / Land.STREAM_L[1] + Land.STREAM_P[1], TAU)))
	RenderingServer.global_shader_parameter_set("noise_shift", fposmod(o, Land.NOISE_PERIOD))


## Moves the origin of the scene close to u, so the numbers stay small on long rides.
func _shift_to(u: float) -> void:
	var target := floorf(u / SHIFT) * SHIFT
	if target != world.origin_u:
		world.shift_origin(target - world.origin_u)
	_update_globals()


func _place_extras() -> void:
	var p := cam.global_position
	backdrop.global_position = Vector3(p.x, Land.path_height(rider.u) - 8.0, p.z)
	var w := Land.weights(rider.u, Land.BLEND)
	var s := 0.0
	for k in Land.KINDS:
		s += w[k] * BACKDROP_SCALE[k]
	backdrop.scale = Vector3(1.0, s, 1.0)
	pollen.global_position = p + cam.global_transform.basis.z * -6.0


func _process(dt: float) -> void:
	link.poll()
	if _capture_dir != "":
		_capture_tick()
		return
	if _loading:
		world.update(rider.u, Land.path_x(rider.u), 60)
		if _movie:
			world.wait_idle()
		rider.place(cam, world.origin_u, 0.0, true)
		_place_extras()
		if world.is_idle():
			_loading = false
			hud.show_loading(false)
		return
	_since_ready += dt
	var kmh := link.speed_kmh if link.has_data() else demo_kmh
	rider.advance(dt, kmh)
	if rider.u - world.origin_u > SHIFT:
		_shift_to(rider.u)
	rider.place(cam, world.origin_u, dt, false)
	_place_extras()
	world.update(rider.u, Land.path_x(rider.u), 2)
	if _movie:
		world.wait_idle()
	_measure(dt)
	_hud_time -= dt
	if _hud_time <= 0.0:
		_hud_time = 0.25
		_update_hud()


func _measure(dt: float) -> void:
	_fps_time += dt
	_fps_frames += 1
	if _fps_time < 2.0:
		return
	_fps = _fps_frames / _fps_time
	_fps_time = 0.0
	_fps_frames = 0
	if quality != "auto" or _since_ready < 6.0 or _movie:
		return
	_slow_windows = _slow_windows + 1 if _fps < 27.0 else 0
	if _slow_windows >= 2 and level < LEVELS.size() - 1:
		_apply_level(level + 1)


func _num(v: float) -> String:
	return ("%.1f" % v).replace(".", ",")


func _update_hud() -> void:
	var status := ""
	var sub := ""
	var demo := ""
	var km: String = Land.NAMES[Land.kind_at(rider.u)] + " · " + _num(rider.ridden / 1000.0) + " km gefahren"
	if link.has_data():
		status = "%s · %s km/h" % [link.app, _num(rider.speed * 3.6)]
		sub = km
	elif link.connected():
		status = "Verbunden mit %s" % link.app
		sub = "Warte auf Werte: Rad in %s verbinden" % link.app
	else:
		status = "Demo-Fahrt · %s km/h" % _num(rider.speed * 3.6)
		sub = link.diagnosis() + " · " + km
		demo = "Demo %d km/h" % int(round(demo_kmh))
	var lname: String = LEVELS[level]["name"]
	var q: String = "Qualität: " + ("Auto (%s)" % lname if quality == "auto" else lname)
	var l: String = "Licht: " + ("Abendsonne" if light == "abend" else "Sommertag")
	var ln: String = "Landschaft: " + ("Wechsel" if land < 0 else Land.NAMES[land])
	var fps := ("%d Bilder/s\n" % int(round(_fps)) if _fps > 0.0 else "") + _gfx
	hud.set_texts(status, sub, q, l, ln, fps, demo)


func _capture_tick() -> void:
	if _capture_i >= _capture_at.size():
		get_tree().quit()
		return
	if _capture_wait < 0 and _gallery != "":
		_capture_wait = 8
		return
	if _capture_wait < 0:
		rider.u = float(_capture_at[_capture_i])
		_shift_to(rider.u)
		rider.place(cam, world.origin_u, 0.0, true)
		_place_extras()
		world.update(rider.u, Land.path_x(rider.u), 0)
		world.wait_idle()
		_capture_wait = 8
		return
	_capture_wait -= 1
	if _capture_wait == 0:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/shot_%02d.png" % [_capture_dir, _capture_i])
		print("saved shot ", _capture_i, " at u=", rider.u, " draw calls: ",
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), " primitives: ",
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		_capture_i += 1
		_capture_wait = -1
