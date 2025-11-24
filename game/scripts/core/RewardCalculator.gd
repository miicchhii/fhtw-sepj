# RewardCalculator.gd - Centralized reward calculation for RTS training
#
# Encapsulates all reward logic for reinforcement learning with policy-specific rewards.
# Each policy (aggressive, defensive, etc.) has custom reward weights.
#
# Features:
# - Loads policy configurations from JSON
# - Applies policy-specific reward weights per unit
# - Supports multiple policies with different behaviors
# - Fallback to baseline policy if unit policy not found

class_name RewardCalculator

# Policy configurations loaded from JSON
var policy_config: Dictionary = {}
var default_policy: String = "policy_baseline"

# Tactical spacing threshold (shared across all policies)
var tactical_spacing_threshold: float = GameConfig.TACTICAL_SPACING_THRESHOLD

func _init():
	"""Initialize RewardCalculator and load policy configurations from JSON"""
	load_policy_config()

func load_policy_config() -> void:
	"""Load AI policy configurations from JSON file"""
	var config_path = "res://config/ai_policies.json"
	var file = FileAccess.open(config_path, FileAccess.READ)

	if not file:
		push_error("Failed to load ai_policies.json - using default rewards")
		return

	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("Failed to parse ai_policies.json: " + json.get_error_message())
		return

	var data = json.data
	if not data.has("policies"):
		push_error("Invalid ai_policies.json: missing 'policies' key")
		return

	policy_config = data["policies"]
	default_policy = data.get("default_policy", "policy_baseline")

	print("RewardCalculator: Loaded ", policy_config.size(), " policies from JSON")

func get_reward_profile(policy_id: String) -> Dictionary:
	"""
	Get reward profile for a specific policy.
	Falls back to default policy if not found.
	"""
	if policy_id == "" or not policy_config.has(policy_id):
		if policy_config.has(default_policy):
			return policy_config[default_policy]["reward_profile"]
		else:
			push_error("Default policy not found: " + default_policy)
			return {}

	return policy_config[policy_id]["reward_profile"]

func calculate_rewards(
	units: Array,
	ally_base: Node,
	enemy_base: Node,
	ai_controls_allies: bool,
	game_won: bool,
	game_lost: bool,
	map_center: Vector2
) -> Dictionary:
	"""
	Calculate rewards for all units based on current game state.

	Args:
		units: Array of RTSUnit instances
		ally_base: Ally base node (or null if destroyed)
		enemy_base: Enemy base node (or null if destroyed)
		ai_controls_allies: Whether AI is controlling ally units
		game_won: Whether allies won this step
		game_lost: Whether allies lost this step
		map_center: Center of the map for fallback positioning

	Returns:
		Dictionary mapping unit_id → reward (float)
	"""
	var rewards := {}

	# Calculate base damage (not using policy-specific weights here since it's team-wide)
	var ally_base_damage = 0.0
	var enemy_base_damage = 0.0
	if ally_base and is_instance_valid(ally_base):
		ally_base_damage = ally_base.damage_taken_this_step
	if enemy_base and is_instance_valid(enemy_base):
		enemy_base_damage = enemy_base.damage_taken_this_step

	# Calculate rewards for each unit
	for u in units:
		# Skip manually controlled ally units
		if not u.is_enemy and not ai_controls_allies:
			u.reset_combat_stats()
			continue

		# Get policy-specific reward profile for this unit
		var reward_profile = get_reward_profile(u.policy_id)

		var reward = _calculate_unit_reward(
			u,
			ally_base,
			enemy_base,
			game_won,
			game_lost,
			map_center,
			ally_base_damage,
			enemy_base_damage,
			units,
			reward_profile
		)

		rewards[u.unit_id] = reward
		u.reset_combat_stats()

	return rewards

func _calculate_unit_reward(
	u: RTSUnit,
	ally_base: Node,
	enemy_base: Node,
	game_won: bool,
	game_lost: bool,
	map_center: Vector2,
	ally_base_damage: float,
	enemy_base_damage: float,
	all_units: Array,
	profile: Dictionary
) -> float:
	"""Calculate total reward for a single unit using policy-specific weights."""
	var reward: float = 0.0

	# 1. Combat rewards (primary)
	reward += _calculate_combat_reward(u, profile)

	# 2. Team outcome rewards
	reward += _calculate_team_outcome_reward(u, game_won, game_lost, profile)

	# 3. Positional reward (encourage moving toward objective)
	reward += _calculate_positional_reward(u, ally_base, enemy_base, map_center, profile)

	# 4. Survival reward
	reward += _calculate_survival_reward(u, profile)

	# 5. Movement efficiency reward/penalty
	reward += _calculate_movement_efficiency_reward(u, profile)

	# 6. Base damage penalty (shared by entire team)
	var base_damage = ally_base_damage if not u.is_enemy else enemy_base_damage
	reward += base_damage * profile.get("base_defense_penalty", -0.5)

	# 7. Tactical spacing penalty (anti-clustering)
	reward += _calculate_spacing_penalty(u, all_units, profile)

	return reward

