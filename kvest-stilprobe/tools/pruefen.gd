extends SceneTree
## Prüft die Formeln von Land über 50 km: Die Anteile der Landschaften ergeben zusammen 1, die Höhen sind endlich und
## ohne Sprünge, der Boden am Weg liegt auf Weghöhe, und das Wasser liegt nirgends über dem Weg.
## Aufruf im Ordner kvest-stilprobe: godot --headless --path . -s res://tools/pruefen.gd
## Erwartet: „Fehler: 0“ und „Stellen mit Wasser über dem Weg: 0“.

func _init() -> void:
	Land.init()
	Land.mode = -1
	var bad := 0
	var prev_h := Land.path_height(-100.0)
	var max_jump := 0.0
	var water_over_path := 0
	var u := -100.0
	while u < 50000.0:
		var r := Land.row(u)
		var s := 0.0
		var sr := 0.0
		for k in Land.KINDS:
			s += r[Land.W + k]
			sr += r[Land.RW + k]
		if absf(s - 1.0) > 1e-5 or absf(sr - 1.0) > 1e-5:
			bad += 1
		var h: float = r[2]
		if is_nan(h) or is_inf(h):
			bad += 1
		max_jump = maxf(max_jump, absf(h - prev_h))
		prev_h = h
		if r[Land.SW] > 0.05 and r[5] > h - 0.2 and absf(r[3] - r[0]) * r[1] < 14.0:
			water_over_path += 1
		# der Boden direkt am Weg liegt auf Weghöhe
		var g := Land.height(r[0], u, r)
		if absf(g - (h - 0.05)) > 0.001:
			bad += 1
		u += 1.0
	print("Fehler: ", bad, "  größter Höhensprung je 1 m: %.3f m" % max_jump, "  Stellen mit Wasser über dem Weg (Fluss < 14 m): ", water_over_path)
	quit()
