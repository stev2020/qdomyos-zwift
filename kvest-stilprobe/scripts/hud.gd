class_name Hud
extends CanvasLayer
## The small overlay: status, quality, light, landscape and the demo speed. Buttons fade out after a while,
## a tap brings them back.

signal quality_pressed
signal light_pressed
signal land_pressed
signal demo_step(delta: float)
## the light panel: one value of the light mood changed, compare with the mood before the round on light and colour,
## back to the stored mood, switch the tone mapper, copy the values
signal look_changed(key: String, value: float)
signal look_compare
signal look_reset
signal look_tonemap
signal look_copy

## The sliders of the light panel: key in the light mood (LOOKS in main.gd), name, smallest and largest value.
const LOOK_SLIDERS := [
	["sun", "Sonne", 0.5, 5.0],
	["warmth", "Wärme der Sonne", 0.0, 2.0],
	["ambient", "Licht im Schatten", 0.0, 1.2],
	["shadow", "Schatten deckt", 0.0, 1.0],
	["exposure", "Belichtung", 0.3, 1.6],
	["sky_energy", "Himmel hell", 0.6, 2.5],
	["saturation", "Sättigung", 0.6, 1.6],
	["contrast", "Kontrast", 0.8, 1.3],
	["haze", "Dunst", 0.0, 3.0],
	["scatter", "Dunst leuchtet zur Sonne", 0.0, 1.2],
	["glow", "Leuchten", 0.0, 2.0],
	["foot", "Gras unten (klein = dunkel)", 0.1, 1.0],
	["ground", "Boden zwischen dem Gras", 0.2, 1.2],
	["crown", "Kronen innen dunkel", 0.5, 4.0],
	["leaf_wrap", "Kronen weich", 0.1, 1.2],
	["leaf_glow", "Sonne durch die Blätter", 0.0, 0.8],
]

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
var _look_button: Button
var _look_panel: Control
var _look_title: Label
var _compare: Button
var _tonemap: Button
var _sliders := {}
var _slider_values := {}
var _quiet := false


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
	_look_button = _button("Licht-Regler")
	_look_button.pressed.connect(func(): _look_panel.visible = not _look_panel.visible)
	right.add_child(_look_button)
	_fps = _label("", 14, Color(0.9, 0.92, 0.94))
	_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_fps)
	_make_look_panel()

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


## The light panel on the left: a slider for each value of the light mood, and buttons to compare with the mood before
## the round on light and colour, to go back to the stored mood, for the tone mapper and to copy the values.
func _make_look_panel() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(0.62))
	panel.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	panel.offset_left = 20
	panel.offset_right = 440
	panel.offset_top = 130
	panel.offset_bottom = -90
	panel.visible = false
	_root.add_child(panel)
	_look_panel = panel
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	scroll.add_child(col)
	_look_title = _label("", 18, Color(1, 0.86, 0.6))
	col.add_child(_look_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	_compare = _button("Vorher zeigen")
	_compare.pressed.connect(func(): look_compare.emit())
	row.add_child(_compare)
	var reset := _button("Zurück")
	reset.pressed.connect(func(): look_reset.emit())
	row.add_child(reset)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	col.add_child(row2)
	_tonemap = _button("Filmic")
	_tonemap.pressed.connect(func(): look_tonemap.emit())
	row2.add_child(_tonemap)
	var copy := _button("Werte kopieren")
	copy.pressed.connect(func(): look_copy.emit())
	row2.add_child(copy)
	for entry in LOOK_SLIDERS:
		var key: String = entry[0]
		var name_label := _label(entry[1], 15, Color(0.92, 0.94, 0.96))
		col.add_child(name_label)
		var slider := HSlider.new()
		slider.min_value = entry[2]
		slider.max_value = entry[3]
		slider.step = 0.01
		slider.custom_minimum_size = Vector2(360, 34)
		slider.focus_mode = Control.FOCUS_NONE
		slider.value_changed.connect(func(v: float): _on_slider(key, v))
		slider.gui_input.connect(func(_e): _idle = 0.0)
		col.add_child(slider)
		_sliders[key] = slider
		_slider_values[key] = name_label
		name_label.set_meta("name", entry[1])


func _on_slider(key: String, v: float) -> void:
	_idle = 0.0
	var l: Label = _slider_values[key]
	l.text = "%s: %s" % [l.get_meta("name"), ("%.2f" % v).replace(".", ",")]
	if not _quiet:
		look_changed.emit(key, v)


## Shows the values of the current light mood in the panel, without sending them back.
func show_look(look: Dictionary, title: String, vorher: bool) -> void:
	_quiet = true
	for key in _sliders:
		if look.has(key):
			_sliders[key].value = look[key]
			_on_slider(key, float(look[key]))
	_quiet = false
	_look_title.text = title
	_compare.text = "Neu zeigen" if vorher else "Vorher zeigen"
	_tonemap.text = "Tonemapper: " + ("AgX" if look["tonemap"] == "agx" else "Filmic")


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
	# while the light panel is open the buttons stay; the button "Licht-Regler" closes it again
	var target := 1.0 if _idle < 8.0 or _look_panel.visible else 0.0
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
