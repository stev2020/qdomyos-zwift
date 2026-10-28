class_name Link
extends RefCounted
## Listens to Kvestrun (or QZ) on the same device. Both apps send the values of the ride once a
## second to every WebSocket client of their built-in web server:
## {"msg": "workout", "content": {"speed": km/h, "watts": ..., "cadence": ..., ...}}
## Kvestrun listens on port 6680, QZ on 6666.

const PORTS := [6680, 6666]

var speed_kmh := 0.0
var watts := 0.0
var cadence := 0.0
var app := ""
## What the last attempt on each port found: "" (not tried yet), "offen", "zu" (refused at once:
## nothing listens there) or "still" (no answer: the app is there but paused, e.g. by Android)
var port_state := {6680: "", 6666: ""}

var _ws := WebSocketPeer.new()
var _state := "wait"      # wait | connecting | open
var _port := 0
var _retry_at := 0
var _started := 0
var _last_data := -100000


func poll() -> void:
	var now := Time.get_ticks_msec()
	if _state == "wait":
		if now < _retry_at:
			return
		_ws = WebSocketPeer.new()
		_ws.inbound_buffer_size = 1 << 18
		if _ws.connect_to_url("ws://127.0.0.1:%d/kvest-ws" % PORTS[_port]) == OK:
			_state = "connecting"
			_started = now
		else:
			_next(now)
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_state = "open"
			port_state[PORTS[_port]] = "offen"
			app = "Kvestrun" if PORTS[_port] == 6680 else "QZ"
			while _ws.get_available_packet_count() > 0:
				_handle(_ws.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CONNECTING:
			if now - _started > 4000:
				port_state[PORTS[_port]] = "still"
				_ws.close()
				_next(now)
		WebSocketPeer.STATE_CLOSED:
			if _state != "open":
				port_state[PORTS[_port]] = "zu" if now - _started < 1500 else "still"
			_next(now)


func _next(now: int) -> void:
	_state = "wait"
	_port = (_port + 1) % PORTS.size()
	_retry_at = now + 1500


func _handle(text: String) -> void:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or data.get("msg", "") != "workout":
		return
	var c = data.get("content")
	if typeof(c) != TYPE_DICTIONARY:
		return
	speed_kmh = float(c.get("speed", 0.0))
	watts = float(c.get("watts", 0.0))
	cadence = float(c.get("cadence", 0.0))
	_last_data = Time.get_ticks_msec()


func connected() -> bool:
	return _state == "open"


func has_data() -> bool:
	return Time.get_ticks_msec() - _last_data < 4000


## A short explanation for the overlay when there is no connection.
func diagnosis() -> String:
	var k: String = port_state[6680]
	if k == "still":
		return "Kvestrun antwortet nicht. Läuft das Rad dort, oder hat Android die App pausiert?"
	if k == "zu":
		return "Kvestrun ist nicht geöffnet (Port 6680 zu)"
	return "Suche Kvestrun …"
