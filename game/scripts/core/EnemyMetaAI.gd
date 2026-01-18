# EnemyMetaAI.gd - Scripted AI controller for enemy units in inference mode
#
# Perpetual rules:
# - If player base is unprotected → spawn aggro units
# - If player has units → spawn defensive units
# - If player damages enemy base → set ALL existing units to defensive
# - If player has few units AND base hasn't been damaged in 100 ticks → set ALL units to aggro
#
# The meta-AI can only:
# - Spawn units with assigned policies
# - Change policies of existing units
# - The policy determines unit behavior (no direct movement control)

class_name EnemyMetaAI
extends Node

# Spawn costs (match player costs from roboshop_ui.gd)
const COST_INFANTRY: int = 30
const COST_SNIPER: int = 40
const COST_HEAVY: int = 70

# Thresholds
const BASE_PROTECTION_RADIUS: float = 300.0
const MIN_PROTECTORS: int = 3
const FEW_UNITS_THRESHOLD: int = 3  # Player has "few" units if <= this
const SAFE_TICKS_FOR_AGGRO: int = 100  # Ticks without base damage to go aggro

# Squad definitions - each squad spawns units with a specific POLICY
var squad_templates: Dictionary = {
	"defense": {
		"units": [
			{"type": Global.UnitType.INFANTRY, "count": 3}
		],
		"policy": "policy_defensive_1",
		"cost": 90  # 3 * 30
	},
	"aggro_base": {
		"units": [
			{"type": Global.UnitType.SNIPER, "count": 1},
			{"type": Global.UnitType.INFANTRY, "count": 3}
		],
		"policy": "policy_aggressive_1",
		"cost": 130  # 40 + 3*30
	},
	"aggro_units": {
		"units": [
			{"type": Global.UnitType.INFANTRY, "count": 5}
		],
		"policy": "policy_aggressive_1",
		"cost": 150  # 5 * 30
	}
}

# Decision state
var current_strategy: String = "balanced"

# Reference to game node (set during initialization)
var game_node: Node = null

# Track if we've spawned the initial unit (to avoid 0-agent scenario)
var _spawned_initial_unit: bool = false

# Track enemy base damage for policy switching
var _last_enemy_base_hp: int = -1
var _ticks_since_base_damage: int = 0
var _current_army_policy: String = ""  # Track what policy the army is currently set to

func _init() -> void:
	pass

func set_game_node(game: Node) -> void:
	"""Set reference to game node for accessing world state."""
	game_node = game

func reset() -> void:
	"""Reset state for a new episode."""
	_spawned_initial_unit = false
	current_strategy = "balanced"
	_last_enemy_base_hp = -1
	_ticks_since_base_damage = 0
	_current_army_policy = ""

func evaluate_and_spawn() -> void:
	"""
	Main decision function called each AI tick (inference mode only).
	Evaluates game state, updates existing unit policies, and spawns new squads.
	"""
	# Ensure there's always at least one enemy unit (avoids 0-agent timeout in Python)
	if not _spawned_initial_unit:
		_spawn_initial_unit()
		_spawned_initial_unit = true
		return  # Skip regular evaluation on first tick

	# Track base damage
	_update_base_damage_tracking()

	# Evaluate and potentially switch existing units' policies
	_evaluate_army_policy()

	# Decide spawn strategy and try to spawn
	_decide_spawn_strategy()
	_try_spawn_squad()

func _update_base_damage_tracking() -> void:
	"""Track when the enemy base takes damage."""
	var enemy_bases = get_tree().get_nodes_in_group("enemy_base")
	if enemy_bases.size() == 0:
		return

	var base = enemy_bases[0]
	if not is_instance_valid(base):
		return

	var current_hp = base.hp if base.has_method("get") or "hp" in base else base.get("hp")
	if current_hp == null:
		return

	# Initialize on first check
	if _last_enemy_base_hp < 0:
		_last_enemy_base_hp = current_hp
		return

	# Check if base took damage
	if current_hp < _last_enemy_base_hp:
		_ticks_since_base_damage = 0
		print("EnemyMetaAI: Enemy base took damage! Resetting aggro timer.")
	else:
		_ticks_since_base_damage += 1

	_last_enemy_base_hp = current_hp

func _evaluate_army_policy() -> void:
	"""
	Evaluate game state and switch ALL existing enemy units' policies if needed.

	Rules:
	- If enemy base took damage recently → defensive (protect base)
	- If player has few units AND base safe for 100 ticks → aggressive (finish them)
	"""
	var player_units = _count_player_units()
	var base_recently_damaged = _ticks_since_base_damage < 10  # Within last 10 ticks
	var base_safe_long_time = _ticks_since_base_damage >= SAFE_TICKS_FOR_AGGRO
	var player_has_few_units = player_units <= FEW_UNITS_THRESHOLD

	var new_policy: String = ""

	# Rule: Base took damage → go defensive
	if base_recently_damaged:
		new_policy = "policy_defensive_1"
	# Rule: Player weak AND base safe → go aggressive
	elif player_has_few_units and base_safe_long_time:
		new_policy = "policy_aggressive_1"

	# Only switch if we have a new policy and it's different from current
	if new_policy != "" and new_policy != _current_army_policy:
		_set_all_enemy_units_policy(new_policy)
		_current_army_policy = new_policy

func _set_all_enemy_units_policy(policy: String) -> void:
	"""Change the policy of ALL existing enemy units."""
	var count = 0
	for unit in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(unit) and unit.has_method("set_policy"):
			unit.set_policy(policy)
			count += 1

	if count > 0:
		var reason = "base under attack" if policy == "policy_defensive_1" else "player weakened"
		print("EnemyMetaAI: Switched ", count, " units to ", policy, " (", reason, ")")