func _calculate_combat_reward(u: RTSUnit, profile: Dictionary) -> float:
	"""Calculate combat-based rewards using policy-specific weights."""
	var reward: float = 0.0

	reward += u.damage_dealt_this_step * profile.get("damage_to_unit", 0.2)
	reward += u.damage_to_base_this_step * profile.get("damage_to_base", 1.0)
	reward += u.kills_this_step * profile.get("unit_kill", 15.0)
	reward += u.base_kills_this_step * profile.get("base_kill", 200.0)
	reward += u.damage_received_this_step * profile.get("damage_received", -0.1)

	if u.died_this_step:
		reward += profile.get("death", -5.0)

	return reward

func _calculate_team_outcome_reward(u: RTSUnit, game_won: bool, game_lost: bool, profile: Dictionary) -> float:
	"""Calculate team victory/defeat rewards using policy-specific weights."""
	var reward: float = 0.0

	if game_won and not u.is_enemy:
		reward += profile.get("team_victory", 50.0)
	elif game_lost and not u.is_enemy:
		reward += profile.get("team_defeat", -25.0)
	elif game_won and u.is_enemy:
		reward += profile.get("team_defeat", -25.0)
	elif game_lost and u.is_enemy:
		reward += profile.get("team_victory", 50.0)

	return reward

func _calculate_positional_reward(
	u: RTSUnit,
	ally_base: Node,
	enemy_base: Node,
	map_center: Vector2,
	profile: Dictionary
) -> float:
	"""
	Calculate positional reward based on proximity to bases.
	Uses policy-specific multipliers for enemy/ally base proximity.
	"""
	var reward: float = 0.0

	# Get base positions
	var ally_base_pos = ally_base.global_position if (ally_base and is_instance_valid(ally_base)) else map_center
	var enemy_base_pos = enemy_base.global_position if (enemy_base and is_instance_valid(enemy_base)) else map_center

	# Determine which is "our" base and which is "enemy" base
	var our_base_pos = ally_base_pos if not u.is_enemy else enemy_base_pos
	var their_base_pos = enemy_base_pos if not u.is_enemy else ally_base_pos

	# Calculate normalized distances
	var max_dist = GameConfig.MAP_WIDTH
	var dist_to_enemy_base = u.global_position.distance_to(their_base_pos)
	var dist_to_ally_base = u.global_position.distance_to(our_base_pos)

	# Proximity to enemy base (1.0 = at base, 0.0 = max distance)
	var proximity_to_enemy = 1.0 - clamp(dist_to_enemy_base / max_dist, 0.0, 1.0)
	reward += proximity_to_enemy * profile.get("proximity_to_enemy_base_multiplier", 1.5)

	# Proximity to ally base (1.0 = at base, 0.0 = max distance)
	var proximity_to_ally = 1.0 - clamp(dist_to_ally_base / max_dist, 0.0, 1.0)
	reward += proximity_to_ally * profile.get("proximity_to_ally_base_multiplier", 0.0)

	return reward

func _calculate_survival_reward(u: RTSUnit, profile: Dictionary) -> float:
	"""Small reward for staying alive each step."""
	if not u.died_this_step:
		return profile.get("alive_per_step", 0.01)
	return 0.0

func _calculate_movement_efficiency_reward(u: RTSUnit, profile: Dictionary) -> float:
	"""Calculate movement efficiency reward based on direction changes."""
	# u.direction_change_reward already calculated in RTSUnit
	# Scale it by policy-specific weights
	if u.direction_change_reward > 0:
		# Continuing straight
		return u.direction_change_reward * profile.get("movement_continue_straight", 0.5) / GameConfig.REWARD_CONTINUE_STRAIGHT
	else:
		# Changing direction
		return u.direction_change_reward * profile.get("movement_reverse_direction", -1.0) / GameConfig.PENALTY_REVERSE_DIRECTION

func _calculate_spacing_penalty(u: RTSUnit, all_units: Array, profile: Dictionary) -> float:
	"""
	Calculate stacking penalty for units clustering too closely together.
	Uses policy-specific weight for tactical spacing.
	"""
	var spacing_penalty: float = 0.0

	for other_unit in all_units:
		if other_unit == u:
			continue  # Skip self

		# Only check same faction (allies)
		if other_unit.is_enemy != u.is_enemy:
			continue

		var distance = u.global_position.distance_to(other_unit.global_position)

		if distance < tactical_spacing_threshold:
			# Closer = bigger penalty
			var proximity_ratio = 1.0 - (distance / tactical_spacing_threshold)
			spacing_penalty += profile.get("tactical_spacing", -1.0) * proximity_ratio

	return spacing_penalty
