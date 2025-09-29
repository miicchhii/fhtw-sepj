# Infantry.gd - Standard infantry unit with balanced stats
extends RTSUnit
class_name Infantry

func _initialize_unit_stats() -> void:
	# Set infantry-specific stats
	max_hp = 100
	attack_range = 64.0
	attack_damage = 15
	attack_cooldown = 0.8
	Speed = 50
	print("Infantry stats initialized for unit: ", unit_id)