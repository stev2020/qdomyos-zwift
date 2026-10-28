class_name Rider
extends RefCounted
## Moves the camera along the path at the speed of the bike (or the demo speed), at eye height.

const EYE := 1.75
const LOOK_AHEAD := 16.0

var u := 0.0          ## absolute distance along the main direction (metres)
var speed := 0.0      ## m/s, smoothed
var ridden := 0.0     ## metres ridden in this session
var _look := Vector3.FORWARD
var _bob := 0.0


func advance(dt: float, target_kmh: float) -> void:
	var target := maxf(target_kmh, 0.0) / 3.6
	speed += (target - speed) * (1.0 - exp(-dt / 1.1))
	var dx := Land.path_dx(u)
	var ds := speed * dt
	u += ds / sqrt(1.0 + dx * dx)
	ridden += ds
	_bob += ds


func place(cam: Camera3D, origin_u: float, dt: float, snap: bool) -> void:
	var pos := Vector3(Land.path_x(u), Land.path_height(u) - 0.05 + EYE + sin(_bob * TAU / 2.4) * 0.012, -(u - origin_u))
	var la := u + LOOK_AHEAD
	var target := Vector3(Land.path_x(la), Land.path_height(la) + EYE - 0.6, -(la - origin_u))
	var dir := (target - pos).normalized()
	if snap or dt <= 0.0:
		_look = dir
	else:
		_look = _look.slerp(dir, 1.0 - exp(-dt / 0.6)).normalized()
	cam.global_transform = Transform3D(Basis.looking_at(_look, Vector3.UP), pos)
