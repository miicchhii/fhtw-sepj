# Game.gd - Main game controller for RTS multi-agent training
#
# Manages:
# - 100 RTS units (50 allies, 50 enemies)
# - AI training integration via AiServer
# - Episode management and resets
# - Reward calculation for reinforcement learning
# - Spawn side alternation for robust learning
extends Node2D
class_name Game

# Physics and timing
var tick: int = 0               # Physics tick counter (60 ticks per second)
var ai_step: int = 0            # AI step counter (independent of physics ticks)
var ai_tick_interval: int = 15  # Run AI logic every 15 physics ticks (~4 AI steps/second)

# Map dimensions
var map_w: int = 1280*2  # Map width in pixels
var map_h: int = 720*2   # Map height in pixels

# Episode management
var episode_ended: bool = false  # True when episode terminates
var max_episode_steps: int = 500  # Maximum AI steps per episode

# Unit configuration
var num_ally_units_start = 50   # Number of ally units to spawn
var num_enemy_units_start = 50  # Number of enemy units to spawn

# AI control toggle (N key = AI, M key = manual)
var ai_controls_allies: bool = true  # Whether AI controls ally units

# Spawn side alternation for position-invariant learning
# Prevents AI from learning position-specific strategies
var episode_count: int = 0          # Total episodes completed
var swap_spawn_sides: bool = false  # True to swap ally/enemy spawn sides

var units = []
var unit_scene = preload("res://scenes/units/infantry.tscn")
var next_unit_id = 1

# Base configuration
var base_scene = preload("res://scenes/buildings/base.tscn")
var ally_base: Node = null
var enemy_base: Node = null

# Reward configuration - adjust these to tune AI behavior
# Combat rewards
var reward_damage_to_unit: float = 0.2       # Reward per damage point to enemy units
var reward_damage_to_base: float = 1.0       # Reward per damage point to enemy base
var reward_unit_kill: float = 15.0           # Reward for killing an enemy unit
var reward_base_kill: float = 200.0          # Reward for destroying enemy base
var penalty_damage_received: float = 0.1     # Penalty per damage point received
var penalty_death: float = 5.0               # Penalty for dying

# Team outcome rewards
var reward_team_victory: float = 50.0        # Bonus when your team wins
var penalty_team_defeat: float = 25.0        # Penalty when your team loses

# Positional rewards
var reward_position_multiplier: float = 1.5  # Multiplier for proximity to enemy base (0.5 at base, 0.0 at far edge)

# Survival reward
var reward_alive_per_step: float = 0.01      # Small reward for staying alive each step

# Movement efficiency rewards
var reward_continue_straight: float = 0.5    # Reward for maintaining direction (0° angle)
var penalty_reverse_direction: float = 1   # Penalty for reversing direction (180° angle)

# Base damage penalty (applied to entire team when their base takes damage)
var penalty_base_damage_per_unit: float = 0.5  # Penalty per damage point to your base, divided among all units

# Tactical spacing (anti-clustering)
var reward_tactical_spacing: float = 0.1       # Penalty per nearby ally within threshold
var tactical_spacing_threshold: float = 100.0  # Minimum desired ally spacing (pixels)

func _ready() -> void:
	spawn_bases()
	init_units()
	get_units()

	# IMPORTANT: Add this node to the "game" group so AiServer can find it
	add_to_group("game")
	print("Game: Added to 'game' group")

