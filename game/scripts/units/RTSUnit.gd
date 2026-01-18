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

# Behavior modes for meta-AI control
enum BehaviorMode { NEUTRAL, DEFENSIVE, AGGRO_1, AGGRO_2 }
var behavior_mode: BehaviorMode = BehaviorMode.NEUTRAL

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
@onready var target_click = global_position

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

# Policy change tracking - triggers episode reset when changed via UI
var policy_changed_this_step: bool = false

# Attack sound effect
var _attack_sound_player: AudioStreamPlayer2D = null
static var _attack_sound: AudioStream = null
static var _last_sound_time: float = 0.0  # Global cooldown to prevent audio overload
const SOUND_COOLDOWN: float = 0.05  # Minimum 50ms between any gunshot sounds

func _ready() -> void:
	# Set unit-specific stats first
	_initialize_unit_stats()

	# Only assign policy from JSON config if not already pre-set by SpawnManager
	if policy_id == "":
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

	# Setup attack sound (loaded once, shared across all units)
	if _attack_sound == null:
		_attack_sound = load("res://RTSAssets/SFX/cannon-shot-6153.wav")
	_attack_sound_player = AudioStreamPlayer2D.new()
	_attack_sound_player.stream = _attack_sound
	_attack_sound_player.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	add_child(_attack_sound_player)


func _play_attack_sound() -> void:
	"""Play attack sound with pitch randomization and global cooldown."""
	if _attack_sound_player == null or _attack_sound == null:
		return

	# Global cooldown to prevent audio overload (50ms between any shots)
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - _last_sound_time < SOUND_COOLDOWN:
		return
	_last_sound_time = current_time

	# Pitch randomization (±10%) to reduce sonic fatigue
	_attack_sound_player.pitch_scale = randf_range(0.9, 1.1)
	# Slight volume variation (±15%)
	_attack_sound_player.volume_db = randf_range(-3.0, 0.0)
	_attack_sound_player.play()


# Virtual function to be overridden by subclasses
func _initialize_unit_stats() -> void:
	# Base stats - subclasses should override this
	pass

func _assign_policy() -> void:
	"""
	Assign initial AI policy based on faction.
	Loads policy configuration from JSON to determine team assignments.

	Policy distribution (configurable in game/config/ai_policies.json):
	- Allies (is_enemy=false) → policy_aggressive_1 (trainable)
	- Enemies (is_enemy=true) → policy_defensive_1 (trainable)

	This assignment can be changed at runtime via set_policy().
	"""
	# Load team policy assignments from JSON config
	var config_path = "res://config/ai_policies.json"
	var file = FileAccess.open(config_path, FileAccess.READ)

	if not file:
		push_error("Failed to load ai_policies.json for policy assignment")
		policy_id = "policy_baseline"  # Fallback to baseline
		return

	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("Failed to parse ai_policies.json: " + json.get_error_message())
		policy_id = "policy_baseline"  # Fallback to baseline
		return

	var data = json.data

	# Get team assignments from config, or use defaults
	var ally_policy = data.get("ally_team_policy", "policy_aggressive_1")
	var enemy_policy = data.get("enemy_team_policy", "policy_defensive_1")

	if is_enemy:
		policy_id = enemy_policy
	else:
		policy_id = ally_policy

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
	The new policy triggers an episode reset so RLlib picks up the change.

	Args:
		new_policy_id: Name of the policy (e.g., "policy_LT50", "policy_frontline")
	"""
	if policy_id != new_policy_id:
		print("Unit ", unit_id, " policy changed: ", policy_id, " -> ", new_policy_id)
		policy_id = new_policy_id
		policy_changed_this_step = true  # Flag for episode reset

func clear_policy_changed_flag() -> void:
	"""Clear the policy changed flag after it's been processed."""
	policy_changed_this_step = false

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
	if (value == true):
		Global.set_selected_unit(self)
	if (value == false) && (Global.SelectedUnit == self):
		Global.set_selected_unit(null)
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
	var cur = global_position
	var distance_to_target = cur.distance_to(move_target)

	if distance_to_target > 10.0:
		velocity = (move_target - cur).normalized() * Speed
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
					_play_attack_sound()
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
					_play_attack_sound()
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

# Behavior mode support for meta-AI control
func set_behavior_mode(mode: BehaviorMode) -> void:
	"""Set the unit's behavior mode (used by EnemyMetaAI)."""
	behavior_mode = mode

func get_behavior_target() -> Vector2:
	"""
	Get the target position based on behavior mode.
	Used as movement objective for AI-controlled units.
	"""
	match behavior_mode:
		BehaviorMode.DEFENSIVE:
			# Stay near own base
			return _get_own_base_position()
		BehaviorMode.AGGRO_1:
			# Move toward nearest enemy unit
			return _get_nearest_enemy_position()
		BehaviorMode.AGGRO_2:
			# Move toward enemy base
			return _get_enemy_base_position()
		_:
			# NEUTRAL: no specific target, stay at current position
			return position

func _get_own_base_position() -> Vector2:
	"""Get position of this unit's team base."""
	var base_group = "enemy_base" if is_enemy else "ally_base"
	var bases = get_tree().get_nodes_in_group(base_group)
	if bases.size() > 0 and is_instance_valid(bases[0]):
		return bases[0].global_position
	return position

func _get_enemy_base_position() -> Vector2:
	"""Get position of the opposing team's base."""
	var base_group = "ally_base" if is_enemy else "enemy_base"
	var bases = get_tree().get_nodes_in_group(base_group)
	if bases.size() > 0 and is_instance_valid(bases[0]):
		return bases[0].global_position
	return position

func _get_nearest_enemy_position() -> Vector2:
	"""Get position of nearest enemy (from this unit's perspective)."""
	var enemy_group = "ally" if is_enemy else "enemy"
	var enemies = get_tree().get_nodes_in_group(enemy_group)
	var nearest_pos = position
	var nearest_dist = INF

	for enemy in enemies:
		if is_instance_valid(enemy):
			var dist = position.distance_to(enemy.global_position)
			if dist < nearest_dist:
				nearest_dist = dist
				nearest_pos = enemy.global_position

	return nearest_pos
