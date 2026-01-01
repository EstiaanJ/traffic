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

# ------------------- Sensors -------------------
@export var ray_length_m: float = 30.0
@export var sweep_arc_deg: float = 120.0
@export var sweep_frequency_hz: float = 2.0

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

# ------------------- Telemetry -------------------
@export var telemetry_enabled: bool = true
@export var telemetry_host: String = "127.0.0.1"
@export var telemetry_port: int = 5050

# Internals (px units)
var max_accel: float
var max_brake_decel: float
var regen_decel: float
var coast_friction_decel: float
var drag_decel_per_speed: float
var min_speed_for_steer: float
var ray_length_px: float

enum Gear { P, R, N, D }
var gear: Gear = Gear.P
var _steer_angle: float = 0.0
var _sweep_phase: float = 0.0

@onready var _forward_ray: RayCast2D = $Raycasts/Forward
@onready var _left_ray: RayCast2D = $Raycasts/Left5
@onready var _right_ray: RayCast2D = $Raycasts/Right5
@onready var _sweep_ray: RayCast2D = $Raycasts/Sweep

var _tcp := StreamPeerTCP.new()

func _ready() -> void:
        # Keep px versions synced to meter versions
        wheelbase = wheelbase_m * px_per_meter

        ray_length_px = ray_length_m * px_per_meter

	max_accel = max_accel_mps2 * px_per_meter
	max_brake_decel = max_brake_mps2 * px_per_meter
	regen_decel = regen_mps2 * px_per_meter
	coast_friction_decel = coast_friction_mps2 * px_per_meter

	# since v is px/s, and a is px/s^2, drag_decel_per_speed should be 1/s
        drag_decel_per_speed = drag_k_per_s

        min_speed_for_steer = min_speed_for_steer_mps * px_per_meter

        gear = Gear.P

        _configure_raycasts()

        # Optional: print computed top speed in px/s for sanity
        # print("Target top speed px/s:", top_speed_px_s())

func _physics_process(delta: float) -> void:
        _handle_gear_shift()

        var throttle_in := _get_throttle() # 0..1
        var brake_in := _get_brake()       # 0..1
        var steer_in := _get_steer()       # -1..1

        _update_sweep_ray(delta)

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

        _send_telemetry(speed / px_per_meter, throttle_in, brake_in, steer_in)

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

func _configure_raycasts() -> void:
        for ray in [_forward_ray, _left_ray, _right_ray, _sweep_ray]:
                ray.target_position = Vector2(ray_length_px, 0.0)
                ray.enabled = true

func _update_sweep_ray(delta: float) -> void:
        _sweep_phase = wrapf(_sweep_phase + delta * sweep_frequency_hz * TAU, 0.0, TAU)
        var half_arc := deg_to_rad(sweep_arc_deg * 0.5)
        _sweep_ray.rotation = sin(_sweep_phase) * half_arc
        _sweep_ray.force_raycast_update()

func _ray_distance_m(ray: RayCast2D) -> float:
        if not ray.is_colliding():
                return -1.0
        return ray.global_position.distance_to(ray.get_collision_point()) / px_per_meter

func _connect_telemetry() -> void:
        if not telemetry_enabled:
                return

        var status := _tcp.get_status()
        if status == StreamPeerTCP.STATUS_CONNECTING or status == StreamPeerTCP.STATUS_CONNECTED:
                return

        var err := _tcp.connect_to_host(telemetry_host, telemetry_port)
        if err != OK:
                _tcp.disconnect_from_host()

func _send_telemetry(speed_mps: float, throttle_in: float, brake_in: float, steer_in: float) -> void:
        if not telemetry_enabled:
                return

        _connect_telemetry()
        _tcp.poll()
        if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
                return

        _tcp.set_no_delay(true)

        _forward_ray.force_raycast_update()
        _left_ray.force_raycast_update()
        _right_ray.force_raycast_update()
        _sweep_ray.force_raycast_update()

        var forward_hit_m := _ray_distance_m(_forward_ray)
        var left_hit_m := _ray_distance_m(_left_ray)
        var right_hit_m := _ray_distance_m(_right_ray)
        var sweep_hit_m := _ray_distance_m(_sweep_ray)
        var sweep_angle_deg := rad_to_deg(_sweep_ray.rotation)

        var payload := "speed_mps=%f|throttle=%f|brake=%f|steering=%f|forward_hit_m=%f|left_hit_m=%f|right_hit_m=%f|sweep_hit_m=%f|sweep_angle_deg=%f\n"
        payload = payload % [speed_mps, throttle_in, brake_in, steer_in, forward_hit_m, left_hit_m, right_hit_m, sweep_hit_m, sweep_angle_deg]

        _tcp.put_data(payload.to_utf8_buffer())