func spawn_bases():
	"""
	Spawn ally and enemy bases randomly within their respective halves of the map.

	Map halves (with spawn side alternation):
	- Normal (even episodes): Ally left half, Enemy right half
	- Swapped (odd episodes): Ally right half, Enemy left half

	Random placement ensures varied strategic scenarios and prevents
	position-specific learning.
	"""
	var rng = RandomNumberGenerator.new()
	rng.randomize()

	# Define safe margins from map edges (pixels)
	var margin_x = 150  # Horizontal margin
	var margin_y = 150  # Vertical margin

	# Calculate team halves
	var half_map_x = map_w / 2.0

	# Determine which half each team spawns in
	var ally_x_min: float
	var ally_x_max: float
	var enemy_x_min: float
	var enemy_x_max: float

	if not swap_spawn_sides:
		# Normal: Ally left, Enemy right
		ally_x_min = margin_x
		ally_x_max = half_map_x - margin_x
		enemy_x_min = half_map_x + margin_x
		enemy_x_max = map_w - margin_x
	else:
		# Swapped: Ally right, Enemy left
		ally_x_min = half_map_x + margin_x
		ally_x_max = map_w - margin_x
		enemy_x_min = margin_x
		enemy_x_max = half_map_x - margin_x

	# Random positions within team halves
	var ally_base_x = rng.randf_range(ally_x_min, ally_x_max)
	var ally_base_y = rng.randf_range(margin_y, map_h - margin_y)
	var enemy_base_x = rng.randf_range(enemy_x_min, enemy_x_max)
	var enemy_base_y = rng.randf_range(margin_y, map_h - margin_y)

	# Spawn ally base
	ally_base = base_scene.instantiate()
	ally_base.is_enemy = false
	ally_base.position = Vector2(ally_base_x, ally_base_y)
	add_child(ally_base)
	print("Spawned ally base at (", ally_base_x, ", ", ally_base_y, ")")

	# Spawn enemy base
	enemy_base = base_scene.instantiate()
	enemy_base.is_enemy = true
	enemy_base.position = Vector2(enemy_base_x, enemy_base_y)
	add_child(enemy_base)
	print("Spawned enemy base at (", enemy_base_x, ", ", enemy_base_y, ")")

func spawn_all_units():
	"""
	Spawn all ally and enemy units with a mix of infantry and snipers.

	Implements spawn side alternation for position-invariant learning:
	- Even episodes (0, 2, 4...): allies spawn left (x=300), enemies right (x=700)
	- Odd episodes (1, 3, 5...): allies spawn right (x=700), enemies left (x=300)

	This prevents the AI from learning position-specific strategies and ensures
	robust tactical behavior regardless of spawn location.

	Unit composition:
	- 50 ally units: 1/3 snipers (long range), 2/3 infantry (balanced)
	- 50 enemy units: 1/3 snipers (long range), 2/3 infantry (balanced)

	Units are spawned in a 5-column grid formation with 60-pixel spacing.
	"""
	
	var spawnbox_start_x_1 = 50
	var spawnbox_start_y_1 = 100

	var spawnbox_start_x_2 = map_w/2
	var spawnbox_start_y_2 = 100

	var spawn_spacing_x = 250/1
	var spawn_spacing_y = 133/1

	var spawn_rows = 5

	# Determine spawn positions based on swap_spawn_sides
	var ally_x = spawnbox_start_x_1 if not swap_spawn_sides else spawnbox_start_x_2
	var ally_y = spawnbox_start_y_1 if not swap_spawn_sides else spawnbox_start_y_2
	var enemy_x = spawnbox_start_x_2 if not swap_spawn_sides else spawnbox_start_x_1
	var enemy_y = spawnbox_start_y_2 if not swap_spawn_sides else spawnbox_start_y_1

	var spawn_side_label = "normal" if not swap_spawn_sides else "SWAPPED"
	print("Spawning units (", spawn_side_label, "): allies at (", ally_x, ", ", ally_y, "), enemies at (", enemy_x, ", ", enemy_y, ")")

	# Create ally units with sequential IDs (mix of infantry and snipers)
	print("Creating ally units...")
	for i in range(num_ally_units_start):
		var pos = Vector2(ally_x + (i % spawn_rows) * spawn_spacing_x, ally_y + (i / spawn_rows) * spawn_spacing_y)
		# Spawn snipers for every 3rd unit (roughly 1/3 snipers, 2/3 infantry)
		var unit_type = Global.UnitType.SNIPER if i % 3 == 0 else Global.UnitType.INFANTRY
		Global.spawnUnit(pos, false, unit_type)

	# Create enemy units with sequential IDs (mix of infantry and snipers)
	print("Creating enemy units...")
	for i in range(num_enemy_units_start):
		var pos = Vector2(enemy_x + (i % spawn_rows) * spawn_spacing_x, enemy_y + (i / spawn_rows) * spawn_spacing_y)
		# Spawn snipers for every 3rd unit (roughly 1/3 snipers, 2/3 infantry)
		var unit_type = Global.UnitType.SNIPER if i % 3 == 0 else Global.UnitType.INFANTRY
		Global.spawnUnit(pos, true, unit_type)

