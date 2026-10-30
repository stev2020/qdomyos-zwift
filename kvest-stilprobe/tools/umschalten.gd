extends SceneTree
## Startet die Stilprobe, fährt im Demo-Tempo und schaltet Landschaft und Qualität durch. Dabei zählt es die gezeigten
## Kiesel und prüft in jedem Bild, dass jeder Block von Bäumen und Felsen die richtigen Modelle zeigt (World._fade_lods).
## Aufruf im Ordner kvest-stilprobe (braucht eine Grafik, am Rechner ohne Bildschirm mit xvfb):
##   godot --path . --resolution 1280x720 -s res://tools/umschalten.gd
## Erwartet: zum Schluss „OK; gefahren … m“, keine Zeile mit „FEHLER“.

var main: Node
var frames := 0
var presses := 0
var waiting := 0
var wrong := 0


func _init() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func _count() -> String:
	var pieces := 0
	var shown := 0
	var total := 0
	for iu in main.world.rows:
		var list = main.world.rows[iu].get("pebbles")
		if list == null:
			continue
		for p in list:
			pieces += 1
			total += p["mmi"].multimesh.instance_count
			if p["mmi"].visible:
				shown += p["mmi"].multimesh.visible_instance_count
	return "Kiesel-Stücke %d, gezeigt %d von %d" % [pieces, shown, total]


## Die Modelle eines Blocks, die gerade kommen, sind sichtbar; die anderen nur, solange der Wechsel läuft.
func _check_blocks() -> void:
	for key in main.world.blocks:
		var b: Dictionary = main.world.blocks[key]
		if not b.has("near"):
			continue
		var coming: Array = b["near"] if b["lod"] == 0 else b["far"]
		var going: Array = b["far"] if b["lod"] == 0 else b["near"]
		for m in coming:
			if is_instance_valid(m) and not m.visible:
				wrong += 1
		for m in going:
			if is_instance_valid(m) and m.visible != (b["mix"] < 1.0):
				wrong += 1


func _process(_dt: float) -> bool:
	frames += 1
	if frames > 30000:
		print("FEHLER: Zeitüberschreitung")
		return true
	if main._loading:
		waiting += 1
		return false
	if waiting > 0:
		print("Aufbau fertig nach %d Bildern, Landschaft %d, Qualität %s, %s; %s" % [waiting, main.land, main.quality, Land.NAMES[Land.kind_at(main.rider.u)], _count()])
		waiting = 0
	_check_blocks()
	if presses >= 9:
		if wrong > 0:
			print("FEHLER: %d Mal zeigte ein Block die falschen Bäume" % wrong)
		print("OK; gefahren %.0f m; %s" % [main.rider.ridden, _count()])
		return true
	if frames % 40 == 0:
		if presses % 2 == 0:
			main._on_land()
		else:
			main._on_quality()
			print("Qualität jetzt %s: %s" % [main.quality, _count()])
		presses += 1
	return false
