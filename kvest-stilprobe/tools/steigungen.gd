extends SceneTree
## Misst die Steigungen entlang des Wegs, je Landschaft und im Wechsel (die Tabelle in docs/landschaften.md).
## Aufruf im Ordner kvest-stilprobe: godot --headless --path . -s res://tools/steigungen.gd

const STEP := 5.0


func _init() -> void:
	Land.init()
	for k in Land.KINDS:
		Land.mode = k
		_measure(Land.NAMES[k], 60000.0)
	Land.mode = -1
	_measure("im Wechsel", 96000.0)
	quit()


## Steigung über 100 m gemittelt: der Wert, den die Hälfte der Strecke nicht erreicht, 9 von 10 Stellen und der höchste;
## dazu die Höhenmeter bergauf je km und der Höhenunterschied.
func _measure(name: String, length: float) -> void:
	var hs := PackedFloat64Array()
	var dist := PackedFloat64Array()
	var d := 0.0
	var prev := Land.path_x(0.0)
	var u := 0.0
	while u <= length:
		var px := Land.path_x(u)
		if u > 0.0:
			d += sqrt(STEP * STEP + (px - prev) * (px - prev))
		prev = px
		hs.append(Land.path_height(u))
		dist.append(d)
		u += STEP
	var k := int(100.0 / STEP)
	var g := []
	for i in range(0, hs.size() - k):
		g.append(absf(hs[i + k] - hs[i]) / (dist[i + k] - dist[i]) * 100.0)
	g.sort()
	var n := g.size()
	var up := 0.0
	var lo := INF
	var hi := -INF
	for i in hs.size():
		lo = minf(lo, hs[i])
		hi = maxf(hi, hs[i])
		if i > 0:
			up += maxf(0.0, hs[i] - hs[i - 1])
	print("%-12s meist %.1f %%, 9 von 10 unter %.1f %%, höchstens %.1f %%, %.0f Hm/km, Höhenunterschied %.0f m" % [
		name, g[n / 2], g[n * 9 / 10], g[n - 1], up / (d / 1000.0), hi - lo])
