# EpisodeManager.gd - Centralized episode management for RTS training
#
# Encapsulates all episode lifecycle logic.
# Separating this from Game.gd makes it easier to:
# - Test episode tracking and termination logic
# - Modify episode parameters without touching game logic
# - Track episode statistics
# - Handle complex reset scenarios

class_name EpisodeManager

# Episode tracking
var episode_count: int = 0
var episode_ended: bool = false
var max_episode_steps: int

# Spawn side alternation for position-invariant learning
var swap_spawn_sides: bool = false

func _init(p_max_episode_steps: int):
	max_episode_steps = p_max_episode_steps

func should_end_episode(ai_step: int, game_won: bool, game_lost: bool) -> bool:
	"""
	Check if the current episode should terminate.

	Episode termination conditions:
	- ai_step >= max_episode_steps (timeout)
	- All allies dead (game lost)
	- All enemies dead (game won)
	- Base destroyed (immediate win/loss)

	Args:
		ai_step: Current AI step counter
		game_won: Whether allies won this step
		game_lost: Whether allies lost this step

	Returns:
		True if episode should end, False otherwise
	"""
	return (ai_step >= max_episode_steps) or game_won or game_lost

func mark_episode_ended() -> void:
	"""Mark the current episode as ended (prevents multiple end signals)."""
	episode_ended = true

func is_episode_ended() -> bool:
	"""Check if episode has already ended."""
	return episode_ended

func request_reset(
	spawn_manager: SpawnManager,
	observation_builder: ObservationBuilder,
	game_node: Node2D,
	ally_base_ref: Array,  # [0] contains current ally_base
	enemy_base_ref: Array,  # [0] contains current enemy_base
	ai_server: Node
) -> void:
	"""
	Reset the episode when called by Python training system.

	This function handles:
	- Clearing all units and resetting counters
	- Alternating spawn sides for position-invariant learning
	- Respawning all units with fresh IDs
	- Sending initial observation to Python

	Spawn side alternation:
	- Episode 0, 2, 4... (even): allies left, enemies right
	- Episode 1, 3, 5... (odd): allies right, enemies left

	This prevents the AI from learning position-dependent strategies like
	"always move right" instead of "move toward enemies".

	Args:
		spawn_manager: SpawnManager instance for respawning
		observation_builder: ObservationBuilder for initial obs
		game_node: Game node for accessing tree and adding children
		ally_base_ref: Array containing current ally_base (will be updated)
		enemy_base_ref: Array containing current enemy_base (will be updated)
		ai_server: AiServer for sending observations
	"""
	print("EpisodeManager: Resetting episode...")

	# Reset flags
	episode_ended = false

	# Increment episode count and alternate spawn sides
	episode_count += 1
	swap_spawn_sides = (episode_count % 2 == 1)  # Swap on odd episodes

	# Remove all existing bases
	if ally_base_ref[0] and is_instance_valid(ally_base_ref[0]):
		ally_base_ref[0].queue_free()
	if enemy_base_ref[0] and is_instance_valid(enemy_base_ref[0]):
		enemy_base_ref[0].queue_free()

	# Remove all existing units
	for u in game_node.get_tree().get_nodes_in_group("units"):
		u.queue_free()

	# Wait for units and bases to be removed
	await game_node.get_tree().process_frame

	# Reset unit ID counter to start fresh
	Global.next_unit_id = 1

	# Respawn bases and units using spawn manager
	print("EpisodeManager: Respawning bases and units (episode ", episode_count, ")...")
	var bases = spawn_manager.spawn_bases(swap_spawn_sides)
	ally_base_ref[0] = bases["ally_base"]
	enemy_base_ref[0] = bases["enemy_base"]

	spawn_manager.spawn_all_units(swap_spawn_sides)

	# Refresh units list in game node
	game_node.get_units()

	print("EpisodeManager: Reset complete (episode ", episode_count, ")")

	# Send initial observation immediately after reset
	var all_units = game_node.get_tree().get_nodes_in_group("units")
	var obs = observation_builder.build_observation(
		0,  # ai_step = 0 after reset
		0,  # tick = 0 after reset
		all_units,
		ally_base_ref[0],
		enemy_base_ref[0]
	)
	print("EpisodeManager: Sending initial observation with ", obs["units"].size(), " units")
	ai_server.send_observation(obs)

func get_episode_info() -> Dictionary:
	"""
	Get current episode information for logging/debugging.

	Returns:
		Dictionary with episode state:
		- episode_count: Total episodes completed
		- episode_ended: Whether current episode has ended
		- swap_spawn_sides: Current spawn side configuration
		- max_episode_steps: Maximum steps per episode
	"""
	return {
		"episode_count": episode_count,
		"episode_ended": episode_ended,
		"swap_spawn_sides": swap_spawn_sides,
		"max_episode_steps": max_episode_steps
	}

func get_spawn_sides_swapped() -> bool:
	"""Check if spawn sides are currently swapped."""
	return swap_spawn_sides
