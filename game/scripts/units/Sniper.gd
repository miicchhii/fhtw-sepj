# Sniper.gd - Long-range unit with high damage but slower movement
extends RTSUnit
class_name Sniper

func _initialize_unit_stats() -> void:
	# Set sniper-specific stats
	max_hp = 80
	attack_range = 150.0     # Much longer range
	attack_damage = 25       # Higher damage
	attack_cooldown = 1.0    # Slower attack rate
	Speed = 80               # Slower movement
	print("Sniper stats initialized for unit: ", unit_id)
