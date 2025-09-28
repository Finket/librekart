extends CharacterBody3D

enum FloorTypes { ROAD, OFFROAD, BOOST }

@onready var track : GridMap = $"../TrackGridMap"
@onready var camera : Node3D = $CameraHolder

@onready var boost_timer : Timer = $"../BoostTimer"
var drift_timer : float = 0.0

# No default value means left TODO
var top_speed : float = 12.0
var acceleration : float = 10.0
var handling : float = 1.1
var weight : float = 0.9
var drift_power : float = 2.0

var max_speed : float = top_speed # CURRENT top speed considering boosts

var gas_strength : float = 0.0
var turn_strength : float = 0.0
var look_strength : float = 0.0
var floor_type : FloorTypes = FloorTypes.ROAD

var turn_offset : float = 0.0 # From exiting drifts etc.

var drifting : int = 0
var looking : bool = false
var reversing : bool = false
var bogged : bool = false # Going too slow for some interactions

var base_camera_rotation : float = 0.0
var target_camera_rotation : float = 0.0

var default_friction : float = 20.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	boost_timer.timeout.connect(end_boost)

# We use _input to allow controlling in menus for quick driving settings fixes.
# Switch to _unhandled_input if this sucks during gameplay.
# TODO: Steering (and maybe gas) smoothing for keyboard players.
func _input(event : InputEvent) -> void:
		if event.is_action_pressed("hop"):
			hop()
		
		if event.is_action_pressed("drift"):
			drift(true)
		if event.is_action_released("drift"):
			drift(false)
		
		if event.is_action_pressed("look_back"):
			looking = true
			camera.rotation.y = PI
		if event.is_action_released("look_back"):
			looking = false
			camera.rotation.y = base_camera_rotation
		if event.is_action_pressed("look_left"):
			looking = true
			camera.rotation.y = 2*PI/3
		if event.is_action_released("look_left"):
			looking = false
			camera.rotation.y = base_camera_rotation
		if event.is_action_pressed("look_right"):
			looking = true
			camera.rotation.y = -2*PI/3
		if event.is_action_released("look_right"):
			looking = false
			camera.rotation.y = base_camera_rotation

func end_boost() -> void:
	max_speed = top_speed
	print('boost stopped')

func hop() -> void:
	if not is_on_floor():
		return
	velocity.y += 8.0 * handling / weight

func drift(enter_drift : bool = true) -> void:
	# Exit drift state
	if drifting != 0 and not enter_drift:
		# Rotate vehicle back a bit
		turn_offset = target_camera_rotation
		target_camera_rotation = 0.0
		
		boost_timer.wait_time = minf(drift_timer, 2.0)
		boost_timer.start()
		max_speed = top_speed * 2 # double the top speed for drift duration for now
		drift_timer = 0.0
		print('drift boosting for ', boost_timer.wait_time, 's')
		
	if not enter_drift:
		drifting = 0
		return
	
	# Do not allow drifting in reverse or at slow speeds
	if reversing:
		drifting = 0
		return
	if bogged:
		drifting = 0
		return
	
	if turn_strength < 0.0:
		drifting = -1
	elif turn_strength > 0.0:
		drifting = 1
	else:
		drifting = 0
	
	if is_on_floor():
		hop()

func turn(delta : float) -> void:
	var invert_reverse : bool = true
	
	var horizontal_velocity : Vector3 = Vector3(velocity.x, 0, velocity.z)
	var horizontal_speed : float = horizontal_velocity.length()
	
	#var turn_angle : float = turn_strength * handling * delta * (horizontal_speed / top_speed)
	var turn_angle : float = turn_strength * handling * delta if drifting == 0 else (turn_strength + drifting * 1.25) * handling * delta
	
	if turn_offset != 0:
		turn_angle -= turn_offset * delta
		turn_offset = move_toward(turn_offset, 0.0, handling * delta)
	
	target_camera_rotation = 0.0 if not drifting else -turn_angle * 8.0
	
	if reversing and invert_reverse:
		turn_angle *= -1.0
	
	rotation.y += turn_angle
	
	var rotation_factor : float = 0.5 if drifting else 0.8
	horizontal_velocity = horizontal_velocity.rotated(Vector3.UP, turn_angle * rotation_factor)
	
	# Velocity correction when finishing a drift
	if turn_offset != 0.0 or (not drifting and abs(target_camera_rotation) > 0.0):
		horizontal_velocity = horizontal_velocity.slerp(global_transform.basis.z * horizontal_speed, 16.0 * delta)
	
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

