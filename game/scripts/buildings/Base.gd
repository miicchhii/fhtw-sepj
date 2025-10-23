# Base.gd - Team base with health system
#
# Each team has a central base that serves as the main objective.
# Bases can take damage from enemy units and their destruction determines match outcome.
extends StaticBody2D
class_name Base

# Team assignment
@export var is_enemy: bool = false   # True for enemy base, False for ally base

# Health properties
@export var max_hp: int = 5000       # Maximum base health
var hp: int = max_hp                  # Current health

# Visual components
@onready var hp_bar := $HPBar if has_node("HPBar") else null
@onready var sprite := $Sprite2D if has_node("Sprite2D") else null

# Reference to game controller
var game_node: Node = null

# Damage tracking for reward calculation
var damage_taken_this_step: int = 0   # Damage received this AI step

func _ready() -> void:
	# Add to appropriate team group
	if is_enemy:
		add_to_group("enemy_base")
		# Apply red tint for enemy base
		if sprite:
			sprite.modulate = Color(1.0, 0.314, 0.335, 1.0)
	else:
		add_to_group("ally_base")
		# Apply blue tint for ally base
		if sprite:
			sprite.modulate = Color(0.4, 0.6, 1.0, 1.0)

	# Add to bases group for easy lookup
	add_to_group("bases")

	# Initialize health bar
	_update_hp_bar()

	# Find game controller
	var game_nodes = get_tree().get_nodes_in_group("game")
	if game_nodes.size() > 0:
		game_node = game_nodes[0]

	print("Base initialized: ", "enemy" if is_enemy else "ally", " HP=", max_hp)

func apply_damage(amount: int, attacker: Node = null) -> void:
	"""Apply damage to the base and check for destruction."""
	var actual_damage = min(amount, hp)
	hp = max(0, hp - amount)

	print("Base (", "enemy" if is_enemy else "ally", ") took ", actual_damage, " damage. HP: ", hp, "/", max_hp)

	# Track damage taken this step (for team penalty calculation)
	damage_taken_this_step += actual_damage

	# Track damage dealt by the attacker (for reward calculation)
	if attacker and is_instance_valid(attacker) and attacker.has_method("reset_combat_stats"):
		attacker.damage_to_base_this_step += actual_damage  # Track base damage separately
		# If this killed the base, give the attacker a base kill credit (worth more than unit kills)
		if hp <= 0:
			attacker.base_kills_this_step += 1

	_update_hp_bar()

	# Check if base is destroyed
	if hp <= 0:
		_on_destroyed()

func reset_damage_tracking() -> void:
	"""Reset damage tracking for next AI step."""
	damage_taken_this_step = 0

func _update_hp_bar() -> void:
	"""Update the visual health bar."""
	if hp_bar:
		hp_bar.max_value = max_hp
		hp_bar.value = hp

func _on_destroyed() -> void:
	"""Handle base destruction - let AI training handle episode end."""
	print("Base destroyed! ", "Enemies win!" if not is_enemy else "Allies win!")

	# Don't reload scene - let the AI training system handle episode reset
	# The game end detection in Game.gd:_physics_process will detect the destroyed base
	# and end the episode properly, sending rewards before reset

	# Remove the base from the game
	queue_free()
