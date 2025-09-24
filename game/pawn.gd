extends CharacterBody2D
class_name Unit

@export var speed := 300.0
var target = null

enum Policy { IDLE, CHASE_MOUSE, PATROL }
@export var policy: Policy = Policy.CHASE_MOUSE

# Patrol points for the PATROL policy
@export var patrol_points: Array[Vector2] = []
@export var patrol_tolerance := 5.0
var _patrol_i := 0

func _input(event):
	if event.is_action_pressed("set_target"):
		target = get_global_mouse_position()
		patrol_points.append(target)
	if event.is_action_pressed("policy_idle"):
		policy = Policy.IDLE
	if event.is_action_pressed("policy_chase"):
		policy = Policy.CHASE_MOUSE
	if event.is_action_pressed("policy_patrol"):
		policy = Policy.PATROL
		patrol_points = []
		patrol_points.append(position)

func _physics_process(delta: float) -> void:
	# --- run policy every tick ---
	match policy:
		Policy.IDLE:
			_tick_idle(delta)
		Policy.CHASE_MOUSE:
			_tick_chase_mouse(delta)
		Policy.PATROL:
			_tick_patrol(delta)
	# --- move + animate (shared) ---
	velocity = velocity.normalized() * speed
	move_and_collide(velocity * delta)
	if velocity != Vector2.ZERO:
		$AnimationPlayer.play("running")
		$idle.visible = false
		$running.visible = true
	else:
		$AnimationPlayer.play("idle")
		$idle.visible = true
		$running.visible = false

# ------------------ policies ------------------

func _tick_idle(_delta: float) -> void:
	velocity = Vector2.ZERO
	target = null

func _tick_chase_mouse(_delta: float) -> void:
	if target != null:
		var dir := global_position.direction_to(target)
		velocity = dir
		if global_position.distance_squared_to(target) < 50.0:
			target = null
			velocity = Vector2.ZERO
	else:
		velocity = Vector2.ZERO

func _tick_patrol(_delta: float) -> void:
	if patrol_points.is_empty():
		velocity = Vector2.ZERO
		return
	var goal := patrol_points[_patrol_i]
	var to_goal := goal - global_position
	if to_goal.length() <= patrol_tolerance:
		_patrol_i = (_patrol_i + 1) % patrol_points.size()
	else:
		velocity = to_goal.normalized() * speed
