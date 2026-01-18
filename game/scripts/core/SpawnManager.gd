# SpawnManager.gd - Centralized spawning logic for RTS training
#
# Encapsulates all spawning logic (bases, buildings, and units).
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
var shop_scene: PackedScene
var coin_house_scene: PackedScene
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

	# Preload building scenes
	shop_scene = preload("res://scenes/buildings/robo_shop.tscn")
	coin_house_scene = preload("res://scenes/buildings/coinHouse.tscn")

func spawn_bases(swap_spawn_sides: bool) -> Dictionary:
	"""
	Spawn ally and enemy bases at diagonal corners.

	Normal (swap_spawn_sides = false):
	- Ally base + buildings: bottom-left
	- Enemy base + buildings: top-right

	Swapped (swap_spawn_sides = true):
	- Ally base + buildings: top-right
	- Enemy base + buildings: bottom-left

	This ensures bases and units swap together for position-invariant learning.
	"""
	# Define safe margins from map edges (from GameConfig)
	var margin_x = GameConfig.BASE_SPAWN_MARGIN_X
	var margin_y = GameConfig.BASE_SPAWN_MARGIN_Y

	# Define the two corner positions for bases
	var pos_bottom_left = Vector2(margin_x, map_h - margin_y)
	var pos_top_right = Vector2(map_w - margin_x, margin_y)

	# Assign based on swap_spawn_sides
	var ally_base_pos = pos_bottom_left if not swap_spawn_sides else pos_top_right
	var enemy_base_pos = pos_top_right if not swap_spawn_sides else pos_bottom_left

	var spawn_side_label = "normal" if not swap_spawn_sides else "SWAPPED"

	# Spawn ally base
	var ally_base = base_scene.instantiate()
	ally_base.is_enemy = false
	ally_base.position = ally_base_pos
	parent_node.add_child(ally_base)
	print("SpawnManager: Spawned ally base at ", ally_base_pos, " [", spawn_side_label, "]")

	# Spawn enemy base
	var enemy_base = base_scene.instantiate()
	enemy_base.is_enemy = true
	enemy_base.position = enemy_base_pos
	parent_node.add_child(enemy_base)
	print("SpawnManager: Spawned enemy base at ", enemy_base_pos, " [", spawn_side_label, "]")

	# Spawn buildings for both teams
	_spawn_team_buildings(ally_base_pos, false, swap_spawn_sides)
	_spawn_team_buildings(enemy_base_pos, true, swap_spawn_sides)

	return {
		"ally_base": ally_base,
		"enemy_base": enemy_base
	}

func _spawn_team_buildings(base_pos: Vector2, is_enemy: bool, swap_spawn_sides: bool) -> void:
	"""
	Spawn shop and coin house for a team near their base.

	Buildings are offset from the base position to avoid overlap.
	"""
	var team_name = "enemy" if is_enemy else "ally"

	# Determine horizontal direction for building placement (away from map center)
	# Bottom-left base: buildings to the left/above
	# Top-right base: buildings to the right/below
	var is_bottom_left = base_pos.y > map_h / 2

	# Building offsets from base
	var shop_offset: Vector2
	var coin_house_offset: Vector2

	if is_bottom_left:
		# Bottom-left: place buildings above the base
		shop_offset = Vector2(0, -500)       # Shop above base
		coin_house_offset = Vector2(0, -900) # Coin house further above
	else:
		# Top-right: place buildings below the base
		shop_offset = Vector2(0, 500)        # Shop below base
		coin_house_offset = Vector2(0, 900)  # Coin house further below

	# Spawn shop
	var shop = shop_scene.instantiate()
	shop.position = base_pos + shop_offset
	shop.scale = Vector2(1.6, 1.6)  # Match original scale from scene
	shop.is_enemy = is_enemy  # Set team ownership
	parent_node.add_child(shop)
	print("SpawnManager: Spawned ", team_name, " shop at ", shop.position)

	# Spawn coin house
	var coin_house = coin_house_scene.instantiate()
	coin_house.position = base_pos + coin_house_offset
	coin_house.scale = Vector2(8.7, 8.7)  # Match original scale from scene
	coin_house.is_enemy = is_enemy  # Set team ownership
	parent_node.add_child(coin_house)
	print("SpawnManager: Spawned ", team_name, " coin house at ", coin_house.position)

