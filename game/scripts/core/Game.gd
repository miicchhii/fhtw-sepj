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
var ai_tick_interval: int = GameConfig.AI_TICK_INTERVAL

# Map dimensions (from GameConfig)
var map_w: int = GameConfig.MAP_WIDTH
var map_h: int = GameConfig.MAP_HEIGHT

# Episode management
var episode_ended: bool = false  # True when episode terminates
var max_episode_steps: int = GameConfig.MAX_EPISODE_STEPS

# Unit configuration
var num_ally_units_start: int = GameConfig.NUM_ALLY_UNITS
var num_enemy_units_start: int = GameConfig.NUM_ENEMY_UNITS

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

# Core components (initialized in _ready)
var reward_calculator: RewardCalculator = null
var observation_builder: ObservationBuilder = null
var action_handler: ActionHandler = null
var spawn_manager: SpawnManager = null

# Reward configuration - initialized from GameConfig, can be tuned at runtime
# Combat rewards
var reward_damage_to_unit: float = GameConfig.REWARD_DAMAGE_TO_UNIT
var reward_damage_to_base: float = GameConfig.REWARD_DAMAGE_TO_BASE
var reward_unit_kill: float = GameConfig.REWARD_UNIT_KILL
var reward_base_kill: float = GameConfig.REWARD_BASE_KILL
var penalty_damage_received: float = GameConfig.PENALTY_DAMAGE_RECEIVED
var penalty_death: float = GameConfig.PENALTY_DEATH

# Team outcome rewards
var reward_team_victory: float = GameConfig.REWARD_TEAM_VICTORY
var penalty_team_defeat: float = GameConfig.PENALTY_TEAM_DEFEAT

# Positional rewards
var reward_position_multiplier: float = GameConfig.REWARD_POSITION_MULTIPLIER

# Survival reward
var reward_alive_per_step: float = GameConfig.REWARD_ALIVE_PER_STEP

# Movement efficiency rewards
var reward_continue_straight: float = GameConfig.REWARD_CONTINUE_STRAIGHT
var penalty_reverse_direction: float = GameConfig.PENALTY_REVERSE_DIRECTION

# Base damage penalty (applied to entire team when their base takes damage)
var penalty_base_damage_per_unit: float = GameConfig.PENALTY_BASE_DAMAGE_PER_UNIT

# Tactical spacing (anti-clustering)
var reward_tactical_spacing: float = GameConfig.REWARD_TACTICAL_SPACING
var tactical_spacing_threshold: float = GameConfig.TACTICAL_SPACING_THRESHOLD

func _ready() -> void:
	# Initialize reward calculator with current reward configuration
	reward_calculator = RewardCalculator.new(
		reward_damage_to_unit,
		reward_damage_to_base,
		reward_unit_kill,
		reward_base_kill,
		penalty_damage_received,
		penalty_death,
		reward_team_victory,
		penalty_team_defeat,
		reward_position_multiplier,
		reward_alive_per_step,
		reward_continue_straight,
		penalty_reverse_direction,
		penalty_base_damage_per_unit,
		reward_tactical_spacing,
		tactical_spacing_threshold
	)

	# Initialize observation builder
	observation_builder = ObservationBuilder.new(map_w, map_h)

	# Initialize action handler
	action_handler = ActionHandler.new(
		reward_continue_straight,
		penalty_reverse_direction,
		map_w,
		map_h
	)

	# Initialize spawn manager
	spawn_manager = SpawnManager.new(
		map_w,
		map_h,
		num_ally_units_start,
		num_enemy_units_start,
		base_scene,
		self  # Parent node for spawned entities
	)

	# Spawn bases and units
	var bases = spawn_manager.spawn_bases(swap_spawn_sides)
	ally_base = bases["ally_base"]
	enemy_base = bases["enemy_base"]

	init_units()
	get_units()

	# IMPORTANT: Add this node to the "game" group so AiServer can find it
	add_to_group("game")
	print("Game: Added to 'game' group")

func init_units():
	"""Initialize units container and spawn all units."""
	print("Game: Starting init_units()")

	var units_container = get_node("Units")
	print("Game: Units container found: ", units_container != null)
	if not units_container:
		units_container = Node2D.new()
		units_container.name = "Units"
		add_child(units_container)
		print("Game: Created new Units container")

	# Spawn all units using spawn manager
	spawn_manager.spawn_all_units(swap_spawn_sides)
	print("Game: init_units() completed")

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

			# Get all units once for reuse
			var all_units = get_tree().get_nodes_in_group("units")

			# Apply actions using ActionHandler
			for actions: Dictionary in action_batches:
				action_handler.apply_actions(actions, all_units, ai_controls_allies)

			# Build and send observations using ObservationBuilder
			var obs = observation_builder.build_observation(
				ai_step,
				tick,
				all_units,
				ally_base,
				enemy_base
			)
			AiServer.send_observation(obs)

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

			# Calculate rewards using RewardCalculator
			var all_units = get_tree().get_nodes_in_group("units")
			var rewards = reward_calculator.calculate_rewards(
				all_units,
				ally_base,
				enemy_base,
				ai_controls_allies,
				game_won,
				game_lost,
				GameConfig.get_map_center()
			)

			# Build dones dictionary
			var dones := {}
			for u in all_units:
				dones[u.unit_id] = should_end_episode

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

	# Respawn bases and units using spawn manager
	print("Game: Respawning bases and units (episode ", episode_count, ")...")
	var bases = spawn_manager.spawn_bases(swap_spawn_sides)
	ally_base = bases["ally_base"]
	enemy_base = bases["enemy_base"]

	spawn_manager.spawn_all_units(swap_spawn_sides)

	# Refresh units array
	get_units()

	print("Game: Reset complete with ", num_ally_units_start, " ally units and ", num_enemy_units_start, " enemy units")

	# Send initial observation immediately after reset using ObservationBuilder
	var all_units = get_tree().get_nodes_in_group("units")
	var obs = observation_builder.build_observation(
		ai_step,
		tick,
		all_units,
		ally_base,
		enemy_base
	)
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
