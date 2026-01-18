extends Node

func _ready() -> void:
	# This node keeps running even when the game is paused
	process_mode = Node.PROCESS_MODE_ALWAYS

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_pause"):
		get_tree().paused = !get_tree().paused
		get_viewport().set_input_as_handled()
		print("Paused:", get_tree().paused)
