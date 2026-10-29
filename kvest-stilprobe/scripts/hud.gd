class_name Hud
extends CanvasLayer
## The small overlay: status, quality, light, landscape and the demo speed. Buttons fade out after a while,
## a tap brings them back.

signal quality_pressed
signal light_pressed
signal land_pressed
signal demo_step(delta: float)

var _root: Control
var _status: Label
var _sub: Label
var _quality: Button
var _light: Button
var _land: Button
var _fps: Label
var _controls: Control
var _demo: Control
var _demo_label: Label
var _loading: Control
var _idle := 0.0


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var info := PanelContainer.new()
	info.add_theme_stylebox_override("panel", _style(0.5))
	info.position = Vector2(20, 20)
	_root.add_child(info)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	info.add_child(col)
	col.add_child(_label("KVEST · Stilprobe", 20, Color(1, 0.86, 0.6)))
	_status = _label("", 18, Color.WHITE)
	col.add_child(_status)
	_sub = _label("", 14, Color(0.85, 0.88, 0.9))
	col.add_child(_sub)

	var right := VBoxContainer.new()
	right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	right.offset_left = -260
	right.offset_right = -20
	right.offset_top = 20
	right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right.add_theme_constant_override("separation", 8)
	_root.add_child(right)
	_controls = right
	_quality = _button("Qualität")
	_quality.pressed.connect(func(): quality_pressed.emit())
	right.add_child(_quality)
	_light = _button("Licht")
	_light.pressed.connect(func(): light_pressed.emit())
	right.add_child(_light)
	# the landscape: they take turns along the ride, or one of them on its own
	_land = _button("Landschaft")
	_land.pressed.connect(func(): land_pressed.emit())
	right.add_child(_land)
	_fps = _label("", 14, Color(0.9, 0.92, 0.94))
	_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_fps)

	var demo := HBoxContainer.new()
	demo.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	demo.offset_left = 20
	demo.offset_top = -78
	demo.offset_bottom = -20
	demo.add_theme_constant_override("separation", 8)
	_root.add_child(demo)
	_demo = demo
	var minus := _button("−")
	minus.custom_minimum_size = Vector2(58, 52)
	minus.pressed.connect(func(): demo_step.emit(-2.0))
	demo.add_child(minus)
	var lab := PanelContainer.new()
	lab.add_theme_stylebox_override("panel", _style(0.5))
	_demo_label = _label("", 18, Color.WHITE)
	lab.add_child(_demo_label)
	demo.add_child(lab)
	var plus := _button("+")
	plus.custom_minimum_size = Vector2(58, 52)
	plus.pressed.connect(func(): demo_step.emit(2.0))
	demo.add_child(plus)

	var cover := ColorRect.new()
	cover.color = Color(0.07, 0.09, 0.11, 1.0)
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(cover)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	cover.add_child(box)
	var t1 := _label("Kvest entsteht …", 30, Color(1, 0.86, 0.6))
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t1)
	var t2 := _label("Die Landschaft wird gebaut.", 18, Color(0.85, 0.88, 0.9))
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t2)
	_loading = cover


func _style(alpha: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.07, 0.09, alpha)
	s.set_corner_radius_all(16)
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.35))
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color(1, 0.86, 0.6))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, _style(0.62 if state == "pressed" else 0.5))
	b.custom_minimum_size = Vector2(0, 52)
	b.gui_input.connect(func(_e): _idle = 0.0)
	return b


func show_loading(on: bool) -> void:
	_loading.visible = on


func set_texts(status: String, sub: String, quality: String, light: String, land: String, fps: String, demo: String) -> void:
	_status.text = status
	_sub.text = sub
	_quality.text = quality
	_light.text = light
	_land.text = land
	_fps.text = fps
	_demo_label.text = demo
	if demo == "":
		_demo.visible = false


func _process(delta: float) -> void:
	_idle += delta
	var target := 1.0 if _idle < 8.0 else 0.0
	_controls.modulate.a = move_toward(_controls.modulate.a, target, delta * 2.0)
	_demo.modulate.a = _controls.modulate.a
	# hidden buttons must not catch the tap that brings them back
	var shown := _controls.modulate.a > 0.01
	_controls.visible = shown
	if _demo_label.text != "":
		_demo.visible = shown


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		_idle = 0.0
