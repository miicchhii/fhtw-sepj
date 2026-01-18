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

# Unit configuration
var num_ally_units_start: int = GameConfig.NUM_ALLY_UNITS
var num_enemy_units_start: int = GameConfig.NUM_ENEMY_UNITS

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
var episode_manager: EpisodeManager = null
var player_controller: PlayerController = null
var enemy_meta_ai: EnemyMetaAI = null

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

# Training mode (controls matchup rotation and unit spawning)
# True = training mode (rotate matchups, spawn AI units)
# False = inference mode (fixed matchup, skip AI unit spawning)
var training_mode: bool = true

# Episode statistics tracking (for CSV logging)
var episode_stats: Dictionary = {
	"ally_damage_to_units": 0,
	"enemy_damage_to_units": 0,
	"ally_damage_to_base": 0,
	"enemy_damage_to_base": 0,
	"ally_policy": "",
	"enemy_policy": "",
	"outcome": "",  # "ally_won", "enemy_won", "timeout_max_steps", "timeout_no_damage"
	"ally_units_left": 0,
	"enemy_units_left": 0,
	"episode_steps": 0
}

func _ready() -> void:

	# Initialize reward calculator (loads policy configs from JSON)
	reward_calculator = RewardCalculator.new()

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

	# Initialize episode manager
	episode_manager = EpisodeManager.new(GameConfig.MAX_EPISODE_STEPS)

	# Get the first matchup for episode 0
	var first_matchup = episode_manager.get_first_matchup()
	var ally_policy = first_matchup[0]
	var enemy_policy = first_matchup[1]
	print("Game: First matchup - allies: ", ally_policy, ", enemies: ", enemy_policy)

	# Initialize player controller for manual control
	player_controller = PlayerController.new(self)

	# Initialize enemy meta-AI for inference mode
	enemy_meta_ai = EnemyMetaAI.new()
	enemy_meta_ai.set_game_node(self)
	add_child(enemy_meta_ai)

	# Spawn bases and units with assigned policies
	var bases = spawn_manager.spawn_bases(episode_manager.get_spawn_sides_swapped())
	ally_base = bases["ally_base"]
	enemy_base = bases["enemy_base"]

	init_units(ally_policy, enemy_policy)
	get_units()

	# IMPORTANT: Add this node to the "game" group so AiServer can find it
	add_to_group("game")
	print("Game: Added to 'game' group")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset_game"):
		Global.reset()
		get_tree().reload_current_scene()



func init_units(ally_policy: String, enemy_policy: String):
	"""Initialize units container and spawn all units with assigned policies."""
	print("Game: Starting init_units()")

	var units_container = get_node("Units")
	print("Game: Units container found: ", units_container != null)
	if not units_container:
		units_container = Node2D.new()
		units_container.name = "Units"
		add_child(units_container)
		print("Game: Created new Units container")

	# Spawn all units using spawn manager with policy assignments
	spawn_manager.spawn_all_units(episode_manager.get_spawn_sides_swapped(), ally_policy, enemy_policy)
	print("Game: init_units() completed")

func get_units():
	units = null
	units = get_tree().get_nodes_in_group("units")

func _input(event):
	"""Handle player input by delegating to PlayerController."""
	player_controller.handle_input(event)

