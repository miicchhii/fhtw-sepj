# Infantry.gd - Standard infantry unit with balanced stats
extends RTSUnit
class_name Infantry

func _initialize_unit_stats() -> void:
	# Set infantry-specific stats
	max_hp = 150
	attack_range = 80.0
	attack_damage = 5
	attack_cooldown = 0.2
	Speed = 150
	print("Infantry stats initialized for unit: ", unit_id)
