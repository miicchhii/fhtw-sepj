# ObservationBuilder.gd - Centralized observation building for RTS training
#
# Encapsulates all observation construction logic for reinforcement learning.
# Separating this from Game.gd makes it easier to:
# - Test observation building in isolation
# - Modify observation structure without touching game logic
# - Understand what data the AI sees
# - Add new observation features systematically

class_name ObservationBuilder

# Map dimensions (cached for performance)
var map_w: int
var map_h: int

func _init(p_map_w: int, p_map_h: int):
	map_w = p_map_w
	map_h = p_map_h

func build_observation(
	ai_step: int,
	tick: int,
	all_units: Array,
	ally_base: Node,
	enemy_base: Node
) -> Dictionary:
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
	var arr: Array = []

	for u: RTSUnit in all_units:
		# Get points of interest for this unit (enemy base + own base)
		var points_of_interest = _get_points_of_interest(u, ally_base, enemy_base)

		# Get closest allies and enemies (10 each for spatial awareness)
		var closest_allies = _get_closest_units(u, all_units, false, GameConfig.MAX_ALLIES_IN_OBS)
		var closest_enemies = _get_closest_units(u, all_units, true, GameConfig.MAX_ENEMIES_IN_OBS)

		# Get POI data (direction + distance for each POI)
		var poi_data = _get_poi_data(u, points_of_interest)

		# Update unit's debug visualization data
		u.set_poi_positions(points_of_interest)
		_update_unit_visualization(u, closest_allies, closest_enemies)

		# Build unit observation dictionary
		arr.append({
			"id": u.unit_id,
			"policy_id": u.policy_id,
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
		"ai_step": ai_step,
		"tick": tick,
		"map": {"w": map_w, "h": map_h},
		"units": arr,
	}

func _get_points_of_interest(u: RTSUnit, ally_base: Node, enemy_base: Node) -> Array:
	"""
	Get points of interest for a unit (enemy base + own base).
	POIs are different for each unit based on faction.
	"""
	var points_of_interest: Array = []
	var map_center = GameConfig.get_map_center()

	if u.is_enemy:
		# Enemy units: target ally base, track own base
		if enemy_base and is_instance_valid(enemy_base) and ally_base and is_instance_valid(ally_base):
			points_of_interest.append(ally_base.global_position)
			points_of_interest.append(enemy_base.global_position)
		else:
			points_of_interest.append(map_center)  # Fallback
			points_of_interest.append(map_center)
	else:
		# Ally units: target enemy base, track own base
		if enemy_base and is_instance_valid(enemy_base) and ally_base and is_instance_valid(ally_base):
			points_of_interest.append(enemy_base.global_position)
			points_of_interest.append(ally_base.global_position)
		else:
			points_of_interest.append(map_center)  # Fallback
			points_of_interest.append(map_center)

	return points_of_interest

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
	- Enemy base (primary objective)
	- Own base (defend)
	- Map center
	- Control points (future feature)

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

func _update_unit_visualization(u: RTSUnit, closest_allies: Array, closest_enemies: Array) -> void:
	"""
	Update unit's debug visualization data (for drawing debug lines).
	Reconstructs positions from direction vectors and distances.
	"""
	# Extract ally positions
	var ally_positions: Array = []
	for ally_data in closest_allies:
		var direction = Vector2(ally_data["direction"][0], ally_data["direction"][1])
		var distance = ally_data["distance"]
		if direction != Vector2.ZERO and distance > 0:
			var ally_pos = u.global_position + direction * distance
			ally_positions.append(ally_pos)

	# Extract enemy positions
	var enemy_positions: Array = []
	for enemy_data in closest_enemies:
		var direction = Vector2(enemy_data["direction"][0], enemy_data["direction"][1])
		var distance = enemy_data["distance"]
		if direction != Vector2.ZERO and distance > 0:
			var enemy_pos = u.global_position + direction * distance
			enemy_positions.append(enemy_pos)

	# Update unit's visualization data
	u.set_closest_units_positions(ally_positions, enemy_positions)
