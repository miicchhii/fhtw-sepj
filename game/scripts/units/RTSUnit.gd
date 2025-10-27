# RTSUnit.gd - Base class for all RTS units
#
# This is the base class for all controllable RTS units in the game.
# Units can be controlled by:
# - AI policies (via Python PPO training)
# - Player input (when selected)
#
# Multi-policy support:
# - Each unit has a policy_id that determines which AI model controls it
# - Policies can be changed at runtime via set_policy()
# - Policy assignments are sent to Python in observations
extends CharacterBody2D
class_name RTSUnit

# Faction assignment
@export var is_enemy: bool = false   # True for enemies, False for allies

# Unit identification
@export var unit_id: String = ""     # Unique ID (e.g., "u25", "u87")
@export var type_id: int = 0         # Unit type (0=Infantry, 1=Sniper)
@export var max_hp: int = 100        # Maximum health points
var hp: int                          # Current health points (set in _ready)

# AI policy assignment for multi-policy training
# Determines which neural network model controls this unit
var policy_id: String = ""  # e.g., "policy_LT50", "policy_GT50", "policy_frontline"

# Combat properties - can be overridden by subclasses (Infantry, Sniper, etc.)
var attack_range := 64.0        # Must be within this range to attack
var attack_damage := 15         # Damage per hit
var attack_cooldown := 0.8      # Seconds between attacks
var Speed := 50                 # Movement speed (pixels per second)

# Combat state tracking
var attack_target: Node = null  # Currently targeted enemy/ally
var _atk_cd := 0.0              # Attack cooldown timer

@export var selected = false
@onready var box = get_node("Box")
@onready var anim = get_node("AnimationPlayer")
@onready var target_click = position

@onready var hp_bar := $HPBar if has_node("HPBar") else null

var follow_cursor = false

var target: Vector2

# POI visualization
var poi_positions: Array = []  # Store POI positions for drawing debug lines
var closest_allies_positions: Array = []  # Store closest ally positions
var closest_enemies_positions: Array = []  # Store closest enemy positions

# Combat tracking for RL reward calculation
# These stats are reset each AI step and used to compute rewards in Game.gd
var damage_dealt_this_step: int = 0      # Damage dealt to enemy units this step
var damage_to_base_this_step: int = 0    # Damage dealt to enemy base this step (worth more)
var damage_received_this_step: int = 0   # Damage received from enemies this step
var kills_this_step: int = 0             # Number of kills this step (units)
var base_kills_this_step: int = 0        # Number of base kills this step (worth more)
var died_this_step: bool = false         # True if unit died this step

# Direction change tracking for movement efficiency reward
var previous_move_direction: Vector2 = Vector2.ZERO  # Last movement direction vector
var direction_change_reward: float = 0.0  # Reward/penalty for direction consistency

func _ready() -> void:
	# Set unit-specific stats first
	_initialize_unit_stats()

	# Assign policy based on unit_id number
	_assign_policy()

	# mark enemies and keep them unselectable
	if is_enemy:
		add_to_group("enemy")
		# Enemies are not selectable / don't respond to player input
		selected = false
		set_selected(selected)
		# Apply red tint to sprites only (not healthbar/UI)
		_apply_enemy_tint()
	else:
		add_to_group("ally")

	# Set current HP to match max HP before updating the HP bar
	hp = max_hp
	_update_hp_bar()

	set_selected(selected)
	add_to_group("units", true)
	print("Unit ", unit_id, " final stats: HP=", max_hp, " Range=", attack_range, " Damage=", attack_damage, " Speed=", Speed, " Policy=", policy_id)
	print("Unit ", unit_id, " added to groups: ", get_groups())
	target = global_position
	target_click = global_position  # Initialize both targets to current position

# Virtual function to be overridden by subclasses
func _initialize_unit_stats() -> void:
	# Base stats - subclasses should override this
	pass

func _assign_policy() -> void:
	"""
	Assign initial AI policy based on faction.

	Policy distribution:
	- Allies (is_enemy=false) → policy_LT50 (trainable)
	- Enemies (is_enemy=true) → policy_GT50 (trainable)

	This assignment can be changed at runtime via set_policy().
	"""
	if is_enemy:
		policy_id = "policy_GT50"  # Enemy team policy
	else:
		policy_id = "policy_LT50"  # Ally team policy

