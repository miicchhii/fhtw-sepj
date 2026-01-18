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

# Matchup rotation for balanced training
var matchup_rotation: Array = []  # List of [ally_policy, enemy_policy] pairs
var current_matchup_index: int = 0

func _init(p_max_episode_steps: int):
	max_episode_steps = p_max_episode_steps
	_load_matchup_rotation()

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

	# Get next matchup for balanced training
	var matchup = _get_next_matchup()
	var ally_policy = matchup[0]
	var enemy_policy = matchup[1]
	print("EpisodeManager: Next matchup - allies: ", ally_policy, ", enemies: ", enemy_policy)

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

	# Reset unit ID counter to prevent overflow after many episodes
	# This is safe because RLlib tracks agents per-episode, not globally.
	# Each episode is independent, so reusing IDs across episodes is fine.
	# Without this reset, after ~100 episodes we exceed MAX_AGENTS (10000)
	# and Python crashes when trying to spawn units with IDs > u10000.
	Global.next_unit_id = 1
	print("EpisodeManager: Reset unit ID counter to 1")

	# Respawn bases and units using spawn manager
	print("EpisodeManager: Respawning bases and units (episode ", episode_count, ")...")
	var bases = spawn_manager.spawn_bases(swap_spawn_sides)
	ally_base_ref[0] = bases["ally_base"]
	enemy_base_ref[0] = bases["enemy_base"]

	spawn_manager.spawn_all_units(swap_spawn_sides, ally_policy, enemy_policy)

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

func get_first_matchup() -> Array:
	"""
	Get the first matchup for episode 0.
	Called from Game._ready() before spawning initial units.
	Returns: [ally_policy, enemy_policy]
	"""
	return _get_next_matchup()

func _load_matchup_rotation() -> void:
	"""
	Load policy matchups from JSON and generate round-robin rotation.

	Creates all possible policy vs policy matchups (including self-play)
	ensuring each policy plays against every other equally on both sides.
	"""
	var config_path = "res://config/ai_policies.json"
	var file = FileAccess.open(config_path, FileAccess.READ)

	if not file:
		push_error("Failed to load ai_policies.json for matchup rotation")
		return

	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("Failed to parse ai_policies.json: " + json.get_error_message())
		return

	var data = json.data
	var policies = data.get("policies", {})

	# Get all trainable policies
	var trainable_policies = []
	for policy_id in policies.keys():
		if policies[policy_id].get("trainable", true):
			trainable_policies.append(policy_id)

	# Generate all pairwise matchups (including self-play)
	for ally_policy in trainable_policies:
		for enemy_policy in trainable_policies:
			matchup_rotation.append([ally_policy, enemy_policy])

	print("EpisodeManager: Loaded ", matchup_rotation.size(), " matchups for rotation")
	print("  Trainable policies: ", trainable_policies.size())
	print("  Matchups per policy: ", matchup_rotation.size() / trainable_policies.size() if trainable_policies.size() > 0 else 0)

func _get_next_matchup() -> Array:
	"""
	Get the next matchup in the rotation and advance the index.

	Returns: [ally_policy, enemy_policy]
	"""
	if matchup_rotation.is_empty():
		push_error("No matchups available in rotation!")
		return ["policy_baseline", "policy_baseline"]

	var matchup = matchup_rotation[current_matchup_index % matchup_rotation.size()]
	current_matchup_index += 1
	return matchup