func init_units():
	print("Starting init_units()")

	var units_container = get_node("Units")
	print("Units container found: ", units_container != null)
	if not units_container:
		units_container = Node2D.new()
		units_container.name = "Units"
		add_child(units_container)
		print("Created new Units container")

	spawn_all_units()
	print("init_units() completed")

func get_units():
	units = null
	units = get_tree().get_nodes_in_group("units")

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_N:  # N key - Enable AI control
			ai_controls_allies = true
			print("AI now controls ally units")
		elif event.keycode == KEY_M:  # M key - Manual control
			ai_controls_allies = false
			print("Manual control enabled for ally units")

func _physics_process(_delta: float) -> void:
	tick += 1

	# Unit movement is now handled in their individual _physics_process methods
	# No need to call step() anymore since it's empty

	# Only process AI logic every ai_tick_interval ticks
	if tick % ai_tick_interval == 0:
		# Only process AI logic when we have actions from Python
		var action_batches = AiServer.pop_actions()
		if action_batches.size() > 0:
			ai_step += 1  # Increment AI step counter only when we get actions
			#print("Game: Processing AI step ", ai_step, " at tick ", tick, " with ", action_batches.size(), " action batches")

			# Apply actions (from AiServer)
			for actions: Dictionary in action_batches:
				_apply_actions(actions)

			# Send obs + rewards
			var obs := _build_observation()
			#print("Game: Sending observation for AI step ", ai_step)
			AiServer.send_observation(obs)

			var center := Vector2(map_w * 0.5, map_h * 0.5)
			var rewards := {}
			var dones := {}

			# Calculate base damage penalties for teams
			var ally_base_damage_penalty: float = 0.0
			var enemy_base_damage_penalty: float = 0.0

			if ally_base and is_instance_valid(ally_base):
				if ally_base.damage_taken_this_step > 0:
					ally_base_damage_penalty = ally_base.damage_taken_this_step * penalty_base_damage_per_unit

			if enemy_base and is_instance_valid(enemy_base):
				if enemy_base.damage_taken_this_step > 0:
					enemy_base_damage_penalty = enemy_base.damage_taken_this_step * penalty_base_damage_per_unit

			# Check for victory/defeat conditions
			var ally_units = get_tree().get_nodes_in_group("ally")
			var enemy_units = get_tree().get_nodes_in_group("enemy")
			var allies_alive = ally_units.size()
			var enemies_alive = enemy_units.size()

			# Check base destruction
			var ally_base_destroyed = (ally_base == null or not is_instance_valid(ally_base))
			var enemy_base_destroyed = (enemy_base == null or not is_instance_valid(enemy_base))

			var game_won = (enemies_alive == 0 and allies_alive > 0) or enemy_base_destroyed
			var game_lost = (allies_alive == 0 and enemies_alive > 0) or ally_base_destroyed

			# Check for episode end condition
			var should_end_episode = (ai_step >= max_episode_steps) or game_won or game_lost

			# DEBUG: Log episode termination variables
			#print("Game: Episode termination check - ai_step=", ai_step, " max_episode_steps=", max_episode_steps, " should_end_episode=", should_end_episode, " episode_ended=", episode_ended)

			for u: RTSUnit in get_tree().get_nodes_in_group("units"):
				# Skip reward calculation for manually controlled ally units
				# Only calculate rewards for AI-controlled units (enemies + allies when AI is enabled)
				if not u.is_enemy and not ai_controls_allies:
					u.reset_combat_stats()  # Still reset stats to avoid accumulation
					continue

				var reward: float = 0.0

				# Combat-based rewards (primary)
				reward += u.damage_dealt_this_step * reward_damage_to_unit
				reward += u.damage_to_base_this_step * reward_damage_to_base
				reward += u.kills_this_step * reward_unit_kill
				reward += u.base_kills_this_step * reward_base_kill
				reward -= u.damage_received_this_step * penalty_damage_received
				if u.died_this_step:
					reward -= penalty_death

				# Team outcome rewards
				if game_won and not u.is_enemy:
					reward += reward_team_victory
				elif game_lost and not u.is_enemy:
					reward -= penalty_team_defeat
				elif game_won and u.is_enemy:
					reward -= penalty_team_defeat
				elif game_lost and u.is_enemy:
					reward += reward_team_victory

				# Positional reward: encourage moving toward enemy base (objective-focused)
				var enemy_base_pos: Vector2
				if u.is_enemy and ally_base and is_instance_valid(ally_base):
					enemy_base_pos = ally_base.global_position
				elif not u.is_enemy and enemy_base and is_instance_valid(enemy_base):
					enemy_base_pos = enemy_base.global_position
				else:
					enemy_base_pos = center  # Fallback to center if base destroyed

				var dist_to_objective: float = u.global_position.distance_to(enemy_base_pos)
				var max_dist: float = 1280.0  # Map width
				var normalized_dist: float = clamp(dist_to_objective / max_dist, 0.0, 1.0)
				var position_reward = reward_position_multiplier * (1.0 - normalized_dist)
				reward += position_reward

				# Survival reward
				if not u.died_this_step:
					reward += reward_alive_per_step

				# Movement efficiency reward/penalty
				reward += u.direction_change_reward

				# Base damage penalty (shared by entire team)
				if not u.is_enemy:
					reward -= ally_base_damage_penalty
				else:
					reward -= enemy_base_damage_penalty

				# Tactical spacing: Penalize for each ally too close (stacking penalty)
				var spacing_penalty: float = 0.0
				var nearby_ally_count: int = 0

				for other_unit in get_tree().get_nodes_in_group("units"):
					if other_unit == u:
						continue  # Skip self

					# Check if same faction
					if other_unit.is_enemy != u.is_enemy:
						continue  # Only care about allies

					var distance = u.global_position.distance_to(other_unit.global_position)

					if distance < tactical_spacing_threshold:
						# Calculate penalty based on how close they are
						# Closer = bigger penalty
						var proximity_ratio = 1.0 - (distance / tactical_spacing_threshold)
						spacing_penalty += reward_tactical_spacing * proximity_ratio
						nearby_ally_count += 1

				reward -= spacing_penalty

				# Optional: Debug log for tuning (comment out after testing)
				# if nearby_ally_count > 3:
				# 	print("Unit ", u.unit_id, " has ", nearby_ally_count, " allies too close, penalty: ", spacing_penalty)

				rewards[u.unit_id] = reward
				dones[u.unit_id] = should_end_episode

				# Reset combat stats for next step
				u.reset_combat_stats()

			# CRITICAL: Send rewards immediately after observation, don't wait
			#print("Game: Sending rewards - should_end_episode: ", should_end_episode, " dones: ", dones)
			AiServer.send_reward(0.0, should_end_episode, {"rewards": rewards, "dones": dones})

			# Reset base damage tracking for next step
			if ally_base and is_instance_valid(ally_base):
				ally_base.reset_damage_tracking()
			if enemy_base and is_instance_valid(enemy_base):
				enemy_base.reset_damage_tracking()

			# Force process to ensure message is sent immediately
			await get_tree().process_frame

			# IMPORTANT: Only reset AFTER sending the done signal
			if should_end_episode and not episode_ended:
				episode_ended = true
				print("Episode ended at ai_step ", ai_step, " (physics_tick ", tick, ") - waiting for Python reset...")
				# Don't auto-reset here - let Python handle the reset via _ai_request_reset()