func _physics_process(_delta: float) -> void:
	tick += 1

	# Unit movement is now handled in their individual _physics_process methods
	# No need to call step() anymore since it's empty

	# Only process AI logic every ai_tick_interval ticks
	if tick % ai_tick_interval == 0:
		# Skip if episode has already ended (waiting for Python reset)
		if episode_manager.is_episode_ended():
			return

		# Run enemy meta-AI decision EVERY tick in inference mode
		# This allows spawning even when there are no agents (0 units at game start)
		if not training_mode and enemy_meta_ai:
			enemy_meta_ai.evaluate_and_spawn()

		# Only process AI logic when we have actions from Python
		var action_batches = AiServer.pop_actions()
		if action_batches.size() > 0:
			ai_step += 1  # Increment AI step counter only when we get actions
			#print("Game: Processing AI step ", ai_step, " at tick ", tick, " with ", action_batches.size(), " action batches")

			# Get all units once for reuse
			var all_units = get_tree().get_nodes_in_group("units")

			# Apply actions using ActionHandler
			for actions: Dictionary in action_batches:
				action_handler.apply_actions(actions, all_units, player_controller.is_ai_controlling_allies())

			# Check for victory/defeat conditions BEFORE building observation
			# (bases may be destroyed during combat)
			var ally_units = get_tree().get_nodes_in_group("ally")
			var enemy_units = get_tree().get_nodes_in_group("enemy")
			var allies_alive = ally_units.size()
			var enemies_alive = enemy_units.size()

			# Check base destruction
			var ally_base_destroyed = (ally_base == null or not is_instance_valid(ally_base))
			var enemy_base_destroyed = (enemy_base == null or not is_instance_valid(enemy_base))

			# Build and send observations using ObservationBuilder
			# Pass null for destroyed bases to avoid "previously freed" error
			var obs_ally_base = ally_base if not ally_base_destroyed else null
			var obs_enemy_base = enemy_base if not enemy_base_destroyed else null
			var obs = observation_builder.build_observation(
				ai_step,
				tick,
				all_units,
				obs_ally_base,
				obs_enemy_base
			)

			# Check if any policy changed this step (triggers episode reset in Python)
			obs["policy_changed"] = _any_policy_changed()
			_clear_all_policy_changed_flags()

			AiServer.send_observation(obs)

			# Game only ends on base destruction (not unit elimination)
			# This allows training to continue even if one team's units are wiped out
			var game_won = enemy_base_destroyed
			var game_lost = ally_base_destroyed

			# Check if any damage was dealt this step (for no-damage timeout in training)
			# Also accumulate episode statistics
			var damage_this_step = false
			for u in all_units:
				if u != null and is_instance_valid(u):
					if u.damage_dealt_this_step > 0 or u.damage_to_base_this_step > 0 or u.damage_received_this_step > 0:
						damage_this_step = true
					# Accumulate damage stats for episode logging
					if u.is_in_group("ally"):
						episode_stats["ally_damage_to_units"] += u.damage_dealt_this_step
						episode_stats["ally_damage_to_base"] += u.damage_to_base_this_step
					else:
						episode_stats["enemy_damage_to_units"] += u.damage_dealt_this_step
						episode_stats["enemy_damage_to_base"] += u.damage_to_base_this_step

			# Check for episode end condition using EpisodeManager
			# In inference mode, there's no timeout - only win/loss conditions end the game
			var should_end_episode = episode_manager.should_end_episode(ai_step, game_won, game_lost, training_mode, damage_this_step)

			# Calculate rewards using RewardCalculator
			# Pass null for destroyed bases to avoid "previously freed" error
			var reward_ally_base = ally_base if not ally_base_destroyed else null
			var reward_enemy_base = enemy_base if not enemy_base_destroyed else null
			var rewards = reward_calculator.calculate_rewards(
				all_units,
				reward_ally_base,
				reward_enemy_base,
				player_controller.is_ai_controlling_allies(),
				game_won,
				game_lost,
				GameConfig.get_map_center()
			)

			# Build dones dictionary
			var dones := {}
			for u in all_units:
				if u != null and is_instance_valid(u):
					dones[u.unit_id] = should_end_episode

			# Build reward data payload
			var reward_data = {"rewards": rewards, "dones": dones}

			# If episode is ending, compile and include episode summary for CSV logging
			if should_end_episode:
				# Determine outcome
				var outcome = ""
				if game_won:
					outcome = "ally_won"
				elif game_lost:
					outcome = "enemy_won"
				elif episode_manager.steps_without_damage >= GameConfig.MAX_STEPS_WITHOUT_DAMAGE:
					outcome = "timeout_no_damage"
				else:
					outcome = "timeout_max_steps"

				# Get policies from first units of each team (they should all have same policy per team)
				var ally_policy = ""
				var enemy_policy = ""
				for u in all_units:
					if u != null and is_instance_valid(u):
						if u.is_in_group("ally") and ally_policy == "":
							ally_policy = u.policy_id
						elif u.is_in_group("enemy") and enemy_policy == "":
							enemy_policy = u.policy_id
						if ally_policy != "" and enemy_policy != "":
							break

				# Finalize episode stats
				episode_stats["outcome"] = outcome
				episode_stats["ally_policy"] = ally_policy
				episode_stats["enemy_policy"] = enemy_policy
				episode_stats["ally_units_left"] = allies_alive
				episode_stats["enemy_units_left"] = enemies_alive
				episode_stats["episode_steps"] = ai_step

				# Include in reward data
				reward_data["episode_summary"] = episode_stats.duplicate()
				print("Episode summary: ", episode_stats)

			# CRITICAL: Send rewards immediately after observation, don't wait
			#print("Game: Sending rewards - should_end_episode: ", should_end_episode, " dones: ", dones)
			AiServer.send_reward(0.0, should_end_episode, reward_data)

			# Reset base damage tracking for next step (only if bases still exist)
			if ally_base and is_instance_valid(ally_base):
				ally_base.reset_damage_tracking()
			if enemy_base and is_instance_valid(enemy_base):
				enemy_base.reset_damage_tracking()

			# Force process to ensure message is sent immediately
			await get_tree().process_frame

			# IMPORTANT: Only reset AFTER sending the done signal
			if should_end_episode and not episode_manager.is_episode_ended():
				episode_manager.mark_episode_ended()
				print("Episode ended at ai_step ", ai_step, " (physics_tick ", tick, ") - waiting for Python reset...")
				# Don't auto-reset here - let Python handle the reset via _ai_request_reset()

