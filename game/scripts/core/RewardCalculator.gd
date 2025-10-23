# RewardCalculator.gd - Centralized reward calculation for RTS training
#
# Encapsulates all reward logic for reinforcement learning.
# Separating this from Game.gd makes it easier to:
# - Test reward calculations in isolation
# - Tune reward weights without touching game logic
# - Understand the reward structure at a glance
# - Add reward tracking/logging in the future

class_name RewardCalculator

# Reward configuration (initialized from Game.gd)
var reward_damage_to_unit: float
var reward_damage_to_base: float
var reward_unit_kill: float
var reward_base_kill: float
var penalty_damage_received: float
var penalty_death: float
var reward_team_victory: float
var penalty_team_defeat: float
var reward_position_multiplier: float
var reward_alive_per_step: float
var reward_continue_straight: float
var penalty_reverse_direction: float
var penalty_base_damage_per_unit: float
var reward_tactical_spacing: float
var tactical_spacing_threshold: float

func _init(
	p_reward_damage_to_unit: float,
	p_reward_damage_to_base: float,
	p_reward_unit_kill: float,
	p_reward_base_kill: float,
	p_penalty_damage_received: float,
	p_penalty_death: float,
	p_reward_team_victory: float,
	p_penalty_team_defeat: float,
	p_reward_position_multiplier: float,
	p_reward_alive_per_step: float,
	p_reward_continue_straight: float,
	p_penalty_reverse_direction: float,
	p_penalty_base_damage_per_unit: float,
	p_reward_tactical_spacing: float,
	p_tactical_spacing_threshold: float
):
	reward_damage_to_unit = p_reward_damage_to_unit
	reward_damage_to_base = p_reward_damage_to_base
	reward_unit_kill = p_reward_unit_kill
	reward_base_kill = p_reward_base_kill
	penalty_damage_received = p_penalty_damage_received
	penalty_death = p_penalty_death
	reward_team_victory = p_reward_team_victory
	penalty_team_defeat = p_penalty_team_defeat
	reward_position_multiplier = p_reward_position_multiplier
	reward_alive_per_step = p_reward_alive_per_step
	reward_continue_straight = p_reward_continue_straight
	penalty_reverse_direction = p_penalty_reverse_direction
	penalty_base_damage_per_unit = p_penalty_base_damage_per_unit
	reward_tactical_spacing = p_reward_tactical_spacing
	tactical_spacing_threshold = p_tactical_spacing_threshold

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

	# Calculate base damage penalties for teams
	var ally_base_damage_penalty = _calculate_base_damage_penalty(ally_base)
	var enemy_base_damage_penalty = _calculate_base_damage_penalty(enemy_base)

	# Calculate rewards for each unit
	for u in units:
		# Skip manually controlled ally units
		if not u.is_enemy and not ai_controls_allies:
			u.reset_combat_stats()
			continue

		var reward = _calculate_unit_reward(
			u,
			ally_base,
			enemy_base,
			game_won,
			game_lost,
			map_center,
			ally_base_damage_penalty,
			enemy_base_damage_penalty,
			units
		)

		rewards[u.unit_id] = reward
		u.reset_combat_stats()

	return rewards

func _calculate_base_damage_penalty(base: Node) -> float:
	"""Calculate team-wide penalty for base damage."""
	if base and is_instance_valid(base):
		if base.damage_taken_this_step > 0:
			return base.damage_taken_this_step * penalty_base_damage_per_unit
	return 0.0

func _calculate_unit_reward(
	u: RTSUnit,
	ally_base: Node,
	enemy_base: Node,
	game_won: bool,
	game_lost: bool,
	map_center: Vector2,
	ally_base_damage_penalty: float,
	enemy_base_damage_penalty: float,
	all_units: Array
) -> float:
	"""Calculate total reward for a single unit."""
	var reward: float = 0.0

	# 1. Combat rewards (primary)
	reward += _calculate_combat_reward(u)

	# 2. Team outcome rewards
	reward += _calculate_team_outcome_reward(u, game_won, game_lost)

	# 3. Positional reward (encourage moving toward objective)
	reward += _calculate_positional_reward(u, ally_base, enemy_base, map_center)

	# 4. Survival reward
	reward += _calculate_survival_reward(u)

	# 5. Movement efficiency reward/penalty
	reward += u.direction_change_reward

	# 6. Base damage penalty (shared by entire team)
	if not u.is_enemy:
		reward -= ally_base_damage_penalty
	else:
		reward -= enemy_base_damage_penalty

	# 7. Tactical spacing penalty (anti-clustering)
	reward -= _calculate_spacing_penalty(u, all_units)

	return reward

func _calculate_combat_reward(u: RTSUnit) -> float:
	"""Calculate combat-based rewards (damage, kills, deaths)."""
	var reward: float = 0.0

	reward += u.damage_dealt_this_step * reward_damage_to_unit
	reward += u.damage_to_base_this_step * reward_damage_to_base
	reward += u.kills_this_step * reward_unit_kill
	reward += u.base_kills_this_step * reward_base_kill
	reward -= u.damage_received_this_step * penalty_damage_received

	if u.died_this_step:
		reward -= penalty_death

	return reward

func _calculate_team_outcome_reward(u: RTSUnit, game_won: bool, game_lost: bool) -> float:
	"""Calculate team victory/defeat rewards."""
	var reward: float = 0.0

	if game_won and not u.is_enemy:
		reward += reward_team_victory
	elif game_lost and not u.is_enemy:
		reward -= penalty_team_defeat
	elif game_won and u.is_enemy:
		reward -= penalty_team_defeat
	elif game_lost and u.is_enemy:
		reward += reward_team_victory

	return reward

func _calculate_positional_reward(
	u: RTSUnit,
	ally_base: Node,
	enemy_base: Node,
	map_center: Vector2
) -> float:
	"""
	Calculate positional reward based on proximity to enemy base.
	Encourages units to move toward the objective.
	"""
	var enemy_base_pos: Vector2

	# Determine enemy base position based on unit faction
	if u.is_enemy and ally_base and is_instance_valid(ally_base):
		enemy_base_pos = ally_base.global_position
	elif not u.is_enemy and enemy_base and is_instance_valid(enemy_base):
		enemy_base_pos = enemy_base.global_position
	else:
		enemy_base_pos = map_center  # Fallback if base destroyed

	var dist_to_objective = u.global_position.distance_to(enemy_base_pos)
	var max_dist = GameConfig.MAP_WIDTH  # Normalize by map width
	var normalized_dist = clamp(dist_to_objective / max_dist, 0.0, 1.0)
	var position_reward = reward_position_multiplier * (1.0 - normalized_dist)

	return position_reward

func _calculate_survival_reward(u: RTSUnit) -> float:
	"""Small reward for staying alive each step."""
	if not u.died_this_step:
		return reward_alive_per_step
	return 0.0

func _calculate_spacing_penalty(u: RTSUnit, all_units: Array) -> float:
	"""
	Calculate stacking penalty for units clustering too closely together.
	Each ally within threshold adds a penalty proportional to proximity.
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
			spacing_penalty += reward_tactical_spacing * proximity_ratio

	return spacing_penalty