func _build_observation() -> Dictionary:
	"""
	Build observation dictionary for all units to send to Python training.

	Observation structure (94 dimensions per unit):
	- Base (3): vel_x, vel_y, hp_ratio
	- Battle stats (5): attack_range, attack_damage, attack_cooldown, remaining_cooldown, speed
	- Closest 10 allies (40): direction (2D), distance, hp_ratio (4 values × 10)
	- Closest 10 enemies (40): direction (2D), distance, hp_ratio (4 values × 10)
	- Points of interest (6): 2 POIs × (direction (2D), distance) = enemy base + own base

	The observation is sent to godot_multi_env.py which converts it to the RLlib format
	(94-dimensional Box space normalized to appropriate ranges).

	Note: Velocity replaces absolute position to prevent position-specific learning and
	enable direction consistency rewards. Velocity reflects actual achieved movement
	after collisions (from Godot's move_and_slide). This allows the AI to:
	1. Learn position-invariant strategies (no "always go left" bias)
	2. See its own previous movement direction for smooth trajectory learning

	Returns:
		Dictionary with keys:
		- ai_step: Current AI step counter (independent of physics ticks)
		- tick: Physics tick counter (60 ticks per second)
		- map: Map dimensions {w: 2560, h: 1440}
		- units: Array of unit observation dictionaries
	"""
	var all_units = get_tree().get_nodes_in_group("units")
	var arr: Array = []

	for u: RTSUnit in all_units:
		# Define POI as opponent's base location (different for each unit based on faction)
		var points_of_interest: Array = []
		if u.is_enemy:
			# Enemy units target ally base
			if enemy_base and is_instance_valid(enemy_base) and ally_base and is_instance_valid(ally_base):
				points_of_interest.append(ally_base.global_position)
				points_of_interest.append(enemy_base.global_position)
			else:
				points_of_interest.append(Vector2(map_w * 0.5, map_h * 0.5))  # Fallback to center
		else:
			# Ally units target enemy base
			if enemy_base and is_instance_valid(enemy_base) and ally_base and is_instance_valid(ally_base):
				points_of_interest.append(enemy_base.global_position)
				points_of_interest.append(ally_base.global_position)
			else:
				points_of_interest.append(Vector2(map_w * 0.5, map_h * 0.5))  # Fallback to center

		# Get closest allies and enemies (10 each for spatial awareness)
		var closest_allies = _get_closest_units(u, all_units, false, 10)  # 10 closest allies
		var closest_enemies = _get_closest_units(u, all_units, true, 10)   # 10 closest enemies

		# Get POI data (direction + distance for each POI)
		var poi_data = _get_poi_data(u, points_of_interest)

		# Update unit's POI positions for debug visualization
		u.set_poi_positions(points_of_interest)

		# Extract positions from closest allies/enemies for visualization
		var ally_positions: Array = []
		for ally_data in closest_allies:
			# Reconstruct position from direction and distance
			var direction = Vector2(ally_data["direction"][0], ally_data["direction"][1])
			var distance = ally_data["distance"]
			if direction != Vector2.ZERO and distance > 0:
				var ally_pos = u.global_position + direction * distance
				ally_positions.append(ally_pos)

		var enemy_positions: Array = []
		for enemy_data in closest_enemies:
			# Reconstruct position from direction and distance
			var direction = Vector2(enemy_data["direction"][0], enemy_data["direction"][1])
			var distance = enemy_data["distance"]
			if direction != Vector2.ZERO and distance > 0:
				var enemy_pos = u.global_position + direction * distance
				enemy_positions.append(enemy_pos)

		# Update unit's closest units positions for debug visualization
		u.set_closest_units_positions(ally_positions, enemy_positions)

		arr.append({
			"id": u.unit_id,
			"policy_id": u.policy_id,  # Include policy assignment
			"type_id": u.type_id,
			"hp": u.hp,
			"max_hp": u.max_hp,
			"velocity": [u.velocity.x, u.velocity.y],  # Actual achieved velocity (collision-aware)
			"is_enemy": u.is_enemy,
			# Battle stats
			"attack_range": u.attack_range,
			"attack_damage": u.attack_damage,
			"attack_cooldown": u.attack_cooldown,
			"attack_cooldown_remaining": u._atk_cd,
			"speed": u.Speed,
			"closest_allies": closest_allies,
			"closest_enemies": closest_enemies,
			"points_of_interest": poi_data
		})
	return {
		"ai_step": ai_step,  # Send AI step instead of physics tick
		"tick": tick,
		"map": {"w": map_w, "h": map_h},
		"units": arr,
	}