func _decide_spawn_strategy() -> void:
	"""Decide what type of units to spawn based on game state."""
	var player_units = _count_player_units()
	var enemy_units = _count_enemy_units()
	var player_base_protected = _is_player_base_protected()

	# Rule: Player base unprotected → aggressive spawns
	if not player_base_protected:
		current_strategy = "aggressive"
	# Rule: Player has more units → defensive spawns
	elif player_units > enemy_units:
		current_strategy = "defensive"
	# Rule: We have advantage → aggressive
	elif enemy_units > player_units * 1.5:
		current_strategy = "aggressive"
	else:
		current_strategy = "balanced"

func _try_spawn_squad() -> void:
	"""Attempt to spawn a squad based on current strategy and available Metal."""
	# Find the cheapest squad we can afford
	var squad_type: String = ""
	var squad_cost: int = 0

	match current_strategy:
		"defensive":
			squad_type = "defense"
		"aggressive":
			# Randomly choose between base-focused or unit-focused aggro
			squad_type = "aggro_base" if randf() > 0.3 else "aggro_units"
		"balanced":
			squad_type = "defense" if randf() > 0.5 else "aggro_base"
		_:
			squad_type = "defense"

	var squad = squad_templates[squad_type]
	squad_cost = squad.cost

	# If we can't afford preferred squad, try cheaper options
	if Global.EnemyMetal < squad_cost:
		# Try defense squad (cheapest)
		if Global.EnemyMetal >= squad_templates["defense"].cost:
			squad_type = "defense"
			squad = squad_templates[squad_type]
			squad_cost = squad.cost
		else:
			return  # Can't afford anything

	if Global.EnemyMetal >= squad_cost:
		_spawn_squad(squad_type)
		Global.EnemyMetal -= squad_cost
		print("EnemyMetaAI: Spawned ", squad_type, " squad (strategy: ", current_strategy, ", cost: ", squad_cost, " Metal). Remaining: ", Global.EnemyMetal)

func _spawn_initial_unit() -> void:
	"""
	Spawn a single initial enemy unit to ensure Python always has at least one agent.
	This is free (no Metal cost) and happens on the first AI tick.
	"""
	var spawn_pos = _get_spawn_position()
	Global.spawnUnit(spawn_pos, true, Global.UnitType.INFANTRY, "policy_defensive_1")
	print("EnemyMetaAI: Spawned initial enemy unit (free starter)")

func _spawn_squad(squad_type: String) -> void:
	"""Spawn a squad of units near the enemy shop with the squad's assigned policy."""
	var squad = squad_templates[squad_type]
	var spawn_pos = _get_spawn_position()
	var policy = squad.policy

	# Spawn all units in the squad
	var spawn_offset_index = 0
	for unit_def in squad.units:
		for i in range(unit_def.count):
			# Offset each unit slightly to avoid overlap
			var offset = Vector2(
				(spawn_offset_index % 3) * 50 - 50,  # -50, 0, 50
				(spawn_offset_index / 3) * 50
			)
			var unit_pos = spawn_pos + offset

			# Spawn the unit with the squad's assigned policy
			Global.spawnUnit(unit_pos, true, unit_def.type, policy)

			spawn_offset_index += 1

func _get_spawn_position() -> Vector2:
	"""Get spawn position near the enemy shop (the shop closest to enemy base)."""
	# Find enemy base first
	var enemy_bases = get_tree().get_nodes_in_group("enemy_base")
	if enemy_bases.size() == 0:
		# Fallback: spawn at map center-left (enemy side)
		var map_w = GameConfig.MAP_WIDTH if game_node == null else game_node.map_w
		var map_h = GameConfig.MAP_HEIGHT if game_node == null else game_node.map_h
		return Vector2(map_w * 0.25, map_h * 0.5)

	var enemy_base = enemy_bases[0]
	var enemy_base_pos = enemy_base.global_position

	# Find the shop closest to enemy base (that's the enemy shop)
	var shops = get_tree().get_nodes_in_group("Roboshop")
	var closest_shop: Node = null
	var closest_dist: float = INF

	for shop in shops:
		if is_instance_valid(shop):
			var dist = shop.global_position.distance_to(enemy_base_pos)
			if dist < closest_dist:
				closest_dist = dist
				closest_shop = shop

	if closest_shop:
		# Spawn near the enemy shop with some random offset
		return closest_shop.global_position + Vector2(randf_range(-80, 80), randf_range(-80, 80))

	# Fallback: spawn near enemy base
	return enemy_base_pos + Vector2(randf_range(-100, 100), randf_range(-100, 100))

func _count_player_units() -> int:
	"""Count player (ally) units."""
	return get_tree().get_nodes_in_group("ally").size()

func _count_enemy_units() -> int:
	"""Count AI-controlled (enemy) units."""
	return get_tree().get_nodes_in_group("enemy").size()

func _is_player_base_protected() -> bool:
	"""
	Check if player's base has sufficient protection.
	Returns true if >= MIN_PROTECTORS ally units are within BASE_PROTECTION_RADIUS.
	"""
	var ally_bases = get_tree().get_nodes_in_group("ally_base")
	if ally_bases.size() == 0:
		return false  # No base to protect

	var base = ally_bases[0]
	if not is_instance_valid(base):
		return false

	var base_pos = base.global_position
	var protector_count = 0

	for unit in get_tree().get_nodes_in_group("ally"):
		if is_instance_valid(unit):
			var dist = unit.global_position.distance_to(base_pos)
			if dist <= BASE_PROTECTION_RADIUS:
				protector_count += 1

	return protector_count >= MIN_PROTECTORS
