# Infantry.gd - Standard infantry unit with balanced stats
extends RTSUnit
class_name Heavy

func _initialize_unit_stats() -> void:
	# Set heavy-specific stats
	type_id = 2  # Heavy
	max_hp = 300
	attack_range = 100.0
	attack_damage = 10
	attack_cooldown = 0.5
	Speed = 50
	print("Infantry stats initialized for unit: ", unit_id)