func _get_closest_units(source_unit: RTSUnit, all_units: Array, find_enemies: bool, max_count: int) -> Array:
	"""
	Find the closest N units of a specific faction relative to source_unit.

	This function is used to build spatial awareness observations for each unit.
	It finds nearby allies or enemies and returns their relative position,
	distance, and health ratio.

	Args:
		source_unit: The unit for which we're finding nearby units
		all_units: Array of all units in the game
		find_enemies: True to find enemies, False to find allies
		max_count: Maximum number of units to return (e.g., 10)

	Returns:
		Array of dictionaries (length = max_count, padded with zeros if needed):
		- direction: [x, y] normalized direction vector from source to target
		- distance: Euclidean distance in pixels
		- hp_ratio: Target's current HP / max HP (0.0 to 1.0)
	"""
	var candidates: Array = []

	# Filter units by faction (allies vs enemies relative to source_unit)
	for u: RTSUnit in all_units:
		if u == source_unit:
			continue  # Skip self

		# If source is enemy, allies are other enemies, enemies are non-enemies
		# If source is ally, allies are other allies, enemies are enemies
		var is_same_faction = (u.is_enemy == source_unit.is_enemy)

		if find_enemies and is_same_faction:
			continue  # Looking for enemies but found ally
		if not find_enemies and not is_same_faction:
			continue  # Looking for allies but found enemy

		var distance = source_unit.global_position.distance_to(u.global_position)
		candidates.append({"unit": u, "distance": distance})

	# Sort by distance (closest first)
	candidates.sort_custom(func(a, b): return a.distance < b.distance)

	# Take only the closest max_count units
	var result: Array = []
	var count = min(candidates.size(), max_count)

	for i in range(count):
		var unit_data = candidates[i]
		var u: RTSUnit = unit_data.unit
		var distance: float = unit_data.distance

		# Calculate directional vector (normalized)
		var direction = (u.global_position - source_unit.global_position).normalized()

		result.append({
			"direction": [direction.x, direction.y],
			"distance": distance,
			"hp_ratio": float(u.hp) / float(u.max_hp) if u.max_hp > 0 else 0.0
		})

	# Pad with empty entries if we have fewer than max_count units
	while result.size() < max_count:
		result.append({
			"direction": [0.0, 0.0],
			"distance": 0.0,
			"hp_ratio": 0.0
		})

	return result