func gas(delta : float) -> void:
	var new_velocity : Vector3 = velocity + global_transform.basis.z * acceleration * gas_strength * delta
	
	if gas_strength > 0.0:
		velocity = new_velocity.limit_length(max_speed)
	elif gas_strength < 0.0:
		velocity = new_velocity.limit_length(max_speed / 2.0)
	
	if Vector3(velocity.x, 0, velocity.z).dot(global_transform.basis.z) < 0.0:
		reversing = true
	else:
		reversing = false

func apply_gravity(delta : float):
	if not is_on_floor():
		velocity.y -= 9.8 * 8.0 * delta

func apply_friction(delta : float):
	if not is_on_floor():
		return
	
	var horizontal_velocity : Vector3 = Vector3(velocity.x, 0, velocity.z)
	
	var friction : float = default_friction
	var cap : float = max_speed
	match floor_type:
		FloorTypes.ROAD:
			friction = default_friction
		FloorTypes.OFFROAD:
			friction = default_friction * 2.0
			cap = max_speed / 4.0
		FloorTypes.BOOST:
			friction = default_friction / 2.0
			cap = top_speed * 2.0 # top_speed to avoid stacking boosts
	
	if drifting:
		friction *= 0.5
	
	if horizontal_velocity.length() > cap:
		horizontal_velocity = horizontal_velocity.move_toward(horizontal_velocity.limit_length(cap), friction * delta)
	elif gas_strength == 0.0:
		horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, friction * delta)
	
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

func check_floor() -> void:
	var cell : Vector3i = track.local_to_map(global_transform.origin)
	var tile_id : int = track.get_cell_item(cell)
	
	if tile_id != -1:
		var tile_name : String = track.mesh_library.get_item_name(tile_id)
		
		match tile_name:
			"Road":
				floor_type = FloorTypes.ROAD
			"SlopedRoad":
				floor_type = FloorTypes.ROAD
			"Offroad":
				floor_type = FloorTypes.OFFROAD
			"SlopedOffroad":
				floor_type = FloorTypes.OFFROAD
			"Boost":
				floor_type = FloorTypes.BOOST
	pass

func free_look() -> void:
	var look_sensitivity : float = 10.0
	var deadzone : float = 0.01
	
	var look_input : Vector2 = Vector2(
		Input.get_action_strength("look_right_analog") - Input.get_action_strength("look_left_analog"),
		Input.get_action_strength("look_backward_analog") - Input.get_action_strength("look_forward_analog")
	)
	
	if look_input.length_squared() > deadzone:
		var stick_angle : float = atan2(-look_input.x, -look_input.y)
		camera.rotation.y = stick_angle
	else:
		camera.rotation.y = base_camera_rotation

func _physics_process(delta: float) -> void:
	check_floor()
	
	gas_strength = Input.get_action_strength("gas") - Input.get_action_strength("brake")
	turn_strength = Input.get_action_strength("left") - Input.get_action_strength("right")
	
	if turn_strength != 0.0 or drifting != 0 or turn_offset != 0.0:
		turn(delta)
	
	if gas_strength != 0.0:
		gas(delta)
	
	# Going too slow for some interactions
	if velocity.length_squared() <= max_speed / 2.0:
		bogged = true
	else:
		bogged = false
	
	if reversing:
		if velocity == Vector3.ZERO:
			reversing = false
	
	if drifting != 0:
		drift_timer += delta
	
	apply_gravity(delta)
	apply_friction(delta)
	
	move_and_slide()

func _process(delta: float) -> void:
	if reversing:
		base_camera_rotation = lerp(camera.rotation.y, target_camera_rotation - PI, 10.0 * delta)
	else:
		base_camera_rotation = lerp(camera.rotation.y, target_camera_rotation, 10.0 * delta)
	
	if not looking:
		free_look()
