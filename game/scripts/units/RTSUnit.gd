# RTSUnit.gd - Base class for all RTS units
extends CharacterBody2D
class_name RTSUnit

@export var is_enemy: bool = false   # same scene, different faction

@export var unit_id: String = ""
@export var type_id: int = 0
@export var max_hp: int = 100
var hp: int = max_hp

# Combat properties - can be overridden by subclasses
var attack_range := 64.0        # must be inside this to hit
var attack_damage := 15
var attack_cooldown := 0.8
var Speed := 50

# Combat state
var attack_target: Node = null
var _atk_cd := 0.0

@export var selected = false
@onready var box = get_node("Box")
@onready var anim = get_node("AnimationPlayer")
@onready var target_click = position

@onready var hp_bar := $HPBar if has_node("HPBar") else null

var follow_cursor = false

var target: Vector2

# Combat tracking for rewards
var damage_dealt_this_step: int = 0
var damage_received_this_step: int = 0
var kills_this_step: int = 0
var died_this_step: bool = false

func _ready() -> void:
	# Set unit-specific stats first
	_initialize_unit_stats()

	# mark enemies and keep them unselectable
	if is_enemy:
		add_to_group("enemy")
		# Enemies are not selectable / don't respond to player input
		selected = false
		set_selected(selected)
		# Apply red tint while preserving unit-specific colors
		var current_color = modulate
		modulate = Color(current_color.r * 1.0, current_color.g * 0.314, current_color.b * 0.335, 1.0)
	else:
		add_to_group("ally")
	_update_hp_bar()

	set_selected(selected)
	add_to_group("units", true)
	print("Unit ", unit_id, " final stats: HP=", max_hp, " Range=", attack_range, " Damage=", attack_damage, " Speed=", Speed)
	print("Unit ", unit_id, " added to groups: ", get_groups())
	hp = max_hp
	target = global_position
	target_click = global_position  # Initialize both targets to current position

# Virtual function to be overridden by subclasses
func _initialize_unit_stats() -> void:
	# Base stats - subclasses should override this
	pass

func set_move_target(p: Vector2) -> void:
	target = p
	target_click = p  # Sync both targets to avoid conflicts

func step(_delta: float) -> void:
	# AI movement logic - just update the target, actual movement happens in _physics_process
	pass

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
	# Handle player input for selected units
	if follow_cursor == true:
		if selected:
			target_click = get_global_mouse_position()
			target = target_click  # Sync AI target with player input
			anim.play("Walk")

	# Use target_click for all movement (both player and AI controlled)
	var move_target = target_click
	var distance_to_target = position.distance_to(move_target)

	if distance_to_target > 10:
		velocity = position.direction_to(move_target) * Speed
		move_and_slide()
		if not anim.is_playing() or anim.current_animation != "Walk":
			anim.play("Walk")
	else:
		velocity = Vector2.ZERO
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
							var target_hp_before = attack_target.hp
							attack_target.apply_damage(attack_damage, self)  # Pass attacker reference
							# Track damage dealt and kills
							var actual_damage = target_hp_before - attack_target.hp
							damage_dealt_this_step += actual_damage
							if attack_target.hp <= 0:
								kills_this_step += 1
					if has_node("AnimationPlayer"):
						$AnimationPlayer.play("Attack") # ok if missing
					_atk_cd = attack_cooldown
	
		# --- Enemy units: attack ONLY when an ally is already in range ---
	if is_enemy:
		# clear invalid target
		if attack_target and not is_instance_valid(attack_target):
			attack_target = null

		# acquire a target only if it's already inside attack_range
		if attack_target == null:
			attack_target = _pick_ally_in_range(attack_range)

		if attack_target:
			var d := position.distance_to(attack_target.global_position)
			if d > attack_range:
				attack_target = null             # do not chase
			else:
				_atk_cd -= delta
				if _atk_cd <= 0.0:
					if is_instance_valid(attack_target) and attack_target.has_method("apply_damage"):
						var target_hp_before = attack_target.hp
						attack_target.apply_damage(attack_damage, self)  # Pass attacker reference
						# Track damage dealt and kills
						var actual_damage = target_hp_before - attack_target.hp
						damage_dealt_this_step += actual_damage
						if attack_target.hp <= 0:
							kills_this_step += 1
					if has_node("AnimationPlayer"):
						$AnimationPlayer.play("Attack")
					_atk_cd = attack_cooldown

		
		
func apply_damage(amount: int, attacker: RTSUnit = null) -> void:
	var actual_damage = min(amount, hp)  # Don't count overkill damage
	hp = max(0, hp - amount)

	# Track damage received for rewards
	damage_received_this_step += actual_damage

	if has_node("AnimationPlayer"):
		$AnimationPlayer.play("Attack")
	_update_hp_bar()
	if hp == 0:
		died_this_step = true
		queue_free()

func _update_hp_bar() -> void:
	if hp_bar:
		hp_bar.max_value = max_hp
		hp_bar.value = hp

func reset_combat_stats() -> void:
	# Reset combat tracking for next step
	damage_dealt_this_step = 0
	damage_received_this_step = 0
	kills_this_step = 0
	died_this_step = false

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
	
func _pick_ally_in_range(radius: float) -> Node:
	var best: Node = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group("ally"):
		if not is_instance_valid(n):
			continue
		var d := position.distance_to(n.global_position)
		if d <= radius and d < best_d:
			best = n
			best_d = d
	return best