func _get_poi_data(source_unit: RTSUnit, pois: Array) -> Array:
	"""
	Get directional vectors and distances to points of interest.

	Similar to _get_closest_units, but for static map locations like:
	- Map center (reward zone)
	- Control points
	- Resource locations
	- Strategic positions

	Args:
		source_unit: The unit for which we're calculating POI data
		pois: Array of Vector2 positions representing points of interest

	Returns:
		Array of dictionaries (one per POI):
		- direction: [x, y] normalized direction vector from source to POI
		- distance: Euclidean distance in pixels
	"""
	var result: Array = []

	for poi_pos in pois:
		# Calculate distance and direction to this POI
		var distance = source_unit.global_position.distance_to(poi_pos)
		var direction = (poi_pos - source_unit.global_position).normalized()

		result.append({
			"direction": [direction.x, direction.y],
			"distance": distance
		})

	return result

func _apply_actions(actions: Dictionary) -> void:
	"""
	Apply movement actions from Python AI to Godot units.

	Receives actions from godot_multi_env.py using continuous 2D action space.
	Actions are [dx, dy] vectors in range [-1, 1] where:
	- Direction: Normalized vector direction (e.g., [1,1] → 45° northeast)
	- Magnitude: Fraction of full step to take (e.g., |[1,1]| = 1.41 → clamped to 1.0 = full step)

	Examples:
	- [1.0, 1.0]: Full step (200px) at 45° northeast
	- [0.0, 1.0]: Full step (200px) straight north
	- [0.5, 0.5]: 71% step (141px) at 45° northeast
	- [0.5, 0.0]: Half step (100px) straight east

	Action format from Python:
	{
		"u1": {"move_vector": [dx, dy]},
		"u2": {"move_vector": [dx, dy]},
		...
	}

	The AI control toggle (N/M keys) allows switching between AI and manual control
	for ally units. Enemy units are always AI-controlled.

	Args:
		actions: Dictionary mapping unit IDs to action dictionaries with move_vector
	"""
	# actions expected shape: { "u1": {"move_vector":[dx, dy]}, ... }
	for id_var in actions.keys():
		var id: String = String(id_var)

		var u: RTSUnit = _get_unit(id)
		if u == null:
			continue

		# Only apply AI actions to ally units if AI control is enabled
		# Enemy units are always AI controlled
		if not u.is_enemy and not ai_controls_allies:
			continue  # Skip AI actions for ally units when in manual control mode

		var a := actions[id] as Dictionary
		if a.has("move_vector"):
			var vec := a["move_vector"] as Array
			if vec.size() >= 2:
				var dx: float = float(vec[0])
				var dy: float = float(vec[1])

				# Interpret action as: direction (normalized) + magnitude (fraction of full step)
				var action_vector = Vector2(dx, dy)
				var action_magnitude = action_vector.length()

				# Maximum movement distance per AI step
				var stepsize: float = 200.0

				# Calculate movement offset
				var move_offset: Vector2
				if action_magnitude > 0.01:  # Avoid division by zero
					# Normalize direction, then scale by magnitude fraction (clamped to 1.0)
					var direction = action_vector.normalized()
					var step_fraction = min(action_magnitude, 1.0)  # Clamp to max 1.0
					move_offset = direction * (step_fraction * stepsize)
				else:
					# Zero or near-zero action = no movement
					move_offset = Vector2.ZERO

				# Calculate new target position from current position
				var new_target = u.global_position + move_offset

				# Clamp to map boundaries
				new_target.x = clamp(new_target.x, 0, map_w)
				new_target.y = clamp(new_target.y, 0, map_h)

				# Calculate direction change reward/penalty
				var new_direction = (new_target - u.global_position).normalized()

				# Only calculate if we have a previous direction and both directions are non-zero
				if u.previous_move_direction.length_squared() > 0.01 and new_direction.length_squared() > 0.01:
					# Calculate dot product to get cosine of angle
					var dot = u.previous_move_direction.dot(new_direction)
					dot = clamp(dot, -1.0, 1.0)  # Clamp for numerical stability

					# Convert to angle in degrees
					var angle_rad = acos(dot)
					var angle_deg = rad_to_deg(angle_rad)

					# Linear interpolation using configurable values
					# reward_continue_straight at 0° to -penalty_reverse_direction at 180°
					var reward_range = reward_continue_straight + penalty_reverse_direction
					u.direction_change_reward = reward_continue_straight - (angle_deg / 180.0) * reward_range
				else:
					# No penalty for first move or stationary units
					u.direction_change_reward = 0.0

				# Store current direction for next comparison
				if new_direction.length_squared() > 0.01:
					u.previous_move_direction = new_direction

				u.set_move_target(new_target)

