# ActionHandler.gd - Centralized action processing for RTS training
#
# Encapsulates all action handling logic for reinforcement learning.
# Separating this from Game.gd makes it easier to:
# - Test action processing in isolation
# - Modify action interpretation without touching game logic
# - Support different action spaces (discrete, continuous, hybrid)
# - Add action validation and error handling

class_name ActionHandler

# Movement rewards/penalties (initialized from Game.gd)
var reward_continue_straight: float
var penalty_reverse_direction: float

# Map dimensions for boundary clamping
var map_w: int
var map_h: int

func _init(
	p_reward_continue_straight: float,
	p_penalty_reverse_direction: float,
	p_map_w: int,
	p_map_h: int
):
	reward_continue_straight = p_reward_continue_straight
	penalty_reverse_direction = p_penalty_reverse_direction
	map_w = p_map_w
	map_h = p_map_h

func apply_actions(
	actions: Dictionary,
	all_units: Array,
	ai_controls_allies: bool
) -> void:
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
		all_units: Array of all RTSUnit instances
		ai_controls_allies: Whether AI is controlling ally units (vs manual control)
	"""
	# Build unit lookup for performance
	var unit_lookup = _build_unit_lookup(all_units)

	# Process each action
	for id_var in actions.keys():
		var id: String = String(id_var)

		var u: RTSUnit = unit_lookup.get(id, null)
		if u == null:
			continue

		# Only apply AI actions to ally units if AI control is enabled
		# Enemy units are always AI controlled
		if not u.is_enemy and not ai_controls_allies:
			continue  # Skip AI actions for ally units when in manual control mode

		var action_dict := actions[id] as Dictionary
		if action_dict.has("move_vector"):
			_apply_movement_action(u, action_dict["move_vector"])

func _build_unit_lookup(all_units: Array) -> Dictionary:
	"""Build a dictionary mapping unit IDs to unit instances for fast lookup."""
	var lookup := {}
	for u: RTSUnit in all_units:
		lookup[u.unit_id] = u
	return lookup

func _apply_movement_action(u: RTSUnit, move_vector: Array) -> void:
	"""
	Apply a movement action to a specific unit.

	Args:
		u: The unit to move
		move_vector: [dx, dy] action vector from Python AI
	"""
	if move_vector.size() < 2:
		return

	var dx: float = float(move_vector[0])
	var dy: float = float(move_vector[1])

	# Interpret action as: direction (normalized) + magnitude (fraction of full step)
	var action_vector = Vector2(dx, dy)
	var action_magnitude = action_vector.length()

	# Maximum movement distance per AI step (from GameConfig)
	var stepsize: float = GameConfig.AI_ACTION_STEPSIZE

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
	new_target = GameConfig.clamp_to_map(new_target)

	# Calculate and store direction change reward/penalty
	_calculate_direction_change_reward(u, new_target)

	# Apply the movement command
	u.set_move_target(new_target)

func _calculate_direction_change_reward(u: RTSUnit, new_target: Vector2) -> void:
	"""
	Calculate reward/penalty based on how much the unit's direction changed.

	Encourages smooth movement patterns:
	- Continuing straight: +reward_continue_straight
	- Reversing direction (180°): -penalty_reverse_direction
	- Intermediate angles: Linear interpolation

	Args:
		u: The unit whose direction change to evaluate
		new_target: The new target position
	"""
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
