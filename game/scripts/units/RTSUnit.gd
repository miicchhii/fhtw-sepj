# RTSUnit.gd
extends CharacterBody2D
class_name RTSUnit

@export var is_enemy: bool = false   # same scene, different faction

@export var unit_id: String = "u1"
@export var type_id: int = 0
@export var max_hp: int = 100
var hp: int = max_hp

# simple combat
var attack_target: Node = null
@export var attack_range := 64.0        # must be inside this to hit
@export var attack_damage := 15
@export var attack_cooldown := 0.8
var _atk_cd := 0.0


@export var selected = false
@onready var box = get_node("Box")
@onready var anim = get_node("AnimationPlayer")
@onready var target_click = position

@onready var hp_bar := $HPBar if has_node("HPBar") else null


var follow_cursor = false
var Speed = 50

var target: Vector2

func _ready() -> void:
	# mark enemies and keep them unselectable
	if is_enemy:
		add_to_group("enemy")
		# Enemies are not selectable / don’t respond to player input
		selected = false
		set_selected(selected)
		# tint enemy red
		modulate = Color(1.0, 0.314, 0.335, 1.0)   # light red shade
	# keep the rest of your existing _ready() content
	_update_hp_bar()
	
	set_selected(selected)
	add_to_group("units", true)
	hp = max_hp
	target = global_position

func set_move_target(p: Vector2) -> void:
	target = p

func step(delta: float) -> void:
	var dir := (target - global_position)
	if dir.length() > 1.0:
		dir = dir.normalized()
		velocity = dir * 1000.0
	else:
		velocity = Vector2.ZERO
	move_and_slide()

#new code - lukas
func set_selected(value):
	selected = value
	box.visible = value

func _input(event):
	if is_enemy:
		return
	if event.is_action_pressed("RightClick"):
		follow_cursor = true
	if event.is_action_released("RightClick"):
		follow_cursor = false
		
func _physics_process(delta):
	if follow_cursor == true:
		if selected:
			target_click = get_global_mouse_position()
			anim.play("Walk")
	velocity = position.direction_to(target_click) *Speed
	
	if position.distance_to(target_click) > 10:
		move_and_slide()
	else:
		anim.stop()
		
		# --- Auto-attack ONLY when an enemy is already in range ---
	if not is_enemy:
		# clear invalid target
		if attack_target and not is_instance_valid(attack_target):
			attack_target = null

		# acquire a target only if it's already inside attack_range
		if attack_target == null:
			attack_target = _pick_enemy_in_range(attack_range)

		if attack_target:
			# if target left range, drop it (no chasing)
			var d := position.distance_to(attack_target.global_position)
			if d > attack_range:
				attack_target = null
			else:
				# stand still and swing on cooldown
				_atk_cd -= delta
				if _atk_cd <= 0.0:
					if attack_target and is_instance_valid(attack_target):
						if attack_target.has_method("apply_damage"):
							attack_target.apply_damage(attack_damage)
					if has_node("AnimationPlayer"):
						$AnimationPlayer.play("Attack") # ok if missing
					_atk_cd = attack_cooldown

		
		
func apply_damage(amount: int) -> void:
	hp = max(0, hp - amount)
	if has_node("AnimationPlayer"):
		$AnimationPlayer.play("Attack")
	_update_hp_bar()
	if hp == 0:
		queue_free()

func _update_hp_bar() -> void:
	if hp_bar:
		hp_bar.max_value = max_hp
		hp_bar.value = hp

func _pick_enemy_in_range(radius: float) -> Node:
	var best: Node = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(n):
			continue
		var d := position.distance_to(n.global_position)
		if d <= radius and d < best_d:
			best = n
			best_d = d
	return best