func spawn_all_units(swap_spawn_sides: bool, ally_policy: String, enemy_policy: String, skip_ai_units: bool = false) -> void:
	"""
	Spawn all ally and enemy units near their respective bases.

	Implements spawn side alternation for position-invariant learning:
	- Even episodes (0, 2, 4...): allies bottom-left, enemies top-right
	- Odd episodes (1, 3, 5...): allies top-right, enemies bottom-left

	Units spawn in a grid formation in their team's half of the map.

	Args:
		swap_spawn_sides: True to swap ally/enemy spawn positions
		ally_policy: Policy ID to assign to ally units
		enemy_policy: Policy ID to assign to enemy units
		skip_ai_units: True to skip AI unit spawning (inference mode)
	"""
	# In inference mode, skip AI unit spawning (player will place units manually)
	if skip_ai_units:
		print("SpawnManager: Skipping AI unit spawning (inference mode)")
		return

	# Use tighter spacing for formations near bases
	var spawn_spacing_x: float = 100.0  # Tighter horizontal spacing
	var spawn_spacing_y: float = 160.0  # Double vertical spacing
	var spawn_cols: int = 10            # More columns for wider formation

	# Define spawn areas in each team's half
	# Left half: x from 100 to map_w/2 - 100
	# Right half: x from map_w/2 + 100 to map_w - 100
	var left_spawn_start = Vector2(100, 200)      # Top-left area
	var right_spawn_start = Vector2(map_w / 2 + 100, 200)  # Top-right area

	# Determine spawn positions based on swap_spawn_sides
	var ally_spawn_start: Vector2
	var enemy_spawn_start: Vector2

	if not swap_spawn_sides:
		# Normal: allies left, enemies right
		ally_spawn_start = left_spawn_start
		enemy_spawn_start = right_spawn_start
	else:
		# Swapped: allies right, enemies left
		ally_spawn_start = right_spawn_start
		enemy_spawn_start = left_spawn_start

	var spawn_side_label = "normal" if not swap_spawn_sides else "SWAPPED"
	print("SpawnManager: Spawning units (", spawn_side_label, "): allies at ", ally_spawn_start, ", enemies at ", enemy_spawn_start)

	# Create ally units with sequential IDs (mix of infantry, snipers, and heavy units)
	print("SpawnManager: Creating ", num_ally_units, " ally units with policy: ", ally_policy)
	for i in range(num_ally_units):
		var col = i % spawn_cols
		var row = i / spawn_cols
		var pos = Vector2(
			ally_spawn_start.x + col * spawn_spacing_x,
			ally_spawn_start.y + row * spawn_spacing_y
		)
		var unit_type = Global.UnitType.INFANTRY
		if i % GameConfig.HEAVY_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.HEAVY
		elif i % GameConfig.SNIPER_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.SNIPER
		Global.spawnUnit(pos, false, unit_type, ally_policy)

	# Create enemy units with sequential IDs (mix of infantry, snipers, and heavy units)
	print("SpawnManager: Creating ", num_enemy_units, " enemy units with policy: ", enemy_policy)
	for i in range(num_enemy_units):
		var col = i % spawn_cols
		var row = i / spawn_cols
		var pos = Vector2(
			enemy_spawn_start.x + col * spawn_spacing_x,
			enemy_spawn_start.y + row * spawn_spacing_y
		)
		var unit_type = Global.UnitType.INFANTRY
		if i % GameConfig.HEAVY_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.HEAVY
		elif i % GameConfig.SNIPER_SPAWN_INTERVAL == 0:
			unit_type = Global.UnitType.SNIPER
		Global.spawnUnit(pos, true, unit_type, enemy_policy)

	print("SpawnManager: All units spawned successfully")
