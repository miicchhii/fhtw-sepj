# Game.gd
extends Node2D
class_name Game

var tick: int = 0
var ai_step: int = 0  # Track AI steps separately from physics ticks
var map_w: int = 1280
var map_h: int = 720
var episode_ended: bool = false
var max_episode_steps: int = 200  # Longer episodes for better learning feedback

var units = []

func _ready() -> void:
	get_units()
	
	# IMPORTANT: Add this node to the "game" group so AiServer can find it
	add_to_group("game")
	print("Game: Added to 'game' group")

func get_units():
	units = null
	units = get_tree().get_nodes_in_group("units")

func _physics_process(delta: float) -> void:
	tick += 1

	# Only process AI logic when we have actions from Python
	var action_batches = AiServer.pop_actions()
	if action_batches.size() > 0:
		ai_step += 1  # Increment AI step counter only when we get actions
		#print("Game: Processing AI step ", ai_step, " with ", action_batches.size(), " action batches")
		
		# Apply actions (from AiServer)
		for actions: Dictionary in action_batches:
			_apply_actions(actions)

		# Advance sim
		for u: RTSUnit in get_tree().get_nodes_in_group("units"):
			u.step(delta)

		# Send obs + rewards
		var obs := _build_observation()
		#print("Game: Sending observation for AI step ", ai_step)
		AiServer.send_observation(obs)

		var center := Vector2(map_w * 0.5, map_h * 0.5)
		var rewards := {}
		var dones := {}

		# Check for episode end condition based on AI steps, not physics ticks
		var should_end_episode = (ai_step >= max_episode_steps)

		# DEBUG: Log episode termination variables
		#print("Game: Episode termination check - ai_step=", ai_step, " max_episode_steps=", max_episode_steps, " should_end_episode=", should_end_episode, " episode_ended=", episode_ended)

		for u: RTSUnit in get_tree().get_nodes_in_group("units"):
			var d: float = u.global_position.distance_to(center)
			# Better reward scaling: closer to center = higher reward
			# Max distance is ~640 (corner to center), so normalize and scale
			var max_dist: float = 640.0
			var normalized_dist: float = clamp(d / max_dist, 0.0, 1.0)
			# Reward range: +1.0 (at center) to -0.5 (at corners)
			rewards[u.unit_id] = 1.0 - (1.5 * normalized_dist)
			dones[u.unit_id] = should_end_episode

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
	var arr: Array = []
	for u: RTSUnit in get_tree().get_nodes_in_group("units"):
		arr.append({
			"id": u.unit_id,
			"type_id": u.type_id,
			"hp": u.hp,
			"max_hp": u.max_hp,
			"pos": [u.global_position.x, u.global_position.y],
		})
	return {
		"ai_step": ai_step,  # Send AI step instead of physics tick
		"tick": tick,
		"map": {"w": map_w, "h": map_h},
		"units": arr,
	}

func _apply_actions(actions: Dictionary) -> void:
	# actions expected shape: { "u1": {"move":[x,y]}, ... }
	for id_var in actions.keys():
		var id: String = String(id_var)

		var u: RTSUnit = _get_unit(id)
		if u == null:
			continue

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
	
	var min_x := 100
	var max_x := 1300
	var min_y := 50
	var max_y := 700
	
	var unit_number = 0
	for u: RTSUnit in get_tree().get_nodes_in_group("units"):
		unit_number += 1
		u.global_position = Vector2(
			randi_range(min_x, max_x),
			randi_range(min_y, max_y)
		)
		u.hp = u.max_hp
		u.target = u.global_position
	
	# Send initial observation immediately after reset
	var obs := _build_observation()
	print("Game: Sending initial observation with ", obs["units"].size(), " units")
	AiServer.send_observation(obs)

#new code - lukas

func _on_area_selected(object):
	var start = object.start
	var end = object.end
	var area = []
	area.append(Vector2(min(start.x, end.x), min(start.y, end.y)))
	area.append(Vector2(max(start.x, end.x), max(start.y, end.y)))
	var ut = get_units_in_area(area)
	for u in units:
		u.set_selected(false)
	for u in ut:
		u.set_selected(!u.selected)
	
	
func get_units_in_area(area):
	var u = []
	for unit in units:
		if unit.position.x > area[0].x and unit.position.x < area[1].x:
			if unit.position.y > area[0].y and unit.position.y < area[1].y:
				u.append(unit)
	return u