func _get_unit(id: String) -> RTSUnit:
	for u: RTSUnit in get_tree().get_nodes_in_group("units"):
		if u.unit_id == id:
			return u
	return null

func _ai_request_reset() -> void:
	"""
	Reset the game episode when called by Python training system.

	This function is called by AiServer when Python sends a reset request after
	an episode terminates. It handles:
	- Clearing all units and resetting counters
	- Alternating spawn sides for position-invariant learning
	- Respawning all units with fresh IDs
	- Sending initial observation to Python

	Episode termination conditions:
	- ai_step >= max_episode_steps (default 100)
	- All allies dead (game lost)
	- All enemies dead (game won)

	Spawn side alternation:
	- Episode 0, 2, 4... (even): allies left, enemies right
	- Episode 1, 3, 5... (odd): allies right, enemies left

	This prevents the AI from learning position-dependent strategies like
	"always move right" instead of "move toward enemies".
	"""
	print("Game: Resetting episode...")
	tick = 0
	ai_step = 0
	episode_ended = false

	# Increment episode count and alternate spawn sides
	episode_count += 1
	swap_spawn_sides = (episode_count % 2 == 1)  # Swap on odd episodes

	# Remove all existing bases
	if ally_base and is_instance_valid(ally_base):
		ally_base.queue_free()
	if enemy_base and is_instance_valid(enemy_base):
		enemy_base.queue_free()

	# Remove all existing units
	for u in get_tree().get_nodes_in_group("units"):
		u.queue_free()

	# Wait for units and bases to be removed
	await get_tree().process_frame

	# Reset unit ID counter to start fresh
	Global.next_unit_id = 1

	# Respawn bases and units using the reusable functions
	print("Respawning bases and units (episode ", episode_count, ")...")
	spawn_bases()
	spawn_all_units()

	# Refresh units array
	get_units()

	print("Game: Reset complete with ", num_ally_units_start, " ally units and ", num_enemy_units_start, " enemy units")

	# Send initial observation immediately after reset
	var obs := _build_observation()
	print("Game: Sending initial observation with ", obs["units"].size(), " units")
	AiServer.send_observation(obs)

