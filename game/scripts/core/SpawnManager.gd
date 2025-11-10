# SpawnManager.gd - Centralized spawning logic for RTS training
#
# Encapsulates all spawning logic (bases and units).
# Separating this from Game.gd makes it easier to:
# - Test spawn logic in isolation
# - Modify spawn patterns without touching game logic
# - Support different spawn strategies
# - Handle spawn side alternation cleanly

class_name SpawnManager

# Map dimensions
var map_w: int
var map_h: int

# Spawn configuration
var num_ally_units: int
var num_enemy_units: int

# Scene references
var base_scene: PackedScene
var parent_node: Node2D  # Where to add children

func _init(
	p_map_w: int,
	p_map_h: int,
	p_num_ally_units: int,
	p_num_enemy_units: int,
	p_base_scene: PackedScene,
	p_parent_node: Node2D
):
	map_w = p_map_w
	map_h = p_map_h
	num_ally_units = p_num_ally_units
	num_enemy_units = p_num_enemy_units
	base_scene = p_base_scene
	parent_node = p_parent_node

func spawn_bases(swap_spawn_sides: bool) -> Dictionary:
	"""
	Spawn ally and enemy bases randomly within their respective halves of the map.

	Map halves (with spawn side alternation):
	- Normal (even episodes): Ally left half, Enemy right half
	- Swapped (odd episodes): Ally right half, Enemy left half

	Random placement ensures varied strategic scenarios and prevents
	position-specific learning.

	Args:
		swap_spawn_sides: True to swap ally/enemy spawn halves

	Returns:
		Dictionary with keys:
		- ally_base: Spawned ally base node
		- enemy_base: Spawned enemy base node
	"""
	var rng = RandomNumberGenerator.new()
	rng.randomize()

	# Define safe margins from map edges (from GameConfig)
	var margin_x = GameConfig.BASE_SPAWN_MARGIN_X
	var margin_y = GameConfig.BASE_SPAWN_MARGIN_Y

	# Calculate team halves
	var half_map_x = GameConfig.get_half_map_width()

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
	var ally_base = base_scene.instantiate()
	ally_base.is_enemy = false
	ally_base.position = Vector2(ally_base_x, ally_base_y)
	parent_node.add_child(ally_base)
	print("SpawnManager: Spawned ally base at (", ally_base_x, ", ", ally_base_y, ")")

	# Spawn enemy base
	var enemy_base = base_scene.instantiate()
	enemy_base.is_enemy = true
	enemy_base.position = Vector2(enemy_base_x, enemy_base_y)
	parent_node.add_child(enemy_base)
	print("SpawnManager: Spawned enemy base at (", enemy_base_x, ", ", enemy_base_y, ")")

	return {
		"ally_base": ally_base,
		"enemy_base": enemy_base
	}

func spawn_all_units(swap_spawn_sides: bool) -> void:
	"""
	Spawn all ally and enemy units with a mix of infantry and snipers.

	Implements spawn side alternation for position-invariant learning:
	- Even episodes (0, 2, 4...): allies spawn left, enemies right
	- Odd episodes (1, 3, 5...): allies spawn right, enemies left

	This prevents the AI from learning position-specific strategies and ensures
	robust tactical behavior regardless of spawn location.

	Unit composition (from GameConfig):
	- Ally units: 1/3 snipers (long range), 2/3 infantry (balanced)
	- Enemy units: 1/3 snipers (long range), 2/3 infantry (balanced)

	Units are spawned in a grid formation using GameConfig parameters.

	Args:
		swap_spawn_sides: True to swap ally/enemy spawn halves
	"""
	var spawnbox_start_x_1 = GameConfig.UNIT_SPAWNBOX_X_LEFT
	var spawnbox_start_y_1 = GameConfig.UNIT_SPAWNBOX_Y

	var spawnbox_start_x_2 = GameConfig.UNIT_SPAWNBOX_X_RIGHT
	var spawnbox_start_y_2 = GameConfig.UNIT_SPAWNBOX_Y

	var spawn_spacing_x = GameConfig.UNIT_SPAWN_SPACING_X
	var spawn_spacing_y = GameConfig.UNIT_SPAWN_SPACING_Y

	var spawn_rows = GameConfig.UNIT_SPAWN_COLUMNS

	# Determine spawn positions based on swap_spawn_sides
	var ally_x = spawnbox_start_x_1 if not swap_spawn_sides else spawnbox_start_x_2
	var ally_y = spawnbox_start_y_1 if not swap_spawn_sides else spawnbox_start_y_2
	var enemy_x = spawnbox_start_x_2 if not swap_spawn_sides else spawnbox_start_x_1
	var enemy_y = spawnbox_start_y_2 if not swap_spawn_sides else spawnbox_start_y_1

	var spawn_side_label = "normal" if not swap_spawn_sides else "SWAPPED"
	print("SpawnManager: Spawning units (", spawn_side_label, "): allies at (", ally_x, ", ", ally_y, "), enemies at (", enemy_x, ", ", enemy_y, ")")

	# Create ally units with sequential IDs (mix of infantry, snipers, and heavy units)
	print("SpawnManager: Creating ", num_ally_units, " ally units...")
	for i in range(num_ally_units):
		var pos = Vector2(ally_x + (i % spawn_rows) * spawn_spacing_x, ally_y + (i / spawn_rows) * spawn_spacing_y)
		# Spawn heavy units every HEAVY_SPAWN_INTERVAL, snipers every SNIPER_SPAWN_INTERVAL, otherwise infantry
		var unit_type = Global.UnitType.INFANTRY
		if i % GameConfig.HEAVY_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.HEAVY
		elif i % GameConfig.SNIPER_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.SNIPER
		Global.spawnUnit(pos, false, unit_type)

	# Create enemy units with sequential IDs (mix of infantry, snipers, and heavy units)
	print("SpawnManager: Creating ", num_enemy_units, " enemy units...")
	for i in range(num_enemy_units):
		var pos = Vector2(enemy_x + (i % spawn_rows) * spawn_spacing_x, enemy_y + (i / spawn_rows) * spawn_spacing_y)
		# Spawn heavy units every HEAVY_SPAWN_INTERVAL, snipers every SNIPER_SPAWN_INTERVAL, otherwise infantry
		var unit_type = Global.UnitType.INFANTRY
		if i % GameConfig.HEAVY_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.HEAVY
		elif i % GameConfig.SNIPER_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.SNIPER
		Global.spawnUnit(pos, true, unit_type)

	print("SpawnManager: All units spawned successfully")