func _ai_request_reset(p_training_mode: bool = true) -> void:
	"""
	Reset the game episode when called by Python training system.

	This function is called by AiServer when Python sends a reset request after
	an episode terminates. Delegates to EpisodeManager for full reset orchestration.

	Episode termination conditions:
	- ai_step >= max_episode_steps (default 500)
	- Base destroyed (immediate win/loss)

	Spawn side alternation (training mode only):
	- Episode 0, 2, 4... (even): allies left, enemies right
	- Episode 1, 3, 5... (odd): allies right, enemies left

	Training mode controls:
	- Matchup rotation (training) vs fixed matchup (inference)
	- AI unit spawning (training) vs skip spawning (inference)
	"""
	print("Game: Reset requested (training_mode=", p_training_mode, "), delegating to EpisodeManager...")
	tick = 0
	ai_step = 0
	training_mode = p_training_mode  # Store for use by other systems

	# Reset episode statistics for new episode
	_reset_episode_stats()

	# Reset EnemyMetaAI state for new episode
	if enemy_meta_ai:
		enemy_meta_ai.reset()

	# Delegate to episode manager for full reset
	# Use arrays to pass base references (allows EpisodeManager to update them)
	var ally_base_ref = [ally_base]
	var enemy_base_ref = [enemy_base]

	await episode_manager.request_reset(
		spawn_manager,
		observation_builder,
		self,  # game_node
		ally_base_ref,
		enemy_base_ref,
		AiServer,
		training_mode  # Pass training mode to episode manager
	)

	# Update local references from EpisodeManager
	ally_base = ally_base_ref[0]
	enemy_base = enemy_base_ref[0]

	# Refresh units array
	get_units()

# Manual control - area selection (used for debugging/testing)
func _on_area_selected(object):
	"""Handle area selection by delegating to PlayerController."""
	player_controller.handle_area_selection(object)

# Policy change detection for episode reset
func _any_policy_changed() -> bool:
	"""Check if any unit had its policy changed this step (via UI)."""
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.policy_changed_this_step:
			return true
	return false

func _clear_all_policy_changed_flags() -> void:
	"""Clear policy change flags after processing."""
	for unit in get_tree().get_nodes_in_group("units"):
		unit.clear_policy_changed_flag()

func _ai_send_current_observation() -> void:
	"""
	Send current game state as observation without resetting.
	Used for soft resets when policy changes - preserves unit positions, HP, etc.
	"""
	var all_units = get_tree().get_nodes_in_group("units")
	var obs_ally_base = ally_base if is_instance_valid(ally_base) else null
	var obs_enemy_base = enemy_base if is_instance_valid(enemy_base) else null

	var obs = observation_builder.build_observation(
		ai_step,
		tick,
		all_units,
		obs_ally_base,
		obs_enemy_base
	)
	obs["policy_changed"] = false  # Clear flag for new episode
	AiServer.send_observation(obs)

func _reset_episode_stats() -> void:
	"""Reset episode statistics for a new episode."""
	episode_stats = {
		"ally_damage_to_units": 0,
		"enemy_damage_to_units": 0,
		"ally_damage_to_base": 0,
		"enemy_damage_to_base": 0,
		"ally_policy": "",
		"enemy_policy": "",
		"outcome": "",
		"ally_units_left": 0,
		"enemy_units_left": 0,
		"episode_steps": 0
	}
