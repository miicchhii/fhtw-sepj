# Game.gd
extends Node2D
class_name Game

var tick: int = 0
var ai_step: int = 0  # Track AI steps separately from physics ticks
var ai_tick_interval: int = 25  # Run AI logic every X ticks
var map_w: int = 1280
var map_h: int = 720
var episode_ended: bool = false
var max_episode_steps: int = 100 

var num_ally_units_start = 50
var num_enemy_units_start = 50

# AI Control toggle
var ai_controls_allies: bool = true  # Start with AI controlling allies

var units = []
var unit_scene = preload("res://scenes/units/infantry.tscn")
var next_unit_id = 1

func _ready() -> void:
	init_units()
	get_units()

	# IMPORTANT: Add this node to the "game" group so AiServer can find it
	add_to_group("game")
	print("Game: Added to 'game' group")

func spawn_all_units():
	"""Spawn all ally and enemy units with a mix of infantry and snipers"""
	# Create ally units with sequential IDs (mix of infantry and snipers)
	print("Creating ally units...")
	for i in range(num_ally_units_start):
		var pos = Vector2(300 + (i % 5) * 60, 100 + (i / 5) * 60)
		# Spawn snipers for every 3rd unit (roughly 1/3 snipers, 2/3 infantry)
		var unit_type = Global.UnitType.SNIPER if i % 3 == 0 else Global.UnitType.INFANTRY
		Global.spawnUnit(pos, false, unit_type)

	# Create enemy units with sequential IDs (mix of infantry and snipers)
	print("Creating enemy units...")
	for i in range(num_enemy_units_start):
		var pos = Vector2(700 + (i % 5) * 60, 100 + (i / 5) * 60)
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

			# Check for victory/defeat conditions
			var ally_units = get_tree().get_nodes_in_group("ally")
			var enemy_units = get_tree().get_nodes_in_group("enemy")
			var allies_alive = ally_units.size()
			var enemies_alive = enemy_units.size()

			var game_won = (enemies_alive == 0 and allies_alive > 0)
			var game_lost = (allies_alive == 0 and enemies_alive > 0)

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
				reward += u.damage_dealt_this_step * 0.1  # +0.1 per damage point dealt
				reward += u.kills_this_step * 25.0         # +5.0 per kill
				reward -= u.damage_received_this_step * 0.1  # -0.1 per damage point received
				if u.died_this_step:
					reward -= 10.0  # -10.0 for dying

				# Small positional reward for being near center
				var d: float = u.global_position.distance_to(center)
				var max_dist: float = 640.0
				var normalized_dist: float = clamp(d / max_dist, 0.0, 1.0)
				var position_reward = 0.1 * (1.0 - normalized_dist)  # Small reward: +0.1 at center, 0 at edges
				reward += position_reward

				# Small baseline reward for staying alive
				if not u.died_this_step:
					reward += 0.01

				rewards[u.unit_id] = reward
				dones[u.unit_id] = should_end_episode

				# Reset combat stats for next step
				u.reset_combat_stats()

			# CRITICAL: Send rewards immediately after observation, don't wait
			#print("Game: Sending rewards - should_end_episode: ", should_end_episode, " dones: ", dones)
			AiServer.send_reward(0.0, should_end_episode, {"rewards": rewards, "dones": dones})

			# Force process to ensure message is sent immediately
			await get_tree().process_frame

			# IMPORTANT: Only reset AFTER sending the done signal
			if should_end_episode and not episode_ended:
				episode_ended = true
				print("Episode ended at ai_step ", ai_step, " (physics_tick ", tick, ") - waiting for Python reset...")
				# Don't auto-reset here - let Python handle the reset via _ai_request_reset()

func _build_observation() -> Dictionary:
	var all_units = get_tree().get_nodes_in_group("units")
	var arr: Array = []

	for u: RTSUnit in all_units:
		# Get closest allies and enemies
		var closest_allies = _get_closest_units(u, all_units, false, 10)  # 10 closest allies
		var closest_enemies = _get_closest_units(u, all_units, true, 10)   # 10 closest enemies

		arr.append({
			"id": u.unit_id,
			"type_id": u.type_id,
			"hp": u.hp,
			"max_hp": u.max_hp,
			"pos": [u.global_position.x, u.global_position.y],
			"is_enemy": u.is_enemy,
			# Battle stats
			"attack_range": u.attack_range,
			"attack_damage": u.attack_damage,
			"attack_cooldown": u.attack_cooldown,
			"attack_cooldown_remaining": u._atk_cd,
			"speed": u.Speed,
			"closest_allies": closest_allies,
			"closest_enemies": closest_enemies
		})
	return {
		"ai_step": ai_step,  # Send AI step instead of physics tick
		"tick": tick,
		"map": {"w": map_w, "h": map_h},
		"units": arr,
	}

func _get_closest_units(source_unit: RTSUnit, all_units: Array, find_enemies: bool, max_count: int) -> Array:
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

func _apply_actions(actions: Dictionary) -> void:
	# actions expected shape: { "u1": {"move":[x,y]}, ... }
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
		if a.has("move"):
			var p := a["move"] as Array
			if p.size() >= 2:
				var tx: float = float(p[0])
				var ty: float = float(p[1])
				u.set_move_target(Vector2(tx, ty))

func _get_unit(id: String) -> RTSUnit:
	for u: RTSUnit in get_tree().get_nodes_in_group("units"):
		if u.unit_id == id:
			return u
	return null

func _ai_request_reset() -> void:
	print("Game: Resetting episode...")
	tick = 0
	ai_step = 0
	episode_ended = false

	# Remove all existing units
	for u in get_tree().get_nodes_in_group("units"):
		u.queue_free()

	# Wait for units to be removed
	await get_tree().process_frame

	# Reset unit ID counter to start fresh
	Global.next_unit_id = 1

	# Respawn all units using the reusable function
	print("Respawning units...")
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