#new code - lukas

func _on_area_selected(object):
	var start = object.start
	var end   = object.end

	var a0 = Vector2(min(start.x, end.x), min(start.y, end.y))
	var a1 = Vector2(max(start.x, end.x), max(start.y, end.y))

	var ut = get_units_in_area([a0, a1])   # your area query that reads from "ally"

	# 1) Deselect all *live* allies
	for u in get_tree().get_nodes_in_group("ally"):
		if u != null and is_instance_valid(u) and u.has_method("set_selected"):
			u.set_selected(false)

	# 2) Select the ones inside the area
	for u in ut:
		if u != null and is_instance_valid(u) and u.has_method("set_selected"):
			u.set_selected(true)   # or toggle if you prefer

	
	
func get_units_in_area(area: Array) -> Array:
	# area[0] and area[1] might be any corners; normalize first
	var a0 := Vector2(min(area[0].x, area[1].x), min(area[0].y, area[1].y))
	var a1 := Vector2(max(area[0].x, area[1].x), max(area[0].y, area[1].y))

	var selected: Array = []
	for unit in get_tree().get_nodes_in_group("ally"):
		if unit == null or not is_instance_valid(unit):
			continue
		var p: Vector2 = unit.global_position
		if p.x >= a0.x and p.x <= a1.x and p.y >= a0.y and p.y <= a1.y:
			selected.append(unit)
	return selected