func _apply_enemy_tint() -> void:
	"""
	Apply red tint to sprite nodes only (not healthbar/UI).
	Preserves unit-specific colors while adding enemy team identification.
	"""
	# Apply red tint to all Sprite2D children
	for child in get_children():
		if child is Sprite2D:
			var current_color = child.modulate
			child.modulate = Color(current_color.r * 1.0, current_color.g * 0.314, current_color.b * 0.335, 1.0)

func set_policy(new_policy_id: String) -> void:
	"""
	Change this unit's AI policy at runtime.

	Enables dynamic policy switching during gameplay or training.
	The new policy takes effect on the next AI step.

	Args:
		new_policy_id: Name of the policy (e.g., "policy_LT50", "policy_frontline")
	"""
	if policy_id != new_policy_id:
		print("Unit ", unit_id, " policy changed: ", policy_id, " -> ", new_policy_id)
		policy_id = new_policy_id

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
	queue_redraw()  # Redraw when selection changes

func set_poi_positions(pois: Array):
	"""Update POI positions for debug visualization"""
	poi_positions = pois
	if selected:
		queue_redraw()  # Redraw if selected

func set_closest_units_positions(allies: Array, enemies: Array):
	"""Update closest ally/enemy positions for debug visualization"""
	closest_allies_positions = allies
	closest_enemies_positions = enemies
	if selected:
		queue_redraw()  # Redraw if selected

func _draw():
	"""Draw debug lines to POIs, allies, and enemies when unit is selected"""
	if not selected or is_enemy:  # Only draw for selected ally units
		return

	# Draw attack range circle (semi-transparent white)
	draw_arc(Vector2.ZERO, attack_range, 0, TAU, 64, Color(1.0, 1.0, 1.0, 0.3), 2.0, true)

	# Always draw lines to POIs (yellow)
	for poi in poi_positions:
		var local_poi = poi - global_position
		draw_line(Vector2.ZERO, local_poi, Color.YELLOW, 2.0)

	# Check if this is the only selected unit
	var selected_allies = get_tree().get_nodes_in_group("ally").filter(func(u): return u.selected)
	var is_only_selected = selected_allies.size() == 1

	# Only draw ally/enemy lines if this is the only selected unit
	if is_only_selected:
		# Draw lines to closest allies (blue)
		for ally_pos in closest_allies_positions:
			var local_ally = ally_pos - global_position
			draw_line(Vector2.ZERO, local_ally, Color.BLUE, 1.5)

		# Draw lines to closest enemies (red)
		for enemy_pos in closest_enemies_positions:
			var local_enemy = enemy_pos - global_position
			draw_line(Vector2.ZERO, local_enemy, Color.RED, 1.5)

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
			# Prioritize enemy units, but also attack enemy base if in range
			attack_target = _pick_enemy_in_range(attack_range)
			if attack_target == null:
				attack_target = _pick_enemy_base_in_range(attack_range)

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
						anim.play("Attack") # ok if missing
					_atk_cd = attack_cooldown
	
		# --- Enemy units: attack ONLY when an ally is already in range ---
	if is_enemy:
		# clear invalid target
		if attack_target and not is_instance_valid(attack_target):
			attack_target = null

		# acquire a target only if it's already inside attack_range
		if attack_target == null:
			# Prioritize ally units, but also attack ally base if in range
			attack_target = _pick_ally_in_range(attack_range)
			if attack_target == null:
				attack_target = _pick_ally_base_in_range(attack_range)

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
						anim.play("Attack")
					_atk_cd = attack_cooldown

		
		
func apply_damage(amount: int, attacker: RTSUnit = null) -> void:
	var actual_damage = min(amount, hp)  # Don't count overkill damage
	hp = max(0, hp - amount)

	# Track damage received for rewards
	damage_received_this_step += actual_damage

	if has_node("AnimationPlayer"):
		anim.play("Attack")
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
	damage_to_base_this_step = 0
	damage_received_this_step = 0
	kills_this_step = 0
	base_kills_this_step = 0
	died_this_step = false
	direction_change_reward = 0.0

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

func _pick_enemy_base_in_range(radius: float) -> Node:
	var bases = get_tree().get_nodes_in_group("enemy_base")
	if bases.size() > 0:
		var base = bases[0]
		if is_instance_valid(base):
			var d := position.distance_to(base.global_position)
			if d <= radius:
				return base
	return null

func _pick_ally_base_in_range(radius: float) -> Node:
	var bases = get_tree().get_nodes_in_group("ally_base")
	if bases.size() > 0:
		var base = bases[0]
		if is_instance_valid(base):
			var d := position.distance_to(base.global_position)
			if d <= radius:
				return base
	return null
