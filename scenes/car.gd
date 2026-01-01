extends CharacterBody2D

# ------------------- Scale -------------------
@export var px_per_meter: float = 11.24

const G: float = 9.81

# Target: 150 km/h
@export var top_speed_kmh: float = 150.0

func top_speed_px_s() -> float:
	return (top_speed_kmh / 3.6) * px_per_meter # km/h -> m/s -> px/s

# ------------------- Vehicle geometry -------------------
@export var wheelbase_m: float = 2.7
@export var wheelbase: float = 2.7 * 11.24 # overwritten in _ready() to keep in sync

# ------------------- Controls -------------------
@export var max_steer_deg: float = 28.0
@export var steer_response: float = 12.0

# ------------------- Longitudinal dynamics (in m/s^2, converted) -------------------
@export var max_accel_mps2: float = 4           # "EV-ish" full throttle accel
@export var max_brake_mps2: float = 1.2 * G        # ~1G braking
@export var regen_mps2: float = 1.0                # ~1 m/s^2 regen

@export var coast_friction_mps2: float = 0.15      # rolling resistance-ish (constant)
# Linear drag: a_drag = drag_k * v  (drag_k has units 1/s)
@export var drag_k_per_s: float = 0.084            # tuned for ~150 km/h with max_accel_mps2

# ------------------- Handling -------------------
@export var lateral_grip: float = 10.0
@export var min_speed_for_steer_mps: float = 0.1   # m/s
@export var regen_throttle_deadzone: float = 0.08

# Internals (px units)
var max_accel: float
var max_brake_decel: float
var regen_decel: float
var coast_friction_decel: float
var drag_decel_per_speed: float
var min_speed_for_steer: float

enum Gear { P, R, N, D }
var gear: Gear = Gear.P
var _steer_angle: float = 0.0

func _ready() -> void:
	# Keep px versions synced to meter versions
	wheelbase = wheelbase_m * px_per_meter

	max_accel = max_accel_mps2 * px_per_meter
	max_brake_decel = max_brake_mps2 * px_per_meter
	regen_decel = regen_mps2 * px_per_meter
	coast_friction_decel = coast_friction_mps2 * px_per_meter

	# since v is px/s, and a is px/s^2, drag_decel_per_speed should be 1/s
	drag_decel_per_speed = drag_k_per_s

	min_speed_for_steer = min_speed_for_steer_mps * px_per_meter

	gear = Gear.P

	# Optional: print computed top speed in px/s for sanity
	# print("Target top speed px/s:", top_speed_px_s())

func _physics_process(delta: float) -> void:
	_handle_gear_shift()

	var throttle_in := _get_throttle() # 0..1
	var brake_in := _get_brake()       # 0..1
	var steer_in := _get_steer()       # -1..1

	# Steering
	var max_steer := deg_to_rad(max_steer_deg)
	var target_steer := steer_in * max_steer
	_steer_angle = lerp(_steer_angle, target_steer, 1.0 - exp(-steer_response * delta))

	# Local basis (you rotated sprite/collider, so forward is +X on the body)
	var forward := global_transform.x.normalized()
	var right := global_transform.y.normalized()

	var v_world := velocity
	var v_fwd := v_world.dot(forward)
	var v_lat := v_world.dot(right)
	var speed := v_world.length()

	# Lateral grip (kills sideways slip)
	var lat_damp := 1.0 - exp(-lateral_grip * delta)
	v_lat = lerp(v_lat, 0.0, lat_damp)

	# Longitudinal accel along forward axis
	var a_fwd := 0.0

	if gear == Gear.P:
		velocity = Vector2.ZERO
		_steer_angle = 0.0
		move_and_slide()
		return

	# Throttle
	if gear == Gear.D:
		a_fwd += throttle_in * max_accel
	elif gear == Gear.R:
		a_fwd -= throttle_in * max_accel
	# N: no drive force

	# Brake (oppose motion)
	if brake_in > 0.0 and absf(v_fwd) > 0.01:
		a_fwd += -signf(v_fwd) * (brake_in * max_brake_decel)

	# Regen (only D/R, no brake, low throttle)
	var regen_allowed := (gear == Gear.D or gear == Gear.R) and throttle_in < regen_throttle_deadzone
	if regen_allowed and absf(v_fwd) > 0.01 and brake_in <= 0.01:
		a_fwd += -signf(v_fwd) * regen_decel

	# Coast friction (constant)
	if speed > 0.01:
		a_fwd += -signf(v_fwd) * coast_friction_decel

	# Linear drag (a = k * v)
	if speed > 0.01:
		a_fwd += -signf(v_fwd) * (drag_decel_per_speed * absf(v_fwd))

	# Avoid jittering through 0 from passive decel
	var dv_fwd := a_fwd * delta
	if absf(v_fwd) < absf(dv_fwd) and _is_passive_decel_only(throttle_in, brake_in):
		v_fwd = 0.0
	else:
		v_fwd += dv_fwd

	# Yaw from bicycle model
	if absf(v_fwd) > min_speed_for_steer:
		var yaw_rate := (v_fwd / wheelbase) * tan(_steer_angle)
		rotation += yaw_rate * delta

	# Recompute basis after rotation change
	forward = global_transform.x.normalized()
	right = global_transform.y.normalized()

	velocity = forward * v_fwd + right * v_lat
	move_and_slide()

func _is_passive_decel_only(throttle_in: float, brake_in: float) -> bool:
	if brake_in > 0.01:
		return false
	if gear == Gear.D and throttle_in > 0.01:
		return false
	if gear == Gear.R and throttle_in > 0.01:
		return false
	return true

# ------------------- Inputs -------------------

func _get_throttle() -> float:
	return clampf(Input.get_action_strength("throttle"), 0.0, 1.0)

func _get_brake() -> float:
	return clampf(Input.get_action_strength("brake"), 0.0, 1.0)

func _get_steer() -> float:
	return clampf(Input.get_axis("steer_left", "steer_right"), -1.0, 1.0)

func _handle_gear_shift() -> void:
	if Input.is_action_just_pressed("gear_up"):
		gear = clampi(int(gear) + 1, int(Gear.P), int(Gear.D))
	if Input.is_action_just_pressed("gear_down"):
		gear = clampi(int(gear) - 1, int(Gear.P), int(Gear.D))
