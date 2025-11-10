# PlayerController.gd - Manual player control for debugging and testing
#
# Encapsulates manual control features:
# - AI vs manual control toggle (N/M keys)
# - Area selection for units
# - Unit selection helpers
#
# This is secondary to the AI training system and can be disabled
# for headless training or removed entirely if not needed.

class_name PlayerController

# Reference to game node for accessing unit groups
var game_node: Node2D

# AI control state (shared with Game.gd)
var ai_controls_allies: bool = true  # Whether AI controls ally units

func _init(p_game_node: Node2D):
	game_node = p_game_node

func handle_input(event: InputEvent) -> void:
	"""
	Handle keyboard input for AI control toggle.

	Keys:
	- N: Enable AI control for ally units
	- M: Enable manual control for ally units (disables AI)

	Args:
		event: Input event from Game._input()
	"""
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_N:  # N key - Enable AI control
			ai_controls_allies = true
			print("PlayerController: AI now controls ally units")
		elif event.keycode == KEY_M:  # M key - Manual control
			ai_controls_allies = false
			print("PlayerController: Manual control enabled for ally units")

func handle_area_selection(selection_object) -> void:
	"""
	Handle area selection for units (drag selection).

	Prioritizes ally units, but allows selecting enemy units if no allies found.
	This allows inspecting enemy stats for debugging/analysis.

	Args:
		selection_object: Object with 'start' and 'end' Vector2 properties
	"""
	var start = selection_object.start
	var end = selection_object.end

	# Normalize rectangle corners
	var a0 = Vector2(min(start.x, end.x), min(start.y, end.y))
	var a1 = Vector2(max(start.x, end.x), max(start.y, end.y))

	# Try to get ally units first
	var selected_units = get_units_in_area([a0, a1], "ally")

	# If no allies found, try enemy units
	if selected_units.is_empty():
		selected_units = get_units_in_area([a0, a1], "enemy")

	# Deselect all units (both ally and enemy)
	for u in game_node.get_tree().get_nodes_in_group("ally"):
		if u != null and is_instance_valid(u) and u.has_method("set_selected"):
			u.set_selected(false)
	for u in game_node.get_tree().get_nodes_in_group("enemy"):
		if u != null and is_instance_valid(u) and u.has_method("set_selected"):
			u.set_selected(false)

	# Select units inside the area
	for u in selected_units:
		if u != null and is_instance_valid(u) and u.has_method("set_selected"):
			u.set_selected(true)

func get_units_in_area(area: Array, group: String = "ally") -> Array:
	"""
	Get all units from specified group within a rectangular area.

	Args:
		area: Array of 2 Vector2 positions defining rectangle corners
		group: Unit group to search ("ally" or "enemy")

	Returns:
		Array of RTSUnit instances within the area
	"""
	# Normalize rectangle corners (handle any corner order)
	var a0 := Vector2(min(area[0].x, area[1].x), min(area[0].y, area[1].y))
	var a1 := Vector2(max(area[0].x, area[1].x), max(area[0].y, area[1].y))

	var selected: Array = []
	for unit in game_node.get_tree().get_nodes_in_group(group):
		if unit == null or not is_instance_valid(unit):
			continue
		var p: Vector2 = unit.global_position
		if p.x >= a0.x and p.x <= a1.x and p.y >= a0.y and p.y <= a1.y:
			selected.append(unit)
	return selected

func is_ai_controlling_allies() -> bool:
	"""Check if AI is currently controlling ally units."""
	return ai_controls_allies
